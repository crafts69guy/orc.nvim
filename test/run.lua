local uv = vim.uv
local file = assert(uv.fs_realpath(arg[0]))
local cwd = assert(uv.cwd())
local root = vim.env.ORC_TEST_ROOT
	or (uv.fs_stat(cwd .. "/test/run.lua") and cwd)
	or vim.fs.dirname(vim.fs.dirname(file))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. root .. "/?.lua;" .. package.path

local tests, temporary = {}, {}
local filter, coverage
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
	assert(vim.deep_equal(actual, expected), "expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
end

function Test.raises(pattern, fn)
	local ok, err = pcall(fn)
	assert(not ok, "expected an error matching " .. pattern)
	assert(tostring(err):match(pattern), "expected error matching " .. pattern .. ", got " .. tostring(err))
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

local function run()
	if coverage then
		local ok, module = pcall(require, "test.support.coverage")
		assert(ok, "coverage requested but coverage tooling is unavailable: " .. tostring(module))
		coverage = module
		coverage.start(root)
	end
	local files = vim.fn.glob(root .. "/test/*_spec.lua", false, true)
	table.sort(files)
	for _, path in ipairs(files) do
		dofile(path)
	end
	local passed, failed = 0, 0
	for _, test in ipairs(tests) do
		if not filter or test.name:find(filter, 1, true) then
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
		coverage.finish()
	end
	return failed == 0 and 0 or 1
end

local ok, result = xpcall(run, debug.traceback)
cleanup()
if not ok then
	io.stderr:write(tostring(result) .. "\n")
	result = 1
end
io.stdout:flush()
io.stderr:flush()
vim.cmd("cquit " .. result)
