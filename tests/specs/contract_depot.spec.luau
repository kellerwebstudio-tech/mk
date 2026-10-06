--!nonstrict
-- tests/specs/contract_depot.spec.luau
-- Offline specs for ContractService (Lunch Rush), DepotService and DriverService. The services under
-- test are real; OrderService, PlayerDataService, VehicleService and RewardService are in-spec stubs
-- (ProgressionService is the real module when present). Everything runs on the harness' virtual clock.

shim.setContext("server")

local ReplicatedStorageRef = game:GetService("ReplicatedStorage")

-------------------------------------------------------------------------------
-- Mini layout: two neighbourhoods, three businesses, five destinations each, two depot plots
-------------------------------------------------------------------------------

local LAYOUT = {
	name = "TestCity",
	bounds = { minX = -600, maxX = 600, minZ = -600, maxZ = 600 },
	groundY = 0,
	killY = -60,
	neighborhoods = {
		{ id = "Downtown", name = "Downtown", center = { x = 0, z = -100 }, bounds = { minX = -600, maxX = 600, minZ = -600, maxZ = 100 }, accent = { r = 1, g = 0.5, b = 0.2 } },
		{ id = "Residential", name = "Maple Hill", center = { x = 0, z = 300 }, bounds = { minX = -600, maxX = 600, minZ = 100, maxZ = 600 }, accent = { r = 0.4, g = 0.8, b = 0.4 } },
		{ id = "Industrial", name = "Docks", center = { x = -300, z = -300 }, bounds = { minX = -600, maxX = -200, minZ = -600, maxZ = -200 }, accent = { r = 0.5, g = 0.5, b = 0.6 } },
	},
	roads = {
		{ id = "Main", name = "Main Street", kind = "Road", width = 12, points = { { x = -500, z = 0 }, { x = 500, z = 0 } } },
		{ id = "South", name = "South Road", kind = "Road", width = 12, points = { { x = 0, z = -500 }, { x = 0, z = 500 } } },
	},
	water = {},
	bridges = {},
	buildings = {},
	businesses = {
		{ id = "SliceStreetPizza", neighborhood = "Downtown", door = { x = -20, z = -14 }, facing = { x = 0, z = 1 }, pickupPoint = { x = -20, z = -9 }, arrivalPoint = { x = -20, z = -5 } },
		{ id = "BeanAndBunCafe", neighborhood = "Downtown", door = { x = 60, z = 14 }, facing = { x = 0, z = -1 }, pickupPoint = { x = 60, z = 9 }, arrivalPoint = { x = 60, z = 5 } },
		{ id = "FreshLaneMarket", neighborhood = "Residential", door = { x = 40, z = 214 }, facing = { x = 0, z = -1 }, pickupPoint = { x = 40, z = 209 }, arrivalPoint = { x = 40, z = 205 } },
		{ id = "CrateAndCoSupply", neighborhood = "Industrial", door = { x = -300, z = -14 }, facing = { x = 0, z = 1 }, pickupPoint = { x = -300, z = -9 }, arrivalPoint = { x = -300, z = -5 } },
	},
	destinations = {
		{ id = "D1", address = "1 Main Street", neighborhood = "Downtown", kind = "House", door = { x = 120, z = -12 }, facing = { x = 0, z = 1 }, arrivalPoint = { x = 120, z = -5 } },
		{ id = "D2", address = "2 Main Street", neighborhood = "Downtown", kind = "House", door = { x = 180, z = -12 }, facing = { x = 0, z = 1 }, arrivalPoint = { x = 180, z = -5 } },
		{ id = "D3", address = "3 Main Street", neighborhood = "Downtown", kind = "Apartment", door = { x = 240, z = -12 }, facing = { x = 0, z = 1 }, arrivalPoint = { x = 240, z = -5 } },
		{ id = "D4", address = "4 South Road", neighborhood = "Downtown", kind = "House", door = { x = 12, z = -180 }, facing = { x = -1, z = 0 }, arrivalPoint = { x = 5, z = -180 } },
		{ id = "D5", address = "5 South Road", neighborhood = "Downtown", kind = "Apartment", door = { x = 12, z = -240 }, facing = { x = -1, z = 0 }, arrivalPoint = { x = 5, z = -240 } },
		{ id = "R1", address = "1 Hill Road", neighborhood = "Residential", kind = "House", door = { x = 12, z = 160 }, facing = { x = -1, z = 0 }, arrivalPoint = { x = 5, z = 160 } },
		{ id = "R2", address = "2 Hill Road", neighborhood = "Residential", kind = "House", door = { x = 12, z = 220 }, facing = { x = -1, z = 0 }, arrivalPoint = { x = 5, z = 220 } },
		{ id = "R3", address = "3 Hill Road", neighborhood = "Residential", kind = "House", door = { x = 12, z = 280 }, facing = { x = -1, z = 0 }, arrivalPoint = { x = 5, z = 280 } },
		{ id = "R4", address = "4 Hill Road", neighborhood = "Residential", kind = "House", door = { x = 12, z = 340 }, facing = { x = -1, z = 0 }, arrivalPoint = { x = 5, z = 340 } },
		{ id = "R5", address = "5 Hill Road", neighborhood = "Residential", kind = "House", door = { x = 12, z = 400 }, facing = { x = -1, z = 0 }, arrivalPoint = { x = 5, z = 400 } },
		-- Industrial: loading bays (Medium/Large only) plus one shop and one house. Only businesses whose
		-- deliveryProfile allows the neighbourhood/kind may be offered there (FreshLaneMarket is listed
		-- for Industrial in ContractDefinitions but its profile excludes it).
		{ id = "I1", address = "1 Dock Road", neighborhood = "Industrial", kind = "LoadingBay", door = { x = -360, z = -12 }, facing = { x = 0, z = 1 }, arrivalPoint = { x = -360, z = -5 } },
		{ id = "I2", address = "2 Dock Road", neighborhood = "Industrial", kind = "LoadingBay", door = { x = -420, z = -12 }, facing = { x = 0, z = 1 }, arrivalPoint = { x = -420, z = -5 } },
		{ id = "I3", address = "3 Dock Road", neighborhood = "Industrial", kind = "Shop", door = { x = -480, z = -12 }, facing = { x = 0, z = 1 }, arrivalPoint = { x = -480, z = -5 } },
		{ id = "I4", address = "4 Dock Road", neighborhood = "Industrial", kind = "House", door = { x = -240, z = -12 }, facing = { x = 0, z = 1 }, arrivalPoint = { x = -240, z = -5 } },
	},
	landmarks = {},
	hub = { spawn = { x = 0, z = 30, facing = { x = 0, z = -1 } }, vehiclePads = { { x = 10, z = 30, facing = { x = 0, z = -1 } } }, kiosk = { x = 0, z = 40 } },
	depotPlots = {
		{ id = "P1", x = -300, z = 300, w = 60, d = 50, facing = { x = 0, z = -1 }, parking = { { x = -315, z = 308, facing = { x = 0, z = -1 } }, { x = -285, z = 308, facing = { x = 0, z = -1 } } } },
		{ id = "P2", x = 300, z = 300, w = 60, d = 50, facing = { x = 0, z = -1 }, parking = { { x = 285, z = 308, facing = { x = 0, z = -1 } }, { x = 315, z = 308, facing = { x = 0, z = -1 } } } },
	},
	pedestrianPaths = {},
	parkedVehicles = {},
	props = {},
	bikeShortcuts = {},
}

local function v3(x, y, z)
	return Vector3.new(x, y, z)
end

local function folder(name, parent)
	local existing = parent:FindFirstChild(name)
	if existing then
		return existing
	end
	local f = Instance.new("Folder")
	f.Name = name
	f.Parent = parent
	return f
end

local function anchoredPart(name, cframe, size, parent)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Anchored = true
	part.CFrame = cframe
	part.Parent = parent
	return part
end

