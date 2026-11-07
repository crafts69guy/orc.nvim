local uv = vim.uv
local file = assert(uv.fs_realpath(arg[0]))
local cwd = assert(uv.cwd())
local root = vim.env.ORC_TEST_ROOT
	or (uv.fs_stat(cwd .. "/test/run.lua") and cwd)
	or vim.fs.dirname(vim.fs.dirname(file))
package.path = root
	.. "/lua/?.lua;"
	.. root
	.. "/lua/?/init.lua;"
	.. root
	.. "/?.lua;"
	.. package.path

-- Tests must not see the invoking orc/Rex session.
for name in pairs(vim.fn.environ()) do
	if name:match("^ORC") or name:match("^REX_") or name:match("^INKDROP_") then
		vim.env[name] = nil
	end
end
vim.env.CLAUDE_CONFIG_DIR = nil
vim.env.CODEX_HOME = nil

local tests, temporary = {}, {}
local filter, coverage, coverage_session
local index = 1
while index <= #arg do
	if arg[index] == "--filter" then
		index = index + 1
		filter = assert(arg[index], "--filter needs a substring")
	elseif arg[index] == "--coverage" then
		coverage = true
	else
		error("unknown test option: " .. arg[index])
	end
	index = index + 1
end

---@class orc.Test
---@field test fun(name:string,fn:function) Register a test.
---@field eq fun(actual:any,expected:any) Assert deep equality.
---@field raises fun(pattern:string,fn:function) Assert an error matching a Lua pattern.
---@field temp fun():string Create an automatically cleaned temporary directory.
Test = {}

function Test.test(name, fn)
	assert(type(name) == "string" and type(fn) == "function", "test needs a name and function")
	tests[#tests + 1] = { name = name, run = fn }
end

function Test.eq(actual, expected)
	assert(
		vim.deep_equal(actual, expected),
		"expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual)
	)
end

function Test.raises(pattern, fn)
	local ok, err = pcall(fn)
	assert(not ok, "expected an error matching " .. pattern)
	assert(
		tostring(err):match(pattern),
		"expected error matching " .. pattern .. ", got " .. tostring(err)
	)
end

function Test.temp()
	local path = assert(uv.fs_mkdtemp(vim.fn.tempname() .. "-XXXXXX"))
	temporary[#temporary + 1] = path
	return path
end

local function cleanup()
	for _, path in ipairs(temporary) do
		vim.fn.delete(path, "rf")
	end
end

local finished, current = false, "none"

-- A quit mid-run (e.g. a test running `qa`) would otherwise exit 0 with specs unrun.
vim.api.nvim_create_autocmd("VimLeavePre", {
	callback = function()
		if finished then
			return
		end
		io.stderr:write(
			"orc test runner: Neovim exited before the run finished (last test: " .. current .. ")\n"
		)
		cleanup()
		io.stdout:flush()
		io.stderr:flush()
		os.exit(1)
	end,
})

local function run()
	if coverage then
		local ok, module = pcall(require, "test.support.coverage")
		assert(ok, "coverage requested but coverage tooling is unavailable: " .. tostring(module))
		coverage_session = module.start(root)
	end
	local files = vim.fn.glob(root .. "/test/*_spec.lua", false, true)
	table.sort(files)
	for _, path in ipairs(files) do
		dofile(path)
	end
	local passed, failed = 0, 0
	for _, test in ipairs(tests) do
		if not filter or test.name:find(filter, 1, true) then
			current = test.name
			local ok, err = xpcall(test.run, debug.traceback)
			if ok then
				passed = passed + 1
				io.stdout:write("ok " .. test.name .. "\n")
			else
				failed = failed + 1
				io.stderr:write("not ok " .. test.name .. "\n" .. tostring(err) .. "\n")
			end
		end
	end
	assert(passed + failed > 0, "no tests matched")
	io.stdout:write(string.format("# pass %d\n# fail %d\n", passed, failed))
	if coverage then
		local accepted, reason, report = coverage_session.check(98)
		vim.fn.mkdir(root .. "/coverage", "p")
		vim.fn.writefile({ vim.json.encode(report) }, root .. "/coverage/report.json")
		for _, name in ipairs({ "lines", "branches", "functions" }) do
			local metric = report[name]
			io.stdout:write(
				string.format(
					"# coverage %s %d/%d %.2f%%\n",
					name,
					metric.hit,
					metric.total,
					metric.percent
				)
			)
		end
		coverage_session.stop()
		if not accepted then
			io.stderr:write(reason .. "\n")
			failed = failed + 1
		end
	end
	return failed == 0 and 0 or 1
end

local ok, result = xpcall(run, debug.traceback)
if coverage_session then
	coverage_session.stop()
end
cleanup()
if not ok then
	io.stderr:write(tostring(result) .. "\n")
	result = 1
end
io.stdout:flush()
io.stderr:flush()
finished = true
vim.cmd("cquit " .. result)
