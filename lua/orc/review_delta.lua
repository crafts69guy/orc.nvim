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

local regex_keywords = {}
for keyword in
	("return typeof instanceof in of new delete void throw case do else yield await"):gmatch("%S+")
do
	regex_keywords[keyword] = true
end

local function line_break(source, index)
	if source:sub(index, index) == "\r" then
		return source:sub(index + 1, index + 1) == "\n" and 2 or 1
	elseif source:sub(index, index) == "\n" then
		return 1
	elseif source:find("^\226\128[\168\169]", index) then
		return 3
	end
end

local function line_end(source, index)
	while index <= #source and not line_break(source, index) do
		index = index + 1
	end
	return index
end

local function unicode_space(source, index)
	if source:find("^\194\160", index) then
		return 2
	end
	local char = source:sub(index, index + 2)
	if
		char == "\225\154\128"
		or char:match("^\226\128[\128-\138\168\169\175]$")
		or char == "\226\129\159"
		or char == "\227\128\128"
		or char == "\239\187\191"
	then
		return 3
	end
end

local function word_end(source, index)
	while true do
		local after = source:match("^[%w_$]+()", index)
		if after then
			index = after
		elseif (source:byte(index) or 0) >= 128 and not unicode_space(source, index) then
			index = index + 1
		else
			return index
		end
	end
end

local function literal_end(source, index, delimiter)
	local regex, in_class = delimiter == "/", false
	while index <= #source do
		local char = source:sub(index, index)
		if line_break(source, index) then
			return nil
		elseif char == "\\" then
			local continued = line_break(source, index + 1)
			if regex and continued then
				return nil
			end
			index = index + 1 + (continued or 1)
		elseif char == delimiter and not in_class then
			return regex and word_end(source, index + 1) or index + 1
		else
			if regex and char == "[" then
				in_class = true
			elseif regex and char == "]" then
				in_class = false
			end
			index = index + 1
		end
	end
end

local function clean_slash_line_end(source, index)
	local ending = line_end(source, index + 1)
	local line = source:sub(index, ending - 1)
	if not line:find("[`\"'{}]") and not line:find("/*", 1, true) then
		return ending
	end
end

local function typescript_tokens(source)
	local tokens, templates = {}, {}
	local index, template_start = source:match("^\239\187\191()") or 1, 1
	if source:sub(index, index + 1) == "#!" then
		index = line_end(source, index + 2)
	end
	local regex_allowed, uncertain_prefix, after_dot = true, false, false
	local doubt_line_end
	while index <= #source do
		local char, pair = source:sub(index, index), source:sub(index, index + 1)
		local depth = templates[#templates]
		if depth == 0 then
			if char == "`" then
				templates[#templates] = nil
				if #templates == 0 then
					tokens[#tokens + 1] = source:sub(template_start, index)
				end
				index, regex_allowed, after_dot = index + 1, false, false
			elseif pair == "${" then
				templates[#templates] = 1
				index, regex_allowed, uncertain_prefix, after_dot = index + 2, true, false, false
			else
				index = index + (char == "\\" and 2 or 1)
			end
		elseif source:find("^%s", index) then
			index = index + 1
		elseif pair == "//" then
			index = line_end(source, index + 2)
		elseif pair == "/*" then
			local closing = source:find("*/", index + 2, true)
			if not closing then
				return nil
			end
			index = closing + 2
		elseif char == "`" then
			doubt_line_end = nil
			if #templates == 0 then
				template_start = index
			end
			templates[#templates + 1] = 0
			index = index + 1
		else
			local start = index
			local space = (source:byte(index) or 0) >= 128 and unicode_space(source, index)
			if space then
				index = index + space
			elseif char == "/" then
				local after = literal_end(source, index + 1, "/")
				if
					after
					and (not doubt_line_end or index >= doubt_line_end)
					and (doubt_line_end or not regex_allowed or uncertain_prefix)
				then
					doubt_line_end = clean_slash_line_end(source, index)
					if not doubt_line_end then
						return nil
					end
				end
				if regex_allowed and not after then
					return nil
				end
				index = regex_allowed and after or index + 1
				regex_allowed, uncertain_prefix, after_dot = not regex_allowed, false, false
			elseif char == "'" or char == '"' then
				local after = literal_end(source, index + 1, char)
				if not after then
					return nil
				end
				doubt_line_end = nil
				index, regex_allowed, after_dot = after, false, false
			else
				index = word_end(source, index)
				if index > start then
					local word = source:sub(start, index - 1)
					regex_allowed = regex_keywords[word] == true
					uncertain_prefix = after_dot or word == "of" or word == "yield" or word == "await"
					after_dot = false
				else
					if doubt_line_end and start >= doubt_line_end then
						doubt_line_end = nil
					end
					if depth and char == "{" then
						templates[#templates] = depth + 1
					elseif depth and char == "}" then
						templates[#templates] = depth - 1
					end
					index, regex_allowed = index + 1, char ~= ")" and char ~= "]"
					uncertain_prefix = char:find("[}+.>!%-]") ~= nil
					after_dot = char == "."
				end
			end
			if not space and #templates == 0 then
				tokens[#tokens + 1] = source:sub(start, index - 1)
			end
		end
	end
	return #templates == 0 and tokens or nil
end

local function code_matches(rt, options, dir, reviewed, current)
	local output = rt.path(dir, "source")
	local changed = rt.exec({
		"git",
		"diff",
		"--name-only",
		"-z",
		"--no-renames",
		"--no-relative",
		"--ignore-submodules=none",
		"--output=" .. output,
		reviewed,
		current,
		"--",
	}, options)
	local paths = changed.code == 0 and rt.read(output)
	if not paths or paths == "" then
		return false
	end
	local function read_blob(tree, file)
		local result = rt.exec({
			"sh",
			"-c",
			'git cat-file blob "$1" > "$2"',
			"orc",
			tree .. ":" .. file,
			output,
		}, options)
		return result.code == 0 and rt.read(output) or nil
	end
	for _, file in ipairs(vim.split(paths, "\0", { plain = true, trimempty = true })) do
		local before, after = read_blob(reviewed, file), read_blob(current, file)
		if not before or not after then
			return false
		end
		if file:sub(-4) == ".lua" then
			local old_chunk, new_chunk = loadstring(before), loadstring(after)
			if
				not old_chunk
				or not new_chunk
				or string.dump(old_chunk, true) ~= string.dump(new_chunk, true)
			then
				return false
			end
		else
			local old_tokens, new_tokens = typescript_tokens(before), typescript_tokens(after)
			if not old_tokens or not new_tokens or not vim.deep_equal(old_tokens, new_tokens) then
				return false
			end
		end
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
	local accepted = with_temp_dir(rt, function(dir)
		local raw_patch = rt.path(dir, "diff")
		local options = { cwd = path, env = { LC_ALL = "C" } }
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
		}, options)
		local patch = diff.code == 0 and rt.read(raw_patch)
		return patch
			and patch ~= ""
			and M.comment_only(patch)
			and code_matches(rt, options, dir, reviewed_tree, now)
	end) == true
	return accepted, accepted or nil
end

return M
