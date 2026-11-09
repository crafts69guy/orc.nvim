local gate = require("orc.gate")
local runtime = require("orc.runtime")

local function fixture()
	local root = Test.temp()
	local rt = runtime.new({
		cwd = root,
		env = { HOME = root, XDG_CACHE_HOME = root .. "/cache", ORC_GATE_LOCK = root .. "/gate.lock" },
	})
	return rt, root .. "/gate.lock"
end

Test.test("gate malformed or incomplete owners recover safely and wait only once", function()
	for _, metadata in ipairs({
		"",
		"[]",
		"null",
		"broken",
		'{"pid":-1}',
		'{"pid":0}',
		'{"pid":1.5}',
		'{"pid":"bad"}',
	}) do
		local rt, lock = fixture()
		rt.write(lock, metadata)
		assert(vim.uv.fs_utime(lock, 1, 1))
		Test.eq(gate.run(rt, { "--", "true" }).code, 0)
		Test.eq(rt.exists(lock), false)
	end
	local rt, lock = fixture()
	rt.write(lock, "")
	local sleep, waits = rt.sleep, 0
	rt.sleep = function(ms)
		if rt.exists(lock) and rt.read(lock) == "" then
			waits = waits + 1
			if waits == 2 then
				rt.remove(lock)
			end
		else
			sleep(ms)
		end
	end
	Test.eq(gate.run(rt, { "--", "true" }).code, 0)
	Test.eq(waits, 2)
end)

Test.test("gate signal cancellation preserves another owner and stops its own child", function()
	local original = vim.uv.new_signal
	for _, waiting in ipairs({ true, false }) do
		local rt, lock = fixture()
		local interrupt, finished, stopped
		vim.uv.new_signal = function()
			return {
				start = function(_, _, callback)
					interrupt = callback
					return true
				end,
				stop = function() end,
				close = function() end,
			}
		end
		local ok, err = xpcall(function()
			if waiting then
				rt.write(lock, rt.encode({ pid = vim.uv.os_getpid() }))
			else
				rt.stream = function(_, opts)
					finished = opts.on_exit
					return {
						stop = function()
							stopped = true
							finished({ code = 0, signal = 15 })
						end,
					}
				end
			end
			rt.sleep = function()
				interrupt(15)
			end
			Test.eq(gate.run(rt, { "--", "true" }).code, 143)
			Test.eq(rt.exists(lock), waiting)
			Test.eq(stopped == true, not waiting)
		end, debug.traceback)
		vim.uv.new_signal = original
		assert(ok, err)
	end
end)

Test.test("gate output failures stop the child and release the lock", function()
	local rt, lock = fixture()
	local output, complete, stopped
	rt.stream = function(_, opts, on_data)
		output, complete = on_data, opts.on_exit
		return {
			stop = function()
				stopped = true
				complete({ code = 0, signal = 15 })
			end,
		}
	end
	local open = io.open
	io.open = function()
		return {
			write = function()
				error("disk full")
			end,
			close = function() end,
		}
	end
	rt.sleep = function()
		output("fixture output\n")
	end
	local ok, err = pcall(gate.run, rt, { "--log", "output.log", "--", "true" })
	io.open = open
	assert(not ok and tostring(err):find("disk full", 1, true))
	assert(stopped)
	Test.eq(rt.exists(lock), false)
	Test.raises("must not overwrite the lock", function()
		gate.run(rt, { "--log", lock, "--", "true" })
	end)
	Test.eq(rt.exists(lock), false)
end)

Test.test("gate locks streams logs and preserves child exit codes", function()
	local rt, lock = fixture()
	for _, code in ipairs({ 0, 7 }) do
		local inspected = false
		local stream = rt.stream
		rt.stream = function(argv, opts, output)
			local owner = rt.decode((assert(rt.read(lock))))
			Test.eq(owner.pid, vim.uv.os_getpid())
			Test.eq(owner.label, "fixture gate")
			Test.eq(owner.cwd, rt.cwd)
			Test.eq(type(owner.startedAt), "number")
			inspected = true
			return stream(argv, opts, output)
		end
		local response = gate.run(rt, {
			"--label",
			"fixture gate",
			"--log",
			"output.log",
			"--",
			"sh",
			"-c",
			"printf 'stdout\n'; printf 'stderr\n' >&2; exit " .. code,
		})
		Test.eq(response.code, code)
		assert(inspected)
		local log = assert(rt.read(rt.path(rt.cwd, "output.log")))
		assert(log:find("stdout\n", 1, true))
		assert(log:find("stderr\n", 1, true))
		Test.eq(rt.exists(lock), false)
		rt.stream = stream
	end
end)

Test.test("gate waits without spinning and recovers a dead owner", function()
	local rt, lock = fixture()
	rt.write(
		lock,
		rt.encode({
			pid = vim.uv.os_getpid(),
			label = "holder",
			cwd = rt.cwd,
			startedAt = os.time() - 10,
		})
	)
	local slept = 0
	local sleep = rt.sleep
	rt.sleep = function(ms)
		if rt.exists(lock) and rt.decode((assert(rt.read(lock)))).label == "holder" then
			Test.eq(ms, 250)
			slept = slept + 1
			rt.remove(lock)
		else
			sleep(ms)
		end
	end
	Test.eq(gate.run(rt, { "--", "true" }).code, 0)
	Test.eq(slept, 1)
	rt.write(lock, rt.encode({ pid = 2147483647, label = "dead" }))
	Test.eq(gate.run(rt, { "--", "true" }).code, 0)
	Test.eq(rt.exists(lock), false)
end)

