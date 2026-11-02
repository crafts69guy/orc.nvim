return function(api, t)
	local function utc(text)
		return vim.fn.strptime("%Y-%m-%dT%H:%M:%S%z", text .. "+0000") * 1000
	end
	t.test("cron fields steps names and weekday aliases", function()
		local parsed = api.parse("0,15-45/15 1-5/2 1,13 JAN,dec 5-7")
		t.eq(parsed.minute, { 0, 15, 30, 45 })
		t.eq(parsed.hour, { 1, 3, 5 })
		t.eq(parsed.dayOfMonth, { 1, 13 })
		t.eq(parsed.month, { 1, 12 })
		t.eq(parsed.dayOfWeek, { 0, 5, 6 })
		t.eq(api.parse("*/15 * * * mon-Fri").dayOfWeek, { 1, 2, 3, 4, 5 })
		t.eq(api.parse("0 0 * * 7").dayOfWeek, { 0 })
	end)
	t.test("cron rejects unrepresentable calendar timestamps", function()
		for _, value in ipairs({ 1e300, -1e300, -62135596800001, 253149840000000 }) do
			t.error("RangeError", function()
				api.next("* * * * *", value)
			end)
		end
		t.eq(api.next("* * * * *", -62135596800000), -62135596740000)
		t.eq(api.next("* * * * *", 253149839940000), 253149840000000)
	end)
	for _, macro in ipairs({
		"@yearly",
		"@annually",
		"@monthly",
		"@weekly",
		"@daily",
		"@midnight",
		"@hourly",
	}) do
		t.test("cron macro " .. macro, function()
			t.eq(api.parse(macro).minute, { 0 })
		end)
	end
	for _, text in ipairs({
		"",
		"* * * *",
		"* * * * * *",
		"@reboot",
		"@DAILY",
		"1,,2 * * * *",
		"1, * * * *",
		"5/15 * * * *",
		"1- * * * *",
		"-1 * * * *",
		"1.5 * * * *",
		"** * * * *",
		"*/ * * * *",
		"* * * JANUARY *",
		"JAN * * * *",
		"* * * * FRI-SUN/x",
		"* * * * */1/2",
	}) do
		t.test("cron syntax " .. text, function()
			t.error("SyntaxError", function()
				api.parse(text)
			end)
		end)
	end
	for _, text in ipairs({
		"60 * * * *",
		"* 24 * * *",
		"* * 0 * *",
		"* * * 13 *",
		"* * * * 8",
		"5-1 * * * *",
		"* * * * FRI-SUN",
		"*/0 * * * *",
	}) do
		t.test("cron range " .. text, function()
			t.error("RangeError", function()
				api.parse(text)
			end)
		end)
	end
	t.test("cron argument types", function()
		t.error("TypeError", function()
			api.parse(false)
		end)
		for _, value in ipairs({ false, "date", math.huge, 0 / 0 }) do
			t.error("TypeError", function()
				api.next("* * * * *", value)
			end)
		end
	end)
	for _, case in ipairs({
		{ "* * * * *", "2026-01-01T00:00:00", "2026-01-01T00:01:00" },
		{ "0 0 * * *", "2026-01-01T01:00:30", "2026-01-02T00:00:00" },
		{ "0 0 29 2 *", "2026-01-01T00:00:00", "2028-02-29T00:00:00" },
		{ "0 0 13 * FRI", "2026-02-12T00:00:00", "2026-02-13T00:00:00" },
		{ "0 0 13 * FRI", "2026-02-13T00:00:00", "2026-02-20T00:00:00" },
		{ "0 0 13 * FRI", "2026-03-12T00:00:00", "2026-03-13T00:00:00" },
		{ "0 0 13 * FRI", "2026-04-12T00:00:00", "2026-04-13T00:00:00" },
		{ "0 0 * * MON", "2026-01-01T00:00:00", "2026-01-05T00:00:00" },
		{ "0 1,2 * * *", "2026-01-01T01:30:00", "2026-01-01T02:00:00" },
	}) do
		t.test("cron next " .. case[1] .. case[2], function()
			t.eq(api.next(case[1], utc(case[2])), utc(case[3]))
		end)
	end
	t.test("cron impossible dates stop within eight years", function()
		t.eq(api.next("0 0 30 2 *", utc("2026-01-01T00:00:00")), vim.NIL)
	end)
end
