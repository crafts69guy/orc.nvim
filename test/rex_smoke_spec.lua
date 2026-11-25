local cli = require("orc.cli")
local runtime = require("orc.runtime")
local root = runtime.new().root
local script = vim.fs.joinpath(root, "evals", "rex-smoke.lua")

local function smoke(args, rt, globals)
	local argv = vim.list_extend({ [0] = script }, args)
	local env =
		vim.tbl_extend("force", { arg = argv, package = { path = package.path } }, globals or {})
	return setfenv(assert(loadfile(script)), setmetatable(env, { __index = _G }))(rt)
end

local function change_record(rt, file, fields)
	local record = rt.decode((assert(rt.read(file))))
	rt.write(file, rt.encode(vim.tbl_extend("force", record, fields)))
end

local function intercept_cli(reply)
	return function(name)
		if name ~= "orc.cli" then
			return require(name)
		end
		return {
			run = function(rt, args, input)
				local result = cli.run(rt, args, input)
				reply(rt, args, result)
				return result
			end,
		}
	end
end

Test.test("Rex smoke rejects invalid arguments and requires a local anchor", function()
	Test.raises("usage: rex%-smoke.lua", function()
		smoke({ "--invalid" })
	end)
	Test.raises("usage: rex%-smoke.lua", function()
		smoke({ "--self-check", "extra" })
	end)
	for _, args in ipairs({
		{ "--transport" },
		{ "--transport", "unknown" },
		{ "--transport", "tui", "--transport", "exec" },
		{ "--self-check", "--self-check" },
	}) do
		Test.raises("usage: rex%-smoke.lua", function()
			smoke(args)
		end)
	end
	local rt = runtime.new({ env = { REX_SESSION = false, REX_BLOCK = false } })
	Test.raises("run from a local Rex terminal", function()
		smoke({ "--transport", "exec" }, rt)
	end)
	rt.env.REX_SESSION = "session:fixture"
	Test.raises("run from a local Rex terminal", function()
		smoke({}, rt)
	end)
	rt.env.REX_BLOCK = ""
	Test.raises("run from a local Rex terminal", function()
		smoke({}, rt)
	end)
end)

