local M = {}

local credential_names = {
	"INKDROP_LOCAL_USERNAME",
	"INKDROP_LOCAL_PASSWORD",
	"INKDROP_LOCAL_SERVER_URL",
}

local function decoded(rt, path)
	local text, err = rt.read(path)
	if not text then
		assert(not err or tostring(err):match("^ENOENT"), "orc: cannot read Claude MCP configuration")
		return {}
	end
	local ok, value = pcall(rt.decode, text)
	assert(ok and type(value) == "table", "orc: cannot read Claude MCP configuration")
	return value
end

local function claude_entry(rt, cwd)
	local home = assert(rt.env.HOME, "orc: shared Inkdrop requires HOME")
	local path = rt.env.CLAUDE_CONFIG_DIR and rt.path(rt.env.CLAUDE_CONFIG_DIR, ".claude.json")
		or rt.path(home, ".claude.json")
	local user = decoded(rt, path)
	local entry = user.mcpServers and user.mcpServers.inkdrop
	local git = rt.exec({ "git", "rev-parse", "--show-toplevel" }, { cwd = cwd })
	local root = git.code == 0 and vim.trim(git.stdout) or cwd
	if root == "" then
		root = cwd
	end
	local project = decoded(rt, rt.path(root, ".mcp.json"))
	entry = project.mcpServers and project.mcpServers.inkdrop or entry
	local canonical = vim.uv.fs_realpath(cwd) or cwd
	local local_config = user.projects
		and (user.projects[canonical] or user.projects[cwd] or user.projects[root])
	entry = local_config and local_config.mcpServers and local_config.mcpServers.inkdrop or entry
	assert(entry == nil or type(entry) == "table", "orc: invalid Claude Inkdrop entry")
	local result = vim.deepcopy(entry or {})
	assert(result.disabled ~= true, "orc: Inkdrop is disabled in the provider configuration")
	for _, key in ipairs({ "headers", "headersHelper", "oauth", "auth" }) do
		local value = result[key]
		assert(
			value == nil
				or value == vim.NIL
				or value == ""
				or type(value) == "table" and next(value) == nil,
			"orc: authenticated Claude Inkdrop cannot be converted safely to this unauthenticated local bridge; manual review of authentication fields is required"
		)
	end
	for _, key in ipairs({
		"command",
		"args",
		"env",
		"cwd",
		"headers",
		"headersHelper",
		"oauth",
		"auth",
	}) do
		result[key] = nil
	end
	return result
end

local function codex_config_args(args)
	local config, index = {}, 1
	while index <= #args do
		local word = args[index]
		if word == "--" then
			break
		end
		assert(
			word ~= "--cd" and not word:match("^%-%-cd=") and not word:match("^%-C"),
			"orc: shared Inkdrop does not support native Codex directory overrides; select the working directory before launching orc"
		)
		assert(
			not word:match("^%-%-remote[=%-]?") and word ~= "--remote",
			"orc: shared Inkdrop requires a local Codex provider"
		)
		local option, value
		if word == "-c" or word == "--config" or word == "-p" or word == "--profile" then
			option, value = word, args[index + 1]
			assert(value and value ~= "", "orc: missing provider configuration value")
			index = index + 1
		elseif word:match("^%-%-config=") then
			option, value = "--config", word:sub(10)
		elseif word:match("^%-%-profile=") then
			option, value = "--profile", word:sub(11)
		elseif word:match("^%-c.") then
			option, value = "-c", word:sub(3)
		elseif word:match("^%-p.") then
			option, value = "-p", word:sub(3)
		end
		if option then
			if option == "-c" or option == "--config" then
				local key = (value:match("^%s*([^=]+)=") or ""):gsub("['\"%s]", "")
				local field = key:match("^mcp_servers%.inkdrop%.([^.]+)$")
				assert(
					key ~= "mcp_servers"
						and key ~= "mcp_servers.inkdrop"
						and not vim.tbl_contains(
							{ "command", "args", "env", "env_vars", "cwd", "url", "required" },
							field
						),
					"orc: conflicting Inkdrop transport override; use explicit migration"
				)
			end
			vim.list_extend(config, { option, value })
		end
		index = index + 1
	end
	return config
end

local function shared_args(rt, kind, cwd, args, config)
	if kind == "claude" then
		for _, word in ipairs(args) do
			if word == "--" then
				break
			end
			assert(
				word ~= "--strict-mcp-config"
					and not word:match("^%-%-mcp%-config[=]?")
					and not word:match("^%-%-strict%-mcp%-config="),
				"orc: conflicting Claude MCP options in shared Inkdrop mode"
			)
		end
		local entry = claude_entry(rt, cwd)
		entry.type, entry.url = "http", config.url
		return { "--mcp-config", rt.encode({ mcpServers = { inkdrop = entry } }) }
	end
	local inspect = { "codex" }
	vim.list_extend(inspect, codex_config_args(args))
	vim.list_extend(inspect, { "mcp", "get", "inkdrop", "--json" })
	local clean_env = {}
	for _, name in ipairs(credential_names) do
		clean_env[name] = false
	end
	local response = rt.exec(inspect, { cwd = cwd, timeout = 5000, env = clean_env })
	local ok, entry = pcall(rt.decode, response.stdout)
	assert(
		response.code == 0
			and ok
			and type(entry) == "table"
			and entry.enabled == true
			and (entry.disabled_reason == nil or entry.disabled_reason == vim.NIL)
			and type(entry.transport) == "table"
			and entry.transport.type == "streamable_http"
			and entry.transport.url == config.url,
		"orc: Codex Inkdrop must be migrated to the shared HTTP endpoint; run orc inkdrop-mcp migrate --provider codex"
	)
	return { "-c", "mcp_servers.inkdrop.required=true" }
