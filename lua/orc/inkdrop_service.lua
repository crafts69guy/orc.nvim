local M = {}
local uv = vim.uv
local LABEL = "io.crafts69guy.orc.inkdrop-mcp"
local PREFIX = "orc inkdrop-mcp: "
local locked
local usage =
	"usage: orc inkdrop-mcp install --proxy ABS --node ABS --backend ABS --port PORT [--credentials FILE] | start|stop|restart|status [--json] | enable|disable | migrate --provider claude|codex [--file ABS] [--apply] | rollback --provider claude|codex [--file ABS] | uninstall"

local function need(value, message)
	if not value then
		error(PREFIX .. message, 0)
	end
	return value
end

local function absolute(value)
	return type(value) == "string" and value:sub(1, 1) == "/" and not value:find("[%z\r\n]")
end

local function private(path, kind)
	local stat = uv.fs_lstat(path)
	need(stat and stat.type == kind, "private " .. kind .. " is missing or is a symlink")
	need(
		stat.uid == uv.getuid() and stat.mode % 64 == 0,
		"private path has unsafe ownership or permissions"
	)
	return stat
end

local function directory(rt, path)
	if uv.fs_lstat(path) then
		private(path, "directory")
	else
		rt.mkdir(path)
		need(uv.fs_chmod(path, 448), "cannot secure private directory")
		private(path, "directory")
	end
end

local function write_private(rt, path, body)
	if uv.fs_lstat(path) then
		private(path, "file")
	end
	rt.write(path, body)
	need(uv.fs_chmod(path, 384), "cannot secure private file")
end

local function json(rt, body, message)
	local ok, data = pcall(rt.decode, body or "")
	need(ok and type(data) == "table" and not vim.islist(data), message)
	return data
end

local function settings(rt, paths)
	private(paths.dir, "directory")
	private(paths.config, "file")
	local data = json(rt, rt.read(paths.config), "invalid installed settings")
	need(data.schemaVersion == 1 and type(data.service) == "table", "service is not installed")
	need(
		data.service.label == LABEL and data.service.uid == uv.getuid(),
		"service ownership mismatch"
	)
	local port = data.service.port
	need(
		type(port) == "number"
			and port % 1 == 0
			and port >= 1
			and port <= 65535
			and data.url == "http://127.0.0.1:" .. port .. "/servers/inkdrop/mcp",
		"installed service endpoint is invalid"
	)
	return data
end

local function checked(rt, argv, opts, message)
	local result = rt.exec(argv, opts)
	need(result.code == 0, message)
	return result.stdout
end

local function darwin(rt)
	need(
		vim.trim(checked(rt, { "uname", "-s" }, nil, "cannot inspect platform")) == "Darwin",
		"launchd control requires macOS"
	)
end

local function identity(data)
	return "gui/" .. data.service.uid, "gui/" .. data.service.uid .. "/" .. LABEL
end

local function intact(rt, paths, data)
	private(paths.backend, "file")
	need(
		vim.fn.sha256(need(rt.read(paths.backend), "missing backend configuration"))
			== data.service.backendHash,
		"backend configuration changed; refusing service control"
	)
	local stat = uv.fs_lstat(paths.plist)
	need(stat and stat.type == "file" and stat.uid == uv.getuid(), "service plist ownership mismatch")
	need(
		vim.fn.sha256(need(rt.read(paths.plist), "missing service plist")) == data.service.plistHash,
		"service plist changed; refusing service control"
	)
end

local function loaded(rt, paths, data)
	intact(rt, paths, data)
	local _, target = identity(data)
	local result = rt.exec({ "launchctl", "print", target }, { timeout = 3000 })
	if result.code ~= 0 then
		need(
			result.stderr:find("Could not find service", 1, true)
				or result.stderr:find("not found", 1, true),
			"cannot inspect launchd job"
		)
		return false
	end
	local text = "\n" .. result.stdout .. "\n"
	local job_path = text:match("\n%s*path = ([^\n]+)")
	local program = text:match("\n%s*program = ([^\n]+)")
	local own_path, own_program = uv.fs_realpath(paths.plist), uv.fs_realpath(data.service.proxy)
	-- launchd resolves aliases such as /var to /private/var in its submitted plist path.
	need(
		job_path
			and program
			and own_path
			and own_program
			and uv.fs_realpath(job_path) == own_path
			and uv.fs_realpath(program) == own_program
			and text:find("--named-server-config", 1, true)
			and text:find(paths.backend, 1, true),
		"loaded launchd job is not the installed service"
	)
	return true
