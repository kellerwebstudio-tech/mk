--!nonstrict
-- ClientState: the reactive store every client controller and UI module reads from.
-- Bootstrap seeds it from GetSnapshot and keeps it updated from server RemoteEvents; controllers
-- subscribe with onChange(key, fn). Keys are the documented fields (docs/ARCHITECTURE.md section 7):
--   profile, orders ({available, active, capacity, serverTime}), vehicle ({state, vehicleId, model}),
--   contract, depot, tutorial ({step, completed, title, body, hint}), serverTimeOffset,
--   stopOrder ({orderId}), settings, device ("Keyboard" | "Gamepad" | "Touch").
-- Also forwards server OrderEvent / WorldEvent payloads as signals.
-- Stop / interaction positions prefer the streamed world instances when they are present
-- (workspace.PickupLocations.<businessId>.PickupPad, workspace.DeliveryDestinations.<destinationId>
-- .Door / .ArrivalPad, as built by the server CityBuilder) and fall back to the layout x/z with
-- y = groundY (CityBuilder.positionsFor is server-only, so the client cannot reuse its numbers).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Util = Shared:WaitForChild("Util")
local Signal = require(Util:WaitForChild("Signal"))

local ClientState = {}

-- Key -> current value. Table values fire Changed on every set (callers mutate copies, not the stored table).
local values: { [string]: any } = {
	profile = nil,
	orders = { available = {}, active = {}, capacity = nil, serverTime = nil },
	vehicle = { state = nil, vehicleId = nil, model = nil },
	contract = nil,
	depot = nil,
	tutorial = { step = 0, completed = false, title = nil, body = nil, hint = nil },
	serverTimeOffset = 0,
	stopOrder = {},
	settings = nil,
	device = "Keyboard",
}

-- Layout reference (set by bootstrap through setLayout) used for stop positions.
local layout: any = nil

ClientState.Changed = Signal.new() -- (key: string, value: any)
ClientState.OrderEvent = Signal.new() -- (payload) forwarded from the OrderEvent RemoteEvent
ClientState.WorldEvent = Signal.new() -- (payload) forwarded from the WorldEvent RemoteEvent

function ClientState.get(key: string): any
	return values[key]
end

-- Sets a value. Fires Changed when the value changed by reference, or whenever the value is a table
-- (tables are treated as new snapshots even if the reference is reused by a caller).
function ClientState.set(key: string, value: any)
	local previous = values[key]
	values[key] = value
	if previous ~= value or type(value) == "table" then
		ClientState.Changed:Fire(key, value)
	end
end

-- Calls fn immediately with the current value and again on every change of that key.
function ClientState.onChange(key: string, fn: (any) -> ())
	local connection = ClientState.Changed:Connect(function(changedKey, value)
		if changedKey == key then
			fn(value)
		end
	end)
	task.spawn(fn, values[key])
	return connection
end

-- Server clock estimate: os.clock() on this client plus the measured offset.
function ClientState.serverNow(): number
	return os.clock() + (values.serverTimeOffset or 0)
end

function ClientState.setLayout(cityLayout: any)
	layout = cityLayout
end

function ClientState.getLayout(): any
	return layout
end

function ClientState.getActiveOrder(orderId: string): any
	local orders = values.orders
	if not orders or type(orders.active) ~= "table" then
		return nil
	end
	for _, order in ipairs(orders.active) do
		if order.id == orderId then
			return order
		end
	end
	return nil
end

function ClientState.getActiveOrders(): { any }
	local orders = values.orders
	if not orders or type(orders.active) ~= "table" then
		return {}
	end
	return orders.active
end

