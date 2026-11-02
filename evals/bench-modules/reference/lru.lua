local M = {}
---@class EvalLRU
---@field size integer Number of stored entries; read-only.
---@field get fun(self:EvalLRU,key:any):any Promotes a present key to most recent.
---@field set fun(self:EvalLRU,key:any,value:any):EvalLRU Stores and promotes a key.
---@field has fun(self:EvalLRU,key:any):boolean Checks presence without promotion.
---@field delete fun(self:EvalLRU,key:any):boolean Removes a present key.
local NIL, NAN = {}, {}
local function key_of(key)
	if key == nil then
		return NIL
	end
	if type(key) == "number" and key ~= key then
		return NAN
	end
	return key
end

---Construct an O(1) LRU with nil/NaN keys, nil values and read-only size.
---@param capacity integer
---@return EvalLRU
function M.new(capacity)
	if type(capacity) ~= "number" or capacity < 1 or capacity % 1 ~= 0 or capacity == math.huge then
		error({ kind = "RangeError", message = "capacity must be a positive finite integer" }, 0)
	end
	local entries, count, head, tail = {}, 0, nil, nil
	local object, methods = {}, {}
	local function detach(node)
		if node.prev then
			node.prev.next = node.next
		else
			head = node.next
		end
		if node.next then
			node.next.prev = node.prev
		else
			tail = node.prev
		end
	end
	local function newest(node)
		node.prev, node.next = tail, nil
		if tail then
			tail.next = node
		else
			head = node
		end
		tail = node
	end
	function methods.get(_, key)
		local node = entries[key_of(key)]
		if not node then
			return nil
		end
		detach(node)
		newest(node)
		return node.value
	end
	function methods.set(_, key, value)
		key = key_of(key)
		local node = entries[key]
		if node then
			detach(node)
			node.value = value
		else
			node = { key = key, value = value }
			entries[key], count = node, count + 1
		end
		newest(node)
		if count > capacity then
			entries[head.key] = nil
			detach(head)
			count = count - 1
		end
		return object
	end
	function methods.has(_, key)
		return entries[key_of(key)] ~= nil
	end
	function methods.delete(_, key)
		key = key_of(key)
		local node = entries[key]
		if not node then
			return false
		end
		detach(node)
		entries[key], count = nil, count - 1
		return true
	end
	return setmetatable(object, {
		__index = function(_, key)
			return key == "size" and count or methods[key]
		end,
		__newindex = function()
			error({ kind = "TypeError", message = "cache fields are read-only" }, 0)
		end,
	})
end
return M
