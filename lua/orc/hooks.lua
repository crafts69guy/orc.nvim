local M = {}
local restricted = { implementer = true, scoper = true, reviewer = true }
-- Read-only roles hand back a report; a background task they started keeps the agent alive.
local foreground = { scoper = true, reviewer = true }

---Normalize plugin-qualified roles; an empty role identifies the main agent.
---@param value? string
---@return string
function M.role(value)
	return type(value) == "string" and value ~= "" and (value:match("([^:]+)$") or value) or "main"
end

local function words(command)
	local segments, tokens, token, quote, escaped = {}, {}, "", nil, false
	local function flush()
		if token ~= "" then
			tokens[#tokens + 1], token = token, ""
		end
	end
	for index = 1, #command do
		local char = command:sub(index, index)
		if escaped then
			token, escaped = token .. char, false
		elseif char == "\\" and quote ~= "'" then
			escaped = true
		elseif quote then
			if char == quote then
				quote = nil
			else
				token = token .. char
			end
		elseif char == '"' or char == "'" then
			quote = char
		elseif char:match("[;&|\n]") then
			flush()
			segments[#segments + 1], tokens = tokens, {}
		elseif char:match("%s") then
			flush()
		else
			token = token .. char
		end
	end
	flush()
	segments[#segments + 1] = tokens
	return segments
end

local function command_kind(tokens, depth)
	if depth > 5 then
		return "wrapped-command"
	end
	local index = 1
	while
		tokens[index]
		and (tokens[index] == "env" or tokens[index] == "command" or tokens[index]:match("^[%w_]+="))
	do
		index = index + 1
	end
	local executable = vim.fs.basename(tokens[index] or "")
	if executable == "sh" or executable == "bash" or executable == "zsh" or executable == "fish" then
		for position = index + 1, #tokens do
			if tokens[position] == "-c" or tokens[position] == "-lc" then
				for _, segment in ipairs(words(tokens[position + 1] or "")) do
					local kind = command_kind(segment, depth + 1)
					if kind then
						return kind
					end
				end
			end
		end
	elseif executable == "git" or executable == "gh" then
		local value_options = {
			["-C"] = true,
			["-c"] = true,
			["--git-dir"] = true,
			["--work-tree"] = true,
			["--namespace"] = true,
			["-R"] = true,
			["--repo"] = true,
		}
		index = index + 1
		while tokens[index] and tokens[index]:sub(1, 1) == "-" do
			index = index + (value_options[tokens[index]] and 2 or 1)
		end
		local verb = tokens[index]
		if executable == "git" and (verb == "commit" or verb == "push") then
			return verb
		elseif executable == "gh" and verb == "pr" then
			local action = tokens[index + 1]
			if action == "create" or action == "merge" or action == "edit" then
				return "pr"
			end
		end
	elseif executable == "rex" then
		for position = index + 1, #tokens do
			if tokens[position] == "--" then
				local nested = command_kind(vim.list_slice(tokens, position + 1), depth + 1)
				if nested then
					return nested
				end
			end
		end
		local readonly =
			{ ls = true, list = true, whoami = true, capture = true, version = true, help = true }
		if not readonly[tokens[index + 1]] then
			return "rex-control"
		end
	elseif executable == "orc" and tokens[index + 1] == "wt" then
		local verb = tokens[index + 2]
		if verb == "merge" or verb == "apply" or verb == "remove" then
			return "commit"
		end
	end
	return nil
end

---Apply workflow role restrictions, including shell and Rex command wrappers.
---@param role string
---@param command? string
---@return string? deny_reason
function M.decide(role, command)
	if type(command) ~= "string" then
		return nil
	end
	for _, segment in ipairs(words(command)) do
		local kind = command_kind(segment, 0)
		if (kind == "push" or kind == "pr") and role ~= "shipper" then
			return "orc: only the shipper role may push or manage pull requests"
		elseif
			restricted[role] and (kind == "commit" or kind == "rex-control" or kind == "wrapped-command")
		then
			return "orc: " .. role .. " must leave Git writes and terminal control to the orchestrator"
		end
	end
	return nil
end

---Check that an implementer supplied a recognized status and a nonempty Validation section.
---@param report? string
---@return boolean
function M.evidence(report)
	if type(report) ~= "string" then
		return false
	end
	local parsed = require("orc.workers").parse_report(report)
	return parsed.status ~= nil and parsed.validation
end

local function signal(rt, kind, role, reason)
	pcall(function()
		local wt = require("orc.worktrees")
		local root = wt.root(rt)
		if root then
			wt.ignore(rt)
			local path = rt.path(root, ".orc", "signals.jsonl")
			rt.append(
				path,
				rt.encode({ ts = rt.now(), kind = kind, role = role, reason = reason }) .. "\n"
			)
		end
	end)
end

---Read the most recent handback report from a JSONL subagent transcript.
---@param rt orc.Runtime
---@param path? string
---@return string?
function M.handback(rt, path)
	if type(path) ~= "string" or path == "" then
		return nil
	end
	local found
	for line in ((rt.read(path) or "") .. "\n"):gmatch("([^\n]*)\n") do
		local ok, record = pcall(rt.decode, line)
		if ok and type(record) == "table" and type(record.message) == "table" then
			for _, part in
				ipairs(type(record.message.content) == "table" and record.message.content or {})
			do
				if
					type(part) == "table"
					and part.type == "tool_use"
					and part.name == "SubagentHandback"
					and type(part.input) == "table"
				then
					found = part.input.message
				end
			end
		end
	end
	return found
end

---Build the common orchestration context for both harnesses.
---Includes only the active ORC_LEVEL routing paragraph (default: Single).
---@param rt orc.Runtime
---@param cwd? string
---@return string
function M.context(rt, cwd)
	local rules = assert(
		rt.read(rt.path(rt.root, "rules", "orchestrator.md")),
		"orc: rules/orchestrator.md is missing"
	)
	local text = { rules, "CLI: `" .. rt.path(rt.root, "bin", "orc") .. "`." }
	local root = require("orc.worktrees").root(rt, cwd)
	if root then
		text[#text + 1] = "Scratch dir: " .. rt.path(root, ".scratch")
		local memory = require("orc.lessons").read(rt, cwd)
		if memory ~= "" then
			text[#text + 1] = "Approved project lessons:\n" .. memory
		end
		local dirty = rt.exec({ "git", "status", "--porcelain" }, { cwd = cwd or rt.cwd })
		if dirty.code == 0 and vim.trim(dirty.stdout) ~= "" then
			text[#text + 1] =
				"Checkout already has uncommitted changes. Preserve work from other sessions; isolate with `orc wt session <branch>` when ownership is uncertain."
		end
		local checkout = require("orc.worktrees").checkout(rt, cwd)
		for _, worker in ipairs(require("orc.workers").collect(rt, cwd)) do
			local own_pair = rt.env.ORC_PAIR == "1" and worker.sessionId == rt.env.REX_SESSION
			local active = worker.role ~= "scoper"
				and worker.state ~= "closed"
				and worker.state ~= "exited"
				and worker.state ~= "error"
			if
				active
				and worker.path == checkout
				and worker.blockId ~= rt.env.REX_BLOCK
				and not own_pair
			then
				text[#text + 1] = "Another worker owns this checkout ("
					.. worker.task
					.. ", "
					.. worker.blockId
					.. "). Isolate with `orc wt session <branch>` before editing."
			end
		end
	end
	if rt.env.ORC_PAIR == "1" or rt.env.ORC_PANES == "1" then
		assert(rt.env.REX_SESSION and rt.env.REX_BLOCK, "orc: pair/pane mode needs a Rex terminal")
		text[#text + 1] = rt.env.ORC_PAIR == "1"
				and "Pair mode: use one Codex worker with `orc pane start <feature> <task> --here --path <checkout> --brief <file> --kind codex`; do not write beside the worker."
			or table.concat({
				"Pane mode (automatic in Rex): delegate scopers and implementers through `orc pane start <feature> <task> --path <checkout> --brief <file> --role scoper|implementer` workers (Codex by default), rather than native subagents.",
				"Use cross-vendor review per the orchestrator rules; shipper stays native. For a single task add `--here` in the session checkout; the orchestrator must not edit beside the implementer.",
				"For parallel tasks use dispatch worktrees. Run `orc pane wait` with the harness's background execution.",
			}, "\n")
	end
	if rt.env.ORC_LEVEL == "high" then
		text[#text + 1] =
			"Level high (Cascade): run deterministic checks first; after a review round fails, escalate instead of retrying the same tier: switch the worker to the other --kind or a stronger Claude model, and record why."
	elseif rt.env.ORC_LEVEL == "max" then
		text[#text + 1] =
			"Level max (Critique): run deterministic checks first; every substantial diff gets two independent reviews in parallel from different vendors; merge findings into one follow-up for the same implementer."
	else
		text[#text + 1] =
			"Level default (Single): one implementer per task; run deterministic checks first; use the reviewer only for risky diffs (security, concurrency, migrations, public APIs)."
	end
	local flag = require("orc.inkdrop").flag(rt, cwd)
	if flag then
		text[#text + 1] = "Inkdrop notebook: "
			.. flag.name
			.. " ("
			.. flag.id
			.. "). Use `orc inkdrop` for feature notes."
	end
	return table.concat(text, "\n\n")
end

---Execute a lifecycle hook. Bad JSON is ignored rather than crashing the harness.
---@param rt orc.Runtime
---@param event string
---@param input string JSON input from the harness.
---@return table
function M.run(rt, event, input)
	if rt.env.ORC ~= "1" then
		return { code = 0, out = "" }
	end
	local ok, payload = pcall(rt.decode, input)
	if not ok or type(payload) ~= "table" then
		return { code = 0, out = "" }
	end
	if event == "worker-event" then
		return require("orc.workers").event(rt, payload)
	end
	local role = restricted[rt.env.ORC_ROLE] and rt.env.ORC_ROLE or M.role(payload.agent_type)
	local output
	if event == "session-start" and (not rt.env.ORC_ROLE or rt.env.ORC_ROLE == "") then
		output =
			{ hookSpecificOutput = { hookEventName = "SessionStart", additionalContext = M.context(rt) } }
	elseif event == "guard" then
		local tool = payload.tool_input or {}
		local reason = M.decide(role, tool.command or tool.cmd)
		if not reason and foreground[role] and tool.run_in_background then
			reason = "orc: "
				.. role
				.. " must not start background commands; run it in the foreground or name it for the orchestrator"
		end
		if reason then
			signal(rt, "deny", role, reason)
			output = {
				hookSpecificOutput = {
					hookEventName = "PreToolUse",
					permissionDecision = "deny",
					permissionDecisionReason = reason,
				},
			}
		end
	elseif event == "subagent-stop" and role == "implementer" and not payload.stop_hook_active then
		if
			not M.evidence(payload.last_assistant_message)
			and not M.evidence(M.handback(rt, payload.agent_transcript_path))
		then
			local reason =
				"orc: report Status: done|partial|blocked and a Validation section with commands and results"
			signal(rt, "no-evidence", role, reason)
			output = { decision = "block", reason = reason }
		end
	end
	return { code = 0, out = output and rt.encode(output) .. "\n" or "" }
end

return M
