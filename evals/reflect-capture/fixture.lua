#!/usr/bin/env -S nvim -l
local M = {}
local source = assert(vim.uv.fs_realpath(debug.getinfo(1, "S").source:sub(2)))
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))

---Prepare this case's disposable repository; never execute models.
---@param target? string
---@return boolean
function M.run(target)
	package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
	local rt = require("orc.runtime").new({ root = root })
	return require("orc.eval").scaffold(rt, "reflect-capture", target or rt.cwd)
end
if arg and arg[0] and vim.uv.fs_realpath(arg[0]) == source then
	M.run()
end
return M
