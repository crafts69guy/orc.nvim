local M = {}
local serial = 0
local statuses = { done = true, partial = true, blocked = true }
local TERMINAL_CREATOR = "com.superlogical.terminal"
local TERMINAL_FLAVOR = TERMINAL_CREATOR .. ".shell"

---@class orc.Worker
---@field runId string Identity of the current prompt attempt.
---@field feature string Feature name.
---@field task string Task identifier.
---@field path string Canonical absolute checkout used by the worker; scopers do not own edits.
---@field root string Main checkout containing the durable record.
---@field kind 'claude'|'codex' Harness executable.
---@field transport 'tui'|'exec' Missing transports in older records default to tui.
---@field threadId? string Codex exec thread identity.
---@field usage? table<string,number> Last completed exec turn's token usage.
---@field rateLimited? boolean Exec errors indicated a usage or rate limit.
---@field execFinished? boolean Runner has saved final usage and child exit status.
---@field role 'implementer'|'scoper' Missing roles in older records default to implementer.
---@field level 'default'|'high'|'max' ORC_LEVEL at start; missing levels default to default.
---@field sessionId string Rex session ID.
---@field here? boolean Whether launch used a split. Older records infer this from the live tiled layer.
---@field blockId? string Rex block created by this run.
---@field launchLabel? string Unique Rex label for the original launch, absent on legacy records.
---@field windowId? string Rex window returned during creation.
---@field state string Observed worker lifecycle state.
---@field acknowledged boolean Whether UserPromptSubmit accepted this run marker.
---@field report string Run-specific report path.
---@field transcript? string Harness transcript path, retained across follow-up runs.
---@field brief string Original handoff file.
---@field hostId string Rex host identity.
---@field instanceId string Rex server instance identity.
---@field createdAt string UTC creation timestamp.
---@field updatedAt string Last state change timestamp.
---@field revision integer Atomic record revision.
---@field eventRevision? integer Revision of the latest applied hook state.
---@field hookState 'pending'|'working'|'blocked'|'idle' Independent harness lifecycle, never inferred from Rex status.
---@field previousRunId? string Previous accepted attempt used for compare-and-swap.
---@field previousReport? string Preserved historical report while delivery is pending.
---@field queued? boolean Follow-up queued behind a working turn; it is acknowledged only when that turn ends.
---@field reportStatus? 'done'|'partial'|'blocked' Status in the matching report.
---@field process? {pid:integer,name:string,path?:string,script?:string} Captured terminal child identity.
---@field inputReady boolean Last observed readiness; always recomputed before input.
---@field nativeState? string Latest recognized root program status.
---@field nativeOwner? table|userdata Foreground owner, or JSON null when unavailable.
---@field blockedKind? string User action requested by the native program.
---@field exitCode? integer Last terminal child exit code.
---@field deliveryError? string Diagnostic for an unconfirmed terminal write.
---@field observationError? string Diagnostic for a failed live status observation.
---@field review? {skill:string,target:string,baseline:string} Read-only review run and its checkout fingerprint.
---@field reviewPin? {runId:string,report:string,baseline:string,started:number} Independent review requested before dispatch.
---@field reviewed? {runId?:string,report?:string,baseline:string} Last done review run or absolute saved report, kept across runs; close requires its fingerprint.

---Whether the worker record still owns its checkout. A failed worker may have left edits.
---@param worker orc.Worker
---@return boolean
function M.owns_checkout(worker)
	return worker.role ~= "scoper" and worker.state ~= "closed" and worker.state ~= "exited"
end

local function main_root(rt, cwd)
	return assert(require("orc.worktrees").root(rt, cwd), "orc pane: not a git checkout")
end

local function key(task, path)
	return vim.fn.sha256(path .. "\0" .. task)
end

local function record_path(rt, root, task, path)
	return rt.path(root, ".orc", "workers", key(task, path) .. ".json")
end

local function read_record(rt, file)
	local text, err = rt.read(file)
	if not text then
		assert(not err or err:find("ENOENT", 1, true), "orc pane: cannot read worker record")
		return nil
	end
	local ok, record = pcall(rt.decode, text)
	assert(ok and type(record) == "table", "orc pane: invalid worker record")
	for _, field in ipairs({
		"runId",
		"path",
		"root",
		"feature",
		"task",
		"sessionId",
		"kind",
		"state",
		"report",
		"hostId",
		"instanceId",
	}) do
		assert(type(record[field]) == "string", "orc pane: invalid worker record field " .. field)
	end
	if record.role == nil then
		record.role = "implementer"
	end
	record.level = record.level or "default"
	record.transport = record.transport or "tui"
	assert(
		record.transport == "tui" or record.transport == "exec",
		"orc pane: invalid worker transport"
	)
	assert(
		record.transport ~= "exec" or record.kind == "codex",
		"orc pane: exec transport requires Codex"
	)
	assert(record.role == "implementer" or record.role == "scoper", "orc pane: invalid worker role")
	return record
end

-- The state lock is held for milliseconds, so an old directory is a crashed holder.
local function stale_lock(lock)
	local stat = vim.uv.fs_stat(lock)
	return stat ~= nil and os.time() - stat.mtime.sec > 60
end

---@param rt orc.Runtime
---@param file string
---@param fn fun():any
---@param wait? boolean Wait briefly and reclaim an expired lock.
---@return any
local function with_task_lock(rt, file, fn, wait)
	local lock = file .. ".lock"
	rt.mkdir(vim.fs.dirname(file))
	local deadline = rt.clock() + 5000
	while not rt.mkdir_lock(lock) do
		assert(
			wait and rt.clock() < deadline,
			"orc pane: another command holds this lock; remove "
				.. lock
				.. " if no orc command is running"
		)
		if stale_lock(lock) then
			local reaper = lock .. ".reaper"
			if rt.mkdir_lock(reaper) then
				local ok, err = pcall(function()
					if stale_lock(lock) then
						rt.rmdir(lock)
					end
				end)
				rt.rmdir(reaper)
				assert(ok, err)
			elseif stale_lock(reaper) then
				rt.rmdir(reaper)
			else
				rt.sleep(25)
			end
		else
			rt.sleep(25)
		end
	end
	local ok, value = xpcall(fn, debug.traceback)
	rt.remove(lock)
	assert(ok, value)
	return value
end

local function save(rt, record, mode)
	local file = record_path(rt, record.root, record.task, record.path)
	local lock = file .. ".state.lock"
	rt.mkdir(vim.fs.dirname(file))
	local deadline = rt.clock() + 5000
	while not rt.mkdir_lock(lock) do
		if stale_lock(lock) then
			rt.remove(lock)
		else
			assert(
				rt.clock() < deadline,
				"orc pane: worker state lock is busy; remove " .. lock .. " if no orc command is running"
			)
			rt.sleep(25)
		end
	end
	local ok, err = pcall(function()
		local latest = read_record(rt, file)
		local stale_event = false
		if mode == "new" and record.previousRunId then
			assert(
				latest
					and latest.runId == record.previousRunId
					and latest.state ~= "closed"
					and latest.eventRevision == record.eventRevision
					and latest.hookState == record._authorizedHook
					and latest.acknowledged,
				"orc pane: hook authorization changed before paste"
			)
		end
		if latest then
			-- Closed wins; a lock-free observer's snapshot of a run a follow-up replaced is dropped.
			if
				(latest.state == "closed" and mode ~= "new")
				or (mode == "snapshot" and latest.runId ~= record.runId)
			then
				for name in pairs(record) do
					record[name] = nil
				end
				for name, value in pairs(latest) do
					record[name] = value
				end
				return
			end
			if mode == "review-pin" then
				assert(latest.runId == record.runId, "orc pane: current run changed while writing")
				latest.reviewPin = record.reviewPin
				record = latest
			elseif mode == "new" then
				assert(
					latest.state == "closed" or latest.runId == record.previousRunId,
					"orc pane: current run changed while writing"
				)
			else
				assert(latest.runId == record.runId, "orc pane: current run changed while writing")
				record.reviewPin = latest.reviewPin
				if record.transport == "exec" and mode ~= "exec" then
					for _, field in ipairs({ "threadId", "usage", "exitCode", "rateLimited", "execFinished" }) do
						if latest[field] ~= nil then
							record[field] = latest[field]
						end
					end
				end
				record.acknowledged = record.acknowledged or latest.acknowledged
				stale_event = (latest.eventRevision or 0) > (record.eventRevision or 0)
				if (mode == "snapshot" or mode == "event" or mode == "exec") and stale_event then
					record.state = latest.state
					record.inputReady = false
				end
				if mode ~= "event" or stale_event then
					record.hookState = latest.hookState
					record.transcript = latest.transcript
				end
				record.eventRevision = latest.eventRevision
			end
		end
		if record.state ~= "closed" then
			if record.rateLimited then
				record.state = "rate-limited"
			elseif record.execFinished then
				record.state = record.exitCode == 0 and "exited" or "error"
			end
		end
		record.revision = (latest and latest.revision or 0) + 1
		if mode == "event" and not stale_event then
			record.eventRevision = record.revision
		end
		record.updatedAt = rt.now()
		record._authorizedHook = nil
		rt.write(file, rt.encode(record) .. "\n")
	end)
	rt.remove(lock)
	assert(ok, err)
