local M = {}

---Find Rex on PATH or in its macOS app bundle; a missing binary stays diagnosable.
---@param rt orc.Runtime
---@return string executable
function M.resolve(rt)
	local binary = vim.fn.exepath("rex")
	local bundled = "/Applications/Rex Beta.app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex"
	return binary ~= "" and binary or rt.exists(bundled) and bundled or "rex"
end

---@class orc.RexIdentity
---@field host_id string Server host identity.
---@field instance_id string Current server process identity.
---@field endpoint string Local Unix socket URI.

---@class orc.RexTarget
---@field session_id string Session to focus.
---@field block_id? string Block within the session, when focusing a worker.
---@field client_id? string Originating app; absent means server focus only.
---@field identity {host_id:string,instance_id:string,endpoint?:string} Expected server identity, including an endpoint when known.

---@class orc.RexClient
---@field binary string Resolved CLI executable.
---@field argv fun(args:string[]):string[] Build a CLI argument vector.
---@field identity fun():orc.RexIdentity Read and validate local server identity.
---@field call fun(method:string,arguments?:table,session?:string):table Call a typed server method.
---@field block fun(session:string,block:string,method:string,arguments?:table):table Call a terminal method.
---@field watch fun(session:string,on_event:fun(event:table),on_exit?:fun(result:orc.ProcessResult)):table Stream handle exposing stop().
---@field create_session fun(opts:{cwd:string,label:string},callback:fun(value?:table,error?:string)):orc.ProcessHandle Create one session asynchronously; a failed reply may have created it.
---@field focus fun(target:orc.RexTarget,callback:fun(value?:table,error?:string)):orc.ProcessHandle Validate identity, focus a block, then select its session on the originating app.