end

local function xml(value)
	return value
		:gsub("&", "&amp;")
		:gsub("<", "&lt;")
		:gsub(">", "&gt;")
		:gsub('"', "&quot;")
		:gsub("'", "&apos;")
end

local function plist(paths, proxy, port)
	local args = {
		proxy,
		"--host",
		"127.0.0.1",
		"--port",
		tostring(port),
		"--log-level",
		"WARNING",
		"--named-server-config",
		paths.backend,
	}
	local lines = {
		'<?xml version="1.0" encoding="UTF-8"?>',
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
		'<plist version="1.0"><dict>',
		"<key>Label</key><string>" .. LABEL .. "</string>",
		"<key>ProgramArguments</key><array>",
	}
	for _, argument in ipairs(args) do
		lines[#lines + 1] = "<string>" .. xml(argument) .. "</string>"
	end
	vim.list_extend(lines, {
		"</array>",
		"<key>WorkingDirectory</key><string>" .. xml(paths.dir) .. "</string>",
		"<key>RunAtLoad</key><true/>",
		"<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>",
		"<key>ThrottleInterval</key><integer>10</integer>",
		"<key>ProcessType</key><string>Background</string>",
		"<key>StandardOutPath</key><string>" .. xml(paths.log) .. "</string>",
		"<key>StandardErrorPath</key><string>" .. xml(paths.log) .. "</string>",
		"</dict></plist>",
	})
	return table.concat(lines, "\n") .. "\n"
end

local function install(rt, flags, paths)
	for _, key in ipairs({ "proxy", "node", "backend" }) do
		need(absolute(flags[key]), "install requires absolute --" .. key)
		local stat = uv.fs_stat(flags[key])
		need(stat and stat.type == "file", "install dependency is missing")
	end
	local port = tonumber(flags.port)
	need(port and port % 1 == 0 and port >= 1 and port <= 65535, "install requires a valid --port")
	local version = checked(
		rt,
		{ flags.proxy, "--version" },
		{ timeout = 3000 },
		"cannot inspect proxy version"
	)
	need(version:match("%f[%d]0%.13%.3%f[^%d.]") ~= nil, "mcp-proxy 0.13.3 is required")
	checked(rt, { flags.node, "--version" }, { timeout = 3000 }, "cannot inspect Node executable")
	local package_path = rt.path(vim.fs.dirname(vim.fs.dirname(flags.backend)), "package.json")
	local package = json(rt, rt.read(package_path), "cannot inspect Inkdrop package")
	need(
		package.name == "@inkdropapp/mcp-server" and package.version == "1.5.0",
		"Inkdrop MCP package 1.5.0 is required"
	)
	local source = rt.env
	if flags.credentials then
		need(absolute(flags.credentials), "--credentials needs an absolute private JSON file")
		private(flags.credentials, "file")
		source = json(rt, rt.read(flags.credentials), "invalid credential file")
	end
	local env = {}
	for _, key in ipairs({
		"INKDROP_LOCAL_USERNAME",
		"INKDROP_LOCAL_PASSWORD",
		"INKDROP_LOCAL_SERVER_URL",
	}) do
		local value = source[key] or (key == "INKDROP_LOCAL_SERVER_URL" and "http://127.0.0.1:19840")
		need(type(value) == "string" and value ~= "", "Inkdrop credentials are incomplete")
		env[key] = value
	end
	need(
		env.INKDROP_LOCAL_SERVER_URL:match("^http://127%.0%.0%.1:%d+/?$")
			or env.INKDROP_LOCAL_SERVER_URL:match("^http://localhost:%d+/?$"),
		"Inkdrop data API must use loopback HTTP"
	)
	local backend = rt.encode({
		mcpServers = { inkdrop = { command = flags.node, args = { flags.backend }, env = env } },
	}) .. "\n"
	local body = plist(paths, flags.proxy, port)
	local service = {
		label = LABEL,
		uid = uv.getuid(),
		proxy = flags.proxy,
		node = flags.node,
		backend = flags.backend,
		port = port,
		backendHash = vim.fn.sha256(backend),
		plistHash = vim.fn.sha256(body),
	}
	directory(rt, paths.dir)
	return locked(paths.config, function()
		if rt.exists(paths.config) then
			local current = settings(rt, paths)
			service.backendHash = current.service.backendHash
			need(
				vim.deep_equal(current.service, service)
					and vim.deep_equal(
						json(rt, rt.read(paths.backend), "invalid backend configuration"),
						rt.decode(backend)
					),
				"different service install exists; disable, rollback and uninstall it first"
			)
			intact(rt, paths, current)
			return "already installed\n"
		end
		need(
			not rt.exists(paths.backend) and not rt.exists(paths.plist) and not rt.exists(paths.log),
			"unmanaged install files already exist"
		)
		directory(rt, paths.dir)
		directory(rt, paths.backups)
		need(#rt.list(paths.backups) == 0, "unmanaged migration backups already exist")
		rt.mkdir(vim.fs.dirname(paths.plist))
		local created = {}
		local ok = pcall(function()
			for _, entry in ipairs({
				{ paths.backend, backend },
				{ paths.log, "" },
				{ paths.plist, body },
				{
					paths.config,
					rt.encode({
						schemaVersion = 1,
						mode = "inherit",
						url = "http://127.0.0.1:" .. port .. "/servers/inkdrop/mcp",
						service = service,
					}) .. "\n",
				},
			}) do
				created[#created + 1] = entry[1]
				write_private(rt, entry[1], entry[2])
			end
		end)
		if not ok then
			for _, path in ipairs(created) do
				pcall(rt.remove, path)
			end
			pcall(rt.rmdir, paths.backups)
			pcall(rt.rmdir, paths.dir)
			need(
				false,
				"cannot complete private service installation; retry after checking filesystem permissions"
			)
		end
		return "installed in inherit mode; start and enable are explicit\n"
	end)
end

local function strip_comment(line)
	local quote, escaped = nil, false
	for index = 1, #line do
		local char = line:sub(index, index)
		if escaped then
			escaped = false
		elseif quote == '"' and char == "\\" then
			escaped = true
		elseif quote then
			if char == quote then
				quote = nil
			end
		elseif char == '"' or char == "'" then
			quote = char
		elseif char == "#" then
			return line:sub(1, index - 1)
		end
	end
	return line
end

local function key_prefix(text)
	text = vim.trim(text)
	local quote = text:sub(1, 1)
	local key = quote == '"' and text:match('^"([^"]*)"')
		or quote == "'" and text:match("^'([^']*)'")
		or text:match("^([%w_-]+)")
	if not key then
		return nil, text
	end
	return key, vim.trim(text:sub(#key + ((quote == '"' or quote == "'") and 3 or 1)))
end

local function header(line)
	local text = vim.trim(strip_comment(line))
	if text:sub(1, 1) ~= "[" then
		return nil
	end
	local array = text:sub(1, 2) == "[["
	local first, rest = key_prefix(text:sub(array and 3 or 2))
	if first ~= "mcp_servers" then
		return { first or false }
	end
	if rest:sub(1, 1) ~= "." then
		return { first }
	end
	local second
	second, rest = key_prefix(rest:sub(2))
	if second ~= "inkdrop" then
		return { first, second or false }
	end
	need(not array, "unsupported Inkdrop TOML array table")
	need(text:sub(-1) == "]", "unsupported Inkdrop TOML table header")
	if rest == "]" then
		return { first, second }
	end
	need(rest:sub(1, 1) == ".", "unsupported Inkdrop TOML table header")
	local third = key_prefix(rest:sub(2))
	need(third, "unsupported Inkdrop TOML table header")
	return { first, second, third }
end

local function multiline_state(line, delimiter)
	local index, quote, opened = 1, nil, false
	while index <= #line do
		local char, three = line:sub(index, index), line:sub(index, index + 2)
		if delimiter then
			if delimiter == '"""' and char == "\\" then
				index = index + 2
			elseif three == delimiter then
				delimiter = nil
				index = index + 3
				while line:sub(index, index) == char do
					index = index + 1
				end
			else
				index = index + 1
			end
		elseif quote then
			if quote == '"' and char == "\\" then
				index = index + 2
			else
				if char == quote then
					quote = nil
				end
				index = index + 1
			end
		elseif char == "#" then
			break
		elseif three == '"""' or three == "'''" then
			delimiter, opened, index = three, true, index + 3
		elseif char == '"' or char == "'" then
			quote, index = char, index + 1
		else
			index = index + 1
		end
	end
	return delimiter, opened
end

local transport = {
	command = true,
	args = true,
	env = true,
	env_vars = true,
	cwd = true,
	experimental_environment = true,
	environment_id = true,
	url = true,
}

local function single_line(value)
	local quote, escaped, square, curly = nil, false, 0, 0
	for index = 1, #value do
		local char = value:sub(index, index)
		if escaped then
			escaped = false
		elseif quote == '"' and char == "\\" then
			escaped = true
		elseif quote then
			if char == quote then
				quote = nil
			end
		elseif char == '"' or char == "'" then
			quote = char
		elseif char == "[" then
			square = square + 1
		elseif char == "]" then
			square = square - 1
		elseif char == "{" then
			curly = curly + 1
		elseif char == "}" then
			curly = curly - 1
		end
	end
	return not quote and square == 0 and curly == 0
end

local function codex_body(source, url, rt)
	local lines, section, found, multiline = {}, {}, false, nil
	local offset = 1
	for original_line in (source .. "\n"):gmatch("(.-)\n") do
		local raw = source:sub(offset, offset + #original_line)
		offset = offset + #original_line + 1
		local line = raw:gsub("[\r\n]+$", "")
		local inside = multiline ~= nil
		local opened
		multiline, opened = multiline_state(line, multiline)
		local next_section = not inside and header(line)
		if inside then
			lines[#lines + 1] = raw
		elseif next_section then
			section = next_section
			if section[1] == "mcp_servers" and section[2] == "inkdrop" and not section[3] then
				need(not found, "duplicate Inkdrop TOML table")
				found = true
				lines[#lines + 1] = raw:sub(-1) == "\n" and raw or raw .. "\n"
				lines[#lines + 1] = "url = " .. rt.encode(url) .. "\n"
			elseif
				not (section[1] == "mcp_servers" and section[2] == "inkdrop" and section[3] == "env")
			then
				lines[#lines + 1] = raw
			end
		elseif section[1] == "mcp_servers" and section[2] == "inkdrop" and section[3] == "env" then
			need(not opened, "multiline TOML transport values are unsupported")
			-- Credentials belong only in the private service backend configuration.
		elseif section[1] == "mcp_servers" and section[2] == "inkdrop" and not section[3] then
			local code = vim.trim(strip_comment(line))
			local key, value = code:match("^([%w_-]+)%s*=%s*(.*)$")
			if not key then
				key, value = code:match('^"([%w_-]+)"%s*=%s*(.*)$')
			end
			if not key then
				key, value = code:match("^'([%w_-]+)'%s*=%s*(.*)$")
			end
			if key and transport[key] then
				need(not opened and single_line(value), "multiline TOML transport values are unsupported")
			else
				lines[#lines + 1] = raw
			end
		else
			local code = vim.trim(strip_comment(line))
			local first, rest = key_prefix(code)
			need(
				not (section[1] == "mcp_servers" and not section[2] and first == "inkdrop"),
				"inline Inkdrop TOML tables are unsupported"
			)
			if not section[1] and first == "mcp_servers" then
				local second = rest:sub(1, 1) == "." and key_prefix(rest:sub(2))
				need(
					second and second ~= "inkdrop",
					"inline or dotted Inkdrop TOML configuration is unsupported"
				)
			end
			lines[#lines + 1] = raw
		end
	end
	need(not multiline, "unterminated TOML multiline string")
	if not found then
		lines[#lines + 1] = (source:sub(-1) == "\n" and "" or "\n")
			.. "[mcp_servers.inkdrop]\nurl = "
			.. rt.encode(url)
			.. "\n"
	end
	return table.concat(lines)
end

local function validate_codex(rt, body, url)
	local folder =
		need(uv.fs_mkdtemp(vim.fn.tempname() .. "-XXXXXX"), "cannot stage Codex configuration")
	local ok, result = pcall(function()
		write_private(rt, rt.path(folder, "config.toml"), body)
		local output = checked(
			rt,
			{ "codex", "mcp", "get", "inkdrop", "--json" },
			{ cwd = folder, env = { CODEX_HOME = folder }, timeout = 5000 },
			"staged Codex configuration is invalid or Codex is unavailable"
		)
		local data = json(rt, output, "invalid Codex configuration response")
		need(
			data.name == "inkdrop"
				and data.transport
				and data.transport.type == "streamable_http"
				and data.transport.url == url,
			"staged Codex transport did not match"
		)
	end)
	rt.remove(folder)
	need(
		ok,
		type(result) == "string" and result:sub(1, #PREFIX) == PREFIX and result:sub(#PREFIX + 1)
			or "cannot validate staged Codex configuration"
	)
end

local function provider_file(rt, flags)
	need(
		flags.provider == "claude" or flags.provider == "codex",
		"--provider must be claude or codex"
	)
	local file = flags.file
	if not file then
		file = flags.provider == "claude"
				and rt.path(rt.env.CLAUDE_CONFIG_DIR or rt.env.HOME, ".claude.json")
			or rt.path(rt.env.CODEX_HOME or rt.path(rt.env.HOME, ".codex"), "config.toml")
	end
	need(absolute(file), "provider configuration path must be absolute")
	return file
end

local function receipt_path(rt, paths, provider, file)
	return rt.path(paths.backups, provider .. "-" .. vim.fn.sha256(file):sub(1, 20) .. ".json")
end

locked = function(file, fn)
	local lock = file .. ".orc-inkdrop-mcp.lock"
	need(uv.fs_mkdir(lock, 448), "provider configuration is locked by another migration")
	local ok, value = pcall(fn)
	uv.fs_rmdir(lock)
	if not ok then
		error(value, 0)
	end
	return value
end

local function migrate(rt, flags, paths, data)
	local file = provider_file(rt, flags)
	local stat = uv.fs_lstat(file)
	need(
		stat and stat.type == "file" and stat.uid == uv.getuid(),
		"provider configuration must be a regular user-owned file"
	)
	local source = need(rt.read(file), "cannot read provider configuration")
	local body, after_entry
	if flags.provider == "claude" then
		local doc = json(rt, source, "invalid Claude configuration")
		need(
			doc.mcpServers == nil or type(doc.mcpServers) == "table",
			"invalid Claude MCP configuration"
		)
		doc.mcpServers = doc.mcpServers or vim.empty_dict()
		local entry = doc.mcpServers.inkdrop or {}
		need(type(entry) == "table", "invalid Claude Inkdrop entry")
		for _, key in ipairs({ "headers", "headersHelper", "oauth", "auth" }) do
			local value = entry[key]
			need(
				value == nil
					or value == vim.NIL
					or value == ""
					or type(value) == "table" and next(value) == nil,
				"Claude Inkdrop transport authentication requires explicit review before migration"
			)
			entry[key] = nil
		end
		for key in pairs(transport) do
			if key ~= "url" then
				entry[key] = nil
			end
		end
		entry.type, entry.url = "http", data.url
		doc.mcpServers.inkdrop, after_entry = entry, entry
		body = rt.encode(doc) .. "\n"
	else
		body = codex_body(source, data.url, rt)
		validate_codex(rt, body, data.url)
	end
	if not flags.apply then
		return "migration preview valid; no files changed; use --apply to opt in\n"
	end
	directory(rt, paths.backups)
	local receipt = receipt_path(rt, paths, flags.provider, file)
	return locked(file, function()
		need(not rt.exists(receipt), "migration receipt already exists; rollback first")
		need(rt.read(file) == source, "provider configuration changed during migration")
		local backup = receipt .. ".before"
		need(not rt.exists(backup), "unmanaged migration backup already exists")
		write_private(rt, backup, source)
		local document = {
			schemaVersion = 1,
			provider = flags.provider,
			file = file,
			backup = backup,
			beforeHash = vim.fn.sha256(source),
			afterHash = vim.fn.sha256(body),
			afterEntry = after_entry,
		}
		write_private(rt, receipt, rt.encode(document) .. "\n")
		-- shortcut: cooperative migrations are locked; native editors can still race the final read/rename.
		need(
			rt.read(file) == source,
			"provider configuration changed before atomic replacement; rollback receipt retained"
		)
		rt.write(file, body)
		need(uv.fs_chmod(file, stat.mode % 512), "cannot preserve provider configuration permissions")
		return "migrated Inkdrop only; private rollback receipt saved\n"
	end)
end

-- Claude rewrites its own file; restore only our entry while it still equals the migrated one.
local function claude_restored(rt, doc, current, source)
	if doc.provider ~= "claude" or type(doc.afterEntry) ~= "table" then
		return nil
	end
	local ok, live = pcall(rt.decode, current)
	if
		not ok
		or type(live) ~= "table"
		or type(live.mcpServers) ~= "table"
		or not vim.deep_equal(live.mcpServers.inkdrop, doc.afterEntry)
	then
		return nil
	end
	local before = json(rt, source, "invalid migration backup")
	local servers = type(before.mcpServers) == "table" and before.mcpServers or {}
	live.mcpServers.inkdrop = servers.inkdrop
	-- An emptied Lua table would encode as a JSON array.
	if next(live.mcpServers) == nil then
		live.mcpServers = vim.empty_dict()
	end
	return rt.encode(live) .. "\n"
end

local function rollback(rt, flags, paths)
	local file = provider_file(rt, flags)
	local receipt = receipt_path(rt, paths, flags.provider, file)
	private(paths.backups, "directory")
	private(receipt, "file")
	local doc = json(rt, rt.read(receipt), "invalid migration receipt")
	need(
		doc.schemaVersion == 1
			and doc.provider == flags.provider
			and doc.file == file
			and doc.backup == receipt .. ".before",
		"migration receipt identity mismatch"
	)
	private(doc.backup, "file")
	local source = need(rt.read(doc.backup), "cannot read migration backup")
	need(vim.fn.sha256(source) == doc.beforeHash, "migration backup changed")
	return locked(file, function()
		local stat = uv.fs_lstat(file)
		need(
			stat and stat.type == "file" and stat.uid == uv.getuid(),
			"provider configuration ownership changed"
		)
		local current = need(rt.read(file), "cannot read provider configuration")
		local hash = vim.fn.sha256(current)
		local restored
		if hash ~= doc.afterHash and hash ~= doc.beforeHash then
			restored = claude_restored(rt, doc, current, source)
			need(restored, "provider configuration has later user edits; refusing rollback")
		end
		need(rt.read(file) == current, "provider configuration changed during rollback")
		if hash ~= doc.beforeHash then
			rt.write(file, restored or source)
			need(uv.fs_chmod(file, stat.mode % 512), "cannot preserve provider configuration permissions")
		end
		rt.remove(receipt)
		rt.remove(doc.backup)
		return "rolled back exact provider configuration bytes\n"
	end)
end

local function execute(rt, argv)
	local command = argv[1]
	local specs = {
		install = {
			proxy = "string",
			node = "string",
			backend = "string",
			port = "string",
			credentials = "string",
		},
		start = {},
		stop = {},
		restart = {},
		enable = {},
		disable = {},
		uninstall = {},
		status = { json = "boolean" },
		migrate = { provider = "string", file = "string", apply = "boolean" },
		rollback = { provider = "string", file = "string" },
	}
	need(specs[command], usage)
	local flags, rest = require("orc.args").parse(vim.list_slice(argv, 2), specs[command])
	need(#rest == 0, usage)
	local config = require("orc.inkdrop_mcp")
	local paths = config.paths(rt)
	if command == "install" then
		return { code = 0, out = install(rt, flags, paths) }
	end
	if command == "status" and not rt.exists(paths.config) then
		return {
			code = 0,
			out = flags.json and rt.encode({ schemaVersion = 1, installed = false }) .. "\n"
				or "not installed\n",
		}
	end
	local function operate()
		local data = settings(rt, paths)
		if command == "migrate" then
			return { code = 0, out = migrate(rt, flags, paths, data) }
		end
		if command == "rollback" then
			return { code = 0, out = rollback(rt, flags, paths) }
		end
		if command == "disable" then
			data.mode = "inherit"
			write_private(rt, paths.config, rt.encode(data) .. "\n")
			return { code = 0, out = "inherit mode enabled; service lifecycle unchanged\n" }
		end
		if
			command == "status"
			and vim.trim(checked(rt, { "uname", "-s" }, nil, "cannot inspect platform")) ~= "Darwin"
		then
			return {
				code = 0,
				out = flags.json and rt.encode({
					schemaVersion = 1,
					installed = true,
					running = rt.null,
					mode = data.mode,
					platform = "unsupported",
				}) .. "\n" or "installed; launchd unavailable on this platform\n",
			}
		end
		darwin(rt)
		local running = loaded(rt, paths, data)
		local domain, target = identity(data)
		if command == "status" then
			return {
				code = 0,
				out = flags.json and rt.encode({
					schemaVersion = 1,
					installed = true,
					running = running,
					mode = data.mode,
					url = data.url,
				}) .. "\n" or (running and "running" or "stopped") .. " (" .. data.mode .. ")\n",
			}
		elseif command == "enable" then
			need(running, "service is stopped; start it explicitly")
			need(config.check(rt, config.resolve(rt, "shared")).ok, "shared MCP endpoint is unavailable")
			data.mode = "shared"
			write_private(rt, paths.config, rt.encode(data) .. "\n")
			return { code = 0, out = "shared mode enabled; existing sessions must reconnect\n" }
		elseif command == "start" then
			if not running then
				checked(
					rt,
					{ "launchctl", "bootstrap", domain, paths.plist },
					{ timeout = 5000 },
					"cannot bootstrap installed service"
				)
			end
			return { code = 0, out = running and "already running\n" or "service started\n" }
		elseif command == "restart" then
			need(running, "service is stopped; start it explicitly")
			checked(
				rt,
				{ "launchctl", "kickstart", "-k", target },
				{ timeout = 5000 },
				"cannot restart owned service"
			)
			return { code = 0, out = "service restarted; clients must reconnect\n" }
		elseif command == "stop" then
			if running then
				checked(
					rt,
					{ "launchctl", "bootout", target },
					{ timeout = 5000 },
					"cannot stop owned service"
				)
			end
			return { code = 0, out = "service stopped\n" }
		end
		for _, name in ipairs(rt.list(paths.backups)) do
			need(not name:match("%.json$"), "active migrations exist; rollback before uninstall")
		end
		if running then
			checked(
				rt,
				{ "launchctl", "bootout", target },
				{ timeout = 5000 },
				"cannot stop owned service"
			)
		end
		for _, path in ipairs({ paths.config, paths.backend, paths.plist, paths.log }) do
			rt.remove(path)
		end
		pcall(rt.rmdir, paths.backups)
		pcall(rt.rmdir, paths.dir)
		return { code = 0, out = "service uninstalled; unrelated private files retained\n" }
	end
	if command == "status" then
		return operate()
	end
	private(paths.dir, "directory")
	local result = locked(paths.config, operate)
	if command == "uninstall" then
		pcall(rt.rmdir, paths.dir)
	end
	return result
end

---Manage the explicitly opted-in user service and reversible provider migrations.
---Lifecycle commands never run from provider startup or worker shutdown.
---@param rt orc.Runtime
---@param argv string[] Command and strict long options; secret values are never accepted in argv.
---@return table result Redacted code/out/err document.
function M.run(rt, argv)
	local ok, value = pcall(execute, rt, argv)
	if ok then
		return value
	end
	local message = type(value) == "string" and value:match("^orc inkdrop%-mcp: (.*)$")
		or "operation failed; configuration and secrets were not logged"
	return { code = 1, out = "", err = PREFIX .. message .. "\n" }
end

return M
