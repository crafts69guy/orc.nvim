local M = {}

---Register :Orc and optional setup values; no global keymaps are installed.
---@param opts? {cwd?:string} Optional project directory override.
function M.setup(opts)
	opts = opts or {}
	vim.api.nvim_create_user_command("Orc", function(command)
		local ui = require("orc.ui")
		ui.open(require("orc.runtime").new({ cwd = opts.cwd }))
		if command.args ~= "" then
			ui.action(command.args)
		end
	end, {
		nargs = "?",
		force = true,
		complete = function()
			return { "status", "refresh", "brief", "report", "diff", "focus", "prompt" }
		end,
		desc = "Open orc task panel or act on the selected task",
	})
end

return M
