local M = {}
local function fail(kind, message)
	error({ kind = kind, message = message }, 0)
end

---Parse RFC4180-style CSV; lone carriage returns are field data.
---@param text string
---@return string[][]
function M.parse(text)
	if type(text) ~= "string" then
		fail("TypeError", "CSV must be a string")
	end
	if text == "" then
		return {}
	end
	local rows, row, field, position = {}, {}, {}, 1
	local quoted, closed, open = false, false, true
	local function finish_field()
		row[#row + 1], field, closed = table.concat(field), {}, false
	end
	while position <= #text do
		local char, following = text:sub(position, position), text:sub(position + 1, position + 1)
		if quoted then
			if char == '"' then
				if following == '"' then
					field[#field + 1], position = '"', position + 1
				else
					quoted, closed = false, true
				end
			else
				field[#field + 1] = char
			end
		elseif char == "," then
			finish_field()
			open = true
		elseif char == "\n" or (char == "\r" and following == "\n") then
			finish_field()
			rows[#rows + 1], row, open = row, {}, false
			if char == "\r" then
				position = position + 1
			end
		elseif closed then
			fail("SyntaxError", "characters after closing quote")
		elseif char == '"' then
			if #field ~= 0 then
				fail("SyntaxError", "quote inside unquoted field")
			end
			quoted, open = true, true
		else
			field[#field + 1], open = char, true
		end
		position = position + 1
	end
	if quoted then
		fail("SyntaxError", "unterminated quoted field")
	end
	if open then
		finish_field()
		rows[#rows + 1] = row
	end
	return rows
end
return M
