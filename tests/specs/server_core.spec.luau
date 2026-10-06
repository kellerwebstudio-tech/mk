--!nonstrict
-- tests/specs/server_core.spec.luau
-- Offline specs for the core server services (PlayerData, Progression, AntiCheat, Vehicle, Reward,
-- Order, Tutorial, Shop, Interaction). Everything needed (mini layout, world, CityService stub,
-- fallback builders) lives in this file; the harness bundles src/ into the virtual DataModel.

shim.setContext("server")

local STORE = "DDC_Profiles_v1"

-------------------------------------------------------------------------------
-- Mini city: four roads in a cross + one alley, two businesses, four destinations
-------------------------------------------------------------------------------

local LAYOUT = {
	name = "TestCity",
	bounds = { minX = -400, maxX = 400, minZ = -400, maxZ = 400 },
	groundY = 0,
	killY = -60,
	neighborhoods = {
		{ id = "Downtown", name = "Downtown", center = { x = 0, z = -50 }, bounds = { minX = -400, maxX = 400, minZ = -400, maxZ = 100 }, accent = { r = 1, g = 0.5, b = 0.2 } },
		{ id = "Residential", name = "Maple Hill", center = { x = 0, z = 250 }, bounds = { minX = -400, maxX = 400, minZ = 100, maxZ = 400 }, accent = { r = 0.4, g = 0.8, b = 0.4 } },
	},
	roads = {
		{ id = "Main", name = "Main Street", kind = "Road", width = 12, points = { { x = -300, z = 0 }, { x = 300, z = 0 } } },
		{ id = "North", name = "North Avenue", kind = "Street", width = 8, points = { { x = 0, z = 0 }, { x = 0, z = -300 } } },
		{ id = "South", name = "South Road", kind = "Road", width = 12, points = { { x = 0, z = 0 }, { x = 0, z = 300 } } },
		{ id = "Alley", name = "Back Alley", kind = "Alley", width = 5, points = { { x = -100, z = 0 }, { x = -100, z = -200 } } },
	},
	water = {},
	bridges = {},
	buildings = {},
	businesses = {
		{ id = "SliceStreetPizza", neighborhood = "Downtown", door = { x = -20, z = -14 }, facing = { x = 0, z = 1 }, pickupPoint = { x = -20, z = -9 }, arrivalPoint = { x = -20, z = -5 } },
		{ id = "BeanAndBunCafe", neighborhood = "Downtown", door = { x = 60, z = 14 }, facing = { x = 0, z = -1 }, pickupPoint = { x = 60, z = 9 }, arrivalPoint = { x = 60, z = 5 } },
	},
	destinations = {
		{ id = "D_Near", address = "1 Main Street", neighborhood = "Downtown", kind = "Apartment", door = { x = 120, z = -12 }, facing = { x = 0, z = 1 }, arrivalPoint = { x = 120, z = -5 } },
		{ id = "D_Mid", address = "2 North Avenue", neighborhood = "Downtown", kind = "House", door = { x = 12, z = -180 }, facing = { x = -1, z = 0 }, arrivalPoint = { x = 5, z = -180 } },
		{ id = "D_Far", address = "3 South Road", neighborhood = "Residential", kind = "House", door = { x = 12, z = 260 }, facing = { x = -1, z = 0 }, arrivalPoint = { x = 5, z = 260 } },
		{ id = "D_Alley", address = "4 Back Alley", neighborhood = "Downtown", kind = "Apartment", door = { x = -112, z = -150 }, facing = { x = 1, z = 0 }, arrivalPoint = { x = -105, z = -150 } },
	},
	landmarks = {},
	hub = { spawn = { x = 0, z = 30, facing = { x = 0, z = -1 } }, vehiclePads = { { x = 10, z = 30, facing = { x = 0, z = -1 } } }, kiosk = { x = 0, z = 40 } },
	depotPlots = {},
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

local function anchoredPart(name, position, parent)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = v3(4, 1, 4)
	part.Anchored = true
	part.CFrame = CFrame.new(position)
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
		local pad = anchoredPart("PickupPad", v3(b.pickupPoint.x, 0.5, b.pickupPoint.z), model)
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
		local door = anchoredPart("Door", v3(d.door.x, 3, d.door.z), model)
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
	local hub = layout.hub
	local pads = {}
	for _, pad in ipairs(hub.vehiclePads) do
		table.insert(pads, CFrame.lookAlong(v3(pad.x, 0, pad.z), v3(pad.facing.x, 0, pad.facing.z)))
	end
	return {
		cityFolder = cityFolder,
		pickupFolder = pickupFolder,
		destinationFolder = destinationFolder,
		depotFolder = depotFolder,
		runtime = runtime,
		businesses = businesses,
		destinations = destinations,
		depotPlots = {},
		hubSpawn = CFrame.lookAlong(v3(hub.spawn.x, 3, hub.spawn.z), v3(hub.spawn.facing.x, 0, hub.spawn.facing.z)),
		vehiclePads = pads,
	}
end

-- Minimal CityService that fulfils the 5.3 contract from the mini layout.
local function makeCityService(layout, world, RouteGraph)
	local CityService = {}
	local ctxRef = nil
	function CityService.Init(ctx)
		ctxRef = ctx
		ctx.graph = RouteGraph.build(layout)
		ctx.world = world
	end
	function CityService.Start() end
	function CityService.GetNearestRoadPoint(position, mask)
		local point, _, _, distance = RouteGraph.nearestPointOnGraph(ctxRef.graph, position, mask)
		return point, distance
	end
	function CityService.GetSafeRespawnCFrame(position, mask)
		local graph = ctxRef.graph
		local point, edge = RouteGraph.nearestPointOnGraph(graph, position, mask)
		local dir = graph.nodes[edge.b].position - graph.nodes[edge.a].position
		return CFrame.lookAlong(point + v3(0, 1.5, 0), dir.Unit)
	end
	function CityService.GetHubSpawn()
		return world.hubSpawn
	end
	function CityService.GetFreeVehiclePad()
		return world.vehiclePads[1]
	end
	return CityService
end

-- Fallback builders used only when the real Builders modules are absent from the bundle.
local FakeVehicleBuilder = {}
function FakeVehicleBuilder.build(vehicleId, ownerUserId, colors)
	local model = Instance.new("Model")
	model.Name = "Vehicle"
	local chassis = Instance.new("Part")
	chassis.Name = "Chassis"
	chassis.Size = v3(2, 1, 5)
	chassis.Anchored = true
	chassis.Parent = model
	model.PrimaryPart = chassis
	for _, name in ipairs({ "RootAttachment", "CargoAttachment", "DismountAttachment" }) do
		local att = Instance.new("Attachment")
		att.Name = name
		att.Parent = chassis
	end
	chassis.DismountAttachment.Position = v3(-2.6, -1.5, 0)
	local bodyRoot = Instance.new("Part")
	bodyRoot.Name = "BodyRoot"
	bodyRoot.Massless = true
	bodyRoot.CanCollide = false
	bodyRoot.Parent = model
	local seat = Instance.new("VehicleSeat")
	seat.Name = "Seat"
	seat.Disabled = true
	seat.CFrame = chassis.CFrame * CFrame.new(0, 1.5, 0.7)
	seat.Parent = model
	local cargo = Instance.new("Folder")
	cargo.Name = "Cargo"
	cargo.Parent = model
	model:SetAttribute("OwnerUserId", ownerUserId)
	model:SetAttribute("VehicleId", vehicleId)
	return model
end
function FakeVehicleBuilder.applyCosmetics() end

local FakePackageBuilder = {}
function FakePackageBuilder.build(packageKey)
	local model = Instance.new("Model")
	model.Name = "Package"
	local root = Instance.new("Part")
	root.Name = "Root"
	root.Size = v3(1, 1, 1)
	root.Parent = model
	model.PrimaryPart = root
	model:SetAttribute("PackageKey", packageKey)
	return model
end
function FakePackageBuilder.attachToVehicle(model, record)
	model.Parent = record.model:FindFirstChild("Cargo") or record.model
end
function FakePackageBuilder.attachToCharacter(model, character)
	model.Parent = character
end
function FakePackageBuilder.detach(model)
	model.Parent = nil
end

-------------------------------------------------------------------------------
-- Environment builder
-------------------------------------------------------------------------------

local SERVICE_NAMES = { "PlayerDataService", "ProgressionService", "AntiCheatService", "VehicleService", "RewardService", "OrderService", "TutorialService", "ShopService", "InteractionService" }
local INIT_ORDER = { "PlayerDataService", "ProgressionService", "CityService", "AntiCheatService", "VehicleService", "RewardService", "OrderService", "TutorialService", "ShopService", "InteractionService" }

local function buildEnv()
	shim.reset()
	shim.setContext("server")
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local Shared = ReplicatedStorage:WaitForChild("Shared")
	local Remotes = require(Shared.Util.Remotes)
	local RouteGraph = require(Shared.City.RouteGraph)
	local TableUtil = require(Shared.Util.TableUtil)
	local root = game:GetService("ServerScriptService"):WaitForChild("DeliveryDash")
	local servicesFolder = root:WaitForChild("Services")
	local buildersFolder = root:FindFirstChild("Builders")

	local world = buildWorld(LAYOUT)
	local ctx = { services = {}, remotes = Remotes, layout = LAYOUT, graph = nil, world = nil, isStudio = false, builders = {} }
	local vehicleBuilderModule = buildersFolder and buildersFolder:FindFirstChild("VehicleBuilder")
	local packageBuilderModule = buildersFolder and buildersFolder:FindFirstChild("PackageBuilder")
	ctx.builders.VehicleBuilder = if vehicleBuilderModule then require(vehicleBuilderModule) else FakeVehicleBuilder
	ctx.builders.PackageBuilder = if packageBuilderModule then require(packageBuilderModule) else FakePackageBuilder

	ctx.services.CityService = makeCityService(LAYOUT, world, RouteGraph)
	for _, name in ipairs(SERVICE_NAMES) do
		ctx.services[name] = require(servicesFolder:WaitForChild(name))
	end
	for _, name in ipairs(INIT_ORDER) do
		ctx.services[name].Init(ctx)
	end
	for _, name in ipairs(INIT_ORDER) do
		ctx.services[name].Start()
	end
	return { ctx = ctx, services = ctx.services, world = world, Remotes = Remotes, RouteGraph = RouteGraph, TableUtil = TableUtil }
end

local function storeProfile(userId, data)
	shim.datastore.data[STORE] = shim.datastore.data[STORE] or {}
	shim.datastore.data[STORE]["u_" .. tostring(userId)] = data
end

local function storedProfile(userId)
	local data = shim.datastore.data[STORE]
	return data and data["u_" .. tostring(userId)] or nil
end

local function updateCalls()
	local n = 0
	for _, call in ipairs(shim.datastore.calls) do
		if call.method == "UpdateAsync" then
			n += 1
		end
	end
	return n
end

local COMPLETED_TUTORIAL = { schemaVersion = 1, tutorial = { completed = true, step = 9 } }

-- Adds a player with a character and lets the (synchronous) load and deferred work settle.
local function joinPlayer(env, name, userId, stored)
	if stored then
		storeProfile(userId, stored)
	end
	local player = shim.addPlayer(name, userId)
	shim.spawnCharacter(player)
	shim.advance(0.1)
	return player
end

local function moveTo(player, position)
	player.Character:PivotTo(CFrame.new(position))
end

local function orderAt(env, player, spec)
	local orders = env.services.OrderService
	local order = orders.CreateOrder(player, spec)
	orders.InjectOrders(player, { order })
	return order
end

local function pizzaOrder(env, player, extra)
	local spec = { businessId = "SliceStreetPizza", destinationId = "D_Near", size = "Small", itemCategory = "Pizza", prepTimeOverride = 0 }
	for k, v in pairs(extra or {}) do
		spec[k] = v
	end
	return orderAt(env, player, spec)
end

local function collectOrder(env, player, order)
	moveTo(player, env.world.businesses[order.businessId].pickupPosition)
	return env.services.OrderService.RequestPickup(player, order.id)
end

local function deliverOrder(env, player, order)
	moveTo(player, env.world.destinations[order.destinationId].doorPosition)
	return env.services.OrderService.RequestDelivery(player, order.id)
end

-------------------------------------------------------------------------------
-- PlayerDataService
-------------------------------------------------------------------------------

describe("PlayerDataService", function()
	local env
	beforeEach(function()
		env = buildEnv()
	end)

	it("loads defaults for a new player and reconciles stored data", function()
		local player = joinPlayer(env, "Alice", 101, { schemaVersion = 1, cash = 120 })
		local data = env.services.PlayerDataService
		local profile = data.GetProfile(player)
		expect(profile).toBeTruthy()
		expect(profile.cash).toBe(120)
		expect(profile.reputation).toBe(0)
		expect(profile.ownedVehicles.Bicycle).toBe(true)
		expect(profile.equippedVehicle).toBe("Bicycle")
		expect(profile.cosmetics.equipped.BikeColor).toBe("BikeColor_Red")
		expect(profile.cosmetics.owned.Uniform_Orange).toBe(true)
		expect(profile.settings.musicVolume).toBe(0.6)
		expect(type(profile.stats.milestonesGranted)).toBe("table")
		expect(profile.tutorial.completed).toBe(false)
		expect(data.IsSaveable(player)).toBe(true)
		expect(player:FindFirstChild("leaderstats").Cash.Value).toBe(120)
		-- The load claimed the session lock in the same write.
		expect(storedProfile(101).lock.jobId).toBe(game.JobId)
		local public = data.GetPublicProfile(player)
		expect(public.lastSeen).toBeNil()
		expect(public.__loadFailed).toBeNil()
		expect(public.cash).toBe(120)
	end)

	it("never saves after a failed load", function()
		shim.datastore.failNextCalls = 4
		local player = shim.addPlayer("Bob", 102)
		shim.advance(10) -- 4 attempts with 1/2/4 s backoff
		local data = env.services.PlayerDataService
		local profile = data.GetProfile(player)
		expect(profile).toBeTruthy()
		expect(profile.__loadFailed).toBe(true)
		expect(data.IsSaveable(player)).toBe(false)
		expect(data.AddCash(player, 500, "test")).toBe(true)
		expect(profile.cash).toBe(500)
		shim.advance(130) -- autosave window
		expect(storedProfile(102)).toBeNil()
		shim.removePlayer(player)
		shim.advance(1)
		expect(storedProfile(102)).toBeNil()
		local warned = false
		for _, line in ipairs(shim.warnings) do
			if string.find(line, "read%-only") then
				warned = true
			end
		end
		expect(warned).toBe(true)
	end)

	it("respects a session lock held by another live server", function()
		storeProfile(103, { schemaVersion = 1, cash = 77, lock = { jobId = "other-job", t = os.time() } })
		local player = shim.addPlayer("Cara", 103)
		shim.advance(10) -- 3 lock retries over 6 s
		local data = env.services.PlayerDataService
		local profile = data.GetProfile(player)
		expect(profile).toBeTruthy()
		expect(profile.cash).toBe(77)
		expect(profile.__loadFailed).toBe(true)
		expect(data.IsSaveable(player)).toBe(false)
		expect(storedProfile(103).lock.jobId).toBe("other-job")
	end)

	it("claims a stale lock from another server", function()
		storeProfile(104, { schemaVersion = 1, cash = 5, lock = { jobId = "other-job", t = os.time() - 500 } })
		local player = joinPlayer(env, "Dan", 104)
		expect(env.services.PlayerDataService.IsSaveable(player)).toBe(true)
		expect(storedProfile(104).lock.jobId).toBe(game.JobId)
	end)

	it("autosaves only when dirty", function()
		-- A completed-tutorial profile: nothing mutates it on load (the tutorial persists step 0 otherwise).
		local player = joinPlayer(env, "Eve", 105, COMPLETED_TUTORIAL)
		local data = env.services.PlayerDataService
		local before = updateCalls()
		shim.advance(125)
		expect(updateCalls()).toBe(before)
		data.Update(player, function(profile)
			profile.cash = 5
		end)
		shim.advance(125)
		expect(updateCalls()).toBe(before + 1)
		expect(storedProfile(105).cash).toBe(5)
		expect(storedProfile(105).lock.jobId).toBe(game.JobId)
	end)

	it("saves everything on BindToClose and releases locks", function()
		local player = joinPlayer(env, "Finn", 106)
		env.services.PlayerDataService.AddCash(player, 42, "test")
		expect(#shim.boundToClose).toBeGreaterThan(0)
		local done = false
		task.spawn(function()
			shim.boundToClose[1]()
			done = true
		end)
		shim.advance(1)
		expect(done).toBe(true)
		expect(storedProfile(106).cash).toBe(42)
		expect(storedProfile(106).lock).toBeNil()
	end)

	it("saves on leave and releases the lock", function()
		local player = joinPlayer(env, "Gus", 107)
		local unloading = nil
		env.services.PlayerDataService.ProfileUnloading:Connect(function(p)
			unloading = p
		end)
		env.services.PlayerDataService.AddCash(player, 9, "test")
		shim.removePlayer(player)
		shim.advance(1)
		expect(unloading).toBe(player)
		expect(storedProfile(107).cash).toBe(9)
		expect(storedProfile(107).lock).toBeNil()
	end)

	it("never writes a profile older than the stored schema", function()
		local player = joinPlayer(env, "Hal", 108)
		env.services.PlayerDataService.AddCash(player, 10, "test")
		storedProfile(108).schemaVersion = 99
		env.services.PlayerDataService.SaveNow(player)
		expect(storedProfile(108).schemaVersion).toBe(99)
		expect(storedProfile(108).cash).toBeNil()
	end)

	it("TrySpendCash is atomic and amounts are validated", function()
		local player = joinPlayer(env, "Ivy", 109)
		local data = env.services.PlayerDataService
		expect(data.AddCash(player, 100, "test")).toBe(true)
		expect(data.TrySpendCash(player, 60, "a")).toBe(true)
		expect(data.TrySpendCash(player, 60, "b")).toBe(false)
		expect(data.GetProfile(player).cash).toBe(40)
		expect(data.AddCash(player, -5, "neg")).toBe(false)
		expect(data.AddCash(player, 0 / 0, "nan")).toBe(false)
		expect(data.AddCash(player, math.huge, "inf")).toBe(false)
		expect(data.TrySpendCash(player, 10.4, "round")).toBe(true)
		expect(data.GetProfile(player).cash).toBe(30)
		expect(data.AddReputation(player, 7.6, "rep")).toBe(true)
		expect(data.GetProfile(player).reputation).toBe(8)
		expect(player.leaderstats.Rep.Value).toBe(8)
	end)

	it("coalesces ProfileUpdated replication", function()
		local player = joinPlayer(env, "Jo", 110)
		local event = env.Remotes.getEvent("ProfileUpdated")
		local count = 0
		event.OnClientEvent:Connect(function()
			count += 1
		end)
		for _ = 1, 20 do
			env.services.PlayerDataService.AddCash(player, 1, "spam")
		end
		shim.advance(0.3)
		expect(count).toBeLessThan(3)
		expect(count).toBeGreaterThan(0)
	end)
end)

-------------------------------------------------------------------------------
-- ProgressionService (pure)
-------------------------------------------------------------------------------

describe("ProgressionService", function()
	local env, Progression, profile
	beforeEach(function()
		env = buildEnv()
		Progression = env.services.ProgressionService
		profile = env.TableUtil.deepCopy(env.services.PlayerDataService.DEFAULT_PROFILE)
	end)

	it("computes capacity per vehicle and upgrades", function()
		expect(Progression.GetCapacityForVehicle(profile, nil)).toBe(1)
		expect(Progression.GetCapacityForVehicle(profile, "Bicycle")).toBe(1)
		expect(Progression.GetMaxCapacity(profile)).toBe(1)
		profile.upgrades.BasketI = 1
		expect(Progression.GetCapacityForVehicle(profile, "Bicycle")).toBe(2)
		profile.upgrades.BasketII = 1
		expect(Progression.GetCapacityForVehicle(profile, "Bicycle")).toBe(3)
		expect(Progression.GetCapacityForVehicle(profile, "Scooter")).toBe(3)
		expect(Progression.GetMaxCapacity(profile)).toBe(3)
		profile.ownedVehicles.Scooter = true
		profile.upgrades.ScooterTopBoxI = 1
		expect(Progression.GetCapacityForVehicle(profile, "Scooter")).toBe(4)
		expect(Progression.GetMaxCapacity(profile)).toBe(4)
		profile.ownedVehicles.Van = true
		profile.upgrades.VanShelvingI = 1
		expect(Progression.GetCapacityForVehicle(profile, "Van")).toBe(10)
		expect(Progression.GetMaxCapacity(profile)).toBe(10)
		expect(Progression.GetCapacityForVehicle(profile, "Nope")).toBe(1)
	end)

	it("computes tip and speed multipliers", function()
		expect(Progression.GetTipMultiplier(profile)).toBe(1)
		profile.upgrades.ThermalBagI = 1
		expect(Progression.GetTipMultiplier(profile)).toBeCloseTo(1.15, 1e-9)
		profile.upgrades.ThermalBagII = 1
		expect(Progression.GetTipMultiplier(profile)).toBeCloseTo(1.3, 1e-9)
		expect(Progression.GetSpeedMultiplier(profile, "Bicycle")).toBe(1)
		profile.upgrades.TunedGears = 1
		expect(Progression.GetSpeedMultiplier(profile, "Bicycle")).toBeCloseTo(1.05, 1e-9)
		expect(Progression.GetSpeedMultiplier(profile, "Van")).toBe(1)
	end)

	it("returns purchase reason codes", function()
		local ok, reason = Progression.CanPurchaseVehicle(profile, "Bicycle")
		expect(ok).toBe(false)
		expect(reason).toBe("AlreadyOwned")
		ok, reason = Progression.CanPurchaseVehicle(profile, "Scooter")
		expect(reason).toBe("Requirements")
		profile.reputation = 150
		ok, reason = Progression.CanPurchaseVehicle(profile, "Scooter")
		expect(reason).toBe("Insufficient")
		profile.cash = 1500
		ok, reason = Progression.CanPurchaseVehicle(profile, "Scooter")
		expect(ok).toBe(true)
		ok, reason = Progression.CanPurchaseVehicle(profile, "Nope")
		expect(reason).toBe("NotFound")

		ok, reason = Progression.CanPurchaseUpgrade(profile, "BasketII")
		expect(reason).toBe("Requirements")
		profile.upgrades.BasketI = 1
		ok, reason = Progression.CanPurchaseUpgrade(profile, "BasketII")
		expect(ok).toBe(true)
		ok, reason = Progression.CanPurchaseUpgrade(profile, "BasketI")
		expect(reason).toBe("AlreadyOwned")
		ok, reason = Progression.CanPurchaseUpgrade(profile, "ScooterTopBoxI")
		expect(reason).toBe("Requirements")

		ok, reason = Progression.CanPurchaseCosmetic(profile, "Bag_Deluxe")
		expect(reason).toBe("Locked")
		ok, reason = Progression.CanPurchaseCosmetic(profile, "BikeColor_Red")
		expect(reason).toBe("AlreadyOwned")
		ok, reason = Progression.CanPurchaseCosmetic(profile, "BikeColor_Mint")
		expect(ok).toBe(true)

		ok, reason = Progression.CanPurchaseDepot(profile)
		expect(reason).toBe("Requirements")
		ok, reason = Progression.IsContractUnlocked(profile, "LunchRush")
		expect(reason).toBe("Requirements")
		profile.tutorial.completed = true
		profile.reputation = 60
		profile.stats.deliveries = 5
		ok = Progression.IsContractUnlocked(profile, "LunchRush")
		expect(ok).toBe(true)
	end)

	it("unlocks businesses and driver categories by reputation", function()
		expect(Progression.GetUnlockedBusinesses(profile)).toEqual({ "BeanAndBunCafe", "SliceStreetPizza" })
		profile.reputation = 500
		expect(#Progression.GetUnlockedBusinesses(profile)).toBe(4)
		expect(#Progression.GetUnlockedDriverCategories(profile)).toBe(0)
		profile.reputation = 1200
		expect(Progression.GetUnlockedDriverCategories(profile)).toEqual({ "DowntownFood", "ResidentialGrocery" })
		expect(Progression.IsMultiOrderUnlocked(profile)).toBe(false)
		profile.tutorial.completed = true
		profile.stats.deliveries = 3
		expect(Progression.IsMultiOrderUnlocked(profile)).toBe(true)
	end)

	it("grants milestones once", function()
		profile.stats.deliveries = 10
		expect(Progression.ApplyMilestones(profile)).toBe(25)
		expect(profile.reputation).toBe(25)
		expect(Progression.ApplyMilestones(profile)).toBe(0)
		profile.stats.deliveries = 100
		expect(Progression.ApplyMilestones(profile)).toBe(225)
	end)
end)

-------------------------------------------------------------------------------
-- OrderService + RewardService
-------------------------------------------------------------------------------

describe("OrderService", function()
	local env, player, Orders, Data
	beforeEach(function()
		env = buildEnv()
		Orders = env.services.OrderService
		Data = env.services.PlayerDataService
		player = joinPlayer(env, "Courier", 201, COMPLETED_TUTORIAL)
	end)

	it("prices orders from the route graph and business definition", function()
		local order = Orders.CreateOrder(player, { businessId = "SliceStreetPizza", destinationId = "D_Near", size = "Medium", itemCategory = "Pizza" })
		expect(order.routeDistance).toBeGreaterThan(130)
		expect(order.routeDistance).toBeLessThan(170)
		local expectedBase = math.floor((28 + 0.09 * order.routeDistance) * 1.25 + 0.5)
		expect(order.basePay).toBe(expectedBase)
		expect(order.tipMax).toBe(math.floor(expectedBase * 0.3 + 0.5))
		expect(order.repReward).toBe(7)
		expect(order.sizeUnits).toBe(2)
		expect(order.packageKey).toBe("PizzaBox")
		expect(order.timeLimit).toBe(90)
		expect(order.prepTime).toBeGreaterThanOrEqual(6)
		expect(order.prepTime).toBeLessThanOrEqual(12)
		expect(order.state).toBe("Available")
		expect(#order.id).toBeGreaterThan(5)
	end)

	it("validates Accept (ownership, state, capacity, multi-order lock)", function()
		local other = joinPlayer(env, "Other", 202, COMPLETED_TUTORIAL)
		local theirs = pizzaOrder(env, other)
		expect(Orders.Accept(player, theirs.id).error).toBe("NotFound")
		expect(Orders.Accept(player, "nope").error).toBe("NotFound")

		local medium = pizzaOrder(env, player, { size = "Medium", destinationId = "D_Mid" })
		expect(Orders.Accept(player, medium.id).error).toBe("NoCapacity")

		local first = pizzaOrder(env, player)
		local result = Orders.Accept(player, first.id)
		expect(result.ok).toBe(true)
		expect(result.order.state).toBe("ReadyForPickup") -- prepTime 0
		expect(Orders.Accept(player, first.id).error).toBe("WrongState")

		local second = pizzaOrder(env, player, { destinationId = "D_Alley" })
		expect(Orders.Accept(player, second.id).error).toBe("Locked")
		expect(#Orders.GetActive(player)).toBe(1)
	end)

	it("moves Accepted orders to ReadyForPickup after the prep time", function()
		local order = pizzaOrder(env, player, { prepTimeOverride = 5 })
		expect(Orders.Accept(player, order.id).ok).toBe(true)
		expect(order.state).toBe("Accepted")
		local early = collectOrder(env, player, order)
		expect(early.error).toBe("NotReady")
		expect(early.secondsLeft).toBe(5)
		shim.advance(6.5) -- readyAt is 5 s away; the tick loop runs once per second
		expect(order.state).toBe("ReadyForPickup")
		expect(collectOrder(env, player, order).ok).toBe(true)
		expect(order.state).toBe("Collected")
	end)

	it("checks pickup distance and capacity", function()
		local order = pizzaOrder(env, player)
		Orders.Accept(player, order.id)
		moveTo(player, v3(300, 1, 300))
		expect(Orders.RequestPickup(player, order.id).error).toBe("TooFar")
		expect(collectOrder(env, player, order).ok).toBe(true)
		expect(Orders.GetCapacityInfo(player)).toEqual({ current = 1, max = 1, load = 1, committed = 1 })
		expect(Orders.RequestPickup(player, order.id).error).toBe("WrongState")
	end)

	it("pays exactly once even when RequestDelivery is called twice", function()
		local order = pizzaOrder(env, player)
		Orders.Accept(player, order.id)
		collectOrder(env, player, order)
		moveTo(player, v3(300, 1, 300))
		expect(Orders.RequestDelivery(player, order.id).error).toBe("TooFar")
		local before = Data.GetProfile(player).cash
		local delivered = nil
		Orders.OrderDelivered:Connect(function(_, o, payout)
			delivered = payout
		end)
		local result = deliverOrder(env, player, order)
		expect(result.ok).toBe(true)
		expect(result.payout.base).toBe(order.basePay)
		expect(result.payout.tip).toBe(order.tipMax)
		expect(result.payout.total).toBe(order.basePay + order.tipMax)
		expect(result.payout.timelinessFactor).toBe(1)
		expect(delivered).toBeTruthy()
		local profile = Data.GetProfile(player)
		expect(profile.cash).toBe(before + result.payout.total)
		expect(profile.reputation).toBe(order.repReward)
		expect(profile.stats.deliveries).toBe(1)
		expect(profile.stats.bestTimes["SliceStreetPizza>D_Near"]).toBeTruthy()
		expect(order.rewardGranted).toBe(true)
		expect(Orders.RequestDelivery(player, order.id).ok).toBe(false)
		expect(Data.GetProfile(player).cash).toBe(before + result.payout.total)
		expect(#Orders.GetActive(player)).toBe(0)
		expect(Orders.GetOrder(order.id)).toBeNil()
		expect(env.services.RewardService.GrantDeliveryPayout(player, order)).toBeNil()
	end)

	it("pays base with a reduced tip when late", function()
		local order = pizzaOrder(env, player, { timeLimit = 10 })
		Orders.Accept(player, order.id)
		shim.advance(15) -- halfway between the limit and 2x the limit
		collectOrder(env, player, order)
		local result = deliverOrder(env, player, order)
		expect(result.ok).toBe(true)
		expect(result.payout.base).toBe(order.basePay)
		expect(result.payout.tip).toBe(math.floor(order.tipMax * 0.5 + 0.5))
		expect(result.payout.lateSeconds).toBeCloseTo(5, 0.2)
		expect(Data.GetProfile(player).stats.lateDeliveries).toBe(1)

		local late = pizzaOrder(env, player, { timeLimit = 10, destinationId = "D_Mid" })
		Orders.Accept(player, late.id)
		shim.advance(40)
		collectOrder(env, player, late)
		local result2 = deliverOrder(env, player, late)
		expect(result2.ok).toBe(true)
		expect(result2.payout.tip).toBe(0)
		expect(result2.payout.base).toBe(late.basePay)
	end)

	it("cancelling a collected order costs 2 rep floored at 0", function()
		Data.AddReputation(player, 1, "seed")
		local order = pizzaOrder(env, player)
		Orders.Accept(player, order.id)
		collectOrder(env, player, order)
		expect(Orders.Cancel(player, order.id).ok).toBe(true)
		expect(Data.GetProfile(player).reputation).toBe(0)
		expect(order.state).toBe("Cancelled")
		expect(#Orders.GetActive(player)).toBe(0)

		Data.AddReputation(player, 5, "seed")
		local second = pizzaOrder(env, player)
		Orders.Accept(player, second.id)
		collectOrder(env, player, second)
		Orders.Cancel(player, second.id)
		expect(Data.GetProfile(player).reputation).toBe(3)

		local third = pizzaOrder(env, player)
		Orders.Accept(player, third.id)
		expect(Orders.Cancel(player, third.id, { noPenalty = true, silent = true, reason = "Test" }).ok).toBe(true)
		expect(Data.GetProfile(player).reputation).toBe(3)
		expect(Orders.Cancel(player, third.id).error).toBe("NotFound")
	end)

	it("expires available orders", function()
		local order = pizzaOrder(env, player, { availableFor = 2 })
		local removed = nil
		Orders.OrderRemoved:Connect(function(_, o, reason)
			removed = reason
		end)
		expect(Orders.GetOrder(order.id)).toBe(order)
		shim.advance(3)
		expect(order.state).toBe("Expired")
		expect(removed).toBe("Expired")
		expect(Orders.GetOrder(order.id)).toBeNil()
		for _, o in ipairs(Orders.GetAvailable(player)) do
			expect(o.id).never.toBe(order.id)
		end
	end)

	it("clears orders on PlayerRemoving", function()
		local order = pizzaOrder(env, player)
		Orders.Accept(player, order.id)
		collectOrder(env, player, order)
		shim.removePlayer(player)
		shim.advance(0.1)
		expect(Orders.GetActive(player)).toEqual({})
		expect(Orders.GetOrder(order.id)).toBeNil()
		expect(order.state).toBe("Cancelled")
	end)

	it("keeps the board filled from unlocked businesses", function()
		local available = Orders.GetAvailable(player)
		expect(#available).toBeGreaterThanOrEqual(3)
		expect(#available).toBeLessThanOrEqual(6)
		local seen = {}
		for _, order in ipairs(available) do
			expect(order.sizeUnits).toBe(1)
			expect(order.businessId == "SliceStreetPizza" or order.businessId == "BeanAndBunCafe").toBe(true)
			expect(seen[order.destinationId]).toBeNil()
			seen[order.destinationId] = true
		end
		-- Accepting and finishing an order lets the generator top the board up again.
		local order = available[1]
		Orders.Accept(player, order.id)
		collectOrder(env, player, order)
		deliverOrder(env, player, order)
		shim.advance(6)
		expect(#Orders.GetAvailable(player)).toBeGreaterThanOrEqual(3)
	end)

	it("attaches package visuals to the character and vehicle", function()
		local order = pizzaOrder(env, player)
		Orders.Accept(player, order.id)
		collectOrder(env, player, order)
		local onCharacter = nil
		for _, child in ipairs(player.Character:GetChildren()) do
			if child:GetAttribute("OrderId") == order.id then
				onCharacter = child
			end
		end
		expect(onCharacter).toBeTruthy()
		local vehicles = env.services.VehicleService
		expect(vehicles.Spawn(player, "Bicycle").ok).toBe(true)
		local record = vehicles.GetVehicle(player)
		moveTo(player, record.chassis.Position + v3(2, 0, 0))
		expect(vehicles.Mount(player).ok).toBe(true)
		expect(onCharacter:IsDescendantOf(record.model)).toBe(true)
		vehicles.Dismount(player)
		expect(onCharacter:IsDescendantOf(player.Character)).toBe(true)
		deliverOrder(env, player, order)
		expect(onCharacter.Parent).toBeNil()
	end)

	it("replicates OrdersUpdated with capacity and serverTime", function()
		local payload = nil
		env.Remotes.getEvent("OrdersUpdated").OnClientEvent:Connect(function(p)
			payload = p
		end)
		local order = pizzaOrder(env, player)
		Orders.Accept(player, order.id)
		shim.advance(0.6)
		expect(payload).toBeTruthy()
		expect(payload.capacity.committed).toBe(1)
		expect(type(payload.serverTime)).toBe("number")
		expect(#payload.active).toBe(1)
	end)
end)

describe("RewardService", function()
	local env
	beforeEach(function()
		env = buildEnv()
	end)

	it("computes timeliness linearly to zero at twice the limit", function()
		local Rewards = env.services.RewardService
		local profile = env.TableUtil.deepCopy(env.services.PlayerDataService.DEFAULT_PROFILE)
		local order = { basePay = 100, tipMax = 30, repReward = 6, timeLimit = 100, acceptedAt = 0, businessId = "a", destinationId = "b", routeDistance = 0 }
		expect(Rewards.ComputePayout(order, profile, 50).tip).toBe(30)
		expect(Rewards.ComputePayout(order, profile, 150).tip).toBe(15)
		expect(Rewards.ComputePayout(order, profile, 200).tip).toBe(0)
		expect(Rewards.ComputePayout(order, profile, 500).total).toBe(100)
		profile.upgrades.ThermalBagI = 1
		expect(Rewards.ComputePayout(order, profile, 50).tip).toBe(35)
		order.timeLimit = nil
		expect(Rewards.ComputePayout(order, profile, 10000).timelinessFactor).toBe(1)
	end)

	it("tracks best times and grants contract bonuses", function()
		local player = joinPlayer(env, "Rec", 301, COMPLETED_TUTORIAL)
		local Orders = env.services.OrderService
		local first = pizzaOrder(env, player)
		Orders.Accept(player, first.id)
		shim.advance(20)
		collectOrder(env, player, first)
		local r1 = deliverOrder(env, player, first)
		expect(r1.ok).toBe(true)
		expect(r1.payout.newRecord).toBe(false)
		-- The spec teleports the character between stops; tell AntiCheat before time advances.
		env.services.AntiCheatService.NotePlausibleTeleport(player, 5)
		local second = pizzaOrder(env, player)
		expect(Orders.Accept(player, second.id).ok).toBe(true)
		shim.advance(2)
		expect(collectOrder(env, player, second).ok).toBe(true)
		local r2 = deliverOrder(env, player, second)
		expect(r2.ok).toBe(true)
		expect(r2.payout.newRecord).toBe(true)
		local cash = env.services.PlayerDataService.GetProfile(player).cash
		local bonus = env.services.RewardService.GrantContractBonus(player, "LunchRush", { first, second })
		expect(bonus).toBe(math.floor((first.basePay + second.basePay) * 0.4 + 60 + 0.5))
		local profile = env.services.PlayerDataService.GetProfile(player)
		expect(profile.cash).toBe(cash + bonus)
		expect(profile.stats.contractsCompleted).toBe(1)
	end)
end)

-------------------------------------------------------------------------------
-- VehicleService
-------------------------------------------------------------------------------

describe("VehicleService", function()
	local env, player, Vehicles
	beforeEach(function()
		env = buildEnv()
		Vehicles = env.services.VehicleService
		player = joinPlayer(env, "Rider", 401, COMPLETED_TUTORIAL)
	end)

	local function spawnAndMount()
		expect(Vehicles.Spawn(player, "Bicycle").ok).toBe(true)
		local record = Vehicles.GetVehicle(player)
		moveTo(player, record.chassis.Position + v3(3, 0, 0))
		expect(Vehicles.Mount(player).ok).toBe(true)
		return record
	end

	it("walks through Spawn, Mount, Dismount, Recover and Despawn", function()
		local states = {}
		Vehicles.StateChanged:Connect(function(_, state)
			table.insert(states, state)
		end)
		expect(Vehicles.GetState(player)).toBeNil()
		expect(Vehicles.GetVehicleMask(player)).toBe(7)
		expect(Vehicles.GetCapacityUnits(player)).toBe(1)

		local result = Vehicles.Spawn(player, "Bicycle")
		expect(result.ok).toBe(true)
		expect(result.vehicleId).toBe("Bicycle")
		local record = Vehicles.GetVehicle(player)
		expect(record).toBeTruthy()
		expect(record.state).toBe("Parked")
		expect(record.model.Parent).toBe(game:GetService("Workspace").Runtime.Vehicles)
		expect(record.model:GetAttribute("OwnerUserId")).toBe(401)
		expect(record.model:GetAttribute("VehicleId")).toBe("Bicycle")
		expect(record.model:GetAttribute("State")).toBe("Parked")
		expect(record.model:GetAttribute("Capacity")).toBe(1)
		expect(record.chassis.Anchored).toBe(true)
		expect(record.chassis.CollisionGroup).toBe("Vehicles")
		-- spawned near the player's nearest road point (hub is beside Main Street)
		expect((record.chassis.Position - v3(0, 0, 30)).Magnitude).toBeLessThan(80)

		moveTo(player, record.chassis.Position + v3(50, 0, 0))
		expect(Vehicles.Mount(player).error).toBe("TooFar")
		moveTo(player, record.chassis.Position + v3(3, 0, 0))
		expect(Vehicles.Mount(player).ok).toBe(true)
		expect(Vehicles.GetState(player)).toBe("Driving")
		expect(Vehicles.IsDriving(player)).toBe(true)
		local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
		expect(record.seat.Occupant).toBe(humanoid)
		expect(record.chassis.Anchored).toBe(false)
		expect(Vehicles.GetVehicleMask(player)).toBe(1)
		expect(Vehicles.GetPlayerPosition(player)).toEqual(record.chassis.Position)
		expect(Vehicles.Mount(player).error).toBe("WrongState")

		expect(Vehicles.Dismount(player).ok).toBe(true)
		expect(Vehicles.GetState(player)).toBe("Parked")
		expect(record.seat.Occupant).toBeNil()
		expect(humanoid.SeatPart).toBeNil()
		expect(record.chassis.Anchored).toBe(true)
		expect(record.chassis.Position.Y).toBeCloseTo(1.5, 0.01)
		expect(Vehicles.Dismount(player).error).toBe("WrongState")

		expect(Vehicles.Recover(player).ok).toBe(true)
		expect(Vehicles.GetState(player)).toBe("Parked")
		expect(Vehicles.Recover(player).error).toBe("Cooldown")
		shim.advance(3.1)
		expect(Vehicles.Recover(player).ok).toBe(true)

		local despawned = false
		Vehicles.Despawned:Connect(function()
			despawned = true
		end)
		expect(Vehicles.Despawn(player).ok).toBe(true)
		expect(despawned).toBe(true)
		expect(Vehicles.GetVehicle(player)).toBeNil()
		expect(record.model.Parent).toBeNil()
		expect(Vehicles.Despawn(player).error).toBe("NotFound")
		expect(states[1]).toBe("Parked")
		expect(states[2]).toBe("Mounting")
		expect(states[3]).toBe("Driving")
		expect(states[4]).toBe("Dismounting")
		expect(states[5]).toBe("Parked")
	end)

	it("requires ownership and a known vehicle", function()
		expect(Vehicles.Spawn(player, "Scooter").error).toBe("Locked")
		expect(Vehicles.Spawn(player, "Nope").error).toBe("NotFound")
		expect(Vehicles.Mount(player).error).toBe("NotFound")
		expect(Vehicles.Recover(player).error).toBe("NotFound")
	end)

	it("rejects another player's mount attempt with NotOwner", function()
		Vehicles.Spawn(player, "Bicycle")
		local record = Vehicles.GetVehicle(player)
		local intruder = joinPlayer(env, "Intruder", 402, COMPLETED_TUTORIAL)
		moveTo(intruder, record.chassis.Position + v3(2, 0, 0))
		expect(Vehicles.Mount(intruder, record.model).error).toBe("NotOwner")
		expect(Vehicles.Mount(intruder).error).toBe("NotFound")
		expect(record.state).toBe("Parked")
	end)

	it("replaces the vehicle when spawning again and recovers while driving", function()
		local first = spawnAndMount()
		expect(Vehicles.Spawn(player, "Bicycle").ok).toBe(true)
		expect(first.model.Parent).toBeNil()
		local second = Vehicles.GetVehicle(player)
		expect(second).never.toBe(first)
		expect(second.state).toBe("Parked")
		moveTo(player, second.chassis.Position + v3(2, 0, 0))
		Vehicles.Mount(player)
		second.model:PivotTo(CFrame.new(250, 1.5, 250))
		expect(Vehicles.Recover(player).ok).toBe(true)
		expect(Vehicles.GetState(player)).toBe("Driving")
		expect((second.chassis.Position - v3(250, 0, 250)).Magnitude).toBeGreaterThan(50)
		expect(second.seat.Occupant).toBeTruthy()
	end)

	it("watchdog ejects intruders, dismounts lost riders and recovers fallen vehicles", function()
		local record = spawnAndMount()
		local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
		-- Rider falls out: auto-dismount back to Parked.
		humanoid.Sit = false
		expect(record.seat.Occupant).toBeNil()
		Vehicles.RunWatchdog()
		expect(Vehicles.GetState(player)).toBe("Parked")
		expect(record.chassis.Anchored).toBe(true)

		-- Intruder sits in a parked vehicle: ejected.
		local intruder = joinPlayer(env, "Intruder", 403, COMPLETED_TUTORIAL)
		local intruderHumanoid = intruder.Character:FindFirstChildOfClass("Humanoid")
		record.seat:Sit(intruderHumanoid)
		expect(record.seat.Occupant).toBe(intruderHumanoid)
		Vehicles.RunWatchdog()
		expect(record.seat.Occupant).toBeNil()

		-- Falling below killY triggers a recovery.
		record.model:PivotTo(CFrame.new(0, -200, 0))
		Vehicles.RunWatchdog()
		expect(record.chassis.Position.Y).toBeGreaterThan(-60)
		expect(Vehicles.GetState(player)).toBe("Parked")

		-- The watchdog loop also runs on its own every 2 s.
		record.model:PivotTo(CFrame.new(0, -200, 0))
		shim.advance(2.1)
		expect(record.chassis.Position.Y).toBeGreaterThan(-60)
	end)

	it("dismounts on death and keeps the vehicle parked", function()
		local record = spawnAndMount()
		local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
		humanoid.Health = 0
		expect(Vehicles.GetState(player)).toBe("Parked")
		expect(record.seat.Occupant).toBeNil()
		expect(record.chassis.Anchored).toBe(true)
		-- Respawn: the vehicle stays, the character goes to the hub.
		shim.spawnCharacter(player)
		shim.advance(0.1)
		expect(Vehicles.GetVehicle(player)).toBe(record)
		local root = player.Character.HumanoidRootPart
		expect((root.Position - env.world.hubSpawn.Position).Magnitude).toBeLessThan(10)
		expect(root.CollisionGroup).toBe("Players")
	end)

	it("reports capacity units for the spawned vehicle", function()
		local Data = env.services.PlayerDataService
		expect(Vehicles.GetCapacityUnits(player)).toBe(1)
		Vehicles.Spawn(player, "Bicycle")
		Data.Update(player, function(profile)
			profile.upgrades.BasketI = 1
		end)
		expect(Vehicles.GetCapacityUnits(player)).toBe(2)
		Vehicles.RefreshCapacity(player)
		expect(Vehicles.GetVehicle(player).model:GetAttribute("Capacity")).toBe(2)
		Data.Update(player, function(profile)
			profile.ownedVehicles.Scooter = true
		end)
		expect(Vehicles.Spawn(player, "Scooter").ok).toBe(true)
		expect(Vehicles.GetCapacityUnits(player)).toBe(3)
		expect(Vehicles.GetCurrentVehicleId(player)).toBe("Scooter")
		shim.removePlayer(player)
		expect(Vehicles.GetVehicle(player)).toBeNil()
	end)

	it("registers the collision group matrix", function()
		local PhysicsService = game:GetService("PhysicsService")
		expect(PhysicsService:CollisionGroupsAreCollidable("Vehicles", "Players")).toBe(false)
		expect(PhysicsService:CollisionGroupsAreCollidable("Vehicles", "Vehicles")).toBe(false)
		expect(PhysicsService:CollisionGroupsAreCollidable("Packages", "Default")).toBe(false)
		expect(PhysicsService:CollisionGroupsAreCollidable("Vehicles", "Default")).toBe(true)
	end)
end)

-------------------------------------------------------------------------------
-- AntiCheatService
-------------------------------------------------------------------------------

describe("AntiCheatService", function()
	local env, player, AntiCheat
	beforeEach(function()
		env = buildEnv()
		AntiCheat = env.services.AntiCheatService
		player = joinPlayer(env, "Runner", 501, COMPLETED_TUTORIAL)
		shim.advance(3.5) -- past the respawn teleport grace
	end)

	it("flags a teleport and clears the flag after the window", function()
		expect(AntiCheat.CheckPosition(player)).toBe(true)
		moveTo(player, player.Character.HumanoidRootPart.Position + v3(1000, 0, 0))
		shim.advance(1.1)
		expect(AntiCheat.CheckPosition(player)).toBe(false)
		expect(AntiCheat.GetStrikes(player)).toBe(1)
		shim.advance(4.5)
		expect(AntiCheat.CheckPosition(player)).toBe(true)
	end)

	it("allows plausible movement", function()
		for _ = 1, 3 do
			moveTo(player, player.Character.HumanoidRootPart.Position + v3(20, 0, 0))
			shim.advance(1)
		end
		expect(AntiCheat.GetStrikes(player)).toBe(0)
		expect(AntiCheat.CheckPosition(player)).toBe(true)
	end)

	it("NotePlausibleTeleport suppresses the check", function()
		AntiCheat.NotePlausibleTeleport(player, 3)
		moveTo(player, player.Character.HumanoidRootPart.Position + v3(1000, 0, 0))
		shim.advance(1.1)
		expect(AntiCheat.GetStrikes(player)).toBe(0)
		expect(AntiCheat.CheckPosition(player)).toBe(true)
	end)

	it("blocks pickups while flagged and cleans up on leave", function()
		local Orders = env.services.OrderService
		local order = pizzaOrder(env, player)
		Orders.Accept(player, order.id)
		moveTo(player, v3(-300, 1, 300))
		shim.advance(1.1)
		local result = collectOrder(env, player, order)
		expect(result.error).toBe("PositionCheck")
		shim.advance(4.5)
		expect(collectOrder(env, player, order).ok).toBe(true)
		shim.removePlayer(player)
		expect(AntiCheat.GetStrikes(player)).toBe(0)
	end)
end)

-------------------------------------------------------------------------------
-- TutorialService
-------------------------------------------------------------------------------

describe("TutorialService", function()
	local env, player, Tutorial, Orders, Vehicles, Data
	beforeEach(function()
		env = buildEnv()
		Tutorial = env.services.TutorialService
		Orders = env.services.OrderService
		Vehicles = env.services.VehicleService
		Data = env.services.PlayerDataService
		player = joinPlayer(env, "Newbie", 601)
	end)

	it("runs steps 0-9 on a scripted first session", function()
		local updates = {}
		env.Remotes.getEvent("TutorialUpdated").OnClientEvent:Connect(function(payload)
			table.insert(updates, payload)
		end)
		expect(Tutorial.GetStep(player)).toBe(0)
		expect(player:GetAttribute("TutorialStep")).toBe(0)
		expect(#Orders.GetAvailable(player)).toBe(0) -- generator silent during the tutorial
		expect(Tutorial.AdvanceTutorial(player, 3).error).toBe("WrongState")
		expect(Tutorial.AdvanceTutorial(player, 0).ok).toBe(true)
		expect(Tutorial.GetStep(player)).toBe(1)

		local available = Orders.GetAvailable(player)
		expect(#available).toBe(1)
		local first = available[1]
		expect(first.isTutorial).toBe(true)
		expect(first.businessId).toBe("SliceStreetPizza")
		expect(first.destinationId).toBe("D_Near")
		expect(first.basePay).toBe(45)
		expect(first.prepTime).toBe(0)
		expect(first.timeLimit).toBeNil()
		expect(Tutorial.AdvanceTutorial(player, 1).error).toBe("Invalid") -- not dismissable

		expect(Orders.Accept(player, first.id).ok).toBe(true)
		expect(Tutorial.GetStep(player)).toBe(2)
		expect(Vehicles.Spawn(player, "Bicycle").ok).toBe(true)
		local record = Vehicles.GetVehicle(player)
		moveTo(player, record.chassis.Position + v3(2, 0, 0))
		expect(Vehicles.Mount(player).ok).toBe(true)
		expect(Tutorial.GetStep(player)).toBe(3)

		record.model:PivotTo(CFrame.new(env.world.businesses.SliceStreetPizza.pickupPosition + v3(0, 1.5, 0)))
		shim.advance(1.1)
		expect(Tutorial.GetStep(player)).toBe(4)
		expect(Orders.RequestPickup(player, first.id).ok).toBe(true)
		expect(Tutorial.GetStep(player)).toBe(5)

		record.model:PivotTo(CFrame.new(env.world.destinations.D_Near.doorPosition + v3(0, 1.5, 0)))
		local delivered = Orders.RequestDelivery(player, first.id)
		expect(delivered.ok).toBe(true)
		expect(delivered.payout.total).toBe(45 + 14)
		expect(Tutorial.GetStep(player)).toBe(6)
		expect(Tutorial.AdvanceTutorial(player, 6).ok).toBe(true)
		expect(Tutorial.GetStep(player)).toBe(7)

		local second = Orders.GetAvailable(player)[1]
		expect(second).toBeTruthy()
		expect(second.destinationId).toBe("D_Mid")
		expect(second.basePay).toBe(50)
		Orders.Accept(player, second.id)
		record.model:PivotTo(CFrame.new(env.world.businesses.SliceStreetPizza.pickupPosition + v3(0, 1.5, 0)))
		expect(Orders.RequestPickup(player, second.id).ok).toBe(true)
		record.model:PivotTo(CFrame.new(env.world.destinations.D_Mid.doorPosition + v3(0, 1.5, 0)))
		expect(Orders.RequestDelivery(player, second.id).ok).toBe(true)
		expect(Tutorial.GetStep(player)).toBe(8)
		expect(Data.GetProfile(player).tutorial.step).toBe(8)
		expect(Orders.IsGeneratorEnabled(player)).toBe(true)
		shim.advance(0.1)
		expect(#Orders.GetAvailable(player)).toBeGreaterThanOrEqual(3)

		local repBefore = Data.GetProfile(player).reputation
		Data.AddCash(player, 100, "seed")
		expect(env.services.ShopService.PurchaseUpgrade(player, "BasketI").ok).toBe(true)
		shim.advance(1.1)
		expect(Tutorial.GetStep(player)).toBe(9)
		local profile = Data.GetProfile(player)
		expect(profile.tutorial.completed).toBe(true)
		expect(profile.reputation).toBe(repBefore + 25)
		expect(player:GetAttribute("TutorialStep")).toBe(9)
		expect(Tutorial.AdvanceTutorial(player, 9).ok).toBe(true)
		local last = updates[#updates]
		expect(last.step).toBe(9)
		expect(last.completed).toBe(true)
		expect(type(last.title)).toBe("string")
		expect(Tutorial.GetHint(8).title).toBe("First upgrade")
	end)

	it("lets step 8 be dismissed without buying", function()
		Tutorial.AdvanceTutorial(player, 0)
		local first = Orders.GetAvailable(player)[1]
		Orders.Accept(player, first.id)
		collectOrder(env, player, first)
		deliverOrder(env, player, first)
		Tutorial.AdvanceTutorial(player, 6)
		local second = Orders.GetAvailable(player)[1]
		Orders.Accept(player, second.id)
		collectOrder(env, player, second)
		deliverOrder(env, player, second)
		expect(Tutorial.GetStep(player)).toBe(8)
		expect(Tutorial.AdvanceTutorial(player, 8).ok).toBe(true)
		expect(Tutorial.GetStep(player)).toBe(9)
		expect(Tutorial.AdvanceTutorial(player, 0).ok).toBe(true) -- stale ack is a no-op
		expect(Tutorial.GetStep(player)).toBe(9)
	end)

	it("re-issues a cancelled tutorial order", function()
		Tutorial.AdvanceTutorial(player, 0)
		local first = Orders.GetAvailable(player)[1]
		Orders.Accept(player, first.id)
		expect(Tutorial.GetStep(player)).toBe(2)
		Orders.Cancel(player, first.id)
		expect(Tutorial.GetStep(player)).toBe(1)
		local again = Orders.GetAvailable(player)[1]
		expect(again).toBeTruthy()
		expect(again.id).never.toBe(first.id)
		expect(again.isTutorial).toBe(true)
	end)

	it("skips entirely for completed profiles", function()
		local veteran = joinPlayer(env, "Vet", 602, COMPLETED_TUTORIAL)
		expect(Tutorial.GetStep(veteran)).toBeNil()
		expect(veteran:GetAttribute("TutorialStep")).toBe(9)
		expect(Orders.IsGeneratorEnabled(veteran)).toBe(true)
		expect(#Orders.GetAvailable(veteran)).toBeGreaterThanOrEqual(3)
	end)
end)

-------------------------------------------------------------------------------
-- ShopService
-------------------------------------------------------------------------------

describe("ShopService", function()
	local env, player, Shop, Data
	beforeEach(function()
		env = buildEnv()
		Shop = env.services.ShopService
		Data = env.services.PlayerDataService
		player = joinPlayer(env, "Shopper", 701, COMPLETED_TUTORIAL)
	end)

	it("buys upgrades and refreshes vehicle capacity", function()
		expect(Shop.PurchaseUpgrade(player, "BasketI").error).toBe("Insufficient")
		Data.AddCash(player, 100, "seed")
		env.services.VehicleService.Spawn(player, "Bicycle")
		local result = Shop.PurchaseUpgrade(player, "BasketI")
		expect(result.ok).toBe(true)
		expect(result.profile.upgrades.BasketI).toBe(1)
		expect(Data.GetProfile(player).cash).toBe(25)
		expect(env.services.VehicleService.GetVehicle(player).model:GetAttribute("Capacity")).toBe(2)
		expect(Shop.PurchaseUpgrade(player, "BasketI").error).toBe("AlreadyOwned")
		expect(Shop.PurchaseUpgrade(player, "Nope").error).toBe("NotFound")
	end)

	it("buys and equips vehicles, respawning a spawned one", function()
		local Vehicles = env.services.VehicleService
		Data.AddCash(player, 2000, "seed")
		expect(Shop.PurchaseVehicle(player, "Scooter").error).toBe("Requirements")
		Data.AddReputation(player, 150, "seed")
		Vehicles.Spawn(player, "Bicycle")
		local result = Shop.PurchaseVehicle(player, "Scooter")
		expect(result.ok).toBe(true)
		expect(result.profile.ownedVehicles.Scooter).toBe(true)
		expect(result.profile.equippedVehicle).toBe("Scooter")
		expect(Data.GetProfile(player).cash).toBe(500)
		expect(Vehicles.GetCurrentVehicleId(player)).toBe("Scooter")
		expect(Shop.EquipVehicle(player, "Van").error).toBe("Locked")
		expect(Shop.EquipVehicle(player, "Bicycle").ok).toBe(true)
		expect(Vehicles.GetCurrentVehicleId(player)).toBe("Bicycle")
	end)

	it("handles cosmetics, paid-only items and uniforms", function()
		expect(Shop.PurchaseCosmetic(player, "Bag_Deluxe").error).toBe("Locked")
		expect(Shop.PurchaseCosmetic(player, "Bag_Deluxe").message).toBe("Available in the store")
		expect(Shop.EquipCosmetic(player, "BikeColor_Mint").error).toBe("Locked")
		Data.AddCash(player, 500, "seed")
		local result = Shop.PurchaseCosmetic(player, "BikeColor_Mint")
		expect(result.ok).toBe(true)
		expect(result.profile.cosmetics.owned.BikeColor_Mint).toBe(true)
		expect(result.profile.cosmetics.equipped.BikeColor).toBe("BikeColor_Mint")
		expect(Data.GetProfile(player).cash).toBe(350)
		expect(Shop.PurchaseCosmetic(player, "BikeColor_Mint").error).toBe("AlreadyOwned")

		expect(player.Character:FindFirstChild("CourierVest")).toBeTruthy()
		Data.AddCash(player, 250, "seed")
		Data.AddReputation(player, 20, "seed")
		expect(Shop.PurchaseCosmetic(player, "Uniform_Blue").ok).toBe(true)
		local vest = player.Character:FindFirstChild("CourierVest")
		expect(vest).toBeTruthy()
		expect(vest.Color).toEqual(Color3.fromRGB(50, 110, 200))
		expect(vest:FindFirstChild("VestTrim")).toBeTruthy()
		expect(vest.Massless).toBe(true)
		expect(vest.CanCollide).toBe(false)
	end)
end)

-------------------------------------------------------------------------------
-- InteractionService (remote boundary)
-------------------------------------------------------------------------------

describe("InteractionService", function()
	local env, player
	beforeEach(function()
		env = buildEnv()
		player = joinPlayer(env, "Client", 801, COMPLETED_TUTORIAL)
	end)

	local function invoke(name, ...)
		local remote = env.Remotes.getFunction(name)
		return remote.OnServerInvoke(player, ...)
	end

	it("creates every remote and binds the functions", function()
		local folder = game:GetService("ReplicatedStorage"):FindFirstChild("Remotes")
		expect(folder).toBeTruthy()
		for _, name in ipairs(env.Remotes.Functions) do
			local remote = folder:FindFirstChild(name)
			expect(remote).toBeTruthy()
			expect(type(remote.OnServerInvoke)).toBe("function")
		end
		for _, name in ipairs(env.Remotes.Events) do
			expect(folder:FindFirstChild(name)).toBeTruthy()
		end
	end)

	it("rejects bursts with RateLimited", function()
		for _ = 1, 12 do
			expect(invoke("AcceptOrder", "nope").error).toBe("NotFound")
		end
		expect(invoke("AcceptOrder", "nope").error).toBe("RateLimited")
		shim.advance(1)
		expect(invoke("AcceptOrder", "nope").error).toBe("NotFound")
	end)

	it("validates arguments strictly", function()
		expect(invoke("AcceptOrder", 123).error).toBe("Invalid")
		expect(invoke("AcceptOrder", string.rep("x", 65)).error).toBe("Invalid")
		expect(invoke("AcceptOrder").error).toBe("Invalid")
		expect(invoke("SpawnVehicle", { "Bicycle" }).error).toBe("Invalid")
		expect(invoke("HireDriver", 1.5).error).toBe("Invalid")
		expect(invoke("AdvanceTutorial", "0").error).toBe("Invalid")
		expect(invoke("SaveSettings", "nope").error).toBe("Invalid")
		local big = {}
		for i = 1, 40 do
			big["k" .. i] = i
		end
		expect(invoke("SaveSettings", big).error).toBe("Invalid")
	end)

	it("per-order limiter throttles pickup spam and wraps failures", function()
		local order = pizzaOrder(env, player)
		expect(invoke("AcceptOrder", order.id).ok).toBe(true)
		moveTo(player, env.world.businesses.SliceStreetPizza.pickupPosition)
		-- Break the service to prove the pcall wrapper returns Internal.
		local real = env.services.OrderService.RequestPickup
		env.services.OrderService.RequestPickup = function()
			error("boom")
		end
		expect(invoke("RequestPickup", order.id).error).toBe("Internal")
		env.services.OrderService.RequestPickup = real
		expect(invoke("RequestPickup", order.id).error).toBe("RateLimited")
		shim.advance(0.35)
		expect(invoke("RequestPickup", order.id).ok).toBe(true)
	end)

	it("returns Unavailable for services that are not loaded", function()
		expect(invoke("PurchaseDepot").error).toBe("Unavailable")
		expect(invoke("JoinContract", "LunchRush", { "a", "b" }).error).toBe("Unavailable")
		expect(invoke("JoinContract", "LunchRush", { 1 }).error).toBe("Invalid")
	end)

	it("gates on the profile being loaded", function()
		shim.datastore.failNextCalls = 1
		local loading = shim.addPlayer("Loading", 802)
		local remote = env.Remotes.getFunction("AcceptOrder")
		expect(remote.OnServerInvoke(loading, "x").error).toBe("Locked")
		shim.advance(2)
		expect(remote.OnServerInvoke(loading, "x").error).toBe("NotFound")
	end)

	it("assembles the snapshot", function()
		local Vehicles = env.services.VehicleService
		Vehicles.Spawn(player, "Bicycle")
		local snapshot = invoke("GetSnapshot")
		expect(snapshot.ok).toBe(true)
		expect(snapshot.profile.cash).toBe(0)
		expect(snapshot.profile.lastSeen).toBeNil()
		expect(snapshot.tutorial.completed).toBe(true)
		expect(snapshot.vehicle.state).toBe("Parked")
		expect(snapshot.vehicle.vehicleId).toBe("Bicycle")
		expect(#snapshot.orders.available).toBeGreaterThanOrEqual(3)
		expect(snapshot.orders.capacity.max).toBe(1)
		expect(snapshot.contract).toBeNil()
		expect(snapshot.depot).toBeNil()
		expect(type(snapshot.serverTime)).toBe("number")
	end)

	it("sanitizes settings field by field", function()
		local result = invoke("SaveSettings", { cameraSensitivity = 9, musicVolume = -1, sfxVolume = 0.5, reducedMotion = "yes", showMinimap = false, junk = 1 })
		expect(result.ok).toBe(true)
		expect(result.settings.cameraSensitivity).toBe(3)
		expect(result.settings.musicVolume).toBe(0)
		expect(result.settings.sfxVolume).toBe(0.5)
		expect(result.settings.reducedMotion).toBe(false)
		expect(result.settings.showMinimap).toBe(false)
		expect(result.settings.autoRecenter).toBe(true)
		expect(result.settings.junk).toBeNil()
		local profile = env.services.PlayerDataService.GetProfile(player)
		expect(profile.settings.cameraSensitivity).toBe(3)
		expect(profile.settings.showMinimap).toBe(false)
	end)

	it("drives the full vehicle + delivery flow through remotes", function()
		expect(invoke("SpawnVehicle", "Bicycle").ok).toBe(true)
		local record = env.services.VehicleService.GetVehicle(player)
		moveTo(player, record.chassis.Position + v3(2, 0, 0))
		expect(invoke("MountVehicle").ok).toBe(true)
		local order = pizzaOrder(env, player)
		expect(invoke("AcceptOrder", order.id).ok).toBe(true)
		record.model:PivotTo(CFrame.new(env.world.businesses.SliceStreetPizza.pickupPosition + v3(0, 1.5, 0)))
		expect(invoke("RequestPickup", order.id).ok).toBe(true)
		record.model:PivotTo(CFrame.new(env.world.destinations.D_Near.arrivalPosition + v3(0, 1.5, 0)))
		local delivered = invoke("RequestDelivery", order.id)
		expect(delivered.ok).toBe(true)
		expect(delivered.payout.total).toBe(order.basePay + order.tipMax)
		expect(invoke("DismountVehicle").ok).toBe(true)
		expect(invoke("RecoverVehicle").ok).toBe(true)
		expect(invoke("DespawnVehicle").ok).toBe(true)
		expect(invoke("CancelOrder", order.id).error).toBe("NotFound")
	end)
end)
