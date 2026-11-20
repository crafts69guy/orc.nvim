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
	local rt = runtime.new({ env = { REX_SESSION = false, REX_BLOCK = false } })
	Test.raises("run from a local Rex terminal", function()
		smoke({}, rt)
	end)
	rt.env.REX_SESSION = "session:fixture"
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

	local rt = runtime.new()
	rt.stream = function(_, opts)
		vim.schedule(function()
			opts.on_exit({ code = 1, signal = 0 })
		end)
		return { stop = function() end }
	end
	Test.raises("exit = ", function()
		smoke({ "--self-check" }, rt)
	end)

	local stopped = false
	rt = runtime.new()
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
	local rt = runtime.new({
		env = {
			REX_SESSION = "session:fixture",
			REX_BLOCK = "block:anchor",
			GIT_DIR = "/must-not-use",
		},
	})
	local state = { watches = 0, stops = 0, probes = 0, closes = 0 }
	local parent, worker, launch, receive, exited
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
	rt.sleep = function(ms)
		now = now + ms
		while timers[1] and timers[1].at <= now do
			table.remove(timers, 1).callback()
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
			})
		elseif argv[3] == "block" then
			Test.eq({ argv[6], argv[8] }, { rt.env.REX_SESSION, owned.block_id })
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
		Test.eq(argv[6], rt.env.REX_SESSION)
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
			worker = launch.command[#launch.command]
			return response(options.no_owned_block and {} or { block_ids = { owned.block_id } })
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
			{ "rex", "--autostart=false", "events", rt.env.REX_SESSION }
		)
		state.watches = state.watches + 1
		local watch = state.watches
		if watch == 1 and options.wait_error then
			error("initial watch refused")
		elseif watch == 1 and options.early_exit then
			defer(function()
				opts.on_exit({ code = 1, signal = 0 })
			end, 1)
		elseif watch == 2 then
			if options.failed_replacement then
				defer(function()
					opts.on_exit({ code = 1, signal = 0 })
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
						opts.on_exit({ code = 0, signal = 15 })
					end, 0)
				end
			end,
		}
	end

	local path = vim.env.PATH
	vim.env.PATH = temp .. ":" .. path
	local ok, err = pcall(smoke, {}, rt, {
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
	vim.env.PATH = path
	Test.eq(restored_path, temp .. ":" .. path)
	state.retained = rt.exists(assert(parent))
	if state.retained then
		state.record = rt.decode((assert(rt.read(assert(worker)))))
		rt.remove(parent)
	end
	return ok, tostring(err), state
end

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
