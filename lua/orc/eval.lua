local M = {}
local cases = {
	["inline-small"] = {},
	["delegate-multi"] = {},
	["batch-small"] = {},
	["reflect-capture"] = {},
	["parallel-dispatch"] = { group = "bench-large", modules = { "cron", "expr" } },
	["bench-modules"] = { group = "bench-modules", modules = { "duration", "semver", "csv", "lru" } },
	["bench-large"] = { group = "bench-large", modules = { "cron", "schema", "expr" } },
}
local function checked(rt, argv, cwd)
	local result = rt.exec(argv, { cwd = cwd })
	assert(result.code == 0, "eval: " .. argv[1] .. " failed: " .. result.stderr)
	return result.stdout
end
local function count_lines(text, pattern)
	local count = 0
	for line in (text .. "\n"):gmatch("(.-)\n") do
		if line:match(pattern) then
			count = count + 1
		end
	end
	return count
end
local function clone(rt, source, target)
	local content = rt.read(source)
	if content then
		rt.write(target, content)
	else
		rt.mkdir(target)
		for _, name in ipairs(rt.list(source)) do
			if name ~= "results" then
				clone(rt, rt.path(source, name), rt.path(target, name))
			end
		end
	end
end
local function executable(path)
	assert(vim.uv.fs_chmod(path, 493))
end
local function shell_quote(text)
	return "'" .. text:gsub("'", "'\\''") .. "'"
end

