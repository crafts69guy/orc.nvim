local args = require("orc.args")

Test.test("args parses values, booleans, operands and separator", function()
	local values, operands = args.parse({ "start", "--path=a b", "--here", "--", "--literal", "-x" }, {
		path = "string",
		here = "boolean",
	})
	Test.eq(values, { path = "a b", here = true })
	Test.eq(operands, { "start", "--literal", "-x" })
	Test.eq(args.parse({ "--flag=false" }, { flag = "boolean" }), { flag = false })
	Test.eq(args.parse({ "--flag=true" }, { flag = "boolean" }), { flag = true })
	Test.eq(args.parse({ "--value", "-1" }, { value = "string" }), { value = "-1" })
	Test.eq(args.parse({ "--value=" }, { value = "string" }), { value = "" })
end)

Test.test("args rejects unknown, duplicate and missing options", function()
	for _, argv in ipairs({ { "--unknown" }, { "-x" }, { "--=value" } }) do
		Test.raises("unknown option", function()
			args.parse(argv, {})
		end)
	end
	Test.raises("duplicate option", function()
		args.parse({ "--flag=false", "--flag" }, { flag = "boolean" })
	end)
	for _, argv in ipairs({ { "--value" }, { "--value", "--flag" } }) do
		Test.raises("missing value", function()
			args.parse(argv, { value = "string", flag = "boolean" })
		end)
	end
	Test.raises("needs true or false", function()
		args.parse({ "--flag=yes" }, { flag = "boolean" })
	end)
end)
