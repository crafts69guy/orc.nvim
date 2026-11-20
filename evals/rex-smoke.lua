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

if arg[1] == "--fake-codex" then
	if arg[2] == "mcp" and arg[3] == "list" and arg[4] == "--json" then
		io.write("[]\n")
		return
	end
	assert(arg[2] == "--no-daemon" and arg[3] == "exec" and arg[4] == "--json")
	local worker = assert(rt.env.ORC_WORKER_FILE)
	local record = rt.decode((assert(rt.read(worker))))
	local prompt = arg[#arg]
	assert(prompt:match("^%[orc%-run:([%w%-]+)%]") == record.runId)
	local function hook(event, fields)
		fields.hook_event_name = event
		local result = orc(rt, { "hook", "worker-event" }, rt.encode(fields))
		assert(result.code == 0, result.err)
	end
	hook("UserPromptSubmit", { prompt = prompt })
	io.write(rt.encode({ type = "thread.started", thread_id = "rex-smoke" }) .. "\n")
	io.stdout:flush()
	assert(
		vim.wait(25000, function()
			return rt.exists(release_file(record.root))
		end, 25),
		"smoke never released the fake worker"
	)
	hook("Stop", {
		last_assistant_message = "Run: "
			.. record.runId
			.. "\nStatus: done\n\n## Validation\nFake Codex acknowledged this run.\n",
	})
	io.write(
		rt.encode({ type = "turn.completed", usage = { input_tokens = 0, output_tokens = 0 } }) .. "\n"
	)
	return
end

local offline = arg[1] == "--self-check"
assert(#arg == 0 or (#arg == 1 and offline), "usage: rex-smoke.lua [--self-check]")
local rex = require("orc.rex").new(rt)
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
	assert(rt.env.REX_SESSION and rt.env.REX_BLOCK, "run from a local Rex terminal")
	rt.exec = function(argv, opts)
		return exec(argv[1] == rex.binary and rex_command(argv) or argv, opts)
	end
	rex.identity()
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
	rt.write(
		codex,
		"#!/bin/sh\nexec " .. quote(nvim) .. " --clean -l " .. quote(script) .. ' --fake-codex "$@"\n'
	)
	assert(vim.uv.fs_chmod(codex, 448))
	assert(vim.uv.fs_symlink(nvim, rt.path(bin, "nvim")))
	assert(vim.uv.fs_symlink(vim.fn.exepath("git"), rt.path(bin, "git")))
	if not offline then
		assert(vim.uv.fs_symlink(rex.binary, rt.path(bin, "rex")))
	end
	-- libuv can resolve executables using the caller's PATH on macOS.
	vim.env.PATH, rt.env.PATH = bin, bin
	rex = require("orc.rex").new(rt)
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

local function confirm_absent(client, owned)
	assert(type(owned.blockId) == "string" and owned.blockId ~= "", "no confirmed owned block")
	check_server(client, owned)
	local listed = client.call("session.list_blocks", {}, owned.sessionId)
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
			transport = "exec",
			state = "unconfirmed",
			report = report,
			hostId = "fixture-host",
			instanceId = "fixture-instance",
			brief = brief,
		})
	)
	rt.write(release_file(repo), "offline\n")
	local opts = {
		root = root,
		cwd = checkout,
		env = vim.tbl_extend("force", rt.env, {
			ORC_WORKER_FILE = worker,
			REX_SESSION = "fixture-session",
			REX_BLOCK = "fixture-block",
		}),
	}
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
	confirm_absent(client, ended)
	blocks[2] = { block_id = ended.blockId }
	assert(not pcall(confirm_absent, client, ended), "a listed owned block passed cleanup")
	blocks = nil
	assert(not pcall(confirm_absent, client, ended), "a missing block list passed cleanup")
end

local function live()
	local started = pane("start", "--brief", brief, "--transport", "exec")
	assert(type(started.pane) == "string" and started.pane ~= rt.env.REX_BLOCK, "no owned pane")
	local owned = record()
	assert(
		started.runId == owned.runId
			and started.pane == owned.blockId
			and owned.sessionId == rt.env.REX_SESSION,
		"smoke pane ownership changed"
	)
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
					}, owned.sessionId)
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

local caller_path = vim.env.PATH
local ok, err = xpcall(function()
	fixture()
	if offline then
		self_check()
	else
		live()
	end
end, debug.traceback)
local cleaned, cleanup_error = true, nil
if not offline and (ok or rt.exists(worker)) then
	cleaned, cleanup_error = pcall(function()
		local owned = record()
		assert(owned.sessionId == rt.env.REX_SESSION, "refusing to close a pane in another Rex session")
		assert(owned.blockId ~= rt.env.REX_BLOCK, "refusing to close the caller's Rex pane")
		local closed, result = pcall(pane, "close")
		confirm_absent(rex, owned)
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
		or "Rex smoke passed (start, ack, reconnect, wait, close)"
)