end

local function local_block(client, record, block)
	local listed = client.call("session.list_blocks", {}, record.sessionId)
	for _, found in ipairs(listed.blocks or {}) do
		if found.block_id == block then
			assert(
				found.host_id == record.hostId,
				"orc pane: block is remote; local worktrees are unavailable"
			)
			return found
		end
	end
	error("orc pane: owned block is missing", 0)
end

local function verify_server(client, record)
	local identity = client.identity()
	assert(
		identity.host_id == record.hostId and identity.instance_id == record.instanceId,
		"orc pane: Rex server identity changed; refusing stale block"
	)
end

local function client_for(rt, record)
	local client = require("orc.rex").new(rt)
	verify_server(client, record)
	if record.blockId then
		local_block(client, record, record.blockId)
	end
	return client
end

---Parse the final-report fields shared by hooks, status and worker delivery.
---Labels may be bulleted, headed or wrapped in markdown emphasis.
---The first Run and Status win: a report that quotes an earlier run's report keeps its own header.
---@param text string
---@return {run:string?,status:'done'|'partial'|'blocked'|nil,validation:boolean}
function M.parse_report(text)
	local run, status, validation, depth
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		local plain = line:gsub("[*_]", ""):gsub("^%s*[#>%-]*%s*", "")
		run = run or plain:match("^Run:%s*([%w%-]+)%s*$")
		local found = (plain:match("^Status:%s*(%a+)%s*$") or ""):lower()
		status = status or (statuses[found] and found or nil)
		local tail = plain:match("^Validation%s*:?(.*)$")
		local level = #line:match("^%s*(#*)")
		if tail then
			-- A headed Validation keeps its deeper sub-headings; label forms end at any heading.
			depth = level > 0 and level or math.huge
			if tail:match("%S") then
				validation = true
			end
		elseif depth and level <= depth then
			if level > 0 or plain:match("^%u%w*:%s*") then
				depth = nil
			elseif plain:match("%S") then
				validation = true
			end
		end
	end
	return { run = run, status = status, validation = validation == true }
end

local function report(rt, record)
	if not record.acknowledged then
		return false
	end
	local text = rt.read(record.report)
	if not text then
		return false
	end
	local parsed = M.parse_report(text)
	if parsed.run ~= record.runId or not parsed.status or not parsed.validation then
		return false
	end
	record.reportStatus = parsed.status
	return true
end

local function process_matches(process, record)
	local child = process.child
	if type(child) ~= "table" or type(child.pid) ~= "number" then
		return false
	end
	if record.process then
		return record.process.pid == child.pid
			and record.process.name == child.name
			and (not record.process.path or record.process.path == child.path)
			and (not record.process.script or record.process.script == child.script)
	end
	local foreground = type(process.foreground) == "table" and process.foreground or child
	local identity = table
		.concat({
			child.name or "",
			child.path or "",
			child.script or "",
			foreground.name or "",
			foreground.path or "",
			foreground.script or "",
		}, " ")
		:lower()
	local runner = record.transport == "exec"
		and (child.name == "nvim" or identity:find("orc", 1, true))
	if not runner and not identity:find(record.kind, 1, true) then
		return false
	end
	record.process = { pid = child.pid, name = child.name, path = child.path, script = child.script }
	return true
end

local function input_owner_matches(process, owner, kind)
	local foreground = process.foreground
	if type(foreground) ~= "table" or type(owner) ~= "table" then
		return false
	end
	if
		type(foreground.pid) ~= "number"
		or type(owner.pid) ~= "number"
		or type(foreground.name) ~= "string"
		or type(owner.name) ~= "string"
	then
		return false
	end
	if foreground.pid ~= owner.pid or foreground.name ~= owner.name then
		return false
	end
	local name =
		table.concat({ foreground.name, foreground.path or "", foreground.script or "" }, " "):lower()
	return name:find(kind, 1, true) ~= nil
end

local function snapshot(rt, client, record)
	if record.state == "closed" then
		return false
	end
	record.inputReady, record.nativeState, record.nativeOwner = false, nil, nil
	record.blockedKind = nil
	local ok, process = pcall(client.block, record.sessionId, record.blockId, "process")
	if not ok then
		record.state = "disconnected"
		save(rt, record, "snapshot")
		return false
	end
	local alive = process_matches(process, record)
	if type(process.last_exit) == "table" then
		record.exitCode = process.last_exit.exit_code
		record.state = process.last_exit.exit_code == 0 and "exited" or "error"
	elseif not alive then
		record.state = "unknown"
	else
		record.state = "unknown"
		local got, status = pcall(client.block, record.sessionId, record.blockId, "program_status")
		if got then
			for _, entry in ipairs(status.records or {}) do
				local app = entry.effective_app or entry.app or ""
				local matching_app = app:lower():find(record.kind, 1, true) ~= nil
				if record.transport == "exec" then
					matching_app = app == "orc"
				end
				if matching_app and (entry.id == nil or entry.id == rt.null) then
					local state = entry.state
					if
						state == "working"
						or state == "blocked"
						or state == "idle"
						or state == "done"
						or state == "error"
					then
						record.state = state
						record.nativeState, record.nativeOwner = state, entry.owner
						record.inputReady = record.hookState == "idle"
							and (state == "idle" or state == "done")
							and input_owner_matches(process, entry.owner, record.kind)
						record.blockedKind = state == "blocked"
								and type(entry.kind) == "string"
								and entry.kind ~= ""
								and entry.kind ~= "no-evidence"
								and entry.kind
							or nil
					end
				end
			end
		end
	end
	local durable = read_record(rt, record_path(rt, record.root, record.task, record.path))
	if durable and durable.runId == record.runId and durable.acknowledged then
		record.acknowledged = true
	end
	local evidence = report(rt, record)
	if
		record.hookState == "blocked"
		and record.state ~= "exited"
		and record.state ~= "error"
		and not (record.nativeState == "working" and not record.blockedKind)
	then
		record.state = "blocked"
	elseif record.hookState == "working" and (record.state == "idle" or record.state == "done") then
		record.state = "working"
	end
	if
		not evidence
		and record.hookState == "idle"
		and not record.blockedKind
		and (
			record.state == "working"
			or record.state == "idle"
			or record.state == "done"
			or record.state == "blocked"
		)
	then
		record.state = "turn-ended-no-report"
	end
	save(rt, record, "snapshot")
	return record.state ~= "closed" and evidence
end

local function result(rt, code, value)
	return { code = code, out = rt.encode(value) .. "\n", err = "", result = value }
end

-- Rex-side failures can strand a record; tell the user how to release it locally.
local function hinted(record, fn, ...)
	local pending = not record.blockId and record.launchLabel
	local ok, value, extra = pcall(fn, ...)
	if not ok then
		local recovery = pending
				and "; retry the same orc pane start to reconcile the pending launch. If the pane is gone, "
			or "; "
		error(
			tostring(value)
				.. recovery
				.. "run orc pane close "
				.. record.task
				.. " --path "
				.. record.path
				.. " --force to mark it closed without touching Rex",
			0
		)
	end
	return value, extra
