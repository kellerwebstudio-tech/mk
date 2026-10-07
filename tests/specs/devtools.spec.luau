--!nonstrict
-- tests/specs/devtools.spec.luau
-- Offline specs for the Studio-only developer tooling: DevService (server), HandlingOverrides,
-- the live handling wiring in VehicleController / CameraController and DevPanelController
-- (client). The server fixture mirrors tests/specs/server_core.spec.luau (mini city, real
-- services, CityService stub); the client fixture mirrors tests/specs/client.spec.luau.

local STORE = "DDC_Profiles_v1"

local function v3(x, y, z)
	return Vector3.new(x, y, z)
end

-------------------------------------------------------------------------------
-- Server fixture (same mini city as server_core.spec plus one depot plot)
-------------------------------------------------------------------------------

local LAYOUT = {
	name = "DevTestCity",
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
	depotPlots = { { id = "PlotA", x = 200, z = 200, w = 40, d = 40, facing = { x = 0, z = -1 }, parking = {} } },
	pedestrianPaths = {},
	parkedVehicles = {},
	props = {},
	bikeShortcuts = {},
}

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
	local depotPlots = {}
	for _, p in ipairs(layout.depotPlots) do
		local model = Instance.new("Model")
		model.Name = p.id
		model:SetAttribute("PlotId", p.id)
		model:SetAttribute("OwnerUserId", 0)
		local ground = anchoredPart("Ground", v3(p.x, 0, p.z), model)
		local sign = anchoredPart("Sign", v3(p.x, 4, p.z - 10), model)
		model.PrimaryPart = ground
		model.Parent = depotFolder
		depotPlots[p.id] = {
			model = model,
			origin = CFrame.lookAlong(v3(p.x, 0, p.z), v3(p.facing.x, 0, p.facing.z)),
			parking = {},
			signPart = sign,
			plotId = p.id,
			groundY = 0,
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
		depotPlots = depotPlots,
		hubSpawn = CFrame.lookAlong(v3(hub.spawn.x, 3, hub.spawn.z), v3(hub.spawn.facing.x, 0, hub.spawn.facing.z)),
		vehiclePads = pads,
	}
end

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
	CityService.RESPAWN_HEIGHT = 3
	function CityService.GetSafeRespawnCFrame(position, mask, raise)
		local graph = ctxRef.graph
		local point, edge = RouteGraph.nearestPointOnGraph(graph, position, mask)
		local dir = graph.nodes[edge.b].position - graph.nodes[edge.a].position
		local height = if type(raise) == "number" then raise else CityService.RESPAWN_HEIGHT
		return CFrame.lookAlong(point + v3(0, height, 0), dir.Unit)
	end
	function CityService.GetHubSpawn()
		return world.hubSpawn
	end
	function CityService.GetFreeVehiclePad()
		return world.vehiclePads[1]
	end
	return CityService
end

local FakeVehicleBuilder = {}
function FakeVehicleBuilder.build(vehicleId, ownerUserId)
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
	local bodyRoot = Instance.new("Part")
	bodyRoot.Name = "BodyRoot"
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
	root.Parent = model
	model.PrimaryPart = root
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

local SERVICE_NAMES = { "PlayerDataService", "ProgressionService", "AntiCheatService", "VehicleService", "RewardService", "OrderService", "TutorialService", "ShopService", "ContractService", "DriverService", "DepotService", "InteractionService", "DevService" }
local INIT_ORDER = { "PlayerDataService", "ProgressionService", "CityService", "AntiCheatService", "VehicleService", "RewardService", "OrderService", "TutorialService", "ShopService", "ContractService", "DriverService", "DepotService", "InteractionService", "DevService" }

local function buildEnv()
	shim.setContext("server")
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local RunService = game:GetService("RunService")
	local Shared = ReplicatedStorage:WaitForChild("Shared")
	local Remotes = require(Shared.Util.Remotes)
	local RouteGraph = require(Shared.City.RouteGraph)
	local root = game:GetService("ServerScriptService"):WaitForChild("DeliveryDash")
	local servicesFolder = root:WaitForChild("Services")
	local buildersFolder = root:FindFirstChild("Builders")

	local world = buildWorld(LAYOUT)
	-- Mirrors ServerBootstrap: isStudio comes from RunService (shim.isStudio).
	local ctx = { services = {}, remotes = Remotes, layout = LAYOUT, graph = nil, world = nil, isStudio = RunService:IsStudio(), builders = {} }
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
	return { ctx = ctx, services = ctx.services, world = world, Remotes = Remotes }
end

local function storeProfile(userId, data)
	shim.datastore.data[STORE] = shim.datastore.data[STORE] or {}
	shim.datastore.data[STORE]["u_" .. tostring(userId)] = data
end

local COMPLETED_TUTORIAL = { schemaVersion = 1, tutorial = { completed = true, step = 9 } }

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

local function devRemote()
	local remotes = game:GetService("ReplicatedStorage"):FindFirstChild("Remotes")
	return remotes and remotes:FindFirstChild("DevCommand") or nil
end

local function invoke(env, player, command, args)
	return env.services.DevService.Invoke(player, command, args)
end

local function profileOf(env, player)
	return env.services.PlayerDataService.GetProfile(player)
end

local function mountBicycle(env, player)
	local vehicles = env.services.VehicleService
	expect(vehicles.Spawn(player, "Bicycle").ok).toBe(true)
	local record = vehicles.GetVehicle(player)
	moveTo(player, record.chassis.Position + v3(2, 0, 0))
	expect(vehicles.Mount(player).ok).toBe(true)
	expect(vehicles.IsDriving(player)).toBe(true)
	return record
end

local function findWarning(pattern)
	for _, line in ipairs(shim.warnings) do
		if string.find(line, pattern, 1, true) then
			return line
		end
	end
	return nil
end

-------------------------------------------------------------------------------
-- DevService (server)
-------------------------------------------------------------------------------

describe("DevService gating", function()
	afterEach(function()
		shim.isStudio = false
	end)
	it("creates no DevCommand remote outside Studio and refuses every command", function()
		shim.isStudio = false
		local env = buildEnv()
		expect(devRemote()).toBeNil()
		expect(env.services.DevService.IsEnabled()).toBe(false)
		local player = joinPlayer(env, "Alice", 1)
		local result = invoke(env, player, "GrantCash", { amount = 1000 })
		expect(result.ok).toBe(false)
		expect(result.error).toBe("Unavailable")
		expect(profileOf(env, player).cash).toBe(0)
	end)

	it("creates the remote directly under ReplicatedStorage.Remotes in Studio, outside the Remotes lists", function()
		shim.isStudio = true
		local env = buildEnv()
		local remote = devRemote()
		expect(remote).toBeTruthy()
		expect(remote.ClassName).toBe("RemoteFunction")
		expect(env.services.DevService.IsEnabled()).toBe(true)
		local listed = false
		for _, name in ipairs(env.Remotes.Functions) do
			if name == "DevCommand" then
				listed = true
			end
		end
		expect(listed).toBe(false)
		-- The remote routes to Invoke with the calling player.
		local player = joinPlayer(env, "Alice", 1)
		shim.setLocalPlayer(player)
		local result = remote:InvokeServer("GrantCash", { amount = 5 })
		expect(result.ok).toBe(true)
		expect(profileOf(env, player).cash).toBe(5)
	end)
end)

