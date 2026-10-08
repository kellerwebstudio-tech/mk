--!nonstrict
-- Specs for the world builders: CityBuilder, VehicleBuilder, PackageBuilder, NPCBuilder, DepotBuilder.
-- Runs under tests/run.sh (virtual DataModel + shim). When Shared.City.CityLayout is missing the
-- CityBuilder specs run against a small synthetic layout and say so.

local function getServices()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local ServerScriptService = game:GetService("ServerScriptService")
	local CollectionService = game:GetService("CollectionService")
	return ReplicatedStorage, ServerScriptService, CollectionService
end

local function requireBuilder(name: string)
	local _, ServerScriptService = getServices()
	return require(ServerScriptService.DeliveryDash.Builders[name])
end

local function requireShared(path: string)
	local ReplicatedStorage = getServices()
	local node = ReplicatedStorage.Shared
	for segment in string.gmatch(path, "[^/]+") do
		node = node[segment]
	end
	return require(node)
end

local function tryCityLayout()
	local ok, layout = pcall(function()
		return requireShared("City/CityLayout")
	end)
	if ok and type(layout) == "table" then
		return layout
	end
	return nil
end

-- Minimal valid layout used when CityLayout is not present yet: a crossroads, one business,
-- one destination, one depot plot, a hub, some props, water and landmarks.
local function syntheticLayout()
	return {
		name = "Synthetic",
		bounds = { minX = -300, maxX = 300, minZ = -300, maxZ = 300 },
		groundY = 0,
		killY = -60,
		neighborhoods = { { id = "Downtown", name = "Downtown", center = { x = 0, z = 0 }, bounds = { minX = -300, maxX = 300, minZ = -300, maxZ = 300 }, accent = { 200, 100, 80 } } },
		roads = {
			{ id = "MainEW", name = "Main", kind = "Road", width = 14, points = { { x = -200, z = 0 }, { x = 200, z = 0 } } },
			{ id = "MainNS", name = "Cross", kind = "Road", width = 12, points = { { x = 0, z = -200 }, { x = 0, z = 200 } } },
			{ id = "Alley1", name = "Alley", kind = "Alley", width = 6, points = { { x = 60, z = 0 }, { x = 60, z = 80 } } },
			{ id = "Ramp1", name = "Ramp", kind = "Ramp", width = 12, points = { { x = 0, z = 200 }, { x = 0, y = 8, z = 260 } } },
			{ id = "Bridge1", name = "Bridge", kind = "Bridge", width = 14, points = { { x = 200, z = 0 }, { x = 280, z = 0 } } },
		},
		water = { { x = 240, z = 0, w = 40, d = 120, surfaceY = -2, depth = 6 } },
		bridges = { { roadId = "Bridge1", fromIndex = 1, toIndex = 2 } },
		buildings = {
			{ x = -40, z = -40, w = 24, d = 20, h = 14, style = "Shop", name = "ShopA" },
			{ x = 40, z = -40, w = 24, d = 24, h = 40, style = "Apartment" },
			{ x = -40, z = 50, w = 20, d = 18, h = 10, style = "House" },
			{ x = 120, z = -60, w = 40, d = 30, h = 16, style = "Warehouse" },
			{ x = -120, z = -60, w = 30, d = 20, h = 10, style = "Hub", name = "Hub" },
		},
		businesses = {
			{ id = "SliceStreetPizza", buildingIndex = 1, door = { x = -40, z = -30 }, facing = { x = 0, z = 1 }, pickupPoint = { x = -40, z = -20 }, arrivalPoint = { x = -40, z = -10 }, neighborhood = "Downtown" },
		},
		destinations = {
			{ id = "D_Apt1", address = "12 Cross St", neighborhood = "Downtown", kind = "Apartment", door = { x = 40, z = -28 }, facing = { x = 0, z = 1 }, arrivalPoint = { x = 40, z = -10 }, accepts = { Small = true, Medium = true, Large = false } },
			{ id = "D_House1", address = "3 Hill Rd", neighborhood = "Downtown", kind = "House", door = { x = -40, z = 41 }, facing = { x = 0, z = -1 }, arrivalPoint = { x = -40, z = 10 }, accepts = { Small = true, Medium = true, Large = true }, building = { x = -80, z = 90, w = 16, d = 14, h = 9, style = "House" } },
		},
		landmarks = { plaza = { x = -120, z = 0, r = 30 }, tower = { x = -200, z = -120 }, park = { x = 120, z = 120, w = 80, d = 60 }, waterTower = { x = 150, z = -150 }, hub = { x = -120, z = -60 } },
		hub = { spawn = { x = -120, z = -20, facing = { x = 0, z = 1 } }, vehiclePads = { { x = -100, z = -20, facing = { x = 0, z = 1 } }, { x = -90, z = -20, facing = { x = 0, z = 1 } } }, kiosk = { x = -110, z = -30 } },
		depotPlots = {
			{ id = "Plot1", x = 100, z = 60, w = 40, d = 30, facing = { x = 0, z = -1 }, parking = { { x = 90, z = 65, facing = { x = 0, z = -1 } }, { x = 110, z = 65, facing = { x = 0, z = -1 } } } },
		},
		pedestrianPaths = { { id = "Walk1", points = { { x = -20, z = 10 }, { x = 20, z = 10 } }, loop = true } },
		parkedVehicles = { { x = 30, z = 12, rot = 90, color = { 200, 60, 60 }, kind = "Car" }, { x = 130, z = -30, rot = 0, color = { 60, 60, 200 }, kind = "Truck" } },
		props = {
			{ type = "Tree", x = -60, z = 20 }, { type = "Lamp", x = 20, z = 12 }, { type = "Bench", x = -20, z = 14, rot = 180 }, { type = "Hydrant", x = 25, z = 13 },
			{ type = "Planter", x = -25, z = 14 }, { type = "Crate", x = 140, z = -80 }, { type = "Container", x = 160, z = -90 }, { type = "Dumpster", x = 70, z = 40, rot = 90 },
			{ type = "Sign", x = 10, z = 12 }, { type = "Cone", x = 5, z = 20 },
		},
		bikeShortcuts = { { roadId = "Alley1", hint = "Alley shortcut" } },
	}
end

