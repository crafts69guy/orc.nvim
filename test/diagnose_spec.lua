local cli = require("orc.cli")
local runtime = require("orc.runtime")

local function fixture()
	local root, checkout = Test.temp(), Test.temp()
	local rt = runtime.new({ cwd = checkout })
	rt.exec = function(argv)
		Test.eq(argv, { "git", "rev-parse", "--path-format=absolute", "--git-common-dir" })
		return { code = 0, signal = 0, stdout = root .. "/.git\n", stderr = "" }
	end
	local function record(task, fields)
		local path = rt.path(root, ".orc", "workers", task .. ".json")
		rt.write(
			path,
			rt.encode(vim.tbl_extend("force", {
				feature = "feature",
				task = task,
				kind = "codex",
				state = "closed",
				reportStatus = "done",
				path = checkout,
				runId = "run-" .. task,
				createdAt = "2026-01-01T00:00:20Z",
				updatedAt = "2026-01-01T00:00:30Z",
			}, fields))
		)
		return path
	end
	return rt, root, record
end

Test.test(
	"diagnose reports unknown features and publishes CLI usage and fish completion",
	function()
		local rt, _, record = fixture()
		record("other", { feature = "unrelated" })
		local result = cli.run(rt, { "diagnose", "missing", "--json" })
		Test.eq(result.code, 1)
		assert(result.err:find("no worker records for feature", 1, true), result.err)
		assert(cli.run(rt, { "diagnose", "--help" }).out:find("diagnose <feature> [--json]", 1, true))
		assert(cli.run(rt, { "completion", "fish" }).out:find("-a diagnose ", 1, true))
	end
)

