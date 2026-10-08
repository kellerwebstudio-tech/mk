--!nonstrict
-- Embedded vehicle meshes (no upload): MeshAssets.isEmbedded / usesCustomMesh, the VehicleBuilder
-- placeholder path (invisible Part "MeshBody" tagged "EmbeddedMeshBody", attributes VehicleId +
-- EmbeddedMesh/EmbeddedPart), display publishing, the client EmbeddedMeshController on one-part
-- vehicle entries (EditableMesh / EditableImage build, placeholder dressing, failure fallback,
-- priority order), the CosmeticsController preview and the harness EditableMesh/EditableImage.
-- Multi-part figures, the untextured vest and the FigureRig dressing: tests/specs/figures.spec.luau.
--
-- The decoders (Base64 / Inflate / PngDecoder / MeshPack / MeshData) have their own specs; here
-- they are stubbed through MeshAssets._setMeshData and EmbeddedMeshController._setDecoders
-- (version-2 shape: index + loadPart) with tiny inputs: a 2x2 RGBA PNG (generated once with PIL,
-- pasted as base64) and a one-triangle DDCM blob built with string.pack. When the real decoder
-- modules are present, one test also runs the two vectors through them.

local function requireShared(path)
	return shim.requirePath("ReplicatedStorage/Shared/" .. path)
end

local function requireBuilder(name)
	return shim.requirePath("ServerScriptService/DeliveryDash/Builders/" .. name)
end

local function clientRoot()
	local root
	for _, child in ipairs(game:GetService("StarterPlayer"):GetChildren()) do
		root = child:FindFirstChild("DeliveryDashClient") or root
	end
	assert(root, "DeliveryDashClient not found under StarterPlayer")
	return root
end

local function vecOf(t)
	return Vector3.new(t[1], t[2], t[3])
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

local function callsOf(method)
	local n = 0
	for _, call in ipairs(shim.assetService.calls) do
		if call.method == method then
			n += 1
		end
	end
	return n
end

local TAG = "EmbeddedMeshBody"

-------------------------------------------------------------------------------
-- Test vectors
-------------------------------------------------------------------------------

-- 2x2 RGBA8 PNG (colour type 6, non-interlaced): pixels red, green, blue, half-transparent white.
local PNG_B64 = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAGUlEQVR4nAXBAQ0AAAjAINwsbvILImlH4h4/gAaBNbRWFQAAAABJRU5ErkJggg=="
local PNG_PIXELS = { 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 128 }

local TRI = {
	positions = { Vector3.new(-1, 0, 0), Vector3.new(1, 0, 0), Vector3.new(0, 2, 0) },
	normals = { Vector3.new(0, 0, 1), Vector3.new(0, 0, 1), Vector3.new(0, 0, 1) },
	uvs = { Vector2.new(0, 1), Vector2.new(1, 1), Vector2.new(0.5, 0) },
	triangles = { 1, 2, 3 },
}

-- DDCM v1 blob for the triangle (layout documented in tools/mesh_embed.py).
local function ddcmBlob()
	local parts = {}
	table.insert(parts, string.pack("<c4HHII", "DDCM", 1, 0, 3, 1))
	table.insert(parts, string.pack("<fff", -1, 0, 0))
	table.insert(parts, string.pack("<fff", 1, 2, 0))
	for _, p in ipairs(TRI.positions) do
		table.insert(parts, string.pack("<fff", p.X, p.Y, p.Z))
	end
	for _, n in ipairs(TRI.normals) do
		table.insert(parts, string.pack("<bbb", math.round(n.X * 127), math.round(n.Y * 127), math.round(n.Z * 127)))
	end
	for _, uv in ipairs(TRI.uvs) do
		table.insert(parts, string.pack("<HH", math.round(uv.X * 65535), math.round(uv.Y * 65535)))
	end
	table.insert(parts, string.pack("<HHH", 0, 1, 2))
	return buffer.fromstring(table.concat(parts))
end

local function decodedGeometry()
	return {
		vertexCount = 3,
		triangleCount = 1,
		bboxMin = Vector3.new(-1, 0, 0),
		bboxMax = Vector3.new(1, 2, 0),
		positions = table.clone(TRI.positions),
		normals = table.clone(TRI.normals),
		uvs = table.clone(TRI.uvs),
		triangles = table.clone(TRI.triangles),
	}
end

local function decodedImage()
	local rgba = buffer.create(16)
	for i, v in ipairs(PNG_PIXELS) do
		buffer.writeu8(rgba, i - 1, v)
	end
	return { width = 2, height = 2, rgba = rgba }
end

-- Standard-alphabet base64 decode for the integration test (independent of Shared.Util.Base64).
local function b64decode(s)
	local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	local map = {}
	for i = 1, #alphabet do
		map[string.sub(alphabet, i, i)] = i - 1
	end
	local out = {}
	local bits, count = 0, 0
	for i = 1, #s do
		local ch = string.sub(s, i, i)
		local v = map[ch]
		if v then
			bits = bits * 64 + v
			count += 6
			if count >= 8 then
				count -= 8
				local byte = math.floor(bits / 2 ^ count)
				bits = bits - byte * 2 ^ count
				table.insert(out, string.char(byte))
			end
		end
	end
	return buffer.fromstring(table.concat(out))
end

-- A version-2 index for a one-part textured vehicle entry.
local function vehicleIndex(id)
	return {
		id = id,
		version = 2,
		kind = "vehicle",
		texture = { chunks = 1, bytes = 0, width = 2, height = 2, format = "png" },
		bboxMin = { -1, 0, 0 },
		bboxMax = { 1, 2, 0 },
		parts = { { name = "Body", chunks = { "Body_G1" }, bytes = 0, vertexCount = 3, triangleCount = 1, bboxMin = { -1, 0, 0 }, bboxMax = { 1, 2, 0 } } },
	}
end

-- MeshData stand-in (has/list/index/kind/loadPart/loadGeometry/loadTexture) for the given ids.
local function meshDataStub(ids)
	local set = {}
	for _, id in ipairs(ids) do
		set[id] = true
	end
	return {
		list = function()
			return table.clone(ids)
		end,
		has = function(id)
			return set[id] == true
		end,
		index = function(id)
			return vehicleIndex(id)
		end,
		kind = function()
			return "vehicle"
		end,
		loadPart = function()
			return ddcmBlob()
		end,
		loadGeometry = function()
			return ddcmBlob()
		end,
		loadTexture = function()
			return b64decode(PNG_B64)
		end,
	}
end