end

local function new_run(rt, record)
	-- A follow-up replaces the review run; keep a done review so close can still match it.
	if record.review and record.reportStatus == "done" then
		record.reviewed = { runId = record.runId, baseline = record.review.baseline }
	end
	record.previousRunId = record.runId
	record.previousReport = record.report or record.previousReport
	serial = serial + 1
	record.runId = vim.fn
		.sha256(record.path .. record.task .. rt.now() .. rt.clock() .. serial .. vim.uv.os_getpid())
		:sub(1, 24)
	record.report = rt.path(record.path, ".orc", "reports", record.runId .. ".md")
	record.state, record.acknowledged, record.reportStatus = "unconfirmed", false, nil
	record.hookState, record.review = "pending", nil
	record.reviewPin = nil
	record.inputReady, record.nativeState, record.nativeOwner = false, nil, nil
	record.createdAt = rt.now()
end

local function prompt_text(rt, record, body)
	-- A review run reads the reviewer role whatever role the worker was started with.
	local role = record.review and "reviewer" or record.role
	local profile = rt.path(record.root, ".orc", "validation.md")
	if role == "implementer" and rt.exists(profile) then
		body = body
			.. " Validation profile: read "
			.. profile
			.. "; it overrides the brief's Validate section."
	end
	local prompt = "[orc-run:"
		.. record.runId
		.. "] You are the orc "
		.. role
		.. ". Read "
		.. rt.path(rt.root, "agents", role .. ".md")
		.. ". Work only in "
		.. record.path
		.. ". Do not commit or push. "
		.. body
		.. " If you need a user decision, end the turn with a Status: blocked report that states the question; never wait at an interactive prompt."
		.. " Keep the final report concise (about 60 lines max); put long logs/outputs in files under .scratch/ and cite their paths."
	if role == "scoper" then
		return prompt
			.. " Do not modify files. End your final message with the report. Include Run: "
			.. record.runId
			.. ", Status: done|partial|blocked, Scope with file citations, Validation with commands and results, Decisions."
	elseif role == "reviewer" then
		return prompt
			.. " End your final message with the report; do not write a report file. Include Run: "
			.. record.runId
			.. ", Status: done|partial|blocked, Target, Findings numbered with file citations (say none when clean), Validation with the read-only commands you ran and a statement that no tests ran, Verdict."
	end
	return prompt
		.. " Write the final report atomically to "
		.. record.report
		.. ". Include Run: "
		.. record.runId
		.. ", Status: done|partial|blocked, Changes, Validation with commands and results, Notes and Docs."
end

local review_skills = { ["ponytail-review"] = true, ["ponytail-audit"] = true }

-- Only a TUI implementer can take `pane review`; scopers and exec runs close without one.
local function reviewable(record)
	return record.role == "implementer" and record.transport == "tui"
end

local function git(rt, path, ...)
	local done = rt.exec({ "git", ... }, { cwd = path })
	assert(done.code == 0, "orc pane: git " .. (...) .. " failed: " .. vim.trim(done.stderr))
	return done.stdout
end

