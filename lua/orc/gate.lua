local M = {}
local uv = vim.uv

local function alive(pid)
	if type(pid) ~= "number" or pid < 1 or pid % 1 ~= 0 then
		return false
	end
	local ok, err = uv.kill(pid, 0)
	return ok ~= nil or not tostring(err):find("ESRCH", 1, true)
end

---Serialize heavy validation across checkouts, streaming both output channels.
---ORC_GATE_LOCK overrides the private cache lock; dead and pre-boot owners are recovered.
---@param rt orc.Runtime
---@param argv string[] Gate options followed by -- and the command argv.
---@return table result Child exit code; diagnostics are streamed to stderr.
function M.run(rt, argv)
	local flags, command = require("orc.args").command(argv, { label = "string", log = "string" })
	local lock = rt.abspath(
		rt.env.ORC_GATE_LOCK
			or rt.path(
				rt.env.XDG_CACHE_HOME or rt.path(assert(rt.env.HOME), ".cache"),
				"orc",
				"gate.lock"
			)
	)
	rt.mkdir(vim.fs.dirname(lock))
	local owner =
		{ pid = uv.os_getpid(), label = flags.label or command[1], cwd = rt.cwd, startedAt = os.time() }
	local held, log, child, interrupted, finished, write_error
	local reaper = lock .. ".reap"
	local reaping = false
	local signals = {}
	local function cleanup()
		if child and not finished then
			child.stop()
			while not finished do
				rt.sleep(25)
			end
		end
		if log then
			log:close()
			log = nil
		end
		if held then
			assert(uv.fs_unlink(lock))
			held = false
		end
		if reaping then
			rt.rmdir(reaper)
			reaping = false
		end
		for _, handle in ipairs(signals) do
			handle:stop()
			handle:close()
		end
		signals = {}
	end
	-- Neovim also handles fatal signals itself, which can bypass the Lua return path.
	local leave = vim.api.nvim_create_autocmd("VimLeavePre", { callback = cleanup })
	local function emit(chunk, stderr)
		local ok, err = pcall(function()
			local output = stderr and io.stderr or io.stdout
			assert(output:write(chunk))
			output:flush()
			if log then
				assert(log:write(chunk))
				assert(log:flush())
			end
		end)
		if not ok then
			write_error = err
		end
	end
	local function read_owner()
		local text = rt.read(lock)
		local ok, value = pcall(rt.decode, text or "")
		return ok and type(value) == "table" and value or {}
	end
	local function stale(value)
		local started = tonumber(value.startedAt)
		-- Sandboxes may deny uptime; keep live owners when boot time is unavailable.
		local uptime = uv.uptime()
		if started and uptime and started < os.time() - uptime - 5 then
			return true
		end
		if value.pid then
			return not alive(value.pid)
		end
		-- A crash between exclusive create and metadata write leaves an empty file.
		local stat = uv.fs_stat(lock)
		return stat and os.time() - stat.mtime.sec > 60
	end
	local ok, response = xpcall(function()
		for _, name in ipairs({ "sigint", "sigterm", "sighup", "sigquit" }) do
			local handle = assert(uv.new_signal())
			signals[#signals + 1] = handle
			assert(handle:start(name, function(number)
				interrupted = number
			end))
		end
		local announced = false
		while not held do
			if interrupted then
				return { code = 128 + interrupted, out = "", err = "" }
			end
			local fd, err = uv.fs_open(lock, "wx", 384)
			if fd then
				held = true
				local metadata = rt.encode(owner) .. "\n"
				local written, problem = uv.fs_write(fd, metadata, 0)
				local closed, close_error = uv.fs_close(fd)
				assert(written == #metadata, problem or "short gate metadata write")
				assert(closed, close_error)
			else
				assert(tostring(err):find("EEXIST", 1, true), err)
				local holder = read_owner()
				if stale(holder) then
					-- Reapers must re-read under their own lock before unlinking a stale owner.
					if rt.mkdir_lock(reaper) then
						reaping = true
						local reaped, problem = pcall(function()
							if stale(read_owner()) then
								assert(uv.fs_unlink(lock))
								emit("orc gate: taking over stale lock\n", true)
							end
						end)
						rt.rmdir(reaper)
						reaping = false
						assert(reaped, problem)
					else
						local stat = uv.fs_stat(reaper)
						if stat and os.time() - stat.mtime.sec > 60 then
							rt.rmdir(reaper)
						end
					end
				elseif not announced then
					announced = true
					emit(
						string.format(
							"orc gate: waiting for %s in %s (age %ds)\n",
							tostring(holder.label or "unknown"),
							tostring(holder.cwd or "unknown"),
							math.max(0, os.time() - (tonumber(holder.startedAt) or os.time()))
						),
						true
					)
				end
				assert(not write_error, write_error)
				rt.sleep(250)
			end
		end
		if flags.log then
			local path = rt.abspath(flags.log)
			assert(
				path ~= lock and uv.fs_realpath(path) ~= uv.fs_realpath(lock),
				"orc gate: log must not overwrite the lock"
			)
			log = assert(io.open(path, "w"))
		end
		child = rt.stream(command, {
			cwd = rt.cwd,
			on_stderr = function(chunk)
				emit(chunk, true)
			end,
			on_exit = function(value)
				finished = value
			end,
		}, function(chunk)
			emit(chunk, false)
		end)
		while not finished do
			if interrupted or write_error then
				child.stop()
			end
			rt.sleep(25)
		end
		assert(not write_error, write_error)
		return {
			code = interrupted and 128 + interrupted
				or finished.signal ~= 0 and 128 + finished.signal
				or finished.code,
			out = "",
			err = "",
		}
	end, debug.traceback)
	cleanup()
	vim.api.nvim_del_autocmd(leave)
	assert(ok, response)
	return response
end

return M
