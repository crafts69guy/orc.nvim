local M = {}
local uv = vim.uv
local label = "io.crafts69guy.orc.inkdrop-mcp"
local credential_keys = {
	"INKDROP_LOCAL_USERNAME",
	"INKDROP_LOCAL_PASSWORD",
	"INKDROP_LOCAL_SERVER_URL",
}
local protocols = {
	["2025-11-25"] = true,
	["2025-06-18"] = true,
	["2025-03-26"] = true,
	["2024-11-05"] = true,
}

local function fail(message)
	error("orc Inkdrop MCP: " .. message, 0)
end

local function url(value)
	if type(value) ~= "string" then
		fail("shared endpoint must be a loopback HTTP URL")
	end
	local port, path = value:match("^http://127%.0%.0%.1:(%d+)(/[^%s?#]*)$")
	if not port or tonumber(port) < 1 or tonumber(port) > 65535 or path:find("[%z\1-\31\127]") then
		fail("shared endpoint must be HTTP on 127.0.0.1 with a valid port and path")
	end
	return value
end

---@class orc.InkdropMcpPaths
---@field dir string Private user service directory.
---@field config string User transport settings, optionally selected by environment.
---@field backend string Private native mcp-proxy named-server configuration.
---@field backups string Private migration receipts and exact configuration backups.
---@field plist string User LaunchAgent property list.
---@field log string Private service log.

---Resolve service paths independently of the current repository or worktree.
---@param rt orc.Runtime
---@return orc.InkdropMcpPaths
function M.paths(rt)
	local home = rt.env.HOME
	if type(home) ~= "string" or home:sub(1, 1) ~= "/" then
		fail("an absolute HOME is required")
	end
	local config = rt.env.ORC_INKDROP_MCP_CONFIG
	if config and (type(config) ~= "string" or config:sub(1, 1) ~= "/") then
		fail("ORC_INKDROP_MCP_CONFIG must be an absolute path")
	end
	local dir = config and vim.fs.dirname(config)
		or rt.path(home, "Library", "Application Support", "orc", "inkdrop-mcp")
	return {
		dir = dir,
		config = config or rt.path(dir, "config.json"),
		backend = rt.path(dir, "backend.json"),
		backups = rt.path(dir, "backups"),
		plist = rt.path(home, "Library", "LaunchAgents", label .. ".plist"),
		log = rt.path(dir, "service.log"),
	}
end

local function decode(rt, text, message)
	local ok, value = pcall(rt.decode, text)
	if not ok or type(value) ~= "table" or value == vim.NIL or vim.islist(value) then
		fail(message)
	end
	return value
end

---@class orc.InkdropMcpConfig
---@field mode 'inherit'|'shared' Whether the provider keeps its own transport or requires sharing.
---@field url? string Validated loopback endpoint when mode is shared.
---@field paths? orc.InkdropMcpPaths Service paths, absent for an unconfigured runtime without HOME.

---Resolve explicit, environment and user settings in that order; inherit performs no probe.
---@param rt orc.Runtime
---@param mode? string Explicit per-launch mode.
---@return orc.InkdropMcpConfig
function M.resolve(rt, mode)
	mode = mode or rt.env.ORC_INKDROP_MCP_MODE
	if mode and mode ~= "inherit" and mode ~= "shared" then
		fail("mode must be inherit or shared")
	end
	if not rt.env.HOME and not rt.env.ORC_INKDROP_MCP_CONFIG and mode ~= "shared" then
		return { mode = "inherit" }
	end
	local paths = M.paths(rt)
	if mode == "inherit" then
		return { mode = mode, paths = paths }
	end
	local ok, text, err = pcall(rt.read, paths.config)
	if not ok or not text and err and not err:find("ENOENT", 1, true) then
		fail("user configuration could not be read")
	end
	local settings = text and decode(rt, text, "user configuration is invalid") or {}
	mode = mode or settings.mode or "inherit"
	if mode ~= "inherit" and mode ~= "shared" then
		fail("mode must be inherit or shared")
	end
	if mode == "inherit" then
		return { mode = mode, paths = paths }
	end
	if settings.schemaVersion ~= 1 then
		fail("shared mode requires schemaVersion 1 user configuration")
	end
	return { mode = mode, url = url(settings.url), paths = paths }
