local M = {}
local fields = {
	{ "minute", 0, 59 },
	{ "hour", 0, 23 },
	{ "dayOfMonth", 1, 31 },
	{
		"month",
		1,
		12,
		{
			JAN = 1,
			FEB = 2,
			MAR = 3,
			APR = 4,
			MAY = 5,
			JUN = 6,
			JUL = 7,
			AUG = 8,
			SEP = 9,
			OCT = 10,
			NOV = 11,
			DEC = 12,
		},
	},
	{ "dayOfWeek", 0, 7, { SUN = 0, MON = 1, TUE = 2, WED = 3, THU = 4, FRI = 5, SAT = 6 } },
}
local macros = {
	["@yearly"] = "0 0 1 1 *",
	["@annually"] = "0 0 1 1 *",
	["@monthly"] = "0 0 1 * *",
	["@weekly"] = "0 0 * * 0",
	["@daily"] = "0 0 * * *",
	["@midnight"] = "0 0 * * *",
	["@hourly"] = "0 * * * *",
}
local function fail(kind, message)
	error({ kind = kind, message = message }, 0)
end
local function expression(text)
	if type(text) ~= "string" then
		fail("TypeError", "cron must be a string")
	end
	text = vim.trim(text)
	if text:sub(1, 1) == "@" then
		text = macros[text]
		if not text then
			fail("SyntaxError", "unknown cron macro")
		end
	end
	local result = vim.split(text, "[ \t]+")
	if #result ~= 5 then
		fail("SyntaxError", "cron requires five fields")
	end
	return result
end
local function value(token, field)
	local number
	if token:match("^[0-9]+$") then
		number = tonumber(token)
	else
		number = field[4] and field[4][token:upper()]
	end
	if number == nil then
		fail("SyntaxError", "unknown field value")
	end
	if number < field[2] or number > field[3] then
		fail("RangeError", "field value out of range")
	end
	return number
end
local function parse_field(text, field)
	local seen, result = {}, {}
	for _, item in ipairs(vim.split(text, ",", { plain = true })) do
		local parts = vim.split(item, "/", { plain = true })
		if #parts > 2 or (#parts == 2 and not parts[2]:match("^[0-9]+$")) then
			fail("SyntaxError", "invalid step")
		end
		local base, step = parts[1], tonumber(parts[2] or "1")
		if step == 0 then
			fail("RangeError", "step must be positive")
		end
		local low, high
		if base == "*" then
			low, high = field[2], field[3]
		else
			local first, last = base:match("^([0-9A-Za-z]+)%-([0-9A-Za-z]+)$")
			if first then
				low, high = value(first, field), value(last, field)
			elseif base:match("^[0-9A-Za-z]+$") and #parts == 1 then
				low = value(base, field)
				high = low
			else
				fail("SyntaxError", "invalid cron item")
			end
		end
		if low > high then
			fail("RangeError", "reversed cron range")
		end
		for number = low, high, step do
			seen[field[1] == "dayOfWeek" and number % 7 or number] = true
		end
	end
	for number in pairs(seen) do
		result[#result + 1] = number
	end
	table.sort(result)
	return result
end

---Parse five cron fields into sorted integer arrays.
---@param text string
---@return table
function M.parse(text)
	local parts, result = expression(text), {}
	for index, field in ipairs(fields) do
		result[field[1]] = parse_field(parts[index], field)
	end
	return result
end

---Return earliest matching whole UTC minute strictly after epoch milliseconds.
---@param text string
---@param from number
---@return number|userdata
function M.next(text, from)
	local parts, sets = expression(text), M.parse(text)
	if type(from) ~= "number" or from ~= from or math.abs(from) == math.huge then
		fail("TypeError", "from must be finite epoch milliseconds")
	end
	if from < -62135596800000 or from >= 253149840000000 then
		fail("RangeError", "from must be in UTC years 0001 through 9991")
	end
	local start = math.floor(from / 60000) * 60000 + 60000
	local utc = os.date("!*t", math.floor(from / 1000))
	local limit = vim.fn.strptime(
		"%Y-%m-%dT%H:%M:%S%z",
		string.format(
			"%04d-%02d-%02dT%02d:%02d:%02d+0000",
			utc.year + 8,
			utc.month,
			utc.day,
			utc.hour,
			utc.min,
			utc.sec
		)
	) * 1000
	local day = math.floor(start / 86400000) * 86400000
	while day <= limit do
		local date = os.date("!*t", day / 1000)
		local dom, dow =
			vim.tbl_contains(sets.dayOfMonth, date.day), vim.tbl_contains(sets.dayOfWeek, date.wday - 1)
		local either = parts[3] ~= "*" and parts[5] ~= "*"
		local matches = either and (dom or dow) or (not either and dom and dow)
		if vim.tbl_contains(sets.month, date.month) and matches then
			for _, hour in ipairs(sets.hour) do
				for _, minute in ipairs(sets.minute) do
					local candidate = day + hour * 3600000 + minute * 60000
					if candidate >= start then
						return candidate <= limit and candidate or vim.NIL
					end
				end
			end
		end
		day = day + 86400000
	end
	return vim.NIL
end
return M
