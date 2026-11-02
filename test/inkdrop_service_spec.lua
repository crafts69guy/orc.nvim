local runtime = require("orc.runtime")
local service = require("orc.inkdrop_service")
local uv = vim.uv
local LABEL = "io.crafts69guy.orc.inkdrop-mcp"

local function fake()
	local home = Test.temp()
	local rt = runtime.new({ cwd = home, env = { HOME = home } })
	rt.env.CLAUDE_CONFIG_DIR, rt.env.CODEX_HOME, rt.env.ORC_INKDROP_MCP_CONFIG = nil, nil, nil
	rt.env.ORC_INKDROP_MCP_MODE = nil
	rt.env.INKDROP_LOCAL_USERNAME, rt.env.INKDROP_LOCAL_PASSWORD = "fixture-user", "fixture-secret<&"
	rt.env.INKDROP_LOCAL_SERVER_URL = "http://localhost:19840"
	local paths = require("orc.inkdrop_mcp").paths(rt)
	local state = { calls = {}, paths = paths, check = true }
	state.proxy, state.node, state.backend =
		home .. "/dependencies/proxy",
		home .. "/dependencies/node",
		home .. "/dependencies/inkdrop/dist/index.js"
	for _, file in ipairs({ state.proxy, state.node, state.backend }) do
		rt.write(file, "fixture")
	end
	rt.write(
		home .. "/dependencies/inkdrop/package.json",
		rt.encode({ name = "@inkdropapp/mcp-server", version = "1.5.0" })
	)
	rt.exec = function(argv, opts)
		state.calls[#state.calls + 1] = { argv = vim.deepcopy(argv), opts = vim.deepcopy(opts) }
		local result = { code = 0, stdout = "", stderr = "", signal = 0 }
		if argv[1] == "uname" then
			result.stdout = state.platform or "Darwin"
		elseif argv[1] == state.proxy then
			result.stdout = state.version or "mcp-proxy 0.13.3\n"
		elseif argv[1] == state.node then
			result.stdout = "v24.18.0\n"
		elseif argv[1] == "codex" then
			if state.invalid_codex then
				result.code, result.stderr = 1, "fixture-secret<&"
			elseif state.bad_codex_json then
				result.stdout = "not JSON"
			else
				local data = rt.decode((assert(rt.read(paths.config))))
				state.staged = assert(rt.read(opts.env.CODEX_HOME .. "/config.toml"))
				result.stdout = rt.encode({
					name = "inkdrop",
					transport = {
						type = state.bad_transport and "stdio" or "streamable_http",
						url = data.url,
					},
				})
			end
		elseif argv[1] == "curl" then
			if not state.check then
				result.code = 1
				result.stderr = "fixture-secret<&"
				return result
			end
			local encoded = opts.stdin:match('data%-binary = "(.-)"\n')
			local message = encoded and rt.decode(rt.decode('"' .. encoded .. '"'))
			local value, status
			if message and message.method == "initialize" then
				value = {
					jsonrpc = "2.0",
					id = message.id,
					result = {
						serverInfo = { name = "Inkdrop", version = "1.3.0" },
						protocolVersion = "2025-11-25",
						capabilities = { tools = vim.empty_dict() },
					},
				}
			elseif message and message.method == "tools/list" then
				value = {
					jsonrpc = "2.0",
					id = message.id,
					result = { tools = { { name = "read-note" }, { name = "list-notebooks" } } },
				}
			else
				status = 204
			end
			result.stdout = "HTTP/1.1 "
				.. (status or 200)
				.. " OK\r\nContent-Type: application/json\r\nMcp-Session-Id: service-test\r\n\r\n"
				.. (value and rt.encode(value) or "")
				.. "\n"
				.. (status or 200)
		elseif argv[1] == "launchctl" then
			if argv[2] == "print" then
				if state.inspect_error then
					result.code, result.stderr = 1, "permission denied"
				elseif not state.running then
					result.code, result.stderr = 113, "Could not find service"
				else
					result.stdout = "path = "
						.. (state.foreign and "/foreign.plist" or paths.plist)
						.. "\nprogram = "
						.. state.proxy
						.. "\narguments = {\n--named-server-config\n"
						.. paths.backend
						.. "\n}\n"
				end
			elseif state.control_error then
				result.code, result.stderr = 1, "fixture-secret<&"
			elseif argv[2] == "bootstrap" then
				state.running = true
			elseif argv[2] == "bootout" then
				state.running = false
			end
		else
			error("unexpected executable")
		end
		return result
	end
	return rt, state
end

local function run(rt, state, args)
	local ok, value = pcall(service.run, rt, args)
	assert(ok, value)
	return value
end

local function install(rt, state, extra)
	local args = {
		"install",
		"--proxy",
		state.proxy,
		"--node",
		state.node,
		"--backend",
		state.backend,
		"--port",
		"49199",
	}
	vim.list_extend(args, extra or {})
	return run(rt, state, args)
end

local function installed()
	local rt, state = fake()
	Test.eq(install(rt, state).code, 0)
	return rt, state
end

local function assert_error(value, pattern)
	Test.eq(value.code, 1)
	assert(value.err:find(pattern, 1, true), value.err)
	assert(not value.err:find("fixture-secret", 1, true), value.err)
end

Test.test(
	"inkdrop_service install pins dependencies and writes only private native service files",
	function()
		local rt, state = installed()
		local paths = state.paths
		local config = rt.decode((assert(rt.read(paths.config))))
		Test.eq(config.mode, "inherit")
		Test.eq(config.url, "http://127.0.0.1:49199/servers/inkdrop/mcp")
		local backend = rt.decode((assert(rt.read(paths.backend))))
		Test.eq(vim.tbl_keys(backend.mcpServers), { "inkdrop" })
		Test.eq(backend.mcpServers.inkdrop.command, state.node)
		Test.eq(backend.mcpServers.inkdrop.args, { state.backend })
		Test.eq(backend.mcpServers.inkdrop.env.INKDROP_LOCAL_PASSWORD, "fixture-secret<&")
		Test.eq(vim.tbl_count(backend.mcpServers.inkdrop.env), 3)
		for _, path in ipairs({ paths.config, paths.backend, paths.log, paths.plist }) do
			Test.eq(uv.fs_stat(path).mode % 512, 384)
		end
		for _, path in ipairs({ paths.dir, paths.backups }) do
			Test.eq(uv.fs_stat(path).mode % 512, 448)
		end
		local plist = assert(rt.read(paths.plist))
		assert(plist:find("--named-server-config", 1, true))
		assert(not plist:find("fixture-secret", 1, true))
		assert(not plist:find("<string>nvim</string>", 1, true))
		for _, call in ipairs(state.calls) do
			assert(not table.concat(call.argv, " "):find("fixture-secret", 1, true))
		end
		assert(install(rt, state).out:find("already installed", 1, true))
		local before = rt.read(paths.backend)
		rt.env.INKDROP_LOCAL_PASSWORD = "different"
		assert_error(install(rt, state), "different service install")
		Test.eq(rt.read(paths.backend), before)
	end
)

Test.test(
	"inkdrop_service install supports a private credential map and refuses unsafe imports",
	function()
		local rt, state = fake()
		local credential = rt.env.HOME .. "/credentials.json"
		rt.write(
			credential,
			rt.encode({
				INKDROP_LOCAL_USERNAME = "private-user",
				INKDROP_LOCAL_PASSWORD = "private-pass",
				OTHER = "do-not-copy",
			})
		)
		Test.eq(install(rt, state, { "--credentials", credential }).code, 0)
		local env = rt.decode((rt.read(state.paths.backend))).mcpServers.inkdrop.env
		Test.eq(env.INKDROP_LOCAL_USERNAME, "private-user")
		Test.eq(env.INKDROP_LOCAL_SERVER_URL, "http://127.0.0.1:19840")
		Test.eq(env.OTHER, nil)
		rt, state = fake()
		credential = rt.env.HOME .. "/credentials.json"
		rt.write(credential, "invalid JSON")
		assert_error(install(rt, state, { "--credentials", credential }), "invalid credential file")
		uv.fs_chmod(credential, 420)
		assert_error(install(rt, state, { "--credentials", credential }), "unsafe ownership")
		assert_error(install(rt, state, { "--credentials", "relative" }), "absolute private JSON")
		rt.env.INKDROP_LOCAL_USERNAME = nil
		assert_error(install(rt, state), "credentials are incomplete")
	end
)

Test.test(
	"inkdrop_service install fails before mutation for invalid dependencies and unmanaged files",
	function()
		local rt, state = fake()
		assert_error(run(rt, state, { "install" }), "absolute --proxy")
		assert_error(install(rt, state, { "--port", "1" }), "operation failed")
		state.version = "mcp-proxy 0.13.30"
		assert_error(install(rt, state), "0.13.3 is required")
		state.version = "mcp-proxy 0.13.3"
		rt.write(
			vim.fs.dirname(vim.fs.dirname(state.backend)) .. "/package.json",
			'{"name":"@inkdropapp/mcp-server","version":"2.0.0"}'
		)
		assert_error(install(rt, state), "1.5.0 is required")
		Test.eq(rt.exists(state.paths.config), false)
		rt, state = fake()
		rt.write(state.paths.backend, "user-owned")
		uv.fs_chmod(state.paths.dir, 448)
		assert_error(install(rt, state), "unmanaged install files")
		Test.eq(rt.read(state.paths.backend), "user-owned")
	end
)

Test.test("inkdrop_service lifecycle owns exactly one explicit launchd job", function()
	local rt, state = installed()
	local before = #state.calls
	Test.eq(run(rt, state, { "status" }).out, "stopped (inherit)\n")
	Test.eq(run(rt, state, { "start" }).code, 0)
	Test.eq(run(rt, state, { "start" }).out, "already running\n")
	Test.eq(run(rt, state, { "restart" }).code, 0)
	Test.eq(run(rt, state, { "enable" }).code, 0)
	Test.eq(rt.decode(run(rt, state, { "status", "--json" }).out).mode, "shared")
	Test.eq(run(rt, state, { "disable" }).code, 0)
	Test.eq(state.running, true)
	Test.eq(run(rt, state, { "stop" }).code, 0)
	Test.eq(run(rt, state, { "stop" }).code, 0)
	assert_error(run(rt, state, { "restart" }), "service is stopped")
	assert_error(run(rt, state, { "enable" }), "service is stopped")
	local bootstrap, bootout = 0, 0
	for i = before + 1, #state.calls do
		local argv = state.calls[i].argv
		if argv[1] == "launchctl" then
			if argv[2] == "bootstrap" then
				bootstrap = bootstrap + 1
				Test.eq(argv[4], state.paths.plist)
			elseif argv[2] == "bootout" then
				bootout = bootout + 1
				Test.eq(argv[3], "gui/" .. uv.getuid() .. "/" .. LABEL)
			end
		end
	end
	Test.eq(bootstrap, 1)
	Test.eq(bootout, 1)
end)

Test.test(
	"inkdrop_service control refuses foreign jobs tampering platform and failed health",
	function()
		local rt, state = installed()
		state.running, state.foreign = true, true
		for _, action in ipairs({ "start", "stop", "restart", "enable", "uninstall" }) do
			assert_error(run(rt, state, { action }), "not the installed service")
		end
		state.foreign, state.check = false, false
		assert_error(run(rt, state, { "enable" }), "endpoint is unavailable")
		state.platform = "Linux"
		assert_error(run(rt, state, { "start" }), "requires macOS")
		state.platform, state.inspect_error = "Darwin", true
		assert_error(run(rt, state, { "status" }), "cannot inspect launchd")
		state.inspect_error, state.control_error = false, true
		assert_error(run(rt, state, { "restart" }), "cannot restart")
		assert_error(run(rt, state, { "stop" }), "cannot stop")
		state.running = false
		assert_error(run(rt, state, { "start" }), "cannot bootstrap")
		state.control_error = false
		rt.write(state.paths.backend, "tampered")
		assert_error(run(rt, state, { "start" }), "backend configuration changed")
	end
)

local CODEX = [[# root comment
model = "fixture-model"

[mcp_servers."inkdrop"] # keep table spelling
command = "/old/ccc"
args = ["--old"]
env_vars = ["SYNTHETIC_SECRET"]
cwd = "/old"
enabled_tools = ["read-note"] # preserve filter
disabled_tools = ["delete-note"]
startup_timeout_sec = 17
tool_timeout_sec = 31
default_tools_approval_mode = "prompt"

[mcp_servers.inkdrop.env]
SYNTHETIC_SECRET = "fixture-secret<&"

[mcp_servers.inkdrop.tools.read-note]
approval_mode = "prompt"

# unrelated comment
[mcp_servers.unrelated]
command = "/keep/unrelated"
args = ["--keep"]
]]

local function provider(rt, name, source)
	local path = rt.env.HOME .. "/" .. name .. "-config"
	rt.write(path, source)
	return path
end

Test.test(
	"inkdrop_service Codex migration previews preserves policy and rolls back exact bytes",
	function()
		local rt, state = installed()
		local file = provider(rt, "codex", CODEX)
		local args = { "migrate", "--provider", "codex", "--file", file }
		Test.eq(run(rt, state, args).code, 0)
		Test.eq(rt.read(file), CODEX)
		Test.eq(#rt.list(state.paths.backups), 0)
		assert(state.staged:find('[mcp_servers."inkdrop"] # keep table spelling\nurl = ', 1, true))
		for _, key in ipairs({
			"enabled_tools",
			"disabled_tools",
			"startup_timeout_sec",
			"tool_timeout_sec",
			"default_tools_approval_mode",
			"approval_mode",
		}) do
			assert(state.staged:find(key, 1, true))
		end
		assert(not state.staged:find("SYNTHETIC_SECRET", 1, true))
		assert(not state.staged:find("/old", 1, true))
		assert(
			state.staged:find(
				'# unrelated comment\n[mcp_servers.unrelated]\ncommand = "/keep/unrelated"\nargs = ["--keep"]\n',
				1,
				true
			)
		)
		vim.list_extend(args, { "--apply" })
		Test.eq(run(rt, state, args).code, 0)
		Test.eq(rt.read(file), state.staged)
		for _, name in ipairs(rt.list(state.paths.backups)) do
			Test.eq(uv.fs_stat(state.paths.backups .. "/" .. name).mode % 512, 384)
		end
		assert_error(run(rt, state, args), "receipt already exists")
		assert_error(run(rt, state, { "uninstall" }), "active migrations")
		Test.eq(run(rt, state, { "rollback", "--provider", "codex", "--file", file }).code, 0)
		Test.eq(rt.read(file), CODEX)
		Test.eq(#rt.list(state.paths.backups), 0)
	end
)

Test.test(
	"inkdrop_service Claude migration preserves other servers approvals and exact rollback",
	function()
		local rt, state = installed()
		local original = {
			mcpServers = {
				inkdrop = {
					command = "old",
					args = { "old" },
					env = { SECRET = "fixture-secret<&" },
					timeout = 17000,
				},
				unrelated = { command = "keep", env = { KEEP = "private" } },
			},
			permissions = {
				allow = { "mcp__inkdrop__read-note" },
				deny = { "mcp__inkdrop__delete-note" },
			},
		}
		local source = rt.encode(original)
		local file = provider(rt, "claude", source)
		local args = { "migrate", "--provider", "claude", "--file", file }
		Test.eq(run(rt, state, args).code, 0)
		Test.eq(rt.read(file), source)
		args[#args + 1] = "--apply"
		Test.eq(run(rt, state, args).code, 0)
		local migrated = rt.decode((rt.read(file)))
		Test.eq(migrated.permissions, original.permissions)
		Test.eq(migrated.mcpServers.unrelated, original.mcpServers.unrelated)
		Test.eq(migrated.mcpServers.inkdrop.timeout, 17000)
		Test.eq(migrated.mcpServers.inkdrop.command, nil)
		Test.eq(migrated.mcpServers.inkdrop.env, nil)
		Test.eq(migrated.mcpServers.inkdrop.type, "http")
		Test.eq(run(rt, state, { "rollback", "--provider", "claude", "--file", file }).code, 0)
		Test.eq(rt.read(file), source)
	end
)

Test.test("inkdrop_service migration rejects unsupported TOML before any provider write", function()
	local rt, state = installed()
	for _, source in ipairs({
		'[mcp_servers]\ninkdrop = {command="old"}\n',
		'mcp_servers.inkdrop.command="old"\n',
		'[mcp_servers.inkdrop]\nargs = [\n"old"\n]\n',
		'[mcp_servers.inkdrop]\ncommand="""old"""\n',
		'[[mcp_servers.inkdrop]]\ncommand="old"\n',
		"[mcp_servers.inkdrop]\n[mcp_servers.inkdrop]\n",
		"[mcp_servers.inkdrop\n",
		"[mcp_servers.inkdrop.]\n",
	}) do
		local file = provider(rt, "codex", source)
		local result = run(rt, state, { "migrate", "--provider", "codex", "--file", file, "--apply" })
		Test.eq(result.code, 1)
		Test.eq(rt.read(file), source)
		Test.eq(#rt.list(state.paths.backups), 0)
	end
	state.invalid_codex = true
	local file = provider(rt, "codex", "this is not valid TOML")
	assert_error(
		run(rt, state, { "migrate", "--provider", "codex", "--file", file, "--apply" }),
		"staged Codex configuration is invalid"
	)
	Test.eq(rt.read(file), "this is not valid TOML")
end)

Test.test(
	"inkdrop_service migration and rollback refuse concurrent user edits and corrupted backup",
	function()
		local rt, state = installed()
		local file = provider(rt, "claude", '{"mcpServers":{}}')
		Test.eq(
			run(rt, state, { "migrate", "--provider", "claude", "--file", file, "--apply" }).code,
			0
		)
		local migrated = rt.read(file)
		rt.write(file, "later user edit")
		assert_error(
			run(rt, state, { "rollback", "--provider", "claude", "--file", file }),
			"later user edits"
		)
		Test.eq(rt.read(file), "later user edit")
		rt.write(file, migrated)
		for _, name in ipairs(rt.list(state.paths.backups)) do
			if name:match("%.before$") then
				rt.write(state.paths.backups .. "/" .. name, "corrupted")
			end
		end
		assert_error(
			run(rt, state, { "rollback", "--provider", "claude", "--file", file }),
			"backup changed"
		)
		rt, state = installed()
		file = provider(rt, "claude", '{"mcpServers":{}}')
		uv.fs_mkdir(file .. ".orc-inkdrop-mcp.lock", 448)
		assert_error(
			run(rt, state, { "migrate", "--provider", "claude", "--file", file, "--apply" }),
			"locked by another migration"
		)
		uv.fs_rmdir(file .. ".orc-inkdrop-mcp.lock")
		local write = rt.write
		rt.write = function(path, body)
			write(path, body)
			if path:match("%.before$") then
				write(file, "concurrent edit")
			end
		end
		assert_error(
			run(rt, state, { "migrate", "--provider", "claude", "--file", file, "--apply" }),
			"changed before atomic replacement"
		)
		Test.eq(rt.read(file), "concurrent edit")
	end
)

Test.test(
	"inkdrop_service default paths strict flags and uninstall retain unrelated private data",
	function()
		local rt, state = fake()
		Test.eq(
			rt.decode(run(rt, state, { "status", "--json" }).out),
			{ schemaVersion = 1, installed = false }
		)
		Test.eq(run(rt, state, { "status" }).out, "not installed\n")
		assert_error(run(rt, state, {}), "usage:")
		assert_error(run(rt, state, { "start", "extra" }), "usage:")
		assert_error(run(rt, state, { "status", "--unknown" }), "operation failed")
		Test.eq(install(rt, state).code, 0)
		rt.env.CLAUDE_CONFIG_DIR = rt.env.HOME .. "/claude"
		rt.write(rt.env.CLAUDE_CONFIG_DIR .. "/.claude.json", "{}")
		Test.eq(run(rt, state, { "migrate", "--provider", "claude", "--apply" }).code, 0)
		Test.eq(run(rt, state, { "rollback", "--provider", "claude" }).code, 0)
		rt.write(state.paths.dir .. "/user-notes.txt", "preserve")
		Test.eq(run(rt, state, { "uninstall" }).code, 0)
		Test.eq(rt.read(state.paths.dir .. "/user-notes.txt"), "preserve")
		Test.eq(rt.exists(state.paths.config), false)
		Test.eq(rt.exists(state.paths.backend), false)
		Test.eq(rt.exists(state.paths.plist), false)
	end
)

Test.test(
	"inkdrop_service migrations handle missing entries quoted keys and validation failures",
	function()
		local rt, state = installed()
		local file =
			provider(rt, "codex", "# existing unrelated bytes\n[mcp_servers.unrelated]\ncommand='keep'")
		Test.eq(run(rt, state, { "migrate", "--provider", "codex", "--file", file }).code, 0)
		assert(state.staged:find("[mcp_servers.inkdrop]\nurl = ", 1, true))
		file = provider(
			rt,
			"codex",
			'["mcp_servers".\'inkdrop\']\n"command" = "old"\n\'args\' = [\'old\']\nenv = { SECRET = "old" }\n# preserve\n'
		)
		Test.eq(run(rt, state, { "migrate", "--provider", "codex", "--file", file }).code, 0)
		assert(not state.staged:find('"command"', 1, true))
		assert(state.staged:find("# preserve", 1, true))
		state.bad_codex_json = true
		assert_error(
			run(rt, state, { "migrate", "--provider", "codex", "--file", file }),
			"invalid Codex configuration response"
		)
		state.bad_codex_json, state.bad_transport = false, true
		assert_error(
			run(rt, state, { "migrate", "--provider", "codex", "--file", file }),
			"transport did not match"
		)
		file = provider(rt, "claude", '"wrong type"')
		assert_error(
			run(rt, state, { "migrate", "--provider", "claude", "--file", file }),
			"invalid Claude configuration"
		)
		assert_error(
			run(rt, state, { "migrate", "--provider", "wrong", "--file", file }),
			"must be claude or codex"
		)
		assert_error(
			run(rt, state, { "migrate", "--provider", "claude", "--file", "relative" }),
			"must be absolute"
		)
	end
)

Test.test(
	"inkdrop_service install errors clean new files and preserve existing private material",
	function()
		local rt, state = fake()
		local write = rt.write
		rt.write = function(path, body)
			if path == state.paths.plist then
				error("fixture-secret<&")
			end
			write(path, body)
		end
		assert_error(install(rt, state), "cannot complete private service installation")
		for _, path in ipairs({
			state.paths.config,
			state.paths.backend,
			state.paths.log,
			state.paths.plist,
		}) do
			Test.eq(rt.exists(path), false)
		end
		rt.write = write
		Test.eq(install(rt, state).code, 0)
		rt, state = fake()
		rt.write(state.paths.log, "private existing log")
		uv.fs_chmod(state.paths.dir, 448)
		assert_error(install(rt, state), "unmanaged install files")
		Test.eq(rt.read(state.paths.log), "private existing log")
		rt, state = fake()
		rt.mkdir(state.paths.dir)
		uv.fs_chmod(state.paths.dir, 493)
		assert_error(install(rt, state), "unsafe ownership")
		Test.eq(uv.fs_stat(state.paths.dir).mode % 512, 493)
		rt, state = fake()
		rt.mkdir(state.paths.dir)
		uv.fs_chmod(state.paths.dir, 448)
		rt.mkdir(state.paths.backups)
		uv.fs_chmod(state.paths.backups, 448)
		rt.write(state.paths.backups .. "/user-backup", "preserve")
		assert_error(install(rt, state), "unmanaged migration backups")
	end
)

Test.test(
	"inkdrop_service dependency versions ports URLs and missing executables are validated",
	function()
		for _, port in ipairs({ "bad", "1.5", "0", "65536" }) do
			local rt, state = fake()
			assert_error(
				run(rt, state, {
					"install",
					"--proxy",
					state.proxy,
					"--node",
					state.node,
					"--backend",
					state.backend,
					"--port",
					port,
				}),
				"valid --port"
			)
		end
		local rt, state = fake()
		rt.remove(state.node)
		assert_error(install(rt, state), "dependency is missing")
		rt, state = fake()
		rt.remove(vim.fs.dirname(vim.fs.dirname(state.backend)) .. "/package.json")
		assert_error(install(rt, state), "cannot inspect Inkdrop package")
		rt.write(
			vim.fs.dirname(vim.fs.dirname(state.backend)) .. "/package.json",
			'{"name":"other","version":"1.5.0"}'
		)
		assert_error(install(rt, state), "1.5.0 is required")
		rt, state = fake()
		rt.env.INKDROP_LOCAL_SERVER_URL = "https://remote.invalid:443"
		assert_error(install(rt, state), "data API must use loopback")
		rt, state = fake()
		local exec = rt.exec
		rt.exec = function(argv, opts)
			if argv[1] == state.proxy or argv[1] == state.node then
				return { code = 1, stderr = "fixture-secret<&", stdout = "" }
			end
			return exec(argv, opts)
		end
		assert_error(install(rt, state), "cannot inspect proxy version")
	end
)

Test.test("inkdrop_service installed metadata and missing private files fail closed", function()
	local rt, state = installed()
	local original = rt.decode((rt.read(state.paths.config)))
	for _, update in ipairs({
		{ schemaVersion = 2 },
		{ service = {} },
		{ url = "http://remote.invalid:49199/servers/inkdrop/mcp" },
	}) do
		local doc = vim.tbl_extend("force", {}, original, update)
		rt.write(state.paths.config, rt.encode(doc))
		Test.eq(run(rt, state, { "status" }).code, 1)
	end
	for _, update in ipairs({
		{ port = "49199" },
		{ port = 1.5 },
		{ port = 0 },
		{ port = 65536 },
		{ label = "foreign" },
		{ uid = uv.getuid() + 1 },
	}) do
		local doc = vim.deepcopy(original)
		doc.service = vim.tbl_extend("force", doc.service, update)
		rt.write(state.paths.config, rt.encode(doc))
		Test.eq(run(rt, state, { "status" }).code, 1)
	end
	rt.write(state.paths.config, rt.encode(original))
	rt.remove(state.paths.plist)
	assert_error(run(rt, state, { "start" }), "plist ownership mismatch")
	rt, state = installed()
	rt.write(state.paths.plist, "user edit")
	assert_error(run(rt, state, { "start" }), "plist changed")
	rt, state = installed()
	rt.remove(state.paths.backend)
	assert_error(run(rt, state, { "start" }), "private file is missing")
end)

Test.test(
	"inkdrop_service default Codex paths unsupported status and owned running uninstall",
	function()
		local rt, state = installed()
		rt.env.CODEX_HOME = rt.env.HOME .. "/codex-home"
		rt.write(rt.env.CODEX_HOME .. "/config.toml", "")
		Test.eq(run(rt, state, { "migrate", "--provider", "codex", "--apply" }).code, 0)
		Test.eq(run(rt, state, { "rollback", "--provider", "codex" }).code, 0)
		rt.env.CODEX_HOME = nil
		rt.write(rt.env.HOME .. "/.codex/config.toml", "# empty\n")
		Test.eq(run(rt, state, { "migrate", "--provider", "codex" }).code, 0)
		rt.write(rt.env.HOME .. "/.claude.json", "{}")
		Test.eq(run(rt, state, { "migrate", "--provider", "claude" }).code, 0)
		state.platform = "Linux"
		Test.eq(run(rt, state, { "status" }).code, 0)
		Test.eq(rt.decode(run(rt, state, { "status", "--json" }).out).platform, "unsupported")
		state.platform = "Darwin"
		state.running = true
		Test.eq(run(rt, state, { "status" }).out, "running (inherit)\n")
		Test.eq(run(rt, state, { "uninstall" }).code, 0)
		Test.eq(state.running, false)
	end
)

Test.test(
	"inkdrop_service migration validates escaping transport shapes and unchanged receipts",
	function()
		local rt, state = installed()
		local file = provider(
			rt,
			"codex",
			'[mcp_servers.inkdrop]\ncommand="old\\"quoted" # comment\nargs=["\\\\old"]\n\n[[unrelated]]\nname="preserve"\n'
		)
		Test.eq(run(rt, state, { "migrate", "--provider", "codex", "--file", file }).code, 0)
		assert(state.staged:find('[[unrelated]]\nname="preserve"\n', 1, true))
		file = provider(rt, "codex", "[mcp_servers.inkdrop]")
		Test.eq(run(rt, state, { "migrate", "--provider", "codex", "--file", file }).code, 0)
		for _, value in ipairs({ '"unclosed', '{ SECRET="unclosed"' }) do
			rt.write(file, "[mcp_servers.inkdrop]\ncommand=" .. value)
			Test.eq(run(rt, state, { "migrate", "--provider", "codex", "--file", file }).code, 1)
		end
		file = provider(rt, "claude", '{"mcpServers":{}}')
		local original = rt.read(file)
		Test.eq(
			run(rt, state, { "migrate", "--provider", "claude", "--file", file, "--apply" }).code,
			0
		)
		rt.write(file, original)
		Test.eq(run(rt, state, { "rollback", "--provider", "claude", "--file", file }).code, 0)
	end
)

Test.test("inkdrop_service receipt identity and provider ownership protect rollback", function()
	local rt, state = installed()
	local file = provider(rt, "claude", "{}")
	Test.eq(run(rt, state, { "migrate", "--provider", "claude", "--file", file, "--apply" }).code, 0)
	local receipt
	for _, name in ipairs(rt.list(state.paths.backups)) do
		if name:match("%.json$") then
			receipt = state.paths.backups .. "/" .. name
		end
	end
	local original = rt.decode((rt.read(receipt)))
	for _, update in ipairs({
		{ schemaVersion = 2 },
		{ provider = "codex" },
		{ file = "/foreign" },
		{ backup = "/foreign" },
	}) do
		rt.write(receipt, rt.encode(vim.tbl_extend("force", {}, original, update)))
		assert_error(
			run(rt, state, { "rollback", "--provider", "claude", "--file", file }),
			"receipt identity mismatch"
		)
	end
	rt.write(receipt, rt.encode(original))
	rt.remove(file)
	assert_error(
		run(rt, state, { "rollback", "--provider", "claude", "--file", file }),
		"ownership changed"
	)
	Test.eq(run(rt, state, { "migrate", "--provider", "claude", "--file", file }).code, 1)
	rt.mkdir(file)
	Test.eq(run(rt, state, { "migrate", "--provider", "claude", "--file", file }).code, 1)
	rt.remove(file)
	local target = provider(rt, "target", "{}")
	uv.fs_symlink(target, file)
	Test.eq(run(rt, state, { "migrate", "--provider", "claude", "--file", file }).code, 1)
	Test.eq(rt.read(target), "{}")
end)

Test.test(
	"inkdrop_service Claude auth transport refusal never writes or exposes credentials",
	function()
		local rt, state = installed()
		for key, value in pairs({
			headers = { Authorization = "fixture-secret<&" },
			headersHelper = "fixture-secret<&",
			oauth = { clientSecret = "fixture-secret<&" },
			auth = "fixture-secret<&",
		}) do
			local source = rt.encode({ mcpServers = { inkdrop = { command = "old", [key] = value } } })
			local file = provider(rt, "claude", source)
			for _, apply in ipairs({ false, true }) do
				local args = { "migrate", "--provider", "claude", "--file", file }
				if apply then
					args[#args + 1] = "--apply"
				end
				assert_error(run(rt, state, args), "authentication requires explicit review")
				Test.eq(rt.read(file), source)
				Test.eq(#rt.list(state.paths.backups), 0)
			end
		end
		local file = provider(
			rt,
			"claude",
			rt.encode({
				mcpServers = {
					inkdrop = { headers = vim.NIL, headersHelper = "", oauth = vim.empty_dict() },
				},
			})
		)
		Test.eq(
			run(rt, state, { "migrate", "--provider", "claude", "--file", file, "--apply" }).code,
			0
		)
		Test.eq(rt.decode((rt.read(file))).mcpServers.inkdrop.headers, nil)
	end
)

Test.test(
	"inkdrop_service cooperative service lock prevents migration uninstall and install races",
	function()
		local rt, state = installed()
		local file = provider(rt, "claude", '{"mcpServers":{}}')
		local write = rt.write
		local attempted = false
		rt.write = function(path, body)
			if path:match("%.before$") then
				attempted = true
				assert_error(run(rt, state, { "uninstall" }), "locked by another migration")
				assert_error(install(rt, state), "locked by another migration")
				assert_error(run(rt, state, { "disable" }), "locked by another migration")
			end
			write(path, body)
		end
		Test.eq(
			run(rt, state, { "migrate", "--provider", "claude", "--file", file, "--apply" }).code,
			0
		)
		Test.eq(attempted, true)
		Test.eq(rt.exists(state.paths.config), true)
		Test.eq(run(rt, state, { "rollback", "--provider", "claude", "--file", file }).code, 0)
	end
)

Test.test("inkdrop_service owner metadata and validation error objects remain redacted", function()
	local rt, state = installed()
	local original_lstat = uv.fs_lstat
	uv.fs_lstat = function(path, ...)
		local stat, err = original_lstat(path, ...)
		if stat and path == state.paths.config then
			stat = vim.deepcopy(stat)
			stat.uid = uv.getuid() + 1
		end
		return stat, err
	end
	local ok, err = pcall(function()
		assert_error(run(rt, state, { "status" }), "unsafe ownership")
	end)
	uv.fs_lstat = original_lstat
	assert(ok, err)
	local exec = rt.exec
	rt.exec = function(argv, opts)
		if argv[1] == "uname" then
			error({ secret = "fixture-secret<&" })
		end
		return exec(argv, opts)
	end
	assert_error(run(rt, state, { "status" }), "operation failed")
	rt.exec = exec
	local file = provider(rt, "codex", CODEX)
	rt.exec = function(argv, opts)
		if argv[1] == "codex" then
			return { code = 0, stdout = '{"name":"wrong","transport":{}}', stderr = "" }
		end
		return exec(argv, opts)
	end
	assert_error(
		run(rt, state, { "migrate", "--provider", "codex", "--file", file }),
		"transport did not match"
	)
	rt.exec = function(argv, opts)
		if argv[1] == "codex" then
			return { code = 0, stdout = '{"name":"inkdrop"}', stderr = "" }
		end
		return exec(argv, opts)
	end
	assert_error(
		run(rt, state, { "migrate", "--provider", "codex", "--file", file }),
		"transport did not match"
	)
end)

Test.test(
	"inkdrop_service Codex migration preserves unrelated quoted headers and multiline values",
	function()
		for _, delimiter in ipairs({ '"""', "'''" }) do
			local rt, state = installed()
			local prefix = "# user instructions stay byte-identical\ndeveloper_instructions = "
				.. delimiter
				.. "\n"
				.. "[mcp_servers.inkdrop]\ncommand = '/this/is/instruction/text'\n"
				.. (delimiter == '"""' and "escaped closing marker: " .. string.char(92) .. '"""\n' or 'other marker: """\n')
				.. delimiter
				.. "\n\n"
				.. '[projects."/Users/fixture/repo.with.dots"]\ntrust_level = "trusted"\n\n'
				.. '[mcp_servers."unrelated.server.with.dots"]\ncommand = "keep-me"\n\n'
			local actual = '[mcp_servers."inkdrop"]\ncommand = "old" # """ in a comment\nargs = ["--old"]\n'
				.. "tool_timeout_sec = 47 # retain this exact policy\n\n"
				.. '[mcp_servers.inkdrop.env]\nSECRET = "fixture-only"\n\n'
			local suffix = '[mcp_servers.inkdrop.tools."read-note"]\napproval_mode = "prompt"\n\n'
				.. '[projects."/Users/fixture/other repo"]\ntrust_level = "trusted"\n'
			local source = prefix .. actual .. suffix
			local file = provider(rt, "codex", source)
			Test.eq(run(rt, state, { "migrate", "--provider", "codex", "--file", file }).code, 0)
			Test.eq(rt.read(file), source)
			Test.eq(state.staged:sub(1, #prefix), prefix)
			Test.eq(state.staged:sub(-#suffix), suffix)
			assert(state.staged:find("tool_timeout_sec = 47 # retain this exact policy\n\n", 1, true))
			assert(not state.staged:find('command = "old"', 1, true))
			assert(not state.staged:find("fixture-only", 1, true))
			Test.eq(
				run(rt, state, { "migrate", "--provider", "codex", "--file", file, "--apply" }).code,
				0
			)
			Test.eq(rt.read(file), state.staged)
			Test.eq(run(rt, state, { "rollback", "--provider", "codex", "--file", file }).code, 0)
			Test.eq(rt.read(file), source)
		end
	end
)

Test.test(
	"inkdrop_service multiline policy delimiters remain opaque and transport multiline fails closed",
	function()
		local rt, state = installed()
		for _, source in ipairs({
			'developer_instructions = """text""""\n[mcp_servers.inkdrop]\ncommand="old"\n',
			"developer_instructions = '''text'''''\n[mcp_servers.inkdrop]\ncommand='old'\n",
			'[mcp_servers.inkdrop]\ncommand="old"\n[mcp_servers.inkdrop.tools."read-note"]\napproval_mode="""prompt"""\n',
			'[mcp_servers."other.id"]\ncommand="keep"\n[mcp_servers.inkdrop]\ncommand="old"\n',
			'"mcp_servers"."other.id".command="keep"\n[mcp_servers.inkdrop]\ncommand="old"\n',
		}) do
			local file = provider(rt, "codex", source)
			Test.eq(run(rt, state, { "migrate", "--provider", "codex", "--file", file }).code, 0)
		end
		for _, source in ipairs({
			'[mcp_servers.inkdrop]\ncommand="""old"""\n',
			'[mcp_servers.inkdrop]\ncommand="old"\n[mcp_servers.inkdrop.env]\nSECRET="""secret\n[mcp_servers.unrelated]\n"""\n',
			'developer_instructions="""unterminated\n[mcp_servers.inkdrop]\ncommand="old"\n',
			'[mcp_servers.inkdrop BAD]\ncommand="old"\n',
			'[mcp_servers]\n"inkdrop" = {command="old"}\n',
			'"mcp_servers"."inkdrop".command="old"\n',
		}) do
			local file = provider(rt, "codex", source)
			Test.eq(
				run(rt, state, { "migrate", "--provider", "codex", "--file", file, "--apply" }).code,
				1
			)
			Test.eq(rt.read(file), source)
			Test.eq(#rt.list(state.paths.backups), 0)
		end
	end
)