end

local function private(stat, kind)
	return stat and stat.type == kind and stat.uid == uv.getuid() and stat.mode % 64 == 0
end

---Read only Inkdrop credentials from its private service file; absence permits legacy fallback.
---Validate the opened descriptor as well as its path before reading any bytes.
---@param rt orc.Runtime
---@return table<string,string>? credentials
function M.credentials(rt)
	if not rt.env.HOME and not rt.env.ORC_INKDROP_MCP_CONFIG then
		return nil
	end
	local paths = M.paths(rt)
	local stat, err = uv.fs_lstat(paths.backend)
	if not stat and err and err:find("ENOENT", 1, true) then
		return nil
	end
	if not private(stat, "file") or not private(uv.fs_lstat(paths.dir), "directory") then
		fail("backend credential file and directory must be private and owned by this user")
	end
	local fd = uv.fs_open(paths.backend, "r", 0)
	if not fd then
		fail("backend credential file could not be opened")
	end
	local opened = uv.fs_fstat(fd)
	local text
	if
		private(opened, "file")
		and opened.ino == stat.ino
		and opened.dev == stat.dev
		and opened.size <= 1048576
	then
		text = uv.fs_read(fd, opened.size, 0)
	end
	uv.fs_close(fd)
	if type(text) ~= "string" or #text ~= opened.size then
		fail("backend credential file could not be read safely")
	end
	local document = decode(rt, text, "backend credential configuration is invalid")
	local entry = type(document.mcpServers) == "table" and document.mcpServers.inkdrop
	local source = type(entry) == "table" and entry.env
	if type(source) ~= "table" then
		fail("backend credential configuration is invalid")
	end
	local result = {}
	for _, key in ipairs(credential_keys) do
		if type(source[key]) ~= "string" or source[key] == "" then
			fail("backend Inkdrop credentials are incomplete")
		end
		result[key] = source[key]
	end
	return result
end

---Quote one value for a curl config file.
---@param value string
---@return string
function M.curl_quote(value)
	return '"'
		.. value
			:gsub("\\", "\\\\")
			:gsub('"', '\\"')
			:gsub("\r", "\\r")
			:gsub("\n", "\\n")
			:gsub("\t", "\\t")
		.. '"'
end

local function token(value)
	return #value <= 256 and value:match("^[%w!#$%%&'*+%.%^_`|~-]+$") ~= nil
end

local function metadata(value)
	return type(value) == "string"
		and #value > 0
		and #value <= 128
		and not value:find("[%z\1-\31\127]")
end

