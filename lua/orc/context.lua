local M = {}
local MARK = { fail = "✗", warn = "!", info = "·" }
local USAGE = "usage: orc context [--scope user|project|all] [--json]\n"
local function trim(text)
	return vim.trim(text or "")
end
local function chars(text)
	return vim.fn.strchars(text)
end
local function lines(text)
	return (text:gsub("\r\n", "\n") .. "\n"):gmatch("(.-)\n")
end
local function keys(map)
	local result = vim.tbl_keys(map or {})
	table.sort(result)
	return result
end
local function finding(status, name, detail, hint)
	local item = { status = status, mark = MARK[status], name = name, detail = detail }
	if hint then
		item.fix = hint
	end
	return item
end
local function under(path, base)
	return path == base or path:sub(1, #base + 1) == base .. "/"
end
local function frontmatter(text)
	local header, body = text:match("^%-%-%-\r?\n(.-)\r?\n%-%-%-\r?\n(.*)$")
	local data = {}
	if header then
		local current
		for line in lines(header) do
			local key, value = line:match("^([%w_-]+):%s*(.-)%s*$")
			if key then
				current = key
				data[key] = value:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
			elseif current and line:match("^%s+%S") then
				data[current] = data[current] .. " " .. trim(line)
			end
		end
		data.description = trim((data.description or ""):gsub("^[>|][+-]?%s*", ""))
	end
	return data, body or text
end

---Find memory imports outside fenced and inline code.
---@param text string
---@return string[]
function M.find_imports(text)
	local found, fenced, tick = {}, false, string.char(96)
	for line in lines(text) do
		if line:match("^%s*" .. tick:rep(3)) or line:match("^%s*~~~") then
			fenced = not fenced
		elseif not fenced then
			for spec in
				(" " .. line:gsub(tick .. "[^" .. tick .. "]*" .. tick, " ")):gmatch("%s@([^%s]+)")
			do
				spec = spec:gsub("[.,;:)]+$", "")
				if
					spec:match("^~/")
					or spec:match("^%.?%./")
					or spec:match("^/")
					or spec:match("%.%w+$")
				then
					found[#found + 1] = spec
				end
			end
		end
	end
	return found
end

---Find literal absolute/home paths; skip globs, templates and ellipses.
---@param text string
---@return string[]
function M.find_paths(text)
	local found, tick = {}, string.char(96)
	for path in text:gmatch(tick .. "([^" .. tick .. "]+)" .. tick) do
		if
			(path:match("^~/") or path:match("^/[^/%s]+/"))
			and not path:find("[%s*{<$]")
			and not path:find("...", 1, true)
		then
			found[#found + 1] = path
		end
	end
	return found
end

---Read the flat TOML keys and sections used by the static audit.
---@param text string
---@return table
function M.parse_toml(text)
	local top, sections = {}, {}
	local current = top
	for raw in lines(text) do
		local line = trim(raw)
		local header = line:match("^%[([^%[%]]+)%]$")
		if header then
			header = trim(header:gsub('"', ""))
			sections[header], current = {}, nil
			current = sections[header]
		else
			local key, value = line:match("^([%w_.-]+)%s*=%s*(.*)$")
			if key then
				current[key] = trim(value:gsub("%s+#.*$", ""))
			end
		end
	end
	return { top = top, sections = sections }
end
local function unquote(text)
	return (text or ""):gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
end
local function resolve(rt, path, parent)
	if path:sub(1, 2) == "~/" then
		return rt.path(rt.env.HOME or "", path:sub(3))
	end
	return rt.abspath(path, parent)
end
local function project_root(rt, cwd)
	local result = rt.exec({ "git", "rev-parse", "--show-toplevel" }, { cwd = cwd })
	return result.code == 0 and trim(result.stdout) ~= "" and trim(result.stdout) or cwd
end
local function collect_sources(rt, root, cwd)
	local home, sources, findings, harness = rt.env.HOME or "", {}, {}, "claude"
	local function short(path)
		return home ~= "" and under(path, home) and ("~" .. path:sub(#home + 1)) or path
	end
	local function add(status, name, detail, hint, scope)
		local item = finding(status, name, detail, hint)
		item.harness, item.scope = harness, scope
		findings[#findings + 1] = item
	end
	local function text(path, scope)
		if not rt.exists(path) then
			return nil
		end
		local ok, content, err = pcall(rt.read, path)
		if not ok or not content then
			add(
				"warn",
				"unreadable",
				short(path) .. ": " .. tostring(err or content),
				"check file permissions",
				scope or (under(path, root) and "project" or "user")
			)
			return nil
		end
		return content
	end
	local function json(path)
		local content = text(path)
		if not content then
			return nil
		end
		local ok, doc = pcall(rt.decode, content)
		if not ok or type(doc) ~= "table" then
			add(
				"warn",
				"unreadable",
				short(path) .. ": invalid JSON",
				"fix the JSON syntax",
				under(path, root) and "project" or "user"
			)
			return nil
		end
		return doc
	end
	local function list(path)
		local ok, names = pcall(rt.list, path)
		return ok and names or {}
	end
	local function push(scope, origin, kind, name, path, size, description)
		local item = {
			harness = harness,
			scope = scope,
			origin = origin,
			kind = kind,
			name = name,
			path = path,
			always = 0,
			listing = 0,
			body = 0,
			manual = false,
			description = description or "",
		}
		for key, value in pairs(size or {}) do
			item[key] = value
		end
		sources[#sources + 1] = item
	end
	local function doc(kind, fallback, path, scope, origin)
		local content = text(path, scope)
		if not content then
			return
		end
		local data, body = frontmatter(content)
		local description, name = data.description or "", data.name or fallback
		local manual = data["disable-model-invocation"] == "true"
		if harness == "codex" then
			local policy = text(rt.path(vim.fs.dirname(path), "agents", "openai.yaml"), scope) or ""
			manual = kind == "skill" and policy:match("allow_implicit_invocation:%s*false") ~= nil
		end
		push(scope, origin, kind, name, path, {
			listing = manual and 0 or chars(name) + chars(description),
			body = chars(body),
			manual = manual,
		}, description)
		if kind == "skill" and select(2, content:gsub("\n", "")) + 1 > 500 then
			add(
				"warn",
				"skill-body-large",
				name .. ": over 500 lines",
				"move detail into referenced files",
				scope
			)
		end
	end
	local function skills(dir, scope, origin)
		for _, name in ipairs(list(dir)) do
			if name:sub(1, 1) ~= "." then
				doc("skill", name, rt.path(dir, name, "SKILL.md"), scope, origin)
			end
		end
	end
	local function md_files(kind, dir, scope, origin)
		for _, name in ipairs(list(dir)) do
			if name:match("%.md$") then
				doc(kind, name:sub(1, -4), rt.path(dir, name), scope, origin)
			end
		end
	end
	local function components(base, scope, origin)
		skills(rt.path(base, "skills"), scope, origin)
		md_files("agent", rt.path(base, "agents"), scope, origin)
		md_files("command", rt.path(base, "commands"), scope, origin)
	end
	local function hooks(value, path, scope, origin)
		if value and (value.SessionStart or (value.hooks and value.hooks.SessionStart)) then
			push(scope, origin, "hook", "SessionStart", path)
		end
	end
	local function mcp(servers, path, scope)
		for _, name in ipairs(keys(servers)) do
			push(scope, scope, "mcp", name, path)
		end
	end
	local function memory(path, scope, origin)
		if not rt.exists(path) then
			return 0
		end
		local visited = { [path] = true }
		local function walk(file, depth)
			local content = text(file, scope)
			if not content then
				return 0, 0
			end
			local count = chars(content)
			for _, literal in ipairs(M.find_paths(content)) do
				if not rt.exists(resolve(rt, literal, vim.fs.dirname(file))) then
					add(
						"warn",
						"dangling-path",
						short(file) .. ": " .. literal,
						"remove or fix the path",
						scope
					)
				end
			end
			for _, spec in ipairs(M.find_imports(content)) do
				local target = resolve(rt, spec, vim.fs.dirname(file))
				if visited[target] then
					add(
						"warn",
						"import-cycle",
						short(file) .. " -> " .. spec,
						"remove the circular @import",
						scope
					)
				elseif depth >= 5 then
					add(
						"warn",
						"import-depth",
						short(file) .. " -> " .. spec,
						"keep imports within 5 levels",
						scope
					)
				elseif not rt.exists(target) then
					add(
						"fail",
						"broken-import",
						short(file) .. " -> " .. spec,
						"fix or remove the @import",
						scope
					)
				else
					visited[target] = true
					count = count + walk(target, depth + 1)
					visited[target] = nil
				end
			end
			return count, #content
		end
		local count, bytes = walk(path, 0)
		push(scope, origin, "memory", short(path), path, { always = count })
		return bytes
	end
	local common = rt.exec(
		{ "git", "rev-parse", "--path-format=absolute", "--git-common-dir" },
		{ cwd = cwd }
	)
	local lessons_path =
		rt.path(common.code == 0 and vim.fs.dirname(trim(common.stdout)) or root, ".orc", "lessons.md")
	local function lessons()
		local content = text(lessons_path, "project")
		if not content then
			return
		end
		local lesson_module = require("orc.lessons")
		local parsed, invalid = lesson_module.parse(content)
		local active = lesson_module.select(parsed, #parsed)
		local size = 0
		for index = 1, math.min(40, #active) do
			size = size + chars(active[index].line) + 1
		end
		push("project", "project", "memory", short(lessons_path), lessons_path, { always = size })
		if harness == "claude" and (#active > 40 or #invalid > 0) then
			local detail = #active > 40 and (#active .. " active lessons > cap 40") or ""
			if #invalid > 0 then
				detail = detail
					.. (#detail > 0 and "; " or "")
					.. "invalid lines "
					.. table.concat(invalid, ", ")
			end
			add(
				"warn",
				"lessons",
				short(lessons_path) .. ": " .. detail,
				"run the reflect skill to consolidate",
				"project"
			)
		end
	end
	local cdir = rt.env.CLAUDE_CONFIG_DIR or rt.path(home, ".claude")
	local user_memory = rt.path(cdir, "CLAUDE.md")
	memory(user_memory, "user", "user")
	local seen, directory = { [user_memory] = true }, cwd
	while directory do
		for _, name in ipairs({ "CLAUDE.md", "CLAUDE.local.md", ".claude/CLAUDE.md" }) do
			local path = rt.path(directory, name)
			if not seen[path] then
				seen[path] = true
				memory(path, "project", "project")
			end
		end
		local parent = vim.fs.dirname(directory)
		directory = parent ~= directory and parent or nil
	end
	lessons()
	components(cdir, "user", "user")
	if root ~= home then
		components(rt.path(root, ".claude"), "project", "project")
	end
	local user_settings = rt.path(cdir, "settings.json")
	local settings = { { user_settings, "user" } }
	if rt.path(root, ".claude", "settings.json") ~= user_settings then
		settings[#settings + 1] = { rt.path(root, ".claude", "settings.json"), "project" }
	end
	settings[#settings + 1] = { rt.path(root, ".claude", "settings.local.json"), "project" }
	local enabled = {}
	for _, entry in ipairs(settings) do
		local data = json(entry[1])
		if data then
			hooks(data.hooks, entry[1], entry[2], entry[2])
			for id, on in pairs(data.enabledPlugins or {}) do
				if on == true then
					enabled[id] = enabled[id] or {}
					enabled[id][entry[2]] = true
				end
			end
		end
	end
	local installed = json(rt.path(cdir, "plugins", "installed_plugins.json"))
	installed = installed and installed.plugins or {}
	for _, id in ipairs(keys(enabled)) do
		local scopes = enabled[id]
		local scope = scopes.user and "user" or "project"
		if scopes.user and scopes.project then
			add("warn", "plugin-both-scopes", id, "enable it in one scope only", "user")
		end
		local entries = installed[id] or {}
		local entry = entries[1]
		for _, candidate in ipairs(entries) do
			if candidate.scope == "user" then
				entry = candidate
				break
			elseif candidate.projectPath == root then
				entry = candidate
			end
		end
		if entry and entry.installPath then
			components(entry.installPath, scope, id)
			local path = rt.path(entry.installPath, "hooks", "hooks.json")
			hooks(json(path), path, scope, id)
		end
	end
	local claude_path = rt.path(home, ".claude.json")
	local cj = json(claude_path)
	mcp(cj and cj.mcpServers, claude_path, "user")
	mcp(
		cj and cj.projects and cj.projects[root] and cj.projects[root].mcpServers,
		claude_path,
		"project"
	)
	local mp = rt.path(root, ".mcp.json")
	local mj = json(mp)
	mcp(mj and mj.mcpServers, mp, "project")

	harness = "codex"
	local xdir = rt.env.CODEX_HOME or rt.path(home, ".codex")
	local function agents_file(dir)
		local override = rt.path(dir, "AGENTS.override.md")
		return rt.exists(override) and override or rt.path(dir, "AGENTS.md")
	end
	memory(agents_file(xdir), "user", "user")
	local chain, current = {}, cwd
	while current do
		table.insert(chain, 1, current)
		if current == root then
			break
		end
		local parent = vim.fs.dirname(current)
		current = parent ~= current and parent or nil
	end
	local config_path = rt.path(xdir, "config.toml")
	local config = M.parse_toml(text(config_path) or "")
	local limit, bytes = tonumber(config.top.project_doc_max_bytes) or 32768, 0
	for _, dir in ipairs(chain) do
		bytes = bytes + memory(agents_file(dir), "project", "project")
	end
	lessons()
	if bytes > limit then
		add(
			"fail",
			"codex-doc-limit",
			"project docs " .. bytes .. " bytes > project_doc_max_bytes " .. limit .. "; Codex truncates",
			"shorten AGENTS.md or raise project_doc_max_bytes",
			"project"
		)
	elseif bytes > limit * 0.8 then
		add(
			"warn",
			"codex-doc-limit",
			"project docs " .. bytes .. " of " .. limit .. " bytes",
			"shorten AGENTS.md before Codex truncates it",
			"project"
		)
	end
	skills(rt.path(xdir, "skills"), "user", "user")
	skills(rt.path(home, ".agents", "skills"), "user", "user")
	if root ~= home then
		skills(rt.path(root, ".agents", "skills"), "project", "project")
	end
	for _, dir in ipairs({
		{ rt.path(xdir, "agents"), "user" },
		{ rt.path(root, ".codex", "agents"), "project" },
	}) do
		for _, name in ipairs(list(dir[1])) do
			if name:match("%.toml$") then
				local path = rt.path(dir[1], name)
				local data = M.parse_toml(text(path) or "").top
				local description, agent = unquote(data.description), unquote(data.name or name:sub(1, -6))
				push(
					dir[2],
					dir[2],
					"agent",
					agent,
					path,
					{ listing = chars(agent) + chars(description) },
					description
				)
			end
		end
	end
	for _, header in ipairs(keys(config.sections)) do
		local values = config.sections[header]
		local plugin, marketplace = header:match("^plugins%.(.+)@([^@]+)$")
		if plugin and values.enabled ~= "false" then
			local dir = rt.path(xdir, "plugins", "cache", marketplace, plugin)
			local versions = list(dir)
			table.sort(versions, function(a, b)
				local aa, bb = {}, {}
				for n in a:gmatch("%d+") do
					aa[#aa + 1] = tonumber(n)
				end
				for n in b:gmatch("%d+") do
					bb[#bb + 1] = tonumber(n)
				end
				for i = 1, math.max(#aa, #bb) do
					if (aa[i] or 0) ~= (bb[i] or 0) then
						return (aa[i] or 0) < (bb[i] or 0)
					end
				end
				return a < b
			end)
			local version = versions[#versions]
			if version then
				local base = rt.path(dir, version)
				skills(rt.path(base, "skills"), "user", plugin .. "@" .. marketplace)
				local path = rt.path(base, "hooks", "hooks.json")
				if not rt.exists(path) then
					path = rt.path(base, "hooks.json")
				end
				hooks(json(path), path, "user", plugin .. "@" .. marketplace)
			end
		end
		local name = header:match("^mcp_servers%.([^.]+)$")
		if name then
			push("user", "user", "mcp", name, config_path)
		end
	end
	local ok, shared = pcall(require("orc.inkdrop_mcp").resolve, rt)
	if not ok or shared.mode == "shared" then
		for _, provider in ipairs({ "claude", "codex" }) do
			harness = provider
			add(
				ok and "info" or "fail",
				"inkdrop-mcp",
				ok
						and ("shared HTTP requested: " .. shared.url .. "; effective MCP policy is checked on launch")
					or tostring(shared),
				ok and "this static audit does not connect to the service or inspect live tool availability"
					or "check the private shared Inkdrop settings",
				"user"
			)
		end
	end
	return { sources = sources, findings = findings }
end
local function tokens(count)
	return math.ceil(count / 4)
end
local function token_text(count)
	local amount = tokens(count)
	return amount >= 1000 and string.format("~%.1fk", amount / 1000) or ("~" .. amount)
end
local function words(text)
	local found = {}
	for word in text:lower():gmatch("[a-z]+") do
		if #word >= 4 then
			found[word] = true
		end
	end
	return found
end
local function overlap(a, b)
	local common, total = 0, 0
	for word in pairs(a) do
		total = total + 1
		if b[word] then
			common = common + 1
		end
	end
	for word in pairs(b) do
		if not a[word] then
			total = total + 1
		end
	end
	return total > 0 and common / total or 0
end

---Analyze listing budgets, description triggers and duplicate configuration.
---@param data table
---@param scope? string
---@return table
function M.analyze(data, scope)
	scope = scope or "all"
	local kept, output = {}, {}
	local function keep(item)
		return scope == "all" or item.scope == scope
	end
	for _, source in ipairs(data.sources) do
		if keep(source) then
			kept[#kept + 1] = source
		end
	end
	for _, harness in ipairs({ "claude", "codex" }) do
		local own, docs, always, listing, manual, counts = {}, {}, 0, 0, 0, {}
		local has_findings = false
		for _, item in ipairs(data.findings) do
			if item.harness == harness and keep(item) then
				has_findings = true
			end
		end
		for _, source in ipairs(kept) do
			if source.harness == harness then
				own[#own + 1] = source
				always, listing = always + source.always, listing + source.listing
				if source.manual then
					manual = manual + 1
				else
					counts[source.kind] = (counts[source.kind] or 0) + 1
					if vim.tbl_contains({ "skill", "agent", "command" }, source.kind) then
						docs[#docs + 1] = source
					end
				end
			end
		end
		local function add(status, name, detail, hint)
			local item = finding(status, name, detail, hint)
			item.harness = harness
			output[#output + 1] = item
		end
		if #own > 0 or has_findings then
			local detail = string.format(
				"always-loaded %s tokens (%d files), listing %s tokens (%d skills, %d agents, %d commands%s), %d MCP servers, %d SessionStart hooks (not measured)",
				token_text(always),
				counts.memory or 0,
				token_text(listing),
				counts.skill or 0,
				counts.agent or 0,
				counts.command or 0,
				manual > 0 and ("; " .. manual .. " manual-only, not listed") or "",
				counts.mcp or 0,
				counts.hook or 0
			)
			local heavy = tokens(always) > 6000 or tokens(listing) > 5000
			add(
				heavy and "warn" or "info",
				"budget",
				detail,
				heavy and "disable unused plugins or trim memory files and descriptions" or nil
			)
			table.sort(own, function(a, b)
				local aa, bb = a.always + a.listing, b.always + b.listing
				return aa == bb and a.path < b.path or aa > bb
			end)
			local emitted = 0
			for _, source in ipairs(own) do
				if source.always + source.listing > 0 and emitted < 5 then
					add(
						"info",
						"top",
						token_text(source.always + source.listing)
							.. "  "
							.. source.kind
							.. " "
							.. source.name
							.. " ("
							.. source.origin
							.. ")"
					)
					emitted = emitted + 1
				end
			end
			local by_name, plugin_long = {}, {}
			for _, source in ipairs(docs) do
				local label = source.kind .. " " .. source.name .. " (" .. source.origin .. ")"
				if source.description == "" and source.kind ~= "command" then
					add("warn", "description-missing", label, "add a description to the frontmatter")
				end
				if chars(source.description) > 300 then
					if source.origin == "user" or source.origin == "project" then
						add(
							"warn",
							"description-long",
							label .. ": " .. chars(source.description) .. " chars",
							"keep it under 300"
						)
					else
						plugin_long[source.origin] = plugin_long[source.origin] or {}
						table.insert(
							plugin_long[source.origin],
							source.name .. " " .. chars(source.description)
						)
					end
				end
				local lower = source.description:lower()
				if
					source.description:find("%f[%w]ANY%f[%W]")
					or source.description:find("%f[%w]ALWAYS%f[%W]")
					or source.description:find("%f[%w]EVERY%f[%W]")
					or source.description:find("%f[%w]MUST%f[%W]")
					or lower:find("use proactively", 1, true)
					or lower:match("any coding task")
					or lower:match("every coding task")
					or lower:match("any task")
					or lower:match("every task")
					or lower:match("always use")
					or lower:match("always load")
					or lower:match("always invoke")
				then
					add("warn", "broad-trigger", label, "name the situations that should trigger it")
				end
				local name = source.kind .. " " .. source.name
				by_name[name] = by_name[name] or {}
				by_name[name][source.origin] = true
			end
			for _, origin in ipairs(keys(plugin_long)) do
				local names = plugin_long[origin]
				add(
					"warn",
					"description-long",
					origin .. ": " .. #names .. " over 300 chars (" .. table.concat(names, ", ") .. ")",
					"report upstream or disable the plugin if unused"
				)
			end
			for _, name in ipairs(keys(by_name)) do
				local origins = keys(by_name[name])
				if #origins > 1 then
					add(
						"warn",
						"duplicate-name",
						name .. ": " .. table.concat(origins, ", "),
						"keep one copy"
					)
				end
			end
			for i, a in ipairs(docs) do
				if a.kind ~= "command" and a.description ~= "" then
					for j = i + 1, #docs do
						local b = docs[j]
						if
							b.kind ~= "command"
							and b.description ~= ""
							and overlap(words(a.description), words(b.description)) >= 0.5
						then
							add(
								"warn",
								"overlap",
								a.name .. " (" .. a.origin .. ") ~ " .. b.name .. " (" .. b.origin .. ")",
								"merge or sharpen one description"
							)
						end
					end
				end
			end
		end
	end
	for _, item in ipairs(data.findings) do
		if keep(item) then
			output[#output + 1] = item
		end
	end
	return { schemaVersion = 1, sources = kept, findings = output }
end

---Audit configuration for both harnesses without contacting servers or models.
---@param rt table
---@param cwd? string
---@return table
function M.collect(rt, cwd)
	cwd = cwd or rt.cwd
	return M.analyze(collect_sources(rt, project_root(rt, cwd), cwd))
end

---Run the scope-filtered audit; structural failures produce exit code 1.
---@param rt table
---@param argv string[]
---@return table
function M.run(rt, argv)
	local ok, flags, positions =
		pcall(require("orc.args").parse, argv, { scope = "string", json = "boolean" })
	if
		not ok
		or #positions ~= 0
		or not vim.tbl_contains({ "all", "user", "project" }, flags.scope or "all")
	then
		return { code = 1, out = "", err = USAGE }
	end
	local success, data = pcall(function()
		return M.analyze(collect_sources(rt, project_root(rt, rt.cwd), rt.cwd), flags.scope)
	end)
	if not success then
		local item = finding("fail", "context", tostring(data))
		item.harness = "claude"
		data = { schemaVersion = 1, sources = {}, findings = { item } }
	end
	local code = 0
	for _, item in ipairs(data.findings) do
		if item.status == "fail" then
			code = 1
		end
	end
	if flags.json then
		return { code = code, out = rt.encode(data) .. "\n", err = "" }
	end
	local rendered = {}
	for _, harness in ipairs({ "claude", "codex" }) do
		local own = {}
		for _, item in ipairs(data.findings) do
			if item.harness == harness then
				own[#own + 1] = "  "
					.. item.mark
					.. " "
					.. item.name
					.. ": "
					.. item.detail
					.. (item.fix and (" — fix: " .. item.fix) or "")
			end
		end
		if #own > 0 then
			rendered[#rendered + 1] = harness .. "\n" .. table.concat(own, "\n")
		end
	end
	return { code = code, out = table.concat(rendered, "\n") .. "\n", err = "" }
end

return M
