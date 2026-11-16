local root =
	assert(vim.uv.fs_realpath(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))))

-- Run test/run.lua against a temp root holding the given spec bodies.
local function run_specs(specs, log_file)
	local temp = Test.temp()
	vim.fn.mkdir(temp .. "/test", "p")
	for index, body in ipairs(specs) do
		vim.fn.writefile(vim.split(body, "\n"), string.format("%s/test/%02d_spec.lua", temp, index))
	end
	return vim
		.system({ "nvim", "--clean", "-l", root .. "/test/run.lua" }, {
			text = true,
			cwd = temp,
			env = { ORC_TEST_ROOT = temp, NVIM_LOG_FILE = log_file or "/dev/null" },
		})
		:wait(20000)
end

Test.test("runner replaces the Neovim fallback log path for child processes", function()
	-- In the sandbox the outer Neovim may already have written ./nvim.log before Lua starts.
	local existed = vim.uv.fs_stat("nvim.log")
	local result = run_specs({
		[[Test.test("log path", function()
			local path = assert(vim.env.NVIM_LOG_FILE)
			assert(vim.startswith(path, "/"), "expected an absolute log path, got " .. path)
			local child = vim.system({"env"}, {text = true}):wait()
			assert(child.stdout:find("NVIM_LOG_FILE=" .. path, 1, true))
		end)]],
	}, "nvim.log")
	assert(result.code == 0, result.stdout .. result.stderr)
	assert(existed or not vim.uv.fs_stat("nvim.log"), "child runner created nvim.log in caller cwd")
	Test.eq(require("orc.runtime").new().env.NVIM_LOG_FILE, vim.env.NVIM_LOG_FILE)
end)

Test.test("runner exits 0 and reports a passing run", function()
	local result =
		run_specs({ 'Test.test("fine", function() Test.eq(vim.env.NVIM_LOG_FILE, "/dev/null") end)' })
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
