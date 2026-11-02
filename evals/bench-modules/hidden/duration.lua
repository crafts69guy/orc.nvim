return function(api, t)
	for _, case in ipairs({
		{ "1h30m15s", 5415000 },
		{ "250ms", 250 },
		{ "2d", 172800000 },
		{ "1m30s500ms", 90500 },
		{ "0s", 0 },
		{ "05m", 300000 },
		{ " 1d2h3m4s5ms ", 93784005 },
		{ "9007199254740991ms", 9007199254740991 },
	}) do
		t.test("duration " .. case[1], function()
			t.eq(api.parseDuration(case[1]), case[2])
		end)
	end
	for _, input in ipairs({
		"",
		" ",
		"h",
		"10",
		"5w",
		"1s1m",
		"1m1m",
		"-1s",
		"+1s",
		"1.5s",
		"1s 1ms",
		"1H",
		"1e2s",
	}) do
		t.test("duration rejects " .. input, function()
			t.error("SyntaxError", function()
				api.parseDuration(input)
			end)
		end)
	end
	t.test("duration input type", function()
		t.error("TypeError", function()
			api.parseDuration(false)
		end)
	end)
	t.test("duration safe range", function()
		t.error("RangeError", function()
			api.parseDuration("9007199254740992ms")
		end)
		t.error("RangeError", function()
			api.parseDuration("999999999999999999999999999999d")
		end)
	end)
end
