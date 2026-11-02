local M = {}

---Run a scaffold's own tests without dependencies, returning TAP-style totals.
---@param root string
---@return integer code
---@return string output
function M.run(root)
	local old_path, saved = package.path, {}
	package.path = root .. "/src/?.lua;" .. package.path
	for _, file in ipairs(vim.fn.glob(root .. "/src/*.lua", false, true)) do
		local name = vim.fs.basename(file):sub(1, -5)
		saved[name] = package.loaded[name] or false
		package.loaded[name] = nil
	end
	local passed, failed, output = 0, 0, {}
	local test = {}
	function test.eq(actual, expected)
		assert(
			vim.deep_equal(actual, expected),
			"expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual)
		)
	end
	function test.error(kind, fn)
		local ok, err = pcall(fn)
		assert(not ok and type(err) == "table" and err.kind == kind, "expected " .. kind)
	end
	function test.test(name, fn)
		local ok, err = pcall(fn)
		if ok then
			passed = passed + 1
		else
			failed = failed + 1
		end
		output[#output + 1] = (ok and "ok " or "not ok ")
			.. name
			.. (ok and "" or (" " .. tostring(err)))
	end
	for _, file in ipairs(vim.fn.glob(root .. "/test/*_spec.lua", false, true)) do
		local ok, err = pcall(function()
			assert(loadfile(file))()(test)
		end)
		if not ok then
			failed = failed + 1
			output[#output + 1] = "not ok " .. file .. " " .. tostring(err)
		end
	end
	package.path = old_path
	for name, value in pairs(saved) do
		package.loaded[name] = value or nil
	end
	output[#output + 1] = "# pass " .. passed
	output[#output + 1] = "# fail " .. failed
	return failed == 0 and 0 or 1, table.concat(output, "\n") .. "\n"
end

if
	arg
	and arg[0]
	and vim.uv.fs_realpath(arg[0]) == vim.uv.fs_realpath(debug.getinfo(1, "S").source:sub(2))
then
	local code, output = M.run(assert(vim.uv.cwd()))
	io.stdout:write(output)
	if code ~= 0 then
		error("fixture tests failed", 0)
	end
end
return M
