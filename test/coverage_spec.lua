local coverage = require("test.support.coverage")

local function execute(source, exercise)
	local instrumented, manifest = coverage.instrument(source, "corpus.lua")
	local collector = coverage.collector({ manifest })
	collector.activate()
	local ok, err = xpcall(function()
		local value = assert(loadstring(instrumented, "@corpus.lua"))()
		if exercise then
			exercise(value, collector, manifest)
		end
	end, debug.traceback)
	collector.stop()
	assert(ok, err)
	return collector.report(), manifest
end

Test.test("coverage independent metrics include unused functions and unreachable lines", function()
	local report = execute(
		[[local function unused()
  return 7
end
return function(x)
  if x then
    return 1
  end
  return 0
end]],
		function(f)
			Test.eq(f(true), 1)
		end
	)
	Test.eq(report.functions.total, 2)
	Test.eq(report.functions.hit, 1)
	Test.eq(report.functions.percent, 50)
	Test.eq(report.branches.total, 2)
	Test.eq(report.branches.percent, 50)
	assert(report.lines.hit < report.lines.total)
end)

Test.test("coverage same-line short circuit tracks each decision and true false nil", function()
	local report = execute([[return function(a,b,c) if a and b or c then return 1 else return 0 end end]], function(f)
		Test.eq(f(false, nil, false), 0)
		Test.eq(f(nil, true, nil), 0)
		Test.eq(f(true, true, nil), 1)
		Test.eq(f(true, false, 0), 1)
	end)
	Test.eq(report.lines.percent, 100)
	Test.eq(report.functions.percent, 100)
	Test.eq(report.branches.total, 6)
	Test.eq(report.branches.percent, 100)
end)

Test.test("coverage if elseif implicit else each have two outcomes", function()
	local report = execute(
		[[return function(x)
  if x == 1 then return 1
  elseif x == 2 then return 2
  end
  return 3
end]],
		function(f)
			Test.eq(f(1), 1)
			Test.eq(f(2), 2)
			Test.eq(f(3), 3)
		end
	)
	Test.eq(report.branches.total, 4)
	Test.eq(report.branches.percent, 100)
	Test.eq(report.lines.percent, 100)
end)

Test.test("coverage numeric generic for measure continuation and normal termination", function()
	local report = execute(
		[[return function(n, values)
  local result = 0
  for i = 1,n do result = result + i end
  for k,v in pairs(values) do result = result + k + v end
  return result
end]],
		function(f)
			Test.eq(f(0, {}), 0)
			Test.eq(f(2, { 4, 5 }), 15)
		end
	)
	Test.eq(report.branches.total, 4)
	Test.eq(report.branches.percent, 100)
	Test.eq(report.lines.percent, 100)
end)

Test.test("coverage nonempty constant for loops naturally cover both native outcomes", function()
	local report = execute("for i=1,2 do local x=i end; for k,v in ipairs({1,2}) do local x=v end")
	Test.eq(report.branches.total, 4)
	Test.eq(report.branches.hit, 4)
end)

Test.test("coverage break and return do not masquerade as normal for termination", function()
	for _, ending in ipairs({ "break", "return" }) do
		local report = execute("return function(n) for i=1,n do " .. ending .. " end end", function(f)
			f(2)
		end)
		Test.eq(report.branches.total, 2)
		Test.eq(report.branches.hit, 1)
		Test.eq(report.files["corpus.lua"].missing.branches[1].outcome, false)
		report = execute("return function(n) for i=1,n do " .. ending .. " end end", function(f)
			f(2)
			f(0)
		end)
		Test.eq(report.branches.hit, 2)
	end
end)