local function buildWorld(layout)
	local ws = game:GetService("Workspace")
	local cityFolder = folder("City", ws)
	local pickupFolder = folder("PickupLocations", ws)
	local destinationFolder = folder("DeliveryDestinations", ws)
	local depotFolder = folder("DepotPlots", ws)
	local runtime = folder("Runtime", ws)
	folder("Vehicles", runtime)
	folder("Packages", runtime)
	folder("NPCs", runtime)

	local businesses = {}
	for _, b in ipairs(layout.businesses) do
		local model = Instance.new("Model")
		model.Name = b.id
		model:SetAttribute("BusinessId", b.id)
		local pad = anchoredPart("PickupPad", CFrame.new(b.pickupPoint.x, 0.5, b.pickupPoint.z), v3(4, 1, 4), model)
		model.PrimaryPart = pad
		model.Parent = pickupFolder
		businesses[b.id] = {
			model = model,
			pickupPosition = v3(b.pickupPoint.x, 1, b.pickupPoint.z),
			arrivalPosition = v3(b.arrivalPoint.x, 1, b.arrivalPoint.z),
			doorPart = nil,
		}
	end
	local destinations = {}
	for _, d in ipairs(layout.destinations) do
		local model = Instance.new("Model")
		model.Name = d.id
		model:SetAttribute("DestinationId", d.id)
		model:SetAttribute("Address", d.address)
		local door = anchoredPart("Door", CFrame.new(d.door.x, 3, d.door.z), v3(4, 6, 1), model)
		model.PrimaryPart = door
		model.Parent = destinationFolder
		destinations[d.id] = {
			model = model,
			doorPosition = v3(d.door.x, 1, d.door.z),
			arrivalPosition = v3(d.arrivalPoint.x, 1, d.arrivalPoint.z),
			doorPart = door,
			facing = v3(d.facing.x, 0, d.facing.z),
		}
	end
	local depotPlots = {}
	for _, p in ipairs(layout.depotPlots) do
		local model = Instance.new("Model")
		model.Name = p.id
		model:SetAttribute("PlotId", p.id)
		model:SetAttribute("OwnerUserId", 0)
		model:SetAttribute("OwnerName", "")
		model:SetAttribute("PlotWidth", p.w)
		model:SetAttribute("PlotDepth", p.d)
		local origin = CFrame.lookAlong(v3(p.x, 0, p.z), v3(p.facing.x, 0, p.facing.z))
		local ground = anchoredPart("Ground", origin * CFrame.new(0, -0.2, 0), v3(p.w, 0.4, p.d), model)
		model.PrimaryPart = ground
		local sign = anchoredPart("Sign", origin * CFrame.new(0, 6, -p.d / 2), v3(10, 3, 0.5), model)
		folder("Built", model)
		model.Parent = depotFolder
		local parking = {}
		for _, spot in ipairs(p.parking) do
			table.insert(parking, CFrame.lookAlong(v3(spot.x, 0, spot.z), v3(spot.facing.x, 0, spot.facing.z)))
		end
		depotPlots[p.id] = { model = model, origin = origin, parking = parking, signPart = sign, plotId = p.id }
	end
	local hub = layout.hub
	return {
		cityFolder = cityFolder,
		pickupFolder = pickupFolder,
		destinationFolder = destinationFolder,
		depotFolder = depotFolder,
		runtime = runtime,
		businesses = businesses,
		destinations = destinations,
		depotPlots = depotPlots,
		hubSpawn = CFrame.lookAlong(v3(hub.spawn.x, 3, hub.spawn.z), v3(hub.spawn.facing.x, 0, hub.spawn.facing.z)),
		vehiclePads = {},
	}
end

-------------------------------------------------------------------------------
-- Stub services
-------------------------------------------------------------------------------

-- PlayerDataService stub: real in-memory profiles built from the real DEFAULT_PROFILE.
local function makePlayerData(Signal, TableUtil, defaultProfile)
	local svc = { profiles = {}, updates = 0, failAddCash = false, cashLog = {} }
	svc.ProfileLoaded = Signal.new()
	svc.ProfileUnloading = Signal.new()
	function svc.Init() end
	function svc.Start() end
	function svc.GetProfile(player)
		return svc.profiles[player]
	end
	function svc.Update(player, mutator)
		local profile = svc.profiles[player]
		if not profile then
			return false
		end
		mutator(profile)
		svc.updates += 1
		return true
	end
	function svc.AddCash(player, amount, reason)
		if svc.failAddCash then
			return false
		end
		local rounded = math.floor(amount + 0.5)
		if rounded < 0 then
			return false
		end
		table.insert(svc.cashLog, { amount = rounded, reason = reason })
		return svc.Update(player, function(profile)
			profile.cash += rounded
		end)
	end
	function svc.TrySpendCash(player, amount, reason)
		local profile = svc.profiles[player]
		local rounded = math.floor(amount + 0.5)
		if not profile or profile.cash < rounded then
			return false
		end
		profile.cash -= rounded
		svc.updates += 1
		return true
	end
	function svc.AddReputation(player, amount)
		return svc.Update(player, function(profile)
			profile.reputation += math.floor(amount + 0.5)
		end)
	end
	function svc.GetPublicProfile(player)
		local profile = svc.profiles[player]
		return profile and TableUtil.deepCopy(profile) or nil
	end
	function svc.IsSaveable()
		return true
	end
	local function overlay(target, overrides)
		for key, value in pairs(overrides) do
			if type(value) == "table" and type(target[key]) == "table" and #value == 0 then
				overlay(target[key], value)
			else
				target[key] = TableUtil.deepCopy(value)
			end
		end
	end
	-- Builds a profile (defaults + overrides) and fires ProfileLoaded like the real service.
	function svc.load(player, overrides)
		local profile = TableUtil.deepCopy(defaultProfile)
		if overrides then
			overlay(profile, overrides)
		end
		svc.profiles[player] = profile
		svc.ProfileLoaded:Fire(player, profile)
		return profile
	end
	return svc
end

-- OrderService stub: enough of 5.5 for contract offers (CreateOrder/InjectOrders/Accept/Cancel/...).
local function makeOrderService(Signal, OrderDefinitions, getCtx)
	local svc = { created = {}, cancels = {}, available = {}, active = {}, byId = {}, nextId = 0 }
	svc.OrderAccepted = Signal.new()
	svc.OrderReady = Signal.new()
	svc.OrderCollected = Signal.new()
	svc.OrderDelivered = Signal.new()
	svc.OrderRemoved = Signal.new()
	function svc.Init() end
	function svc.Start() end
	local function lists(player)
		svc.available[player] = svc.available[player] or {}
		svc.active[player] = svc.active[player] or {}
		return svc.available[player], svc.active[player]
	end
	local function removeFrom(list, order)
		for index, item in ipairs(list) do
			if item == order then
				table.remove(list, index)
				return true
			end
		end
		return false
	end
	function svc.CreateOrder(player, spec)
		svc.nextId += 1
		local size = spec.size or "Small"
		local units = OrderDefinitions.unitsFor(size)
		local now = os.clock()
		local order = {
			id = string.format("o%03d", svc.nextId),
			userId = player.UserId,
			businessId = spec.businessId,
			destinationId = spec.destinationId,
			itemCategory = spec.itemCategory or "Pizza",
			size = size,
			sizeUnits = units,
			packageKey = "PizzaBox",
			itemLabel = "Test order",
			basePay = spec.basePayOverride or (40 * units),
			tipMax = 12,
			repReward = 6,
			timeLimit = spec.timeLimit,
			availableUntil = now + (spec.availableFor or 150),
			prepTime = spec.prepTimeOverride or 0,
			routeDistance = 100,
			createdAt = now,
			state = "Available",
			contractId = spec.contractId,
			isTutorial = spec.isTutorial,
			rewardGranted = false,
		}
		table.insert(svc.created, { player = player, spec = spec, order = order })
		return order
	end
	function svc.InjectOrders(player, orders)
		local available = lists(player)
		for _, order in ipairs(orders) do
			order.state = "Available"
			order.userId = player.UserId
			if not svc.byId[order.id] then
				svc.byId[order.id] = order
				table.insert(available, order)
			end
		end
	end
	function svc.GetAvailable(player)
		local available = lists(player)
		return table.clone(available)
	end
	function svc.GetActive(player)
		local _, active = lists(player)
		return table.clone(active)
	end
	function svc.GetOrder(orderId)
		return svc.byId[orderId]
	end
	function svc.GetCapacityInfo(player)
		local ctx = getCtx()
		local profile = ctx.services.PlayerDataService.GetProfile(player)
		local max = profile and ctx.services.ProgressionService.GetMaxCapacity(profile) or 1
		local _, active = lists(player)
		local load, committed = 0, 0
		for _, order in ipairs(active) do
			committed += order.sizeUnits
			if order.state == "Collected" then
				load += order.sizeUnits
			end
		end
		return { current = max, max = max, load = load, committed = committed }
	end
	function svc.Accept(player, orderId)
		local available, active = lists(player)
		local order = svc.byId[orderId]
		if not order or order.userId ~= player.UserId then
			return { ok = false, error = "NotFound", message = "no order" }
		end
		if order.state ~= "Available" then
			return { ok = false, error = "WrongState", message = "not available" }
		end
		local capacity = svc.GetCapacityInfo(player)
		if capacity.committed + order.sizeUnits > capacity.max then
			return { ok = false, error = "NoCapacity", message = "too much" }
		end
		removeFrom(available, order)
		order.state = "Accepted"
		order.acceptedAt = os.clock()
		order.readyAt = order.acceptedAt
		table.insert(active, order)
		svc.OrderAccepted:Fire(player, order)
		return { ok = true, order = order }
	end
	function svc.Cancel(player, orderId, opts)
		opts = opts or {}
		local available, active = lists(player)
		local order = svc.byId[orderId]
		if not order or order.userId ~= player.UserId then
			return { ok = false, error = "NotFound", message = "no order" }
		end
		table.insert(svc.cancels, { id = orderId, opts = opts, stateBefore = order.state })
		order.state = "Cancelled"
		svc.byId[orderId] = nil
		removeFrom(available, order)
		removeFrom(active, order)
		svc.OrderRemoved:Fire(player, order, opts.reason or "Cancelled")
		return { ok = true }
	end
	-- Test helpers (not part of the contract): collect / deliver an active order.
	function svc.collect(player, orderId)
		local order = svc.byId[orderId]
		order.state = "Collected"
		order.collectedAt = os.clock()
		svc.OrderCollected:Fire(player, order)
	end
	function svc.deliver(player, orderId)
		local _, active = lists(player)
		local order = svc.byId[orderId]
		order.state = "Delivered"
		order.deliveredAt = os.clock()
		svc.byId[orderId] = nil
		removeFrom(active, order)
		local payout = { base = order.basePay, tip = 0, total = order.basePay, rep = order.repReward, lateSeconds = 0, timelinessFactor = 1 }
		svc.OrderDelivered:Fire(player, order, payout)
		return order
	end
	return svc
