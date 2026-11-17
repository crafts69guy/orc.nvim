local hooks = require("orc.hooks")
local runtime = require("orc.runtime")

local function fixture()
	local rt = runtime.new()
	rt.env = { ORC = "1" }
	rt.transcript = ""
	rt.read = function()
		error("context must not read the whole transcript")
	end
	rt.tail = function(path, bytes)
		Test.eq(path, "/transcript")
		Test.eq(bytes, 512 * 1024)
		return rt.transcript
	end
	local function run(payload)
		return hooks.run(rt, "context", rt.encode(payload or { transcript_path = "/transcript" }))
	end
	local function usage(input, read, creation, sidechain)
		return rt.encode({
			isSidechain = sidechain,
			message = {
				usage = {
					input_tokens = input,
					cache_read_input_tokens = read,
					cache_creation_input_tokens = creation,
				},
			},
		})
	end
	return rt, run, usage
end

Test.test("context warning uses latest main-thread usage including both caches", function()
	local rt, run, usage = fixture()
	rt.transcript = usage(199999)
	Test.eq(run(), { code = 0, out = "" })
	rt.transcript = usage(200000)
	local warning = rt.decode(run().out)
	assert(warning.systemMessage:find("~200k tokens (warn at 200k)", 1, true))
	Test.eq(warning.hookSpecificOutput.hookEventName, "UserPromptSubmit")
	local context = warning.hookSpecificOutput.additionalContext
	assert(context:find(".scratch/<feature>/log.md", 1, true))
	assert(context:find("current T accepted, its pane closed", 1, true))
	assert(context:find("/clear", 1, true))
	assert(context:find("/compact <focus>", 1, true))
	Test.eq(select(2, context:gsub("\n", "")), 2)
	rt.transcript = usage(10000, 500000, 4000) .. "\n" .. usage(1, 0, 0, true)
	assert(rt.decode(run().out).systemMessage:find("~514k", 1, true))
	rt.transcript = rt.transcript .. "\n{}\ninvalid"
	assert(run().out ~= "")
	rt.transcript = rt.transcript .. "\n{}\ninvalid\n" .. usage(5)
	Test.eq(run().out, "")
	for _, role in ipairs({ "implementer", "scoper", "reviewer", "shipper" }) do
		rt.env.ORC_ROLE, rt.transcript = role, usage(300000)
		Test.eq(run().out, "")
	end
	rt.env.ORC_ROLE = ""
	warning = rt.decode(run().out)
	assert(warning.systemMessage:find("~300k tokens (warn at 200k)", 1, true))
	Test.eq(warning.hookSpecificOutput.hookEventName, "UserPromptSubmit")
	assert(warning.hookSpecificOutput.additionalContext:find("/clear", 1, true))
	rt.env.ORC_ROLE = nil
	rt.env.ORC = "0"
	Test.eq(run().out, "")
end)

Test.test("context warning thresholds and unusable transcripts fail quietly", function()
	local rt, run, usage = fixture()
	rt.transcript = usage(300000)
	rt.env.ORC_CONTEXT_WARN = "0"
	Test.eq(run().out, "")
	rt.env.ORC_CONTEXT_WARN, rt.transcript = "42", usage(42)
	assert(run().out ~= "")
	rt.transcript = usage(41)
	Test.eq(run().out, "")
	for _, value in ipairs({ "bad", "-1", "inf", "nan", "0.0", "" }) do
		rt.env.ORC_CONTEXT_WARN, rt.transcript = value, usage(200000)
		assert(run().out ~= "", value)
		rt.transcript = usage(199999)
		Test.eq(run().out, "")
	end
	for _, payload in ipairs({ {}, { transcript_path = "" }, { transcript_path = false } }) do
		Test.eq(run(payload).out, "")
	end
	for _, data in ipairs({
		"garbage\nnull\n42\n{}",
		usage(300000) .. '\n{"message":{"usage":false}}',
		'{"message":{"usage":{"input_tokens":"300000"}}}',
		usage(-1),
		usage(300000, "bad"),
		usage(300000, 0, -1),
		'{"message":{"usage":{}}}',
	}) do
		rt.transcript = data
		Test.eq(run(), { code = 0, out = "" })
	end
	rt.transcript = nil
	Test.eq(run().out, "")
end)

Test.test("context warning accepts verified Codex rollout last input usage", function()
	local rt, run = fixture()
	local function event(info, kind)
		return rt.encode({ type = "event_msg", payload = { type = kind or "token_count", info = info } })
	end
	rt.transcript =
		event({ last_token_usage = { input_tokens = 250000, cached_input_tokens = 50000 } })
	assert(rt.decode(run().out).systemMessage:find("~250k", 1, true))
	rt.transcript = rt.transcript .. "\n" .. event({ last_token_usage = { input_tokens = 12 } })
	Test.eq(run().out, "")
	for _, data in ipairs({
		event({ total_token_usage = { input_tokens = 900000 } }),
		event(false),
		event({}, "other"),
		event({ last_token_usage = false }),
		event({ last_token_usage = { input_tokens = "900000" } }),
		'{"type":"event_msg","payload":false}',
	}) do
		rt.transcript = data
		Test.eq(run().out, "")
	end
end)

Test.test("context warning reads only a bounded tail of large real files", function()
	local rt, dir = runtime.new(), Test.temp()
	rt.env = { ORC = "1" }
	local path = rt.path(dir, "large.jsonl")
	local usage = rt.encode({ message = { usage = { input_tokens = 300000 } } })
	rt.write(path, usage .. "\n" .. string.rep("x", 1024 * 1024) .. "\n{}\n")
	Test.eq(hooks.run(rt, "context", rt.encode({ transcript_path = path })).out, "")
	rt.write(path, string.rep("x", 1024 * 1024) .. "\n" .. usage .. "\n")
	assert(#assert(rt.tail(path, 512 * 1024)) < 512 * 1024)
	assert(hooks.run(rt, "context", rt.encode({ transcript_path = path })).out ~= "")
	Test.eq(hooks.run(rt, "context", rt.encode({ transcript_path = dir .. "/missing" })).out, "")
	Test.eq(hooks.run(rt, "context", rt.encode({ transcript_path = dir })).out, "")
end)

Test.test("context hook registration preserves worker event hook", function()
	local rt = runtime.new()
	local entries =
		rt.decode((assert(rt.read(rt.path(rt.root, "hooks/hooks.json"))))).hooks.UserPromptSubmit
	local commands = entries[1].hooks
	Test.eq(#commands, 2)
	Test.eq(commands[1].command, '"${CLAUDE_PLUGIN_ROOT}/bin/orc" hook worker-event')
	Test.eq(commands[2], {
		type = "command",
		command = '"${CLAUDE_PLUGIN_ROOT}/bin/orc" hook context',
		timeout = 5,
	})
end)