Test.test("coverage nested breaks target their nearest native loop", function()
	local report = execute([[for i=1,2 do
  while i > 0 do break end
  repeat break until false
  for j=1,2 do break end
end]])
	local missing = report.files["corpus.lua"].missing.branches
	for _, branch in ipairs(missing) do
		assert(branch.id ~= 1, "inner break incorrectly marked outer for as broken")
	end
	Test.eq(#missing, 4)
end)

Test.test("coverage while repeat conditions measure actual outcomes", function()
	local report = execute(
		[[return function(n)
  local x = 0
  while x < n do x = x + 1 end
  repeat x = x - 1 until x <= 0
  return x
end]],
		function(f)
			Test.eq(f(0), -1)
			Test.eq(f(2), 0)
		end
	)
	Test.eq(report.branches.total, 4)
	Test.eq(report.branches.percent, 100)
end)

Test.test("coverage nested loops early returns break and closure scopes remain native", function()
	execute(
		[[return function(n)
  local values = {}
  for i = 1,n do
    for j = 1,n do
      if j > 1 then break end
      values[#values + 1] = function() return i,j end
    end
    if i == 2 then return values end
  end
  return values
end]],
		function(f)
			Test.eq(#f(0), 0)
			local values = f(3)
			Test.eq(#values, 2)
			local a, b = values[1]()
			Test.eq({ a, b }, { 1, 1 })
			a, b = values[2]()
			Test.eq({ a, b }, { 2, 1 })
		end
	)
end)

Test.test("coverage functions preserve varargs multireturn false nil and tail recursion", function()
	local report = execute(
		[[local function tail(n, ...)
  if n == 0 then return ... end
  return tail(n - 1, ...)
end
return function(...) return tail(2000, ...) end]],
		function(f)
			local values = { n = select("#", f(false, nil, 7)), f(false, nil, 7) }
			Test.eq(values, { n = 3, [1] = false, [3] = 7 })
		end
	)
	Test.eq(report.functions.total, 2)
	Test.eq(report.functions.percent, 100)
	Test.eq(report.branches.percent, 100)
end)

Test.test("coverage probes preserve side effect order and short circuit", function()
	execute(
		[[return function()
  local order = {}
  local function mark(x) order[#order+1]=x; return x end
  local a = mark(false) and mark(1)
  local b = mark(2) or mark(3)
  local c = mark(nil) or mark(4)
  return a,b,c,order
end]],
		function(f)
			local a, b, c, order = f()
			Test.eq({ a, b, c }, { false, 2, 4 })
			Test.eq(order, { false, 2, 4 })
		end
	)
end)

Test.test("coverage coroutine yields resume correctly across probes", function()
	execute(
		[[return function()
  return coroutine.create(function(x)
    while x do x = coroutine.yield(x) end
    return false,nil,9
  end)
end]],
		function(f)
			local co = f()
			Test.eq({ coroutine.resume(co, 4) }, { true, 4 })
			Test.eq({ coroutine.resume(co, 5) }, { true, 5 })
			local function pack(...)
				return { n = select("#", ...), ... }
			end
			Test.eq(pack(coroutine.resume(co, false)), { n = 4, [1] = true, [2] = false, [4] = 9 })
			Test.eq(coroutine.status(co), "dead")
		end
	)
end)

Test.test("coverage empty function shebang and comments remain valid", function()
	local report = execute("#!/usr/bin/env -S nvim -l\n-- comment\nreturn function() end", function(f)
		Test.eq(f(), nil)
	end)
	Test.eq(report.lines.total, 1)
	Test.eq(report.functions.total, 1)
	Test.eq(report.functions.percent, 100)
	local source, manifest = coverage.instrument("#!/usr/bin/env -S nvim -l", "empty-script")
	local collector = coverage.collector({ manifest })
	collector.activate()
	assert(loadstring(source:gsub("^#![^\n]*", "")))()
	collector.stop()
end)

Test.test("coverage rejects invalid syntax LuaJIT-only goto and empty source inventory", function()
	Test.raises("unsupported Lua syntax", function()
		coverage.instrument("if then", "bad.lua")
	end)
	Test.raises("goto", function()
		coverage.instrument("::target:: goto target", "bad.lua")
	end)
	Test.raises("source manifests", function()
		coverage.collector({})
	end)
	Test.raises("no production sources", function()
		coverage.start(Test.temp())
	end)
end)

Test.test("coverage missing sites fail independent gates and unknown counters fail closed", function()
	local _, manifest = coverage.instrument("return function(x) if x then return 1 end return 0 end", "gate.lua")
	local collector = coverage.collector({ manifest })
	local ok, err, report = collector.check(98)
	Test.eq(ok, false)
	assert(err:find("lines", 1, true) and err:find("branches", 1, true) and err:find("functions", 1, true))
	Test.eq(report.functions.hit, 0)
	Test.raises("unknown line", function()
		collector.line("gate.lua", 9)
	end)
	Test.raises("unknown function", function()
		collector.enter("gate.lua", 9)
	end)
	Test.raises("unknown branch", function()
		collector.branch("gate.lua", 9, true)
	end)
	Test.raises("unknown source", function()
		collector.branch("other.lua", 1, true)
	end)
	Test.raises("threshold", function()
		collector.check(101)
	end)
	Test.raises("duplicate", function()
		coverage.collector({ manifest, manifest })
	end)
	local complete = execute("return function() return 1 end", function(f)
		Test.eq(f(), 1)
	end)
	Test.eq(complete.functions.percent, 100)
end)

Test.test("coverage start inventories unloaded modules and restores package loaders", function()
	local root = Test.temp()
	vim.fn.mkdir(root .. "/lua/survey", "p")
	vim.fn.mkdir(root .. "/scripts", "p")
	vim.fn.mkdir(root .. "/bin", "p")
	vim.fn.mkdir(root .. "/test", "p")
	vim.fn.writefile({ "return function() return 5 end" }, root .. "/lua/survey/init.lua")
	vim.fn.writefile({ "return function() return 8 end" }, root .. "/lua/survey/unused.lua")
	vim.fn.writefile({ "return 3" }, root .. "/scripts/build.lua")
	vim.fn.writefile({ "#!/usr/bin/env -S nvim -l", "return 2" }, root .. "/bin/orc")
	vim.fn.writefile({ "this is test infrastructure" }, root .. "/test/excluded.lua")
	local old_path, old_loadfile, old_dofile, old_loader = package.path, loadfile, dofile, package.loaders[2]
	local old_module = { previous = true }
	package.loaded.survey = old_module
	package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
	local session = coverage.start(root)
	local ok, err = xpcall(function()
		Test.eq(require("survey")(), 5)
		Test.eq(dofile(root .. "/scripts/build.lua"), 3)
		Test.eq(assert(loadfile(root .. "/bin/orc"))(), 2)
		local report = session.report()
		Test.eq(report.functions.total, 2)
		Test.eq(report.functions.hit, 1)
		Test.eq(report.files[root .. "/lua/survey/unused.lua"].lines.hit, 0)
		assert(report.files[root .. "/bin/orc"])
		Test.raises("not enumerated", function()
			session.load("missing.lua")
		end)
		Test.eq(session.load("scripts/build.lua")(), 3)
	end, debug.traceback)
	session.stop()
	session.stop()
	Test.eq(package.loaded.survey, old_module)
	package.loaded.survey, package.path = nil, old_path
	Test.eq(loadfile, old_loadfile)
	Test.eq(dofile, old_dofile)
	Test.eq(package.loaders[2], old_loader)
	assert(ok, err)
end)

Test.test("coverage nested collectors restore their parent and reject wrong stop order", function()
	local _, manifest = coverage.instrument("return 1", "nested.lua")
	local outer, inner = coverage.collector({ manifest }), coverage.collector({ manifest })
	outer.activate()
	Test.raises("already active", outer.activate)
	inner.activate()
	Test.raises("reverse order", outer.stop)
	inner.stop()
	Test.eq(rawget(_G, "__ORC_COVERAGE"), outer)
	outer.stop()
end)
