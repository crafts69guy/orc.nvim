local runtime = require("orc.runtime")

Test.test("runtime tail bounds reads and discards truncated first records", function()
	local rt, dir = runtime.new(), Test.temp()
	local path = rt.path(dir, "transcript")
	rt.write(path, "first\nlast\n")
	Test.eq(rt.tail(path, 100), "first\nlast\n")
	Test.eq(rt.tail(path, 8), "last\n")
	Test.eq(rt.tail(path, 2), "")
	rt.write(path, "unterminated")
	Test.eq(rt.tail(path, 4), "")
	rt.write(path, "")
	Test.eq(rt.tail(path, 8), "")
	local data, err = rt.tail(dir .. "/missing", 8)
	Test.eq(data, nil)
	assert(assert(err):find("ENOENT", 1, true))
	data, err = rt.tail(dir, 8)
	Test.eq(data, nil)
	assert(assert(err):find("EISDIR", 1, true))
end)

Test.test("runtime root, paths and environment do not depend on cwd", function()
	local rt = runtime.new({ cwd = "/tmp", env = { ORC_RUNTIME_TEST = "base" } })
	assert(rt.exists(rt.path(rt.root, "AGENTS.md")))
	Test.eq(rt.abspath("folder/../file"), "/tmp/file")
	Test.eq(rt.abspath("file", "/other"), "/other/file")
	Test.eq(rt.abspath("/absolute/../file"), "/file")
	Test.eq(rt.abspath("~/file"), rt.path(rt.env.HOME, "file"))
	Test.eq(rt.abspath("~"), rt.env.HOME)
	Test.eq(rt.env.ORC_RUNTIME_TEST, "base")
	Test.eq(vim.env.ORC_RUNTIME_TEST, nil)
	Test.eq(runtime.new({ root = "/fixture" }).root, "/fixture")
	Test.eq(rt.decode(rt.encode({ null = rt.null, list = {}, object = vim.empty_dict() })), {
		null = vim.NIL,
		list = {},
		object = vim.empty_dict(),
	})
	assert(rt.now():match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$"))
	local before = rt.clock()
	rt.sleep(2)
	assert(rt.clock() >= before)
	Test.raises("nonnegative", function()
		rt.sleep(-1)
	end)
end)

Test.test("runtime executes argv literally with stdin, cwd, exit and environment", function()
	local rt = runtime.new({ cwd = "/tmp", env = { ORC_RUNTIME_TEST = "base" } })
	local result = rt.exec({ "printf", "%s", "a;$(false) b" })
	Test.eq(result, { code = 0, signal = 0, stdout = "a;$(false) b", stderr = "" })
	Test.eq(rt.exec({ "cat" }, { stdin = "hello\n" }).stdout, "hello\n")
	Test.eq(rt.exec({ "pwd" }).stdout, vim.uv.fs_realpath("/tmp") .. "\n")
	Test.eq(rt.exec({ "pwd" }, { cwd = "/" }).stdout, "/\n")
	Test.eq(rt.exec({ "printenv", "ORC_RUNTIME_TEST" }).stdout, "base\n")
	Test.eq(
		rt.exec({ "printenv", "ORC_RUNTIME_TEST" }, { env = { ORC_RUNTIME_TEST = "child" } }).stdout,
		"child\n"
	)
	Test.eq(
		rt.exec({ "printenv", "ORC_RUNTIME_TEST" }, { env = { ORC_RUNTIME_TEST = false } }).code,
		1
	)
	Test.eq(
		rt.exec({ "printenv", "ORC_RUNTIME_TEST" }, { env = { ORC_RUNTIME_TEST = 42 } }).stdout,
		"42\n"
	)
	Test.eq(rt.exec({ "false" }).code, 1)
	Test.eq(rt.exec({ "orc-executable-does-not-exist" }).code, 127)
	Test.eq(rt.exec({ "pwd" }, { cwd = "/orc-missing-cwd" }).code, 127)
	local timeout = rt.exec({ "sleep", "2" }, { timeout = 5 })
	assert(timeout.code ~= 0)
	Test.eq(rt.env.ORC_RUNTIME_TEST, "base")
end)

Test.test(
	"runtime writes atomically, reads, sorts and removes without following symlinks",
	function()
		local rt, dir = runtime.new(), Test.temp()
		local target = rt.path(dir, "nested", "report.md")
		rt.write(target, "first")
		Test.eq(rt.read(target), "first")
		rt.write(target, "second\n")
		Test.eq(rt.read(target), "second\n")
		rt.write(rt.path(dir, "nested", "a"), "")
		Test.eq(rt.list(rt.path(dir, "nested")), { "a", "report.md" })
		Test.eq(rt.list(rt.path(dir, "missing")), {})
		Test.eq(rt.read(rt.path(dir, "missing")), nil)
		local _, read_error = rt.read(rt.path(dir, "missing"))
		assert(assert(read_error):find("ENOENT", 1, true))
		local data, directory_error = rt.read(rt.path(dir, "nested"))
		Test.eq(data, nil)
		assert(assert(directory_error):find("EISDIR", 1, true))
		Test.raises("ENOTDIR", function()
			rt.list(target)
		end)
		assert(vim.uv.fs_symlink(rt.path(dir, "nested"), rt.path(dir, "link")))
		rt.remove(rt.path(dir, "link"))
		Test.eq(rt.read(target), "second\n")
		rt.remove(rt.path(dir, "nested"))
		assert(not rt.exists(target))
		rt.remove(rt.path(dir, "missing"))
		Test.eq(rt.list(dir), {})
	end
)

Test.test(
	"runtime atomic write retains old target and cleans temporary on rename failure",
	function()
		local rt, dir = runtime.new(), Test.temp()
		local target = rt.path(dir, "directory")
		rt.mkdir(target)
		Test.raises("EISDIR", function()
			rt.write(target, "must not replace directory")
		end)
		Test.eq(rt.list(dir), { "directory" })
		assert(rt.exists(target))
	end
)

Test.test("runtime interactive preserves exit codes and environment", function()
	local rt = runtime.new({ env = { ORC_RUNTIME_TEST = "base" } })
	Test.eq(rt.interactive({ "true" }), 0)
	Test.eq(rt.interactive({ "false" }), 1)
	Test.eq(rt.interactive({ "test", "child", "=", "child" }, { cwd = "/tmp" }), 0)
	Test.eq(
		rt.interactive(
			{ "/bin/sh", "-c", 'test "$ORC_RUNTIME_TEST" = child' },
			{ env = { ORC_RUNTIME_TEST = "child" } }
		),
		0
	)
	Test.eq(rt.interactive({ "/bin/sh", "-c", "kill -TERM $$" }), 143)
	Test.eq(rt.interactive({ "orc-executable-does-not-exist" }), 127)
	Test.raises("executable", function()
		rt.interactive({})
	end)
end)

local function replace_child(source)
	local rt, dir = runtime.new(), Test.temp()
	local script = rt.path(dir, "replace.lua")
	local lua_path = rt.path(rt.root, "lua", "?.lua") .. ";"
	rt.write(
		script,
		("package.path = %q .. package.path\nlocal rt = require('orc.runtime').new()\n"):format(
			lua_path
		) .. source
	)
	return rt.exec({ vim.v.progpath, "--clean", "-l", script }, { timeout = 5000 })
end

local has_ffi = pcall(require, "ffi")

local function execve_test(name, run)
	name = name .. " (requires LuaJIT FFI)"
	if has_ffi then
		Test.test(name, run)
	else
		io.stdout:write("skip " .. name .. "\n")
	end
end

execve_test("runtime replace keeps the launcher pid", function()
	local result = replace_child([[
io.stdout:write(vim.fn.getpid(), "\n")
os.exit(rt.replace({ "/bin/sh", "-c", "echo $$" }))
]])
	assert(result.code == 0, result.stderr)
	local launcher, shell = result.stdout:match("^(%d+)\n(%d+)\n$")
	assert(launcher and shell, result.stdout)
	Test.eq(shell, launcher)
end)

Test.test("runtime replace passes through exit status", function()
	local exited = replace_child([[os.exit(rt.replace({ "/bin/sh", "-c", "exit 7" }))]])
	assert(exited.code == 7, vim.inspect(exited))
	Test.eq(exited.signal, 0)
end)

execve_test("runtime replace passes through signal death", function()
	local signaled = replace_child([[
os.exit(rt.replace({ "/bin/sh", "-c", "kill -TERM $$" }))
]])
	assert(signaled.signal == 15, vim.inspect(signaled))
end)

Test.test("runtime replace searches the merged PATH from the launch cwd", function()
	local rt, dir = runtime.new(), Test.temp()
	rt.mkdir(rt.path(dir, "orc-test-agent"))
	local script = rt.path(dir, "agent bin", "orc-test-agent")
	rt.write(
		script,
		[[#!/bin/sh
printf '%s|%s|%s\n' "$ORC_RUNTIME_TEST" "${ORC_RUNTIME_REMOVE-unset}" "$1"
/bin/pwd -P
]]
	)
	assert(vim.uv.fs_chmod(script, 493))
	local result = replace_child(([[
rt.cwd = %q
rt.env.PATH = "base-path"
rt.env.ORC_RUNTIME_TEST = "base"
rt.env.ORC_RUNTIME_REMOVE = "remove me"
os.exit(rt.replace({ "orc-test-agent", "literal a;$(false)" }, {
	env = { PATH = ":agent bin", ORC_RUNTIME_TEST = "override", ORC_RUNTIME_REMOVE = false },
}))
]]):format(dir))
	assert(result.code == 0, result.stderr)
	Test.eq(
		result.stdout,
		"override|unset|literal a;$(false)\n" .. assert(vim.uv.fs_realpath(dir)) .. "\n"
	)
end)

Test.test("runtime replace reports missing cwd or executable and returns to the caller", function()
	local dir = Test.temp()
	local missing_cwd_status = has_ffi and 1 or 127
	local result = replace_child(([[
local cwd = vim.uv.cwd()
assert(rt.replace({ "/bin/sh", "-c", "echo unexpected exec" }, { cwd = %q }) == %d)
assert(rt.replace({ "orc-not-found" }, { cwd = %q, env = { PATH = false } }) == 127)
assert(vim.uv.cwd() == cwd)
io.stdout:write("continued\n")
]]):format(dir .. "/absent", missing_cwd_status, dir))
	assert(result.code == 0, result.stderr)
	Test.eq(result.stdout, "continued\n")
	local cwd_error, executable_error = result.stderr:match("^([^\n]+)\n([^\n]+)\n$")
	assert(cwd_error and cwd_error:find("ENOENT", 1, true), result.stderr)
	local expected = has_ffi and "orc-not-found" or "ENOENT"
	assert(executable_error and executable_error:find(expected, 1, true), result.stderr)
end)

execve_test("runtime replace reports execve failures and can be retried", function()
	local rt, dir = runtime.new(), Test.temp()
	local invalid = rt.path(dir, "invalid format")
	local missing_interpreter = rt.path(dir, "missing interpreter")
	rt.write(invalid, "invalid executable\n")
	rt.write(missing_interpreter, "#!" .. rt.path(dir, "absent") .. "\n")
	assert(vim.uv.fs_chmod(invalid, 493))
	assert(vim.uv.fs_chmod(missing_interpreter, 493))
	local result = replace_child(([[
local cwd = vim.uv.cwd()
local options = { cwd = %q }
assert(rt.replace({ "./invalid format" }, options) == 126)
assert(rt.replace({ "./missing interpreter" }, options) == 127)
assert(vim.uv.cwd() == cwd)
]]):format(dir))
	assert(result.code == 0, result.stderr)
	assert(result.stderr:find("./invalid format: ", 1, true), result.stderr)
	assert(result.stderr:find("./missing interpreter: ", 1, true), result.stderr)
end)

Test.test("runtime replace falls back to interactive when FFI is unavailable", function()
	local result = replace_child([[
package.loaded.ffi = nil
package.preload.ffi = function()
	error("FFI unavailable")
end
local code = rt.replace({ "/bin/sh", "-c", 'echo "$ORC_RUNTIME_TEST"; exit 7' }, {
	env = { ORC_RUNTIME_TEST = "fallback" },
})
assert(code == 7)
io.stdout:write("continued\n")
]])
	assert(result.code == 0, result.stderr)
	Test.eq(result.stdout, "fallback\ncontinued\n")
end)

Test.test(
	"runtime async captures output without blocking and reports missing executables",
	function()
		local rt = runtime.new()
		---@type orc.ProcessResult?
		local completed
		local handle = rt.async({ "cat" }, { stdin = "async input" }, function(value)
			completed = value
		end)
		Test.eq(completed, nil)
		assert(vim.wait(3000, function()
			return completed ~= nil
		end))
		local result = assert(completed)
		Test.eq(result.code, 0)
		Test.eq(result.stdout, "async input")
		handle.stop()
		handle.stop()
		completed = nil
		local missing = rt.async({ "orc-executable-does-not-exist" }, {}, function(value)
			completed = value
		end)
		assert(vim.wait(1000, function()
			return completed ~= nil
		end))
		Test.eq(assert(completed).code, 127)
		missing.stop()
		Test.raises("completion callback", function()
			rt.async({ "true" }, {}, Test.invalid(nil))
		end)
	end
)

Test.test("runtime stream delivers chunks and cancellation terminates its owned process", function()
	local rt, output = runtime.new(), ""
	---@type orc.ProcessResult?
	local completed
	local stream = rt.stream({ "printf", "%s", "event\n" }, {
		on_exit = function(value)
			completed = value
		end,
	}, function(chunk)
		output = output .. chunk
	end)
	assert(vim.wait(3000, function()
		return completed ~= nil
	end))
	Test.eq(output, "event\n")
	Test.eq(assert(completed).code, 0)
	stream.stop()
	completed = nil
	local sleeper = rt.async({ "sleep", "30" }, {}, function(value)
		completed = value
	end)
	sleeper.stop()
	sleeper.stop()
	assert(vim.wait(3000, function()
		return completed ~= nil
	end))
	local result = assert(completed)
	assert(result.code ~= 0 or result.signal ~= 0)
	local no_exit = rt.stream({ "true" }, nil, function() end)
	no_exit.stop()
	Test.raises("data callback", function()
		rt.stream({ "true" }, {}, Test.invalid(nil))
	end)
end)

Test.test("runtime mkdir rejects null and empty paths without creating entries", function()
	local rt, dir = runtime.new(), Test.temp()
	local cwd = assert(vim.uv.cwd())
	assert(vim.uv.chdir(dir))
	local ok, err = xpcall(function()
		for _, path in ipairs({ vim.NIL, "" }) do
			Test.raises("mkdir needs a path", function()
				rt.mkdir(Test.invalid(path))
			end)
		end
		Test.eq(rt.list(dir), {})
	end, debug.traceback)
	assert(vim.uv.chdir(cwd))
	assert(ok, err)
end)

Test.test(
	"runtime mkdir_lock acquires privately and reports contention without replacing data",
	function()
		local rt, dir = runtime.new(), Test.temp()
		local lock = rt.path(dir, "lock")
		Test.eq(rt.mkdir_lock(lock), true)
		Test.eq(bit.band(assert(vim.uv.fs_stat(lock)).mode, 511), 448)
		Test.eq(rt.mkdir_lock(lock), false)
		rt.write(rt.path(lock, "owner"), "preserved")
		Test.eq(rt.mkdir_lock(lock), false)
		Test.eq(rt.read(rt.path(lock, "owner")), "preserved")
		local file = rt.path(dir, "file")
		rt.write(file, "preserved")
		Test.eq(rt.mkdir_lock(file), false)
		Test.eq(rt.read(file), "preserved")
		Test.raises("ENOENT", function()
			rt.mkdir_lock(rt.path(dir, "missing", "lock"))
		end)
		Test.replace(vim.uv, "fs_mkdir", function()
			return nil, "EACCES: denied", "EACCES"
		end, function()
			Test.raises("EACCES: denied", function()
				rt.mkdir_lock(lock)
			end)
		end)
	end
)

Test.test(
	"runtime filesystem failures preserve existing data and close owned descriptors",
	function()
		local rt, dir = runtime.new(), Test.temp()
		local file = rt.path(dir, "report")
		rt.write(file, "retained")
		Test.replace(vim.uv, "fs_fstat", function()
			return nil, "fstat failed"
		end, function()
			local data, err = rt.read(file)
			Test.eq(data, nil)
			Test.eq(err, "fstat failed")
			data, err = rt.tail(file, 8)
			Test.eq(data, nil)
			Test.eq(err, "fstat failed")
		end)
		local close = vim.uv.fs_close
		Test.replace(vim.uv, "fs_close", function(fd)
			close(fd)
			return nil, "close failed"
		end, function()
			local data, err = rt.read(file)
			Test.eq(data, nil)
			Test.eq(err, "close failed")
			data, err = rt.tail(file, 8)
			Test.eq(data, nil)
			Test.eq(err, "close failed")
		end)
		Test.replace(vim.uv, "fs_write", function()
			return nil, "write failed"
		end, function()
			Test.raises("write failed", function()
				rt.write(file, "new")
			end)
		end)
		Test.eq(rt.read(file), "retained")
		Test.eq(rt.list(dir), { "report" })
		Test.replace(vim.fn, "mkdir", function()
			return 0
		end, function()
			Test.raises("cannot create directory", function()
				rt.mkdir(rt.path(dir, "missing"))
			end)
		end)
		Test.replace(vim.uv, "fs_lstat", function()
			return nil, "EACCES: denied"
		end, function()
			Test.raises("EACCES", function()
				rt.remove(file)
			end)
		end)
		Test.eq(rt.exec({ "pwd" }, { cwd = file }).code, 1)
		Test.eq(rt.interactive({ "pwd" }, { cwd = file }), 1)
	end
)

Test.test(
	"runtime interactive forwards cancellation and never kills after child completion",
	function()
		local rt, callbacks = runtime.new(), {}
		Test.replace(vim.uv, "new_signal", function()
			return {
				start = function(_, name, callback)
					callbacks[name] = callback
				end,
				stop = function() end,
				close = function() end,
			}
		end, function()
			vim.defer_fn(function()
				callbacks.sigterm()
			end, 10)
			Test.eq(rt.interactive({ "sleep", "30" }), 143)
			callbacks.sigterm()
		end)
		local wait, interrupted = vim.wait, false
		Test.replace(vim, "wait", function(...)
			if not interrupted then
				interrupted = true
				return false, -2
			end
			return wait(...)
		end, function()
			Test.eq(rt.interactive({ "sleep", "30" }), 130)
		end)
	end
)

Test.test(
	"runtime streaming errors terminate its owned child and completion normalizes absent output",
	function()
		local rt, killed = runtime.new(), false
		---@type orc.ProcessResult?
		local completed
		Test.replace(vim, "system", function(_, settings, on_exit)
			local handle = {
				kill = function()
					killed = true
					on_exit({ code = 1, signal = 15 })
				end,
			}
			vim.schedule(function()
				settings.stdout("EIO", nil)
			end)
			return handle
		end, function()
			rt.stream({ "fake" }, {
				on_exit = function(value)
					completed = value
				end,
			}, function()
				error("no data expected")
			end)
			assert(vim.wait(1000, function()
				return completed ~= nil
			end))
			assert(killed)
			local result = assert(completed)
			Test.eq(result.stdout, "")
			Test.eq(result.stderr, "")
		end)
		Test.replace(vim, "system", function()
			return {
				wait = function()
					return { code = 0, signal = 0 }
				end,
			}
		end, function()
			Test.eq(rt.exec({ "fake" }).stdout, "")
			Test.eq(rt.exec({ "fake" }).stderr, "")
		end)
	end
)

Test.test("runtime rmdir never removes contents or follows directory symlinks", function()
	local rt, dir = runtime.new(), Test.temp()
	local empty, occupied = rt.path(dir, "empty"), rt.path(dir, "occupied")
	rt.mkdir(empty)
	rt.rmdir(empty)
	assert(not rt.exists(empty))
	rt.write(rt.path(occupied, "user-work"), "preserve")
	Test.raises("ENOTEMPTY", function()
		rt.rmdir(occupied)
	end)
	assert(vim.uv.fs_symlink(occupied, rt.path(dir, "link")))
	Test.raises("ENOTDIR", function()
		rt.rmdir(rt.path(dir, "link"))
	end)
	Test.eq(rt.read(rt.path(occupied, "user-work")), "preserve")
end)

Test.test("runtime append keeps interleaved records with one O_APPEND write per caller", function()
	local rt, dir = runtime.new(), Test.temp()
	local file = rt.path(dir, "signals.jsonl")
	rt.write(file, '{"before":true}\n')
	local write, interleaved, writes = vim.uv.fs_write, false, 0
	Test.replace(vim.uv, "fs_write", function(fd, text, offset)
		writes = writes + 1
		if not interleaved then
			interleaved = true
			rt.append(file, '{"writer":"B"}\n')
		end
		Test.eq(offset, -1)
		return write(fd, text, offset)
	end, function()
		rt.append(file, '{"writer":"A"}\n')
	end)
	Test.eq(writes, 2)
	Test.eq(rt.read(file), '{"before":true}\n{"writer":"B"}\n{"writer":"A"}\n')
end)

Test.test(
	"runtime append rejects oversized or multiline records and preserves data on write failure",
	function()
		local rt, dir = runtime.new(), Test.temp()
		local file = rt.path(dir, "signals.jsonl")
		rt.append(file, '{"before":true}\n')
		for _, value in ipairs({ "", string.rep("x", 4097) }) do
			Test.raises("1%-4096 bytes", function()
				rt.append(file, value)
			end)
		end
		for _, value in ipairs({ "missing newline", "two\nlines\n" }) do
			Test.raises("newline%-terminated", function()
				rt.append(file, value)
			end)
		end
		Test.replace(vim.uv, "fs_write", function()
			return nil, "append failed"
		end, function()
			Test.raises("append failed", function()
				rt.append(file, '{"after":true}\n')
			end)
		end)
		Test.eq(rt.read(file), '{"before":true}\n')
	end
)
