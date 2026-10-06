--!strict
-- Lightweight signal implementation (connections run in order; handlers run in their own thread).

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
}

export type Signal<T...> = {
	Connect: (self: Signal<T...>, handler: (T...) -> ()) -> Connection,
	Once: (self: Signal<T...>, handler: (T...) -> ()) -> Connection,
	Wait: (self: Signal<T...>) -> T...,
	Fire: (self: Signal<T...>, T...) -> (),
	DisconnectAll: (self: Signal<T...>) -> (),
	Destroy: (self: Signal<T...>) -> (),
}

local Signal = {}
Signal.__index = Signal

local ConnectionClass = {}
ConnectionClass.__index = ConnectionClass

function ConnectionClass.Disconnect(self)
	if not self.Connected then
		return
	end
	self.Connected = false
	local signal = self._signal
	local list = signal._handlers
	for i = #list, 1, -1 do
		if list[i] == self then
			table.remove(list, i)
			break
		end
	end
end

function Signal.new()
	local self = setmetatable({
		_handlers = {},
	}, Signal)
	return self
end

function Signal.Connect(self, handler)
	assert(type(handler) == "function", "Signal:Connect expects a function")
	local connection = setmetatable({
		Connected = true,
		_handler = handler,
		_signal = self,
		_once = false,
	}, ConnectionClass)
	table.insert(self._handlers, connection)
	return connection
end

function Signal.Once(self, handler)
	local connection = self:Connect(handler)
	connection._once = true
	return connection
end

function Signal.Wait(self)
	local thread = coroutine.running()
	local connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end

function Signal.Fire(self, ...)
	local snapshot = table.clone(self._handlers)
	for _, connection in ipairs(snapshot) do
		if connection.Connected then
			if connection._once then
				connection:Disconnect()
			end
			task.spawn(connection._handler, ...)
		end
	end
end

function Signal.DisconnectAll(self)
	for _, connection in ipairs(self._handlers) do
		connection.Connected = false
	end
	table.clear(self._handlers)
end

function Signal.Destroy(self)
	self:DisconnectAll()
end

return Signal
