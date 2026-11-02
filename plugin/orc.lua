if vim.g.loaded_orc then
	return
end
vim.g.loaded_orc = true
require("orc").setup()
