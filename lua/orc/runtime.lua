local M = {}
local uv = vim.uv
local serial = 0

---@class orc.ProcessResult
---@field code integer Process exit code; 127 when the executable is missing.
---@field signal integer Terminating signal, or zero.
---@field stdout string Captured standard output.
---@field stderr string Captured diagnostics.

---@class orc.ProcessOptions
---@field cwd? string Working directory, defaulting to the runtime's cwd.
---@field env? table<string,string|number|false> Overrides; false removes a variable.
---@field stdin? string Input for a captured command.
---@field timeout? integer Timeout in milliseconds for captured commands.

local function environment(base, overrides)
	local env = vim.deepcopy(base)
	for key, value in pairs(overrides or {}) do
		env[key] = value ~= false and tostring(value) or nil
	end
	return env
end

local function spawn_error(err)
	return tostring(err):find("ENOENT", 1, true) and 127 or 1
end

local function source_root()
	local source = debug.getinfo(1, "S").source:sub(2)
	local file = assert(uv.fs_realpath(source))
	return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(file)))
end

---@class orc.Runtime
---@field root string Absolute plugin root, resolved through symlinks.
---@field cwd string Original working directory.
---@field env table<string,string> Runtime environment, independent of vim.env.
---@field null userdata JSON null sentinel.
---@field exec fun(argv:string[], opts?:orc.ProcessOptions):orc.ProcessResult
---@field interactive fun(argv:string[], opts?:orc.ProcessOptions):integer
---@field read fun(path:string):string?,string?
---@field write fun(path:string,text:string) Atomically replace a file; throw on failure.
---@field mkdir fun(path:string) Create parent directories; throw on failure.
---@field remove fun(path:string) Remove a file or directory tree; missing paths are allowed.
---@field list fun(path:string):string[] Sorted entries; missing directories yield an empty list.
---@field exists fun(path:string):boolean
---@field path fun(...:string):string Join and normalize path components.
---@field abspath fun(path:string,base?:string):string
---@field encode fun(value:any):string
---@field decode fun(text:string):any
---@field now fun():string UTC RFC3339 timestamp.
---@field clock fun():number Monotonic milliseconds.
---@field sleep fun(ms:integer)

---@class orc.RuntimeOptions
---@field root? string Override the plugin location for a fixture.
---@field cwd? string Override the working directory.
---@field env? table<string,string> Environment overrides, merged with the current process.

