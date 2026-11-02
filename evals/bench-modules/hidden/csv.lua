return function(api, t)
	for _, case in ipairs({
		{ "", {} },
		{ "a,b", { { "a", "b" } } },
		{ " a , b ", { { " a ", " b " } } },
		{ "a,,b", { { "a", "", "b" } } },
		{ ",", { { "", "" } } },
		{ '""', { { "" } } },
		{ '"a,b",c', { { "a,b", "c" } } },
		{ '"a""b"', { { 'a"b' } } },
		{ '"a\r\nb"', { { "a\r\nb" } } },
		{ "a\r\nb\n", { { "a" }, { "b" } } },
		{ "a\n\nb", { { "a" }, { "" }, { "b" } } },
		{ "a\n", { { "a" } } },
		{ "a\n\n", { { "a" }, { "" } } },
		{ "\n", { { "" } } },
		{ "a\rb", { { "a\rb" } } },
		{ '"a",\n', { { "a", "" } } },
		{ '"a"\r\nb,c', { { "a" }, { "b", "c" } } },
	}) do
		t.test("csv " .. vim.inspect(case[1]), function()
			t.eq(api.parse(case[1]), case[2])
		end)
	end
	for _, input in ipairs({ '"', '"a', 'a"b', '"a"b', '"a" ', '"a"\r' }) do
		t.test("csv invalid " .. input, function()
			t.error("SyntaxError", function()
				api.parse(input)
			end)
		end)
	end
	t.test("csv type", function()
		t.error("TypeError", function()
			api.parse(1)
		end)
	end)
end
