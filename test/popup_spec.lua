local popup_module = require("orc.popup")

-- Capture notifications and deferred callbacks; restore globals and extra windows/buffers.
local function fixture(exercise)
	local state = { notices = {}, scheduled = {}, quit = 0 }
	local old_notify, old_schedule, old_cmd = vim.notify, vim.schedule, vim.cmd
	local windows, buffers = {}, {}
	for _, window in ipairs(vim.api.nvim_list_wins()) do
		windows[window] = true
	end
	for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
		buffers[buffer] = true
	end
	vim.notify = function(message, level, opts)
		state.notices[#state.notices + 1] = { message = message, level = level, opts = opts }
	end
	vim.schedule = function(fn)
		state.scheduled[#state.scheduled + 1] = fn
	end
	function state.run_scheduled()
		for _, fn in ipairs(state.scheduled) do
			fn()
		end
		state.scheduled = {}
	end
	function state.press(buffer, lhs)
		for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buffer, "n")) do
			if mapping.lhs == lhs then
				return mapping.callback()
			end
		end
		error("no mapping " .. lhs)
	end
	function state.extra()
		local found = { windows = {}, buffers = {} }
		for _, window in ipairs(vim.api.nvim_list_wins()) do
			if not windows[window] then
				found.windows[#found.windows + 1] = window
			end
		end
		for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
			if not buffers[buffer] then
				found.buffers[#found.buffers + 1] = buffer
			end
		end
		return found
	end
	local ok, err = xpcall(exercise, debug.traceback, state)
	-- Cleanup wipes error buffers, which schedules qa; keep the stubs until then.
	for _, window in ipairs(state.extra().windows) do
		pcall(vim.api.nvim_win_close, window, true)
	end
	for _, buffer in ipairs(state.extra().buffers) do
		pcall(vim.api.nvim_buf_delete, buffer, { force = true })
	end
	vim.notify, vim.schedule, vim.cmd = old_notify, old_schedule, old_cmd
	assert(ok, err)
end

local function resources(log)
	return {
		job = {
			stop = function()
				log[#log + 1] = "job"
			end,
		},
		picker = {
			close = function()
				log[#log + 1] = "picker"
			end,
		},
	}
end

Test.test("popup close is idempotent and releases owned resources once", function()
	local log = {}
	local popup = popup_module.new({
		title = "T",
		on_close = function()
			log[#log + 1] = "on_close"
		end,
	})
	local owned = resources(log)
	popup.job, popup.picker = owned.job, owned.picker
	Test.eq(popup.closed, false)
	popup.close()
	popup.close()
	Test.eq(popup.closed, true)
	-- on_close first: callers inspect their state before the job is stopped.
	Test.eq(log, { "on_close", "job", "picker" })
end)

Test.test("popup close tolerates a throwing picker and missing job or picker", function()
	local stopped = 0
	local popup = popup_module.new({ title = "T" })
	popup.job = {
		stop = function()
			stopped = stopped + 1
		end,
	}
	popup.picker = {
		close = function()
			error("picker boom")
		end,
	}
	popup.close()
	Test.eq({ popup.closed, stopped }, { true, 1 })
	local bare = popup_module.new({ title = "T" })
	bare.close()
	Test.eq(bare.closed, true)
end)

Test.test("popup fail without quit_on_close only notifies", function()
	fixture(function(state)
		local popup = popup_module.new({ title = "Orc projects" })
		popup.fail("boom")
		Test.eq(state.notices, {
			{ message = "boom", level = vim.log.levels.ERROR, opts = { title = "Orc projects" } },
		})
		Test.eq(state.extra(), { windows = {}, buffers = {} })
		Test.eq(state.scheduled, {})
	end)
end)

Test.test("popup fail with quit_on_close shows a readable unmodifiable error window", function()
	fixture(function(state)
		local popup = popup_module.new({ title = "Orc", quit_on_close = true })
		popup.fail("first\nsecond")
		local extra = state.extra()
		Test.eq(#extra.windows, 1)
		Test.eq(#extra.buffers, 1)
		local buffer = extra.buffers[1]
		Test.eq(vim.api.nvim_win_get_buf(extra.windows[1]), buffer)
		Test.eq(vim.api.nvim_win_get_config(extra.windows[1]).relative, "editor")
		Test.eq(
			vim.api.nvim_buf_get_lines(buffer, 0, -1, false),
			{ "Orc", "", "first", "second", "", "Press Esc or q to close." }
		)
		Test.eq(
			{ vim.bo[buffer].buftype, vim.bo[buffer].bufhidden, vim.bo[buffer].swapfile },
			{ "nofile", "wipe", false }
		)
		Test.eq({ vim.bo[buffer].modifiable, vim.bo[buffer].modified }, { false, false })
		Test.eq(state.notices[1].message, "first\nsecond")
	end)
end)

Test.test("popup error window closes on q or Esc", function()
	for _, key in ipairs({ "q", "<Esc>" }) do
		fixture(function(state)
			local popup = popup_module.new({ title = "Orc", quit_on_close = true })
			popup.fail("boom")
			local extra = state.extra()
			state.press(extra.buffers[1], key)
			Test.eq(popup.closed, true)
			Test.eq(state.extra(), { windows = {}, buffers = {} })
		end)
	end
end)

Test.test("popup close after fail removes the error window and buffer", function()
	fixture(function(state)
		local popup = popup_module.new({ title = "Orc", quit_on_close = true })
		popup.fail("boom")
		popup.close()
		Test.eq(state.extra(), { windows = {}, buffers = {} })
	end)
end)

Test.test("popup wiping the error buffer closes without a double delete", function()
	fixture(function(state)
		local popup = popup_module.new({ title = "Orc", quit_on_close = true })
		popup.fail("boom")
		local buffer = state.extra().buffers[1]
		vim.cmd("bwipeout " .. buffer)
		Test.eq(popup.closed, true)
		Test.eq(state.extra(), { windows = {}, buffers = {} })
		Test.eq(#state.notices, 1)
	end)
end)

Test.test("popup quit_on_close schedules qa and keeps Neovim open when it fails", function()
	for _, blocked in ipairs({ false, true }) do
		fixture(function(state)
			vim.cmd = function(command)
				Test.eq(command, "qa")
				if blocked then
					error("E37: No write since last change")
				end
				state.quit = state.quit + 1
			end
			local popup = popup_module.new({ title = "Orc", quit_on_close = true })
			popup.close()
			Test.eq({ #state.scheduled, state.quit }, { 1, 0 })
			state.run_scheduled()
			if blocked then
				Test.eq(state.quit, 0)
				Test.eq(
					state.notices[1].message,
					"Popup remains open: save modified buffers before quitting"
				)
				Test.eq(state.notices[1].level, vim.log.levels.ERROR)
			else
				Test.eq({ state.quit, #state.notices }, { 1, 0 })
			end
		end)
	end
end)

Test.test("popup without quit_on_close never schedules qa", function()
	fixture(function(state)
		popup_module.new({ title = "Orc" }).close()
		Test.eq(state.scheduled, {})
	end)
end)
