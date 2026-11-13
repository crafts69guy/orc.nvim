local mcp = require("orc.inkdrop_mcp")
local runtime = require("orc.runtime")
local uv = vim.uv

local function fixture()
	return runtime.new({
		env = { HOME = Test.temp(), ORC_INKDROP_MCP_MODE = false, ORC_INKDROP_MCP_CONFIG = false },
	})
end

local function settings(rt, value)
	local paths = mcp.paths(rt)
	rt.write(paths.config, type(value) == "string" and value or rt.encode(value))
	return paths
end

local function backend(rt)
	local paths = mcp.paths(rt)
	rt.mkdir(paths.dir)
	assert(uv.fs_chmod(paths.dir, 448))
	local values = {
		INKDROP_LOCAL_USERNAME = "fixture-user",
		INKDROP_LOCAL_PASSWORD = "fixture-secret",
		INKDROP_LOCAL_SERVER_URL = "http://localhost:19840",
	}
	rt.write(
		paths.backend,
		rt.encode({
			mcpServers = {
				inkdrop = { env = vim.tbl_extend("force", values, { UNRELATED = "ignored" }) },
			},
		})
	)
	assert(uv.fs_chmod(paths.backend, 384))
	return paths, values
end

local function with_uv(overrides, fn)
	local old = {}
	for key, value in pairs(overrides) do
		old[key], uv[key] = uv[key], value
	end
	local ok, err = xpcall(fn, debug.traceback)
	for key, value in pairs(old) do
		uv[key] = value
	end
	assert(ok, err)
end

local function redacted(fn)
	local ok, err = pcall(fn)
	assert(not ok)
	assert(not tostring(err):find("fixture-secret", 1, true), tostring(err))
	return tostring(err)
end

Test.test(
	"inkdrop_mcp paths and explicit inherit remain independent of repository and credentials",
	function()
		local rt = fixture()
		local paths = mcp.paths(rt)
		Test.eq(paths.dir, rt.path(rt.env.HOME, "Library", "Application Support", "orc", "inkdrop-mcp"))
		Test.eq(paths.config, paths.dir .. "/config.json")
		Test.eq(paths.backend, paths.dir .. "/backend.json")
		Test.eq(paths.backups, paths.dir .. "/backups")
		Test.eq(paths.log, paths.dir .. "/service.log")
		Test.eq(
			paths.plist,
			rt.path(rt.env.HOME, "Library", "LaunchAgents", "io.crafts69guy.orc.inkdrop-mcp.plist")
		)
		rt.env.ORC_INKDROP_MCP_CONFIG = rt.path(rt.env.HOME, "custom", "settings.json")
		Test.eq(mcp.paths(rt).backend, rt.path(rt.env.HOME, "custom", "backend.json"))
		rt.env.ORC_INKDROP_MCP_MODE = "shared"
		rt.read = function()
			error("must not read configuration for explicit inherit")
		end
		Test.eq(mcp.resolve(rt, "inherit"), { mode = "inherit", paths = mcp.paths(rt) })
		local empty = runtime.new()
		empty.env = {}
		Test.eq(mcp.resolve(empty), { mode = "inherit" })
		Test.eq(mcp.resolve(empty, "inherit"), { mode = "inherit" })
		Test.eq(mcp.credentials(empty), nil)
		Test.raises("absolute HOME", function()
			mcp.paths(empty)
		end)
		empty.env.HOME = "relative"
		Test.raises("absolute HOME", function()
			mcp.paths(empty)
		end)
		rt.env.ORC_INKDROP_MCP_CONFIG = "relative.json"
		Test.raises("absolute path", function()
			mcp.paths(rt)
		end)
		rt.env.ORC_INKDROP_MCP_CONFIG = 1
		Test.raises("absolute path", function()
			mcp.paths(rt)
		end)
	end
)

