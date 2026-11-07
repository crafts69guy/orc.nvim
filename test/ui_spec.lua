local ui = require("orc.ui")

local function fixture(exercise)
	local rt = require("orc.runtime").new({ cwd = assert(vim.uv.fs_realpath(Test.temp())) })
	rt.write(rt.cwd .. "/brief.md", "fixture brief")
	rt.write(rt.cwd .. "/report.md", "fixture report")
	local worker = {
		runId = "run",
		feature = "feature",
		task = "task",
		path = rt.cwd,
		state = "idle",
		brief = rt.cwd .. "/brief.md",
		report = rt.cwd .. "/report.md",
		acknowledged = true,
		sessionId = "session:test",
		blockId = "block:test",
		hostId = "host",
		instanceId = "instance",
	}
	local document = {
		schemaVersion = 1,
		root = rt.cwd,
		features = {
			{
				feature = "feature",
				plan = rt.cwd .. "/brief.md",
				tasks = {
					{ id = "task", worktree = rt.null, merged = rt.null, agent = rt.null, report = rt.null },
				},
			},
		},
		workers = { worker },
	}
	local state =
		{ calls = {}, callbacks = {}, stopped = 0, notices = {}, document = document, worker = worker }
	rt.async = function(argv, options, callback)
		state.calls[#state.calls + 1] = { argv = argv, options = options }
		state.callbacks[#state.calls] = callback
		return {
			stop = function()
				state.stopped = state.stopped + 1
			end,
		}
	end
	rt.exec = function()
		error("panel action blocked on synchronous command")
	end
	function state.reply(index, code, out, err)
		local default = vim.tbl_contains(state.calls[index].argv, "whoami")
				and { host_id = "host", instance_id = "instance", endpoint = "unix:///fixture" }
			or document
		state.callbacks[index]({
			code = code or 0,
			stdout = out or rt.encode(default),
			stderr = err or "",
		})
	end
	local old_notify, old_input = vim.notify, vim.ui.input
	vim.notify = function(message)
		state.notices[#state.notices + 1] = message
	end
	vim.ui.input = function(_, callback)
		state.input = callback
	end
	local previous_windows = {}
	for _, window in ipairs(vim.api.nvim_list_wins()) do
		previous_windows[window] = true
	end
	local ok, err = xpcall(function()
		exercise(rt, state, document)
	end, debug.traceback)
	ui.close()
	for _, window in ipairs(vim.api.nvim_list_wins()) do
		if not previous_windows[window] then
			pcall(vim.api.nvim_win_close, window, true)
		end
	end
	vim.notify, vim.ui.input = old_notify, old_input
	assert(ok, err)
end

Test.test(
	"ui render normalizes null paths and includes pair workers without duplicate tasks",
	function()
		fixture(function(rt, state, document)
			local lines, rows = ui.render(document)
			Test.eq(#lines, 4)
			Test.eq(rows[4].path, rt.cwd)
			Test.eq(rows[4].worker, state.worker)
			document.features = {}
			Test.eq(#ui.render(document), 4)
			document.workers = {}
			Test.eq(ui.render(document)[4], "No feature tasks or pair workers.")
			Test.raises("schema", function()
				ui.render({ schemaVersion = 2 })
			end)
		end)
	end
)

Test.test("ui render preserves merged agent report pending and previous-report states", function()
	local document = {
		schemaVersion = 1,
		root = "/repo",
		features = {
			{
				feature = "f",
				plan = "/plan",
				tasks = {
					{ id = "merged", merged = { commit = "abc" } },
					{ id = "agent", agent = { state = "working" } },
					{ id = "report", report = { status = "partial" }, worktree = "/r" },
					{ id = "pending" },
				},
			},
		},
		workers = {
			{
				feature = "pair",
				task = "p",
				path = "/r",
				state = "unconfirmed",
				runId = "r",
				previousReport = "/old",
				report = "/new",
				acknowledged = false,
			},
		},
	}
	local lines, rows = ui.render(document)
	assert(lines[4]:find("merged", 1, true))
	assert(lines[5]:find("working", 1, true))
	assert(lines[6]:find("partial", 1, true))
	assert(lines[7]:find("pending", 1, true))
	Test.eq(rows[8].report, "/old")
	Test.eq(rows[6].report, "/r/.orc/report.md")
end)

Test.test("ui opens one read-only panel and coalesces asynchronous refresh", function()
	fixture(function(rt, state)
		local buffer = ui.open(rt)
		Test.eq(ui.open(rt), buffer)
		Test.eq(#state.calls, 1)
		ui.refresh()
		Test.eq(#state.calls, 1)
		state.reply(1)
		Test.eq(vim.bo[buffer].modifiable, false)
		Test.eq(vim.bo[buffer].buftype, "nofile")
		Test.eq(
			vim.api.nvim_buf_get_lines(buffer, 3, 4, false)[1]:find("feature/task", 1, true) ~= nil,
			true
		)
		ui.action("status")
		Test.eq(#state.calls, 2)
		state.reply(2, 1, "", "offline")
		assert(state.notices[#state.notices]:find("offline", 1, true))
		ui.refresh()
		state.reply(3, 0, "invalid JSON")
		assert(#state.notices >= 2)
		ui.close()
		assert(not vim.api.nvim_buf_is_valid(buffer))
		assert(state.stopped >= 1)
		ui.close()
		ui.refresh()
	end)
end)

Test.test(
	"ui brief report diff focus and prompt actions use selected task and async subprocesses",
	function()
		fixture(function(rt, state)
			local buffer = ui.open(rt)
			state.reply(1)
			vim.api.nvim_win_set_cursor(0, { 4, 0 })
			ui.action("brief")
			Test.eq(vim.api.nvim_buf_get_name(0), rt.cwd .. "/brief.md")
			ui.action("report")
			Test.eq(vim.api.nvim_buf_get_name(0), rt.cwd .. "/report.md")
			ui.action("diff")
			Test.eq(state.calls[2].argv, { "git", "-C", rt.cwd, "--no-pager", "diff" })
			state.reply(2, 0, "diff --git a/x b/x\n+fixed\n")
			Test.eq(vim.bo.filetype, "diff")
			ui.action("focus")
			state.reply(3)
			state.reply(4)
			assert(table.concat(state.calls[5].argv, " "):find("session.focus_block", 1, true))
			Test.eq(rt.decode(state.calls[5].options.stdin).block_id, "block:test")
			state.reply(5)
			ui.action("prompt")
			state.input("fix the regression")
			Test.eq(state.calls[6].argv, {
				rt.root .. "/bin/orc",
				"pane",
				"prompt",
				"task",
				"--path",
				rt.cwd,
				"--text",
				"fix the regression",
			})
			state.reply(6)
			Test.eq(state.calls[7].argv[2], "status")
			state.reply(7)
			assert(vim.api.nvim_buf_is_valid(buffer))
		end)
	end
)

Test.test("ui reports action failures and ignores cancelled input", function()
	fixture(function(rt, state)
		ui.open(rt)
		state.reply(1)
		vim.api.nvim_win_set_cursor(0, { 4, 0 })
		ui.action("diff")
		state.reply(2, 1, "", "bad diff")
		ui.action("focus")
		state.reply(3, 1, "", "bad focus")
		ui.action("prompt")
		state.input(nil)
		state.input("  ")
		Test.eq(#state.calls, 3)
		state.input("change")
		state.reply(4, 1, "rejected", "")
		state.reply(5)
		assert(table.concat(state.notices, " "):find("rejected", 1, true))
		ui.action("unknown")
		assert(state.notices[#state.notices]:find("unknown", 1, true))
		vim.api.nvim_win_set_cursor(0, { 1, 0 })
		ui.action("report")
		assert(state.notices[#state.notices]:find("select a task", 1, true))
	end)
end)

Test.test(
	"ui closing cancels owned jobs and pending callbacks never reopen windows or send prompts",
	function()
		fixture(function(rt, state)
			local buffer = ui.open(rt)
			state.reply(1)
			vim.api.nvim_win_set_cursor(0, { 4, 0 })
			ui.action("diff")
			ui.action("focus")
			ui.action("prompt")
			ui.close()
			local windows, calls = #vim.api.nvim_list_wins(), #state.calls
			state.reply(2, 0, "late diff")
			state.reply(3, 1, "", "late focus")
			state.input("late prompt")
			Test.eq(#vim.api.nvim_list_wins(), windows)
			Test.eq(#state.calls, calls)
			Test.eq(state.stopped, 3)
			assert(not vim.api.nvim_buf_is_valid(buffer))
			local next_buffer = ui.open(rt)
			ui.close()
			state.reply(4)
			assert(not vim.api.nvim_buf_is_valid(next_buffer))
		end)
	end
)

Test.test("ui hidden buffer stops watchers and missing row resources are diagnosed", function()
	fixture(function(rt, state, document)
		document.workers = {}
		local buffer = ui.open(rt)
		state.reply(1)
		vim.api.nvim_win_set_cursor(0, { 4, 0 })
		ui.action("diff")
		ui.action("focus")
		ui.action("report")
		ui.action("prompt")
		assert(#state.notices >= 4)
		vim.api.nvim_exec_autocmds("BufHidden", { buffer = buffer })
		assert(state.stopped > 0)
		vim.api.nvim_buf_delete(buffer, { force = true })
	end)
end)

Test.test("ui missing optional worker arrays and closed actions remain safe", function()
	local lines = ui.render({ schemaVersion = 1, root = "/repo" })
	Test.eq(lines[4], "No feature tasks or pair workers.")
	fixture(function(rt, state)
		ui.action("report")
		assert(state.notices[#state.notices]:find("open the task panel", 1, true))
		local buffer = ui.open(rt)
		state.reply(1, 1, "status failed", "")
		ui.action("refresh")
		state.reply(2)
		vim.api.nvim_win_set_cursor(0, { 4, 0 })
		for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buffer, "n")) do
			if mapping.lhs == "r" then
				mapping.callback()
			end
		end
		state.reply(3)
		ui.action("prompt")
		state.input("accepted")
		ui.close()
		local windows = #vim.api.nvim_list_wins()
		state.reply(4)
		Test.eq(#vim.api.nvim_list_wins(), windows)
	end)
end)

Test.test("ui actual buffer wipe stops watchers without recursively deleting the buffer", function()
	fixture(function(rt, state)
		local buffer = ui.open(rt)
		state.reply(1)
		vim.api.nvim_buf_delete(buffer, { force = true })
		assert(not vim.api.nvim_buf_is_valid(buffer))
		assert(state.stopped > 0)
	end)
end)

Test.test("ui failed refresh launch can be closed and prompt stderr is shown", function()
	fixture(function(rt, state)
		local async = rt.async
		rt.async = function()
			error("spawn failed")
		end
		Test.raises("spawn failed", function()
			ui.open(rt)
		end)
		ui.close()
		rt.async = async
		ui.open(rt)
		state.reply(1)
		vim.api.nvim_win_set_cursor(0, { 4, 0 })
		ui.action("prompt")
		state.input("again")
		state.reply(2, 1, "", "prompt offline")
		assert(state.notices[#state.notices]:find("prompt offline", 1, true))
	end)
end)

Test.test("ui setup and plugin register only Orc and are idempotent", function()
	local actual_ui, actual_runtime, actual_projects, actual_workers =
		package.loaded["orc.ui"],
		package.loaded["orc.runtime"],
		package.loaded["orc.projects"],
		package.loaded["orc.worker_picker"]
	local opened, actions, projects, workers = 0, {}, {}, {}
	package.loaded["orc.ui"] = {
		open = function()
			opened = opened + 1
		end,
		action = function(value)
			actions[#actions + 1] = value
		end,
	}
	package.loaded["orc.runtime"] = {
		new = function(opts)
			return opts
		end,
	}
	package.loaded["orc.projects"] = {
		open = function(_, opts)
			projects[#projects + 1] = opts or {}
			return "handle"
		end,
	}
	package.loaded["orc.worker_picker"] = {
		open = function(rt, opts)
			Test.eq(rt.cwd, opts.cwd)
			workers[#workers + 1] = opts
			return "worker handle"
		end,
	}
	local ok, err = xpcall(function()
		local module = require("orc")
		module.setup({ cwd = "/fixture" })
		module.setup()
		vim.cmd("Orc")
		vim.cmd("Orc status")
		Test.eq(opened, 2)
		Test.eq(actions, { "status" })
		module.open()
		Test.eq(opened, 3)
		module.open({ cwd = Test.temp() })
		Test.eq(opened, 4)
		for _, cwd in ipairs({ "relative", "/missing-orc-cwd", true }) do
			Test.raises("existing absolute", function()
				module.open({ cwd = cwd })
			end)
			Test.raises("existing absolute", function()
				module.workers({ cwd = cwd })
			end)
		end
		Test.eq(module.projects({ client_id = "origin" }), "handle")
		vim.cmd("Orc projects")
		Test.eq(projects, { { client_id = "origin" }, {} })
		local cwd = Test.temp()
		local context = { cwd = cwd, client_id = "origin", quit_on_close = true }
		Test.eq(module.workers(context), "worker handle")
		Test.eq(module.workers(), "worker handle")
		module.setup({ cwd = cwd })
		vim.cmd("Orc workers")
		Test.eq(workers, { context, {}, { cwd = cwd } })
		Test.eq(opened, 4)
		Test.eq(actions, { "status" })
		assert(vim.tbl_contains(vim.fn.getcompletion("Orc ", "cmdline"), "report"))
		assert(vim.tbl_contains(vim.fn.getcompletion("Orc ", "cmdline"), "workers"))
		vim.g.loaded_orc = nil
		dofile(actual_runtime.new().root .. "/plugin/orc.lua")
		dofile(actual_runtime.new().root .. "/plugin/orc.lua")
		Test.eq(vim.g.loaded_orc, true)
	end, debug.traceback)
	package.loaded["orc.ui"], package.loaded["orc.runtime"] = actual_ui, actual_runtime
	package.loaded["orc.projects"] = actual_projects
	package.loaded["orc.worker_picker"] = actual_workers
	vim.g.loaded_orc = nil
	pcall(vim.api.nvim_del_user_command, "Orc")
	assert(ok, err)
end)

Test.test("ui popup closes only its view and focuses the explicitly originating Rex app", function()
	fixture(function(rt, state)
		local old_cmd, old_schedule = vim.cmd, vim.schedule
		local quit, scheduled = 0, {}
		vim.cmd = function(command)
			if command == "qa" then
				quit = quit + 1
			else
				old_cmd(command)
			end
		end
		vim.schedule = function(fn)
			scheduled[#scheduled + 1] = fn
		end
		local ok, err = xpcall(function()
			ui.open(rt, { client_id = "client:origin", quit_on_close = true })
			state.reply(1)
			vim.api.nvim_win_set_cursor(0, { 4, 0 })
			ui.action("focus")
			state.reply(2)
			state.reply(3)
			state.reply(4, 0, "{}")
			assert(vim.tbl_contains(state.calls[5].argv, "client:origin"))
			state.reply(5, 1, "", "Remote Control disabled")
			assert(state.notices[1]:find("Remote Control disabled", 1, true))
			ui.close()
			ui.close()
			for _, callback in ipairs(scheduled) do
				callback()
			end
			Test.eq(quit, 1)
		end, debug.traceback)
		vim.cmd, vim.schedule = old_cmd, old_schedule
		assert(ok, err)
	end)
end)

Test.test("ui popup preserves modified buffers when non-forced quit is refused", function()
	fixture(function(rt, state)
		local old_cmd, old_schedule = vim.cmd, vim.schedule
		vim.cmd = function(command)
			if command == "qa" then
				error("modified buffers")
			else
				old_cmd(command)
			end
		end
		vim.schedule = function(fn)
			fn()
		end
		local ok, err = xpcall(function()
			ui.open(rt, { quit_on_close = true })
			ui.close()
			assert(state.notices[1]:find("save modified buffers", 1, true))
		end, debug.traceback)
		vim.cmd, vim.schedule = old_cmd, old_schedule
		assert(ok, err)
	end)
end)

Test.test("ui health checks dependencies local Rex and failures without model calls", function()
	local old_health, old_rex, old_has, old_executable =
		vim.health, package.loaded["orc.rex"], vim.fn.has, vim.fn.executable
	local calls, success = {}, true
	vim.health = {}
	for _, kind in ipairs({ "start", "ok", "warn", "error", "info" }) do
		vim.health[kind] = function(message)
			calls[#calls + 1] = kind .. ":" .. message
		end
	end
	vim.fn.has = function()
		return success and 1 or 0
	end
	vim.fn.executable = function()
		return success and 1 or 0
	end
	package.loaded["orc.rex"] = {
		new = function()
			return {
				identity = function()
					assert(success, "offline")
					return { instance_id = "fixture" }
				end,
			}
		end,
	}
	local ok, err = xpcall(function()
		require("orc.health").check()
		success = false
		require("orc.health").check()
		assert(table.concat(calls, " "):find("offline", 1, true))
		assert(table.concat(calls, " "):find("git missing", 1, true))
	end, debug.traceback)
	vim.health, package.loaded["orc.rex"], vim.fn.has, vim.fn.executable =
		old_health, old_rex, old_has, old_executable
	assert(ok, err)
end)
