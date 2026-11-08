local runner = require("orc.exec_worker")
local runtime = require("orc.runtime")

local function fixture(fn)
	local rt = runtime.new({ cwd = Test.temp() })
	local state =
		{ output = "", fields = {}, chunks = {}, code = 0, signal = 0, stderr = "", stops = 0 }
	state.log = rt.path(rt.cwd, ".orc", "runs", "abc.jsonl")
	local launch = {
		argv = { "codex", "--no-daemon", "exec", "--json", "prompt" },
		cwd = rt.cwd,
		env = { SECRET = false },
	}
	rt.stream = function(argv, opts, on_data)
		Test.eq(argv, launch.argv)
		Test.eq(opts.cwd, launch.cwd)
		Test.eq(opts.env, launch.env)
		Test.eq(opts.stdin, nil)
		if state.spawnError then
			error("spawn failed")
		end
		for _, chunk in ipairs(state.chunks) do
			on_data(chunk)
		end
		state.finish = function()
			opts.on_exit({ code = state.code, signal = state.signal, stdout = "", stderr = state.stderr })
		end
		return {
			stop = function()
				state.stops = state.stops + 1
			end,
		}
	end
	rt.sleep = function(ms)
		Test.eq(ms, 10)
		state.finish()
	end
	function state.run()
		return runner.run(rt, launch, state.log, function(fields)
			if state.updateError then
				error("record changed")
			end
			state.fields = vim.tbl_extend("force", state.fields, fields)
		end)
	end
	local stdout = io.stdout
	io.stdout = {
		write = function(_, text)
			state.output = state.output .. text
		end,
		flush = function() end,
	}
	local ok, err = xpcall(function()
		fn(rt, state)
	end, debug.traceback)
	io.stdout = stdout
	assert(ok, err)
end

Test.test(
	"exec runner tees fragmented and large JSONL verbatim, captures usage and emits OSC",
	function()
		fixture(function(rt, state)
			local usage = {
				input_tokens = 100,
				cached_input_tokens = 80,
				cache_write_input_tokens = 2,
				output_tokens = 9,
				reasoning_output_tokens = 3,
			}
			local lines = {
				rt.encode({ type = "thread.started", thread_id = "thread-abc" }),
				rt.encode({ type = "turn.started" }),
				rt.encode({ type = "item.started", item = { type = "command_execution" } }),
				rt.encode({
					type = "item.updated",
					item = { type = "command_execution", aggregated_output = string.rep("x", 12000) },
				}),
				rt.encode({
					type = "item.completed",
					item = { type = "agent_message", text = "final report" },
				}),
				rt.encode({ type = "future.event" }),
				rt.encode({ type = "turn.completed", usage = usage }),
			}
			local raw = table.concat(lines, "\n")
			state.chunks = { raw:sub(1, 9), raw:sub(10, 100), raw:sub(101) }
			Test.eq(state.run(), { code = 0, out = "", err = "" })
			Test.eq(rt.read(state.log), raw)
			Test.eq(vim.uv.fs_stat(state.log).mode % 512, 384)
			Test.eq(state.fields, {
				threadId = "thread-abc",
				usage = usage,
				exitCode = 0,
				execFinished = true,
				rateLimited = false,
			})
			Test.eq(
				state.output,
				"\27]7501;state=working:app=orc\27\\orc: thread started\norc: turn started\norc: item.started: command_execution\norc: item.completed: agent_message\norc: turn completed\n\27]7501;state=done:app=orc\27\\"
			)
		end)
	end
)

