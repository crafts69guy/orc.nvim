local eval = require("orc.eval")
local runtime = require("orc.runtime")

local function fixture(overrides, respond)
	local root = Test.temp()
	local rt = runtime.new({ root = root, cwd = root })
	local spec = rt.path(root, "specs", "micro spec.lua")
	local results = rt.path(root, "evals", "results")
	local calls = {}
	rt.now = function()
		return "2026-11-27T13:00:00Z"
	end
	rt.write(rt.path(root, "context.md"), "Shared context")
	rt.write(spec, [[
local spec = {
	provider = "claude",
	model = "test-model",
	reps = 5,
	cap = 0.5,
	context = "../context.md",
	task = "Review task",
	arms = { control = {}, recipe = { guidance = "Recipe guidance" } },
	score = function(output)
		if output == "broken score" then error("scorer fixture error") end
		local lines = {}
		for line, text in ipairs(vim.split(output, "\n", { plain = true })) do
			if text == "flag" then lines[#lines + 1] = line end
		end
		return #lines, lines
	end,
}
]] .. (overrides or "") .. "\nreturn spec\n")
	rt.interactive = function()
		error("micro must use captured, single-shot calls")
	end
	Test.replace(eval, "build", function()
		error("micro subcommand fell through to plugin evaluation", 0)
	end)
	rt.exec = function(argv, opts)
		local cwd = assert(opts).cwd or rt.cwd
		calls[#calls + 1] = {
			argv = argv,
			stdin = opts.stdin,
			cwd = cwd,
			real_cwd = vim.uv.fs_realpath(cwd),
			entries = rt.list(cwd),
		}
		if respond then
			return respond(rt, argv, #calls)
		end
		return { code = 0, signal = 0, stdout = "clean", stderr = "" }
	end
	local run = function(...)
		return eval.run(rt, { "micro", "specs/micro spec.lua", ... })
	end
	return rt, calls, results, run
end

local function has(text, part)
	assert(
		type(text) == "string" and text:find(part, 1, true),
		"expected " .. vim.inspect(part) .. " in " .. vim.inspect(text)
	)
end

local function refused(rt, calls, results, result, message)
	Test.eq(result.code, 1)
	has(result.err, message)
	Test.eq(#calls, 0)
	Test.eq(rt.exists(results), false)
end

local function result_dir(rt, results)
	local dirs = rt.list(results)
	Test.eq(#dirs, 1)
	has(dirs[1], "micro-2026-11-27T13-00-00Z")
	return rt.path(results, dirs[1])
end

local function saved_scores(rt, dir)
	return rt.decode((assert(rt.read(rt.path(dir, "scores.json")))))
end

local function assert_isolated(rt, calls)
	local root = assert(vim.uv.fs_realpath(rt.root))
	local visited = {}
	for _, call in ipairs(calls) do
		local cwd = assert(call.real_cwd, "working directory must exist at call time")
		assert(cwd ~= root and not vim.startswith(cwd, root .. "/"), "provider ran inside the checkout")
		Test.eq(call.entries, {})
		Test.eq(visited[cwd], nil)
		Test.eq(rt.exists(call.cwd), false)
		visited[cwd] = true
	end
end

Test.test("micro gives each provider call a fresh empty directory and cleans it up", function()
	for _, provider in ipairs({ "claude", "codex" }) do
		local rt, calls, _, run = fixture(
			("spec.provider = %q"):format(provider),
			function(localrt, argv)
				if argv[1] == "codex" then
					localrt.write(argv[#argv - 1], "clean")
				end
				return { code = 0, signal = 0, stdout = "clean", stderr = "" }
			end
		)
		rt.write(rt.path(rt.root, "AGENTS.md"), "Checkout instructions")
		rt.env.ORC_EVAL_CODEX = "1"
		local result = run("--pilot")
		assert(result.code == 0, result.err)
		Test.eq(#calls, 2)
		assert_isolated(rt, calls)
	end
	local rt, calls, _, run = fixture(nil, function()
		error("adapter raised", 0)
	end)
	local result = run("--pilot")
	Test.eq(result.code, 1)
	has(result.err, "adapter raised")
	Test.eq(#calls, 1)
	assert_isolated(rt, calls)
end)

Test.test("micro refuses four reps and pilots one interleaved pass", function()
	local rt, calls, results, run = fixture("spec.reps = 4")
	refused(rt, calls, results, run(), "at least 5")
	local result = run("--pilot")
	assert(result.code == 0, result.err)
	Test.eq(#calls, 2)
	Test.eq(calls[1].stdin, "Shared context\n\nReview task")
	Test.eq(calls[2].stdin, "Shared context\n\nRecipe guidance\n\nReview task")
	local dir = result_dir(rt, results)
	Test.eq(rt.list(dir), { "control-1.txt", "recipe-1.txt", "scores.json" })
	result = run("--pilot")
	assert(result.code == 0, result.err)
	Test.eq(#rt.list(results), 2)
	Test.eq(rt.read(rt.path(dir, "control-1.txt")), "clean")
end)

Test.test("micro validates all spec fields and requires a control without guidance", function()
	for _, invalid in ipairs({
		{ "spec.arms.control = nil", "control arm" },
		{ 'spec.arms.control.guidance = ""', "control arm must have no guidance" },
		{ 'spec.provider = "other"', "provider" },
		{ 'spec.model = " "', "model" },
		{ "spec.reps = 5.5", "reps" },
		{ "spec.cap = math.huge", "cap" },
		{ 'spec.context = "/context.md"', "context" },
		{ 'spec.context = "missing.md"', "cannot read context" },
		{ "spec.task = nil", "task" },
		{ "spec.arms = nil", "arms" },
		{ 'spec.arms["../escape"] = {}', "arm name" },
		{ "spec.arms.Recipe = {}", "arm names must be distinct" },
		{ "spec.arms.recipe.guidance = 1", "recipe.guidance" },
		{ "spec.score = nil", "score" },
	}) do
		local rt, calls, results, run = fixture(invalid[1])
		refused(rt, calls, results, run(), invalid[2])
	end
end)

Test.test("micro enforces Claude's total cap before calls or writes", function()
	local rt, calls, results, run = fixture("spec.cap = 0.5001")
	refused(rt, calls, results, run(), "exceeds ORC_EVAL_MAX_COST")
	for _, value in ipairs({ "bad", "0", "-1", "1e999" }) do
		rt.env.ORC_EVAL_MAX_COST = value
		refused(rt, calls, results, run(), "ORC_EVAL_MAX_COST must be a positive finite number")
	end
	rt.env.ORC_EVAL_MAX_COST = "5.001"
	local result = run()
	assert(result.code == 0, result.err)
	Test.eq(#calls, 10)
	for _, budget in ipairs({ { "0.5", "5" }, { "0.07", "0.7" }, { "0.12345678901234567", "5" } }) do
		local budget_rt, budget_calls, _, budget_run = fixture("spec.cap = " .. budget[1])
		budget_rt.env.ORC_EVAL_MAX_COST = budget[2]
		result = budget_run()
		assert(result.code == 0, result.err)
		Test.eq(#budget_calls, 10)
		Test.eq(tonumber(budget_calls[1].argv[11]), tonumber(budget[1]))
	end
	local overflow_rt, overflow_calls, overflow_results, overflow_run = fixture("spec.cap = 1e308")
	overflow_rt.env.ORC_EVAL_MAX_COST = "1.7976931348623157e308"
	refused(
		overflow_rt,
		overflow_calls,
		overflow_results,
		overflow_run(),
		"exceeds ORC_EVAL_MAX_COST"
	)
end)

Test.test("micro dry-run shows every prompt and cost ceiling without writing or calling", function()
	local rt, calls, results, run = fixture()
	local result = run("--dry-run")
	assert(result.code == 0, result.err)
	has(result.out, "10 calls")
	has(result.out, "USD 5")
	has(result.out, "test-model")
	has(result.out, "Shared context\n\nReview task")
	has(result.out, "Shared context\n\nRecipe guidance\n\nReview task")
	Test.eq(#calls, 0)
	Test.eq(rt.exists(results), false)
end)

Test.test(
	"micro gates Codex and scores the last-message file through the read-only command",
	function()
		local rt, calls, results, run = fixture('spec.provider = "codex"', function(localrt, argv)
			localrt.write(argv[#argv - 1], "clean\nflag")
			return { code = 0, signal = 0, stdout = "CLI chatter", stderr = "" }
		end)
		rt.env.ORC_EVAL_CODEX = "true"
		refused(rt, calls, results, run("--pilot"), "ORC_EVAL_CODEX=1")
		rt.env.ORC_EVAL_CODEX = "1"
		local result = run("--pilot")
		assert(result.code == 0, result.err)
		Test.eq(#calls, 2)
		local file = rt.path(result_dir(rt, results), "control-1.txt")
		Test.eq(calls[1].argv, {
			"codex",
			"--no-daemon",
			"-a",
			"never",
			"exec",
			"--ignore-user-config",
			"--ignore-rules",
			"--ephemeral",
			"--sandbox",
			"read-only",
			"--skip-git-repo-check",
			"-m",
			"test-model",
			"-o",
			file,
			"-",
		})
		Test.eq(rt.read(file), "clean\nflag")
		has(result.out, file .. ":2")
	end
)

Test.test("micro records a Codex exit without a last-message file", function()
	local rt, calls, results, run = fixture('spec.provider = "codex"', function(localrt, argv, index)
		if index == 2 then
			localrt.write(argv[#argv - 1], "flag")
		end
		return { code = 0, signal = 0, stdout = "CLI chatter", stderr = "" }
	end)
	rt.env.ORC_EVAL_CODEX = "1"
	local result = run("--pilot")
	assert(result.code == 0, result.err)
	Test.eq(#calls, 2)
	local dir = result_dir(rt, results)
	local scores = saved_scores(rt, dir)
	has(scores.arms.control[1].error, "codex did not write its last-message file")
	Test.eq(scores.arms.control[1].score, nil)
	Test.eq(rt.read(rt.path(dir, "control-1.txt")), "CLI chatter")
	Test.eq(scores.arms.recipe[1].score, 1)
end)

Test.test("micro records non-finite scores and invalid flagged lines as errors", function()
	local rt, calls, results, run = fixture(
		[[
spec.score = function(output)
	if output == "invalid number" then return 0 / 0, {} end
	return 1, { 0 }
end
]],
		function(_, _, index)
			local stdout = index == 1 and "invalid number" or "invalid line"
			return { code = 0, signal = 0, stdout = stdout, stderr = "" }
		end
	)
	local result = run("--pilot")
	assert(result.code == 0, result.err)
	Test.eq(#calls, 2)
	local scores = saved_scores(rt, result_dir(rt, results))
	for _, name in ipairs({ "control", "recipe" }) do
		local rep = scores.arms[name][1]
		has(rep.error, "score must return a finite number and a list of positive line numbers")
		Test.eq(rep.score, nil)
		Test.eq(rep.flagged, nil)
	end
end)

Test.test(
	"micro interleaves five reps and saves scores and flags despite call and scorer errors",
	function()
		local rt, calls, results, run = fixture(nil, function(_, _, index)
			if index == 1 then
				return { code = 7, signal = 0, stdout = "partial", stderr = "fake failure" }
			end
			local stdout = ({ [2] = "flag\nclean\nflag", [3] = "broken score", [5] = "flag" })[index]
			return { code = 0, signal = 0, stdout = stdout or "clean", stderr = "" }
		end)
		local result = run()
		assert(result.code == 0, result.err)
		Test.eq(#calls, 10)
		for i, call in ipairs(calls) do
			Test.eq(call.stdin:find("Recipe guidance", 1, true) ~= nil, i % 2 == 0)
			Test.eq(call.argv, {
				"claude",
				"-p",
				"--tools",
				"",
				"--setting-sources",
				"",
				"--strict-mcp-config",
				"--max-turns",
				"1",
				"--max-budget-usd",
				"0.5",
				"--no-session-persistence",
				"--model",
				"test-model",
			})
		end
		local dir = result_dir(rt, results)
		local scores = saved_scores(rt, dir)
		Test.eq(scores.reps, 5)
		Test.eq(#scores.arms.control, 5)
		Test.eq(#scores.arms.recipe, 5)
		has(scores.arms.control[1].error, "fake failure")
		has(scores.arms.control[2].error, "scorer fixture error")
		Test.eq(scores.arms.recipe[1].score, 2)
		Test.eq(scores.arms.recipe[1].flagged, { 1, 3 })
		Test.eq(rt.read(rt.path(dir, "control-1.txt")), "partial")
		Test.eq(rt.read(rt.path(dir, "control-2.txt")), "broken score")
		Test.eq(rt.read(rt.path(dir, "recipe-5.txt")), "clean")
		has(result.out, "control n=3 errors=2 mean=0.333333 range=0..1 spread=1")
		has(result.out, "recipe n=5 errors=0 mean=0.4 range=0..2 spread=2")
		has(result.out, rt.path(dir, "recipe-1.txt") .. ":1")
		has(result.out, rt.path(dir, "recipe-1.txt") .. ":3")
	end
)

Test.test("micro example counts phrases and reports each matching line once", function()
	local rt = runtime.new()
	local spec = dofile(rt.path(rt.root, "evals", "micro", "review-coaching.lua"))
	local score, flagged =
		spec.score("Do not flag this: not a defect.\nRead the diff.\nThe plan chose this.\n")
	Test.eq(score, 3)
	Test.eq(flagged, { 1, 3 })
	score, flagged = spec.score("Don’t treat this as resolved.\nDon't treat that as resolved.\n")
	Test.eq(score, 2)
	Test.eq(flagged, { 1, 2 })
end)