local function makeCityFolders()
	local folders = {}
	for key, name in pairs({ city = "City", pickup = "PickupLocations", destinations = "DeliveryDestinations", depots = "DepotPlots" }) do
		local existing = workspace:FindFirstChild(name)
		if existing then
			existing:Destroy()
		end
		local folder = Instance.new("Folder")
		folder.Name = name
		folder.Parent = workspace
		folders[key] = folder
	end
	return folders
end

local function countBaseParts(root: Instance): number
	local n = 0
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") then
			n += 1
		end
	end
	return n
end

local function vecClose(a: Vector3, b: Vector3, eps: number?): boolean
	return (a - b).Magnitude <= (eps or 1e-3)
end

-------------------------------------------------------------------------------
describe("CityBuilder", function()
	local CityBuilder
	local layout
	local synthetic

	beforeEach(function()
		shim.reset()
		shim.setContext("server")
		CityBuilder = requireBuilder("CityBuilder")
		layout = tryCityLayout()
		synthetic = layout == nil
		if synthetic then
			print("CityLayout missing: CityBuilder specs run against the synthetic layout")
			layout = syntheticLayout()
		end
	end)

	it("positionsFor returns entries for every business and destination without creating instances", function()
		local before = #workspace:GetDescendants()
		local positions = CityBuilder.positionsFor(layout)
		expect(#workspace:GetDescendants()).toBe(before)
		for _, business in ipairs(layout.businesses) do
			local entry = positions.businesses[business.id]
			expect(entry).toBeTruthy()
			expect(typeof(entry.pickup)).toBe("Vector3")
			expect(typeof(entry.arrival)).toBe("Vector3")
			expect(typeof(entry.door)).toBe("Vector3")
			expect(entry.pickup.X).toBeCloseTo(business.pickupPoint.x, 1e-6)
			expect(entry.pickup.Z).toBeCloseTo(business.pickupPoint.z, 1e-6)
		end
		for _, destination in ipairs(layout.destinations) do
			local entry = positions.destinations[destination.id]
			expect(entry).toBeTruthy()
			expect(typeof(entry.door)).toBe("Vector3")
			expect(typeof(entry.arrival)).toBe("Vector3")
			expect(typeof(entry.facing)).toBe("Vector3")
			expect(entry.facing.Magnitude).toBeCloseTo(1, 1e-4)
			expect(entry.door.X).toBeCloseTo(destination.door.x, 1e-6)
			expect(entry.door.Z).toBeCloseTo(destination.door.z, 1e-6)
		end
		expect(typeof(positions.hubSpawn)).toBe("CFrame")
		expect(positions.hubSpawn.Position.X).toBeCloseTo(layout.hub.spawn.x, 1e-6)
		expect(positions.hubSpawn.Position.Z).toBeCloseTo(layout.hub.spawn.z, 1e-6)
		expect(#positions.vehiclePads).toBe(#layout.hub.vehiclePads)
		for _, plot in ipairs(layout.depotPlots) do
			local entry = positions.depotPlots[plot.id]
			expect(entry).toBeTruthy()
			expect(typeof(entry.origin)).toBe("CFrame")
			expect(#entry.parking).toBe(#plot.parking)
		end
	end)

	it("places the hub kiosk outside every building and clear of the vehicle pads", function()
		-- The authored kiosk once sat at the centre of the "Dash Hub Kiosk" building body, so the
		-- kiosk part, its screen and its billboard were built inside a solid box.
		local kiosk = layout.hub.kiosk
		for _, b in ipairs(layout.buildings or {}) do
			local rot = math.rad(b.rot or 0)
			local dx, dz = kiosk.x - b.x, kiosk.z - b.z
			local lx = dx * math.cos(rot) + dz * math.sin(rot)
			local lz = -dx * math.sin(rot) + dz * math.cos(rot)
			local inside = math.abs(lx) <= b.w / 2 + 1 and math.abs(lz) <= b.d / 2 + 1
			expect(inside).toBe(false)
		end
		-- A player standing on a pad (6 x 12, pad centre +- 3 / +- 6) must get the pad's own
		-- prompt, not the kiosk's (InteractionController.KIOSK_DISTANCE = 6).
		for _, pad in ipairs(layout.hub.vehiclePads) do
			local nearestX = math.clamp(kiosk.x, pad.x - 3, pad.x + 3)
			local nearestZ = math.clamp(kiosk.z, pad.z - 6, pad.z + 6)
			local distance = math.sqrt((nearestX - kiosk.x) ^ 2 + (nearestZ - kiosk.z) ^ 2)
			expect(distance).toBeGreaterThan(6)
		end
		if not synthetic then
			-- Built hub: the kiosk part is not enclosed by any colliding building body.
			local folders = makeCityFolders()
			CityBuilder.build(layout, folders)
			local kioskPart = folders.city:FindFirstChild("Kiosk", true)
			expect(kioskPart).toBeTruthy()
			local p = kioskPart.Position
			for _, part in ipairs(folders.city:GetDescendants()) do
				if part:IsA("BasePart") and part ~= kioskPart and part.CanCollide and part.Size.X >= 20 and part.Size.Y >= 8 then
					local rel = part.CFrame:PointToObjectSpace(p)
					local enclosed = math.abs(rel.X) < part.Size.X / 2 and math.abs(rel.Y) < part.Size.Y / 2 and math.abs(rel.Z) < part.Size.Z / 2
					expect(enclosed).toBe(false)
				end
			end
		end
	end)

	it("positionsFor uses road elevation where available", function()
		local elevated = syntheticLayout()
		elevated.roads = { { id = "High", name = "High", kind = "Road", width = 12, points = { { x = -100, y = 20, z = 0 }, { x = 100, y = 20, z = 0 } } } }
		elevated.businesses = { { id = "B", door = { x = 0, z = -9 }, facing = { x = 0, z = 1 }, pickupPoint = { x = 0, z = -3 }, arrivalPoint = { x = 0, z = 2 }, neighborhood = "Downtown" } }
		elevated.destinations = {}
		elevated.depotPlots = {}
		local positions = CityBuilder.positionsFor(elevated)
		expect(positions.businesses.B.arrival.Y).toBeCloseTo(20, 1e-6) -- on the road surface
		expect(positions.businesses.B.door.Y).toBeCloseTo(20.5, 1e-6) -- on the sidewalk
	end)

	it("build creates folders, models, tags, a SpawnLocation and stays within budget", function()
		local _, _, CollectionService = getServices()
		local folders = makeCityFolders()
		local world = CityBuilder.build(layout, folders)

		expect(world.cityFolder).toBe(folders.city)
		expect(world.pickupFolder).toBe(folders.pickup)
		expect(world.destinationFolder).toBe(folders.destinations)
		expect(world.depotFolder).toBe(folders.depots)
		expect(world.runtime).toBe(workspace:FindFirstChild("Runtime"))
		expect(world.runtime:FindFirstChild("Vehicles")).toBeTruthy()
		expect(typeof(world.hubSpawn)).toBe("CFrame")
		expect(#world.vehiclePads).toBe(#layout.hub.vehiclePads)

		for _, name in ipairs({ "Roads", "Sidewalks", "Markings", "Buildings", "Landmarks", "Props", "ParkedVehicles" }) do
			expect(folders.city:FindFirstChild(name)).toBeTruthy()
		end

		-- Ground layer: large Grass parts just under the road surface, with the canal cut out,
		-- and the terrain lowered beneath them with grass decoration off.
		local ground = folders.city:FindFirstChild("Ground")
		expect(ground).toBeTruthy()
		local groundParts = ground:GetChildren()
		expect(#groundParts).toBeGreaterThan(0)
		local function groundAt(x, z)
			for _, part in ipairs(groundParts) do
				local half = part.Size / 2
				local p = part.Position
				if x >= p.X - half.X and x <= p.X + half.X and z >= p.Z - half.Z and z <= p.Z + half.Z then
					return part
				end
			end
			return nil
		end
		local hubPart = groundAt(layout.hub.spawn.x, layout.hub.spawn.z)
		expect(hubPart).toBeTruthy()
		expect(hubPart.Position.Y + hubPart.Size.Y / 2).toBeCloseTo(layout.groundY - 0.1, 1e-6) -- top just under road tops
		expect(hubPart.CanCollide).toBe(true)
		expect(hubPart.CanQuery).toBe(true) -- vehicle ground rays must hit it
		expect(hubPart.Material).toBe(Enum.Material.Grass)
		for _, part in ipairs(groundParts) do
			expect(part.Size.X).toBeLessThan(2049)
			expect(part.Size.Z).toBeLessThan(2049)
		end
		for _, water in ipairs(layout.water) do
			expect(groundAt(water.x, water.z)).toBeNil() -- canal is open water
			expect(groundAt(water.x + water.w / 2 + 2, water.z)).toBeTruthy() -- bank right beside it
		end
		local terrain = workspace:FindFirstChildOfClass("Terrain")
		expect(terrain.Decoration).toBe(false)
		local fills = terrain._fills
		local slab = fills[1]
		expect(slab[4]).toBe(Enum.Material.Grass)
		expect(slab[2].Position.Y + slab[3].Y / 2).toBeCloseTo(layout.groundY - 0.1 - 2, 1e-6) -- terrain top under the ground parts
		expect(#folders.city.Roads:GetChildren()).toBeGreaterThan(0)
		expect(#folders.city.Sidewalks:GetChildren()).toBeGreaterThan(0)

		for _, business in ipairs(layout.businesses) do
			local model = folders.pickup:FindFirstChild(business.id)
			expect(model).toBeTruthy()
			expect(model:IsA("Model")).toBe(true)
			expect(model:GetAttribute("BusinessId")).toBe(business.id)
			local pad = model:FindFirstChild("PickupPad")
			expect(pad).toBeTruthy()
			expect(CollectionService:HasTag(pad, "PickupZone")).toBe(true)
			expect(pad.CanCollide).toBe(false)
			expect(pad:FindFirstChildWhichIsA("BillboardGui")).toBeTruthy()
			expect(model:FindFirstChild("Counter")).toBeTruthy()
			expect(model:FindFirstChild("Staff")).toBeTruthy()
			expect(model:FindFirstChild("Storefront")).toBeTruthy()
			expect(model.Storefront:FindFirstChild("Sign")).toBeTruthy()
			local entry = world.businesses[business.id]
			expect(entry.model).toBe(model)
			expect(typeof(entry.pickupPosition)).toBe("Vector3")
			expect(typeof(entry.arrivalPosition)).toBe("Vector3")
		end

		for _, destination in ipairs(layout.destinations) do
			local model = folders.destinations:FindFirstChild(destination.id)
			expect(model).toBeTruthy()
			expect(model:GetAttribute("DestinationId")).toBe(destination.id)
			expect(model:GetAttribute("Address")).toBe(destination.address)
			local door = model:FindFirstChild("Door")
			expect(door).toBeTruthy()
			expect(CollectionService:HasTag(door, "DoorPart")).toBe(true)
			expect(door.Size.X).toBeCloseTo(4, 1e-6)
			expect(door.Size.Y).toBeCloseTo(7, 1e-6)
			local pad = model:FindFirstChild("ArrivalPad")
			expect(pad).toBeTruthy()
			expect(CollectionService:HasTag(pad, "DeliveryZone")).toBe(true)
			expect(pad.CanCollide).toBe(false)
			expect(model:FindFirstChild("AddressSign")).toBeTruthy()
			expect(model:FindFirstChild("Doorbell")).toBeTruthy()
			if destination.building then
				expect(model:FindFirstChild("Building")).toBeTruthy()
			end
			local entry = world.destinations[destination.id]
			expect(entry.model).toBe(model)
			expect(entry.doorPart).toBe(door)
			expect(entry.facing.Magnitude).toBeCloseTo(1, 1e-4)
		end

		for _, plot in ipairs(layout.depotPlots) do
			local model = folders.depots:FindFirstChild(plot.id)
			expect(model).toBeTruthy()
			expect(model:GetAttribute("PlotId")).toBe(plot.id)
			expect(model:GetAttribute("OwnerUserId")).toBe(0)
			expect(model:GetAttribute("OwnerName")).toBe("")
			expect(CollectionService:HasTag(model, "DepotPlot")).toBe(true)
			expect(model:FindFirstChild("Ground")).toBeTruthy()
			expect(model:FindFirstChild("Sign")).toBeTruthy()
			expect(model:FindFirstChild("Built")).toBeTruthy()
			local entry = world.depotPlots[plot.id]
			expect(entry.model).toBe(model)
			expect(entry.signPart).toBe(model.Sign)
			expect(#entry.parking).toBe(#plot.parking)
			expect(entry.plotId).toBe(plot.id)
		end

		local spawn = folders.city:FindFirstChildWhichIsA("SpawnLocation", true)
		expect(spawn).toBeTruthy()
		expect(spawn.Neutral).toBe(true)
		expect(spawn.Enabled).toBe(true)
		expect(#CollectionService:GetTagged("VehiclePad")).toBe(#layout.hub.vehiclePads)
		expect(#CollectionService:GetTagged("PickupZone")).toBe(#layout.businesses)
		expect(#CollectionService:GetTagged("DeliveryZone")).toBe(#layout.destinations)

		local total = 0
		for _, folder in pairs(folders) do
			for _, d in ipairs(folder:GetDescendants()) do
				if d:IsA("BasePart") then
					total += 1
					expect(d.Anchored).toBe(true)
				end
			end
		end
		expect(total).toBeGreaterThan(0)
		expect(total).toBeLessThan(4500)
		expect(world.partCount).toBe(total)
		expect(CityBuilder.getLastPartCount()).toBe(total)
	end)

	it("build accepts keyed 0-1 colours and {r,g,b} 0-255 arrays", function()
		local custom = syntheticLayout()
		custom.buildings = {
			{ x = -40, z = -40, w = 24, d = 20, h = 14, style = "Shop", name = "Keyed", color = { r = 0.5, g = 0.25, b = 0.1 } },
			{ x = 40, z = -40, w = 24, d = 20, h = 14, style = "Shop", name = "Array", color = { 255, 0, 51 } },
		}
		custom.parkedVehicles = { { x = 30, z = 12, rot = 90, color = { r = 0.2, g = 0.4, b = 0.6 }, kind = "Car" } }
		local folders = makeCityFolders()
		CityBuilder.build(custom, folders)
		local keyed = folders.city.Buildings:FindFirstChild("Keyed")
		expect(keyed.Color.R).toBeCloseTo(0.5, 1e-3)
		expect(keyed.Color.G).toBeCloseTo(0.25, 1e-3)
		expect(keyed.Color.B).toBeCloseTo(0.1, 1e-3)
		local array = folders.city.Buildings:FindFirstChild("Array")
		expect(array.Color.R).toBeCloseTo(1, 1e-3)
		expect(array.Color.G).toBeCloseTo(0, 1e-3)
		expect(array.Color.B).toBeCloseTo(0.2, 1e-3)
		local car = folders.city.ParkedVehicles:GetChildren()[1]
		expect(car.Body.Color.R).toBeCloseTo(0.2, 1e-3)
		expect(car.Body.Color.B).toBeCloseTo(0.6, 1e-3)
	end)

	it("build keeps decorative parts non-colliding and bodies colliding", function()
		local folders = makeCityFolders()
		CityBuilder.build(layout, folders)
		for _, d in ipairs(folders.city.Markings:GetDescendants()) do
			if d:IsA("BasePart") then
				expect(d.CanCollide).toBe(false)
				expect(d.CanQuery).toBe(false)
				expect(d.CanTouch).toBe(false)
			end
		end
		local collidingBuildings = 0
		for _, d in ipairs(folders.city.Buildings:GetChildren()) do
			if d:IsA("BasePart") and d.CanCollide then
				collidingBuildings += 1
			end
			if d.Name == "Windows" or d.Name == "Awning" or d.Name == "RoofLip" or d.Name == "Door" then
				expect(d.CanCollide).toBe(false)
			end
		end
		expect(collidingBuildings).toBe(#layout.buildings)
		for _, model in ipairs(folders.city.ParkedVehicles:GetChildren()) do
			local body = model:FindFirstChild("Body") or model:FindFirstChild("Cab")
			expect(body).toBeTruthy()
			expect(body.CanCollide).toBe(true)
			expect(body.CollisionGroup).toBe("Default")
		end
	end)
end)

-------------------------------------------------------------------------------
describe("VehicleBuilder", function()
	local VehicleBuilder
	local VehicleDefinitions

	beforeEach(function()
		shim.reset()
		shim.setContext("server")
		-- Generated-part path: switch the embedded mesh mode (the default; see
		-- tests/specs/embedded_meshes.spec.luau) off for every vehicle.
		local MeshAssets = requireShared("Config/MeshAssets")
		for _, entry in pairs(MeshAssets.Vehicles) do
			entry.embedded = false
		end
		VehicleBuilder = requireBuilder("VehicleBuilder")
		VehicleDefinitions = requireShared("Definitions/VehicleDefinitions")
	end)

	it("builds the documented structure for every vehicle", function()
		local _, _, CollectionService = getServices()
		for _, vehicleId in ipairs(VehicleDefinitions.Order) do
			local def = VehicleDefinitions.get(vehicleId)
			local model = VehicleBuilder.build(vehicleId, 42, nil)
			expect(model.Name).toBe("Vehicle")
			expect(model:GetAttribute("OwnerUserId")).toBe(42)
			expect(model:GetAttribute("VehicleId")).toBe(vehicleId)
			expect(model:GetAttribute("State")).toBe("Parked")
			expect(model:GetAttribute("Capacity")).toBe(def.baseCapacity)
			expect(CollectionService:HasTag(model, "DeliveryVehicle")).toBe(true)

			local chassis = model:FindFirstChild("Chassis")
			expect(chassis).toBeTruthy()
			expect(model.PrimaryPart).toBe(chassis)
			expect(chassis.Anchored).toBe(true)
			expect(chassis.Transparency).toBe(1)
			expect(chassis.CanCollide).toBe(true)
			expect(chassis.CanQuery).toBe(false)
			expect(chassis.CanTouch).toBe(false)
			expect(chassis.CollisionGroup).toBe("Vehicles")
			expect(chassis.Size.X).toBeCloseTo(def.chassisSize[1], 1e-6)
			expect(chassis.Size.Z).toBeCloseTo(def.chassisSize[3], 1e-6)
			expect(chassis:FindFirstChild("RootAttachment")).toBeTruthy()
			expect(chassis:FindFirstChild("RootAttachment"):IsA("Attachment")).toBe(true)
			expect(chassis:FindFirstChild("Align"):IsA("AlignOrientation")).toBe(true)
			expect(chassis:FindFirstChild("Align").Attachment0).toBe(chassis.RootAttachment)
			expect(chassis:FindFirstChild("Velocity"):IsA("LinearVelocity")).toBe(true)
			expect(chassis:FindFirstChild("Velocity").Attachment0).toBe(chassis.RootAttachment)
			expect(chassis:FindFirstChild("CargoAttachment"):IsA("Attachment")).toBe(true)
			expect(vecClose(chassis.CargoAttachment.Position, Vector3.new(def.cargoOffset[1], def.cargoOffset[2], def.cargoOffset[3]))).toBe(true)
			expect(chassis:FindFirstChild("DismountAttachment"):IsA("Attachment")).toBe(true)
			expect(chassis:FindFirstChild("EngineSound")).toBeTruthy()

			local bodyRoot = model:FindFirstChild("BodyRoot")
			expect(bodyRoot).toBeTruthy()
			expect(bodyRoot.Transparency).toBe(1)
			expect(bodyRoot.Massless).toBe(true)
			expect(bodyRoot.CanCollide).toBe(false)
			local bodyMotor = bodyRoot:FindFirstChild("BodyMotor")
			expect(bodyMotor:IsA("Motor6D")).toBe(true)
			expect(bodyMotor.Part0).toBe(chassis)
			expect(bodyMotor.Part1).toBe(bodyRoot)

			local seat = model:FindFirstChild("Seat")
			expect(seat:IsA("VehicleSeat")).toBe(true)
			expect(seat.Disabled).toBe(true)
			expect(seat.MaxSpeed).toBe(0)
			expect(seat.Torque).toBe(0)
			expect(seat.HeadsUpDisplay).toBe(false)
			expect(seat.Transparency).toBe(1)
			local seatWeld = seat:FindFirstChildWhichIsA("WeldConstraint")
			expect(seatWeld).toBeTruthy()
			expect(seatWeld.Part0).toBe(bodyRoot)
			local expectedSeat = chassis.CFrame * CFrame.new(def.seatOffset[1], def.seatOffset[2], def.seatOffset[3])
			expect(vecClose(seat.Position, expectedSeat.Position)).toBe(true)

			local body = model:FindFirstChild("Body")
			expect(body:IsA("Folder")).toBe(true)
			local bodyParts = body:GetChildren()
			expect(#bodyParts).toBe(#def.visual.parts)
			local slotCount = 0
			for _, part in ipairs(bodyParts) do
				expect(part:IsA("BasePart")).toBe(true)
				expect(part.Massless).toBe(true)
				expect(part.CanCollide).toBe(false)
				expect(part.CanQuery).toBe(false)
				expect(part.CanTouch).toBe(false)
				expect(part.Anchored).toBe(false)
				local weld = part:FindFirstChildWhichIsA("WeldConstraint")
				expect(weld).toBeTruthy()
				expect(weld.Part0).toBe(bodyRoot)
				expect(weld.Part1).toBe(part)
				if part:GetAttribute("PaintSlot") ~= nil then
					slotCount += 1
				end
			end
			local expectedSlots = 0
			for _, spec in ipairs(def.visual.parts) do
				if type(spec.color) == "string" then
					expectedSlots += 1
				end
			end
			expect(slotCount).toBe(expectedSlots)
			expect(slotCount).toBeGreaterThan(0)

			local wheels = model:FindFirstChild("Wheels")
			expect(wheels:IsA("Folder")).toBe(true)
			expect(#wheels:GetChildren()).toBe(#def.visual.wheels)
			for _, spec in ipairs(def.visual.wheels) do
				local wheel = wheels:FindFirstChild(spec.name)
				expect(wheel).toBeTruthy()
				expect(wheel.Shape).toBe(Enum.PartType.Cylinder)
				expect(vecClose(wheel.Size, Vector3.new(spec.width, spec.radius * 2, spec.radius * 2))).toBe(true)
				expect(wheel:GetAttribute("Steerable")).toBe(spec.steerable)
				expect(wheel:GetAttribute("Radius")).toBe(spec.radius)
				local motor = wheel:FindFirstChild("WheelMotor")
				expect(motor:IsA("Motor6D")).toBe(true)
				expect(motor.Part0).toBe(bodyRoot)
				expect(motor.Part1).toBe(wheel)
				expect(vecClose(motor.C0.Position, Vector3.new(spec.offset[1], spec.offset[2], spec.offset[3]))).toBe(true)
			end

			expect(model:FindFirstChild("Cargo"):IsA("Folder")).toBe(true)
		end
	end)

	it("getSlotCFrame lays out van cargo in columns, rows and layers", function()
		local def = VehicleDefinitions.get("Van")
		local base = def.cargoOffset
		local lay = def.cargoLayout
		local expected = {
			[1] = { 0, 0, 0 },
			[2] = { 1, 0, 0 },
			[3] = { 0, 1, 0 },
			[4] = { 1, 1, 0 },
			[5] = { 0, 2, 0 },
			[6] = { 1, 2, 0 },
			[7] = { 0, 0, 1 },
		}
		for slot, e in pairs(expected) do
			local cf = VehicleBuilder.getSlotCFrame("Van", slot)
			expect(cf.X).toBeCloseTo(base[1] + e[1] * lay.spacingX, 1e-6)
			expect(cf.Y).toBeCloseTo(base[2] + e[2] * lay.spacingY, 1e-6)
			expect(cf.Z).toBeCloseTo(base[3] + e[3] * lay.spacingZ, 1e-6)
		end
		-- bicycle: single column stacking up
		local b2 = VehicleBuilder.getSlotCFrame("Bicycle", 2)
		local bdef = VehicleDefinitions.get("Bicycle")
		expect(b2.Y).toBeCloseTo(bdef.cargoOffset[2] + bdef.cargoLayout.spacingY, 1e-6)
		expect(b2.X).toBeCloseTo(bdef.cargoOffset[1], 1e-6)
	end)

	it("van seat leaves headroom for a seated R15 rig under the cab roof", function()
		-- A seated R15 rig stacks roughly 3.5-4 studs above the seat surface, so the cab
		-- roof underside must sit at least ~4 studs above the seat top (vehicle-9).
		local def = VehicleDefinitions.get("Van")
		local seatTop = def.seatOffset[2] + 0.25 -- VehicleSeat is 0.5 thick
		local roof, cabLower
		for _, part in ipairs(def.visual.parts) do
			if part.name == "CabRoof" then
				roof = part
			elseif part.name == "CabLower" then
				cabLower = part
			end
		end
		expect(roof).toBeTruthy()
		expect(cabLower).toBeTruthy()
		local roofUnderside = roof.offset[2] - roof.size[2] / 2
		expect(roofUnderside - seatTop >= 4).toBe(true)
		-- the seat stays inside the chassis / cab shell rather than floating above it
		local cabTop = cabLower.offset[2] + cabLower.size[2] / 2
		expect(seatTop <= cabTop).toBe(true)
		expect(seatTop >= -def.chassisSize[2] / 2).toBe(true)
	end)

	it("applyCosmetics recolours PaintSlot parts", function()
		local model = VehicleBuilder.build("Van", 1, { Primary = { 1, 2, 3 }, Accent = { 4, 5, 6 }, Decal = { 7, 8, 9 } })
		local function checkSlot(slot, color)
			local found = 0
			for _, part in ipairs(model.Body:GetChildren()) do
				if part:GetAttribute("PaintSlot") == slot then
					found += 1
					expect(part.Color).toEqual(color)
				end
			end
			expect(found).toBeGreaterThan(0)
		end
		checkSlot("Primary", Color3.fromRGB(1, 2, 3))
		checkSlot("Accent", Color3.fromRGB(4, 5, 6))
		checkSlot("Decal", Color3.fromRGB(7, 8, 9))
		VehicleBuilder.applyCosmetics(model, { Primary = { 10, 20, 30 }, Decal = { 40, 50, 60 } })
		checkSlot("Primary", Color3.fromRGB(10, 20, 30))
		checkSlot("Accent", Color3.fromRGB(4, 5, 6)) -- untouched
		checkSlot("Decal", Color3.fromRGB(40, 50, 60))
	end)

	it("buildDisplay is anchored and has no constraints", function()
		local display = VehicleBuilder.buildDisplay("Scooter", nil)
		expect(display.PrimaryPart).toBeTruthy()
		local parts = 0
		for _, d in ipairs(display:GetDescendants()) do
			if d:IsA("BasePart") then
				parts += 1
				expect(d.Anchored).toBe(true)
				expect(d.CanCollide).toBe(false)
			end
			expect(d:IsA("Motor6D")).toBe(false)
			expect(d:IsA("WeldConstraint")).toBe(false)
			expect(d:IsA("VehicleSeat")).toBe(false)
			expect(d:IsA("Constraint")).toBe(false)
		end
		local def = VehicleDefinitions.get("Scooter")
		expect(parts).toBe(1 + #def.visual.parts + #def.visual.wheels)
	end)
end)

-------------------------------------------------------------------------------
describe("PackageBuilder", function()
	local PackageBuilder
	local VehicleBuilder
	local OrderDefinitions

	beforeEach(function()
		shim.reset()
		shim.setContext("server")
		PackageBuilder = requireBuilder("PackageBuilder")
		VehicleBuilder = requireBuilder("VehicleBuilder")
		OrderDefinitions = requireShared("Definitions/OrderDefinitions")
	end)

	it("builds every package key as a tagged, massless, non-colliding model", function()
		local _, _, CollectionService = getServices()
		for _, key in ipairs(OrderDefinitions.PackageKeys) do
			local model = PackageBuilder.build(key, nil)
			expect(model.Name).toBe("Package")
			expect(model:GetAttribute("PackageKey")).toBe(key)
			expect(CollectionService:HasTag(model, "Package")).toBe(true)
			local root = model.PrimaryPart
			expect(root).toBeTruthy()
			expect(root.Name).toBe("Root")
			local visual = OrderDefinitions.PackageVisuals[key]
			expect(vecClose(root.Size, Vector3.new(visual.size[1], visual.size[2], visual.size[3]))).toBe(true)
			expect(root:FindFirstChildWhichIsA("SurfaceGui")).toBeTruthy()
			local parts = 0
			for _, d in ipairs(model:GetDescendants()) do
				if d:IsA("BasePart") then
					parts += 1
					expect(d.Massless).toBe(true)
					expect(d.CanCollide).toBe(false)
					expect(d.CanQuery).toBe(false)
					expect(d.CanTouch).toBe(false)
				end
			end
			expect(parts).toBe(2)
		end
	end)

	it("applies the bag style colours", function()
		local model = PackageBuilder.build("FoodBag", { color = { 1, 2, 3 }, accent = { 4, 5, 6 } })
		expect(model.PrimaryPart.Color).toEqual(Color3.fromRGB(1, 2, 3))
		expect(model:FindFirstChild("Strap").Color).toEqual(Color3.fromRGB(4, 5, 6))
	end)

	it("attaches to a vehicle slot and detaches", function()
		local vehicle = VehicleBuilder.build("Van", 7, nil)
		vehicle.Parent = workspace
		vehicle:PivotTo(CFrame.new(100, 5, 50))
		local record = { model = vehicle, chassis = vehicle.Chassis, seat = vehicle.Seat, bodyRoot = vehicle.BodyRoot, vehicleId = "Van", state = "Parked", ownerUserId = 7, lastSafePosition = Vector3.zero, cargoAttachment = vehicle.Chassis.CargoAttachment, spawnedAt = 0, lastRecoverAt = 0 }
		local package = PackageBuilder.build("Parcel", nil)
		PackageBuilder.attachToVehicle(package, record, 3)
		expect(package.Parent).toBe(vehicle.Cargo)
		local weld = package.PrimaryPart:FindFirstChild("AttachWeld")
		expect(weld).toBeTruthy()
		expect(weld:IsA("WeldConstraint")).toBe(true)
		expect(weld.Part0).toBe(vehicle.Chassis)
		expect(weld.Part1).toBe(package.PrimaryPart)
		expect(package.PrimaryPart.Anchored).toBe(false)
		local expected = vehicle.Chassis.CFrame * VehicleBuilder.getSlotCFrame("Van", 3)
		expect(vecClose(package.PrimaryPart.Position, expected.Position)).toBe(true)

		-- re-attaching replaces the weld rather than stacking a second one
		PackageBuilder.attachToVehicle(package, record, 1)
		local welds = 0
		for _, d in ipairs(package.PrimaryPart:GetChildren()) do
			if d:IsA("WeldConstraint") and d.Name == "AttachWeld" then
				welds += 1
			end
		end
		expect(welds).toBe(1)

		PackageBuilder.detach(package)
		expect(package.Parent).toBeNil()
		expect(package.PrimaryPart:FindFirstChild("AttachWeld")).toBeNil()
		PackageBuilder.destroy(package)
	end)

	it("attaches to the character's back, stacking by slot", function()
		local player = shim.addPlayer("Courier", 1001)
		local character = shim.spawnCharacter(player)
		local torso = character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso") or character:FindFirstChild("HumanoidRootPart")
		expect(torso).toBeTruthy()
		local first = PackageBuilder.build("FoodBag", nil)
		local second = PackageBuilder.build("FoodBag", nil)
		PackageBuilder.attachToCharacter(first, character, 1)
		PackageBuilder.attachToCharacter(second, character, 2)
		expect(first.Parent).toBe(character)
		expect(second.Parent).toBe(character)
		expect(first.PrimaryPart.AttachWeld.Part0).toBe(torso)
		local behind = torso.CFrame:PointToObjectSpace(first.PrimaryPart.Position)
		expect(behind.Z).toBeGreaterThan(torso.Size.Z / 2) -- behind the torso (+Z is the back)
		expect(second.PrimaryPart.Position.Y).toBeGreaterThan(first.PrimaryPart.Position.Y)
		PackageBuilder.detach(first)
		expect(first.Parent).toBeNil()
	end)
end)

-------------------------------------------------------------------------------
-- The NameTag BillboardGui: on the Head of a generated figure, on the Body of an embedded rig.
local function nameTagOf(model)
	local host = model:FindFirstChild("Head") or model:FindFirstChild("Body")
	return host and host:FindFirstChild("NameTag")
end

describe("NPCBuilder", function()
	local NPCBuilder

	beforeEach(function()
		shim.reset()
		shim.setContext("server")
		-- These specs describe the generated part figure: hide the embedded people data
		-- (tests/specs/figures.spec.luau covers the FigureRig path).
		requireShared("Util/FigureRig")._setMeshData({ has = function() return false end })
		NPCBuilder = requireBuilder("NPCBuilder")
	end)

	it("builds every kind with Root, limbs, Motor6Ds, tag and attribute", function()
		local _, _, CollectionService = getServices()
		for _, kind in ipairs({ "Pedestrian", "Staff", "Customer", "Worker", "Driver" }) do
			local model = NPCBuilder.build(kind, 5, nil)
			expect(model:GetAttribute("NPCKind")).toBe(kind)
			expect(CollectionService:HasTag(model, "CityNPC")).toBe(true)
			local root = model.PrimaryPart
			expect(root).toBeTruthy()
			expect(root.Name).toBe("Root")
			expect(root.Transparency).toBe(1)
			expect(vecClose(root.Size, Vector3.new(2, 2, 1))).toBe(true)
			for _, limb in ipairs({ "Head", "Torso", "LeftArm", "RightArm", "LeftLeg", "RightLeg" }) do
				local part = model:FindFirstChild(limb)
				expect(part).toBeTruthy()
				local motor = part:FindFirstChildWhichIsA("Motor6D")
				expect(motor).toBeTruthy()
				expect(motor.Part0).toBe(root)
				expect(motor.Part1).toBe(part)
			end
			for _, d in ipairs(model:GetDescendants()) do
				if d:IsA("BasePart") then
					expect(d.Anchored).toBe(false)
					expect(d.CanCollide).toBe(false)
					expect(d.CanQuery).toBe(false)
					expect(d.CanTouch).toBe(false)
					expect(d.CollisionGroup).toBe("NPCs")
				end
			end
			-- legs reach the ground 3 studs below the root
			local leg = model.LeftLeg
			expect(leg.Position.Y - leg.Size.Y / 2).toBeCloseTo(root.Position.Y - 3, 1e-4)
		end
	end)

	it("adds kind accessories and name tags", function()
		local staff = NPCBuilder.build("Staff", 1, { name = "Priya", shirt = { 10, 20, 30 } })
		expect(staff:FindFirstChild("Apron")).toBeTruthy()
		expect(staff.Apron.Color).toEqual(Color3.fromRGB(10, 20, 30))
		expect(staff:FindFirstChild("Cap")).toBeTruthy()
		expect(staff.Head:FindFirstChild("NameTag")).toBeTruthy()
		expect(staff.Head.NameTag.Label.Text).toBe("Priya")
		local worker = NPCBuilder.build("Worker", 2, nil)
		expect(worker:FindFirstChild("Vest")).toBeTruthy()
		expect(worker:FindFirstChild("HardHat")).toBeTruthy()
		expect(worker.Head:FindFirstChild("NameTag")).toBeNil()
		local driver = NPCBuilder.build("Driver", 3, { name = "Ava" })
		expect(driver:FindFirstChild("Cap")).toBeTruthy()
	end)

	it("is deterministic per seed and animates with setWalkPose", function()
		local a = NPCBuilder.build("Pedestrian", 77, nil)
		local b = NPCBuilder.build("Pedestrian", 77, nil)
		expect(a.Torso.Color).toEqual(b.Torso.Color)
		expect(a.LeftLeg.Color).toEqual(b.LeftLeg.Color)
		NPCBuilder.setWalkPose(a, math.pi / 2)
		local motor = a.LeftArm.LeftShoulder
		expect(motor.Transform ~= CFrame.new()).toBe(true)
		NPCBuilder.setWalkPose(a, 0)
		expect(motor.Transform).toEqual(CFrame.new())
	end)

	it("place puts the feet on the surface and freeze anchors everything", function()
		local npc = NPCBuilder.build("Customer", 9, nil)
		NPCBuilder.place(npc, Vector3.new(10, 2, 10), Vector3.new(1, 0, 0), true)
		expect(npc.PrimaryPart.Anchored).toBe(true)
		expect(npc.PrimaryPart.Position.Y).toBeCloseTo(5, 1e-4)
		expect(npc.PrimaryPart.CFrame.LookVector.X).toBeCloseTo(1, 1e-4)
		NPCBuilder.freeze(npc)
		for _, d in ipairs(npc:GetDescendants()) do
			if d:IsA("BasePart") then
				expect(d.Anchored).toBe(true)
			end
		end
	end)
end)

-------------------------------------------------------------------------------
describe("DepotBuilder", function()
	local DepotBuilder

	local function makePlotWorld()
		local model = Instance.new("Model")
		model.Name = "Plot1"
		model:SetAttribute("PlotId", "Plot1")
		model:SetAttribute("OwnerUserId", 0)
		model:SetAttribute("OwnerName", "")
		model:SetAttribute("PlotWidth", 40)
		model:SetAttribute("PlotDepth", 30)
		model.Parent = workspace
		local sign = Instance.new("Part")
		sign.Name = "Sign"
		sign.Size = Vector3.new(8, 3, 0.4)
		sign.Anchored = true
		sign.Parent = model
		local gui = Instance.new("SurfaceGui")
		gui.Parent = sign
		local label = Instance.new("TextLabel")
		label.Name = "Label"
		label.Text = "FOR SALE - Depot"
		label.Parent = gui
		local built = Instance.new("Folder")
		built.Name = "Built"
		built.Parent = model
		local origin = CFrame.new(100, 0.4, 60)
		return {
			model = model,
			origin = origin,
			parking = { origin * CFrame.new(-10, 0, 5), origin * CFrame.new(10, 0, 5) },
			signPart = sign,
			plotId = "Plot1",
		}, label
	end

	local function makeProfile(hiredSecond: boolean, equipped)
		return {
			cash = 0,
			reputation = 2000,
			depot = { owned = true, slotsUnlocked = 2, drivers = { { hired = true, name = "Ava", pending = 0 }, { hired = hiredSecond, name = if hiredSecond then "Benji" else nil, pending = 0 } } },
			cosmetics = { owned = {}, equipped = equipped or {} },
		}
	end

	beforeEach(function()
		shim.reset()
		shim.setContext("server")
		DepotBuilder = requireBuilder("DepotBuilder")
	end)

	it("apply builds office, decor, vans and drivers idempotently", function()
		local plot, label = makePlotWorld()
		local profile = makeProfile(false, { DepotSign = "DepotSign_Bold", DepotDecor = "DepotDecor_Planters" })
		DepotBuilder.apply(plot, profile, "Kai", 555)
		DepotBuilder.apply(plot, profile, "Kai", 555)
		local built = plot.model.Built
		local offices, decors, slots = 0, 0, 0
		for _, child in ipairs(built:GetChildren()) do
			if child.Name == "Office" then
				offices += 1
			elseif child.Name == "Decor" then
				decors += 1
			elseif string.sub(child.Name, 1, 4) == "Slot" then
				slots += 1
			end
		end
		expect(offices).toBe(1)
		expect(decors).toBe(1)
		expect(slots).toBe(1)
		expect(built:FindFirstChild("Slot1")).toBeTruthy()
		expect(built:FindFirstChild("Slot2")).toBeNil()
		expect(built.Slot1:FindFirstChild("Van")).toBeTruthy()
		expect(built.Slot1:FindFirstChild("Driver")).toBeTruthy()
		expect(built.Slot1.Driver:GetAttribute("NPCKind")).toBe("Driver")
		expect(nameTagOf(built.Slot1.Driver).Label.Text).toBe("Ava")
		expect(#built.Decor:GetChildren()).toBeGreaterThan(0)
		expect(label.Text).toBe("Kai's Depot")
		expect(plot.signPart.Color).toEqual(Color3.fromRGB(226, 76, 60))
		expect(plot.model:GetAttribute("OwnerName")).toBe("Kai")
		expect(plot.model:GetAttribute("OwnerUserId")).toBe(555)
		-- everything it built is anchored (the van is a display; the driver is frozen)
		for _, d in ipairs(built:GetDescendants()) do
			if d:IsA("BasePart") then
				expect(d.Anchored).toBe(true)
			end
		end
		-- the van sits on the parking spot
		local van = built.Slot1.Van
		local spot = plot.parking[1]
		expect(van.PrimaryPart.Position.X).toBeCloseTo(spot.Position.X, 1e-3)
		expect(van.PrimaryPart.Position.Z).toBeCloseTo(spot.Position.Z, 1e-3)
		expect(van.PrimaryPart.Position.Y).toBeGreaterThan(spot.Position.Y)
	end)

	it("refreshes when a second driver is hired and the decor changes", function()
		local plot = makePlotWorld()
		DepotBuilder.apply(plot, makeProfile(false, { DepotDecor = "DepotDecor_None" }), "Kai")
		expect(#plot.model.Built.Decor:GetChildren()).toBe(0)
		DepotBuilder.apply(plot, makeProfile(true, { DepotDecor = "DepotDecor_Lights" }), "Kai")
		expect(plot.model.Built:FindFirstChild("Slot2")).toBeTruthy()
		expect(#plot.model.Built.Decor:GetChildren()).toBeGreaterThan(0)
		expect(nameTagOf(plot.model.Built.Slot2.Driver).Label.Text).toBe("Benji")
	end)

	it("clear resets the plot to FOR SALE", function()
		local plot, label = makePlotWorld()
		DepotBuilder.apply(plot, makeProfile(true, nil), "Kai", 555)
		DepotBuilder.clear(plot)
		expect(#plot.model.Built:GetChildren()).toBe(0)
		expect(label.Text).toBe("FOR SALE - Depot")
		expect(plot.model:GetAttribute("OwnerUserId")).toBe(0)
		expect(plot.model:GetAttribute("OwnerName")).toBe("")
		-- clear is safe to call twice and apply works again afterwards
		DepotBuilder.clear(plot)
		DepotBuilder.apply(plot, makeProfile(false, nil), "Lena")
		expect(label.Text).toBe("Lena's Depot")
		expect(plot.model.Built:FindFirstChild("Slot1")).toBeTruthy()
	end)

	it("setVanPresent hides and restores the slot visuals", function()
		local plot = makePlotWorld()
		DepotBuilder.apply(plot, makeProfile(false, nil), "Kai")
		local van = plot.model.Built.Slot1.Van
		local visibleBefore = {}
		for _, d in ipairs(van:GetDescendants()) do
			if d:IsA("BasePart") then
				visibleBefore[d] = d.Transparency
			end
		end
		DepotBuilder.setVanPresent(plot, 1, false)
		expect(DepotBuilder.isVanPresent(plot, 1)).toBe(false)
		for part in pairs(visibleBefore) do
			expect(part.Transparency).toBe(1)
		end
		DepotBuilder.setVanPresent(plot, 1, true)
		expect(DepotBuilder.isVanPresent(plot, 1)).toBe(true)
		for part, transparency in pairs(visibleBefore) do
			expect(part.Transparency).toBe(transparency)
		end
		-- unknown slot is a no-op
		DepotBuilder.setVanPresent(plot, 2, false)
		expect(DepotBuilder.isVanPresent(plot, 2)).toBe(false)
	end)
end)
