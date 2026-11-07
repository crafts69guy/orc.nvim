local M = {}

---@class orc.Popup
---@field closed boolean True once close() ran; callbacks must then do nothing.
---@field job? orc.ProcessHandle Owned CLI child, stopped on close.
---@field picker? table Owned Snacks picker, closed on close; clear it when Snacks closes itself.
---@field close fun() Idempotently release owned resources and optionally quit the popup Neovim.
---@field fail fun(message: string) Notify an error and, in a dedicated popup, show a closable error window.

---@class orc.PopupOptions
---@field title string Notification title and error window heading.
---@field quit_on_close? boolean Exit the dedicated popup Neovim after close.
---@field on_close? fun() Runs once, right after the closed flag is set.

---Create the lifecycle shared by the Snacks popups.
---@param opts orc.PopupOptions Popup identity and lifetime.
---@return orc.Popup popup Mutable lifecycle state plus close and fail.
function M.new(opts)
	local popup = { closed = false }
	local error_buffer, error_window
	local function notify(message)
		vim.notify(message, vim.log.levels.ERROR, { title = opts.title })
	end
	function popup.close()
		if popup.closed then
			return
		end
		popup.closed = true
		if opts.on_close then
			opts.on_close()
		end
		if popup.job then
			popup.job.stop()
		end
		if popup.picker then
			pcall(popup.picker.close, popup.picker)
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
	function popup.fail(message)
		notify(message)
		if not opts.quit_on_close then
			return
		end
		local buffer = vim.api.nvim_create_buf(false, true)
		error_buffer = buffer
		local lines = vim.list_extend({ opts.title, "" }, vim.split(message, "\n", { plain = true }))
		vim.list_extend(lines, { "", "Press Esc or q to close." })
		vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
		vim.bo[buffer].buftype, vim.bo[buffer].bufhidden, vim.bo[buffer].swapfile =
			"nofile", "wipe", false
		vim.bo[buffer].modified, vim.bo[buffer].modifiable = false, false
		vim.keymap.set("n", "q", popup.close, { buffer = buffer })
		vim.keymap.set("n", "<Esc>", popup.close, { buffer = buffer })
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
				popup.close()
			end,
		})
	end
	return popup
end

return M
