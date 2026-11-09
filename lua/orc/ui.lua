local M = {}
local panel

---@class orc.PanelRow
---@field feature string Feature identifier.
---@field task string Task identifier.
---@field path? string Checkout path when available.
---@field worker? orc.Worker Matching durable worker record.
---@field brief? string Handoff or plan path.
---@field report? string Current or preserved report path.

local function notify(message)
	vim.notify(message, vim.log.levels.WARN, { title = "orc" })
end

local function selected()
	assert(panel and vim.api.nvim_buf_is_valid(panel.buffer), "orc: open the task panel first")
	local row = vim.api.nvim_win_get_cursor(panel.window)[1]
	return assert(panel.rows[row], "orc: select a task row")
end

local function open_file(path)
	assert(type(path) == "string" and path ~= "", "orc: selected task has no such file")
	vim.cmd("aboveleft split " .. vim.fn.fnameescape(path))
end

local function scratch(text, kind)
	vim.cmd("aboveleft new")
	local buffer = vim.api.nvim_get_current_buf()
	vim.bo[buffer].buftype, vim.bo[buffer].bufhidden, vim.bo[buffer].swapfile =
		"nofile", "wipe", false
	vim.api.nvim_buf_set_lines(buffer, 0, -1, false, vim.split(text, "\n", { plain = true }))
	vim.bo[buffer].filetype, vim.bo[buffer].modifiable = kind, false
end

---Render task and pair-worker rows from the versioned status document.
---@param document table Status JSON document.
---@return string[] lines
---@return table<integer,orc.PanelRow> rows Task objects keyed by their panel line number.
function M.render(document)
	assert(document.schemaVersion == 1, "orc: unsupported status schema")
	local lines, rows, seen =
		{
			"orc · " .. document.root,
			"r refresh  b brief  <Enter> report  d diff  f focus  p prompt  q close",
			"",
		}, {}, {}
	local workers = document.workers or {}
	local function add(feature, task, worker, plan)
		local path = task.worktree ~= vim.NIL and task.worktree or nil
		path = path or (worker and worker.path)
		local row = {
			feature = feature,
			task = task.id,
			path = path,
			worker = worker,
			brief = worker and worker.brief or plan,
			report = worker and (not worker.acknowledged and worker.previousReport or worker.report),
		}
		lines[#lines + 1] = string.format(
			"%-28s %-12s %s",
			feature .. "/" .. task.id,
			require("orc.status").task_state(task),
			path or "-"
		)
		rows[#lines] = row
		if worker then
			seen[worker.runId] = true
		end
	end
	for _, feature in ipairs(document.features or {}) do
		for _, task in ipairs(feature.tasks) do
			local matching
			for _, worker in ipairs(workers) do
				if worker.feature == feature.feature and worker.task == task.id then
					matching = worker
				end
			end
			add(feature.feature, task, matching, feature.plan)
		end
	end
	for _, worker in ipairs(workers) do
		if not seen[worker.runId] then
			add(
				worker.feature,
				{ id = worker.task, worktree = worker.path, state = worker.state },
				worker
			)
		end
	end
	if #lines == 3 then
		lines[#lines + 1] = "No feature tasks or pair workers."
	end
	return lines, rows
end

---Refresh the panel asynchronously; concurrent refresh requests are coalesced.
function M.refresh()
	if not panel or panel.busy then
		return
	end
	local current = panel
	current.busy = true
	current.job = current.rt.async(
		{ current.rt.path(current.rt.root, "bin", "orc"), "status", "--json" },
		{ cwd = current.rt.cwd },
		function(result)
			if panel ~= current or not vim.api.nvim_buf_is_valid(current.buffer) then
				return
			end
			current.busy = false
			if result.code ~= 0 then
				notify(result.stderr ~= "" and result.stderr or result.stdout)
				return
			end
			local ok, lines, rows = pcall(function()
				return M.render(current.rt.decode(result.stdout))
			end)
			if not ok then
				notify(tostring(lines))
				return
			end
			current.rows = rows
			vim.bo[current.buffer].modifiable = true
			vim.api.nvim_buf_set_lines(current.buffer, 0, -1, false, lines)
			vim.bo[current.buffer].modifiable = false
		end
	)
end

---Close only the view and its watchers; Rex workers continue independently.
---@param event? table Autocmd context when Neovim is already hiding/wiping the view.
function M.close(event)
	if not panel then
		return
	end
	local previous = panel
	panel = nil
	previous.timer:stop()
	previous.timer:close()
	if previous.job then
		previous.job.stop()
	end
	for _, job in ipairs(previous.actions) do
		job.stop()
	end
	if not event and vim.api.nvim_buf_is_valid(previous.buffer) then
		vim.api.nvim_buf_delete(previous.buffer, { force = true })
	end
	if previous.options.quit_on_close then
		vim.schedule(function()
			local ok = pcall(vim.cmd, "qa")
			if not ok then
				notify("Popup remains open: save modified buffers before quitting")
			end
		end)
	end
end

---Run an action for the selected task without blocking the editor's process loop.
---@param action string refresh|brief|report|diff|focus|prompt
function M.action(action)
	local ok, err = pcall(function()
		if action == "refresh" or action == "status" then
			M.refresh()
			return
		end
		local row, current = selected(), panel
		local rt = current.rt
		local function active()
			return panel == current and vim.api.nvim_buf_is_valid(current.buffer)
		end
		if action == "brief" or action == "report" then
			local path = row[action]
			assert(path and rt.exists(path), "orc: selected task has no readable " .. action)
			open_file(path)
		elseif action == "diff" then
			assert(row.path, "orc: task has no checkout")
			current.actions[#current.actions + 1] = rt.async(
				{ "git", "-C", row.path, "--no-pager", "diff" },
				{},
				function(result)
					if not active() then
						return
					end
					if result.code == 0 then
						scratch(result.stdout, "diff")
					else
						notify(result.stderr)
					end
				end
			)
		elseif action == "focus" then
			local worker = assert(row.worker, "orc: task has no Rex worker")
			assert(worker.blockId, "orc: worker has no confirmed block")
			local client = require("orc.rex").new(rt)
			current.actions[#current.actions + 1] = client.focus({
				session_id = worker.sessionId,
				block_id = worker.blockId,
				client_id = current.options.client_id,
				identity = { host_id = worker.hostId, instance_id = worker.instanceId },
			}, function(_, error)
				if not active() then
					return
				end
				if error then
					notify(error)
				end
			end)
		elseif action == "prompt" then
			assert(row.path and row.worker, "orc: task has no worker")
			vim.ui.input({ prompt = "Worker follow-up: " }, function(text)
				if not active() or not text or vim.trim(text) == "" then
					return
				end
				current.actions[#current.actions + 1] = rt.async({
					rt.path(rt.root, "bin", "orc"),
					"pane",
					"prompt",
					row.task,
					"--path",
					row.path,
					"--text",
					text,
				}, {}, function(result)
					if not active() then
						return
					end
					if result.code ~= 0 then
						notify(result.stdout ~= "" and result.stdout or result.stderr)
					end
					M.refresh()
				end)
			end)
		else
			error("orc: unknown panel action: " .. action, 0)
		end
	end)
	if not ok then
		notify(tostring(err))
	end
