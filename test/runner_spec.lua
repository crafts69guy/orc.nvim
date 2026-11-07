local root =
	assert(vim.uv.fs_realpath(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))))

-- Run test/run.lua against a temp root holding the given spec bodies.
local function run_specs(specs)
	local temp = Test.temp()
	vim.fn.mkdir(temp .. "/test", "p")
	for index, body in ipairs(specs) do
		vim.fn.writefile(vim.split(body, "\n"), string.format("%s/test/%02d_spec.lua", temp, index))
	end
	return vim
		.system({ "nvim", "--clean", "-l", root .. "/test/run.lua" }, {
			text = true,
			env = { ORC_TEST_ROOT = temp, NVIM_LOG_FILE = "/dev/null" },
		})
		:wait(20000)
end

Test.test("runner exits 0 and reports a passing run", function()
	local result = run_specs({ 'Test.test("fine", function() end)' })
	Test.eq(result.code, 0)
	assert(result.stdout:find("# pass 1", 1, true), result.stdout)
end)

Test.test("runner exits 1 for a failing test", function()
	local result = run_specs({ 'Test.test("bad", function() error("boom") end)' })
	Test.eq(result.code, 1)
	assert(result.stderr:find("not ok bad", 1, true), result.stderr)
end)

Test.test("runner fails when Neovim quits before the run finishes", function()
	local result = run_specs({
		'Test.test("quitter", function() vim.cmd("qa") end)',
		'Test.test("later", function() end)',
	})
	assert(result.code ~= 0, "expected non-zero exit, got " .. result.code)
	assert(
		result.stderr:find("exited before the run finished (last test: quitter)", 1, true),
		result.stderr
	)
	assert(not result.stdout:find("# pass", 1, true), result.stdout)
end)
