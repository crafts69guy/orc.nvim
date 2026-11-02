return function(api, t)
	local function json(value)
		return vim.json.decode(value)
	end
	local function valid(value, schema)
		t.eq(api.validate(value, schema), {})
	end
	local function invalid(value, schema, keyword, path)
		local errors = api.validate(value, schema)
		local found = false
		for _, entry in ipairs(errors) do
			assert(type(entry.message) == "string" and entry.message ~= "")
			if entry.keyword == keyword and entry.path == (path or "") then
				found = true
			end
		end
		assert(found, "missing " .. keyword .. " at " .. (path or ""))
	end
	t.test("schema booleans and invalid schema types", function()
		valid(vim.NIL, true)
		invalid("anything", false, "false")
		for _, schema in ipairs({ 1, "schema", vim.NIL, {} }) do
			t.error("TypeError", function()
				api.validate(1, schema)
			end)
		end
	end)
	for _, case in ipairs({
		{ "null", vim.NIL },
		{ "boolean", false },
		{ "object", vim.empty_dict() },
		{ "array", {} },
		{ "number", 1.2 },
		{ "integer", 1 },
		{ "string", "text" },
	}) do
		t.test("schema type " .. case[1], function()
			valid(case[2], { type = case[1] })
			invalid(case[2], { type = "unknown" }, "type")
		end)
	end
	t.test("schema union and exact integer", function()
		valid("x", { type = { "number", "string" } })
		invalid(1.5, { type = "integer" }, "type")
		invalid({}, { type = "object" }, "type")
		invalid(vim.empty_dict(), { type = "array" }, "type")
	end)
	t.test("schema JSON deep equality respects keys order types and array shape", function()
		valid(json('{"a":1,"b":[true,null]}'), { const = json('{"b":[true,null],"a":1}') })
		valid({ 1, 2 }, { enum = { false, { 1, 2 } } })
		invalid({ 1, 2 }, { const = { 1 } }, "const")
		invalid(json('{"a":1}'), { const = json('{"b":1}') }, "const")
		invalid(json('{"a":1}'), { const = json('{"a":2}') }, "const")
		invalid({}, { const = vim.empty_dict() }, "const")
		invalid(false, { enum = { true, 1 } }, "enum")
		valid(false, { const = false })
	end)
	t.test("schema objects required additional and escaped pointers", function()
		invalid(vim.empty_dict(), { required = { "a", "b" } }, "required")
		invalid({ extra = true }, { additionalProperties = false }, "additionalProperties")
		valid(
			{ allowed = 1 },
			{ properties = { allowed = { type = "number" } }, additionalProperties = false }
		)
		invalid({ extra = "x" }, { additionalProperties = { type = "number" } }, "type", "/extra")
		invalid(
			{ ["a/b~c"] = "x" },
			{ properties = { ["a/b~c"] = { type = "number" } } },
			"type",
			"/a~1b~0c"
		)
		invalid({ present = 1 }, { properties = { present = false } }, "false", "/present")
	end)
	t.test("schema arrays bounds and item pointers", function()
		valid({ 1, 2 }, { items = { type = "number" }, minItems = 2, maxItems = 2 })
		invalid({}, { minItems = 1 }, "minItems")
		invalid({ 1, 2 }, { maxItems = 1 }, "maxItems")
		invalid({ "x" }, { items = { type = "number" } }, "type", "/0")
	end)
	t.test("schema string codepoints patterns and numeric limits", function()
		valid("😀", { minLength = 1, maxLength = 1, pattern = "." })
		invalid("", { minLength = 1 }, "minLength")
		invalid("ab", { maxLength = 1 }, "maxLength")
		invalid("abc", { pattern = "^x" }, "pattern")
		invalid(1, { minimum = 2 }, "minimum")
		invalid(3, { maximum = 2 }, "maximum")
		valid(2, { minimum = 2, maximum = 2, minLength = 10 })
		valid(false, { minLength = 10, minimum = 100, items = false })
	end)
	t.test("schema conjunction disjunction and exclusive disjunction", function()
		invalid(3, { allOf = { { minimum = 4 }, { maximum = 2 } } }, "minimum")
		invalid(3, { allOf = { { minimum = 4 }, { maximum = 2 } } }, "maximum")
		valid(3, { anyOf = { { type = "string" }, { type = "number" } } })
		invalid(false, { anyOf = { { type = "string" }, { type = "number" } } }, "anyOf")
		valid(3, { oneOf = { { type = "string" }, { type = "number" } } })
		invalid(3, { oneOf = { { type = "integer" }, { type = "number" } } }, "oneOf")
		invalid(false, { oneOf = { { type = "string" }, { type = "number" } } }, "oneOf")
	end)
	t.test("schema references ignore siblings and recurse over finite JSON trees", function()
		local rule = {
			definitions = {
				node = {
					type = "object",
					properties = {
						value = { type = "number", minimum = 0 },
						children = { type = "array", items = { ["$ref"] = "#/definitions/node" } },
					},
				},
			},
			["$ref"] = "#/definitions/node",
			type = "boolean",
		}
		valid({ value = 1, children = { { value = 2 } } }, rule)
		invalid({ value = 1, children = { { value = -1 } } }, rule, "minimum", "/children/0/value")
		invalid(1, { definitions = { no = false }, ["$ref"] = "#/definitions/no" }, "false")
		for _, ref in ipairs({ "#/missing", "#/definitions/absent", false }) do
			t.error("ReferenceError", function()
				api.validate(1, { ["$ref"] = ref })
			end)
		end
		t.error("ReferenceError", function()
			api.validate(1, { definitions = {}, ["$ref"] = "#/definitions/x" })
		end)
		t.error("TypeError", function()
			api.validate({ 1 }, { items = 1 })
		end)
	end)
end
