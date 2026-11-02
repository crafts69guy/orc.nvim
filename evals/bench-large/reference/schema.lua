local M = {}
local function fail(kind, message)
	error({ kind = kind, message = message }, 0)
end
local function object(value)
	return type(value) == "table" and not vim.islist(value)
end
local function pointer(path, key)
	return path .. "/" .. tostring(key):gsub("~", "~0"):gsub("/", "~1")
end
local function equal(a, b)
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" or vim.islist(a) ~= vim.islist(b) then
		return false
	end
	if vim.tbl_count(a) ~= vim.tbl_count(b) then
		return false
	end
	for key, value in pairs(a) do
		if rawget(b, key) == nil or not equal(value, b[key]) then
			return false
		end
	end
	return true
end
local function matches(value, name)
	if name == "null" then
		return value == vim.NIL
	elseif name == "boolean" then
		return type(value) == "boolean"
	elseif name == "object" then
		return object(value)
	elseif name == "array" then
		return type(value) == "table" and vim.islist(value)
	elseif name == "number" then
		return type(value) == "number"
	elseif name == "integer" then
		return type(value) == "number" and value % 1 == 0
	elseif name == "string" then
		return type(value) == "string"
	end
	return false
end

---Validate a JSON value against the documented draft-07 subset.
---JSON null is vim.NIL; use vim.empty_dict() to distinguish empty objects from arrays.
---@param value any
---@param schema table|boolean
---@return table[]
function M.validate(value, schema)
	local errors = {}
	local function check(current, rule, path, output)
		local function reject(keyword)
			output[#output + 1] = { path = path, keyword = keyword, message = "failed " .. keyword }
		end
		if rule == true then
			return
		end
		if rule == false then
			reject("false")
			return
		end
		if not object(rule) then
			fail("TypeError", "schema must be an object or boolean")
		end
		if rule["$ref"] ~= nil then
			local ref = type(rule["$ref"]) == "string" and rule["$ref"]:match("^#/definitions/(.+)$")
			if not ref or not object(schema.definitions) or rawget(schema.definitions, ref) == nil then
				fail("ReferenceError", "unresolved schema reference")
			end
			check(current, schema.definitions[ref], path, output)
			return
		end
		if rule.type ~= nil then
			local types = type(rule.type) == "table" and rule.type or { rule.type }
			local valid = false
			for _, name in ipairs(types) do
				if matches(current, name) then
					valid = true
					break
				end
			end
			if not valid then
				reject("type")
			end
		end
		if rule.enum ~= nil then
			local valid = false
			for _, candidate in ipairs(rule.enum) do
				if equal(current, candidate) then
					valid = true
					break
				end
			end
			if not valid then
				reject("enum")
			end
		end
		if rule.const ~= nil and not equal(current, rule.const) then
			reject("const")
		end
		if object(current) then
			for _, key in ipairs(rule.required or {}) do
				if rawget(current, key) == nil then
					reject("required")
				end
			end
			local properties = rule.properties or {}
			for key, entry in pairs(current) do
				if rawget(properties, key) ~= nil then
					check(entry, properties[key], pointer(path, key), output)
				elseif rule.additionalProperties == false then
					reject("additionalProperties")
				elseif rule.additionalProperties ~= nil then
					check(entry, rule.additionalProperties, pointer(path, key), output)
				end
			end
		elseif type(current) == "table" then
			if rule.items ~= nil then
				for index, entry in ipairs(current) do
					check(entry, rule.items, pointer(path, index - 1), output)
				end
			end
			if rule.minItems and #current < rule.minItems then
				reject("minItems")
			end
			if rule.maxItems and #current > rule.maxItems then
				reject("maxItems")
			end
		elseif type(current) == "string" then
			local size = vim.fn.strchars(current)
			if rule.minLength and size < rule.minLength then
				reject("minLength")
			end
			if rule.maxLength and size > rule.maxLength then
				reject("maxLength")
			end
			if rule.pattern and not current:find(rule.pattern) then
				reject("pattern")
			end
		elseif type(current) == "number" then
			if rule.minimum and current < rule.minimum then
				reject("minimum")
			end
			if rule.maximum and current > rule.maximum then
				reject("maximum")
			end
		end
		for _, child in ipairs(rule.allOf or {}) do
			check(current, child, path, output)
		end
		for _, keyword in ipairs({ "anyOf", "oneOf" }) do
			if rule[keyword] then
				local passed = 0
				for _, child in ipairs(rule[keyword]) do
					local trial = {}
					check(current, child, path, trial)
					if #trial == 0 then
						passed = passed + 1
					end
				end
				if (keyword == "anyOf" and passed == 0) or (keyword == "oneOf" and passed ~= 1) then
					reject(keyword)
				end
			end
		end
	end
	check(value, schema, "", errors)
	return errors
end
return M