-- shortcut: ignored paths (.orc, .scratch, build output) are not compared; hash them if reviewers write there.
local function fingerprint(rt, path)
	local status =
		git(rt, path, "status", "--porcelain=v1", "-z", "--untracked-files=all", "--no-renames")
	local parts = {
		git(rt, path, "rev-parse", "HEAD"),
		status,
		git(rt, path, "diff", "--no-ext-diff", "--no-textconv", "--binary", "HEAD"),
		git(rt, path, "diff", "--cached", "--no-ext-diff", "--no-textconv", "--binary", "HEAD"),
	}
	local untracked = { "hash-object", "--" }
	for _, entry in ipairs(vim.split(status, "\0", { trimempty = true })) do
		if entry:sub(1, 3) == "?? " then
			untracked[#untracked + 1] = entry:sub(4)
		end
	end
	if #untracked > 2 then
		parts[#parts + 1] = git(rt, path, unpack(untracked))
	end
	return vim.fn.sha256(table.concat(parts, "\0"))
end

local function independent_review_hint(record)
	local target = record.task .. " --path " .. vim.fn.shellescape(record.path)
	return "run no-comments on the current diff, then orc pane review-begin "
		.. target
		.. " --review <new-file> before dispatching an independent review; read and accept its verdict, then run orc pane close "
		.. target
		.. " --review <saved report>"
end

local function require_new_review_file(file)
	local _, err, code = vim.uv.fs_lstat(file)
	assert(code == "ENOENT", "orc pane review-begin: report must be a new file: " .. (err or file))
end

local function review_begin(rt, record, path)
	assert(record.state ~= "closed", "orc pane review-begin: worker is closed")
	assert(path and path ~= "", "orc pane review-begin: --review is required")
	local file = rt.abspath(path)
	require_new_review_file(file)
	local baseline = fingerprint(rt, record.path)
	local seconds, microseconds = vim.uv.gettimeofday()
	require_new_review_file(file)
	record.reviewPin = {
		runId = record.runId,
		report = file,
		baseline = baseline,
		started = seconds + microseconds / 1000000,
	}
	save(rt, record, "review-pin")
	return result(
		rt,
		0,
		{ status = "review-pinned", task = record.task, runId = record.runId, report = file }
	)
end

local function independent_review(rt, record, path)
	local pin = record.reviewPin
	assert(
		pin and pin.runId == record.runId,
		"orc pane close: no independent review pinned for the current run"
	)
	local file = rt.abspath(path)
	assert(
		file == pin.report,
		"orc pane close: review report differs from the pinned path " .. pin.report
	)
	local stat, err = vim.uv.fs_lstat(file)
	assert(stat, "orc pane close: cannot read review report " .. file .. ": " .. tostring(err))
	assert(stat.type == "file", "orc pane close: review report must be a regular file")
	assert(
		stat.mtime.sec + stat.mtime.nsec / 1000000000 >= pin.started,
		"orc pane close: review report predates the pin"
	)
	local text, read_error = rt.read(file)
	assert(text, "orc pane close: cannot read review report " .. file .. ": " .. tostring(read_error))
	assert(text:find("%S"), "orc pane close: review report is empty: " .. file)
	assert(
		fingerprint(rt, record.path) == pin.baseline,
		"orc pane close: checkout changed after review-begin"
	)
	return { runId = pin.runId, report = pin.report, baseline = pin.baseline }
end

-- Default target: the checkout's uncommitted diff, else its task branch against the base.
local function review_target(rt, record, values)
	if values.target then
		return values.target
	elseif values.skill == "ponytail-audit" then
		return "the whole repository"
	elseif git(rt, record.path, "status", "--porcelain", "--untracked-files=all") ~= "" then
		return "the uncommitted changes (staged, unstaged and untracked)"
	end
	local branch = vim.trim(git(rt, record.path, "branch", "--show-current"))
	-- Task worktrees use the `<base>--<task>` branch from `orc wt new`.
	local base = branch:match("^(.+)%-%-" .. vim.pesc(record.task) .. "$")
	if base and vim.trim(git(rt, record.path, "rev-list", "--count", base .. "..HEAD")) ~= "0" then
		return "the branch diff `git diff " .. base .. "...HEAD`"
	end
	error(
		"orc pane review: "
			.. record.path
			.. " has no uncommitted changes or task commits; pass --target <range|paths> or --skill ponytail-audit",
		0
	)
end

local function review_body(record, review)
	local call = record.kind == "claude" and "Use the Skill tool to run ponytail:" or "Run $"
	return "Review-only turn: for this run agents/reviewer.md replaces your "
		.. record.role
		.. " role and brief. Do not edit, create, delete or stage files; run no tests, builds, typechecks, linters or orc gate; use read-only commands only. orc compares the checkout before and after this run. "
		.. call
		.. review.skill
		.. " on "
		.. review.target
		.. ". If the skill is unavailable, end with Status: blocked."
end

local function launch_block(found, record)
	return found.host_id == record.hostId
		and found.label == record.launchLabel
		and found.flavor == TERMINAL_FLAVOR
		and found.creator_name == TERMINAL_CREATOR
end

local function process_name_matches(value, expected)
	return type(value) == "string" and vim.fs.basename(value):lower() == expected
end

local function reconcile_launch(rt, client, record)
	local listed = client.call("session.list_blocks", {}, record.sessionId)
	local candidate
	for _, block in ipairs(listed.blocks or {}) do
		if block.label == record.launchLabel then
			assert(not candidate, "orc pane: multiple Rex blocks match the pending launch")
			candidate = block
		end
	end
	assert(
		candidate
			and type(candidate.block_id) == "string"
			and candidate.block_id ~= ""
			and launch_block(candidate, record),
		"orc pane: pending launch has no unique local terminal with its run label"
	)
	local process = client.block(record.sessionId, candidate.block_id, "process")
	local child = type(process.child) == "table" and process.child or {}
	local expected = record.transport == "exec" and "nvim" or record.kind
	local matching_name = process_name_matches(child.name, expected)
		or process_name_matches(child.path, expected)
		or (record.transport == "tui" and process_name_matches(child.script, expected .. ".js"))
	assert(
		matching_name
			and type(child.cwd) == "string"
			and (vim.uv.fs_realpath(child.cwd) or child.cwd) == record.path
			and process_matches(process, record),
		"orc pane: pending launch process does not match the worker and checkout"
	)
	verify_server(client, record)
	record.blockId = candidate.block_id
	record.windowId = type(candidate.window_id) == "string" and candidate.window_id or nil
	save(rt, record)
end

---@class orc.WorkerLayout
---@field layout 'grid'|'skipped'|'failed'
---@field layoutReason? string

---@param layout? orc.WorkerLayout
local function start_result(rt, record, layout)
	return result(
		rt,
		0,
		vim.tbl_extend("force", {
			task = record.task,
			runId = record.runId,
			status = record.acknowledged and "started" or "unconfirmed",
			state = record.state,
			pane = record.blockId or rt.null,
			path = record.path,
		}, layout or {})
	)
end

---Hooks cannot call Rex, so REX_SESSION is compared only when the terminal sets it.
local function session_matches(rt, record)
	local session = rt.env.REX_SESSION
	return not session or session == "" or session == record.sessionId
end

---@param client orc.RexClient
---@param session string
---@return table
local function session_view(client, session)
	return client.call("session.view", { session_id = session }, session)
end

---@param rt orc.Runtime
---@param client orc.RexClient
---@param record orc.Worker
---@param new_block? string
---@param window? string Window containing both caller and worker before close.
---@return orc.WorkerLayout
local function tile(rt, client, record, new_block, window)
	local ok, layout = pcall(function()
		local cache = rt.env.XDG_CACHE_HOME or rt.path(assert(rt.env.HOME, "HOME is not set"), ".cache")
		local file = rt.path(cache, "orc", "rex-layout", vim.fn.sha256(record.sessionId))
		return with_task_lock(rt, file, function()
			local grid = require("orc.rex_grid")
			local anchor = rt.env.REX_BLOCK
			local layer, current_window = grid.find_layer(session_view(client, record.sessionId), anchor)
			if not layer or (window and window ~= current_window) then
				return { layout = "skipped", layoutReason = "anchor is outside the worker's tiled window" }
			end
			local calls, reason = grid.plan(layer, anchor, new_block)
			if not calls then
				return { layout = "skipped", layoutReason = reason }
			end
			for _, call in ipairs(calls) do
				local now = os.time()
				assert(vim.uv.fs_utime(file .. ".lock", now, now))
				call.arguments.session_id = record.sessionId
				client.call(call.method, call.arguments, record.sessionId)
			end
			return { layout = "grid" }
		end, true)
	end)
	if not ok then
		return {
			layout = "failed",
			layoutReason = tostring(layout):match("^(.-)\nstack traceback:") or tostring(layout),
		}
	end
	return layout
end

-- Rex's create RPC alone can take ten seconds before reconciliation begins.
local function launch_deadline(rt, record)
	return rt.clock() + (record.launchLabel and 60000 or 5000)
end

local function start(rt, feature, task, values, file, servers)
	local transport = values.transport or "tui"
	assert(transport == "tui" or transport == "exec", "orc pane: transport must be tui or exec")
	assert(
		transport ~= "exec" or (values.kind or "codex") == "codex",
		"orc pane: exec transport requires --kind codex"
	)
	local previous = read_record(rt, file)
	if previous and previous.state ~= "closed" then
		local layout
		hinted(previous, function()
			local client = client_for(rt, previous)
			local recovered
			if not previous.blockId and previous.launchLabel then
				reconcile_launch(rt, client, previous)
				recovered = previous.blockId
			end
			if previous.blockId then
				snapshot(rt, client, previous)
			end
			if recovered and (previous.here or (previous.here == nil and values.here)) then
				if rt.env.REX_BLOCK and session_matches(rt, previous) then
					layout = tile(rt, client, previous, recovered)
				else
					layout = { layout = "skipped", layoutReason = "no anchor in the worker's Rex session" }
				end
			end
		end)
		return start_result(rt, previous, layout)
	end
	local client = require("orc.rex").new(rt)
	local identity = client.identity()
	local session = require("orc.rex").session(rt, identity)
	local kind = values.kind or "codex"
	assert(kind == "claude" or kind == "codex", "orc pane: kind must be claude or codex")
	local role = values.role or "implementer"
	assert(role == "implementer" or role == "scoper", "orc pane: role must be implementer or scoper")
	local path = values.path
	assert(rt.exists(path), "orc pane: worktree does not exist")
	local brief = rt.abspath(values.brief)
	assert(rt.read(brief), "orc pane: cannot read brief")
	if values.precheck then
		local checked = rt.exec({ "sh", "-c", values.precheck }, { cwd = path })
		if checked.code ~= 0 then
			local lines =
				vim.split((checked.stdout .. checked.stderr):gsub("\n$", ""), "\n", { plain = true })
			return result(rt, 0, {
				status = "precheck-failed",
				exitCode = checked.code,
				output = table.concat(vim.list_slice(lines, math.max(1, #lines - 39)), "\n"),
			})
		end
	end
	local record = {
		feature = feature,
		task = task,
		path = path,
		root = main_root(rt, path),
		kind = kind,
		transport = transport,
		role = role,
		level = rt.env.ORC_LEVEL or "default",
		mcp = servers or {},
		sessionId = session,
		here = values.here == true,
		hostId = identity.host_id,
		instanceId = identity.instance_id,
		brief = brief,
	}
	assert(rt.env.REX_BLOCK, "orc pane: start needs a local Rex anchor")
	local_block(client, record, rt.env.REX_BLOCK)
	local creators = client.call("block_creator.list", {})
	local terminal
	for _, creator in ipairs(creators.creators or {}) do
		if creator.name == TERMINAL_CREATOR then
			assert(creator.host_id == record.hostId, "orc pane: terminal creator is remote")
			terminal = true
		end
	end
	assert(terminal, "orc pane: local terminal creator unavailable")
	new_run(rt, record)
	record.launchLabel = "orc:" .. record.runId .. ":" .. task:sub(1, 99)
	local launch = require("orc.providers").plan(rt, {
		kind = kind,
		role = role,
		transport = transport,
		mcp = record.mcp,
		cwd = path,
		workerFile = file,
		prompt = prompt_text(rt, record, "Your brief: " .. brief .. "."),
	})
	-- Already-installed hook copies still require REX_SESSION, which new Rex no longer exports.
	launch.env.REX_SESSION = session
	require("orc.worktrees").ignore(rt, path)
	if values.here and role == "implementer" then
		assert(rt.env.REX_BLOCK, "orc pane: --here needs REX_BLOCK")
		for _, worker in ipairs(M.collect(rt, path)) do
			if worker.path == path and M.owns_checkout(worker) then
				local command = "orc pane close " .. worker.task .. " --path " .. vim.fn.shellescape(path)
				if worker.state == "error" then
					command = command
						.. " --no-review. If the worker has stopped and its pane is gone, use --force."
				end
				error("orc pane: close the existing pair worker first. Run " .. command, 0)
			end
		end
	end
	save(rt, record, "new")
	local command, names = { "env" }, vim.tbl_keys(launch.env)
	table.sort(names)
	for _, name in ipairs(names) do
		if launch.env[name] == false then
			vim.list_extend(command, { "-u", name })
		end
	end
	for _, name in ipairs(names) do
		if launch.env[name] ~= false then
			command[#command + 1] = name .. "=" .. launch.env[name]
		end
	end
	if transport == "exec" then
		vim.list_extend(command, { rt.path(rt.root, "bin", "orc"), "worker-run", file })
	else
		vim.list_extend(command, launch.argv)
	end
	local layout = {
		block = {
			flavor = TERMINAL_FLAVOR,
			label = record.launchLabel,
			options = {
				shell = "none",
				login = false,
				cwd = path,
				command = command,
				exit = { on_completion = false },
			},
		},
	}
	local method, request =
		"session.new_window",
		{ window_label = "orc:" .. feature .. "/" .. task, layout = layout, focus = false }
	if values.here then
		method, request =
			"session.new_split", {
				anchor_id = rt.env.REX_BLOCK,
				direction = "horizontal",
				side = "after",
				layout = layout,
				focus = false,
			}
	end
	local ok, created = pcall(client.call, method, request, record.sessionId)
	hinted(record, function()
		client = client_for(rt, record)
		if
			ok
			and type(created.block_ids) == "table"
			and #created.block_ids == 1
			and type(created.block_ids[1]) == "string"
			and created.block_ids[1] ~= ""
		then
			local block = local_block(client, record, created.block_ids[1])
			assert(
				launch_block(block, record),
				"orc pane: create reply does not identify the launched terminal"
			)
			record.blockId, record.windowId = created.block_ids[1], created.window_id
			save(rt, record)
		else
			local recovered, reason = pcall(reconcile_launch, rt, client, record)
			if not recovered then
				error(
					(ok and "rex: creation returned no single block ID" or tostring(created))
						.. "; "
						.. tostring(reason),
					0
				)
			end
		end
		snapshot(rt, client, record)
	end)
	local grid = record.here and tile(rt, client, record, record.blockId) or nil
	return start_result(rt, record, grid)
end

---@param review? {skill:string,target:string,baseline?:string}
local function follow_up(rt, record, values, review)
	-- shortcut: exec resume needs a new owned block; add it when follow-ups are required.
	assert(
		record.transport ~= "exec",
		"orc pane: exec follow-ups are not supported; close and start a new worker, or use --transport tui"
	)
	local client = client_for(rt, record)
	snapshot(rt, client, record)
	local queue = values.queue
		and record.nativeState == "working"
		and (record.hookState == "working" or record.hookState == "idle")
	if not record.acknowledged or not (record.inputReady or queue) then
		return result(
			rt,
			0,
			{ status = "not-sent", task = record.task, state = record.state, runId = record.runId }
		)
	end
	local process = client.block(record.sessionId, record.blockId, "process")
	assert(
		process_matches(process, record)
			and input_owner_matches(process, record.nativeOwner, record.kind),
		"orc pane: worker process changed; refusing terminal input"
	)
	local body = "Follow-up: " .. tostring(values.text)
	if review then
		body = review_body(record, review)
		-- Baseline after readiness so it is the state the reviewer starts from.
		review.baseline = fingerprint(rt, record.path)
	elseif values.file then
		local file = rt.abspath(values.file)
		assert(rt.read(file), "orc pane: cannot read follow-up file")
		body = "Follow-up: Read and act on " .. file .. "."
	end
	local authorization =
		{ runId = record.runId, eventRevision = record.eventRevision, owner = record.nativeOwner }
	local authorized_hook = record.hookState
	new_run(rt, record)
	record.review = review
	record.queued = queue or nil
	record._authorizedHook = authorized_hook
	save(rt, record, "new")
	local text = prompt_text(rt, record, body)
	local sent, err = pcall(function()
		client.call(
			"block.event",
			{ block_id = record.blockId, event = { type = "paste", payload = { text = text } } },
			record.sessionId
		)
		client_for(rt, record)
		local current_process = client.block(record.sessionId, record.blockId, "process")
		assert(process_matches(current_process, record), "orc pane: process changed after paste")
		local current_status = client.block(record.sessionId, record.blockId, "program_status")
		local ready = false
		for _, entry in ipairs(current_status.records or {}) do
			local app = entry.effective_app or entry.app or ""
			if
				(entry.id == nil or entry.id == rt.null)
				and app:find(record.kind, 1, true)
				and (
					queue and entry.state == "working"
					or not queue and (entry.state == "idle" or entry.state == "done")
				)
			then
				ready = input_owner_matches(current_process, entry.owner, record.kind)
					and entry.owner.pid == authorization.owner.pid
					and entry.owner.name == authorization.owner.name
			end
		end
		assert(ready, "orc pane: native readiness changed after paste; Enter was not sent")
		local durable = assert(
			read_record(rt, record_path(rt, record.root, record.task, record.path)),
			"orc pane: run disappeared after paste"
		)
		assert(
			durable.runId == record.runId
				and durable.previousRunId == authorization.runId
				and durable.eventRevision == authorization.eventRevision
				and durable.hookState == "pending"
				and not durable.acknowledged,
			"orc pane: hook authorization changed after paste; Enter was not sent"
		)
		client.block(
			record.sessionId,
			record.blockId,
			"write",
			{ data = queue and record.kind == "codex" and "\t" or "\r" }
		)
	end)
	if not sent then
		record.deliveryError = "terminal write was not confirmed"
		save(rt, record, "snapshot")
	end
	local answer = {
		status = queue and sent and "queued" or "unconfirmed",
		task = record.task,
		state = record.state,
		runId = record.runId,
		sent = sent,
		queued = (queue and sent) == true,
		message = sent and "Awaiting UserPromptSubmit acknowledgment" or tostring(err),
	}
	if review then
		answer.mode, answer.skill, answer.target = "review", review.skill, review.target
	end
	return result(rt, 0, answer)
end

local function review_run(rt, record, values)
	assert(
		not (values.text or values.file),
		"orc pane review: the prompt is generated; --text and --file do not apply"
	)
	assert(not values.target or vim.trim(values.target) ~= "", "orc pane review: --target is empty")
	values.skill = values.skill or "ponytail-review"
	assert(
		review_skills[values.skill],
		"orc pane review: --skill must be ponytail-review or ponytail-audit"
	)
	return follow_up(
		rt,
		record,
		values,
		{ skill = values.skill, target = review_target(rt, record, values) }
	)
end

local PAUSE_WAIT_MS = 10000

-- Esc interrupts a TUI turn without a Stop hook, so record the ended turn explicitly;
-- a later `pane prompt` then resumes it as a normal follow-up run.
local function pause(rt, record)
	assert(record.transport ~= "exec", "orc pane: exec workers cannot be paused; close them instead")
	assert(record.state ~= "closed", "orc pane: worker is closed")
	local client = client_for(rt, record)
	snapshot(rt, client, record)
	local function answer(status)
		return result(
			rt,
			0,
			{ status = status, task = record.task, state = record.state, runId = record.runId }
		)
	end
	local function idle()
		return record.nativeState == "idle" or record.nativeState == "done"
	end
	-- Never dismiss a permission or user-action dialog on the user's behalf.
	local function blocked()
		return record.hookState == "blocked" or record.blockedKind ~= nil
	end
	if blocked() or not (idle() or record.nativeState == "working") then
		return answer("not-paused")
	end
	local process = client.block(record.sessionId, record.blockId, "process")
	assert(
		process_matches(process, record)
			and input_owner_matches(process, record.nativeOwner, record.kind),
		"orc pane: worker process changed; refusing terminal input"
	)
	if not idle() then
		client.block(record.sessionId, record.blockId, "write", { data = "\27" })
		local deadline = rt.clock() + PAUSE_WAIT_MS
		repeat
			rt.sleep(250)
			snapshot(rt, client, record)
		until idle() or blocked() or rt.clock() >= deadline
		if blocked() or not idle() then
			return answer("not-paused")
		end
	end
	record.hookState = "idle"
	save(rt, record, "event")
	snapshot(rt, client, record)
	return answer(record.hookState == "idle" and "paused" or "not-paused")
end

---Run the owned Codex exec child from its Rex block; used by the hidden worker-run command.
---Runner metadata shares the hook/snapshot state lock and cannot update a different run.
---@param rt orc.Runtime
---@param file string Absolute durable worker record path.
---@return table result Child exit status and diagnostics; progress is streamed to stdout.
function M.worker_run(rt, file)
	local record = assert(read_record(rt, file), "orc worker: missing record")
	local run_id = record.runId
	assert(
		record.transport == "exec" and not record.execFinished,
		"orc worker: expected an unfinished exec worker"
	)
	assert(
		file == record_path(rt, record.root, record.task, record.path)
			and rt.env.ORC_WORKER_FILE == file,
		"orc worker: record path mismatch"
	)
	local deadline = launch_deadline(rt, record)
	while not record.blockId and record.state ~= "closed" and rt.clock() < deadline do
		rt.sleep(25)
		record = assert(read_record(rt, file), "orc worker: missing record")
		assert(record.runId == run_id, "orc worker: current run changed during launch")
	end
	assert(
		record.state ~= "closed"
			and type(record.blockId) == "string"
			and session_matches(rt, record)
			and rt.env.REX_BLOCK == record.blockId,
		"orc worker: Rex block identity mismatch"
	)
	local launch = require("orc.providers").plan(rt, {
		kind = record.kind,
		role = record.role,
		cwd = record.path,
		transport = "exec",
		mcp = record.mcp,
		workerFile = file,
		prompt = prompt_text(rt, record, "Your brief: " .. record.brief .. "."),
	})
	local lock = file .. "." .. run_id .. ".exec.lock"
	assert(rt.mkdir_lock(lock), "orc worker: exec runner already active")
	local ok, response = pcall(
		require("orc.exec_worker").run,
		rt,
		launch,
		rt.path(record.path, ".orc", "runs", record.runId .. ".jsonl"),
		function(fields)
			local latest = assert(read_record(rt, file), "orc worker: missing record")
			assert(latest.runId == record.runId, "orc worker: current run changed")
			for name, value in pairs(fields) do
				latest[name] = value
			end
			save(rt, latest, "exec")
		end
	)
	rt.remove(lock)
	assert(ok, response)
	return response
end

-- Missing or failing hooks can leave a prompt unacknowledged.
local UNACKNOWLEDGED_WAIT_MS = 60000
local UNACKNOWLEDGED_HINT = "Worker prompt was not acknowledged."
	.. " If needed, trust orc hooks in Codex (/hooks) or Claude."
	.. " Check the pane for 'Hook failed' messages."
	.. " Answer any dialog in the pane, then run orc pane wait again to restart the acknowledgment window."
-- Pane workers never resume on their own after a turn ends without a report.
local NO_REPORT_GRACE_MS = 300000
local STALLED_TRANSCRIPT_SECONDS = 30 * 60
local NO_REPORT_HINT =
	"the worker stayed idle without a report for this run; inspect the pane, then send orc pane prompt"
local WAIT_FAILED_HINT =
	"read stderr and fix its cause, then rerun the same orc pane wait; if Rex restarted or the worker pane is gone, run orc pane close <task> --path <worktree> --force"

local function wait_for(rt, record, timeout, until_report)
	if record.state == "closed" then
		return result(rt, 0, {
			task = record.task,
			runId = record.runId,
			state = "closed",
			report = rt.null,
			evidence = false,
		})
	end
	assert(record.blockId, "orc pane: launch has no confirmed owned block")
	local client = client_for(rt, record)
	local changed, connected = true, false
	local stream, generation = nil, 0
	local function connect()
		generation = generation + 1
		local current = generation
		if stream then
			stream.stop()
		end
		stream = client.watch(record.sessionId, function()
			if generation == current then
				changed = true
			end
		end, function()
			if generation == current then
				connected = false
				changed = true
			end
		end)
		connected = true
	end
	local started = rt.clock()
	local deadline = started + timeout
	local last_snapshot = started
	local ended_since
	local file = record_path(rt, record.root, record.task, record.path)
	-- A follow-up (queued or not) replaces the run on this record; keep waiting for the newest.
	-- acknowledged: a replaced run's report is identified by its Run line, not by the hook.
	local run, followed = { runId = record.runId, report = record.report, acknowledged = true }, {}
	local ok, answer = pcall(function()
		connect()
		repeat
			local disk =
				assert(read_record(rt, file), "orc pane: worker record disappeared while waiting")
			if disk.runId ~= run.runId then
				followed[#followed + 1] = run
				run = { runId = disk.runId, report = disk.report, acknowledged = true }
				started, ended_since, changed = rt.clock(), nil, true
			end
			record = disk
			if record.state == "closed" then
				return {
					task = record.task,
					runId = record.runId,
					state = "closed",
					report = rt.null,
					evidence = false,
				}
			end
			if changed or not connected or rt.clock() - last_snapshot >= 5000 then
				changed = false
				client_for(rt, record)
				local evidence = snapshot(rt, client, record)
				last_snapshot = rt.clock()
				if record.state == "turn-ended-no-report" then
					ended_since = ended_since or last_snapshot
				else
					ended_since = nil
				end
				local transcript_stat = (record.transport == nil or record.transport == "tui")
					and record.hookState == "working"
					and record.transcript
					and vim.fn.filereadable(record.transcript) == 1
					and vim.uv.fs_stat(record.transcript)
				if record.runId ~= run.runId then
					changed = true -- replaced during this snapshot; the next pass follows it
				elseif
					(until_report and evidence)
					or (record.state == "blocked" and (not until_report or record.blockedKind ~= nil))
					or (record.state == "turn-ended-no-report" and (not until_report or last_snapshot - ended_since >= NO_REPORT_GRACE_MS))
					or record.state == "closed"
					or record.state == "error"
					or record.state == "rate-limited"
					or record.state == "exited"
					or (evidence and (record.state == "idle" or record.state == "done"))
				then
					local answer = {
						task = record.task,
						runId = record.runId,
						state = record.state,
						report = evidence and record.report or rt.null,
						evidence = evidence,
						status = record.reportStatus or rt.null,
					}
					-- The worker may still be ending its turn; the result carries the next step.
					local done = evidence and record.reportStatus == "done"
					local target = record.task .. " --path " .. vim.fn.shellescape(record.path)
					if record.review then
						-- Detection, not prevention: the worker keeps its write tools during a review.
						local fingerprinted, now = pcall(fingerprint, rt, record.path)
						answer.mode = "review"
						answer.readOnly = fingerprinted and now == record.review.baseline
						if not answer.readOnly then
							answer.violation = "checkout changed during review run "
								.. record.runId
								.. "; inspect git status and git diff in "
								.. record.path
								.. (fingerprinted and "" or ": " .. tostring(now))
						elseif done then
							answer.next = "after accepting the review verdict: orc pane close "
								.. target
								.. "; send findings as one orc pane prompt follow-up instead"
						end
					elseif
						done
						and reviewable(record)
						and record.state ~= "exited"
						and record.state ~= "error"
					then
						answer.next = "after reading the report, inspecting the diff, running checks and no-comments once the worker is idle: orc pane review "
							.. target
							.. "; or "
							.. independent_review_hint(record)
					elseif done then
						answer.next = "after accepting the report: orc pane close " .. target
					end
					if record.state == "rate-limited" then
						answer.hint =
							"close this worker and restart the same brief and worktree with --kind claude --transport tui"
					elseif until_report and record.state == "turn-ended-no-report" then
						answer.hint = NO_REPORT_HINT
					end
					return answer
				elseif
					transcript_stat
					and os.time() - transcript_stat.mtime.sec >= STALLED_TRANSCRIPT_SECONDS
				then
					return {
						task = record.task,
						runId = record.runId,
						state = "stalled",
						report = rt.null,
						evidence = false,
						transcript = record.transcript,
						hint = "worker transcript unchanged for 30+ minutes while working; check the pane for a running child process (a long test); if none, close with orc pane close "
							.. record.task
							.. " --path "
							.. vim.fn.shellescape(record.path)
							.. " --no-review, record why in the task log, then review and validate the diff yourself or restart the same brief",
					}
				end
				if not connected then
					connect()
				end
			end
			if record.queued and record.nativeState ~= "idle" and record.nativeState ~= "done" then
				started = rt.clock() -- a queued prompt needs evidence that the running turn ended
			end
			if
				record.runId == run.runId
				and not record.acknowledged
				and rt.clock() - started > UNACKNOWLEDGED_WAIT_MS
			then
				return {
					task = record.task,
					runId = record.runId,
					state = "unacknowledged",
					report = rt.null,
					evidence = false,
					hint = UNACKNOWLEDGED_HINT,
				}
			end
			if rt.clock() >= deadline then
				break
			end
			rt.sleep(math.min(250, deadline - rt.clock()))
		until rt.clock() >= deadline
		return {
			task = record.task,
			runId = record.runId,
			state = "timeout",
			report = rt.null,
			evidence = false,
			hint = not record.acknowledged and UNACKNOWLEDGED_HINT or nil,
		}
	end)
	if stream then
		generation = generation + 1
		stream.stop()
	end
	if not ok then
		error(answer, 0)
	end
	if #followed > 0 then
		answer.previousRuns = {}
		for _, entry in ipairs(followed) do
			local found = report(rt, entry)
			answer.previousRuns[#answer.previousRuns + 1] = {
				runId = entry.runId,
				report = found and entry.report or rt.null,
				status = entry.reportStatus or rt.null,
			}
		end
	end
	return result(rt, 0, answer)
end

-- A done review run or attested saved report must match the checkout as it is now.
local function unreviewed(rt, record)
	local last = record.reviewed
	if
		not (last and last.report)
		and record.review
		and report(rt, record)
		and record.reportStatus == "done"
	then
		last = { runId = record.runId, baseline = record.review.baseline }
	end
	if last and fingerprint(rt, record.path) == last.baseline then
		return nil
	end
	return "orc pane close: "
		.. (last and "the checkout changed after " .. (last.report and "saved review " .. last.report or "self-review run " .. last.runId) or "no done self-review for this implementer")
		.. "; run no-comments on the current diff, then orc pane review "
		.. record.task
		.. " --path "
		.. vim.fn.shellescape(record.path)
		.. " and wait for it, then close; or "
		.. independent_review_hint(record)
		.. "; pass --no-review only for an abandoned, stalled or failed task or an unavailable review skill"
end

---@param rt orc.Runtime
---@param client orc.RexClient
---@param record orc.Worker
---@return { window?:string, outcome?:orc.WorkerLayout }?
local function closing_layout(rt, client, record)
	if record.here == false then
		return nil
	end
	local anchor = rt.env.REX_BLOCK
	if not anchor or anchor == "" or not session_matches(rt, record) then
		return record.here
				and {
					outcome = { layout = "skipped", layoutReason = "no anchor in the worker's Rex session" },
				}
			or nil
	end
	local ok, window = pcall(function()
		local grid = require("orc.rex_grid")
		local view = session_view(client, record.sessionId)
		local worker_layer, worker_window = grid.find_layer(view, assert(record.blockId))
		if worker_layer and grid.find_layer(view, anchor) == worker_layer then
			return worker_window
		end
	end)
	if not ok then
		return { outcome = { layout = "failed", layoutReason = tostring(window) } }
	end
	if window then
		return { window = window }
	end
	return record.here
			and {
				outcome = {
					layout = "skipped",
					layoutReason = "anchor is outside the worker's tiled window",
				},
			}
		or nil
end

---@return string? refusal Why the worker still needs a review.
---@return {client:orc.RexClient, window?:string, outcome?:orc.WorkerLayout}? layout
local function close_owned(rt, record, authorize)
	local client = client_for(rt, record)
	assert(record.blockId, "orc pane: run has no confirmed owned block")
	local process = client.block(record.sessionId, record.blockId, "process")
	local exited = type(process.last_exit) == "table"
	assert(
		(exited and type(process.child) ~= "table") or process_matches(process, record),
		"orc pane: process changed; refusing to close block"
	)
	verify_server(client, record)
	local refusal = authorize(exited)
	if refusal then
		return refusal
	end
	local layout = closing_layout(rt, client, record)
	client.call("block.close", { block_id = record.blockId }, record.sessionId)
	if layout then
		return nil, { client = client, window = layout.window, outcome = layout.outcome }
	end
end

local function close(rt, record, force, no_review, review)
	local accepted
	local function authorize(skip_self_review)
		if review then
			local checked, value = pcall(independent_review, rt, record, review)
			if not checked then
				return tostring(value) .. "; " .. independent_review_hint(record)
			end
			accepted = value
		elseif not (skip_self_review or no_review) and reviewable(record) then
			-- Keep review failures out of hinted's local-only recovery path.
			local checked, refusal = pcall(unreviewed, rt, record)
			if not checked then
				return "orc pane close: cannot compare the checkout with its review: "
					.. tostring(refusal)
					.. "; inspect git status in "
					.. record.path
					.. ", or pass --no-review"
			end
			return refusal
		end
	end
	local already_closed = record.state == "closed"
	local refusal, layout
	if force or already_closed then
		refusal = authorize(true)
	else
		refusal, layout = hinted(record, close_owned, rt, record, authorize)
	end
	if refusal then
		return result(
			rt,
			1,
			{ status = "not-reviewed", task = record.task, runId = record.runId, stderr = refusal }
		)
	end
	if not already_closed then
		if accepted then
			record.reviewed = accepted
		end
		record.state = "closed"
		save(rt, record)
		-- Best effort: the allowlisted MCP config can carry credentials.
		local file = record_path(rt, record.root, record.task, record.path)
		pcall(rt.remove, (file:gsub("%.json$", "")) .. ".mcp.json")
	end
	local outcome = layout and (layout.outcome or tile(rt, layout.client, record, nil, layout.window))
	return result(
		rt,
		0,
		vim.tbl_extend(
			"force",
			{ status = "closed", task = record.task, pane = record.blockId or rt.null },
			outcome or {}
		)
	)
end

---Read worker records, including pair-mode workers that have no plan task.
---@param rt orc.Runtime
---@param cwd? string
---@param opts? {durable_only?: boolean} Set durable_only to read recorded states without querying Rex.
---@return orc.Worker[]
---@return string[] skipped Paths with mismatched or missing record identities.
function M.collect(rt, cwd, opts)
	local root = main_root(rt, cwd or rt.cwd)
	local dir, workers, skipped = rt.path(root, ".orc", "workers"), {}, {}
	local refresh = not (opts and opts.durable_only)
	for _, name in ipairs(rt.list(dir)) do
		if name:match("^[%x]+%.json$") then
			local file = rt.path(dir, name)
			local record = read_record(rt, file)
			if
				record
				and record.root == root
				and record_path(rt, root, record.task, record.path) == file
			then
				if refresh and record.state ~= "closed" and record.blockId then
					local ok, err = pcall(function()
						snapshot(rt, client_for(rt, record), record)
					end)
					if not ok then
						record.state, record.observationError = "disconnected", tostring(err)
					end
				end
				workers[#workers + 1] = record
			else
				skipped[#skipped + 1] = file
			end
		end
	end
	return workers, skipped
end

---Acknowledge only matching worker hook events; a queued terminal write is not delivery.
---@param rt orc.Runtime
---@param input table|string Harness hook payload.
---@return table result Quiet hook result; invalid worker identity is an error.
function M.event(rt, input)
	if
		(rt.env.ORC_ROLE ~= "implementer" and rt.env.ORC_ROLE ~= "scoper")
		or not rt.env.ORC_WORKER_FILE
	then
		return { code = 0, out = "", err = "" }
	end
	if type(input) == "string" then
		input = rt.decode(input)
	end
	assert(type(input) == "table", "orc worker: invalid hook input")
	local record = assert(read_record(rt, rt.env.ORC_WORKER_FILE), "orc worker: missing record")
	local deadline = launch_deadline(rt, record)
	while not record.blockId and record.state ~= "closed" and rt.clock() < deadline do
		rt.sleep(25)
		record = assert(read_record(rt, rt.env.ORC_WORKER_FILE), "orc worker: missing record")
	end
	assert(
		rt.env.ORC_WORKER_FILE == record_path(rt, record.root, record.task, record.path),
		"orc worker: record path mismatch"
	)
	assert(
		type(record.blockId) == "string"
			and session_matches(rt, record)
			and rt.env.REX_BLOCK == record.blockId,
		"orc worker: Rex block identity mismatch"
	)
	if record.state == "closed" then
		return { code = 0, out = "", err = "" }
	end
	local event = input.hook_event_name
	record.inputReady = false
	if event == "UserPromptSubmit" then
		if type(input.transcript_path) == "string" and input.transcript_path ~= "" then
			record.transcript = input.transcript_path
		end
		local marker = type(input.prompt) == "string" and input.prompt:match("^%[orc%-run:([%w%-]+)%]")
		if marker == record.runId then
			record.acknowledged = true
		end
		record.state, record.hookState = "working", "working"
	elseif event == "PermissionRequest" then
		record.state, record.hookState = "blocked", "blocked"
	elseif event == "PostToolUse" and record.hookState == "blocked" then
		record.state, record.hookState = "working", "working"
	elseif event == "Stop" then
		-- Until a queued run is acknowledged, Stop ends the previous run's turn: keep only its report.
		local run, file = record.runId, record.report
		if not record.acknowledged then
			run, file = record.previousRunId, record.previousReport
		end
		local message = input.last_assistant_message
		if
			file
			and not rt.exists(file)
			and type(message) == "string"
			and M.parse_report(message).run == run
		then
			rt.write(file, message)
		end
		if not record.acknowledged then
			return { code = 0, out = "", err = "" }
		end
		record.state, record.hookState = "idle", "idle"
		report(rt, record)
	else
		return { code = 0, out = "", err = "" }
	end
	save(rt, record, "event")
	return { code = 0, out = "", err = "" }
end

local function prune(rt, path)
	local closed, skipped = {}, {}
	for _, worker in ipairs(M.collect(rt, path)) do
		if worker.state ~= "closed" then
			local file = record_path(rt, worker.root, worker.task, worker.path)
			local layout, layout_reason
			local ok, reason = pcall(with_task_lock, rt, file, function()
				worker = assert(read_record(rt, file), "orc pane: worker not found")
				local evidence = snapshot(rt, client_for(rt, worker), worker)
				local completed = (worker.state == "idle" or worker.state == "done")
					and worker.reportStatus == "done"
					and evidence
				if worker.state ~= "exited" and not completed then
					return "worker has no completed report or successful exit"
				end
				local closed = close(rt, worker, false)
				if closed.code ~= 0 then
					return closed.result.stderr
				end
				layout, layout_reason = closed.result.layout, closed.result.layoutReason
			end)
			if ok and not reason then
				closed[#closed + 1] = {
					task = worker.task,
					pane = worker.blockId or rt.null,
					layout = layout,
					layoutReason = layout_reason,
				}
			else
				skipped[#skipped + 1] =
					{ task = worker.task, state = worker.state, reason = tostring(reason) }
			end
		end
	end
	return result(rt, 0, { status = "pruned", closed = closed, skipped = skipped })
end

---Manage workers and pin independent reviews with machine-readable output.
---@param rt orc.Runtime
---@param argv string[]
---@return table result Exit code, JSON stdout and diagnostics.
function M.run(rt, argv)
	local ok, response = xpcall(function()
		local command = argv[1]
		local values, pos = require("orc.args").parse(vim.list_slice(argv, 2), {
			path = "string",
			brief = "string",
			kind = "string",
			transport = "string",
			role = "string",
			here = "boolean",
			["allow-subdir"] = "boolean",
			precheck = "string",
			mcp = "string",
			queue = "boolean",
			["until"] = "string",
			timeout = "string",
			text = "string",
			file = "string",
			force = "boolean",
			["no-review"] = "boolean",
			review = "string",
			skill = "string",
			target = "string",
		})
		assert(not values.force or command == "close", "orc pane: --force only applies to close")
		assert(
			not values.review or command == "close" or command == "review-begin",
			"orc pane: --review only applies to close and review-begin"
		)
		assert(
			not (values.review and values["no-review"]),
			"orc pane: --review and --no-review are mutually exclusive"
		)
		assert(
			not values["no-review"] or command == "close",
			"orc pane: --no-review only applies to close"
		)
		assert(not values.queue or command == "prompt", "orc pane: --queue only applies to prompt")
		assert(
			not (values.skill or values.target) or command == "review",
			"orc pane: --skill and --target only apply to review"
		)
		assert(
			not values["until"] or (command == "wait" and values["until"] == "report"),
			"orc pane: --until must be report and only applies to wait"
		)
		assert(
			not (values.precheck or values["allow-subdir"]) or command == "start",
			"orc pane: --precheck and --allow-subdir only apply to start"
		)
		assert(
			not values.transport or command == "start",
			"orc pane: --transport only applies to start"
		)
		assert(not values.mcp or command == "start", "orc pane: --mcp only applies to start")
		local mcp = values.mcp --[[@as string?]]
		local servers
		if mcp then
			local names = {}
			for _, name in ipairs(vim.split(mcp, ",", { trimempty = true })) do
				name = vim.trim(name)
				-- Claude allows display names such as "Framelink MCP for Figma".
				assert(name:match("^[%w_.:-][%w_.: -]*$"), "orc pane: invalid MCP server name " .. name)
				names[name] = true
			end
			servers = vim.tbl_keys(names)
			table.sort(servers)
		end
		local raw_path = values.path --[[@as string?]]
		assert(raw_path and raw_path ~= "", "orc pane: --path is required")
		local path = rt.abspath(raw_path)
		path = vim.uv.fs_realpath(path) or path
		values.path = path
		if command == "prune" then
			assert(#pos == 0 and vim.tbl_count(values) == 1, "usage: orc pane prune --path <dir>")
			return prune(rt, path)
		end
		local task = command == "start" and pos[2] or pos[1]
		assert(task and task:match("^[%w_.%-]+$") and not task:match("^%.+$"), "orc pane: invalid task")
		assert(
			(command == "start" and #pos == 2 and values.brief) or (command ~= "start" and #pos == 1),
			"orc pane: invalid arguments"
		)
		local root = main_root(rt, path)
		if command == "start" then
			local checkout =
				assert(require("orc.worktrees").checkout(rt, path), "orc pane: not a git checkout")
			assert(
				values["allow-subdir"] or path == (vim.uv.fs_realpath(checkout) or checkout),
				"orc pane: --path must be checkout toplevel "
					.. checkout
					.. "; use --allow-subdir to override"
			)
		end
		local file = record_path(rt, root, task, path)
		if command == "wait" then
			local record = assert(read_record(rt, file), "orc pane: worker not found")
			local timeout = tonumber(values.timeout or "1800000")
			assert(timeout and timeout >= 0, "orc pane: invalid timeout")
			return wait_for(rt, record, timeout, values["until"] == "report")
		end
		return with_task_lock(rt, file, function()
			if command == "start" then
				assert(
					pos[1]:match("^[%w_.%-]+$") and not pos[1]:match("^%.+$"),
					"orc pane: invalid feature"
				)
				return start(rt, pos[1], task, values, file, servers)
			end
			local record = assert(read_record(rt, file), "orc pane: worker not found")
			if command == "prompt" then
				assert((values.text ~= nil) ~= (values.file ~= nil), "orc pane: supply --text or --file")
				return follow_up(rt, record, values)
			elseif command == "review" then
				return review_run(rt, record, values)
			elseif command == "review-begin" then
				assert(
					vim.tbl_count(values) == 2 and values.review,
					"usage: orc pane review-begin <task> --path <dir> --review <new-file>"
				)
				return review_begin(rt, record, values.review)
			elseif command == "pause" then
				return pause(rt, record)
			elseif command == "close" then
				return close(rt, record, values.force, values["no-review"], values.review)
			end
			error("orc pane: unknown command", 0)
		end)
	end, function(err)
		return tostring(err)
	end)
	if not ok then
		local answer = { status = "error", stderr = response }
		if argv[1] == "wait" then
			answer.state, answer.hint = "wait-failed", WAIT_FAILED_HINT
		end
		return result(rt, 1, answer)
	end
	return response
end

return M