end

local function makeVehicleService()
	local svc = { positions = {} }
	function svc.Init() end
	function svc.Start() end
	function svc.GetPlayerPosition(player)
		return svc.positions[player] or v3(0, 0, 0)
	end
	function svc.IsDriving()
		return false
	end
	function svc.GetVehicle()
		return nil
	end
	return svc
end

local function makeRewardService()
	local svc = { bonuses = {} }
	function svc.Init() end
	function svc.Start() end
	function svc.GrantContractBonus(player, contractId, orders)
		table.insert(svc.bonuses, { player = player, contractId = contractId, orders = table.clone(orders) })
		return 123
	end
	return svc
end

local function makeProgressionStub(ContractDefinitions, DepotDefinitions, BusinessDefinitions, VehicleDefinitions)
	local svc = {}
	function svc.Init() end
	function svc.Start() end
	function svc.IsBusinessUnlocked(profile, id)
		local def = BusinessDefinitions.get(id)
		return def ~= nil and profile.reputation >= def.repRequired
	end
	function svc.GetMaxCapacity(profile)
		local best = 1
		for id, owned in pairs(profile.ownedVehicles) do
			local def = owned and VehicleDefinitions.get(id)
			if def then
				best = math.max(best, def.baseCapacity)
			end
		end
		return best
	end
	function svc.IsContractUnlocked(profile, id)
		local def = ContractDefinitions.All[id]
		if not def then
			return false, "NotFound"
		end
		if not profile.tutorial.completed or profile.reputation < def.requirements.reputation or profile.stats.deliveries < def.requirements.deliveries then
			return false, "Requirements"
		end
		return true
	end
	function svc.CanPurchaseDepot(profile)
		if profile.depot.owned then
			return false, "AlreadyOwned"
		elseif profile.reputation < DepotDefinitions.repRequired then
			return false, "Requirements"
		elseif profile.cash < DepotDefinitions.price then
			return false, "Insufficient"
		end
		return true
	end
	function svc.GetUnlockedDriverCategories(profile)
		local result = {}
		for _, id in ipairs(DepotDefinitions.CategoryOrder) do
			if profile.reputation >= DepotDefinitions.Categories[id].repRequired then
				table.insert(result, id)
			end
		end
		return result
	end
	return svc
end

-- Recording wrapper around DepotBuilder (delegates to the real builder when it is in the bundle).
local function makeBuilder(real)
	local wrapper = { calls = { apply = {}, clear = {}, setVanPresent = {} } }
	function wrapper.apply(plot, profile, ownerName, ownerUserId)
		table.insert(wrapper.calls.apply, { plotId = plot.plotId, ownerName = ownerName })
		if real and real.apply then
			real.apply(plot, profile, ownerName, ownerUserId)
		end
	end
	function wrapper.clear(plot)
		table.insert(wrapper.calls.clear, { plotId = plot.plotId })
		if real and real.clear then
			real.clear(plot)
		end
	end
	function wrapper.setVanPresent(plot, slot, present)
		table.insert(wrapper.calls.setVanPresent, { plotId = plot.plotId, slot = slot, present = present })
		if real and real.setVanPresent then
			real.setVanPresent(plot, slot, present)
		end
	end
	return wrapper
end

-------------------------------------------------------------------------------
-- Environment
-------------------------------------------------------------------------------

local INIT_ORDER = { "PlayerDataService", "ProgressionService", "VehicleService", "RewardService", "OrderService", "ContractService", "DriverService", "DepotService" }

local function buildEnv()
	shim.reset()
	shim.setContext("server")
	local Shared = ReplicatedStorageRef:WaitForChild("Shared")
	local Signal = require(Shared.Util.Signal)
	local Remotes = require(Shared.Util.Remotes)
	local TableUtil = require(Shared.Util.TableUtil)
	local OrderDefinitions = require(Shared.Definitions.OrderDefinitions)
	local ContractDefinitions = require(Shared.Definitions.ContractDefinitions)
	local DepotDefinitions = require(Shared.Definitions.DepotDefinitions)
	local BusinessDefinitions = require(Shared.Definitions.BusinessDefinitions)
	local VehicleDefinitions = require(Shared.Definitions.VehicleDefinitions)
	local root = game:GetService("ServerScriptService"):WaitForChild("DeliveryDash")
	local servicesFolder = root:WaitForChild("Services")
	local buildersFolder = root:FindFirstChild("Builders")

	Remotes.createAll()
	local world = buildWorld(LAYOUT)
	local ctx = { services = {}, remotes = Remotes, layout = LAYOUT, graph = nil, world = world, isStudio = false, builders = {} }

	local realBuilderModule = buildersFolder and buildersFolder:FindFirstChild("DepotBuilder")
	local realBuilder = nil
	if realBuilderModule then
		local okRequire, result = pcall(require, realBuilderModule)
		if okRequire then
			realBuilder = result
		end
	end
	local builder = makeBuilder(realBuilder)
	ctx.builders.DepotBuilder = builder

	local defaultProfile = require(servicesFolder:WaitForChild("PlayerDataService")).DEFAULT_PROFILE
	local data = makePlayerData(Signal, TableUtil, defaultProfile)
	local orders = makeOrderService(Signal, OrderDefinitions, function()
		return ctx
	end)
	local vehicles = makeVehicleService()
	local rewards = makeRewardService()
	local progressionModule = servicesFolder:FindFirstChild("ProgressionService")
	local progression = if progressionModule then require(progressionModule) else makeProgressionStub(ContractDefinitions, DepotDefinitions, BusinessDefinitions, VehicleDefinitions)

	ctx.services.PlayerDataService = data
	ctx.services.ProgressionService = progression
	ctx.services.VehicleService = vehicles
	ctx.services.RewardService = rewards
	ctx.services.OrderService = orders
	ctx.services.ContractService = require(servicesFolder:WaitForChild("ContractService"))
	ctx.services.DriverService = require(servicesFolder:WaitForChild("DriverService"))
	ctx.services.DepotService = require(servicesFolder:WaitForChild("DepotService"))
	for _, name in ipairs(INIT_ORDER) do
		ctx.services[name].Init(ctx)
	end
	for _, name in ipairs(INIT_ORDER) do
		ctx.services[name].Start()
	end
	return {
		ctx = ctx,
		services = ctx.services,
		world = world,
		data = data,
		orders = orders,
		vehicles = vehicles,
		rewards = rewards,
		builder = builder,
		contracts = ctx.services.ContractService,
		depot = ctx.services.DepotService,
		drivers = ctx.services.DriverService,
		def = ContractDefinitions.LunchRush,
		DepotDefinitions = DepotDefinitions,
	}
end

-- Adds a player with a character and a loaded profile (defaults + overrides), then settles deferred work.
local function joinPlayer(env, name, userId, overrides)
	local player = shim.addPlayer(name, userId)
	shim.spawnCharacter(player)
	env.data.load(player, overrides)
	shim.step()
	return player
end

-- Payloads of every RemoteEvent `name` fired to `player` (FireClient) or to everyone (FireAllClients).
local function eventsFor(name, player)
	local result = {}
	for _, entry in ipairs(shim.remoteLog) do
		if entry.remote and entry.remote.Name == name then
			if entry.kind == "FireClient" and entry.player == player then
				table.insert(result, entry.args[1])
			elseif entry.kind == "FireAllClients" and player == nil then
				table.insert(result, entry.args[1])
			end
		end
	end
	return result
end

local function clearRemoteLog()
	table.clear(shim.remoteLog)
end

local ELIGIBLE_VAN = {
	tutorial = { completed = true, step = 9 },
	reputation = 100,
	stats = { deliveries = 10 },
	ownedVehicles = { Bicycle = true, Van = true },
}

