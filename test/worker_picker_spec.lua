local rex = require("orc.rex")
local runtime = require("orc.runtime")
local worker_picker = require("orc.worker_picker")

local function fixture(exercise)
	local rt = runtime.new({ cwd = assert(vim.uv.fs_realpath(Test.temp())) })
	local state =
		{ calls = {}, callbacks = {}, stopped = {}, notices = {}, focuses = {}, focus_stopped = 0 }
	state.worker = {
		feature = "feature",
		task = "T1",
		kind = "codex",
		state = "running",
		blockId = "block:worker",
		sessionId = "session:worker",
		hostId = "host",
		instanceId = "instance",
	}
	rt.exec = function()
		error("synchronous process in worker picker")
	end
	rt.async = function(argv, opts, callback)
		local index = #state.calls + 1
		state.calls[index] = { argv = argv, opts = opts }
		state.callbacks[index] = callback
		return {
			stop = function()
				state.stopped[index] = (state.stopped[index] or 0) + 1
			end,
		}
	end
	function state.reply(value, code, err, index)
		state.callbacks[index or 1]({
			code = code or 0,
			signal = 0,
			stdout = type(value) == "string" and value or rt.encode(value),
			stderr = err or "",
		})
	end
	function state.open(opts, workers)
		local handle = worker_picker.open(rt, opts)
		state.reply({ schemaVersion = 1, workers = workers or { state.worker } })
		return handle
	end
	local old_snacks, old_preload, old_rex, old_notify =
		package.loaded["snacks.picker"],
		package.preload["snacks.picker"],
		package.loaded["orc.rex"],
		vim.notify
	local windows, buffers = {}, {}
	for _, window in ipairs(vim.api.nvim_list_wins()) do
		windows[window] = true
	end
	for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
		buffers[buffer] = true
	end
	package.loaded["orc.rex"] = {
		new = function(actual_rt)
			Test.eq(actual_rt, rt)
			return {
				focus = function(target, callback)
					state.focuses[#state.focuses + 1] = target
					state.focus_reply = callback
					return {
						stop = function()
							state.focus_stopped = state.focus_stopped + 1
						end,
					}
				end,
			}
		end,
	}
	package.loaded["snacks.picker"] = {
		pick = function(opts)
			state.options = opts
			state.buffer = vim.api.nvim_create_buf(false, true)
			state.window = vim.api.nvim_open_win(state.buffer, true, {
				relative = "editor",
				width = 30,
				height = 5,
				row = 1,
				col = 1,
			})
			local picker = { closed = false }
			function picker.close(self)
				assert(not self.closed, "re-entered Snacks close")
				opts.on_close(self)
				self.closed = true
				vim.api.nvim_win_close(state.window, true)
				vim.api.nvim_buf_delete(state.buffer, { force = true })
			end
			state.picker = picker
			return picker
		end,
	}
	vim.notify = function(message)
		state.notices[#state.notices + 1] = message
	end
	local ok, err = xpcall(function()
		exercise(rt, state)
	end, debug.traceback)
	vim.notify = old_notify
	package.loaded["snacks.picker"], package.preload["snacks.picker"], package.loaded["orc.rex"] =
		old_snacks, old_preload, old_rex
	for _, window in ipairs(vim.api.nvim_list_wins()) do
		if not windows[window] then
			vim.api.nvim_win_close(window, true)
		end
	end
	for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
		if not buffers[buffer] then
			vim.api.nvim_buf_delete(buffer, { force = true })
		end
	end
	assert(ok, err)
end

local function with_quit(blocked, exercise)
	local old_cmd, old_schedule = vim.cmd, vim.schedule
	local quits = 0
	vim.cmd = function(command)
		if command ~= "qa" then
			return old_cmd(command)
		end
		if blocked then
			error("modified buffers")
		end
		quits = quits + 1
	end
	vim.schedule = function(fn)
		fn()
	end
	local ok, err = xpcall(function()
		exercise(function()
			return quits
		end)
	end, debug.traceback)
	vim.cmd, vim.schedule = old_cmd, old_schedule
	assert(ok, err)
end

Test.test(
	"worker picker lists non-closed workers and focuses exact Rex identity before closing",
	function()
		fixture(function(rt, state)
			local scoper = vim.tbl_extend(
				"force",
				state.worker,
				{ task = "T2", role = "scoper", level = "high", state = "idle" }
			)
			local max = vim.tbl_extend("force", state.worker, { task = "T3", level = "max" })
			local closed = vim.tbl_extend("force", state.worker, { task = "T4", state = "closed" })
			local handle = state.open(
				{ client_id = "client:origin", cwd = rt.cwd },
				{ state.worker, scoper, max, closed }
			)
			Test.eq(state.calls, {
				{
					argv = { rt.path(rt.root, "bin", "orc"), "status", "--json" },
					opts = { cwd = rt.cwd, timeout = 10000 },
				},
			})
			local opts = state.options
			Test.eq(
				vim.tbl_map(function(item)
					return item.text
				end, opts.items),
				{
					"feature/T1  implementer  codex  default  running",
					"feature/T2  scoper  codex  high  idle",
					"feature/T3  implementer  codex  max  running",
				}
			)
			Test.eq(opts.items[2].value, scoper)
			Test.eq(opts.layout, { preset = "select", fullscreen = false })
			Test.eq(opts.format, "text")
			Test.eq(opts.win.input.keys["<Esc>"], { "close", mode = { "n", "i" } })
			Test.eq(opts.win.input.keys["<CR>"], { "confirm", mode = { "n", "i" } })
			opts.confirm(state.picker, opts.items[2])
			opts.confirm(state.picker, opts.items[2])
			Test.eq(state.focuses, {
				{
					session_id = scoper.sessionId,
					block_id = scoper.blockId,
					client_id = "client:origin",
					identity = { host_id = scoper.hostId, instance_id = scoper.instanceId },
				},
			})
			assert(not state.picker.closed)
			state.focus_reply({})
			assert(state.picker.closed and not vim.api.nvim_win_is_valid(state.window))
			handle.stop()
			Test.eq(state.focus_stopped, 1)
			Test.eq(state.notices, {})
		end)
	end
)

Test.test(
	"worker picker diagnoses unconfirmed blocks and allows retry after focus errors",
	function()
		fixture(function(_, state)
			local missing = vim.tbl_extend("force", state.worker, { blockId = vim.NIL })
			state.open(nil, { missing, state.worker })
			local opts = state.options
			opts.confirm(state.picker, nil)
			opts.confirm(state.picker, opts.items[1])
			opts.confirm(state.picker, { value = { blockId = "" } })
			Test.eq(#state.focuses, 0)
			assert(state.notices[1]:find("no confirmed block", 1, true))
			opts.confirm(state.picker, opts.items[2])
			Test.eq(state.focuses[1].client_id, nil)
			state.focus_reply(nil, "app unavailable")
			assert(not state.picker.closed and state.notices[3] == "app unavailable")
			opts.confirm(state.picker, opts.items[2])
			Test.eq(#state.focuses, 2)
			state.focus_reply({})
			assert(state.picker.closed)
		end)
	end
)

Test.test("worker picker cancellation stops only owned jobs and ignores late callbacks", function()
	fixture(function(rt, state)
		local handle = worker_picker.open(rt)
		handle.stop()
		handle.stop()
		state.reply({ schemaVersion = 1, workers = { state.worker } })
		Test.eq(state.stopped, { 1 })
		Test.eq(#state.calls, 1)
		assert(not state.options)
	end)
	fixture(function(_, state)
		local handle = state.open()
		state.picker:close()
		handle.stop()
		state.options.confirm(state.picker, state.options.items[1])
		Test.eq(#state.focuses, 0)
		Test.eq(state.stopped, { 1 })
	end)
	fixture(function(_, state)
		local handle = state.open()
		state.options.confirm(state.picker, state.options.items[1])
		handle.stop()
		state.focus_reply(nil, "late failure")
		state.focus_reply({})
		Test.eq(state.focus_stopped, 1)
		Test.eq(state.notices, {})
		Test.eq(#state.calls, 1)
	end)
end)

Test.test(
	"worker picker uses Rex adapter to focus the block and select the originating client",
	function()
		fixture(function(rt, state)
			package.loaded["orc.rex"] = rex
			state.open({ client_id = "client:origin" })
			state.options.confirm(state.picker, state.options.items[1])
			local identity = { host_id = "host", instance_id = "instance", endpoint = "unix:///fixture" }
			state.reply(identity, 0, "", 2)
			state.reply(identity, 0, "", 3)
			Test.eq(rt.decode(state.calls[4].opts.stdin), { block_id = "block:worker" })
			assert(vim.tbl_contains(state.calls[4].argv, "session.focus_block"))
			assert(vim.tbl_contains(state.calls[4].argv, "session:worker"))
			state.reply({}, 0, "", 4)
			assert(vim.tbl_contains(state.calls[5].argv, "client:origin"))
			assert(vim.tbl_contains(state.calls[5].argv, "session.select"))
			state.reply("null", 0, "", 5)
			assert(state.picker.closed)
		end)
	end
)

Test.test(
	"worker picker reports missing Snacks, process failures and empty lists without opening a picker",
	function()
		fixture(function(rt, state)
			package.loaded["snacks.picker"] = nil
			package.preload["snacks.picker"] = function()
				error("missing")
			end
			local handle = worker_picker.open(rt)
			assert(state.notices[1]:find("Snacks.nvim is required", 1, true))
			Test.eq(#state.calls, 0)
			handle.stop()
		end)
		fixture(function(rt, state)
			rt.async = function()
				error("spawn failed")
			end
			worker_picker.open(rt)
			assert(state.notices[1]:find("could not start", 1, true))
		end)
		for _, stderr in ipairs({ "offline", "" }) do
			fixture(function(rt, state)
				worker_picker.open(rt)
				state.reply("", 1, stderr)
				assert(#state.notices == 1 and not state.options)
			end)
		end
		for _, workers in ipairs({ {}, { { state = "closed" } } }) do
			fixture(function(_, state)
				state.open(nil, workers)
				Test.eq(state.notices, { "No non-closed workers found" })
				assert(not state.options)
			end)
		end
	end
)

Test.test("worker picker rejects malformed status documents with a diagnostic", function()
	for _, value in ipairs({
		"invalid json",
		"null",
		"false",
		{},
		{ schemaVersion = 2 },
		{ schemaVersion = 1 },
		{ schemaVersion = 1, workers = false },
		{ schemaVersion = 1, workers = { invalid = true } },
		{ schemaVersion = 1, workers = { false } },
		{ schemaVersion = 1, workers = { { state = "running" } } },
		{
			schemaVersion = 1,
			workers = { { feature = "f", task = "t", kind = "codex", state = "idle", role = {} } },
		},
		{
			schemaVersion = 1,
			workers = { { feature = "f", task = "t", kind = "codex", state = "idle", level = {} } },
		},
	}) do
		fixture(function(rt, state)
			worker_picker.open(rt)
			state.reply(value)
			assert(state.notices[1]:find("Invalid worker status", 1, true))
			assert(not state.options)
		end)
	end
end)

Test.test(
	"worker picker popup shows startup diagnostics safely and quits only after close",
	function()
		for _, scenario in ipairs({
			"missing",
			"spawn",
			"failure",
			"empty",
			"malformed",
			"partial",
			"user-buffer",
		}) do
			fixture(function(rt, state)
				with_quit(true, function(quits)
					local user = vim.api.nvim_create_buf(true, false)
					vim.api.nvim_buf_set_lines(user, 0, -1, false, { "unsaved text" })
					vim.api.nvim_open_win(user, true, { split = "below" })
					local partial_buffer, partial_window
					if scenario == "missing" then
						package.loaded["snacks.picker"] = nil
						package.preload["snacks.picker"] = function()
							error("missing")
						end
					elseif scenario == "spawn" then
						rt.async = function()
							error("spawn failed")
						end
					elseif scenario == "partial" or scenario == "user-buffer" then
						package.loaded["snacks.picker"].pick = function()
							partial_buffer = user
							if scenario == "partial" then
								partial_buffer = vim.api.nvim_create_buf(false, true)
							end
							partial_window = vim.api.nvim_open_win(partial_buffer, true, { split = "below" })
							error("partially opened picker")
						end
					end
					local handle = worker_picker.open(rt, { quit_on_close = true })
					if scenario == "failure" then
						state.reply("", 1, "status failed\ncheck repository")
					elseif scenario == "empty" then
						state.reply({ schemaVersion = 1, workers = {} })
					elseif scenario == "malformed" then
						state.reply("invalid")
					elseif scenario == "partial" or scenario == "user-buffer" then
						state.reply({ schemaVersion = 1, workers = { state.worker } })
					end
					local diagnostic = vim.api.nvim_get_current_buf()
					assert(diagnostic ~= user)
					Test.eq(vim.bo[diagnostic].buftype, "nofile")
					Test.eq(vim.bo[diagnostic].modifiable, false)
					Test.eq(quits(), 0)
					if scenario == "failure" then
						Test.eq(
							vim.api.nvim_buf_get_lines(diagnostic, 2, 4, false),
							{ "status failed", "check repository" }
						)
					end
					if partial_window then
						assert(not vim.api.nvim_win_is_valid(partial_window))
						Test.eq(vim.api.nvim_buf_is_valid(partial_buffer), partial_buffer == user)
					end
					for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(diagnostic, "n")) do
						if mapping.lhs == "q" then
							mapping.callback()
						end
					end
					handle.stop()
					assert(not vim.api.nvim_buf_is_valid(diagnostic))
					Test.eq(vim.api.nvim_buf_get_lines(user, 0, -1, false), { "unsaved text" })
					assert(vim.bo[user].modified)
					Test.eq(quits(), 0)
					assert(state.notices[#state.notices]:find("save modified buffers", 1, true))
				end)
			end)
		end
	end
)

Test.test("worker picker popup quits once on successful focus or diagnostic :q", function()
	for _, success in ipairs({ true, false }) do
		fixture(function(rt, state)
			with_quit(false, function(quits)
				local handle = worker_picker.open(rt, { quit_on_close = true })
				if success then
					state.reply({ schemaVersion = 1, workers = { state.worker } })
					state.options.confirm(state.picker, state.options.items[1])
					state.focus_reply({})
				else
					state.reply("", 1, "offline")
					vim.cmd("q")
				end
				handle.stop()
				Test.eq(quits(), 1)
			end)
		end)
	end
end)

Test.test("worker picker cleans up a diagnostic buffer after its window was closed", function()
	fixture(function(rt, state)
		with_quit(false, function(quits)
			local handle = worker_picker.open(rt, { quit_on_close = true })
			state.reply("", 1, "offline")
			local buffer, window = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
			vim.bo[buffer].bufhidden = "hide"
			vim.api.nvim_win_close(window, false)
			assert(vim.api.nvim_buf_is_valid(buffer))
			handle.stop()
			assert(not vim.api.nvim_buf_is_valid(buffer))
			Test.eq(quits(), 1)
		end)
	end)
end)

Test.test("dedicated worker popup fills its Rex layer", function()
	fixture(function(_, state)
		state.open({ quit_on_close = true })
		Test.eq(state.options.layout, { preset = "select", fullscreen = true })
	end)
end)
