local M = {}

---Report local prerequisites without changing harness trust or starting a model.
function M.check()
	local health = vim.health
	health.start("orc.nvim")
	if vim.fn.has("nvim-0.11") == 1 then
		health.ok("Neovim >= 0.11")
	else
		health.error("Neovim >= 0.11 is required")
	end
	for _, executable in ipairs({ "git", "wt", "curl" }) do
		if vim.fn.executable(executable) == 1 then
			health.ok(executable .. " available")
		else
			health.warn(executable .. " missing")
		end
	end
	local ok, identity = pcall(function()
		return require("orc.rex").new(require("orc.runtime").new()).identity()
	end)
	if ok then
		health.ok("Local Rex server " .. identity.instance_id)
	else
		health.warn(tostring(identity))
	end
	health.info(
		"Approve changed lifecycle hooks in the harness before automated worker delivery; trust dialogs are never answered by orc."
	)
end

return M