Test.test("gate recovers pre-boot pids with slack and an unavailable uptime", function()
	local uptime = vim.uv.uptime
	local ok, err = xpcall(function()
		for _, case in ipairs({ "previous-boot", "slack", "unavailable" }) do
			local rt, lock = fixture()
			vim.uv.uptime = function()
				if case ~= "unavailable" then
					return 1000
				end
				return nil, "EPERM: operation not permitted"
			end
			rt.write(
				lock,
				rt.encode({
					pid = vim.uv.os_getpid(),
					label = "holder",
					cwd = rt.cwd,
					startedAt = os.time() - 1000 - (case == "slack" and 2 or 10),
				})
			)
			local sleep, waits = rt.sleep, 0
			rt.sleep = function(ms)
				local text = rt.read(lock)
				if text and rt.decode(text).label == "holder" then
					assert(case ~= "previous-boot", "pre-boot owner was retained")
					waits = waits + 1
					rt.remove(lock)
				else
					sleep(ms)
				end
			end
			Test.eq(gate.run(rt, { "--", "true" }).code, 0)
			Test.eq(waits, case == "previous-boot" and 0 or 1)
			Test.eq(rt.exists(lock), false)
		end
	end, debug.traceback)
	vim.uv.uptime = uptime
	assert(ok, err)
end)

Test.test("gate stale cleanup serializes reapers and recovers abandoned cleanup", function()
	for _, abandoned in ipairs({ true, false }) do
		local rt, lock = fixture()
		rt.write(lock, rt.encode({ pid = 2147483647 }))
		rt.mkdir(lock .. ".reap")
		if abandoned then
			assert(vim.uv.fs_utime(lock .. ".reap", 1, 1))
		end
		local sleep = rt.sleep
		rt.sleep = function(ms)
			if not abandoned and rt.exists(lock .. ".reap") then
				rt.rmdir(lock .. ".reap")
			else
				sleep(ms)
			end
		end
		Test.eq(gate.run(rt, { "--", "true" }).code, 0)
		Test.eq(rt.exists(lock), false)
		Test.eq(rt.exists(lock .. ".reap"), false)
	end
	local rt, lock = fixture()
	rt.write(lock, rt.encode({ pid = 2147483647 }))
	local mkdir = rt.mkdir_lock
	rt.mkdir_lock = function(path)
		local created = mkdir(path)
		if created then
			rt.write(lock, rt.encode({ pid = vim.uv.os_getpid() }))
		end
		return created
	end
	local sleep = rt.sleep
	rt.sleep = function(ms)
		if rt.exists(lock) and rt.decode((rt.read(lock))).label == nil then
			rt.remove(lock)
		else
			sleep(ms)
		end
	end
	Test.eq(gate.run(rt, { "--", "true" }).code, 0)
end)

Test.test("gate releases on spawn log and streaming errors and uses cache defaults", function()
	local rt, lock = fixture()
	Test.eq(gate.run(rt, { "--", "orc-nonexistent-command" }).code, 127)
	Test.eq(rt.exists(lock), false)
	Test.raises("No such file", function()
		gate.run(rt, { "--log", "missing/output.log", "--", "true" })
	end)
	Test.eq(rt.exists(lock), false)
	rt.stream = function()
		error("stream failed")
	end
	Test.raises("stream failed", function()
		gate.run(rt, { "--", "true" })
	end)
	Test.eq(rt.exists(lock), false)
	rt.env.ORC_GATE_LOCK = nil
	Test.raises("stream failed", function()
		gate.run(rt, { "--", "true" })
	end)
	Test.eq(rt.exists(rt.path(rt.env.XDG_CACHE_HOME, "orc", "gate.lock")), false)
	rt.env.XDG_CACHE_HOME = nil
	Test.raises("stream failed", function()
		gate.run(rt, { "--", "true" })
	end)
	Test.eq(rt.exists(rt.path(rt.env.HOME, ".cache", "orc", "gate.lock")), false)
end)

Test.test("gate command parser preserves argv and rejects missing separators", function()
	local parse = require("orc.args").command
	local flags, command = parse(
		{ "--label", "x", "--", "echo", "--log", "a b" },
		{ label = "string" }
	)
	Test.eq(flags.label, "x")
	Test.eq(command, { "echo", "--log", "a b" })
	for _, argv in ipairs({
		{},
		{ "--" },
		{ "echo" },
		{ "echo", "--", "true" },
	}) do
		Test.raises("gate:", function()
			parse(argv, {})
		end)
	end
	Test.raises("unknown option", function()
		parse({ "--unknown", "--", "true" }, {})
	end)
end)

Test.test("gate independent processes serialize and interrupt releases its lock", function()
	local rt, lock = fixture()
	local bin = rt.path(rt.root, "bin", "orc")
	local function start(command)
		return vim.system({
			vim.v.progpath,
			"--clean",
			"-l",
			bin,
			"gate",
			"--label",
			"process fixture",
			"--",
			"sh",
			"-c",
			command,
		}, { cwd = rt.cwd, env = rt.env, clear_env = true, text = true })
	end
	local first = start("touch started; sleep 0.3; touch finished")
	assert(vim.wait(5000, function()
		return rt.exists(rt.path(rt.cwd, "started"))
	end, 10))
	local second = start("test -f finished")
	Test.eq(first:wait(5000).code, 0)
	local waited = second:wait(5000)
	Test.eq(waited.code, 0)
	assert(waited.stderr:find("waiting for process fixture", 1, true))
	Test.eq(rt.exists(lock), false)
	local interrupted = start("touch interrupt-started; exec sleep 10")
	assert(vim.wait(5000, function()
		return rt.exists(rt.path(rt.cwd, "interrupt-started"))
	end, 10))
	interrupted:kill(15)
	assert(interrupted:wait(5000).code ~= 0)
	Test.eq(rt.exists(lock), false)
end)
