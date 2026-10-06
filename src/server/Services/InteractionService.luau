--!nonstrict
-- InteractionService: the single remote boundary. Creates every remote, binds RemoteFunctions to the
-- owning service with rate limiting, strict argument validation, a profile-loaded gate and pcall
-- wrapping. See docs/ARCHITECTURE.md sections 3 and 5.9.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)
local Remotes = require(Shared.Util.Remotes)
local RateLimiter = require(Shared.Util.RateLimiter)
local TableUtil = require(Shared.Util.TableUtil)

type Profile = Types.Profile

local RATE_PER_SECOND = 8
local RATE_BURST = 12
local ORDER_RATE_INTERVAL = 0.3 -- pickup/delivery: 1 per 0.3 s per order
local HEARTBEAT_RATE = 1
local HEARTBEAT_BURST = 3
local MAX_ID_LENGTH = 64
local MAX_TABLE_ENTRIES = 32
local SNAPSHOT_PROFILE_WAIT = 15

local SETTINGS_SCHEMA = {
	cameraSensitivity = { kind = "number", min = 0.2, max = 3 },
	reducedMotion = { kind = "boolean" },
	autoRecenter = { kind = "boolean" },
	musicVolume = { kind = "number", min = 0, max = 1 },
	sfxVolume = { kind = "number", min = 0, max = 1 },
	showMinimap = { kind = "boolean" },
	invertCameraY = { kind = "boolean" },
}

local InteractionService = {}

local ctx: any = nil
local limiter = RateLimiter.new(RATE_PER_SECOND, RATE_BURST)
local orderLimiter = RateLimiter.new(1 / ORDER_RATE_INTERVAL, 1)
local heartbeatLimiter = RateLimiter.new(HEARTBEAT_RATE, HEARTBEAT_BURST)
InteractionService._orderLimiter = orderLimiter -- exposed for the offline specs

-------------------------------------------------------------------------------
-- Validation helpers
-------------------------------------------------------------------------------

function InteractionService.validateId(value: any): boolean
	return type(value) == "string" and #value > 0 and #value <= MAX_ID_LENGTH
end

function InteractionService.validateNumber(value: any): boolean
	return TableUtil.isFiniteNumber(value)
end

function InteractionService.validateTable(value: any): boolean
	if type(value) ~= "table" then
		return false
	end
	local count = 0
	for _ in pairs(value) do
		count += 1
		if count > MAX_TABLE_ENTRIES then
			return false
		end
	end
	return true
end

local validateId = InteractionService.validateId
local validateNumber = InteractionService.validateNumber
local validateTable = InteractionService.validateTable

local function service(name: string)
	return ctx and ctx.services and ctx.services[name]
end

local function getProfile(player: Player): Profile?
	local playerData = service("PlayerDataService")
	return playerData and playerData.GetProfile(player) or nil
end

local function notify(player: Player, text: string, kind: string)
	pcall(function()
		ctx.remotes.getEvent("Notify"):FireClient(player, { text = text, kind = kind, duration = 4 })
	end)
end

-- Calls `methodName` on the named service, or returns Unavailable when the service is missing.
local function callService(serviceName: string, methodNames: { string }, player: Player, ...)
	local target = service(serviceName)
	if not target then
		return Remotes.fail("Unavailable", "That feature isn't available right now")
	end
	for _, methodName in ipairs(methodNames) do
		local method = target[methodName]
		if type(method) == "function" then
			return method(player, ...)
		end
	end
	return Remotes.fail("Unavailable", "That feature isn't available right now")
end

-------------------------------------------------------------------------------
-- Binding
-------------------------------------------------------------------------------

-- options: { waitForProfile: boolean? }
local function bind(name: string, handler: (Player, ...any) -> any, options)
	options = options or {}
	local remote = ctx.remotes.getFunction(name)
	remote.OnServerInvoke = function(player: Player, ...)
		if typeof(player) ~= "Instance" or not player:IsA("Player") then
			return Remotes.fail("Invalid", "Invalid caller")
		end
		if not limiter:Allow(player) then
			return Remotes.fail("RateLimited", "Slow down")
		end
		local profile = getProfile(player)
		if not profile and options.waitForProfile then
			local playerData = service("PlayerDataService")
			if playerData then
				profile = playerData.WaitForProfile(player, SNAPSHOT_PROFILE_WAIT)
			end
		end
		if not profile then
			return Remotes.fail("Locked", "Your profile is still loading")
		end
		local okCall, result = pcall(handler, player, ...)
		if not okCall then
			warn(string.format("[InteractionService] %s failed for %s: %s", name, player.Name, tostring(result)))
			notify(player, "Something went wrong. Please try again.", "error")
			return Remotes.fail("Internal", "Something went wrong")
		end
		if type(result) ~= "table" then
			return Remotes.fail("Internal", "Something went wrong")
		end
		return result
	end