end

---@class orc.ProviderRequest
---@field kind "claude"|"codex" Native provider executable.
---@field role "main"|"implementer" Existing workflow role.
---@field cwd? string Working directory.
---@field flags? table Orc-owned launcher options.
---@field args? string[] Native arguments, passed through without shell parsing.
---@field prompt? string Worker assignment appended as one argument.
---@field workerFile? string Durable record passed to worker hooks.

---@class orc.LaunchSpec
---@field argv string[] Provider executable and native arguments.
---@field cwd string Working directory.
---@field env table<string,string|boolean> Environment changes; false removes a variable.

---Build a native provider launch without starting its process or managing a shared service.
---Shared mode performs a bounded connection/configuration preflight and never falls back to STDIO.
---@param rt orc.Runtime
---@param request orc.ProviderRequest
---@return orc.LaunchSpec
function M.plan(rt, request)
	local kind, role = request.kind, request.role
	assert(kind == "claude" or kind == "codex", "orc: unknown provider")
	assert(role == "main" or role == "implementer", "orc: unknown provider role")
	local flags, args, cwd = request.flags or {}, request.args or {}, request.cwd or rt.cwd
	local env = { ORC = "1", ORC_ROLE = role == "main" and "" or "implementer" }
	if role == "main" then
		env.ORC_PAIR, env.ORC_PANES = flags.pair and "1" or false, flags.panes and "1" or false
		if flags.level then
			env.ORC_LEVEL = flags.level
		end
	else
		env.ORC_WORKER_FILE, env.PATH = request.workerFile, rt.env.PATH or ""
	end
	local mcp = require("orc.inkdrop_mcp")
	local config = mcp.resolve(rt, flags["inkdrop-mcp"])
	env.ORC_INKDROP_MCP_MODE = config.mode
	if config.paths and config.paths.config then
		env.ORC_INKDROP_MCP_CONFIG = config.paths.config
	end
	local command = { kind }
	if config.mode == "shared" then
		local extra = shared_args(rt, kind, cwd, args, config)
		local health = mcp.check(rt, config)
		assert(health.ok, "orc: shared Inkdrop MCP is unavailable; start or repair the user service")
		vim.list_extend(command, extra)
		for _, name in ipairs(credential_names) do
			env[name] = false
		end
		-- Rex's daemon environment may differ from the caller whose provider config was checked.
		env.HOME = rt.env.HOME
		env.CODEX_HOME = rt.env.CODEX_HOME or false
		env.CLAUDE_CONFIG_DIR = rt.env.CLAUDE_CONFIG_DIR or false
	end
	local run_rt = vim.tbl_extend("force", {}, rt, {
		cwd = cwd,
		env = vim.tbl_extend("force", {}, rt.env, env),
	})
	for name, value in pairs(run_rt.env) do
		if value == false then
			run_rt.env[name] = nil
		end
	end
	if kind == "claude" then
		-- --mcp-config is variadic, so a following option must precede any positional prompt.
		vim.list_extend(command, { "--plugin-dir", rt.root })
		local model = false
		for _, word in ipairs(args) do
			model = model or word == "--model" or word:match("^%-%-model=") ~= nil
		end
		if not model then
			vim.list_extend(command, {
				"--model",
				role == "main" and "opus" or rt.env.ORC_LEVEL == "high" and "opus" or "sonnet",
			})
		end
		if flags.yolo then
			command[#command + 1] = "--dangerously-skip-permissions"
		end
		if role == "main" and flags.level == "high" then
			local definitions = {}
			for _, file in ipairs(rt.list(rt.path(rt.root, "agents"))) do
				if file:match("%.md$") then
					local data, body =
						require("orc.generator").parse(assert(rt.read(rt.path(rt.root, "agents", file))))
					definitions[data.name] = {
						description = data.description,
						prompt = body,
						tools = vim.tbl_map(vim.trim, vim.split(data.tools or "", ",", { trimempty = true })),
						model = (data.name == "implementer" or data.name == "reviewer") and "opus" or "sonnet",
					}
				end
			end
			vim.list_extend(command, { "--agents", rt.encode(definitions) })
		end
	elseif role == "implementer" then
		vim.list_extend(command, { "--sandbox", "workspace-write" })
	else
		local context = require("orc.hooks").context(run_rt, cwd)
		vim.list_extend(command, { "-c", "developer_instructions=" .. rt.encode(context) })
		for _, file in ipairs(rt.list(rt.path(rt.root, "codex", "agents"))) do
			if file:match("%.toml$") then
				local name, path = file:gsub("%.toml$", ""), rt.path(rt.root, "codex", "agents", file)
				vim.list_extend(command, { "-c", "agents." .. name .. ".config_file=" .. rt.encode(path) })
				local description = (rt.read(path) or ""):match("\ndescription = ([^\n]+)")
				if description then
					vim.list_extend(command, { "-c", "agents." .. name .. ".description=" .. description })
				end
			end
		end
		local common = require("orc.worktrees").common(rt, cwd)
		if common then
			vim.list_extend(command, { "--add-dir", common })
		end
		if flags.yolo then
			command[#command + 1] = "--dangerously-bypass-approvals-and-sandbox"
		end
	end
	vim.list_extend(command, args)
	if request.prompt then
		command[#command + 1] = request.prompt
	end
	return { argv = command, cwd = cwd, env = env }
end

return M
