local M = {}

---@class orc.MicroSpec
---@field provider "claude"|"codex"
---@field model string
---@field reps integer
---@field cap number Claude's per-call budget in USD.
---@field context string Context file path relative to the spec.
---@field task string
---@field arms table<string,{ guidance?: string }>
---@field score fun(output:string): number, integer[] Score and one-based flagged line numbers.

---@class orc.MicroRun
---@field file string
---@field score? number
---@field flagged? integer[]
---@field error? string

local function read(rt, path, kind)
	local text, err = rt.read(path)
	assert(text, ("cannot read %s %s: %s"):format(kind, path, tostring(err)))
	return text
end

local function nonblank(value)
	return type(value) == "string" and value:find("%S") ~= nil
end

local function finite(value)
	return type(value) == "number" and math.abs(value) < math.huge
end

local function positive_integer(value)
	return type(value) == "number" and value >= 1 and value < 2 ^ 53 and value % 1 == 0
end

---@param rt orc.Runtime
---@param path string
---@return orc.MicroSpec
local function load_spec(rt, path)
	local spec = assert(loadstring(read(rt, path, "spec"), "@" .. path))()
	assert(type(spec) == "table", "spec must return a table")
	assert(spec.provider == "claude" or spec.provider == "codex", "provider must be claude or codex")
	assert(nonblank(spec.model), "model must be a nonempty string")
	assert(positive_integer(spec.reps), "reps must be a positive integer")
	assert(finite(spec.cap) and spec.cap > 0, "cap must be a positive finite number")
	assert(
		nonblank(spec.context) and not spec.context:match("^/") and not spec.context:match("^~/"),
		"context must be a path relative to the spec"
	)
	assert(nonblank(spec.task), "task must be a nonempty string")
	assert(type(spec.arms) == "table", "arms must be a map")
	assert(type(spec.arms.control) == "table", "arms must include a control arm table")
	assert(spec.arms.control.guidance == nil, "control arm must have no guidance")
	local filenames = {}
	for name, arm in pairs(spec.arms) do
		assert(
			type(name) == "string" and name:match("^[%w_.%-]+$"),
			"invalid arm name: " .. tostring(name)
		)
		local filename = name:lower()
		assert(not filenames[filename], "arm names must be distinct ignoring case: " .. name)
		filenames[filename] = true
		assert(type(arm) == "table", "arm " .. name .. " must be a table")
		assert(
			arm.guidance == nil or type(arm.guidance) == "string",
			name .. ".guidance must be a string"
		)
	end
	assert(type(spec.score) == "function", "score must be a function")
	return spec
end

local function result_dir(rt)
	local parent = rt.path(rt.root, "evals", "results")
	local base = rt.path(parent, "micro-" .. (rt.now():gsub(":", "-")))
	rt.mkdir(parent)
	local dir, suffix = base, 1
	while not rt.mkdir_lock(dir) do
		suffix = suffix + 1
		dir = base .. "-" .. suffix
	end
	return dir
end

---@param rt orc.Runtime
---@param spec orc.MicroSpec
---@param cap string
---@param prompt string
---@param file string
---@return orc.MicroRun
local function run_rep(rt, spec, cap, prompt, file)
	local command
	if spec.provider == "claude" then
		command = {
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
			cap,
			"--no-session-persistence",
			"--model",
			spec.model,
		}
	else
		command = {
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
			spec.model,
			"-o",
			file,
			"-",
		}
	end
	local cwd = assert(vim.uv.fs_mkdtemp(vim.fn.tempname() .. "-XXXXXX"))
	local started, result = pcall(rt.exec, command, { cwd = cwd, stdin = prompt })
	rt.remove(cwd)
	if not started then
		error(result, 0)
	end
	local last_message = spec.provider == "codex" and rt.read(file) or nil
	local output = last_message or result.stdout
	rt.write(file, output)
	if result.code ~= 0 then
		return {
			file = file,
			error = ("%s exit %d: %s"):format(spec.provider, result.code, result.stderr),
		}
	end
	if spec.provider == "codex" and not last_message then
		return { file = file, error = "codex did not write its last-message file" }
	end
	local ok, score, flagged = pcall(spec.score, output)
	if not ok then
		return { file = file, error = "score: " .. tostring(score) }
	end
	if
		not finite(score)
		or not vim.islist(flagged)
		or not vim.iter(flagged):all(positive_integer)
	then
		return {
			file = file,
			error = "score must return a finite number and a list of positive line numbers",
		}
	end
	return { file = file, score = score, flagged = flagged }
end