end

---Open a native read-only task panel. No picker plugin or global mappings are required.
---@param rt orc.Runtime
---@param opts? orc.ViewOptions Explicit originating app and popup lifetime.
---@return integer buffer Panel buffer identifier.
function M.open(rt, opts)
	if panel and vim.api.nvim_win_is_valid(panel.window) then
		vim.api.nvim_set_current_win(panel.window)
		return panel.buffer
	end
	vim.cmd("botright 12new")
	local buffer, window = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
	vim.api.nvim_buf_set_name(buffer, "orc://tasks")
	vim.bo[buffer].buftype, vim.bo[buffer].bufhidden, vim.bo[buffer].swapfile =
		"nofile", "wipe", false
	vim.bo[buffer].filetype, vim.bo[buffer].modifiable = "orc", false
	local timer = assert(vim.uv.new_timer())
	panel = {
		rt = rt,
		options = opts or {},
		buffer = buffer,
		window = window,
		rows = {},
		timer = timer,
		busy = false,
		actions = {},
	}
	vim.api.nvim_create_autocmd(
		{ "BufWipeout", "BufHidden" },
		{ buffer = buffer, once = true, callback = M.close }
	)
	for key, action in pairs({
		r = "refresh",
		b = "brief",
		["<CR>"] = "report",
		d = "diff",
		f = "focus",
		p = "prompt",
	}) do
		vim.keymap.set("n", key, function()
			M.action(action)
		end, { buffer = buffer, silent = true, desc = "orc " .. action })
	end
	vim.keymap.set("n", "q", M.close, { buffer = buffer, silent = true, desc = "Close orc panel" })
	timer:start(2000, 2000, vim.schedule_wrap(M.refresh))
	M.refresh()
	return buffer
end

return M