---Build a Rex CLI adapter. The bundled macOS executable is a fallback when PATH
---does not inherit Rex's terminal environment.
---@param rt orc.Runtime
---@return orc.RexClient client Methods return decoded JSON or raise a bounded diagnostic.
function M.new(rt)
	local binary = M.resolve(rt)
	local client = { binary = binary }
	function client.argv(args)
		local command = { binary }
		vim.list_extend(command, args)
		return command
	end
	local function command(args, input)
		local result = rt.exec(client.argv(args), { stdin = input, timeout = 10000 })
		assert(
			result.code == 0,
			"rex: " .. (result.stderr ~= "" and result.stderr or "command failed (" .. result.code .. ")")
		)
		local ok, value = pcall(rt.decode, result.stdout)
		assert(ok and type(value) == "table", "rex: invalid JSON response")
		return value
	end
	function client.identity()
		local identity = command({ "whoami", "--json" })
		assert(
			type(identity.endpoint) == "string" and identity.endpoint:match("^unix://"),
			"rex: remote server cannot share local worktrees"
		)
		assert(
			type(identity.host_id) == "string" and type(identity.instance_id) == "string",
			"rex: server identity is missing"
		)
		return identity
	end
	function client.call(method, arguments, session)
		local args = { "api", "call" }
		if session then
			vim.list_extend(args, { "-s", session })
		end
		vim.list_extend(args, { method, "-" })
		return command(args, rt.encode(arguments and next(arguments) and arguments or vim.empty_dict()))
	end
	function client.block(session, block, method, arguments)
		return command(
			{ "block", "call", "-s", session, "-b", block, method, "-" },
			rt.encode(arguments and next(arguments) and arguments or vim.empty_dict())
		)
	end
	local function operation(callback)
		local pending, stopped, finished, endpoint
		local task = {}
		function task.stop()
			stopped = true
			if pending then
				pending.stop()
			end
		end
		function task.finish(value, err)
			if not stopped and not finished then
				finished = true
				callback(value, err)
			end
		end
		function task.request(args, input, next_step, empty)
			if stopped or finished then
				return
			end
			local argv = { "--autostart=false" }
			if endpoint then
				vim.list_extend(argv, { "--server", endpoint })
			end
			vim.list_extend(argv, args)
			local ok, child = pcall(rt.async, client.argv(argv), {
				stdin = input and rt.encode(input),
				timeout = 10000,
			}, function(result)
				if stopped or finished then
					return
				end
				if result.code ~= 0 then
					task.finish(
						nil,
						"rex: "
							.. (result.stderr ~= "" and result.stderr or "command failed (" .. result.code .. ")")
					)
					return
				end
				local decoded, value = pcall(rt.decode, result.stdout)
				if empty and (result.stdout == "" or value == vim.NIL) then
					decoded, value = true, {}
				end
				if not decoded or type(value) ~= "table" then
					task.finish(nil, "rex: invalid JSON response")
					return
				end
				local advanced, err = pcall(next_step, value)
				if not advanced then
					task.finish(nil, tostring(err))
				end
			end)
			if not ok then
				task.finish(nil, "rex: " .. tostring(child))
			else
				pending = child
			end
		end
		function task.verify(expected, next_step)
			task.request({ "whoami", "--json" }, nil, function(identity)
				assert(
					type(identity.endpoint) == "string" and identity.endpoint:match("^unix:///[^%z]+$"),
					"rex: local Unix server required"
				)
				assert(
					type(identity.host_id) == "string"
						and identity.host_id ~= ""
						and type(identity.instance_id) == "string"
						and identity.instance_id ~= "",
					"rex: server identity is missing"
				)
				if expected then
					assert(
						identity.host_id == expected.host_id
							and identity.instance_id == expected.instance_id
							and (not expected.endpoint or identity.endpoint == expected.endpoint),
						"rex: server identity changed; refusing stale target"
					)
				end
				endpoint = identity.endpoint
				next_step(identity)
			end)
		end
		return task
	end
	function client.create_session(opts, callback)
		local task = operation(callback)
		local stat = type(opts.cwd) == "string"
			and opts.cwd:sub(1, 1) == "/"
			and vim.uv.fs_stat(opts.cwd)
		if not stat or stat.type ~= "directory" or type(opts.label) ~= "string" or opts.label == "" then
			task.finish(nil, "rex: project needs an absolute directory and label")
			return task
		end
		task.verify(nil, function(identity)
			task.verify(identity, function()
				task.request({ "api", "call", "session.create", "-" }, {
					label = opts.label,
					initial_windows = {
						{
							window_label = "Terminal",
							layout = {
								block = {
									flavor = "com.superlogical.terminal.shell",
									options = { cwd = opts.cwd },
								},
							},
						},
					},
				}, function(value)
					assert(
						type(value.session_id) == "string" and value.session_id:match("^session:.+"),
						"rex: session creation is unconfirmed"
					)
					value.identity = identity
					task.finish(value)
				end)
			end)
		end)
		return task
	end
	function client.focus(target, callback)
		local task = operation(callback)
		if
			type(target.session_id) ~= "string"
			or target.session_id == ""
			or type(target.identity) ~= "table"
		then
			task.finish(nil, "rex: target identity and session are required")
			return task
		end
		task.verify(target.identity, function(identity)
			task.verify(identity, function()
				local function select()
					if target.client_id then
						assert(
							type(target.client_id) == "string" and target.client_id ~= "",
							"rex: originating client is missing"
						)
						task.request(
							{
								"-C",
								target.client_id,
								"do",
								"session.select",
								"--args",
								rt.encode({ session_id = target.session_id }),
							},
							nil,
							function(value)
								task.finish(value)
							end,
							true
						)
					else
						task.finish({ session_id = target.session_id })
					end
				end
				if target.block_id then
					task.request(
						{ "api", "call", "-s", target.session_id, "session.focus_block", "-" },
						{ block_id = target.block_id },
						select
					)
				else
					select()
				end
			end)
		end)
		return task
	end
	---Stream NDJSON notifications. The caller resnapshots state after disconnects.
	function client.watch(session, on_event, on_exit)
		assert(rt.stream, "rex: runtime streaming is unavailable")
		local pending, stream = "", nil
		stream = rt.stream(client.argv({ "events", "-s", session, "--json" }), {
			on_exit = on_exit,
		}, function(chunk)
			pending = pending .. chunk
			if #pending > 1048576 then
				pending = ""
				if stream then
					stream.stop()
				end
				if on_exit then
					on_exit({ code = 1, signal = 0, stdout = "", stderr = "rex: event exceeded one MiB" })
				end
				return
			end
			while pending:find("\n", 1, true) do
				local at = pending:find("\n", 1, true)
				local line = pending:sub(1, at - 1)
				pending = pending:sub(at + 1)
				if line ~= "" then
					local ok, event = pcall(rt.decode, line)
					if ok and type(event) == "table" then
						on_event(event)
					end
				end
			end
		end)
		return stream
	end
	return client
end

return M
