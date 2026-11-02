#!/usr/bin/env -S nvim -l
local file = assert(vim.uv.fs_realpath(arg[0]))
local root = vim.fs.dirname(vim.fs.dirname(file))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
assert(#arg == 0 or #arg == 1 and arg[1] == "--check", "usage: gen-agents.lua [--check]")
local result = require("orc.generator").generate(
	require("orc.runtime").new({ root = root }),
	arg[1] == "--check"
)
io.stdout:write(result.out)
io.stdout:flush()
os.exit(result.code)
