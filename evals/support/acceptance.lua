local M = {}

---Run each hidden assertion independently, retaining structured per-case outcomes.
---@param api table Candidate module.
---@param suite fun(api:table,test:table)
---@return table
function M.run(api, suite)
	local result = { pass = 0, total = 0, results = {} }
	local test = {}
	function test.eq(actual, expected)
		assert(
			vim.deep_equal(actual, expected),
			"expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual)
		)
	end
	function test.error(kind, fn, position)
		local ok, err = pcall(fn)
		assert(
			not ok and type(err) == "table" and err.kind == kind,
			"expected " .. kind .. ", got " .. vim.inspect(err)
		)
		if position ~= nil then
			test.eq(err.position, position)
		end
		assert(type(err.message) == "string" and #err.message > 0, "error needs a message")
	end
	function test.test(name, fn)
		local ok, err = pcall(fn)
		result.total = result.total + 1
		if ok then
			result.pass = result.pass + 1
		end
		result.results[#result.results + 1] =
			{ name = name, passed = ok, error = not ok and tostring(err) or nil }
	end
	suite(api, test)
	return result
end
return M
