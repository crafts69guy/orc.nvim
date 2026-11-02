local M = {}
local precedence = {
	["||"] = 2,
	["&&"] = 3,
	["=="] = 4,
	["!="] = 4,
	["<"] = 5,
	["<="] = 5,
	[">"] = 5,
	[">="] = 5,
	["+"] = 6,
	["-"] = 6,
	["*"] = 7,
	["/"] = 7,
	["%"] = 7,
	["^"] = 9,
}
local function fail(kind, message, position)
	error({ kind = kind, message = message, position = position }, 0)
end
local function typed(value, expected)
	if type(value) ~= expected then
		fail("TypeError", "operand must be a " .. expected)
	end
	return value
end
local function tokenize(source)
	local result, position = {}, 1
	while position <= #source do
		local char = source:sub(position, position)
		if char:match("%s") then
			position = position + 1
		else
			local rest, token = source:sub(position), nil
			for _, pattern in ipairs({
				"^[0-9]+%.[0-9]+[eE][+-]?[0-9]+",
				"^[0-9]+[eE][+-]?[0-9]+",
				"^[0-9]+%.[0-9]+",
				"^[0-9]+",
			}) do
				token = rest:match(pattern)
				if token then
					break
				end
			end
			local kind, value
			if token then
				kind, value = "literal", tonumber(token)
			else
				token = rest:match("^[A-Za-z_][A-Za-z0-9_]*")
				if token == "true" or token == "false" then
					kind, value = "literal", token == "true"
				elseif token then
					kind, value = "variable", token
				else
					local pair = rest:sub(1, 2)
					if precedence[pair] then
						token = pair
					elseif ("()?:,<>+-*/%!^"):find(char, 1, true) then
						token = char
					else
						fail("SyntaxError", "unexpected character", position - 1)
					end
					kind, value = "operator", token
				end
			end
			result[#result + 1] = { kind = kind, value = value, position = position - 1 }
			position = position + #token
		end
	end
	result[#result + 1] = { kind = "end", position = #source }
	return result
end
local function parse(tokens)
	local index, expression = 1, nil
	local function expect(value)
		if tokens[index].value ~= value then
			fail("SyntaxError", "expected " .. value, tokens[index].position)
		end
		index = index + 1
	end
	local function primary()
		local token = tokens[index]
		index = index + 1
		if token.kind == "literal" then
			return token
		end
		if token.kind == "variable" then
			if tokens[index].value ~= "(" then
				return token
			end
			index = index + 1
			local arguments = {}
			if tokens[index].value ~= ")" then
				arguments[#arguments + 1] = expression(1)
				while tokens[index].value == "," do
					index = index + 1
					arguments[#arguments + 1] = expression(1)
				end
			end
			expect(")")
			return { kind = "call", value = token.value, arguments = arguments }
		end
		if token.value == "(" then
			local value = expression(1)
			expect(")")
			return value
		end
		if token.value == "-" or token.value == "!" then
			return { kind = "prefix", value = token.value, operand = expression(8) }
		end
		fail("SyntaxError", "unexpected token", token.position)
	end
	expression = function(minimum)
		local left = primary()
		local current = tokens[index].value
		while precedence[current] and precedence[current] >= minimum do
			index = index + 1
			local right = expression(precedence[current] + (current == "^" and 0 or 1))
			left = { kind = "binary", value = current, left = left, right = right }
			current = tokens[index].value
		end
		if minimum == 1 and current == "?" then
			index = index + 1
			local yes = expression(1)
			expect(":")
			left = { kind = "conditional", condition = left, yes = yes, no = expression(1) }
		end
		return left
	end
	local result = expression(1)
	if tokens[index].kind ~= "end" then
		fail("SyntaxError", "unexpected token", tokens[index].position)
	end
	return result
end
local functions = {
	abs = { 1, math.abs },
	floor = { 1, math.floor },
	ceil = { 1, math.ceil },
	min = { -1, math.min },
	max = { -1, math.max },
	round = {
		1,
		function(value)
			return (value < 0 and -1 or 1) * math.floor(math.abs(value) + 0.5)
		end,
	},
	sqrt = {
		1,
		function(value)
			if value < 0 then
				fail("RangeError", "sqrt of negative number")
			end
			return math.sqrt(value)
		end,
	},
}
local function evaluate(node, variables)
	if node.kind == "literal" then
		return node.value
	end
	if node.kind == "variable" then
		local value = rawget(variables, node.value)
		if value == nil then
			fail("ReferenceError", "unknown variable " .. node.value)
		end
		if
			type(value) == "boolean"
			or (type(value) == "number" and value == value and math.abs(value) ~= math.huge)
		then
			return value
		end
		fail("TypeError", "variable must be a finite number or boolean")
	end
	if node.kind == "conditional" then
		if typed(evaluate(node.condition, variables), "boolean") then
			return evaluate(node.yes, variables)
		end
		return evaluate(node.no, variables)
	end
	if node.kind == "call" then
		local fn = functions[node.value]
		if not fn then
			fail("ReferenceError", "unknown function " .. node.value)
		end
		if (fn[1] == -1 and #node.arguments == 0) or (fn[1] ~= -1 and #node.arguments ~= fn[1]) then
			fail("TypeError", "wrong function arity")
		end
		local arguments = {}
		for _, argument in ipairs(node.arguments) do
			arguments[#arguments + 1] = typed(evaluate(argument, variables), "number")
		end
		return fn[2](unpack(arguments))
	end
	local operator = node.value
	if node.kind == "prefix" then
		local value = evaluate(node.operand, variables)
		if operator == "!" then
			return not typed(value, "boolean")
		end
		return -typed(value, "number")
	end
	local left = evaluate(node.left, variables)
	if operator == "&&" then
		if not typed(left, "boolean") then
			return false
		end
		return typed(evaluate(node.right, variables), "boolean")
	elseif operator == "||" then
		if typed(left, "boolean") then
			return true
		end
		return typed(evaluate(node.right, variables), "boolean")
	end
	local right = evaluate(node.right, variables)
	if operator == "==" or operator == "!=" then
		if type(left) ~= type(right) or (type(left) ~= "number" and type(left) ~= "boolean") then
			fail("TypeError", "incompatible equality operands")
		end
		if operator == "==" then
			return left == right
		end
		return left ~= right
	end
	left, right = typed(left, "number"), typed(right, "number")
	if operator == "+" then
		return left + right
	elseif operator == "-" then
		return left - right
	elseif operator == "*" then
		return left * right
	elseif operator == "^" then
		return left ^ right
	elseif operator == "<" then
		return left < right
	elseif operator == "<=" then
		return left <= right
	elseif operator == ">" then
		return left > right
	elseif operator == ">=" then
		return left >= right
	end
	if right == 0 then
		fail("RangeError", "division by zero")
	end
	if operator == "/" then
		return left / right
	end
	return math.fmod(left, right)
end

---Evaluate a complete expression with strict types and short-circuit semantics.
---@param source string
---@param variables? table
---@return number|boolean
function M.evaluate(source, variables)
	if type(source) ~= "string" or (variables ~= nil and type(variables) ~= "table") then
		fail("TypeError", "invalid expression arguments")
	end
	return evaluate(parse(tokenize(source)), variables or {})
end
return M
