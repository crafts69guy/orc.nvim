local script = assert(vim.uv.fs_realpath(arg[0]))
local root = vim.fs.dirname(vim.fs.dirname(script))

-- Specs pass a runtime with fake Rex process effects to the loaded script.
---@type orc.Runtime
local rt = ...
if type(rt) ~= "table" then
	package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
	rt = require("orc.runtime").new({ root = root })
end
local orc = require("orc.cli").run

local function release_file(repo)
	return rt.path(vim.fs.dirname(repo), "release")
end

local function fake_hook(event, fields)
	fields.hook_event_name = event
	local result = orc(rt, { "hook", "worker-event" }, rt.encode(fields))
	assert(result.code == 0, result.err)
end

local function finish_turn(run_id)
	fake_hook("Stop", {
		last_assistant_message = "Run: "
			.. run_id
			.. "\nStatus: done\n\n## Validation\nFake Codex acknowledged this run.\n",
	})
end

local function fake_tui(record, prompt)
	local tty = assert(vim.uv.new_tty(0, true))
	assert(tty:set_mode(1))
	local pending, ended, read_error = "", false, nil
	assert(tty:read_start(function(err, chunk)
		if chunk then
			pending = pending .. chunk
		else
			ended, read_error = true, err
		end
	end))
	local function status(state)
		io.write("\27]7501;state=" .. state .. ":app=codex\27\\")
		io.stdout:flush()
	end
	local function begin_turn(text)
		local run = assert(text:match("^%[orc%-run:([%w%-]+)%]"), "fake TUI received no run marker")
		status("working")
		fake_hook("UserPromptSubmit", { prompt = text })
		return run
	end
	local function receive(key, release)
		local text
		assert(
			vim.wait(25000, function()
				local at = pending:find("[\t\r]")
				if not text and at then
					assert(pending:sub(at, at) == key, "fake TUI received the wrong submit key")
					-- The smoke sends single-line prompts. Buffer through split paste markers.
					text = pending:sub(1, at - 1):gsub("\27%[20[01]~", "")
					pending = pending:sub(at + 1)
				end
				return ended or (text and (not release or rt.exists(release)))
			end, 10),
			"fake TUI did not receive or release its follow-up"
		)
		return not ended and text or nil
	end
	local ok, err = pcall(function()
		io.write("\27[?2004h")
		local first = begin_turn(prompt)
		local queued = receive("\t", release_file(record.root))
		if queued then
			finish_turn(first)
			finish_turn(begin_turn(queued))
			status("idle")
			local immediate = receive("\r")
			if immediate then
				finish_turn(begin_turn(immediate))
				status("idle")
				-- Keep the terminal process alive for pane close to verify ownership.
				vim.wait(25000, function()
					return ended
				end, 25)
			end
		end
	end)
	tty:read_stop()
	tty:set_mode(0)
	tty:close()
	assert(ok, err)
	assert(not read_error, read_error)
end

