local eval = require("orc.eval")
local runtime = require("orc.runtime")
local rt = runtime.new()
local groups = {
	["bench-modules"] = { "duration", "semver", "csv", "lru" },
	["bench-large"] = { "cron", "schema", "expr" },
}
local acceptance = dofile(rt.path(rt.root, "evals", "support", "acceptance.lua"))
local runner = dofile(rt.path(rt.root, "evals", "support", "runner.lua"))
local function load(group, kind, name)
	return dofile(rt.path(rt.root, "evals", group, kind, name .. ".lua"))
end
local function all_pass(result)
	for _, item in ipairs(result.results) do
		assert(item.passed, item.name .. ": " .. tostring(item.error))
	end
	Test.eq(result.pass, result.total)
end
local function result_run(score, seconds, cost)
	return { score = score, durationSeconds = seconds, costUsd = cost }
end
local function sample()
	return {
		durationSeconds = 50,
		costUsd = 2,
		cases = {
			{
				name = "case",
				arms = {
					with = { result_run(1, 10, 0.2), result_run(0.5, 20, 0.4) },
					without = { result_run(0.5, 30, 0.5) },
				},
			},
		},
	}
end
local function source_copy(path)
	rt.mkdir(path)
	for _, name in ipairs({
		"agents",
		"rules",
		"skills",
		"hooks",
		"bin",
		"lua",
		"codex",
		"evals",
		".claude-plugin",
		".codex-plugin",
	}) do
		local result = rt.exec({ "cp", "-R", rt.path(rt.root, name), rt.path(path, name) })
		Test.eq(result.code, 0)
	end
	return runtime.new({ root = path })
end
local function entry(path, target)
	local saved_arg, saved_cwd, saved_path = arg, vim.uv.cwd(), package.path
	arg = { [0] = path }
	assert(vim.uv.chdir(target))
	local ok, value = pcall(dofile, path)
	arg, package.path = saved_arg, saved_path
	assert(vim.uv.chdir(saved_cwd))
	return ok, value
end

Test.test("evals hidden suites accept every fresh Lua reference and reject every stub", function()
	local total = 0
	for group, names in pairs(groups) do
		for _, name in ipairs(names) do
			local api, suite = load(group, "reference", name), load(group, "hidden", name)
			local result = acceptance.run(api, suite)
			all_pass(result)
			total = total + result.total
			local stub = setmetatable({}, {
				__index = function()
					return function()
						error({ kind = "Unimplemented", message = "stub" }, 0)
					end
				end,
			})
			local broken = acceptance.run(stub, suite)
			Test.eq(broken.pass, 0)
			Test.eq(broken.total, result.total)
		end
	end
	assert(total >= 200)
end)

Test.test("evals hidden suites detect regressions rather than only matching references", function()
	local duration = load("bench-modules", "reference", "duration")
	local changed_duration = acceptance.run({
		parseDuration = function(text)
			return duration.parseDuration(text) + 1
		end,
	}, load("bench-modules", "hidden", "duration"))
	assert(changed_duration.pass < changed_duration.total)
	local semver = load("bench-modules", "reference", "semver")
	local sem = acceptance.run({
		compare = function(a, b)
			return -semver.compare(a, b)
		end,
	}, load("bench-modules", "hidden", "semver"))
	assert(sem.pass < sem.total)
	local expr = load("bench-large", "reference", "expr")
	local eager = {
		evaluate = function(text, variables)
			if text == "false && missing" then
				error({ kind = "ReferenceError", message = "eager" }, 0)
			end
			return expr.evaluate(text, variables)
		end,
	}
	local expression = acceptance.run(eager, load("bench-large", "hidden", "expr"))
	Test.eq(expression.pass, expression.total - 1)
	local schema = load("bench-large", "reference", "schema")
	local anyof = {
		validate = function(value, rule)
			if type(rule) == "table" and rule.oneOf then
				rule = vim.deepcopy(rule)
				rule.anyOf, rule.oneOf = rule.oneOf, nil
			end
			return schema.validate(value, rule)
		end,
	}
	local changed = acceptance.run(anyof, load("bench-large", "hidden", "schema"))
	assert(changed.pass < changed.total)
end)

