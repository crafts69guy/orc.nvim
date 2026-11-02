return function(api, t)
	local ordered = {
		"1.0.0-alpha",
		"1.0.0-alpha.1",
		"1.0.0-alpha.beta",
		"1.0.0-beta",
		"1.0.0-beta.2",
		"1.0.0-beta.11",
		"1.0.0-rc.1",
		"1.0.0",
	}
	for index = 2, #ordered do
		t.test("semver precedence " .. index, function()
			t.eq(api.compare(ordered[index - 1], ordered[index]), -1)
			t.eq(api.compare(ordered[index], ordered[index - 1]), 1)
		end)
	end
	for _, case in ipairs({
		{ "1.0.0+a", "1.0.0+b", 0 },
		{ "1.0.0+001", "1.0.0", 0 },
		{ "1.0.0-a", "1.0.0-a", 0 },
		{ "10.0.0", "9.9.9", 1 },
		{ "1.1.0", "1.0.9", 1 },
		{ "1.0.2", "1.0.10", -1 },
		{ "999999999999999999999.0.0", "999999999999999999998.0.0", 1 },
		{ "1.0.0-999999999999999999998", "1.0.0-999999999999999999999", -1 },
		{ "1.0.0-1", "1.0.0-a", -1 },
		{ "1.0.0-a", "1.0.0-1", 1 },
		{ "1.0.0-z", "1.0.0-a", 1 },
		{ "0.0.0-a-b+build.01", "0.0.0-a-b+other", 0 },
	}) do
		t.test("semver " .. case[1] .. ":" .. case[2], function()
			t.eq(api.compare(case[1], case[2]), case[3])
		end)
	end
	for _, input in ipairs({
		"1",
		"1.2",
		"01.0.0",
		"1.01.0",
		"1.0.01",
		"v1.0.0",
		" 1.0.0",
		"1.0.0 ",
		"1.0.0-",
		"1.0.0+",
		"1.0.0-a..b",
		"1.0.0-01",
		"1.0.0+a..b",
		"1.0.0_a",
	}) do
		t.test("semver invalid " .. input, function()
			t.error("TypeError", function()
				api.compare(input, "1.0.0")
			end)
		end)
	end
	t.test("semver input types", function()
		t.error("TypeError", function()
			api.compare({}, "1.0.0")
		end)
		t.error("TypeError", function()
			api.compare("1.0.0", false)
		end)
	end)
end
