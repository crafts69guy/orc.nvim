local grid = require("orc.rex_grid")

local function view(name)
	local root = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
	local path = root .. "/fixtures/rex-grid/view-" .. name .. ".json"
	return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
end

local function detach(node, block)
	if node.block_id then
		if node.block_id ~= block then
			return node
		end
	else
		local split = node.split
		split.before = detach(split.before, block)
		split.after = detach(split.after, block)
		if split.before and split.after then
			return node
		end
		return split.before or split.after
	end
end

local function insert(node, args)
	if node.block_id == args.anchor_block_id then
		return {
			split = {
				direction = args.direction,
				ratio = args.ratio,
				before = node,
				after = { block_id = args.block_id },
			},
		}
	end
	if node.split then
		node.split.before = insert(node.split.before, args)
		node.split.after = insert(node.split.after, args)
	end
	return node
end

local function rects(node, out, rect)
	if node.block_id then
		out[#out + 1] = { id = node.block_id, rect = rect or node.rect }
		return
	end
	local split = node.split
	if not rect then
		rects(split.before, out)
		rects(split.after, out)
		return
	end
	local before, after = vim.deepcopy(rect), vim.deepcopy(rect)
	local axis = split.direction == "horizontal" and 1 or 2
	before[axis + 2] = rect[axis + 2] * split.ratio
	after[axis] = after[axis] + before[axis + 2]
	after[axis + 2] = after[axis + 2] - before[axis + 2]
	rects(split.before, out, before)
	rects(split.after, out, after)
end

Test.test("Rex grid shapes from one to ten cells", function()
	for count, expected in ipairs({
		{ 1, 1 },
		{ 2, 1 },
		{ 2, 2 },
		{ 2, 2 },
		{ 3, 2 },
		{ 3, 2 },
		{ 3, 3 },
		{ 3, 3 },
		{ 3, 3 },
		{ 4, 3 },
	}) do
		Test.eq({ grid.shape(count) }, expected)
		local layer = { blocks = {} }
		for index = count, 1, -1 do
			local id = "block:" .. index
			local leaf = { block_id = id, rect = { (index - 1) / count, 0, 1 / count, 1 } }
			layer.blocks[index] =
				{ block_id = id, label = string.format("orc:%024x:task-%d", index, index) }
			local remaining = count - index + 1
			layer.layout = layer.layout
					and {
						rect = { (index - 1) / count, 0, remaining / count, 1 },
						split = {
							direction = "horizontal",
							ratio = 1 / remaining,
							before = leaf,
							after = layer.layout,
						},
					}
				or leaf
		end
		for _, call in ipairs(assert(grid.plan(layer, "block:1"))) do
			Test.eq(call.method, "session.move_block")
			layer.layout = insert(assert(detach(layer.layout, call.arguments.block_id)), call.arguments)
		end
		local actual = {}
		rects(layer.layout, actual, { 0, 0, 1, 1 })
		local cols, rows = unpack(expected)
		for index, cell in ipairs(actual) do
			Test.eq(cell.id, "block:" .. index)
			local col, row = math.floor((index - 1) / rows), (index - 1) % rows
			local height = 1 / math.min(rows, count - col * rows)
			for axis, value in ipairs({ col / cols, row * height, 1 / cols, height }) do
				assert(math.abs(cell.rect[axis] - value) <= 0.01)
			end
		end
	end
end)

Test.test(
	"Rex grid rearranges the captured six columns into the captured equal geometry",
	function()
		local before = assert(grid.find_layer(view("before-columns"), "block:main"))
		local after = assert(grid.find_layer(view("after-grid"), "block:main"))
		local plan = assert(grid.plan(before, "block:main"))
		for _, call in ipairs(plan) do
			Test.eq(call.method, "session.move_block")
			Test.eq(call.arguments.side, "after")
			before.layout = insert(assert(detach(before.layout, call.arguments.block_id)), call.arguments)
		end
		local actual, expected = {}, {}
		rects(before.layout, actual, { 0, 0, 1, 1 })
		rects(after.layout, expected)
		Test.eq(
			vim.tbl_map(function(cell)
				return cell.id
			end, actual),
			{
				"block:main",
				"block:worker",
				"block:b",
				"block:c",
				"block:d",
				"block:e",
			}
		)
		for index, cell in ipairs(actual) do
			for axis = 1, 4 do
				assert(math.abs(cell.rect[axis] - expected[index].rect[axis]) <= 0.01)
			end
		end
		Test.eq(grid.plan(after, "block:main"), {})
	end
)

Test.test("Rex grid corrects split ratios without moving correctly arranged panes", function()
	local layer = assert(grid.find_layer(view("after-grid"), "block:main"))
	local outer = assert(layer.layout.split)
	outer.ratio = 0.7
	local right = assert(outer.after.split)
	right.ratio = 0.7
	right.before.rect, right.after.rect = { 0.7, 0, 0.3, 0.7 }, { 0.7, 0.7, 0.3, 0.3 }
	Test.eq(grid.plan(layer, "block:main"), {
		{
			method = "session.resize_pane",
			arguments = {
				direction = "vertical",
				before_block_id = "block:e",
				after_block_id = "block:c",
				ratio = 1 / 2,
			},
		},
		{
			method = "session.resize_pane",
			arguments = {
				direction = "horizontal",
				before_block_id = "block:d",
				after_block_id = "block:e",
				ratio = 2 / 3,
			},
		},
	})
end)

Test.test("Rex grid ignores floating panes and workers in other windows", function()
	local captured = view("after-grid")
	local window = captured.windows[1]
	table.insert(window.layers, 1, { kind = "floating", blocks = { { block_id = "block:float" } } })
	local layer, window_id = grid.find_layer(captured, "block:main")
	Test.eq(window_id, "window:worker")
	Test.eq(grid.find_layer(captured, "block:float"), nil)
	Test.eq(grid.plan(assert(layer), "block:main"), {})
	local calls, reason = grid.plan(assert(layer), "block:main", "block:other")
	Test.eq({ calls, reason }, { nil, "new worker is outside the anchor's tiled layer" })
end)

Test.test("Rex grid skips a foreign label with the orc prefix", function()
	local layer = assert(grid.find_layer(view("before-columns"), "block:main"))
	for index = #layer.blocks, 4, -1 do
		local block = table.remove(layer.blocks, index)
		layer.layout = assert(detach(layer.layout, block.block_id))
	end
	layer.blocks[3].label = "orc:manual:logs"
	local calls, reason = grid.plan(layer, "block:main", "block:worker")
	Test.eq({ calls, reason }, { nil, "tiled layer contains a non-orc block" })
end)