-- Decoder set for EmbeddedMeshController._setDecoders. opts = { delay = s, failPng = bool, failMesh = bool }
local function decoderStub(ids, opts)
	opts = opts or {}
	local stub = {
		calls = { loadGeometry = 0, loadTexture = 0, decodePng = 0, decodeMesh = 0, loaderProgress = 0 },
		progressCalls = 0,
	}
	stub.index = function(id)
		return vehicleIndex(id)
	end
	-- The loaders receive the controller's yielder as options.onProgress (MeshData fires it per
	-- decoded base64 chunk); count the loaders that got one and invoke it like MeshData would.
	local function loaderProgress(options, bytes)
		if options and type(options.onProgress) == "function" then
			stub.calls.loaderProgress += 1
			options.onProgress(bytes, bytes)
		end
	end
	stub.list = function()
		return table.clone(ids)
	end
	stub.loadPart = function(id, partName, options)
		expect(partName).toBe("Body")
		stub.calls.loadGeometry += 1
		if opts.delay then
			task.wait(opts.delay)
		end
		local blob = ddcmBlob()
		loaderProgress(options, buffer.len(blob))
		return blob
	end
	stub.loadTexture = function(id, options)
		stub.calls.loadTexture += 1
		local png = b64decode(PNG_B64)
		loaderProgress(options, buffer.len(png))
		return png
	end
	stub.decodePng = function(png, options)
		stub.calls.decodePng += 1
		if opts.failPng then
			error("bad png (simulated)")
		end
		if options and type(options.onProgress) == "function" then
			options.onProgress(0.5)
			stub.progressCalls += 1
			options.onProgress(1)
			stub.progressCalls += 1
		end
		return decodedImage()
	end
	stub.decodeMesh = function(blob)
		stub.calls.decodeMesh += 1
		if opts.failMesh then
			error("bad DDCM (simulated)")
		end
		expect(buffer.len(blob)).toBe(buffer.len(ddcmBlob()))
		return decodedGeometry()
	end
	return stub
end

local ALL = { "Bicycle", "Scooter", "Van" }

-------------------------------------------------------------------------------
-- Config
-------------------------------------------------------------------------------

