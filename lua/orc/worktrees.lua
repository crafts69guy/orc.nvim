local M = {}
local parse = require("orc.args").parse
M.usage =
	"usage: orc wt new <base> <task>... [--yes] | merge <base> <task> --message <msg> [--yes] | apply <base> <task> [--message <msg>] | remove <base> <task> [--yes] | list <base> | session <branch> [--base <ref>] [--yes]"

local function git(rt, cwd, ...)
	return rt.exec({ "git", ... }, { cwd = cwd or rt.cwd })
end

local function checked(result)
	assert(result.code == 0, result.stderr ~= "" and result.stderr or result.stdout)
	return vim.trim(result.stdout)
end

-- Git quotes non-ASCII and unusual paths unless -z; quoted names never match as pathspecs.
local function names(rt, cwd, ...)
	local result = git(rt, cwd, ...)
	checked(result)
	return vim.split(result.stdout, "\0", { trimempty = true })
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
---Plain Git: the panel polls this, and `wt list` computes per-worktree status (or CI with list.full).
---@param rt orc.Runtime
---@param cwd? string
---@return table[]
function M.list(rt, cwd)
	local found, tree = {}, nil
	for _, field in ipairs(names(rt, cwd, "worktree", "list", "--porcelain", "-z")) do
		local key, value = field:match("^(%S+) ?(.*)$")
		if key == "worktree" then
			tree = { path = value }
			found[#found + 1] = tree
		elseif key == "branch" and tree then
			tree.branch = (value:gsub("^refs/heads/", ""))
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

-- Squashing or removing under a writing worker would capture or delete half-written files.
local function settled(rt, path)
	local real = vim.uv.fs_realpath(path) or path
	for _, worker in ipairs(require("orc.workers").collect(rt)) do
		if worker.path == real and (worker.state == "working" or worker.state == "blocked") then
			error(
				"orc wt: worker "
					.. tostring(worker.task)
					.. " is still "
					.. worker.state
					.. " in "
					.. path
					.. "; wait for its report or `orc pane pause` it first",
				0
			)
		end
	end
end

-- Resolve a task worktree for merge, apply or remove; refuses while its worker writes.
local function find(rt, branch)
	for _, tree in ipairs(M.list(rt)) do
		if tree.branch == branch then
			settled(rt, tree.path)
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

-- Keeps the last applied task snapshot alive so a fix round can apply only its delta.
local function applied_ref(branch)
	return "refs/orc/applied/" .. branch
end

-- Best effort: a leftover ref only keeps one old task commit reachable.
local function forget_applied(rt, branch)
	git(rt, rt.cwd, "update-ref", "-d", applied_ref(branch))
end

-- Squash the task checkout into one commit on its own branch; return the files it changes.
-- A single existing commit is redone too, so the caller's message always wins.
local function squash(rt, path, base, task, message)
	local dirty = checked(git(rt, path, "status", "--porcelain")) ~= ""
	local ancestor = checked(git(rt, path, "merge-base", base, "HEAD"))
	local count =
		assert(tonumber(checked(git(rt, path, "rev-list", "--count", ancestor .. "..HEAD"))))
	if dirty or count > 0 then
		if count > 0 then
			checked(git(rt, path, "reset", "--soft", ancestor))
		end
		checked(git(rt, path, "add", "-A"))
		checked(git(rt, path, "commit", "-m", message))
	end
	local files = names(rt, path, "diff", "-z", "--name-only", "--no-renames", base .. "...HEAD")
	assert(#files > 0, "orc wt: task " .. task .. " has no changes")
	return files
end

-- Report the files a squash merge of the task commit into base would conflict on.
local function preflight(rt, path, base, task)
	local preflight = git(rt, path, "merge-tree", "--write-tree", "--name-only", "-z", base, "HEAD")
	if preflight.code == 1 then
		-- -z output: tree OID, conflicted names, then an empty field before the messages.
		local files = {}
		for index, name in ipairs(vim.split(preflight.stdout, "\0")) do
			if name == "" then
				break
			elseif index > 1 then
				files[#files + 1] = name
			end
		end
		return { status = "conflict", task = task, files = files }
	end
	checked(preflight)
end

---Merge one reviewed task, preserving conflicts and reporting cleanup failures explicitly.
---@param rt orc.Runtime
---@param base string
---@param task string
---@param message string
---@param yes? boolean
---@return {status:string,task:string,base?:string,commit?:string,files?:string[],warning?:string} result
---@return integer code
function M.merge(rt, base, task, message, yes)
	local branch = M.branch(base, task)
	local path = find(rt, branch)
	squash(rt, path, base, task, message)
	local conflict = preflight(rt, path, base, task)
	if conflict then
		return conflict, 2
	end
	local merged =
		rt.exec(options({ "wt", "-C", path, "merge", base, "--no-commit", "--no-remove" }, yes))
	if merged.code ~= 0 then
		local rebase = checked(git(rt, path, "rev-parse", "--git-path", "rebase-merge"))
		if rt.exists(rt.abspath(rebase, path)) then
			local files = names(rt, path, "diff", "-z", "--name-only", "--diff-filter=U")
			checked(git(rt, path, "rebase", "--abort"))
			return { status = "conflict", task = task, files = files }, 2
		end
		checked(merged)
	end
	local commit = checked(git(rt, rt.cwd, "rev-parse", base))
	-- The merge already landed: a cleanup failure is a warning, so the receipt is still recorded.
	local done = { status = "merged", base = base, task = task, commit = commit }
	local removed = rt.exec(options({ "wt", "remove", branch, "--foreground", "-D" }, yes))
	if removed.code ~= 0 then
		done.warning = "worktree remains: " .. vim.trim(removed.stderr)
	elseif rt.exists(path) then
		local cleaned, err = pcall(rt.rmdir, path)
		if not cleaned then
			done.warning = "worktree remains: " .. path .. ": " .. tostring(err)
		end
	end
	forget_applied(rt, branch)
	return done, 0
end

---Stage one reviewed task in the current checkout without committing on base.
---Only the task branch gets a squash commit; its worktree stays until `remove`.
---Re-applying after a fix round lands only the delta while the checkout still holds
---the last apply for those files; otherwise it falls back to a full squash merge.
---@param rt orc.Runtime
---@param base string
---@param task string
---@param message string Commit message for the task branch only.
---@return {status:string,task:string,base?:string,files?:string[],incremental?:boolean} result
---@return integer code
function M.apply(rt, base, task, message)
	local branch = M.branch(base, task)
	local path = find(rt, branch)
	local current = checked(git(rt, rt.cwd, "rev-parse", "--abbrev-ref", "HEAD"))
	assert(current == base, "orc wt apply: current checkout is on " .. current .. ", not " .. base)
	local files = squash(rt, path, base, task, message)
	local head = checked(git(rt, path, "rev-parse", "HEAD"))
	local ref = applied_ref(branch)
	local previous = git(rt, rt.cwd, "rev-parse", "--verify", "--quiet", ref .. "^{commit}")
	local diverged = {}
	if previous.code == 0 then
		local last = vim.trim(previous.stdout)
		local changed = names(rt, rt.cwd, "diff", "-z", "--name-only", "--no-renames", last, head)
		local compare = { "diff", "-z", "--name-only", "--no-renames", last, "--" }
		vim.list_extend(compare, #changed > 0 and changed or files)
		diverged = names(rt, rt.cwd, unpack(compare))
		-- These files still hold exactly the last apply, so only the fix-round delta lands.
		if #diverged == 0 then
			assert(#changed > 0, "orc wt apply: task " .. task .. " is already applied")
			local patch = git(rt, rt.cwd, "diff", "--binary", "--no-renames", last, head)
			assert(patch.code == 0, patch.stderr)
			checked(rt.exec({ "git", "apply", "--binary" }, { cwd = rt.cwd, stdin = patch.stdout }))
			local add = { "add", "-A", "--" }
			vim.list_extend(add, changed)
			checked(git(rt, rt.cwd, unpack(add)))
			checked(git(rt, rt.cwd, "update-ref", ref, head))
			return { status = "applied", base = base, task = task, files = changed, incremental = true },
				0
		end
	end
	-- A squash merge cannot be aborted, so refuse before touching files with local changes.
	local local_changes, overlap = {}, {}
	-- Entries are "XY path"; -z keeps paths unquoted so they compare with the diff names.
	for _, entry in ipairs(names(rt, rt.cwd, "status", "--porcelain", "-z", "--no-renames")) do
		local_changes[entry:sub(4)] = true
	end
	for _, file in ipairs(files) do
		if local_changes[file] then
			overlap[#overlap + 1] = file
		end
	end
	if #overlap > 0 then
		-- After an earlier apply, name only the files edited since then, not the applied ones.
		local edited = vim.tbl_filter(function(file)
			return vim.tbl_contains(diverged, file)
		end, overlap)
		return { status = "conflict", task = task, files = #edited > 0 and edited or overlap }, 2
	end
	local conflict = preflight(rt, path, base, task)
	if conflict then
		return conflict, 2
	end
	checked(git(rt, rt.cwd, "merge", "--squash", branch))
	checked(git(rt, rt.cwd, "update-ref", ref, head))
	return { status = "applied", base = base, task = task, files = files }, 0
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
			-- Validate every id before creating any, and reuse live task worktrees so a retry is safe.
			local branches, existing = {}, {}
			for index = 3, #pos do
				branches[index] = M.branch(base, pos[index])
			end
			M.ignore(rt)
			for _, tree in ipairs(M.list(rt)) do
				if tree.branch then
					existing[tree.branch] = tree.path
				end
			end
			local created = {}
			for index = 3, #pos do
				local branch, action = branches[index], "reused"
				if not existing[branch] then
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
					existing[branch], action = item.path, "created"
				end
				created[#created + 1] =
					{ task = pos[index], branch = branch, path = existing[branch], action = action }
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
		elseif command == "apply" and #pos == 3 then
			return M.apply(rt, base, task, flags.message or ("orc: apply " .. task))
		elseif command == "remove" and #pos == 3 then
			local branch = M.branch(base, task)
			find(rt, branch)
			checked(rt.exec(options({ "wt", "remove", branch, "--foreground", "-D", "-f" }, flags.yes)))
			forget_applied(rt, branch)
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