end

local function orderCall(action: string, player: Player, orderId: any)
	if not validateId(orderId) then
		return Remotes.fail("Invalid", "Invalid order id")
	end
	if not orderLimiter:Allow(tostring(player.UserId) .. ":" .. action .. ":" .. orderId) then
		return Remotes.fail("RateLimited", "Slow down")
	end
	return callService("OrderService", { action }, player, orderId)
end

local function buildSnapshot(player: Player)
	local playerData = service("PlayerDataService")
	local orders = service("OrderService")
	local vehicles = service("VehicleService")
	local contracts = service("ContractService")
	local depot = service("DepotService")
	local profile = playerData.GetProfile(player)
	local public = playerData.GetPublicProfile(player)

	local snapshot = {
		profile = public,
		orders = {
			available = orders and orders.GetAvailable(player) or {},
			active = orders and orders.GetActive(player) or {},
			capacity = orders and orders.GetCapacityInfo(player) or nil,
		},
		vehicle = {
			state = vehicles and vehicles.GetState(player) or nil,
			vehicleId = vehicles and vehicles.GetCurrentVehicleId(player) or nil,
			model = nil,
		},
		contract = nil,
		depot = nil,
		tutorial = { completed = profile.tutorial.completed, step = profile.tutorial.step },
		serverTime = os.clock(),
	}
	if vehicles then
		local record = vehicles.GetVehicle(player)
		snapshot.vehicle.model = record and record.model or nil
	end
	if contracts and type(contracts.GetStateFor) == "function" then
		local okState, state = pcall(contracts.GetStateFor, player)
		if okState then
			snapshot.contract = state
		end
	end
	if depot and type(depot.GetStateFor) == "function" then
		local okState, state = pcall(depot.GetStateFor, player)
		if okState then
			snapshot.depot = state
		end
	end
	return Remotes.ok(snapshot)
end

-- Validates settings field by field against the schema; unknown fields are ignored.
function InteractionService.SanitizeSettings(current: any, incoming: any): any
	local result = {}
	for key, rule in pairs(SETTINGS_SCHEMA) do
		local value = incoming[key]
		local fallback = current and current[key]
		if rule.kind == "number" then
			if validateNumber(value) then
				result[key] = math.clamp(value, rule.min, rule.max)
			elseif validateNumber(fallback) then
				result[key] = math.clamp(fallback, rule.min, rule.max)
			else
				result[key] = rule.min
			end
		elseif rule.kind == "boolean" then
			if type(value) == "boolean" then
				result[key] = value
			elseif type(fallback) == "boolean" then
				result[key] = fallback
			else
				result[key] = false
			end
		end
	end
	return result
end

local function saveSettings(player: Player, settings: any)
	if not validateTable(settings) then
		return Remotes.fail("Invalid", "Invalid settings")
	end
	local playerData = service("PlayerDataService")
	local profile = playerData.GetProfile(player)
	local sanitized = InteractionService.SanitizeSettings(profile.settings, settings)
	playerData.Update(player, function(p: Profile)
		for key, value in pairs(sanitized) do
			(p.settings :: any)[key] = value
		end
	end)
	return Remotes.ok({ settings = sanitized })
end

