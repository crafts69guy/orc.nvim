local M = {}
local function fail()
	error({ kind = "TypeError", message = "invalid semantic version" }, 0)
end
local function numeric(text)
	return text:match("^[0-9]+$") ~= nil
end
local function identifiers(text, prerelease)
	local result = vim.split(text, ".", { plain = true })
	for _, part in ipairs(result) do
		if
			not part:match("^[0-9A-Za-z-]+$")
			or (prerelease and numeric(part) and #part > 1 and part:sub(1, 1) == "0")
		then
			fail()
		end
	end
	return result
end
local function parse(text)
	if type(text) ~= "string" then
		fail()
	end
	local major, minor, patch, tail = text:match("^([0-9]+)%.([0-9]+)%.([0-9]+)(.*)$")
	if not major then
		fail()
	end
	for _, value in ipairs({ major, minor, patch }) do
		if #value > 1 and value:sub(1, 1) == "0" then
			fail()
		end
	end
	local pre
	if tail:sub(1, 1) == "-" then
		local part, rest = tail:match("^%-([^+]*)(.*)$")
		pre, tail = identifiers(part, true), rest
	end
	if tail ~= "" then
		if tail:sub(1, 1) ~= "+" then
			fail()
		end
		identifiers(tail:sub(2), false)
	end
	return { major, minor, patch }, pre
end
local function compare_number(a, b)
	if #a ~= #b then
		return #a < #b and -1 or 1
	end
	if a == b then
		return 0
	end
	return a < b and -1 or 1
end

---Compare SemVer precedence without converting unbounded numeric identifiers.
---@param a string
---@param b string
---@return integer
function M.compare(a, b)
	local first, pre_a = parse(a)
	local second, pre_b = parse(b)
	for index = 1, 3 do
		local order = compare_number(first[index], second[index])
		if order ~= 0 then
			return order
		end
	end
	if not pre_a and not pre_b then
		return 0
	end
	if not pre_a then
		return 1
	end
	if not pre_b then
		return -1
	end
	for index = 1, math.max(#pre_a, #pre_b) do
		local left, right = pre_a[index], pre_b[index]
		if not left then
			return -1
		end
		if not right then
			return 1
		end
		if left ~= right then
			if numeric(left) and numeric(right) then
				return compare_number(left, right)
			end
			if numeric(left) then
				return -1
			end
			if numeric(right) then
				return 1
			end
			return left < right and -1 or 1
		end
	end
	return 0
end
return M