Test.test(
	"evals structured acceptance assertions detect wrong positions and empty error messages",
	function()
		local result = acceptance.run({}, function(_, t)
			t.test("matching error", function()
				t.error("SyntaxError", function()
					error({ kind = "SyntaxError", message = "bad", position = 3 }, 0)
				end, 3)
			end)
			t.test("wrong position", function()
				t.error("SyntaxError", function()
					error({ kind = "SyntaxError", message = "bad", position = 2 }, 0)
				end, 3)
			end)
			t.test("missing message", function()
				t.error("TypeError", function()
					error({ kind = "TypeError", message = "" }, 0)
				end)
			end)
			t.test("no exception", function()
				t.error("RangeError", function()
					return true
				end)
			end)
			t.test("non-string message", function()
				t.error("TypeError", function()
					error({ kind = "TypeError", message = false }, 0)
				end)
			end)
		end)
		Test.eq(result.pass, 1)
		Test.eq(result.total, 5)
	end
)

Test.test("evals Lua fixtures execute standalone and refuse existing source directories", function()
	for _, name in ipairs({
		"inline-small",
		"delegate-multi",
		"batch-small",
		"reflect-capture",
		"parallel-dispatch",
		"bench-modules",
		"bench-large",
	}) do
		local target, path = Test.temp(), rt.path(rt.root, "evals", name, "fixture.lua")
		local fixture = dofile(path)
		Test.eq(type(fixture.run), "function")
		local ok, value = entry(path, target)
		assert(ok, tostring(value))
		Test.eq(rt.exec({ "git", "branch", "--show-current" }, { cwd = target }).stdout, "feat/x\n")
		assert(rt.exists(rt.path(target, "test", "run.lua")))
		Test.raises("refuses existing", function()
			fixture.run(target)
		end)
		local saved = arg
		arg = nil
		Test.eq(type(dofile(path).run), "function")
		arg = {}
		Test.eq(type(dofile(path).run), "function")
		arg = saved
	end
	local saved = arg
	arg = nil
	Test.eq(type(dofile(rt.path(rt.root, "evals", "inline-small", "fixture.lua")).run), "function")
	arg = {}
	Test.eq(type(dofile(rt.path(rt.root, "evals", "support", "runner.lua")).run), "function")
	arg = nil
	Test.eq(type(dofile(rt.path(rt.root, "evals", "support", "runner.lua")).run), "function")
	arg = saved
	Test.raises("unknown case", function()
		eval.scaffold(rt, "unknown", Test.temp())
	end)
end)