if arg[1] == "--fake-codex" or arg[1] == "--fake-codex-tui" then
	if arg[2] == "mcp" and arg[3] == "list" and arg[4] == "--json" then
		io.write("[]\n")
		return
	end
	local tui = arg[1] == "--fake-codex-tui"
	assert(arg[2] == "--no-daemon" and (tui or (arg[3] == "exec" and arg[4] == "--json")))
	local worker = assert(rt.env.ORC_WORKER_FILE)
	local record = rt.decode((assert(rt.read(worker))))
	local prompt = arg[#arg]
	assert(prompt:match("^%[orc%-run:([%w%-]+)%]") == record.runId)
	if tui then
		return fake_tui(record, prompt)
	end
	fake_hook("UserPromptSubmit", { prompt = prompt })
	io.write(rt.encode({ type = "thread.started", thread_id = "rex-smoke" }) .. "\n")
	io.stdout:flush()
	assert(
		vim.wait(25000, function()
			return rt.exists(release_file(record.root))
		end, 25),
		"smoke never released the fake worker"
	)
	finish_turn(record.runId)
	io.write(
		rt.encode({ type = "turn.completed", usage = { input_tokens = 0, output_tokens = 0 } }) .. "\n"
	)
	return
end

local offline, transport, index = false, nil, 1
local usage = "usage: rex-smoke.lua [--self-check] [--transport exec|tui]"
while index <= #arg do
	if arg[index] == "--self-check" and not offline then
		offline = true
	else
		assert(arg[index] == "--transport" and not transport, usage)
		index = index + 1
		transport = arg[index]
		assert(transport == "exec" or transport == "tui", usage)
	end
	index = index + 1
end
transport = transport or "exec"
local rex_module = require("orc.rex")
local rex = rex_module.new(rt)
local session
local exec, stream = rt.exec, rt.stream
local function interrupt_stream(argv, opts, on_data, delay)
	local first = {}
	local handle = stream(
		argv,
		vim.tbl_extend("force", opts, {
			on_exit = function(result)
				first.exit = { code = result.code, signal = result.signal }
				opts.on_exit(result)
			end,
		}),
		on_data
	)
	vim.defer_fn(function()
		if not first.exit then
			first.interrupted = true
			handle.stop()
		end
	end, delay)
	return handle, first
end

local function rex_command(argv)
	return vim.list_extend({ rex.binary, "--autostart=false" }, vim.list_slice(argv, 2))
end
if not offline then
	assert(rt.env.REX_BLOCK and rt.env.REX_BLOCK ~= "", "run from a local Rex terminal")
	rt.exec = function(argv, opts)
		return exec(argv[1] == rex.binary and rex_command(argv) or argv, opts)
	end
	session = rex_module.session(rt, rex.identity())
end

local temp = assert(vim.uv.fs_mkdtemp(rt.path(vim.uv.os_tmpdir(), "orc-rex-smoke-XXXXXX")))
local parent = assert(vim.uv.fs_realpath(temp))
local repo, checkout = rt.path(parent, "repo"), rt.path(parent, "worktree")
local task = "smoke-" .. vim.fs.basename(parent)
local worker = rt.path(repo, ".orc", "workers", vim.fn.sha256(checkout .. "\0" .. task) .. ".json")
local brief = rt.path(parent, "brief.md")

local function run(argv)
	local result = rt.exec(argv, { timeout = 10000 })
	assert(result.code == 0, table.concat(argv, " ") .. "\n" .. result.stderr .. result.stdout)
	return result.stdout
end

local function pane(command, ...)
	local args = { "pane", command }
	if command == "start" then
		args[#args + 1] = "rex-smoke"
	end
	vim.list_extend(args, { task, "--path", checkout, ... })
	local result = orc(rt, args)
	assert(result.code == 0, (result.err or "") .. (result.out or ""))
	return rt.decode(result.out)
end

local function fixture()
	for name in pairs(rt.env) do
		if name:match("^GIT_") then
			rt.env[name] = nil
		end
	end
	rt.env.GIT_CONFIG_GLOBAL, rt.env.GIT_CONFIG_NOSYSTEM = "/dev/null", "1"
	rt.env.ORC_INKDROP_MCP_MODE = "inherit"
	rt.mkdir(repo)
	run({ "git", "init", "-q", "--template=", repo })
	run({
		"git",
		"-C",
		repo,
		"-c",
		"user.name=Orc Smoke",
		"-c",
		"user.email=smoke@example.test",
		"-c",
		"commit.gpgsign=false",
		"commit",
		"-qm",
		"Private smoke fixture",
		"--allow-empty",
	})
	run({ "git", "-C", repo, "worktree", "add", "-q", "--detach", checkout })
	rt.write(
		brief,
		"Fake Codex will acknowledge the prompt and write a report through the Stop hook.\n"
	)
	local bin = rt.path(parent, "bin")
	local codex = rt.path(bin, "codex")
	local nvim = assert(vim.uv.fs_realpath(vim.v.progpath))
	local function quote(value)
		return "'" .. value:gsub("'", "'\\''") .. "'"
	end
	local launcher, executable, mode = "#!/bin/sh\n", nvim, "--fake-codex"
	if transport == "tui" then
		local native = rt.path(parent, "libexec", "codex")
		rt.mkdir(vim.fs.dirname(native))
		-- Rex identifies the executable behind exec, so a symlink would report nvim.
		assert(vim.uv.fs_copyfile(nvim, native))
		launcher = launcher .. "export VIMRUNTIME=" .. quote(assert(vim.env.VIMRUNTIME)) .. "\n"
		executable, mode = native, "--fake-codex-tui"
	end
	rt.write(
		codex,
		launcher
			.. "exec "
			.. quote(executable)
			.. " --clean -l "
			.. quote(script)
			.. " "
			.. mode
			.. ' "$@"\n'
	)
	assert(vim.uv.fs_chmod(codex, 448))
	assert(vim.uv.fs_symlink(nvim, rt.path(bin, "nvim")))
	assert(vim.uv.fs_symlink(vim.fn.exepath("git"), rt.path(bin, "git")))
	if not offline then
		assert(vim.uv.fs_symlink(rex.binary, rt.path(bin, "rex")))
	end
	-- libuv can resolve executables using the caller's PATH on macOS.
	vim.env.PATH, rt.env.PATH = bin, bin
	rex = rex_module.new(rt)
	assert(vim.trim(run({ "codex", "mcp", "list", "--json" })) == "[]", "fake Codex lost on PATH")
end

local function record()
	return rt.decode((assert(rt.read(worker))))
end

local function check_server(client, owned)
	local identity = client.identity()
	assert(
		identity.host_id == owned.hostId and identity.instance_id == owned.instanceId,
		"Rex server identity changed"
	)
end

local function confirm_absent(client, owned, session_id)
	assert(type(owned.blockId) == "string" and owned.blockId ~= "", "no confirmed owned block")
	check_server(client, owned)
	local listed = client.call("session.list_blocks", {}, session_id)
	assert(vim.islist(listed.blocks), "Rex returned no block list")
	for _, block in ipairs(listed.blocks) do
		assert(type(block) == "table" and type(block.block_id) == "string", "invalid Rex block list")
		assert(block.block_id ~= owned.blockId, "the owned pane is still listed after close")
	end
end

local function observe_replacement(replacement, release)
	local pending = ""
	return function(chunk)
		if replacement.observed or replacement.exit or replacement.finished then
			return
		end
		pending = pending .. chunk
		if #pending > 1048576 then
			pending = ""
			return
		end
		local lines = vim.split(pending, "\n", { plain = true })
		pending = table.remove(lines)
		for _, line in ipairs(lines) do
			local ok, event = pcall(rt.decode, line)
			if ok and type(event) == "table" and next(event) and not vim.islist(event) then
				release()
				replacement.observed = true
				return
			end
		end
	end
end

local function self_check_tui(env)
	local output = ""
	local job = vim.fn.jobstart(
		{ rt.path(parent, "bin", "codex"), "--no-daemon", "[orc-run:self-check] Start" },
		{
			cwd = checkout,
			clear_env = true,
			env = vim.tbl_extend("force", env, { ORC = "1", ORC_ROLE = "implementer" }),
			pty = true,
			on_stdout = function(_, data)
				output = output .. table.concat(data, "\n")
			end,
		}
	)
	assert(job > 0, "could not start the fake TUI in a local PTY")
	local function await_turn(run_id, state)
		local osc = "\27]7501;state=" .. state .. ":app=codex\27\\"
		assert(
			vim.wait(5000, function()
				local latest = record()
				return vim.deep_equal(
					{ latest.runId, latest.acknowledged, latest.hookState, output:find(osc, 1, true) ~= nil },
					{ run_id, true, state, true }
				)
			end, 10),
			"fake TUI did not acknowledge " .. run_id .. " in state " .. state .. ": " .. output
		)
		output = ""
	end
	local function next_prompt(run_id)
		local latest = record()
		latest.previousRunId, latest.previousReport = latest.runId, latest.report
		latest.runId, latest.report = run_id, rt.path(checkout, ".orc", "reports", run_id .. ".md")
		latest.acknowledged, latest.hookState, latest.reportStatus = false, "pending", nil
		rt.write(worker, rt.encode(latest))
		return "[orc-run:" .. run_id .. "] Follow-up"
	end
	local ok, err = pcall(function()
		await_turn("self-check", "working")
		local prompt = next_prompt("self-check-queued")
		assert(vim.fn.chansend(job, "\27[20") > 0)
		assert(vim.fn.chansend(job, "0~" .. prompt .. "\27[201~\t") > 0)
		rt.write(release_file(repo), "offline\n")
		await_turn("self-check-queued", "idle")
		local latest = record()
		assert(latest.reportStatus == "done", "fake TUI queued report was not done")
		local previous = assert(rt.read(latest.previousReport))
		assert(previous:find("Run: self-check\n", 1, true), "fake TUI lost the first turn's report")
		assert(vim.fn.chansend(job, next_prompt("self-check-enter") .. "\r") > 0)
		await_turn("self-check-enter", "idle")
		assert(record().reportStatus == "done")
	end)
	vim.fn.jobstop(job)
	assert(
		vim.fn.jobwait({ job }, 2000)[1] ~= -1,
		"fake TUI did not exit after closing the local PTY"
	)
	assert(ok, err)
end

local function self_check()
	local report = rt.path(checkout, ".orc", "reports", "self-check.md")
	rt.write(
		worker,
		rt.encode({
			runId = "self-check",
			path = checkout,
			root = repo,
			feature = "rex-smoke",
			task = task,
			sessionId = "fixture-session",
			blockId = "fixture-block",
			kind = "codex",
			transport = transport,
			state = "unconfirmed",
			report = report,
			hostId = "fixture-host",
			instanceId = "fixture-instance",
			brief = brief,
		})
	)
	local opts = {
		root = root,
		cwd = checkout,
		env = vim.tbl_extend("force", rt.env, {
			ORC_WORKER_FILE = worker,
			REX_SESSION = "fixture-session",
			REX_BLOCK = "fixture-block",
		}),
	}
	if transport == "tui" then
		return self_check_tui(opts.env)
	end
	rt.write(release_file(repo), "offline\n")
	local launch_rt = require("orc.runtime").new(opts)
	local result = orc(launch_rt, { "worker-run", worker })
	assert(result.code == 0, result.err)
	local ended = record()
	assert(ended.acknowledged and ended.reportStatus == "done" and ended.execFinished)
	assert(ended.threadId == "rex-smoke" and ended.usage.input_tokens == 0)
	assert(rt.read(report):find("Run: self-check", 1, true))
	local exited = false
	local output = ""
	local handle, first = interrupt_stream(
		{ "/bin/sh", "-c", "trap 'exit 0' TERM; printf 'ready\\n'; while :; do /bin/sleep 0.02; done" },
		{
			on_exit = function()
				exited = true
			end,
		},
		function(chunk)
			output = output .. chunk
		end,
		200
	)
	local ended_cleanly = vim.wait(2000, function()
		return exited
	end)
	handle.stop()
	assert(
		ended_cleanly and first.interrupted and first.exit.code == 0,
		"event stream interruption failed " .. vim.inspect(first)
	)
	assert(output == "ready\n", "interrupt test did not receive subprocess output")

	local released = 0
	local function release()
		released = released + 1
	end
	local replacement = {}
	local receive = observe_replacement(replacement, release)
	receive('{"type":"oversized","padding":"' .. ("x"):rep(1048577) .. '"}\n')
	assert(released == 0, "oversized event released the worker")
	receive('bad json\n{}\n{"type":"session_view')
	assert(released == 0)
	receive('_changed"}\n{"type":"extra"}\n')
	assert(replacement.observed and released == 1)
	observe_replacement({ exit = { code = 1 } }, release)('{"type":"late"}\n')
	assert(released == 1, "an exited replacement released the worker")

	local blocks = { { block_id = "other-pane" } }
	local client = {
		identity = function()
			return { host_id = ended.hostId, instance_id = ended.instanceId }
		end,
		call = function(method, _, session)
			assert(method == "session.list_blocks" and session == ended.sessionId)
			return { blocks = blocks }
		end,
	}
	confirm_absent(client, ended, ended.sessionId)
	blocks[2] = { block_id = ended.blockId }
	assert(
		not pcall(confirm_absent, client, ended, ended.sessionId),
		"a listed owned block passed cleanup"
	)
	blocks = nil
	assert(
		not pcall(confirm_absent, client, ended, ended.sessionId),
		"a missing block list passed cleanup"
	)
end

local function start_owned()
	local started = pane("start", "--brief", brief, "--transport", transport)
	assert(type(started.pane) == "string" and started.pane ~= rt.env.REX_BLOCK, "no owned pane")
	local owned = record()
	assert(
		started.runId == owned.runId and started.pane == owned.blockId and owned.sessionId == session,
		"smoke pane ownership changed"
	)
	return started, owned
end

local function live_exec()
	local started, owned = start_owned()
	local watches, first = 0, nil
	local replacement = { probes = 0, failedProbes = 0 }
	rt.stream = function(argv, opts, on_data)
		if argv[1] ~= rex.binary or argv[2] ~= "events" then
			return stream(argv, opts, on_data)
		end
		watches = watches + 1
		if watches == 1 then
			local handle
			handle, first = interrupt_stream(rex_command(argv), opts, on_data, 700)
			return handle
		end
		if watches ~= 2 or not (first.interrupted and first.exit) then
			return stream(rex_command(argv), opts, on_data)
		end
		local receive = observe_replacement(replacement, function()
			rt.write(release_file(repo), "watch reconnected\n")
		end)
		local handle = stream(
			rex_command(argv),
			vim.tbl_extend("force", opts, {
				on_exit = function(result)
					replacement.exit = { code = result.code, signal = result.signal }
					opts.on_exit(result)
				end,
			}),
			function(chunk)
				on_data(chunk)
				receive(chunk)
			end
		)
		-- Retry the probe briefly in case the client is still subscribing.
		for _, delay in ipairs({ 250, 750, 1500 }) do
			vim.defer_fn(function()
				if replacement.observed or replacement.exit or replacement.finished then
					return
				end
				replacement.probes = replacement.probes + 1
				local ok = pcall(function()
					check_server(rex, owned)
					rex.call("session.set_block_label", {
						block_id = owned.blockId,
						label = "orc:" .. task .. " reconnect " .. replacement.probes,
					}, session)
				end)
				if not ok then
					replacement.failedProbes = replacement.failedProbes + 1
				end
			end, delay)
		end
		return handle
	end
	local ok, waited = pcall(pane, "wait", "--until", "report", "--timeout", "20000")
	replacement.finished = true
	assert(ok, waited)
	assert(
		replacement.observed,
		("replacement watch received no event (watches=%d, first=%s, replacement=%s, wait=%s)"):format(
			watches,
			vim.inspect(first, { newline = " " }),
			vim.inspect(replacement, { newline = " " }),
			tostring(waited.state)
		)
	)
	assert(
		waited.runId == started.runId and waited.evidence and waited.status == "done",
		vim.inspect(waited)
	)
	assert(record().acknowledged and waited.report == record().report)
	assert(
		vim.wait(2000, function()
			return record().execFinished
		end, 25),
		"fake worker did not exit"
	)
	assert(record().exitCode == 0 and record().threadId == "rex-smoke")
end

local function live_tui()
	rt.stream = function(argv, opts, on_data)
		return stream(rex_command(argv), opts, on_data)
	end
	local started, first = start_owned()
	local function await_state(run_id, state)
		local deadline = rt.clock() + 10000
		repeat
			local snapshot = pane("start", "--brief", brief, "--transport", transport)
			local latest = record()
			assert(snapshot.runId == run_id, "TUI run changed before reaching " .. state)
			if
				snapshot.status == "started"
				and latest.nativeState == state
				and latest.hookState == state
			then
				return
			end
			rt.sleep(100)
		until rt.clock() >= deadline
		error("TUI run was not acknowledged in state " .. state)
	end
	local function assert_report(waited, run_id)
		local latest = record()
		assert(
			waited.runId == run_id
				and waited.evidence
				and waited.status == "done"
				and latest.runId == run_id
				and latest.acknowledged
				and waited.report == latest.report,
			"TUI wait did not return the acknowledged run's done report: " .. vim.inspect(waited)
		)
	end
	await_state(started.runId, "working")
	local queued
	local sleep = rt.sleep
	-- The waiter must hold the first run before the Tab prompt replaces it.
	rt.sleep = function(ms)
		rt.sleep = sleep
		queued = pane("prompt", "--queue", "--text", "Complete the queued follow-up.")
		assert(
			vim.deep_equal({ queued.status, queued.sent, queued.queued }, { "queued", true, true }),
			vim.inspect(queued)
		)
		assert(queued.runId ~= started.runId, "TUI queue reused the startup run ID")
		rt.write(release_file(repo), "queued\n")
		sleep(ms)
	end
	local ok, waited = pcall(pane, "wait", "--until", "report", "--timeout", "20000")
	rt.sleep = sleep
	assert(ok, waited)
	assert(queued, "TUI wait ended before the queue prompt was sent")
	assert_report(waited, queued.runId)
	assert(
		vim.deep_equal(waited.previousRuns, {
			{ runId = first.runId, report = first.report, status = "done" },
		}),
		"TUI wait did not list the replaced run's done report: " .. vim.inspect(waited)
	)

	await_state(queued.runId, "idle")
	local immediate = pane("prompt", "--text", "Complete the idle follow-up.")
	assert(
		vim.deep_equal({ immediate.sent, immediate.queued }, { true, false }),
		vim.inspect(immediate)
	)
	assert(immediate.runId ~= queued.runId, "TUI Enter reused the queued run ID")
	assert_report(pane("wait", "--until", "report", "--timeout", "20000"), immediate.runId)
end

local caller_path = vim.env.PATH
local ok, err = xpcall(function()
	fixture()
	if offline then
		self_check()
	elseif transport == "tui" then
		live_tui()
	else
		live_exec()
	end
end, debug.traceback)
local cleaned, cleanup_error = true, nil
if not offline and (ok or rt.exists(worker)) then
	cleaned, cleanup_error = pcall(function()
		local owned = record()
		assert(owned.sessionId == session, "refusing to close a pane in another Rex session")
		assert(owned.blockId ~= rt.env.REX_BLOCK, "refusing to close the caller's Rex pane")
		local closed, result = pcall(pane, "close", transport == "tui" and "--no-review" or nil)
		confirm_absent(rex, owned, session)
		assert(closed, result)
		assert(
			result.status == "closed" and result.pane == owned.blockId,
			"close did not confirm ownership"
		)
	end)
end
vim.env.PATH = caller_path
if not cleaned then
	error(
		(ok and "" or err .. "\n")
			.. "Could not confirm cleanup. Retained "
			.. parent
			.. "\n"
			.. tostring(cleanup_error),
		0
	)
end
rt.remove(parent)
assert(ok, err)
print(
	offline and "Rex smoke self-check passed"
		or transport == "tui" and "Rex smoke passed (tui start, ack, queued follow-up, newest run, prompt, close)"
		or "Rex smoke passed (start, ack, reconnect, wait, close)"
)