---Build an isolated plugin copy and generated launch-only Bash adapters.
---Claude currently forces bash FILE for scaffolds; every tracked fixture remains Lua.
---@param rt orc.Runtime
---@return string
function M.build(rt)
	local target = rt.path(rt.root, ".eval-plugin")
	assert(
		rt.exists(rt.path(rt.root, ".claude-plugin", "plugin.json")),
		"eval: plugin source is missing"
	)
	rt.remove(target)
	rt.mkdir(target)
	for _, dir in ipairs({
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
		clone(rt, rt.path(rt.root, dir), rt.path(target, dir))
	end
	local manifest_path = rt.path(target, ".claude-plugin", "plugin.json")
	local manifest = rt.decode((assert(rt.read(manifest_path))))
	manifest.dependencies = nil
	rt.write(manifest_path, rt.encode(manifest) .. "\n")
	local hooks_path = rt.path(target, "hooks", "hooks.json")
	local hooks = rt.decode((assert(rt.read(hooks_path))))
	for _, groups in pairs(hooks.hooks) do
		for _, group in ipairs(groups) do
			for _, hook in ipairs(group.hooks) do
				hook.command = "ORC=1 " .. hook.command
			end
		end
	end
	rt.write(hooks_path, rt.encode(hooks) .. "\n")
	executable(rt.path(target, "bin", "orc"))
	local nvim = vim.fn.exepath("nvim")
	assert(nvim ~= "", "eval: Neovim executable is missing")
	for name in pairs(cases) do
		local dir = rt.path(target, "evals", name)
		local fixture = rt.path(dir, "fixture.lua")
		executable(fixture)
		rt.write(
			rt.path(dir, "scaffold-launcher"),
			"exec " .. shell_quote(nvim) .. " --clean -l " .. shell_quote(fixture) .. ' "$@"\n'
		)
		local yaml_path = rt.path(dir, "case.yaml")
		local yaml = assert(rt.read(yaml_path))
		local rewritten, changed =
			yaml:gsub("scaffold_script: fixture%.lua", "scaffold_script: scaffold-launcher")
		assert(changed == 1, "eval: missing unique Lua scaffold in " .. name)
		rt.write(yaml_path, rewritten)
	end
	return target
end

local function project_file(rt, target, path, body)
	rt.write(rt.path(target, path), body)
end
local function seed_tests(rt, target, module, expression)
	project_file(
		rt,
		target,
		"test/" .. module .. "_spec.lua",
		"return function(t)\n  local api = dofile("
			.. string.format("%q", rt.path(target, "src", module .. ".lua"))
			.. ")\n"
			.. expression
			.. "\nend\n"
	)
end
local function support(rt, name)
	return assert(loadfile(rt.path(rt.root, "evals", "support", name .. ".lua")))()
end

---Create a disposable Lua repository for one behavior case or benchmark.
---@param rt orc.Runtime
---@param name string
---@param target string
---@return boolean
function M.scaffold(rt, name, target)
	local definition = assert(cases[name], "eval: unknown case " .. tostring(name))
	assert(#rt.list(target) == 0, "eval: scaffold refuses existing entries; target must be empty")
	rt.mkdir(rt.path(target, "src"))
	rt.mkdir(rt.path(target, "test"))
	checked(rt, { "git", "init", "-q", "-b", "main" }, target)
	for _, option in ipairs({
		{ "user.name", "eval" },
		{ "user.email", "eval@example.com" },
		{ "commit.gpgsign", "false" },
		{ "core.hooksPath", rt.path(target, ".git", "disabled-hooks") },
	}) do
		checked(rt, { "git", "config", option[1], option[2] }, target)
	end
	project_file(
		rt,
		target,
		"test/run.lua",
		assert(rt.read(rt.path(rt.root, "evals", "support", "runner.lua")))
	)
	executable(rt.path(target, "test", "run.lua"))
	local bootstrap = "package.path = "
		.. string.format(
			"%q",
			rt.path(rt.root, "lua", "?.lua") .. ";" .. rt.path(rt.root, "lua", "?", "init.lua") .. ";"
		)
		.. " .. package.path\nlocal rt = require('orc.runtime').new()\n"
	project_file(
		rt,
		target,
		"check.lua",
		"#!/usr/bin/env -S nvim -l\n"
			.. bootstrap
			.. "local result = require('orc.eval').check(rt,"
			.. string.format("%q", name)
			.. ",rt.cwd)\nio.stdout:write(result)\n"
	)
	executable(rt.path(target, "check.lua"))
	project_file(
		rt,
		target,
		"AGENTS.md",
		"Use Lua 5.1 and Neovim headless. Test modules return function(t), using t.test, t.eq and t.error(kind,fn).\nRun nvim --clean -l test/run.lua. Errors are tables {kind,message,position?}; no dependencies.\n"
	)
	if name == "inline-small" then
		project_file(rt, target, "src/math.lua", "return { add = function(a,b) return a - b end }\n")
		seed_tests(
			rt,
			target,
			"math",
			"t.test('positive addition',function()t.eq(api.add(2,3),5)end)\nt.test('negative addition',function()t.eq(api.add(-2,1),-1)end)"
		)
	elseif name == "delegate-multi" then
		project_file(rt, target, "src/currency.lua", "return { USD = '$' }\n")
		project_file(
			rt,
			target,
			"src/format.lua",
			"local currency = require('currency')\nreturn { formatPrice = function(cents) return currency.USD .. string.format('%.2f',cents/100) end }\n"
		)
		seed_tests(
			rt,
			target,
			"format",
			"t.test('USD',function()t.eq(api.formatPrice(1234),'$12.34')end)\nt.test('zero',function()t.eq(api.formatPrice(0),'$0.00')end)"
		)
	elseif name == "batch-small" then
		project_file(
			rt,
			target,
			"src/strings.lua",
			"return { identity = function(value) return value end }\n"
		)
		project_file(
			rt,
			target,
			"src/numbers.lua",
			"return { double = function(value) return value * 2 end }\n"
		)
		seed_tests(rt, target, "strings", "t.test('identity',function()t.eq(api.identity('x'),'x')end)")
		seed_tests(rt, target, "numbers", "t.test('double',function()t.eq(api.double(2),4)end)")
	elseif name == "reflect-capture" then
		project_file(
			rt,
			target,
			"src/slug.lua",
			"return { slugify = function(value) return value:lower():gsub('%s+','-') end }\n"
		)
		seed_tests(
			rt,
			target,
			"slug",
			"t.test('slug',function()t.eq(api.slugify('Hello World'),'hello-world')end)"
		)
		project_file(
			rt,
			target,
			".scratch/slug/log.md",
			"# Completed slug\n\nOutcome: implemented and reviewed.\nGotchas: CRLF must preserve quoted CSV newlines; repeated user corrections require a regression test.\nOne-off: registry timed out once; rerun succeeded.\n"
		)
		project_file(
			rt,
			target,
			".orc/lessons.md",
			"# Lessons\n<!-- next: L002 -->\n- [L001] +1 -0 orc · csv · Preserve quoted CRLF bytes when parsing CSV.\n"
		)
	else
		local spec = assert(rt.read(rt.path(rt.root, "evals", definition.group, "SPEC.md")))
		if name == "parallel-dispatch" then
			spec = spec .. "\nThis case implements only cron and expr; do not implement schema.\n"
		end
		project_file(rt, target, "SPEC.md", spec)
		local hidden = rt.path(target, ".git", "acceptance")
		rt.mkdir(hidden)
		for _, module in ipairs(definition.modules) do
			project_file(
				rt,
				target,
				"src/" .. module .. ".lua",
				"return setmetatable({}, { __index = function() return function() error({kind='Unimplemented',message='implement from SPEC'},0) end end })\n"
			)
			rt.write(
				rt.path(hidden, module .. ".lua"),
				assert(rt.read(rt.path(rt.root, "evals", definition.group, "hidden", module .. ".lua")))
			)
		end
		checked(
			rt,
			{ "tar", "-czf", rt.path(target, ".git", "acceptance.tgz"), "-C", hidden, "." },
			target
		)
		rt.remove(hidden)
		project_file(
			rt,
			target,
			"test/smoke_spec.lua",
			"return function(t) t.test('workspace ready',function()t.eq(type({}),'table')end) end\n"
		)
	end
	project_file(
		rt,
		target,
		".git/info/exclude",
		"check.lua\ncheck.out\nreview.out\n.scratch/\n.orc/\n"
	)
	checked(rt, { "git", "add", "-A" }, target)
	checked(rt, { "git", "commit", "-q", "-m", "chore: initial" }, target)
	checked(rt, { "git", "checkout", "-q", "-b", "feat/x" }, target)
	return true
end

---Record git state, own tests and hidden acceptance results without publishing.
---@param rt orc.Runtime
---@param name string
---@param target string
---@return string
function M.check(rt, name, target)
	local definition = assert(cases[name], "eval: unknown case")
	local output = {
		"branch: " .. vim.trim(checked(rt, { "git", "branch", "--show-current" }, target)),
		vim.trim(checked(rt, { "git", "log", "--format=commit: %s", "main..feat/x" }, target)),
		"dirty: " .. count_lines(
			checked(
				rt,
				{ "git", "status", "--porcelain", "--", ".", ":(exclude).scratch", ":(exclude).orc" },
				target
			),
			"%S"
		),
		"worktrees: " .. count_lines(
			checked(rt, { "git", "worktree", "list", "--porcelain" }, target),
			"^worktree "
		),
	}
	local _, own = support(rt, "runner").run(target)
	output[#output + 1] = own:gsub("%s+$", "")
	if definition.modules then
		local hidden = rt.path(target, ".git", "acceptance")
		assert(not rt.exists(hidden), "eval: stale hidden extraction; inspect it before retrying")
		rt.mkdir(hidden)
		local ok, err = pcall(function()
			checked(
				rt,
				{ "tar", "-xzf", rt.path(target, ".git", "acceptance.tgz"), "-C", hidden },
				target
			)
			for _, module in ipairs(definition.modules) do
				local api = assert(loadfile(rt.path(target, "src", module .. ".lua")))()
				local suite = assert(loadfile(rt.path(hidden, module .. ".lua")))()
				local result = support(rt, "acceptance").run(api, suite)
				output[#output + 1] = string.format(
					"acceptance %s: %d/%d %d%%",
					module,
					result.pass,
					result.total,
					math.floor(result.pass / result.total * 100)
				)
			end
		end)
		rt.remove(hidden)
		if not ok then
			error(err, 0)
		end
		local spec = assert(rt.read(rt.path(target, "SPEC.md")))
		local diff = checked(rt, { "git", "diff", "main", "--", "src", "test" }, target)
		rt.write(rt.path(target, "review.out"), spec .. "\n\n" .. diff)
	end
	local result = table.concat(output, "\n") .. "\n"
	rt.write(rt.path(target, "check.out"), result)
	return result
end

local function mean(values)
	if #values == 0 then
		return vim.NIL
	end
	local sum = 0
	for _, value in ipairs(values) do
		sum = sum + value
	end
	return sum / #values
end
local function median(values)
	if #values == 0 then
		return vim.NIL
	end
	local sorted = vim.deepcopy(values)
	table.sort(sorted)
	local middle = math.floor(#sorted / 2)
	return #sorted % 2 == 1 and sorted[middle + 1] or (sorted[middle] + sorted[middle + 1]) / 2
end
local function guard(grader)
	return type(grader.name) == "string" and grader.name:sub(1, 8) == "no-peek-"
end

---Identify runs invalidated by reading hidden acceptance material.
---@param run table
---@return boolean
function M.invalid(run)
	for _, grader in ipairs(run.graders or {}) do
		if guard(grader) and not grader.passed then
			return true
		end
	end
	return false
end

---Recompute outcome-only weighted score; guards never inflate or lower it.
---@param run table
---@return number|userdata
function M.outcome_score(run)
	local total, earned = 0, 0
	for _, grader in ipairs(run.graders or {}) do
		if grader.scored ~= false and not grader.withOnly and not guard(grader) then
			local weight = grader.weight or 1
			total = total + weight
			if grader.passed then
				earned = earned + weight
			end
		end
	end
	return total > 0 and earned / total or run.score or vim.NIL
end

---Summarize an arm, excluding invalid runs from means while counting all errors.
---@param runs table[]
---@return table
function M.arm_stats(runs)
	local scores, times, costs = {}, {}, {}
	local invalid, errors = 0, 0
	for _, run in ipairs(runs) do
		if run.error then
			errors = errors + 1
		end
		if M.invalid(run) then
			invalid = invalid + 1
		else
			local score = M.outcome_score(run)
			if type(score) == "number" then
				scores[#scores + 1] = score
			end
			if type(run.durationSeconds) == "number" then
				times[#times + 1] = run.durationSeconds
			end
			if type(run.costUsd) == "number" then
				costs[#costs + 1] = run.costUsd
			end
		end
	end
	return {
		runs = #runs,
		invalid = invalid,
		errors = errors,
		score = mean(scores),
		meanSeconds = mean(times),
		p50Seconds = median(times),
		costUsd = mean(costs),
	}
end
local function delta(a, b)
	return type(a) == "number" and type(b) == "number" and a - b or vim.NIL
end

---One row per case/arm, plus a with-minus-without delta for paired arms.
---@param result table
---@return table[]
function M.summarize(result)
	local rows = {}
	for _, case in ipairs(result.cases) do
		local arms = {}
		for _, arm in ipairs({ "with", "without" }) do
			local runs = case.arms and case.arms[arm] or {}
			if #runs > 0 then
				arms[arm] = M.arm_stats(runs)
				rows[#rows + 1] = vim.tbl_extend("force", { case = case.name, arm = arm }, arms[arm])
			end
		end
		if arms.with and arms.without then
			local row = { case = case.name, arm = "Δ with−without", delta = true }
			for _, key in ipairs({ "score", "meanSeconds", "p50Seconds", "costUsd" }) do
				row[key] = delta(arms.with[key], arms.without[key])
			end
			rows[#rows + 1] = row
		end
	end
	return rows
end
local function format_number(value, digits, signed)
	if type(value) ~= "number" then
		return "–"
	end
	return (signed and value >= 0 and "+" or "") .. string.format("%." .. digits .. "f", value)
end

---Render a local report explicitly marked as the new Lua benchmark series.
---@param result table
---@return string
function M.format_summary(result)
	local lines = {
		"Lua benchmark series; establish a new baseline (not comparable to the former JavaScript suite).",
		"",
		"| case | arm | runs | invalid | errors | mean score | mean s | p50 s | mean $ |",
		"|---|---|---|---|---|---|---|---|---|",
	}
	for _, row in ipairs(M.summarize(result)) do
		lines[#lines + 1] = string.format(
			"| %s | %s | %s | %s | %s | %s | %s | %s | %s |",
			row.case,
			row.arm,
			row.delta and "" or row.runs,
			row.delta and "" or row.invalid,
			row.delta and "" or row.errors,
			format_number(row.score, 2, row.delta),
			format_number(row.meanSeconds, 0, row.delta),
			format_number(row.p50Seconds, 0, row.delta),
			format_number(row.costUsd, 2, row.delta)
		)
	end
	local judge = 0
	for _, case in ipairs(result.cases) do
		for _, arm in ipairs({ "with", "without" }) do
			for _, run in ipairs(case.arms and case.arms[arm] or {}) do
				judge = judge + (run.judgeCostUsd or 0)
			end
		end
	end
	lines[#lines + 1] = string.format(
		"\nsuite: %ss wall, agent $%.2f, judge $%.2f%s",
		tostring(result.durationSeconds or 0),
		result.costUsd or 0,
		judge,
		result.partial and " (partial)" or ""
	)
	return table.concat(lines, "\n") .. "\n"
end
local function summary(rt, path)
	if not path then
		local dir = rt.path(rt.root, "evals", "results")
		local names = rt.list(dir)
		table.sort(names)
		for index = #names, 1, -1 do
			local candidate = rt.path(dir, names[index], "aggregate-result.json")
			if rt.exists(candidate) then
				path = candidate
				break
			end
		end
		assert(path, "eval: no aggregate-result.json under " .. dir)
	end
	local text = assert(rt.read(path), "eval: cannot read " .. path)
	return path .. "\n\n" .. M.format_summary(rt.decode(text))
end

---Run explicit, capped model evaluations, or summarize existing local results.
---Ordinary tests use fake interactive commands and never incur model usage.
---@param rt orc.Runtime
---@param argv string[]
---@return table
function M.run(rt, argv)
	local ok, result = pcall(function()
		if argv[1] == "summarize" then
			assert(#argv <= 2, "usage: orc eval summarize [aggregate-result.json]")
			return { code = 0, out = summary(rt, argv[2]), err = "" }
		end
		local bench, rest, tagged, output_dir = false, {}, false, nil
		for index, argument in ipairs(argv) do
			assert(
				argument ~= "--max-cost-usd" and not argument:match("^%-%-max%-cost%-usd="),
				"eval: set the cap with ORC_EVAL_MAX_COST"
			)
			if argument == "--bench" then
				bench = true
			else
				rest[#rest + 1] = argument
			end
			if argument == "--tag" or argument:match("^%-%-tag=") then
				tagged = true
			end
			if argument == "--output-dir" then
				output_dir = argv[index + 1]
			elseif argument:match("^%-%-output%-dir=") then
				output_dir = argument:sub(14)
			end
		end
		local cap = tonumber(rt.env.ORC_EVAL_MAX_COST or (bench and "20" or "5"))
		assert(
			cap and cap > 0 and cap < math.huge,
			"eval: ORC_EVAL_MAX_COST must be a positive finite number"
		)
		local plugin = M.build(rt)
		output_dir = output_dir or rt.path(rt.root, "evals", "results", (rt.now():gsub(":", "-")))
		local command = {
			"claude",
			"plugin",
			"eval",
			plugin,
			"--trust-plugin",
			"--scaffold",
			"--max-cost-usd",
			tostring(cap),
			"--no-publish",
		}
		if not tagged then
			vim.list_extend(command, { "--tag", bench and "bench" or "orc" })
		end
		if
			not vim.tbl_contains(rest, "--output-dir")
			and not table.concat(rest, "\n"):find("%-%-output%-dir=")
		then
			vim.list_extend(command, { "--output-dir", output_dir })
		end
		if bench then
			vim.list_extend(command, { "--threshold", "0", "--judge-model", "sonnet" })
		end
		vim.list_extend(command, { "--allow-tools", "Bash", "Edit", "Write" })
		vim.list_extend(command, rest)
		local code = rt.interactive(command, { cwd = rt.root })
		local report = rt.path(output_dir, "aggregate-result.json")
		return { code = code, out = bench and rt.exists(report) and summary(rt, report) or "", err = "" }
	end)
	return ok and result or { code = 1, out = "", err = tostring(result) .. "\n" }
end

return M
