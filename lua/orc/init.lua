local M = {}

---@class orc.ViewOptions
---@field cwd? string Absolute project directory; defaults to the editor's current directory.
---@field client_id? string Originating Rex app, used when focusing a worker.
---@field quit_on_close? boolean Exit the dedicated popup process on close; false in a normal editor.

---Open the task view; neither closing the view nor its popup closes a Rex worker.
---@param opts? orc.ViewOptions Explicit popup context.
---@return integer buffer Task panel buffer.
function M.open(opts)
	opts = opts or {}
	if opts.cwd then
		local stat = type(opts.cwd) == "string"
			and opts.cwd:sub(1, 1) == "/"
			and vim.uv.fs_stat(opts.cwd)
		assert(stat and stat.type == "directory", "orc: cwd must be an existing absolute directory")
	end
	return require("orc.ui").open(require("orc.runtime").new({ cwd = opts.cwd }), opts)
end

---Search GHQ repositories with Telescope and open a fresh local Rex session.
---@param opts? orc.ProjectOptions Explicit originating app and popup lifetime.
---@return orc.ProcessHandle handle Stops only the view's owned subprocesses.
function M.projects(opts)
	return require("orc.projects").open(require("orc.runtime").new(), opts)
end

---Register :Orc and optional setup values; no global keymaps are installed.
---@param opts? {cwd?:string} Optional project directory override.
function M.setup(opts)
	opts = opts or {}
	vim.api.nvim_create_user_command("Orc", function(command)
		if command.args == "projects" then
			M.projects()
			return
		end
		local ui = require("orc.ui")
		M.open({ cwd = opts.cwd })
		if command.args ~= "" then
			ui.action(command.args)
		end
	end, {
		nargs = "?",
		force = true,
		complete = function()
			return { "status", "refresh", "brief", "report", "diff", "focus", "prompt", "projects" }
		end,
		desc = "Open orc task panel or act on the selected task",
	})
end

return M
