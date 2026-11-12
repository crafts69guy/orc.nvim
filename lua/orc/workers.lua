local M = {}
local serial = 0
local statuses = { done = true, partial = true, blocked = true }

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
---@field blockId? string Rex block created by this run.
---@field windowId? string Rex window returned during creation.
---@field state string Observed worker lifecycle state.
---@field acknowledged boolean Whether UserPromptSubmit accepted this run marker.
---@field report string Run-specific report path.
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
			if mode == "new" then
				assert(
					latest.state == "closed" or latest.runId == record.previousRunId,
					"orc pane: current run changed while writing"
				)
			else
				assert(latest.runId == record.runId, "orc pane: current run changed while writing")
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
			return
		end
	end
	error("orc pane: owned block is missing", 0)
end

local function client_for(rt, record)
	local client = require("orc.rex").new(rt)
	local identity = client.identity()
	assert(
		identity.host_id == record.hostId and identity.instance_id == record.instanceId,
		"orc pane: Rex server identity changed; refusing stale block"
	)
	if record.blockId then
		local_block(client, record, record.blockId)
	end
	return client
end

---Parse the final-report fields shared by hooks, status and worker delivery.
---Labels may be bulleted, headed or wrapped in markdown emphasis.
---@param text string
---@return {run:string?,status:'done'|'partial'|'blocked'|nil,validation:boolean}
function M.parse_report(text)
	local run, status, validation, collecting
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		local plain = line:gsub("[*_]", ""):gsub("^%s*[#>%-]*%s*", "")
		run = plain:match("^Run:%s*([%w%-]+)%s*$") or run
		local found = (plain:match("^Status:%s*(%a+)%s*$") or ""):lower()
		status = statuses[found] and found or status
		local tail = plain:match("^Validation%s*:?(.*)$")
		if tail then
			collecting = true
			if tail:match("%S") then
				validation = true
			end
		elseif collecting then
			if line:match("^%s*#") or plain:match("^%u%w*:%s*") then
				collecting = false
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
				local matching_app = app:lower():find(record.kind, 1, true)
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
	local ok, err = pcall(fn, ...)
	if not ok then
		error(
			tostring(err)
				.. "; run orc pane close "
				.. record.task
				.. " --path "
				.. record.path
				.. " --force to mark it closed without touching Rex",
			0
		)
	end
end

local function new_run(rt, record)
	record.previousRunId = record.runId
	record.previousReport = record.report or record.previousReport
	serial = serial + 1
	record.runId = vim.fn
		.sha256(record.path .. record.task .. rt.now() .. rt.clock() .. serial .. vim.uv.os_getpid())
		:sub(1, 24)
	record.report = rt.path(record.path, ".orc", "reports", record.runId .. ".md")
	record.state, record.acknowledged, record.reportStatus = "unconfirmed", false, nil
	record.hookState, record.review = "pending", nil
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

local function git(rt, path, ...)
	local done = rt.exec({ "git", ... }, { cwd = path })
	assert(done.code == 0, "orc pane review: git " .. (...) .. " failed: " .. vim.trim(done.stderr))
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

