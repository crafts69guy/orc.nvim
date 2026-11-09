local runtime = require("orc.runtime")
local identity = { host_id = "host", instance_id = "instance", endpoint = "unix:///fixture" }

local function fixture(exercise)
	local rt = runtime.new({ cwd = Test.temp() })
	local path = rt.cwd .. "/-repo with spaces;$()'東京"
	rt.mkdir(path)
	local state = { calls = {}, callbacks = {}, stopped = 0, notices = {}, path = path }
	rt.exec = function()
		error("synchronous process in project UI")
	end
	rt.async = function(argv, opts, callback)
		state.calls[#state.calls + 1] = { argv = argv, opts = opts }
		state.callbacks[#state.calls] = callback
		return {
			stop = function()
				state.stopped = state.stopped + 1
			end,
		}
	end
	function state.reply(index, value, code, err)
		state.callbacks[index]({
			code = code or 0,
			signal = 0,
			stdout = type(value) == "string" and value or rt.encode(value or identity),
			stderr = err or "",
		})
	end
	function state.create(first)
		state.reply(first)
		state.reply(first + 1)
		state.reply(first + 2, { session_id = "session:new" })
	end
	function state.focus(first, client)
		state.reply(first)
		state.reply(first + 1)
		if client then
			state.reply(first + 2, "null")
		end
	end
	local previous, preload = {}, {}
	local modules = {
		["snacks.picker"] = {
			pick = function(opts)
				state.options = opts
				state.items = vim.tbl_map(function(item)
					Test.eq(item.text, item.value)
					return item.value
				end, opts.items)
				state.buffer = vim.api.nvim_create_buf(false, true)
				if state.show then
					state.window = vim.api.nvim_open_win(state.buffer, true, {
						relative = "editor",
						width = 30,
						height = 5,
						row = 1,
						col = 1,
					})
				end
				if state.partialFailure then
					error("partially opened picker")
				end
				-- Mirrors snacks Picker:close(): on_close runs before the picker is marked closed.
				local picker = { closed = false }
				function picker.close(self)
					if self.closed then
						return
					end
					opts.on_close(self)
					self.closed, state.closed = true, true
					if vim.api.nvim_buf_is_valid(state.buffer) then
						vim.api.nvim_buf_delete(state.buffer, { force = true })
					end
				end
				state.picker = picker
				function state.confirm()
					opts.confirm(picker, state.entry)
				end
				return picker
			end,
		},
	}
	for key, module in pairs(modules) do
		previous[key], preload[key] = package.loaded[key], package.preload[key]
		package.loaded[key] = module
	end
	local notify = vim.notify
	vim.notify = function(message)
		state.notices[#state.notices + 1] = message
	end
	function state.open(opts)
		local handle = require("orc.projects").open(rt, opts)
		state.reply(1, path .. "\n")
		state.entry = { value = path }
		return handle
	end
	local ok, err = xpcall(function()
		exercise(rt, state)
	end, debug.traceback)
	if state.buffer and vim.api.nvim_buf_is_valid(state.buffer) then
		vim.api.nvim_buf_delete(state.buffer, { force = true })
	end
	vim.notify = notify
	for key, value in pairs(modules) do
		package.loaded[key], package.preload[key] = previous[key], preload[key]
	end
	assert(ok, err)
end

Test.test(
	"projects Snacks picker lists GHQ and creates one correctly quoted session on its originating app",
	function()
		fixture(function(rt, state)
			state.open({ client_id = "client:origin" })
			Test.eq(state.calls[1].argv, { "ghq", "list", "-p" })
			Test.eq(state.items, { state.path })
			Test.eq(state.options.layout, { preset = "select", fullscreen = false })
			Test.eq(state.options.format, "text")
			Test.eq(state.options.win.input.keys["<Esc>"], { "close", mode = { "n", "i" } })
			Test.eq(state.options.win.input.keys["<CR>"], { "confirm", mode = { "n", "i" } })
			state.confirm()
			state.confirm()
			Test.eq(#state.calls, 2)
			state.create(2)
			local call = state.calls[4]
			local input = rt.decode(call.opts.stdin)
			Test.eq(input.label, vim.fs.basename(state.path))
			Test.eq(input.initial_windows[1].layout.block.options.cwd, state.path)
			assert(
				vim.tbl_contains(call.argv, "--server") and vim.tbl_contains(call.argv, "unix:///fixture")
			)
			state.focus(5, true)
			assert(vim.tbl_contains(state.calls[7].argv, "client:origin"))
			assert(state.closed and #state.notices == 0)
		end)
	end
)

Test.test(
	"projects selection retry uses known session and never replays an uncertain create",
	function()
		fixture(function(_, state)
			state.open({ client_id = "client:origin" })
			state.confirm()
			state.create(2)
			state.reply(5, "", 1, "app unavailable")
			assert(state.notices[1]:find("exists; press Enter", 1, true))
			state.confirm()
			state.focus(6, true)
			Test.eq(#state.calls, 8)
			assert(state.closed)
		end)
		fixture(function(_, state)
			state.open()
			state.confirm()
			state.reply(2)
			state.reply(3)
			state.reply(4, "garbage")
			state.confirm()
			Test.eq(#state.calls, 4)
			assert(state.notices[2]:find("unconfirmed", 1, true))
		end)
	end
)

Test.test("projects cancellation and stale callbacks stop only owned children", function()
	fixture(function(_, state)
		local handle = state.open()
		state.entry = nil
		state.confirm()
		Test.eq(#state.calls, 1)
		state.entry = { value = "relative" }
		state.confirm()
		assert(state.notices[1]:find("not absolute", 1, true))
		state.entry = { value = 42 }
		state.confirm()
		assert(state.notices[2]:find("not absolute", 1, true))
		state.entry = { value = state.path }
		state.confirm()
		state.picker:close()
		handle.stop()
		state.reply(2)
		Test.eq(#state.calls, 2)
		assert(state.notices[3]:find("may be unconfirmed", 1, true))
		Test.eq(state.stopped, 1)
	end)
	fixture(function(rt, state)
		local handle = require("orc.projects").open(rt)
		handle.stop()
		state.reply(1, state.path .. "\n")
		assert(not state.options)
	end)
end)

Test.test(
	"projects reports missing dependencies listing failures and empty GHQ without creating sessions",
	function()
		fixture(function(rt, state)
			package.loaded["snacks.picker"] = nil
			package.preload["snacks.picker"] = function()
				error("missing")
			end
			require("orc.projects").open(rt)
			assert(state.notices[1]:find("Snacks.nvim is required", 1, true))
			Test.eq(#state.calls, 0)
		end)
		for _, sample in ipairs({
			{ code = 1, stderr = "offline" },
			{ code = 1, stderr = "" },
			{ code = 0, stderr = "" },
		}) do
			fixture(function(rt, state)
				require("orc.projects").open(rt)
				state.reply(1, "", sample.code, sample.stderr)
				assert(#state.notices == 1 and not state.options)
			end)
		end
		fixture(function(rt, state)
			rt.async = function()
				error("missing ghq")
			end
			require("orc.projects").open(rt)
			assert(state.notices[1]:find("could not start", 1, true))
		end)
	end
)

Test.test(
	"projects Rex adapter rejects changed or remote identities and malformed create replies",
	function()
		for _, value in ipairs({
			{},
			{ endpoint = "tcp://remote" },
			{ endpoint = "unix:///fixture" },
			{ endpoint = "unix:///fixture", host_id = "", instance_id = "x" },
		}) do
			fixture(function(rt, state)
				local result
				require("orc.rex")
					.new(rt)
					.create_session({ cwd = state.path, label = "test" }, function(_, err)
						result = err
					end)
				state.reply(1, value)
				assert(result)
				Test.eq(#state.calls, 1)
			end)
		end
		fixture(function(rt, state)
			local result
			require("orc.rex")
				.new(rt)
				.create_session({ cwd = state.path, label = "test" }, function(_, err)
					result = err
				end)
			state.reply(1)
			state.reply(2, { endpoint = "unix:///fixture", host_id = "other", instance_id = "instance" })
			assert(result:find("identity changed", 1, true))
			Test.eq(#state.calls, 2)
		end)
		for _, value in ipairs({ {}, { session_id = "" }, { session_id = false } }) do
			fixture(function(rt, state)
				local result
				require("orc.rex")
					.new(rt)
					.create_session({ cwd = state.path, label = "test" }, function(_, err)
						result = err
					end)
				state.reply(1)
				state.reply(2)
				state.reply(3, value)
				assert(result:find("unconfirmed", 1, true))
			end)
		end
	end
)

Test.test(
	"projects Rex adapter validates inputs errors cancellation and server-only focus",
	function()
		fixture(function(rt, state)
			local client = require("orc.rex").new(rt)
			local result
			client.create_session({ cwd = "relative", label = "x" }, function(_, err)
				result = err
			end)
			assert(result:find("absolute", 1, true))
			Test.eq(#state.calls, 0)
			client.focus({}, function(_, err)
				result = err
			end)
			assert(result:find("identity and session", 1, true))
			client.focus({ session_id = "session:test", identity = identity }, function(value, err)
				result = err or value
			end)
			state.reply(1)
			state.reply(2)
			Test.eq(result, { session_id = "session:test" })
		end)
		fixture(function(rt, state)
			local result
			local handle = require("orc.rex").new(rt).focus({
				session_id = "session:test",
				block_id = "block:test",
				client_id = "client:test",
				identity = identity,
			}, function(_, err)
				result = err
			end)
			state.reply(1)
			state.reply(2)
			state.reply(3, {}, 1)
			assert(result:find("command failed", 1, true))
			handle.stop()
			state.reply(3)
		end)
		fixture(function(rt, state)
			local result
			rt.async = function()
				error("spawn")
			end
			require("orc.rex")
				.new(rt)
				.focus({ session_id = "session:test", identity = identity }, function(_, err)
					result = err
				end)
			assert(result:find("spawn", 1, true))
		end)
	end
)

Test.test(
	"projects popup errors remain readable and modified buffers prevent automatic exit",
	function()
		for _, blocked in ipairs({ false, true }) do
			fixture(function(rt, state)
				local old_cmd, old_schedule = vim.cmd, vim.schedule
				local quit, scheduled = 0, {}
				vim.cmd = function(command)
					assert(command == "qa")
					if blocked then
						error("E37: No write since last change")
					end
					quit = quit + 1
				end
				vim.schedule = function(fn)
					scheduled[#scheduled + 1] = fn
				end
				local ok, err = xpcall(function()
					require("orc.projects").open(rt, { quit_on_close = true })
					state.reply(1, "", 1, "ghq offline")
					local buffer = vim.api.nvim_get_current_buf()
					assert(vim.api.nvim_buf_get_lines(buffer, 0, -1, false)[3]:find("ghq offline", 1, true))
					for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buffer, "n")) do
						if mapping.lhs == "q" then
							mapping.callback()
						end
					end
					for _, callback in ipairs(scheduled) do
						callback()
					end
					Test.eq(quit, blocked and 0 or 1)
					if blocked then
						assert(state.notices[2]:find("save modified buffers", 1, true))
					end
				end, debug.traceback)
				vim.cmd, vim.schedule = old_cmd, old_schedule
				assert(ok, err)
			end)
		end
		fixture(function(rt, state)
			package.loaded["snacks.picker"].pick = function()
				error("picker failure")
			end
			require("orc.projects").open(rt)
			state.reply(1, state.path .. "\n")
			assert(state.notices[1]:find("Snacks picker failed", 1, true))
		end)
		fixture(function(rt, state)
			local user = vim.api.nvim_create_buf(true, false)
			local window
			package.loaded["snacks.picker"].pick = function()
				window = vim.api.nvim_open_win(user, false, { split = "below" })
				error("partial picker")
			end
			require("orc.projects").open(rt)
			state.reply(1, state.path .. "\n")
			assert(not vim.api.nvim_win_is_valid(window) and vim.api.nvim_buf_is_valid(user))
			vim.api.nvim_buf_delete(user, { force = true })
		end)
	end
)

Test.test(
	"projects public stop dismisses owned visible Snacks picker without quitting the editor",
	function()
		fixture(function(_, state)
			state.show = true
			local handle = state.open()
			assert(vim.api.nvim_win_is_valid(state.window))
			handle.stop()
			handle.stop()
			assert(state.closed and not vim.api.nvim_win_is_valid(state.window))
			assert(not vim.api.nvim_buf_is_valid(state.buffer))
			Test.eq(state.stopped, 1)
			state.confirm()
			Test.eq(#state.calls, 1)
		end)
	end
)

Test.test(
	"projects popup diagnostics preserve modified buffers across dependency and late multiline failures",
	function()
		for _, scenario in ipairs({ "missing", "late", "partial" }) do
			fixture(function(rt, state)
				local original_window = vim.api.nvim_get_current_win()
				local buffers, windows = {}, {}
				local function modified(text)
					local buffer = vim.api.nvim_create_buf(true, false)
					local window = vim.api.nvim_open_win(buffer, true, { split = "below" })
					vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { text })
					vim.bo[buffer].modified = true
					buffers[#buffers + 1], windows[#windows + 1] = buffer, window
					return buffer
				end
				local before = modified("unsaved user text")
				local old_cmd, old_schedule = vim.cmd, vim.schedule
				vim.cmd = function(command)
					assert(command == "qa")
					error("modified buffers")
				end
				vim.schedule = function(fn)
					fn()
				end
				local handle
				local ok, err = xpcall(function()
					if scenario == "missing" then
						package.loaded["snacks.picker"] = nil
						package.preload["snacks.picker"] = function()
							error("missing")
						end
					end
					state.show, state.partialFailure = scenario == "partial", scenario == "partial"
					handle = require("orc.projects").open(rt, { quit_on_close = true })
					local switched
					if scenario == "late" then
						switched = modified("another unsaved buffer")
						state.reply(1, "", 1, "ghq failed\ncheck configuration")
					elseif scenario == "partial" then
						state.reply(1, state.path .. "\n")
					end
					local diagnostic = vim.api.nvim_get_current_buf()
					assert(diagnostic ~= before and diagnostic ~= switched)
					Test.eq(vim.bo[diagnostic].buftype, "nofile")
					Test.eq(vim.bo[diagnostic].modifiable, false)
					if scenario == "late" then
						Test.eq(
							vim.api.nvim_buf_get_lines(diagnostic, 2, 4, false),
							{ "ghq failed", "check configuration" }
						)
					end
					handle.stop()
					assert(not vim.api.nvim_buf_is_valid(diagnostic))
					if scenario == "partial" then
						assert(
							not vim.api.nvim_buf_is_valid(state.buffer)
								and not vim.api.nvim_win_is_valid(state.window)
						)
					end
					Test.eq(vim.api.nvim_buf_get_lines(before, 0, -1, false), { "unsaved user text" })
					Test.eq(vim.bo[before].modified, true)
					Test.eq(vim.bo[before].buftype, "")
					Test.eq(vim.bo[before].bufhidden, "")
					if switched then
						Test.eq(
							vim.api.nvim_buf_get_lines(switched, 0, -1, false),
							{ "another unsaved buffer" }
						)
						Test.eq(vim.bo[switched].modified, true)
					end
				end, debug.traceback)
				if handle then
					handle.stop()
				end
				vim.cmd, vim.schedule = old_cmd, old_schedule
				for _, window in ipairs(windows) do
					if vim.api.nvim_win_is_valid(window) then
						vim.api.nvim_win_close(window, true)
					end
				end
				for _, buffer in ipairs(buffers) do
					if vim.api.nvim_buf_is_valid(buffer) then
						vim.api.nvim_buf_delete(buffer, { force = true })
					end
				end
				vim.api.nvim_set_current_win(original_window)
				assert(ok, err)
			end)
		end
	end
)

Test.test("projects popup diagnostic closes cleanly with :q instead of mappings", function()
	fixture(function(rt, state)
		local old_cmd, old_schedule = vim.cmd, vim.schedule
		local quit = 0
		vim.cmd = function(command)
			if command == "qa" then
				quit = quit + 1
				return
			end
			return old_cmd(command)
		end
		vim.schedule = function(fn)
			fn()
		end
		local ok, err = xpcall(function()
			require("orc.projects").open(rt, { quit_on_close = true })
			state.reply(1, "", 1, "ghq offline")
			local diagnostic = vim.api.nvim_get_current_buf()
			vim.cmd("q")
			assert(not vim.api.nvim_buf_is_valid(diagnostic))
			Test.eq(quit, 1)
		end, debug.traceback)
		vim.cmd, vim.schedule = old_cmd, old_schedule
		assert(ok, err)
	end)
end)

Test.test("dedicated projects popup fills its Rex layer", function()
	fixture(function(_, state)
		state.open({ quit_on_close = true })
		Test.eq(state.options.layout, { preset = "select", fullscreen = true })
	end)
end)
