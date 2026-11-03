local runtime = require("orc.runtime")

local function fake()
	local rt = runtime.new({ root = "/plugin", cwd = "/repo" })
	rt.env = { HOME = "/home/u" }
	rt.exists = function(path)
		return path == "/plugin/hooks/hooks.json"
	end
	rt.read = function() end
	rt.list = function()
		return {}
	end
	rt.exec = function(argv, opts)
		local stdout = "fixture\n"
		if argv[1] == "git" then
			stdout = argv[2] == "rev-parse" and "/repo/.git\n"
				or "orc.inkdropbook book:main\norc.inkdropbookname Main\norc.inkdroptag tag:orc\n"
		elseif argv[1] == "curl" then
			Test.eq(argv, { "curl", "--disable", "--config", "-" })
			assert(opts.stdin:find(vim.base64.encode("private-user:private-password"), 1, true))
			assert(opts.stdin:find("127.0.0.1:19840", 1, true))
			stdout = '{"version":"6.3.0"}\n200'
		end
		return { code = 0, signal = 0, stdout = stdout, stderr = "" }
	end
	return rt
end

local function with_mcp(module, fn)
	local previous = package.loaded["orc.inkdrop_mcp"]
	package.loaded["orc.inkdrop_mcp"] = module
	local ok, err = xpcall(fn, debug.traceback)
	package.loaded["orc.inkdrop_mcp"] = previous
	assert(ok, err)
end

local credentials = {
	INKDROP_LOCAL_USERNAME = "private-user",
	INKDROP_LOCAL_PASSWORD = "private-password",
	INKDROP_LOCAL_SERVER_URL = "http://127.0.0.1:19840",
}

Test.test(
	"shared_integrations REST uses private credentials without provider environment secrets",
	function()
		local rt = fake()
		with_mcp({
			credentials = function()
				return credentials
			end,
		}, function()
			local inkdrop = require("orc.inkdrop")
			Test.eq(inkdrop.enabled(rt), true)
			Test.eq(inkdrop.flag(rt), { id = "book:main", name = "Main" })
			Test.eq(inkdrop.probe(rt), { version = "6.3.0" })
			rt.env.INKDROP_LOCAL_USERNAME, rt.env.INKDROP_LOCAL_PASSWORD = "stale", "stale"
			Test.eq(inkdrop.probe(rt), { version = "6.3.0" })
			rt.env.ORC_INKDROP = "0"
			Test.eq(inkdrop.enabled(rt), false)
		end)
		with_mcp({
			credentials = function()
				error("private source invalid", 0)
			end,
		}, function()
			rt.env.ORC_INKDROP = nil
			Test.eq(require("orc.inkdrop").enabled(rt), false)
			assert(require("orc.inkdrop").probe(rt).error:find("private source invalid", 1, true))
		end)
	end
)

Test.test("shared_integrations doctor distinguishes MCP from private REST credentials", function()
	local rt = fake()
	local module = {
		resolve = function()
			return { mode = "shared", url = "http://127.0.0.1:19841/mcp" }
		end,
		credentials = function()
			return credentials
		end,
		check = function()
			return { ok = true }
		end,
	}
	with_mcp(module, function()
		local doctor = require("orc.doctor")
		local document = doctor.collect(rt)
		local found = {}
		for _, check in ipairs(document.checks) do
			found[check.name] = check.status
		end
		Test.eq(found["inkdrop-mcp"], "pass")
		Test.eq(found.inkdrop, "pass")
		assert(not rt.encode(document):find("private-password", 1, true))
		module.check = function()
			return { ok = false, error = "endpoint unavailable" }
		end
		Test.eq(doctor.run(rt, {}).code, 1)
		module.resolve = function()
			error("invalid shared settings", 0)
		end
		Test.eq(doctor.run(rt, {}).code, 1)
		module.resolve = function()
			return { mode = "inherit" }
		end
		module.credentials = function()
			error("private credential file rejected", 0)
		end
		local checks = doctor.collect(rt).checks
		Test.eq(checks[#checks].status, "warn")
		rt.env.ORC_INKDROP = "0"
		Test.eq(doctor.collect(rt).checks[#checks].status, "info")
	end)
end)

Test.test(
	"shared_integrations context describes requested transport without probing or reading secrets",
	function()
		local rt = fake()
		local module = {
			resolve = function()
				return { mode = "shared", url = "http://127.0.0.1:19841/mcp" }
			end,
			credentials = function()
				error("must not read credentials")
			end,
			check = function()
				error("must not connect")
			end,
		}
		with_mcp(module, function()
			local context = require("orc.context")
			local result = context.collect(rt)
			local providers = {}
			for _, item in ipairs(result.findings) do
				if item.name == "inkdrop-mcp" then
					providers[item.harness] = item.status
					assert(item.detail:find("effective MCP policy is checked on launch", 1, true))
				end
			end
			Test.eq(providers, { claude = "info", codex = "info" })
			Test.eq(context.run(rt, { "--scope", "project", "--json" }).code, 0)
			module.resolve = function()
				error("invalid shared settings", 0)
			end
			Test.eq(context.run(rt, { "--json" }).code, 1)
		end)
	end
)

Test.test("shared_integrations completions expose explicit service and provider opt-in", function()
	local text = require("orc.completion").fish()
	for _, word in ipairs({
		"inkdrop-mcp",
		"migrate rollback uninstall",
		"inherit shared",
		"-l apply",
		"-l credentials",
	}) do
		assert(text:find(word, 1, true), word)
	end
end)
