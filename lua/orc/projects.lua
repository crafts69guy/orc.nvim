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
	local busy, creating, uncertain = false, false, false
	local snacks_picker
	local created = {}
	local function notify(message)
		vim.notify(message, vim.log.levels.ERROR, { title = "orc projects" })
	end
	local popup = require("orc.popup").new({
		title = "orc projects",
		quit_on_close = opts.quit_on_close,
		on_close = function()
			if creating then
				notify("Session creation may be unconfirmed; check rex ls before reopening")
			end
		end,
	})
	local close, startup_error = popup.close, popup.fail
	local handle = { stop = close }
	local loaded
	loaded, snacks_picker = pcall(require, "snacks.picker")
	if not loaded then
		startup_error("Snacks.nvim is required for GHQ search; install folke/snacks.nvim")
		return handle
	end
	local client = require("orc.rex").new(rt)
	local ok, child = pcall(rt.async, { "ghq", "list", "-p" }, { timeout = 10000 }, function(result)
		if popup.closed then
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
			popup.job = client.focus({
				session_id = session.session_id,
				identity = session.identity,
				client_id = opts.client_id,
			}, function(_, err)
				if popup.closed then
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
			if popup.closed or busy then
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
			popup.job = client.create_session(
				{ cwd = path, label = vim.fn.strcharpart(vim.fs.basename(path), 0, 128) },
				function(value, err)
					if popup.closed then
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
			popup.picker = snacks_picker.pick({
				title = "GHQ → New Rex Session",
				items = items,
				format = "text",
				-- Compact centered list (50% wide, 80-100 cols, 40% tall); repo paths need no preview.
				-- A dedicated popup fills its Rex layer so the bare editor never shows behind it.
				layout = { preset = "select", fullscreen = opts.quit_on_close == true },
				-- Pin both modes: Snacks' insert <Esc> only leaves insert mode, and a user's
				-- plain-string `["<CR>"] = "confirm"` override maps normal mode only.
				win = {
					input = {
						keys = {
							["<Esc>"] = { "close", mode = { "n", "i" } },
							["<CR>"] = { "confirm", mode = { "n", "i" } },
						},
					},
				},
				confirm = confirm,
				on_close = function()
					-- Snacks is already closing itself; drop the reference so close() does not re-enter it.
					popup.picker = nil
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
		popup.job = child
	end
	return handle
end

return M