local function response(rt, body, expected)
	expected = expected or 1
	local ok, value = pcall(rt.decode, body)
	if ok and type(value) == "table" and value.id == expected then
		return value
	end
	local data = {}
	local function event()
		local parsed, candidate = pcall(rt.decode, table.concat(data, "\n"))
		data = {}
		if parsed and type(candidate) == "table" and candidate.id == expected then
			return candidate
		end
	end
	for line in (body:gsub("\r\n", "\n") .. "\n\n"):gmatch("([^\n]*)\n") do
		if line == "" then
			local candidate = event()
			if candidate then
				return candidate
			end
		else
			local part = line:match("^data: ?(.*)$")
			if part then
				data[#data + 1] = part
			end
		end
	end
	fail("endpoint returned an invalid MCP response")
end

---Probe MCP protocol readiness with a short-lived downstream session, never invoking tools.
---Connection failures are redacted and never trigger service startup or STDIO fallback.
---@param rt orc.Runtime
---@param config orc.InkdropMcpConfig
---@return {ok:boolean,error?:string,serverName?:string,version?:string}
function M.check(rt, config)
	local deadline, session, protocol = rt.clock() + 2500, nil, nil
	local function request(method, body, cleanup)
		local remaining = math.floor(deadline - rt.clock() - (cleanup and 0 or 300))
		if remaining < 1 then
			fail("endpoint health check timed out")
		end
		local lines = {
			"silent",
			"show-error",
			"include",
			"max-redirs = 0",
			'noproxy = "*"',
			'proto = "=http"',
			"max-filesize = 1048576",
			'write-out = "\\n%{http_code}"',
			"request = " .. M.curl_quote(method),
			"url = " .. M.curl_quote(url(config.url)),
			"max-time = " .. tostring(remaining / 1000),
			'header = "Accept: application/json, text/event-stream"',
		}
		if session then
			lines[#lines + 1] = "header = " .. M.curl_quote("Mcp-Session-Id: " .. session)
		end
		if protocol then
			lines[#lines + 1] = "header = " .. M.curl_quote("MCP-Protocol-Version: " .. protocol)
		end
		if body then
			lines[#lines + 1] = 'header = "Content-Type: application/json"'
			lines[#lines + 1] = "data-binary = " .. M.curl_quote(rt.encode(body))
		end
		local result = rt.exec({ "curl", "--disable", "--config", "-" }, {
			stdin = table.concat(lines, "\n") .. "\n",
			timeout = remaining,
		})
		if result.code ~= 0 then
			fail("shared endpoint is unavailable")
		end
		if #result.stdout > 1048576 then
			fail("endpoint health response exceeded its limit")
		end
		local payload, status = result.stdout:match("^(.*)\n(%d%d%d)$")
		local headers, content
		if payload then
			headers, content = payload:match("^(.-)\r?\n\r?\n(.*)$")
		end
		if not headers then
			fail("endpoint returned an invalid HTTP response")
		end
		for line in headers:gmatch("[^\r\n]+") do
			local key, value = line:match("^([^:]+):%s*(.-)%s*$")
			if key and key:lower() == "mcp-session-id" then
				if not token(value) or session and session ~= value then
					fail("endpoint returned an invalid session identifier")
				end
				session = value
			end
		end
		status = tonumber(status)
		if cleanup and status == 404 then
			return ""
		end
		if status < 200 or status >= 300 then
			fail("endpoint health request failed")
		end
		return content
	end
	local ok, result = pcall(function()
		local message = response(
			rt,
			request("POST", {
				jsonrpc = "2.0",
				id = 1,
				method = "initialize",
				params = {
					protocolVersion = "2025-11-25",
					capabilities = vim.empty_dict(),
					clientInfo = { name = "orc-health", version = "0.1.0" },
				},
			})
		)
		local value = message.result
		local info = type(value) == "table" and value.serverInfo
		local negotiated = type(value) == "table" and value.protocolVersion
		if
			message.jsonrpc ~= "2.0"
			or message.error
			or type(info) ~= "table"
			or not metadata(info.name)
			or info.name ~= "Inkdrop"
			or not metadata(info.version)
			or type(value.capabilities) ~= "table"
			or vim.islist(value.capabilities)
			or type(value.capabilities.tools) ~= "table"
			or vim.islist(value.capabilities.tools)
			or not protocols[negotiated]
		then
			fail("endpoint returned an invalid MCP initialize response")
		end
		protocol = negotiated
		request("POST", { jsonrpc = "2.0", method = "notifications/initialized" })
		local catalog = response(
			rt,
			request("POST", { jsonrpc = "2.0", id = 2, method = "tools/list", params = vim.empty_dict() }),
			2
		)
		local tools = type(catalog.result) == "table" and catalog.result.tools
		if
			catalog.jsonrpc ~= "2.0"
			or catalog.error
			or type(tools) ~= "table"
			or not vim.islist(tools)
		then
			fail("endpoint returned an invalid Inkdrop tool catalog")
		end
		local names = {}
		for _, tool in ipairs(tools) do
			if type(tool) ~= "table" or type(tool.name) ~= "string" then
				fail("endpoint returned an invalid Inkdrop tool catalog")
			end
			names[tool.name] = true
		end
		if not names["read-note"] or not names["list-notebooks"] then
			fail("endpoint is missing canonical Inkdrop tools")
		end
		return { ok = true, serverName = info.name, version = info.version }
	end)
	if session then
		local closed = pcall(request, "DELETE", nil, true)
		if not closed and ok then
			ok, result = false, "orc Inkdrop MCP: endpoint session cleanup failed"
		end
	end
	if ok then
		return result
	end
	local message = type(result) == "string" and result:match("^orc Inkdrop MCP: ([^\n]+)$")
	return { ok = false, error = message or "endpoint health check failed" }
end

return M