Test.test("evals scaffolds refuse nonempty user workspaces without any mutation", function()
	local function snapshot(root)
		local result = {}
		local function visit(path, relative)
			for _, name in ipairs(rt.list(path)) do
				local child, key = rt.path(path, name), relative .. "/" .. name
				if assert(vim.uv.fs_lstat(child)).type == "directory" then
					result[key] = "directory"
					visit(child, key)
				else
					result[key] = assert(rt.read(child))
				end
			end
		end
		visit(root, "")
		return result
	end
	for _, kind in ipairs({ "instructions", "secret", "repository" }) do
		local target = Test.temp()
		if kind == "instructions" then
			rt.write(rt.path(target, "AGENTS.md"), "Personal instructions\n")
		elseif kind == "secret" then
			rt.write(rt.path(target, ".env"), "SYNTHETIC_FIXTURE_SECRET=preserve-me\n")
		else
			local function git(args)
				local command = { "git", "-C", target }
				vim.list_extend(command, args)
				local result = rt.exec(command)
				assert(result.code == 0, result.stderr)
			end
			git({ "init", "-q", "-b", "personal" })
			git({ "config", "user.name", "Personal Fixture" })
			git({ "config", "user.email", "personal@example.invalid" })
			git({ "config", "commit.gpgsign", "false" })
			git({ "config", "core.hooksPath", rt.path(target, ".git", "disabled-hooks") })
			rt.write(rt.path(target, "personal.txt"), "committed\n")
			git({ "add", "personal.txt" })
			git({ "commit", "-q", "-m", "personal state" })
			rt.write(rt.path(target, "personal.txt"), "staged\n")
			git({ "add", "personal.txt" })
			rt.write(rt.path(target, "personal.txt"), "unstaged\n")
			rt.write(rt.path(target, ".git", "info", "exclude"), "personal-ignore\n")
		end
		local before, calls = snapshot(target), {}
		local guarded = vim.tbl_extend("force", {}, rt)
		for _, operation in ipairs({
			"exec",
			"write",
			"mkdir",
			"remove",
			"rmdir",
			"append",
			"interactive",
		}) do
			guarded[operation] = function()
				calls[#calls + 1] = operation
				error("unexpected mutation: " .. operation)
			end
		end
		Test.raises("target must be empty", function()
			eval.scaffold(guarded, "inline-small", target)
		end)
		Test.eq(calls, {})
		Test.eq(snapshot(target), before)
	end
end)

Test.test("evals hidden-material graders retain JSON-string escape-aware wire patterns", function()
	local fields = { Bash = "command", Read = "file_path", Grep = "path" }
	local total = 0
	for _, name in ipairs({ "bench-modules", "bench-large", "parallel-dispatch" }) do
		local yaml = assert(rt.read(rt.path(rt.root, "evals", name, "case.yaml")))
		for line in yaml:gmatch("[^\n]+") do
			if line:find('"name":"no-peek-', 1, true) then
				local grader = rt.decode(line:sub(5))
				Test.eq(
					grader.input_match,
					string.format(
						[["%s"\s*:\s*"(?:[^"\\]|\\.)*?(?:acceptance\.tgz|\.git/acceptance)]],
						fields[grader.tool]
					)
				)
				Test.eq(grader.min, 0)
				Test.eq(grader.max, 0)
				total = total + 1
			end
		end
	end
	Test.eq(total, 9)
end)

Test.test("evals fixture checker reports failing own tests then repaired behavior", function()
	local target = Test.temp()
	eval.scaffold(rt, "inline-small", target)
	assert(eval.check(rt, "inline-small", target):find("# pass 0\n# fail 2", 1, true))
	rt.write(rt.path(target, "src", "math.lua"), "return {add=function(a,b)return a+b end}\n")
	local after = eval.check(rt, "inline-small", target)
	assert(after:find("# pass 2\n# fail 0", 1, true))
	assert(after:find("branch: feat/x", 1, true) and after:find("worktrees: 1", 1, true))
	Test.eq(rt.read(rt.path(target, "check.out")), after)
	local ok, err = entry(rt.path(target, "check.lua"), target)
	assert(ok, tostring(err))
	assert(entry(rt.path(rt.root, "evals", "support", "runner.lua"), target))
	local seed = Test.temp()
	eval.scaffold(rt, "inline-small", seed)
	local failed = entry(rt.path(rt.root, "evals", "support", "runner.lua"), seed)
	Test.eq(failed, false)
	Test.raises("unknown case", function()
		eval.check(rt, "unknown", target)
	end)
end)