Test.test(
	"inkdrop_mcp resolves mode precedence and rejects malformed settings without echoing contents",
	function()
		local rt = fixture()
		Test.eq(mcp.resolve(rt).mode, "inherit")
		settings(
			rt,
			{ schemaVersion = 1, mode = "shared", url = "http://127.0.0.1:19841/servers/inkdrop/mcp" }
		)
		Test.eq(mcp.resolve(rt).url, "http://127.0.0.1:19841/servers/inkdrop/mcp")
		rt.env.ORC_INKDROP_MCP_MODE = "inherit"
		Test.eq(mcp.resolve(rt).mode, "inherit")
		Test.eq(mcp.resolve(rt, "shared").mode, "shared")
		settings(rt, { mode = "inherit" })
		rt.env.ORC_INKDROP_MCP_MODE = nil
		Test.eq(mcp.resolve(rt).mode, "inherit")
		Test.raises("schemaVersion", function()
			mcp.resolve(rt, "shared")
		end)
		for _, mode in ipairs({ "wrong", "", "SHARED" }) do
			Test.raises("mode must", function()
				mcp.resolve(rt, mode)
			end)
		end
		settings(rt, { mode = "wrong" })
		Test.raises("mode must", function()
			mcp.resolve(rt)
		end)
		for _, text in ipairs({ "fixture-secret{", "null", "false", "[]", "[1]", '"fixture-secret"' }) do
			settings(rt, text)
			assert(redacted(function()
				mcp.resolve(rt)
			end):find("configuration is invalid", 1, true))
		end
		rt.read = function()
			error("fixture-secret")
		end
		assert(redacted(function()
			mcp.resolve(rt)
		end):find("could not be read", 1, true))
		rt.read = function()
			return nil, "EACCES fixture-secret"
		end
		assert(redacted(function()
			mcp.resolve(rt)
		end):find("could not be read", 1, true))
		rt.read = function()
			return nil, "ENOENT missing"
		end
		Test.eq(mcp.resolve(rt).mode, "inherit")
	end
)

Test.test(
	"inkdrop_mcp shared endpoint accepts only literal loopback HTTP ports and paths",
	function()
		local rt = fixture()
		for _, endpoint in ipairs({
			"https://127.0.0.1:19841/mcp",
			"http://localhost:19841/mcp",
			"http://127.0.0.1/mcp",
			"http://127.0.0.1:0/mcp",
			"http://127.0.0.1:65536/mcp",
			"http://127.0.0.1:19841",
			"http://127.0.0.1.evil:19841/mcp",
			"http://user@127.0.0.1:19841/mcp",
			"http://127.0.0.1:19841/mcp?token=fixture-secret",
			"http://127.0.0.1:19841/mcp#fragment",
			"http://127.0.0.1:19841/m cp",
			"http://127.0.0.1:19841/mcp\0",
			"http://127.0.0.1:19841/mcp\127",
		}) do
			settings(rt, { schemaVersion = 1, mode = "shared", url = endpoint })
			redacted(function()
				mcp.resolve(rt)
			end)
		end
		settings(rt, { schemaVersion = 1, mode = "shared", url = 1 })
		Test.raises("loopback HTTP URL", function()
			mcp.resolve(rt)
		end)
		for _, port in ipairs({ 1, 65535 }) do
			settings(
				rt,
				{ schemaVersion = 1, mode = "shared", url = "http://127.0.0.1:" .. port .. "/mcp" }
			)
			Test.eq(mcp.resolve(rt).mode, "shared")
		end
	end
)

Test.test(
	"inkdrop_mcp credentials read only private same-user files and discard unrelated environment",
	function()
		local rt = fixture()
		Test.eq(mcp.credentials(rt), nil)
		local paths, values = backend(rt)
		Test.eq(mcp.credentials(rt), values)
		assert(uv.fs_chmod(paths.backend, 420))
		Test.raises("private and owned", function()
			mcp.credentials(rt)
		end)
		assert(uv.fs_chmod(paths.backend, 384))
		assert(uv.fs_chmod(paths.dir, 493))
		Test.raises("private and owned", function()
			mcp.credentials(rt)
		end)
		assert(uv.fs_chmod(paths.dir, 448))
		local stat = uv.fs_lstat
		with_uv({
			fs_lstat = function(path)
				local result, err = stat(path)
				if path == paths.backend then
					result.uid = result.uid + 1
				end
				return result, err
			end,
		}, function()
			Test.raises("private and owned", function()
				mcp.credentials(rt)
			end)
		end)
		local real = paths.backend .. ".real"
		assert(uv.fs_rename(paths.backend, real))
		assert(uv.fs_symlink(real, paths.backend))
		Test.raises("private and owned", function()
			mcp.credentials(rt)
		end)
		assert(uv.fs_unlink(paths.backend))
		assert(uv.fs_rename(real, paths.backend))
		local original = paths.dir .. ".real"
		assert(uv.fs_rename(paths.dir, original))
		assert(uv.fs_symlink(original, paths.dir))
		Test.raises("private and owned", function()
			mcp.credentials(rt)
		end)
		assert(uv.fs_unlink(paths.dir))
		assert(uv.fs_rename(original, paths.dir))
	end
)

