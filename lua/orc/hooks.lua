local M = {}
local restricted = { implementer = true, scoper = true, reviewer = true, ["comment-sicko"] = true }
-- Report-only roles hand back a report; a background task they started keeps the agent alive.
local foreground = { scoper = true, reviewer = true, ["comment-sicko"] = true }

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
		elseif char:match("[;&|()\n]") then
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
		local first_kind
		for position = index + 1, #tokens do
			if tokens[position]:match("^%-%a*c%a*$") then
				for _, segment in ipairs(words(tokens[position + 1] or "")) do
					local kind = command_kind(segment, depth + 1)
					if kind == "push" or kind == "pr" then
						return kind
					end
					first_kind = first_kind or kind
				end
			end
		end
		return first_kind
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
		elseif executable == "git" and verb == "stash" then
			local action = tokens[index + 1]
			if action ~= "list" and action ~= "show" then
				return "stash"
			end
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
		local rename = tokens[index + 1] == "session"
			and tokens[index + 2] == "rename"
			and #tokens == index + 3
			and tokens[index + 3]:sub(1, 1) ~= "-"
		if not readonly[tokens[index + 1]] and not rename then
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
		elseif kind == "stash" and restricted[role] then
			return "orc: git stash is shared by every worktree; copy files aside and use git checkout HEAD -- <file> instead"
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

---@class orc.OrchestratorRuleSource
---@field path string Absolute path under the active Orc runtime root.
---@field version string Version reported by that runtime's CLI.
---@field sha256? string SHA-256 of the rule contents, when readable.

---Read the startup rule and describe the source used by this Orc runtime.
---@param rt orc.Runtime
---@return orc.OrchestratorRuleSource source
---@return string? rules
---@return string? read_error
function M.rule_source(rt)
	local version = require("orc.cli").version
	assert(type(version) == "string" and version ~= "", "Orc CLI version is unavailable")
	---@type orc.OrchestratorRuleSource
	local source = { path = rt.path(rt.root, "rules", "orchestrator.md"), version = version }
	local ok, rules, err = pcall(rt.read, source.path)
	if not ok or not rules then
		return source, nil, tostring(ok and (err or "file is missing") or rules)
	end
	source.sha256 = vim.fn.sha256(rules)
	return source, rules
end

---Format the provenance shared by the static audit and fresh session context.
---@param source orc.OrchestratorRuleSource
---@return string
function M.format_rule_source(source)
	return string.format(
		"Orc runtime orchestrator rule: `%s` (CLI version `%s`, SHA-256 `%s`).",
		source.path,
		source.version,
		source.sha256 or "unavailable"
	)
end

