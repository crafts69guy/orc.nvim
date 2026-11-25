local M = {}
local WORKER_LABEL = "^orc:" .. string.rep("[0-9a-f]", 24) .. ":[%w_.%-]+$"

---@class orc.RexLayoutNode
---@field rect number[]
---@field block_id? string
---@field split? {direction:string,ratio:number,before:orc.RexLayoutNode,after:orc.RexLayoutNode}

---@class orc.RexTiledLayer
---@field blocks {block_id:string,label?:string}[]
---@field layout orc.RexLayoutNode

---@class orc.RexGridCall
---@field method string
---@field arguments table

---Find the tiled layer containing a block and the ID of its window.
---@param view table
---@param block_id string
---@return orc.RexTiledLayer?, string?
function M.find_layer(view, block_id)
	for _, window in ipairs(view.windows) do
		for _, layer in ipairs(window.layers) do
			if layer.kind == "tiled" then
				for _, block in ipairs(layer.blocks) do
					if block.block_id == block_id then
						return layer, window.window_id
					end
				end
			end
		end
	end
end

---Return the number of columns and maximum column height for a positive cell count.
---@param count integer
---@return integer cols, integer rows
function M.shape(count)
	local cols = math.ceil(math.sqrt(count))
	return cols, math.ceil(count / cols)
end

---@param node orc.RexLayoutNode
---@param leaves orc.RexLayoutNode[]
local function collect(node, leaves)
	if node.block_id then
		leaves[#leaves + 1] = node
	else
		local split = assert(node.split, "rex: invalid tiled layout")
		collect(split.before, leaves)
		collect(split.after, leaves)
	end
end

---@param node orc.RexLayoutNode
---@param positions table<string,integer>
---@param ids string[]
---@param rows integer
---@param calls orc.RexGridCall[]
---@return integer? first, integer? last
local function resize_grid(node, positions, ids, rows, calls)
	if node.block_id then
		local at = assert(positions[node.block_id], "rex: tiled block missing from grid")
		return at, at
	end
	local split = assert(node.split)
	local first, before = resize_grid(split.before, positions, ids, rows, calls)
	local after, last = resize_grid(split.after, positions, ids, rows, calls)
	if not first or not before or not after or not last or before + 1 ~= after then
		return nil
	end
	local first_col, last_col = math.ceil(first / rows), math.ceil(last / rows)
	local direction = first_col == last_col and "vertical" or "horizontal"
	if split.direction ~= direction then
		return nil
	end
	local ratio = (before - first + 1) / (last - first + 1)
	if direction == "horizontal" then
		if before % rows ~= 0 then
			return nil
		end
		local before_col = before / rows
		ratio = (before_col - first_col + 1) / (last_col - first_col + 1)
		before = (before_col - 1) * rows + 1
	end
	if math.abs(split.ratio - ratio) > 0.000001 then
		calls[#calls + 1] = {
			method = "session.resize_pane",
			arguments = {
				direction = direction,
				before_block_id = ids[before],
				after_block_id = ids[after],
				ratio = ratio,
			},
		}
	end
	return first, last
end

---@param calls orc.RexGridCall[]
---@param block string
---@param anchor string
---@param direction string
---@param size integer
local function move(calls, block, anchor, direction, size)
	calls[#calls + 1] = {
		method = "session.move_block",
		arguments = {
			block_id = block,
			anchor_block_id = anchor,
			direction = direction,
			side = "after",
			ratio = (size - 1) / size,
		},
	}
end

---@param leaves orc.RexLayoutNode[]
---@param positions table<string,integer>
---@param cols integer
---@param rows integer
---@return boolean
local function equal_grid(leaves, positions, cols, rows)
	for _, leaf in ipairs(leaves) do
		local offset = positions[assert(leaf.block_id)] - 1
		local col, row = math.floor(offset / rows), offset % rows
		local height = 1 / math.min(rows, #leaves - col * rows)
		local rect = leaf.rect
		if
			math.max(
				math.abs(rect[1] - col / cols),
				math.abs(rect[2] - row * height),
				math.abs(rect[3] - 1 / cols),
				math.abs(rect[4] - height)
			) > 0.01
		then
			return false
		end
	end
	return true
end

---Plan an equal grid using column order, then top-to-bottom order within each column.
---@param layer orc.RexTiledLayer
---@param anchor string
---@param new_block? string Newly launched worker, placed after the existing workers.
---@return orc.RexGridCall[]? calls, string? skip_reason
function M.plan(layer, anchor, new_block)
	local owned = {}
	for _, block in ipairs(layer.blocks) do
		if block.block_id ~= anchor and not (block.label or ""):match(WORKER_LABEL) then
			return nil, "tiled layer contains a non-orc block"
		end
		owned[block.block_id] = true
	end
	if new_block and not owned[new_block] then
		return nil, "new worker is outside the anchor's tiled layer"
	end
	local leaves = {}
	collect(layer.layout, leaves)
	table.sort(leaves, function(a, b)
		if a.rect[1] == b.rect[1] then
			return a.rect[2] < b.rect[2]
		end
		return a.rect[1] < b.rect[1]
	end)
	local ids = { anchor }
	for _, leaf in ipairs(leaves) do
		local id = assert(leaf.block_id)
		assert(owned[id], "rex: tiled block missing from layer")
		if id ~= anchor and id ~= new_block then
			ids[#ids + 1] = id
		end
	end
	if new_block then
		ids[#ids + 1] = new_block
	end
	assert(#ids == #leaves, "rex: inconsistent tiled layout")
	local cols, rows = M.shape(#ids)
	local positions, calls = {}, {}
	for index, id in ipairs(ids) do
		positions[id] = index
	end
	if
		equal_grid(leaves, positions, cols, rows)
		or resize_grid(layer.layout, positions, ids, rows, calls)
	then
		return calls
	end
	calls = {}
	for col = cols, 2, -1 do
		move(calls, ids[(col - 1) * rows + 1], anchor, "horizontal", col)
	end
	for first = 1, #ids, rows do
		for at = math.min(first + rows - 1, #ids), first + 1, -1 do
			move(calls, ids[at], ids[first], "vertical", at - first + 1)
		end
	end
	return calls
end

return M