-- Position of the local player: the vehicle chassis while driving, else the character root.
function ClientState.getPlayerPosition(): Vector3?
	local vehicle = values.vehicle
	if vehicle and vehicle.state == "Driving" and typeof(vehicle.model) == "Instance" then
		local chassis = vehicle.model:FindFirstChild("Chassis")
		if chassis and chassis:IsA("BasePart") then
			return chassis.Position
		end
	end
	local player = Players.LocalPlayer
	local character = player and player.Character
	if character then
		local root = character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			return root.Position
		end
		local pivotOk, pivot = pcall(function()
			return character:GetPivot()
		end)
		if pivotOk and pivot then
			return pivot.Position
		end
	end
	return nil
end

-------------------------------------------------------------------------------
-- Stop positions: streamed world instances first, layout fallback
-------------------------------------------------------------------------------

local function findWorldModel(folderName: string, id: string): Instance?
	local folder = Workspace:FindFirstChild(folderName)
	if not folder then
		return nil
	end
	local model = folder:FindFirstChild(id)
	if model then
		return model
	end
	-- Streamed models can carry the id as an attribute even if renamed; scan as a fallback.
	local attribute = folderName == "PickupLocations" and "BusinessId" or "DestinationId"
	for _, child in ipairs(folder:GetChildren()) do
		if child:GetAttribute(attribute) == id then
			return child
		end
	end
	return nil
end

-- Walkable-surface position of a world part: pads report their top face, doors their bottom edge.
local function surfacePosition(part: BasePart, edge: "top" | "bottom"): Vector3
	local position = part.Position
	local half = part.Size.Y / 2
	if edge == "top" then
		return Vector3.new(position.X, position.Y + half, position.Z)
	end
	return Vector3.new(position.X, position.Y - half, position.Z)
end

local function worldPart(model: Instance?, name: string): BasePart?
	if not model then
		return nil
	end
	local part = model:FindFirstChild(name)
	if part and part:IsA("BasePart") then
		return part
	end
	return nil
end

-- Pickup pad top centre of a streamed business model, or nil when not streamed in.
function ClientState.getWorldBusinessPickupPosition(businessId: string): Vector3?
	local pad = worldPart(findWorldModel("PickupLocations", businessId), "PickupPad")
	return pad and surfacePosition(pad, "top") or nil
end

-- Door bottom centre of a streamed destination model, or nil when not streamed in.
function ClientState.getWorldDestinationDoorPosition(destinationId: string): Vector3?
	local door = worldPart(findWorldModel("DeliveryDestinations", destinationId), "Door")
	return door and surfacePosition(door, "bottom") or nil
end

-- Arrival pad top centre of a streamed destination model, or nil when not streamed in.
function ClientState.getWorldDestinationArrivalPosition(destinationId: string): Vector3?
	local pad = worldPart(findWorldModel("DeliveryDestinations", destinationId), "ArrivalPad")
	return pad and surfacePosition(pad, "top") or nil
end

local function groundY(): number
	if layout and type(layout.groundY) == "number" then
		return layout.groundY
	end
	return 0
end

local function toVector(point: any, baseY: number?): Vector3?
	if type(point) ~= "table" or type(point.x) ~= "number" or type(point.z) ~= "number" then
		return nil
	end
	local y = point.y
	if type(y) ~= "number" then
		y = baseY or groundY()
	end
	return Vector3.new(point.x, y, point.z)
end

local function findById(list: any, id: string): any
	if type(list) ~= "table" then
		return nil
	end
	for _, entry in ipairs(list) do
		if entry.id == id then
			return entry
		end
	end
	return nil
end

-- Business pickup point: the streamed PickupPad when present, else layout businesses[].pickupPoint
-- with ground y.
function ClientState.getBusinessPickupPosition(businessId: string): Vector3?
	local world = ClientState.getWorldBusinessPickupPosition(businessId)
	if world then
		return world
	end
	if not layout then
		return nil
	end
	local business = findById(layout.businesses, businessId)
	if not business then
		return nil
	end
	local baseY = business.building and business.building.baseY or nil
	return toVector(business.pickupPoint, baseY) or toVector(business.door, baseY)
end

