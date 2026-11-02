return function(api, t)
	for _, case in ipairs({
		{ "1+2*3", 7 },
		{ "(1+2)*3", 9 },
		{ "-2 ^ 2", -4 },
		{ "2 ^ -1", 0.5 },
		{ "2 ^ 3 ^ 2", 512 },
		{ "1e2 + 1.5e+1 - 1.0E-1", 114.9 },
		{ "7/2", 3.5 },
		{ "-7%3", -1 },
		{ "true && false", false },
		{ "false && missing", false },
		{ "true || missing", true },
		{ "false || true", true },
		{ "true ? 1 : 1/0", 1 },
		{ "false ? missing : 2", 2 },
		{ "true ? false ? 1 : 2 : 3", 2 },
		{ "!false", true },
		{ "!!true", true },
		{ "true == true", true },
		{ "1 != 2", true },
		{ "1 < 2", true },
		{ "2 <= 2", true },
		{ "3 > 2", true },
		{ "3 >= 3", true },
		{ "4 - 1 - 1", 2 },
		{ "abs(-2)", 2 },
		{ "floor(1.9)", 1 },
		{ "ceil(1.1)", 2 },
		{ "round(2.5)", 3 },
		{ "round(-2.5)", -3 },
		{ "sqrt(4)", 2 },
		{ "min(3,1,2)", 1 },
		{ "max(3,1,2)", 3 },
		{ " \t1\n+2 ", 3 },
		{ "1.25", 1.25 },
		{ "x + 1", 3, { x = 2 } },
		{ "flag && true", false, { flag = false } },
	}) do
		t.test("expr " .. case[1], function()
			t.eq(api.evaluate(case[1], case[3]), case[2])
		end)
	end
	for _, case in ipairs({
		{ "", 0 },
		{ "1 +", 3 },
		{ "(1", 2 },
		{ "1 2", 2 },
		{ ")", 0 },
		{ "1 # 2", 2 },
		{ "1 = 2", 2 },
		{ "max(1,)", 6 },
		{ "1.", 1 },
		{ "1 2 #", 4 },
		{ ".5", 0 },
		{ "&", 0 },
	}) do
		t.test("expr syntax " .. case[1], function()
			t.error("SyntaxError", function()
				api.evaluate(case[1])
			end, case[2])
		end)
	end
	for _, source in ipairs({ "missing", "unknown(1)", "toString(1)" }) do
		t.test("expr reference " .. source, function()
			t.error("ReferenceError", function()
				api.evaluate(source)
			end)
		end)
	end
	for _, source in ipairs({
		"1+true",
		"1<2<3",
		"1&&true",
		"!1",
		"-false",
		"1?2:3",
		"1==true",
		"true!=2",
		"abs()",
		"abs(1,2)",
		"min()",
		"sqrt(true)",
	}) do
		t.test("expr type " .. source, function()
			t.error("TypeError", function()
				api.evaluate(source)
			end)
		end)
	end
	for _, source in ipairs({ "1/0", "1%0", "sqrt(-1)" }) do
		t.test("expr range " .. source, function()
			t.error("RangeError", function()
				api.evaluate(source)
			end)
		end)
	end
	t.test("expr rejects nonfinite variables and inherited lookups", function()
		for _, value in ipairs({ "text", {}, math.huge, 0 / 0 }) do
			t.error("TypeError", function()
				api.evaluate("x", { x = value })
			end)
		end
		t.error("ReferenceError", function()
			api.evaluate("x", setmetatable({}, { __index = { x = 1 } }))
		end)
		t.error("TypeError", function()
			api.evaluate(false)
		end)
		t.error("TypeError", function()
			api.evaluate("1", false)
		end)
	end)
end