Test.test("evals own test runner isolates module loading and records malformed tests", function()
	local target = Test.temp()
	rt.write(rt.path(target, "src", "dependency.lua"), "return {value=2}\n")
	rt.write(
		rt.path(target, "test", "valid_spec.lua"),
		[[return function(t)
  t.test("require",function()t.eq(require("dependency").value,2)end)
  t.test("expected",function()t.error("RangeError",function()error({kind="RangeError"},0)end)end)
  t.test("eq failure",function()t.eq(1,2)end)
  t.test("missing error",function()t.error("RangeError",function()end)end)
end]]
	)
	rt.write(rt.path(target, "test", "broken_spec.lua"), "invalid Lua")
	local prior = package.loaded.dependency
	package.loaded.dependency = { value = 100 }
	local code, output = runner.run(target)
	Test.eq(code, 1)
	assert(output:find("# pass 2\n# fail 3", 1, true))
	Test.eq(package.loaded.dependency.value, 100)
	package.loaded.dependency = prior
	local empty = Test.temp()
	rt.mkdir(rt.path(empty, "test"))
	Test.eq(select(2, runner.run(empty)), "# pass 0\n# fail 0\n")
end)

Test.test(
	"evals benchmark checkers remove extracted hidden material on success or failure",
	function()
		for _, name in ipairs({ "bench-modules", "bench-large", "parallel-dispatch" }) do
			local target = Test.temp()
			eval.scaffold(rt, name, target)
			assert(rt.exists(rt.path(target, ".git", "acceptance.tgz")))
			assert(not rt.exists(rt.path(target, ".git", "acceptance")))
			assert(eval.check(rt, name, target):find(" 0/", 1, true))
			local group = name == "parallel-dispatch" and "bench-large" or name
			local modules = name == "parallel-dispatch" and { "cron", "expr" } or groups[group]
			for _, module in ipairs(modules) do
				rt.write(
					rt.path(target, "src", module .. ".lua"),
					assert(rt.read(rt.path(rt.root, "evals", group, "reference", module .. ".lua")))
				)
			end
			local result = eval.check(rt, name, target)
			for _, module in ipairs(modules) do
				assert(result:match("acceptance " .. module .. ": %d+/%d+ 100%%"))
			end
			assert(not rt.exists(rt.path(target, ".git", "acceptance")))
			assert(rt.read(rt.path(target, "review.out")):find("Lua benchmark series", 1, true))
			rt.mkdir(rt.path(target, ".git", "acceptance"))
			Test.raises("stale hidden", function()
				eval.check(rt, name, target)
			end)
			rt.remove(rt.path(target, ".git", "acceptance"))
			rt.remove(rt.path(target, ".git", "acceptance.tgz"))
			Test.raises("tar failed", function()
				eval.check(rt, name, target)
			end)
			assert(not rt.exists(rt.path(target, ".git", "acceptance")))
		end
	end
)

Test.test("evals plugin builder preserves sources and shell-quotes generated launchers", function()
	local path = rt.path(Test.temp(), "plugin's source")
	local copy = source_copy(path)
	local hook = assert(copy.read(copy.path(path, "hooks", "hooks.json")))
	local yaml = assert(copy.read(copy.path(path, "evals", "inline-small", "case.yaml")))
	local stage = eval.build(copy)
	Test.eq(copy.read(copy.path(path, "hooks", "hooks.json")), hook)
	Test.eq(copy.read(copy.path(path, "evals", "inline-small", "case.yaml")), yaml)
	assert(
		copy
			.read(copy.path(stage, "evals", "inline-small", "case.yaml"))
			:find("scaffold_script: scaffold-launcher", 1, true)
	)
	local built = copy.decode((copy.read(copy.path(stage, "hooks", "hooks.json"))))
	for _, list in pairs(built.hooks) do
		for _, group in ipairs(list) do
			for _, item in ipairs(group.hooks) do
				assert(item.command:match("^ORC=1 "))
			end
		end
	end
	Test.eq(
		copy.decode((copy.read(copy.path(stage, ".claude-plugin", "plugin.json")))).dependencies,
		nil
	)
	local target = Test.temp()
	Test.eq(
		copy.exec(
			{ "bash", copy.path(stage, "evals", "inline-small", "scaffold-launcher") },
			{ cwd = target }
		).code,
		0
	)
	assert(copy.exists(copy.path(target, "src", "math.lua")))
	copy.write(copy.path(path, "evals", "inline-small", "case.yaml"), "scaffold_script: wrong\n")
	Test.raises("unique Lua scaffold", function()
		eval.build(copy)
	end)
	Test.raises("source is missing", function()
		eval.build(runtime.new({ root = Test.temp() }))
	end)
end)