---Build the common orchestration context for both harnesses with runtime provenance.
---Includes only the active ORC_LEVEL routing paragraph (default: Single).
---Resolves the delegated guide path without reading the guide.
---Uses recorded worker ownership without querying Rex.
---Recommends fast-check when a readable root package.json does not list it.
---@param rt orc.Runtime
---@param cwd? string
---@return string
function M.context(rt, cwd)
	local source, rules, err = M.rule_source(rt)
	assert(rules, source.path .. ": " .. tostring(err))
	local text = {
		rules,
		"CLI: `" .. rt.path(rt.root, "bin", "orc") .. "`.",
		M.format_rule_source(source),
		"Delegated workflow guide: `" .. rt.path(rt.root, "rules", "delegated-workflow.md") .. "`.",
	}
	local root = require("orc.worktrees").root(rt, cwd)
	if root then
		text[#text + 1] = "Scratch dir: " .. rt.path(root, ".scratch")
		local ok, manifest = pcall(rt.read, rt.path(root, "package.json"))
		if
			ok
			and manifest
			and not manifest:find('"fast-check"', 1, true)
			and not manifest:find('"@fast-check/', 1, true)
		then
			text[#text + 1] =
				"Root package.json does not list fast-check. When a task adds JS or TS tests, recommend once that the user add `fast-check` (with `@fast-check/vitest` or `@fast-check/jest` for the test runner) as a devDependency. Install only with their approval."
		end
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
		local own_session = rt.env.ORC_PAIR == "1"
			and (rt.env.REX_SESSION or "") ~= ""
			and rt.env.REX_SESSION
		local workers = require("orc.workers")
		for _, worker in ipairs(workers.collect(rt, cwd, { durable_only = true })) do
			local own_pair = own_session and worker.sessionId == own_session
			if
				workers.owns_checkout(worker)
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
		assert((rt.env.REX_BLOCK or "") ~= "", "orc: pair/pane mode needs a Rex terminal")
		text[#text + 1] = rt.env.ORC_PAIR == "1"
				and "Pair mode uses one Codex implementer in the selected checkout."
			or "Pane mode delegates scoping and implementation in Rex."
	end
	if rt.env.ORC_LEVEL == "high" then
		text[#text + 1] =
			"Level high (Cascade) requires deterministic checks first. Escalate after a failed review round."
	elseif rt.env.ORC_LEVEL == "max" then
		text[#text + 1] =
			"Level max (Critique) requires deterministic checks first. Give every substantial diff two independent reviews in parallel. Prefer different vendors when available. Merge findings into one follow-up for the same implementer."
	else
		text[#text + 1] =
			"Level default (Single) uses one implementer per task. Run deterministic checks first. Use independent review for risky diffs (security, concurrency, migrations, public APIs, fund safety). Prefer cross-vendor review and follow the delegated guide for fallback."
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

local function token_number(value)
	return type(value) == "number" and value >= 0 and value < math.huge
end

local function context_warning(rt, payload)
	if (rt.env.ORC_ROLE and rt.env.ORC_ROLE ~= "") or rt.env.ORC_CONTEXT_WARN == "0" then
		return nil
	end
	local threshold = tonumber(rt.env.ORC_CONTEXT_WARN)
	if not token_number(threshold) or threshold == 0 then
		threshold = 200000
	end
	local path = payload.transcript_path
	if type(path) ~= "string" or path == "" then
		return nil
	end
	local tokens
	for line in ((rt.tail(path, 512 * 1024) or "") .. "\n"):gmatch("([^\n]+)\n") do
		local ok, record = pcall(rt.decode, line)
		if ok and type(record) == "table" and record.isSidechain ~= true then
			local usage
			if type(record.message) == "table" then
				usage = record.message.usage
			end
			if usage ~= nil then
				tokens = nil
				if type(usage) == "table" then
					local input = usage.input_tokens
					local read = usage.cache_read_input_tokens or 0
					local creation = usage.cache_creation_input_tokens or 0
					if token_number(input) and token_number(read) and token_number(creation) then
						tokens = input + read + creation
					end
				end
			elseif record.type == "event_msg" and type(record.payload) == "table" then
				local event = record.payload
				if event.type == "token_count" and type(event.info) == "table" then
					local last = event.info.last_token_usage
					tokens = type(last) == "table" and last.input_tokens or nil
				end
			end
		end
	end
	if not token_number(tokens) or tokens < threshold then
		return nil
	end
	return {
		systemMessage = string.format(
			"orc: context ~%.0fk tokens (warn at %.0fk). Log progress, then /clear at the next task boundary.",
			tokens / 1000,
			threshold / 1000
		),
		hookSpecificOutput = {
			hookEventName = "UserPromptSubmit",
			additionalContext = table.concat({
				"At the next task boundary (current T accepted, its pane closed), write outcome, open decisions and the next step to .scratch/<feature>/log.md.",
				"Then tell the user to run /clear (SessionStart re-injects orc rules) and resume from the plan and log.",
				"Mid-task, prefer /compact <focus>.",
			}, "\n"),
		},
	}
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
	if event == "context" then
		output = context_warning(rt, payload)
	elseif event == "session-start" and (not rt.env.ORC_ROLE or rt.env.ORC_ROLE == "") then
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
