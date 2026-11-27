local M = {}
local line_limit = 1024 * 1024

---@class orc.DiagnoseCost
---@field runs integer
---@field turns integer
---@field toolCalls integer
---@field failedToolCalls integer
---@field inputTokens integer
---@field outputTokens integer
---@field wallSeconds number

---@type orc.DiagnoseCost
local empty_cost = {
	runs = 0,
	turns = 0,
	toolCalls = 0,
	failedToolCalls = 0,
	inputTokens = 0,
	outputTokens = 0,
	wallSeconds = 0,
}

local function new_cost()
	return vim.tbl_extend("force", {}, empty_cost)
end

local function object(value)
	return type(value) == "table" and value or {}
end

local function decode(rt, text)
	local ok, value = pcall(rt.decode, text)
	return ok and type(value) == "table" and value or nil
end

local function timestamp(value)
	if type(value) ~= "string" then
		return nil
	end
	local whole, fraction, offset = value:match("^(%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d)(%.?%d*)(.*)$")
	if not whole or not (offset == "Z" or offset:match("^[+-]%d%d:?%d%d$")) then
		return nil
	end
	local seconds = vim.fn.strptime(
		"%Y-%m-%dT%H:%M:%S%z",
		whole .. (offset == "Z" and "+0000" or offset:gsub(":", ""))
	)
	return seconds ~= 0 and seconds + (tonumber(fraction) or 0) or nil
end

