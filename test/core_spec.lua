local cli = require("orc.cli")
local generator = require("orc.generator")
local hooks = require("orc.hooks")
local lessons = require("orc.lessons")
local runtime = require("orc.runtime")
local status = require("orc.status")
local wt = require("orc.worktrees")

local function result(code, stdout, stderr)
	return { code = code or 0, stdout = stdout or "", stderr = stderr or "", signal = 0 }
end

local function fake()
	local rt = runtime.new({ root = "/plugin", cwd = "/repo" })
	rt.env, rt.files, rt.commands, rt.launched = {}, {}, {}, {}
	rt.read = function(path)
		return rt.files[path]
	end
	rt.write = function(path, text)
		rt.files[path] = text
	end
	rt.append = function(path, line)
		rt.files[path] = (rt.files[path] or "") .. line
	end
	rt.rmdir = function(path)
		assert(#rt.list(path) == 0, "ENOTEMPTY: directory not empty")
		rt.files[path] = nil
	end
	rt.mkdir = function() end
	rt.remove = function(path)
		rt.files[path] = nil
	end
	rt.exists = function(path)
		return rt.files[path] ~= nil
	end
	rt.list = function(path)
		local seen, names = {}, {}
		for file in pairs(rt.files) do
			if file:sub(1, #path + 1) == path .. "/" then
				local name = file:sub(#path + 2):match("^[^/]+")
				if not seen[name] then
					seen[name], names[#names + 1] = true, name
				end
			end
		end
		table.sort(names)
		return names
	end
	rt.exec = function(argv, options)
		rt.commands[#rt.commands + 1] = { argv = argv, options = options }
		local key = table.concat(argv, " ")
		if key == "git rev-parse --path-format=absolute --git-common-dir" then
			return result(0, "/repo/.git\n")
		elseif key == "git rev-parse --show-toplevel" then
			return result(0, "/repo\n")
		elseif key == "wt list --format=json" then
			return result(0, rt.encode({ items = {} }))
		elseif key:match("^git check%-ignore") then
			return result(1)
		end
		return result()
	end
	rt.interactive = function(argv, options)
		rt.launched[#rt.launched + 1] = { argv = argv, options = options }
		return 0
	end
	rt.files["/plugin/rules/orchestrator.md"] = "Fixture rules"
	return rt
end

local function route(rt, routes)
	local previous = rt.exec
	rt.exec = function(argv, options)
		local found = routes[table.concat(argv, " ")]
		if type(found) == "function" then
			return found(argv, options)
		end
		return found or previous(argv, options)
	end
end

local function with_module(name, value, fn)
	local previous = package.loaded[name]
	package.loaded[name] = value
	local ok, err = xpcall(fn, debug.traceback)
	package.loaded[name] = previous
	assert(ok, err)
end

Test.test("core CLI help, version, errors and lazy routing", function()
	local rt = fake()
	for _, argv in ipairs({ {}, { "help" }, { "-h" }, { "--help" } }) do
		Test.eq(cli.run(rt, argv).out, cli.usage)
	end
	Test.eq(cli.run(rt, { "--version" }).out, "0.1.0\n")
	Test.eq(cli.run(rt, { "-V" }).code, 0)
	Test.eq(cli.run(rt, { "unknown" }).code, 1)
	Test.eq(cli.run(rt, { "completion", "zsh" }).code, 1)
	assert(cli.run(rt, { "completion", "fish" }).out:find("complete -c orc", 1, true))
	for command, module in pairs({
		pane = "workers",
		context = "context",
		inkdrop = "inkdrop",
		eval = "eval",
	}) do
		with_module("orc." .. module, {
			run = function(_, args)
				Test.eq(args, { "argument" })
				return { code = 0, out = "routed" }
			end,
		}, function()
			Test.eq(cli.run(rt, { command, "argument" }).out, "routed")
		end)
	end
end)

Test.test(
	"core Claude launcher preserves harness args, plugin root, permission defaults and overrides",
	function()
		local rt = fake()
		Test.eq(cli.run(rt, { "claude", "-c", "literal config", "prompt" }).code, 0)
		Test.eq(
			rt.launched[1].argv,
			{ "claude", "--plugin-dir", "/plugin", "--model", "opus", "-c", "literal config", "prompt" }
		)
		Test.eq(rt.launched[1].options.env.ORC_ROLE, "")
		Test.eq(rt.launched[1].options.env.ORC, "1")
		Test.eq(cli.run(rt, { "claude", "--yolo", "--model=sonnet", "--", "--pair" }).code, 0)
		Test.eq(rt.launched[2].argv, {
			"claude",
			"--plugin-dir",
			"/plugin",
			"--dangerously-skip-permissions",
			"--model=sonnet",
			"--",
			"--pair",
		})
		for _, args in ipairs({
			{ "--base", "main" },
			{ "--wt" },
			{ "--level=bad" },
			{ "--yolo=true" },
			{ "--yolo", "--yolo" },
			{ "--pair", "--panes" },
			{ "--pair" },
		}) do
			Test.eq(cli.run(rt, vim.list_extend({ "claude" }, args)).code, 1)
		end
		Test.eq(cli.run(rt, { "codex", "--pair" }).code, 1)
	end
)

Test.test("core Claude high mode and Rex mode are explicit per-run options", function()
	local rt = fake()
	rt.env.REX_SESSION, rt.env.REX_BLOCK = "session:1", "block:1"
	for _, name in ipairs({ "implementer", "reviewer", "scoper", "shipper" }) do
		local tools = name == "implementer" and "Read, Write, Edit, Bash" or "Read, Grep, Glob, Bash"
		rt.files["/plugin/agents/" .. name .. ".md"] = "---\nname: "
			.. name
			.. "\ndescription: role\ntools: "
			.. tools
			.. "\n---\nBody"
	end
	Test.eq(cli.run(rt, { "claude", "--level", "high", "--pair", "prompt" }).code, 0)
	Test.eq(rt.launched[1].options.env.ORC_PAIR, "1")
	local agents
	for index, word in ipairs(rt.launched[1].argv) do
		if word == "--agents" then
			agents = rt.decode(rt.launched[1].argv[index + 1])
		end
	end
	Test.eq(agents.implementer.model, "opus")
	Test.eq(agents.scoper.model, "sonnet")
	Test.eq(agents.reviewer.model, "opus")
	Test.eq(agents.scoper.tools, { "Read", "Grep", "Glob", "Bash" })
	Test.eq(agents.implementer.tools, { "Read", "Write", "Edit", "Bash" })
	Test.eq(cli.run(rt, { "claude", "--panes", "--level=default" }).code, 0)
	Test.eq(rt.launched[2].options.env.ORC_PANES, "1")
end)

Test.test(
	"core launcher honors documented environment modes and detects combined conflicts",
	function()
		local rt = fake()
		rt.env.REX_SESSION, rt.env.REX_BLOCK = "s", "b"
		rt.env.ORC_PAIR, rt.env.ORC_LEVEL = "1", "high"
		Test.eq(cli.run(rt, { "claude" }).code, 0)
		Test.eq(rt.launched[1].options.env.ORC_PAIR, "1")
		Test.eq(rt.launched[1].options.env.ORC_LEVEL, "high")
		Test.eq(cli.run(rt, { "claude", "--panes" }).code, 1)
		Test.eq(cli.run(rt, { "codex" }).code, 0)
		Test.eq(rt.launched[2].options.env.ORC_PAIR, false)
		rt.env.ORC_PAIR, rt.env.ORC_PANES = nil, "1"
		Test.eq(cli.run(rt, { "claude", "--level=default" }).code, 0)
		Test.eq(rt.launched[3].options.env.ORC_PANES, "1")
		Test.eq(rt.launched[3].options.env.ORC_LEVEL, "default")
		rt.env.ORC_LEVEL = "bad"
		Test.eq(cli.run(rt, { "claude" }).code, 1)
	end
)

Test.test(
	"core context warns about active foreign checkout owners but permits its own pair",
	function()
		local rt = fake()
		rt.env.REX_SESSION, rt.env.REX_BLOCK = "own", "main"
		with_module("orc.workers", {
			parse_report = require("orc.workers").parse_report,
			collect = function()
				return {
					{ path = "/repo", task = "T1", blockId = "worker", sessionId = "own", state = "working" },
					{ path = "/repo", task = "closed", blockId = "old", state = "closed" },
				}
			end,
		}, function()
			assert(hooks.context(rt):find("Another worker owns", 1, true))
			rt.env.ORC_PAIR = "1"
			assert(not hooks.context(rt):find("Another worker owns", 1, true))
		end)
	end
)

Test.test(
	"core Codex launcher injects context and generated roles without persisted config",
	function()
		local rt = fake()
		rt.files["/plugin/codex/agents/implementer.toml"] =
			'name = "implementer"\ndescription = "role"\n'
		rt.files["/plugin/codex/agents/ignored.txt"] = ""
		Test.eq(cli.run(rt, { "codex", "--yolo", "--sandbox", "workspace-write", "prompt" }).code, 0)
		local joined = table.concat(rt.launched[1].argv, " ")
		assert(joined:find("developer_instructions=", 1, true))
		assert(joined:find('agents.implementer.description="role"', 1, true))
		assert(joined:find("--add-dir /repo/.git", 1, true))
		assert(joined:find("--dangerously-bypass-approvals-and-sandbox", 1, true))
		Test.eq(rt.files["/plugin/rules/orchestrator.md"], "Fixture rules")
		route(rt, { ["git rev-parse --path-format=absolute --git-common-dir"] = result(128) })
		Test.eq(cli.run(rt, { "codex" }).code, 0)
		assert(not table.concat(rt.launched[2].argv, " "):find("--add-dir", 1, true))
	end
)

Test.test(
	"core generator validates frontmatter, sandbox and drift without writes in check mode",
	function()
		local source =
			'---\nname: reader\ndescription: "Read only"\neffort: max\ntools: Read, Bash\n---\nBody with "quotes"\n'
		local rendered = generator.render(source, "reader.md")
		assert(rendered:find('sandbox_mode = "read-only"', 1, true))
		assert(rendered:find('model_reasoning_effort = "xhigh"', 1, true))
		Test.raises("frontmatter", function()
			generator.render("body", "bad.md")
		end)
		Test.raises("missing name", function()
			generator.render("---\ndescription: test\n---\nbody", "bad.md")
		end)
		Test.raises("missing description", function()
			generator.render("---\nname: a\n---\nbody", "bad.md")
		end)
		Test.raises("invalid codex%-sandbox", function()
			generator.render(source:gsub("effort: max", "codex-sandbox: bad"), "bad.md")
		end)
		assert(
			not generator
				.render(source:gsub("effort: max", "codex-sandbox: inherit"), "a.md")
				:find("sandbox_mode", 1, true)
		)
		assert(
			generator
				.render(source:gsub("effort: max", "codex-sandbox: workspace-write"), "a.md")
				:find('sandbox_mode = "workspace-write"', 1, true)
		)
		assert(
			not generator
				.render(source:gsub("Read, Bash", "Write, Edit"), "a.md")
				:find("sandbox_mode", 1, true)
		)
		local rt = fake()
		rt.files["/plugin/agents/reader.md"], rt.files["/plugin/agents/ignore.txt"] = source, ""
		rt.files["/plugin/codex/agents/extra.toml"] = "old"
		Test.eq(generator.generate(rt, true).code, 1)
		assert(rt.files["/plugin/codex/agents/extra.toml"])
		Test.eq(generator.generate(rt).code, 0)
		Test.eq(rt.files["/plugin/codex/agents/extra.toml"], nil)
		Test.eq(rt.files["/plugin/codex/agents/reader.toml"], rendered)
		Test.eq(generator.generate(rt, true).code, 0)
	end
)

Test.test(
	"core lessons preserve file order, recognize legacy rows and cap approved memory",
	function()
		local text =
			"# Lessons\r\n- [L009] +2 -0 project · feature with spaces · First\r\n- [L001] +3 -1 orc · other · Second\r\n- [L003] +0 -0 project · retired · Gone\r\n- [bad]\r\n- prose\r\n"
		local parsed, malformed = lessons.parse(text)
		Test.eq(#parsed, 3)
		Test.eq(malformed, { 5 })
		Test.eq(lessons.select(parsed, 1)[1].id, "L009")
		Test.eq(#lessons.select(parsed), 2)
		local rt = fake()
		rt.files["/repo/.orc/lessons.md"] = text
		assert(lessons.read(rt):find("First", 1, true))
		assert(not lessons.read(rt):find("Gone", 1, true))
		route(rt, { ["git rev-parse --path-format=absolute --git-common-dir"] = result(128) })
		Test.eq(lessons.read(rt), "")
	end
)

Test.test("core workflow guards classify direct, chained, quoted and wrapped writes", function()
	Test.eq(hooks.role(nil), "main")
	Test.eq(hooks.role(""), "main")
	Test.eq(hooks.role("orc:implementer"), "implementer")
	for _, command in ipairs({
		"git push",
		"git -C /repo push",
		"env A=1 git -c a=b push",
		"command git commit -m x",
		"gh -R owner/repo pr create",
		"gh pr merge",
		"gh pr edit",
		"true && git push",
		"false; git commit -m x",
		"sh -c 'git push'",
		'bash -lc "git commit -m x"',
		"rex run -- git push",
		"rex split -- git commit -m x",
		"orc wt merge feat T1",
	}) do
		assert(hooks.decide("implementer", command), command)
	end
	for _, command in ipairs({
		"git status",
		"git diff",
		"gh pr view",
		"rex ls",
		"rex capture",
		"echo 'git push'",
		'printf "a;b"',
		"A=1",
		"",
	}) do
		Test.eq(hooks.decide("implementer", command), nil)
	end
	Test.eq(hooks.decide("shipper", "git push"), nil)
	Test.eq(hooks.decide("main", "git commit -m x"), nil)
	Test.eq(hooks.decide("main", "rex run -- git push") ~= nil, true)
	Test.eq(hooks.decide("reviewer", "rex do action") ~= nil, true)
	Test.eq(hooks.decide("main", nil), nil)
end)

Test.test(
	"core hooks gate activation, malformed input, role restrictions and report evidence",
	function()
		local rt = fake()
		Test.eq(hooks.run(rt, "guard", "{}").out, "")
		rt.env.ORC = "1"
		Test.eq(hooks.run(rt, "guard", "invalid").out, "")
		Test.eq(hooks.run(rt, "guard", "null").out, "")
		local denied = hooks.run(
			rt,
			"guard",
			rt.encode({ agent_type = "orc:implementer", tool_input = { command = "git commit -m x" } })
		)
		Test.eq(rt.decode(denied.out).hookSpecificOutput.permissionDecision, "deny")
		assert(rt.files["/repo/.orc/signals.jsonl"]:find('"kind":"deny"', 1, true))
		rt.env.ORC_ROLE = "implementer"
		Test.eq(
			rt.decode(
				hooks.run(
					rt,
					"guard",
					rt.encode({ agent_type = "orc:shipper", tool_input = { cmd = "git push" } })
				).out
			).hookSpecificOutput.permissionDecision,
			"deny"
		)
		Test.eq(hooks.run(rt, "session-start", "{}").out, "")
		rt.env.ORC_ROLE = ""
		Test.eq(
			rt.decode(hooks.run(rt, "session-start", "{}").out).hookSpecificOutput.hookEventName,
			"SessionStart"
		)
		Test.eq(hooks.evidence(nil), false)
		Test.eq(hooks.evidence("Status: done. I did not run validation.\nNotes: flaky"), false)
		Test.eq(hooks.evidence("- Status: done\n- Changes: x\n- Validation: nvim -l t -> ok"), true)
		Test.eq(hooks.evidence("**Status:** blocked\n**Validation**\nran tests"), true)
		Test.eq(hooks.evidence("Status: done\nValidation\n"), false)
		Test.eq(hooks.evidence("Status: unknown\nValidation\npass"), false)
		local payload = {
			agent_type = "implementer",
			last_assistant_message = "Status: done\nValidation\nnvim tests passed",
		}
		Test.eq(hooks.run(rt, "subagent-stop", rt.encode(payload)).out, "")
		payload.last_assistant_message = "incomplete"
		Test.eq(rt.decode(hooks.run(rt, "subagent-stop", rt.encode(payload)).out).decision, "block")
		payload.stop_hook_active = true
		Test.eq(hooks.run(rt, "subagent-stop", rt.encode(payload)).out, "")
		Test.eq(cli.run(rt, { "hook" }).code, 1)
		Test.eq(cli.run(rt, { "hook", "guard" }, "{}").code, 0)
	end
)

Test.test(
	"core hooks read the last handback and surface context flags without trusting output",
	function()
		local rt = fake()
		local part = function(message)
			return rt.encode({
				message = {
					content = {
						{ type = "tool_use", name = "SubagentHandback", input = { message = message } },
					},
				},
			})
		end
		rt.files["/transcript"] = "invalid\n"
			.. part("old")
			.. "\n"
			.. part("Status: done\nValidation\npassed")
		Test.eq(hooks.handback(rt, nil), nil)
		assert(hooks.handback(rt, "/transcript"):find("passed", 1, true))
		rt.env.ORC = "1"
		Test.eq(
			hooks.run(
				rt,
				"subagent-stop",
				rt.encode({ agent_type = "implementer", agent_transcript_path = "/transcript" })
			).out,
			""
		)
		rt.files["/repo/.orc/lessons.md"] = "- [L001] +1 -0 project · feature · Remember\n"
		rt.env.ORC_PAIR, rt.env.REX_SESSION, rt.env.REX_BLOCK, rt.env.ORC_LEVEL = "1", "s", "b", "high"
		route(rt, { ["git status --porcelain"] = result(0, " M file\n") })
		local context = hooks.context(rt)
		assert(
			context:find("Pair mode", 1, true)
				and context:find("High level", 1, true)
				and context:find("Remember", 1, true)
		)
		rt.env.ORC_PAIR, rt.env.ORC_PANES = nil, "1"
		assert(hooks.context(rt):find("Pane mode", 1, true))
		rt.env.REX_BLOCK = nil
		Test.raises("Rex terminal", function()
			hooks.context(rt)
		end)
		with_module("orc.workers", {
			event = function(_, input)
				return { code = 0, out = input.value }
			end,
		}, function()
			Test.eq(hooks.run(rt, "worker-event", '{"value":"received"}').out, "received")
		end)
	end
)

Test.test(
	"core plan parser handles documented fields, comments, quotes and missing sections",
	function()
		local plan =
			"Base branch: feat/x # comment\r\n## Decisions\r\nignored\r\n## Tasks\r\n```yaml\r\n- id: T1\r\n  goal: 'Preserve # content' # comment\r\n  size: substantial\r\n  depends_on: [T0, \"T2\"]\r\n  files: [ignored]\r\n```\r\n## Other\r\n- id: wrong\r\n"
		Test.eq(status.parse_base(plan), "feat/x")
		Test.eq(status.parse_base("nothing"), nil)
		Test.eq(status.parse_tasks(plan), {
			{ id = "T1", goal = "Preserve # content", size = "substantial", dependsOn = { "T0", "T2" } },
		})
		Test.eq(status.parse_tasks("## Tasks\n```yml\n- goal: orphan\n```\n"), {})
		Test.eq(status.parse_tasks("## Other\n```yaml\n- id: wrong\n```\n"), {})
	end
)

Test.test(
	"core status joins worktrees, pair workers, reports, nulls, merges and orphan tasks",
	function()
		local rt = fake()
		rt.files["/repo/.scratch/f/plan.md"] =
			"Base branch: feat/x\n## Tasks\n```yaml\n- id: T1\n  goal: Task\n- id: T2\n```\n"
		rt.files["/repo/.scratch/f/merged"] = "T2 abc123\n"
		rt.files["/repo/.scratch/f/inkdrop.json"] = '{"noteId":"note:test"}'
		rt.files["/repo/task/.orc/report.md"] = "git status: clean\nStatus: done\nValidation\npassed"
		rt.files["/repo/.scratch/no-plan/log.md"] = "ignore"
		route(rt, {
			["wt list --format=json"] = result(
				0,
				rt.encode({
					items = {
						{ branch = "feat/x--T1", worktree = { path = "/repo/task" } },
						{ branch = "feat/x--orphan", worktree = { path = "/repo/orphan" } },
						{ branch = "unrelated", worktree = { path = "/other" } },
					},
				})
			),
		})
		with_module("orc.workers", {
			parse_report = require("orc.workers").parse_report,
			collect = function()
				return { { feature = "f", task = "T2", runId = "run", state = "idle", path = "/repo/pair" } }
			end,
		}, function()
			local snapshot = status.collect(rt)
			Test.eq(#snapshot.features, 1)
			local feature = snapshot.features[1]
			Test.eq(feature.note, "note:test")
			Test.eq(#feature.tasks, 3)
			Test.eq(feature.tasks[1].report, { status = "done" })
			Test.eq(feature.tasks[1].state, "done")
			Test.eq(feature.tasks[2].state, "merged")
			Test.eq(feature.tasks[3].state, "worktree")
			Test.eq(feature.tasks[2].agent, { name = "run", state = "idle" })
			Test.eq(feature.tasks[2].worktree, rt.null)
			Test.eq(feature.tasks[2].merged, { commit = "abc123" })
			Test.eq(feature.tasks[3].goal, rt.null)
			Test.eq(rt.decode(status.run(rt, { "--json" }).out).schemaVersion, 1)
			assert(status.run(rt, {}).out:find("f/T2  merged", 1, true))
		end)
		route(rt, { ["wt list --format=json"] = result(1, "", "offline") })
		assert(#status.collect(rt).warnings == 1)
		Test.eq(cli.run(rt, { "status", "--bad" }).code, 1)
	end
)

Test.test(
	"core status records unique merges, preserves ambiguity and warns on mirror failures",
	function()
		local rt = fake()
		Test.eq(status.record_merge(rt, "feat/x", "T1", "abc"), nil)
		rt.files["/repo/.scratch/f/plan.md"] = "Base branch: feat/x\n"
		Test.eq(status.record_merge(rt, "feat/x", "T1", "abc"), nil)
		Test.eq(rt.files["/repo/.scratch/f/merged"], "T1 abc\n")
		rt.files["/repo/.scratch/f/inkdrop.json"] = "{}"
		with_module("orc.inkdrop", {
			push = function()
				return { code = 1, err = "offline" }
			end,
		}, function()
			assert(status.record_merge(rt, "feat/x", "T2", "def"):find("offline", 1, true))
		end)
		rt.files["/repo/.scratch/g/plan.md"] = "Base branch: feat/x\n"
		assert(status.record_merge(rt, "feat/x", "T3", "ghi"):find("several plans", 1, true))
		assert(not rt.files["/repo/.scratch/f/merged"]:find("T3", 1, true))
	end
)

Test.test(
	"core worktree parser and session creation validate output and preserve user template",
	function()
		local rt = fake()
		Test.eq(wt.branch("feat/x", "T1"), "feat/x--T1")
		Test.raises("invalid task", function()
			wt.branch("feat/x", "../bad")
		end)
		Test.eq(wt.checkout(rt), "/repo")
		wt.ignore(rt)
		assert(rt.files["/repo/.git/info/exclude"]:find(".orc/", 1, true))
		Test.eq(wt.common(rt), "/repo/.git")
		route(
			rt,
			{ ["git rev-parse --path-format=absolute --git-common-dir"] = result(0, "/gitdirs/r\n") }
		)
		Test.eq(wt.root(rt), "/gitdirs")
		wt.ignore(rt)
		assert(rt.files["/gitdirs/r/info/exclude"]:find(".orc/", 1, true))
		route(rt, { ["git rev-parse --path-format=absolute --git-common-dir"] = result(1) })
		Test.eq(wt.common(rt), nil)
		route(rt, {
			["git rev-parse --path-format=absolute --git-common-dir"] = result(0, "/repo/.git\n"),
		})
		route(rt, {
			["git rev-parse --verify --quiet refs/heads/new"] = result(1),
			["wt switch -c new --base main --no-cd --format=json --yes"] = result(0, '{"path":"/new"}'),
			["wt switch existing --no-cd --format=json"] = result(0, '{"path":"/existing"}'),
		})
		Test.eq(wt.session(rt, "new", "main", true).action, "created")
		Test.eq(wt.session(rt, "existing", "ignored").path, "/existing")
		Test.eq(wt.run(rt, { "bad" }).code, 1)
		Test.eq(wt.run(rt, { "session", "existing" }).code, 0)
		Test.eq(wt.run(rt, { "list", "feat/x" }).code, 0)
		Test.eq(wt.run(rt, { "new", "feat/x", "T1" }).code, 1)
		route(rt, { ["wt list --format=json"] = result(0, "{}") })
		Test.raises("no items", function()
			wt.list(rt)
		end)
		route(rt, { ["wt list --format=json"] = result(0, "invalid") })
		Test.raises("", function()
			wt.list(rt)
		end)
	end
)

Test.test(
	"core worktree merge handles conflict before merge and never deletes its worktree",
	function()
		local rt = fake()
		route(rt, {
			["wt list --format=json"] = result(
				0,
				'{"items":[{"branch":"feat--T1","worktree":{"path":"/task"}}]}'
			),
			["git merge-base feat HEAD"] = result(0, "base\n"),
			["git rev-list --count base..HEAD"] = result(0, "1\n"),
			["git merge-tree --write-tree --name-only feat HEAD"] = result(
				1,
				"tree\nconflict.lua\n\nconflict detail"
			),
		})
		local output = wt.run(rt, { "merge", "feat", "T1", "--message", "feat: work" })
		Test.eq(output.code, 2)
		Test.eq(output.result, { status = "conflict", task = "T1", files = { "conflict.lua" } })
		for _, command in ipairs(rt.commands) do
			assert(not table.concat(command.argv, " "):find("wt remove", 1, true))
		end
		Test.eq(wt.run(rt, { "remove", "feat", "missing" }).code, 1)
	end
)

Test.test(
	"core worktree merge commits dirty tasks, cleans accepted work and reports failures",
	function()
		local rt = fake()
		route(rt, {
			["wt list --format=json"] = result(
				0,
				'{"items":[{"branch":"feat--T1","worktree":{"path":"/task"}}]}'
			),
			["git merge-base feat HEAD"] = result(0, "base\n"),
			["git rev-list --count base..HEAD"] = result(0, "2\n"),
			["git status --porcelain"] = result(0, " M file\n"),
			["git rev-parse feat"] = result(0, "commit\n"),
		})
		local merged = wt.run(rt, { "merge", "feat", "T1", "--message=feat: work", "--yes" })
		Test.eq(merged.result, { status = "merged", task = "T1", commit = "commit" })
		Test.eq(wt.run(rt, { "remove", "feat", "T1", "--yes" }).result.status, "removed")
		route(rt, { ["git add -A"] = result(1, "", "write denied") })
		assert(
			wt.run(rt, { "merge", "feat", "T1", "--message=x" }).result.stderr
				:find("write denied", 1, true)
		)
	end
)

Test.test("core doctor reports optional integrations and required failures in schema1", function()
	local rt = fake()
	local doctor = require("orc.doctor")
	rt.files["/plugin/hooks/hooks.json"] = "{}"
	Test.eq(doctor.run(rt, { "--json" }).code, 0)
	Test.eq(rt.decode(doctor.run(rt, { "--json" }).out).schemaVersion, 1)
	assert(doctor.run(rt, {}).out:find("neovim", 1, true))
	route(rt, {
		["git --version"] = result(127, "", "missing git"),
		["claude --version"] = result(127),
		["codex --version"] = result(127),
		["rex version"] = result(127),
	})
	Test.eq(doctor.run(rt, {}).code, 1)
	rt.env.ORC_PANES, rt.env.INKDROP_LOCAL_USERNAME, rt.env.INKDROP_LOCAL_PASSWORD =
		"1", "user", "secret"
	with_module("orc.inkdrop", {
		probe = function()
			return { error = "offline" }
		end,
	}, function()
		Test.eq(doctor.run(rt, {}).code, 1)
	end)
	Test.eq(cli.run(rt, { "doctor", "unexpected" }).code, 1)
end)

Test.test(
	"core update refuses local modifications and only updates installed new marketplaces",
	function()
		local rt = fake()
		route(rt, { ["git status --porcelain"] = result(0, " M local\n") })
		assert(cli.run(rt, { "update" }).err:find("dirty checkout", 1, true))
		route(rt, {
			["git status --porcelain"] = result(),
			["git pull --ff-only"] = result(1, "", "no upstream"),
		})
		Test.eq(cli.run(rt, { "update" }).code, 1)
		route(rt, {
			["git pull --ff-only"] = result(0, "updated\n"),
			["claude plugin marketplace list --json"] = result(0, '[{"name":"orc-nvim"}]'),
			["codex plugin marketplace list --json"] = result(
				0,
				'{"marketplaces":[{"name":"orc-nvim"}]}'
			),
			["claude plugin update orc@orc-nvim"] = result(1, "", "plugin failed"),
		})
		Test.eq(cli.run(rt, { "update" }).code, 1)
		Test.eq(cli.run(rt, { "update", "bad" }).code, 1)
	end
)

Test.test("core Git root helpers distinguish linked worktrees from the main checkout", function()
	local dir = assert(vim.uv.fs_realpath(Test.temp()))
	local rt = runtime.new({ cwd = dir })
	for _, command in ipairs({
		{ "git", "init", "-b", "main" },
		{ "git", "config", "user.name", "test" },
		{ "git", "config", "user.email", "test@example.invalid" },
		{ "git", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "fixture" },
		{ "git", "worktree", "add", "-b", "worker", dir .. "/linked" },
	}) do
		Test.eq(rt.exec(command).code, 0)
	end
	Test.eq(wt.root(rt, dir .. "/linked"), dir)
	Test.eq(wt.checkout(rt, dir .. "/linked"), dir .. "/linked")
	wt.ignore(rt, dir .. "/linked")
	assert(rt.read(dir .. "/.git/info/exclude"):find(".orc/", 1, true))
	local outside = runtime.new({ cwd = "/" })
	Test.eq(wt.root(outside), nil)
	Test.eq(wt.checkout(outside), nil)
end)

Test.test("core CLI entrypoints emit clean machine output and propagate failures", function()
	local rt = runtime.new()
	local previous = {
		argv = arg,
		stdout = io.stdout,
		stderr = io.stderr,
		stdin = io.stdin,
		exit = os.exit,
		path = package.path,
	}
	local out, err, exit = "", "", nil
	io.stdout = {
		write = function(_, text)
			out = out .. text
		end,
		flush = function() end,
	}
	io.stderr = {
		write = function(_, text)
			err = err .. text
		end,
		flush = function() end,
	}
	io.stdin = {
		read = function()
			return "{}"
		end,
	}
	os.exit = function(code)
		exit = code
	end
	local ok, failure = xpcall(function()
		arg = { [0] = rt.path(rt.root, "bin", "orc"), "--version" }
		dofile(arg[0])
		Test.eq(out, "0.1.0\n")
		Test.eq(err, "")
		Test.eq(exit, 0)
		arg = { [0] = rt.path(rt.root, "bin", "orc"), "unknown" }
		dofile(arg[0])
		Test.eq(exit, 1)
		assert(err:find("unknown command", 1, true))
		arg = { [0] = rt.path(rt.root, "bin", "orc"), "hook", "guard" }
		dofile(arg[0])
		Test.eq(exit, 0)
		arg = { [0] = rt.path(rt.root, "scripts", "gen-agents.lua"), "--check" }
		dofile(arg[0])
		Test.eq(exit, 0)
		arg = { [0] = rt.path(rt.root, "scripts", "gen-agents.lua") }
		dofile(arg[0])
		Test.eq(exit, 0)
		arg = { [0] = rt.path(rt.root, "scripts", "gen-agents.lua"), "--unknown" }
		Test.raises("usage", function()
			dofile(arg[0])
		end)
	end, debug.traceback)
	arg, io.stdout, io.stderr, io.stdin, os.exit, package.path =
		previous.argv, previous.stdout, previous.stderr, previous.stdin, previous.exit, previous.path
	assert(ok, failure)
end)

Test.test("core launcher switches session cwd before starting the native harness", function()
	local rt = fake()
	route(rt, { ["wt switch existing --no-cd --format=json"] = result(0, '{"path":"/session"}') })
	Test.eq(cli.run(rt, { "claude", "--wt=existing" }).code, 0)
	Test.eq(rt.launched[1].options.cwd, "/session")
	local source = "---\nname: lone\ndescription: d\n---\nbody"
	Test.eq(generator.render(source, "lone.md"):find("sandbox_mode", 1, true), nil)
	Test.eq(generator.generate(fake(), true).code, 0)
end)

Test.test(
	"core worktree creation, listing and post-merge receipts use canonical task branches",
	function()
		local rt = fake()
		route(rt, {
			['wt --config-set worktree-path=".worktrees/{{ branch | sanitize }}" switch -c feat--T1 --base feat --no-cd --format=json'] = result(
				0,
				'{"path":"/task"}'
			),
			["wt list --format=json"] = result(
				0,
				'{"items":[{"branch":"feat--T1","worktree":{"path":"/task"}},{"branch":"other","worktree":{"path":"/else"}},{"branch":"bare"}]}'
			),
			["git merge-base feat HEAD"] = result(0, "base\n"),
			["git rev-list --count base..HEAD"] = result(0, "0\n"),
			["git rev-parse feat"] = result(0, "sha\n"),
		})
		Test.eq(
			wt.run(rt, { "new", "feat", "T1" }).result,
			{ { task = "T1", branch = "feat--T1", path = "/task" } }
		)
		Test.eq(#wt.run(rt, { "list", "feat" }).result, 1)
		rt.files["/repo/.scratch/feature/plan.md"] = "Base branch: feat\n"
		Test.eq(cli.run(rt, { "wt", "merge", "feat", "T1", "--message=x" }).code, 0)
		Test.eq(rt.files["/repo/.scratch/feature/merged"], "T1 sha\n")
		Test.eq(wt.run(rt, { "list", "feat", "extra" }).code, 1)
		route(rt, {
			["git check-ignore -q .orc/x"] = result(),
			["git check-ignore -q .scratch/x"] = result(),
			["git check-ignore -q .worktrees/x"] = result(),
		})
		local prior = rt.files["/repo/.git/info/exclude"]
		wt.ignore(rt)
		Test.eq(rt.files["/repo/.git/info/exclude"], prior)
	end
)

Test.test("core merge aborts rebase conflicts and retains nonempty cleanup leftovers", function()
	local rt = fake()
	route(rt, {
		["wt list --format=json"] = result(
			0,
			'{"items":[{"branch":"feat--T1","worktree":{"path":"/task"}}]}'
		),
		["git merge-base feat HEAD"] = result(0, "base\n"),
		["git rev-list --count base..HEAD"] = result(0, "1\n"),
		["wt -C /task merge feat --no-commit --no-remove"] = result(1, "", "conflict"),
		["git rev-parse --git-path rebase-merge"] = result(0, ".git/rebase-merge\n"),
		["git diff --name-only --diff-filter=U"] = result(0, "a.lua\nb.lua\n"),
	})
	rt.files["/task/.git/rebase-merge"] = "present"
	local conflict = wt.run(rt, { "merge", "feat", "T1", "--message=x" })
	Test.eq(conflict.result.files, { "a.lua", "b.lua" })
	Test.eq(conflict.code, 2)
	rt.files["/task/.git/rebase-merge"] = nil
	Test.eq(wt.run(rt, { "merge", "feat", "T1", "--message=x" }).code, 1)
	route(rt, {
		["wt -C /task merge feat --no-commit --no-remove"] = result(),
		["git rev-parse feat"] = result(0, "sha\n"),
	})
	rt.files["/task"], rt.files["/task/unrelated"] = "directory", "must retain"
	assert(
		wt.run(rt, { "merge", "feat", "T1", "--message=x" }).result.stderr
			:find("worktree remains", 1, true)
	)
	Test.eq(rt.files["/task/unrelated"], "must retain")
	rt.files["/task/unrelated"] = nil
	Test.eq(wt.run(rt, { "merge", "feat", "T1", "--message=x" }).code, 0)
	Test.eq(rt.files["/task"], nil)
end)

Test.test(
	"core status covers empty plans, orphan-only worktrees and malformed note links",
	function()
		local rt = fake()
		with_module("orc.workers", {
			parse_report = require("orc.workers").parse_report,
			collect = function()
				return {}
			end,
		}, function()
			Test.eq(status.run(rt, {}).out, "no features\n")
			rt.files["/repo/.scratch/empty/plan.md"] = "# No tasks\n"
			Test.eq(status.run(rt, {}).out, "no tasks\n")
			rt.files["/repo/.scratch/empty/inkdrop.json"] = "malformed"
			Test.eq(status.collect(rt).features[1].note, rt.null)
			rt.files["/repo/.scratch/empty/inkdrop.json"] = "null"
			Test.eq(status.collect(rt).features[1].note, rt.null)
			route(rt, {
				["wt list --format=json"] = result(
					0,
					'{"items":[{"branch":"empty--orphan","worktree":{"path":"/orphan"}}]}'
				),
			})
			Test.eq(status.collect(rt).features[1].tasks[1].branch, "empty--orphan")
			assert(status.run(rt, {}).out:find("worktree", 1, true))
			rt.files["/orphan/.orc/report.md"] = "Status: partial\n"
			assert(status.run(rt, {}).out:find("partial", 1, true))
		end)
		Test.eq(
			status.parse_tasks(
				"## Tasks\n```yaml\n  goal: before task\n- id: x # comment\n  depends_on: []\n```"
			)[1].dependsOn,
			{}
		)
		Test.eq(
			status.parse_tasks('## Tasks\n```yaml\n- id: "unterminated\n```')[1].id,
			'"unterminated'
		)
	end
)

Test.test("core hooks cover escaped arguments, safe shells and report fallback shapes", function()
	for _, command in ipairs({
		"echo escaped\\ word",
		"sh",
		"sh -c ''",
		"bash --version",
		"sh -c 'echo safe'",
		"git --version",
		"gh issue list",
		"gh pr view",
		"rex",
		"rex run -- true",
		"orc wt list feature",
	}) do
		local denied = hooks.decide("main", command)
		Test.eq(denied, nil)
	end
	assert(hooks.decide("implementer", "sh -c 'git push; echo after'"))
	local nested = "git status"
	for _ = 1, 7 do
		nested = "sh -c " .. string.format("%q", nested)
	end
	assert(hooks.decide("implementer", nested))
	local rt = fake()
	rt.files["/transcript"] = table.concat({
		"null",
		"{}",
		'{"message":{"content":"text"}}',
		'{"message":{"content":[null,{}, {"type":"tool_use","name":"other"}]}}',
	}, "\n")
	Test.eq(hooks.handback(rt, "/transcript"), nil)
	with_module("orc.inkdrop", {
		flag = function()
			return { id = "book:x", name = "Notebook" }
		end,
	}, function()
		assert(hooks.context(rt):find("Notebook", 1, true))
	end)
end)

Test.test("core doctor probes connected Rex and Inkdrop without exposing credentials", function()
	local rt = fake()
	rt.files["/plugin/hooks/hooks.json"] = "{}"
	rt.env.ORC_PAIR, rt.env.INKDROP_LOCAL_USERNAME, rt.env.INKDROP_LOCAL_PASSWORD =
		"1", "user", "private"
	local rex = require("orc.rex")
	local resolve = rex.resolve
	rex.resolve = function()
		return "rex"
	end
	with_module("orc.inkdrop", {
		probe = function()
			return { version = "6" }
		end,
	}, function()
		local document = require("orc.doctor").collect(rt)
		assert(rt.encode(document):find("connected", 1, true))
		assert(rt.encode(document):find("v6", 1, true))
		assert(not rt.encode(document):find("private", 1, true))
		route(rt, { ["rex whoami --json"] = result(1) })
		Test.eq(require("orc.doctor").run(rt, {}).code, 1)
	end)
	rex.resolve = resolve
end)

Test.test("core update tolerates unavailable or malformed marketplace inventories", function()
	for _, listing in ipairs({
		result(127),
		result(0, "bad JSON"),
		result(0, "null"),
		result(0, "[]"),
		result(0, '[{"name":"unrelated"}]'),
	}) do
		local rt = fake()
		route(rt, {
			["claude plugin marketplace list --json"] = listing,
			["codex plugin marketplace list --json"] = listing,
		})
		Test.eq(cli.run(rt, { "update" }).code, 0)
		for _, command in ipairs(rt.commands) do
			assert(not table.concat(command.argv, " "):find("plugin update", 1, true))
		end
	end
	Test.eq(cli.run(fake(), { "wt", "bad" }).code, 1)
	Test.eq(cli.run(fake(), { "hook", "guard" }).code, 0)
	Test.eq(cli.run(fake(), { "completion" }).code, 1)
	local rt = fake()
	rt.files["/plugin/agents/ignored.txt"] = "ignored"
	Test.eq(cli.run(rt, { "claude", "--level=high" }).code, 0)
	rt.files["/plugin/codex/agents/empty.toml"] = "name = 'empty'"
	Test.eq(cli.run(rt, { "codex" }).code, 0)
end)

Test.test("core merge receipts warn without changing a completed merge's exit status", function()
	local rt = fake()
	local response =
		{ code = 0, out = "merged\n", result = { status = "merged", task = "T1", commit = "sha" } }
	with_module("orc.worktrees", {
		run = function()
			return response
		end,
	}, function()
		with_module("orc.status", {
			record_merge = function()
				return "ambiguous plans"
			end,
		}, function()
			local found = cli.run(rt, { "wt", "merge", "main", "T1", "--message=x" })
			Test.eq(found.code, 0)
			assert(found.err:find("ambiguous plans", 1, true))
		end)
		with_module("orc.status", {
			record_merge = function()
				error("disk failed")
			end,
		}, function()
			Test.eq(cli.run(rt, { "wt", "merge", "main", "T1", "--message=x" }).code, 0)
		end)
	end)
end)

Test.test(
	"core status tolerates malformed note metadata and reports pending and live tasks",
	function()
		local rt = fake()
		rt.files["/repo/.scratch/f/plan.md"] =
			"## Tasks\n```yaml\n- id: T1\n  depends_on: missing-list\n- id: T2\n```\n"
		rt.files["/repo/.scratch/else/log.md"] = "no plan"
		with_module("orc.workers", {
			parse_report = require("orc.workers").parse_report,
			collect = function()
				return { { feature = "f", task = "T2", runId = "run", state = "working", path = "/pair" } }
			end,
		}, function()
			for _, note in ipairs({ "{}", '{"noteId":1}', '{"noteId":"wrong"}' }) do
				rt.files["/repo/.scratch/f/inkdrop.json"] = note
				Test.eq(status.collect(rt).features[1].note, rt.null)
			end
			local text = status.run(rt, {}).out
			assert(text:find("f/T1  pending", 1, true))
			assert(text:find("f/T2  working", 1, true))
			route(rt, { ["wt list --format=json"] = result(1, "", "unavailable") })
			assert(status.run(rt, {}).err:find("unavailable", 1, true))
		end)
		with_module("orc.inkdrop", {
			push = function()
				return { code = 0 }
			end,
		}, function()
			Test.eq(status.record_merge(rt, "f", "T1", "sha"), nil)
		end)
		with_module("orc.inkdrop", {
			push = function()
				return { code = 1, error = "HTTP failed" }
			end,
		}, function()
			assert(status.record_merge(rt, "f", "T1", "sha"):find("HTTP failed", 1, true))
		end)
		with_module("orc.inkdrop", {
			push = function()
				return { code = 1 }
			end,
		}, function()
			assert(status.record_merge(rt, "f", "T1", "sha"):find("unknown error", 1, true))
		end)
		rt.env.ORC_INKDROP = "0"
		Test.eq(status.record_merge(rt, "f", "T1", "sha"), nil)
	end
)

Test.test(
	"core lessons rank by score and denied hooks tolerate unavailable signal storage",
	function()
		local parsed =
			lessons.parse("- [L001] +1 -0 project · f · Lower\n- [L002] +4 -0 orc · f · Higher\n")
		Test.eq(lessons.select(parsed)[1].id, "L002")
		Test.eq(hooks.role(":"), ":")
		local rt = fake()
		rt.env.ORC = "1"
		route(rt, { ["git rev-parse --path-format=absolute --git-common-dir"] = result(128) })
		Test.eq(
			rt.decode(hooks.run(rt, "guard", '{"tool_input":{"command":"git push"}}').out).hookSpecificOutput.permissionDecision,
			"deny"
		)
		rt.files["/transcript"] = "{}"
		Test.eq(hooks.handback(rt, "/transcript"), nil)
		Test.eq(hooks.run(rt, "subagent-stop", '{"agent_type":"reviewer"}').out, "")
		Test.eq(hooks.context(rt), "Fixture rules\n\nCLI: `/plugin/bin/orc`.")
	end
)

Test.test(
	"core worktrees validate references and preserve cwd and quiet error diagnostics",
	function()
		for _, base in ipairs({ "", "-option" }) do
			Test.raises("invalid base", function()
				wt.branch(base, "T")
			end)
		end
		local rt = fake()
		route(rt, {
			["wt list --format=json"] = result(0, '{"items":[{"worktree":{"path":"/orphan"}}]}'),
			["wt switch existing --no-cd --format=json"] = result(0, '{"path":"/session"}'),
		})
		Test.eq(#wt.run(rt, { "list", "base" }).result, 0)
		Test.eq(wt.session(rt, "existing", nil, false, "/explicit").path, "/session")
		Test.eq(wt.list(rt, "/explicit")[1].path, "/orphan")
		Test.raises("needs a branch", function()
			wt.session(rt, nil)
		end)
		route(rt, { ["wt list --format=json"] = result(1, "quiet error", "") })
		Test.raises("quiet error", function()
			wt.list(rt)
		end)
		local source = "---\nname: editor\ndescription: role\ntools: Edit\n---\nbody"
		assert(not generator.render(source, "editor.md"):find("sandbox_mode", 1, true))
		rt.files["/plugin/agents/editor.md"], rt.files["/plugin/codex/agents/readme.txt"] =
			source, "ignore"
		Test.eq(generator.generate(rt).code, 0)
	end
)

Test.test(
	"core doctor enforces minimum Neovim version and accepts future major releases",
	function()
		local rt, original = fake(), vim.version
		local ok, err = xpcall(function()
			vim.version = function()
				return setmetatable({ major = 0, minor = 10 }, {
					__tostring = function()
						return "0.10"
					end,
				})
			end
			Test.eq(require("orc.doctor").collect(rt).checks[1].status, "fail")
			vim.version = function()
				return setmetatable({ major = 1, minor = 0 }, {
					__tostring = function()
						return "1.0"
					end,
				})
			end
			Test.eq(require("orc.doctor").collect(rt).checks[1].status, "pass")
		end, debug.traceback)
		vim.version = original
		assert(ok, err)
	end
)

Test.test("core entrypoints handle absent output and reject extra generator arguments", function()
	local root = runtime.new().root
	local previous = { argv = arg, exit = os.exit }
	os.exit = function() end
	local ok, err = xpcall(function()
		with_module("orc.cli", {
			run = function()
				return { code = 0 }
			end,
		}, function()
			arg = { [0] = root .. "/bin/orc" }
			dofile(arg[0])
		end)
		arg = { [0] = root .. "/scripts/gen-agents.lua", "--check", "extra" }
		Test.raises("usage", function()
			dofile(arg[0])
		end)
	end, debug.traceback)
	arg, os.exit = previous.argv, previous.exit
	assert(ok, err)
end)

Test.test("core merge cleanup preserves files created after worktrunk removal", function()
	local real, rt = runtime.new(), fake()
	local path = real.path(Test.temp(), "task")
	real.mkdir(path)
	rt.exists, rt.rmdir = real.exists, real.rmdir
	rt.list = function()
		error("cleanup must not use a list-then-delete check")
	end
	rt.remove = function()
		error("cleanup must never recursively delete")
	end
	route(rt, {
		["wt list --format=json"] = result(
			0,
			rt.encode({ items = { { branch = "feat--T1", worktree = { path = path } } } })
		),
		["git merge-base feat HEAD"] = result(0, "base\n"),
		["git rev-list --count base..HEAD"] = result(0, "1\n"),
		["git rev-parse feat"] = result(0, "sha\n"),
		["wt remove feat--T1 --foreground -D"] = function()
			real.write(real.path(path, "late-user-work"), "must survive")
			return result()
		end,
	})
	local merged = wt.run(rt, { "merge", "feat", "T1", "--message=x" })
	Test.eq(merged.code, 1)
	assert(merged.result.stderr:find("merged as sha but worktree remains", 1, true))
	Test.eq(real.read(real.path(path, "late-user-work")), "must survive")
end)

Test.test(
	"core hook signals append interleaved events without replacing earlier records",
	function()
		local rt, interleaved = fake(), false
		rt.env.ORC = "1"
		rt.files["/repo/.orc/signals.jsonl"] = '{"existing":true}\n'
		local read = rt.read
		rt.read = function(path)
			assert(path ~= "/repo/.orc/signals.jsonl", "signal writes must not read-modify-replace")
			return read(path)
		end
		rt.append = function(path, line)
			if not interleaved then
				interleaved = true
				hooks.run(
					rt,
					"guard",
					'{"agent_type":"implementer","tool_input":{"command":"git commit -m x"}}'
				)
			end
			rt.files[path] = (rt.files[path] or "") .. line
		end
		local denied = hooks.run(rt, "guard", '{"tool_input":{"command":"git push"}}')
		Test.eq(rt.decode(denied.out).hookSpecificOutput.permissionDecision, "deny")
		local records = {}
		for line in rt.files["/repo/.orc/signals.jsonl"]:gmatch("[^\n]+") do
			records[#records + 1] = rt.decode(line)
		end
		Test.eq(#records, 3)
		Test.eq(records[1], { existing = true })
		Test.eq(records[2].role, "implementer")
		Test.eq(records[3].role, "main")
		rt.append = function()
			error("disk full")
		end
		Test.eq(
			rt.decode(hooks.run(rt, "guard", '{"tool_input":{"command":"git push"}}').out).hookSpecificOutput.permissionDecision,
			"deny"
		)
	end
)

Test.test(
	"core doctor resolves bundled Rex off PATH for both version and session probes",
	function()
		local bundled = "/Applications/Rex Beta.app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex"
		local rt, exepath = fake(), vim.fn.exepath
		rt.env.ORC_PANES = "1"
		rt.files[bundled] = "exists"
		local previous, probes = rt.exec, {}
		rt.exec = function(argv, options)
			assert(argv[1] ~= "rex", "off-PATH Rex must use its resolved executable")
			if argv[1] == bundled then
				probes[#probes + 1] = argv
				return result(0, argv[2] == "version" and "rex fixture\n" or "{}")
			end
			return previous(argv, options)
		end
		vim.fn.exepath = function(name)
			return name == "rex" and "" or exepath(name)
		end
		local ok, err = xpcall(function()
			local document = require("orc.doctor").collect(rt)
			Test.eq(probes, { { bundled, "version" }, { bundled, "whoami", "--json" } })
			local checks = {}
			for _, check in ipairs(document.checks) do
				checks[check.name] = check
			end
			Test.eq(checks.rex.status, "pass")
			Test.eq(checks["rex-session"].status, "pass")
		end, debug.traceback)
		vim.fn.exepath = exepath
		assert(ok, err)
	end
)
