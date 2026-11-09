local M = {}
local wt = require("orc.worktrees")

local function scalar(value)
	value = vim.trim(value)
	local quote = value:sub(1, 1)
	if quote == '"' or quote == "'" then
		local close = value:find(quote, 2, true)
		if close then
			return value:sub(2, close - 1)
		end
	end
	return vim.trim((value:gsub("%s+#.*$", "")))
end

---Read the first token after a plan's Base branch label.
---@param plan string
---@return string?
function M.parse_base(plan)
	return ("\n" .. plan):match("\nBase branch:[ \t]*([^%s#]+)")
end

---Parse the documented flat task schema inside the Tasks YAML fence.
---@param plan string
---@return table[]
function M.parse_tasks(plan)
	local tasks, section, fence, current = {}, false, false, nil
	for line in (plan:gsub("\r\n", "\n") .. "\n"):gmatch("([^\n]*)\n") do
		if line:match("^## ") then
			section, fence = line:match("^## Tasks%s*$") ~= nil, false
		elseif section and line:match("^```ya?ml%s*$") then
			fence = true
		elseif fence and line:match("^```%s*$") then
			break
		elseif fence then
			local prefix, key, value = line:match("^(%- )([%w_]+):%s*(.*)$")
			if prefix then
				current = { id = vim.NIL, goal = vim.NIL, size = vim.NIL, dependsOn = {} }
				tasks[#tasks + 1] = current
			else
				key, value = line:match("^  ([%w_]+):%s*(.*)$")
			end
			if current and key then
				if key == "id" or key == "goal" or key == "size" then
					current[key] = scalar(value)
				elseif key == "depends_on" then
					for dependency in (value:match("^%[(.-)%]") or ""):gmatch("[^,]+") do
						current.dependsOn[#current.dependsOn + 1] = scalar(dependency)
					end
				end
			end
		end
	end
	return vim.tbl_filter(function(task)
		return task.id ~= vim.NIL and task.id ~= ""
	end, tasks)
end

local function optional_json(rt, path)
	local text = rt.read(path)
	if not text then
		return nil
	end
	local ok, value = pcall(rt.decode, text)
	return ok and type(value) == "table" and value or nil
end

---Single task-state precedence: merged, agent, report, worktree, then pending.
---Uses the collected `state` when present so plain task tables work too.
---@param task table Task from the status document.
---@return string
function M.task_state(task)
	if task.state then
		return task.state
	end
	if task.merged ~= nil and task.merged ~= vim.NIL then
		return "merged"
	end
	if task.agent ~= nil and task.agent ~= vim.NIL then
		return task.agent.state
	end
	if task.report ~= nil and task.report ~= vim.NIL then
		return task.report.status
	end
	if task.worktree ~= nil and task.worktree ~= vim.NIL then
		return "worktree"
	end
	return "pending"
end

---Join plans, worktrees, durable workers, reports and merge receipts into schema version 1.
---@param rt orc.Runtime
---@param cwd? string
---@return table
function M.collect(rt, cwd)
	local root = assert(wt.root(rt, cwd), "orc status: not a Git repository")
	local result = { schemaVersion = 1, root = root, warnings = {}, features = {}, workers = {} }
	local skipped
	result.workers, skipped = require("orc.workers").collect(rt, cwd)
	for _, file in ipairs(skipped or {}) do
		result.warnings[#result.warnings + 1] = "worker record identity mismatch; skipped " .. file
	end
	local trees = nil
	for _, feature in ipairs(rt.list(rt.path(root, ".scratch"))) do
		local dir = rt.path(root, ".scratch", feature)
		local plan_path = rt.path(dir, "plan.md")
		local plan = rt.read(plan_path)
		if plan then
			if not trees then
				local ok, found = pcall(wt.list, rt, cwd)
				trees = ok and found or {}
				if not ok then
					result.warnings[#result.warnings + 1] = "wt list failed; worktrees unknown: "
						.. tostring(found)
				end
			end
			local base = M.parse_base(plan)
			local branch = base or feature
			local tasks = M.parse_tasks(plan)
			local by_id = {}
			for _, task in ipairs(tasks) do
				by_id[task.id] = task
			end
			local paths = {}
			for _, tree in ipairs(trees) do
				local prefix = branch .. "--"
				if tree.branch and tree.branch:sub(1, #prefix) == prefix then
					local id = tree.branch:sub(#prefix + 1)
					paths[id] = rt.abspath(tree.path, root)
					if not by_id[id] then
						local orphan = { id = id, goal = rt.null, size = rt.null, dependsOn = {} }
						tasks[#tasks + 1], by_id[id] = orphan, orphan
					end
				end
			end
			local merges = {}
			for id, commit in (rt.read(rt.path(dir, "merged")) or ""):gmatch("([^%s]+) ([^%s]+)") do
				merges[id] = commit
			end
			for _, task in ipairs(tasks) do
				task.branch, task.worktree = wt.branch(branch, task.id), paths[task.id] or rt.null
				task.agent, task.report, task.merged = rt.null, rt.null, rt.null
				for _, worker in ipairs(result.workers) do
					if worker.feature == feature and worker.task == task.id then
						task.agent = { name = worker.runId, state = worker.state }
						task.report = worker.reportStatus and { status = worker.reportStatus } or rt.null
					end
				end
				if merges[task.id] then
					task.merged = { commit = merges[task.id] }
				end
				task.state = M.task_state(task)
			end
			local link = optional_json(rt, rt.path(dir, "inkdrop.json"))
			local note = link
					and type(link.noteId) == "string"
					and link.noteId:match("^note:")
					and link.noteId
				or rt.null
			result.features[#result.features + 1] = {
				feature = feature,
				base = base or rt.null,
				plan = plan_path,
				note = note,
				tasks = tasks,
			}
		end
	end
	return result
end

---Record a reviewed task merge in its unique feature plan, then mirror to Inkdrop if enabled.
---@param rt orc.Runtime
---@param base string
---@param task string
---@param commit string
---@return string? warning
function M.record_merge(rt, base, task, commit)
	local root = assert(wt.root(rt), "not a Git repository")
	local features = {}
	for _, name in ipairs(rt.list(rt.path(root, ".scratch"))) do
		local plan = rt.read(rt.path(root, ".scratch", name, "plan.md"))
		if plan and (name == base or M.parse_base(plan) == base) then
			features[#features + 1] = name
		end
	end
	if #features > 1 then
		return "merge not recorded: several plans use base " .. base
	elseif #features == 0 then
		return nil
	end
	local path = rt.path(root, ".scratch", features[1], "merged")
	rt.write(path, (rt.read(path) or "") .. task .. " " .. commit .. "\n")
	if
		rt.env.ORC_INKDROP ~= "0" and rt.exists(rt.path(root, ".scratch", features[1], "inkdrop.json"))
	then
		local pushed = require("orc.inkdrop").push(rt, rt.cwd, features[1], {})
		if pushed.code ~= 0 then
			return "Inkdrop push failed: " .. (pushed.err or pushed.error or "unknown error")
		end
	end
	return nil
end

---Render a status snapshot as JSON or concise task rows.
---@param rt orc.Runtime
---@param argv string[]
---@return table
function M.run(rt, argv)
	local flags, pos = require("orc.args").parse(argv, { json = "boolean" })
	assert(#pos == 0, "usage: orc status [--json]")
	local result = M.collect(rt)
	if flags.json then
		return { code = 0, out = rt.encode(result) .. "\n" }
	end
	local lines = {}
	for _, feature in ipairs(result.features) do
		for _, task in ipairs(feature.tasks) do
			lines[#lines + 1] = feature.feature
				.. "/"
				.. task.id
				.. "  "
				.. task.state
				.. "  "
				.. (task.worktree ~= rt.null and task.worktree or "-")
		end
	end
	return {
		code = 0,
		out = (
			#lines > 0 and table.concat(lines, "\n")
			or #result.features > 0 and "no tasks"
			or "no features"
		) .. "\n",
		err = #result.warnings > 0 and table.concat(result.warnings, "\n") .. "\n" or "",
	}
end

return M