Test.test(
	"exec runner detects limit events and stderr while propagating exits and signals",
	function()
		for _, message in ipairs({
			"Rate limit reached",
			"usage_limit_reached",
			"insufficient-quota",
			"Too many requests",
			"HTTP 429",
		}) do
			for _, source in ipairs({ "error", "turn.failed", "stderr" }) do
				fixture(function(rt, state)
					state.code = 7
					if source == "stderr" then
						state.stderr = message
					elseif source == "error" then
						state.chunks = { rt.encode({ type = source, message = message }) .. "\n" }
					else
						state.chunks = { rt.encode({ type = source, error = { message = message } }) .. "\n" }
					end
					Test.eq(state.run().code, 7)
					Test.eq(state.fields.rateLimited, true)
					Test.eq(state.fields.exitCode, 7)
					assert(state.output:find("\27]7501;state=error:app=orc\27\\", 1, true))
				end)
			end
		end
		fixture(function(_, state)
			state.code, state.stderr = 127, "executable missing: 1429"
			Test.eq(state.run().err, state.stderr)
			Test.eq(state.fields.rateLimited, false)
			Test.eq(state.fields.exitCode, 127)
		end)
		fixture(function(_, state)
			state.signal = 15
			Test.eq(state.run().code, 143)
			Test.eq(state.fields.exitCode, 143)
		end)
		fixture(function(rt, state)
			state.chunks = { rt.encode({ type = "error", message = "usage limit reached" }) .. "\n" }
			Test.eq(state.run().code, 0)
			Test.eq(state.fields.rateLimited, true)
			assert(state.output:find("\27]7501;state=error:app=orc\27\\", 1, true))
		end)
	end
)

Test.test(
	"exec runner prints bounded safe errors and does not classify normal errors as limits",
	function()
		fixture(function(rt, state)
			state.code = 1
			state.chunks = {
				rt.encode({
					type = "error",
					message = "Invalid credentials\27]7501;state=done\7\n" .. string.rep("x", 300),
				}) .. "\n",
				rt.encode({ type = "turn.failed", error = { message = "unauthorized" } }) .. "\n",
			}
			Test.eq(state.run().code, 1)
			Test.eq(state.fields.rateLimited, false)
			assert(state.output:find("orc: error: Invalid credentials ]7501;state=done", 1, true))
			assert(not state.output:find(string.rep("x", 180), 1, true))
		end)
	end
)

Test.test(
	"exec runner skips malformed events without stopping the child or losing raw evidence",
	function()
		for _, line in ipairs({
			"invalid",
			"[]",
			"null",
			"{}",
			'{"type":3}',
			'{"type":"thread.started"}',
			'{"type":"turn.completed"}',
			'{"type":"error"}',
			'{"type":"error","error":{"message":"x"}}',
			'{"type":"turn.failed","error":"bad"}',
			'{"type":"turn.failed","error":{}}',
			'{"type":"item.started"}',
			'{"type":"item.completed","item":{}}',
		}) do
			for _, code in ipairs({ 0, 7 }) do
				fixture(function(rt, state)
					state.code = code
					local usage = { input_tokens = 10, output_tokens = 2 }
					local valid = table.concat({
						rt.encode({ type = "thread.started", thread_id = "thread-abc" }),
						rt.encode({ type = "turn.completed", usage = usage }),
					}, "\n")
					state.chunks = { line .. "\n", valid .. "\n", line }
					Test.eq(state.run(), { code = code, out = "", err = "" })
					Test.eq(state.stops, 0)
					Test.eq(rt.read(state.log), table.concat(state.chunks))
					Test.eq(state.fields, {
						threadId = "thread-abc",
						usage = usage,
						exitCode = code,
						execFinished = true,
						rateLimited = false,
					})
				end)
			end
		end
	end
)

Test.test(
	"exec runner closes logs and emits error on spawn, storage and metadata failures",
	function()
		fixture(function(_, state)
			state.spawnError = true
			assert(state.run().err:find("spawn failed", 1, true))
			Test.eq(state.fields.exitCode, 1)
		end)
		fixture(function(rt, state)
			state.log = rt.cwd
			Test.eq(state.run().code, 1)
			Test.eq(state.fields.exitCode, 1)
		end)
		fixture(function(rt, state)
			state.updateError = true
			state.chunks = { rt.encode({ type = "thread.started", thread_id = "abc" }) .. "\n" }
			local result = state.run()
			Test.eq(result.code, 1)
			assert(result.err:find("record changed", 1, true))
			Test.eq(state.stops, 1)
			assert(state.output:find("\27]7501;state=error:app=orc\27\\", 1, true))
		end)
	end
)