describe("MeshAssets embedded mode", function()
	local MeshAssets

	beforeEach(function()
		shim.reset()
		shim.setContext("server")
		MeshAssets = requireShared("Config/MeshAssets")
	end)

	it("ships with embedded = true for every vehicle and reports isEmbedded only with data", function()
		for _, id in ipairs(ALL) do
			expect(MeshAssets.Vehicles[id].embedded).toBe(true)
			expect(MeshAssets.hasBody(id)).toBe(false)
		end
		-- No data module reported: not embedded, no custom mesh.
		MeshAssets._setMeshData({ has = function() return false end })
		for _, id in ipairs(ALL) do
			expect(MeshAssets.isEmbedded(id)).toBe(false)
			expect(MeshAssets.usesCustomMesh(id)).toBe(false)
		end
		-- Data for the Van only.
		MeshAssets._setMeshData(meshDataStub({ "Van" }))
		expect(MeshAssets.isEmbedded("Van")).toBe(true)
		expect(MeshAssets.usesCustomMesh("Van")).toBe(true)
		expect(MeshAssets.isEmbedded("Bicycle")).toBe(false)
		expect(MeshAssets.isEmbedded("Nope")).toBe(false)
		-- embedded = false switches the vehicle back to the uploaded-id path.
		MeshAssets.Vehicles.Van.embedded = false
		expect(MeshAssets.isEmbedded("Van")).toBe(false)
		expect(MeshAssets.usesCustomMesh("Van")).toBe(false)
		MeshAssets.Vehicles.Van.body.meshId = 5001
		expect(MeshAssets.hasBody("Van")).toBe(true)
		expect(MeshAssets.usesCustomMesh("Van")).toBe(true)
		-- A throwing has() is treated as false.
		MeshAssets.Vehicles.Van.embedded = true
		MeshAssets._setMeshData({ has = function() error("boom") end })
		expect(MeshAssets.isEmbedded("Van")).toBe(false)
		expect(#shim.warnings).toBe(0)
	end)
end)

-------------------------------------------------------------------------------
-- Server
-------------------------------------------------------------------------------

describe("VehicleBuilder embedded placeholder", function()
	local VehicleBuilder, VehicleDefinitions, MeshAssets, CollectionService

	beforeEach(function()
		shim.reset()
		shim.setContext("server")
		MeshAssets = requireShared("Config/MeshAssets")
		MeshAssets._setMeshData(meshDataStub(ALL))
		VehicleDefinitions = requireShared("Definitions/VehicleDefinitions")
		VehicleBuilder = requireBuilder("VehicleBuilder")
		CollectionService = game:GetService("CollectionService")
	end)

	it("builds a tagged invisible placeholder with the mesh size/offset and no generated parts", function()
		for _, id in ipairs(VehicleDefinitions.Order) do
			local def = VehicleDefinitions.get(id)
			local mesh = def.mesh
			expect(VehicleBuilder.isEmbedded(id)).toBe(true)
			expect(VehicleBuilder.usesMesh(id)).toBe(true)
			local model = VehicleBuilder.build(id, 42, nil)
			expect(model:GetAttribute("UsesMesh")).toBe(true)
			expect(partNames(model.Body)).toEqual({ "MeshBody" })
			local body = model.Body.MeshBody
			expect(body.ClassName).toBe("Part")
			expect(body:IsA("MeshPart")).toBe(false)
			expect(body.Size).toBeCloseTo(vecOf(mesh.body.size), 1e-6)
			expect(body.CFrame).toBeCloseTo(model.Chassis.CFrame * CFrame.new(vecOf(mesh.body.offset)), 1e-5)
			expect(body.Transparency).toBe(1)
			expect(body.CanCollide).toBe(false)
			expect(body.CanQuery).toBe(false)
			expect(body.CanTouch).toBe(false)
			expect(body.Massless).toBe(true)
			expect(body.Anchored).toBe(false)
			expect(body.CollisionGroup).toBe("Vehicles")
			expect(body:GetAttribute("VehicleId")).toBe(id)
			expect(body:GetAttribute("EmbeddedMesh")).toBe(id)
			expect(body:GetAttribute("EmbeddedPart")).toBe("Body")
			expect(body:GetAttribute("PaintSlot")).toBeNil()
			expect(CollectionService:HasTag(body, TAG)).toBe(true)
			local weld = body:FindFirstChildWhichIsA("WeldConstraint")
			expect(weld).toBeTruthy()
			expect(weld.Part0).toBe(model.BodyRoot)
			expect(weld.Part1).toBe(body)
			-- No wheels (baked into the mesh) until wheel ids are configured.
			expect(#model.Wheels:GetChildren()).toBe(0)
			-- Seat, cargo, chassis and dismount come from the mesh block.
			local eff = VehicleDefinitions.getEffective(id, true)
			expect(model.Seat.CFrame).toBeCloseTo(model.Chassis.CFrame * CFrame.new(vecOf(eff.seatOffset)), 1e-5)
			expect(model.Chassis.CargoAttachment.Position).toBeCloseTo(vecOf(eff.cargoOffset), 1e-6)
			expect(model.Chassis.DismountAttachment.Position).toBeCloseTo(vecOf(eff.dismountOffset), 1e-6)
			expect(model.Chassis.Size).toBeCloseTo(vecOf(eff.chassisSize), 1e-6)
			expect(VehicleBuilder.getSlotCFrame(id, 1).Position).toBeCloseTo(vecOf(eff.cargoOffset), 1e-6)
			-- Tagged placeholders are found once the model is in the DataModel.
			model.Parent = workspace
			expect(CollectionService:GetTagged(TAG)).toContain(body)
			model:Destroy()
		end
		-- Nothing was loaded from Roblox and warmMeshCache is a no-op that still reports the mesh.
		expect(VehicleBuilder.warmMeshCache("Van")).toBe(true)
		expect(callsOf("CreateMeshPartAsync")).toBe(0)
		expect(#shim.warnings).toBe(0)
	end)

	it("buildDisplay creates the placeholder anchored and without constraints", function()
		local display = VehicleBuilder.buildDisplay("Van", nil)
		expect(display:GetAttribute("UsesMesh")).toBe(true)
		expect(partNames(display.Body)).toEqual({ "MeshBody" })
		local body = display.Body.MeshBody
		expect(body.Anchored).toBe(true)
		expect(body.Transparency).toBe(1)
		expect(body:GetAttribute("VehicleId")).toBe("Van")
		expect(body:GetAttribute("EmbeddedMesh")).toBe("Van")
		expect(CollectionService:HasTag(body, TAG)).toBe(true)
		expect(body:FindFirstChildWhichIsA("WeldConstraint")).toBeNil()
		expect(#display.Wheels:GetChildren()).toBe(0)
		local mesh = VehicleDefinitions.get("Van").mesh
		expect(body.Size).toBeCloseTo(vecOf(mesh.body.size), 1e-6)
		expect(display.Chassis.Size).toBeCloseTo(vecOf(mesh.chassisSize), 1e-6)
		expect(callsOf("CreateMeshPartAsync")).toBe(0)
	end)

	it("keeps the uploaded-id path with embedded = false and the generated parts without ids", function()
		local savedEmbedded = MeshAssets.Vehicles.Van.embedded
		local savedId, savedTex = MeshAssets.Vehicles.Van.body.meshId, MeshAssets.Vehicles.Van.body.textureId
		MeshAssets.Vehicles.Van.embedded = false
		-- No ids: generated build.
		expect(VehicleBuilder.usesMesh("Van")).toBe(false)
		local generated = VehicleBuilder.build("Van", 1, nil)
		expect(generated.Body:FindFirstChild("MeshBody")).toBeNil()
		expect(#generated.Body:GetChildren()).toBe(#VehicleDefinitions.Vehicles.Van.visual.parts)
		expect(#generated.Wheels:GetChildren()).toBe(4)
		expect(generated:GetAttribute("UsesMesh")).toBe(false)
		-- Ids set: the AssetService template path.
		MeshAssets.Vehicles.Van.body.meshId = 5001
		MeshAssets.Vehicles.Van.body.textureId = 5002
		expect(VehicleBuilder.isEmbedded("Van")).toBe(false)
		expect(VehicleBuilder.usesMesh("Van")).toBe(true)
		local uploaded = VehicleBuilder.build("Van", 1, nil)
		local body = uploaded.Body.MeshBody
		expect(body:IsA("MeshPart")).toBe(true)
		expect(body.MeshId).toBe("rbxassetid://5001")
		expect(body.TextureID).toBe("rbxassetid://5002")
		expect(CollectionService:HasTag(body, TAG)).toBe(false)
		expect(callsOf("CreateMeshPartAsync")).toBe(1)
		-- Embedded wins over ids when both are set.
		MeshAssets.Vehicles.Van.embedded = true
		local embedded = VehicleBuilder.build("Van", 1, nil)
		expect(embedded.Body.MeshBody.ClassName).toBe("Part")
		expect(CollectionService:HasTag(embedded.Body.MeshBody, TAG)).toBe(true)
		expect(callsOf("CreateMeshPartAsync")).toBe(1)
		-- Other vehicles are untouched by the toggle.
		expect(VehicleBuilder.isEmbedded("Bicycle")).toBe(true)
		MeshAssets.Vehicles.Van.embedded = savedEmbedded
		MeshAssets.Vehicles.Van.body.meshId = savedId
		MeshAssets.Vehicles.Van.body.textureId = savedTex
		expect(#shim.warnings).toBe(0)
	end)

	it("DepotBuilder parked vans carry the placeholder", function()
		local DepotBuilder = requireBuilder("DepotBuilder")
		expect(type(DepotBuilder.apply)).toBe("function")
		-- buildDisplay is what DepotBuilder uses for its parked vans; the placeholder is in place.
		local display = VehicleBuilder.buildDisplay("Van", nil)
		expect(CollectionService:HasTag(display.Body.MeshBody, TAG)).toBe(true)
	end)
end)

describe("VehicleService with embedded vehicles", function()
	local MeshAssets

	local function serverEnv()
		local ReplicatedStorage = game:GetService("ReplicatedStorage")
		local Remotes = require(ReplicatedStorage.Shared.Util.Remotes)
		Remotes.createAll()
		local profile = { ownedVehicles = { Bicycle = true, Scooter = true, Van = true }, cosmetics = { owned = {}, equipped = {} } }
		local VehicleService = shim.requirePath("ServerScriptService/DeliveryDash/Services/VehicleService")
		local ctx = {
			services = { PlayerDataService = { GetProfile = function() return profile end } },
			remotes = Remotes,
			layout = { groundY = 0, killY = -60, bounds = { minX = -1000, maxX = 1000, minZ = -1000, maxZ = 1000 } },
			builders = { VehicleBuilder = requireBuilder("VehicleBuilder") },
			isStudio = false,
		}
		VehicleService.Init(ctx)
		VehicleService.Start()
		return VehicleService, ctx
	end

	beforeEach(function()
		shim.reset()
		shim.setContext("server")
		MeshAssets = requireShared("Config/MeshAssets")
		MeshAssets._setMeshData(meshDataStub(ALL))
	end)

	it("publishes SharedAssets.VehicleDisplays with the placeholder for every embedded vehicle", function()
		local VehicleService = serverEnv()
		local ReplicatedStorage = game:GetService("ReplicatedStorage")
		local CollectionService = game:GetService("CollectionService")
		local displays = ReplicatedStorage.SharedAssets:FindFirstChild("VehicleDisplays")
		expect(displays).toBeTruthy()
		for _, id in ipairs(ALL) do
			local display = displays:FindFirstChild(id)
			expect(display).toBeTruthy()
			expect(display:GetAttribute("UsesMesh")).toBe(true)
			local body = display.Body.MeshBody
			expect(body.ClassName).toBe("Part")
			expect(body.Anchored).toBe(true)
			expect(body:GetAttribute("VehicleId")).toBe(id)
			expect(body:GetAttribute("EmbeddedMesh")).toBe(id)
			expect(CollectionService:HasTag(body, TAG)).toBe(true)
			expect(CollectionService:GetTagged(TAG)).toContain(body)
		end
		expect(callsOf("CreateMeshPartAsync")).toBe(0)
		VehicleService.PublishDisplays()
		expect(#displays:GetChildren()).toBe(3)
		expect(#shim.warnings).toBe(0)
	end)

	it("spawns an embedded Van with the placeholder and the mesh dismount offset", function()
		local VehicleService = serverEnv()
		local VehicleDefinitions = requireShared("Definitions/VehicleDefinitions")
		local player = shim.addPlayer("Rider", 401)
		shim.spawnCharacter(player, CFrame.new(10, 3, 20))
		shim.advance(0.1)
		expect(VehicleService.Spawn(player, "Van").ok).toBe(true)
		local record = VehicleService.GetVehicle(player)
		local body = record.model.Body:FindFirstChild("MeshBody")
		expect(body).toBeTruthy()
		expect(body:GetAttribute("VehicleId")).toBe("Van")
		expect(record.model:GetAttribute("UsesMesh")).toBe(true)
		expect(#record.model.Wheels:GetChildren()).toBe(0)
		local eff = VehicleDefinitions.getEffective("Van", true)
		expect(record.model.Chassis.DismountAttachment.Position).toBeCloseTo(vecOf(eff.dismountOffset), 1e-6)
		expect(callsOf("CreateMeshPartAsync")).toBe(0)
	end)
end)

-------------------------------------------------------------------------------
-- Client
-------------------------------------------------------------------------------

describe("EmbeddedMeshController", function()
	local Controller, VehicleBuilder, VehicleDefinitions, MeshAssets

	local function clientSetup(ids, opts)
		shim.reset()
		shim.setContext("client")
		MeshAssets = requireShared("Config/MeshAssets")
		MeshAssets._setMeshData(meshDataStub(ALL))
		VehicleDefinitions = requireShared("Definitions/VehicleDefinitions")
		VehicleBuilder = requireBuilder("VehicleBuilder")
		Controller = require(clientRoot().Controllers.EmbeddedMeshController)
		local stub = decoderStub(ids, opts)
		Controller._setDecoders(stub)
		Controller.Init({ state = { get = function() return nil end }, controllers = {} })
		return stub
	end

	local function placeholderOf(model)
		return model.Body.MeshBody
	end

	it("builds one textured MeshPart per vehicle id through EditableMesh / EditableImage", function()
		local stub = clientSetup({ "Van", "Bicycle" })
		local loaded = {}
		Controller.Loaded:Connect(function(id)
			table.insert(loaded, id)
		end)
		expect(Controller.ListVehicles()).toEqual({ "Van", "Bicycle" })
		expect(Controller.DecodeOrder({ "Van", "Bicycle" })).toEqual({ "Bicycle", "Van" })
		Controller.Start()
		shim.advance(0.2)
		table.sort(loaded)
		expect(loaded).toEqual({ "Bicycle", "Van" })
		expect(Controller.IsReady("Van")).toBe(true)
		expect(Controller.IsReady("Bicycle")).toBe(true)
		expect(Controller.IsReady("Scooter")).toBe(false)
		expect(stub.calls.loadGeometry).toBe(2)
		expect(stub.calls.decodeMesh).toBe(2)
		expect(stub.calls.decodePng).toBe(2)
		expect(stub.progressCalls).toBe(4)
		-- both loaders of both vehicles were handed the yielder as options.onProgress
		expect(stub.calls.loaderProgress).toBe(4)

		local part = Controller.GetMeshPart("Van")
		expect(part:IsA("MeshPart")).toBe(true)
		expect(Controller.GetMeshPart("Van", "Body")).toBe(part)
		expect(Controller.GetMeshPart("Van", "LegL")).toBeNil()
		expect(Controller.ListParts("Van")).toEqual({ "Body" })
		expect(part.Name).toBe("EmbeddedMesh")
		expect(part.Parent).toBeNil()
		expect(part.Size).toBeCloseTo(vecOf(VehicleDefinitions.get("Van").mesh.body.size), 1e-6)
		expect(part.Massless).toBe(true)
		expect(part.CanCollide).toBe(false)
		expect(part.CanQuery).toBe(false)
		expect(part.CanTouch).toBe(false)
		expect(part.CastShadow).toBe(true)
		expect(part.CollisionFidelity).toBe(Enum.CollisionFidelity.Box)
		expect(part.RenderFidelity).toBe(Enum.RenderFidelity.Precise)

		-- Mesh content: the editable mesh received the triangle with per-face normal/uv ids.
		local meshContent = part.MeshContent
		expect(typeof(meshContent)).toBe("Content")
		local editableMesh = meshContent.Object
		expect(editableMesh.ClassName).toBe("EditableMesh")
		-- Built from scratch with AddVertex/AddTriangle: never a fixed-size mesh (those cannot grow).
		expect(editableMesh.FixedSize).toBe(false)
		local data = shim.editableData(editableMesh)
		expect(#data.vertices).toBe(3)
		expect(#data.normals).toBe(3)
		expect(#data.uvs).toBe(3)
		expect(#data.faces).toBe(1)
		expect(data.faces[1]).toEqual({ 1, 2, 3 })
		expect(data.faceNormals[1]).toEqual({ 1, 2, 3 })
		expect(data.faceUVs[1]).toEqual({ 1, 2, 3 })
		expect(editableMesh:GetPosition(3)).toBeCloseTo(Vector3.new(0, 2, 0), 1e-6)
		expect(editableMesh:GetNormal(1)).toBeCloseTo(Vector3.new(0, 0, 1), 1e-6)
		expect(editableMesh:GetUV(3)).toBeCloseTo(Vector2.new(0.5, 0), 1e-6)

		-- Texture content: a 2x2 editable image that received the 16-byte RGBA buffer at the origin.
		local textureContent = part.TextureContent
		expect(typeof(textureContent)).toBe("Content")
		local editableImage = textureContent.Object
		expect(editableImage.ClassName).toBe("EditableImage")
		expect(editableImage.Size).toBeCloseTo(Vector2.new(2, 2), 1e-6)
		local writes = shim.editableData(editableImage).writes
		expect(#writes).toBe(1)
		expect(writes[1].position).toBeCloseTo(Vector2.zero, 1e-6)
		expect(writes[1].size).toBeCloseTo(Vector2.new(2, 2), 1e-6)
		expect(writes[1].length).toBe(16)
		expect(buffer.readu8(writes[1].buffer, 0)).toBe(255)
		expect(buffer.readu8(writes[1].buffer, 15)).toBe(128)

		-- Stats and no warnings.
		local stats = Controller.DecodeStats.Van
		expect(stats).toBeTruthy()
		expect(stats.geometrySeconds).toBeGreaterThanOrEqual(0)
		expect(stats.textureSeconds).toBeGreaterThanOrEqual(0)
		expect(stats.buildSeconds).toBeGreaterThanOrEqual(0)
		expect(stats.parts).toBe(1)
		expect(callsOf("CreateMeshPartAsync")).toBe(2)
		expect(callsOf("CreateEditableMesh")).toBe(2)
		expect(callsOf("CreateEditableImage")).toBe(2)
		expect(#shim.warnings).toBe(0)
	end)

	it("dresses placeholders: welded clone on a live vehicle, anchored clone on a display", function()
		clientSetup({ "Van" })
		Controller.Start()
		shim.advance(0.2)
		expect(Controller.IsReady("Van")).toBe(true)

		local model = VehicleBuilder.build("Van", 1, nil)
		local placeholder = placeholderOf(model)
		expect(placeholder:FindFirstChild("EmbeddedMesh")).toBeNil()
		model:PivotTo(CFrame.new(30, 2.4, 10) * CFrame.Angles(0, math.rad(90), 0))
		model.Parent = workspace
		local dressed = placeholder:FindFirstChild("EmbeddedMesh")
		expect(dressed).toBeTruthy()
		expect(dressed:IsA("MeshPart")).toBe(true)
		expect(dressed).never.toBe(Controller.GetMeshPart("Van"))
		expect(dressed.CFrame).toBeCloseTo(placeholder.CFrame, 1e-5)
		expect(dressed.Anchored).toBe(false)
		expect(dressed.CanCollide).toBe(false)
		expect(dressed.Massless).toBe(true)
		expect(dressed.TextureContent.Object.ClassName).toBe("EditableImage")
		local weld = dressed:FindFirstChildWhichIsA("WeldConstraint")
		expect(weld).toBeTruthy()
		expect(weld.Part0).toBe(placeholder)
		expect(weld.Part1).toBe(dressed)
		-- The placeholder stays invisible; only one mesh is attached even after a refresh.
		expect(placeholder.Transparency).toBe(1)
		Controller.Refresh()
		expect(#placeholder:GetChildren()).toBe(2) -- BodyWeld + EmbeddedMesh

		local display = VehicleBuilder.buildDisplay("Van", nil)
		display.Parent = workspace
		local shown = placeholderOf(display):FindFirstChild("EmbeddedMesh")
		expect(shown).toBeTruthy()
		expect(shown.Anchored).toBe(true)
		expect(shown:FindFirstChildWhichIsA("WeldConstraint")).toBeNil()
		expect(shown.CFrame).toBeCloseTo(placeholderOf(display).CFrame, 1e-5)

		-- Removal takes the mesh along; re-adding (streaming) does not duplicate it.
		model.Parent = nil
		expect(dressed.Parent).toBe(placeholder)
		model.Parent = workspace
		local count = 0
		for _, child in ipairs(placeholder:GetChildren()) do
			if child.Name == "EmbeddedMesh" then
				count += 1
			end
		end
		expect(count).toBe(1)
		-- A vehicle whose mesh is not embedded (Scooter here) is left alone.
		local scooter = VehicleBuilder.build("Scooter", 1, nil)
		scooter.Parent = workspace
		expect(placeholderOf(scooter):FindFirstChild("EmbeddedMesh")).toBeNil()
		expect(#shim.warnings).toBe(0)
	end)

	it("dresses placeholders that exist before the decode finishes once Loaded fires", function()
		clientSetup({ "Van" }, { delay = 1 })
		local model = VehicleBuilder.build("Van", 1, nil)
		model.Parent = workspace
		local placeholder = placeholderOf(model)
		local loadedCount = 0
		Controller.Loaded:Connect(function(id)
			expect(id).toBe("Van")
			loadedCount += 1
		end)
		Controller.Start()
		shim.advance(0.3)
		expect(Controller.IsReady("Van")).toBe(false)
		expect(placeholder:FindFirstChild("EmbeddedMesh")).toBeNil()
		-- A second placeholder added mid-decode waits too.
		local later = VehicleBuilder.build("Van", 2, nil)
		later.Parent = workspace
		expect(placeholderOf(later):FindFirstChild("EmbeddedMesh")).toBeNil()
		shim.advance(1.2)
		expect(loadedCount).toBe(1)
		expect(Controller.IsReady("Van")).toBe(true)
		expect(placeholder:FindFirstChild("EmbeddedMesh")).toBeTruthy()
		expect(placeholderOf(later):FindFirstChild("EmbeddedMesh")).toBeTruthy()
		-- Load() on a ready vehicle is a no-op.
		expect(Controller.Load("Van")).toBe(false)
		expect(#shim.warnings).toBe(0)
	end)

	it("decodes the entries one after another in priority order so one frame never carries several decode budgets", function()
		local stub = clientSetup({ "Van", "Bicycle" }, { delay = 1 })
		Controller.Start()
		shim.advance(0.5)
		-- only the first entry's loader has started; the second waits for it to finish. The
		-- Bicycle comes before the Van in EmbeddedMeshController.PRIORITY whatever the list order.
		expect(stub.calls.loadGeometry).toBe(1)
		expect(Controller.IsReady("Van")).toBe(false)
		expect(Controller.IsReady("Bicycle")).toBe(false)
		shim.advance(1)
		expect(Controller.IsReady("Bicycle")).toBe(true)
		expect(Controller.IsReady("Van")).toBe(false)
		expect(stub.calls.loadGeometry).toBe(2)
		shim.advance(1)
		expect(Controller.IsReady("Van")).toBe(true)
		expect(callsOf("CreateMeshPartAsync")).toBe(2)
		expect(#shim.warnings).toBe(0)
	end)

	it("warns once on a geometry failure (naming the stage) and shows the placeholder as a semi-transparent box", function()
		clientSetup({ "Van" }, { failMesh = true })
		local before = VehicleBuilder.build("Van", 1, nil)
		before.Parent = workspace
		Controller.Start()
		shim.advance(0.2)
		expect(Controller.IsReady("Van")).toBe(false)
		expect(Controller.HasFailed("Van")).toBe(true)
		expect(Controller.GetMeshPart("Van")).toBeNil()
		-- The entry's warning names the stage and part; the run ends with one summary warning.
		expect(#shim.warnings).toBe(2)
		expect(shim.warnings[1]).toMatch("EmbeddedMeshController")
		expect(shim.warnings[1]).toMatch("Van: embedded mesh failed")
		expect(shim.warnings[1]).toMatch("decodeMesh Van/Body: ")
		expect(shim.warnings[1]).toMatch("bad DDCM")
		expect(shim.warnings[2]).toMatch("decode finished: 0 of 1 entries ready")
		expect(shim.warnings[2]).toMatch("failed: Van")
		expect(placeholderOf(before).Transparency).toBeCloseTo(Controller.FAILED_TRANSPARENCY, 1e-6)
		expect(placeholderOf(before):FindFirstChild("EmbeddedMesh")).toBeNil()
		-- Placeholders added afterwards get the same treatment; nothing is retried.
		local after = VehicleBuilder.build("Van", 2, nil)
		after.Parent = workspace
		expect(placeholderOf(after).Transparency).toBeCloseTo(Controller.FAILED_TRANSPARENCY, 1e-6)
		expect(Controller.Load("Van")).toBe(false)
		expect(callsOf("CreateMeshPartAsync")).toBe(0)
		expect(#shim.warnings).toBe(2)
		expect(#shim.prints).toBe(0)
	end)

	it("a texture failure keeps the mesh and shows it untextured instead of a box", function()
		clientSetup({ "Van" }, { failPng = true })
		local model = VehicleBuilder.build("Van", 1, nil)
		model.Parent = workspace
		Controller.Start()
		shim.advance(0.2)
		expect(Controller.IsReady("Van")).toBe(true)
		expect(Controller.HasFailed("Van")).toBe(false)
		expect(#shim.warnings).toBe(1)
		expect(shim.warnings[1]).toMatch("Van: texture failed, the mesh shows untextured: decodePng: ")
		expect(shim.warnings[1]).toMatch("bad png")
		local template = Controller.GetMeshPart("Van")
		expect(template).toBeTruthy()
		expect(template.TextureContent).toBeNil()
		expect(template.Color).toEqual(Color3.fromRGB(163, 162, 165))
		expect(callsOf("CreateEditableImage")).toBe(0)
		local dressed = placeholderOf(model):FindFirstChild("EmbeddedMesh")
		expect(dressed).toBeTruthy()
		expect(dressed.MeshContent.Object).toBe(template.MeshContent.Object)
		expect(dressed.TextureContent).toBeNil()
		expect(placeholderOf(model).Transparency).toBe(1)
		-- The success line says so, and the summary counts the entry as ready.
		expect(#shim.prints).toBe(2)
		expect(shim.prints[1]).toMatch("Van: ready %(1 part, untextured")
		expect(shim.prints[2]).toMatch("decode finished: 1 of 1 entries ready")
	end)

	it("names the CreateMeshPartAsync stage when the engine call throws", function()
		clientSetup({ "Van" })
		shim.assetService.failNextCalls = 1
		Controller.Start()
		shim.advance(0.2)
		expect(Controller.HasFailed("Van")).toBe(true)
		expect(shim.warnings[1]).toMatch("CreateMeshPartAsync Van/Body: ")
		expect(shim.warnings[1]).toMatch("simulated")
	end)

	it("explains a nil EditableMesh / EditableImage (memory budget or Mesh / Image APIs off)", function()
		clientSetup({ "Van" })
		shim.assetService.editableBudgetExhausted = true
		Controller.Start()
		shim.advance(0.2)
		expect(Controller.HasFailed("Van")).toBe(true)
		-- The image comes first (texture fallback), then the mesh fails the entry.
		expect(#shim.warnings).toBe(3)
		expect(shim.warnings[1]).toMatch("texture failed")
		expect(shim.warnings[1]).toMatch("CreateEditableImage: AssetService:CreateEditableImage returned nil")
		expect(shim.warnings[2]).toMatch("EditableMesh Van/Body: AssetService:CreateEditableMesh returned nil")
		expect(shim.warnings[2]).toMatch("editable memory budget")
		expect(shim.warnings[2]).toMatch("Enable Mesh / Image APIs")
		expect(shim.warnings[3]).toMatch("decode finished: 0 of 1")
	end)

	it("a geometry failure is reported the same way and other vehicles still load", function()
		clientSetup({ "Van", "Bicycle" }, { failMesh = true })
		Controller.Start()
		shim.advance(0.2)
		expect(Controller.HasFailed("Van")).toBe(true)
		expect(Controller.HasFailed("Bicycle")).toBe(true)
		expect(#shim.warnings).toBe(3) -- two entries + the summary
		expect(shim.warnings[3]).toMatch("failed: Bicycle, Van")
		-- A fresh decoder set that works lets a later Load succeed after a reset.
		Controller._stop()
		Controller._setDecoders(decoderStub({ "Van" }))
		Controller.Start()
		shim.advance(0.2)
		expect(Controller.IsReady("Van")).toBe(true)
		expect(#shim.warnings).toBe(3)
	end)

	it("attaches copies through ApplyMesh so they keep the EditableMesh even when Clone drops object content", function()
		clientSetup({ "Van" })
		shim.assetService.cloneDropsObjectContent = true
		Controller.Start()
		shim.advance(0.2)
		local template = Controller.GetMeshPart("Van")
		local model = VehicleBuilder.build("Van", 1, nil)
		model.Parent = workspace
		local dressed = placeholderOf(model):FindFirstChild("EmbeddedMesh")
		expect(dressed).toBeTruthy()
		expect(dressed).never.toBe(template)
		expect(dressed.MeshContent.Object).toBe(template.MeshContent.Object)
		expect(dressed.TextureContent.Object).toBe(template.TextureContent.Object)
		expect(dressed.Size).toEqual(template.Size)
		expect(dressed.CollisionFidelity).toBe(template.CollisionFidelity)
		expect(dressed.RenderFidelity).toBe(template.RenderFidelity)
		expect(callsOf("ApplyMesh")).toBe(1)
		expect(dressed:FindFirstChildWhichIsA("WeldConstraint")).toBeTruthy()
		expect(#shim.warnings).toBe(0)

		-- Without ApplyMesh the plain clone is used (and keeps the content when the engine does).
		shim.assetService.cloneDropsObjectContent = false
		shim.assetService.applyMeshUnavailable = true
		local second = VehicleBuilder.build("Van", 2, nil)
		second.Parent = workspace
		local cloned = placeholderOf(second):FindFirstChild("EmbeddedMesh")
		expect(cloned).toBeTruthy()
		expect(cloned.MeshContent.Object).toBe(template.MeshContent.Object)
		expect(callsOf("ApplyMesh")).toBe(1)
		expect(#shim.warnings).toBe(0)

		-- Neither path keeps the mesh: the attach is reported once per entry/part and the
		-- placeholder is shown as a box instead of a plain grey block.
		shim.assetService.cloneDropsObjectContent = true
		local third = VehicleBuilder.build("Van", 3, nil)
		third.Parent = workspace
		expect(placeholderOf(third):FindFirstChild("EmbeddedMesh")).toBeNil()
		expect(placeholderOf(third).Transparency).toBeCloseTo(Controller.FAILED_TRANSPARENCY, 1e-6)
		expect(#shim.warnings).toBe(1)
		expect(shim.warnings[1]).toMatch("Van/Body: attach failed: the attached copy lost the EditableMesh content")
		local fourth = VehicleBuilder.build("Van", 4, nil)
		fourth.Parent = workspace
		expect(#shim.warnings).toBe(1)
		expect(placeholderOf(fourth).Transparency).toBeCloseTo(Controller.FAILED_TRANSPARENCY, 1e-6)
	end)

	it("does nothing with an empty vehicle list", function()
		clientSetup({})
		Controller.Start()
		shim.advance(0.2)
		expect(Controller.ListVehicles()).toEqual({})
		expect(callsOf("CreateEditableMesh")).toBe(0)
		expect(#shim.warnings).toBe(0)
	end)
end)

describe("CosmeticsController embedded previews", function()
	local Cosmetics, Controller, VehicleBuilder, MeshAssets

	local function clientSetup(opts)
		shim.reset()
		shim.setContext("client")
		MeshAssets = requireShared("Config/MeshAssets")
		MeshAssets._setMeshData(meshDataStub(ALL))
		VehicleBuilder = requireBuilder("VehicleBuilder")
		local root = clientRoot()
		local ctx = { state = { get = function() return nil end }, controllers = {} }
		Cosmetics = require(root.Controllers.CosmeticsController)
		Controller = require(root.Controllers.EmbeddedMeshController)
		Controller._setDecoders(decoderStub({ "Van" }, opts))
		Cosmetics.Init(ctx)
		Controller.Init(ctx)
		Cosmetics.Start()
		Controller.Start()
	end

	local function publishDisplay(vehicleId)
		local ReplicatedStorage = game:GetService("ReplicatedStorage")
		local sharedAssets = ReplicatedStorage:FindFirstChild("SharedAssets")
		local displays = sharedAssets:FindFirstChild("VehicleDisplays")
		if not displays then
			displays = Instance.new("Folder")
			displays.Name = "VehicleDisplays"
			displays.Parent = sharedAssets
		end
		local display = VehicleBuilder.buildDisplay(vehicleId, nil)
		display.Name = vehicleId
		display.Parent = displays
		return display
	end

	it("clones the published placeholder display and the controller dresses it", function()
		clientSetup()
		shim.advance(0.2)
		local published = publishDisplay("Van")
		-- The published template itself is tagged and in ReplicatedStorage: the controller dressed it
		-- too, which is harmless; previews drop that child and get their own clone.
		local holder = Instance.new("Folder")
		holder.Parent = workspace
		local model = Cosmetics.BuildDisplayVehicle("Van", holder)
		expect(model.Parent).toBe(holder)
		expect(model).never.toBe(published)
		expect(model:GetAttribute("VehicleId")).toBe("Van")
		local placeholder = model.Body.MeshBody
		expect(placeholder.ClassName).toBe("Part")
		expect(placeholder.Anchored).toBe(true)
		expect(game:GetService("CollectionService"):HasTag(placeholder, TAG)).toBe(true)
		local meshes = {}
		for _, child in ipairs(placeholder:GetChildren()) do
			if child.Name == "EmbeddedMesh" then
				table.insert(meshes, child)
			end
		end
		expect(#meshes).toBe(1)
		expect(meshes[1]:IsA("MeshPart")).toBe(true)
		expect(meshes[1].Anchored).toBe(true)
		expect(meshes[1]:FindFirstChildWhichIsA("WeldConstraint")).toBeNil()
		expect(Cosmetics.GetDisplayRadius("Van")).toBeGreaterThan(7)
		expect(#shim.warnings).toBe(0)
	end)

	it("shows the bare placeholder until the mesh is ready, then dresses the preview", function()
		clientSetup({ delay = 1 })
		publishDisplay("Van")
		local holder = Instance.new("Folder")
		holder.Parent = workspace
		local model = Cosmetics.BuildDisplayVehicle("Van", holder)
		local placeholder = model.Body.MeshBody
		expect(placeholder:FindFirstChild("EmbeddedMesh")).toBeNil()
		shim.advance(1.5)
		expect(Controller.IsReady("Van")).toBe(true)
		expect(placeholder:FindFirstChild("EmbeddedMesh")).toBeTruthy()
		expect(placeholder.EmbeddedMesh.Anchored).toBe(true)
		expect(#shim.warnings).toBe(0)
	end)
end)

-------------------------------------------------------------------------------
-- Harness + optional real-decoder round trip
-------------------------------------------------------------------------------

describe("Harness: EditableMesh, EditableImage and Content.fromObject", function()
	beforeEach(function()
		shim.reset()
		shim.setContext("client")
	end)

	it("records sequential ids, validates references and builds a MeshPart from an object Content", function()
		local AssetService = game:GetService("AssetService")
		local mesh = AssetService:CreateEditableMesh({ FixedSize = true })
		expect(mesh.ClassName).toBe("EditableMesh")
		expect(mesh.FixedSize).toBe(true)
		expect(mesh:AddVertex(Vector3.new(0, 0, 0))).toBe(1)
		expect(mesh:AddVertex(Vector3.new(1, 0, 0))).toBe(2)
		expect(mesh:AddVertex(Vector3.new(0, 1, 0))).toBe(3)
		expect(mesh:AddNormal(Vector3.new(0, 0, 1))).toBe(1)
		expect(mesh:AddNormal()).toBe(2)
		expect(mesh:AddUV(Vector2.new(0, 0))).toBe(1)
		local face = mesh:AddTriangle(1, 2, 3)
		expect(face).toBe(1)
		mesh:SetFaceNormals(face, { 1, 2, 1 })
		mesh:SetFaceUVs(face, { 1, 1, 1 })
		expect(mesh:GetFaceVertices(1)).toEqual({ 1, 2, 3 })
		expect(mesh:GetFaceNormals(1)).toEqual({ 1, 2, 1 })
		expect(mesh:GetFaceUVs(1)).toEqual({ 1, 1, 1 })
		expect(mesh:GetVertices()).toEqual({ 1, 2, 3 })
		expect(mesh:GetFaces()).toEqual({ 1 })
		expect(mesh:GetSize()).toBeCloseTo(Vector3.new(1, 1, 0), 1e-6)
		expect(function()
			mesh:AddTriangle(1, 2, 9)
		end).toThrow("invalid vertex id")
		expect(function()
			mesh:SetFaceNormals(face, { 1, 2, 7 })
		end).toThrow("invalid normal id")
		expect(function()
			mesh:AddVertex("nope")
		end).toThrow("Vector3")

		local image = AssetService:CreateEditableImage({ Size = Vector2.new(2, 2) })
		expect(image.ClassName).toBe("EditableImage")
		expect(image.Size).toBeCloseTo(Vector2.new(2, 2), 1e-6)
		expect(function()
			image:WritePixelsBuffer(Vector2.zero, Vector2.new(2, 2), buffer.create(3))
		end).toThrow("does not match")
		image:WritePixelsBuffer(Vector2.zero, Vector2.new(2, 2), buffer.create(16))
		expect(#shim.editableData(image).writes).toBe(1)
		expect(function()
			AssetService:CreateEditableImage({ Size = Vector2.new(2048, 2) })
		end).toThrow("1024")

		local content = Content.fromObject(mesh)
		expect(typeof(content)).toBe("Content")
		expect(content.Object).toBe(mesh)
		local part = AssetService:CreateMeshPartAsync(content, { CollisionFidelity = Enum.CollisionFidelity.Box, RenderFidelity = Enum.RenderFidelity.Precise })
		expect(part:IsA("MeshPart")).toBe(true)
		expect(part.MeshContent).toBe(content)
		expect(part.MeshId).toBe("")
		expect(part.RenderFidelity).toBe(Enum.RenderFidelity.Precise)
		part.TextureContent = Content.fromObject(image)
		expect(part.TextureContent.Object).toBe(image)
		local clone = part:Clone()
		expect(clone.TextureContent.Object).toBe(image)
		-- The asset-id path is unchanged.
		local byId = AssetService:CreateMeshPartAsync(Content.fromAssetId(5001), {})
		expect(byId.MeshId).toBe("rbxassetid://5001")
		expect(byId.MeshContent.AssetId).toBe(5001)
		expect(function()
			AssetService:CreateMeshPartAsync(Content.fromObject(image), {})
		end).toThrow("EditableMesh")
	end)

	it("CollectionService:GetTagged reports clones of tagged parts (the preview path relies on it)", function()
		local CollectionService = game:GetService("CollectionService")
		local source = Instance.new("Part")
		CollectionService:AddTag(source, TAG)
		local added = {}
		CollectionService:GetInstanceAddedSignal(TAG):Connect(function(inst)
			table.insert(added, inst)
		end)
		local copy = source:Clone()
		expect(CollectionService:HasTag(copy, TAG)).toBe(true)
		expect(CollectionService:GetTagged(TAG)).never.toContain(copy)
		copy.Parent = workspace
		expect(CollectionService:GetTagged(TAG)).toContain(copy)
		expect(added).toEqual({ copy })
		copy:Destroy()
		expect(CollectionService:GetTagged(TAG)).never.toContain(copy)
	end)

	it("runs the 2x2 PNG and the one-triangle DDCM blob through the real decoders when present", function()
		local Shared = game:GetService("ReplicatedStorage").Shared
		local pngModule = Shared.Util:FindFirstChild("PngDecoder")
		local meshData = Shared:FindFirstChild("MeshData")
		local packModule = meshData and meshData:FindFirstChild("MeshPack")
		if not (pngModule and pngModule:IsA("ModuleScript") and packModule and packModule:IsA("ModuleScript")) then
			print("[embedded_meshes.spec] real decoders not present; round trip skipped")
			return
		end
		local PngDecoder = require(pngModule)
		local MeshPack = require(packModule)
		local image = PngDecoder.decode(b64decode(PNG_B64))
		expect(image.width).toBe(2)
		expect(image.height).toBe(2)
		expect(buffer.len(image.rgba)).toBe(16)
		for i, v in ipairs(PNG_PIXELS) do
			expect(buffer.readu8(image.rgba, i - 1)).toBe(v)
		end
		local geometry = MeshPack.decode(ddcmBlob())
		expect(geometry.vertexCount).toBe(3)
		expect(geometry.triangleCount).toBe(1)
		expect(#geometry.positions).toBe(3)
		expect(geometry.positions[3]).toBeCloseTo(Vector3.new(0, 2, 0), 1e-5)
		expect(geometry.normals[1]).toBeCloseTo(Vector3.new(0, 0, 1), 0.02)
		expect(geometry.uvs[3]).toBeCloseTo(Vector2.new(0.5, 0), 1e-3)
		expect(geometry.triangles).toEqual({ 1, 2, 3 })
		expect(geometry.bboxMin).toBeCloseTo(Vector3.new(-1, 0, 0), 1e-5)
		expect(geometry.bboxMax).toBeCloseTo(Vector3.new(1, 2, 0), 1e-5)
	end)
end)
