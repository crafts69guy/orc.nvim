local runtime = require("orc.runtime")
local workers = require("orc.workers")

local function fake()
	local root = assert(vim.uv.fs_realpath(Test.temp()))
	local rt = runtime.new({
		cwd = root,
		env = {
			HOME = root,
			XDG_CACHE_HOME = root .. "/cache",
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
		gridCalls = {},
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
	function state.hook(event, extra, env)
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
			}, env or {}),
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
	---@type (fun())?
	local on_lock
	---@type (fun(ms:integer))?
	local on_sleep
	---@param callback fun()
	function state.on_lock(callback)
		on_lock = callback
	end
	---@param callback? fun(ms:integer)
	function state.on_sleep(callback)
		on_sleep = callback
	end
	rt.sleep = function(ms)
		state.clock = state.clock + ms
		if on_sleep then
			on_sleep(ms)
		end
	end
	rt.mkdir_lock = function(path)
		if on_lock and path:match("%.state%.lock$") then
			local callback = on_lock
			on_lock = nil
			callback()
		end
		if state.locked then
			return false
		end
		return mkdir_lock(path)
	end
	rt.exec = function(argv, opts)
		if state.exec_result then
			return state.exec_result
		end
		opts = opts or {}
		state.calls[#state.calls + 1] = { argv = argv, opts = opts }
		if argv[1] == "codex" and argv[2] == "mcp" then
			return { code = 0, stdout = state.mcpList or "[]", stderr = "" }
		elseif argv[1] == "git" then
			if argv[3] == "--show-toplevel" then
				return { code = 0, stdout = state.toplevel or root, stderr = "" }
			end
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
				session_id = state.whoamiSession,
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
				local blocks = {}
				if not state.blocksMissing then
					blocks[1] = { block_id = "block:main", host_id = state.anchorHost or "host" }
					if not state.workerHidden then
						blocks[2] = vim.tbl_extend("force", {
							block_id = "block:worker",
							window_id = "window:worker",
							host_id = state.blockHost or "host",
							label = state.layout and state.layout.block.label,
							flavor = "com.superlogical.terminal.shell",
							creator_name = "com.superlogical.terminal",
						}, state.workerBlock or {})
					end
					if state.extraBlock then
						blocks[#blocks + 1] = state.extraBlock
					end
				end
				return response({ blocks = blocks })
			elseif method == "session.new_split" or method == "session.new_window" then
				state.createAttempts = (state.createAttempts or 0) + 1
				if state.createFail then
					return failure("could not create")
				end
				state.created = state.created + 1
				state.layout, state.method, state.creation = input.layout, method, input
				if state.lostCreate then
					return failure("create reply was lost")
				end
				return response(
					state.noBlock and {}
						or { block_ids = { state.returnedBlock or "block:worker" }, window_id = "window:worker" }
				)
			elseif
				method == "session.view"
				or method == "session.move_block"
				or method == "session.resize_pane"
			then
				state.gridCalls[#state.gridCalls + 1] = { method, input, argv[5] }
				if state.gridFailure == method then
					return failure("grid RPC failed")
				end
				if method == "session.view" then
					return response(state.view())
				end
				return response({})
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
					child = state.childOverride or state.noChild and rt.null or {
						pid = state.pid,
						name = state.processName,
						path = "/bin/" .. state.processName,
						cwd = state.processCwd or root,
					},
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
	function state.view()
		local anchor = { block_id = "block:main", rect = { 0, 0, 1, 1 } }
		local blocks = { { block_id = anchor.block_id } }
		local layout = anchor
		if state.created > 0 and #state.closed == 0 then
			blocks[2] = { block_id = "block:worker", label = state.layout.block.label }
			anchor.rect[3] = 0.5
			layout = {
				rect = { 0, 0, 1, 1 },
				split = {
					direction = "horizontal",
					ratio = 0.5,
					before = anchor,
					after = { block_id = "block:worker", rect = { 0.5, 0, 0.5, 1 } },
				},
			}
		end
		return {
			windows = {
				{
					window_id = "window:worker",
					layers = { { kind = "tiled", blocks = blocks, layout = layout } },
				},
			},
		}
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
	-- A done self-review run on an acknowledged idle worker, so close's review check passes.
	function state.review()
		state.native = "idle"
		local sent = state.run("review").result
		state.hook("UserPromptSubmit")
		state.report()
		state.hook("Stop")
		return sent
	end
	return rt, state
end

Test.test("workers symlink paths share one canonical record for start wait and close", function()
	local rt, state = fake()
	local git_rt, exec = runtime.new({ cwd = rt.cwd }), rt.exec
	Test.eq(git_rt.exec({ "git", "init", "--quiet" }).code, 0)
	rt.exec = function(argv, opts)
		if argv[1] == "git" then
			return git_rt.exec(argv, opts)
		end
		return exec(argv, opts)
	end
	local alias = Test.temp() .. "/checkout"
	assert(vim.uv.fs_symlink(rt.cwd, alias, { dir = true }))
	local started = workers.run(rt, {
		"start",
		"feature",
		"task",
		"--path",
		alias,
		"--brief",
		rt.cwd .. "/brief.md",
	})
	Test.eq(started.code, 0)
	Test.eq(state.record().path, rt.cwd)
	Test.eq(state.layout.block.options.cwd, rt.cwd)
	Test.eq(state.start().result.runId, started.result.runId)
	Test.eq(state.created, 1)
	local pair = workers.run(rt, {
		"start",
		"feature",
		"second",
		"--path",
		alias,
		"--brief",
		rt.cwd .. "/brief.md",
		"--here",
	})
	Test.eq(pair.code, 1)
	assert(pair.result.stderr:find("close the existing pair worker first", 1, true))
	Test.eq(state.run("wait", { "--timeout", "0" }).code, 0)
	Test.eq(state.run("close", { "--no-review" }).result.status, "closed")
	Test.eq(#state.closed, 1)
end)

Test.test("workers here refuses a recorded error until the failed worker is closed", function()
	local rt, state = fake()
	Test.eq(state.start().code, 0)
	state.native = "error"
	Test.eq(state.run("wait", { "--timeout", "0" }).result.state, "error")
	Test.eq(state.record().state, "error")
	local args = { "start", "feature", "other", "--path", rt.cwd, "--brief", "brief.md", "--here" }
	local refused = workers.run(rt, args)
	Test.eq(refused.code, 1)
	Test.eq(state.created, 1)
	assert(refused.result.stderr:find("close the existing pair worker first", 1, true))
	local close = "orc pane close task --path " .. vim.fn.shellescape(rt.cwd) .. " --no-review"
	assert(refused.result.stderr:find(close, 1, true))
	assert(refused.result.stderr:find("its pane is gone, use --force", 1, true))
	Test.eq(state.run("close").result.status, "not-reviewed")
	Test.eq(state.run("close", { "--no-review" }).result.status, "closed")
	Test.eq(workers.run(rt, args).code, 0)
	Test.eq(state.created, 2)
end)

Test.test("workers collection skips stale identities and status warns with their paths", function()
	for _, mismatch in ipairs({ "root", "path" }) do
		for _, closed in ipairs({ false, true }) do
			local rt, state = fake()
			state.start()
			local stale = state.record()
			stale[mismatch] = "/old/repo"
			stale.state = closed and "closed" or stale.state
			local file = rt.path(rt.cwd, ".orc", "workers", "abc123.json")
			rt.write(file, rt.encode(stale))
			local found, skipped = workers.collect(rt)
			Test.eq(#found, 1)
			Test.eq(skipped, { file })
			local status = require("orc.status").run(rt, { "--json" })
			Test.eq(status.code, 0)
			Test.eq(#rt.decode(status.out).workers, 1)
			assert(rt.decode(status.out).warnings[1]:find(file, 1, true))
			assert(require("orc.status").run(rt, {}).err:find(file, 1, true))
			assert(require("orc.hooks").context(rt):find("Scratch dir:", 1, true))
			Test.eq(workers.run(rt, { "prune", "--path", rt.cwd }).code, 0)
			Test.eq(rt.read(file), rt.encode(stale))
		end
	end
end)

Test.test("workers validation profile follows shared project memory and is optional", function()
	for _, present in ipairs({ false, true }) do
		local rt, state = fake()
		local profile = rt.path(rt.cwd, ".orc", "validation.md")
		if present then
			rt.write(profile, "# Validation\nedit: syntax\ntask: focused tests\ngate: full suite\n")
		end
		Test.eq(state.start().code, 0)
		local prompt = table.concat(state.layout.block.options.command, " ")
		assert(prompt:find("about 60 lines max", 1, true))
		assert(prompt:find("cite their paths", 1, true))
		Test.eq(prompt:find("Validation profile: read " .. profile, 1, true) ~= nil, present)
		Test.eq(prompt:find("it overrides the brief's Validate section.", 1, true) ~= nil, present)
	end
end)

Test.test("workers reject subdirectories and allow here starts in another checkout", function()
	for _, allow in ipairs({ false, true }) do
		local rt, state = fake()
		local sub = rt.path(rt.cwd, ".scratch", "feature")
		rt.mkdir(sub)
		local args = { "start", "feature", "task", "--path", sub, "--brief", "brief.md", "--here" }
		if allow then
			args[#args + 1] = "--allow-subdir"
		end
		local response = workers.run(rt, args)
		Test.eq(response.code, allow and 0 or 1)
		Test.eq(state.created, allow and 1 or 0)
		if not allow then
			assert(response.result.stderr:find(rt.cwd, 1, true))
		end
	end
	local rt, state = fake()
	local other = rt.path(rt.cwd, "other-checkout")
	rt.mkdir(other)
	local exec = rt.exec
	rt.exec = function(argv, opts)
		if argv[3] == "--show-toplevel" then
			return { code = 0, stdout = opts.cwd, stderr = "" }
		end
		return exec(argv, opts)
	end
	local response = workers.run(rt, {
		"start",
		"feature",
		"task",
		"--path",
		other,
		"--brief",
		"brief.md",
		"--here",
	})
	Test.eq(response.code, 0)
	Test.eq(state.created, 1)
	Test.eq(state.method, "session.new_split")
	Test.eq(state.layout.block.options.cwd, other)
end)

Test.test("workers precheck failure tails output without creating a pane or record", function()
	for _, code in ipairs({ 0, 7 }) do
		local rt, state = fake()
		local exec = rt.exec
		rt.env.SHELL = "fish"
		rt.exec = function(argv, opts)
			if argv[1] == "sh" then
				Test.eq(argv, { "sh", "-c", "verify prerequisite" })
				Test.eq(opts.cwd, rt.cwd)
				local lines = {}
				for i = 1, 45 do
					lines[i] = tostring(i)
				end
				return { code = code, stdout = table.concat(lines, "\n") .. "\n", stderr = "failure\n" }
			end
			return exec(argv, opts)
		end
		local response = state.start({ "--precheck", "verify prerequisite" })
		Test.eq(response.code, 0)
		if code == 0 then
			Test.eq(state.created, 1)
		else
			Test.eq(response.result.status, "precheck-failed")
			Test.eq(response.result.exitCode, 7)
			Test.eq(#vim.split(response.result.output, "\n"), 40)
			assert(response.result.output:match("^7\n"))
			assert(response.result.output:match("failure$"))
			Test.eq(state.created, 0)
			Test.eq(state.record(), nil)
		end
	end
end)

Test.test("workers precheck uses sh syntax regardless of the configured shell", function()
	for _, present in ipairs({ false, true }) do
		local rt, state = fake()
		rt.env.SHELL = "orc-nonexistent-shell"
		if present then
			rt.write(rt.path(rt.cwd, "x"), "fixture")
		end
		local exec = rt.exec
		local shell_exec = runtime.new({ cwd = rt.cwd, env = rt.env }).exec
		rt.exec = function(argv, opts)
			if argv[1] == "sh" or argv[1] == rt.env.SHELL then
				return shell_exec(argv, opts)
			end
			return exec(argv, opts)
		end
		local response = state.start({ "--precheck", "if [ -f x ]; then exit 0; else exit 3; fi" })
		Test.eq(response.code, 0)
		Test.eq(state.created, present and 1 or 0)
		if not present then
			Test.eq(response.result.status, "precheck-failed")
			Test.eq(response.result.exitCode, 3)
			Test.eq(state.record(), nil)
		end
	end
end)

Test.test("workers queue working followups with native keys and preserve process checks", function()
	for _, kind in ipairs({ "codex", "claude" }) do
		for _, mutation in ipairs({ "none", "before", "after", "authorization" }) do
			local rt, state = fake()
			state.processName = kind
			Test.eq(
				workers.run(
					rt,
					{ "start", "feature", "task", "--path", rt.cwd, "--brief", "brief.md", "--kind", kind }
				).code,
				0
			)
			state.hook("UserPromptSubmit")
			Test.eq(state.run("prompt", { "--text", "later" }).result.status, "not-sent")
			Test.eq(#state.writes, 0)
			if mutation == "before" then
				state.pid = 99
			elseif mutation == "after" then
				state.onPaste = function()
					state.pid = 99
				end
			elseif mutation == "authorization" then
				state.onPaste = function()
					state.hook("PermissionRequest")
				end
			end
			local previous = state.record().runId
			local response = state.run("prompt", { "--queue", "--text", "later" })
			if mutation == "before" then
				Test.eq(response.result.status, "not-sent")
				Test.eq(#state.writes, 0)
			elseif mutation ~= "none" then
				Test.eq(response.result.status, "unconfirmed")
				Test.eq(state.enter, nil)
			else
				Test.eq(response.result.status, "queued")
				Test.eq(state.enter, kind == "codex" and "\t" or "\r")
				assert(state.record().runId ~= previous)
				Test.eq(state.record().acknowledged, false)
				state.hook("UserPromptSubmit")
				Test.eq(state.record().acknowledged, true)
			end
		end
	end
end)

Test.test(
	"workers wait until report ignores missing evidence and exits on real outcomes",
	function()
		for _, outcome in ipairs({
			"report",
			"permission",
			"exit",
			"error",
			"timeout",
			"unacknowledged",
		}) do
			local rt, state = fake()
			state.start()
			if outcome == "unacknowledged" then
				state.native = "done"
			else
				state.hook("UserPromptSubmit")
				state.hook("Stop")
				state.native = "idle"
				Test.eq(state.run("wait", { "--timeout", "0" }).result.state, "turn-ended-no-report")
			end
			state.on_sleep(function()
				if state.clock >= 500 then
					if outcome == "report" then
						state.report()
					elseif outcome == "permission" then
						state.native = "blocked"
					elseif outcome == "exit" then
						state.exitCode = 0
					elseif outcome == "error" then
						state.exitCode = 3
					end
					state.onEvent('{"type":"block_event"}\n')
				end
			end)
			local response = state.run(
				"wait",
				{ "--until", "report", "--timeout", outcome == "unacknowledged" and "61000" or "1000" }
			)
			Test.eq(response.code, 0)
			local expected = ({
				report = "idle",
				permission = "blocked",
				exit = "exited",
				error = "error",
				unacknowledged = "unacknowledged",
			})[outcome] or "timeout"
			Test.eq(response.result.state, expected)
			Test.eq(response.result.evidence, outcome == "report")
			if outcome == "unacknowledged" then
				Test.eq(response.result.report, rt.null)
				assert(state.clock >= 60000 and state.clock < 61000)
				assert(response.result.hint:find("trust orc hooks", 1, true))
				assert(response.result.hint:find("Hook failed", 1, true))
				assert(
					response.result.hint:find(
						"Answer any dialog in the pane, then run orc pane wait again",
						1,
						true
					)
				)
			else
				Test.eq(response.result.hint, nil)
			end
			Test.eq(state.stopped, outcome == "unacknowledged" and 1 or 2)
		end
	end
)

Test.test(
	"workers report waits accept working reports and ignore native no-evidence blocks",
	function()
		local _, state = fake()
		state.start()
		state.hook("UserPromptSubmit")
		state.report()
		local response = state.run("wait", { "--until", "report", "--timeout", "0" })
		Test.eq(response.result.state, "working")
		Test.eq(response.result.evidence, true)
		assert(
			response.result.next:find(
				"no-comments once the worker is idle: orc pane review task --path '",
				1,
				true
			)
		)
		state.report("partial")
		Test.eq(state.run("wait", { "--until", "report", "--timeout", "0" }).result.next, nil)
		local rt, missing = fake()
		missing.start()
		missing.hook("UserPromptSubmit")
		missing.hook("Stop")
		missing.entries = { { app = "codex", state = "blocked", kind = "no-evidence" } }
		Test.eq(missing.run("wait", { "--timeout", "0" }).result.state, "turn-ended-no-report")
		Test.eq(missing.run("wait", { "--until", "report", "--timeout", "0" }).result.state, "timeout")
		for _, kind in ipairs({ rt.null, "" }) do
			missing.entries = { { app = "codex", state = "blocked", kind = kind } }
			Test.eq(
				missing.run("wait", { "--until", "report", "--timeout", "0" }).result.state,
				"timeout"
			)
		end
		missing.hook("PermissionRequest")
		missing.exitCode = 0
		Test.eq(missing.run("wait", { "--until", "report", "--timeout", "0" }).result.state, "exited")
		for _, flags in ipairs({
			{ "--until", "idle" },
			{ "--queue" },
			{ "--allow-subdir" },
			{ "--precheck", "true" },
			{ "--no-review" },
		}) do
			Test.eq(missing.run("wait", flags).code, 1)
		end
		rt.env.SHELL = nil
		local exec = rt.exec
		rt.exec = function(argv, opts)
			if argv[1] == "sh" then
				return { code = 1, stdout = "", stderr = "failed" }
			end
			return exec(argv, opts)
		end
		missing.run("close", { "--force" })
		Test.eq(missing.start({ "--precheck", "false" }).result.output, "failed")
	end
)

Test.test("workers launch persists exact ownership and native codex sandbox", function()
	local rt, state = fake()
	local result = state.start()
	assert(result.code == 0, vim.inspect(result))
	Test.eq(result.result.status, "unconfirmed")
	Test.eq(state.created, 1)
	Test.eq(state.method, "session.new_window")
	Test.eq(state.creation.focus, false)
	local record = state.record()
	Test.eq(record.blockId, "block:worker")
	Test.eq(record.launchLabel, "orc:" .. record.runId .. ":task")
	Test.eq(state.layout.block.label, record.launchLabel)
	Test.eq(record.hostId, "host")
	Test.eq(record.instanceId, "instance")
	Test.eq(record.level, "default")
	Test.eq(record.transport, "tui")
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
	record.role, record.level, record.transport = nil, nil, nil
	state.store(record)
	Test.eq(workers.collect(rt)[1].role, "implementer")
	Test.eq(workers.collect(rt)[1].level, "default")
	Test.eq(workers.collect(rt)[1].transport, "tui")
	state.hook("UserPromptSubmit")
	state.hook("Stop")
	state.native = "idle"
	Test.eq(state.run("prompt", { "--text", "continue" }).result.sent, true)
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

local function with_exec_runner(fn, body)
	local previous = package.loaded["orc.exec_worker"]
	package.loaded["orc.exec_worker"] = { run = fn }
	local ok, err = xpcall(body, debug.traceback)
	package.loaded["orc.exec_worker"] = previous
	assert(ok, err)
end

Test.test(
	"workers exec transport launches the owned Lua runner and recognizes its OSC app",
	function()
		local rt, state = fake()
		state.processName, state.app = "nvim", "orc"
		rt.env.APP_SECRET = "synthetic-secret"
		Test.eq(state.start({ "--transport", "exec" }).code, 0)
		local record = state.record()
		Test.eq(record.transport, "exec")
		Test.eq(
			workers.run(rt, {
				"start",
				"feature",
				"task",
				"--path",
				rt.cwd,
				"--brief",
				"brief.md",
				"--kind",
				"claude",
				"--transport",
				"exec",
			}).code,
			1
		)
		Test.eq(record.state, "working")
		Test.eq(record.nativeState, "working")
		Test.eq(record.process.name, "nvim")
		local command = state.layout.block.options.command
		Test.eq(
			vim.list_slice(command, #command - 2),
			{ rt.path(rt.root, "bin", "orc"), "worker-run", state.file() }
		)
		assert(not table.concat(command, " "):find("synthetic-secret", 1, true))
		assert(table.concat(command, " "):find("-u APP_SECRET", 1, true))
		local response = state.run("prompt", { "--text", "continue" })
		Test.eq(response.code, 1)
		assert(response.result.stderr:find("exec follow-ups are not supported", 1, true))
		Test.eq(#state.writes, 0)
		Test.eq(state.record().runId, record.runId)
		Test.eq(state.run("wait", { "--transport", "exec" }).code, 1)
		state.exitCode = 0
		Test.eq(state.run("close").code, 0)
		Test.eq(state.record().state, "closed")
	end
)

Test.test("workers reject unsupported transports before creating a block", function()
	for _, transport in ipairs({ "bad", "exec" }) do
		local rt, state = fake()
		local response = workers.run(rt, {
			"start",
			"feature",
			"task",
			"--path",
			rt.cwd,
			"--brief",
			"brief.md",
			"--kind",
			"claude",
			"--transport",
			transport,
		})
		Test.eq(response.code, 1)
		assert(response.result.stderr:find("transport", 1, true))
		Test.eq(state.created, 0)
	end
	local rt, state = fake()
	state.start()
	local record = state.record()
	record.transport = "bad"
	state.store(record)
	Test.raises("invalid worker transport", function()
		workers.collect(rt)
	end)
	record.transport, record.kind = "exec", "claude"
	state.store(record)
	Test.raises("exec transport requires Codex", function()
		workers.collect(rt)
	end)
end)

Test.test(
	"workers exec snapshots retain unexpected exits and ignore provider root readiness",
	function()
		local rt, state = fake()
		state.start({ "--transport", "exec" })
		state.hook("UserPromptSubmit")
		state.hook("Stop")
		state.report()
		state.native, state.app = "done", "codex"
		Test.eq(state.run("wait", { "--timeout", "0" }).result.state, "timeout")
		state.exitCode = 143
		Test.eq(state.run("wait", { "--timeout", "0" }).result.state, "error")
		Test.eq(state.record().exitCode, 143)
		Test.eq(state.record().execFinished, nil)
		Test.eq(workers.collect(rt)[1].exitCode, 143)
	end
)

Test.test("workers exec runner persists metadata with hook evidence and terminal exit", function()
	for _, code in ipairs({ 0, 9 }) do
		local rt, state = fake()
		state.processName, state.app = "nvim", "orc"
		state.start({ "--transport", "exec", "--role", "scoper" })
		local record = state.record()
		rt.env.ORC_WORKER_FILE, rt.env.REX_BLOCK = state.file(), record.blockId
		with_exec_runner(function(_, launch, log, update)
			Test.eq(log, rt.path(rt.cwd, ".orc", "runs", record.runId .. ".jsonl"))
			Test.eq(
				vim.list_slice(launch.argv, 1, 6),
				{ "codex", "--no-daemon", "exec", "--json", "--sandbox", "read-only" }
			)
			assert(launch.argv[#launch.argv]:find("[orc-run:" .. record.runId .. "]", 1, true))
			assert(launch.argv[#launch.argv]:find("Do not modify files", 1, true))
			state.hook("UserPromptSubmit")
			update({ threadId = "abc", usage = { input_tokens = 42 } })
			state.hook("Stop", {
				last_assistant_message = "Run: "
					.. record.runId
					.. "\nStatus: done\nValidation: tests passed\n",
			})
			update({ exitCode = code, execFinished = true, rateLimited = false })
			return { code = code, out = "", err = "" }
		end, function()
			Test.eq(workers.worker_run(rt, state.file()).code, code)
		end)
		state.exitCode = code
		local response = state.run("wait", { "--timeout", "0" })
		Test.eq(response.code, 0)
		Test.eq(response.result.state, code == 0 and "exited" or "error")
		Test.eq(response.result.evidence, true)
		Test.eq(response.result.status, "done")
		Test.eq(response.result.hint, nil)
		Test.eq(state.record().usage, { input_tokens = 42 })
		Test.eq(state.record().threadId, "abc")
		Test.eq(state.record().exitCode, code)
		Test.eq(state.record().hookState, "idle")
		Test.eq(rt.exists(state.file() .. "." .. record.runId .. ".exec.lock"), false)
		Test.eq(state.run("close").code, 0)
		Test.eq(state.record().state, "closed")
	end
end)

Test.test("workers retry a lost create without replay while the exec runner waits", function()
	local rt, state = fake()
	local args = { "--transport", "exec", "--here" }
	state.lostCreate, state.workerHidden = true, true
	state.processName = "nvim"
	local first = state.start(args)
	Test.eq(first.code, 1)
	assert(first.result.stderr:find("create reply was lost", 1, true))
	assert(first.result.stderr:find("retry the same orc pane start", 1, true))
	local pending = state.record()
	Test.eq(pending.blockId, nil)
	Test.eq(state.createAttempts, 1)
	rt.env.ORC_WORKER_FILE, rt.env.REX_BLOCK = state.file(), "block:worker"
	state.on_sleep(function()
		if state.clock > 10000 then
			state.workerHidden = false
			state.on_sleep(nil)
			local retried = state.start(args)
			Test.eq(retried.code, 0)
			Test.eq({ retried.result.pane, retried.result.runId }, { "block:worker", pending.runId })
		end
	end)
	with_exec_runner(function(_, _, _, update)
		Test.eq(state.record().process.pid, state.pid)
		update({ threadId = "recovered" })
		return { code = 0, out = "", err = "" }
	end, function()
		Test.eq(workers.worker_run(rt, state.file()).code, 0)
	end)
	Test.eq(state.record().threadId, "recovered")
	Test.eq(state.record().windowId, "window:worker")
	Test.eq(state.createAttempts, 1)
	Test.eq(state.method, "session.new_split")
	Test.eq(state.closed, {})
end)

Test.test("workers TUI submit hook survives delayed launch recovery in both harnesses", function()
	for _, kind in ipairs({ "codex", "claude" }) do
		local rt, state = fake()
		local function read_json(path)
			return rt.decode((assert(rt.read(rt.path(rt.root, path)))))
		end
		local plugin = read_json("." .. kind .. "-plugin/plugin.json")
		local submit = read_json(plugin.hooks).hooks.UserPromptSubmit[1].hooks[1]
		local args = { "--kind=" .. kind }
		state.processName = kind
		state.lostCreate, state.workerHidden = true, true
		Test.eq(state.start(args).code, 1)
		local pending = state.record()
		local hook_rt = vim.tbl_extend("force", {}, rt, {
			env = vim.tbl_extend("force", {}, rt.env, {
				ORC = "1",
				ORC_ROLE = "implementer",
				ORC_WORKER_FILE = state.file(),
				REX_BLOCK = "block:worker",
			}),
		})
		local deadline = rt.clock() + submit.timeout * 1000
		state.on_sleep(function()
			assert(rt.clock() < deadline, kind .. " canceled its submit hook before recovery")
			if rt.clock() >= 59000 then
				state.on_sleep(nil)
				state.workerHidden = false
				local recovered = state.start(args)
				Test.eq({ recovered.code, recovered.result.runId }, { 0, pending.runId })
				Test.eq(recovered.result.status, "unconfirmed")
			end
		end)
		local hook = require("orc.hooks").run(
			hook_rt,
			"worker-event",
			rt.encode({
				hook_event_name = "UserPromptSubmit",
				prompt = "[orc-run:" .. pending.runId .. "] work",
			})
		)
		Test.eq(hook.code, 0)
		Test.eq(state.start(args).result.status, "started")
		Test.eq(state.createAttempts, 1)
	end
end)

Test.test(
	"workers adopt a corroborated terminal immediately for ambiguous create replies",
	function()
		for _, failure in ipairs({ "lostCreate", "noBlock" }) do
			local rt, state = fake()
			state.lostCreate, state.noBlock = failure == "lostCreate", failure == "noBlock"
			state.workerBlock = { window_id = rt.null }
			local started = state.start()
			Test.eq({ started.code, started.result.pane }, { 0, "block:worker" })
			Test.eq(started.result.runId, state.record().runId)
			Test.eq(state.record().windowId, nil)
			Test.eq(state.start().result.pane, "block:worker")
			Test.eq(state.createAttempts, 1)
			state.pid = state.pid + 1
			Test.eq(state.run("close", { "--no-review" }).code, 1)
			Test.eq(state.closed, {})
		end
	end
)

Test.test("workers preserve confirmed and pending records from before launch labels", function()
	local rt, state = fake()
	Test.eq(state.start().code, 0)
	local legacy = state.record()
	legacy.launchLabel = nil
	state.store(legacy)
	Test.eq(state.start().result.pane, legacy.blockId)
	legacy.blockId = nil
	state.store(legacy)
	local pending = state.start()
	Test.eq({ pending.code, pending.result.pane, pending.result.runId }, { 0, rt.null, legacy.runId })
	Test.eq(state.createAttempts, 1)
end)

Test.test(
	"workers reject ambiguous or wrong launch evidence without creating or closing another pane",
	function()
		for _, case in ipairs({
			{ field = "instance", value = "wrong-instance", reason = "identity changed" },
			{ field = "blockHost", value = "remote", reason = "no unique local terminal" },
			{ field = "workerBlock", value = { flavor = "other" }, reason = "no unique local terminal" },
			{
				field = "workerBlock",
				value = { creator_name = "other" },
				reason = "no unique local terminal",
			},
			{
				field = "workerBlock",
				value = { label = "orc:previous:task" },
				reason = "no unique local terminal",
			},
			{ field = "processName", value = "not-codex", reason = "process does not match" },
			{ field = "processCwd", value = "/elsewhere", reason = "process does not match" },
			{
				field = "childOverride",
				value = { name = "codex", cwd = false },
				reason = "process does not match",
			},
			{ field = "noChild", value = true, reason = "process does not match" },
			{ field = "processFail", value = true, reason = "block not found" },
			{ field = "extraBlock", reason = "multiple Rex blocks" },
		}) do
			local _, state = fake()
			state.lostCreate, state.workerHidden = true, true
			Test.eq(state.start().code, 1)
			local pending = state.record()
			state.workerHidden = false
			state[case.field] = case.value or { label = pending.launchLabel, block_id = "block:other" }
			local retried = state.start()
			Test.eq(retried.code, 1)
			assert(retried.result.stderr:find(case.reason, 1, true), retried.result.stderr)
			Test.eq({ state.record().runId, state.record().blockId }, { pending.runId, nil })
			Test.eq(state.run("close", { "--no-review" }).code, 1)
			Test.eq(state.createAttempts, 1)
			Test.eq(state.closed, {})
		end
		local _, state = fake()
		state.returnedBlock = "block:main"
		Test.eq(state.start().code, 1)
		Test.eq(state.record().blockId, nil)
		Test.eq(state.closed, {})
		Test.eq(state.start().result.pane, "block:worker")
		Test.eq(state.createAttempts, 1)
	end
)

Test.test(
	"workers close an owned Rex pane after the child exits and its process disappears",
	function()
		local _, state = fake()
		Test.eq(state.start().code, 0)
		state.noChild, state.exitCode = true, 0
		Test.eq(state.run("close").result.status, "closed")
		Test.eq(state.closed, { "block:worker" })
	end
)

Test.test(
	"workers exec rate limits survive snapshots and hooks and wait suggests the other kind",
	function()
		local rt, state = fake()
		state.start({ "--transport", "exec" })
		local record = state.record()
		record.rateLimited, record.execFinished, record.exitCode = true, true, 1
		state.store(record)
		state.hook("UserPromptSubmit")
		state.hook("Stop")
		state.exitCode = 1
		local response = state.run("wait", { "--timeout", "0" })
		Test.eq(response.result.state, "rate-limited")
		Test.eq(response.result.evidence, false)
		assert(response.result.hint:find("--kind claude --transport tui", 1, true))
		Test.eq(workers.collect(rt)[1].state, "rate-limited")
		Test.eq(state.run("close").code, 0)
		Test.eq(state.record().state, "closed")
	end
)

Test.test(
	"workers snapshot merges exec metadata saved during a concurrent hook revision",
	function()
		local rt, state = fake()
		state.start({ "--transport", "exec" })
		state.on_lock(function()
			local record = state.record()
			record.threadId, record.usage = "concurrent", { output_tokens = 7 }
			record.rateLimited, record.execFinished, record.exitCode = true, true, 1
			record.eventRevision = record.revision + 1
			state.store(record)
		end)
		Test.eq(workers.collect(rt)[1].state, "rate-limited")
		Test.eq(state.record().threadId, "concurrent")
		Test.eq(state.record().usage, { output_tokens = 7 })
	end
)

Test.test(
	"workers hidden runner validates identity, waits for block ownership and releases its lock",
	function()
		local rt, state = fake()
		Test.raises("missing record", function()
			workers.worker_run(rt, "/missing")
		end)
		state.start()
		Test.raises("unfinished exec", function()
			workers.worker_run(rt, state.file())
		end)
		local record = state.record()
		record.transport = "exec"
		state.store(record)
		Test.raises("record path mismatch", function()
			workers.worker_run(rt, state.file())
		end)
		rt.env.ORC_WORKER_FILE = state.file()
		Test.raises("Rex block identity mismatch", function()
			workers.worker_run(rt, state.file())
		end)
		rt.env.REX_BLOCK = record.blockId
		with_exec_runner(function()
			error("runner failure")
		end, function()
			Test.raises("runner failure", function()
				workers.worker_run(rt, state.file())
			end)
		end)
		local lock = state.file() .. "." .. record.runId .. ".exec.lock"
		Test.eq(rt.exists(lock), false)
		rt.mkdir(lock)
		Test.raises("already active", function()
			workers.worker_run(rt, state.file())
		end)
		rt.remove(lock)
		local block = record.blockId
		record.blockId = nil
		state.store(record)
		state.on_sleep(function()
			record.blockId = block
			state.store(record)
		end)
		with_exec_runner(function(_, _, _, update)
			record.runId = "replacement"
			state.store(record)
			update({ threadId = "stale" })
		end, function()
			Test.raises("current run changed", function()
				workers.worker_run(rt, state.file())
			end)
		end)
	end
)

Test.test(
	"workers exec restarts ignore old runner locks and reject a changed launch run",
	function()
		local rt, state = fake()
		state.start({ "--transport", "exec" })
		local previous = state.record()
		rt.mkdir(state.file() .. "." .. previous.runId .. ".exec.lock")
		Test.eq(state.run("close").code, 0)
		Test.eq(state.start({ "--transport", "exec" }).code, 0)
		local record = state.record()
		assert(record.runId ~= previous.runId)
		rt.env.ORC_WORKER_FILE, rt.env.REX_BLOCK = state.file(), record.blockId
		with_exec_runner(function()
			return { code = 0, out = "", err = "" }
		end, function()
			Test.eq(workers.worker_run(rt, state.file()).code, 0)
		end)
		record.blockId = nil
		state.store(record)
		state.on_sleep(function()
			record.runId = "changed-during-launch"
			state.store(record)
		end)
		Test.raises("current run changed during launch", function()
			workers.worker_run(rt, state.file())
		end)
	end
)

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
			"about 60 lines max",
			"cite their paths",
		}) do
			assert(command:find(part, 1, true), part)
		end
		assert(not command:find("Write the final report", 1, true))
		state.hook("UserPromptSubmit")
		state.hook("Stop")
		state.native = "idle"
		Test.eq(state.run("prompt", { "--text", "scope callers too" }).result.sent, true)
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
		Test.eq(rt.read(rt.path(rt.cwd, ".orc", "report.md")), nil)
		state.native = "idle"
		Test.eq(state.run("wait", { "--timeout", "0" }).result.evidence, true)
		state.hook("Stop", {
			last_assistant_message = "Run: " .. record.runId .. "\nStatus: blocked\nValidation: failed",
		})
		Test.eq(rt.read(record.report), message)
		Test.eq(state.record().reportStatus, "done")
	end
end)

Test.test("workers here ownership ends when an implementer closes or exits successfully", function()
	for _, case in ipairs({
		{ role = "scoper", native = "working", allowed = true },
		{ role = "implementer", native = "working", allowed = false },
		{ native = "working", allowed = false },
		{ role = "implementer", native = "idle", allowed = false },
		{ role = "implementer", exit = 0, allowed = true },
		{ role = "implementer", exit = 1, allowed = false },
	}) do
		local rt, state = fake()
		state.start()
		local record = state.record()
		record.role = case.role
		state.store(record)
		state.native, state.exitCode = case.native, case.exit
		if case.exit ~= nil then
			local waited = state.run("wait", { "--timeout", "0" })
			Test.eq(waited.result.state, case.exit == 0 and "exited" or "error")
		end
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

Test.test(
	"workers prune closes only successful exits or evidenced reviewed done workers",
	function()
		for _, case in ipairs({
			{ native = "working", exit = 0, close = true },
			{ native = "idle", report = "done", ack = true, close = true },
			{ native = "done", report = "done", ack = true, close = true },
			{ native = "idle", report = "done", ack = true, unreviewed = true },
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
			if case.close and case.report then
				state.review()
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
				local reason = case.unreviewed
						and "no done self-review for this implementer; run no-comments on the current diff, then orc pane review task"
					or "no completed report"
				assert(response.result.skipped[1].reason:find(reason, 1, true), reason)
				Test.eq(#state.closed, 0)
			end
			assert(not rt.exists(state.file() .. ".lock"))
		end
	end
)

Test.test(
	"workers prune preserves locks and refuses stale servers changed processes and close failures",
	function()
		for _, failure in ipairs({ "lock", "identity", "process", "close" }) do
			local rt, state = fake()
			state.start()
			state.hook("UserPromptSubmit")
			state.hook("Stop")
			state.report()
			state.review()
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
		state.mcpList = rt.encode({ { name = "inkdrop", enabled = true } })
		rt.exec = function(argv, opts)
			if argv[1] == "codex" and argv[3] == "get" then
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
			Test.eq(state.start({ "--mcp", "inkdrop" }).code, 0)
			Test.eq(state.record().mcp, { "inkdrop" })
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
			Test.eq(state.run("close", { "--no-review" }).code, 0)
			Test.eq(checks, 1)
			for _, call in ipairs(state.calls) do
				assert(call.argv[1] ~= "launchctl")
			end
		end, debug.traceback)
		package.loaded["orc.inkdrop_mcp"] = old
		assert(ok, err)
	end
)

Test.test("workers record a sorted MCP allowlist and drop its config on close", function()
	local rt, state = fake()
	state.processName = "claude"
	for _, extra in ipairs({ { "--mcp", "a;b" }, { "--mcp", "$(x)" } }) do
		local args =
			{ "start", "feature", "task", "--path", rt.cwd, "--brief", rt.path(rt.cwd, "brief.md") }
		vim.list_extend(args, extra)
		Test.eq(workers.run(rt, args).code, 1)
	end
	Test.eq(state.run("close", { "--mcp", "figma" }).code, 1)
	rt.write(
		rt.env.HOME .. "/.claude.json",
		rt.encode({
			mcpServers = { ["Figma Name"] = { command = "figma" }, chrome = { command = "chrome" } },
		})
	)
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
		"--mcp",
		" Figma Name,chrome,Figma Name ",
	}
	Test.eq(workers.run(rt, args).code, 0)
	Test.eq(state.record().mcp, { "Figma Name", "chrome" })
	local command = state.layout.block.options.command
	local config = command[vim.fn.index(command, "--mcp-config") + 2]
	local names = vim.tbl_keys(rt.decode((assert(rt.read(config)))).mcpServers)
	table.sort(names)
	Test.eq(names, { "Figma Name", "chrome" })
	Test.eq(state.run("close", { "--no-review" }).code, 0)
	Test.eq(rt.read(config), nil)
end)

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
			"--mcp",
			"inkdrop",
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
	state.review()
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
		Test.eq(state.record().reportStatus, "partial")
		Test.eq(rt.read(rt.path(rt.cwd, ".orc", "report.md")), nil)
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
	Test.eq(result.result.sent, true)
	Test.eq(result.result.queued, false)
	assert(result.result.runId ~= old.runId)
	Test.eq(state.record().previousReport, old.report)
	assert(rt.read(old.report))
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
		Test.eq(result.result.sent, false)
		Test.eq(result.result.status, "unconfirmed")
		Test.eq(state.start().result.runId, result.result.runId)
		Test.eq(#state.writes, 1)
		assert(state.record().deliveryError)
	end
)

Test.test("workers wait reports stalled TUI transcripts without changing worker state", function()
	for _, transport in ipairs({ "tui", false }) do
		for _, until_report in ipairs({ false, true }) do
			local rt, state = fake()
			state.start()
			local transcript = rt.path(rt.cwd, "transcript.jsonl")
			rt.write(transcript, "working\n")
			local old = os.time() - 1800
			assert(vim.uv.fs_utime(transcript, old, old))
			state.hook("UserPromptSubmit", { transcript_path = transcript })
			local record = state.record()
			record.transport = transport or nil
			state.store(record)
			local flags = { "--timeout", "0" }
			if until_report then
				vim.list_extend(flags, { "--until", "report" })
			end
			local response = state.run("wait", flags)
			Test.eq(response.code, 0)
			Test.eq(response.result.state, "stalled")
			Test.eq(response.result.report, rt.null)
			Test.eq(response.result.evidence, false)
			Test.eq(response.result.transcript, transcript)
			assert(response.result.hint:find("running child process", 1, true))
			assert(response.result.hint:find("orc pane close task --path", 1, true))
			assert(response.result.hint:find("--no-review", 1, true))
			Test.eq(state.record().state, "working")
			Test.eq(state.record().hookState, "working")
			Test.eq(#state.closed, 0)
			Test.eq(state.stopped, state.streams)
		end
	end
end)

Test.test("workers report wait prefers matching evidence over a stalled transcript", function()
	local rt, state = fake()
	state.start()
	local transcript = rt.path(rt.cwd, "transcript.jsonl")
	rt.write(transcript, "working\n")
	local old = os.time() - 3600
	assert(vim.uv.fs_utime(transcript, old, old))
	state.hook("UserPromptSubmit", { transcript_path = transcript })
	state.report("done")
	local response = state.run("wait", { "--until", "report", "--timeout", "0" })
	Test.eq(response.code, 0)
	Test.eq(response.result.state, "working")
	Test.eq(response.result.evidence, true)
	Test.eq(response.result.report, state.record().report)
	Test.eq(response.result.status, "done")
	Test.eq(state.record().hookState, "working")
end)

Test.test(
	"workers wait ignores fresh missing unreadable idle blocked and exec transcripts",
	function()
		for _, case in ipairs({ "fresh", "missing", "absent", "unreadable", "idle", "blocked", "exec" }) do
			local rt, state = fake()
			state.start(case == "exec" and { "--transport", "exec" } or nil)
			local transcript = rt.path(rt.cwd, "transcript.jsonl")
			rt.write(transcript, "working\n")
			local stamp = os.time() - (case == "fresh" and 1790 or 3600)
			assert(vim.uv.fs_utime(transcript, stamp, stamp))
			state.hook("UserPromptSubmit", {
				transcript_path = case == "absent" and "" or transcript,
			})
			if case == "missing" then
				rt.remove(transcript)
			elseif case == "unreadable" then
				assert(vim.uv.fs_chmod(transcript, 0))
			elseif case == "idle" then
				state.hook("Stop")
				state.native = "idle"
			elseif case == "blocked" then
				state.hook("PermissionRequest")
				state.native = "blocked"
			end
			local response = state.run("wait", { "--until", "report", "--timeout", "1000" })
			if case == "unreadable" then
				assert(vim.uv.fs_chmod(transcript, 384))
			end
			Test.eq(response.code, 0)
			Test.eq(response.result.state, case == "blocked" and "blocked" or "timeout")
			Test.eq(state.clock, case == "blocked" and 0 or 1000)
		end
	end
)

Test.test("workers transcript survives snapshots stale events and follow-up runs", function()
	local rt, state = fake()
	state.start()
	local transcript = rt.path(rt.cwd, "transcript.jsonl")
	rt.write(transcript, "working\n")
	state.on_lock(function()
		state.hook("UserPromptSubmit", { transcript_path = transcript })
	end)
	workers.collect(rt)
	Test.eq(state.record().transcript, transcript)
	state.on_lock(function()
		state.hook("UserPromptSubmit", { transcript_path = transcript .. ".new" })
	end)
	state.hook("UserPromptSubmit", { transcript_path = transcript .. ".stale" })
	transcript = transcript .. ".new"
	Test.eq(state.record().transcript, transcript)
	state.hook("Stop")
	state.native = "idle"
	local previous = state.record().runId
	Test.eq(state.run("prompt", { "--text", "continue" }).code, 0)
	assert(state.record().runId ~= previous)
	Test.eq(state.record().transcript, transcript)
	for _, value in ipairs({ "", false, 42 }) do
		state.hook("UserPromptSubmit", { transcript_path = value })
		Test.eq(state.record().transcript, transcript)
	end
	state.hook("UserPromptSubmit")
	Test.eq(state.record().transcript, transcript)
end)

Test.test("workers wait reconnects resnapshots and cleans streams", function()
	local _, state = fake()
	state.ack = true
	state.start()
	local ticks = 0
	state.on_sleep(function()
		ticks = ticks + 1
		if ticks == 1 then
			assert(state.onExit)({ code = 1, signal = 0, stdout = "", stderr = "" })
		elseif ticks == 2 then
			state.native = "idle"
			state.report()
			state.hook("Stop")
			state.onEvent('{"type":"block_event"}\n')
		end
	end)
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
			state.on_sleep(function(ms)
				assert(ms <= 250)
				if state.clock == event_at then
					state.onEvent('{"type":"block_event"}\n')
				end
			end)
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
	state.on_sleep(function()
		state.native = "blocked"
		state.onEvent('{"type":"block_event"}\n')
	end)
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

Test.test("workers wait timeout omits the acknowledgment hint for acknowledged workers", function()
	local _, state = fake()
	state.ack = true
	state.start()
	local result = state.run("wait", { "--timeout", "120000" }).result
	Test.eq(result.state, "timeout")
	Test.eq(result.hint, nil)
end)

Test.test("workers wait timeout below the unacknowledged limit includes a hint", function()
	local _, state = fake()
	state.start()
	local result = state.run("wait", { "--timeout", "1000" }).result
	Test.eq(result.state, "timeout")
	assert(result.hint and result.hint:find("Hook failed", 1, true), "missing acknowledgment hint")
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
		local original = state.record()
		state.on_sleep(function()
			local record = state.record()
			record.runId = "changed"
			local file = rt.path(
				rt.cwd,
				".orc",
				"workers",
				vim.fn.sha256(record.path .. "\0" .. record.task) .. ".json"
			)
			rt.write(file, rt.encode(record))
		end)
		local followed = state.run("wait", { "--timeout", "500" })
		Test.eq(followed.result.state, "timeout")
		Test.eq(followed.result.runId, "changed")
		Test.eq(
			followed.result.previousRuns,
			{ { runId = original.runId, report = rt.null, status = rt.null } }
		)
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
	local refused = state.run("close")
	Test.eq({ refused.code, refused.result.status }, { 1, "not-reviewed" })
	assert(
		refused.result.stderr:find(
			"no done self-review for this implementer; run no-comments on the current diff, then orc pane review task --path '",
			1,
			true
		)
	)
	assert(refused.result.stderr:find("pass --no-review only", 1, true))
	assert(refused.result.stderr:find("--review <saved report>", 1, true))
	Test.eq(#state.closed, 0)
	Test.eq(state.record().state ~= "closed", true)
	Test.eq(state.run("close", { "--no-review" }).result.status, "closed")
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
		state.on_lock(function()
			state.hook("UserPromptSubmit")
		end)
		local observed = workers.collect(rt)[1]
		Test.eq(observed.acknowledged, true)
		Test.eq(state.record().acknowledged, true)
		state.on_lock(function()
			Test.eq(state.run("close", { "--no-review" }).code, 0)
		end)
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
		state.on_lock(function()
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
		end)
		-- The stale snapshot is dropped and the newer run's durable state is shown.
		Test.eq(workers.collect(rt)[1].state, "unconfirmed")
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
		Test.eq(state.closed, {})
		Test.eq(state.record().blockId, nil)
		state.blockHost = nil
		Test.eq(state.start().code, 0)
		Test.eq(state.created, 1)
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
		assert(state.start().result.stderr:find("pending launch", 1, true))
		Test.eq(state.created, 0)
		Test.eq(state.createAttempts, 1)
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
		Test.eq(failed.closed, {})
		Test.eq(failed.record().blockId, nil)
		failed_rt.write = write
		Test.eq(failed.start().result.pane, "block:worker")
		Test.eq(failed.createAttempts, 1)
		assert(not other_rt.exists(other_rt.cwd .. "/.orc/unrelated"))
		assert(rt.exists(rt.cwd))
	end
)

Test.test("workers report a grid after starting here", function()
	local _, state = fake()
	local started = state.start({ "--here" })
	Test.eq(started.code, 0)
	Test.eq(started.result.layout, "grid")
	Test.eq(
		state.gridCalls,
		{ { "session.view", { session_id = "session:fixture" }, "session:fixture" } }
	)
end)

Test.test("workers grid start moves the newest worker to the last cell", function()
	local rt, state = fake()
	local path = rt.path(rt.root, "test", "fixtures", "rex-grid", "view-before-columns.json")
	state.view = function()
		local view = rt.decode((assert(rt.read(path))))
		view.windows[1].layers[1].blocks[2].label = state.layout.block.label
		return view
	end
	local started = state.start({ "--here" })
	Test.eq(started.result.layout, "grid")
	Test.eq(state.creation.focus, false)
	local observed = {}
	for _, call in ipairs(state.gridCalls) do
		local method, args, session = call[1], call[2], call[3]
		Test.eq({ session, args.session_id }, { "session:fixture", "session:fixture" })
		observed[#observed + 1] =
			{ method, args.block_id, args.anchor_block_id, args.direction, args.side, args.ratio }
	end
	Test.eq(observed, {
		{ "session.view" },
		{ "session.move_block", "block:e", "block:main", "horizontal", "after", 2 / 3 },
		{ "session.move_block", "block:c", "block:main", "horizontal", "after", 1 / 2 },
		{ "session.move_block", "block:b", "block:main", "vertical", "after", 1 / 2 },
		{ "session.move_block", "block:d", "block:c", "vertical", "after", 1 / 2 },
		{ "session.move_block", "block:worker", "block:e", "vertical", "after", 1 / 2 },
	})
end)

Test.test(
	"workers grid respects foreign panes and persists launches after a layout failure",
	function()
		for _, case in ipairs({ "foreign", "failure", "new-window" }) do
			local _, state = fake()
			local view = state.view
			state.view = function()
				local current = view()
				local layer = current.windows[1].layers[1]
				if case == "foreign" then
					layer.blocks[#layer.blocks + 1] =
						{ block_id = "block:foreign", label = "orc:feature/task" }
				else
					layer.layout.split.ratio, layer.layout.split.before.rect[3] = 0.75, 0.75
				end
				return current
			end
			if case == "failure" then
				state.gridFailure = "session.resize_pane"
			end
			local here = case ~= "new-window"
			local started = state.start(here and { "--here" } or {})
			Test.eq({ started.code, state.record().blockId }, { 0, "block:worker" })
			Test.eq(state.record().here, here)
			if here then
				Test.eq(
					{ state.created, state.method, #state.gridCalls },
					{ 1, "session.new_split", case == "foreign" and 1 or 2 }
				)
				Test.eq({
					state.creation.anchor_id,
					state.creation.direction,
					state.creation.side,
					state.creation.focus,
				}, { "block:main", "horizontal", "after", false })
				Test.eq(started.result.layout, case == "foreign" and "skipped" or "failed")
				assert(
					started.result.layoutReason:find(
						case == "foreign" and "non-orc block" or "grid RPC failed",
						1,
						true
					)
				)
			else
				Test.eq(state.method, "session.new_window")
				Test.eq(started.result.layout, nil)
				Test.eq(state.run("close", { "--no-review" }).result.layout, nil)
				Test.eq(state.gridCalls, {})
			end
		end
	end
)

Test.test("workers grid retiles close and prune from a fresh view", function()
	for _, case in ipairs({ "close", "prune", "failed-prune" }) do
		local command = case == "close" and "close" or "prune"
		local rt, state = fake()
		local path = rt.path(rt.root, "test", "fixtures", "rex-grid", "view-before-columns.json")
		local before = rt.decode((assert(rt.read(path))))
		local after = vim.deepcopy(before)
		local layer = after.windows[1].layers[1]
		table.remove(layer.blocks, 2)
		local anchor = layer.layout.split.before.split.before.split.before
		anchor.block_id, anchor.split = "block:main", nil
		state.view = function()
			return #state.closed == 0 and before or after
		end
		Test.eq(state.start({ "--here" }).result.layout, "grid")
		state.gridCalls = {}
		state.exitCode = 0
		if command == "prune" then
			local record = state.record()
			record.here = nil
			state.store(record)
		end
		if case == "failed-prune" then
			state.gridFailure = "session.move_block"
		end
		local response = command == "close" and state.run("close")
			or workers.run(rt, { "prune", "--path", rt.cwd })
		local outcome = command == "close" and response.result or response.result.closed[1]
		Test.eq({ response.code, state.record().state, outcome.layout }, {
			0,
			"closed",
			case == "failed-prune" and "failed" or "grid",
		})
		Test.eq(
			{ state.gridCalls[1][1], state.gridCalls[2][1], state.gridCalls[3][1] },
			{ "session.view", "session.view", "session.move_block" }
		)
		Test.eq(state.closed, { "block:worker" })
		if case == "failed-prune" then
			assert(outcome.layoutReason:find("grid RPC failed", 1, true))
			Test.eq(#state.gridCalls, 3)
		end
	end
end)

Test.test("workers grid skips close without an anchor in the worker's tiled layer", function()
	for _, case in ipairs({
		{ anchor = nil, views = 0, reason = "no anchor in the worker's Rex session" },
		{ anchor = "", views = 0, reason = "no anchor in the worker's Rex session" },
		{
			anchor = "block:main",
			session = "session:elsewhere",
			views = 0,
			reason = "no anchor in the worker's Rex session",
		},
		{
			anchor = "block:elsewhere",
			views = 1,
			reason = "anchor is outside the worker's tiled window",
		},
		{ anchor = nil, views = 0, legacy = true },
		{ anchor = "block:elsewhere", views = 1, legacy = true },
		{
			anchor = "block:main",
			views = 1,
			worker_missing = true,
			reason = "anchor is outside the worker's tiled window",
		},
	}) do
		local rt, state = fake()
		Test.eq(state.start({ "--here" }).result.layout, "grid")
		state.gridCalls = {}
		if case.anchor then
			rt.env.REX_BLOCK = case.anchor
		else
			rt.env.REX_BLOCK = nil
		end
		if case.session then
			rt.env.REX_SESSION = case.session
		end
		if case.legacy then
			local record = state.record()
			record.here = nil
			state.store(record)
		end
		if case.worker_missing then
			state.view = function()
				return { windows = {} }
			end
		end
		local closed = state.run("close", { "--no-review" })
		Test.eq(
			{ closed.code, closed.result.status, closed.result.layout, closed.result.layoutReason },
			{
				0,
				"closed",
				case.reason and "skipped" or nil,
				case.reason,
			}
		)
		Test.eq(state.closed, { "block:worker" })
		Test.eq(#state.gridCalls, case.views)
	end
end)

Test.test(
	"workers grid leaves the layout alone if the anchor changes windows during close",
	function()
		for _, case in ipairs({ "missing", "moved" }) do
			local _, state = fake()
			Test.eq(state.start({ "--here" }).result.layout, "grid")
			state.gridCalls = {}
			local view = state.view
			state.view = function()
				local current = view()
				if #state.closed > 0 then
					if case == "missing" then
						return { windows = {} }
					end
					current.windows[1].window_id = "window:elsewhere"
				end
				return current
			end
			local closed = state.run("close", { "--no-review" })
			Test.eq(
				{ closed.code, closed.result.status, closed.result.layout, closed.result.layoutReason },
				{
					0,
					"closed",
					"skipped",
					"anchor is outside the worker's tiled window",
				}
			)
			Test.eq({ state.gridCalls[1][1], state.gridCalls[2][1], #state.gridCalls }, {
				"session.view",
				"session.view",
				2,
			})
		end
	end
)

Test.test("workers grid waits for the Rex session lock before reading the layout", function()
	for _, case in ipairs({
		"released",
		"stale",
		"busy",
		"stale-reaper",
		"busy-reaper",
		"reclaim-failed",
	}) do
		local rt, state = fake()
		local cache = rt.env.XDG_CACHE_HOME
		if case == "released" then
			rt.env.XDG_CACHE_HOME = nil
			cache = rt.path(rt.env.HOME, ".cache")
		end
		local lock = rt.path(cache, "orc", "rex-layout", vim.fn.sha256(rt.env.REX_SESSION) .. ".lock")
		local reaper = lock .. ".reaper"
		rt.mkdir(lock)
		if
			case == "stale"
			or case == "stale-reaper"
			or case == "busy-reaper"
			or case == "reclaim-failed"
		then
			local old = os.time() - 120
			assert(vim.uv.fs_utime(lock, old, old))
			if case == "stale-reaper" or case == "busy-reaper" then
				rt.mkdir(reaper)
				if case == "stale-reaper" then
					assert(vim.uv.fs_utime(reaper, old, old))
				end
			elseif case == "reclaim-failed" then
				local rmdir = rt.rmdir
				rt.rmdir = function(path)
					assert(path ~= lock, "cannot reclaim grid lock")
					rmdir(path)
				end
			end
		elseif case == "released" then
			state.on_sleep(function()
				Test.eq(state.gridCalls, {})
				Test.eq(state.record().blockId, "block:worker")
				rt.rmdir(lock)
				state.on_sleep(nil)
			end)
		end
		local started = state.start({ "--here" })
		Test.eq({ started.code, state.record().blockId }, { 0, "block:worker" })
		local failed = case == "busy" or case == "busy-reaper" or case == "reclaim-failed"
		Test.eq(started.result.layout, failed and "failed" or "grid")
		Test.eq(rt.exists(lock), failed)
		Test.eq(rt.exists(reaper), case == "busy-reaper")
		Test.eq(#state.gridCalls, failed and 0 or 1)
		if case == "reclaim-failed" then
			assert(started.result.layoutReason:find("cannot reclaim grid lock", 1, true))
		end
	end
end)

Test.test("workers grid rechecks a stale layout lock before reclaiming it", function()
	local rt, first = fake()
	local other_rt, second = fake()
	other_rt.env.XDG_CACHE_HOME = rt.env.XDG_CACHE_HOME
	local lock = rt.path(
		rt.env.XDG_CACHE_HOME,
		"orc",
		"rex-layout",
		vim.fn.sha256(rt.env.REX_SESSION) .. ".lock"
	)
	rt.mkdir(lock)
	local old = os.time() - 120
	assert(vim.uv.fs_utime(lock, old, old))

	local waiter = coroutine.create(function()
		return second.start({ "--here" })
	end)
	local stat = vim.uv.fs_stat
	local observed = false
	Test.replace(vim.uv, "fs_stat", function(path, ...)
		local result, err, code = stat(path, ...)
		if path == lock and coroutine.running() == waiter and not observed then
			observed = true
			coroutine.yield("saw-stale-lock")
		end
		return result, err, code
	end)
	second.on_sleep(function()
		second.on_sleep(nil)
		coroutine.yield("waiting-for-owner")
	end)

	Test.eq({ coroutine.resume(waiter) }, { true, "saw-stale-lock" })
	local view = first.view
	local saw_wait
	first.view = function()
		local ok, phase = coroutine.resume(waiter)
		assert(ok, phase)
		saw_wait = phase
		return view()
	end
	Test.eq(first.start({ "--here" }).result.layout, "grid")
	Test.eq(#second.gridCalls, 0)
	Test.eq(saw_wait, "waiting-for-owner")

	local ok, started = coroutine.resume(waiter)
	assert(ok, started)
	Test.eq({ started.result.layout, #second.gridCalls, rt.exists(lock) }, { "grid", 1, false })
end)

Test.test("workers grid still closes an owned split when the Rex view fails", function()
	local _, state = fake()
	Test.eq(state.start({ "--here" }).result.layout, "grid")
	state.gridFailure = "session.view"
	local response = state.run("close", { "--no-review" })
	Test.eq(
		{ response.code, state.record().state, response.result.layout },
		{ 0, "closed", "failed" }
	)
	assert(response.result.layoutReason:find("grid RPC failed", 1, true))
end)

Test.test("workers grid recovers a split after an unconfirmed launch", function()
	for _, case in ipairs({ "here", "legacy", "elsewhere", "no-anchor" }) do
		local rt, state = fake()
		state.lostCreate, state.workerHidden = true, true
		Test.eq(state.start({ "--here" }).code, 1)
		Test.eq(state.gridCalls, {})
		state.workerHidden = false
		if case == "legacy" then
			local record = state.record()
			record.here = nil
			state.store(record)
		elseif case == "elsewhere" then
			rt.env.REX_SESSION = "session:elsewhere"
		elseif case == "no-anchor" then
			rt.env.REX_BLOCK = nil
		end
		local started = state.start({ "--here" })
		Test.eq({ started.code, started.result.pane, state.created }, { 0, "block:worker", 1 })
		local skipped = case == "elsewhere" or case == "no-anchor"
		Test.eq(started.result.layout, skipped and "skipped" or "grid")
		Test.eq(#state.gridCalls, skipped and 0 or 1)
	end
end)

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
		assert(state.onExit)({ code = 0, signal = 0, stdout = "", stderr = "" })
		Test.eq(ended, true)
		stream.stop()
		state.exec_result = { code = 0, signal = 0, stdout = "bad", stderr = "" }
		Test.raises("invalid JSON", client.identity)
		state.exec_result.stdout = "{}"
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
	local executable = "/fixture/rex"
	Test.replace(vim.fn, "exepath", function()
		return executable
	end, function()
		Test.eq(rex.resolve(rt), "/fixture/rex")
		executable = ""
		local old_exists = rt.exists
		rt.exists = function()
			return false
		end
		Test.eq(rex.resolve(rt), "rex")
		rt.exists = old_exists
	end)
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
		state.exec_result = { code = 0, signal = 0, stdout = response, stderr = "" }
		Test.raises("rex:", client.identity)
	end
	state.exec_result = { code = 127, signal = 0, stdout = "", stderr = "" }
	Test.raises("command failed", client.identity)
	state.exec_result = { code = 0, signal = 0, stdout = "{}", stderr = "" }
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
	local found, skipped = workers.collect(rt)
	Test.eq(found, {})
	Test.eq(skipped, { state.file() })
	local read = rt.read
	rt.read = function(path)
		if path:match("%.json$") then
			return nil, "permission denied"
		end
		return read(path)
	end
	Test.eq(state.run("close").code, 1)
	Test.raises("cannot read worker record", function()
		workers.collect(rt)
	end)
	Test.eq(#state.closed, 0)
	local _, no_block = fake()
	no_block.noBlock, no_block.workerHidden = true, true
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
		workers.event(hook_rt, Test.invalid(false))
	end)
	hook_rt.env.REX_BLOCK = "other"
	Test.raises("block identity", function()
		workers.event(hook_rt, {})
	end)
	hook_rt.env.REX_BLOCK = "block:worker"
	record.blockId = nil
	state.store(record)
	state.on_sleep(function()
		if state.clock > 10000 then
			record.blockId = "block:worker"
			state.store(record)
			state.on_sleep(nil)
		end
	end)
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
	state.run("close", { "--no-review" })
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
		Test.eq(other.record().state, "turn-ended-no-report")
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
		state.run("close", { "--no-review" })
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
		local tick = 0
		local previous_event, previous_exit
		state.on_sleep(function()
			tick = tick + 1
			if tick == 1 then
				previous_event, previous_exit = state.onEvent, state.onExit
				assert(previous_exit)({ code = 0, signal = 0, stdout = "", stderr = "" })
			elseif tick == 2 then
				previous_event('{"type":"old"}\n')
				assert(previous_exit)({ code = 0, signal = 0, stdout = "", stderr = "" })
				local record = state.record()
				record.state = "closed"
				state.store(record)
			end
		end)
		Test.eq(state.run("wait", { "--timeout", "1000" }).result.state, "closed")
		Test.eq(state.streams, 2)
		Test.eq(state.stopped, 2)
		local other_rt, other = fake()
		other.start()
		other_rt.stream = nil
		Test.eq(other.run("wait", { "--timeout", "0" }).code, 1)
		local missing_rt, missing = fake()
		missing.start()
		missing.on_sleep(function()
			missing_rt.remove(missing.file())
		end)
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
		local found, skipped = workers.collect(rt)
		Test.eq(found, {})
		Test.eq(skipped, { state.file() })
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
	state.on_lock(function()
		state.hook("Stop")
		Test.eq(state.record().state, "idle")
	end)
	state.hook("PermissionRequest")
	Test.eq(state.record().state, "idle")
	Test.eq(state.record().acknowledged, true)
	state.on_lock(function()
		state.hook("UserPromptSubmit", { prompt = "manual newer work" })
	end)
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
			Test.eq(result.result.sent, false)
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
			state.on_lock(function()
				state.on_lock(function()
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
				end)
			end)
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
				Test.eq(result.result.sent, true)
				Test.eq(state.enter, "\r")
			else
				Test.eq(state.enter, nil)
				assert(result.code ~= 0 or not result.result.sent)
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

Test.test(
	"workers plain wait resumes after an auto-resolved permission but keeps native blocks",
	function()
		for _, native in ipairs({ "working", "blocked" }) do
			local _, state = fake()
			state.start()
			state.hook("UserPromptSubmit")
			state.hook("PermissionRequest")
			state.native = native
			local response = state.run("wait", { "--timeout", "1000" })
			Test.eq(response.code, 0)
			Test.eq(response.result.state, native == "working" and "timeout" or "blocked")
			Test.eq(state.record().state, native)
			Test.eq(state.record().blockedKind, native == "blocked" and "permission" or nil)
			Test.eq(state.record().hookState, "blocked")
		end
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
			local response = state.run("close", { "--no-review" })
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

Test.test("workers parse_report keeps its own header when it quotes an earlier report", function()
	-- A follow-up run pasted its previous report, Run line included; the last Run used to win.
	local parsed = workers.parse_report(
		"Run: new\nStatus: partial\n## Validation\nran tests\n\n## Earlier report\nRun: old\nStatus: done\n"
	)
	Test.eq(parsed, { run = "new", status = "partial", validation = true })
end)

Test.test(
	"workers parse_report keeps Validation sub-headings and stops at its own level",
	function()
		local function validation(body)
			return workers.parse_report("Run: abc\nStatus: done\n\n## Changes\n- x\n\n" .. body).validation
		end
		-- Shapes from real worker reports: sub-headed sections were rejected as turn-ended-no-report.
		Test.eq(
			validation(
				"## Validation\n\n### E1: fresh source and pre-commit preparation\n\nUsed a fresh copy.\n\n## Notes\nn"
			),
			true
		)
		Test.eq(
			validation(
				"## Validation\n\n### Install and packaged notes\n\n- `bun install --ignore-scripts`: passed\n\n## Docs\nnone"
			),
			true
		)
		Test.eq(
			validation("## Validation\n\n- `bun run test:file a.ts` — passed, exit 0.\n\n## Notes\nn"),
			true
		)
		Test.eq(validation("## Validation\n\n## Notes\nunvalidated"), false)
		Test.eq(validation("## Validation\n\n### Unit\n\n#### Fast\n\n## Notes\nunvalidated"), false)
		Test.eq(validation("## Validation\n\n### Unit\n\nNotes: unvalidated"), false)
		Test.eq(validation("Validation: nvim --clean -l test/run.lua passed\nNotes: n"), true)
	end
)

Test.test("workers pause interrupts with Esc so prompt can resume the ended turn", function()
	local _, state = fake()
	state.start()
	state.hook("UserPromptSubmit")
	state.on_sleep(function()
		if state.enter == "\27" then
			state.native = "idle"
		end
	end)
	local paused = state.run("pause")
	Test.eq(paused.result.status, "paused")
	Test.eq(paused.result.state, "turn-ended-no-report")
	Test.eq(state.enter, "\27")
	Test.eq(state.record().hookState, "idle")
	local resumed = state.run("prompt", { "--text", "continue the task" })
	Test.eq(resumed.result.sent, true)
	Test.eq(state.enter, "\r")
	assert(state.writes[1]:find("[orc-run:" .. resumed.result.runId .. "]", 1, true))
end)

Test.test("workers pause records a manual Esc and refuses dialogs or a busy program", function()
	local _, manual = fake()
	manual.start()
	manual.hook("UserPromptSubmit")
	manual.native = "idle"
	Test.eq(manual.run("prompt", { "--text", "resume" }).result.status, "not-sent")
	Test.eq(manual.run("pause").result.status, "paused")
	Test.eq(manual.enter, nil)
	Test.eq(manual.run("prompt", { "--text", "resume" }).result.sent, true)
	local _, dialog = fake()
	dialog.start()
	dialog.hook("UserPromptSubmit")
	dialog.hook("PermissionRequest")
	Test.eq(dialog.run("pause").result.status, "not-paused")
	Test.eq(dialog.enter, nil)
	Test.eq(dialog.record().hookState, "blocked")
	local _, busy = fake()
	busy.start()
	busy.hook("UserPromptSubmit")
	Test.eq(busy.run("pause").result.status, "not-paused")
	Test.eq(busy.enter, "\27")
	Test.eq(busy.record().hookState, "working")
	local _, permission = fake()
	permission.start()
	permission.hook("UserPromptSubmit")
	permission.on_sleep(function()
		permission.on_sleep(nil)
		permission.hook("PermissionRequest")
	end)
	Test.eq(permission.run("pause").result.status, "not-paused")
	Test.eq(permission.record().hookState, "blocked")
	local _, exec = fake()
	exec.start({ "--transport", "exec" })
	assert(exec.run("pause").result.stderr:find("exec workers cannot be paused", 1, true))
end)

Test.test("workers report wait gives up on an idle turn without a report after grace", function()
	local _, state = fake()
	state.start()
	state.hook("UserPromptSubmit")
	state.hook("Stop")
	state.native = "idle"
	local response = state.run("wait", { "--until", "report", "--timeout", "900000" })
	Test.eq(response.result.state, "turn-ended-no-report")
	assert(response.result.hint:find("orc pane prompt", 1, true))
	assert(state.clock >= 300000 and state.clock < 900000)
end)

Test.test("workers report wait follows a queued run and returns every run's report", function()
	for _, first_report in ipairs({ true, false }) do
		local rt, state = fake()
		state.start()
		state.hook("UserPromptSubmit")
		local first = state.record()
		rt.write(rt.cwd .. "/addendum.md", "Also cover the edge case")
		local queued, step = nil, 0
		state.on_sleep(function()
			step = step + 1
			if step == 1 then
				queued = state.run("prompt", { "--queue", "--file", rt.cwd .. "/addendum.md" }).result
				Test.eq(queued.status, "queued")
				Test.eq(state.enter, "\t")
			elseif step == 2 then
				if first_report then
					rt.write(
						first.report,
						"Run: " .. first.runId .. "\nStatus: done\nValidation:\n- nvim test: pass\n"
					)
				end
				-- The first turn ends, then Codex submits the queued prompt.
				state.hook("Stop")
				Test.eq(state.record().hookState, "pending")
				state.hook("UserPromptSubmit")
			elseif step == 3 then
				state.report()
				state.hook("Stop")
				state.native = "idle"
			end
			state.onEvent('{"type":"block_event"}\n')
		end)
		local response = state.run("wait", { "--until", "report", "--timeout", "10000" })
		Test.eq(response.code, 0)
		Test.eq(response.result.runId, assert(queued).runId)
		Test.eq(response.result.state, "idle")
		Test.eq(response.result.evidence, true)
		Test.eq(response.result.status, "done")
		Test.eq(response.result.previousRuns, {
			{
				runId = first.runId,
				report = first_report and first.report or rt.null,
				status = first_report and "done" or rt.null,
			},
		})
	end
end)

Test.test("workers report wait follows a plain prompt and restarts the no-report grace", function()
	local _, state = fake()
	state.start()
	state.hook("UserPromptSubmit")
	state.hook("Stop")
	state.native = "idle"
	local first = state.record().runId
	local prompted, reported = nil, false
	state.on_sleep(function()
		if not prompted and state.clock >= 290000 then
			prompted = state.run("prompt", { "--text", "write the report" }).result
			Test.eq(prompted.status, "unconfirmed")
			Test.eq(state.record().queued, nil)
			-- The new turn also ends without a report; its grace starts now, not at the first turn.
			state.hook("UserPromptSubmit")
			state.hook("Stop")
		elseif prompted and not reported and state.clock >= 400000 then
			reported = true
			state.report()
			state.onEvent('{"type":"block_event"}\n')
		end
	end)
	local response = state.run("wait", { "--until", "report", "--timeout", "900000" })
	Test.eq(response.result.runId, assert(prompted).runId)
	Test.eq(response.result.evidence, true)
	Test.eq(response.result.previousRuns[1].runId, first)
	assert(state.clock >= 400000 and state.clock < 590000)
end)

Test.test("workers wait follows a run replaced during its own snapshot", function()
	local _, state = fake()
	state.start()
	state.hook("UserPromptSubmit")
	local first = state.record().runId
	state.on_sleep(function()
		state.on_sleep(nil)
		-- The queued prompt lands while the waiter holds a stale snapshot of the first run.
		state.on_lock(function()
			Test.eq(state.run("prompt", { "--queue", "--text", "later" }).result.status, "queued")
		end)
		state.onEvent('{"type":"block_event"}\n')
	end)
	local response = state.run("wait", { "--until", "report", "--timeout", "1000" })
	Test.eq(response.code, 0)
	Test.eq(response.result.state, "timeout")
	Test.eq(response.result.runId, state.record().runId)
	Test.eq(response.result.previousRuns[1].runId, first)
end)

Test.test(
	"workers report wait resets the acknowledgment window for a follow-up during a snapshot",
	function()
		local _, state = fake()
		state.start()
		state.hook("UserPromptSubmit")
		state.hook("Stop")
		state.native = "idle"
		local first = state.record().runId
		local followup_at = 65000
		local followup
		state.on_sleep(function()
			if state.clock == followup_at then
				state.on_lock(function()
					followup = state.run("prompt", { "--text", "later" }).result
					Test.eq(followup.status, "unconfirmed")
					Test.eq(followup.sent, true)
				end)
				state.onEvent('{"type":"block_event"}\n')
			end
		end)
		local response = state.run("wait", { "--until", "report", "--timeout", "130000" }).result
		Test.eq(response.state, "unacknowledged")
		Test.eq(response.runId, followup.runId)
		Test.eq(response.previousRuns[1].runId, first)
		assert(state.clock - followup_at >= 60000 and state.clock < 130000)
	end
)

Test.test("workers plain wait does not call a queued prompt unacknowledged", function()
	local _, state = fake()
	state.start()
	state.hook("UserPromptSubmit")
	Test.eq(state.run("prompt", { "--queue", "--text", "later" }).result.status, "queued")
	Test.eq(state.record().queued, true)
	Test.eq(state.run("wait", { "--timeout", "120000" }).result.state, "timeout")
	-- The first turn ends but the queued prompt never starts (removed from the queue).
	state.native = "done"
	local started = state.clock
	local dropped = state.run("wait", { "--timeout", "120000" }).result
	Test.eq(dropped.state, "unacknowledged")
	assert(state.clock - started > 60000 and state.clock - started < 120000)
	state.hook("UserPromptSubmit")
	Test.eq(state.record().acknowledged, true)
end)

Test.test(
	"workers report wait starts the queued acknowledgment window after the running turn",
	function()
		local rt, state = fake()
		state.start()
		state.hook("UserPromptSubmit")
		local queued = state.run("prompt", { "--queue", "--text", "later" }).result
		Test.eq(queued.status, "queued")
		local turn_end = 75000
		state.on_sleep(function()
			if state.clock == turn_end then
				state.hook("Stop")
				state.native = "idle"
				state.onEvent('{"type":"block_event"}\n')
			end
		end)
		local response = state.run("wait", { "--until", "report", "--timeout", "150000" }).result
		Test.eq(response.state, "unacknowledged")
		Test.eq(response.runId, queued.runId)
		Test.eq(response.report, rt.null)
		Test.eq(response.evidence, false)
		assert(state.clock - turn_end >= 60000 and state.clock < 150000)
	end
)

for _, failure in ipairs({ "statusFail", "processFail" }) do
	Test.test("workers report wait defers queued acknowledgment on " .. failure, function()
		local _, state = fake()
		state.start()
		state.hook("UserPromptSubmit")
		Test.eq(state.run("prompt", { "--queue", "--text", "later" }).result.status, "queued")
		state.on_sleep(function()
			if state.clock == 10000 then
				state.statusFail, state.processFail = failure == "statusFail", failure == "processFail"
				state.onEvent('{"type":"block_event"}\n')
			end
		end)
		local response = state.run("wait", { "--until", "report", "--timeout", "120000" })
		Test.eq(response.result.state, "timeout")
		Test.eq(state.clock, 120000)
	end)
end

for _, mode in ipairs({ "plain", "report" }) do
	Test.test(
		"workers wait timeout includes a queued acknowledgment hint in " .. mode .. " mode",
		function()
			local _, state = fake()
			state.start()
			state.hook("UserPromptSubmit")
			local queued = state.run("prompt", { "--queue", "--text", "later" }).result
			Test.eq(queued.status, "queued")
			state.on_sleep(function()
				if state.clock == 10000 then
					state.hook("Stop")
					state.noRecords = true
					state.onEvent('{"type":"block_event"}\n')
				end
			end)
			local args = { "--timeout", "600000" }
			if mode == "report" then
				vim.list_extend(args, { "--until", "report" })
			end
			local result = state.run("wait", args).result
			Test.eq(result.state, "timeout")
			Test.eq(result.runId, queued.runId)
			Test.eq(state.clock, 600000)
			assert(
				result.hint and result.hint:find("Hook failed", 1, true),
				"missing acknowledgment hint"
			)
		end
	)
end

Test.test("workers keep the previous run's final-message report during a queued run", function()
	local rt, state = fake()
	state.start({ "--role", "scoper" })
	state.hook("UserPromptSubmit")
	local first = state.record()
	Test.eq(state.run("prompt", { "--queue", "--text", "also check b.lua" }).result.status, "queued")
	local stale = "Run: " .. state.record().runId .. "\nStatus: done\nValidation:\n- rg: ok\n"
	state.hook("Stop", { last_assistant_message = stale })
	Test.eq(rt.read(first.report), nil)
	local message = "Run: "
		.. first.runId
		.. "\nStatus: done\nScope: a.lua:1\nValidation:\n- rg: ok\n"
	state.hook("Stop", { last_assistant_message = message })
	Test.eq(rt.read(first.report), message)
	Test.eq(state.record().hookState, "pending")
	Test.eq(rt.read(state.record().report), nil)
end)

Test.test("workers wait failures are JSON with a state and hint, never a traceback", function()
	local rt, state = fake()
	state.start()
	local function failed(response)
		Test.eq(response.code, 1)
		Test.eq(response.result.status, "error")
		Test.eq(response.result.state, "wait-failed")
		assert(response.result.hint:find("orc pane close", 1, true))
		Test.eq(response.result.stderr:find("stack traceback", 1, true), nil)
		return response.result.stderr
	end
	state.on_sleep(function()
		state.on_sleep(nil)
		state.instance = "restarted"
		state.onEvent('{"type":"block_event"}\n')
	end)
	local restarted = failed(state.run("wait", { "--until", "report", "--timeout", "1000" }))
	assert(restarted:find("Rex server identity changed", 1, true))
	state.instance = "instance"
	local file = state.file()
	state.on_sleep(function()
		state.on_sleep(nil)
		rt.remove(file)
	end)
	assert(failed(state.run("wait", { "--timeout", "1000" })):find("record disappeared", 1, true))
	assert(failed(state.run("wait")):find("worker not found", 1, true))
	Test.eq(state.run("close").result.state, nil)
end)

-- A ready TUI worker in a real temporary repository, so review fingerprints run real Git.
local function review_fixture(kind)
	local rt, state = fake()
	local git_rt, exec = runtime.new({ cwd = rt.cwd }), rt.exec
	local function git(...)
		local done = git_rt.exec({ "git", ... })
		assert(done.code == 0, done.stderr)
		return done.stdout
	end
	git("init", "-q", "-b", "main")
	git("config", "user.name", "test")
	git("config", "user.email", "test@example.invalid")
	git("config", "commit.gpgsign", "false")
	rt.write(rt.cwd .. "/tracked.txt", "base\n")
	git("add", "-A")
	git("commit", "-q", "-m", "fixture")
	rt.exec = function(argv, opts)
		if argv[1] == "git" then
			if argv[2] == state.failGit then
				return { code = 1, signal = 0, stdout = "", stderr = "broken " .. argv[2] }
			end
			return git_rt.exec(argv, opts)
		end
		return exec(argv, opts)
	end
	state.processName = kind or "codex"
	Test.eq(
		workers.run(rt, {
			"start",
			"feature",
			"task",
			"--path",
			rt.cwd,
			"--brief",
			"brief.md",
			"--kind",
			state.processName,
		}).code,
		0
	)
	state.hook("UserPromptSubmit")
	state.hook("Stop")
	state.native = "idle"
	return rt, state, git
end

Test.test(
	"workers close accepts a fresh pinned independent review for the current checkout",
	function()
		local rt, state = review_fixture()
		local args = { "--review", ".scratch/review.md" }
		state.report()
		local next_step = state.run("wait", { "--until", "report", "--timeout", "0" }).result.next
		assert(next_step:find("orc pane review task", 1, true))
		assert(next_step:find("orc pane review-begin task", 1, true))
		assert(next_step:find("--review <saved report>", 1, true))
		local pin = state.run("review-begin", args).result
		local report_path = rt.cwd .. "/.scratch/review.md"
		Test.eq(
			{ pin.status, pin.report, pin.runId },
			{ "review-pinned", report_path, state.record().runId }
		)
		rt.write(report_path, "Independent review: accepted\n")
		Test.eq(state.record().reviewed, nil)
		state.closeFail = true
		Test.eq(state.run("close", args).code, 1)
		Test.eq(state.record().reviewed, nil)
		Test.eq(state.record().reviewPin.runId, pin.runId)
		state.closeFail = false
		Test.eq(state.run("close", { "--review", report_path }).result.status, "closed")
		Test.eq(state.closed, { "block:worker" })
		local record = state.record()
		Test.eq(record.reviewed.report, report_path)
		Test.eq(record.reviewed.runId, pin.runId)
		Test.eq(#record.reviewed.baseline, 64)
		-- Reopening only the fake record checks that the saved baseline matches and detects edits.
		record.state = "idle"
		state.store(record)
		rt.write(rt.cwd .. "/tracked.txt", "changed after review\n")
		local refused = state.run("close")
		Test.eq({ refused.code, refused.result.status }, { 1, "not-reviewed" })
		assert(
			refused.result.stderr:find(
				"checkout changed after saved review " .. record.reviewed.report,
				1,
				true
			)
		)
		rt.write(rt.cwd .. "/tracked.txt", "base\n")
		Test.eq(state.run("close").result.status, "closed")
	end
)

Test.test("workers close refuses missing empty and unreadable saved reviews", function()
	local rt, state = review_fixture()
	local read = rt.read
	rt.read = function(file)
		if file == rt.cwd .. "/.scratch/unreadable.md" then
			return nil, "permission denied"
		end
		return read(file)
	end
	for _, case in ipairs({
		{ "missing.md", "cannot read review report" },
		{ "empty.md", "review report is empty", " \n" },
		{ "unreadable.md", "permission denied", "Accepted\n" },
	}) do
		local file = ".scratch/" .. case[1]
		Test.eq(state.run("review-begin", { "--review", file }).code, 0)
		if case[3] then
			rt.write(rt.abspath(file), case[3])
		end
		for _, force in ipairs({ {}, { "--force" } }) do
			local args = { "--review", file }
			vim.list_extend(args, force)
			local refused = state.run("close", args)
			Test.eq({ refused.code, refused.result.status }, { 1, "not-reviewed" })
			assert(refused.result.stderr:find(case[2], 1, true))
			Test.eq(state.record().reviewed, nil)
			Test.eq(state.record().state ~= "closed", true)
			Test.eq(#state.closed, 0)
		end
	end
	local args = { "--review", ".scratch/review.md" }
	Test.eq(state.run("review-begin", args).code, 0)
	rt.write(rt.abspath(args[2]), "Accepted\n")
	state.failGit = "status"
	local failed = state.run("close", args)
	Test.eq({ failed.code, failed.result.status }, { 1, "not-reviewed" })
	assert(failed.result.stderr:find("git status failed", 1, true))
	Test.eq(#state.closed, 0)
end)

Test.test("workers reject stale review evidence after the final Rex identity read", function()
	for _, change in ipairs({
		{
			file = "tracked.txt",
			text = "edited during Rex ownership check\n",
			reason = "checkout changed",
		},
		{ file = ".scratch/review.md", text = "", reason = "review report is empty" },
	}) do
		local rt, state = review_fixture()
		local args = { "--review", ".scratch/review.md" }
		Test.eq(state.run("review-begin", args).code, 0)
		rt.write(rt.abspath(args[2]), "Accepted\n")
		local exec, identities = rt.exec, 0
		rt.exec = function(argv, opts)
			if argv[2] == "whoami" then
				identities = identities + 1
				if identities == 2 then
					rt.write(rt.abspath(change.file), change.text)
				end
			end
			return exec(argv, opts)
		end
		local refused = state.run("close", args)
		Test.eq(identities, 2)
		Test.eq({ refused.code, refused.result.status }, { 1, "not-reviewed" })
		assert(refused.result.stderr:find(change.reason, 1, true))
		assert(refused.result.stderr:find("orc pane review-begin", 1, true))
		Test.eq(state.closed, {})
		Test.eq(state.record().reviewed, nil)
	end
end)

Test.test("workers reject stale reviews after an index-only edit to an MM file", function()
	local rt, state, git = review_fixture()
	local tracked = rt.abspath("tracked.txt")
	local args = { "--review", ".scratch/review.md" }
	rt.write(tracked, "staged first\n")
	git("add", "--", "tracked.txt")
	rt.write(tracked, "same working file\n")
	local status = git("status", "--porcelain=v1", "-z")
	local combined = git("diff", "--binary", "HEAD")
	local staged = git("diff", "--cached", "--binary", "HEAD")
	Test.eq(status, "MM tracked.txt\0")
	Test.eq(state.run("review-begin", args).code, 0)
	rt.write(rt.abspath(args[2]), "Accepted\n")

	rt.write(tracked, "staged second\n")
	git("add", "--", "tracked.txt")
	rt.write(tracked, "same working file\n")
	Test.eq(git("status", "--porcelain=v1", "-z"), status)
	Test.eq(git("diff", "--binary", "HEAD"), combined)
	assert(git("diff", "--cached", "--binary", "HEAD") ~= staged)
	local refused = state.run("close", args)
	Test.eq({ refused.code, refused.result.status }, { 1, "not-reviewed" })
	assert(refused.result.stderr:find("checkout changed after review-begin", 1, true))
	Test.eq(state.closed, {})
	Test.eq(state.record().reviewed, nil)
end)

Test.test(
	"workers reject a preexisting report, stale content and pins for another path, diff or run",
	function()
		local rt, state = review_fixture()
		local old = { "--review", ".scratch/old.md" }
		local args = { "--review", ".scratch/review.md" }
		local file = rt.abspath(args[2])
		rt.write(rt.abspath(old[2]), "Old review\n")
		assert(state.run("review-begin", old).result.stderr:find("must be a new file", 1, true))
		assert(vim.uv.fs_symlink("absent.md", rt.abspath(".scratch/link.md")))
		assert(
			state
				.run("review-begin", { "--review", ".scratch/link.md" }).result.stderr
				:find("must be a new file", 1, true)
		)
		local function refuse(which, reason)
			local response = state.run("close", which)
			Test.eq({ response.code, response.result.status }, { 1, "not-reviewed" })
			assert(response.result.stderr:find(reason, 1, true), response.result.stderr)
			assert(response.result.stderr:find("orc pane review-begin", 1, true))
			Test.eq(state.record().reviewed, nil)
			Test.eq(state.closed, {})
		end
		refuse(old, "no independent review pinned for the current run")
		Test.eq(state.run("review-begin", args).code, 0)
		refuse(old, "differs from the pinned path")
		assert(vim.uv.fs_symlink(rt.abspath(old[2]), file))
		refuse(args, "review report must be a regular file")
		assert(vim.uv.fs_unlink(file))
		assert(vim.uv.fs_rename(rt.abspath(old[2]), file))
		assert(vim.uv.fs_utime(file, 1, 1))
		refuse(args, "review report predates the pin")
		rt.write(file, "Fresh review\n")
		rt.write(rt.cwd .. "/tracked.txt", "new implementation\n")
		refuse(args, "checkout changed after review-begin")
		rt.write(rt.cwd .. "/tracked.txt", "base\n")
		local old_pin = state.record().reviewPin
		Test.eq(state.run("prompt", { "--text", "follow up" }).result.sent, true)
		local record = state.record()
		Test.eq(record.reviewPin, nil)
		record.reviewPin = old_pin
		state.store(record)
		refuse(args, "no independent review pinned for the current run")
	end
)

Test.test("workers review pin and hook or snapshot writes preserve each other's state", function()
	local rt, state = review_fixture()
	local first = { "--review", ".scratch/first.md" }
	local second = { "--review", ".scratch/second.md" }
	local third = { "--review", ".scratch/third.md" }
	state.on_lock(function()
		state.hook("PermissionRequest")
	end)
	Test.eq(state.run("review-begin", first).code, 0)
	Test.eq(state.record().hookState, "blocked")
	Test.eq(state.record().reviewPin.report, rt.abspath(first[2]))
	state.on_lock(function()
		Test.eq(state.run("review-begin", second).code, 0)
	end)
	state.hook("Stop")
	Test.eq(state.record().hookState, "idle")
	Test.eq(state.record().reviewPin.report, rt.abspath(second[2]))
	state.on_lock(function()
		Test.eq(state.run("review-begin", third).code, 0)
	end)
	workers.collect(rt)
	Test.eq(state.record().reviewPin.report, rt.abspath(third[2]))
end)

Test.test("workers expose review-begin and scope the saved review flag", function()
	local _, state = fake()
	state.start()
	assert(
		require("orc.cli").usage:find(
			"pane review-begin <task> --path <dir> --review <new-file>",
			1,
			true
		)
	)
	assert(
		require("orc.completion")
			.fish()
			:find("__fish_seen_subcommand_from review-begin' -l review -r", 1, true)
	)
	Test.eq(state.run("review-begin").code, 1)
	local conflict = state.run("close", { "--review", "review.md", "--no-review" })
	Test.eq(conflict.code, 1)
	assert(conflict.result.stderr:find("--review and --no-review are mutually exclusive", 1, true))
	for _, command in ipairs({ "start", "wait", "prompt", "review", "pause", "prune" }) do
		local refused = state.run(command, { "--review", "review.md" })
		Test.eq(refused.code, 1)
		assert(refused.result.stderr:find("--review only applies to close and review-begin", 1, true))
	end
	Test.eq(#state.closed, 0)
end)

Test.test("workers review frames a read-only reviewer turn per worker kind", function()
	for _, kind in ipairs({ "codex", "claude" }) do
		local rt, state = review_fixture(kind)
		rt.write(rt.path(rt.cwd, ".orc", "validation.md"), "Validate: everything")
		rt.write(rt.cwd .. "/tracked.txt", "changed\n")
		local response = state.run("review").result
		Test.eq(response.sent, true)
		Test.eq(
			{ response.mode, response.skill, response.target },
			{ "review", "ponytail-review", "the uncommitted changes (staged, unstaged and untracked)" }
		)
		local call = kind == "codex" and "Run $ponytail-review"
			or "Use the Skill tool to run ponytail:ponytail-review"
		for _, part in ipairs({
			"[orc-run:" .. response.runId .. "] You are the orc reviewer.",
			"agents/reviewer.md",
			"replaces your implementer role and brief",
			"Do not edit, create, delete or stage files",
			"run no tests",
			call .. " on the uncommitted changes",
			"End your final message with the report; do not write a report file",
			"Findings numbered with file citations",
			"about 60 lines max",
			"cite their paths",
			"For .ts or .tsx changes, also check them against "
				.. rt.path(rt.root, "skills", "typescript-best-practices", "SKILL.md"),
			" When the diff adds or changes tests, also check them against "
				.. rt.path(rt.root, "skills", "test-discipline", "SKILL.md")
				.. ".",
		}) do
			assert(state.writes[1]:find(part, 1, true), part)
		end
		for _, absent in ipairs({
			"Validation profile",
			"Write the final report",
			"Follow-up:",
			"agents/implementer.md",
		}) do
			assert(not state.writes[1]:find(absent, 1, true), absent)
		end
		Test.eq(state.record().review.skill, "ponytail-review")
		Test.eq(#state.record().review.baseline, 64)
	end
end)

Test.test("workers review defaults its target and refuses empty or invalid reviews", function()
	local rt, state, git = review_fixture()
	local clean = state.run("review")
	Test.eq(clean.code, 1)
	assert(clean.result.stderr:find("no uncommitted changes or task commits; pass --target", 1, true))
	for _, args in ipairs({
		{ "--skill", "ponytail-debt" },
		{ "--target", " " },
		{ "--text", "extra" },
		{ "--queue" },
	}) do
		Test.eq(state.run("review", args).code, 1)
	end
	Test.eq(state.run("prompt", { "--text", "x", "--skill", "ponytail-audit" }).code, 1)
	git("checkout", "-q", "-b", "main--task")
	Test.eq(state.run("review").code, 1)
	Test.eq(#state.writes, 0)
	local function ready()
		state.hook("UserPromptSubmit")
		state.hook("Stop")
	end
	local audit = state.run("review", { "--skill", "ponytail-audit" }).result
	Test.eq({ audit.skill, audit.target }, { "ponytail-audit", "the whole repository" })
	assert(state.writes[1]:find("Run $ponytail-audit on the whole repository.", 1, true))
	ready()
	rt.write(rt.cwd .. "/tracked.txt", "task\n")
	git("commit", "-q", "-am", "task work")
	Test.eq(state.run("review").result.target, "the branch diff `git diff main...HEAD`")
	ready()
	Test.eq(state.run("review", { "--target", "src/a.lua" }).result.target, "src/a.lua")
	state.native = "working"
	ready()
	state.hook("UserPromptSubmit")
	Test.eq(state.run("review", { "--target", "x" }).result.status, "not-sent")
	Test.eq(#state.writes, 3)
end)

Test.test("workers review wait reports whether the checkout stayed byte-identical", function()
	local rt, state = review_fixture()
	rt.write(rt.cwd .. "/tracked.txt", "changed\n")
	rt.write(rt.cwd .. "/new file.txt", "draft\n")
	local sent = state.run("review").result
	state.hook("UserPromptSubmit")
	state.hook("Stop", {
		last_assistant_message = "Run: "
			.. sent.runId
			.. "\nStatus: done\nTarget: uncommitted\nFindings: none\nValidation: git diff; no tests ran\nVerdict: Ship.\n",
	})
	local function wait()
		return state.run("wait", { "--timeout", "0" }).result
	end
	local clean = wait()
	Test.eq(
		{ clean.mode, clean.readOnly, clean.evidence, clean.status, clean.violation },
		{ "review", true, true, "done", nil }
	)
	assert(
		clean.next:find("after accepting the review verdict: orc pane close task --path '", 1, true)
	)
	rt.write(rt.cwd .. "/new file.txt", "edited\n")
	local edited = wait()
	Test.eq({ edited.readOnly, edited.next }, { false, nil })
	assert(edited.violation:find("checkout changed during review run " .. sent.runId, 1, true))
	rt.write(rt.cwd .. "/new file.txt", "draft\n")
	Test.eq(wait().readOnly, true)
	state.failGit = "diff"
	local broken = wait()
	Test.eq(broken.readOnly, false)
	assert(broken.violation:find("git diff failed: broken diff", 1, true))
	state.failGit = nil
	Test.eq(state.run("prompt", { "--text", "fix finding 1" }).result.sent, true)
	Test.eq(state.record().review, nil)
	assert(state.writes[2]:find("You are the orc implementer.", 1, true))
	state.hook("UserPromptSubmit")
	state.report()
	state.hook("Stop")
	local normal = wait()
	Test.eq(normal.mode, nil)
	assert(normal.next:find("orc pane review task", 1, true))
	-- The done review survives the follow-up run and still matches an unchanged checkout.
	Test.eq(state.record().reviewed.runId, sent.runId)
	-- A git failure refuses without the --force advice that would strand the live pane.
	state.failGit = "status"
	local unchecked = state.run("close")
	Test.eq({ unchecked.code, unchecked.result.status }, { 1, "not-reviewed" })
	for _, part in ipairs({
		"orc pane close: cannot compare the checkout with its review: ",
		"orc pane: git status failed: broken status; inspect git status in ",
	}) do
		assert(unchecked.result.stderr:find(part, 1, true), part)
	end
	assert(not unchecked.result.stderr:find("--force", 1, true))
	Test.eq(state.record().state ~= "closed", true)
	state.failGit = nil
	rt.write(rt.cwd .. "/tracked.txt", "fixed\n")
	local changed = state.run("close")
	Test.eq({ changed.code, changed.result.status }, { 1, "not-reviewed" })
	assert(
		changed.result.stderr:find("checkout changed after self-review run " .. sent.runId, 1, true)
	)
	Test.eq(state.record().state ~= "closed", true)
	rt.write(rt.cwd .. "/tracked.txt", "changed\n")
	Test.eq(state.run("close").result.status, "closed")
end)

Test.test("workers review gate skips scopers exec workers and blocked reviews", function()
	for _, field in ipairs({ "role", "transport" }) do
		local _, state = fake()
		state.start()
		state.hook("UserPromptSubmit")
		state.report()
		state.hook("Stop")
		state.native = "idle"
		local record = state.record()
		record[field] = field == "role" and "scoper" or "exec"
		state.store(record)
		local waited = state.run("wait", { "--until", "report", "--timeout", "0" }).result
		assert(waited.next:find("after accepting the report: orc pane close task", 1, true), field)
		Test.eq(state.run("close").result.status, "closed")
	end
	local _, state = fake()
	state.start()
	state.hook("UserPromptSubmit")
	state.report()
	state.hook("Stop")
	state.native = "idle"
	state.run("review")
	state.hook("UserPromptSubmit")
	state.report("blocked")
	state.hook("Stop")
	Test.eq(state.run("wait", { "--timeout", "0" }).result.next, nil)
	Test.eq(state.run("close").result.status, "not-reviewed")
	Test.eq(state.run("prompt", { "--text", "retry" }).result.sent, true)
	Test.eq(state.record().reviewed, nil)
end)

Test.test("workers accept Rex terminals that set REX_BLOCK without REX_SESSION", function()
	local rt, state = fake()
	rt.env.REX_SESSION = nil
	state.whoamiSession = "session:resolved"
	Test.eq(state.start().code, 0)
	local record = state.record()
	Test.eq(record.sessionId, "session:resolved")
	local launched = false
	for _, call in ipairs(state.calls) do
		launched = launched
			or (call.opts.stdin or ""):find("REX_SESSION=session:resolved", 1, true) ~= nil
	end
	assert(launched, "worker launch env must carry the resolved REX_SESSION")
	local ok = state.hook("UserPromptSubmit", nil, { REX_SESSION = false })
	Test.eq(ok.code, 0)
	Test.eq(state.record().acknowledged, true)
	local function hook_env(env)
		return vim.tbl_extend("force", {}, rt, {
			env = vim.tbl_extend(
				"force",
				{},
				rt.env,
				{ ORC_ROLE = "implementer", ORC_WORKER_FILE = state.file() },
				env
			),
		})
	end
	Test.raises("block identity", function()
		workers.event(hook_env({ REX_BLOCK = "block:other" }), { hook_event_name = "Stop" })
	end)
	Test.raises("block identity", function()
		workers.event(
			hook_env({ REX_BLOCK = record.blockId, REX_SESSION = "session:wrong" }),
			{ hook_event_name = "Stop" }
		)
	end)
	Test.eq(
		workers.event(
			hook_env({ REX_BLOCK = record.blockId, REX_SESSION = record.sessionId }),
			{ hook_event_name = "Stop" }
		).code,
		0
	)
end)
