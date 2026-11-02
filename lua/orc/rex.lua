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

---@class orc.RexClient
---@field binary string Resolved CLI executable.
---@field argv fun(args:string[]):string[] Build a CLI argument vector.
---@field identity fun():orc.RexIdentity Read and validate local server identity.
---@field call fun(method:string,arguments?:table,session?:string):table Call a typed server method.
---@field block fun(session:string,block:string,method:string,arguments?:table):table Call a terminal method.
---@field watch fun(session:string,on_event:fun(event:table),on_exit?:fun(result:orc.ProcessResult)):table Stream handle exposing stop().

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
		return command(args, rt.encode(arguments or vim.empty_dict()))
	end
	function client.block(session, block, method, arguments)
		return command(
			{ "block", "call", "-s", session, "-b", block, method, "-" },
			rt.encode(arguments or vim.empty_dict())
		)
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
