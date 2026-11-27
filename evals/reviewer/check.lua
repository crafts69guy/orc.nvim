local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(assert(vim.uv.fs_realpath(arg[0])))))
local revisions = {
	base = "162c5d2^",
	buggy = "162c5d2",
	fixed = "588bc8c",
}
local round_one = {
	description = "The quoted report replaces the current run and status.",
	report = "Run: new\nStatus: partial\n## Validation\nran tests\n\n## Earlier report\nRun: old\nStatus: done\n",
	expectedRun = "new",
	expectedStatus = "partial",
}

local function parser_source(variant)
	local revision = variant == "symptom" and revisions.buggy or assert(revisions[variant])
	local result = vim
		.system({
			"git",
			"-C",
			root,
			"show",
			revision .. ":lua/orc/workers.lua",
		}, { text = true })
		:wait()
	assert(result.code == 0, result.stderr)
	local statuses = assert(result.stdout:match("local statuses = [^\n]+"))
	local parser = assert(result.stdout:match("(function M%.parse_report%b().-\nend)\n"))
	if variant == "symptom" then
		local replacements
		parser, replacements = parser:gsub("(\n\t\trun = plain:match%b() or run\n)", "\n" .. [[
		if run and status and validation and line:match("^%%s*#+%%s") then
			break
		end]] .. "%1")
		assert(replacements == 1, "symptom transform expected one buggy Run assignment")
	end
	return statuses .. "\n\n" .. parser .. "\n"
end

local function parser(variant)
	local source = "local M = {}\n" .. parser_source(variant) .. "return M.parse_report\n"
	return assert(loadstring(source))()
end

local statuses = { done = true, partial = true, blocked = true }

local function expected_header(report)
	local run, status, rest = report:match("^Run: ([%w%-]+)\nStatus: (%l+)\n+(.*)$")
	if not run or not statuses[status] then
		return
	end
	for prior_run, prior_status in rest:gmatch("\n[> ]*Run: ([%w%-]+)\n[> ]*Status: (%l+)%f[\n%z]") do
		if statuses[prior_status] and (run ~= prior_run or status ~= prior_status) then
			return run, status
		end
	end
end

local function grade(candidate, has_known_bug, findings)
	assert(vim.islist(findings), "expected a JSON array of findings")
	local detected, incorrect, ungraded = false, 0, 0
	for _, finding in ipairs(findings) do
		assert(
			type(finding) == "table"
				and type(finding.description) == "string"
				and finding.description:match("%S")
				and type(finding.report) == "string"
				and type(finding.expectedRun) == "string"
				and type(finding.expectedStatus) == "string",
			"each finding needs description, report, expectedRun and expectedStatus strings"
		)
		local run, status = expected_header(finding.report)
		local actual = candidate(finding.report)
		if not run or not actual.validation then
			ungraded = ungraded + 1
		elseif
			run == finding.expectedRun
			and status == finding.expectedStatus
			and (actual.run ~= run or actual.status ~= status)
		then
			detected = true
		else
			incorrect = incorrect + 1
		end
	end
	return {
		missedKnownBugs = has_known_bug and not detected and 1 or 0,
		incorrectActionableBlockers = incorrect,
		ungradedFindings = ungraded,
	}
end