local function scan_lines(rt, path, warnings, visit)
	local stat = vim.uv.fs_stat(path)
	local file = stat and stat.type == "file" and io.open(path, "rb")
	if not file then
		warnings[#warnings + 1] = "cannot read " .. path
		return
	end
	local parts, size, line = {}, 0, 1
	local function finish_line()
		if size > line_limit then
			warnings[#warnings + 1] = path .. ":" .. line .. ": skipped line over 1 MiB"
		elseif size > 0 then
			local value = decode(rt, table.concat(parts))
			if value then
				visit(value, line)
			end
		end
		parts, size, line = {}, 0, line + 1
	end
	while true do
		local chunk, err = file:read(64 * 1024)
		if not chunk then
			if err then
				warnings[#warnings + 1] = "cannot finish reading " .. path
			else
				finish_line()
			end
			break
		end
		local first = 1
		while first <= #chunk do
			local newline = chunk:find("\n", first, true)
			local last = newline and newline - 1 or #chunk
			size = size + last - first + 1
			if size <= line_limit then
				parts[#parts + 1] = chunk:sub(first, last)
			end
			if newline then
				finish_line()
			end
			first = last + (newline and 2 or 1)
		end
	end
	file:close()
end

local function label(value, fallback)
	return type(value) == "string" and value:match("^[%w_.:/+%-]+$") and value or fallback
end

local function token(value)
	return type(value) == "number" and value >= 0 and value < math.huge and math.floor(value) or 0
end

local function usage(cost, value, cumulative)
	local input, output = token(value.input_tokens), token(value.output_tokens)
	cost.inputTokens = (cumulative and 0 or cost.inputTokens) + input
	cost.outputTokens = (cumulative and 0 or cost.outputTokens) + output
end

local function update_window(window, time)
	if time then
		window.first = math.min(window.first or time, time)
		window.last = math.max(window.last or time, time)
	end
end

local function stumble(stumbles, kind, path, line, detail)
	stumbles[#stumbles + 1] = { kind = kind, path = path, line = line, detail = detail }
end

local function hook_text(value, diagnostic)
	if type(value) == "string" then
		if diagnostic then
			return value:find("Hook failed", 1, true) ~= nil
		end
		return value:find("^[ \t]*Hook failed%f[%W]") ~= nil
			or value:find("\n[ \t]*Hook failed%f[%W]") ~= nil
	end
	if type(value) == "table" then
		for _, block in ipairs(value) do
			if type(block) == "table" and hook_text(block.text or block.content, diagnostic) then
				return true
			end
		end
	end
	return false
end

local function prompt_run(value)
	if type(value) == "string" then
		return value:match("^%[orc%-run:([%w_.%-]+)%]")
	end
	for _, block in ipairs(object(value)) do
		local id = prompt_run(object(block).text)
		if id then
			return id
		end
	end
end

local function prompt(state, content)
	local id = prompt_run(content)
	if id then
		state.cost.runs = state.cost.runs + 1
		state.runIds[id] = true
	end
end

local function turn(state, id)
	if not id or id ~= state.turnId then
		state.turnId, state.seen = id, {}
		state.cost.turns = state.cost.turns + 1
	end
end

local function input_key(value)
	if type(value) ~= "table" then
		return vim.json.encode(value)
	end
	local parts = {}
	local keys = vim.tbl_keys(value)
	table.sort(keys)
	for _, key in ipairs(keys) do
		parts[#parts + 1] = vim.json.encode(key) .. ":" .. input_key(value[key])
	end
	return (vim.islist(value) and "[" or "{")
		.. table.concat(parts, ",")
		.. (vim.islist(value) and "]" or "}")
end

local function command_preview(command)
	if type(command) == "table" then
		local words = {}
		for _, word in ipairs(command) do
			if type(word) ~= "string" then
				return ""
			end
			words[#words + 1] = word
		end
		command = table.concat(words, " ")
	end
	if type(command) ~= "string" then
		return ""
	end
	local first = command:match("^[^\r\n]*"):gsub("%c", " ")
	return vim.fn.strcharpart(first, 0, 80)
end

local function shell_command(name, input)
	local leaf = name:match("[^.]+$")
	if leaf == "exec_command" or leaf == "shell_command" or leaf == "shell" or leaf == "Bash" then
		return object(input).cmd or object(input).command
	end
end

local function tool_detail(call, code)
	local detail = call and call.name or "unknown tool"
	if code then
		detail = detail .. " (exit " .. code .. ")"
	end
	if call and call.command ~= "" then
		detail = detail .. " · " .. call.command
	end
	return detail
end

local function tool_call(state, line, id, name, input, command)
	id = type(id) == "string" and id or nil
	if id and state.calls[id] then
		return
	end
	name = label(name, "unknown tool")
	local call = { name = name, command = command_preview(command or shell_command(name, input)) }
	if id then
		state.calls[id] = call
	end
	state.cost.toolCalls = state.cost.toolCalls + 1
	local key = vim.fn.sha256(name .. "\0" .. input_key(input))
	if state.seen[key] then
		state.stumble("repeated-tool", line, tool_detail(call))
	end
	state.seen[key] = true
end

local function tool_failure(state, line, id, code)
	local call = state.calls[id]
	if call then
		if call.failed then
			return
		end
		call.failed = true
	end
	state.cost.failedToolCalls = state.cost.failedToolCalls + 1
	state.stumble("failed-tool", line, tool_detail(call, code))
end

local function exit_code(value)
	if type(value) == "number" and value > -math.huge and value < math.huge and value % 1 == 0 then
		return value
	end
end

local function tool_exit(state, id, value, output)
	local code = exit_code(value) or exit_code(object(output).exit_code)
	local call = state.calls[id]
	if code or not call or call.command == "" then
		return code
	end
	local text = type(output) == "string" and output or object(object(output)[1]).text
	if type(text) ~= "string" then
		return nil
	end
	local header = text:gsub("^Chunk ID:[^\n]*\n", "", 1):gsub("^Wall time:[^\n]*\n", "", 1)
	return exit_code(
		tonumber(
			header:match("^Process exited with code (-?%d+)%f[%D]")
				or header:match("^Exit code:? (-?%d+)%f[%D]")
		)
	)
end

local function command_event(state, item, line, completed)
	local id = label(item.id, nil)
	tool_call(
		state,
		line,
		id,
		"command_execution",
		{ command = item.command, cwd = item.cwd },
		item.command
	)
	local code = exit_code(item.exit_code)
	if completed and code and code ~= 0 then
		tool_failure(state, line, id, code)
	end
	return completed and hook_text(item.aggregated_output)
end

local function codex(rt, state, event, line)
	local payload = object(event.payload)
	local kind = payload.type
	if event.type == "turn_context" or event.type == "session_meta" then
		state.model = label(payload.model, state.model)
	elseif event.type == "event_msg" then
		if kind == "task_started" or kind == "turn_started" then
			state.hasTurnEvents = true
			turn(state, payload.turn_id)
		elseif kind == "token_count" then
			local total = object(payload.info).total_token_usage
			if type(total) == "table" then
				usage(state.cost, total, true)
			end
		elseif kind == "item_completed" and object(payload.item).type == "CommandExecution" then
			return command_event(state, payload.item, line, true)
		elseif kind == "error" or kind == "warning" or kind == "hook_failed" then
			return kind == "hook_failed" or hook_text(payload.message, true)
		end
	elseif event.type == "response_item" then
		if kind == "message" and payload.role == "user" then
			if not state.hasTurnEvents then
				turn(state)
			end
			prompt(state, payload.content)
		elseif kind == "message" and payload.role == "assistant" then
			return hook_text(payload.content)
		elseif kind == "function_call" or kind == "custom_tool_call" then
			local input = payload.arguments or payload.input
			if type(input) == "string" then
				input = decode(rt, input) or input
			end
			tool_call(state, line, payload.call_id, payload.name, input)
		elseif kind == "function_call_output" or kind == "custom_tool_call_output" then
			local code = tool_exit(state, payload.call_id, payload.exit_code, payload.output)
			if code and code ~= 0 then
				tool_failure(state, line, payload.call_id, code)
			end
			return hook_text(payload.output)
		end
	end
	return false
end

local function claude(state, event, line)
	local message = object(event.message)
	if event.type == "assistant" then
		state.model = label(message.model ~= "<synthetic>" and message.model, state.model)
		local id = label(message.id, nil)
		local value = message.usage
		if id and type(value) == "table" and not state.messages[id] then
			state.messages[id] = true
			local cost = state.cost
			usage(cost, value, false)
			cost.inputTokens = cost.inputTokens
				+ token(value.cache_read_input_tokens)
				+ token(value.cache_creation_input_tokens)
		end
		for _, value in ipairs(object(message.content)) do
			local block = object(value)
			if block.type == "tool_use" then
				tool_call(state, line, block.id, block.name, block.input)
			end
		end
		return hook_text(message.content)
	elseif event.type == "user" then
		local result, hook_failed = false, false
		for _, value in ipairs(object(message.content)) do
			local block = object(value)
			if block.type == "tool_result" then
				result = true
				if block.is_error == true then
					local code = tool_exit(state, block.tool_use_id, block.exit_code, block.content)
					tool_failure(state, line, block.tool_use_id, code)
				end
				hook_failed = hook_failed or hook_text(block.content)
			end
		end
		if not result and not event.isMeta and not event.sourceToolUseID then
			turn(state)
			prompt(state, message.content)
		end
		return hook_failed
	elseif event.type == "system" then
		return #object(event.hookErrors) > 0 or hook_text(event.content, true)
	end
	return false
end

local function exec_event(state, event, line)
	state.model = label(event.model, state.model)
	if event.type == "thread.started" then
		state.cost.runs = 1
	elseif event.type == "turn.started" then
		state.cost.runs = 1
		turn(state, event.turn_id)
	elseif event.type == "turn.completed" and type(event.usage) == "table" then
		usage(state.cost, event.usage, false)
	elseif event.type == "item.started" or event.type == "item.completed" then
		local item, completed = object(event.item), event.type == "item.completed"
		if item.type == "command_execution" then
			return command_event(state, item, line, completed)
		elseif item.type == "mcp_tool_call" then
			local name = label(item.server, "mcp") .. "/" .. label(item.tool, "unknown")
			tool_call(state, line, item.id, name, item.arguments)
		elseif item.type == "agent_message" and completed then
			return hook_text(item.text)
		end
	elseif event.type == "error" or event.type == "turn.failed" then
		return hook_text(event.message or object(event.error).message, true)
	end
	return false
end

local function scan(rt, path, source, warnings, stumbles)
	local state = {
		cost = new_cost(),
		window = {},
		model = "unknown",
		runIds = {},
		calls = {},
		seen = {},
		messages = {},
	}
	state.stumble = function(kind, line, detail)
		stumble(stumbles, kind, path, line, detail)
	end
	scan_lines(rt, path, warnings, function(event, line)
		update_window(state.window, timestamp(event.timestamp))
		local hook_failed
		if source == "exec" then
			hook_failed = exec_event(state, event, line)
		elseif source == "claude" then
			hook_failed = claude(state, event, line)
		else
			hook_failed = codex(rt, state, event, line)
		end
		if hook_failed then
			state.stumble("hook-failure", line, "Hook failed")
		end
	end)
	return state
end

local function add_cost(total, cost)
	for key in pairs(empty_cost) do
		total[key] = total[key] + cost[key]
	end
end

local function collect_worker(rt, root, path, record, result, window)
	local task = label(record.task, "unknown")
	local kind = label(record.kind, "unknown")
	local role, level = label(record.role, "implementer"), label(record.level, "default")
	local state, report = label(record.state, "unknown"), label(record.reportStatus, "missing")
	if (state ~= "done" and state ~= "closed") or (report ~= "done" and report ~= "closed") then
		stumble(
			result.stumbles,
			"worker-incomplete",
			path,
			1,
			task .. " · state " .. state .. " · report " .. report
		)
	end
	update_window(window, timestamp(record.createdAt))
	update_window(window, timestamp(record.updatedAt))
	local transcript
	if type(record.transcript) == "string" and record.transcript ~= "" then
		local directory = type(record.path) == "string" and rt.abspath(record.path, root) or root
		transcript =
			scan(rt, rt.abspath(record.transcript, directory), kind, result.warnings, result.stumbles)
	else
		result.warnings[#result.warnings + 1] = "no transcript recorded for " .. path
	end
	local cost = transcript and transcript.cost or new_cost()
	local model = transcript and transcript.model or "unknown"
	local times = transcript and transcript.window or {}
	if kind == "codex" and type(record.path) == "string" then
		local seen = {}
		for _, value in ipairs({ record.previousRunId or false, record.runId or false }) do
			local id = type(value) == "string" and value:match("^[%w_%-]+$")
			if id and not seen[id] then
				seen[id] = true
				local log = rt.path(rt.abspath(record.path, root), ".orc", "runs", id .. ".jsonl")
				if rt.exists(log) and not (transcript and transcript.runIds[id]) then
					local exec = scan(rt, log, "exec", result.warnings, result.stumbles)
					add_cost(cost, exec.cost)
					if exec.model ~= "unknown" and (model == "unknown" or id == record.runId) then
						model = exec.model
					end
					update_window(times, exec.window.first)
					update_window(times, exec.window.last)
				end
			end
		end
	end
	update_window(window, times.first)
	update_window(window, times.last)
	if times.first then
		cost.wallSeconds = times.last - times.first
	end
	result.workers[#result.workers + 1] = vim.tbl_extend(
		"force",
		cost,
		{ task = task, role = role, kind = kind, level = level, model = model }
	)
	for _, group in ipairs({ { result.totals.byRole, role }, { result.totals.byModel, model } }) do
		local totals, name = group[1], group[2]
		local entry = totals[name] or vim.tbl_extend("force", new_cost(), { workers = 0 })
		entry.workers = entry.workers + 1
		add_cost(entry, cost)
		totals[name] = entry
	end
end

local function render(result)
	local format = "%-14s %-11s %-6s %-7s %-14s %4s %5s %5s %6s %7s %7s %8s"
	local lines = {
		"Feature " .. result.feature,
		format:format(
			"Task / total",
			"Role",
			"Kind",
			"Level",
			"Model",
			"Runs",
			"Turns",
			"Calls",
			"Failed",
			"Input",
			"Output",
			"Wall (s)"
		),
	}
	local function row(task, role, kind, level, model, cost)
		lines[#lines + 1] = format:format(
			task,
			role,
			kind,
			level,
			model,
			cost.runs,
			cost.turns,
			cost.toolCalls,
			cost.failedToolCalls,
			cost.inputTokens,
			cost.outputTokens,
			("%.3f"):format(cost.wallSeconds)
		)
	end
	for _, worker in ipairs(result.workers) do
		row(worker.task, worker.role, worker.kind, worker.level, worker.model, worker)
	end
	for _, role in ipairs(vim.fn.sort(vim.tbl_keys(result.totals.byRole))) do
		row("Role total", role, "", "", "", result.totals.byRole[role])
	end
	for _, model in ipairs(vim.fn.sort(vim.tbl_keys(result.totals.byModel))) do
		row("Model total", "", "", "", model, result.totals.byModel[model])
	end
	lines[#lines + 1] = "\nStumbles (" .. #result.stumbles .. ")"
	for _, item in ipairs(result.stumbles) do
		lines[#lines + 1] = ("%s:%d  %s  %s"):format(item.path, item.line, item.kind, item.detail)
	end
	for _, warning in ipairs(result.warnings) do
		lines[#lines + 1] = "Warning: " .. warning
	end
	return table.concat(lines, "\n") .. "\n"
end

---Read a feature's worker evidence and return a cost and stumbles report.
---@param rt orc.Runtime
---@param argv string[] Feature name and optional --json flag.
---@return {code:integer,out:string,err?:string} result CLI status and rendered output.
function M.run(rt, argv)
	local flags, pos = require("orc.args").parse(argv, { json = "boolean" })
	assert(#pos == 1 and pos[1] ~= "", "usage: orc diagnose <feature> [--json]")
	local feature = pos[1]
	local root = assert(require("orc.worktrees").root(rt), "orc diagnose: not a Git repository")
	local result = {
		schemaVersion = 1,
		feature = feature,
		workers = {},
		totals = { byRole = {}, byModel = {} },
		stumbles = {},
		warnings = {},
	}
	local dir, window = rt.path(root, ".orc", "workers"), {}
	for _, name in ipairs(rt.list(dir)) do
		if name:sub(-5) == ".json" then
			local path = rt.path(dir, name)
			local text = rt.read(path)
			local record = text and decode(rt, text)
			if not record then
				result.warnings[#result.warnings + 1] = "invalid or unreadable worker record: " .. path
			elseif record.feature == feature then
				collect_worker(rt, root, path, record, result, window)
			end
		end
	end
	if #result.workers == 0 then
		local lines = { "orc diagnose: no worker records for feature " .. feature }
		vim.list_extend(lines, result.warnings)
		return { code = 1, out = "", err = table.concat(lines, "\n") .. "\n" }
	end
	local signals = rt.path(root, ".orc", "signals.jsonl")
	if window.first and rt.exists(signals) then
		scan_lines(rt, signals, result.warnings, function(event, line)
			local time = timestamp(event.ts)
			if event.kind == "deny" and time and time >= window.first and time <= window.last then
				stumble(
					result.stumbles,
					"guard-deny",
					signals,
					line,
					"guard denied " .. label(event.role, "unknown")
				)
			end
		end)
	end
	return { code = 0, out = flags.json and rt.encode(result) .. "\n" or render(result) }
end

return M