function ClientState.getBusinessName(businessId: string): string
	local business = layout and findById(layout.businesses, businessId)
	if business and type(business.name) == "string" then
		return business.name
	end
	return businessId
end

-- Destination door: the streamed Door part when present, else the layout door with ground y
-- (or the building base height when the layout provides it).
function ClientState.getDestinationDoorPosition(destinationId: string): Vector3?
	local world = ClientState.getWorldDestinationDoorPosition(destinationId)
	if world then
		return world
	end
	if not layout then
		return nil
	end
	local destination = findById(layout.destinations, destinationId)
	if not destination then
		return nil
	end
	local baseY = destination.building and destination.building.baseY or nil
	return toVector(destination.door, baseY)
end

-- Destination arrival point: the streamed ArrivalPad when present, else the layout arrivalPoint.
function ClientState.getDestinationArrivalPosition(destinationId: string): Vector3?
	local world = ClientState.getWorldDestinationArrivalPosition(destinationId)
	if world then
		return world
	end
	if not layout then
		return nil
	end
	local destination = findById(layout.destinations, destinationId)
	if not destination then
		return nil
	end
	local baseY = destination.building and destination.building.baseY or nil
	return toVector(destination.arrivalPoint, baseY)
end

function ClientState.getDestinationAddress(destinationId: string): string
	local destination = layout and findById(layout.destinations, destinationId)
	if destination and type(destination.address) == "string" then
		return destination.address
	end
	return destinationId
end

export type Stop = { order: any, kind: string, position: Vector3, label: string, address: string }

local function stopForOrder(order: any): Stop?
	if type(order) ~= "table" then
		return nil
	end
	local state = order.state
	if state == "Accepted" or state == "ReadyForPickup" then
		local position = ClientState.getBusinessPickupPosition(order.businessId)
		if not position then
			return nil
		end
		return {
			order = order,
			kind = "pickup",
			position = position,
			label = ClientState.getBusinessName(order.businessId),
			address = ClientState.getBusinessName(order.businessId),
		}
	elseif state == "Collected" then
		local position = ClientState.getDestinationDoorPosition(order.destinationId)
		if not position then
			return nil
		end
		return {
			order = order,
			kind = "deliver",
			position = position,
			label = ClientState.getDestinationAddress(order.destinationId),
			address = ClientState.getDestinationAddress(order.destinationId),
		}
	end
	return nil
end

-- Stops for every active order: the ones listed in stopOrder first (in that order), then the
-- remaining ones nearest-first (greedy chain starting from the last ordered stop or the player).
function ClientState.getOrderedStops(fromPosition: Vector3?): { Stop }
	local result: { Stop } = {}
	local remaining: { Stop } = {}
	local byId: { [string]: Stop } = {}
	for _, order in ipairs(ClientState.getActiveOrders()) do
		local stop = stopForOrder(order)
		if stop then
			byId[order.id] = stop
			table.insert(remaining, stop)
		end
	end

	local stopOrder = values.stopOrder
	if type(stopOrder) == "table" then
		for _, orderId in ipairs(stopOrder) do
			local stop = byId[orderId]
			if stop then
				table.insert(result, stop)
				byId[orderId] = nil
				for index, candidate in ipairs(remaining) do
					if candidate == stop then
						table.remove(remaining, index)
						break
					end
				end
			end
		end
	end

	local origin = fromPosition or ClientState.getPlayerPosition()
	if #result > 0 then
		origin = result[#result].position
	end
	while #remaining > 0 do
		local bestIndex = 1
		if origin then
			local bestDistance = math.huge
			for index, stop in ipairs(remaining) do
				local dx = stop.position.X - origin.X
				local dz = stop.position.Z - origin.Z
				local distance = dx * dx + dz * dz
				if distance < bestDistance then
					bestDistance = distance
					bestIndex = index
				end
			end
		end
		local chosen = table.remove(remaining, bestIndex)
		table.insert(result, chosen)
		origin = chosen.position
	end
	return result
end

return ClientState
