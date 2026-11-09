local M = {}
local parse = require("orc.args").parse
M.usage =
	"usage: orc wt new <base> <task>... [--yes] | merge <base> <task> --message <msg> [--yes] | remove <base> <task> [--yes] | list <base> | session <branch> [--base <ref>] [--yes]"

local function git(rt, cwd, ...)
	return rt.exec({ "git", ... }, { cwd = cwd or rt.cwd })
end

local function checked(result)
	assert(result.code == 0, result.stderr ~= "" and result.stderr or result.stdout)
	return vim.trim(result.stdout)
end

---Absolute shared git directory; nil outside Git.
---@param rt orc.Runtime
---@param cwd? string
---@return string?
function M.common(rt, cwd)
	local result = git(rt, cwd, "rev-parse", "--path-format=absolute", "--git-common-dir")
	if result.code ~= 0 or vim.trim(result.stdout) == "" then
		return nil
	end
	return vim.trim(result.stdout)
end

---Main checkout containing shared .scratch and .orc state; nil outside Git.
---@param rt orc.Runtime
---@param cwd? string
---@return string?
function M.root(rt, cwd)
	local common = M.common(rt, cwd)
	return common and vim.fs.dirname(common)
end

---The current checkout's own top-level directory, including in linked worktrees.
---@param rt orc.Runtime
---@param cwd? string
---@return string?
function M.checkout(rt, cwd)
	local result = git(rt, cwd, "rev-parse", "--show-toplevel")
	return result.code == 0 and vim.trim(result.stdout) or nil
end

---Canonical branch for one independent task.
---@param base string
---@param task string
---@return string
function M.branch(base, task)
	assert(type(base) == "string" and base ~= "" and base:sub(1, 1) ~= "-", "invalid base branch")
	assert(task:match("^[%w_.-]+$") and task ~= "." and task ~= "..", "invalid task id")
	return base .. "--" .. task
end

