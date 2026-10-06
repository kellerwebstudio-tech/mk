--!strict
-- Maid: collects connections, instances, functions and other maids for cleanup.

local Maid = {}
Maid.__index = Maid

export type Maid = typeof(setmetatable({} :: { _tasks: { [any]: any }, _nextId: number }, Maid))

function Maid.new(): Maid
	return setmetatable({ _tasks = {}, _nextId = 0 }, Maid)
end

local function cleanupTask(item: any)
	local itemType = typeof(item)
	if itemType == "function" then
		item()
	elseif itemType == "RBXScriptConnection" then
		item:Disconnect()
	elseif itemType == "Instance" then
		item:Destroy()
	elseif itemType == "table" then
		if type(item.Destroy) == "function" then
			item:Destroy()
		elseif type(item.Disconnect) == "function" then
			item:Disconnect()
		elseif type(item.DoCleaning) == "function" then
			item:DoCleaning()
		end
	elseif itemType == "thread" then
		pcall(task.cancel, item)
	end
end

function Maid.GiveTask(self: Maid, item: any): any
	assert(item ~= nil, "Maid:GiveTask requires a task")
	self._nextId += 1
	local id = self._nextId
	self._tasks[id] = item
	return id
end

function Maid.Set(self: Maid, key: any, item: any)
	local existing = self._tasks[key]
	self._tasks[key] = item
	if existing ~= nil then
		cleanupTask(existing)
	end
end

function Maid.Remove(self: Maid, key: any)
	local existing = self._tasks[key]
	if existing ~= nil then
		self._tasks[key] = nil
		cleanupTask(existing)
	end
end

function Maid.DoCleaning(self: Maid)
	local tasks = self._tasks
	self._tasks = {}
	for _, item in pairs(tasks) do
		cleanupTask(item)
	end
end

Maid.Destroy = Maid.DoCleaning

return Maid
