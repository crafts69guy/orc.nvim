local M = {}
local units =
	{ d = { 1, 86400000 }, h = { 2, 3600000 }, m = { 3, 60000 }, s = { 4, 1000 }, ms = { 5, 1 } }
local function fail(kind, message)
	error({ kind = kind, message = message }, 0)
end

---Parse ordered duration segments into an exactly representable millisecond count.
---@param text string
---@return number
function M.parseDuration(text)
	if type(text) ~= "string" then
		fail("TypeError", "duration must be a string")
	end
	text = vim.trim(text)
	if text == "" then
		fail("SyntaxError", "empty duration")
	end
	local total, position, previous = 0, 1, 0
	while position <= #text do
		local digits, unit, last = text:match("^([0-9]+)([a-z]+)()", position)
		local definition = units[unit]
		if not digits or not definition or definition[1] <= previous then
			fail("SyntaxError", "invalid duration segment")
		end
		local amount = tonumber(digits) * definition[2]
		if amount > 9007199254740991 - total then
			fail("RangeError", "duration exceeds safe integer")
		end
		total, previous, position = total + amount, definition[1], last
	end
	return total
end
return M