describe("DevService commands", function()
	local env, player
	afterEach(function()
		shim.isStudio = false
	end)
	beforeEach(function()
		shim.isStudio = true
		env = buildEnv()
		player = joinPlayer(env, "Alice", 1)
	end)

	it("validates command names and arguments", function()
		-- Spaced out so the 10/s limiter never masks a validation result.
		local function check(command, args)
			shim.advance(0.2)
			return invoke(env, player, command, args)
		end
		expect(check(123).error).toBe("Invalid")
		expect(check(string.rep("x", 65)).error).toBe("Invalid")
		expect(check("NoSuchCommand").error).toBe("NotFound")
		expect(check("GrantCash", "nope").error).toBe("Invalid")
		expect(check("GrantCash", { amount = "1000" }).error).toBe("Invalid")
		expect(check("GrantCash", { amount = 0 }).error).toBe("Invalid")
		expect(check("GrantCash", { amount = 1.5 }).error).toBe("Invalid")
		expect(check("GrantCash", { amount = 1e7 }).error).toBe("Invalid")
		expect(check("GrantCash", { amount = math.huge }).error).toBe("Invalid")
		expect(check("GrantCash", { amount = 0 / 0 }).error).toBe("Invalid")
		expect(check("GrantRep", { amount = 1e5 + 1 }).error).toBe("Invalid")
		expect(check("Teleport", { target = string.rep("a", 65) }).error).toBe("Invalid")
		expect(check("Teleport", { target = { nested = true } }).error).toBe("Invalid")
		expect(check("Teleport", { [string.rep("k", 65)] = "hub" }).error).toBe("Invalid")
		local big = {}
		for index = 1, 20 do
			big["k" .. index] = index
		end
		expect(check("Report", big).error).toBe("Invalid")
		expect(profileOf(env, player).cash).toBe(0)
	end)

	it("grants cash and reputation and logs each command with warn", function()
		expect(invoke(env, player, "GrantCash", { amount = 1000 }).ok).toBe(true)
		expect(invoke(env, player, "GrantRep", { amount = 100 }).ok).toBe(true)
		local profile = profileOf(env, player)
		expect(profile.cash).toBe(1000)
		expect(profile.reputation).toBe(100)
		expect(findWarning("[DevService] GrantCash by Alice {amount=1000} -> ok")).toBeTruthy()
		expect(findWarning("[DevService] GrantRep by Alice {amount=100} -> ok")).toBeTruthy()
	end)

	it("rate limits to 10 commands per second per player", function()
		local limited = 0
		for _ = 1, 12 do
			local result = invoke(env, player, "Report")
			if result.error == "RateLimited" then
				limited += 1
			end
		end
		expect(limited).toBe(2)
		shim.advance(1)
		expect(invoke(env, player, "Report").ok).toBe(true)
	end)

	it("UnlockAll owns every vehicle, upgrade and free cosmetic and raises cash / rep floors", function()
		local result = invoke(env, player, "UnlockAll")
		expect(result.ok).toBe(true)
		local profile = profileOf(env, player)
		local VehicleDefinitions = shim.requirePath("ReplicatedStorage/Shared/Definitions/VehicleDefinitions")
		local UpgradeDefinitions = shim.requirePath("ReplicatedStorage/Shared/Definitions/UpgradeDefinitions")
		local CosmeticDefinitions = shim.requirePath("ReplicatedStorage/Shared/Definitions/CosmeticDefinitions")
		for vehicleId in pairs(VehicleDefinitions.Vehicles) do
			expect(profile.ownedVehicles[vehicleId]).toBe(true)
		end
		for upgradeId in pairs(UpgradeDefinitions.Upgrades) do
			expect(env.services.ProgressionService.GetUpgradeLevel(profile, upgradeId)).toBe(1)
		end
		local paidSeen = false
		for _, item in ipairs(CosmeticDefinitions.Items) do
			if item.paidOnly then
				paidSeen = true
				expect(profile.cosmetics.owned[item.id]).toBeFalsy()
			else
				expect(profile.cosmetics.owned[item.id]).toBe(true)
			end
		end
		expect(paidSeen).toBe(true)
		expect(profile.reputation).toBeGreaterThanOrEqual(2000)
		expect(profile.cash).toBeGreaterThanOrEqual(50000)
		expect(result.profile.cash).toBe(profile.cash)
	end)

	it("SkipTutorial completes the tutorial through TutorialService and withdraws tutorial orders", function()
		local tutorial = env.services.TutorialService
		local orders = env.services.OrderService
		expect(tutorial.GetStep(player)).toBe(0)
		expect(tutorial.AdvanceTutorial(player, 0).ok).toBe(true)
		expect(tutorial.GetStep(player)).toBe(1)
		expect(#orders.GetAvailable(player)).toBe(1)
		expect(orders.GetAvailable(player)[1].isTutorial).toBe(true)
		expect(orders.IsGeneratorEnabled(player)).toBe(false)

		local result = invoke(env, player, "SkipTutorial")
		expect(result.ok).toBe(true)
		expect(result.completed).toBe(true)
		expect(result.cancelled).toBe(1)
		local profile = profileOf(env, player)
		expect(profile.tutorial.completed).toBe(true)
		expect(profile.tutorial.step).toBe(9)
		expect(player:GetAttribute("TutorialStep")).toBe(9)
		expect(orders.IsGeneratorEnabled(player)).toBe(true)
		local tutorialLeft = 0
		for _, order in ipairs(orders.GetAvailable(player)) do
			if order.isTutorial then
				tutorialLeft += 1
			end
		end
		expect(tutorialLeft).toBe(0)
		local updated = nil
		for _, entry in ipairs(shim.remoteLog) do
			if entry.kind == "FireClient" and entry.remote.Name == "TutorialUpdated" and entry.player == player then
				updated = entry.args[1]
			end
		end
		expect(updated).toBeTruthy()
		expect(updated.step).toBe(9)
		expect(updated.completed).toBe(true)
		-- Already complete: a second call is a no-op.
		expect(invoke(env, player, "SkipTutorial").completed).toBe(false)
	end)

	it("ResetProfile restores defaults in session, cancels orders, despawns the vehicle and restarts the tutorial", function()
		expect(invoke(env, player, "UnlockAll").ok).toBe(true)
		expect(invoke(env, player, "SkipTutorial").ok).toBe(true)
		expect(invoke(env, player, "OwnVehicle", { vehicleId = "Van" }).ok).toBe(true)
		local orders = env.services.OrderService
		expect(#orders.GetAvailable(player)).toBeGreaterThan(0)
		local first = orders.GetAvailable(player)[1]
		expect(orders.Accept(player, first.id).ok).toBe(true)
		expect(#orders.GetActive(player)).toBe(1)

		local result = invoke(env, player, "ResetProfile")
		expect(result.ok).toBe(true)
		expect(result.cancelled).toBeGreaterThan(1)
		local profile = profileOf(env, player)
		local defaults = env.services.PlayerDataService.DEFAULT_PROFILE
		expect(profile.cash).toBe(defaults.cash)
		expect(profile.reputation).toBe(defaults.reputation)
		expect(profile.ownedVehicles).toEqual({ Bicycle = true })
		expect(profile.equippedVehicle).toBe("Bicycle")
		expect(profile.upgrades).toEqual({})
		expect(profile.schemaVersion).toBe(1)
		expect(profile.tutorial.completed).toBe(false)
		expect(profile.tutorial.step).toBe(0)
		expect(env.services.TutorialService.GetStep(player)).toBe(0)
		expect(env.services.VehicleService.GetVehicle(player)).toBeNil()
		expect(#orders.GetActive(player)).toBe(0)
		expect(#orders.GetAvailable(player)).toBe(0)
		expect(orders.IsGeneratorEnabled(player)).toBe(false)
	end)

	it("ResetProfile mid-tutorial leaves no stale tutorial order behind (the cancel hook re-issues it)", function()
		local tutorial = env.services.TutorialService
		local orders = env.services.OrderService
		expect(tutorial.AdvanceTutorial(player, 0).ok).toBe(true)
		expect(tutorial.GetStep(player)).toBe(1)
		expect(#orders.GetAvailable(player)).toBe(1)
		local firstId = orders.GetAvailable(player)[1].id

		local result = invoke(env, player, "ResetProfile")
		expect(result.ok).toBe(true)
		expect(tutorial.GetStep(player)).toBe(0)
		-- Withdrawing the step-1 order makes TutorialService inject a replacement; the reset must
		-- clear that too, otherwise the board holds a tutorial order the restarted tutorial does
		-- not track (and step 1 would add a second one).
		expect(#orders.GetAvailable(player)).toBe(0)
		expect(#orders.GetActive(player)).toBe(0)
		expect(orders.IsGeneratorEnabled(player)).toBe(false)

		expect(tutorial.AdvanceTutorial(player, 0).ok).toBe(true)
		local available = orders.GetAvailable(player)
		expect(#available).toBe(1)
		expect(available[1].isTutorial).toBe(true)
		expect(available[1].id).never.toBe(firstId)
	end)

	it("OwnVehicle grants, equips and spawns; Despawn and Recover pass through", function()
		expect(invoke(env, player, "OwnVehicle", { vehicleId = "Hoverboard" }).error).toBe("Invalid")
		local result = invoke(env, player, "OwnVehicle", { vehicleId = "Scooter" })
		expect(result.ok).toBe(true)
		expect(result.vehicleId).toBe("Scooter")
		local profile = profileOf(env, player)
		expect(profile.ownedVehicles.Scooter).toBe(true)
		expect(profile.equippedVehicle).toBe("Scooter")
		local vehicles = env.services.VehicleService
		expect(vehicles.GetCurrentVehicleId(player)).toBe("Scooter")
		expect(vehicles.GetState(player)).toBe("Parked")
		expect(invoke(env, player, "Recover").ok).toBe(true)
		expect(invoke(env, player, "Despawn").ok).toBe(true)
		expect(vehicles.GetVehicle(player)).toBeNil()
		expect(invoke(env, player, "Despawn").error).toBe("NotFound")
	end)

	it("ListTargets lists the hub, businesses by name, destinations by address and plots", function()
		local result = invoke(env, player, "ListTargets")
		expect(result.ok).toBe(true)
		local byId = {}
		for _, target in ipairs(result.targets) do
			byId[target.id] = target
		end
		expect(byId["hub"].label).toBe("Dash Hub")
		expect(byId["business:SliceStreetPizza"].label).toBe("Slice Street Pizza")
		expect(byId["business:BeanAndBunCafe"].kind).toBe("business")
		expect(byId["destination:D_Near"].label).toBe("1 Main Street")
		expect(byId["destination:D_Far"].label).toBe("3 South Road")
		expect(byId["plot:PlotA"].kind).toBe("plot")
		expect(#result.targets).toBe(1 + 2 + 4 + 1)
	end)

	it("Teleport on foot moves the character 3 studs above the point and suppresses the next anti-cheat sample", function()
		shim.advance(3.5) -- past the respawn suppression window
		local anti = env.services.AntiCheatService
		anti.SampleNow(player)
		expect(anti.GetStrikes(player)).toBe(0)

		expect(invoke(env, player, "Teleport").error).toBe("Invalid")
		expect(invoke(env, player, "Teleport", { target = "nowhere" }).error).toBe("NotFound")
		expect(invoke(env, player, "Teleport", { target = "business:Nope" }).error).toBe("NotFound")
		expect(invoke(env, player, "Teleport", { target = "node:999" }).error).toBe("NotFound")

		local result = invoke(env, player, "Teleport", { target = "destination:D_Far" })
		expect(result.ok).toBe(true)
		expect(result.mode).toBe("character")
		local expected = env.world.destinations.D_Far.arrivalPosition + v3(0, 3, 0)
		local root = player.Character.HumanoidRootPart
		expect(root.Position).toBeCloseTo(expected, 1e-3)
		-- Faces the door.
		expect(root.CFrame.LookVector.X).toBeGreaterThan(0.9)

		shim.advance(1)
		anti.SampleNow(player)
		expect(anti.GetStrikes(player)).toBe(0)
		shim.advance(3)
		anti.SampleNow(player)
		expect(anti.GetStrikes(player)).toBe(0)
		expect(anti.CheckPosition(player)).toBe(true)

		-- Control: the same distance without the server's note is flagged.
		moveTo(player, v3(0, 3, 30))
		shim.advance(1)
		anti.SampleNow(player)
		expect(anti.GetStrikes(player)).toBe(1)
	end)

	it("Teleport while driving moves the vehicle with the rider through VehicleService.TeleportTo", function()
		shim.advance(3.5)
		local vehicles = env.services.VehicleService
		local anti = env.services.AntiCheatService
		local record = mountBicycle(env, player)
		anti.SampleNow(player)

		local result = invoke(env, player, "Teleport", { target = "destination:D_Far" })
		expect(result.ok).toBe(true)
		expect(result.mode).toBe("vehicle")
		-- Nearest allowed road point to the arrival point (5, 260) is South Road at x = 0, raised by rideHeight.
		local rideHeight = shim.requirePath("ReplicatedStorage/Shared/Definitions/VehicleDefinitions").get("Bicycle").handling.rideHeight
		expect(record.chassis.Position).toBeCloseTo(v3(0, rideHeight, 260), 1e-3)
		expect(record.lastSafePosition).toBeCloseTo(record.chassis.Position, 1e-6)
		expect(record.state).toBe("Driving")
		expect(vehicles.IsDriving(player)).toBe(true)
		local root = player.Character.HumanoidRootPart
		expect((root.Position - record.chassis.Position).Magnitude).toBeLessThan(6)
		local align = record.chassis:FindFirstChild("Align")
		if align then
			expect(align.CFrame.LookVector).toBeCloseTo(record.chassis.CFrame.LookVector, 1e-6)
		end

		shim.advance(1)
		anti.SampleNow(player)
		expect(anti.GetStrikes(player)).toBe(0)
		shim.advance(3)
		anti.SampleNow(player)
		expect(anti.GetStrikes(player)).toBe(0)

		-- A direct TeleportTo while Parked moves the vehicle alone and keeps it anchored.
		expect(vehicles.Dismount(player).ok).toBe(true)
		local parkedResult = vehicles.TeleportTo(player, CFrame.new(100, 0, 0))
		expect(parkedResult.ok).toBe(true)
		expect(record.chassis.Position).toBeCloseTo(v3(100, rideHeight, 0), 1e-3)
		expect(record.chassis.Anchored).toBe(true)
		expect(vehicles.TeleportTo(player, "bad").error).toBe("Invalid")
	end)

	it("SetSpeedCap raises the anti-cheat allowance for that vehicle and clears with 0", function()
		shim.advance(3.5)
		local anti = env.services.AntiCheatService
		expect(invoke(env, player, "SetSpeedCap", { vehicleId = "Bicycle", maxSpeed = -1 }).error).toBe("Invalid")
		expect(invoke(env, player, "SetSpeedCap", { vehicleId = "Rocket", maxSpeed = 80 }).error).toBe("Invalid")
		local result = invoke(env, player, "SetSpeedCap", { vehicleId = "Bicycle", maxSpeed = 80 })
		expect(result.ok).toBe(true)
		expect(anti.GetSpeedOverride(player, "Bicycle")).toBe(80)

		local record = mountBicycle(env, player)
		-- The 1 s sampling loop takes one sample with the vehicle at rest, then one after a 120 stud
		-- jump: above the definition allowance (38 * 1.8 + 24 = 92.4 per second) but inside the
		-- cap's (80 * 1.8 + 24 = 168).
		shim.advance(1.05)
		record.model:PivotTo(record.chassis.CFrame + v3(0, 0, -120))
		shim.advance(1)
		expect(anti.GetStrikes(player)).toBe(0)

		expect(invoke(env, player, "SetSpeedCap", { vehicleId = "Bicycle", maxSpeed = 0 }).ok).toBe(true)
		expect(anti.GetSpeedOverride(player, "Bicycle")).toBeNil()
		shim.advance(1.05)
		record.model:PivotTo(record.chassis.CFrame + v3(0, 0, -120))
		shim.advance(1)
		expect(anti.GetStrikes(player)).toBe(1)

		-- Overrides are session state: gone when the player leaves.
		expect(invoke(env, player, "SetSpeedCap", { vehicleId = "Van", maxSpeed = 90 }).ok).toBe(true)
		shim.removePlayer(player)
		shim.advance(0.1)
		expect(anti.GetSpeedOverride(player, "Van")).toBeNil()
	end)

	it("FinishDrivers completes every active assignment at once", function()
		local playerData = env.services.PlayerDataService
		local now = os.time()
		playerData.Update(player, function(profile)
			profile.depot = {
				owned = true,
				slotsUnlocked = 2,
				drivers = {
					{ hired = true, name = "Max", pending = 0, assignment = { id = "a1", category = "Local", startedAt = now, endsAt = now + 600, revenue = 120, cost = 50, net = 70, completed = false } },
					{ hired = true, name = "Ivy", pending = 0, assignment = { id = "a2", category = "Local", startedAt = now, endsAt = now + 900, revenue = 200, cost = 80, net = 120, completed = false } },
				},
			}
		end)
		local result = invoke(env, player, "FinishDrivers")
		expect(result.ok).toBe(true)
		expect(result.forced).toBe(2)
		expect(result.completed).toBe(2)
		local depot = profileOf(env, player).depot
		expect(depot.drivers[1].assignment.completed).toBe(true)
		expect(depot.drivers[1].pending).toBe(120)
		expect(depot.drivers[2].assignment.completed).toBe(true)
		expect(depot.drivers[2].pending).toBe(200)
		-- Nothing left to force.
		local again = invoke(env, player, "FinishDrivers")
		expect(again.forced).toBe(0)
		expect(again.completed).toBe(0)
	end)

	it("FillBoard reports a disabled generator during the tutorial and fills the board afterwards", function()
		local disabled = invoke(env, player, "FillBoard")
		expect(disabled.ok).toBe(true)
		expect(disabled.generatorEnabled).toBe(false)
		expect(disabled.message).toMatch("Generator disabled")

		local veteran = joinPlayer(env, "Bob", 2, COMPLETED_TUTORIAL)
		local orders = env.services.OrderService
		for _, order in ipairs(table.clone(orders.GetAvailable(veteran))) do
			orders.Cancel(veteran, order.id, { silent = true, noPenalty = true })
		end
		expect(#orders.GetAvailable(veteran)).toBe(0)
		local filled = invoke(env, veteran, "FillBoard")
		expect(filled.ok).toBe(true)
		expect(filled.generatorEnabled).toBe(true)
		expect(filled.available).toBeGreaterThanOrEqual(3)
		expect(filled.added).toBe(filled.available)
	end)

	it("ReadyOrders makes every Accepted order ready for pickup immediately", function()
		local veteran = joinPlayer(env, "Bob", 2, COMPLETED_TUTORIAL)
		local orders = env.services.OrderService
		local order = orders.CreateOrder(veteran, { businessId = "SliceStreetPizza", destinationId = "D_Near", size = "Small", itemCategory = "Pizza", prepTimeOverride = 120 })
		orders.InjectOrders(veteran, { order })
		expect(orders.Accept(veteran, order.id).ok).toBe(true)
		expect(order.state).toBe("Accepted")
		expect(orders.RequestPickup(veteran, order.id).error).toBe("NotReady")
		local result = invoke(env, veteran, "ReadyOrders")
		expect(result.ok).toBe(true)
		expect(result.readied).toBe(1)
		expect(order.state).toBe("ReadyForPickup")
		expect(invoke(env, veteran, "ReadyOrders").readied).toBe(0)
	end)

	it("OpenLunchRush opens a rush in the chosen neighbourhood; ExpireContract reports the missing API", function()
		expect(invoke(env, player, "OpenLunchRush", { neighborhood = "Atlantis" }).error).toBe("Invalid")
		local result = invoke(env, player, "OpenLunchRush", { neighborhood = "Residential" })
		expect(result.ok).toBe(true)
		expect(result.contract.status).toBe("Open")
		expect(result.contract.neighborhood).toBe("Residential")
		local cycle = env.services.ContractService.GetCycle()
		expect(cycle.status).toBe("Open")
		expect(cycle.neighborhood).toBe("Residential")
		local expire = invoke(env, player, "ExpireContract")
		expect(expire.ok).toBe(false)
		expect(expire.error).toBe("Unavailable")
	end)

	it("Report returns the documented snapshot", function()
		expect(invoke(env, player, "GrantCash", { amount = 250 }).ok).toBe(true)
		expect(invoke(env, player, "OwnVehicle", { vehicleId = "Bicycle" }).ok).toBe(true)
		local result = invoke(env, player, "Report")
		expect(result.ok).toBe(true)
		expect(result.cash).toBe(250)
		expect(result.reputation).toBe(0)
		expect(result.deliveries).toBe(0)
		expect(result.tutorialStep).toBe(0)
		expect(result.tutorialCompleted).toBe(false)
		expect(result.vehicle).toEqual({ state = "Parked", vehicleId = "Bicycle" })
		expect(result.activeOrders).toEqual({})
		expect(result.contract.status).toBe("Idle")
		expect(result.depot.owned).toBe(false)
		expect(result.depot.pending).toBe(0)
		expect(result.antiCheatStrikes).toBe(0)

		local veteran = joinPlayer(env, "Bob", 2, COMPLETED_TUTORIAL)
		local orders = env.services.OrderService
		local order = orders.CreateOrder(veteran, { businessId = "SliceStreetPizza", destinationId = "D_Near", size = "Small", itemCategory = "Pizza", prepTimeOverride = 0 })
		orders.InjectOrders(veteran, { order })
		expect(orders.Accept(veteran, order.id).ok).toBe(true)
		local report = invoke(env, veteran, "Report")
		expect(#report.activeOrders).toBe(1)
		expect(report.activeOrders[1].id).toBe(order.id)
		expect(report.activeOrders[1].business).toBe("SliceStreetPizza")
		expect(report.activeOrders[1].destination).toBe("D_Near")
		expect(report.tutorialCompleted).toBe(true)
	end)
end)

-------------------------------------------------------------------------------
-- Client fixture (mirrors client.spec.luau)
-------------------------------------------------------------------------------

local function clientRoot()
	local starterPlayer = game:GetService("StarterPlayer")
	for _, child in ipairs(starterPlayer:GetChildren()) do
		local root = child:FindFirstChild("DeliveryDashClient")
		if root then
			return root
		end
	end
	error("DeliveryDashClient not found under StarterPlayer")
end

local function clientInstance(relativePath)
	local current = clientRoot()
	for segment in relativePath:gmatch("[^/]+") do
		local nxt = current:FindFirstChild(segment)
		if not nxt then
			error("No client instance at " .. relativePath .. " (missing " .. segment .. ")")
		end
		current = nxt
	end
	return current
end

local function requireClient(relativePath)
	return require(clientInstance(relativePath))
end

local function svc(name)
	return game:GetService(name)
end

local CLIENT_LAYOUT = {
	name = "DevClientCity",
	bounds = { minX = -400, maxX = 400, minZ = -400, maxZ = 400 },
	groundY = 0,
	killY = -60,
	neighborhoods = { { id = "Downtown", name = "Downtown", center = { x = 0, z = 0 }, bounds = { minX = -400, maxX = 400, minZ = -400, maxZ = 400 }, accent = { r = 1, g = 0.5, b = 0.2 } } },
	roads = {
		{ id = "Main", name = "Main Street", kind = "Road", width = 12, points = { { x = 0, z = 300 }, { x = 0, z = -300 } } },
	},
	water = {},
	bridges = {},
	buildings = {},
	businesses = {},
	destinations = {},
	landmarks = {},
	hub = { spawn = { x = 0, z = 30, facing = { x = 0, z = -1 } }, vehiclePads = {}, kiosk = { x = 0, z = 40 } },
	depotPlots = {},
	pedestrianPaths = {},
	parkedVehicles = {},
	props = {},
	bikeShortcuts = {},
}

local function newUIStub()
	local Signal = shim.requirePath("ReplicatedStorage/Shared/Util/Signal")
	local ui = { modal = false, notifications = {}, hud = nil, ModalChanged = Signal.new(), TutorialContinue = Signal.new(), PromptActivated = Signal.new() }
	function ui.Init() end
	function ui.Start() end
	function ui.Notify(text, kind, duration)
		table.insert(ui.notifications, { text = text, kind = kind, duration = duration })
	end
	function ui.IsModalOpen()
		return ui.modal
	end
	function ui.SetVehicleHud(data)
		ui.hud = data
	end
	function ui.ShowPrompt() end
	function ui.HidePrompt() end
	function ui.OpenScreen() end
	function ui.CloseScreen() end
	function ui.GetScreenGui()
		return nil
	end
	return ui
end

local function createRemotes(handlers)
	local Remotes = shim.requirePath("ReplicatedStorage/Shared/Util/Remotes")
	Remotes.createAll()
	for _, name in ipairs(Remotes.Functions) do
		local remote = Remotes.getFunction(name)
		remote.OnServerInvoke = (handlers and handlers[name]) or function()
			return { ok = true }
		end
	end
	return Remotes
end

local function setup(controllerNames, opts)
	opts = opts or {}
	shim.setContext("client")
	local ClientState = requireClient("ClientState")
	ClientState.setLayout(CLIENT_LAYOUT)
	local Remotes = createRemotes(opts.handlers)
	local ui = newUIStub()
	local RouteGraph = shim.requirePath("ReplicatedStorage/Shared/City/RouteGraph")
	local ctx = { state = ClientState, remotes = Remotes, layout = CLIENT_LAYOUT, graph = RouteGraph.build(CLIENT_LAYOUT), controllers = { UIController = ui } }
	local ordered = {}
	for _, name in ipairs(controllerNames) do
		local controller = requireClient("Controllers/" .. name)
		ctx.controllers[name] = controller
		table.insert(ordered, controller)
	end
	for _, controller in ipairs(ordered) do
		controller.Init(ctx)
	end
	for _, controller in ipairs(ordered) do
		controller.Start()
	end
	return ctx, ui, ClientState
end

local function spawnAt(x, z)
	local player = svc("Players").LocalPlayer
	return shim.spawnCharacter(player, CFrame.new(x, 3, z))
end

local function buildVehicleModel(vehicleId, ownerUserId, position)
	local VehicleDefinitions = shim.requirePath("ReplicatedStorage/Shared/Definitions/VehicleDefinitions")
	local def = VehicleDefinitions.get(vehicleId)
	local model = Instance.new("Model")
	model.Name = "Vehicle"
	model:SetAttribute("OwnerUserId", ownerUserId)
	model:SetAttribute("VehicleId", vehicleId)
	model:SetAttribute("State", "Parked")
	local chassis = Instance.new("Part")
	chassis.Name = "Chassis"
	chassis.Size = v3(def.chassisSize[1], def.chassisSize[2], def.chassisSize[3])
	chassis.CFrame = CFrame.new(position + v3(0, def.handling.rideHeight, 0))
	chassis.Anchored = true
	chassis.Parent = model
	model.PrimaryPart = chassis
	local root = Instance.new("Attachment")
	root.Name = "RootAttachment"
	root.Parent = chassis
	local align = Instance.new("AlignOrientation")
	align.Name = "Align"
	align.Attachment0 = root
	align.Parent = chassis
	local velocity = Instance.new("LinearVelocity")
	velocity.Name = "Velocity"
	velocity.Attachment0 = root
	velocity.VectorVelocity = Vector3.zero
	velocity.Parent = chassis
	for _, name in ipairs({ "CargoAttachment", "DismountAttachment" }) do
		local att = Instance.new("Attachment")
		att.Name = name
		att.Parent = chassis
	end
	local bodyRoot = Instance.new("Part")
	bodyRoot.Name = "BodyRoot"
	bodyRoot.CFrame = chassis.CFrame
	bodyRoot.Parent = model
	local bodyMotor = Instance.new("Motor6D")
	bodyMotor.Name = "BodyMotor"
	bodyMotor.Part0 = chassis
	bodyMotor.Part1 = bodyRoot
	bodyMotor.Parent = bodyRoot
	local seat = Instance.new("VehicleSeat")
	seat.Name = "Seat"
	seat.CFrame = chassis.CFrame * CFrame.new(def.seatOffset[1], def.seatOffset[2], def.seatOffset[3])
	seat.Parent = model
	local wheels = Instance.new("Folder")
	wheels.Name = "Wheels"
	wheels.Parent = model
	local runtime = svc("Workspace"):FindFirstChild("Runtime")
	local vehiclesFolder = runtime and runtime:FindFirstChild("Vehicles")
	model.Parent = vehiclesFolder or svc("Workspace")
	return model, chassis, seat, velocity
end

-- Creates the Studio-only remote with a stub server (records commands) before the client starts.
local function createDevRemote(handler)
	shim.setContext("server")
	local Remotes = shim.requirePath("ReplicatedStorage/Shared/Util/Remotes")
	Remotes.createAll()
	local remote = Instance.new("RemoteFunction")
	remote.Name = "DevCommand"
	remote.Parent = svc("ReplicatedStorage").Remotes
	local calls = {}
	remote.OnServerInvoke = function(player, command, args)
		table.insert(calls, { command = command, args = args })
		if handler then
			local result = handler(command, args)
			if result ~= nil then
				return result
			end
		end
		return { ok = true }
	end
	return remote, calls
end

local function playerGui()
	return svc("Players").LocalPlayer:FindFirstChildOfClass("PlayerGui")
end

-------------------------------------------------------------------------------
-- HandlingOverrides
-------------------------------------------------------------------------------

describe("HandlingOverrides", function()
	local HandlingOverrides, VehicleDefinitions
	beforeEach(function()
		shim.setContext("client")
		HandlingOverrides = requireClient("HandlingOverrides")
		VehicleDefinitions = shim.requirePath("ReplicatedStorage/Shared/Definitions/VehicleDefinitions")
	end)

	it("returns the definition's own handling table when nothing is overridden", function()
		local def = VehicleDefinitions.get("Bicycle")
		expect(HandlingOverrides.get("Bicycle")).toBe(def.handling)
		expect(HandlingOverrides.get("Van")).toBe(VehicleDefinitions.get("Van").handling)
		expect(HandlingOverrides.get("Nope")).toBe(def.handling)
		expect(HandlingOverrides.getOverrides("Bicycle")).toEqual({})
		expect(HandlingOverrides.hasOverrides("Bicycle")).toBe(false)
	end)

	it("set merges a copy, fires Changed, leaves the definition untouched and clears on default / reset", function()
		local def = VehicleDefinitions.get("Bicycle")
		local fired = {}
		HandlingOverrides.Changed:Connect(function(vehicleId)
			table.insert(fired, vehicleId)
		end)
		expect(HandlingOverrides.set("Bicycle", "maxSpeed", 50)).toBe(true)
		expect(fired).toEqual({ "Bicycle" })
		local merged = HandlingOverrides.get("Bicycle")
		expect(merged).never.toBe(def.handling)
		expect(merged.maxSpeed).toBe(50)
		expect(merged.acceleration).toBe(def.handling.acceleration)
		expect(merged.cameraDistance).toBe(def.handling.cameraDistance)
		expect(def.handling.maxSpeed).toBe(38)
		expect(HandlingOverrides.get("Bicycle")).toBe(merged) -- cached until the next change
		expect(HandlingOverrides.getOverrides("Bicycle")).toEqual({ maxSpeed = 50 })
		expect(HandlingOverrides.get("Scooter")).toBe(VehicleDefinitions.get("Scooter").handling)

		-- Same value again: nothing changes, no signal.
		expect(HandlingOverrides.set("Bicycle", "maxSpeed", 50)).toBe(false)
		expect(#fired).toBe(1)
		-- Invalid key / value / vehicle are ignored.
		expect(HandlingOverrides.set("Bicycle", "noSuchKey", 1)).toBe(false)
		expect(HandlingOverrides.set("Bicycle", "maxSpeed", 0 / 0)).toBe(false)
		expect(HandlingOverrides.set("Bicycle", "maxSpeed", math.huge)).toBe(false)
		expect(HandlingOverrides.set("Rocket", "maxSpeed", 10)).toBe(false)
		expect(#fired).toBe(1)

		-- Setting the definition value removes the override; the plain table comes back.
		expect(HandlingOverrides.set("Bicycle", "maxSpeed", 38)).toBe(true)
		expect(#fired).toBe(2)
		expect(HandlingOverrides.get("Bicycle")).toBe(def.handling)

		expect(HandlingOverrides.set("Bicycle", "cameraDistance", 20)).toBe(true)
		expect(HandlingOverrides.set("Bicycle", "turnRate", 3.1)).toBe(true)
		expect(HandlingOverrides.reset("Bicycle")).toBe(true)
		expect(fired[#fired]).toBe("Bicycle")
		expect(HandlingOverrides.get("Bicycle")).toBe(def.handling)
		expect(HandlingOverrides.reset("Bicycle")).toBe(false)
	end)

	it("snippet lists the full merged handling as a pasteable Luau block", function()
		HandlingOverrides.set("Bicycle", "maxSpeed", 50)
		HandlingOverrides.set("Bicycle", "minTurnFactor", 0.35)
		local text = HandlingOverrides.snippet("Bicycle")
		expect(text).toMatch("^handling = {\n")
		expect(text).toMatch("\n},$")
		expect(text).toMatch("\tmaxSpeed = 50, %-%- was 38\n")
		expect(text).toMatch("\tminTurnFactor = 0%.35, %-%- was 0%.4\n")
		expect(text).toMatch("\tacceleration = 22,\n")
		expect(text).toMatch("\tcameraDistance = 13,\n")
		expect(text).toMatch("\tfovSpeedBoost = 6,\n")
		-- Every numeric handling key is present exactly once, in definition order.
		local count = 0
		for _ in string.gmatch(text, "\n\t[%a]+ = ") do
			count += 1
		end
		local keys = 0
		for key, value in pairs(VehicleDefinitions.get("Bicycle").handling) do
			if type(value) == "number" then
				keys += 1
			end
		end
		expect(count).toBe(keys)
		expect(string.find(text, "maxSpeed", 1, true)).toBeLessThan(string.find(text, "reverseSpeed", 1, true))
		-- The pasted block parses as Luau.
		local chunk = loadstring("return { " .. text .. " }")
		expect(chunk).toBeTruthy()
		local parsed = chunk()
		expect(parsed.handling.maxSpeed).toBe(50)
		expect(parsed.handling.minTurnFactor).toBeCloseTo(0.35, 1e-9)
		-- No overrides: plain values, no comments.
		HandlingOverrides.reset("Bicycle")
		expect(HandlingOverrides.snippet("Bicycle")).never.toMatch("was")
	end)
end)

-------------------------------------------------------------------------------
-- Live wiring: VehicleController and CameraController
-------------------------------------------------------------------------------

describe("HandlingOverrides live wiring", function()
	it("an active VehicleController picks up a changed maxSpeed / acceleration on the next step", function()
		local ctx, _, ClientState = setup({ "InputController", "VehicleController" })
		local HandlingOverrides = requireClient("HandlingOverrides")
		local character = spawnAt(0, 0)
		local model, chassis, seat, velocity = buildVehicleModel("Bicycle", 1, v3(0, 0, 0))
		-- No physics in the harness: mirror the commanded velocity back as the assembly velocity so
		-- the controller's blocked detection (actual << commanded) never fires.
		svc("RunService").Heartbeat:Connect(function()
			chassis.AssemblyLinearVelocity = velocity.VectorVelocity
		end)
		seat:Sit(character.Humanoid)
		seat.ThrottleFloat = 1
		ClientState.set("vehicle", { state = "Driving", vehicleId = "Bicycle", model = model })
		shim.advance(3)
		local VehicleController = ctx.controllers.VehicleController
		expect(VehicleController.IsActive()).toBe(true)
		expect(VehicleController.GetSpeed()).toBeCloseTo(38, 1e-3)
		expect(VehicleController.GetHandling()).toBe(shim.requirePath("ReplicatedStorage/Shared/Definitions/VehicleDefinitions").get("Bicycle").handling)

		-- Lower cap: the very next frames clamp the speed down to it.
		HandlingOverrides.set("Bicycle", "maxSpeed", 20)
		expect(VehicleController.GetHandling().maxSpeed).toBe(20)
		shim.advance(0.2)
		expect(VehicleController.GetSpeed()).toBeCloseTo(20, 1e-3)
		expect(velocity.VectorVelocity.Magnitude).toBeCloseTo(20, 1e-2)

		-- Higher cap with a bigger acceleration: climbs past the definition's 38 within a second.
		HandlingOverrides.set("Bicycle", "maxSpeed", 60)
		HandlingOverrides.set("Bicycle", "acceleration", 100)
		shim.advance(1)
		expect(VehicleController.GetSpeed()).toBeCloseTo(60, 1e-3)
		expect(VehicleController.GetSpeedFraction()).toBeCloseTo(1, 1e-3)

		-- Overrides for another vehicle do not touch the active one.
		HandlingOverrides.set("Van", "maxSpeed", 5)
		shim.advance(0.2)
		expect(VehicleController.GetSpeed()).toBeCloseTo(60, 1e-3)

		-- Reset restores the shipped table identity and cap.
		HandlingOverrides.resetAll()
		shim.advance(0.2)
		expect(VehicleController.GetSpeed()).toBeCloseTo(38, 1e-3)
		expect(VehicleController.GetHandling()).toBe(shim.requirePath("ReplicatedStorage/Shared/Definitions/VehicleDefinitions").get("Bicycle").handling)
	end)

	it("CameraController follows at the overridden cameraDistance and refreshes when it changes", function()
		local ctx, _, ClientState = setup({ "CameraController" })
		local HandlingOverrides = requireClient("HandlingOverrides")
		local handling = shim.requirePath("ReplicatedStorage/Shared/Definitions/VehicleDefinitions").get("Bicycle").handling
		spawnAt(0, 0)
		local model, chassis = buildVehicleModel("Bicycle", 1, v3(0, 0, 0))
		HandlingOverrides.set("Bicycle", "cameraDistance", 30)
		ClientState.set("vehicle", { state = "Driving", vehicleId = "Bicycle", model = model })
		shim.step(1 / 60)
		local camera = svc("Workspace").CurrentCamera
		expect(camera.CameraType).toBe(Enum.CameraType.Scriptable)
		local pivot = chassis.Position + v3(0, handling.cameraHeight, 0)
		expect((camera.CFrame.Position - pivot).Magnitude).toBeCloseTo(30, 1e-3)

		HandlingOverrides.set("Bicycle", "cameraDistance", 18)
		HandlingOverrides.set("Bicycle", "cameraHeight", 9)
		for _ = 1, 400 do
			shim.step(1 / 60)
		end
		local newPivot = chassis.Position + v3(0, 9, 0)
		expect((camera.CFrame.Position - newPivot).Magnitude).toBeCloseTo(18, 0.05)

		HandlingOverrides.reset("Bicycle")
		for _ = 1, 400 do
			shim.step(1 / 60)
		end
		expect((camera.CFrame.Position - pivot).Magnitude).toBeCloseTo(handling.cameraDistance, 0.05)
	end)
end)

-------------------------------------------------------------------------------
-- DevPanelController
-------------------------------------------------------------------------------

describe("DevPanelController", function()
	afterEach(function()
		shim.isStudio = false
	end)
	it("stays dormant outside Studio even when the remote exists", function()
		shim.isStudio = false
		createDevRemote()
		local ctx = setup({ "DevPanelController" })
		shim.advance(1)
		local panelController = ctx.controllers.DevPanelController
		expect(panelController.IsEnabled()).toBe(false)
		expect(panelController.GetGui()).toBeNil()
		expect(playerGui():FindFirstChild("DDC_Dev")).toBeNil()
		panelController.Toggle()
		expect(panelController.IsOpen()).toBe(false)
		expect(panelController.Invoke("Report").error).toBe("Unavailable")
	end)

	it("stays dormant in Studio when the server created no DevCommand remote", function()
		shim.isStudio = true
		local ctx = setup({ "DevPanelController" })
		shim.advance(25)
		local panelController = ctx.controllers.DevPanelController
		expect(panelController.IsEnabled()).toBe(false)
		expect(playerGui():FindFirstChild("DDC_Dev")).toBeNil()
		expect(#shim.threadErrors).toBe(0)
	end)

	it("builds the panel in Studio with every documented section, toggles with F6 and never opens a modal", function()
		shim.isStudio = true
		local _, calls = createDevRemote(function(command)
			if command == "ListTargets" then
				return { ok = true, targets = { { id = "hub", label = "Dash Hub", kind = "hub" }, { id = "business:SliceStreetPizza", label = "Slice Street Pizza", kind = "business" }, { id = "destination:D_Near", label = "1 Main Street", kind = "destination" } } }
			end
			return nil
		end)
		local ctx, ui = setup({ "DevPanelController" })
		shim.advance(0.5)
		local panelController = ctx.controllers.DevPanelController
		expect(panelController.IsEnabled()).toBe(true)
		local gui = playerGui():FindFirstChild("DDC_Dev")
		expect(gui).toBeTruthy()
		expect(gui.DisplayOrder).toBeGreaterThan(20)
		expect(gui:FindFirstChild("DevButton")).toBeTruthy()
		local panel = gui:FindFirstChild("Panel")
		expect(panel).toBeTruthy()
		expect(panel.Visible).toBe(false)
		expect(panel.Size.X.Offset).toBe(360)
		for _, name in ipairs({ "Economy", "Vehicles", "Teleport", "Events", "Handling", "Report" }) do
			local sectionFrame = panelController.GetSection(name)
			expect(sectionFrame).toBeTruthy()
			expect(sectionFrame:IsDescendantOf(panel)).toBe(true)
			expect(sectionFrame:FindFirstChild("Header").Text).toBe(name)
		end
		-- Every button is at least 32 px tall.
		for _, descendant in ipairs(panel:GetDescendants()) do
			if descendant:IsA("TextButton") then
				expect(descendant.Size.Y.Offset).toBeGreaterThanOrEqual(32)
			end
		end

		-- Toggle: DEV button, F6, API; never a UIController modal.
		gui.DevButton.Activated:Fire()
		expect(panelController.IsOpen()).toBe(true)
		expect(panel.Visible).toBe(true)
		expect(ui.IsModalOpen()).toBe(false)
		shim.input.tap(Enum.KeyCode.F6)
		expect(panelController.IsOpen()).toBe(false)
		shim.input.tap(Enum.KeyCode.F6)
		expect(panelController.IsOpen()).toBe(true)
		expect(ui.IsModalOpen()).toBe(false)

		-- Teleport targets came from ListTargets.
		local targets = panelController.GetTargetList()
		local targetButtons = 0
		for _, child in ipairs(targets:GetChildren()) do
			if child:IsA("TextButton") then
				targetButtons += 1
			end
		end
		expect(targetButtons).toBe(3)
		targets:FindFirstChild("Target_destination:D_Near").Activated:Fire()
		shim.advance(0.1)
		expect(calls[#calls].command).toBe("Teleport")
		expect(calls[#calls].args).toEqual({ target = "destination:D_Near" })

		-- Economy buttons send the documented commands.
		panelController.GetSection("Economy"):FindFirstChild("Button_+$1k", true).Activated:Fire()
		shim.advance(0.1)
		expect(calls[#calls].command).toBe("GrantCash")
		expect(calls[#calls].args).toEqual({ amount = 1000 })
		-- Reset profile needs a confirm tap.
		local resetButton = panelController.GetSection("Economy"):FindFirstChild("Button_ResetProfile", true)
		resetButton.Activated:Fire()
		shim.advance(0.1)
		expect(calls[#calls].command).toBe("GrantCash")
		resetButton.Activated:Fire()
		shim.advance(0.1)
		expect(calls[#calls].command).toBe("ResetProfile")

		-- Report prints a readable summary and toasts.
		local before = #shim.prints
		panelController.GetSection("Report"):FindFirstChild("Button_Print report to Output", true).Activated:Fire()
		shim.advance(0.1)
		expect(calls[#calls].command).toBe("Report")
		expect(#shim.prints).toBeGreaterThan(before)
		expect(ui.notifications[#ui.notifications].text).toBe("Report printed to Output")
	end)

	it("handling steppers change HandlingOverrides live and maxSpeed also sets the server speed cap", function()
		shim.isStudio = true
		local _, calls = createDevRemote()
		local ctx, ui, ClientState = setup({ "DevPanelController" })
		local HandlingOverrides = requireClient("HandlingOverrides")
		shim.advance(0.5)
		local panelController = ctx.controllers.DevPanelController
		expect(panelController.IsEnabled()).toBe(true)
		expect(panelController.GetHandlingVehicle()).toBe("Bicycle")

		local stepper = panelController.GetStepper("maxSpeed")
		expect(stepper).toBeTruthy()
		expect(stepper.box.Text).toBe("38")
		stepper.plus.Activated:Fire()
		expect(HandlingOverrides.getOverrides("Bicycle").maxSpeed).toBe(40)
		expect(HandlingOverrides.get("Bicycle").maxSpeed).toBe(40)
		expect(stepper.box.Text).toBe("40")
		expect(stepper.nameLabel.Text).toBe("maxSpeed *")
		shim.advance(0.1)
		expect(calls[#calls].command).toBe("SetSpeedCap")
		expect(calls[#calls].args).toEqual({ vehicleId = "Bicycle", maxSpeed = 40 })

		-- Small steps stay clean numbers; direct entry through the box.
		local turn = panelController.GetStepper("minTurnFactor")
		turn.minus.Activated:Fire()
		expect(HandlingOverrides.getOverrides("Bicycle").minTurnFactor).toBeCloseTo(0.35, 1e-9)
		expect(turn.box.Text).toBe("0.35")
		turn.box.Text = "0.5"
		turn.box.FocusLost:Fire(true)
		expect(HandlingOverrides.getOverrides("Bicycle").minTurnFactor).toBe(0.5)
		turn.box.Text = "garbage"
		turn.box.FocusLost:Fire(true)
		expect(turn.box.Text).toBe("0.5")
		-- Non-maxSpeed keys never touch the server.
		local capCalls = 0
		for _, call in ipairs(calls) do
			if call.command == "SetSpeedCap" then
				capCalls += 1
			end
		end
		expect(capCalls).toBe(1)
		-- Keys with a floor never go to zero.
		local ride = panelController.GetStepper("rideHeight")
		for _ = 1, 30 do
			ride.minus.Activated:Fire()
		end
		expect(HandlingOverrides.get("Bicycle").rideHeight).toBeGreaterThan(0)

		-- The tab row switches the tuned vehicle; a spawned vehicle selects its own tab.
		panelController.SetHandlingVehicle("Van")
		expect(stepper.box.Text).toBe("62")
		expect(stepper.nameLabel.Text).toBe("maxSpeed")
		ClientState.set("vehicle", { state = "Parked", vehicleId = "Scooter", model = nil })
		expect(panelController.GetHandlingVehicle()).toBe("Scooter")
		expect(stepper.box.Text).toBe("55")

		-- Print snippet goes to the Output plus a toast; reset clears the overrides and the cap.
		panelController.SetHandlingVehicle("Bicycle")
		local before = #shim.prints
		panelController.GetSection("Handling"):FindFirstChild("Button_Print snippet", true).Activated:Fire()
		expect(#shim.prints).toBe(before + 1)
		expect(shim.prints[#shim.prints]).toMatch("maxSpeed = 40, %-%- was 38")
		expect(ui.notifications[#ui.notifications].text).toBe("Snippet printed to Output")
		panelController.GetSection("Handling"):FindFirstChild("Button_Reset to defaults", true).Activated:Fire()
		shim.advance(0.1)
		expect(HandlingOverrides.hasOverrides("Bicycle")).toBe(false)
		expect(stepper.box.Text).toBe("38")
		expect(calls[#calls].command).toBe("SetSpeedCap")
		expect(calls[#calls].args).toEqual({ vehicleId = "Bicycle", maxSpeed = 0 })
		expect(#shim.threadErrors).toBe(0)
	end)
end)
