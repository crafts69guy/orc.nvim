local M = {}

local function limited(message)
	local text = message:lower():gsub("[_%-]", " ")
	return text:find("rate limit", 1, true) ~= nil
		or text:find("usage limit", 1, true) ~= nil
		or text:find("quota", 1, true) ~= nil
		or text:find("too many requests", 1, true) ~= nil
		or text:match("%f[%d]429%f[%D]") ~= nil
end

local function output(text)
	io.stdout:write(text)
	io.stdout:flush()
end

local function status(state)
	output("\27]7501;state=" .. state .. ":app=orc\27\\")
end

---Stream a Codex exec child into a raw JSONL file and short, control-safe pane messages.
---No stdin or approval replies are sent. Hook acknowledgement/report validation stays in workers.
---@param rt orc.Runtime
---@param launch orc.LaunchSpec
---@param log string Run-specific JSONL path.
---@param update fun(fields:table) Persist metadata using the worker state lock.
---@return table result Exit code, empty stdout, and child/runner diagnostics.
function M.run(rt, launch, log, update)
	local fd
	local pending, failure, completed, handle = "", nil, nil, nil
	local rate_limited = false
	local function event(line)
		local ok, value = pcall(rt.decode, line)
		assert(
			ok and type(value) == "table" and type(value.type) == "string",
			"orc worker: invalid JSONL event"
		)
		local kind, summary = value.type, nil
		if kind == "thread.started" then
			assert(type(value.thread_id) == "string", "orc worker: missing thread ID")
			update({ threadId = value.thread_id })
			summary = "thread started"
		elseif kind == "turn.started" then
			summary = "turn started"
		elseif kind == "turn.completed" then
			assert(type(value.usage) == "table", "orc worker: missing turn usage")
			update({ usage = value.usage })
			summary = "turn completed"
		elseif kind == "error" or kind == "turn.failed" then
			local message = value.message
			if kind == "turn.failed" then
				message = type(value.error) == "table" and value.error.message
			end
			assert(type(message) == "string", "orc worker: missing error message")
			if limited(message) then
				rate_limited = true
				update({ rateLimited = true })
			end
			summary = kind .. ": " .. message
		elseif kind == "item.started" or kind == "item.completed" then
			assert(
				type(value.item) == "table" and type(value.item.type) == "string",
				"orc worker: missing item type"
			)
			summary = kind .. ": " .. value.item.type
		end
		if summary then
			output("orc: " .. summary:gsub("[%z\1-\31\127-\159]", " "):sub(1, 180) .. "\n")
		end
	end
	status("working")
	local ok, err = pcall(function()
		rt.mkdir(vim.fs.dirname(log))
		fd = assert(vim.uv.fs_open(log, "w", 384))
		handle = rt.stream(launch.argv, {
			cwd = launch.cwd,
			env = launch.env,
			on_exit = function(result)
				completed = result
			end,
		}, function(chunk)
			local accepted, reason = pcall(function()
				local written = assert(vim.uv.fs_write(fd, chunk, -1))
				assert(written == #chunk, "orc worker: incomplete JSONL write")
				if failure then
					return
				end
				pending = pending .. chunk
				while true do
					local newline = pending:find("\n", 1, true)
					if not newline then
						break
					end
					local line = pending:sub(1, newline - 1)
					pending = pending:sub(newline + 1)
					event(line)
				end
			end)
			if not accepted then
				failure = tostring(reason)
			end
		end)
		while not completed do
			if failure then
				handle.stop()
			end
			rt.sleep(10)
		end
		assert(not failure, failure)
		if pending ~= "" then
			event(pending)
		end
	end)
	if fd then
		vim.uv.fs_close(fd)
	end
	local code = 1
	local diagnostics = ""
	if completed then
		code, diagnostics = completed.code, completed.stderr
		if completed.signal ~= 0 then
			code = 128 + completed.signal
		end
	end
	if not ok then
		diagnostics = diagnostics .. tostring(err) .. "\n"
		if code == 0 then
			code = 1
		end
	end
	rate_limited = rate_limited or limited(diagnostics)
	local saved, save_error =
		pcall(update, { exitCode = code, execFinished = true, rateLimited = rate_limited })
	if not saved then
		code = 1
		diagnostics = diagnostics .. tostring(save_error) .. "\n"
	end
	status(code == 0 and not rate_limited and "done" or "error")
	return { code = code, out = "", err = diagnostics }
end

return M
