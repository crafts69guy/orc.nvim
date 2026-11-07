local M = {}
local marks = { pass = "✓", fail = "✗", warn = "!", info = "·" }

local function trust_sections(config)
	local sections, current = {}, nil
	for line in (config .. "\n"):gmatch("([^\n]*)\n") do
		local header = line:match("^%s*(%[.*%])")
		if header then
			current = {}
			sections[header] = current
		elseif current then
			local key, value = line:match("^%s*([%w_]+)%s*=%s*(.*)")
			if key then
				current[key] = value:match('^"(.-)"') or value:match("^'(.-)'")
			end
		end
	end
	return sections
end

local function codex_hooks(rt, sections, add)
	local ok, manifest = pcall(rt.decode, rt.read(rt.path(rt.root, "hooks", "hooks.json")) or "")
	if not ok or type(manifest) ~= "table" or type(manifest.hooks) ~= "table" then
		add("codex-hooks", "info", "hook manifest unavailable")
		return
	end
	local missing = {}
	for event in pairs(manifest.hooks) do
		local name = event:gsub("(%l)(%u)", "%1_%2"):lower()
		local header = '[hooks.state."orc@orc-nvim:hooks/hooks.json:' .. name .. ':0:0"]'
		local section = sections[header] or {}
		-- shortcut: hash validity is not verified; compare hook contents if stale trust becomes diagnosable.
		if not section.trusted_hash or section.trusted_hash == "" then
			missing[#missing + 1] = name
		end
	end
	table.sort(missing)
	if #missing > 0 then
		add(
			"codex-hooks",
			"warn",
			"missing hook trust: " .. table.concat(missing, ", "),
			"open Codex, run /hooks and trust orc hooks"
		)
	else
		add("codex-hooks", "pass", "all orc hook trust entries present")
	end
end

local function codex_worktrees(rt, sections, add)
	local root = require("orc.worktrees").root(rt)
	local paths = {}
	if root then
		local directory = rt.path(root, ".worktrees")
		for _, name in ipairs(rt.list(directory)) do
			local path = rt.path(directory, name)
			if rt.exists(rt.path(path, ".git")) then
				paths[#paths + 1] = path
			end
		end
	end
	if #paths == 0 then
		add("codex-worktrees", "info", "no task worktrees")
		return
	end
	if not sections then
		add("codex-worktrees", "info", "Codex config unavailable; folder trust unchecked")
		return
	end
	local missing = {}
	local main = sections["[projects." .. rt.encode(root) .. "]"] or {}
	for _, path in ipairs(paths) do
		local section = sections["[projects." .. rt.encode(path) .. "]"] or {}
		if section.trust_level ~= "trusted" and main.trust_level ~= "trusted" then
			missing[#missing + 1] = path
		end
	end
	if #missing > 0 then
		add(
			"codex-worktrees",
			"warn",
			"untrusted task worktrees: " .. table.concat(missing, ", "),
			"trust the folder in Codex once; orc never writes trust"
		)
	else
		add("codex-worktrees", "pass", "all task worktrees trusted")
	end
end

---Inspect prerequisites and Codex trust entries without modifying configuration.
---@param rt orc.Runtime
---@return table schema Versioned doctor document.
function M.collect(rt)
	local checks = {}
	local function add(name, status, detail, fix)
		checks[#checks + 1] =
			{ name = name, status = status, mark = marks[status], detail = detail, fix = fix }
	end
	local version = vim.version()
	add(
		"neovim",
		(version.major > 0 or version.minor >= 11) and "pass" or "fail",
		tostring(version),
		"install Neovim >=0.11"
	)
	local function tool(name, argv, required)
		local result = rt.exec(argv)
		add(
			name,
			result.code == 0 and "pass" or required and "fail" or "warn",
			vim.trim((result.code == 0 and result.stdout or result.stderr)):match("[^\n]*"),
			"install " .. name
		)
		return result.code == 0
	end
	tool("git", { "git", "--version" }, true)
	tool("wt", { "wt", "--version" }, true)
	local claude = tool("claude", { "claude", "--version" }, false)
	local codex = tool("codex", { "codex", "--version" }, false)
	if not claude and not codex then
		add("harness", "fail", "neither Claude Code nor Codex is available", "install a coding harness")
	end
	local pane_mode = rt.env.ORC_PAIR == "1" or rt.env.ORC_PANES == "1"
	local executable = require("orc.rex").resolve(rt)
	local rex = rt.exec({ executable, "version" })
	if rex.code == 0 then
		add("rex", "pass", vim.trim(rex.stdout))
		if pane_mode then
			local connected = rt.exec({ executable, "whoami", "--json" })
			add(
				"rex-session",
				connected.code == 0 and "pass" or "fail",
				connected.code == 0 and "connected" or "server unavailable",
				"start Rex and open a terminal"
			)
		end
	else
		add(
			"rex",
			pane_mode and "fail" or "warn",
			"required for pane/pair mode",
			"install Rex and expose its CLI on PATH"
		)
	end
	add(
		"plugin",
		rt.exists(rt.path(rt.root, "hooks", "hooks.json")) and "pass" or "fail",
		rt.root,
		"reinstall orc.nvim"
	)
	local mcp = require("orc.inkdrop_mcp")
	local configured, shared = pcall(mcp.resolve, rt)
	if not configured then
		add("inkdrop-mcp", "fail", tostring(shared), "check the private shared Inkdrop settings")
	elseif shared.mode == "shared" then
		local health = mcp.check(rt, shared)
		add(
			"inkdrop-mcp",
			health.ok and "pass" or "fail",
			health.ok and "shared HTTP endpoint ready" or health.error,
			"inspect orc inkdrop-mcp status; service start is explicit"
		)
	else
		add("inkdrop-mcp", "info", "inherit provider configuration")
	end
	local private_ok, private = true, nil
	if rt.env.ORC_INKDROP ~= "0" then
		private_ok, private = pcall(mcp.credentials, rt)
	end
	local env = private_ok and private or rt.env
	if not private_ok then
		add("inkdrop", "warn", tostring(private), "check the private backend credential file")
	elseif
		(env or rt.env).INKDROP_LOCAL_USERNAME
		and (env or rt.env).INKDROP_LOCAL_PASSWORD
		and rt.env.ORC_INKDROP ~= "0"
	then
		local inkdrop = require("orc.inkdrop")
		local probe = inkdrop.probe(rt)
		add(
			"inkdrop",
			probe.error and "warn" or "pass",
			probe.error or "v" .. tostring(probe.version),
			"enable Inkdrop's local server"
		)
	else
		add("inkdrop", "info", "not configured")
	end
	if codex then
		local home = rt.env.CODEX_HOME
		if not home and rt.env.HOME then
			home = rt.path(rt.env.HOME, ".codex")
		end
		if home then
			local config = rt.read(rt.path(home, "config.toml"))
			local sections
			if config then
				sections = trust_sections(config)
				codex_hooks(rt, sections, add)
			else
				add("codex-hooks", "info", "Codex config missing or unreadable: " .. home)
			end
			codex_worktrees(rt, sections, add)
		else
			add("codex-hooks", "info", "Codex config location unknown")
			add("codex-worktrees", "info", "Codex config location unknown")
		end
	end
	return { schemaVersion = 1, checks = checks }
end

---Return prerequisite checks as text or versioned JSON.
---@param rt orc.Runtime
---@param argv string[]
---@return table
function M.run(rt, argv)
	local flags, pos = require("orc.args").parse(argv, { json = "boolean" })
	assert(#pos == 0, "usage: orc doctor [--json]")
	local result, failed, lines = M.collect(rt), false, {}
	for _, check in ipairs(result.checks) do
		failed = failed or check.status == "fail"
		lines[#lines + 1] = check.mark
			.. " "
			.. check.name
			.. "  "
			.. check.detail
			.. (check.fix and " — fix: " .. check.fix or "")
	end
	return {
		code = failed and 1 or 0,
		out = (flags.json and rt.encode(result) or table.concat(lines, "\n")) .. "\n",
	}
end

return M
