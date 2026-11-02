local M = {}
local serial = 0
local statuses = { done = true, partial = true, blocked = true }

---@class orc.Worker
---@field runId string Identity of the current prompt attempt.
---@field feature string Feature name.
---@field task string Task identifier.
---@field path string Absolute checkout owned by the worker.
---@field root string Main checkout containing the durable record.
---@field kind 'claude'|'codex' Harness executable.
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
---@field reportStatus? 'done'|'partial'|'blocked' Status in the matching report.
---@field process? {pid:integer,name:string,path?:string,script?:string} Captured terminal child identity.
---@field inputReady boolean Last observed readiness; always recomputed before input.
---@field nativeState? string Latest recognized root program status.
---@field nativeOwner? table|userdata Foreground owner, or JSON null when unavailable.
---@field blockedKind? string User action requested by the native program.
---@field exitCode? integer Last terminal child exit code.
---@field deliveryError? string Diagnostic for an unconfirmed terminal write.
---@field observationError? string Diagnostic for a failed live status observation.

local function main_root(rt, cwd)
	local result = rt.exec(
		{ "git", "rev-parse", "--path-format=absolute", "--git-common-dir" },
		{ cwd = cwd }
	)
	assert(result.code == 0 and result.stdout:match("%S"), "orc pane: not a git checkout")
	return vim.fs.dirname(vim.trim(result.stdout))
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
	return record
end

local function save(rt, record, mode)
	local file = record_path(rt, record.root, record.task, record.path)
	local lock = file .. ".state.lock"
	rt.mkdir(vim.fs.dirname(file))
	local deadline = rt.clock() + 5000
	while rt.exec({ "mkdir", "-m", "700", lock }).code ~= 0 do
		assert(rt.clock() < deadline, "orc pane: worker state lock is busy")
		rt.sleep(25)
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
					and latest.hookState == "idle"
					and latest.acknowledged,
				"orc pane: hook authorization changed before paste"
			)
		end
		if latest then
			if latest.state == "closed" and mode ~= "new" then
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
				record.acknowledged = record.acknowledged or latest.acknowledged
				stale_event = (latest.eventRevision or 0) > (record.eventRevision or 0)
				if (mode == "snapshot" or mode == "event") and stale_event then
					record.state = latest.state
					record.inputReady = false
				end
				if mode ~= "event" or stale_event then
					record.hookState = latest.hookState
				end
				record.eventRevision = latest.eventRevision
			end
		end
		record.revision = (latest and latest.revision or 0) + 1
		if mode == "event" and not stale_event then
			record.eventRevision = record.revision
		end
		record.updatedAt = rt.now()
		local report_text = record._reportText
		record._reportText = nil
		rt.write(file, rt.encode(record) .. "\n")
		if report_text then
			rt.write(rt.path(record.path, ".orc", "report.md"), report_text)
		end
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

local function report(rt, record)
	if not record.acknowledged then
		return false
	end
	local text = rt.read(record.report)
	if not text then
		return false
	end
	local run, status, validation, collecting
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		local plain = line:gsub("^%s*[#>*%-]*%s*", "")
		run = plain:match("^Run:%s*([%w%-]+)%s*$") or run
		status = plain:match("^Status:%s*(%a+)%s*$") or status
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
	if run ~= record.runId or not statuses[status] or not validation then
		return false
	end
	record.reportStatus = status
	record._reportText = text
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
	if not identity:find(record.kind, 1, true) then
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
				if app:lower():find(record.kind, 1, true) and (entry.id == nil or entry.id == rt.null) then
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
						record.blockedKind = entry.kind
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
	if record.hookState == "blocked" then
		record.state = "blocked"
	elseif record.hookState == "working" and (record.state == "idle" or record.state == "done") then
		record.state = "working"
	end
	save(rt, record, "snapshot")
	return record.state ~= "closed" and evidence
end

local function result(rt, code, value)
	return { code = code, out = rt.encode(value) .. "\n", err = "", result = value }
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
	record.hookState = "pending"
	record.inputReady, record.nativeState, record.nativeOwner = false, nil, nil
	record.createdAt = rt.now()
end

