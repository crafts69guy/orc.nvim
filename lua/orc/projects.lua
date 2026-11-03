local M = {}

---@class orc.ProjectOptions
---@field client_id? string Originating Rex app; absent means no app is selected.
---@field quit_on_close? boolean Exit only the dedicated popup Neovim; false in a normal editor.

---Open a Telescope GHQ picker. Session creation is never replayed after an unknown result.
---@param rt orc.Runtime Runtime supplying asynchronous subprocesses.
---@param opts? orc.ProjectOptions Popup context.
---@return orc.ProcessHandle handle Closing stops only owned CLI children, never Rex sessions.
function M.open(rt, opts)
	opts = opts or {}
	local closed, busy, creating, uncertain, job, prompt = false, false, false, false, nil, nil
	local telescope, error_buffer, error_window
	local created = {}
	local function notify(message)
		vim.notify(message, vim.log.levels.ERROR, { title = "orc projects" })
	end
	local function close(event)
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
		if prompt and vim.api.nvim_buf_is_valid(prompt) and (not event or event.buf ~= prompt) then
			pcall(telescope.actions.close, prompt)
		end
		if error_buffer then
			if error_window and vim.api.nvim_win_is_valid(error_window) then
				pcall(vim.api.nvim_win_close, error_window, false)
			end
			if vim.api.nvim_buf_is_valid(error_buffer) then
				pcall(vim.api.nvim_buf_delete, error_buffer, { force = false })
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
			vim.api.nvim_create_autocmd("BufWipeout", { buffer = buffer, once = true, callback = close })
		end
	end
	local loaded
	loaded, telescope = pcall(function()
		return {
			pickers = require("telescope.pickers"),
			finders = require("telescope.finders"),
			config = require("telescope.config").values,
			actions = require("telescope.actions"),
			state = require("telescope.actions.state"),
		}
	end)
	if not loaded then
		startup_error("Telescope is required for GHQ search; install telescope.nvim and plenary.nvim")
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
			items[#items + 1] = path
		end
		if #items == 0 then
			startup_error("No repositories found by ghq list -p")
			return
		end
		local opened, error = pcall(function()
			telescope.pickers
				.new({}, {
					prompt_title = "GHQ → New Rex Session",
					finder = telescope.finders.new_table({ results = items }),
					sorter = telescope.config.generic_sorter({}),
					previewer = false,
					attach_mappings = function(buffer, map)
						prompt = buffer
						vim.api.nvim_create_autocmd(
							{ "BufWipeout", "BufHidden" },
							{ buffer = buffer, once = true, callback = close }
						)
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
										"Session "
											.. session.session_id
											.. " exists; press Enter to retry switching. "
											.. err
									)
									return
								end
								telescope.actions.close(prompt)
								close()
							end)
						end
						telescope.actions.select_default:replace(function()
							if closed or busy then
								return
							end
							if uncertain then
								notify("Session creation is unconfirmed; check rex ls before reopening")
								return
							end
							local entry = telescope.state.get_selected_entry()
							if not entry then
								return
							end
							local path = entry.value
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
										notify(
											err .. "; session creation is unconfirmed; check rex ls before reopening"
										)
										return
									end
									created[path] = value
									select_session(path)
								end
							)
						end)
						for _, mode in ipairs({ "i", "n" }) do
							map(mode, "<Esc>", telescope.actions.close)
							map(mode, "<C-c>", telescope.actions.close)
							map(mode, "<C-j>", telescope.actions.move_selection_next)
							map(mode, "<C-k>", telescope.actions.move_selection_previous)
						end
						return true
					end,
				})
				:find()
		end)
		if not opened then
			startup_error("Telescope picker failed: " .. tostring(error))
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
