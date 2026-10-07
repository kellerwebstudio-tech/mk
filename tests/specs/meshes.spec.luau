--!nonstrict
-- Custom vehicle meshes: MeshAssets config, VehicleDefinitions.getEffective, the VehicleBuilder mesh
-- path (MeshBody MeshPart, template cache, fallback), display publishing (VehicleService →
-- ReplicatedStorage.SharedAssets.VehicleDisplays), the client preview clone and the services that
-- read the mesh offsets (VehicleService dismount, PackageBuilder cargo slots).

local function v3(x, y, z)
	return Vector3.new(x, y, z)
end

local function vecOf(t)
	return Vector3.new(t[1], t[2], t[3])
end

local function requireShared(path)
	return shim.requirePath("ReplicatedStorage/Shared/" .. path)
end

local function requireBuilder(name)
	return shim.requirePath("ServerScriptService/DeliveryDash/Builders/" .. name)
end

local function partNames(folder)
	local names = {}
	for _, child in ipairs(folder:GetChildren()) do
		if child:IsA("BasePart") then
			table.insert(names, child.Name)
		end
	end
	table.sort(names)
	return names
end

local function meshCalls()
	local n = 0
	for _, call in ipairs(shim.assetService.calls) do
		if call.method == "CreateMeshPartAsync" then
			n += 1
		end
	end
	return n
end

-- Sets body ids for the given vehicles on the live MeshAssets module table (restored by resetIds).
local SAVED = {}
local function setIds(MeshAssets, ids)
	for vehicleId, pair in pairs(ids) do
		local entry = MeshAssets.Vehicles[vehicleId]
		SAVED[vehicleId] = { meshId = entry.body.meshId, textureId = entry.body.textureId }
		entry.body.meshId = pair[1]
		entry.body.textureId = pair[2]
	end
end

local function resetIds(MeshAssets)
	for vehicleId, saved in pairs(SAVED) do
		local entry = MeshAssets.Vehicles[vehicleId]
		if entry then
			entry.body.meshId = saved.meshId
			entry.body.textureId = saved.textureId
		end
	end
	SAVED = {}
end