local function bindAll()
	bind("GetSnapshot", buildSnapshot, { waitForProfile = true })

	bind("AcceptOrder", function(player, orderId)
		if not validateId(orderId) then
			return Remotes.fail("Invalid", "Invalid order id")
		end
		return callService("OrderService", { "Accept" }, player, orderId)
	end)
	bind("CancelOrder", function(player, orderId)
		if not validateId(orderId) then
			return Remotes.fail("Invalid", "Invalid order id")
		end
		return callService("OrderService", { "Cancel" }, player, orderId)
	end)
	bind("RequestPickup", function(player, orderId)
		return orderCall("RequestPickup", player, orderId)
	end)
	bind("RequestDelivery", function(player, orderId)
		return orderCall("RequestDelivery", player, orderId)
	end)

	bind("SpawnVehicle", function(player, vehicleId)
		if not validateId(vehicleId) then
			return Remotes.fail("Invalid", "Invalid vehicle id")
		end
		return callService("VehicleService", { "Spawn" }, player, vehicleId)
	end)
	bind("DespawnVehicle", function(player)
		return callService("VehicleService", { "Despawn" }, player)
	end)
	bind("MountVehicle", function(player)
		return callService("VehicleService", { "Mount" }, player)
	end)
	bind("DismountVehicle", function(player)
		return callService("VehicleService", { "Dismount" }, player)
	end)
	bind("RecoverVehicle", function(player)
		return callService("VehicleService", { "Recover" }, player)
	end)

	bind("PurchaseVehicle", function(player, vehicleId)
		if not validateId(vehicleId) then
			return Remotes.fail("Invalid", "Invalid vehicle id")
		end
		return callService("ShopService", { "PurchaseVehicle" }, player, vehicleId)
	end)
	bind("EquipVehicle", function(player, vehicleId)
		if not validateId(vehicleId) then
			return Remotes.fail("Invalid", "Invalid vehicle id")
		end
		return callService("ShopService", { "EquipVehicle" }, player, vehicleId)
	end)
	bind("PurchaseUpgrade", function(player, upgradeId)
		if not validateId(upgradeId) then
			return Remotes.fail("Invalid", "Invalid upgrade id")
		end
		return callService("ShopService", { "PurchaseUpgrade" }, player, upgradeId)
	end)
	bind("PurchaseCosmetic", function(player, cosmeticId)
		if not validateId(cosmeticId) then
			return Remotes.fail("Invalid", "Invalid cosmetic id")
		end
		return callService("ShopService", { "PurchaseCosmetic" }, player, cosmeticId)
	end)
	bind("EquipCosmetic", function(player, cosmeticId)
		if not validateId(cosmeticId) then
			return Remotes.fail("Invalid", "Invalid cosmetic id")
		end
		return callService("ShopService", { "EquipCosmetic" }, player, cosmeticId)
	end)

	bind("PurchaseDepot", function(player)
		return callService("DepotService", { "Purchase", "PurchaseDepot" }, player)
	end)
	bind("UnlockDriverSlot", function(player)
		return callService("DepotService", { "UnlockSlot", "UnlockDriverSlot" }, player)
	end)
	bind("HireDriver", function(player, slot)
		if not validateNumber(slot) or slot ~= math.floor(slot) or slot < 1 or slot > 8 then
			return Remotes.fail("Invalid", "Invalid slot")
		end
		return callService("DepotService", { "HireDriver" }, player, slot)
	end)
	bind("AssignDriver", function(player, slot, category)
		if not validateNumber(slot) or slot ~= math.floor(slot) or slot < 1 or slot > 8 then
			return Remotes.fail("Invalid", "Invalid slot")
		end
		if not validateId(category) then
			return Remotes.fail("Invalid", "Invalid category")
		end
		return callService("DepotService", { "AssignDriver" }, player, slot, category)
	end)
	bind("CollectDepotEarnings", function(player)
		return callService("DepotService", { "Collect", "CollectDepotEarnings" }, player)
	end)

	bind("JoinContract", function(player, contractId, orderIds)
		if not validateId(contractId) then
			return Remotes.fail("Invalid", "Invalid contract id")
		end
		if not validateTable(orderIds) then
			return Remotes.fail("Invalid", "Invalid order list")
		end
		local ids = {}
		for index, value in ipairs(orderIds) do
			if not validateId(value) then
				return Remotes.fail("Invalid", "Invalid order id")
			end
			ids[index] = value
		end
		return callService("ContractService", { "Join", "JoinContract" }, player, contractId, ids)
	end)

	bind("AdvanceTutorial", function(player, step)
		if not validateNumber(step) or step ~= math.floor(step) then
			return Remotes.fail("Invalid", "Invalid step")
		end
		return callService("TutorialService", { "AdvanceTutorial" }, player, step)
	end)

	bind("SaveSettings", saveSettings)

	-- Client -> server telemetry: content ignored, only rate-limited.
	local heartbeat = ctx.remotes.getEvent("ClientHeartbeat")
	heartbeat.OnServerEvent:Connect(function(player)
		heartbeatLimiter:Allow(player)
	end)
end

function InteractionService.Init(context)
	ctx = context
	ctx.remotes.createAll()
end

function InteractionService.Start()
	bindAll()
	Players.PlayerRemoving:Connect(function(player)
		limiter:Reset(player)
		heartbeatLimiter:Reset(player)
		-- orderLimiter keys are "<userId>:<action>:<orderId>" strings (client-supplied ids, so a
		-- Reset per key is impossible); RateLimiter sweeps idle buckets itself, this just frees the
		-- leaver's entries at once.
		orderLimiter:Sweep()
	end)
end

return InteractionService
