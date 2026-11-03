local M = {}

---@class orc.ProjectOptions
---@field client_id? string Originating Rex app; absent means no app is selected.
---@field quit_on_close? boolean Exit only the dedicated popup Neovim; false in a normal editor.

---Open a Snacks GHQ picker. Session creation is never replayed after an unknown result.
---@param rt orc.Runtime Runtime supplying asynchronous subprocesses.
---@param opts? orc.ProjectOptions Popup context.
---@return orc.ProcessHandle handle Closing stops only owned CLI children, never Rex sessions.
function M.open(rt, opts)
	opts = opts or {}
	local closed, busy, creating, uncertain, job, picker = false, false, false, false, nil, nil
	local snacks_picker, error_buffer, error_window
	local created = {}
	local function notify(message)
		vim.notify(message, vim.log.levels.ERROR, { title = "orc projects" })
	end
	local function close()
		if closed then
			return
		end
		closed = true
		if creating then
			notify("Session creation may be unconfirmed; check rex ls before reopening")
		end
		if job then
			job.stop()
		end
		if picker then
			pcall(picker.close, picker)
		end
		local buffer = error_buffer
		if buffer then
			if error_window and vim.api.nvim_win_is_valid(error_window) then
				pcall(vim.api.nvim_win_close, error_window, false)
			end
			if vim.api.nvim_buf_is_valid(buffer) then
				pcall(vim.api.nvim_buf_delete, buffer, { force = false })
			end
		end
		if opts.quit_on_close then
			vim.schedule(function()
				local ok = pcall(vim.cmd, "qa")
				if not ok then
					notify("Popup remains open: save modified buffers before quitting")
				end
			end)
		end
	end
	local handle = { stop = close }
	local function startup_error(message)
		notify(message)
		if opts.quit_on_close then
			local buffer = vim.api.nvim_create_buf(false, true)
			error_buffer = buffer
			local lines =
				vim.list_extend({ "orc projects", "" }, vim.split(message, "\n", { plain = true }))
			vim.list_extend(lines, { "", "Press Esc or q to close." })
			vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
			vim.bo[buffer].buftype, vim.bo[buffer].bufhidden, vim.bo[buffer].swapfile =
				"nofile", "wipe", false
			vim.bo[buffer].modified = false
			vim.bo[buffer].modifiable = false
			vim.keymap.set("n", "q", close, { buffer = buffer })
			vim.keymap.set("n", "<Esc>", close, { buffer = buffer })
			error_window = vim.api.nvim_open_win(buffer, true, {
				relative = "editor",
				width = math.max(1, math.min(100, vim.o.columns - 4)),
				height = math.max(1, math.min(5, vim.o.lines - 4)),
				row = 1,
				col = 1,
				style = "minimal",
				border = "rounded",
			})
			vim.api.nvim_create_autocmd("BufWipeout", {
				buffer = buffer,
				once = true,
				callback = function()
					-- The buffer is already being wiped (e.g. :q); deleting it again raises E937.
					error_buffer = nil
					close()
				end,
			})
		end
	end
	local loaded
	loaded, snacks_picker = pcall(require, "snacks.picker")
	if not loaded then
		startup_error("Snacks.nvim is required for GHQ search; install folke/snacks.nvim")
		return handle
	end
	local client = require("orc.rex").new(rt)
	local ok, child = pcall(rt.async, { "ghq", "list", "-p" }, { timeout = 10000 }, function(result)
		if closed then
			return
		end
		if result.code ~= 0 then
			startup_error(result.stderr ~= "" and result.stderr or "ghq list failed")
			return
		end
		local items = {}
		for path in result.stdout:gmatch("[^\r\n]+") do
			items[#items + 1] = { text = path, value = path }
		end
		if #items == 0 then
			startup_error("No repositories found by ghq list -p")
			return
		end
		local function select_session(path)
			local session = created[path]
			job = client.focus({
				session_id = session.session_id,
				identity = session.identity,
				client_id = opts.client_id,
			}, function(_, err)
				if closed then
					return
				end
				busy = false
				if err then
					notify(
						"Session " .. session.session_id .. " exists; press Enter to retry switching. " .. err
					)
					return
				end
				close()
			end)
		end
		local function confirm(_, item)
			if closed or busy then
				return
			end
			if uncertain then
				notify("Session creation is unconfirmed; check rex ls before reopening")
				return
			end
			if not item then
				return
			end
			local path = item.value
			local stat = type(path) == "string" and path:sub(1, 1) == "/" and vim.uv.fs_stat(path)
			if not stat or stat.type ~= "directory" then
				notify("Repository directory no longer exists or is not absolute")
				return
			end
			busy = true
			if created[path] then
				select_session(path)
				return
			end
			creating = true
			job = client.create_session(
				{ cwd = path, label = vim.fn.strcharpart(vim.fs.basename(path), 0, 128) },
				function(value, err)
					if closed then
						return
					end
					creating = false
					if err then
						busy, uncertain = false, true
						notify(err .. "; session creation is unconfirmed; check rex ls before reopening")
						return
					end
					created[path] = value
					select_session(path)
				end
			)
		end
		local windows, buffers = {}, {}
		for _, window in ipairs(vim.api.nvim_list_wins()) do
			windows[window] = true
		end
		for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
			buffers[buffer] = true
		end
		local opened, error = pcall(function()
			picker = snacks_picker.pick({
				title = "GHQ → New Rex Session",
				items = items,
				format = "text",
				layout = { preview = false },
				-- Snacks' default insert-mode <Esc> only leaves insert mode; close on the first press.
				win = { input = { keys = { ["<Esc>"] = { "close", mode = { "n", "i" } } } } },
				confirm = confirm,
				on_close = function()
					-- Snacks is already closing itself; drop the reference so close() does not re-enter it.
					picker = nil
					close()
				end,
			})
		end)
		if not opened then
			-- A partially opened picker returns no handle; remove only windows and buffers it created.
			for _, window in ipairs(vim.api.nvim_list_wins()) do
				if not windows[window] then
					local buffer = vim.api.nvim_win_get_buf(window)
					pcall(vim.api.nvim_win_close, window, true)
					if not buffers[buffer] then
						pcall(vim.api.nvim_buf_delete, buffer, { force = false })
					end
				end
			end
			startup_error("Snacks picker failed: " .. tostring(error))
		end
	end)
	if not ok then
		startup_error("ghq could not start: " .. tostring(child))
	else
		job = child
	end
	return handle
end

return M
