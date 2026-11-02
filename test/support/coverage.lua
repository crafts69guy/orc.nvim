---Source-based coverage for Lua statements, decisions and function entries.
---Only test copies are instrumented. The production loader and sources are restored on stop.
local M = {}
local registry = "__ORC_COVERAGE"

---@class OrcCoverageMetric
---@field hit integer Executed sites (branch outcomes count separately).
---@field total integer Statically discovered sites, including unloaded files.
---@field percent number Coverage percentage, or 100 when no such sites exist.
---@class OrcCoverageSite
---@field line integer Original, one-based source line.
---@field kind string Source construct that owns the site.
---@class OrcCoverageManifest
---@field path string Source identity used by counters and reports.
---@field lines table<integer, boolean> Executable statement/decision lines.
---@field functions OrcCoverageSite[] Explicit function declarations and expressions.
---@field branches OrcCoverageSite[] Decisions with two independently measured outcomes.

local function read(path)
	local file = assert(io.open(path, "rb"))
	local source = file:read("*a")
	file:close()
	return source
end

local function offset(node, ending)
	local sr, sc, er, ec = node:range()
	return ending and er or sr, ending and ec or sc
end

local function operator(node)
	for child in node:iter_children() do
		if not child:named() then
			local kind = child:type()
			if kind == "and" or kind == "or" then
				return kind
			end
		end
	end
end

local function after_token(node, token, byte)
	for child in node:iter_children() do
		if child:type() == token then
			return byte(child, true)
		end
	end
	error("coverage: missing " .. token .. " in " .. node:type(), 0)
end

