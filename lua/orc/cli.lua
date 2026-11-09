local M = {}
M.version = "0.1.0"
M.usage = [[usage: orc <command> [args]

  claude|codex [--yolo] [--level default|high|max] [--panes|--no-panes|--pair] [--wt <branch>] [--base <ref>] [--inkdrop-mcp inherit|shared] [harness args]
  wt new|merge|remove|list|session ...
  pane start <feature> <task> --path <dir> --brief <file> [--role implementer|scoper] [--kind codex|claude] [--transport tui|exec] [--here] [--allow-subdir] [--precheck <cmd>]
  pane wait <task> --path <dir> [--until report] [--timeout <ms>]
  pane prompt <task> --path <dir> --text <text>|--file <file> [--queue]
  pane close <task> --path <dir> [--force]
  pane prune --path <dir>
  gate [--label <name>] [--log <file>] -- <cmd...>
  status|doctor [--json]
  context [--scope user|project|all] [--json]
  inkdrop init|inbox|claim|push|pull|lessons ...
  inkdrop-mcp install|start|stop|restart|status|enable|disable|migrate|rollback|uninstall ...
  update
  eval [--bench] [evaluation args]
  completion fish
  --help | --version

Pair and pane modes use Rex; pair mode is Claude-main with one Codex worker.
Pane mode is automatic inside Rex; --no-panes or ORC_PANES=0 disables it.
Pane workers default to Codex, the implementer role and tui transport; exec is Codex-only.
--yolo bypasses harness permissions and sandbox only when explicitly requested.
]]

local function slice(argv, first)
	return vim.list_slice(argv, first or 2)
end

local function own_flags(argv)
	local flags, rest = {}, {}
	local strings = { level = true, wt = true, base = true, ["inkdrop-mcp"] = true }
	local booleans = { yolo = true, panes = true, ["no-panes"] = true, pair = true }
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
	return flags, rest
end

-- Explicit flags win, then ORC_PANES; otherwise pane mode follows a Rex terminal.
local function panes_enabled(rt, flags)
	if flags.panes then
		return true
	end
	if flags["no-panes"] or rt.env.ORC_PANES == "0" then
		return false
	end
	if rt.env.ORC_PANES == "1" then
		return true
	end
	if flags.pair then
		return false
	end
	return (rt.env.REX_SESSION or "") ~= "" and (rt.env.REX_BLOCK or "") ~= ""
end

local function launch(rt, kind, argv)
	local flags, rest = own_flags(argv)
	assert(not (flags.panes and flags["no-panes"]), "--panes and --no-panes cannot be combined")
	flags.pair = flags.pair or kind == "claude" and rt.env.ORC_PAIR == "1"
	flags.panes = panes_enabled(rt, flags)
	flags.level = flags.level or rt.env.ORC_LEVEL
	assert(not (flags.pair and flags.panes), "--pair and --panes cannot be combined")
	assert(
		not flags.level or flags.level == "default" or flags.level == "high" or flags.level == "max",
		"--level must be default, high or max"
	)
	assert(not flags.pair or kind == "claude", "--pair requires a Claude orchestrator")
	if flags.pair or flags.panes then
		assert(rt.env.REX_SESSION and rt.env.REX_BLOCK, "orc: pair/pane mode needs a Rex terminal")
	end
	local cwd = rt.cwd
	if flags.wt then
		cwd = require("orc.worktrees").session(rt, flags.wt, flags.base, false).path
	end
	local launch = require("orc.providers").plan(rt, {
		kind = kind,
		role = "main",
		cwd = cwd,
		flags = flags,
		args = rest,
	})
	return { code = rt.interactive(launch.argv, { cwd = launch.cwd, env = launch.env }), out = "" }
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
							or { "codex", "plugin", "add", "orc@orc-nvim" }
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
		elseif command == "worker-run" then
			assert(#rest == 1, "usage: orc worker-run <record-file>")
			return require("orc.workers").worker_run(rt, rest[1])
		elseif command == "wt" then
			local response = require("orc.worktrees").run(rt, rest)
			if response.result.status == "merged" then
				local recorded, warning = pcall(
					require("orc.status").record_merge,
					rt,
					response.result.base,
					response.result.task,
					response.result.commit
				)
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
			gate = "gate",
			pane = "workers",
			status = "status",
			doctor = "doctor",
			context = "context",
			inkdrop = "inkdrop",
			["inkdrop-mcp"] = "inkdrop_service",
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