Test.test(
	"inkdrop_mcp credential reads close descriptors and fail closed on races and filesystem failures",
	function()
		local rt = fixture()
		local paths = backend(rt)
		with_uv({
			fs_lstat = function()
				return nil, "EACCES fixture-secret"
			end,
		}, function()
			redacted(function()
				mcp.credentials(rt)
			end)
		end)
		with_uv({
			fs_open = function()
				return nil, "fixture-secret"
			end,
		}, function()
			assert(redacted(function()
				mcp.credentials(rt)
			end):find("could not be opened", 1, true))
		end)
		local fstat, close = uv.fs_fstat, uv.fs_close
		for _, changed in ipairs({ "ino", "size", "uid", "type", "missing" }) do
			local closed = 0
			with_uv({
				fs_fstat = function(fd)
					local result = fstat(fd)
					if changed == "ino" then
						result.ino = result.ino + 1
					elseif changed == "size" then
						result.size = 1048577
					elseif changed == "uid" then
						result.uid = result.uid + 1
					elseif changed == "type" then
						result.type = "link"
					else
						return nil
					end
					return result
				end,
				fs_close = function(fd)
					closed = closed + 1
					return close(fd)
				end,
			}, function()
				redacted(function()
					mcp.credentials(rt)
				end)
				Test.eq(closed, 1)
			end)
		end
		for _, read in ipairs({
			function()
				return nil, "fixture-secret"
			end,
			function()
				return "short"
			end,
		}) do
			with_uv({ fs_read = read }, function()
				redacted(function()
					mcp.credentials(rt)
				end)
			end)
		end
		for _, content in ipairs({
			"fixture-secret{",
			"null",
			"[]",
			"{}",
			'{"mcpServers":{"inkdrop":{"env":{}}}}',
			'{"mcpServers":{"inkdrop":{"env":{"INKDROP_LOCAL_USERNAME":1}}}}',
		}) do
			rt.write(paths.backend, content)
			redacted(function()
				mcp.credentials(rt)
			end)
		end
	end
)

local function http(code, body, headers)
	return {
		code = 0,
		stdout = "HTTP/1.1 "
			.. code
			.. " Result\r\n"
			.. (headers or "")
			.. "\r\n"
			.. (body or "")
			.. "\n"
			.. code,
		stderr = "",
	}
end

local function initialized(rt)
	return rt.encode({
		jsonrpc = "2.0",
		id = 1,
		result = {
			protocolVersion = "2025-11-25",
			capabilities = { tools = vim.empty_dict() },
			serverInfo = { name = "Inkdrop", version = "1.3.0" },
		},
	})
end

local function catalog(rt)
	return rt.encode({
		jsonrpc = "2.0",
		id = 2,
		result = { tools = { { name = "read-note" }, { name = "list-notebooks" } } },
	})
end