Test.test("evals scores and statistics exclude peeking without hiding error counts", function()
	Test.eq(eval.outcome_score({ score = 0.3 }), 0.3)
	Test.eq(eval.outcome_score({}), vim.NIL)
	Test.eq(
		eval.outcome_score({ score = 0.4, graders = { { name = "zero", weight = 0, passed = true } } }),
		0.4
	)
	Test.eq(
		eval.outcome_score({
			graders = {
				{ name = "pass", weight = 2, passed = true },
				{ name = "fail", weight = 1, passed = false },
				{ name = "no-peek-read", weight = 9, passed = false },
				{ name = "with", withOnly = true, weight = 5, passed = true },
				{ name = "ignored", scored = false, weight = 10, passed = true },
			},
		}),
		2 / 3
	)
	Test.eq(
		eval.invalid({
			graders = {
				{ name = "no-peek-bash", passed = true },
				{
					name = "other",
					passed = false,
				},
			},
		}),
		false
	)
	Test.eq(eval.invalid({ graders = { { name = "no-peek-read", passed = false } } }), true)
	Test.eq(
		eval.arm_stats({
			result_run(1, 10, 1),
			result_run(0.5, 30, 3),
			{
				error = "failed",
				score = 0,
				durationSeconds = 999,
				costUsd = 99,
				graders = { { name = "no-peek-read", passed = false } },
			},
		}),
		{
			runs = 3,
			invalid = 1,
			errors = 1,
			score = 0.75,
			meanSeconds = 20,
			p50Seconds = 20,
			costUsd = 2,
		}
	)
	Test.eq(eval.arm_stats({}).p50Seconds, vim.NIL)
	Test.eq(eval.arm_stats({ result_run(1, 5, 2) }).p50Seconds, 5)
	Test.eq(eval.arm_stats({ { error = "no data" } }).costUsd, vim.NIL)
end)