---Instrument valid Lua 5.1 without executing it.
---A line site is the first source line of a statement or evaluated decision, not
---a comment, structural `end`, or continuation-only expression line. Branches are
---condition truthy/falsy outcomes, short-circuit evaluation/skip, and native loop
---continuation/normal termination. Break and return do not count as termination.
---@param source string
---@param path string
---@return string instrumented
---@return OrcCoverageManifest manifest
function M.instrument(source, path)
	assert(type(source) == "string" and type(path) == "string", "coverage: source and path required")
	if source:match("^#!") and not source:find("\n", 1, true) then
		source = source .. "\n"
	end
	local original, syntax = loadstring(source:gsub("^#![^\n]*", ""), "@" .. path)
	assert(original, "coverage: unsupported Lua syntax: " .. tostring(syntax))
	local parser = vim.treesitter.get_string_parser(source, "lua")
	local root = parser:parse()[1]:root()
	assert(not root:has_error(), "coverage: Lua parser rejected " .. path)
	local manifest = { path = path, lines = {}, functions = {}, branches = {} }
	local starts = { 0 }
	for i = 1, #source do
		if source:sub(i, i) == "\n" then
			starts[#starts + 1] = i
		end
	end
	local function byte(node, ending)
		local row, col = offset(node, ending)
		return starts[row + 1] + col
	end
	local symbol = "__orc_cov_" .. vim.fn.sha256(path .. source):sub(1, 12)
	while source:find(symbol, 1, true) do
		symbol = symbol .. "_"
	end
	local identity = string.format("%q", path)
	local edits, serial = {}, 0
	local function insert(at, text, rank, span)
		serial = serial + 1
		edits[#edits + 1] = { at = at, text = " " .. text .. " ", rank = rank, span = span or 0, serial = serial }
	end
	local function site(list, node, kind)
		local line = node:start() + 1
		local id = #list + 1
		list[id] = { line = line, kind = kind }
		return id
	end
	local function line_probe(node)
		local line = node:start() + 1
		manifest.lines[line] = true
		insert(byte(node), symbol .. ".line(" .. identity .. "," .. line .. ");", 3)
	end
	local function condition(node, kind)
		local line = node:start() + 1
		manifest.lines[line] = true
		local id = site(manifest.branches, node, kind)
		local first, last = byte(node), byte(node, true)
		insert(first, symbol .. ".decision(" .. identity .. "," .. id .. ",(", 4, -(last - first))
		insert(last, "))", 0, last - first)
	end
	local function body_entry(node, text)
		local body = node:field("body")[1]
		if body then
			insert(byte(body), text, 1)
		else
			local last_end
			for child in node:iter_children() do
				if child:type() == "end" then
					last_end = byte(child)
				end
			end
			assert(last_end, "coverage: function has no body or end")
			insert(last_end, text, 1)
		end
	end
	local function visit(node, loop_flag)
		local kind = node:type()
		local child_loop = loop_flag
		assert(kind ~= "goto_statement" and kind ~= "label_statement", "coverage: goto is not Lua 5.1")
		if kind == "chunk" or kind == "block" then
			for child in node:iter_children() do
				if
					child:named()
					and child:type() ~= "comment"
					and child:type() ~= "hash_bang_line"
					and child:type() ~= "empty_statement"
				then
					line_probe(child)
				end
			end
		end
		if kind == "function_declaration" or kind == "function_definition" then
			child_loop = nil
			local id = site(manifest.functions, node, "function")
			body_entry(node, symbol .. ".enter(" .. identity .. "," .. id .. ");")
		elseif
			kind == "if_statement"
			or kind == "elseif_statement"
			or kind == "while_statement"
			or kind == "repeat_statement"
		then
			if kind == "while_statement" or kind == "repeat_statement" then
				child_loop = nil
			end
			local expr = assert(node:field("condition")[1], "coverage: missing condition")
			condition(expr, kind)
		elseif kind == "binary_expression" and operator(node) then
			condition(assert(node:field("left")[1]), operator(node))
		elseif kind == "for_statement" then
			local id = site(manifest.branches, node, "for-loop")
			local flag = symbol .. "_loop" .. id
			child_loop = flag
			local first, last = byte(node), byte(node, true)
			insert(first, "do local " .. flag .. "=false;", 2, -(last - first))
			insert(after_token(node, "do", byte), symbol .. ".branch(" .. identity .. "," .. id .. ",true);", 1)
			insert(
				last,
				";if not " .. flag .. " then " .. symbol .. ".branch(" .. identity .. "," .. id .. ",false) end end;",
				0,
				last - first
			)
		elseif kind == "break_statement" and loop_flag then
			insert(byte(node), loop_flag .. "=true;", 1)
		end
		for child in node:iter_children() do
			if child:named() and child:type() ~= "comment" then
				visit(child, child_loop)
			end
		end
	end
	visit(root)
	local first = source:match("^#![^\n]*\n()")
	insert(
		first and first - 1 or 0,
		"local " .. symbol .. "=assert(_G." .. registry .. ',"coverage collector missing");',
		1
	)
	table.sort(edits, function(a, b)
		if a.at ~= b.at then
			return a.at < b.at
		elseif a.rank ~= b.rank then
			return a.rank < b.rank
		elseif a.span ~= b.span then
			return a.span < b.span
		end
		return a.rank == 0 and a.serial > b.serial or a.rank ~= 0 and a.serial < b.serial
	end)
	local out, previous = {}, 0
	for _, edit in ipairs(edits) do
		out[#out + 1] = source:sub(previous + 1, edit.at)
		out[#out + 1] = edit.text
		previous = edit.at
	end
	out[#out + 1] = source:sub(previous + 1)
	local instrumented = table.concat(out)
	local compiled, err = loadstring(instrumented:gsub("^#![^\n]*", ""), "@" .. path)
	assert(compiled, "coverage: invalid instrumentation for " .. path .. ": " .. tostring(err))
	return instrumented, manifest
end

local function metric(hit, total)
	return { hit = hit, total = total, percent = total == 0 and 100 or hit * 100 / total }
end

---Create a collector for statically enumerated manifests. Install before loading test copies.
---@param manifests OrcCoverageManifest[]
---@return table collector Counter methods plus activate, report, check and stop.
function M.collector(manifests)
	assert(#manifests > 0, "coverage: no source manifests")
	local files = {}
	for _, manifest in ipairs(manifests) do
		assert(not files[manifest.path], "coverage: duplicate source identity")
		files[manifest.path] = { manifest = manifest, lines = {}, branches = {}, functions = {} }
	end
	local collector, previous, installed = {}, nil, false
	function collector.line(path, line)
		assert(files[path] and files[path].manifest.lines[line], "coverage: unknown line site")
		files[path].lines[line] = true
	end
	function collector.branch(path, id, value)
		local file = assert(files[path], "coverage: unknown source")
		assert(file.manifest.branches[id], "coverage: unknown branch site")
		file.branches[id] = file.branches[id] or {}
		file.branches[id][not not value] = true
	end
	function collector.decision(path, id, value)
		collector.branch(path, id, value)
		collector.line(path, files[path].manifest.branches[id].line)
		return value
	end
	function collector.enter(path, id)
		assert(files[path] and files[path].manifest.functions[id], "coverage: unknown function site")
		files[path].functions[id] = true
	end
	function collector.activate()
		assert(not installed, "coverage: collector already active")
		previous = rawget(_G, registry)
		rawset(_G, registry, collector)
		installed = true
	end
	function collector.stop()
		if installed then
			assert(rawget(_G, registry) == collector, "coverage: collectors must stop in reverse order")
			rawset(_G, registry, previous)
			installed = false
		end
	end
	function collector.report()
		local totals = { lines = { 0, 0 }, branches = { 0, 0 }, functions = { 0, 0 } }
		local report = { files = {} }
		for path, file in pairs(files) do
			local counts = { lines = { 0, 0 }, branches = { 0, 0 }, functions = { 0, 0 } }
			local missing = { lines = {}, branches = {}, functions = {} }
			for line in pairs(file.manifest.lines) do
				counts.lines[2] = counts.lines[2] + 1
				if file.lines[line] then
					counts.lines[1] = counts.lines[1] + 1
				else
					missing.lines[#missing.lines + 1] = line
				end
			end
			table.sort(missing.lines)
			for id, branch in ipairs(file.manifest.branches) do
				counts.branches[2] = counts.branches[2] + 2
				for _, outcome in ipairs({ false, true }) do
					if file.branches[id] and file.branches[id][outcome] then
						counts.branches[1] = counts.branches[1] + 1
					else
						missing.branches[#missing.branches + 1] =
							{ id = id, line = branch.line, kind = branch.kind, outcome = outcome }
					end
				end
			end
			for id, func in ipairs(file.manifest.functions) do
				counts.functions[2] = counts.functions[2] + 1
				if file.functions[id] then
					counts.functions[1] = counts.functions[1] + 1
				else
					missing.functions[#missing.functions + 1] = { id = id, line = func.line }
				end
			end
			local result = { missing = missing }
			for name, values in pairs(counts) do
				result[name] = metric(values[1], values[2])
				totals[name][1], totals[name][2] = totals[name][1] + values[1], totals[name][2] + values[2]
			end
			report.files[path] = result
		end
		for name, values in pairs(totals) do
			report[name] = metric(values[1], values[2])
		end
		return report
	end
	function collector.check(threshold)
		threshold = threshold or 98
		assert(type(threshold) == "number" and threshold >= 0 and threshold <= 100, "coverage: invalid threshold")
		local report, errors = collector.report(), {}
		for _, name in ipairs({ "lines", "branches", "functions" }) do
			local value = report[name]
			if value.percent < threshold then
				errors[#errors + 1] =
					string.format("%s %.2f%% < %.2f%% (%d/%d)", name, value.percent, threshold, value.hit, value.total)
			end
		end
		return #errors == 0, table.concat(errors, "; "), report
	end
	return collector
end

local function sources(root)
	local found = {}
	local ignored = {
		[".git"] = true,
		[".scratch"] = true,
		[".worktrees"] = true,
		[".orc"] = true,
		[".eval-plugin"] = true,
		coverage = true,
	}
	local function walk(dir)
		for name, kind in vim.fs.dir(dir) do
			if not ignored[name] and not (dir == root and name == "test") then
				local path = vim.fs.joinpath(dir, name)
				if kind == "directory" then
					walk(path)
				elseif kind == "file" and (name:match("%.lua$") or path == vim.fs.joinpath(root, "bin", "orc")) then
					found[#found + 1] = path
				end
			end
		end
	end
	walk(root)
	table.sort(found)
	return found
end

---Instrument all production sources before execution and replace file/module loaders.
---Paths default to every owned Lua file outside test/ and hidden/build directories,
---plus bin/orc. An explicit path list is useful only for isolated instrumenter tests.
---@param root string
---@param paths? string[]
---@return table session Collector with load(path), report(), check(98), stop().
function M.start(root, paths)
	root = vim.fs.normalize(vim.fn.fnamemodify(root, ":p")):gsub("/$", "")
	paths = paths or sources(root)
	assert(#paths > 0, "coverage: no production sources found")
	local transformed, manifests, modules = {}, {}, {}
	for _, path in ipairs(paths) do
		path = vim.fs.normalize(path:sub(1, 1) == "/" and path or vim.fs.joinpath(root, path))
		local instrumented, manifest = M.instrument(read(path), path)
		transformed[path] = instrumented
		manifests[#manifests + 1] = manifest
		local relative = path:sub(#root + 2):match("^lua/(.+)%.lua$")
		if relative then
			local name = relative:gsub("/init$", ""):gsub("/", ".")
			modules[name] = package.loaded[name]
			if modules[name] == nil then
				modules[name] = false
			end
		end
	end
	local session = M.collector(manifests)
	for name in pairs(modules) do
		package.loaded[name] = nil
	end
	local old_loadfile, old_dofile = _G.loadfile, _G.dofile
	local loaders = package.loaders or package.searchers
	local old_loader = loaders[2]
	local function load(path)
		local absolute = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
		if transformed[absolute] then
			return loadstring(transformed[absolute]:gsub("^#![^\n]*", ""), "@" .. absolute)
		end
		return old_loadfile(path)
	end
	function session.load(path)
		local absolute = vim.fs.normalize(path:sub(1, 1) == "/" and path or vim.fs.joinpath(root, path))
		assert(transformed[absolute], "coverage: source not enumerated: " .. path)
		return assert(load(absolute))
	end
	_G.loadfile = load
	_G.dofile = function(path)
		return assert(load(path))()
	end
	loaders[2] = function(name)
		local module = name:gsub("%.", "/")
		for template in package.path:gmatch("[^;]+") do
			local path = vim.fs.normalize(vim.fn.fnamemodify(template:gsub("%?", module), ":p"))
			if transformed[path] then
				return assert(load(path))
			end
		end
		return old_loader(name)
	end
	local stop, stopped = session.stop, false
	function session.stop()
		if stopped then
			return
		end
		stop()
		_G.loadfile, _G.dofile, loaders[2] = old_loadfile, old_dofile, old_loader
		for name, value in pairs(modules) do
			package.loaded[name] = value or nil
		end
		stopped = true
	end
	session.activate()
	return session
end

return M
