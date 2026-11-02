local M = {}

---Parse flat agent frontmatter and its instruction body.
---@param text string
---@return table metadata
---@return string body
function M.parse(text)
	local header, body = text:gsub("\r\n", "\n"):match("^%-%-%-\n(.-)\n%-%-%-\n(.*)$")
	assert(header, "agent is missing frontmatter")
	local data = {}
	for key, value in header:gmatch("([%w_-]+):[ \t]*([^\n]*)") do
		value = vim.trim(value)
		local quote = value:sub(1, 1)
		if (quote == '"' or quote == "'") and value:sub(-1) == quote then
			value = value:sub(2, -2)
		end
		data[key] = value
	end
	assert(data.name and data.name ~= "", "agent is missing name")
	assert(data.description and data.description ~= "", "agent is missing description")
	return data, vim.trim(body)
end

---Generate Codex TOML from one canonical agent; model choice remains inherited.
---@param text string
---@param name string Source filename used in the generated header.
---@return string
function M.render(text, name)
	local data, body = M.parse(text)
	local lines = {
		"# GENERATED from agents/" .. name .. "; run scripts/gen-agents.lua.",
		"name = " .. vim.json.encode(data.name),
		"description = " .. vim.json.encode(data.description),
	}
	if data.effort then
		lines[#lines + 1] = "model_reasoning_effort = "
			.. vim.json.encode(data.effort == "max" and "xhigh" or data.effort)
	end
	local sandbox = data["codex-sandbox"]
	if sandbox then
		assert(
			sandbox == "inherit" or sandbox == "read-only" or sandbox == "workspace-write",
			"invalid codex-sandbox"
		)
	elseif
		not (data.tools or "Write"):match("Write") and not (data.tools or "Write"):match("Edit")
	then
		sandbox = "read-only"
	end
	if sandbox and sandbox ~= "inherit" then
		lines[#lines + 1] = "sandbox_mode = " .. vim.json.encode(sandbox)
	end
	lines[#lines + 1] = "developer_instructions = " .. vim.json.encode(body)
	return table.concat(lines, "\n") .. "\n"
end

---Regenerate agent files, or fail on drift without changing files when check is true.
---@param rt orc.Runtime
---@param check? boolean
---@return table
function M.generate(rt, check)
	local expected, issues = {}, {}
	for _, name in ipairs(rt.list(rt.path(rt.root, "agents"))) do
		if name:match("%.md$") then
			local target = name:gsub("%.md$", ".toml")
			local rendered = M.render(assert(rt.read(rt.path(rt.root, "agents", name))), name)
			expected[target] = true
			local path = rt.path(rt.root, "codex", "agents", target)
			if rt.read(path) ~= rendered then
				issues[#issues + 1] = "differs: codex/agents/" .. target
				if not check then
					rt.write(path, rendered)
				end
			end
		end
	end
	for _, name in ipairs(rt.list(rt.path(rt.root, "codex", "agents"))) do
		if name:match("%.toml$") and not expected[name] then
			issues[#issues + 1] = "extra: codex/agents/" .. name
			if not check then
				rt.remove(rt.path(rt.root, "codex", "agents", name))
			end
		end
	end
	return {
		code = check and #issues > 0 and 1 or 0,
		out = #issues > 0 and table.concat(issues, "\n") .. "\n" or "agents are current\n",
	}
end

return M
