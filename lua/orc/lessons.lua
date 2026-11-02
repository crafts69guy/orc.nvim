local M = {}

---Parse approved lesson rows, retaining malformed rows for audit diagnostics.
---@param text string
---@return table[] lessons
---@return integer[] malformed One-based line numbers of invalid lesson rows.
function M.parse(text)
	local lessons, malformed = {}, {}
	local line_number = 0
	for line in (text:gsub("\r\n", "\n") .. "\n"):gmatch("([^\n]*)\n") do
		line_number = line_number + 1
		local id, up, down, scope, feature, body =
			line:match("^%- %[(L%d%d%d%d*)%] %+(%d+) %-(%d+) ([%w]+) · (.-) · (.+)$")
		if
			id
			and feature ~= ""
			and not feature:find("·", 1, true)
			and (scope == "project" or scope == "orc")
		then
			lessons[#lessons + 1] = {
				id = id,
				up = tonumber(up),
				down = tonumber(down),
				scope = scope,
				feature = feature,
				text = body,
				line = line,
			}
		elseif line:sub(1, 3) == "- [" then
			malformed[#malformed + 1] = line_number
		end
	end
	return lessons, malformed
end

---Select the best active approved lessons; never mutate the caller's collection.
---@param lessons table[]
---@param cap? integer
---@return table[]
function M.select(lessons, cap)
	local active, positions = {}, {}
	for index, lesson in ipairs(lessons) do
		positions[lesson] = index
		if lesson.down < lesson.up then
			active[#active + 1] = lesson
		end
	end
	table.sort(active, function(a, b)
		local first, second = a.up - a.down, b.up - b.down
		return first == second and positions[a] < positions[b] or first > second
	end)
	return vim.list_slice(active, 1, cap or 40)
end

---Read the active memory from the main checkout, also from linked worktrees.
---@param rt orc.Runtime
---@param cwd? string
---@return string
function M.read(rt, cwd)
	local root = require("orc.worktrees").root(rt, cwd)
	if not root then
		return ""
	end
	local text = rt.read(rt.path(root, ".orc", "lessons.md")) or ""
	local parsed = M.parse(text)
	local selected = M.select(parsed)
	local lines = {}
	for _, lesson in ipairs(selected) do
		lines[#lines + 1] = lesson.line
	end
	return table.concat(lines, "\n")
end

return M
