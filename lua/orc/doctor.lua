local M = {}
local marks = { pass = "✓", fail = "✗", warn = "!", info = "·" }

---Inspect prerequisites without installing software or modifying harness configuration.
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
			vim.trim((result.code == 0 and result.stdout or result.stderr)):match("[^\n]*") or "not found",
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
	local rex = rt.exec({ "rex", "version" })
	if rex.code == 0 then
		add("rex", "pass", vim.trim(rex.stdout))
		if pane_mode then
			local connected = rt.exec({ "rex", "whoami", "--json" })
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
	if
		rt.env.INKDROP_LOCAL_USERNAME
		and rt.env.INKDROP_LOCAL_PASSWORD
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
