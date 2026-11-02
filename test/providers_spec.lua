local cli = require("orc.cli")
local providers = require("orc.providers")
local runtime = require("orc.runtime")

local function fixture(fn)
	local rt = runtime.new({ root = "/plugin", cwd = "/repo" })
	rt.env = { HOME = "/home", PATH = "/tools", INKDROP_LOCAL_PASSWORD = "synthetic-secret" }
	local state = { files = {}, probes = {}, checks = 0, launched = {} }
	local endpoint = "http://127.0.0.1:19841/servers/inkdrop/mcp"
	state.entry = { enabled = true, transport = { type = "streamable_http", url = endpoint } }
	rt.read = function(path)
		if state.unreadable == path then
			return nil, state.readError
		end
		return state.files[path]
	end
	rt.list = function(path)
		return state.lists and state.lists[path] or {}
	end
	rt.exec = function(argv, opts)
		state.probes[#state.probes + 1] = { argv = argv, opts = opts }
		if argv[1] == "codex" then
			return {
				code = state.probeFail and 1 or 0,
				stdout = state.probeText or rt.encode(state.entry),
				stderr = "synthetic-secret",
			}
		end
		return { code = state.gitFail and 1 or 0, stdout = state.gitOutput or "/repo\n", stderr = "" }
	end
	rt.interactive = function(argv, opts)
		state.launched[#state.launched + 1] = { argv = argv, opts = opts }
		return 0
	end
	local previous, hook = package.loaded["orc.inkdrop_mcp"], package.loaded["orc.hooks"]
	package.loaded["orc.hooks"] = {
		context = function()
			return "workflow context"
		end,
	}
	package.loaded["orc.inkdrop_mcp"] = {
		resolve = function(_, mode)
			mode = mode or rt.env.ORC_INKDROP_MCP_MODE or "inherit"
			assert(mode == "inherit" or mode == "shared", "invalid shared mode")
			return { mode = mode, url = endpoint, paths = { config = "/private/config.json" } }
		end,
		check = function()
			state.checks = state.checks + 1
			return { ok = not state.unhealthy }
		end,
	}
	local ok, err = xpcall(function()
		fn(rt, state, endpoint)
	end, debug.traceback)
	package.loaded["orc.inkdrop_mcp"], package.loaded["orc.hooks"] = previous, hook
	assert(ok, err)
end

local function options(argv, flag)
	for index, value in ipairs(argv) do
		if value == flag then
			return argv[index + 1]
		end
	end
end

Test.test("providers preserve literal prompts and reject missing native override values", function()
	fixture(function(rt, state)
		for _, kind in ipairs({ "claude", "codex" }) do
			local spec = providers.plan(rt, {
				kind = kind,
				role = "implementer",
				flags = { ["inkdrop-mcp"] = "shared" },
				args = { "--", "--mcp-config", "literal prompt" },
			})
			Test.eq(vim.list_slice(spec.argv, #spec.argv - 2), { "--", "--mcp-config", "literal prompt" })
		end
		for _, args in ipairs({ { "-c" }, { "--config", "" }, { "-p" } }) do
			Test.raises("missing provider configuration", function()
				providers.plan(rt, {
					kind = "codex",
					role = "implementer",
					flags = { ["inkdrop-mcp"] = "shared" },
					args = args,
				})
			end)
		end
		Test.raises("conflicting Inkdrop transport", function()
			providers.plan(rt, {
				kind = "codex",
				role = "implementer",
				flags = { ["inkdrop-mcp"] = "shared" },
				args = { "-c", "mcp_servers.'inkdrop'.required=false" },
			})
		end)
		state.probeFail = true
		Test.raises("must be migrated", function()
			providers.plan(rt, {
				kind = "codex",
				role = "implementer",
				flags = { ["inkdrop-mcp"] = "shared" },
				args = { "-c", "malformed override" },
			})
		end)
	end)
end)

Test.test(
	"providers shared Codex config inspection cannot diverge through directory or short profile flags",
	function()
		fixture(function(rt, state)
			for _, args in ipairs({
				{ "-C", "/elsewhere" },
				{ "-C/elsewhere" },
				{ "--cd", "/elsewhere" },
				{ "--cd=/elsewhere" },
			}) do
				Test.raises("directory overrides", function()
					providers.plan(rt, {
						kind = "codex",
						role = "implementer",
						flags = { ["inkdrop-mcp"] = "shared" },
						args = args,
					})
				end)
			end
			local args = { "-pwork", "--profile=final" }
			providers.plan(rt, {
				kind = "codex",
				role = "implementer",
				flags = { ["inkdrop-mcp"] = "shared" },
				args = args,
			})
			Test.eq(
				state.probes[1].argv,
				{ "codex", "-p", "work", "--profile", "final", "mcp", "get", "inkdrop", "--json" }
			)
			for _, args2 in ipairs({
				{ "-c", "mcp_servers.inkdrop.required=false" },
				{ "--config=mcp_servers.inkdrop.required=false" },
				{ "-cmcp_servers.inkdrop.required=false" },
			}) do
				Test.raises("conflicting Inkdrop transport", function()
					providers.plan(rt, {
						kind = "codex",
						role = "implementer",
						flags = { ["inkdrop-mcp"] = "shared" },
						args = args2,
					})
				end)
			end
			local inherited = providers.plan(
				rt,
				{ kind = "codex", role = "implementer", args = { "-C", "/elsewhere", "-pwork" } }
			)
			Test.eq(vim.list_slice(inherited.argv, 4), { "-C", "/elsewhere", "-pwork" })
		end)
	end
)

Test.test(
	"providers tolerate absent optional role metadata and empty project scope maps",
	function()
		fixture(function(rt, state)
			state.files["/home/.claude.json"] = rt.encode({ projects = {} })
			state.lists =
				{ ["/plugin/agents"] = { "role.md" }, ["/plugin/codex/agents"] = { "gone.toml" } }
			state.files["/plugin/agents/role.md"] = "---\nname: role\ndescription: role\n---\nBody"
			local spec = providers.plan(
				rt,
				{ kind = "claude", role = "main", flags = { ["inkdrop-mcp"] = "shared", level = "high" } }
			)
			Test.eq(rt.decode(options(spec.argv, "--agents")).role.tools, {})
			assert(providers.plan(rt, { kind = "codex", role = "main" }).argv)
		end)
	end
)

Test.test(
	"providers inherit retains native models, worker sandbox and environment ownership",
	function()
		fixture(function(rt, state)
			local main = providers.plan(rt, { kind = "claude", role = "main" })
			Test.eq(main.argv, { "claude", "--plugin-dir", "/plugin", "--model", "opus" })
			Test.eq(main.env.ORC_ROLE, "")
			Test.eq(main.env.ORC_INKDROP_MCP_MODE, "inherit")
			Test.eq(main.env.INKDROP_LOCAL_PASSWORD, nil)
			local worker = providers.plan(rt, {
				kind = "codex",
				role = "implementer",
				cwd = "/worktree",
				workerFile = "/worker.json",
				prompt = "literal; assignment\nline two",
			})
			Test.eq(
				worker.argv,
				{ "codex", "--sandbox", "workspace-write", "literal; assignment\nline two" }
			)
			Test.eq(worker.cwd, "/worktree")
			Test.eq(worker.env.ORC_ROLE, "implementer")
			Test.eq(worker.env.ORC_WORKER_FILE, "/worker.json")
			Test.eq(worker.env.PATH, "/tools")
			Test.eq(state.checks, 0)
			Test.eq(#state.probes, 0)
			rt.env.ORC_LEVEL = "high"
			Test.eq(
				options(providers.plan(rt, { kind = "claude", role = "implementer" }).argv, "--model"),
				"opus"
			)
			Test.raises("unknown provider$", function()
				providers.plan(rt, { kind = "other", role = "main" })
			end)
			Test.raises("unknown provider role", function()
				providers.plan(rt, { kind = "claude", role = "other" })
			end)
		end)
	end
)

Test.test(
	"providers Claude shared overlay preserves policy and never puts backend credentials in argv",
	function()
		fixture(function(rt, state, endpoint)
			state.files["/home/.claude.json"] = rt.encode({
				mcpServers = { inkdrop = { command = "legacy", env = { PASSWORD = "synthetic-secret" } } },
				projects = {
					["/repo"] = {
						mcpServers = {
							inkdrop = {
								command = "local-legacy",
								args = { "--old" },
								env = { SECRET = "synthetic-secret" },
								timeout = 1234,
								alwaysLoad = true,
								tools = { read = "allow", write = "ask" },
							},
						},
					},
				},
			})
			state.files["/repo/.mcp.json"] =
				rt.encode({ mcpServers = { inkdrop = { command = "project" } } })
			local request = {
				kind = "claude",
				role = "implementer",
				flags = { ["inkdrop-mcp"] = "shared" },
				prompt = "worker prompt",
				workerFile = "/record.json",
			}
			local plan = providers.plan(rt, request)
			Test.eq(plan.argv[2], "--mcp-config")
			Test.eq(plan.argv[4], "--plugin-dir")
			Test.eq(plan.argv[#plan.argv], "worker prompt")
			local overlay = rt.decode(plan.argv[3])
			Test.eq(overlay, {
				mcpServers = {
					inkdrop = {
						type = "http",
						url = endpoint,
						timeout = 1234,
						alwaysLoad = true,
						tools = { read = "allow", write = "ask" },
					},
				},
			})
			Test.eq(plan.env.INKDROP_LOCAL_USERNAME, false)
			Test.eq(plan.env.INKDROP_LOCAL_PASSWORD, false)
			Test.eq(plan.env.INKDROP_LOCAL_SERVER_URL, false)
			Test.eq(plan.env.ORC_INKDROP_MCP_CONFIG, "/private/config.json")
			assert(not table.concat(plan.argv, " "):find("synthetic-secret", 1, true))
			Test.eq(state.checks, 1)
		end)
	end
)

Test.test(
	"providers Claude custom configuration paths and malformed entries fail without credential diagnostics",
	function()
		fixture(function(rt, state)
			rt.env.CLAUDE_CONFIG_DIR = "/claude-home"
			local request = { kind = "claude", role = "main", flags = { ["inkdrop-mcp"] = "shared" } }
			state.unreadable, state.readError = "/claude-home/.claude.json", "EACCES: synthetic-secret"
			Test.raises("cannot read Claude MCP configuration", function()
				providers.plan(rt, request)
			end)
			state.readError = "ENOENT: missing"
			assert(providers.plan(rt, request).argv)
			state.unreadable = nil
			state.files["/claude-home/.claude.json"] = "synthetic-secret invalid JSON"
			Test.raises("cannot read Claude MCP configuration", function()
				providers.plan(rt, request)
			end)
			state.files["/claude-home/.claude.json"] = rt.encode({ mcpServers = { inkdrop = "bad" } })
			Test.raises("invalid Claude Inkdrop entry", function()
				providers.plan(rt, request)
			end)
			state.files["/claude-home/.claude.json"] =
				rt.encode({ mcpServers = { inkdrop = { disabled = true } } })
			Test.raises("disabled", function()
				providers.plan(rt, request)
			end)
			for _, key in ipairs({ "headers", "headersHelper", "oauth", "auth" }) do
				state.files["/claude-home/.claude.json"] =
					rt.encode({ mcpServers = { inkdrop = { [key] = "synthetic-secret" } } })
				Test.raises("manual review", function()
					providers.plan(rt, request)
				end)
			end
			state.files["/claude-home/.claude.json"] =
				rt.encode({ mcpServers = { inkdrop = { headers = {}, auth = vim.NIL, oauth = "" } } })
			state.gitFail = true
			assert(providers.plan(rt, request).argv)
			state.gitFail, state.gitOutput = false, ""
			assert(providers.plan(rt, request).argv)
			rt.env.HOME = nil
			Test.raises("requires HOME", function()
				providers.plan(rt, request)
			end)
		end)
	end
)

Test.test(
	"providers shared mode rejects conflicting flags instead of hiding other MCP servers",
	function()
		fixture(function(rt)
			for _, flag in ipairs({
				"--mcp-config",
				"--mcp-config={}",
				"--strict-mcp-config",
				"--strict-mcp-config=true",
			}) do
				Test.raises("conflicting Claude MCP", function()
					providers.plan(rt, {
						kind = "claude",
						role = "main",
						flags = { ["inkdrop-mcp"] = "shared" },
						args = { flag },
					})
				end)
			end
			for _, value in ipairs({
				"mcp_servers={}",
				'mcp_servers.inkdrop={url="x"}',
				'mcp_servers."inkdrop".command="old"',
				'mcp_servers.inkdrop.url="x"',
				"mcp_servers.inkdrop.required=false",
			}) do
				Test.raises("conflicting Inkdrop transport", function()
					providers.plan(rt, {
						kind = "codex",
						role = "implementer",
						flags = { ["inkdrop-mcp"] = "shared" },
						args = { "-c", value },
					})
				end)
			end
			Test.raises("local Codex", function()
				providers.plan(rt, {
					kind = "codex",
					role = "main",
					flags = { ["inkdrop-mcp"] = "shared" },
					args = { "--remote=unix:///remote" },
				})
			end)
		end)
	end
)

Test.test(
	"providers Codex inspects effective HTTP transport with profile and policy overrides unchanged",
	function()
		fixture(function(rt, state)
			local args = {
				"--profile",
				"work",
				"-c",
				'mcp_servers.inkdrop.enabled_tools=["read-note"]',
				'--config=model="fixture"',
				"--profile=alternate",
				"-cmodel_reasoning_effort=high",
				"prompt",
			}
			local plan = providers.plan(rt, {
				kind = "codex",
				role = "implementer",
				cwd = "/task",
				flags = { ["inkdrop-mcp"] = "shared" },
				args = args,
			})
			Test.eq(state.probes[1].argv, {
				"codex",
				"--profile",
				"work",
				"-c",
				'mcp_servers.inkdrop.enabled_tools=["read-note"]',
				"--config",
				'model="fixture"',
				"--profile",
				"alternate",
				"-c",
				"model_reasoning_effort=high",
				"mcp",
				"get",
				"inkdrop",
				"--json",
			})
			Test.eq(state.probes[1].opts.cwd, "/task")
			Test.eq(vim.list_slice(plan.argv, 6), args)
			Test.eq(
				vim.list_slice(plan.argv, 1, 5),
				{ "codex", "-c", "mcp_servers.inkdrop.required=true", "--sandbox", "workspace-write" }
			)
			Test.eq(state.checks, 1)
			assert(not table.concat(plan.argv, " "):find("synthetic-secret", 1, true))
		end)
	end
)

Test.test(
	"providers Codex refuses mixed STDIO or unavailable effective configurations before launch",
	function()
		fixture(function(rt, state, endpoint)
			local request =
				{ kind = "codex", role = "implementer", flags = { ["inkdrop-mcp"] = "shared" } }
			for _, entry in ipairs({
				{},
				{ enabled = false },
				{ enabled = true, disabled_reason = "policy" },
				{ enabled = true, transport = "bad" },
				{ enabled = true, transport = { type = "stdio", command = "old" } },
				{
					enabled = true,
					transport = { type = "streamable_http", url = "http://127.0.0.1:12/mcp" },
				},
			}) do
				state.entry = entry
				Test.raises("must be migrated", function()
					providers.plan(rt, request)
				end)
			end
			state.entry = {
				enabled = true,
				disabled_reason = vim.NIL,
				transport = { type = "streamable_http", url = endpoint },
			}
			state.probeFail = true
			Test.raises("must be migrated", function()
				providers.plan(rt, request)
			end)
			state.probeFail, state.probeText = false, "synthetic-secret"
			Test.raises("must be migrated", function()
				providers.plan(rt, request)
			end)
			state.probeText, state.unhealthy = nil, true
			Test.raises("unavailable", function()
				providers.plan(rt, request)
			end)
			Test.eq(#state.launched, 0)
		end)
	end
)

Test.test(
	"providers CLI consumes opt-in mode and forwards the service command without activation",
	function()
		fixture(function(rt, state)
			Test.eq(cli.run(rt, { "claude", "--inkdrop-mcp", "shared", "prompt" }).code, 0)
			Test.eq(state.launched[1].opts.env.ORC_INKDROP_MCP_MODE, "shared")
			Test.eq(state.launched[1].opts.env.INKDROP_LOCAL_PASSWORD, false)
			assert(not table.concat(state.launched[1].argv, " "):find("--inkdrop-mcp", 1, true))
			state.unhealthy = true
			Test.eq(cli.run(rt, { "claude", "--inkdrop-mcp=shared" }).code, 1)
			Test.eq(#state.launched, 1)
			Test.eq(cli.run(rt, { "claude", "--inkdrop-mcp=invalid" }).code, 1)
			rt.env.ORC_INKDROP_MCP_MODE = "shared"
			Test.eq(cli.run(rt, { "claude", "--inkdrop-mcp=inherit" }).code, 0)
			Test.eq(state.launched[2].opts.env.ORC_INKDROP_MCP_MODE, "inherit")
			local old = package.loaded["orc.inkdrop_service"]
			package.loaded["orc.inkdrop_service"] = {
				run = function(_, args)
					Test.eq(args, { "status", "--json" })
					return { code = 0, out = "service status" }
				end,
			}
			local result = cli.run(rt, { "inkdrop-mcp", "status", "--json" })
			package.loaded["orc.inkdrop_service"] = old
			Test.eq(result.out, "service status")
		end)
	end
)