Test.test("Rex smoke fake Codex emits NDJSON and writes a matching report via hooks", function()
	local path = assert(vim.uv.fs_realpath(Test.temp()))
	local rt = runtime.new({
		env = {
			ORC = "1",
			ORC_ROLE = "implementer",
			REX_SESSION = "session:fixture",
			REX_BLOCK = "block:fixture",
		},
	})
	local repo, checkout = rt.path(path, "repo"), rt.path(path, "worktree")
	local task, run_id = "fake", "fake-run"
	local worker =
		rt.path(repo, ".orc", "workers", vim.fn.sha256(checkout .. "\0" .. task) .. ".json")
	local report = rt.path(checkout, "report.md")
	rt.env.ORC_WORKER_FILE = worker
	rt.write(
		worker,
		rt.encode({
			runId = run_id,
			root = repo,
			path = checkout,
			task = task,
			feature = "rex-smoke",
			sessionId = rt.env.REX_SESSION,
			blockId = rt.env.REX_BLOCK,
			hostId = "host",
			instanceId = "instance",
			kind = "codex",
			transport = "exec",
			state = "unconfirmed",
			report = report,
		})
	)
	local output, flushed = {}, 0
	local globals = {
		io = {
			write = function(line)
				output[#output + 1] = rt.decode(line)
			end,
			stdout = {
				flush = function()
					flushed = flushed + 1
				end,
			},
		},
	}
	smoke({ "--fake-codex", "mcp", "list", "--json" }, rt, globals)
	Test.eq(output, { {} })
	for _, args in ipairs({
		{ "mcp", "add", "--json" },
		{ "mcp", "list" },
		{ "--no-daemon", "resume" },
		{
			"--no-daemon",
			"exec",
			"--text",
		},
	}) do
		Test.raises("assertion failed", function()
			smoke(vim.list_extend({ "--fake-codex" }, args), rt, globals)
		end)
	end
	local args = { "--fake-codex", "--no-daemon", "exec", "--json", "[orc-run:wrong] work" }
	Test.raises("assertion failed", function()
		smoke(args, rt, globals)
	end)
	Test.eq(rt.exists(report), false)
	Test.eq(rt.decode((assert(rt.read(worker)))).acknowledged, nil)
	rt.write(rt.path(path, "release"), "go\n")
	args[5] = "[orc-run:" .. run_id .. "] work"
	smoke(args, rt, globals)
	Test.eq(flushed, 1)
	Test.eq(output[2], { type = "thread.started", thread_id = "rex-smoke" })
	Test.eq(output[3], { type = "turn.completed", usage = { input_tokens = 0, output_tokens = 0 } })
	local ended = rt.decode((assert(rt.read(worker))))
	Test.eq({ ended.acknowledged, ended.reportStatus }, { true, "done" })
	assert(assert(rt.read(report)):find("Run: " .. run_id, 1, true))
end)

Test.test("Rex smoke self-check exercises the real worker runner offline", function()
	smoke({ "--self-check" }, runtime.new(), {
		print = function(message)
			Test.eq(message, "Rex smoke self-check passed")
		end,
	})
end)

Test.test("Rex smoke TUI self-check reads split paste markers, Tab and Enter on a PTY", function()
	smoke({ "--self-check", "--transport", "tui" }, runtime.new(), {
		print = function(message)
			Test.eq(message, "Rex smoke self-check passed")
		end,
	})
end)

local function tui_input(waits)
	local dir = Test.temp()
	local worker = vim.fs.joinpath(dir, "worker.json")
	local rt = runtime.new({ env = { ORC_WORKER_FILE = worker } })
	rt.write(worker, rt.encode({ runId = "first", root = rt.path(dir, "repo") }))
	local read, closed
	local events = {}
	local tty = {
		set_mode = function()
			return 0
		end,
		read_start = function(_, fn)
			read = fn
			return 0
		end,
		read_stop = function() end,
		close = function()
			closed = true
		end,
	}
	local ok, err = pcall(smoke, { "--fake-codex-tui", "--no-daemon", "[orc-run:first] Start" }, rt, {
		io = { write = function() end, stdout = { flush = function() end } },
		vim = setmetatable({
			uv = setmetatable({
				new_tty = function()
					return tty
				end,
			}, { __index = vim.uv }),
			wait = function(_, predicate)
				for _, step in ipairs(assert(table.remove(waits, 1))) do
					if step == "release" then
						rt.write(rt.path(dir, "release"), "go\n")
					elseif step == false then
						read(nil, nil)
					elseif step == "read error" then
						read("fixture read failed", nil)
					else
						read(nil, step)
					end
					if predicate() then
						return true
					end
				end
				return false
			end,
		}, { __index = vim }),
		require = function(name)
			Test.eq(name, "orc.cli")
			return {
				run = function(_, args, input)
					Test.eq(args, { "hook", "worker-event" })
					local event = rt.decode(input)
					local text = event.prompt or event.last_assistant_message
					events[#events + 1] = { event.hook_event_name, text:match("^[^\n]+") }
					return { code = 0 }
				end,
			}
		end,
	})
	assert(closed and #waits == 0)
	return ok, err, events
end

Test.test("Rex smoke TUI waits for release and orders the three hook pairs", function()
	local ok, err, events = tui_input({
		{ "\27[20", "0~[orc-run:queued] Tab\27[201~\t", "release" },
		{ "[orc-run:enter] Enter\r" },
		{ false },
	})
	assert(ok, err)
	Test.eq(events, {
		{ "UserPromptSubmit", "[orc-run:first] Start" },
		{ "Stop", "Run: first" },
		{ "UserPromptSubmit", "[orc-run:queued] Tab" },
		{ "Stop", "Run: queued" },
		{ "UserPromptSubmit", "[orc-run:enter] Enter" },
		{ "Stop", "Run: enter" },
	})
end)

Test.test("Rex smoke TUI closes its raw input on EOF or input failure", function()
	local ok, err = tui_input({ { false } })
	assert(ok, err)
	ok, err = tui_input({ { "release", "[orc-run:queued] Tab\t" }, { false } })
	assert(ok, err)
	for _, case in ipairs({
		{ { "read error" }, "fixture read failed" },
		{ { "[orc-run:queued] Wrong key\r" }, "wrong submit key" },
		{ { "no marker\t", "release" }, "received no run marker" },
		{ { "[orc-run:queued] Unreleased\t" }, "did not receive or release its follow-up" },
	}) do
		ok, err = tui_input({ case[1] })
		assert(not ok and err:find(case[2], 1, true), err)
	end
end)

Test.test("Rex smoke self-check rejects inconsistent worker state and interruption", function()
	for _, fields in ipairs({
		{ acknowledged = false },
		{ reportStatus = "blocked" },
		{ threadId = "another-thread" },
	}) do
		Test.raises("assertion failed", function()
			smoke({ "--self-check" }, runtime.new(), {
				require = intercept_cli(function(rt, args, result)
					Test.eq({ args[1], result.code }, { "worker-run", 0 })
					change_record(rt, args[2], fields)
				end),
			})
		end)
	end

	local exiting = runtime.new()
	exiting.stream = function(_, opts)
		vim.schedule(function()
			assert(opts.on_exit)({ code = 1, signal = 0, stdout = "", stderr = "" })
		end)
		return { stop = function() end }
	end
	Test.raises("exit = ", function()
		smoke({ "--self-check" }, exiting)
	end)

	local stopped = false
	local rt = runtime.new()
	rt.stream = function()
		return {
			stop = function()
				stopped = true
			end,
		}
	end
	Test.raises("event stream interruption failed {}", function()
		smoke({ "--self-check" }, rt, {
			vim = setmetatable({
				defer_fn = function() end,
				wait = function(timeout, done)
					Test.eq({ timeout, done() }, { 2000, false })
					return false
				end,
			}, { __index = vim }),
		})
	end)
	Test.eq(stopped, true)
end)

local function fake_rex(options)
	local temp = assert(vim.uv.fs_realpath(Test.temp()))
	local session = "session:fixture"
	local rt = runtime.new({
		env = {
			REX_SESSION = not options.session_from_whoami and session,
			REX_BLOCK = "block:anchor",
			GIT_DIR = "/must-not-use",
		},
	})
	local state = { watches = 0, stops = 0, probes = 0, closes = 0 }
	local parent, worker, launch, receive, exited
	local native, active, pasted, queued
	local anchor = { block_id = rt.env.REX_BLOCK, host_id = "host" }
	local owned = { block_id = "block:worker", host_id = "host" }
	local exec, stream = rt.exec, rt.stream

	-- Use an executable sentinel so normal Rex resolution runs with no real Rex on PATH.
	local sentinel = rt.path(temp, "rex")
	rt.write(sentinel, "#!/bin/sh\nexit 125\n")
	assert(vim.uv.fs_chmod(sentinel, 448))

	local now, timers = 0, {}
	local function defer(callback, delay)
		timers[#timers + 1] = { callback = callback, at = now + delay }
		table.sort(timers, function(a, b)
			return a.at < b.at
		end)
	end
	rt.clock = function()
		return now
	end
	local function tui_hook(input)
		local worker_rt = vim.tbl_extend("force", {}, rt, {
			env = vim.tbl_extend("force", rt.env, {
				ORC = "1",
				ORC_ROLE = "implementer",
				ORC_WORKER_FILE = worker,
				REX_BLOCK = owned.block_id,
				REX_SESSION = session,
			}),
		})
		local result = cli.run(worker_rt, { "hook", "worker-event" }, rt.encode(input))
		assert(result.code == 0, result.err)
	end
	local function submit_tui(prompt)
		active = assert(prompt:match("^%[orc%-run:([%w%-]+)%]"))
		native = "working"
		tui_hook({ hook_event_name = "UserPromptSubmit", prompt = prompt })
	end
	local function stop_tui()
		tui_hook({
			hook_event_name = "Stop",
			last_assistant_message = "Run: " .. active .. "\nStatus: done\n\n## Validation\nFake Rex\n",
		})
		native = "idle"
	end
	rt.sleep = function(ms)
		now = now + ms
		while timers[1] and timers[1].at <= now do
			table.remove(timers, 1).callback()
		end
		if options.tui and not options.no_ack and launch and not native then
			submit_tui(launch.command[#launch.command])
		elseif queued and rt.exists(rt.path(parent, "release")) then
			stop_tui()
			submit_tui(queued)
			queued = nil
			stop_tui()
			receive('{"type":"block_event"}\n')
		end
	end
	local function finish_worker()
		local command = launch.command
		Test.eq(
			vim.list_slice(command, #command - 2),
			{ rt.path(root, "bin", "orc"), "worker-run", worker }
		)
		assert(vim.tbl_contains(command, "ORC_WORKER_FILE=" .. worker))
		assert(vim.tbl_contains(command, "PATH=" .. rt.path(parent, "bin")))
		local worker_rt = runtime.new({
			root = root,
			cwd = launch.cwd,
			env = vim.tbl_extend("force", rt.env, {
				ORC_WORKER_FILE = worker,
				REX_BLOCK = owned.block_id,
				REX_SESSION = session,
			}),
		})
		worker_rt.stream = rt.stream
		local result = cli.run(worker_rt, { "worker-run", worker })
		assert(result.code == 0, result.err)
		exited = true
	end
	local function response(value, err)
		return { code = err and 1 or 0, stdout = rt.encode(value), stderr = err or "", signal = 0 }
	end
	rt.exec = function(argv, opts)
		if vim.fs.basename(argv[1]) ~= "rex" then
			if argv[1] == "git" and argv[2] == "init" then
				parent = vim.fs.dirname(argv[#argv])
				Test.eq(rt.env.GIT_DIR, nil)
				if options.fixture_error then
					return response({}, "fixture refused")
				end
			end
			return exec(argv, opts)
		end
		Test.eq(argv[2], "--autostart=false")
		if argv[3] == "whoami" then
			return response({
				endpoint = "unix:///fixture",
				host_id = options.identity_changed and state.closes > 0 and "different" or "host",
				instance_id = "instance",
				session_id = options.session_from_whoami and session or nil,
			})
		elseif argv[3] == "block" then
			Test.eq({ argv[6], argv[8] }, { session, owned.block_id })
			if options.tui then
				local process = { pid = 42, name = "codex", cwd = launch.cwd }
				if argv[9] == "process" then
					return response({ child = process, foreground = process })
				elseif argv[9] == "write" then
					local key = rt.decode(opts.stdin).data
					state.keys = (state.keys or "") .. key
					if native == "working" then
						Test.eq(key, "\t")
						Test.eq(rt.exists(rt.path(parent, "release")), false)
						queued = assert(pasted)
					else
						Test.eq({ native, key }, { "idle", "\r" })
						submit_tui(assert(pasted))
						stop_tui()
					end
					pasted = nil
					return response({})
				end
				Test.eq(argv[9], "program_status")
				return response({
					records = native and { { app = "codex", state = native, owner = process } } or {},
				})
			end
			if argv[9] == "process" then
				return response(exited and { last_exit = { exit_code = 0 } } or {
					child = { pid = 42, name = "nvim" },
				})
			end
			Test.eq(argv[9], "program_status")
			return response({ records = {} })
		end
		Test.eq({ argv[3], argv[4] }, { "api", "call" })
		local method = argv[5] == "-s" and argv[7] or argv[5]
		local input = rt.decode(opts.stdin)
		if method == "block_creator.list" then
			return response({ creators = { { name = "com.superlogical.terminal", host_id = "host" } } })
		end
		Test.eq(argv[6], session)
		if method == "session.list_blocks" then
			if options.invalid_blocks and state.closes > 0 then
				return response({ blocks = { "malformed block" } })
			end
			local blocks = { anchor }
			if launch and (state.closes == 0 or options.leaves_pane) then
				blocks[2] = owned
			end
			return response({ blocks = blocks })
		elseif method == "session.new_window" then
			Test.eq(input.focus, false)
			owned.label = input.layout.block.label
			owned.flavor = input.layout.block.flavor
			owned.creator_name = "com.superlogical.terminal"
			launch = input.layout.block.options
			assert(vim.tbl_contains(launch.command, "REX_SESSION=" .. session))
			if options.tui then
				for _, arg in ipairs(launch.command) do
					worker = worker or arg:match("^ORC_WORKER_FILE=(.+)$")
				end
				assert(worker, "TUI launch is missing the worker file")
				assert(vim.tbl_contains(launch.command, "--no-daemon"))
			else
				worker = launch.command[#launch.command]
			end
			return response(options.no_owned_block and {} or { block_ids = { owned.block_id } })
		elseif method == "block.event" then
			assert(options.tui)
			Test.eq({ input.block_id, input.event.type }, { owned.block_id, "paste" })
			pasted = input.event.payload.text
			return response({})
		elseif method == "session.set_block_label" then
			Test.eq(input.block_id, owned.block_id)
			state.probes = state.probes + 1
			if state.probes == 1 then
				return response({}, "still subscribing")
			end
			receive('bad json\n42\n{}\n["not an event object"]\n{"type":"session_view')
			Test.eq(rt.exists(rt.path(parent, "release")), false)
			receive('_changed"}\n')
			Test.eq(rt.read(rt.path(parent, "release")), "watch reconnected\n")
			receive('{"type":"extra"}\n')
			finish_worker()
			return response({})
		end
		Test.eq(method, "block.close")
		Test.eq(input.block_id, owned.block_id)
		state.closes = state.closes + 1
		rt.sleep(1500)
		return response({}, options.close_error and "close lost its reply")
	end
	rt.stream = function(argv, opts, on_data)
		if argv[1] == "codex" then
			opts.env = vim.tbl_extend("force", opts.env, { REX_BLOCK = owned.block_id })
			return stream(argv, opts, on_data)
		end
		Test.eq(
			{ vim.fs.basename(argv[1]), argv[2], argv[3], argv[5] },
			{ "rex", "--autostart=false", "events", session }
		)
		state.watches = state.watches + 1
		local watch = state.watches
		if options.tui then
			receive = on_data
		elseif watch == 1 and options.wait_error then
			error("initial watch refused")
		elseif watch == 1 and options.early_exit then
			defer(function()
				assert(opts.on_exit)({ code = 1, signal = 0, stdout = "", stderr = "" })
			end, 1)
		elseif watch == 2 then
			if options.failed_replacement then
				defer(function()
					assert(opts.on_exit)({ code = 1, signal = 0, stdout = "", stderr = "" })
					on_data('{"type":"late"}\n')
				end, 1)
			elseif not options.early_exit then
				receive = on_data
			end
		elseif watch == 3 then
			-- Polling can find a valid report even though the replacement stream failed.
			defer(function()
				local release = rt.path(parent, "release")
				Test.eq(rt.exists(release), false)
				rt.write(release, "fixture completed independently\n")
				finish_worker()
				on_data('{"type":"third-watch"}\n')
			end, 1)
		end
		local stopped = false
		return {
			stop = function()
				if not stopped then
					stopped = true
					state.stops = state.stops + 1
					defer(function()
						assert(opts.on_exit)({ code = 0, signal = 15, stdout = "", stderr = "" })
					end, 0)
				end
			end,
		}
	end

	local path = vim.env.PATH
	local restore_path = Test.replace(vim.env, "PATH", temp .. ":" .. path)
	local ok, err = pcall(smoke, options.tui and { "--transport", "tui" } or {}, rt, {
		vim = setmetatable({ defer_fn = defer }, { __index = vim }),
		require = options.reply and intercept_cli(function(active_rt, args, result)
			if args[2] == options.reply.command then
				options.reply.change(active_rt, result, worker)
			end
		end),
		print = function(message)
			state.message = message
		end,
	})
	local restored_path = vim.env.PATH
	restore_path()
	Test.eq(restored_path, temp .. ":" .. path)
	state.retained = parent ~= nil and rt.exists(parent)
	if state.retained then
		state.record = rt.decode((assert(rt.read(assert(worker)))))
		rt.remove(parent)
	end
	return ok, tostring(err), state
end

Test.test("Rex smoke resolves the session from whoami for both transports", function()
	for _, tui in ipairs({ false, true }) do
		local ok, err, state = fake_rex({ tui = tui, session_from_whoami = true })
		assert(ok, err)
		Test.eq({ state.watches, state.closes, state.retained }, { 2, 1, false })
	end
end)

Test.test("Rex smoke refuses to close a pane outside the session resolved from whoami", function()
	local ok, err, state = fake_rex({
		session_from_whoami = true,
		reply = {
			command = "start",
			change = function(rt, result, worker)
				Test.eq(result.code, 0)
				change_record(rt, worker, { sessionId = "session:other" })
			end,
		},
	})
	assert(not ok and err:find("smoke pane ownership changed", 1, true), err)
	assert(err:find("refusing to close a pane in another Rex session", 1, true), err)
	Test.eq({ state.closes, state.retained }, { 0, true })
end)

Test.test("Rex smoke TUI queues during wait and sends Enter when idle", function()
	local ok, err, state = fake_rex({ tui = true })
	assert(ok, err)
	Test.eq({ state.keys, state.watches, state.closes, state.retained }, { "\t\r", 2, 1, false })
	Test.eq(
		state.message,
		"Rex smoke passed (tui start, ack, queued follow-up, newest run, prompt, close)"
	)
end)

Test.test("Rex smoke TUI closes the owned pane if startup is never acknowledged", function()
	local ok, err, state = fake_rex({ tui = true, no_ack = true })
	assert(not ok and err:find("TUI run was not acknowledged in state working", 1, true), err)
	Test.eq({ state.watches, state.closes, state.retained }, { 0, 1, false })
end)

Test.test("Rex smoke TUI rejects a stale report or missing replaced run", function()
	for _, case in ipairs({
		{
			"TUI wait did not return the acknowledged run's done report",
			function(reply)
				reply.runId = reply.previousRuns[1].runId
				reply.report = reply.previousRuns[1].report
			end,
		},
		{
			"TUI wait did not list the replaced run's done report",
			function(reply)
				reply.previousRuns = {}
			end,
		},
	}) do
		local ok, err, state = fake_rex({
			tui = true,
			reply = {
				command = "wait",
				change = function(rt, result)
					if result.result.previousRuns then
						case[2](result.result)
						result.out = rt.encode(result.result)
					end
				end,
			},
		})
		assert(not ok and err:find(case[1], 1, true), "expected " .. case[1] .. ", got " .. err)
		Test.eq({ state.keys, state.closes, state.retained }, { "\t", 1, false })
	end
end)

Test.test("Rex smoke only releases on a decoded replacement event and verifies close", function()
	local ok, err, state = fake_rex({})
	assert(ok, err)
	Test.eq(
		{ state.watches, state.stops, state.probes, state.closes, state.retained },
		{ 2, 2, 2, 1, false }
	)
	Test.eq(state.message, "Rex smoke passed (start, ack, reconnect, wait, close)")
end)

Test.test("Rex smoke rejects a failed replacement even when polling finds the report", function()
	local ok, err, state = fake_rex({ failed_replacement = true })
	assert(not ok and err:find("replacement watch received no event (watches=3", 1, true), err)
	Test.eq(
		{ state.watches, state.stops, state.probes, state.closes, state.retained },
		{ 3, 3, 0, 1, false }
	)
end)

Test.test("Rex smoke rejects a spontaneous initial watch exit as a reconnect", function()
	local ok, err, state = fake_rex({ early_exit = true })
	assert(not ok and err:find("replacement watch received no event (watches=2", 1, true), err)
	Test.eq({ state.probes, state.closes, state.retained }, { 0, 1, false })
end)

Test.test("Rex smoke recovers from setup and wait errors", function()
	local ok, err, state = fake_rex({ fixture_error = true })
	assert(not ok and err:find("fixture refused", 1, true), err)
	Test.eq({ state.watches, state.closes, state.retained }, { 0, 0, false })
	ok, err, state = fake_rex({ wait_error = true })
	assert(not ok and err:find("initial watch refused", 1, true), err)
	Test.eq({ state.watches, state.closes, state.retained }, { 1, 1, false })
end)

Test.test("Rex smoke rejects mismatched ownership and worker evidence", function()
	for _, case in ipairs({
		{ "start", { pane = vim.NIL }, "no owned pane" },
		{ "start", { runId = "another-run" }, "smoke pane ownership changed" },
		{ "start", { pane = "block:other" }, "smoke pane ownership changed" },
		{ "wait", { runId = "another-run" }, 'runId = "another-run"' },
		{ "wait", { evidence = false }, "evidence = false" },
		{ "close", { status = "pending" }, "close did not confirm ownership" },
	}) do
		local ok, err, state = fake_rex({
			reply = {
				command = case[1],
				change = function(rt, result)
					Test.eq(result.code, 0)
					result.out = rt.encode(vim.tbl_extend("force", result.result, case[2]))
				end,
			},
		})
		assert(not ok and err:find(case[3], 1, true), err)
		Test.eq({ state.closes, state.retained }, { 1, case[1] == "close" })
	end

	for _, fields in ipairs({ { acknowledged = false }, { exitCode = 1 } }) do
		local ok, err, state = fake_rex({
			reply = {
				command = "wait",
				change = function(rt, result, worker)
					Test.eq(result.result.status, "done")
					change_record(rt, worker, fields)
				end,
			},
		})
		assert(not ok and err:find("assertion failed", 1, true), err)
		Test.eq({ state.closes, state.retained }, { 1, false })
	end
end)

Test.test(
	"Rex smoke retains a record that points at the caller and never closes that pane",
	function()
		local ok, err, state = fake_rex({
			reply = {
				command = "start",
				change = function(rt, result, worker)
					Test.eq(result.code, 0)
					local caller = rt.env.REX_BLOCK
					change_record(rt, worker, { blockId = caller })
					result.result.pane = caller
					result.out = rt.encode(result.result)
				end,
			},
		})
		assert(not ok and err:find("refusing to close the caller's Rex pane", 1, true), err)
		Test.eq({ state.closes, state.retained, state.record.blockId }, { 0, true, "block:anchor" })
	end
)

Test.test("Rex smoke retains ownership evidence when cleanup is unconfirmed", function()
	for _, case in ipairs({
		{ { leaves_pane = true }, "the owned pane is still listed after close", "closed" },
		{ { close_error = true }, "close lost its reply", "exited" },
		{ { identity_changed = true }, "Rex server identity changed", "closed" },
		{ { invalid_blocks = true }, "invalid Rex block list", "closed" },
		{ { wait_error = true, leaves_pane = true }, "initial watch refused", "closed" },
		{ { no_owned_block = true }, "no confirmed owned block", "unconfirmed" },
	}) do
		local ok, err, state = fake_rex(case[1])
		assert(not ok and err:find(case[2], 1, true), err)
		assert(err:find("Could not confirm cleanup. Retained ", 1, true), err)
		Test.eq(state.retained, true)
		Test.eq(state.record.state, case[3])
	end
end)