Test.test(
	"evals summaries render deltas empty arms partial results and new-series caveat",
	function()
		local result = sample()
		local rows = eval.summarize(result)
		Test.eq(#rows, 3)
		Test.eq(rows[3].score, 0.25)
		Test.eq(rows[3].meanSeconds, -15)
		local text = eval.format_summary(result)
		assert(
			text:find("Lua benchmark series", 1, true)
				and text:find("+0.25", 1, true)
				and text:find("-15", 1, true)
		)
		result.partial = true
		result.cases[1].arms.with[1].judgeCostUsd = 0.1
		assert(eval.format_summary(result):find("judge $0.10 (partial)", 1, true))
		Test.eq(
			#eval.summarize({ cases = { { name = "empty" }, { name = "one", arms = { with = {} } } } }),
			0
		)
		assert(
			eval
				.format_summary({ cases = { { name = "nodata", arms = { with = { {} }, without = { {} } } } } })
				:find("–", 1, true)
		)
	end
)

Test.test("evals additional reference and summary edge cases retain contracts", function()
	local schema = load("bench-large", "reference", "schema")
	Test.eq(schema.validate(false, { type = "array" })[1].keyword, "type")
	Test.eq(schema.validate(1.5, { type = "integer" })[1].keyword, "type")
	Test.eq(schema.validate(false, { type = "integer" })[1].keyword, "type")
	Test.eq(schema.validate({ present = true }, { required = { "present" } }), {})
	local bad_path = acceptance.run({
		validate = function(value, rule)
			local errors = schema.validate(value, rule)
			if #errors > 0 then
				table.insert(errors, 1, { path = "/wrong", keyword = "wrong", message = "wrong" })
			end
			for _, err in ipairs(errors) do
				err.path = "/wrong"
			end
			return errors
		end,
	}, load("bench-large", "hidden", "schema"))
	assert(bad_path.pass < bad_path.total)
	Test.eq(eval.outcome_score({ graders = { { passed = true } } }), 1)
	Test.eq(eval.invalid({ graders = { { name = 1, passed = false } } }), false)
	assert(eval.format_summary({ cases = { { name = "empty" } } }):find("suite:", 1, true))
end)

Test.test(
	"evals summarize command selects newest valid local report and handles invalid input",
	function()
		local localrt = runtime.new({ root = Test.temp() })
		local first = localrt.path(localrt.root, "evals", "results", "2026", "aggregate-result.json")
		local second = localrt.path(localrt.root, "evals", "results", "2027", "aggregate-result.json")
		localrt.write(first, localrt.encode(sample()))
		localrt.write(second, localrt.encode(sample()))
		localrt.mkdir(localrt.path(localrt.root, "evals", "results", "2028-empty"))
		local result = eval.run(localrt, { "summarize" })
		Test.eq(result.code, 0)
		assert(result.out:find(second, 1, true))
		Test.eq(eval.run(localrt, { "summarize", first }).code, 0)
		Test.eq(eval.run(localrt, { "summarize", first, "extra" }).code, 1)
		localrt.write(first, "invalid")
		Test.eq(eval.run(localrt, { "summarize", first }).code, 1)
		Test.eq(eval.run(localrt, { "summarize", "missing.json" }).code, 1)
		Test.eq(eval.run(runtime.new({ root = Test.temp() }), { "summarize" }).code, 1)
	end
)

Test.test(
	"evals capped execution only invokes a fake harness and respects tags output and benchmarks",
	function()
		local localrt = source_copy(rt.path(Test.temp(), "plugin"))
		local calls = {}
		localrt.interactive = function(command, options)
			calls[#calls + 1] = { command = command, options = options }
			local output
			for index, word in ipairs(command) do
				if word == "--output-dir" then
					output = command[index + 1]
				elseif word:match("^%-%-output%-dir=") then
					output = word:sub(14)
				end
			end
			if output then
				localrt.write(localrt.path(output, "aggregate-result.json"), localrt.encode(sample()))
			end
			return 0
		end
		local first = eval.run(localrt, { "--case", "inline-small", "--runs", "1" })
		assert(first.code == 0, first.err)
		assert(table.concat(calls[1].command, " "):find("--max-cost-usd 5", 1, true))
		assert(table.concat(calls[1].command, " "):find("--tag orc", 1, true))
		localrt.env.ORC_EVAL_MAX_COST = "7"
		local out = localrt.path(Test.temp(), "explicit")
		Test.eq(eval.run(localrt, { "--bench", "--tag", "bench", "--output-dir", out }).code, 0)
		assert(table.concat(calls[2].command, " "):find("--max-cost-usd 7", 1, true))
		assert(table.concat(calls[2].command, " "):find("--judge-model sonnet", 1, true))
		localrt.env.ORC_EVAL_MAX_COST = nil
		local bench = eval.run(localrt, { "--bench", "--tag=bench", "--output-dir=" .. out })
		Test.eq(bench.code, 0)
		assert(bench.out:find("Lua benchmark series", 1, true))
		assert(table.concat(calls[3].command, " "):find("--max-cost-usd 20", 1, true))
		localrt.interactive = function()
			return 127
		end
		Test.eq(eval.run(localrt, {}).code, 127)
		for _, value in ipairs({ "0", "bad", "-1", "inf" }) do
			localrt.env.ORC_EVAL_MAX_COST = value
			Test.eq(eval.run(localrt, {}).code, 1)
		end
		Test.eq(eval.run(localrt, { "--max-cost-usd", "5" }).code, 1)
		Test.eq(eval.run(localrt, { "--max-cost-usd=5" }).code, 1)
		localrt.env.ORC_EVAL_MAX_COST = nil
		Test.eq(eval.run(localrt, { "--bench" }).code, 127)
	end
)
