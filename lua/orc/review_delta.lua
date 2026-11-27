local M = {}

local styles = { lua = "lua", ts = "slash", mts = "slash", cts = "slash" }

local directives = {
	"eslint",
	"@ts-",
	"prettier-ignore",
	"biome-ignore",
	"deno-lint",
	"tslint",
	"istanbul",
	"c8 ignore",
	"v8 ignore",
	"__pure__",
	"webpack",
	"@vite-ignore",
	"@jsx",
	"@flow",
	"$flowfixme",
	"@refresh",
	"-environment",
	"@generated",
	"@license",
	"@preserve",
	"@internal",
	"sourcemappingurl",
	"luacheck",
	"stylua:",
	"selene:",
	"@diagnostic",
}

local function object_id(value)
	return type(value) == "string" and (#value == 40 or #value == 64) and value:match("^%x+$")
end

local function with_temp_dir(rt, use)
	local dir = vim.uv.fs_mkdtemp(vim.fn.tempname() .. "-XXXXXX")
	if not dir then
		return nil
	end
	local ok, result = pcall(use, dir)
	local cleaned = pcall(rt.remove, dir)
	return ok and cleaned and result or nil
end

---Capture the checkout's working tree using a temporary copy of its index.
---@param rt orc.Runtime
---@param path string Checkout path.
---@return string? tree Git tree ID, or nil if the snapshot could not be made.
function M.snapshot(rt, path)
	return with_temp_dir(rt, function(dir)
		local found = rt.exec({ "git", "rev-parse", "--git-path", "index", "HEAD" }, { cwd = path })
		local index_path = found.code == 0 and found.stdout:match("^(.*)\n%x+\n$")
		if not index_path then
			return nil
		end
		local source = rt.abspath(index_path, path)
		local index = rt.path(dir, "index")
		local index_stat = vim.uv.fs_stat(source)
		if
			not index_stat
			or not vim.uv.fs_copyfile(source, index)
			or not vim.uv.fs_utime(index, index_stat.atime.sec, index_stat.mtime.sec)
		then
			return nil
		end
		local options = { cwd = path, env = { GIT_INDEX_FILE = index } }
		if rt.exec({ "git", "add", "-A" }, options).code ~= 0 then
			return nil
		end
		local written = rt.exec({ "git", "write-tree" }, options)
		return written.code == 0 and object_id(vim.trim(written.stdout)) or nil
	end)
end

local function has_directive(style, line)
	if
		(style == "lua" and line:match("^%-%-%-%s*@"))
		or (style == "slash" and line:sub(1, 3) == "///")
	then
		return true
	end
	line = line:lower()
	for _, directive in ipairs(directives) do
		if line:find(directive, 1, true) then
			return true
		end
	end
	return false
end

local function removed_comment(style, line, closing)
	if style == "lua" then
		if line:sub(1, 2) ~= "--" then
			return line == "" and not closing
		end
		if not closing then
			local level = line:match("^%-%-%[(=*)%[")
			if not level then
				return not line:find("%]=*%]")
			end
			closing = "]" .. level .. "]"
			line = line:sub(#level + 5)
		end
		local ending = line:find(closing, 1, true)
		if not ending then
			return true, closing
		end
		return vim.trim(line:sub(ending + #closing)) == ""
	end
	while closing or line ~= "" do
		if closing then
			local ending = line:find(closing, 1, true)
			if not ending then
				return true, closing
			end
			line, closing = vim.trim(line:sub(ending + 2)), nil
		elseif line:sub(1, 2) == "/*" then
			line, closing = line:sub(3), "*/"
		else
			return line:sub(1, 2) == "//" and not line:find("*/", 1, true)
		end
	end
	return true
end

---Check a zero-context Git tree diff for deletions of whole comments and blank lines.
---@param diff_text string Unified Git patch without renames, text conversion or external diffs.
---@return boolean accepted
---@return string? reason First rejected condition.
function M.comment_only(diff_text)
	if diff_text == "" then
		return true
	end
	local next_line = (diff_text:sub(-1) == "\n" and diff_text or diff_text .. "\n"):gmatch(
		"([^\n]*)\n"
	)
	local style, closing, remaining
	for line in next_line do
		if line:match("^diff %-%-git ") then
			if style and (closing or remaining ~= 0) then
				return false, "incomplete comment or hunk"
			end
			local index, old, new = next_line(), next_line(), next_line()
			local mode = index and index:match("^index %x+%.%.%x+ (%d+)$")
			if
				(mode ~= "100644" and mode ~= "100755")
				or not (old and old:match('^%-%-%- "?a/') and new and new:match('^%+%+%+ "?b/'))
			then
				return false, "expected an unchanged-mode text file modification"
			end
			local extension = new:match('%.(%w+)"?\t?$')
			style, remaining = extension and styles[extension], nil
			if not style then
				return false, "unsupported file extension"
			end
		elseif line:match("^@@ ") then
			if not style or closing or (remaining and remaining ~= 0) then
				return false, "incomplete comment or hunk"
			end
			local deleted, added = line:match("^@@ %-%d+,?(%d*) %+%d+,?(%d*) @@")
			if added ~= "0" then
				return false, "added lines or invalid deletion hunk"
			end
			remaining = tonumber(deleted) or 1
		elseif line:sub(1, 1) == "-" and remaining and remaining > 0 then
			local removed = line:sub(2):gsub("\r$", "")
			if removed:find("\0", 1, true) then
				return false, "binary content"
			end
			if removed:find("\r", 1, true) or removed:find("\226\128[\168\169]") then
				return false, "unexpected line terminator"
			end
			removed = vim.trim(removed)
			if has_directive(style, removed) then
				return false, "removed directive"
			end
			local accepted
			accepted, closing = removed_comment(style, removed, closing)
			if not accepted then
				return false, "removed code or partial comment"
			end
			remaining = remaining - 1
		elseif line ~= "\\ No newline at end of file" or not remaining then
			return false, "unexpected patch content"
		end
	end
	if closing or remaining ~= 0 then
		return false, "incomplete comment or hunk"
	end
	return true
end

---Compare a reviewed tree to the current checkout.
---@param rt orc.Runtime
---@param path string Checkout path.
---@param reviewed_tree string Reviewed Git tree ID.
---@return boolean accepted True for identical trees or a comment-only deletion.
---@return boolean? deleted_comments True when a deletion was accepted.
function M.compare(rt, path, reviewed_tree)
	local now = M.snapshot(rt, path)
	if not now or not object_id(reviewed_tree) then
		return false
	end
	if now == reviewed_tree then
		return true
	end
	local patch = with_temp_dir(rt, function(dir)
		local raw_patch = rt.path(dir, "diff")
		local diff = rt.exec({
			"git",
			"diff",
			"--output=" .. raw_patch,
			"--no-ext-diff",
			"--no-textconv",
			"--no-renames",
			"--no-color",
			"--no-relative",
			"--src-prefix=a/",
			"--dst-prefix=b/",
			"--inter-hunk-context=0",
			"--ignore-submodules=none",
			"--submodule=short",
			"-U0",
			reviewed_tree,
			now,
			"--",
		}, { cwd = path, env = { LC_ALL = "C" } })
		return diff.code == 0 and rt.read(raw_patch) or nil
	end)
	local accepted = patch ~= nil and patch ~= "" and M.comment_only(patch)
	return accepted, accepted or nil
end

return M