local function summarize(dir, names, arms)
	local lines, matches = { "Results in " .. dir }, {}
	local arm_stats = require("orc.eval").arm_stats
	for _, name in ipairs(names) do
		local stats = arm_stats(arms[name])
		local range = stats.scoreRange
		local measures = type(range) == "table"
				and ("mean=%.6g range=%.6g..%.6g spread=%.6g"):format(
					stats.score,
					range.min,
					range.max,
					range.max - range.min
				)
			or "mean=– range=– spread=–"
		lines[#lines + 1] = ("%s n=%d errors=%d %s"):format(
			name,
			stats.runs - stats.errors,
			stats.errors,
			measures
		)
		for _, run in ipairs(arms[name]) do
			for _, line in ipairs(run.flagged or {}) do
				matches[#matches + 1] = ("%s:%d"):format(run.file, line)
			end
		end
	end
	return table.concat(vim.list_extend(lines, matches), "\n") .. "\n"
end

local function run(rt, argv)
	local usage = "usage: orc eval micro <spec.lua> [--dry-run] [--pilot]"
	assert(argv[1] and not argv[1]:match("^%-"), usage)
	local pilot, dry_run = false, false
	for index = 2, #argv do
		local option = argv[index]
		assert(
			option == "--pilot" or option == "--dry-run",
			usage .. " (unknown option " .. option .. ")"
		)
		pilot = pilot or option == "--pilot"
		dry_run = dry_run or option == "--dry-run"
	end
	local path = rt.abspath(argv[1])
	local spec = load_spec(rt, path)
	local reps = pilot and 1 or spec.reps
	assert(pilot or reps >= 5, "reps must be at least 5 unless using --pilot")
	local names = vim.tbl_keys(spec.arms)
	table.sort(names)
	local calls = #names * reps
	assert(positive_integer(calls), "planned call count exceeds the supported integer range")
	local ceiling = tonumber(rt.env.ORC_EVAL_MAX_COST or "5")
	assert(
		ceiling and ceiling > 0 and ceiling < math.huge,
		"ORC_EVAL_MAX_COST must be a positive finite number"
	)
	local cap = tostring(spec.cap)
	if tonumber(cap) ~= spec.cap then
		cap = ("%.17g"):format(spec.cap)
	end
	local cost
	if spec.provider == "claude" then
		cost = calls * spec.cap
		assert(
			finite(cost) and cost <= ceiling * (1 + 1e-12),
			("Claude cost USD %s exceeds ORC_EVAL_MAX_COST (USD %s)"):format(cost, ceiling)
		)
	else
		assert(rt.env.ORC_EVAL_CODEX == "1", "Codex requires ORC_EVAL_CODEX=1")
	end
	local context = read(rt, rt.path(vim.fs.dirname(path), spec.context), "context")
	local prompts = {}
	for _, name in ipairs(names) do
		local guidance = spec.arms[name].guidance
		prompts[name] = guidance and table.concat({ context, guidance, spec.task }, "\n\n")
			or context .. "\n\n" .. spec.task
	end
	if dry_run then
		local lines =
			{ ("%d calls to %s %s (%d per arm)"):format(calls, spec.provider, spec.model, reps) }
		lines[#lines + 1] = cost
				and ("Claude ceiling USD %s (USD %s per call, ORC_EVAL_MAX_COST USD %s)"):format(
					cost,
					cap,
					ceiling
				)
			or "Codex has no enforced USD ceiling"
		for _, name in ipairs(names) do
			lines[#lines + 1] = ("\n[%s]\n%s"):format(name, prompts[name])
		end
		return table.concat(lines, "\n") .. "\n"
	end
	local dir = result_dir(rt)
	---@type table<string,orc.MicroRun[]>
	local arms = {}
	for _, name in ipairs(names) do
		arms[name] = {}
	end
	for rep = 1, reps do
		for _, name in ipairs(names) do
			local file = rt.path(dir, ("%s-%d.txt"):format(name, rep))
			arms[name][rep] = run_rep(rt, spec, cap, prompts[name], file)
		end
	end
	rt.write(rt.path(dir, "scores.json"), rt.encode({
		provider = spec.provider,
		model = spec.model,
		reps = reps,
		cap = spec.cap,
		arms = arms,
	}) .. "\n")
	return summarize(dir, names, arms)
end

---Run an explicit wording micro-test or preview its calls and prompts.
---@param rt orc.Runtime
---@param argv string[] Spec path followed by optional flags.
---@return { code: integer, out: string, err: string }
function M.run(rt, argv)
	local ok, output = pcall(run, rt, argv)
	if not ok then
		return { code = 1, out = "", err = "micro: " .. tostring(output) .. "\n" }
	end
	return { code = 0, out = output, err = "" }
end

return M