---Ignore runtime state without changing the tracked .gitignore.
---@param rt orc.Runtime
---@param cwd? string
function M.ignore(rt, cwd)
	local common = assert(M.common(rt, cwd), "not a Git repository")
	local file = rt.path(common, "info", "exclude")
	local previous = rt.read(file) or ""
	local missing = {}
	for _, name in ipairs({ ".orc", ".worktrees", ".scratch" }) do
		if git(rt, cwd, "check-ignore", "-q", name .. "/x").code ~= 0 then
			missing[#missing + 1] = name .. "/"
		end
	end
	if #missing > 0 then
		rt.write(
			file,
			previous .. (previous:sub(-1) == "\n" and "" or "\n") .. table.concat(missing, "\n") .. "\n"
		)
	end
end

---List live worktrees with their branches; failures are errors, never an empty success.
---@param rt orc.Runtime
---@param cwd? string
---@return table[]
function M.list(rt, cwd)
	local output =
		rt.decode(checked(rt.exec({ "wt", "list", "--format=json" }, { cwd = cwd or rt.cwd })))
	assert(type(output.items) == "table", "wt list returned no items")
	local found = {}
	for _, item in ipairs(output.items) do
		if type(item.worktree) == "table" and type(item.worktree.path) == "string" then
			found[#found + 1] = { branch = item.branch, path = item.worktree.path }
		end
	end
	return found
end

---Create or reuse a session worktree using the user's worktrunk path template.
---@param rt orc.Runtime
---@param branch string
---@param base? string
---@param yes? boolean
---@param cwd? string
---@return table
function M.session(rt, branch, base, yes, cwd)
	assert(type(branch) == "string" and branch ~= "", "--wt needs a branch")
	local exists = git(rt, cwd, "rev-parse", "--verify", "--quiet", "refs/heads/" .. branch).code == 0
	local command = { "wt", "switch" }
	if not exists then
		command[#command + 1] = "-c"
	end
	command[#command + 1] = branch
	if base and not exists then
		vim.list_extend(command, { "--base", base })
	end
	vim.list_extend(command, { "--no-cd", "--format=json" })
	if yes then
		command[#command + 1] = "--yes"
	end
	local result = rt.decode(checked(rt.exec(command, { cwd = cwd or rt.cwd })))
	assert(type(result.path) == "string", "wt switch returned no path")
	return { branch = branch, path = result.path, action = exists and "reused" or "created" }
end

local function find(rt, branch)
	for _, tree in ipairs(M.list(rt)) do
		if tree.branch == branch then
			return tree.path
		end
	end
	error("no worktree for branch " .. branch, 0)
end

local function options(command, yes)
	if yes then
		command[#command + 1] = "--yes"
	end
	return command
end

---Merge one reviewed task, preserving conflicts and reporting cleanup failures explicitly.
---@param rt orc.Runtime
---@param base string
---@param task string
---@param message string
---@param yes? boolean
---@return {status:string,task:string,base?:string,commit?:string,files?:string[]} result
---@return integer code
function M.merge(rt, base, task, message, yes)
	local branch = M.branch(base, task)
	local path = find(rt, branch)
	local dirty = checked(git(rt, path, "status", "--porcelain")) ~= ""
	local ancestor = checked(git(rt, path, "merge-base", base, "HEAD"))
	local count =
		assert(tonumber(checked(git(rt, path, "rev-list", "--count", ancestor .. "..HEAD"))))
	if dirty or count > 1 then
		if count > 0 then
			checked(git(rt, path, "reset", "--soft", ancestor))
		end
		checked(git(rt, path, "add", "-A"))
		checked(git(rt, path, "commit", "-m", message))
	end
	local preflight = git(rt, path, "merge-tree", "--write-tree", "--name-only", base, "HEAD")
	if preflight.code == 1 then
		local names =
			vim.split(preflight.stdout:match("^(.-)\n\n") or preflight.stdout, "\n", { trimempty = true })
		table.remove(names, 1)
		return { status = "conflict", task = task, files = names }, 2
	end
	checked(preflight)
	local merged =
		rt.exec(options({ "wt", "-C", path, "merge", base, "--no-commit", "--no-remove" }, yes))
	if merged.code ~= 0 then
		local rebase = checked(git(rt, path, "rev-parse", "--git-path", "rebase-merge"))
		if rt.exists(rt.abspath(rebase, path)) then
			local files = vim.split(
				checked(git(rt, path, "diff", "--name-only", "--diff-filter=U")),
				"\n",
				{ trimempty = true }
			)
			checked(git(rt, path, "rebase", "--abort"))
			return { status = "conflict", task = task, files = files }, 2
		end
		checked(merged)
	end
	local commit = checked(git(rt, rt.cwd, "rev-parse", base))
	local removed = rt.exec(options({ "wt", "remove", branch, "--foreground", "-D" }, yes))
	assert(removed.code == 0, "merged as " .. commit .. " but worktree remains: " .. removed.stderr)
	if rt.exists(path) then
		local cleaned, err = pcall(rt.rmdir, path)
		assert(
			cleaned,
			"merged as " .. commit .. " but worktree remains: " .. path .. ": " .. tostring(err)
		)
	end
	return { status = "merged", base = base, task = task, commit = commit }, 0
end

---Execute worktree commands. All command output is a JSON document.
---@param rt orc.Runtime
---@param argv string[]
---@return table
function M.run(rt, argv)
	local ok, result, code = pcall(function()
		local flags, pos = parse(argv, { yes = "boolean", message = "string", base = "string" })
		local command, base, task = pos[1], pos[2], pos[3]
		assert(base, M.usage)
		if command == "session" and #pos == 2 then
			return M.session(rt, base, flags.base, flags.yes), 0
		elseif command == "new" and #pos >= 3 then
			M.ignore(rt)
			local created = {}
			for index = 3, #pos do
				local branch = M.branch(base, pos[index])
				local cmd = options({
					"wt",
					"--config-set",
					'worktree-path=".worktrees/{{ branch | sanitize }}"',
					"switch",
					"-c",
					branch,
					"--base",
					base,
					"--no-cd",
					"--format=json",
				}, flags.yes)
				local item = rt.decode(checked(rt.exec(cmd)))
				assert(type(item.path) == "string", "wt switch returned no path")
				created[#created + 1] = { task = pos[index], branch = branch, path = item.path }
			end
			return created, 0
		elseif command == "list" and #pos == 2 then
			local found, prefix = {}, base .. "--"
			for _, tree in ipairs(M.list(rt)) do
				if tree.branch and tree.branch:sub(1, #prefix) == prefix then
					found[#found + 1] =
						{ branch = tree.branch, path = tree.path, task = tree.branch:sub(#prefix + 1) }
				end
			end
			return found, 0
		elseif command == "merge" and #pos == 3 and flags.message and flags.message ~= "" then
			return M.merge(rt, base, task, flags.message, flags.yes)
		elseif command == "remove" and #pos == 3 then
			local branch = M.branch(base, task)
			find(rt, branch)
			checked(rt.exec(options({ "wt", "remove", branch, "--foreground", "-D", "-f" }, flags.yes)))
			return { status = "removed", task = task, branch = branch }, 0
		end
		error(M.usage, 0)
	end)
	if not ok then
		result, code = { status = "error", stderr = tostring(result) }, 1
	end
	return { code = code, out = rt.encode(result) .. "\n", result = result }
end

return M