local ELIGIBLE_BIKE = {
	tutorial = { completed = true, step = 9 },
	reputation = 100,
	stats = { deliveries = 10 },
}

local function ids(orders)
	local result = {}
	for _, order in ipairs(orders) do
		table.insert(result, order.id)
	end
	return result
end

-------------------------------------------------------------------------------
-- ContractService
-------------------------------------------------------------------------------

describe("ContractService", function()
	local env
	beforeEach(function()
		env = buildEnv()
	end)

	it("opens on schedule and offers compatible orders only to eligible players", function()
		local alice = joinPlayer(env, "Alice", 101, ELIGIBLE_VAN)
		local bob = joinPlayer(env, "Bob", 102, nil) -- fresh profile: not eligible
		local initial = env.contracts.GetStateFor(alice)
		expect(initial.status).toBe("Idle")
		expect(initial.nextAt).toBeCloseTo(1000 + env.contracts.INITIAL_DELAY, 0.01)
		expect(initial.eligible).toBe(true)
		expect(env.contracts.GetStateFor(bob).eligible).toBe(false)
		expect(env.contracts.GetStateFor(bob).eligibilityReason).toBe("Requirements")

		clearRemoteLog()
		shim.advance(env.contracts.INITIAL_DELAY - 1, 0.5)
		expect(env.contracts.GetCycle().status).toBe("Idle")
		shim.advance(2.5, 0.5)
		local cycle = env.contracts.GetCycle()
		expect(cycle.status).toBe("Open")
		expect(cycle.neighborhood).toBe("Downtown")
		expect(cycle.closesAt - cycle.opensAt).toBe(env.def.window)
		expect(cycle.graceEndsAt - cycle.closesAt).toBe(env.def.grace)

		local state = env.contracts.GetStateFor(alice)
		expect(state.id).toBe(cycle.id)
		expect(state.status).toBe("Open")
		expect(#state.offers).toBe(env.def.offerCount)
		local seenDestinations = {}
		for _, order in ipairs(state.offers) do
			expect(order.contractId).toBe(cycle.id)
			expect(order.state).toBe("Available")
			expect(seenDestinations[order.destinationId]).toBeNil()
			seenDestinations[order.destinationId] = true
			expect(order.size == "Small" or order.size == "Medium").toBe(true)
			expect(order.businessId == "SliceStreetPizza" or order.businessId == "BeanAndBunCafe").toBe(true)
			expect(order.timeLimit).toBeCloseTo(cycle.graceEndsAt - order.createdAt, 0.01)
			expect(order.availableUntil).toBeCloseTo(cycle.closesAt, 0.01)
		end
		-- Offers are on Alice's board as Available (not accepted).
		expect(#env.orders.GetAvailable(alice)).toBe(env.def.offerCount)
		expect(#env.orders.GetActive(alice)).toBe(0)
		-- Bob got nothing.
		expect(env.contracts.GetStateFor(bob).offers).toBeNil()
		expect(#env.orders.GetAvailable(bob)).toBe(0)
		for _, created in ipairs(env.orders.created) do
			expect(created.player).toBe(alice)
		end
		-- Personalised pushes on open.
		expect(#eventsFor("ContractUpdated", alice)).toBeGreaterThan(0)
		local last = eventsFor("ContractUpdated", alice)
		expect(#last[#last].offers).toBe(env.def.offerCount)
		expect(last[#last].serverTime).toBeA("number")
		expect(#eventsFor("ContractUpdated", bob)).toBeGreaterThan(0)
		expect(last[#last].joined).toBeNil()
	end)

	it("cancels non-joined offers when the window closes and rotates the neighbourhood", function()
		local alice = joinPlayer(env, "Alice", 101, ELIGIBLE_VAN)
		env.contracts.ForceOpen()
		local first = env.contracts.GetCycle()
		expect(first.neighborhood).toBe("Downtown")
		expect(#env.orders.GetAvailable(alice)).toBe(5)

		shim.advance(env.def.window + 1, 1)
		expect(env.contracts.GetCycle().status).toBe("Grace")
		expect(#env.orders.cancels).toBe(5)
		for _, cancel in ipairs(env.orders.cancels) do
			expect(cancel.opts.silent).toBe(true)
			expect(cancel.opts.noPenalty).toBe(true)
			expect(cancel.opts.reason).toBe("ContractClosed")
			expect(cancel.stateBefore).toBe("Available")
		end
		expect(#env.orders.GetAvailable(alice)).toBe(0)
		expect(env.contracts.GetStateFor(alice).offers).toBeNil()

		shim.advance(env.def.grace + 1, 1)
		local idle = env.contracts.GetCycle()
		expect(idle.status).toBe("Idle")
		expect(idle.id).toBeNil()
		expect(idle.nextAt).toBeCloseTo(os.clock() + env.def.cooldown, 3) -- ended on a 1 s tick

		shim.advance(env.def.cooldown + 1, 1)
		local second = env.contracts.GetCycle()
		expect(second.status).toBe("Open")
		expect(second.neighborhood).toBe("Residential")
		expect(second.id).never.toBe(first.id)
		-- Residential offers come from SliceStreetPizza only: FreshLaneMarket needs 120 rep (Alice has 100).
		local offers = env.contracts.GetStateFor(alice).offers
		expect(#offers).toBe(5)
		for _, order in ipairs(offers) do
			expect(order.businessId).toBe("SliceStreetPizza")
			expect(string.sub(order.destinationId, 1, 1)).toBe("R")
		end
	end)

	it("offers only pair a destination with a business whose delivery profile serves it", function()
		-- Tycoon: everything unlocked (FreshLaneMarket 120 rep, CrateAndCoSupply 500 rep), Van capacity.
		local tycoon = joinPlayer(env, "Tycoon", 104, { tutorial = { completed = true, step = 9 }, reputation = 1000, stats = { deliveries = 50 }, ownedVehicles = { Bicycle = true, Van = true } })
		env.contracts.ForceOpen("Industrial")
		expect(env.contracts.GetCycle().neighborhood).toBe("Industrial")
		local offers = env.contracts.GetStateFor(tycoon).offers
		expect(offers).toBeTruthy()
		-- I4 (House) has no serving business: FreshLaneMarket serves houses but not Industrial, and
		-- CrateAndCoSupply serves Industrial but only LoadingBay/Warehouse/Shop. So 3 offers, not 4.
		expect(#offers).toBe(3)
		local seen = {}
		for _, order in ipairs(offers) do
			expect(order.businessId).toBe("CrateAndCoSupply")
			seen[order.destinationId] = true
			if order.destinationId ~= "I3" then
				expect(order.size).toBe("Medium") -- loading bays never take Small
			end
		end
		expect(seen.I4).toBeNil()
		expect(seen.I1 and seen.I2 and seen.I3).toBe(true)

		-- Residential rush for the same player: FreshLaneMarket and SliceStreetPizza both serve houses.
		shim.advance(env.def.window + env.def.grace + 2, 1)
		env.contracts.ForceOpen("Residential")
		local residential = env.contracts.GetStateFor(tycoon).offers
		expect(#residential).toBe(5)
		for _, order in ipairs(residential) do
			expect(order.businessId == "SliceStreetPizza" or order.businessId == "FreshLaneMarket").toBe(true)
			expect(string.sub(order.destinationId, 1, 1)).toBe("R")
		end
	end)

	it("Join accepts through OrderService with viaContract and an accepted offer leaves the offer list", function()
		local alice = joinPlayer(env, "Alice", 101, ELIGIBLE_VAN)
		local acceptOpts = {}
		local realAccept = env.orders.Accept
		env.orders.Accept = function(player, orderId, opts)
			table.insert(acceptOpts, opts)
			return realAccept(player, orderId, opts)
		end
		env.contracts.ForceOpen()
		local cycle = env.contracts.GetCycle()
		local offerIds = ids(env.contracts.GetStateFor(alice).offers)
		expect(env.contracts.Join(alice, cycle.id, { offerIds[1], offerIds[2] }).ok).toBe(true)
		expect(#acceptOpts).toBe(2)
		for _, opts in ipairs(acceptOpts) do
			expect(opts.viaContract).toBe(true)
		end
		expect(#env.contracts.GetStateFor(alice).offers).toBe(3)

		-- Defensive: an offer accepted by any other path (the stub does not gate) is dropped from the
		-- offers so GetStateFor never advertises a non-Available order.
		local bob = joinPlayer(env, "Bob", 105, ELIGIBLE_VAN)
		local bobOffers = ids(env.contracts.GetStateFor(bob).offers)
		expect(#bobOffers).toBe(5)
		expect(realAccept(bob, bobOffers[1]).ok).toBe(true)
		shim.step()
		local remaining = env.contracts.GetStateFor(bob).offers
		expect(#remaining).toBe(4)
		for _, order in ipairs(remaining) do
			expect(order.id).never.toBe(bobOffers[1])
			expect(order.state).toBe("Available")
		end
	end)

	it("Join validates batch size, ownership, duplicates, capacity and state", function()
		local alice = joinPlayer(env, "Alice", 101, ELIGIBLE_VAN)
		local bike = joinPlayer(env, "Bikey", 103, ELIGIBLE_BIKE)
		local bob = joinPlayer(env, "Bob", 102, nil)
		expect(env.contracts.Join(alice, "LunchRush", {}).error).toBe("WrongState")
		env.contracts.ForceOpen()
		local cycle = env.contracts.GetCycle()
		local offers = env.contracts.GetStateFor(alice).offers
		local offerIds = ids(offers)
		local bikeOffers = ids(env.contracts.GetStateFor(bike).offers)

		expect(env.contracts.Join(bob, cycle.id, { offerIds[1], offerIds[2] }).error).toBe("Requirements")
		expect(env.contracts.Join(alice, "LunchRush-999", { offerIds[1], offerIds[2] }).error).toBe("NotFound")
		expect(env.contracts.Join(alice, cycle.id, { offerIds[1] }).error).toBe("Invalid")
		expect(env.contracts.Join(alice, cycle.id, offerIds).error).toBe("Invalid") -- 5 > maxBatch
		expect(env.contracts.Join(alice, cycle.id, { offerIds[1], offerIds[1] }).error).toBe("Invalid")
		expect(env.contracts.Join(alice, cycle.id, { offerIds[1], "nope" }).error).toBe("NotFound")
		expect(env.contracts.Join(alice, cycle.id, { offerIds[1], bikeOffers[1] }).error).toBe("NotFound")
		-- Bicycle only: max capacity 1, any two orders exceed it.
		local bikeResult = env.contracts.Join(bike, cycle.id, { bikeOffers[1], bikeOffers[2] })
		expect(bikeResult.error).toBe("NoCapacity")
		expect(#env.orders.GetActive(bike)).toBe(0)
		expect(#env.orders.GetAvailable(bike)).toBe(5)
		-- Nothing was accepted by the failed attempts.
		expect(#env.orders.GetActive(alice)).toBe(0)

		clearRemoteLog()
		local result = env.contracts.Join(alice, cycle.id, { offerIds[1], offerIds[2], offerIds[3] })
		expect(result.ok).toBe(true)
		expect(#result.orders).toBe(3)
		expect(result.joined.required).toBe(3)
		expect(result.joined.done).toBe(0)
		expect(result.joined.deadline).toBeCloseTo(cycle.graceEndsAt, 0.01)
		expect(#env.orders.GetActive(alice)).toBe(3)
		for _, order in ipairs(env.orders.GetActive(alice)) do
			expect(order.state).toBe("Accepted")
		end
		local state = env.contracts.GetStateFor(alice)
		expect(#state.offers).toBe(2)
		expect(state.joined.orderIds).toEqual({ offerIds[1], offerIds[2], offerIds[3] })
		expect(env.contracts.Join(alice, cycle.id, { offerIds[4], offerIds[5] }).error).toBe("WrongState")
		shim.step()
		expect(#eventsFor("ContractUpdated", alice)).toBe(1)
		expect(eventsFor("ContractUpdated", alice)[1].joined.required).toBe(3)
		-- The definition id is accepted as an alias of the current rush id.
		local carol = joinPlayer(env, "Carol", 104, ELIGIBLE_VAN)
		local carolIds = ids(env.contracts.GetStateFor(carol).offers)
		expect(env.contracts.Join(carol, "LunchRush", { carolIds[1], carolIds[2] }).ok).toBe(true)
	end)

	it("grants the contract bonus exactly once when the batch is delivered before the deadline", function()
		local alice = joinPlayer(env, "Alice", 101, ELIGIBLE_VAN)
		env.contracts.ForceOpen()
		local cycle = env.contracts.GetCycle()
		local offerIds = ids(env.contracts.GetStateFor(alice).offers)
		expect(env.contracts.Join(alice, cycle.id, { offerIds[1], offerIds[2] }).ok).toBe(true)

		env.orders.collect(alice, offerIds[1])
		local first = env.orders.deliver(alice, offerIds[1])
		expect(env.contracts.GetStateFor(alice).joined.done).toBe(1)
		expect(#env.rewards.bonuses).toBe(0)
		-- A non-contract delivery doesn't count.
		local stray = env.orders.CreateOrder(alice, { businessId = "BeanAndBunCafe", destinationId = "D5", size = "Small" })
		env.orders.InjectOrders(alice, { stray })
		env.orders.Accept(alice, stray.id)
		env.orders.deliver(alice, stray.id)
		expect(env.contracts.GetStateFor(alice).joined.done).toBe(1)

		clearRemoteLog()
		shim.advance(60, 1)
		env.orders.collect(alice, offerIds[2])
		env.orders.deliver(alice, offerIds[2])
		expect(#env.rewards.bonuses).toBe(1)
		expect(env.rewards.bonuses[1].player).toBe(alice)
		expect(env.rewards.bonuses[1].contractId).toBe("LunchRush")
		expect(#env.rewards.bonuses[1].orders).toBe(2)
		local joined = env.contracts.GetStateFor(alice).joined
		expect(joined.done).toBe(2)
		expect(joined.completed).toBe(true)
		-- Duplicate delivered signal for the same order never grants twice.
		env.orders.OrderDelivered:Fire(alice, first, { total = 1 })
		expect(#env.rewards.bonuses).toBe(1)
		expect(env.contracts.GetStateFor(alice).joined.done).toBe(2)
		shim.step()
		local notes = eventsFor("Notify", alice)
		local success = false
		for _, note in ipairs(notes) do
			if note.kind == "success" and string.find(note.text, "complete") then
				success = true
			end
		end
		expect(success).toBe(true)
		expect(#eventsFor("ContractUpdated", alice)).toBeGreaterThan(0)
		-- Nothing to cancel at the deadline; the rush ends cleanly without more bonuses.
		shim.advance(env.def.window + env.def.grace + 2, 1)
		expect(env.contracts.GetCycle().status).toBe("Idle")
		expect(#env.rewards.bonuses).toBe(1)
		expect(#env.orders.cancels).toBe(3) -- the three non-joined offers at window close
		expect(env.contracts.GetStateFor(alice).joined).toBeNil()
	end)

	it("cancels uncollected joined orders without penalty at the deadline and keeps collected ones", function()
		local alice = joinPlayer(env, "Alice", 101, ELIGIBLE_VAN)
		env.contracts.ForceOpen()
		local cycle = env.contracts.GetCycle()
		local offerIds = ids(env.contracts.GetStateFor(alice).offers)
		expect(env.contracts.Join(alice, cycle.id, { offerIds[1], offerIds[2], offerIds[3] }).ok).toBe(true)
		env.orders.collect(alice, offerIds[1])

		shim.advance(env.def.window + 1, 1)
		expect(env.contracts.GetCycle().status).toBe("Grace")
		expect(#env.orders.GetActive(alice)).toBe(3) -- joined orders survive the window close
		clearRemoteLog()
		shim.advance(env.def.grace + 1, 1)
		expect(env.contracts.GetCycle().status).toBe("Idle")
		local expired = {}
		for _, cancel in ipairs(env.orders.cancels) do
			if cancel.opts.reason == "ContractExpired" then
				table.insert(expired, cancel)
				expect(cancel.opts.silent).toBe(true)
				expect(cancel.opts.noPenalty).toBe(true)
				expect(cancel.stateBefore).toBe("Accepted")
			end
		end
		expect(#expired).toBe(2)
		local active = env.orders.GetActive(alice)
		expect(#active).toBe(1)
		expect(active[1].id).toBe(offerIds[1])
		expect(active[1].state).toBe("Collected")
		expect(env.contracts.GetStateFor(alice).joined).toBeNil()
		expect(#env.rewards.bonuses).toBe(0)
		local warned = false
		for _, note in ipairs(eventsFor("Notify", alice)) do
			if note.kind == "warning" then
				warned = true
			end
		end
		expect(warned).toBe(true)
		-- Delivering the collected one later pays normally but never the bonus.
		env.orders.deliver(alice, offerIds[1])
		expect(#env.rewards.bonuses).toBe(0)
	end)

	it("finishing the batch after the deadline grants no bonus", function()
		local alice = joinPlayer(env, "Alice", 101, ELIGIBLE_VAN)
		env.contracts.ForceOpen()
		local cycle = env.contracts.GetCycle()
		local offerIds = ids(env.contracts.GetStateFor(alice).offers)
		expect(env.contracts.Join(alice, cycle.id, { offerIds[1], offerIds[2] }).ok).toBe(true)
		env.orders.collect(alice, offerIds[1])
		env.orders.collect(alice, offerIds[2])
		env.orders.deliver(alice, offerIds[1])
		-- Stop the cycle loop so the deadline passes without the rush ending (deliveries still arrive).
		env.contracts.Stop()
		shim.advance(env.def.window + env.def.grace + 5, 1)
		env.orders.deliver(alice, offerIds[2])
		expect(#env.rewards.bonuses).toBe(0)
		local joined = env.contracts.GetStateFor(alice).joined
		expect(joined.done).toBe(2)
		expect(joined.completed).toBe(false)
	end)

	it("sends the current state on profile load, offers to late joiners and cleans up on leave", function()
		env.contracts.ForceOpen()
		local cycle = env.contracts.GetCycle()
		clearRemoteLog()
		local carol = joinPlayer(env, "Carol", 105, ELIGIBLE_VAN)
		local pushes = eventsFor("ContractUpdated", carol)
		expect(#pushes).toBe(1)
		expect(pushes[1].id).toBe(cycle.id)
		expect(pushes[1].status).toBe("Open")
		expect(#pushes[1].offers).toBe(5)
		expect(#env.orders.GetAvailable(carol)).toBe(5)
		-- Ineligible late joiner: state only.
		local dan = joinPlayer(env, "Dan", 106, nil)
		local danPushes = eventsFor("ContractUpdated", dan)
		expect(#danPushes).toBe(1)
		expect(danPushes[1].offers).toBeNil()
		expect(danPushes[1].eligible).toBe(false)
		-- Leaving drops the player's contract state.
		expect(env.contracts.Join(carol, cycle.id, { ids(pushes[1].offers)[1], ids(pushes[1].offers)[2] }).ok).toBe(true)
		shim.removePlayer(carol)
		shim.step()
		local after = env.contracts.GetStateFor(carol)
		expect(after.joined).toBeNil()
		expect(after.offers).toBeNil()
		expect(after.status).toBe("Open")
	end)

	it("GetStateFor has the ContractPublicState shape", function()
		local alice = joinPlayer(env, "Alice", 101, ELIGIBLE_VAN)
		local idle = env.contracts.GetStateFor(alice)
		expect(idle.status).toBe("Idle")
		expect(idle.id).toBeNil()
		expect(idle.neighborhood).toBeNil()
		expect(idle.nextAt).toBeA("number")
		expect(idle.serverTime).toBeA("number")
		expect(idle.offers).toBeNil()
		expect(idle.joined).toBeNil()
		expect(idle.eligible).toBe(true)
		env.contracts.ForceOpen()
		local open = env.contracts.GetStateFor(alice)
		expect(open.id).toBeA("string")
		expect(open.neighborhood).toBe("Downtown")
		expect(open.opensAt).toBeA("number")
		expect(open.closesAt).toBe(open.opensAt + env.def.window)
		expect(open.graceEndsAt).toBe(open.closesAt + env.def.grace)
		expect(open.nextAt).toBe(open.graceEndsAt + env.def.cooldown)
		expect(open.offers).toHaveLength(5)
		expect(#shim.warnings).toBe(0)
	end)
end)

-------------------------------------------------------------------------------
-- DepotService + DriverService
-------------------------------------------------------------------------------

local OWNER = {
	reputation = 1000,
	cash = 0,
	tutorial = { completed = true, step = 9 },
	depot = { owned = true, slotsUnlocked = 1, drivers = { { hired = false, pending = 0 }, { hired = false, pending = 0 } } },
}

local function ownerWith(overrides)
	local Shared = ReplicatedStorageRef:WaitForChild("Shared")
	local TableUtil = require(Shared.Util.TableUtil)
	local result = TableUtil.deepCopy(OWNER)
	for key, value in pairs(overrides or {}) do
		result[key] = value
	end
	return result
end

local function hiredOwner(overrides)
	local profile = ownerWith(overrides)
	profile.depot.drivers[1] = { hired = true, name = "Ava", pending = 0 }
	return profile
end

describe("DepotService", function()
	local env
	beforeEach(function()
		env = buildEnv()
	end)

	it("Purchase enforces requirements, spends, initialises slots and claims a plot", function()
		local alice = joinPlayer(env, "Alice", 101, { reputation = 500, cash = 20000, tutorial = { completed = true, step = 9 } })
		expect(env.depot.Purchase(alice).error).toBe("Requirements")
		local bob = joinPlayer(env, "Bob", 102, { reputation = 1000, cash = 100, tutorial = { completed = true, step = 9 } })
		expect(env.depot.Purchase(bob).error).toBe("Insufficient")
		expect(env.depot.GetStateFor(bob).owned).toBe(false)

		env.data.GetProfile(bob).cash = 12000
		clearRemoteLog()
		local result = env.depot.Purchase(bob)
		expect(result.ok).toBe(true)
		local profile = env.data.GetProfile(bob)
		expect(profile.cash).toBe(0)
		expect(profile.depot.owned).toBe(true)
		expect(profile.depot.slotsUnlocked).toBe(1)
		expect(#profile.depot.drivers).toBe(2)
		expect(profile.depot.drivers[1]).toEqual({ hired = false, pending = 0 })
		expect(result.depot.plotId).toBe("P1")
		expect(env.depot.GetPlotId(bob)).toBe("P1")
		local plotModel = env.world.depotPlots.P1.model
		expect(plotModel:GetAttribute("OwnerUserId")).toBe(102)
		expect(plotModel:GetAttribute("OwnerName")).toBe("Bob")
		expect(#env.builder.calls.apply).toBe(1)
		expect(env.builder.calls.apply[1].plotId).toBe("P1")
		expect(env.depot.Purchase(bob).error).toBe("AlreadyOwned")
		shim.step()
		-- Coalesced: one DepotUpdated for Bob despite several state changes in the same frame.
		expect(#eventsFor("DepotUpdated", bob)).toBe(1)
		local plots = eventsFor("DepotUpdated", bob)[1].publicPlots
		expect(#plots).toBe(2)
		expect(plots[1]).toEqual({ plotId = "P1", ownerName = "Bob", ownerUserId = 102, drivers = 0 })
		expect(plots[2].ownerUserId).toBe(0)

		-- Second owner gets the next plot; leaving releases it.
		env.data.GetProfile(alice).reputation = 1000
		expect(env.depot.Purchase(alice).ok).toBe(true)
		expect(env.depot.GetPlotId(alice)).toBe("P2")
		shim.removePlayer(bob)
		shim.step()
		expect(plotModel:GetAttribute("OwnerUserId")).toBe(0)
		expect(plotModel:GetAttribute("OwnerName")).toBe("")
		expect(#env.builder.calls.clear).toBe(1)
		expect(env.depot.GetPublicPlots()[1].ownerUserId).toBe(0)
		expect(env.depot.GetPublicPlots()[2].ownerName).toBe("Alice")
		expect(#shim.warnings).toBe(0)
	end)

	it("claims a plot for an existing owner on profile load and releases it on leave", function()
		clearRemoteLog()
		local alice = joinPlayer(env, "Alice", 101, hiredOwner())
		expect(env.depot.GetPlotId(alice)).toBe("P1")
		expect(env.world.depotPlots.P1.model:GetAttribute("OwnerUserId")).toBe(101)
		expect(#env.builder.calls.apply).toBe(1)
		local pushes = eventsFor("DepotUpdated", alice)
		expect(#pushes).toBe(1)
		expect(pushes[1].owned).toBe(true)
		expect(pushes[1].plotId).toBe("P1")
		expect(pushes[1].drivers[1].hired).toBe(true)
		-- The real builder (when bundled) builds the hired slot's van under Built/Slot1.
		local built = env.world.depotPlots.P1.model:FindFirstChild("Built")
		expect(built).toBeTruthy()
		shim.removePlayer(alice)
		shim.step()
		expect(env.depot.GetPlotId(alice)).toBeNil()
		expect(env.world.depotPlots.P1.model:GetAttribute("OwnerUserId")).toBe(0)
		expect(#env.builder.calls.clear).toBe(1)
		expect(#shim.warnings).toBe(0)
	end)

	it("equipping a depot cosmetic through ShopService re-applies the depot visuals at once", function()
		local alice = joinPlayer(env, "Alice", 101, hiredOwner({ reputation = 1000 }))
		expect(env.depot.GetPlotId(alice)).toBe("P1")
		expect(#env.builder.calls.apply).toBe(1)
		local servicesFolder = game:GetService("ServerScriptService"):WaitForChild("DeliveryDash"):WaitForChild("Services")
		local Shop = require(servicesFolder:WaitForChild("ShopService"))
		env.ctx.services.ShopService = Shop
		Shop.Init(env.ctx)

		expect(Shop.EquipCosmetic(alice, "DepotSign_Bold").error).toBe("Locked") -- not owned: no rebuild
		expect(#env.builder.calls.apply).toBe(1)
		env.data.Update(alice, function(profile)
			profile.cosmetics.owned.DepotSign_Bold = true
			profile.cosmetics.owned.DepotDecor_Planters = true
		end)
		expect(Shop.EquipCosmetic(alice, "DepotSign_Bold").ok).toBe(true)
		expect(env.data.GetProfile(alice).cosmetics.equipped.DepotSign).toBe("DepotSign_Bold")
		expect(#env.builder.calls.apply).toBe(2)
		expect(env.builder.calls.apply[2].plotId).toBe("P1")
		expect(Shop.EquipCosmetic(alice, "DepotDecor_Planters").ok).toBe(true)
		expect(#env.builder.calls.apply).toBe(3)
		-- The real builder (when bundled) recolours the plot sign with the Bold data.
		local CosmeticDefinitions = require(ReplicatedStorageRef:WaitForChild("Shared").Definitions.CosmeticDefinitions)
		local bold = CosmeticDefinitions.get("DepotSign_Bold").data.color
		local sign = env.world.depotPlots.P1.signPart
		local built = env.world.depotPlots.P1.model:FindFirstChild("Built")
		if built and #built:GetChildren() > 0 then
			expect(sign.Color).toEqual(Color3.fromRGB(bold[1], bold[2], bold[3]))
		end
		-- A player without a plot: EquipCosmetic still succeeds and nothing is rebuilt.
		local bob = joinPlayer(env, "Bob", 102, { reputation = 1000 })
		env.data.Update(bob, function(profile)
			profile.cosmetics.owned.DepotSign_Bold = true
		end)
		expect(Shop.EquipCosmetic(bob, "DepotSign_Bold").ok).toBe(true)
		expect(#env.builder.calls.apply).toBe(3)
		expect(#shim.warnings).toBe(0)
	end)

	it("UnlockSlot and HireDriver charge the documented costs and validate", function()
		local D = env.DepotDefinitions
		local alice = joinPlayer(env, "Alice", 101, ownerWith({ cash = 10000 }))
		local profile = env.data.GetProfile(alice)
		expect(env.depot.HireDriver(alice, 2).error).toBe("Locked")
		expect(env.depot.HireDriver(alice, 3).error).toBe("Invalid")
		expect(env.depot.HireDriver(alice, 1.5).error).toBe("Invalid")

		expect(env.depot.UnlockSlot(alice).ok).toBe(true)
		expect(profile.cash).toBe(10000 - D.slot2Cost)
		expect(profile.depot.slotsUnlocked).toBe(2)
		expect(env.depot.UnlockSlot(alice).error).toBe("AlreadyOwned")

		local hire = env.depot.HireDriver(alice, 1)
		expect(hire.ok).toBe(true)
		expect(profile.cash).toBe(10000 - D.slot2Cost - D.hireCost)
		expect(profile.depot.drivers[1].hired).toBe(true)
		local known = false
		for _, name in ipairs(D.driverNames) do
			if name == profile.depot.drivers[1].name then
				known = true
			end
		end
		expect(known).toBe(true)
		expect(hire.depot.drivers[1].name).toBe(profile.depot.drivers[1].name)
		expect(env.depot.HireDriver(alice, 1).error).toBe("AlreadyOwned")
		expect(env.depot.HireDriver(alice, 2).error).toBe("Insufficient") -- 1500 left
		expect(profile.cash).toBe(1500)
		expect(#env.builder.calls.apply).toBe(2) -- load + hire
		-- Non-owners are locked out.
		local bob = joinPlayer(env, "Bob", 102, { cash = 50000 })
		expect(env.depot.UnlockSlot(bob).error).toBe("Locked")
		expect(env.depot.HireDriver(bob, 1).error).toBe("Locked")
		expect(env.depot.AssignDriver(bob, 1, "DowntownFood").error).toBe("Locked")
		expect(env.depot.Collect(bob).error).toBe("Locked")
	end)

	it("AssignDriver pays the cost up front and creates an assignment with depart visuals", function()
		local D = env.DepotDefinitions
		local alice = joinPlayer(env, "Alice", 101, hiredOwner({ cash = 1000 }))
		local profile = env.data.GetProfile(alice)
		expect(env.depot.AssignDriver(alice, 2, "DowntownFood").error).toBe("Locked") -- slot 2 not unlocked
		expect(env.depot.AssignDriver(alice, 0, "DowntownFood").error).toBe("Invalid")
		env.data.GetProfile(alice).depot.slotsUnlocked = 2
		expect(env.depot.AssignDriver(alice, 2, "DowntownFood").error).toBe("NotFound") -- unlocked but nobody hired
		env.data.GetProfile(alice).depot.slotsUnlocked = 1
		expect(env.depot.AssignDriver(alice, 1, "Nope").error).toBe("NotFound")
		local locked = env.depot.AssignDriver(alice, 1, "ResidentialGrocery")
		expect(locked.error).toBe("Requirements")
		expect(locked.message).toBe("Requires 1,200 Rep")
		expect(profile.cash).toBe(1000)

		clearRemoteLog()
		local result = env.depot.AssignDriver(alice, 1, "DowntownFood")
		expect(result.ok).toBe(true)
		local category = D.Categories.DowntownFood
		expect(profile.cash).toBe(1000 - category.cost)
		local assignment = profile.depot.drivers[1].assignment
		expect(assignment).toBeTruthy()
		expect(assignment.category).toBe("DowntownFood")
		expect(assignment.startedAt).toBe(os.time())
		expect(assignment.endsAt).toBe(os.time() + category.duration)
		expect(assignment.revenue).toBe(category.revenue)
		expect(assignment.cost).toBe(category.cost)
		expect(assignment.net).toBe(category.revenue - category.cost)
		expect(assignment.completed).toBe(false)
		expect(assignment.id).toBeA("string")
		expect(result.depot.drivers[1].assignment.id).toBe(assignment.id)
		local departs = eventsFor("WorldEvent", nil)
		expect(#departs).toBe(1)
		expect(departs[1]).toEqual({ kind = "DriverDepart", plotId = "P1", slot = 1 })
		local vans = env.builder.calls.setVanPresent
		expect(vans[#vans]).toEqual({ plotId = "P1", slot = 1, present = false })
		expect(env.depot.AssignDriver(alice, 1, "DowntownFood").error).toBe("WrongState")
		expect(profile.cash).toBe(1000 - category.cost)
		env.data.GetProfile(alice).cash = 0
		-- Not enough cash for the next operating cost (after completion).
		shim.advance(category.duration + 6, 5)
		expect(env.depot.AssignDriver(alice, 1, "DowntownFood").error).toBe("Insufficient")
		expect(#shim.warnings).toBe(0)
	end)

	it("the driver tick completes due assignments exactly once", function()
		local D = env.DepotDefinitions
		local alice = joinPlayer(env, "Alice", 101, hiredOwner({ cash = 1000 }))
		local profile = env.data.GetProfile(alice)
		expect(env.depot.AssignDriver(alice, 1, "DowntownFood").ok).toBe(true)
		local completions = {}
		env.drivers.AssignmentCompleted:Connect(function(player, slot, assignment)
			table.insert(completions, { player = player, slot = slot, assignment = assignment })
		end)
		shim.step()
		clearRemoteLog()
		shim.advance(D.Categories.DowntownFood.duration - 10, 5)
		expect(profile.depot.drivers[1].assignment.completed).toBe(false)
		expect(profile.depot.drivers[1].pending).toBe(0)
		expect(#completions).toBe(0)
		shim.advance(20, 5)
		expect(profile.depot.drivers[1].assignment.completed).toBe(true)
		expect(profile.depot.drivers[1].pending).toBe(D.Categories.DowntownFood.revenue)
		expect(#completions).toBe(1)
		expect(completions[1].slot).toBe(1)
		expect(completions[1].assignment.id).toBe(profile.depot.drivers[1].assignment.id)
		local returns = eventsFor("WorldEvent", nil)
		expect(#returns).toBe(1)
		expect(returns[1]).toEqual({ kind = "DriverReturn", plotId = "P1", slot = 1 })
		expect(#eventsFor("DepotUpdated", alice)).toBe(1)
		expect(eventsFor("DepotUpdated", alice)[1].pendingTotal).toBe(900)
		-- Later ticks never complete it again.
		shim.advance(60, 5)
		expect(profile.depot.drivers[1].pending).toBe(900)
		expect(#completions).toBe(1)
		expect(env.drivers.Tick()).toBe(0)
		expect(profile.cash).toBe(700) -- cost paid up front, revenue not yet collected
	end)

	it("Collect pays exactly once, requires proximity and survives a failed AddCash", function()
		local alice = joinPlayer(env, "Alice", 101, hiredOwner({ cash = 1000 }))
		local profile = env.data.GetProfile(alice)
		local origin = env.world.depotPlots.P1.origin.Position
		env.vehicles.positions[alice] = origin + v3(20, 0, 10)
		expect(env.depot.Collect(alice).error).toBe("WrongState") -- nothing pending
		expect(env.depot.AssignDriver(alice, 1, "DowntownFood").ok).toBe(true)
		shim.advance(env.DepotDefinitions.Categories.DowntownFood.duration + 6, 5)
		expect(profile.depot.drivers[1].pending).toBe(900)

		env.vehicles.positions[alice] = origin + v3(60, 0, 0)
		expect(env.depot.Collect(alice).error).toBe("TooFar")
		expect(profile.cash).toBe(700)
		expect(profile.depot.drivers[1].pending).toBe(900)
		env.vehicles.positions[alice] = origin + v3(20, 0, 10)
		clearRemoteLog()
		local result = env.depot.Collect(alice)
		expect(result.ok).toBe(true)
		expect(result.collected).toBe(900)
		expect(profile.cash).toBe(1600)
		expect(profile.depot.drivers[1].pending).toBe(0)
		expect(profile.depot.drivers[1].assignment).toBeNil()
		expect(profile.depot.drivers[1].hired).toBe(true)
		expect(profile.stats.totalEarned).toBe(900)
		expect(result.depot.pendingTotal).toBe(0)
		expect(env.depot.Collect(alice).error).toBe("WrongState")
		expect(profile.cash).toBe(1600)
		expect(#env.data.cashLog).toBe(1)

		-- AddCash failure: pending is restored, nothing is lost or doubled.
		profile.depot.drivers[1].pending = 500
		env.data.failAddCash = true
		expect(env.depot.Collect(alice).error).toBe("Internal")
		expect(profile.depot.drivers[1].pending).toBe(500)
		expect(profile.cash).toBe(1600)
		env.data.failAddCash = false
		expect(env.depot.Collect(alice).collected).toBe(500)
		expect(profile.cash).toBe(2100)
		expect(profile.depot.drivers[1].pending).toBe(0)
	end)

	it("reassigning a completed-uncollected driver keeps the pending cash", function()
		local D = env.DepotDefinitions
		local alice = joinPlayer(env, "Alice", 101, hiredOwner({ cash = 1000 }))
		local profile = env.data.GetProfile(alice)
		expect(env.depot.AssignDriver(alice, 1, "DowntownFood").ok).toBe(true)
		shim.advance(D.Categories.DowntownFood.duration + 6, 5)
		expect(profile.depot.drivers[1].pending).toBe(900)
		local firstId = profile.depot.drivers[1].assignment.id

		local result = env.depot.AssignDriver(alice, 1, "DowntownFood")
		expect(result.ok).toBe(true)
		expect(profile.cash).toBe(400)
		expect(profile.depot.drivers[1].pending).toBe(900)
		local assignment = profile.depot.drivers[1].assignment
		expect(assignment.id).never.toBe(firstId)
		expect(assignment.completed).toBe(false)
		expect(assignment.startedAt).toBe(os.time())

		-- A run that finished but was not ticked yet also settles into pending before the new run.
		assignment.endsAt = os.time() - 1
		expect(env.depot.AssignDriver(alice, 1, "DowntownFood").ok).toBe(true)
		expect(profile.cash).toBe(100)
		expect(profile.depot.drivers[1].pending).toBe(1800)
		expect(profile.depot.drivers[1].assignment.completed).toBe(false)
	end)

	it("offline completion on load settles only the already-paid assignment and never requeues", function()
		local now = os.time()
		local profile = hiredOwner({ cash = 0 })
		profile.depot.slotsUnlocked = 2
		profile.depot.drivers[1].assignment = { id = "a1", category = "DowntownFood", startedAt = now - 2000, endsAt = now - 1400, revenue = 900, cost = 300, net = 600, completed = false }
		profile.depot.drivers[2] = {
			hired = true,
			name = "Benji",
			pending = 0,
			assignment = { id = "a2", category = "DowntownFood", startedAt = now - 100, endsAt = now + 500, revenue = 900, cost = 300, net = 600, completed = false },
		}
		clearRemoteLog()
		local alice = joinPlayer(env, "Alice", 101, profile)
		local loaded = env.data.GetProfile(alice)
		expect(loaded.depot.drivers[1].assignment.completed).toBe(true)
		expect(loaded.depot.drivers[1].assignment.id).toBe("a1")
		expect(loaded.depot.drivers[1].pending).toBe(900)
		expect(loaded.depot.drivers[2].assignment.completed).toBe(false)
		expect(loaded.depot.drivers[2].pending).toBe(0)
		expect(loaded.cash).toBe(0)
		local pushes = eventsFor("DepotUpdated", alice)
		expect(#pushes).toBe(1)
		expect(pushes[1].pendingTotal).toBe(900)
		-- Van visuals: slot 1 is back, slot 2 is still out (applied after the plot was claimed).
		local present = {}
		for _, call in ipairs(env.builder.calls.setVanPresent) do
			present[call.slot] = call.present
		end
		expect(present[1]).toBe(true)
		expect(present[2]).toBe(false)
		-- Time passing completes slot 2 once; slot 1 is never completed again.
		shim.advance(600, 5)
		expect(loaded.depot.drivers[1].pending).toBe(900)
		expect(loaded.depot.drivers[2].assignment.completed).toBe(true)
		expect(loaded.depot.drivers[2].pending).toBe(900)
		expect(#shim.warnings).toBe(0)
	end)

	it("pure simulation helpers behave", function()
		local D = env.DepotDefinitions
		local assignment = env.drivers.CreateAssignment("IndustrialParcel", 5000)
		expect(assignment.startedAt).toBe(5000)
		expect(assignment.endsAt).toBe(5000 + D.Categories.IndustrialParcel.duration)
		expect(assignment.net).toBe(1200)
		expect(function()
			env.drivers.CreateAssignment("Nope", 5000)
		end).toThrow()
		local slot = { hired = true, pending = 10, assignment = assignment }
		expect(env.drivers.Complete(slot, 5000 + 100)).toBe(false)
		expect(env.drivers.Complete(slot, assignment.endsAt)).toBe(true)
		expect(slot.pending).toBe(10 + 1900)
		expect(env.drivers.Complete(slot, assignment.endsAt + 50)).toBe(false)
		expect(slot.pending).toBe(1910)
		local profile = { depot = { owned = true, drivers = { slot, { hired = false, pending = 0 }, { hired = true, pending = 0, assignment = env.drivers.CreateAssignment("DowntownFood", 10) } } } }
		expect(env.drivers.CompleteDue(profile, 10 + 600)).toBe(1)
		expect(env.drivers.CompleteDue(profile, 10 + 600)).toBe(0)
		expect(profile.depot.drivers[3].pending).toBe(900)
	end)

	it("GetStateFor has the DepotPublicState shape", function()
		local alice = joinPlayer(env, "Alice", 101, hiredOwner({ cash = 0 }))
		local state = env.depot.GetStateFor(alice)
		expect(state.owned).toBe(true)
		expect(state.plotId).toBe("P1")
		expect(state.slotsUnlocked).toBe(1)
		expect(#state.drivers).toBe(2)
		expect(state.drivers[1].hired).toBe(true)
		expect(state.drivers[1].name).toBe("Ava")
		expect(state.pendingTotal).toBe(0)
		expect(state.serverTime).toBeA("number")
		expect(#state.categories).toBe(3)
		local food, grocery, parcel = state.categories[1], state.categories[2], state.categories[3]
		expect(food.id).toBe("DowntownFood")
		expect(food.unlocked).toBe(true)
		expect(food.requirement).toBeNil()
		expect(food.duration).toBe(600)
		expect(food.revenue).toBe(900)
		expect(food.cost).toBe(300)
		expect(food.net).toBe(600)
		expect(food.name).toBe("Downtown Food Run")
		expect(grocery.unlocked).toBe(false)
		expect(grocery.requirement).toBe("Requires 1,200 Rep")
		expect(parcel.requirement).toBe("Requires 1,500 Rep")
		expect(#state.publicPlots).toBe(2)
		expect(state.publicPlots[1]).toEqual({ plotId = "P1", ownerName = "Alice", ownerUserId = 101, drivers = 1 })
		-- The state copies profile data: mutating it never touches the profile.
		state.drivers[1].pending = 999
		expect(env.data.GetProfile(alice).depot.drivers[1].pending).toBe(0)
		-- Non-owner shape.
		local bob = joinPlayer(env, "Bob", 102, nil)
		local none = env.depot.GetStateFor(bob)
		expect(none.owned).toBe(false)
		expect(none.plotId).toBeNil()
		expect(none.slotsUnlocked).toBe(0)
		expect(none.drivers).toEqual({})
		expect(none.pendingTotal).toBe(0)
		expect(none.categories[1].unlocked).toBe(false)
		expect(none.categories[1].requirement).toBe("Requires 1,000 Rep")
	end)
end)
