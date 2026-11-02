local M = {}
M.version = "0.1.0"
M.usage = [[usage: orc <command> [args]

  claude|codex [--yolo] [--level default|high] [--panes|--pair] [--wt <branch>] [--base <ref>] [harness args]
  wt new|merge|remove|list|session ...
  pane start|wait|prompt|close ...
  status|doctor [--json]
  context [--scope user|project|all] [--json]
  inkdrop init|inbox|claim|push|pull|lessons ...
  update
  eval [--bench] [evaluation args]
  completion fish
  --help | --version

Pair and pane modes use Rex; pair mode is Claude-main with one Codex worker.
--yolo bypasses harness permissions and sandbox only when explicitly requested.
]]

local function slice(argv, first)
	return vim.list_slice(argv, first or 2)
end

local function own_flags(argv)
	local flags, rest = {}, {}
	local strings = { level = true, wt = true, base = true }
	local booleans = { yolo = true, panes = true, pair = true }
	local index = 1
	while index <= #argv do
		local word = argv[index]
		if word == "--" then
			vim.list_extend(rest, slice(argv, index))
			break
		end
		local name, value = word:match("^%-%-([^=]+)=(.*)$")
		name = name or word:match("^%-%-(.+)$")
		if strings[name] or booleans[name] then
			assert(flags[name] == nil, "duplicate option: --" .. name)
			if strings[name] then
				if value == nil then
					index = index + 1
					value = argv[index]
				end
				assert(value and value ~= "" and value:sub(1, 2) ~= "--", "--" .. name .. " needs a value")
				flags[name] = value
			else
				assert(value == nil, "--" .. name .. " takes no value")
				flags[name] = true
			end
		else
			rest[#rest + 1] = word
		end
		index = index + 1
	end
	assert(not flags.base or flags.wt, "--base needs --wt <branch>")
	assert(not (flags.pair and flags.panes), "--pair and --panes cannot be combined")
	assert(
		not flags.level or flags.level == "default" or flags.level == "high",
		"--level must be default or high"
	)
	return flags, rest
end

local function launch(rt, kind, argv)
	local flags, rest = own_flags(argv)
	flags.pair = flags.pair or kind == "claude" and rt.env.ORC_PAIR == "1"
	flags.panes = flags.panes or rt.env.ORC_PANES == "1"
	flags.level = flags.level or rt.env.ORC_LEVEL
	assert(not (flags.pair and flags.panes), "--pair and --panes cannot be combined")
	assert(
		not flags.level or flags.level == "default" or flags.level == "high",
		"--level must be default or high"
	)
	assert(not flags.pair or kind == "claude", "--pair requires a Claude orchestrator")
	if flags.pair or flags.panes then
		assert(rt.env.REX_SESSION and rt.env.REX_BLOCK, "orc: pair/pane mode needs a Rex terminal")
	end
	local cwd = rt.cwd
	if flags.wt then
		cwd = require("orc.worktrees").session(rt, flags.wt, flags.base, false).path
	end
	local env = {
		ORC = "1",
		ORC_ROLE = "",
		ORC_PAIR = flags.pair and "1" or false,
		ORC_PANES = flags.panes and "1" or false,
	}
	if flags.level then
		env.ORC_LEVEL = flags.level
	end
	local run_rt = vim.tbl_extend(
		"force",
		{},
		rt,
		{ cwd = cwd, env = vim.tbl_extend("force", {}, rt.env, env) }
	)
	for name, value in pairs(run_rt.env) do
		if value == false then
			run_rt.env[name] = nil
		end
	end
	local command = { kind }
	if kind == "claude" then
		vim.list_extend(command, { "--plugin-dir", rt.root })
		local model = false
		for _, word in ipairs(rest) do
			model = model or word == "--model" or word:match("^%-%-model=") ~= nil
		end
		if not model then
			vim.list_extend(command, { "--model", "opus" })
		end
		if flags.yolo then
			command[#command + 1] = "--dangerously-skip-permissions"
		end
		if flags.level == "high" then
			local definitions = {}
			for _, file in ipairs(rt.list(rt.path(rt.root, "agents"))) do
				if file:match("%.md$") then
					local data, body =
						require("orc.generator").parse(assert(rt.read(rt.path(rt.root, "agents", file))))
					definitions[data.name] = {
						description = data.description,
						prompt = body,
						tools = vim.tbl_map(vim.trim, vim.split(data.tools or "", ",", { trimempty = true })),
						model = data.name == "implementer" and "opus"
							or data.name == "reviewer" and "opus"
							or "sonnet",
					}
				end
			end
			vim.list_extend(command, { "--agents", rt.encode(definitions) })
		end
	else
		local context = require("orc.hooks").context(run_rt, cwd)
		vim.list_extend(command, { "-c", "developer_instructions=" .. rt.encode(context) })
		for _, file in ipairs(rt.list(rt.path(rt.root, "codex", "agents"))) do
			if file:match("%.toml$") then
				local name = file:gsub("%.toml$", "")
				local path = rt.path(rt.root, "codex", "agents", file)
				vim.list_extend(command, { "-c", "agents." .. name .. ".config_file=" .. rt.encode(path) })
				local description = (rt.read(path) or ""):match("\ndescription = ([^\n]+)")
				if description then
					vim.list_extend(command, { "-c", "agents." .. name .. ".description=" .. description })
				end
			end
		end
		local common = rt.exec(
			{ "git", "rev-parse", "--path-format=absolute", "--git-common-dir" },
			{ cwd = cwd }
		)
		if common.code == 0 and vim.trim(common.stdout) ~= "" then
			vim.list_extend(command, { "--add-dir", vim.trim(common.stdout) })
		end
		if flags.yolo then
			command[#command + 1] = "--dangerously-bypass-approvals-and-sandbox"
		end
	end
	vim.list_extend(command, rest)
	return { code = rt.interactive(command, { cwd = cwd, env = env }), out = "" }
end

local function update(rt, argv)
	assert(#argv == 0, "usage: orc update")
	local dirty = rt.exec({ "git", "status", "--porcelain" }, { cwd = rt.root })
	assert(dirty.code == 0, "orc update requires a Git installation")
	assert(vim.trim(dirty.stdout) == "", "orc update refuses a dirty checkout")
	local pulled = rt.exec({ "git", "pull", "--ff-only" }, { cwd = rt.root })
	local code, output, errors = pulled.code, pulled.stdout, pulled.stderr
	if code ~= 0 then
		return { code = code, out = output, err = errors }
	end
	for _, kind in ipairs({ "claude", "codex" }) do
		local listing = rt.exec({ kind, "plugin", "marketplace", "list", "--json" })
		if listing.code == 0 then
			local ok, decoded = pcall(rt.decode, listing.stdout)
			if ok and type(decoded) == "table" then
				for _, market in ipairs(decoded.marketplaces or decoded) do
					if market.name == "orc-nvim" then
						local command = kind == "claude" and { "claude", "plugin", "update", "orc@orc-nvim" }
							or { "codex", "plugin", "marketplace", "upgrade", "orc-nvim" }
						local result = rt.exec(command)
						output, errors = output .. result.stdout, errors .. result.stderr
						if code == 0 then
							code = result.code
						end
					end
				end
			end
		end
	end
	return { code = code, out = output, err = errors }
end

---Route one CLI request. Expected failures produce diagnostics, never Lua tracebacks.
---@param rt orc.Runtime
---@param argv string[]
---@param input? string Lifecycle-hook JSON, read by the entrypoint only for hook requests.
---@return table result Fields code, out and err; all output remains caller-controlled.
function M.run(rt, argv, input)
	local ok, result = pcall(function()
		local command, rest = argv[1], slice(argv)
		if not command or command == "help" or command == "--help" or command == "-h" then
			return { code = 0, out = M.usage }
		elseif command == "--version" or command == "-V" then
			return { code = 0, out = M.version .. "\n" }
		elseif command == "claude" or command == "codex" then
			return launch(rt, command, rest)
		elseif command == "hook" then
			assert(#rest == 1, "usage: orc hook <event>")
			return require("orc.hooks").run(rt, rest[1], input or "")
		elseif command == "wt" then
			local response = require("orc.worktrees").run(rt, rest)
			if response.result.status == "merged" then
				local flags, pos = require("orc.args").parse(rest, { yes = "boolean", message = "string" })
				local recorded, warning =
					pcall(require("orc.status").record_merge, rt, pos[2], pos[3], response.result.commit)
				if not recorded or warning then
					response.err = "orc: " .. tostring(warning) .. "\n"
				end
			end
			return response
		elseif command == "completion" then
			assert(#rest == 1 and rest[1] == "fish", "usage: orc completion fish")
			return { code = 0, out = require("orc.completion").fish() }
		elseif command == "update" then
			return update(rt, rest)
		end
		local modules = {
			pane = "workers",
			status = "status",
			doctor = "doctor",
			context = "context",
			inkdrop = "inkdrop",
			eval = "eval",
		}
		assert(modules[command], "unknown command: " .. command .. "\n" .. M.usage)
		return require("orc." .. modules[command]).run(rt, rest)
	end)
	if not ok then
		return { code = 1, out = "", err = "orc: " .. tostring(result) .. "\n" }
	end
	return result
end

return M
