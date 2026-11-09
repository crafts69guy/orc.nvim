local context = require("orc.context")
local ink = require("orc.inkdrop")
local runtime = require("orc.runtime")
local BEGIN, END = "<!-- orc:begin -->", "<!-- orc:end -->"
local MANAGED = BEGIN .. "\nold\n" .. END

local function fake(options)
	options = options or {}
	local files, calls, requests = vim.deepcopy(options.files or {}), {}, {}
	local rt = runtime.new({
		cwd = options.cwd or "/repo",
		env = {
			HOME = "/home/u",
			INKDROP_LOCAL_USERNAME = "alice",
			INKDROP_LOCAL_PASSWORD = 'private"\\secret',
		},
	})
	rt.env.CLAUDE_CONFIG_DIR, rt.env.CODEX_HOME = nil, nil
	rt.env.INKDROP_LOCAL_SERVER_URL, rt.env.ORC_INKDROP = nil, nil
	for key, value in pairs(options.env or {}) do
		rt.env[key] = value
	end
	rt.now = function()
		return "2026-11-02T00:00:00Z"
	end
	rt.read = function(path)
		if options.unreadable == path then
			return nil, "permission denied"
		end
		return files[path]
	end
	rt.exists = function(path)
		if files[path] ~= nil then
			return true
		end
		for file in pairs(files) do
			if file:sub(1, #path + 1) == path .. "/" then
				return true
			end
		end
		return false
	end
	rt.list = function(path)
		if options.list_error == path then
			error("not readable")
		end
		local names = {}
		for file in pairs(files) do
			if file:sub(1, #path + 1) == path .. "/" then
				local name = file:sub(#path + 2):match("^[^/]+")
				if name then
					names[name] = true
				end
			end
		end
		local result = vim.tbl_keys(names)
		table.sort(result)
		return result
	end
	rt.write = function(path, text)
		files[path] = text
	end
	rt.mkdir = function() end
	rt.exec = function(argv, opts)
		opts = opts or {}
		calls[#calls + 1] = { argv = vim.deepcopy(argv), opts = vim.deepcopy(opts) }
		local result = { code = 0, signal = 0, stdout = "", stderr = "" }
		if argv[1] == "git" then
			if argv[2] == "rev-parse" then
				if options.no_git then
					result.code = 128
				else
					result.stdout = argv[#argv] == "--show-toplevel" and "/repo\n" or "/repo/.git\n"
				end
			elseif argv[2] == "remote" then
				result.code, result.stdout =
					options.no_remote and 1 or 0, options.remote or "git@github.com:owner/repo.git\n"
			elseif argv[3] == "--get-regexp" then
				result.stdout = options.config == false and ""
					or (
						options.config
						or "orc.inkdropbook book:main\norc.inkdropbookname Repo\norc.inkdroptag tag:orc\n"
					)
			elseif argv[3] == "--get" then
				result.code, result.stdout = options.parent and 0 or 1, options.parent or ""
			elseif options.config_error then
				result.code, result.stderr = 1, "config locked"
			end
		elseif argv[1] == "curl" then
			Test.eq(argv, { "curl", "--disable", "--config", "-" })
			local config = {}
			for key, value in opts.stdin:gmatch('([%w-]+) = "(.-)"\n') do
				config[key] = vim.json.decode('"' .. value .. '"')
			end
			local path = config.url:match("^https?://[^/]+([^?]+)")
			local query = {}
			for key, value in config.url:gmatch("[?&]([^=&]+)=([^&]*)") do
				query[key] = value:gsub("%%(%x%x)", function(hex)
					return string.char(tonumber(hex, 16))
				end)
			end
			local request = {
				method = config.request,
				path = path,
				query = query,
				config = config,
				body = config["data-binary"] and vim.json.decode(config["data-binary"]) or nil,
			}
			requests[#requests + 1] = request
			local doc, status, code = (options.respond or function()
				return {}
			end)(request, requests)
			result.code = code or 0
			result.stdout = (type(doc) == "string" and doc or vim.json.encode(doc))
				.. "\n"
				.. tostring(status or 200)
			result.stderr = options.curl_stderr or ""
		else
			error("unexpected executable " .. argv[1])
		end
		return result
	end
	return rt, files, calls, requests
end

Test.test(
	"integrations context lists the optional shared validation profile for both harnesses",
	function()
		for _, present in ipairs({ false, true }) do
			local profile = "/repo/.orc/validation.md"
			local rt = fake({
				cwd = "/repo/linked/subdir",
				files = present and { [profile] = "edit: format\ntask: test\ngate: coverage\n" } or {},
			})
			local found = {}
			for _, source in ipairs(context.collect(rt).sources) do
				if source.path == profile then
					Test.eq(source.kind, "memory")
					Test.eq(source.scope, "project")
					assert(source.always > 0)
					found[#found + 1] = source.harness
				end
			end
			Test.eq(found, present and { "claude", "codex" } or {})
		end
	end
)

local function with_status(fn, features)
	local previous = package.loaded["orc.status"]
	package.loaded["orc.status"] = {
		task_state = require("orc.status").task_state,
		collect = function()
			return { features = features or {} }
		end,
	}
	local ok, result = xpcall(fn, debug.traceback)
	package.loaded["orc.status"] = previous
	if not ok then
		error(result)
	end
	return result
end
local function expect_error(result, pattern)
	Test.eq(result.code, 1)
	assert(result.err:match(pattern), result.err)
end
local function check_finding(document, name, status)
	for _, item in ipairs(document.findings) do
		if item.name == name and (not status or item.status == status) then
			return item
		end
	end
	error("missing finding " .. name .. ": " .. vim.inspect(document.findings))
end
local function note(id, fields)
	return vim.tbl_extend("force", {
		_id = id,
		_rev = "1",
		title = "Request",
		body = "spec",
		bookId = "book:main",
		tags = { "tag:orc" },
		status = "active",
		updatedAt = 1,
	}, fields or {})
end

Test.test("integrations Inkdrop config, enable flags and safe health probes", function()
	local rt, _, calls = fake({
		env = {
			http_proxy = "http://untrusted.invalid:8080",
			ALL_PROXY = "socks5://untrusted.invalid:1080",
			NO_PROXY = "",
		},
		respond = function()
			return { version = "6" }
		end,
	})
	Test.eq(ink.config(rt), { book = "book:main", bookName = "Repo", tag = "tag:orc" })
	Test.eq(ink.flag(rt), { id = "book:main", name = "Repo" })
	Test.eq(ink.enabled(rt), true)
	Test.eq(ink.probe(rt), { version = "6" })
	local curl = calls[#calls]
	assert(not table.concat(curl.argv, " "):find("private", 1, true))
	assert(curl.opts.stdin:find(vim.base64.encode('alice:private"\\secret'), 1, true))
	assert(curl.opts.stdin:find('noproxy = "*"\n', 1, true))
	assert(curl.opts.timeout == 2500)
	for _, env in ipairs({
		{ ORC_INKDROP = "0" },
		{ INKDROP_LOCAL_USERNAME = "" },
		{ INKDROP_LOCAL_PASSWORD = "" },
	}) do
		local disabled = fake({ env = env })
		Test.eq(ink.enabled(disabled), false)
		Test.eq(ink.flag(disabled), false)
	end
	local unset = fake({ config = false })
	Test.eq(ink.config(unset).book, vim.NIL)
	Test.eq(ink.flag(unset), false)
	local fallback = fake({ config = "orc.inkdropbook book:main\n" })
	Test.eq(ink.flag(fallback), { id = "book:main", name = "book:main" })
end)

Test.test(
	"integrations Inkdrop fills optional note fields, renders plan tasks and handles empty content",
	function()
		with_status(function()
			local blank = note("note:blank")
			blank.body, blank.tags = nil, nil
			local rt, files = fake({
				respond = function(req)
					if req.method == "GET" then
						return vim.deepcopy(blank)
					end
					return { ok = true, id = "note:created" }
				end,
			})
			Test.eq(ink.run(rt, { "claim", "note:blank", "f" }).code, 0)
			Test.eq(ink.run(rt, { "pull", "f" }).out, "changed: no\n")
			Test.eq(ink.push(rt, "/repo", "f", { done = false }).code, 0)
			Test.eq(ink.run(rt, { "push", "new", "--done" }).code, 0)
			assert(vim.json.decode(files["/repo/.scratch/new/inkdrop.json"]).noteId == "note:created")
		end, {
			{ feature = "other", tasks = {} },
			{ feature = "f", tasks = { { id = "T1", agent = { state = "working" } } } },
		})
		for _, status in ipairs({ 0, 199 }) do
			local rt = fake({
				respond = function()
					return {}, status
				end,
			})
			assert(ink.probe(rt).error:match("HTTP"))
		end
		with_status(function()
			local rt = fake({
				respond = function(req)
					return req.method == "GET" and note("note:x") or {}, req.method == "POST" and 500 or 200
				end,
			})
			expect_error(ink.run(rt, { "claim", "note:x", "f" }), "HTTP 500")
		end)
	end
)

Test.test(
	"integrations Inkdrop remap handles empty notebooks and validates lesson ownership before writes",
	function()
		local function setup_case(notes, tags)
			return fake({
				config = "orc.inkdropbook book:old\n",
				no_remote = true,
				respond = function(req)
					if req.path == "/books" then
						return { {}, { _id = "book:main", name = "target" } }
					end
					if req.path == "/tags" then
						return tags
							or { { _id = "tag:orc", name = "orc" }, { _id = "tag:lesson", name = "orc-lesson" } }
					end
					if req.method == "GET" and req.path == "/notes" then
						return notes
					end
					if req.method == "GET" then
						for _, item in ipairs(notes) do
							if req.path == "/" .. item._id then
								return vim.deepcopy(item)
							end
						end
					end
					return { ok = true }
				end,
			})
		end
		for _, argv in ipairs({
			{ "init", "--book", "target" },
			{ "init", "--book", "target", "--move" },
		}) do
			Test.eq(ink.run(setup_case({}), argv).code, 0)
		end
		local owned = note("note:lesson", {
			bookId = "book:old",
			tags = { "tag:lesson" },
			body = BEGIN .. "\nlesson: repo/L001\ntext\n" .. END,
		})
		local foreign = note("note:foreign", {
			bookId = "book:old",
			tags = { "tag:lesson" },
			body = BEGIN .. "\nlesson: elsewhere/L001\ntext\n" .. END,
		})
		local no_identity =
			note("note:noidentity", { bookId = "book:old", tags = { "tag:lesson" }, body = MANAGED })
		local missing = note("note:missing", { bookId = "book:old", tags = { "tag:lesson" } })
		missing.body = nil
		local untagged = note("note:untagged", { bookId = "book:old" })
		untagged.tags = nil
		local rt = setup_case({ owned, foreign, no_identity, missing, untagged })
		assert(ink.run(rt, { "init", "--book", "target", "--move" }).out:find("moved 1 notes", 1, true))
		local damaged, _, _, requests = setup_case({
			note("note:damaged", {
				bookId = "book:old",
				tags = { "tag:lesson" },
				body = BEGIN,
			}),
		})
		expect_error(ink.run(damaged, { "init", "--book", "target", "--move" }), "damaged")
		for _, request in ipairs(requests) do
			Test.eq(request.method, "GET")
		end
		Test.eq(
			ink.run(
				setup_case(
					{},
					{ { name = "unrelated", _id = "tag:other" }, { name = "orc", _id = "tag:orc" } }
				),
				{ "init", "--book", "target" }
			).code,
			0
		)
	end
)

Test.test(
	"integrations Inkdrop empty lesson collections do not mirror foreign or invalid records",
	function()
		local no_body = note("note:no-body", { tags = { "tag:lesson" } })
		no_body.body = nil
		local rt = fake({
			no_remote = true,
			files = {
				["/repo/.orc/lessons.md"] = "- [L001] +0 -0 orc · f · retired\n- [L002] +1 -0 invalid · f · invalid\n",
			},
			respond = function(req)
				if req.path == "/tags" and req.method == "GET" then
					return { { _id = "tag:other", name = "other" } }
				end
				if req.path == "/notes" and req.method == "GET" then
					return {
						note("note:wrong-book", { bookId = "book:elsewhere", tags = { "tag:lesson" } }),
						note("note:wrong-tag"),
						no_body,
						note("note:no-id", { tags = { "tag:lesson" }, body = MANAGED }),
					}
				end
				return { id = "tag:lesson" }
			end,
		})
		Test.eq(
			ink.run(rt, { "lessons" }).out,
			"lessons: 0 created, 0 updated, 0 dropped, 0 unchanged\n"
		)
		local absent_body = note("note:blank")
		absent_body.body = nil
		Test.eq(
			ink.run(
				fake({
					respond = function()
						return { absent_body }
					end,
				}),
				{ "inbox", "--json" }
			).code,
			0
		)
		Test.eq(
			ink.run(
				fake({
					files = { ["/repo/.orc/lessons.md"] = "" },
					respond = function(req)
						if req.path == "/tags" then
							return { { _id = "tag:lesson", name = "orc-lesson" } }
						end
						return {}
					end,
				}),
				{ "lessons" }
			).code,
			0
		)
	end
)

Test.test(
	"integrations context tolerates empty, hidden and unreadable components without exposing file errors",
	function()
		local tick = string.char(96)
		local files = {
			["/home/u/.claude/CLAUDE.md"] = tick .. "~/exists.md" .. tick,
			["/home/u/exists.md"] = "present",
			["/home/u/.claude/skills/empty/README.md"] = "no SKILL",
			["/home/u/.claude/skills/.hidden/SKILL.md"] = "hidden",
			["/home/u/.claude/agents/read-error.md"] = "bad",
			["/home/u/.claude/agents/ignore.txt"] = "ignored",
			["/home/u/.claude/settings.json"] = "{}",
			["/repo/.claude/settings.json"] = "invalid",
			["/repo/CLAUDE.md"] = "unreadable",
			["/home/u/.codex/agents/empty.toml"] = "",
			["/home/u/.codex/agents/read-error.toml"] = "name = 'bad'",
			["/home/u/.codex/agents/ignore.txt"] = "ignore",
			["/home/u/.codex/skills/empty/SKILL.md"] = "---\n# comment before keys\nname: empty\n\n---\n",
		}
		local rt = fake({ files = files, list_error = "/repo/.claude/skills" })
		local read = rt.read
		rt.read = function(path)
			if path == "/repo/CLAUDE.md" or path:match("read%-error") then
				error("EACCES")
			end
			return read(path)
		end
		local doc = context.collect(rt)
		check_finding(doc, "unreadable", "warn")
		for _, source in ipairs(doc.sources) do
			assert(source.name ~= ".hidden" and not source.path:match("ignore.txt"))
		end
		Test.eq(context.find_paths(tick .. "relative" .. tick), {})
		Test.eq(context.find_imports(tick:rep(3) .. "\n@hidden.md\n" .. tick:rep(3)), {})
		local empty_home = fake({ files = { ["/repo/CLAUDE.md"] = "memory" } })
		empty_home.env.HOME = nil
		Test.eq(context.run(empty_home, { "--json" }).code, 0)
		local broken = fake()
		broken.exists = function()
			error("filesystem unavailable")
		end
		local result = context.run(broken, { "--json" })
		Test.eq(result.code, 1)
		check_finding(vim.json.decode(result.out), "context", "fail")
	end
)

Test.test(
	"integrations context handles custom homes, home projects and symlink cwd ancestry",
	function()
		local rt = fake({
			env = { HOME = "/repo", CLAUDE_CONFIG_DIR = "/custom-claude", CODEX_HOME = "/custom-codex" },
			files = {
				["/custom-claude/CLAUDE.md"] = "user memory",
				["/custom-codex/AGENTS.override.md"] = "user override",
				["/repo/.claude/settings.json"] = '{"enabledPlugins":{"project@m":true,"off@m":false}}',
				["/custom-claude/plugins/installed_plugins.json"] = '{"plugins":{"project@m":[{"scope":"project","projectPath":"/other","installPath":"/wrong"},{"scope":"project","projectPath":"/repo","installPath":"/plugin"}]}}',
				["/plugin/agents/worker.md"] = "---\nname: worker\ndescription: task-specific work\n---\nbody",
				["/custom-codex/config.toml"] = '[plugins."missing@m"]\nenabled = true\n[plugins."p@m"]\nenabled = true',
				["/custom-codex/plugins/cache/m/p/preview/skills/a/SKILL.md"] = "preview",
				["/custom-codex/plugins/cache/m/p/latest/skills/b/SKILL.md"] = "latest",
				["/custom-codex/plugins/cache/m/p/1.0/skills/c/SKILL.md"] = "number",
				["/custom-codex/plugins/cache/m/p/1.0.0/skills/d/SKILL.md"] = "number tie",
				["/custom-codex/plugins/cache/m/p/2/skills/e/SKILL.md"] = "newest",
				["/custom-codex/plugins/cache/m/p/2/hooks/hooks.json"] = '{"hooks":{"SessionStart":[]}}',
			},
		})
		local result = context.collect(rt, "/repo")
		local found = false
		for _, source in ipairs(result.sources) do
			if source.name == "worker" then
				found = true
				Test.eq(source.scope, "project")
			end
		end
		assert(found)
		local home_root =
			fake({ env = { HOME = "/repo" }, files = { ["/repo/.claude/CLAUDE.md"] = "once" } })
		Test.eq(context.collect(home_root).schemaVersion, 1)
		local symlink_cwd = fake({ cwd = "/alias/repo", files = { ["/alias/AGENTS.md"] = "ancestor" } })
		Test.eq(context.collect(symlink_cwd).schemaVersion, 1)
	end
)

Test.test(
	"integrations context covers empty and punctuation-only descriptions and isolated lesson warnings",
	function()
		local function source(name, description, origin, kind, manual)
			return {
				harness = "claude",
				scope = "user",
				origin = origin or "user",
				kind = kind or "skill",
				name = name,
				path = "/" .. name,
				always = 0,
				listing = #description,
				body = 0,
				manual = manual or false,
				description = description,
			}
		end
		local analyzed = context.analyze({
			sources = {
				source("a", "!!!"),
				source("b", "???"),
				source("b", string.rep("b", 301), "plugin"),
				source("c", string.rep("c", 301), "plugin"),
				source("d", "ANY task"),
				source("e", "normal command", "user", "command"),
				source("f", "manual", "user", "skill", true),
			},
			findings = {},
		}, "all")
		check_finding(analyzed, "broad-trigger")
		check_finding(analyzed, "description-long")
		Test.eq(#context.analyze({ sources = {}, findings = {} }, "project").sources, 0)
		local invalid = fake({ files = { ["/repo/.orc/lessons.md"] = "- [oops] invalid" } })
		check_finding(context.collect(invalid), "lessons")
		local active = {}
		for i = 1, 41 do
			active[#active + 1] = string.format("- [L%03d] +2 -0 orc · f · text", i)
		end
		local capped = fake({ files = { ["/repo/.orc/lessons.md"] = table.concat(active, "\n") } })
		check_finding(context.collect(capped), "lessons")
		local retired =
			fake({ files = { ["/repo/.orc/lessons.md"] = "- [L001] +1 -1 orc · f · retired\n" } })
		Test.eq(context.collect(retired).schemaVersion, 1)
	end
)

Test.test("integrations Inkdrop validates loopback URLs and never leaks credentials", function()
	for _, url in ipairs({ "http://localhost:19840/path", "https://127.0.0.1", "http://[::1]:19840" }) do
		local rt = fake({
			env = { INKDROP_LOCAL_SERVER_URL = url },
			respond = function()
				return { version = "6" }
			end,
		})
		Test.eq(ink.probe(rt).version, "6")
	end
	for _, url in ipairs({
		"not-url",
		"ftp://localhost",
		"http://alice:private@localhost",
		"http://example.com",
		"http://localhost:bad",
	}) do
		local rt = fake({ env = { INKDROP_LOCAL_SERVER_URL = url } })
		local result = ink.probe(rt)
		assert(result.error)
		assert(not result.error:find("private", 1, true))
	end
	local no_auth = fake({ env = { INKDROP_LOCAL_USERNAME = "" } })
	assert(ink.probe(no_auth).error:match("set INKDROP"))
	for _, status in ipairs({ 401, 409, 302, 500 }) do
		local rt = fake({
			respond = function()
				return {}, status
			end,
		})
		local result = ink.run(rt, { "inbox" })
		Test.eq(result.code, 1)
		assert(not result.err:find("private", 1, true))
	end
	local bad_json = fake({
		respond = function()
			return "not json"
		end,
	})
	assert(ink.probe(bad_json).error:match("invalid JSON"))
	local offline = fake({
		curl_stderr = "private credential",
		respond = function()
			return "", 0, 7
		end,
	})
	assert(ink.probe(offline).error:match("not running"))
	assert(not ink.probe(offline).error:find("private", 1, true))
end)

Test.test("integrations Inkdrop managed markers preserve user bytes and refuse damage", function()
	Test.eq(ink.spec("  spec\n" .. MANAGED .. "\n tail  "), "spec\n\n tail")
	Test.eq(
		ink.splice("before\r\n" .. BEGIN .. "\r\nold\r\n" .. END .. "\r\nafter", "NEW"),
		"before\r\nNEW\r\nafter"
	)
	Test.eq(ink.splice("spec \n", "NEW"), "spec\n\nNEW")
	Test.eq(ink.splice("", "NEW"), "NEW")
	Test.eq(ink.spec("inline " .. BEGIN), "inline " .. BEGIN)
	for _, body in ipairs({ BEGIN, END, END .. "\n" .. BEGIN, MANAGED .. "\n" .. MANAGED }) do
		Test.raises("damaged", function()
			ink.spec(body)
		end)
		Test.raises("damaged", function()
			ink.splice(body, "NEW")
		end)
	end
	local block = ink.render_block(
		"feature",
		"# title\r\nBase branch: feat/x # comment\r\n## Decisions\r\n- keep\r\n  detail\r\n\r\n## Tasks\n",
		{
			{ id = "T1", goal = "done", merged = { commit = "abcdef12345" } },
			{ id = "T2", goal = vim.NIL, merged = vim.NIL, agent = { state = "working" } },
			{ id = "T3", report = { status = "blocked" } },
			{ id = "T4", worktree = "/wt" },
			{ id = "T5" },
		},
		BEGIN,
		"2026-11-02T00:00:00Z"
	)
	assert(block:find("feat/x", 1, true) and block:find("detail", 1, true))
	assert(block:find("(merged abcdef1)", 1, true) and block:find("(working)", 1, true))
	assert(
		block:find("(blocked)", 1, true)
			and block:find("(worktree)", 1, true)
			and block:find("(pending)", 1, true)
	)
	assert(block:find("<!-- orc begin -->", 1, true))
	assert(ink.render_block("f", nil, {}, nil, "now"):find("no plan yet", 1, true))
end)

Test.test(
	"integrations Inkdrop init creates parent notebook and tag with correct UTC timestamps",
	function()
		local rt, _, _, requests = fake({
			config = false,
			respond = function(req)
				if req.method == "GET" then
					return {}
				end
				if req.path == "/books" then
					return { id = req.body.name == "Orc" and "book:parent" or "book:main" }
				end
				if req.path == "/tags" then
					return { id = "tag:orc" }
				end
				error("unexpected request")
			end,
		})
		local result = ink.run(rt, { "init", "--parent", "Orc", "--create" })
		Test.eq(result.code, 0)
		assert(result.out:find("Orc/repo", 1, true))
		local created = {}
		for _, req in ipairs(requests) do
			if req.method == "POST" then
				created[#created + 1] = req
			end
		end
		Test.eq(created[1].body.createdAt, 1793577600000)
		Test.eq(created[2].body.parentBookId, "book:parent")
		Test.eq(created[3].body.color, "default")
		local missing = fake({
			config = false,
			respond = function()
				return {}
			end,
		})
		expect_error(ink.run(missing, { "init" }), "pass %-%-create")
		local bad_git = fake({
			config_error = true,
			respond = function(req)
				if req.path == "/books" then
					return { { _id = "book:main", name = "REPO" } }
				end
				return { { _id = "tag:orc", name = "orc" } }
			end,
		})
		expect_error(ink.run(bad_git, { "init" }), "config locked")
	end
)

Test.test(
	"integrations Inkdrop remap refuses before writes, then moves only owned notes",
	function()
		for _, move in ipairs({ false, true }) do
			local rt, _, _, requests = fake({
				config = "orc.inkdropbook book:old\n",
				parent = "Orc",
				files = {
					["/repo/.scratch/f/inkdrop.json"] = '{"noteId":"note:linked"}',
					["/repo/.scratch/bad/inkdrop.json"] = "invalid",
				},
				respond = function(req)
					if req.path == "/books" then
						return {
							{ _id = "book:parent", name = "Orc", parentBookId = vim.NIL },
							{ _id = "book:main", name = "repo", parentBookId = "book:parent" },
						}
					end
					if req.path == "/tags" then
						return { { _id = "tag:orc", name = "orc" }, { _id = "tag:lesson", name = "orc-lesson" } }
					end
					if req.path == "/notes" and req.method == "GET" then
						return {
							note("note:linked", { bookId = "book:old", body = MANAGED }),
							note("note:queue", { bookId = "book:old" }),
							note("note:other", { bookId = "book:old", body = MANAGED }),
							note("note:foreign", { bookId = "book:foreign" }),
						}
					end
					if req.method == "GET" then
						return note(req.path:sub(2), { bookId = "book:old" })
					end
					return { ok = true }
				end,
			})
			local result = ink.run(rt, move and { "init", "--move" } or { "init" })
			if move then
				Test.eq(result.code, 0)
				assert(result.out:find("moved 2 notes", 1, true))
			else
				expect_error(result, "rerun with %-%-move")
			end
			local writes = 0
			for _, req in ipairs(requests) do
				if req.method == "POST" then
					writes = writes + 1
				end
			end
			Test.eq(writes, move and 2 or 0)
		end
	end
)

Test.test(
	"integrations Inkdrop inbox filters exact notebook tag markers and local links",
	function()
		local rt = fake({
			files = { ["/repo/.scratch/f/inkdrop.json"] = '{"noteId":"note:linked"}' },
			respond = function()
				return {
					note("note:open"),
					note("note:linked"),
					note("note:managed", { body = MANAGED }),
					note("note:damaged", { body = BEGIN }),
					note("note:wrong", { bookId = "book:other" }),
					note("note:untagged", { tags = {} }),
				}
			end,
		})
		local result = ink.run(rt, { "inbox", "--json" })
		Test.eq(result.code, 0)
		local list = vim.json.decode(result.out)
		Test.eq(
			list,
			{ schemaVersion = 1, notes = { { id = "note:open", title = "Request", updatedAt = 1 } } }
		)
		assert(ink.run(rt, { "inbox" }).out:find("note:open  Request", 1, true))
		Test.eq(
			ink.run(
				fake({
					respond = function()
						return {}
					end,
				}),
				{ "inbox" }
			).out,
			"no queued notes\n"
		)
	end
)

Test.test("integrations Inkdrop claim retries revision conflict from a fresh GET", function()
	with_status(function()
		local posts, reads = 0, 0
		local rt, files, _, requests = fake({
			respond = function(req)
				if req.method == "GET" then
					reads = reads + 1
					return note("note:request", { _rev = tostring(reads), tags = {} })
				end
				posts = posts + 1
				return { ok = true }, posts == 1 and 409 or 200
			end,
		})
		local result = ink.run(rt, { "claim", "note:request", "feature" })
		Test.eq(result.code, 0)
		Test.eq(reads, 2)
		Test.eq(posts, 2)
		Test.eq(requests[4].body._rev, "2")
		Test.eq(requests[4].body.tags, { "tag:orc" })
		assert(result.out:find("# Request\n\nspec", 1, true))
		local link = vim.json.decode(files["/repo/.scratch/feature/inkdrop.json"])
		Test.eq(link.specHash, vim.fn.sha256("spec"))
		expect_error(ink.run(rt, { "claim", "note:request", "feature" }), "already linked")
	end)
end)

Test.test(
	"integrations Inkdrop claim validates IDs features notebook and managed markers",
	function()
		with_status(function()
			for _, id in ipairs({ "bad", "note:../bad" }) do
				expect_error(ink.run(fake(), { "claim", id, "f" }), "invalid note id")
			end
			for _, feature in ipairs({ "..", "../x", "bad/name" }) do
				expect_error(ink.run(fake(), { "claim", "note:ok", feature }), "invalid feature")
			end
			for _, entry in ipairs({
				{ note("note:x", { bookId = "book:other" }), "not in notebook" },
				{ note("note:x", { body = MANAGED }), "already claimed" },
				{ note("note:x", { body = BEGIN }), "damaged" },
			}) do
				local rt = fake({
					respond = function()
						return entry[1]
					end,
				})
				expect_error(ink.run(rt, { "claim", "note:x", "f" }), entry[2])
			end
			expect_error(
				ink.run(fake({ config = false }), { "claim", "note:x", "f" }),
				"no Inkdrop notebook"
			)
			expect_error(ink.run(fake({ no_git = true }), { "inbox" }), "not a git repository")
		end)
	end
)

Test.test(
	"integrations Inkdrop push creates links then preserves spec hash and outside bytes",
	function()
		with_status(function()
			local doc = note("note:new", { body = "user\r\n" .. MANAGED .. "\r\ntail" })
			local rt, files = fake({
				files = { ["/repo/.scratch/f/plan.md"] = "# Feature\nBase branch: feat/x\n" },
				respond = function(req)
					if req.method == "GET" then
						return vim.deepcopy(doc)
					end
					if req.body._id then
						doc = req.body
						return { ok = true }
					end
					doc = vim.tbl_extend("force", doc, req.body)
					return { id = "note:new" }
				end,
			})
			Test.eq(ink.push(rt, "/repo", "f").out, "created note:new\n")
			Test.eq(doc.title, "Feature")
			local original_link = files["/repo/.scratch/f/inkdrop.json"]
			doc.body = "user\r\n" .. MANAGED .. "\r\ntail"
			Test.eq(ink.run(rt, { "push", "f", "--done" }).out, "pushed note:new\n")
			assert(doc.body:match("^user\r\n") and doc.body:match("\r\ntail$"))
			Test.eq(doc.status, "completed")
			Test.eq(files["/repo/.scratch/f/inkdrop.json"], original_link)
			local invalid = fake({ files = { ["/repo/.scratch/f/inkdrop.json"] = "bad" } })
			expect_error(ink.run(invalid, { "push", "f" }), "invalid /repo")
			local no_id = fake({
				respond = function()
					return {}
				end,
			})
			expect_error(ink.run(no_id, { "push", "f" }), "returned no note id")
		end)
	end
)

Test.test("integrations Inkdrop pull tracks changed spec and refuses missing links", function()
	local doc = note("note:x", { body = "spec\n" .. MANAGED })
	local rt, files = fake({
		files = {
			["/repo/.scratch/f/inkdrop.json"] = vim.json.encode({
				noteId = "note:x",
				specHash = vim.fn.sha256("spec"),
			}),
		},
		respond = function()
			return doc
		end,
	})
	Test.eq(ink.run(rt, { "pull", "f" }).out, "changed: no\n")
	doc.body = "new spec\n" .. MANAGED
	Test.eq(ink.run(rt, { "pull", "f" }).out, "changed: yes\n\nnew spec\n")
	Test.eq(
		vim.json.decode(files["/repo/.scratch/f/inkdrop.json"]).specHash,
		vim.fn.sha256("new spec")
	)
	expect_error(ink.run(rt, { "pull", "missing" }), "no linked note")
	doc.body = BEGIN
	expect_error(ink.run(rt, { "pull", "f" }), "damaged")
end)

Test.test("integrations Inkdrop bounded conflict and malformed CLI errors remain safe", function()
	with_status(function()
		local rt = fake({
			respond = function(req)
				return req.method == "GET" and note("note:x") or {}, req.method == "POST" and 409 or 200
			end,
		})
		expect_error(ink.run(rt, { "claim", "note:x", "f" }), "changed concurrently")
		for _, argv in ipairs({
			{},
			{ "wat" },
			{ "init", "--bad" },
			{ "init", "positional" },
			{ "inbox", "x" },
			{ "claim" },
			{ "pull" },
			{ "push" },
			{ "push", "a", "b" },
			{ "lessons", "x" },
		}) do
			Test.eq(ink.run(fake(), argv).code, 1)
		end
	end)
end)

Test.test(
	"integrations Inkdrop lesson identities and origin URLs are repository specific",
	function()
		Test.eq(ink.remote_key("https://github.com/owner/repo.git"), "owner/repo")
		Test.eq(ink.remote_key("git@github.com:group/owner/repo.git\n"), "owner/repo")
		Test.eq(ink.remote_key("https://host/single"), nil)
		Test.eq(ink.remote_key("/local/path"), nil)
		Test.eq(ink.remote_key("https://host/a//b"), nil)
		local rendered = ink.render_lesson(
			"owner/repo",
			{ id = "L001", up = 2, down = 0, scope = "orc", feature = "f", text = string.rep("a", 70) }
		)
		assert(vim.fn.strchars(rendered.title:match("L001 (.*)")) == 60)
		assert(rendered.block:find("lesson: owner/repo/L001", 1, true))
		local plain = ink.render_lesson(
			"repo",
			{ id = "L002", up = 1, down = 0, scope = "project", feature = "f", text = "short" }
		)
		assert(plain.title:match("short$"))
	end
)

Test.test("integrations Inkdrop lessons creates updates drops and skips foreign records", function()
	local wanted =
		{ id = "L001", up = "2", down = "0", scope = "orc", feature = "f", text = "keep validation" }
	local second =
		{ id = "L002", up = "1", down = "0", scope = "project", feature = "f", text = "keep tests" }
	local same = ink.render_lesson("owner/repo", wanted)
	local records = {
		note("note:same", { title = same.title, body = same.block, tags = { "tag:lesson" } }),
		note(
			"note:update",
			{ body = BEGIN .. "\nlesson: owner/repo/L002\nold\n" .. END, tags = { "tag:lesson" } }
		),
		note(
			"note:drop",
			{ body = BEGIN .. "\nlesson: owner/repo/L003\nold\n" .. END, tags = { "tag:lesson" } }
		),
		note("note:dropped", {
			body = BEGIN .. "\nlesson: owner/repo/L004\nold\n" .. END,
			tags = { "tag:lesson" },
			status = "dropped",
		}),
		note(
			"note:foreign",
			{ body = BEGIN .. "\nlesson: foreign/repo/L001\nold\n" .. END, tags = { "tag:lesson" } }
		),
	}
	local rt, _, _, requests = fake({
		files = {
			["/repo/.orc/lessons.md"] = "- [L001] +2 -0 orc · f · keep validation\n- [L002] +1 -0 project · f · keep tests · retain status\n- [L005] +1 -0 orc · f · new lesson\n- [L006] +1 -1 orc · f · retired\n",
		},
		respond = function(req)
			if req.path == "/tags" then
				return { { _id = "tag:lesson", name = "orc-lesson" } }
			end
			if req.path == "/notes" and req.method == "GET" then
				return records
			end
			if req.method == "GET" then
				for _, item in ipairs(records) do
					if req.path == "/" .. item._id then
						return vim.deepcopy(item)
					end
				end
			end
			return { id = "note:new", ok = true }
		end,
	})
	Test.eq(ink.run(rt, { "lessons" }).out, "lessons: 1 created, 1 updated, 1 dropped, 1 unchanged\n")
	local updated
	for _, request in ipairs(requests) do
		if request.method == "POST" and request.body._id == "note:update" then
			updated = request.body
		end
	end
	assert(updated.body:find("feature: f\n\nkeep tests · retain status", 1, true))
	Test.eq(ink.run(fake(), { "lessons" }).out, "no lessons in /repo/.orc/lessons.md\n")
end)

Test.test("integrations context import and TOML parsing respect code and inline syntax", function()
	local tick = string.char(96)
	Test.eq(
		context.find_imports(
			"@AGENTS.md @./a.md,\n"
				.. tick
				.. "@skip.md"
				.. tick
				.. "\n~~~\n@hidden.md\n~~~\n@~/rules.md @/root/rules @nobody"
		),
		{ "AGENTS.md", "./a.md", "~/rules.md", "/root/rules" }
	)
	Test.eq(
		context.find_paths(
			tick
				.. "~/rules.md"
				.. tick
				.. " "
				.. tick
				.. "/a/b"
				.. tick
				.. " "
				.. tick
				.. "/a/*"
				.. tick
				.. " "
				.. tick
				.. "/a/..."
				.. tick
		),
		{ "~/rules.md", "/a/b" }
	)
	Test.eq(
		context.parse_toml(
			'project_doc_max_bytes = 100 # limit\n[plugins."orc@market"]\nenabled = true\n[[ignored]]\ninvalid\n'
		),
		{
			top = { project_doc_max_bytes = "100" },
			sections = { ["plugins.orc@market"] = { enabled = "true" } },
		}
	)
end)

Test.test(
	"integrations context audits memory imports cycles paths unreadable and malformed files",
	function()
		local tick = string.char(96)
		local rt = fake({
			files = {
				["/home/u/.claude/CLAUDE.md"] = "@./import.md\n@missing.md\n"
					.. tick
					.. "~/absent.md"
					.. tick,
				["/home/u/.claude/import.md"] = "@./CLAUDE.md",
				["/repo/CLAUDE.md"] = "repo memory",
				["/repo/AGENTS.md"] = "project rules",
				["/repo/.claude/settings.json"] = "invalid json",
				["/repo/.claude/settings.local.json"] = "{}",
			},
			unreadable = "/repo/.claude/settings.local.json",
		})
		local result = context.collect(rt)
		Test.eq(result.schemaVersion, 1)
		check_finding(result, "import-cycle")
		check_finding(result, "broken-import", "fail")
		check_finding(result, "dangling-path")
		check_finding(result, "unreadable")
		check_finding(result, "budget")
		local run = context.run(rt, { "--json", "--scope=project" })
		Test.eq(run.code, 0)
		for _, source in ipairs(vim.json.decode(run.out).sources) do
			Test.eq(source.scope, "project")
		end
		Test.eq(context.run(rt, { "--scope", "user" }).code, 1)
		assert(context.run(rt, {}).out:find("claude\n", 1, true))
	end
)

Test.test("integrations context depth and Codex byte limits are bounded", function()
	local files = {
		["/home/u/.claude/CLAUDE.md"] = "@./1.md",
		["/home/u/.codex/config.toml"] = "project_doc_max_bytes = 10",
		["/repo/AGENTS.override.md"] = string.rep("x", 11),
		["/repo/AGENTS.md"] = "ignored fallback",
	}
	for i = 1, 7 do
		files["/home/u/.claude/" .. i .. ".md"] = "@./" .. (i + 1) .. ".md"
	end
	local rt = fake({ files = files })
	check_finding(context.collect(rt), "import-depth")
	check_finding(context.collect(rt), "codex-doc-limit", "fail")
	files["/repo/AGENTS.override.md"] = string.rep("x", 9)
	check_finding(context.collect((fake({ files = files }))), "codex-doc-limit", "warn")
end)

Test.test(
	"integrations context discovers plugins manual skills agents hooks and MCP for both harnesses",
	function()
		local files = {
			["/home/u/.claude/settings.json"] = '{"enabledPlugins":{"p@m":true,"unused@m":true},"hooks":{"SessionStart":[]}}',
			["/repo/.claude/settings.json"] = '{"enabledPlugins":{"p@m":true}}',
			["/home/u/.claude/plugins/installed_plugins.json"] = '{"plugins":{"p@m":[{"scope":"project","projectPath":"/repo","installPath":"/plugin"}]}}',
			["/plugin/skills/manual/SKILL.md"] = "---\nname: manual\ndescription: none\ndisable-model-invocation: true\n---\nbody",
			["/plugin/hooks/hooks.json"] = '{"hooks":{"SessionStart":[]}}',
			["/plugin/agents/worker.md"] = "---\nname: worker\ndescription: >\n  Inspect code safely\n---\nbody",
			["/plugin/commands/do.md"] = "do something",
			["/home/u/.claude/skills/same/SKILL.md"] = "---\nname: same\ndescription: inspect code files safely\n---\nbody",
			["/repo/.claude/skills/same/SKILL.md"] = "---\nname: same\ndescription: inspect code files safely\n---\nbody",
			["/home/u/.claude.json"] = '{"mcpServers":{"user":{}},"projects":{"/repo":{"mcpServers":{"project":{}}}}}',
			["/repo/.mcp.json"] = '{"mcpServers":{"local":{}}}',
			["/home/u/.codex/config.toml"] = '[plugins."p@m"]\nenabled = true\n[plugins."off@m"]\nenabled = false\n[mcp_servers.search]\ncommand = "tool"',
			["/home/u/.codex/plugins/cache/m/p/1.9/skills/old/SKILL.md"] = "old",
			["/home/u/.codex/plugins/cache/m/p/1.10/skills/new/SKILL.md"] = "---\nname: new\ndescription: inspect modules\n---\nbody",
			["/home/u/.codex/plugins/cache/m/p/1.10/hooks.json"] = '{"SessionStart":[]}',
			["/home/u/.agents/skills/manual/SKILL.md"] = "---\nname: manual\ndescription: explicit action\n---\nbody",
			["/home/u/.agents/skills/manual/agents/openai.yaml"] = "policy:\n  allow_implicit_invocation: false",
			["/home/u/.codex/agents/reviewer.toml"] = 'name = "reviewer"\ndescription = "Review code"',
		}
		local result = context.collect((fake({ files = files })))
		check_finding(result, "plugin-both-scopes")
		check_finding(result, "duplicate-name")
		check_finding(result, "overlap")
		local kinds, names, manuals = {}, {}, 0
		for _, source in ipairs(result.sources) do
			kinds[source.kind], names[source.name] = true, true
			if source.manual then
				manuals = manuals + 1
				Test.eq(source.listing, 0)
			end
		end
		assert(
			kinds.hook and kinds.mcp and kinds.agent and kinds.command and names.new and not names.old
		)
		Test.eq(manuals, 2)
	end
)

Test.test(
	"integrations context reports heavy budgets missing long broad descriptions and lesson issues",
	function()
		local files = {
			["/repo/CLAUDE.md"] = string.rep("x", 25000),
			["/home/u/.claude/skills/long/SKILL.md"] = "---\nname: long\ndescription: ALWAYS use proactively for any task "
				.. string.rep("a", 301)
				.. "\n---\n"
				.. string.rep("line\n", 502),
			["/home/u/.claude/agents/empty.md"] = "body",
			["/home/u/.claude/settings.json"] = '{"enabledPlugins":{"p@m":true}}',
			["/home/u/.claude/plugins/installed_plugins.json"] = '{"plugins":{"p@m":[{"scope":"user","installPath":"/plugin"}]}}',
			["/plugin/skills/long/SKILL.md"] = "---\nname: plugin-long\ndescription: "
				.. string.rep("b", 301)
				.. "\n---\nbody",
		}
		local lesson_lines = { "- [invalid] bad" }
		for i = 1, 41 do
			lesson_lines[#lesson_lines + 1] = string.format("- [L%03d] +2 -0 orc · f · lesson %d", i, i)
		end
		files["/repo/.orc/lessons.md"] = table.concat(lesson_lines, "\n")
		local result = context.collect((fake({ files = files })))
		for _, name in ipairs({
			"budget",
			"skill-body-large",
			"description-missing",
			"description-long",
			"broad-trigger",
			"lessons",
		}) do
			check_finding(result, name, "warn")
		end
		for _, args in ipairs({ { "--scope", "bad" }, { "positional" }, { "--unknown" }, { "--scope" } }) do
			expect_error(context.run(fake(), args), "usage:")
		end
		Test.eq(context.collect((fake({ no_git = true }))).schemaVersion, 1)
	end
)