-------------------------------------------------------------------------------
describe("MeshAssets + VehicleDefinitions.getEffective", function()
	local MeshAssets, VehicleDefinitions

	beforeEach(function()
		shim.reset()
		shim.setContext("server")
		MeshAssets = requireShared("Config/MeshAssets")
		VehicleDefinitions = requireShared("Definitions/VehicleDefinitions")
	end)

	afterEach(function()
		resetIds(MeshAssets)
	end)

	it("ships with every vehicle unconfigured (meshId 0) and helpers answer accordingly", function()
		for _, id in ipairs(VehicleDefinitions.Order) do
			expect(MeshAssets.Vehicles[id]).toBeTruthy()
			expect(MeshAssets.Vehicles[id].body.meshId).toBe(0)
			expect(MeshAssets.hasBody(id)).toBe(false)
			expect(MeshAssets.bodyIds(id)).toBeNil()
			expect(MeshAssets.wheelIds(id, "FrontWheel")).toBeNil()
		end
		expect(MeshAssets.hasBody("Nope")).toBe(false)
		expect(MeshAssets.assetUrl(0)).toBe("")
		expect(MeshAssets.assetUrl(42)).toBe("rbxassetid://42")
	end)

	it("reports configured body and wheel ids", function()
		setIds(MeshAssets, { Van = { 123456, 654321 }, Bicycle = { 77, 0 } })
		expect(MeshAssets.hasBody("Van")).toBe(true)
		local meshId, textureId = MeshAssets.bodyIds("Van")
		expect(meshId).toBe(123456)
		expect(textureId).toBe(654321)
		local bikeMesh, bikeTexture = MeshAssets.bodyIds("Bicycle")
		expect(bikeMesh).toBe(77)
		expect(bikeTexture).toBe(0)
		expect(MeshAssets.hasBody("Scooter")).toBe(false)
		MeshAssets.Vehicles.Van.wheels.FrontWheelL = { meshId = 9, textureId = 10 }
		local wm, wt = MeshAssets.wheelIds("Van", "FrontWheelL")
		expect(wm).toBe(9)
		expect(wt).toBe(10)
		expect(MeshAssets.wheelIds("Van", "RearWheelL")).toBeNil()
		MeshAssets.Vehicles.Van.wheels.FrontWheelL = nil
	end)

	it("getEffective returns the generated numbers without a mesh and the mesh overrides with one", function()
		for _, id in ipairs(VehicleDefinitions.Order) do
			local def = VehicleDefinitions.get(id)
			expect(def.mesh).toBeTruthy()
			local plain = VehicleDefinitions.getEffective(id, false)
			expect(plain.seatOffset).toEqual(def.seatOffset)
			expect(plain.cargoOffset).toEqual(def.cargoOffset)
			expect(plain.cargoLayout).toEqual(def.cargoLayout)
			expect(plain.chassisSize).toEqual(def.chassisSize)
			expect(plain.dismountOffset).toEqual(def.dismountOffset)

			local mesh = VehicleDefinitions.getEffective(id, true)
			expect(mesh.seatOffset).toEqual(def.mesh.seatOffset)
			expect(mesh.cargoOffset).toEqual(def.mesh.cargoOffset)
			expect(mesh.cargoLayout).toEqual(def.mesh.cargoLayout)
			expect(mesh.chassisSize).toEqual(def.mesh.chassisSize or def.chassisSize)
			expect(mesh.dismountOffset).toEqual(def.mesh.dismountOffset or def.dismountOffset)
		end
		-- The agreed numbers (assets/meshes/*/meta.json).
		local bike = VehicleDefinitions.get("Bicycle").mesh
		expect(bike.body.size).toEqual({ 2.682, 3.647, 6.2 })
		expect(bike.body.offset).toEqual({ 0, 0.323, 0 })
		expect(bike.seatOffset).toEqual({ 0, 1.6, 0.5 })
		expect(bike.cargoOffset).toEqual({ 0, 2.45, 2.3 })
		expect(bike.cargoLayout.rows).toBe(2)
		expect(#bike.wheels).toBe(0)
		local scooter = VehicleDefinitions.get("Scooter").mesh
		expect(scooter.body.size).toEqual({ 2.985, 4.273, 6.4 })
		expect(scooter.body.offset).toEqual({ 0, 0.637, 0 })
		expect(scooter.seatOffset).toEqual({ 0, 0.95, 0.3 })
		expect(scooter.cargoOffset).toEqual({ 0, 2.8, 1.6 })
		local van = VehicleDefinitions.get("Van").mesh
		expect(van.body.size).toEqual({ 7.228, 7.251, 13.5 })
		expect(van.body.offset).toEqual({ 0, 1.226, 0 })
		expect(van.chassisSize).toEqual({ 6.6, 3.0, 13.5 })
		expect(van.dismountOffset).toEqual({ -5.2, -2.4, -4.3 })
		expect(van.cargoLayout).toEqual(VehicleDefinitions.get("Van").cargoLayout)
		-- Generated-part numbers are untouched.
		expect(VehicleDefinitions.get("Van").chassisSize).toEqual({ 6.0, 3.0, 13.5 })
		expect(VehicleDefinitions.get("Van").dismountOffset).toEqual({ -5.0, -2.4, -4.3 })
		expect(VehicleDefinitions.get("Bicycle").seatOffset).toEqual({ 0, 1.55, 0.7 })
		expect(function()
			VehicleDefinitions.getEffective("Nope", true)
		end).toThrow("Unknown vehicle id")
	end)
end)

-------------------------------------------------------------------------------
describe("VehicleBuilder mesh path", function()
	local VehicleBuilder, VehicleDefinitions, MeshAssets

	beforeEach(function()
		shim.reset()
		shim.setContext("server")
		MeshAssets = requireShared("Config/MeshAssets")
		VehicleDefinitions = requireShared("Definitions/VehicleDefinitions")
		VehicleBuilder = requireBuilder("VehicleBuilder")
	end)

	afterEach(function()
		resetIds(MeshAssets)
	end)

	it("with ids 0 the output is the generated build (no MeshBody, no asset calls)", function()
		for _, id in ipairs(VehicleDefinitions.Order) do
			local def = VehicleDefinitions.get(id)
			expect(VehicleBuilder.usesMesh(id)).toBe(false)
			local model = VehicleBuilder.build(id, 42, nil)
			local expectedBody = {}
			for _, spec in ipairs(def.visual.parts) do
				table.insert(expectedBody, spec.name)
			end
			table.sort(expectedBody)
			expect(partNames(model.Body)).toEqual(expectedBody)
			local expectedWheels = {}
			for _, spec in ipairs(def.visual.wheels) do
				table.insert(expectedWheels, spec.name)
			end
			table.sort(expectedWheels)
			expect(partNames(model.Wheels)).toEqual(expectedWheels)
			expect(model.Body:FindFirstChild("MeshBody")).toBeNil()
			expect(model:GetAttribute("UsesMesh")).toBe(false)
			expect(model.Chassis.Size).toBeCloseTo(vecOf(def.chassisSize), 1e-6)
			expect(model.Chassis.CargoAttachment.Position).toBeCloseTo(vecOf(def.cargoOffset), 1e-6)
			expect(model.Chassis.DismountAttachment.Position).toBeCloseTo(vecOf(def.dismountOffset), 1e-6)
			expect(model.Seat.CFrame).toBeCloseTo(model.Chassis.CFrame * CFrame.new(vecOf(def.seatOffset)), 1e-5)
			expect(VehicleBuilder.getSlotCFrame(id, 1).Position).toBeCloseTo(vecOf(def.cargoOffset), 1e-6)
		end
		expect(meshCalls()).toBe(0)
		expect(#shim.warnings).toBe(0)
	end)

	it("with ids set it builds a MeshBody, no generated parts, an empty Wheels folder and mesh offsets", function()
		setIds(MeshAssets, { Van = { 5001, 5002 }, Bicycle = { 6001, 0 }, Scooter = { 7001, 7002 } })
		for _, id in ipairs(VehicleDefinitions.Order) do
			local def = VehicleDefinitions.get(id)
			local mesh = def.mesh
			expect(VehicleBuilder.usesMesh(id)).toBe(true)
			local model = VehicleBuilder.build(id, 42, nil)
			expect(model:GetAttribute("UsesMesh")).toBe(true)
			expect(partNames(model.Body)).toEqual({ "MeshBody" })
			local body = model.Body.MeshBody
			expect(body:IsA("MeshPart")).toBe(true)
			expect(body.Size).toBeCloseTo(vecOf(mesh.body.size), 1e-6)
			expect(body.CFrame).toBeCloseTo(model.Chassis.CFrame * CFrame.new(vecOf(mesh.body.offset)), 1e-5)
			expect(body.MeshId).toBe("rbxassetid://" .. tostring(MeshAssets.Vehicles[id].body.meshId))
			if MeshAssets.Vehicles[id].body.textureId > 0 then
				expect(body.TextureID).toBe("rbxassetid://" .. tostring(MeshAssets.Vehicles[id].body.textureId))
			else
				expect(body.TextureID).toBe("")
			end
			expect(body.Massless).toBe(true)
			expect(body.CanCollide).toBe(false)
			expect(body.CanQuery).toBe(false)
			expect(body.CanTouch).toBe(false)
			expect(body.CastShadow).toBe(true)
			expect(body.Anchored).toBe(false)
			expect(body.CollisionGroup).toBe("Vehicles")
			expect(body:GetAttribute("PaintSlot")).toBeNil()
			local weld = body:FindFirstChildWhichIsA("WeldConstraint")
			expect(weld).toBeTruthy()
			expect(weld.Part0).toBe(model.BodyRoot)
			expect(weld.Part1).toBe(body)
			-- No wheels configured: the folder exists and is empty.
			expect(model:FindFirstChild("Wheels")).toBeTruthy()
			expect(#model.Wheels:GetChildren()).toBe(0)
			-- Seat, cargo, chassis and dismount come from the mesh block.
			local eff = VehicleDefinitions.getEffective(id, true)
			expect(model.Seat.CFrame).toBeCloseTo(model.Chassis.CFrame * CFrame.new(vecOf(eff.seatOffset)), 1e-5)
			expect(model.Chassis.CargoAttachment.Position).toBeCloseTo(vecOf(eff.cargoOffset), 1e-6)
			expect(model.Chassis.DismountAttachment.Position).toBeCloseTo(vecOf(eff.dismountOffset), 1e-6)
			expect(model.Chassis.Size).toBeCloseTo(vecOf(eff.chassisSize), 1e-6)
			expect(VehicleBuilder.getSlotCFrame(id, 1).Position).toBeCloseTo(vecOf(eff.cargoOffset), 1e-6)
			local second = if eff.cargoLayout.columns > 1 then v3(eff.cargoLayout.spacingX, 0, 0) else v3(0, eff.cargoLayout.spacingY, 0)
			expect(VehicleBuilder.getSlotCFrame(id, 2).Position).toBeCloseTo(vecOf(eff.cargoOffset) + second, 1e-6)
		end
		expect(VehicleBuilder.getSlotsPerLayer("Bicycle")).toBe(2)
		expect(VehicleBuilder.getSlotsPerLayer("Van")).toBe(6)
		local van = VehicleBuilder.build("Van", 1, nil)
		expect(van.Chassis.Size).toBeCloseTo(v3(6.6, 3.0, 13.5), 1e-6)
		expect(van.Seat.Position).toBeCloseTo(van.Chassis.CFrame:PointToWorldSpace(v3(-1.5, 0.4, -4.3)), 1e-5)
		expect(#shim.warnings).toBe(0)
		-- applyCosmetics leaves the mesh alone.
		local before = van.Body.MeshBody.Color
		VehicleBuilder.applyCosmetics(van, { Primary = { 1, 2, 3 }, Accent = { 4, 5, 6 }, Decal = { 7, 8, 9 } })
		expect(van.Body.MeshBody.Color).toEqual(before)
	end)

	it("creates each mesh template once and clones it per build", function()
		setIds(MeshAssets, { Van = { 5001, 5002 } })
		local first = VehicleBuilder.build("Van", 1, nil)
		local second = VehicleBuilder.build("Van", 2, nil)
		local display = VehicleBuilder.buildDisplay("Van", nil)
		expect(meshCalls()).toBe(1)
		local call = shim.assetService.calls[1]
		expect(call.meshId).toBe(5001)
		expect(typeof(call.content)).toBe("Content")
		expect(call.options.CollisionFidelity).toBe(Enum.CollisionFidelity.Box)
		expect(call.options.RenderFidelity).toBe(Enum.RenderFidelity.Automatic)
		expect(first.Body.MeshBody).never.toBe(second.Body.MeshBody)
		expect(first.Body.MeshBody.MeshId).toBe(second.Body.MeshBody.MeshId)
		expect(display.Body.MeshBody.MeshId).toBe("rbxassetid://5001")
		expect(first.Body.MeshBody.CollisionFidelity).toBe(Enum.CollisionFidelity.Box)
		-- A different texture id is a different template.
		setIds(MeshAssets, { Scooter = { 5001, 9 } })
		VehicleBuilder.build("Scooter", 3, nil)
		expect(meshCalls()).toBe(2)
		-- warmMeshCache loads nothing new for an already cached id and reports usesMesh.
		expect(VehicleBuilder.warmMeshCache("Van")).toBe(true)
		expect(VehicleBuilder.warmMeshCache("Bicycle")).toBe(false)
		expect(meshCalls()).toBe(2)
	end)

	it("falls back to generated parts with a single warning when the mesh fails to load", function()
		setIds(MeshAssets, { Van = { 5001, 5002 } })
		shim.assetService.failNextCalls = 1
		local model = VehicleBuilder.build("Van", 1, nil)
		local def = VehicleDefinitions.get("Van")
		expect(model.Body:FindFirstChild("MeshBody")).toBeNil()
		expect(#model.Body:GetChildren()).toBe(#def.visual.parts)
		expect(#model.Wheels:GetChildren()).toBe(#def.visual.wheels)
		expect(model:GetAttribute("UsesMesh")).toBe(false)
		-- ... and the generated offsets go with the generated geometry.
		expect(model.Chassis.Size).toBeCloseTo(vecOf(def.chassisSize), 1e-6)
		expect(model.Chassis.DismountAttachment.Position).toBeCloseTo(vecOf(def.dismountOffset), 1e-6)
		expect(VehicleBuilder.usesMesh("Van")).toBe(false)
		expect(VehicleBuilder.getSlotCFrame("Van", 1).Position).toBeCloseTo(vecOf(def.cargoOffset), 1e-6)
		expect(#shim.warnings).toBe(1)
		expect(shim.warnings[1]).toMatch("5001")
		-- The failed id is not retried and does not warn again.
		local again = VehicleBuilder.build("Van", 2, nil)
		expect(again.Body:FindFirstChild("MeshBody")).toBeNil()
		local display = VehicleBuilder.buildDisplay("Van", nil)
		expect(display.Body:FindFirstChild("MeshBody")).toBeNil()
		expect(display:GetAttribute("UsesMesh")).toBe(false)
		expect(meshCalls()).toBe(1)
		expect(#shim.warnings).toBe(1)
		-- Other vehicles are unaffected.
		setIds(MeshAssets, { Bicycle = { 6001, 6002 } })
		expect(VehicleBuilder.build("Bicycle", 3, nil).Body:FindFirstChild("MeshBody")).toBeTruthy()
		expect(#shim.warnings).toBe(1)
		-- resetMeshCache forgets the failure so a later attempt may succeed.
		VehicleBuilder.resetMeshCache()
		expect(VehicleBuilder.usesMesh("Van")).toBe(true)
		expect(VehicleBuilder.build("Van", 4, nil).Body:FindFirstChild("MeshBody")).toBeTruthy()
	end)

	it("requests an in-flight template once when builds race during the load (publish + depot + spawn)", function()
		setIds(MeshAssets, { Van = { 5001, 5002 } })
		shim.assetService.latency = 0.2
		local models = {}
		task.spawn(function()
			table.insert(models, VehicleBuilder.buildDisplay("Van", nil))
		end)
		task.spawn(function()
			table.insert(models, VehicleBuilder.build("Van", 1, nil))
		end)
		task.spawn(function()
			table.insert(models, VehicleBuilder.build("Van", 2, nil))
		end)
		expect(#models).toBe(0) -- all three are waiting on the one async call
		shim.advance(1)
		expect(#models).toBe(3)
		expect(meshCalls()).toBe(1)
		local seen = {}
		for _, model in ipairs(models) do
			local body = model.Body:FindFirstChild("MeshBody")
			expect(body).toBeTruthy()
			expect(body.MeshId).toBe("rbxassetid://5001")
			expect(seen[body]).toBeNil()
			seen[body] = true
			expect(model:GetAttribute("UsesMesh")).toBe(true)
		end
		expect(#shim.warnings).toBe(0)
		-- Later builds hit the cache without yielding.
		local later = VehicleBuilder.build("Van", 3, nil)
		expect(later.Body:FindFirstChild("MeshBody")).toBeTruthy()
		expect(meshCalls()).toBe(1)
	end)

	it("a failed in-flight load warns once and every racing build falls back to generated parts", function()
		setIds(MeshAssets, { Van = { 5001, 5002 } })
		shim.assetService.latency = 0.2
		shim.assetService.failNextCalls = 1
		local models = {}
		task.spawn(function()
			table.insert(models, VehicleBuilder.build("Van", 1, nil))
		end)
		task.spawn(function()
			table.insert(models, VehicleBuilder.build("Van", 2, nil))
		end)
		shim.advance(1)
		expect(#models).toBe(2)
		expect(meshCalls()).toBe(1)
		expect(#shim.warnings).toBe(1)
		local def = VehicleDefinitions.get("Van")
		for _, model in ipairs(models) do
			expect(model.Body:FindFirstChild("MeshBody")).toBeNil()
			expect(#model.Body:GetChildren()).toBe(#def.visual.parts)
			expect(model:GetAttribute("UsesMesh")).toBe(false)
			expect(model.Chassis.DismountAttachment.Position).toBeCloseTo(vecOf(def.dismountOffset), 1e-6)
		end
		expect(VehicleBuilder.usesMesh("Van")).toBe(false)
	end)

	it("buildDisplay uses the mesh, anchored, with no constraints", function()
		setIds(MeshAssets, { Scooter = { 7001, 7002 } })
		local display = VehicleBuilder.buildDisplay("Scooter", nil)
		local mesh = VehicleDefinitions.get("Scooter").mesh
		expect(display:GetAttribute("UsesMesh")).toBe(true)
		expect(display.PrimaryPart.Name).toBe("Chassis")
		expect(partNames(display.Body)).toEqual({ "MeshBody" })
		expect(#display.Wheels:GetChildren()).toBe(0)
		local body = display.Body.MeshBody
		expect(body:IsA("MeshPart")).toBe(true)
		expect(body.Anchored).toBe(true)
		expect(body.Size).toBeCloseTo(vecOf(mesh.body.size), 1e-6)
		expect(body.TextureID).toBe("rbxassetid://7002")
		expect(body.CFrame).toBeCloseTo(display.Chassis.CFrame * CFrame.new(vecOf(mesh.body.offset)), 1e-5)
		for _, d in ipairs(display:GetDescendants()) do
			if d:IsA("BasePart") then
				expect(d.Anchored).toBe(true)
				expect(d.CanCollide).toBe(false)
			end
			expect(d:IsA("Motor6D")).toBe(false)
			expect(d:IsA("WeldConstraint")).toBe(false)
			expect(d:IsA("VehicleSeat")).toBe(false)
		end
		-- Pivoting moves the mesh with the chassis (DepotBuilder parks vans this way).
		display:PivotTo(CFrame.new(100, 1.5, 50))
		expect(body.Position).toBeCloseTo(v3(100, 1.5, 50) + vecOf(mesh.body.offset), 1e-5)
	end)

	it("DepotBuilder parked vans use the mesh display", function()
		setIds(MeshAssets, { Van = { 5001, 5002 } })
		local DepotBuilder = requireBuilder("DepotBuilder")
		local plot = Instance.new("Model")
		plot.Name = "Plot1"
		plot:SetAttribute("PlotWidth", 40)
		plot:SetAttribute("PlotDepth", 30)
		plot.Parent = workspace
		local sign = Instance.new("Part")
		sign.Name = "Sign"
		sign.Parent = plot
		local origin = CFrame.new(100, 0.4, 60)
		local plotWorld = { model = plot, origin = origin, parking = { origin * CFrame.new(-10, 0, 5) }, signPart = sign, plotId = "Plot1" }
		local profile = { depot = { owned = true, slotsUnlocked = 1, drivers = { { hired = true, name = "Ava", pending = 0 } } }, cosmetics = { owned = {}, equipped = {} } }
		DepotBuilder.apply(plotWorld, profile, "Kai", 5)
		local van = plot.Built.Slot1.Van
		expect(van.Body:FindFirstChild("MeshBody")).toBeTruthy()
		expect(van.Body.MeshBody:IsA("MeshPart")).toBe(true)
		expect(van.Body.MeshBody.Anchored).toBe(true)
		expect(#van.Wheels:GetChildren()).toBe(0)
		expect(meshCalls()).toBe(1)
	end)

	it("creates configured wheel meshes with WheelMotor, attributes and C0 = offset", function()
		setIds(MeshAssets, { Van = { 5001, 5002 } })
		local def = VehicleDefinitions.get("Van")
		-- Simulate a later wheel configuration without code changes: definition + ids.
		local savedWheels = def.mesh.wheels
		def.mesh.wheels = {
			{ name = "FrontWheelL", radius = 1.3, offset = { -2.5, -1.1, -4.0 }, steerable = true },
			{ name = "RearWheelL", radius = 1.3, offset = { -2.5, -1.1, 3.6 }, steerable = false },
		}
		MeshAssets.Vehicles.Van.wheels.FrontWheelL = { meshId = 8001, textureId = 8002 }
		local model = VehicleBuilder.build("Van", 1, nil)
		def.mesh.wheels = savedWheels
		MeshAssets.Vehicles.Van.wheels.FrontWheelL = nil
		-- Only the configured wheel exists; the unconfigured one is skipped (baked into the body).
		expect(partNames(model.Wheels)).toEqual({ "FrontWheelL" })
		local wheel = model.Wheels.FrontWheelL
		expect(wheel:IsA("MeshPart")).toBe(true)
		expect(wheel.MeshId).toBe("rbxassetid://8001")
		expect(wheel.TextureID).toBe("rbxassetid://8002")
		expect(wheel:GetAttribute("Steerable")).toBe(true)
		expect(wheel:GetAttribute("Radius")).toBe(1.3)
		local motor = wheel:FindFirstChild("WheelMotor")
		expect(motor:IsA("Motor6D")).toBe(true)
		expect(motor.Part0).toBe(model.BodyRoot)
		expect(motor.Part1).toBe(wheel)
		expect(motor.C0.Position).toBeCloseTo(v3(-2.5, -1.1, -4.0), 1e-6)
		expect(wheel.CFrame).toBeCloseTo(model.Chassis.CFrame * CFrame.new(-2.5, -1.1, -4.0), 1e-5)
		expect(meshCalls()).toBe(2)
	end)
end)

-------------------------------------------------------------------------------
-- VehicleService with mesh vehicles (minimal context: no city, vehicle spawns at the character)
-------------------------------------------------------------------------------

-- Call after shim.reset()/setIds: a reset here would re-execute MeshAssets and drop the test ids.
local function serverEnv(ownedVehicles)
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local Remotes = require(ReplicatedStorage.Shared.Util.Remotes)
	Remotes.createAll()
	local profile = { ownedVehicles = ownedVehicles or { Bicycle = true, Scooter = true, Van = true }, cosmetics = { owned = {}, equipped = {} } }
	local PlayerDataService = {
		GetProfile = function()
			return profile
		end,
	}
	local VehicleService = shim.requirePath("ServerScriptService/DeliveryDash/Services/VehicleService")
	local ctx = {
		services = { PlayerDataService = PlayerDataService },
		remotes = Remotes,
		layout = { groundY = 0, killY = -60, bounds = { minX = -1000, maxX = 1000, minZ = -1000, maxZ = 1000 } },
		builders = { VehicleBuilder = requireBuilder("VehicleBuilder") },
		isStudio = false,
	}
	VehicleService.Init(ctx)
	VehicleService.Start()
	return VehicleService, ctx
end

describe("VehicleService with mesh vehicles", function()
	local MeshAssets

	afterEach(function()
		if MeshAssets then
			resetIds(MeshAssets)
		end
	end)

	it("publishes SharedAssets.VehicleDisplays only for vehicles with ids set", function()
		shim.reset()
		shim.setContext("server")
		MeshAssets = requireShared("Config/MeshAssets")
		setIds(MeshAssets, { Van = { 5001, 5002 }, Bicycle = { 6001, 6002 } })
		local VehicleService = serverEnv()
		local ReplicatedStorage = game:GetService("ReplicatedStorage")
		local displays = ReplicatedStorage.SharedAssets:FindFirstChild("VehicleDisplays")
		expect(displays).toBeTruthy()
		expect(displays:FindFirstChild("Van")).toBeTruthy()
		expect(displays:FindFirstChild("Bicycle")).toBeTruthy()
		expect(displays:FindFirstChild("Scooter")).toBeNil()
		local van = displays.Van
		expect(van:IsA("Model")).toBe(true)
		expect(van:GetAttribute("VehicleId")).toBe("Van")
		expect(van:GetAttribute("UsesMesh")).toBe(true)
		expect(van.Body.MeshBody:IsA("MeshPart")).toBe(true)
		expect(van.Body.MeshBody.Anchored).toBe(true)
		expect(van.Body.MeshBody.TextureID).toBe("rbxassetid://5002")
		-- The publish warmed the cache: a spawn creates no further templates, and republishing
		-- replaces the entries without duplicates.
		local calls = meshCalls()
		expect(calls).toBe(2)
		VehicleService.PublishDisplays()
		expect(#displays:GetChildren()).toBe(2)
		expect(meshCalls()).toBe(calls)
		expect(#shim.warnings).toBe(0)
	end)

	it("publishes nothing with ids 0", function()
		shim.reset()
		shim.setContext("server")
		MeshAssets = requireShared("Config/MeshAssets")
		serverEnv()
		local ReplicatedStorage = game:GetService("ReplicatedStorage")
		expect(ReplicatedStorage.SharedAssets:FindFirstChild("VehicleDisplays")).toBeNil()
		expect(meshCalls()).toBe(0)
	end)

	it("skips the display when the mesh fails to load (generated preview on the client)", function()
		shim.reset()
		shim.setContext("server")
		MeshAssets = requireShared("Config/MeshAssets")
		setIds(MeshAssets, { Van = { 5001, 5002 } })
		shim.assetService.failNextCalls = 1
		serverEnv()
		local ReplicatedStorage = game:GetService("ReplicatedStorage")
		expect(ReplicatedStorage.SharedAssets:FindFirstChild("VehicleDisplays")).toBeNil()
		expect(#shim.warnings).toBe(1)
	end)

	it("Spawn, Mount and Dismount work with a mesh Van and dismount at the mesh offset", function()
		shim.reset()
		shim.setContext("server")
		MeshAssets = requireShared("Config/MeshAssets")
		setIds(MeshAssets, { Van = { 5001, 5002 } })
		local VehicleService = serverEnv()
		local player = shim.addPlayer("Rider", 401)
		local character = shim.spawnCharacter(player, CFrame.new(10, 3, 20))
		shim.advance(0.1)

		expect(VehicleService.Spawn(player, "Van").ok).toBe(true)
		local record = VehicleService.GetVehicle(player)
		expect(record.model.Body:FindFirstChild("MeshBody")).toBeTruthy()
		expect(#record.model.Wheels:GetChildren()).toBe(0)
		expect(record.chassis.Size).toBeCloseTo(v3(6.6, 3.0, 13.5), 1e-6)
		-- (no city graph here: the vehicle spawns beside the character; the ground snap is checked after dismount)

		character:PivotTo(CFrame.new(record.chassis.Position + v3(3, 0, 0)))
		expect(VehicleService.Mount(player).ok).toBe(true)
		expect(VehicleService.GetState(player)).toBe("Driving")
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		expect(record.seat.Occupant).toBe(humanoid)

		-- The character is placed from the chassis pose at dismount time (the chassis is then snapped to the ground).
		local beforeDismount = record.chassis.CFrame
		expect(VehicleService.Dismount(player).ok).toBe(true)
		expect(VehicleService.GetState(player)).toBe("Parked")
		expect(record.seat.Occupant).toBeNil()
		local expected = beforeDismount:PointToWorldSpace(v3(-5.2, -2.4, -4.3)) + v3(0, 3, 0)
		expect(character:GetPivot().Position).toBeCloseTo(expected, 1e-3)
		expect(record.chassis.Anchored).toBe(true)
		expect(record.chassis.Position.Y).toBeCloseTo(2.4, 1e-3)

		-- The definition fallback (no DismountAttachment) agrees with the mesh block too.
		character:PivotTo(CFrame.new(record.chassis.Position + v3(3, 0, 0)))
		expect(VehicleService.Mount(player).ok).toBe(true)
		record.chassis.DismountAttachment:Destroy()
		beforeDismount = record.chassis.CFrame
		expect(VehicleService.Dismount(player).ok).toBe(true)
		expected = beforeDismount:PointToWorldSpace(v3(-5.2, -2.4, -4.3)) + v3(0, 3, 0)
		expect(character:GetPivot().Position).toBeCloseTo(expected, 1e-3)

		expect(VehicleService.Despawn(player).ok).toBe(true)
		expect(#shim.warnings).toBe(0)
	end)

	it("PackageBuilder.attachToVehicle uses the mesh cargo slots", function()
		shim.reset()
		shim.setContext("server")
		MeshAssets = requireShared("Config/MeshAssets")
		setIds(MeshAssets, { Bicycle = { 6001, 6002 } })
		local VehicleBuilder = requireBuilder("VehicleBuilder")
		local PackageBuilder = requireBuilder("PackageBuilder")
		local VehicleDefinitions = requireShared("Definitions/VehicleDefinitions")
		local mesh = VehicleDefinitions.get("Bicycle").mesh
		local vehicle = VehicleBuilder.build("Bicycle", 7, nil)
		vehicle.Parent = workspace
		vehicle:PivotTo(CFrame.new(100, 1.5, 50) * CFrame.Angles(0, math.rad(90), 0))
		local record = { model = vehicle, chassis = vehicle.Chassis, seat = vehicle.Seat, bodyRoot = vehicle.BodyRoot, vehicleId = "Bicycle", state = "Parked", ownerUserId = 7, lastSafePosition = Vector3.zero, cargoAttachment = vehicle.Chassis.CargoAttachment, spawnedAt = 0, lastRecoverAt = 0 }
		local first = PackageBuilder.build("FoodBag", nil)
		local second = PackageBuilder.build("FoodBag", nil)
		PackageBuilder.attachToVehicle(first, record, 1)
		PackageBuilder.attachToVehicle(second, record, 2)
		expect(first.Parent).toBe(vehicle.Cargo)
		local slot1 = vehicle.Chassis.CFrame:PointToWorldSpace(vecOf(mesh.cargoOffset))
		local slot2 = vehicle.Chassis.CFrame:PointToWorldSpace(vecOf(mesh.cargoOffset) + v3(0, mesh.cargoLayout.spacingY, 0))
		expect(first.PrimaryPart.Position).toBeCloseTo(slot1, 1e-4)
		expect(second.PrimaryPart.Position).toBeCloseTo(slot2, 1e-4)
		expect(first.PrimaryPart.Position).toBeCloseTo(vehicle.Chassis.CargoAttachment.WorldPosition, 1e-4)
		-- Generated bicycle slots differ, proving the mesh layout is in effect.
		local generated = vehicle.Chassis.CFrame * VehicleBuilder.getSlotCFrame("Scooter", 1)
		expect((generated.Position - slot1).Magnitude).toBeGreaterThan(0.1)
	end)
end)

-------------------------------------------------------------------------------
describe("CosmeticsController mesh previews", function()
	local MeshAssets

	local function clientSetup()
		shim.reset()
		shim.setContext("client")
		MeshAssets = requireShared("Config/MeshAssets")
		-- StarterPlayer holds two StarterPlayerScripts in the harness (see client.spec.luau): scan for the root.
		local root
		for _, child in ipairs(game:GetService("StarterPlayer"):GetChildren()) do
			root = child:FindFirstChild("DeliveryDashClient") or root
		end
		local Cosmetics = require(root.Controllers.CosmeticsController)
		Cosmetics.Init({ state = { get = function() return nil end }, controllers = {} })
		Cosmetics.Start()
		return Cosmetics
	end

	local function publishDisplay(vehicleId)
		local ReplicatedStorage = game:GetService("ReplicatedStorage")
		local displays = ReplicatedStorage.SharedAssets:FindFirstChild("VehicleDisplays")
		if not displays then
			displays = Instance.new("Folder")
			displays.Name = "VehicleDisplays"
			displays.Parent = ReplicatedStorage.SharedAssets
		end
		-- What the server publishes: VehicleBuilder.buildDisplay output renamed to the vehicle id.
		local VehicleBuilder = requireBuilder("VehicleBuilder")
		local display = VehicleBuilder.buildDisplay(vehicleId, nil)
		display.Name = vehicleId
		display.Parent = displays
		return display
	end

	afterEach(function()
		if MeshAssets then
			resetIds(MeshAssets)
		end
	end)

	it("clones the published display when present", function()
		local Cosmetics = clientSetup()
		setIds(MeshAssets, { Van = { 5001, 5002 } })
		local published = publishDisplay("Van")
		local holder = Instance.new("Folder")
		holder.Parent = workspace
		local model = Cosmetics.BuildDisplayVehicle("Van", holder)
		expect(model.Parent).toBe(holder)
		expect(model).never.toBe(published)
		expect(model.Name).toBe("VehicleDisplay")
		expect(model:GetAttribute("VehicleId")).toBe("Van")
		expect(model.PrimaryPart.Name).toBe("Chassis")
		expect(model.Body:FindFirstChild("MeshBody")).toBeTruthy()
		expect(model.Body.MeshBody:IsA("MeshPart")).toBe(true)
		expect(model.Body.MeshBody.MeshId).toBe("rbxassetid://5001")
		expect(#model.Wheels:GetChildren()).toBe(0)
		for _, part in ipairs(model:GetDescendants()) do
			if part:IsA("BasePart") then
				expect(part.Anchored).toBe(true)
				expect(part.CanCollide).toBe(false)
			end
		end
		-- The published template is untouched and the radius bounds the mesh.
		expect(published.Parent.Name).toBe("VehicleDisplays")
		expect(Cosmetics.GetDisplayRadius("Van")).toBeGreaterThan(7)
		expect(#shim.warnings).toBe(0)
	end)

	it("falls back to the generated preview when nothing is published or ids are 0", function()
		local Cosmetics = clientSetup()
		local VehicleDefinitions = requireShared("Definitions/VehicleDefinitions")
		-- ids 0: generated, no waiting
		local generated = Cosmetics.BuildDisplayVehicle("Van", nil)
		expect(#generated.Body:GetChildren()).toBe(#VehicleDefinitions.Vehicles.Van.visual.parts)
		expect(#generated.Wheels:GetChildren()).toBe(4)
		-- ids set but the server published nothing: waits DISPLAY_WAIT (x2) then builds the generated preview
		setIds(MeshAssets, { Scooter = { 7001, 7002 } })
		local result
		task.spawn(function()
			result = Cosmetics.BuildDisplayVehicle("Scooter", nil)
		end)
		expect(result).toBeNil()
		shim.advance(Cosmetics.DISPLAY_WAIT * 2 + 0.5)
		expect(result).toBeTruthy()
		expect(#result.Body:GetChildren()).toBe(#VehicleDefinitions.Vehicles.Scooter.visual.parts)
		expect(result.Body:FindFirstChild("MeshBody")).toBeNil()
	end)
end)

-------------------------------------------------------------------------------
describe("Harness: AssetService and Content", function()
	beforeEach(function()
		shim.reset()
	end)

	it("Content.fromAssetId is typed Content and CreateMeshPartAsync records calls and honours failNextCalls", function()
		local content = Content.fromAssetId(123)
		expect(typeof(content)).toBe("Content")
		expect(content.AssetId).toBe(123)
		expect(content.Uri).toBe("rbxassetid://123")
		expect(content.Object).toBeNil()
		expect(typeof(Content.none)).toBe("Content")
		expect(Content.fromUri("rbxassetid://55").AssetId).toBe(55)
		local AssetService = game:GetService("AssetService")
		local part = AssetService:CreateMeshPartAsync(content, { CollisionFidelity = Enum.CollisionFidelity.Box })
		expect(part:IsA("MeshPart")).toBe(true)
		expect(part.MeshId).toBe("rbxassetid://123")
		expect(part.Size).toEqual(Vector3.new(1, 1, 1))
		expect(part.CollisionFidelity).toBe(Enum.CollisionFidelity.Box)
		expect(#shim.assetService.calls).toBe(1)
		expect(shim.assetService.calls[1].meshId).toBe(123)
		shim.assetService.failNextCalls = 1
		expect(function()
			AssetService:CreateMeshPartAsync(content)
		end).toThrow("simulated")
		expect(#shim.assetService.calls).toBe(2)
		expect(AssetService:CreateMeshPartAsync(content):IsA("MeshPart")).toBe(true)
		expect(function()
			AssetService:CreateMeshPartAsync("rbxassetid://1")
		end).toThrow("Content")
		local clone = part:Clone()
		expect(clone.MeshId).toBe("rbxassetid://123")
	end)
end)