local function start(rt, feature, task, values, file)
	local transport = values.transport or "tui"
	assert(transport == "tui" or transport == "exec", "orc pane: transport must be tui or exec")
	assert(
		transport ~= "exec" or (values.kind or "codex") == "codex",
		"orc pane: exec transport requires --kind codex"
	)
	local previous = read_record(rt, file)
	if previous and previous.state ~= "closed" then
		hinted(previous, function()
			local client = client_for(rt, previous)
			if previous.blockId then
				snapshot(rt, client, previous)
			end
		end)
		return result(rt, 0, {
			task = task,
			runId = previous.runId,
			status = previous.acknowledged and "started" or "unconfirmed",
			state = previous.state,
			pane = previous.blockId or rt.null,
			path = previous.path,
		})
	end
	local client = require("orc.rex").new(rt)
	local identity = client.identity()
	assert(rt.env.REX_SESSION and rt.env.REX_SESSION ~= "", "orc pane: start needs a Rex session")
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
		mcp = values.mcp or {},
		sessionId = rt.env.REX_SESSION,
		hostId = identity.host_id,
		instanceId = identity.instance_id,
		brief = brief,
	}
	assert(rt.env.REX_BLOCK, "orc pane: start needs a local Rex anchor")
	local_block(client, record, rt.env.REX_BLOCK)
	local creators = client.call("block_creator.list", {})
	local terminal
	for _, creator in ipairs(creators.creators or {}) do
		if creator.name == "com.superlogical.terminal" then
			assert(creator.host_id == record.hostId, "orc pane: terminal creator is remote")
			terminal = true
		end
	end
	assert(terminal, "orc pane: local terminal creator unavailable")
	new_run(rt, record)
	local launch = require("orc.providers").plan(rt, {
		kind = kind,
		role = role,
		transport = transport,
		mcp = record.mcp,
		cwd = path,
		workerFile = file,
		prompt = prompt_text(rt, record, "Your brief: " .. brief .. "."),
	})
	require("orc.worktrees").ignore(rt, path)
	if values.here and role == "implementer" then
		assert(rt.env.REX_BLOCK, "orc pane: --here needs REX_BLOCK")
		for _, worker in ipairs(M.collect(rt, path)) do
			assert(
				worker.role == "scoper"
					or worker.state == "closed"
					or worker.state == "exited"
					or worker.state == "error"
					or worker.path ~= path,
				"orc pane: close the existing pair worker first"
			)
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
			flavor = "com.superlogical.terminal.shell",
			label = "orc:" .. task,
			options = {
				shell = "none",
				login = false,
				cwd = path,
				command = command,
				exit = { on_completion = false },
			},
		},
	}
	local created = values.here
			and client.call("session.new_split", {
				anchor_id = rt.env.REX_BLOCK,
				direction = "horizontal",
				side = "after",
				layout = layout,
				focus = false,
			}, record.sessionId)
		or client.call(
			"session.new_window",
			{ window_label = "orc:" .. feature .. "/" .. task, layout = layout, focus = false },
			record.sessionId
		)
	assert(
		type(created.block_ids) == "table" and type(created.block_ids[1]) == "string",
		"rex: creation returned no block ID"
	)
	record.blockId, record.windowId = created.block_ids[1], created.window_id
	local saved, err = pcall(save, rt, record)
	if not saved then
		pcall(client.call, "block.close", { block_id = record.blockId }, record.sessionId)
		error(err, 0)
	end
	local observed, observation_error = pcall(function()
		client_for(rt, record)
		snapshot(rt, client, record)
	end)
	if not observed then
		local cleaned =
			pcall(client.call, "block.close", { block_id = record.blockId }, record.sessionId)
		if cleaned then
			record.state = "closed"
			pcall(save, rt, record)
		end
		error(observation_error, 0)
	end
	return result(rt, 0, {
		task = task,
		runId = record.runId,
		status = record.acknowledged and "started" or "unconfirmed",
		state = record.state,
		pane = record.blockId,
		path = path,
	})
end

