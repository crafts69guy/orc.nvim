local M = {}

---Parse strict long options. The separator `--` makes remaining arguments positional.
---@param argv string[] Arguments excluding the executable name.
---@param spec table<string,'boolean'|'string'> Supported option names and value types.
---@return table<string,string|boolean> values Flags that were supplied.
---@return string[] positionals Non-option arguments, preserving order.
function M.parse(argv, spec)
	local values, positionals = {}, {}
	local index, positional_only = 1, false
	while index <= #argv do
		local argument = argv[index]
		if positional_only then
			positionals[#positionals + 1] = argument
		elseif argument == "--" then
			positional_only = true
		elseif argument:sub(1, 1) == "-" then
			local name, value = argument:match("^%-%-([^=]+)=(.*)$")
			name = name or argument:match("^%-%-(.+)$")
			local kind = name and spec[name]
			assert(kind == "boolean" or kind == "string", "unknown option: " .. argument)
			assert(values[name] == nil, "duplicate option: --" .. name)
			if kind == "boolean" then
				assert(value == nil or value == "true" or value == "false", "--" .. name .. " needs true or false")
				values[name] = value ~= "false"
			else
				if value == nil then
					index = index + 1
					value = argv[index]
					assert(value ~= nil and value:sub(1, 2) ~= "--", "missing value for --" .. name)
				end
				values[name] = value
			end
		else
			positionals[#positionals + 1] = argument
		end
		index = index + 1
	end
	return values, positionals
end

return M
