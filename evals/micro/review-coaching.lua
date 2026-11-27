local phrases = { "do not flag", "at most minor", "the plan chose", "not a defect", "don't treat" }

---@type orc.MicroSpec
local spec = {
	provider = "claude",
	model = "haiku",
	reps = 5,
	cap = 0.1,
	context = "../../rules/delegated-workflow.md",
	task = [[Write the prompt you would give an independent reviewer for a diff that
adds a fallback to the latest worker report when the current run ID is missing.
The plan chose this fallback over requiring a matching run ID so interrupted runs
could still surface a report. The reviewer will receive the plan, diff, and tests.
Return only the review prompt.]],
	arms = {
		control = {},
		recipe = {
			guidance = [[Ask the reviewer to derive expected behavior from the acceptance criteria,
trace the diff through its callers and tests, and report independently verified
findings with file and line evidence and their impact. Include the plan as context
for evaluating the design decision.]],
		},
	},
	score = function(output)
		local count, flagged = 0, {}
		local normalized = output:lower():gsub("’", "'")
		for number, line in ipairs(vim.split(normalized, "\n", { plain = true })) do
			local before = count
			for _, phrase in ipairs(phrases) do
				local _, matches = line:gsub(phrase, "")
				count = count + matches
			end
			if count > before then
				flagged[#flagged + 1] = number
			end
		end
		return count, flagged
	end,
}

return spec
