local runtime = require("orc.runtime")
local workers = require("orc.workers")

local function fake()
	local root = Test.temp()
	local rt = runtime.new({
		cwd = root,
		env = {
			HOME = root,
			REX_SESSION = "session:fixture",
			REX_BLOCK = "block:main",
			ORC_INKDROP_MCP_MODE = false,
			ORC_INKDROP_MCP_CONFIG = false,
			CLAUDE_CONFIG_DIR = false,
			CODEX_HOME = false,
		},
	})
	rt.env.ORC_ROLE, rt.env.ORC_WORKER_FILE = nil, nil
	rt.write(root .. "/brief.md", "Implement the fixture")
	local mkdir_lock = rt.mkdir_lock
	local state = {
		clock = 0,
		calls = {},
		created = 0,
		native = "working",
		pid = 42,
		processName = "codex",
		streams = 0,
		stopped = 0,
		closed = {},
		writes = {},
	}
	local function response(value)
		return { code = 0, signal = 0, stdout = rt.encode(value), stderr = "" }
	end
	local function failure(message)
		return { code = 1, signal = 0, stdout = "", stderr = message }
	end
	function state.record()
		for _, name in ipairs(rt.list(rt.path(root, ".orc", "workers"))) do
			if name:match("%.json$") then
				local text = assert(rt.read(rt.path(root, ".orc", "workers", name)))
				return rt.decode(text)
			end
		end
	end
	function state.file()
		for _, name in ipairs(rt.list(rt.path(root, ".orc", "workers"))) do
			if name:match("%.json$") then
				return rt.path(root, ".orc", "workers", name)
			end
		end
	end
	function state.store(record)
		rt.write(assert(state.file()), rt.encode(record))
	end
	function state.hook(event, extra)
		local record = assert(state.record())
		local worker_rt = vim.tbl_extend("force", {}, rt, {
			env = vim.tbl_extend("force", {}, rt.env, {
				ORC_ROLE = record.role or "implementer",
				ORC_WORKER_FILE = rt.path(
					root,
					".orc",
					"workers",
					vim.fn.sha256(record.path .. "\0" .. record.task) .. ".json"
				),
				REX_BLOCK = record.blockId,
			}),
		})
		return workers.event(
			worker_rt,
			vim.tbl_extend(
				"force",
				{ hook_event_name = event, prompt = "[orc-run:" .. record.runId .. "] work" },
				extra or {}
			)
		)
	end
	rt.clock = function()
		return state.clock
	end
	rt.sleep = function(ms)
		state.clock = state.clock + ms
		if state.onSleep then
			state.onSleep(ms)
		end
	end
	rt.mkdir_lock = function(path)
		if state.onLock and path:match("%.state%.lock$") then
			local callback = state.onLock
			state.onLock = nil
			callback()
		end
		if state.locked then
			return false
		end
		return mkdir_lock(path)
	end
	rt.exec = function(argv, opts)
		opts = opts or {}
		state.calls[#state.calls + 1] = { argv = argv, opts = opts }
		if argv[1] == "git" then
			if argv[2] == "check-ignore" then
				return { code = state.ignored == false and 1 or 0, stdout = "", stderr = "" }
			end
			if state.gitFail then
				return failure("not a git repo")
			end
			return { code = 0, stdout = state.emptyGit and "" or root .. "/.git\n", stderr = "" }
		elseif argv[2] == "whoami" then
			if state.identityFail then
				return failure("offline")
			end
			return response({
				endpoint = state.endpoint or "unix:///fixture",
				host_id = state.host or "host",
				instance_id = state.instance or "instance",
			})
		elseif argv[2] == "api" then
			local method = argv[4] == "-s" and argv[6] or argv[4]
			local input = rt.decode(opts.stdin)
			if method == "block_creator.list" then
				if state.creatorsNil then
					return response({})
				end
				return response({
					creators = state.creatorMissing and {} or {
						{ name = "com.superlogical.onboarding", host_id = "host" },
						{ name = "com.superlogical.terminal", host_id = state.creatorHost or "host" },
					},
				})
			elseif method == "session.list_blocks" then
				if state.blocksNil then
					return response({})
				end
				return response({
					blocks = state.blocksMissing and {} or {
						{ block_id = "block:main", host_id = state.anchorHost or "host" },
						{ block_id = "block:worker", host_id = state.blockHost or "host" },
					},
				})
			elseif method == "session.new_split" or method == "session.new_window" then
				if state.createFail then
					return failure("could not create")
				end
				state.created = state.created + 1
				state.layout, state.method, state.creation = input.layout, method, input
				return response(
					state.noBlock and {} or { block_ids = { "block:worker" }, window_id = "window:worker" }
				)
			elseif method == "block.close" then
				if state.closeFail then
					return failure("cannot close")
				end
				state.closed[#state.closed + 1] = input.block_id
				return response({})
			elseif method == "block.event" then
				state.writes[#state.writes + 1] = input.event.payload.text
				if state.onPaste then
					state.onPaste()
				end
				if state.writeFail then
					return failure("paste timeout")
				end
				return response({})
			end
			error("unexpected api method " .. tostring(method))
		elseif argv[2] == "block" then
			local method = argv[8]
			if method == "process" then
				if state.processFail then
					return failure("block not found")
				end
				if state.ack then
					state.ack = false
					state.hook("UserPromptSubmit")
				end
				return response({
					child = state.childOverride
						or state.noChild and rt.null
						or { pid = state.pid, name = state.processName, path = "/bin/" .. state.processName },
					last_exit = state.exitCode ~= nil and { exit_code = state.exitCode } or rt.null,
					foreground = state.foreground
						or state.childOverride
						or { pid = state.pid, name = state.processName, path = "/bin/" .. state.processName },
				})
			elseif method == "program_status" then
				if state.noRecords then
					return response({})
				end
				if state.statusFail then
					return failure("status missing")
				end
				return response({
					records = state.native and (state.entries or {
						{
							app = state.app or state.processName,
							state = state.native,
							kind = "permission",
							owner = state.owner or { pid = state.pid, name = state.processName },
						},
					}) or {},
				})
			elseif method == "write" then
				local input = rt.decode(opts.stdin)
				state.enter = input.data
				if state.writeFail then
					return failure("write timeout")
				end
				return response({ bytes_written = #input.data })
			end
			error("unexpected block method " .. tostring(method))
		end
		error("unexpected command " .. table.concat(argv, " "))
	end
	rt.stream = function(argv, opts, on_data)
		state.streams = state.streams + 1
		state.onEvent, state.onExit = on_data, opts.on_exit
		return {
			stop = function()
				state.stopped = state.stopped + 1
			end,
		}
	end
	function state.start(extra)
		local args = {
			"start",
			"feature",
			"task",
			"--path",
			root,
			"--brief",
			root .. "/brief.md",
			"--kind",
			"codex",
		}
		vim.list_extend(args, extra or {})
		return workers.run(rt, args)
	end
	function state.run(command, extra)
		local args = { command, "task", "--path", root }
		vim.list_extend(args, extra or {})
		return workers.run(rt, args)
	end
	function state.report(status, runId, validation)
		local record = state.record()
		rt.write(
			record.report,
			"Run: "
				.. (runId or record.runId)
				.. "\nStatus: "
				.. (status or "done")
				.. "\nValidation:\n"
				.. (validation or "- nvim test: pass")
				.. "\n"
		)
	end
	return rt, state
end

Test.test("workers launch persists exact ownership and native codex sandbox", function()
	local rt, state = fake()
	local result = state.start()
	Test.eq(result.code, 0)
	Test.eq(result.result.status, "unconfirmed")
	Test.eq(state.created, 1)
	Test.eq(state.method, "session.new_window")
	Test.eq(state.creation.focus, false)
	local record = state.record()
	Test.eq(record.blockId, "block:worker")
	Test.eq(record.hostId, "host")
	Test.eq(record.instanceId, "instance")
	Test.eq(record.level, "default")
	local command = table.concat(state.layout.block.options.command, " ")
	assert(command:find("--sandbox workspace-write", 1, true))
	assert(not command:find("--add-dir", 1, true))
	assert(command:find("[orc-run:" .. record.runId .. "]", 1, true))
	Test.eq(state.layout.block.options.shell, "none")
	Test.eq(state.layout.block.options.login, false)
	Test.eq(state.start().result.runId, record.runId)
	Test.eq(state.created, 1)
	assert(not rt.exists(rt.path(rt.cwd, ".orc", "report.md")))
end)

Test.test("workers default to Codex implementers and normalize legacy roles and levels", function()
	local rt, state = fake()
	Test.eq(
		workers.run(rt, { "start", "feature", "task", "--path", rt.cwd, "--brief", "brief.md" }).code,
		0
	)
	local record = state.record()
	Test.eq(record.kind, "codex")
	Test.eq(record.role, "implementer")
	record.role, record.level = nil, nil
	state.store(record)
	Test.eq(workers.collect(rt)[1].role, "implementer")
	Test.eq(workers.collect(rt)[1].level, "default")
	state.hook("UserPromptSubmit")
	state.hook("Stop")
	state.native = "idle"
	Test.eq(state.run("prompt", { "--text", "continue" }).result.queued, true)
	assert(state.writes[1]:find("agents/implementer.md", 1, true))
	assert(state.writes[1]:find("Write the final report atomically", 1, true))
	record = state.record()
	record.role = "reviewer"
	state.store(record)
	Test.raises("invalid worker role", function()
		workers.collect(rt)
	end)
	local _, invalid = fake()
	Test.eq(invalid.start({ "--role", "reviewer" }).code, 1)
	Test.eq(invalid.created, 0)
end)

Test.test("workers persist the start level independently of later caller environments", function()
	for _, level in ipairs({ "default", "high", "max" }) do
		local rt, state = fake()
		rt.env.ORC_LEVEL = level
		Test.eq(state.start().code, 0)
		Test.eq(state.record().level, level)
		rt.env.ORC_LEVEL = "default"
		Test.eq(workers.collect(rt)[1].level, level)
		Test.eq(state.record().level, level)
	end
end)

Test.test(
	"workers scoper prompts and followups request final-message reports without writes",
	function()
		local _, state = fake()
		Test.eq(state.start({ "--role", "scoper", "--here" }).code, 0)
		Test.eq(state.record().role, "scoper")
		local command = table.concat(state.layout.block.options.command, " ")
		for _, part in ipairs({
			"ORC_ROLE=scoper",
			"--sandbox read-only",
			"agents/scoper.md",
			"Do not modify files",
			"End your final message with the report",
			"Scope with file citations",
			"Decisions",
		}) do
			assert(command:find(part, 1, true), part)
		end
		assert(not command:find("Write the final report", 1, true))
		state.hook("UserPromptSubmit")
		state.hook("Stop")
		state.native = "idle"
		Test.eq(state.run("prompt", { "--text", "scope callers too" }).result.queued, true)
		assert(state.writes[1]:find("You are the orc scoper", 1, true))
	end
)

Test.test("workers Stop saves only matching missing reports for either worker role", function()
	for _, role in ipairs({ "implementer", "scoper" }) do
		local rt, state = fake()
		state.start({ "--role", role })
		local record = state.record()
		local message = "Run: "
			.. record.runId
			.. "\nStatus: done\nScope: callers\nValidation: checks passed\nDecisions: none\n"
		state.hook("Stop", { last_assistant_message = message })
		Test.eq(rt.exists(record.report), false)
		state.hook("UserPromptSubmit")
		for _, invalid in ipairs({
			false,
			rt.null,
			"Run: stale\nStatus: done\nValidation: pass",
			"no report",
		}) do
			state.hook("Stop", { last_assistant_message = invalid })
			Test.eq(rt.exists(record.report), false)
		end
		state.hook("Stop", { last_assistant_message = message })
		Test.eq(rt.read(record.report), message)
		Test.eq(state.record().reportStatus, "done")
		Test.eq(rt.read(rt.path(rt.cwd, ".orc", "report.md")), message)
		state.native = "idle"
		Test.eq(state.run("wait", { "--timeout", "0" }).result.evidence, true)
		state.hook("Stop", {
			last_assistant_message = "Run: " .. record.runId .. "\nStatus: blocked\nValidation: failed",
		})
		Test.eq(rt.read(record.report), message)
		Test.eq(state.record().reportStatus, "done")
	end
end)

Test.test("workers here ownership counts only active implementers", function()
	for _, case in ipairs({
		{ role = "scoper", native = "working", allowed = true },
		{ role = "implementer", native = "working", allowed = false },
		{ native = "working", allowed = false },
		{ role = "implementer", native = "idle", allowed = false },
		{ role = "implementer", exit = 0, allowed = true },
		{ role = "implementer", exit = 1, allowed = true },
	}) do
		local rt, state = fake()
		state.start()
		local record = state.record()
		record.role = case.role
		state.store(record)
		state.native, state.exitCode = case.native, case.exit
		local launched = workers.run(
			rt,
			{ "start", "feature", "other", "--path", rt.cwd, "--brief", "brief.md", "--here" }
		)
		Test.eq(launched.code == 0, case.allowed)
	end
	local rt, state = fake()
	state.start()
	Test.eq(
		workers.run(rt, {
			"start",
			"feature",
			"scope",
			"--path",
			rt.cwd,
			"--brief",
			"brief.md",
			"--here",
			"--role",
			"scoper",
		}).code,
		0
	)
end)

Test.test("workers prune closes only successful exits or evidenced done workers", function()
	for _, case in ipairs({
		{ native = "working", exit = 0, close = true },
		{ native = "idle", report = "done", ack = true, close = true },
		{ native = "done", report = "done", ack = true, close = true },
		{ native = "done", report = "partial", ack = true },
		{ native = "idle", report = "blocked", ack = true },
		{ native = "idle", report = "done" },
		{ native = "done", ack = true },
		{ native = "working", report = "done", ack = true },
		{ native = "blocked", report = "done", ack = true },
		{ native = "working", exit = 1 },
		{ native = "idle", report = "done", ack = true, stale = true },
		{ native = "idle", report = "done", ack = true, validation = "" },
	}) do
		local rt, state = fake()
		state.start()
		if case.ack then
			state.hook("UserPromptSubmit")
			state.hook("Stop")
		end
		if case.report then
			state.report(case.report, case.stale and "old-run" or nil, case.validation)
		end
		state.native, state.exitCode = case.native, case.exit
		local response = workers.run(rt, { "prune", "--path", rt.cwd })
		Test.eq(response.code, 0)
		Test.eq(response.result.status, "pruned")
		if case.close then
			Test.eq(response.result.closed, { { task = "task", pane = "block:worker" } })
			Test.eq(response.result.skipped, {})
			Test.eq(state.record().state, "closed")
			Test.eq(workers.run(rt, { "prune", "--path", rt.cwd }).result.closed, {})
		else
			Test.eq(response.result.closed, {})
			Test.eq(response.result.skipped[1].task, "task")
			assert(response.result.skipped[1].reason:find("no completed report", 1, true))
			Test.eq(#state.closed, 0)
		end
		assert(not rt.exists(state.file() .. ".lock"))
	end
end)

Test.test(
	"workers prune preserves locks and refuses stale servers changed processes and close failures",
	function()
		for _, failure in ipairs({ "lock", "identity", "process", "close" }) do
			local rt, state = fake()
			state.start()
			state.hook("UserPromptSubmit")
			state.hook("Stop")
			state.report()
			state.native = "idle"
			if failure == "lock" then
				rt.mkdir(state.file() .. ".lock")
			elseif failure == "identity" then
				state.instance = "replacement"
			elseif failure == "process" then
				local exec = rt.exec
				local observations = 0
				rt.exec = function(argv, opts)
					if argv[2] == "block" and argv[8] == "process" then
						observations = observations + 1
						if observations == 3 then
							state.pid = 99
						end
					end
					return exec(argv, opts)
				end
			else
				state.closeFail = true
			end
			local response = workers.run(rt, { "prune", "--path", rt.cwd }).result
			Test.eq(response.closed, {})
			Test.eq(#response.skipped, 1)
			Test.eq(#state.closed, 0)
			assert(response.skipped[1].reason:find("orc pane", 1, true))
			Test.eq(rt.exists(state.file() .. ".lock"), failure == "lock")
		end
		local rt = fake()
		for _, args in ipairs({
			{ "prune" },
			{ "prune", "task", "--path", rt.cwd },
			{ "prune", "--path", rt.cwd, "--force" },
			{ "prune", "--path", rt.cwd, "--role", "scoper" },
		}) do
			Test.eq(workers.run(rt, args).code, 1)
		end
		local response = workers.run(rt, { "prune", "--path", rt.cwd })
		Test.eq(response.code, 0)
		Test.eq(rt.decode(response.out), { status = "pruned", closed = {}, skipped = {} })
	end
)

Test.test(
	"workers shared plan removes Rex credentials and propagates opt-in without owning the service",
	function()
		local rt, state = fake()
		local old, exec = package.loaded["orc.inkdrop_mcp"], rt.exec
		local url = "http://127.0.0.1:19841/servers/inkdrop/mcp"
		rt.env.INKDROP_LOCAL_USERNAME, rt.env.INKDROP_LOCAL_PASSWORD =
			"synthetic-user", "synthetic-secret"
		rt.env.CODEX_HOME = "/private/codex-profile"
		rt.exec = function(argv, opts)
			if argv[1] == "codex" then
				return {
					code = 0,
					stdout = rt.encode({
						enabled = true,
						transport = { type = "streamable_http", url = url },
					}),
					stderr = "",
				}
			end
			return exec(argv, opts)
		end
		local checks = 0
		package.loaded["orc.inkdrop_mcp"] = {
			resolve = function()
				return { mode = "shared", url = url, paths = { config = "/private/user-config.json" } }
			end,
			check = function()
				checks = checks + 1
				return { ok = true }
			end,
		}
		local ok, err = xpcall(function()
			Test.eq(state.start().code, 0)
			local argv = state.layout.block.options.command
			local command = table.concat(argv, " ")
			Test.eq(argv[1], "env")
			assert(command:find("-u INKDROP_LOCAL_PASSWORD", 1, true))
			assert(command:find("-u INKDROP_LOCAL_USERNAME", 1, true))
			assert(command:find("-u INKDROP_LOCAL_SERVER_URL", 1, true))
			assert(command:find("ORC_INKDROP_MCP_MODE=shared", 1, true))
			assert(command:find("ORC_INKDROP_MCP_CONFIG=/private/user-config.json", 1, true))
			assert(command:find("CODEX_HOME=/private/codex-profile", 1, true))
			assert(command:find("HOME=" .. rt.env.HOME, 1, true))
			assert(command:find("-u CLAUDE_CONFIG_DIR", 1, true))
			assert(not command:find("synthetic-secret", 1, true))
			assert(command:find("--sandbox workspace-write", 1, true))
			Test.eq(checks, 1)
			Test.eq(state.run("close").code, 0)
			Test.eq(checks, 1)
			for _, call in ipairs(state.calls) do
				assert(call.argv[1] ~= "launchctl")
			end
		end, debug.traceback)
		package.loaded["orc.inkdrop_mcp"] = old
		assert(ok, err)
	end
)

Test.test("workers shared preflight failure leaves no durable run and can be retried", function()
	local rt, state = fake()
	local old, healthy = package.loaded["orc.inkdrop_mcp"], false
	package.loaded["orc.inkdrop_mcp"] = {
		resolve = function()
			return { mode = "shared", url = "http://127.0.0.1:19841/mcp" }
		end,
		check = function()
			return { ok = healthy }
		end,
	}
	local ok, err = xpcall(function()
		state.processName = "claude"
		local args = {
			"start",
			"feature",
			"task",
			"--path",
			rt.cwd,
			"--brief",
			rt.path(rt.cwd, "brief.md"),
			"--kind",
			"claude",
		}
		Test.eq(workers.run(rt, args).code, 1)
		Test.eq(state.created, 0)
		Test.eq(state.record(), nil)
		healthy = true
		Test.eq(workers.run(rt, args).code, 0)
		Test.eq(state.created, 1)
	end, debug.traceback)
	package.loaded["orc.inkdrop_mcp"] = old
	assert(ok, err)
end)

Test.test("workers prune spans repository worktrees and continues after a failed close", function()
	local rt, state = fake()
	state.start()
	state.hook("UserPromptSubmit")
	state.report()
	state.hook("Stop")
	state.native = "done"
	local template = state.record()
	for _, task in ipairs({ "other", "working", "closed" }) do
		local record = vim.deepcopy(template)
		record.task, record.path = task, rt.path(rt.cwd, task)
		record.report = rt.path(record.path, ".orc", "reports", record.runId .. ".md")
		rt.mkdir(record.path)
		rt.write(record.report, "Run: " .. record.runId .. "\nStatus: done\nValidation: pass")
		if task == "working" then
			record.hookState = "working"
		elseif task == "closed" then
			record.state = "closed"
		end
		local name = vim.fn.sha256(record.path .. "\0" .. task) .. ".json"
		rt.write(rt.path(rt.cwd, ".orc", "workers", name), rt.encode(record))
	end
	local exec, attempts = rt.exec, 0
	rt.exec = function(argv, opts)
		if argv[2] == "api" and vim.tbl_contains(argv, "block.close") then
			attempts = attempts + 1
			if attempts == 1 then
				return { code = 1, stdout = "", stderr = "close unavailable" }
			end
		end
		return exec(argv, opts)
	end
	local response = workers.run(rt, { "prune", "--path", rt.path(rt.cwd, "other") }).result
	Test.eq(#response.closed, 1)
	Test.eq(#response.skipped, 2)
	Test.eq(attempts, 2)
	Test.eq(#state.closed, 1)
	for _, worker in ipairs(workers.collect(rt)) do
		Test.eq(
			rt.exists(
				rt.path(
					worker.root,
					".orc",
					"workers",
					vim.fn.sha256(worker.path .. "\0" .. worker.task) .. ".json.lock"
				)
			),
			false
		)
	end
end)

Test.test("workers prune rechecks eligibility after acquiring the task lock", function()
	local rt, state = fake()
	state.start()
	state.hook("UserPromptSubmit")
	state.report()
	state.hook("Stop")
	state.native = "idle"
	local mkdir_lock = rt.mkdir_lock
	rt.mkdir_lock = function(path)
		if path == state.file() .. ".lock" then
			state.hook("UserPromptSubmit")
		end
		return mkdir_lock(path)
	end
	local response = workers.run(rt, { "prune", "--path", rt.cwd }).result
	Test.eq(response.closed, {})
	Test.eq(response.skipped[1].state, "working")
	Test.eq(#state.closed, 0)
end)

Test.test(
	"workers acknowledge only their current run hook and keep approval dialogs manual",
	function()
		local rt, state = fake()
		state.native = "blocked"
		state.start()
		Test.eq(state.run("prompt", { "--text", "continue" }).result.status, "not-sent")
		Test.eq(#state.writes, 0)
		state.hook("UserPromptSubmit", { prompt = "[orc-run:stale] ignore" })
		Test.eq(state.record().acknowledged, false)
		state.hook("UserPromptSubmit")
		Test.eq(state.record().acknowledged, true)
		state.hook("PermissionRequest")
		Test.eq(state.record().state, "blocked")
		local result = state.run("wait", { "--timeout", "0" })
		Test.eq(result.result.state, "blocked")
		Test.eq(result.result.evidence, false)
		Test.eq(state.stopped, 1)
		Test.eq(workers.event(rt, {}), { code = 0, out = "", err = "" })
	end
)

Test.test(
	"workers matched reports require acceptance run status and substantive validation",
	function()
		local rt, state = fake()
		state.ack = true
		Test.eq(state.start().result.status, "started")
		state.native = "idle"
		state.report("done", "stale")
		state.hook("Stop")
		Test.eq(state.run("wait", { "--timeout", "0" }).result.evidence, false)
		state.report("invalid")
		Test.eq(state.run("wait", { "--timeout", "0" }).result.evidence, false)
		state.report("done", nil, "")
		Test.eq(state.run("wait", { "--timeout", "0" }).result.evidence, false)
		state.report("partial")
		state.hook("Stop")
		local result = state.run("wait", { "--timeout", "0" })
		Test.eq(result.result.evidence, true)
		Test.eq(result.result.status, "partial")
		Test.eq(rt.read(rt.path(rt.cwd, ".orc", "report.md")), rt.read(state.record().report))
	end
)

Test.test("workers followup is a new unconfirmed run and retains the previous report", function()
	local rt, state = fake()
	state.ack = true
	state.start()
	state.report()
	state.hook("Stop")
	state.native = "idle"
	local old = state.record()
	local result = state.run("prompt", { "--text", "fix the bug" })
	Test.eq(result.result.status, "unconfirmed")
	Test.eq(result.result.queued, true)
	assert(result.result.runId ~= old.runId)
	Test.eq(state.record().previousReport, old.report)
	assert(rt.read(rt.path(rt.cwd, ".orc", "report.md")))
	assert(state.writes[1]:find("[orc-run:" .. result.result.runId .. "]", 1, true))
	Test.eq(state.enter, "\r")
	Test.eq(state.run("prompt", { "--text", "retry" }).result.status, "not-sent")
	Test.eq(#state.writes, 1)
end)

Test.test(
	"workers failed terminal write remains unknown and is never automatically resent",
	function()
		local rt, state = fake()
		state.ack = true
		state.start()
		state.native = "idle"
		state.writeFail = true
		state.hook("Stop")
		local result = state.run("prompt", { "--file", rt.cwd .. "/brief.md" })
		Test.eq(result.result.queued, false)
		Test.eq(result.result.status, "unconfirmed")
		Test.eq(state.start().result.runId, result.result.runId)
		Test.eq(#state.writes, 1)
		assert(state.record().deliveryError)
	end
)

Test.test("workers wait reconnects resnapshots and cleans streams", function()
	local _, state = fake()
	state.ack = true
	state.start()
	local ticks = 0
	state.onSleep = function()
		ticks = ticks + 1
		if ticks == 1 then
			state.onExit({ code = 1 })
		elseif ticks == 2 then
			state.native = "idle"
			state.report()
			state.hook("Stop")
			state.onEvent('{"type":"block_event"}\n')
		end
	end
	local result = state.run("wait", { "--timeout", "2000" })
	Test.eq(result.result.evidence, true)
	assert(state.streams >= 2)
	Test.eq(state.stopped, state.streams)
end)

Test.test(
	"workers wait snapshots only on events or five seconds since the last snapshot",
	function()
		for _, event_at in ipairs({ false, 750 }) do
			local rt, state = fake()
			state.ack = true
			state.start()
			local exec, snapshots = rt.exec, {}
			rt.exec = function(argv, opts)
				if argv[2] == "block" and argv[8] == "process" then
					snapshots[#snapshots + 1] = state.clock
				end
				return exec(argv, opts)
			end
			state.onSleep = function(ms)
				assert(ms <= 250)
				if state.clock == event_at then
					state.onEvent('{"type":"block_event"}\n')
				end
			end
			Test.eq(state.run("wait", { "--timeout", "11000" }).result.state, "timeout")
			if event_at then
				Test.eq(snapshots, { 0, 750, 5750, 10750 })
			else
				Test.eq(snapshots, { 0, 5000, 10000 })
			end
			Test.eq(state.stopped, 1)
		end
	end
)

Test.test("workers wait returns immediately on a Rex event before the heartbeat", function()
	local _, state = fake()
	state.ack = true
	state.start()
	state.onSleep = function()
		state.native = "blocked"
		state.onEvent('{"type":"block_event"}\n')
	end
	Test.eq(state.run("wait", { "--timeout", "1000" }).result.state, "blocked")
	Test.eq(state.clock, 250)
	Test.eq(state.stopped, 1)
end)

Test.test("workers wait stops early when the prompt is never acknowledged", function()
	local _, state = fake()
	state.start()
	local result = state.run("wait", { "--timeout", "120000" }).result
	Test.eq(result.state, "unacknowledged")
	Test.eq(result.evidence, false)
	assert(result.hint:find("trust orc hooks", 1, true))
	assert(state.clock > 60000 and state.clock < 70000)
end)

Test.test("workers wait ignores the unacknowledged limit for acknowledged workers", function()
	local _, state = fake()
	state.ack = true
	state.start()
	Test.eq(state.run("wait", { "--timeout", "120000" }).result.state, "timeout")
end)

Test.test("workers wait timeout below the unacknowledged limit stays a timeout", function()
	local _, state = fake()
	state.start()
	Test.eq(state.run("wait", { "--timeout", "1000" }).result.state, "timeout")
end)

Test.test(
	"workers wait reports timeout exit errors disconnected and changed runs honestly",
	function()
		local rt, state = fake()
		state.start()
		Test.eq(state.run("wait", { "--timeout", "20" }).result.state, "timeout")
		state.exitCode = 7
		Test.eq(state.run("wait", { "--timeout", "0" }).result.state, "error")
		state.exitCode = 0
		Test.eq(state.run("wait", { "--timeout", "0" }).result.state, "exited")
		state.exitCode, state.processFail = nil, true
		Test.eq(state.run("wait", { "--timeout", "0" }).result.state, "timeout")
		Test.eq(state.record().state, "disconnected")
		state.processFail = false
		state.onSleep = function()
			local record = state.record()
			record.runId = "changed"
			local file = rt.path(
				rt.cwd,
				".orc",
				"workers",
				vim.fn.sha256(record.path .. "\0" .. record.task) .. ".json"
			)
			rt.write(file, rt.encode(record))
		end
		assert(state.run("wait", { "--timeout", "500" }).result.stderr:find("run changed", 1, true))
	end
)

Test.test("workers close verifies process server and recorded block rather than labels", function()
	local _, state = fake()
	state.start()
	state.instance = "restarted"
	Test.eq(state.run("close").code, 1)
	Test.eq(#state.closed, 0)
	state.instance, state.pid = "instance", 99
	Test.eq(state.run("close").code, 1)
	state.pid = 42
	Test.eq(state.run("close").result.status, "closed")
	Test.eq(state.closed, { "block:worker" })
	Test.eq(state.run("close").result.status, "closed")
	Test.eq(#state.closed, 1)
	Test.eq(state.run("wait", { "--timeout", "0" }).result.state, "closed")
	state.start()
	Test.eq(state.created, 2)
end)

Test.test(
	"workers short state lock merges concurrent acknowledgments and closed state wins",
	function()
		local rt, state = fake()
		state.start()
		state.onLock = function()
			state.hook("UserPromptSubmit")
		end
		local observed = workers.collect(rt)[1]
		Test.eq(observed.acknowledged, true)
		Test.eq(state.record().acknowledged, true)
		state.onLock = function()
			Test.eq(state.run("close").code, 0)
		end
		state.hook("UserPromptSubmit")
		Test.eq(state.record().state, "closed")
		Test.eq(#state.closed, 1)
	end
)

Test.test(
	"workers snapshot cannot overwrite a newer run and collect reconstructs native state",
	function()
		local rt, state = fake()
		state.start()
		state.exitCode = 0
		Test.eq(workers.collect(rt)[1].state, "exited")
		state.exitCode = nil
		state.onLock = function()
			local record = state.record()
			record.runId, record.acknowledged, record.state = "replacement", false, "unconfirmed"
			rt.write(
				rt.path(
					rt.cwd,
					".orc",
					"workers",
					vim.fn.sha256(record.path .. "\0" .. record.task) .. ".json"
				),
				rt.encode(record)
			)
		end
		Test.eq(workers.collect(rt)[1].state, "disconnected")
		Test.eq(state.record().runId, "replacement")
		Test.eq(state.record().acknowledged, false)
		state.instance = "other-instance"
		local observed = workers.collect(rt)[1]
		Test.eq(observed.state, "disconnected")
		assert(observed.observationError:find("identity changed", 1, true))
	end
)

Test.test(
	"workers refuse remote anchors creators blocks missing ownership and dots-only names",
	function()
		for _, setting in ipairs({ "anchorHost", "creatorHost" }) do
			local _, state = fake()
			state[setting] = "remote"
			Test.eq(state.start().code, 1)
			Test.eq(state.created, 0)
		end
		local rt, state = fake()
		state.creatorMissing = true
		Test.eq(state.start().code, 1)
		state.creatorMissing, state.blockHost = false, "remote"
		Test.eq(state.start().code, 1)
		Test.eq(state.closed, { "block:worker" })
		Test.eq(state.record().state, "closed")
		state.blockHost = nil
		Test.eq(state.start().code, 0)
		state.blockHost = "remote"
		Test.eq(state.run("prompt", { "--text", "do not send" }).code, 1)
		Test.eq(state.run("close").code, 1)
		Test.eq(#state.writes, 0)
		state.blocksMissing = true
		Test.eq(state.run("close").code, 1)
		for _, name in ipairs({ ".", "..", "..." }) do
			Test.eq(
				workers.run(rt, { "start", "f", name, "--path", rt.cwd, "--brief", rt.cwd .. "/brief.md" }).code,
				1
			)
			Test.eq(
				workers.run(
					rt,
					{ "start", name, "new", "--path", rt.cwd, "--brief", rt.cwd .. "/brief.md" }
				).code,
				1
			)
		end
	end
)

Test.test(
	"workers state lock contention creation errors and failed persistence leave safe ownership",
	function()
		local rt, state = fake()
		state.createFail = true
		Test.eq(state.start().code, 1)
		Test.eq(state.created, 0)
		Test.eq(state.start().result.status, "unconfirmed")
		Test.eq(state.created, 0)
		local other_rt, other = fake()
		other.ack = true
		other.start()
		other.locked = true
		Test.raises("state lock is busy", function()
			other.hook("Stop")
		end)
		other.locked = false
		other.processName = "shell"
		Test.eq(other.run("prompt", { "--text", "must not type" }).result.status, "not-sent")
		Test.eq(#other.writes, 0)
		local failed_rt, failed = fake()
		local write = failed_rt.write
		failed_rt.write = function(path, text)
			if path:match("%.json$") and failed_rt.decode(text).blockId then
				error("disk full")
			end
			write(path, text)
		end
		Test.eq(failed.start().code, 1)
		Test.eq(failed.closed, { "block:worker" })
		assert(not other_rt.exists(other_rt.cwd .. "/.orc/unrelated"))
		assert(rt.exists(rt.cwd))
	end
)

Test.test("workers pair creates one split and Claude loads only the new Lua plugin", function()
	local rt, state = fake()
	state.processName = "claude"
	rt.env.ORC_LEVEL = "high"
	local result = workers.run(rt, {
		"start",
		"feature",
		"pair",
		"--path",
		rt.cwd,
		"--brief",
		rt.cwd .. "/brief.md",
		"--here",
		"--kind",
		"claude",
	})
	Test.eq(result.code, 0)
	Test.eq(state.method, "session.new_split")
	Test.eq(state.creation.anchor_id, "block:main")
	local command = table.concat(state.layout.block.options.command, " ")
	assert(command:find("--plugin-dir " .. rt.root, 1, true))
	assert(command:find("--model opus", 1, true))
	local second = workers.run(
		rt,
		{ "start", "feature", "other", "--path", rt.cwd, "--brief", rt.cwd .. "/brief.md", "--here" }
	)
	Test.eq(second.code, 1)
	Test.eq(state.created, 1)
end)

Test.test(
	"workers strict arguments lock errors and local server requirements fail safely",
	function()
		local rt, state = fake()
		for _, args in ipairs({
			{},
			{ "start", "f", "t" },
			{ "start", "f", "../bad", "--path", rt.cwd, "--brief", "brief.md" },
			{ "wait", "t", "--path", rt.cwd },
			{ "bad", "t", "--path", rt.cwd },
			{ "start", "f", "t", "--path", rt.cwd, "--brief", "absent" },
		}) do
			Test.eq(workers.run(rt, args).code, 1)
		end
		state.locked = true
		Test.eq(state.start().code, 1)
		state.locked, state.endpoint = false, "tcp://remote:99"
		Test.eq(state.start().code, 1)
		state.endpoint, state.identityFail = nil, true
		Test.eq(state.start().code, 1)
		state.identityFail = false
		rt.env.REX_SESSION = nil
		Test.eq(state.start().code, 1)
		rt.env.REX_SESSION = "session:fixture"
		state.ignored = false
		Test.eq(state.start().code, 0)
		assert(rt.read(rt.cwd .. "/.git/info/exclude"):find(".orc/", 1, true))
		Test.eq(state.run("wait", { "--timeout", "bad" }).code, 1)
		Test.eq(state.run("prompt", {}).code, 1)
	end
)

Test.test(
	"workers Rex adapter decodes stream fragments ignores malformed events and refuses invalid responses",
	function()
		local rt, state = fake()
		local client = require("orc.rex").new(rt)
		local events, ended = {}, false
		local stream = client.watch("session:fixture", function(event)
			events[#events + 1] = event
		end, function()
			ended = true
		end)
		state.onEvent('{"type":')
		state.onEvent('"one"}\nnot JSON\n\n{"type":"two"}\n')
		Test.eq(events, { { type = "one" }, { type = "two" } })
		state.onExit()
		Test.eq(ended, true)
		stream.stop()
		rt.exec = function()
			return { code = 0, stdout = "bad", stderr = "" }
		end
		Test.raises("invalid JSON", client.identity)
		rt.exec = function()
			return { code = 0, stdout = "{}", stderr = "" }
		end
		Test.raises("remote server", client.identity)
	end
)

Test.test("workers Rex API and block calls send empty JSON objects on the wire", function()
	local rt = fake()
	local calls = {}
	rt.exec = function(argv, opts)
		calls[#calls + 1] = { argv = argv, stdin = opts.stdin }
		return { code = 0, stdout = "{}", stderr = "" }
	end
	local client = require("orc.rex").new(rt)
	client.call("session.list_blocks", nil, "s")
	client.call("session.list_blocks", {}, "s")
	client.block("s", "b", "process")
	client.block("s", "b", "process", {})
	for _, call in ipairs(calls) do
		Test.eq(call.stdin, "{}")
	end
	Test.eq(
		vim.list_slice(calls[1].argv, 2),
		{ "api", "call", "-s", "s", "session.list_blocks", "-" }
	)
	Test.eq(
		vim.list_slice(calls[3].argv, 2),
		{ "block", "call", "-s", "s", "-b", "b", "process", "-" }
	)
	local arguments = { data = "\r", nested = { "one", "two" } }
	client.call("example", arguments)
	client.block("s", "b", "write", arguments)
	Test.eq(calls[5].stdin, rt.encode(arguments))
	Test.eq(calls[6].stdin, rt.encode(arguments))
end)

Test.test("workers Rex resolution schema errors and bounded event frames", function()
	local rt, state = fake()
	local rex = require("orc.rex")
	local old_path = vim.fn.exepath
	local ok, err = xpcall(function()
		vim.fn.exepath = function()
			return "/fixture/rex"
		end
		Test.eq(rex.resolve(rt), "/fixture/rex")
		vim.fn.exepath = function()
			return ""
		end
		local old_exists = rt.exists
		rt.exists = function()
			return false
		end
		Test.eq(rex.resolve(rt), "rex")
		rt.exists = old_exists
	end, debug.traceback)
	vim.fn.exepath = old_path
	assert(ok, err)
	local client = rex.new(rt)
	local exit
	client.watch("s", function() end, function(result)
		exit = result
	end)
	state.onEvent(string.rep("x", 1048577))
	Test.eq(exit.code, 1)
	assert(state.stopped > 0)
	client.watch("s", function() end)
	state.onEvent(string.rep("x", 1048577))
	rt.stream = function(_, _, callback)
		callback(string.rep("x", 1048577))
		return { stop = function() end }
	end
	client.watch("s", function() end)
	rt.stream = nil
	Test.raises("streaming", function()
		client.watch("s", function() end)
	end)
	for _, response in ipairs({
		"null",
		'{"endpoint":"unix:///x"}',
		'{"endpoint":"unix:///x","host_id":"h"}',
	}) do
		rt.exec = function()
			return { code = 0, stdout = response, stderr = "" }
		end
		Test.raises("rex:", client.identity)
	end
	rt.exec = function()
		return { code = 127, stdout = "", stderr = "" }
	end
	Test.raises("command failed", client.identity)
	rt.exec = function()
		return { code = 0, stdout = "{}", stderr = "" }
	end
	Test.eq(client.call("example"), vim.empty_dict())
	Test.eq(client.block("s", "b", "example", {}), vim.empty_dict())
end)

Test.test("workers corrupted unreadable and malformed durable metadata fail closed", function()
	for _, malformed in ipairs({ "bad", "null", "{}", '{"runId":"r","path":"/r"}' }) do
		local rt, state = fake()
		state.start()
		rt.write(state.file(), malformed)
		Test.eq(state.run("close").code, 1)
		Test.eq(#state.closed, 0)
	end
	local rt, state = fake()
	state.start()
	local record = state.record()
	record.root = "/elsewhere"
	state.store(record)
	Test.raises("identity mismatch", function()
		workers.collect(rt)
	end)
	local read = rt.read
	rt.read = function(path)
		if path:match("%.json$") then
			return nil, "permission denied"
		end
		return read(path)
	end
	Test.eq(state.run("close").code, 1)
	Test.eq(#state.closed, 0)
	local _, no_block = fake()
	no_block.noBlock = true
	Test.eq(no_block.start().code, 1)
	Test.eq(no_block.run("wait", { "--timeout", "0" }).code, 1)
	Test.eq(no_block.run("close").code, 1)
end)

Test.test(
	"workers optional process fields and unsupported statuses never authorize terminal input",
	function()
		local rt, state = fake()
		state.childOverride =
			{ pid = 7, name = "node", path = "/bin/node", script = "/package/codex/cli.lua" }
		state.foreground = { name = "node", script = "/package/codex/cli.lua" }
		state.entries = {
			{ effective_app = "codex", state = "idle", id = rt.null },
			{ app = "other", state = "done" },
			{ state = "working" },
			{ app = "codex", state = "future" },
			{ app = "codex", state = "done", id = "child" },
		}
		state.ack = true
		Test.eq(state.start().code, 0)
		Test.eq(state.record().process.script, "/package/codex/cli.lua")
		state.childOverride.script = "/other/script.lua"
		Test.eq(state.run("prompt", { "--text", "no input" }).result.status, "not-sent")
		state.childOverride = { pid = "bad" }
		Test.eq(workers.collect(rt)[1].state, "unknown")
		state.childOverride = nil
		state.noChild = true
		Test.eq(workers.collect(rt)[1].state, "unknown")
		state.noChild = false
		state.statusFail = true
		workers.collect(rt)
		state.statusFail, state.noRecords = false, true
		workers.collect(rt)
		state.noRecords, state.native = false, false
		workers.collect(rt)
		Test.eq(#state.writes, 0)
		local _, anonymous = fake()
		anonymous.childOverride = { pid = 4 }
		Test.eq(anonymous.start().code, 0)
		Test.eq(anonymous.record().state, "unknown")
	end
)

Test.test("workers hook boot ordering validates block identity and ignores stale events", function()
	local rt, state = fake()
	state.start()
	local file, record = state.file(), state.record()
	local hook_rt = vim.tbl_extend("force", {}, rt, {
		env = vim.tbl_extend(
			"force",
			{},
			rt.env,
			{ ORC_ROLE = "implementer", ORC_WORKER_FILE = file, REX_BLOCK = record.blockId }
		),
	})
	Test.eq(workers.event(hook_rt, rt.encode({ hook_event_name = "unknown" })).code, 0)
	Test.eq(workers.event(hook_rt, { hook_event_name = "Stop" }).code, 0)
	Test.eq(workers.event(hook_rt, { hook_event_name = "UserPromptSubmit" }).code, 0)
	Test.raises("invalid hook", function()
		workers.event(hook_rt, false)
	end)
	hook_rt.env.REX_BLOCK = "other"
	Test.raises("block identity", function()
		workers.event(hook_rt, {})
	end)
	hook_rt.env.REX_BLOCK = "block:worker"
	record.blockId = nil
	state.store(record)
	state.onSleep = function()
		record.blockId = "block:worker"
		state.store(record)
		state.onSleep = nil
	end
	Test.eq(
		workers.event(
			hook_rt,
			{ hook_event_name = "UserPromptSubmit", prompt = "[orc-run:" .. record.runId .. "] accepted" }
		).code,
		0
	)
	Test.eq(state.record().acknowledged, true)
	state.report()
	state.hook("Stop")
	state.run("close")
	Test.eq(workers.event(hook_rt, {}).code, 0)
	hook_rt.env.ORC_WORKER_FILE = file .. ".missing"
	Test.raises("missing record", function()
		workers.event(hook_rt, {})
	end)
	hook_rt.env.ORC_WORKER_FILE = nil
	Test.eq(workers.event(hook_rt, {}).code, 0)
end)

Test.test(
	"workers explicit Claude startup Git failures and malformed options are explicit",
	function()
		local rt, state = fake()
		state.processName = "claude"
		Test.eq(
			workers.run(
				rt,
				{ "start", "f", "claude", "--path", rt.cwd, "--brief", "brief.md", "--kind", "claude" }
			).code,
			0
		)
		assert(table.concat(state.layout.block.options.command, " "):find("--model sonnet", 1, true))
		local other_rt, other = fake()
		for _, args in ipairs({
			{ "start", "f", "bad", "--path", other_rt.cwd, "--brief", "brief.md", "--kind", "other" },
			{ "start", "f", "bad", "--path", other_rt.cwd .. "/missing", "--brief", "brief.md" },
			{ "start", "f", "bad", "--path", "", "--brief", "brief.md" },
			{ "start", "f", "bad", "--path", other_rt.cwd, "--brief", "brief.md", "--unknown" },
		}) do
			Test.eq(workers.run(other_rt, args).code, 1)
		end
		other.gitFail = true
		Test.eq(other.start().code, 1)
		other.gitFail, other.emptyGit = false, true
		Test.eq(other.start().code, 1)
		other.emptyGit = false
		other_rt.env.REX_SESSION = ""
		Test.eq(other.start().code, 1)
		other_rt.env.REX_SESSION, other_rt.env.REX_BLOCK = "session:fixture", nil
		Test.eq(other.start().code, 1)
		other_rt.env.REX_BLOCK = "block:main"
		other.creatorsNil = true
		Test.eq(other.start().code, 1)
		other.creatorsNil = false
		other.start()
		other.ack = true
		other.native = "idle"
		other.start()
		other.hook("Stop")
		Test.eq(other.run("prompt", { "--file", "missing" }).code, 1)
		Test.eq(other.run("wait", { "--timeout", "-1" }).code, 1)
		Test.eq(other.run("nonsense").code, 1)
		other.closeFail = true
		Test.eq(other.run("close").code, 1)
		Test.eq(other.record().state, "idle")
	end
)

Test.test(
	"workers report headings inline validation and native status transitions remain distinct",
	function()
		local rt, state = fake()
		state.ack, state.native = true, false
		Test.eq(state.start().result.state, "working")
		local record = state.record()
		rt.write(
			record.report,
			"# Run: "
				.. record.runId
				.. "\n# Status: done\n# Validation: nvim test passed\n\n# Notes\nunchanged\n"
		)
		state.hook("Stop")
		state.native = "working"
		Test.eq(workers.collect(rt)[1].state, "working")
		state.native = "done"
		Test.eq(state.run("wait", { "--timeout", "0" }).result.state, "done")
		state.native = "error"
		Test.eq(state.run("wait", { "--timeout", "0" }).result.state, "error")
		state.native = "blocked"
		Test.eq(state.run("wait").result.state, "blocked")
		rt.write(
			record.report,
			"Run: " .. record.runId .. "\nStatus: done\nValidation:\n\nNotes: no validation supplied\n"
		)
		state.native = "idle"
		Test.eq(state.run("wait", { "--timeout", "0" }).result.evidence, false)
		state.statusFail = true
		workers.collect(rt)
		state.statusFail, state.noRecords = false, true
		workers.collect(rt)
		state.noRecords = false
		state.native = "idle"
		state.run("close")
		Test.eq(state.run("prompt", { "--text", "closed" }).result.status, "not-sent")
	end
)

Test.test(
	"workers no-identity processes alternate source fields and host changes are bounded",
	function()
		local rt, state = fake()
		state.childOverride = { pid = 42, name = "codex" }
		state.foreground = { name = "codex" }
		state.start()
		workers.collect(rt)
		state.entries = {
			{ effective_app = "codex", state = "future", id = rt.null },
			{ state = "idle" },
			{ app = "other", state = "done" },
			{ app = "codex", state = "done", id = "subtask" },
		}
		workers.collect(rt)
		state.childOverride = { pid = 99 }
		workers.collect(rt)
		state.host = "other-host"
		Test.eq(state.run("close").code, 1)
		local _, unknown = fake()
		unknown.childOverride = { pid = 1, name = "shell" }
		unknown.foreground = {}
		unknown.start()
		Test.eq(unknown.record().state, "unknown")
		local _, malformed = fake()
		malformed.childOverride = { pid = "not-an-integer", name = "codex" }
		malformed.start()
		Test.eq(malformed.record().state, "unknown")
	end
)

Test.test(
	"workers stale event stream callbacks and concurrently closed waits do not reconnect old streams",
	function()
		local rt, state = fake()
		state.start()
		local tick, previous_event, previous_exit = 0
		state.onSleep = function()
			tick = tick + 1
			if tick == 1 then
				previous_event, previous_exit = state.onEvent, state.onExit
				previous_exit()
			elseif tick == 2 then
				previous_event('{"type":"old"}\n')
				previous_exit()
				local record = state.record()
				record.state = "closed"
				state.store(record)
			end
		end
		Test.eq(state.run("wait", { "--timeout", "1000" }).result.state, "closed")
		Test.eq(state.streams, 2)
		Test.eq(state.stopped, 2)
		local other_rt, other = fake()
		other.start()
		other_rt.stream = nil
		Test.eq(other.run("wait", { "--timeout", "0" }).code, 1)
		local missing_rt, missing = fake()
		missing.start()
		missing.onSleep = function()
			missing_rt.remove(missing.file())
		end
		Test.eq(missing.run("wait", { "--timeout", "500" }).code, 1)
		assert(rt.exists(rt.cwd))
	end
)

Test.test(
	"workers optional excludes and malformed feature flags do not create unexpected panes",
	function()
		local rt, state = fake()
		rt.write(rt.cwd .. "/.git/info/exclude", "existing\n")
		state.ignored = false
		state.start()
		Test.eq(rt.read(rt.cwd .. "/.git/info/exclude"), "existing\n.orc/\n.worktrees/\n.scratch/\n")
		for _, args in ipairs({
			{ "start", "f", "bad", "extra", "--path", rt.cwd, "--brief", "brief.md" },
			{ "start", "f", "bad", "--path", rt.cwd },
			{ "start", "f", "--path", rt.cwd, "--brief", "brief.md" },
			{ "start", "bad/feature", "bad", "--path", rt.cwd, "--brief", "brief.md" },
		}) do
			Test.eq(workers.run(rt, args).code, 1)
		end
		local record = state.record()
		record.state, record.blockId = "closed", nil
		state.store(record)
		Test.eq(state.run("close").result.pane, rt.null)
		Test.eq(workers.collect(rt)[1].state, "closed")
		local read = rt.read
		rt.read = function(path)
			if path:match("%.json$") then
				return nil
			end
			return read(path)
		end
		Test.raises("identity mismatch", function()
			workers.collect(rt)
		end)
		local other_rt, other = fake()
		other_rt.env.PATH = nil
		other.start()
		Test.eq(other.created, 1)
	end
)

Test.test(
	"workers followup requires fresh native idle ownership rather than durable Stop",
	function()
		for _, condition in ipairs({
			"working",
			"failed",
			"empty",
			"unknown",
			"owner-missing",
			"owner-changed",
			"foreground-changed",
			"foreground-missing",
		}) do
			local rt, state = fake()
			state.ack = true
			state.start()
			state.hook("Stop")
			state.native = "idle"
			if condition == "working" then
				state.native = "working"
			elseif condition == "failed" then
				state.statusFail = true
			elseif condition == "empty" then
				state.noRecords = true
			elseif condition == "unknown" then
				state.native = "future"
			elseif condition == "owner-missing" then
				state.owner = rt.null
			elseif condition == "owner-changed" then
				state.owner = { pid = 99, name = "codex" }
			elseif condition == "foreground-changed" then
				state.foreground = { pid = 99, name = "vim", path = "/bin/vim" }
				state.owner = { pid = 99, name = "vim" }
			elseif condition == "foreground-missing" then
				state.foreground = rt.null
			end
			local result = state.run("prompt", { "--text", "must not interrupt" })
			Test.eq(result.result.status, "not-sent")
			Test.eq(#state.writes, 0)
			Test.eq(state.record().inputReady, false)
		end
	end
)

Test.test(
	"workers unmarked prompts invalidate idle without acknowledging a pending attempt",
	function()
		local _, state = fake()
		state.start()
		state.hook("UserPromptSubmit", { prompt = "human prompt without run marker" })
		Test.eq(state.record().state, "working")
		Test.eq(state.record().acknowledged, false)
		Test.eq(state.record().inputReady, false)
		state.native = "idle"
		Test.eq(state.run("prompt", { "--text", "not yet" }).result.status, "not-sent")
		Test.eq(#state.writes, 0)
		state.hook("UserPromptSubmit")
		state.hook("Stop")
		state.hook("UserPromptSubmit", { prompt = "another human prompt" })
		Test.eq(state.record().state, "working")
		Test.eq(state.record().inputReady, false)
	end
)

Test.test("workers older permission event cannot overwrite a newer Stop event", function()
	local _, state = fake()
	state.ack = true
	state.start()
	state.onLock = function()
		state.hook("Stop")
		Test.eq(state.record().state, "idle")
	end
	state.hook("PermissionRequest")
	Test.eq(state.record().state, "idle")
	Test.eq(state.record().acknowledged, true)
	state.onLock = function()
		state.hook("UserPromptSubmit", { prompt = "manual newer work" })
	end
	state.hook("Stop")
	Test.eq(state.record().state, "working")
end)

Test.test("workers changed foreground between native snapshot and paste is refused", function()
	local rt, state = fake()
	state.ack = true
	state.start()
	state.hook("Stop")
	state.native = "idle"
	local execute, reads = rt.exec, 0
	rt.exec = function(argv, opts)
		if argv[2] == "block" and argv[8] == "process" then
			reads = reads + 1
			if reads == 2 then
				state.foreground = { pid = 99, name = "vim", path = "/bin/vim" }
			end
		end
		return execute(argv, opts)
	end
	Test.eq(state.run("prompt", { "--text", "no paste" }).code, 1)
	Test.eq(#state.writes, 0)
end)

Test.test("workers incomplete owner identities never authorize input", function()
	for _, invalid in ipairs({
		{ foreground = {} },
		{ foreground = { pid = 42 } },
		{ owner = {} },
		{ owner = { pid = 42 } },
		{ owner = { pid = 42, name = "other" } },
	}) do
		local _, state = fake()
		state.ack = true
		state.start()
		state.native = "idle"
		state.foreground, state.owner = invalid.foreground, invalid.owner
		state.hook("Stop")
		Test.eq(
			state.run("prompt", { "--text", "refuse incomplete ownership" }).result.status,
			"not-sent"
		)
		Test.eq(#state.writes, 0)
	end
end)

Test.test("workers stale native idle never erases blocked or working hook lifecycle", function()
	for _, event in ipairs({ "PermissionRequest", "UserPromptSubmit" }) do
		local rt, state = fake()
		state.ack = true
		state.start()
		state.hook("Stop")
		state.native = "idle"
		state.hook(event, { prompt = "manual user work" })
		local expected = event == "PermissionRequest" and "blocked" or "working"
		Test.eq(state.record().hookState, expected)
		Test.eq(workers.collect(rt)[1].state, expected)
		Test.eq(state.record().hookState, expected)
		Test.eq(state.run("prompt", { "--text", "do not answer the dialog" }).result.status, "not-sent")
		Test.eq(#state.writes, 0)
	end
end)

Test.test(
	"workers recheck hook authorization and native ownership after paste before Enter",
	function()
		for _, change in ipairs({
			"permission",
			"human-prompt",
			"foreground",
			"owner",
			"working",
			"no-status",
			"failed-status",
			"early-ack",
		}) do
			local _, state = fake()
			state.ack = true
			state.start()
			state.hook("Stop")
			state.native = "idle"
			state.onPaste = function()
				if change == "permission" then
					state.hook("PermissionRequest")
				elseif change == "human-prompt" then
					state.hook("UserPromptSubmit", { prompt = "human prompt" })
				elseif change == "foreground" then
					state.foreground = { pid = 99, name = "vim" }
				elseif change == "owner" then
					state.owner = { pid = 99, name = "codex" }
				elseif change == "working" then
					state.native = "working"
				elseif change == "no-status" then
					state.noRecords = true
				elseif change == "failed-status" then
					state.statusFail = true
				elseif change == "early-ack" then
					state.hook("UserPromptSubmit")
				end
			end
			local result = state.run("prompt", { "--text", "payload" })
			Test.eq(result.result.status, "unconfirmed")
			Test.eq(result.result.queued, false)
			Test.eq(#state.writes, 1)
			Test.eq(state.enter, nil)
			Test.eq(state.run("prompt", { "--text", "do not retry" }).result.status, "not-sent")
			Test.eq(#state.writes, 1)
		end
	end
)

Test.test(
	"workers new run CAS refuses intervening permissions closure and missing authorization before paste",
	function()
		for _, change in ipairs({ "permission", "closed", "missing", "run", "hook", "ack" }) do
			local rt, state = fake()
			state.ack = true
			state.start()
			state.hook("Stop")
			state.native = "idle"
			state.onLock = function()
				state.onLock = function()
					if change == "permission" then
						state.hook("PermissionRequest")
					elseif change == "missing" then
						rt.remove(state.file())
					else
						local record = state.record()
						if change == "closed" then
							record.state = "closed"
						elseif change == "run" then
							record.runId = "replacement"
						elseif change == "hook" then
							record.hookState = "working"
						elseif change == "ack" then
							record.acknowledged = false
						end
						state.store(record)
					end
				end
			end
			local result = state.run("prompt", { "--text", "must fail before paste" })
			Test.eq(result.code, 1)
			assert(result.result.stderr:find("authorization changed before paste", 1, true))
			Test.eq(#state.writes, 0)
			Test.eq(state.enter, nil)
		end
	end
)

Test.test(
	"workers process observation fallback ownership recovery and cleanup failure remain bounded",
	function()
		local rt, state = fake()
		state.foreground = rt.null
		Test.eq(state.start().code, 0)
		Test.eq(state.record().process.name, "codex")
		state.exitCode = 0
		Test.eq(state.run("close").code, 0)
		state.processName, state.exitCode, state.foreground = "claude", nil, nil
		Test.eq(
			workers.run(
				rt,
				{ "start", "feature", "next", "--path", rt.cwd, "--brief", "brief.md", "--here" }
			).code,
			0
		)
		local _, missing = fake()
		missing.blocksNil = true
		Test.eq(missing.start().code, 1)
		Test.eq(missing.created, 0)
		local _, failed_cleanup = fake()
		failed_cleanup.blockHost, failed_cleanup.closeFail = "remote", true
		Test.eq(failed_cleanup.start().code, 1)
		Test.eq(#failed_cleanup.closed, 0)
		Test.eq(failed_cleanup.record().state, "unconfirmed")
		Test.eq(workers.run(rt, { "close", "--path", rt.cwd }).code, 1)
	end
)

Test.test(
	"workers post-paste accepts stable done but rejects changed roots owner and durable token",
	function()
		for _, change in ipairs({
			"stable-done",
			"records",
			"owner-pid",
			"owner-name",
			"previous-run",
			"hook-state",
			"ack-flag",
			"missing-record",
			"new-run",
		}) do
			local rt, state = fake()
			state.ack = true
			state.start()
			state.hook("Stop")
			state.native = "idle"
			if change == "owner-name" then
				state.foreground = { pid = 99, name = "node", script = "/package/codex/cli.lua" }
				state.owner = { pid = 99, name = "node" }
			end
			state.onPaste = function()
				if change == "stable-done" then
					state.native = "done"
				elseif change == "records" then
					state.entries = {
						{ app = "codex", id = "child", state = "idle" },
						{ effective_app = "other", state = "idle" },
						{ state = "idle" },
						{ app = "codex", state = "future" },
					}
				elseif change == "owner-pid" then
					state.foreground = { pid = 99, name = "codex" }
					state.owner = { pid = 99, name = "codex" }
				elseif change == "owner-name" then
					state.foreground = { pid = 99, name = "codex" }
					state.owner = { pid = 99, name = "codex" }
				elseif change == "missing-record" then
					rt.remove(state.file())
				else
					local record = state.record()
					if change == "previous-run" then
						record.previousRunId = "other"
					elseif change == "hook-state" then
						record.hookState = "blocked"
					elseif change == "ack-flag" then
						record.acknowledged = true
					elseif change == "new-run" then
						record.runId = "replacement"
					end
					state.store(record)
				end
			end
			local result = state.run("prompt", { "--text", "verify final readiness" })
			if change == "stable-done" then
				Test.eq(result.result.queued, true)
				Test.eq(state.enter, "\r")
			else
				Test.eq(state.enter, nil)
				assert(result.code ~= 0 or not result.result.queued)
			end
			Test.eq(#state.writes, 1)
		end
	end
)

local function rex_calls(state)
	local count = 0
	for _, call in ipairs(state.calls) do
		if call.argv[1] == "rex" then
			count = count + 1
		end
	end
	return count
end

Test.test(
	"workers force close releases records stranded by a Rex restart or failed creation",
	function()
		local rt, state = fake()
		state.start()
		state.instance = "restarted"
		local refused = state.run("close").result.stderr
		assert(refused:find("orc pane close task --path " .. rt.cwd .. " --force", 1, true))
		assert(
			state.start().result.stderr:find("--force to mark it closed without touching Rex", 1, true)
		)
		local before = rex_calls(state)
		local forced = state.run("close", { "--force" })
		Test.eq(forced.result.status, "closed")
		Test.eq(rex_calls(state), before)
		Test.eq(#state.closed, 0)
		Test.eq(state.record().state, "closed")
		state.instance = "instance"
		Test.eq(state.start().result.status, "unconfirmed")
		Test.eq(state.created, 2)

		local _, failed = fake()
		failed.createFail = true
		Test.eq(failed.start().code, 1)
		assert(failed.run("close").result.stderr:find("--force", 1, true))
		Test.eq(failed.run("close", { "--force" }).result.status, "closed")
		failed.createFail = false
		Test.eq(failed.start().code, 0)
		Test.eq(failed.created, 1)

		Test.eq(state.run("wait", { "--force" }).code, 1)
		assert(state.run("wait", { "--force" }).result.stderr:find("only applies to close", 1, true))
	end
)

Test.test("workers PostToolUse clears a permission block but is otherwise inert", function()
	local _, state = fake()
	state.start()
	state.hook("UserPromptSubmit")
	state.hook("PermissionRequest")
	Test.eq(state.record().state, "blocked")
	state.hook("PostToolUse")
	Test.eq(state.record().state, "working")
	Test.eq(state.record().hookState, "working")
	local revision = state.record().revision
	state.hook("PostToolUse")
	Test.eq(state.record().revision, revision)
end)

Test.test("workers lock errors name the lock and a stale state lock is reclaimed", function()
	local rt, state = fake()
	state.start()
	local file = assert(state.file())
	state.locked = true
	local busy = state.run("close")
	assert(busy.result.stderr:find(file .. ".lock if no orc command is running", 1, true))
	Test.raises(
		"remove " .. vim.pesc(file) .. "%.state%.lock if no orc command is running",
		function()
			state.hook("UserPromptSubmit")
		end
	)
	state.locked = false
	local lock = file .. ".state.lock"
	assert(vim.uv.fs_mkdir(lock, 448))
	local old = os.time() - 120
	assert(vim.uv.fs_utime(lock, old, old))
	state.hook("UserPromptSubmit")
	Test.eq(state.record().acknowledged, true)
	assert(not rt.exists(lock))
end)

Test.test(
	"workers propagate lock filesystem errors without retrying or leaking the task lock",
	function()
		local rt, state = fake()
		state.start()
		local mkdir_lock = rt.mkdir_lock
		for _, suffix in ipairs({ ".lock", ".state.lock" }) do
			rt.mkdir_lock = function(path)
				if path == state.file() .. suffix then
					error("EACCES: denied " .. path)
				end
				return mkdir_lock(path)
			end
			local response = state.run("close")
			Test.eq(response.code, 1)
			assert(response.result.stderr:find("EACCES: denied", 1, true))
			Test.eq(state.clock, 0)
			assert(not rt.exists(state.file() .. ".lock"))
			assert(not rt.exists(state.file() .. ".state.lock"))
		end
	end
)

Test.test("workers parse_report accepts bullets and bold labels and rejects prose", function()
	local bullets = workers.parse_report(
		"Run: abc\n- Status: done\n- Changes: x\n- Validation: nvim -l t -> ok\n- Notes: n"
	)
	Test.eq(bullets, { run = "abc", status = "done", validation = true })
	Test.eq(workers.parse_report("**Status:** partial\n**Validation**\nran tests").status, "partial")
	Test.eq(workers.parse_report("**Status:** partial\n**Validation**\nran tests").validation, true)
	local prose = workers.parse_report("Status: done. I did not run validation.\nNotes: flaky")
	Test.eq(prose.status, nil)
	Test.eq(prose.validation, false)
	Test.eq(workers.parse_report("Status: maybe\nValidation: ok").status, nil)
	Test.eq(workers.parse_report("Status: Done\nValidation: ok").status, "done")
end)
