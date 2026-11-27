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
	local tasks, section, fence = {}, false, false
	---@type {id:string|vim.NIL,goal:string|vim.NIL,size:string|vim.NIL,dependsOn:string[]}?
	local current
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

local function worktree_owner(branch, features, tasks, claims)
	local owner, task_id, best = nil, nil, 0
	if claims then
		best = 2
		if #claims == 1 then
			owner, task_id = claims[1].feature, claims[1].task
		end
	end
	for _, feature in ipairs(features) do
		local prefix = (feature.base ~= vim.NIL and feature.base or feature.feature) .. "--"
		local id = branch:sub(#prefix + 1)
		if vim.startswith(branch, prefix) and id:match("^[%w_.-]+$") then
			local priority = tasks[feature.feature][id] and 3 or 1
			if priority > best then
				owner, task_id, best = feature, id, priority
			elseif priority == best then
				owner = nil
			end
		end
	end
	return owner, task_id
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
	local features_by_name, tasks_by_feature, trees_by_feature = {}, {}, {}
	for _, feature in ipairs(rt.list(rt.path(root, ".scratch"))) do
		local dir = rt.path(root, ".scratch", feature)
		local plan_path = rt.path(dir, "plan.md")
		local plan = rt.read(plan_path)
		if plan then
			local tasks = M.parse_tasks(plan)
			local planned = {}
			for _, task in ipairs(tasks) do
				planned[task.id] = true
			end
			tasks_by_feature[feature], trees_by_feature[feature] = planned, {}
			local link = optional_json(rt, rt.path(dir, "inkdrop.json"))
			local note = link
					and type(link.noteId) == "string"
					and link.noteId:match("^note:")
					and link.noteId
				or rt.null
			local entry = {
				feature = feature,
				base = M.parse_base(plan) or rt.null,
				plan = plan_path,
				note = note,
				tasks = tasks,
			}
			features_by_name[feature] = entry
			result.features[#result.features + 1] = entry
		end
	end
	local workers_by_feature, claims_by_path = {}, {}
	for _, worker in ipairs(result.workers) do
		local named_workers = workers_by_feature[worker.feature] or {}
		named_workers[worker.task] = worker
		workers_by_feature[worker.feature] = named_workers
		local feature = features_by_name[worker.feature]
		if feature and worker.path then
			local claims = claims_by_path[worker.path] or {}
			claims[#claims + 1] = { feature = feature, task = worker.task }
			claims_by_path[worker.path] = claims
		end
	end
	local ok, trees = pcall(wt.list, rt, cwd)
	if not ok then
		result.warnings[#result.warnings + 1] = "worktree list failed; worktrees unknown: "
			.. tostring(trees)
		trees = {}
	end
	for _, tree in ipairs(trees) do
		local branch = tree.branch
		if branch and branch:match("^.+%-%-[%w_.-]+$") then
			local path = rt.abspath(tree.path, root)
			local owner, id =
				worktree_owner(branch, result.features, tasks_by_feature, claims_by_path[path])
			if owner and id then
				local worktrees = trees_by_feature[owner.feature]
				if not tasks_by_feature[owner.feature][id] and not worktrees[id] then
					owner.tasks[#owner.tasks + 1] =
						{ id = id, goal = rt.null, size = rt.null, dependsOn = {} }
				end
				worktrees[id] = { path = path, branch = branch }
			elseif path ~= root then
				result.warnings[#result.warnings + 1] = "Unclaimed worktree " .. branch .. " at " .. path
			end
		end
	end
	local stash = rt.exec({ "git", "stash", "list" }, { cwd = root })
	if stash.code == 0 then
		local count = #vim.split(stash.stdout, "\n", { trimempty = true })
		if count > 0 then
			local entries = count == 1 and "entry" or "entries"
			local warning = ("%d stash %s (shared by all worktrees)"):format(count, entries)
			result.warnings[#result.warnings + 1] = warning
		end
	end
	for _, feature in ipairs(result.features) do
		local name = feature.feature
		local base = feature.base ~= rt.null and feature.base or name
		local worktrees = trees_by_feature[name]
		local receipt = rt.read(rt.path(root, ".scratch", name, "merged")) or ""
		local merges = {}
		for id, commit in receipt:gmatch("([^%s]+) ([^%s]+)") do
			merges[id] = commit
		end
		local named_workers = workers_by_feature[name] or {}
		local finished = #feature.tasks > 0
		for _, task in ipairs(feature.tasks) do
			local worker = named_workers[task.id]
			local tree = worktrees[task.id]
			task.branch = tree and tree.branch or wt.branch(base, task.id)
			task.worktree = tree and tree.path or rt.null
			task.agent = worker and { name = worker.runId, state = worker.state } or rt.null
			task.report = worker and worker.reportStatus and { status = worker.reportStatus } or rt.null
			task.merged = merges[task.id] and { commit = merges[task.id] } or rt.null
			task.state = M.task_state(task)
			finished = finished and (task.state == "merged" or task.state == "closed")
		end
		if finished then
			local warning = ("Archive finished feature .scratch/%s to .scratch/.archive/%s"):format(
				name,
				name
			)
			result.warnings[#result.warnings + 1] = warning
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
