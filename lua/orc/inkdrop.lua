local M = {}
local BEGIN, END = "<!-- orc:begin -->", "<!-- orc:end -->"
local USAGE =
	"usage: orc inkdrop init [--book name] [--parent name] [--create] [--move] | inbox [--json] | claim <note-id> <feature> | push <feature> [--done] | pull <feature> | lessons\n"
local function trim(s)
	return vim.trim(s or "")
end
local function fail(message)
	error("orc inkdrop: " .. message, 0)
end
local function root(rt, cwd)
	local r = rt.exec(
		{ "git", "rev-parse", "--path-format=absolute", "--git-common-dir" },
		{ cwd = cwd or rt.cwd }
	)
	if r.code ~= 0 or trim(r.stdout) == "" then
		fail("not a git repository: " .. (cwd or rt.cwd))
	end
	return vim.fs.dirname(trim(r.stdout))
end
local function nullable(value)
	return value ~= nil and value ~= vim.NIL and value ~= ""
end
local function epoch(rt)
	return vim.fn.strptime("%Y-%m-%dT%H:%M:%S%z", (rt.now():gsub("Z$", "+0000"))) * 1000
end

---Read this repository's notebook mapping without contacting Inkdrop.
---@param rt table
---@param cwd? string
---@return table
function M.config(rt, cwd)
	local r = rt.exec({ "git", "config", "--get-regexp", "^orc\\.inkdrop" }, { cwd = cwd or rt.cwd })
	local values = {}
	for key, value in (r.stdout or ""):gmatch("([^\n ]+) +([^\n]+)") do
		values[key] = trim(value)
	end
	return {
		book = values["orc.inkdropbook"] or vim.NIL,
		bookName = values["orc.inkdropbookname"] or vim.NIL,
		tag = values["orc.inkdroptag"] or vim.NIL,
	}
end

---Whether credentials and a notebook mapping enable the integration.
---@param rt table
---@param cwd? string
---@return boolean
function M.enabled(rt, cwd)
	return rt.env.ORC_INKDROP ~= "0"
		and nullable(rt.env.INKDROP_LOCAL_USERNAME)
		and nullable(rt.env.INKDROP_LOCAL_PASSWORD)
		and nullable(M.config(rt, cwd).book)
end

---Notebook identity suitable for session-context injection, or false.
---@param rt table
---@param cwd? string
---@return table|false
function M.flag(rt, cwd)
	if not M.enabled(rt, cwd) then
		return false
	end
	local config = M.config(rt, cwd)
	return { id = config.book, name = nullable(config.bookName) and config.bookName or config.book }
end

