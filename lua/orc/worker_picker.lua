local M = {}

---@class orc.WorkerPickerOptions
---@field cwd? string Absolute project directory; defaults to the editor's current directory.
---@field client_id? string Originating Rex app; absent means server focus only.
---@field quit_on_close? boolean Exit only the dedicated popup Neovim; false in a normal editor.

local function worker_items(document)
	assert(
		type(document) == "table" and document.schemaVersion == 1,
		"orc: unsupported status schema"
	)
	assert(
		type(document.workers) == "table" and vim.islist(document.workers),
		"orc: invalid workers list"
	)
	local items = {}
	for _, worker in ipairs(document.workers) do
		assert(type(worker) == "table", "orc: invalid worker record")
		if worker.state ~= "closed" then
			for _, field in ipairs({ "feature", "task", "kind", "state" }) do
				assert(type(worker[field]) == "string", "orc: invalid worker " .. field)
			end
			local role = worker.role or "implementer"
			assert(type(role) == "string", "orc: invalid worker role")
			items[#items + 1] = {
				text = worker.feature
					.. "/"
					.. worker.task
					.. "  "
					.. role
					.. "  "
					.. worker.kind
					.. "  "
					.. worker.state,
				value = worker,
			}
		end
	end
	return items
end

---List workers asynchronously with Snacks; focusing validates the recorded Rex identity.
---@param rt orc.Runtime Runtime supplying asynchronous subprocesses and the project cwd.
---@param opts? orc.WorkerPickerOptions Popup context.
---@return orc.ProcessHandle handle Closing stops only owned CLI children, never Rex workers.
function M.open(rt, opts)
	opts = opts or {}
	local closed, busy, job, picker = false, false, nil, nil
	local error_buffer, error_window
	local function notify(message)
		vim.notify(message, vim.log.levels.ERROR, { title = "orc workers" })
	end
	local function close()
		if closed then
			return
		end
		closed = true
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
				vim.list_extend({ "orc workers", "" }, vim.split(message, "\n", { plain = true }))
			vim.list_extend(lines, { "", "Press Esc or q to close." })
			vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
			vim.bo[buffer].buftype, vim.bo[buffer].bufhidden, vim.bo[buffer].swapfile =
				"nofile", "wipe", false
			vim.bo[buffer].modified, vim.bo[buffer].modifiable = false, false
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
					-- The buffer is already being wiped; close only the remaining owned resources.
					error_buffer = nil
					close()
				end,
			})
		end
	end
	local loaded, snacks_picker = pcall(require, "snacks.picker")
	if not loaded then
		startup_error("Snacks.nvim is required for worker search; install folke/snacks.nvim")
		return handle
	end
	local client = require("orc.rex").new(rt)
	local ok, child = pcall(rt.async, { rt.path(rt.root, "bin", "orc"), "status", "--json" }, {
		cwd = opts.cwd or rt.cwd,
		timeout = 10000,
	}, function(result)
		if closed then
			return
		end
		if result.code ~= 0 then
			startup_error(result.stderr ~= "" and result.stderr or "orc status failed")
			return
		end
		local decoded, items = pcall(function()
			return worker_items(rt.decode(result.stdout))
		end)
		if not decoded then
			startup_error("Invalid worker status: " .. tostring(items))
			return
		end
		if #items == 0 then
			startup_error("No non-closed workers found")
			return
		end
		local function confirm(_, item)
			if closed or busy or not item then
				return
			end
			local worker = item.value
			if type(worker.blockId) ~= "string" or worker.blockId == "" then
				notify("orc: worker has no confirmed block")
				return
			end
			busy = true
			job = client.focus({
				session_id = worker.sessionId,
				block_id = worker.blockId,
				client_id = opts.client_id,
				identity = { host_id = worker.hostId, instance_id = worker.instanceId },
			}, function(_, err)
				if closed then
					return
				end
				busy = false
				if err then
					notify(err)
					return
				end
				close()
			end)
		end
		local windows, buffers = {}, {}
		for _, window in ipairs(vim.api.nvim_list_wins()) do
			windows[window] = true
		end
		for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
			buffers[buffer] = true
		end
		local opened, err = pcall(function()
			picker = snacks_picker.pick({
				title = "Orc Workers",
				items = items,
				format = "text",
				layout = { preset = "select" },
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
					-- Snacks is already closing itself; avoid re-entering Picker:close().
					picker = nil
					close()
				end,
			})
		end)
		if not opened then
			-- A partially opened picker returns no handle; clean up only its new UI resources.
			for _, window in ipairs(vim.api.nvim_list_wins()) do
				if not windows[window] then
					local buffer = vim.api.nvim_win_get_buf(window)
					pcall(vim.api.nvim_win_close, window, true)
					if not buffers[buffer] then
						pcall(vim.api.nvim_buf_delete, buffer, { force = false })
					end
				end
			end
			startup_error("Snacks picker failed: " .. tostring(err))
		end
	end)
	if not ok then
		startup_error("orc status could not start: " .. tostring(child))
	else
		job = child
	end
	return handle
end

return M