local function probe(rt, replies)
	local calls = {}
	rt.exec = function(argv, opts)
		calls[#calls + 1] = { argv = argv, opts = opts }
		local reply = assert(replies[#calls], "unexpected probe request")
		return type(reply) == "function" and reply(opts) or reply
	end
	return function(config)
		return mcp.check(rt, config or { mode = "shared", url = "http://127.0.0.1:19841/mcp" }), calls
	end
end

Test.test(
	"inkdrop_mcp health performs an isolated protocol handshake and closes its downstream session",
	function()
		local rt = fixture()
		local run = probe(rt, {
			http(200, initialized(rt), "Mcp-Session-Id: private-session\r\n"),
			http(202),
			http(200, catalog(rt)),
			http(200),
		})
		local result, calls = run()
		Test.eq(result, { ok = true, serverName = "Inkdrop", version = "1.3.0" })
		Test.eq(#calls, 4)
		for _, call in ipairs(calls) do
			Test.eq(call.argv, { "curl", "--disable", "--config", "-" })
			assert(call.opts.timeout <= 10000)
			assert(call.opts.stdin:find('noproxy = "*"', 1, true))
			assert(call.opts.stdin:find("max-redirs = 0", 1, true))
			assert(not call.opts.stdin:find("fixture-secret", 1, true))
			assert(not call.opts.stdin:find("tools/call", 1, true))
		end
		assert(calls[1].opts.stdin:find('\\"capabilities\\":{}', 1, true))
		assert(calls[2].opts.stdin:find("notifications/initialized", 1, true))
		assert(calls[2].opts.stdin:find("MCP-Protocol-Version: 2025-11-25", 1, true))
		assert(calls[3].opts.stdin:find("tools/list", 1, true))
		assert(calls[4].opts.stdin:find('request = "DELETE"', 1, true))
		assert(calls[4].opts.stdin:find("Mcp-Session-Id: private-session", 1, true))
	end
)

Test.test(
	"inkdrop_mcp health supports SSE responses, stateless endpoints and already-closed sessions",
	function()
		local rt = fixture()
		local body = ': keepalive\r\n\r\nevent: message\r\ndata: {"jsonrpc":"2.0","method":"notice"}\r\n\r\nevent: message\r\ndata: '
			.. initialized(rt)
			.. "\r\n\r\n"
		local result, calls = probe(rt, { http(200, body), http(204), http(200, catalog(rt)) })()
		Test.eq(result.ok, true)
		Test.eq(#calls, 3)
		local multi =
			'event: message\ndata: {"jsonrpc":"2.0","id":1,\ndata: "result":{"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"Inkdrop","version":"1"}}}\n'
		Test.eq(
			probe(rt, {
				http(200, multi, "mcp-session-id: x\r\n"),
				http(202),
				http(200, "data: " .. catalog(rt) .. "\n\n"),
				http(404),
			})().ok,
			true
		)
	end
)

Test.test("inkdrop_mcp health redacts HTTP transport and malformed protocol failures", function()
	local rt = fixture()
	local failures = {
		{ code = 7, stdout = "", stderr = "fixture-secret" },
		{ code = 0, stdout = string.rep("x", 1048577), stderr = "" },
		{ code = 0, stdout = "fixture-secret", stderr = "" },
		http(302, "fixture-secret"),
		http(199, "fixture-secret"),
		http(401, "fixture-secret"),
		http(200, "fixture-secret"),
		http(200, '{"jsonrpc":"2.0","id":1,"error":{"message":"fixture-secret"}}'),
		http(200, '{"jsonrpc":"2.0","id":2,"result":{}}'),
		http(200, initialized(rt), "Mcp-Session-Id: unsafe value\r\n"),
		http(200, initialized(rt), "Mcp-Session-Id: " .. string.rep("a", 257) .. "\r\n"),
		http(200, initialized(rt), "Mcp-Session-Id: one\r\nMcp-Session-Id: two\r\n"),
	}
	for _, failure in ipairs(failures) do
		local result = probe(rt, { failure, http(200) })()
		Test.eq(result.ok, false)
		assert(result.error and not result.error:find("fixture-secret", 1, true))
	end
	for _, response in ipairs({
		{ jsonrpc = "1.0", id = 1, result = {} },
		{
			jsonrpc = "2.0",
			id = 1,
			result = {
				protocolVersion = "unsafe\nheader",
				serverInfo = { name = "Inkdrop", version = "1" },
			},
		},
		{
			jsonrpc = "2.0",
			id = 1,
			result = { protocolVersion = 1, serverInfo = { name = "Inkdrop", version = "1" } },
		},
		{
			jsonrpc = "2.0",
			id = 1,
			result = { protocolVersion = "2025-11-25", serverInfo = { name = 1, version = "1" } },
		},
		{
			jsonrpc = "2.0",
			id = 1,
			result = {
				protocolVersion = "2025-11-25",
				serverInfo = { name = "Inkdrop", version = false },
			},
		},
	}) do
		Test.eq(probe(rt, { http(200, rt.encode(response)) })().ok, false)
	end
	local bad = probe(rt, {})({ mode = "shared", url = "http://fixture-secret.example/mcp" })
	Test.eq(bad.ok, false)
	assert(not bad.error:find("fixture-secret", 1, true))
	for _, field in ipairs({ "name", "version" }) do
		for _, invalid in ipairs({ "", "line\nchange", string.rep("x", 129) }) do
			local message = rt.decode(initialized(rt))
			message.result.serverInfo[field] = invalid
			Test.eq(probe(rt, { http(200, rt.encode(message)) })().ok, false)
		end
	end
	local message = rt.decode(initialized(rt))
	message.result.capabilities = nil
	Test.eq(probe(rt, { http(200, rt.encode(message)) })().ok, false)
	for _, version in ipairs({ "unsupported", "2025-06-18", "2025-03-26", "2024-11-05" }) do
		message = rt.decode(initialized(rt))
		message.result.protocolVersion = version
		Test.eq(
			probe(rt, { http(200, rt.encode(message)), http(202), http(200, catalog(rt)) })().ok,
			version ~= "unsupported"
		)
	end
end)

Test.test(
	"inkdrop_mcp health always attempts cleanup after initialization and preserves a total deadline",
	function()
		local rt = fixture()
		local result, calls =
			probe(rt, { http(200, "fixture-secret", "Mcp-Session-Id: safe\r\n"), http(200) })()
		Test.eq(result.ok, false)
		Test.eq(#calls, 2)
		assert(calls[2].opts.stdin:find('request = "DELETE"', 1, true))
		result, calls =
			probe(rt, { http(200, initialized(rt), "Mcp-Session-Id: safe\r\n"), http(500), http(200) })()
		Test.eq(result.ok, false)
		Test.eq(#calls, 3)
		result = probe(rt, {
			http(200, initialized(rt), "Mcp-Session-Id: safe\r\n"),
			http(202),
			http(200, catalog(rt)),
			http(500),
		})()
		Test.eq(result, { ok = false, error = "endpoint session cleanup failed" })
		local now = 0
		rt.clock = function()
			return now
		end
		result, calls = probe(rt, {
			function()
				now = 9900
				return http(200, initialized(rt), "Mcp-Session-Id: safe\r\n")
			end,
			http(204),
		})()
		Test.eq(result.ok, false)
		Test.eq(#calls, 2)
		Test.eq(calls[2].opts.timeout, 100)
		-- A slow endpoint is reported as a timeout, a refused connection as unavailable.
		for code, message in pairs({
			[28] = "endpoint health check timed out",
			[124] = "endpoint health check timed out",
			[7] = "shared endpoint is unavailable",
		}) do
			now = 0
			result = probe(rt, { { code = code, stdout = "", stderr = "" } })()
			Test.eq(result, { ok = false, error = message })
		end
		rt.exec = function()
			error("fixture-secret")
		end
		Test.eq(
			mcp.check(rt, { mode = "shared", url = "http://127.0.0.1:19841/mcp" }),
			{ ok = false, error = "endpoint health check failed" }
		)
		rt.exec = function()
			error({ secret = "fixture-secret" })
		end
		Test.eq(
			mcp.check(rt, { mode = "shared", url = "http://127.0.0.1:19841/mcp" }),
			{ ok = false, error = "endpoint health check failed" }
		)
	end
)

Test.test(
	"inkdrop_mcp health rejects foreign servers malformed capabilities and missing canonical tools",
	function()
		local rt = fixture()
		for _, change in ipairs({
			function(value)
				value.serverInfo.name = "Other MCP"
			end,
			function(value)
				value.capabilities = {}
			end,
			function(value)
				value.capabilities = vim.empty_dict()
			end,
			function(value)
				value.capabilities.tools = false
			end,
			function(value)
				value.capabilities.tools = {}
			end,
		}) do
			local message = rt.decode(initialized(rt))
			change(message.result)
			local result, calls =
				probe(rt, { http(200, rt.encode(message), "Mcp-Session-Id: safe\r\n"), http(200) })()
			Test.eq(result.ok, false)
			Test.eq(#calls, 2)
		end
		for _, message in ipairs({
			{ jsonrpc = "1.0", id = 2, result = { tools = {} } },
			{ jsonrpc = "2.0", id = 2, error = { message = "fixture-secret" } },
			{ jsonrpc = "2.0", id = 2, result = false },
			{ jsonrpc = "2.0", id = 2, result = { tools = false } },
			{ jsonrpc = "2.0", id = 2, result = { tools = { bad = "fixture-secret" } } },
			{ jsonrpc = "2.0", id = 2, result = { tools = { "bad" } } },
			{ jsonrpc = "2.0", id = 2, result = { tools = { { name = 1 } } } },
			{ jsonrpc = "2.0", id = 2, result = { tools = { { name = "list-notebooks" } } } },
			{ jsonrpc = "2.0", id = 2, result = { tools = { { name = "read-note" } } } },
		}) do
			local result, calls = probe(rt, {
				http(200, initialized(rt), "Mcp-Session-Id: safe\r\n"),
				http(202),
				http(200, rt.encode(message)),
				http(200),
			})()
			Test.eq(result.ok, false)
			assert(not result.error:find("fixture-secret", 1, true))
			Test.eq(#calls, 4)
		end
	end
)

Test.test(
	"inkdrop_mcp curl_quote escapes every control character curl config treats specially",
	function()
		Test.eq(require("orc.inkdrop_mcp").curl_quote('a\\b"c\r\n\td'), '"a\\\\b\\"c\\r\\n\\td"')
	end
)