local function locate(body)
	local marks, offset = {}, 1
	for line in (body .. "\n"):gmatch("(.-)\n") do
		local clean = line:gsub("\r$", "")
		if clean == BEGIN or clean == END then
			marks[#marks + 1] = { begin = clean == BEGIN, first = offset, last = offset + #clean - 1 }
		end
		offset = offset + #line + 1
	end
	if #marks == 0 then
		return nil
	end
	if #marks ~= 2 or not marks[1].begin or marks[2].begin then
		return "damaged"
	end
	return { first = marks[1].first, last = marks[2].last }
end
local function intact(body, id)
	local at = locate(body)
	if at == "damaged" then
		fail((id or "note") .. " has a damaged orc block; fix it in Inkdrop")
	end
	return at
end

---Extract user-authored text, refusing malformed managed markers.
---@param body string
---@return string
function M.spec(body)
	local at = intact(body)
	return trim(at and (body:sub(1, at.first - 1) .. body:sub(at.last + 1)) or body)
end

---Replace the managed block, preserving every byte outside it.
---@param body string
---@param block string
---@return string
function M.splice(body, block)
	local at = intact(body)
	if at then
		return body:sub(1, at.first - 1) .. block .. body:sub(at.last + 1)
	end
	local head = body:gsub("%s+$", "")
	return head ~= "" and (head .. "\n\n" .. block) or block
end
local function defuse(text)
	return ("\n" .. text):gsub("\n<!%-%- orc:(%a+) %-%->", "\n<!-- orc %1 -->"):sub(2)
end

---Render progress from the plan, task states and optional capture log.
---@param feature string
---@param plan? string
---@param tasks table[]
---@param log? string
---@param now string
---@return string
function M.render_block(feature, plan, tasks, log, now)
	local base = ("\n" .. (plan or "")):match("\nBase branch:%s*([^%s#]+)") or "-"
	local tick = string.char(96)
	local parts = {
		"## orc · " .. tick .. feature .. tick .. " · " .. base .. " · updated " .. now
			:sub(1, 16)
			:gsub("T", " "),
	}
	local decisions, inside, open = {}, false, false
	for line in ((plan or ""):gsub("\r\n", "\n") .. "\n"):gmatch("(.-)\n") do
		if line:match("^## ") then
			inside, open = line == "## Decisions", false
		elseif inside and line:match("^%- ") then
			decisions[#decisions + 1], open = line, true
		elseif inside and open and line:match("^%s+%S") then
			decisions[#decisions] = decisions[#decisions] .. "\n" .. line
		else
			open = false
		end
	end
	if #decisions > 0 then
		parts[#parts + 1] = "**Decisions**\n\n" .. table.concat(decisions, "\n")
	end
	if #tasks == 0 then
		parts[#parts + 1] = "_claimed, no plan yet_"
	else
		local lines = {}
		for _, task in ipairs(tasks) do
			local label = task.id .. (nullable(task.goal) and (" " .. task.goal) or "")
			if nullable(task.merged) then
				lines[#lines + 1] = "- [x] " .. label .. " (merged " .. task.merged.commit:sub(1, 7) .. ")"
			else
				local state = nullable(task.agent) and task.agent.state
					or nullable(task.report) and task.report.status
					or nullable(task.worktree) and "worktree"
					or "pending"
				lines[#lines + 1] = "- [ ] " .. label .. " (" .. state .. ")"
			end
		end
		parts[#parts + 1] = "**Tasks**\n\n" .. table.concat(lines, "\n")
	end
	if trim(log) ~= "" then
		parts[#parts + 1] = "### Log\n\n" .. trim(log)
	end
	return BEGIN .. "\n" .. defuse(table.concat(parts, "\n\n")) .. "\n" .. END
end

local function quoted(value)
	return '"'
		.. value
			:gsub("\\", "\\\\")
			:gsub('"', '\\"')
			:gsub("\r", "\\r")
			:gsub("\n", "\\n")
			:gsub("\t", "\\t")
		.. '"'
end
local function server(rt)
	if not nullable(rt.env.INKDROP_LOCAL_USERNAME) or not nullable(rt.env.INKDROP_LOCAL_PASSWORD) then
		fail("set INKDROP_LOCAL_USERNAME and INKDROP_LOCAL_PASSWORD")
	end
	local url = rt.env.INKDROP_LOCAL_SERVER_URL or "http://localhost:19840"
	local scheme, authority = url:match("^([%a][%w+.-]*)://([^/?#]+)")
	if
		not scheme
		or (scheme:lower() ~= "http" and scheme:lower() ~= "https")
		or authority:find("@", 1, true)
	then
		fail("INKDROP_LOCAL_SERVER_URL is not a valid URL")
	end
	local host = authority:match("^%[([^%]]+)%]") or authority:match("^([^:]+)")
	if host:lower() ~= "localhost" and host ~= "127.0.0.1" and host ~= "::1" then
		fail("refusing non-loopback Inkdrop server host " .. host)
	end
	local suffix = authority:sub(host == "::1" and 6 or #host + 1)
	if suffix ~= "" and not suffix:match("^:%d+$") then
		fail("INKDROP_LOCAL_SERVER_URL is not a valid URL")
	end
	local auth =
		vim.base64.encode(rt.env.INKDROP_LOCAL_USERNAME .. ":" .. rt.env.INKDROP_LOCAL_PASSWORD)
	return { base = scheme:lower() .. "://" .. authority, auth = "Basic " .. auth }
end
local function escape(value)
	return (
		tostring(value):gsub("[^%w%-._~]", function(c)
			return string.format("%%%02X", c:byte())
		end)
	)
end
local function request(rt, srv, method, path, opts)
	opts = opts or {}
	local url = srv.base .. path
	if opts.query then
		local query = {}
		for _, key in ipairs(vim.tbl_keys(opts.query)) do
			query[#query + 1] = escape(key) .. "=" .. escape(opts.query[key])
		end
		table.sort(query)
		url = url .. "?" .. table.concat(query, "&")
	end
	local config = {
		"silent",
		"show-error",
		"max-redirs = 0",
		'noproxy = "*"',
		'proto = "=http,https"',
		"request = " .. quoted(method),
		"url = " .. quoted(url),
		"header = " .. quoted("Authorization: " .. srv.auth),
		"max-time = " .. tostring((opts.timeout or 5000) / 1000),
		'write-out = "\\n%{http_code}"',
	}
	if opts.body then
		config[#config + 1] = 'header = "Content-Type: application/json"'
		config[#config + 1] = "data-binary = " .. quoted(rt.encode(opts.body))
	end
	local r = rt.exec({ "curl", "--disable", "--config", "-" }, {
		stdin = table.concat(config, "\n") .. "\n",
		timeout = (opts.timeout or 5000) + 1000,
	})
	if r.code ~= 0 then
		fail("Inkdrop is not running or its local server is off (Preferences → Local Server)")
	end
	local body, status = r.stdout:match("^(.*)\n(%d%d%d)$")
	status = tonumber(status)
	if status == 401 then
		fail("unauthorized; check INKDROP_LOCAL_USERNAME and INKDROP_LOCAL_PASSWORD")
	elseif status == 409 then
		error({ conflict = true }, 0)
	elseif not status or status < 200 or status >= 300 then
		fail(method .. " " .. path .. " failed: HTTP " .. tostring(status))
	end
	local ok, value = pcall(rt.decode, body)
	if not ok then
		fail(method .. " " .. path .. " returned invalid JSON")
	end
	return value
end

---Bounded health request; never exposes credentials or throws.
---@param rt table
---@return table
function M.probe(rt)
	local ok, value = pcall(function()
		return request(rt, server(rt), "GET", "/", { timeout = 1500 })
	end)
	return ok and { version = tostring(value.version) }
		or { error = tostring(value):gsub("^orc inkdrop: ", "") }
end
local function setup(rt, cwd, need_config)
	local base = root(rt, cwd)
	local srv, config = server(rt), M.config(rt, base)
	if
		need_config ~= false
		and not (nullable(config.book) and nullable(config.bookName) and nullable(config.tag))
	then
		fail("this repo has no Inkdrop notebook; run orc inkdrop init")
	end
	return {
		rt = rt,
		root = base,
		config = config,
		call = function(method, path, opts)
			return request(rt, srv, method, path, opts)
		end,
	}
end
local function feature_dir(ctx, feature)
	if not feature:match("^[%w_.-]+$") or feature:match("^%.+$") then
		fail("invalid feature name: " .. feature)
	end
	return ctx.rt.path(ctx.root, ".scratch", feature)
end
local function read_link(ctx, dir)
	local path = ctx.rt.path(dir, "inkdrop.json")
	local text = ctx.rt.read(path)
	if not text then
		return nil
	end
	local ok, value = pcall(ctx.rt.decode, text)
	if
		not ok
		or type(value) ~= "table"
		or type(value.noteId) ~= "string"
		or not value.noteId:match("^note:[%w_-]+$")
	then
		fail("invalid " .. path)
	end
	return value
end
local function write_link(ctx, dir, link)
	ctx.rt.write(ctx.rt.path(dir, "inkdrop.json"), ctx.rt.encode(link) .. "\n")
end
local function linked(ctx)
	local ids = {}
	for _, name in ipairs(ctx.rt.list(ctx.rt.path(ctx.root, ".scratch"))) do
		local ok, link = pcall(read_link, ctx, ctx.rt.path(ctx.root, ".scratch", name))
		if ok and link then
			ids[link.noteId] = true
		end
	end
	return ids
end
local function create(ctx, kind, doc)
	local result = ctx.call("POST", "/" .. kind .. "s", { body = doc })
	if type(result.id) ~= "string" or not result.id:match("^" .. kind .. ":") then
		fail("POST /" .. kind .. "s returned no " .. kind .. " id")
	end
	return result.id
end
local function save(ctx, id, modify)
	for attempt = 1, 2 do
		local doc = modify(ctx.call("GET", "/" .. id))
		doc.updatedAt = epoch(ctx.rt)
		local ok, err = pcall(ctx.call, "POST", "/notes", { body = doc })
		if ok then
			return doc
		elseif type(err) ~= "table" or not err.conflict then
			error(err, 0)
		elseif attempt == 2 then
			fail("note changed concurrently; retry")
		end
	end
end
local function block(ctx, dir, feature)
	local plan = ctx.rt.read(ctx.rt.path(dir, "plan.md"))
	local tasks = {}
	for _, item in ipairs(require("orc.status").collect(ctx.rt, ctx.root).features) do
		if item.feature == feature then
			tasks = item.tasks
		end
	end
	return M.render_block(feature, plan, tasks, ctx.rt.read(ctx.rt.path(dir, "log.md")), ctx.rt.now()),
		plan
end
local function push_feature(rt, cwd, feature, done)
	local ctx = setup(rt, cwd)
	local dir = feature_dir(ctx, feature)
	local rendered, plan = block(ctx, dir, feature)
	local link = read_link(ctx, dir)
	if link then
		save(ctx, link.noteId, function(note)
			intact(note.body or "", link.noteId)
			note.body = M.splice(note.body or "", rendered)
			if done then
				note.status = "completed"
			end
			return note
		end)
		return "pushed " .. link.noteId .. "\n"
	end
	rt.mkdir(dir)
	local time = epoch(rt)
	local note = {
		doctype = "markdown",
		title = ("\n" .. (plan or "")):match("\n# ([^\n]+)") or feature,
		body = rendered,
		bookId = ctx.config.book,
		tags = { ctx.config.tag },
		status = done and "completed" or "active",
		createdAt = time,
		updatedAt = time,
	}
	local id = create(ctx, "note", note)
	write_link(ctx, dir, { noteId = id, specHash = vim.fn.sha256(M.spec(note.body)) })
	return "created " .. id .. "\n"
end
local function attempt(fn)
	local ok, result = pcall(fn)
	if ok then
		return { code = 0, out = result, err = "" }
	end
	local message = type(result) == "table" and result.conflict and "note changed concurrently; retry"
		or tostring(result)
	if not message:match("^orc inkdrop:") then
		message = "orc inkdrop: " .. message
	end
	return { code = 1, out = "", err = message .. "\n" }
end

---Mirror a feature, keeping the user's spec hash unchanged.
---@param rt table
---@param cwd string
---@param feature string
---@param opts? table
---@return table
function M.push(rt, cwd, feature, opts)
	return attempt(function()
		return push_feature(rt, cwd, feature, opts and opts.done)
	end)
end
local function ensure_tag(ctx, name, tags)
	for _, tag in ipairs(tags or ctx.call("GET", "/tags", { query = { limit = 1000 } })) do
		if tag.name == name then
			return tag
		end
	end
	local time = epoch(ctx.rt)
	local doc = { name = name, color = "default", createdAt = time, updatedAt = time }
	doc._id = create(ctx, "tag", doc)
	return doc
end

---Extract a repository identity from HTTPS or SCP-style origin URLs.
---@param url string
---@return string?
function M.remote_key(url)
	local path = trim(url):match("^%a[%w+.-]*://[^/]+/(.+)")
		or trim(url):match("^[^@/%s]+@[^:/%s]+:(.+)")
	if not path or path:find("//", 1, true) then
		return nil
	end
	path = path:gsub("/$", ""):gsub("%.git$", "")
	return path:match("([^/]+/[^/]+)$")
end
local function repo_key(ctx)
	local r = ctx.rt.exec({ "git", "remote", "get-url", "origin" }, { cwd = ctx.root })
	return r.code == 0 and M.remote_key(r.stdout) or vim.fs.basename(ctx.root)
end
local function identity(note)
	local body = note.body or ""
	local at = intact(body, note._id)
	return at and ("\n" .. body:sub(at.first, at.last)):match("\nlesson: ([^\r\n]+)") or nil
end
local function has(tags, id)
	return vim.tbl_contains(tags or {}, id)
end
local function relocate(ctx, old, target, move, tag, lesson)
	local found = ctx.call("GET", "/notes", { query = { keyword = "bookId:" .. old, limit = 1000 } })
	local ids, mine, key = linked(ctx), {}, repo_key(ctx) .. "/"
	for _, note in ipairs(found) do
		if note.bookId == old then
			local own_lesson = lesson
				and has(note.tags, lesson._id)
				and (identity(note) or ""):sub(1, #key) == key
			if
				own_lesson
				or (has(note.tags, tag._id) and (ids[note._id] or locate(note.body or "") == nil))
			then
				mine[#mine + 1] = note
			end
		end
	end
	if #mine > 0 and not move then
		fail(
			#mine
				.. " orc notes in "
				.. old
				.. "; rerun with --move to move them, or move them in Inkdrop first"
		)
	end
	for _, note in ipairs(mine) do
		save(ctx, note._id, function(doc)
			doc.bookId = target
			return doc
		end)
	end
	return move and ("moved " .. #mine .. " notes from " .. old .. "\n") or ""
end
local function init(rt, flags)
	local ctx = setup(rt, rt.cwd, false)
	local name = flags.book or vim.fs.basename(ctx.root)
	local parent_result = rt.exec(
		{ "git", "config", "--get", "orc.inkdropParent" },
		{ cwd = ctx.root }
	)
	local parent = flags.parent
		or (
			parent_result.code == 0 and trim(parent_result.stdout) ~= "" and trim(parent_result.stdout)
			or nil
		)
	local books = ctx.call("GET", "/books", { query = { limit = 1000 } })
	local function pick(book_name, parent_id, root_only)
		for _, book in ipairs(books) do
			if
				(book.name or ""):lower() == book_name:lower()
				and (not root_only or not nullable(book.parentBookId))
				and (not parent_id or book.parentBookId == parent_id)
			then
				return book
			end
		end
		if not flags.create then
			fail('no notebook named "' .. book_name .. '"; pass --create to create it')
		end
		local time = epoch(rt)
		local doc =
			{ name = book_name, parentBookId = parent_id or vim.NIL, createdAt = time, updatedAt = time }
		doc._id = create(ctx, "book", doc)
		return doc
	end
	local top = parent and pick(parent, nil, true) or nil
	local book = pick(name, top and top._id or nil)
	local display = top and (top.name .. "/" .. book.name) or book.name
	local tags = ctx.call("GET", "/tags", { query = { limit = 1000 } })
	local tag, lesson = ensure_tag(ctx, "orc", tags), nil
	for _, item in ipairs(tags) do
		if item.name == "orc-lesson" then
			lesson = item
		end
	end
	local moved = ""
	if nullable(ctx.config.book) and ctx.config.book ~= book._id then
		moved = relocate(ctx, ctx.config.book, book._id, flags.move, tag, lesson)
	end
	for _, pair in ipairs({
		{ "orc.inkdropBook", book._id },
		{ "orc.inkdropBookName", display },
		{ "orc.inkdropTag", tag._id },
	}) do
		local result = rt.exec({ "git", "config", pair[1], pair[2] }, { cwd = ctx.root })
		if result.code ~= 0 then
			fail("git config " .. pair[1] .. " failed: " .. trim(result.stderr))
		end
	end
	return "notebook " .. display .. " (" .. book._id .. "), tag orc (" .. tag._id .. ")\n" .. moved
end
local function inbox(rt, json)
	local ctx = setup(rt)
	local ids, notes = linked(ctx), {}
	local found = ctx.call("GET", "/notes", {
		query = {
			keyword = "bookId:" .. ctx.config.book .. " tag:orc status:active",
			limit = 100,
		},
	})
	for _, note in ipairs(found) do
		if
			note.bookId == ctx.config.book
			and has(note.tags, ctx.config.tag)
			and not locate(note.body or "")
			and not ids[note._id]
		then
			notes[#notes + 1] = { id = note._id, title = note.title, updatedAt = note.updatedAt }
		end
	end
	if json then
		return rt.encode({ schemaVersion = 1, notes = notes }) .. "\n"
	end
	local lines = {}
	for _, note in ipairs(notes) do
		lines[#lines + 1] = note.id .. "  " .. note.title .. "\n"
	end
	return #lines > 0 and table.concat(lines) or "no queued notes\n"
end
local function claim(rt, id, feature)
	local ctx = setup(rt)
	if not id:match("^note:[%w_-]+$") then
		fail("invalid note id: " .. id)
	end
	local dir = feature_dir(ctx, feature)
	local link = read_link(ctx, dir)
	if link then
		fail("feature " .. feature .. " is already linked to " .. link.noteId)
	end
	local rendered = block(ctx, dir, feature)
	local doc = save(ctx, id, function(note)
		if note.bookId ~= ctx.config.book then
			fail(id .. " is not in notebook " .. ctx.config.bookName)
		end
		if intact(note.body or "", id) then
			fail(id .. " is already claimed")
		end
		note.body = M.splice(note.body or "", rendered)
		note.tags = note.tags or {}
		if not has(note.tags, ctx.config.tag) then
			note.tags[#note.tags + 1] = ctx.config.tag
		end
		return note
	end)
	local spec = M.spec(doc.body)
	rt.mkdir(dir)
	write_link(ctx, dir, { noteId = id, specHash = vim.fn.sha256(spec) })
	return "# " .. doc.title .. "\n\n" .. spec .. "\n"
end
local function pull(rt, feature)
	local ctx = setup(rt)
	local dir = feature_dir(ctx, feature)
	local link = read_link(ctx, dir)
	if not link then
		fail("feature " .. feature .. " has no linked note")
	end
	local doc = ctx.call("GET", "/" .. link.noteId)
	intact(doc.body or "", link.noteId)
	local spec = M.spec(doc.body or "")
	local hash = vim.fn.sha256(spec)
	if hash == link.specHash then
		return "changed: no\n"
	end
	link.specHash = hash
	write_link(ctx, dir, link)
	return "changed: yes\n\n" .. spec .. "\n"
end

---Render one durable, repository-qualified lesson note.
---@param repo string
---@param lesson table
---@return table
function M.render_lesson(repo, lesson)
	local count = vim.fn.strchars(lesson.text)
	local title = count > 60 and (vim.fn.strcharpart(lesson.text, 0, 59) .. "…") or lesson.text
	return {
		title = repo .. ":" .. lesson.id .. " " .. title,
		block = BEGIN .. "\n" .. defuse(
			"lesson: "
				.. repo
				.. "/"
				.. lesson.id
				.. "\nscore: +"
				.. lesson.up
				.. " -"
				.. lesson.down
				.. " · scope: "
				.. lesson.scope
				.. " · feature: "
				.. lesson.feature
				.. "\n\n"
				.. lesson.text
		) .. "\n" .. END,
	}
end
local function lessons(rt)
	local base = root(rt)
	local path = rt.path(base, ".orc", "lessons.md")
	local text = rt.read(path)
	if not text then
		return "no lessons in " .. path .. "\n"
	end
	local ctx, active = setup(rt), {}
	local key = repo_key(ctx)
	local lesson_module = require("orc.lessons")
	local parsed = lesson_module.parse(text)
	for _, lesson in ipairs(lesson_module.select(parsed, #parsed)) do
		active[key .. "/" .. lesson.id] = M.render_lesson(key, lesson)
	end
	local tag = ensure_tag(ctx, "orc-lesson")
	local found = ctx.call(
		"GET",
		"/notes",
		{ query = { keyword = "bookId:" .. ctx.config.book .. " tag:orc-lesson", limit = 1000 } }
	)
	local mine, seen = {}, {}
	for _, note in ipairs(found) do
		if note.bookId == ctx.config.book and has(note.tags, tag._id) then
			local id = identity(note)
			if id and id:sub(1, #key + 1) == key .. "/" then
				mine[#mine + 1] = { note = note, id = id }
			end
		end
	end
	local counts = { created = 0, updated = 0, dropped = 0, unchanged = 0 }
	for _, item in ipairs(mine) do
		seen[item.id] = true
		local wanted, note = active[item.id], item.note
		if not wanted then
			if note.status ~= "dropped" then
				save(ctx, note._id, function(doc)
					doc.status = "dropped"
					return doc
				end)
				counts.dropped = counts.dropped + 1
			end
		elseif
			note.title == wanted.title
			and note.body == M.splice(note.body or "", wanted.block)
			and note.status == "active"
		then
			counts.unchanged = counts.unchanged + 1
		else
			save(ctx, note._id, function(doc)
				doc.title, doc.body, doc.status =
					wanted.title, M.splice(doc.body or "", wanted.block), "active"
				return doc
			end)
			counts.updated = counts.updated + 1
		end
	end
	for id, wanted in pairs(active) do
		if not seen[id] then
			local time = epoch(rt)
			create(ctx, "note", {
				doctype = "markdown",
				title = wanted.title,
				body = wanted.block,
				bookId = ctx.config.book,
				tags = { tag._id },
				status = "active",
				createdAt = time,
				updatedAt = time,
			})
			counts.created = counts.created + 1
		end
	end
	return string.format(
		"lessons: %d created, %d updated, %d dropped, %d unchanged\n",
		counts.created,
		counts.updated,
		counts.dropped,
		counts.unchanged
	)
end

---Execute Inkdrop commands; all errors are returned as one safe diagnostic.
---@param rt table
---@param argv string[]
---@return table
function M.run(rt, argv)
	local sub, rest = argv[1], vim.list_slice(argv, 2)
	local function dispatch()
		if sub == "init" then
			local flags, positions = require("orc.args").parse(
				rest,
				{ book = "string", parent = "string", create = "boolean", move = "boolean" }
			)
			if #positions == 0 then
				return init(rt, flags)
			end
		elseif sub == "inbox" and (#rest == 0 or (#rest == 1 and rest[1] == "--json")) then
			return inbox(rt, #rest == 1)
		elseif sub == "claim" and #rest == 2 then
			return claim(rt, rest[1], rest[2])
		elseif sub == "push" then
			local flags, positions = require("orc.args").parse(rest, { done = "boolean" })
			if #positions == 1 then
				return push_feature(rt, rt.cwd, positions[1], flags.done)
			end
		elseif sub == "pull" and #rest == 1 then
			return pull(rt, rest[1])
		elseif sub == "lessons" and #rest == 0 then
			return lessons(rt)
		end
		error(USAGE, 0)
	end
	return attempt(dispatch)
end

return M