local function prompt_text(rt, record, body)
	return "[orc-run:"
		.. record.runId
		.. "] You are the orc implementer. Read "
		.. rt.path(rt.root, "agents", "implementer.md")
		.. ". Work only in "
		.. record.path
		.. ". Do not commit or push. "
		.. body
		.. " Write the final report atomically to "
		.. record.report
		.. ". Include Run: "
		.. record.runId
		.. ", Status: done|partial|blocked, Changes, Validation with commands and results, Notes and Docs."
end

local function ignore_reports(rt, path)
	local check = rt.exec({ "git", "check-ignore", "-q", ".orc/probe" }, { cwd = path })
	if check.code ~= 0 then
		local common = rt.exec(
			{ "git", "rev-parse", "--path-format=absolute", "--git-common-dir" },
			{ cwd = path }
		)
		assert(common.code == 0, "orc pane: cannot locate git excludes")
		local file = rt.path(vim.trim(common.stdout), "info", "exclude")
		local previous = rt.read(file) or ""
		rt.write(file, previous .. (previous:sub(-1) == "\n" and "" or "\n") .. ".orc/\n")
	end
end

local function start(rt, feature, task, values, file)
	local previous = read_record(rt, file)
	if previous and previous.state ~= "closed" then
		local client = client_for(rt, previous)
		if previous.blockId then
			snapshot(rt, client, previous)
		end
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
	local kind = values.kind or "claude"
	assert(kind == "claude" or kind == "codex", "orc pane: kind must be claude or codex")
	local path = rt.abspath(values.path)
	assert(rt.exists(path), "orc pane: worktree does not exist")
	local brief = rt.abspath(values.brief)
	assert(rt.read(brief), "orc pane: cannot read brief")
	local record = {
		feature = feature,
		task = task,
		path = path,
		root = main_root(rt, path),
		kind = kind,
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
		role = "implementer",
		cwd = path,
		workerFile = file,
		prompt = prompt_text(rt, record, "Your brief: " .. brief .. "."),
	})
	ignore_reports(rt, path)
	if values.here then
		assert(rt.env.REX_BLOCK, "orc pane: --here needs REX_BLOCK")
		for _, worker in ipairs(M.collect(rt, path)) do
			assert(
				worker.state == "closed" or worker.path ~= path,
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
	vim.list_extend(command, launch.argv)
	local layout = {
		block = {
			flavor = "com.superlogical.terminal.shell",
			label = "orc:" .. task,
			options = { shell = "none", cwd = path, command = command, exit = { on_completion = false } },
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

local function follow_up(rt, record, values)
	local client = client_for(rt, record)
	snapshot(rt, client, record)
	if not record.acknowledged or not record.inputReady then
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
	local body = values.text
	if values.file then
		local file = rt.abspath(values.file)
		assert(rt.read(file), "orc pane: cannot read follow-up file")
		body = "Read and act on " .. file .. "."
	end
	local authorization =
		{ runId = record.runId, eventRevision = record.eventRevision, owner = record.nativeOwner }
	new_run(rt, record)
	save(rt, record, "new")
	local text = prompt_text(rt, record, "Follow-up: " .. body)
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
				and (entry.state == "idle" or entry.state == "done")
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
		client.block(record.sessionId, record.blockId, "write", { data = "\r" })
	end)
	if not sent then
		record.deliveryError = "terminal write was not confirmed"
		save(rt, record, "snapshot")
	end
	return result(rt, 0, {
		status = "unconfirmed",
		task = record.task,
		state = record.state,
		runId = record.runId,
		queued = sent,
		message = sent and "Awaiting UserPromptSubmit acknowledgment" or tostring(err),
	})
end

local function wait_for(rt, record, timeout)
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
	local deadline = rt.clock() + timeout
	local ok, answer = xpcall(function()
		connect()
		repeat
			local disk = read_record(rt, record_path(rt, record.root, record.task, record.path))
			assert(disk and disk.runId == record.runId, "orc pane: current run changed while waiting")
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
			if changed or not connected then
				client_for(rt, record)
				local evidence = snapshot(rt, client, record)
				if
					record.state == "blocked"
					or record.state == "closed"
					or record.state == "error"
					or record.state == "exited"
					or (evidence and (record.state == "idle" or record.state == "done"))
				then
					return {
						task = record.task,
						runId = record.runId,
						state = record.state,
						report = evidence and record.report or rt.null,
						evidence = evidence,
						status = record.reportStatus or rt.null,
					}
				end
				changed = false
				if not connected then
					connect()
				end
			end
			if rt.clock() >= deadline then
				break
			end
			rt.sleep(math.min(250, deadline - rt.clock()))
			changed = true
		until rt.clock() >= deadline
		return {
			task = record.task,
			runId = record.runId,
			state = "timeout",
			report = rt.null,
			evidence = false,
		}
	end, debug.traceback)
	if stream then
		generation = generation + 1
		stream.stop()
	end
	assert(ok, answer)
	return result(rt, 0, answer)
end

local function close(rt, record)
	if record.state == "closed" then
		return result(
			rt,
			0,
			{ status = "closed", task = record.task, pane = record.blockId or rt.null }
		)
	end
	local client = client_for(rt, record)
	assert(record.blockId, "orc pane: run has no confirmed owned block")
	local process = client.block(record.sessionId, record.blockId, "process")
	assert(
		type(process.last_exit) == "table" or process_matches(process, record),
		"orc pane: process changed; refusing to close block"
	)
	client.call("block.close", { block_id = record.blockId }, record.sessionId)
	record.state = "closed"
	save(rt, record)
	return result(rt, 0, { status = "closed", task = record.task, pane = record.blockId })
end

---Read durable workers, including pair-mode workers that have no plan task.
---@param rt orc.Runtime
---@param cwd? string
---@return orc.Worker[]
function M.collect(rt, cwd)
	local root = main_root(rt, cwd or rt.cwd)
	local dir, workers = rt.path(root, ".orc", "workers"), {}
	for _, name in ipairs(rt.list(dir)) do
		if name:match("^[%x]+%.json$") then
			local record = read_record(rt, rt.path(dir, name))
			assert(
				record
					and record.root == root
					and record_path(rt, root, record.task, record.path) == rt.path(dir, name),
				"orc pane: worker record identity mismatch"
			)
			if record.state ~= "closed" and record.blockId then
				local ok, err = pcall(function()
					snapshot(rt, client_for(rt, record), record)
				end)
				if not ok then
					record.state, record.observationError = "disconnected", tostring(err)
				end
			end
			workers[#workers + 1] = record
		end
	end
	return workers
end

---Acknowledge only matching worker hook events; a queued terminal write is not delivery.
---@param rt orc.Runtime
---@param input table|string Harness hook payload.
---@return table result Quiet hook result; invalid worker identity is an error.
function M.event(rt, input)
	if rt.env.ORC_ROLE ~= "implementer" or not rt.env.ORC_WORKER_FILE then
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
	elseif event == "Stop" and record.acknowledged then
		record.state, record.hookState = "idle", "idle"
		report(rt, record)
	else
		return { code = 0, out = "", err = "" }
	end
	save(rt, record, "event")
	return { code = 0, out = "", err = "" }
end

---Run start/wait/prompt/close with a per-task lock and machine-readable output.
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
			here = "boolean",
			timeout = "string",
			text = "string",
			file = "string",
		})
		assert(values.path and values.path ~= "", "orc pane: --path is required")
		local task = command == "start" and pos[2] or pos[1]
		assert(task and task:match("^[%w_.%-]+$") and not task:match("^%.+$"), "orc pane: invalid task")
		assert(
			(command == "start" and #pos == 2 and values.brief) or (command ~= "start" and #pos == 1),
			"orc pane: invalid arguments"
		)
		local path = rt.abspath(values.path)
		local root = main_root(rt, path)
		local file = record_path(rt, root, task, path)
		if command == "wait" then
			local record = assert(read_record(rt, file), "orc pane: worker not found")
			local timeout = tonumber(values.timeout or "1800000")
			assert(timeout and timeout >= 0, "orc pane: invalid timeout")
			return wait_for(rt, record, timeout)
		end
		local lock = file .. ".lock"
		rt.mkdir(vim.fs.dirname(file))
		assert(
			rt.exec({ "mkdir", "-m", "700", lock }).code == 0,
			"orc pane: another command holds this task lock"
		)
		local locked, value = xpcall(function()
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
			elseif command == "close" then
				return close(rt, record)
			end
			error("orc pane: unknown command", 0)
		end, debug.traceback)
		rt.remove(lock)
		assert(locked, value)
		return value
	end, function(err)
		return tostring(err)
	end)
	if not ok then
		return result(rt, 1, { status = "error", stderr = response })
	end
	return response
end

return M