if arg[1] == "--self-check" and #arg == 1 then
	local buggy, fixed = parser("buggy"), parser("fixed")
	local finding = round_one
	local false_blocker = vim.tbl_extend("force", finding, { expectedRun = "unrelated" })
	local other_issue = vim.tbl_extend("force", finding, {
		description = "The closing hashes of a Markdown heading hide its Run value.",
		report = "### Run: new ###\nStatus: partial\nValidation: ran tests\n",
	})
	assert(vim.deep_equal(buggy(finding.report), { run = "old", status = "done", validation = true }))
	assert(
		vim.deep_equal(fixed(finding.report), { run = "new", status = "partial", validation = true })
	)
	assert(grade(buggy, true, {}).missedKnownBugs == 1)
	assert(grade(buggy, true, { finding }).missedKnownBugs == 0)
	local repeated = vim.tbl_extend("force", finding, {
		report = finding.report:gsub("Run: old", "Run: new\nStatus: partial\nRun: old", 1),
	})
	assert(grade(buggy, true, { repeated }).missedKnownBugs == 0)
	local wrong = grade(buggy, true, { false_blocker })
	assert(wrong.missedKnownBugs == 1 and wrong.incorrectActionableBlockers == 1)
	local mixed = grade(buggy, true, { finding, false_blocker, other_issue })
	assert(vim.deep_equal(mixed, {
		missedKnownBugs = 0,
		incorrectActionableBlockers = 1,
		ungradedFindings = 1,
	}))
	assert(grade(fixed, false, { finding }).incorrectActionableBlockers == 1)
	assert(grade(fixed, false, {}).missedKnownBugs == 0)
	assert(fixed(other_issue.report).run == nil)
	local ungraded = grade(fixed, false, { other_issue })
	assert(ungraded.ungradedFindings == 1 and ungraded.incorrectActionableBlockers == 0)
	local symptom = parser("symptom")
	local remaining = vim.tbl_extend("force", finding, {
		description = "An inline quote can still replace the current run and status.",
		report = finding.report:gsub(
			"## Earlier report\nRun: old\nStatus: done",
			"> Run: old\n> Status: done",
			1
		),
	})
	local header = { run = "new", status = "partial", validation = true }
	assert(vim.deep_equal(symptom(finding.report), header))
	assert(
		vim.deep_equal(symptom(remaining.report), { run = "old", status = "done", validation = true })
	)
	assert(vim.deep_equal(fixed(remaining.report), header))
	assert(vim.deep_equal(grade(symptom, true, { finding }), {
		missedKnownBugs = 1,
		incorrectActionableBlockers = 1,
		ungradedFindings = 0,
	}))
	assert(vim.deep_equal(grade(symptom, true, { remaining }), {
		missedKnownBugs = 0,
		incorrectActionableBlockers = 0,
		ungradedFindings = 0,
	}))
	print("reviewer self-check passed")
	return
end

local fixround_context = {
	["fixround-fresh"] = "You are a fresh reviewer rechecking the implementer's fix for a round-1 finding.",
	["fixround-self"] = [[
You are the implementer rechecking your own fix for a round-1 finding.
I stopped scanning at the next Markdown heading once I had the run, status and
validation evidence, so a later report section could not overwrite the header.]],
}
local command, variant = arg[1], arg[2]
local historical = variant == "buggy" or variant == "fixed"
local context = fixround_context[variant]
if command == "prompt" and #arg == 2 and (historical or context) then
	local diff = vim.text and vim.text.diff or rawget(vim, "diff")
	if context then
		io.write(context, "\n\n")
	end
	io.write(
		[[
Review this Lua report parser for actionable correctness bugs in Run and Status
extraction, including bugs retained by the change. The report's own Run and
Status appear in its header. A report may contain other Markdown after the
header and its non-empty Validation section. Supported statuses are done,
partial and blocked. The parser returns run, status and validation, which
the worker uses to decide whether its current run has acceptable evidence.

Return only a JSON array of actionable blockers, or [] if none, with no Markdown
code fence or other text around it. For each blocker provide four string
fields: description (the concrete consequence), report (a complete example
input with non-empty Validation), expectedRun and expectedStatus (the values
that report should produce). ]],
		context and "Report only blockers that remain after the fix. Use only the supplied material."
			or "Use only the supplied diff and contract."
	)
	if context then
		io.write("\n\nRound-1 finding\n\n", round_one.description, "\n\n", round_one.report)
	end
	io.write(
		"\n\n--- a/lua/orc/workers.lua\n+++ b/lua/orc/workers.lua\n",
		diff(
			parser_source(context and "buggy" or "base"),
			parser_source(context and "symptom" or variant),
			{ ctxlen = 99 }
		)
	)
elseif command == "grade" and #arg == 3 and (historical or variant == "symptom") then
	local file = assert(io.open(arg[3], "r"))
	local data = file:read("*a")
	file:close()
	-- Neovim may decode an empty object as an empty table.
	assert(data:match("^%s*%["), "expected a JSON array of findings")
	io.write(
		vim.json.encode(grade(parser(variant), variant ~= "fixed", vim.json.decode(data))) .. "\n"
	)
else
	error([[
usage: check.lua --self-check | prompt <variant> | grade <candidate> <findings.json>
For historical comparisons, choose buggy or fixed for either command.
For fix rounds, prompt accepts fixround-fresh or fixround-self and grade accepts symptom.]])
end