Test.test(
	"diagnose reads both transcript formats and prints only bounded stumble evidence",
	function()
		local rt, root, record = fixture()
		local codex = rt.path(root, "codex.jsonl")
		local claude = rt.path(rt.root, "test", "fixtures", "diagnose", "claude.jsonl")
		local source = assert(rt.read(rt.path(rt.root, "test", "fixtures", "diagnose", "codex.jsonl")))
		local oversized = '{"type":"event_msg","payload":{"type":"error","message":"Hook failed '
			.. string.rep("x", 1024 * 1024)
			.. '"}}\n'
		rt.write(codex, (source:gsub("\n([^\n]+)\n$", "\n" .. oversized .. "%1")))
		record("codex", { transcript = codex, level = "high" })
		local incomplete = record("claude", {
			transcript = claude,
			kind = "claude",
			role = "scoper",
			state = "working",
			reportStatus = "partial",
		})
		local missing = rt.path(root, "missing.jsonl")
		record("missing", { transcript = missing })
		local invalid = rt.path(root, ".orc", "workers", "invalid.json")
		rt.write(invalid, "{sk-fixture-do-not-display")
		local signals = rt.path(root, ".orc", "signals.jsonl")
		local rows = {}
		for _, event in ipairs({
			{ "2025-12-31T23:59:59Z", "deny" },
			{ "2026-01-01T00:00:02Z", "deny" },
			{ "2026-01-01T00:00:20Z", "no-evidence" },
			{ "2026-01-01T00:00:30Z", "deny" },
			{ "2026-01-01T00:00:31Z", "deny" },
		}) do
			rows[#rows + 1] = rt.encode({
				ts = event[1],
				kind = event[2],
				role = "implementer",
				reason = "sk-fixture-do-not-display",
			})
		end
		rt.write(signals, table.concat(rows, "\n"))

		local json = cli.run(rt, { "diagnose", "feature", "--json" })
		Test.eq(json.code, 0)
		local output = rt.decode(json.out)
		Test.eq(output.schemaVersion, 1)
		Test.eq(output.feature, "feature")
		local workers = {}
		for _, worker in ipairs(output.workers) do
			workers[worker.task] = worker
		end
		Test.eq(#output.workers, 3)
		local function stats(task)
			local w = workers[task]
			return {
				w.role,
				w.kind,
				w.level,
				w.model,
				w.runs,
				w.turns,
				w.toolCalls,
				w.failedToolCalls,
				w.inputTokens,
				w.outputTokens,
				w.wallSeconds,
			}
		end
		Test.eq(
			stats("codex"),
			{ "implementer", "codex", "high", "codex-fixture", 2, 2, 4, 2, 130, 30, 18.25 }
		)
		Test.eq(
			stats("claude"),
			{ "scoper", "claude", "default", "claude-fixture", 1, 2, 3, 1, 165, 9, 8 }
		)
		Test.eq(stats("missing"), { "implementer", "codex", "default", "unknown", 0, 0, 0, 0, 0, 0, 0 })
		Test.eq(output.totals.byRole.implementer.workers, 2)
		Test.eq(output.totals.byRole.implementer.toolCalls, 4)
		Test.eq(output.totals.byRole.scoper.inputTokens, 165)
		Test.eq(output.totals.byModel["codex-fixture"].wallSeconds, 18.25)
		Test.eq(output.totals.byModel["claude-fixture"].inputTokens, 165)
		Test.eq(output.totals.byModel["claude-fixture"].outputTokens, 9)

		local evidence = {}
		for _, stumble in ipairs(output.stumbles) do
			local key = stumble.path .. ":" .. stumble.line
			assert(not evidence[key], key)
			evidence[key] = stumble
		end
		Test.eq(#output.stumbles, 10)
		for _, expected in ipairs({
			{ codex, 7, "failed-tool" },
			{ codex, 8, "repeated-tool" },
			{ codex, 10, "hook-failure" },
			{ codex, 16, "failed-tool" },
			{ claude, 4, "failed-tool" },
			{ claude, 5, "repeated-tool" },
			{ claude, 6, "hook-failure" },
			{ incomplete, 1, "worker-incomplete" },
			{ signals, 2, "guard-deny" },
			{ signals, 4, "guard-deny" },
		}) do
			local key = expected[1] .. ":" .. expected[2]
			assert(evidence[key], key)
			Test.eq(evidence[key].kind, expected[3])
		end
		local failure = evidence[codex .. ":7"].detail
		assert(failure:find("exec_command", 1, true) and failure:find("exit 7", 1, true), failure)
		assert(failure:find("printf " .. string.rep("é", 73), 1, true), failure)
		assert(not failure:find(string.rep("é", 74), 1, true), failure)
		local bash = evidence[claude .. ":4"].detail
		assert(bash:find("Bash (exit 3)", 1, true) and bash:find("check fixture", 1, true), bash)
		local warnings = table.concat(output.warnings, "\n")
		assert(warnings:find(invalid, 1, true) and warnings:find(missing, 1, true), warnings)
		assert(warnings:find(codex .. ":19", 1, true) and warnings:find("1 MiB", 1, true), warnings)
		local plain = cli.run(rt, { "diagnose", "feature" })
		Test.eq(plain.code, 0)
		assert(
			plain.out:find("codex-fixture", 1, true) and plain.out:find(codex .. ":7", 1, true),
			plain.out
		)
		for _, rendered in ipairs({ json, plain }) do
			assert(not (rendered.out .. (rendered.err or "")):find("sk-fixture-do-not-display", 1, true))
		end
	end
)

Test.test("diagnose uses exec logs as fallback without counting a rollout twice", function()
	local rt, _, record = fixture()
	local exec = rt.path(rt.cwd, ".orc", "runs")
	local codex = rt.path(rt.root, "test", "fixtures", "diagnose", "codex.jsonl")
	local function log(run, code)
		local path = rt.path(exec, run .. ".jsonl")
		local item = { id = "same-id", type = "command_execution", command = "test -f redacted" }
		local events = {
			{ type = "thread.started", thread_id = run },
			{ type = "turn.started" },
			{ type = "item.started", item = item },
			{ type = "item.completed", item = vim.tbl_extend("force", item, { exit_code = code }) },
			{
				type = "turn.completed",
				usage = { input_tokens = 3, cached_input_tokens = 2, output_tokens = 2 },
			},
		}
		rt.write(path, table.concat(vim.tbl_map(rt.encode, events), "\n"))
		return path
	end
	record("exec", { transport = "exec", previousRunId = "previous" })
	local evidence = log("run-exec", 8)
	log("previous", 0)
	record("mirrored", { transport = "exec", transcript = codex, runId = "two" })
	log("two", 0)
	local response = cli.run(rt, { "diagnose", "feature", "--json" })
	Test.eq(response.code, 0)
	local output = rt.decode(response.out)
	local worker = output.workers[1]
	Test.eq(worker.task, "exec")
	Test.eq({ worker.runs, worker.turns, worker.toolCalls, worker.failedToolCalls }, { 2, 2, 2, 1 })
	Test.eq({ worker.inputTokens, worker.outputTokens }, { 6, 4 })
	Test.eq(output.workers[2].toolCalls, 4)
	Test.eq(output.stumbles[1].path, evidence)
	Test.eq(output.stumbles[1].line, 4)
end)

Test.test("diagnose counts runs whose prompt the TUI wrapped as pasted content", function()
	local rt, root, record = fixture()
	local transcript = rt.path(root, "pasted.jsonl")
	local rows = {}
	for _, content in ipairs({
		"[orc-run:first] work",
		'\n\n<pasted_content id="4e03">\n[orc-run:second] review\n</pasted_content>',
		"quoting [orc-run:third] is not a run",
	}) do
		rows[#rows + 1] = rt.encode({ type = "user", message = { role = "user", content = content } })
	end
	rt.write(transcript, table.concat(rows, "\n") .. "\n")
	record("pasted", { transcript = transcript, kind = "claude" })
	local response = cli.run(rt, { "diagnose", "feature", "--json" })
	Test.eq(response.code, 0)
	Test.eq(rt.decode(response.out).workers[1].runs, 2)
end)