---@param review? {skill:string,target:string} Frames the run as a read-only review instead.
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
	local deadline = rt.clock() + 5000
	while not record.blockId and rt.clock() < deadline do
		rt.sleep(25)
		record = assert(read_record(rt, file), "orc worker: missing record")
		assert(record.runId == run_id, "orc worker: current run changed during launch")
	end
	assert(
		record.state ~= "closed"
			and type(record.blockId) == "string"
			and rt.env.REX_SESSION == record.sessionId
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

-- Untrusted Codex hooks never acknowledge the prompt; stop waiting after this long.
local UNACKNOWLEDGED_WAIT_MS = 60000
local UNACKNOWLEDGED_HINT =
	"worker prompt was not acknowledged; trust orc hooks in Codex (/hooks) or Claude, then inspect the pane"
-- Pane workers never resume on their own after a turn ends without a report.
local NO_REPORT_GRACE_MS = 300000
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
						end
					-- The worker may still be ending its turn; the result carries the cleanup step.
					elseif evidence and record.reportStatus == "done" then
						answer.next = "after accepting the report: orc pane close "
							.. record.task
							.. " --path "
							.. vim.fn.shellescape(record.path)
					end
					if record.state == "rate-limited" then
						answer.hint =
							"close this worker and restart the same brief and worktree with --kind claude --transport tui"
					elseif until_report and record.state == "turn-ended-no-report" then
						answer.hint = NO_REPORT_HINT
					end
					return answer
				end
				if not connected then
					connect()
				end
			end
			if record.queued and record.nativeState == "working" then
				started = rt.clock() -- a queued prompt starts only after the running turn ends
			end
			if
				not until_report
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
			hint = not record.acknowledged
					and rt.clock() - started > UNACKNOWLEDGED_WAIT_MS
					and UNACKNOWLEDGED_HINT
				or nil,
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

local function close_owned(rt, record)
	local client = client_for(rt, record)
	assert(record.blockId, "orc pane: run has no confirmed owned block")
	local process = client.block(record.sessionId, record.blockId, "process")
	assert(
		type(process.last_exit) == "table" or process_matches(process, record),
		"orc pane: process changed; refusing to close block"
	)
	client.call("block.close", { block_id = record.blockId }, record.sessionId)
end

local function close(rt, record, force)
	if record.state == "closed" then
		return result(
			rt,
			0,
			{ status = "closed", task = record.task, pane = record.blockId or rt.null }
		)
	end
	if not force then
		hinted(record, close_owned, rt, record)
	end
	record.state = "closed"
	save(rt, record)
	-- Best effort: the allowlisted MCP config can carry credentials.
	local file = record_path(rt, record.root, record.task, record.path)
	pcall(rt.remove, (file:gsub("%.json$", "")) .. ".mcp.json")
	return result(rt, 0, { status = "closed", task = record.task, pane = record.blockId or rt.null })
end

---Read durable workers, including pair-mode workers that have no plan task.
---@param rt orc.Runtime
---@param cwd? string
---@return orc.Worker[]
---@return string[] skipped Paths with mismatched or missing record identities.
function M.collect(rt, cwd)
	local root = main_root(rt, cwd or rt.cwd)
	local dir, workers, skipped = rt.path(root, ".orc", "workers"), {}, {}
	for _, name in ipairs(rt.list(dir)) do
		if name:match("^[%x]+%.json$") then
			local file = rt.path(dir, name)
			local record = read_record(rt, file)
			if
				record
				and record.root == root
				and record_path(rt, root, record.task, record.path) == file
			then
				if record.state ~= "closed" and record.blockId then
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
	local deadline = rt.clock() + 5000
	while not record.blockId and rt.clock() < deadline do
		rt.sleep(25)
		record = assert(read_record(rt, rt.env.ORC_WORKER_FILE), "orc worker: missing record")
	end
	assert(
		rt.env.ORC_WORKER_FILE == record_path(rt, record.root, record.task, record.path),
		"orc worker: record path mismatch"
	)
	assert(
		rt.env.REX_SESSION == record.sessionId and rt.env.REX_BLOCK == record.blockId,
		"orc worker: Rex block identity mismatch"
	)
	if record.state == "closed" then
		return { code = 0, out = "", err = "" }
	end
	local event = input.hook_event_name
	record.inputReady = false
	if event == "UserPromptSubmit" then
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

local function with_task_lock(rt, file, fn)
	local lock = file .. ".lock"
	rt.mkdir(vim.fs.dirname(file))
	assert(
		rt.mkdir_lock(lock),
		"orc pane: another command holds this task lock; remove "
			.. lock
			.. " if no orc command is running"
	)
	local ok, value = xpcall(fn, debug.traceback)
	rt.remove(lock)
	assert(ok, value)
	return value
end

local function prune(rt, path)
	local closed, skipped = {}, {}
	for _, worker in ipairs(M.collect(rt, path)) do
		if worker.state ~= "closed" then
			local file = record_path(rt, worker.root, worker.task, worker.path)
			local ok, reason = pcall(with_task_lock, rt, file, function()
				worker = assert(read_record(rt, file), "orc pane: worker not found")
				local evidence = snapshot(rt, client_for(rt, worker), worker)
				local completed = (worker.state == "idle" or worker.state == "done")
					and worker.reportStatus == "done"
					and evidence
				if worker.state ~= "exited" and not completed then
					return "worker has no completed report or successful exit"
				end
				close(rt, worker, false)
			end)
			if ok and not reason then
				closed[#closed + 1] = { task = worker.task, pane = worker.blockId or rt.null }
			else
				skipped[#skipped + 1] =
					{ task = worker.task, state = worker.state, reason = tostring(reason) }
			end
		end
	end
	return result(rt, 0, { status = "pruned", closed = closed, skipped = skipped })
end

---Run start/wait/prompt/review/pause/close/prune with a per-task lock and machine-readable output.
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
			skill = "string",
			target = "string",
		})
		assert(not values.force or command == "close", "orc pane: --force only applies to close")
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
		if values.mcp then
			local names = {}
			for _, name in ipairs(vim.split(values.mcp, ",", { trimempty = true })) do
				name = vim.trim(name)
				-- Claude allows display names such as "Framelink MCP for Figma".
				assert(name:match("^[%w_.:-][%w_.: -]*$"), "orc pane: invalid MCP server name " .. name)
				names[name] = true
			end
			values.mcp = vim.tbl_keys(names)
			table.sort(values.mcp)
		end
		assert(values.path and values.path ~= "", "orc pane: --path is required")
		local path = rt.abspath(values.path)
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
				return start(rt, pos[1], task, values, file)
			end
			local record = assert(read_record(rt, file), "orc pane: worker not found")
			if command == "prompt" then
				assert((values.text ~= nil) ~= (values.file ~= nil), "orc pane: supply --text or --file")
				return follow_up(rt, record, values)
			elseif command == "review" then
				return review_run(rt, record, values)
			elseif command == "pause" then
				return pause(rt, record)
			elseif command == "close" then
				return close(rt, record, values.force)
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