---Create an isolated runtime. Tests can replace methods on the returned table.
---@param opts? orc.RuntimeOptions
---@return orc.Runtime
function M.new(opts)
	opts = opts or {}
	local rt = {
		root = opts.root or source_root(),
		cwd = opts.cwd or assert(uv.cwd()),
		env = environment(vim.fn.environ(), opts.env),
		null = vim.NIL,
	}

	rt.path = function(...)
		return vim.fs.normalize(vim.fs.joinpath(...))
	end
	rt.abspath = function(path, base)
		if path == "~" or path:sub(1, 2) == "~/" then
			path = rt.path(assert(rt.env.HOME, "HOME is not set"), path:sub(3))
		end
		return path:sub(1, 1) == "/" and vim.fs.normalize(path) or rt.path(base or rt.cwd, path)
	end
	rt.encode = vim.json.encode
	rt.decode = vim.json.decode
	rt.now = function()
		return os.date("!%Y-%m-%dT%H:%M:%SZ")
	end
	rt.clock = function()
		return uv.hrtime() / 1000000
	end
	rt.sleep = function(ms)
		assert(type(ms) == "number" and ms >= 0, "sleep needs nonnegative milliseconds")
		vim.wait(ms, function()
			return false
		end, math.max(1, math.min(ms, 10)))
	end

	rt.exec = function(argv, options)
		options = options or {}
		local ok, result = pcall(function()
			return vim.system(argv, {
				cwd = options.cwd or rt.cwd,
				env = environment(rt.env, options.env),
				clear_env = true,
				stdin = options.stdin,
				timeout = options.timeout,
				text = true,
			}):wait()
		end)
		if not ok then
			return { code = spawn_error(result), signal = 0, stdout = "", stderr = tostring(result) }
		end
		return {
			code = result.code,
			signal = result.signal,
			stdout = result.stdout or "",
			stderr = result.stderr or "",
		}
	end

	rt.interactive = function(argv, options)
		options = options or {}
		assert(type(argv) == "table" and type(argv[1]) == "string", "command needs an executable")
		local env = {}
		for key, value in pairs(environment(rt.env, options.env)) do
			env[#env + 1] = key .. "=" .. value
		end
		table.sort(env)
		local finished, code, signal = false, 1, 0
		local handle, err = uv.spawn(argv[1], {
			args = vim.list_slice(argv, 2),
			cwd = options.cwd or rt.cwd,
			env = env,
			stdio = { 0, 1, 2 },
		}, function(exit_code, exit_signal)
			code, signal, finished = exit_code, exit_signal, true
		end)
		if not handle then
			io.stderr:write(tostring(err) .. "\n")
			return spawn_error(err)
		end
		local watchers = {}
		for _, name in ipairs({ "sigint", "sigterm" }) do
			local watcher = assert(uv.new_signal())
			watcher:start(name, function()
				if not finished then
					pcall(handle.kill, handle, name)
				end
			end)
			watchers[#watchers + 1] = watcher
		end
		while not finished do
			local _, reason = vim.wait(1000, function()
				return finished
			end, 10)
			if reason == -2 and not finished then
				pcall(handle.kill, handle, "sigint")
			end
		end
		for _, watcher in ipairs(watchers) do
			watcher:stop()
			watcher:close()
		end
		handle:close()
		return signal == 0 and code or 128 + signal
	end

	rt.read = function(path)
		local fd, err = uv.fs_open(path, "r", 0)
		if not fd then
			return nil, err
		end
		local stat, stat_err = uv.fs_fstat(fd)
		if not stat then
			uv.fs_close(fd)
			return nil, stat_err
		end
		local data, read_err = uv.fs_read(fd, stat.size, 0)
		local closed, close_err = uv.fs_close(fd)
		if not closed then
			return nil, close_err
		end
		return data, read_err
	end
	rt.exists = function(path)
		return uv.fs_stat(path) ~= nil
	end
	rt.mkdir = function(path)
		if vim.fn.mkdir(path, "p") == 0 and not rt.exists(path) then
			error("cannot create directory: " .. path, 0)
		end
	end
	rt.write = function(path, text)
		rt.mkdir(vim.fs.dirname(path))
		serial = serial + 1
		local temporary = path .. ".tmp." .. uv.os_getpid() .. "." .. serial
		local fd = assert(uv.fs_open(temporary, "wx", 384))
		local ok, err = pcall(function()
			local offset = 0
			while offset < #text do
				local written = assert(uv.fs_write(fd, text:sub(offset + 1), offset))
				assert(written > 0, "file write made no progress")
				offset = offset + written
			end
			assert(uv.fs_fsync(fd))
			assert(uv.fs_close(fd))
			fd = nil
			assert(uv.fs_rename(temporary, path))
		end)
		if not ok then
			if fd then
				uv.fs_close(fd)
			end
			uv.fs_unlink(temporary)
			error(err, 0)
		end
	end
	rt.remove = function(path)
		local stat, err = uv.fs_lstat(path)
		if not stat then
			if err and not err:find("ENOENT", 1, true) then
				error(err, 0)
			end
			return
		end
		local flags = stat.type == "directory" and "rf" or ""
		assert(vim.fn.delete(path, flags) == 0, "cannot remove: " .. path)
	end
	rt.list = function(path)
		local request, err = uv.fs_scandir(path)
		if not request then
			if err and err:find("ENOENT", 1, true) then
				return {}
			end
			error(err, 0)
		end
		local entries = {}
		while true do
			local name = uv.fs_scandir_next(request)
			if not name then
				break
			end
			entries[#entries + 1] = name
		end
		table.sort(entries)
		return entries
	end
	return rt
end

return M
