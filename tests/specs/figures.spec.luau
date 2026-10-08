--!nonstrict
-- Embedded people and the courier vest: Shared.Util.FigureRig (placeholder rig, hip Motor6D
-- maths, idForKind, place / walk / idle), NPCBuilder on rigs (and its generated fallback),
-- CityLifeController pedestrian rigs, the EffectsController door customer, ShopService.ApplyUniform
-- with the embedded vest placeholder and the multi-part EmbeddedMeshController (textured figure
-- parts, the untextured MeshColor-tinted vest, dressing of a client-built rig, priority order).
--
-- MeshData is replaced by a tiny stand-in (FigureRig._setMeshData) with a synthetic figure index
-- so the maths can be checked by hand; where the real data modules are present one test also
-- builds a rig from the real NPCStaff index.

local function requireShared(path)
	return shim.requirePath("ReplicatedStorage/Shared/" .. path)
end

local function requireBuilder(name)
	return shim.requirePath("ServerScriptService/DeliveryDash/Builders/" .. name)
end

local function requireService(name)
	return shim.requirePath("ServerScriptService/DeliveryDash/Services/" .. name)
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

local TAG = "EmbeddedMeshBody"
local ROOT_HEIGHT = 3

-------------------------------------------------------------------------------
-- Synthetic MeshData (version-2 indexes)
-------------------------------------------------------------------------------

local FIGURE = {
	bboxMin = { -1.6, 0, -0.75 },
	bboxMax = { 1.6, 5.2, 0.75 },
	parts = {
		{ name = "Body", bboxMin = { -1.6, 1.7, -0.55 }, bboxMax = { 1.6, 5.2, 0.75 } },
		{ name = "LegL", bboxMin = { -1.6, 0, -0.75 }, bboxMax = { 0.1, 2.3, 0.7 }, pivot = { -0.8, 2.4, -0.02 } },
		{ name = "LegR", bboxMin = { -0.3, 0, -0.75 }, bboxMax = { 1.6, 2.35, 0.7 }, pivot = { 0.7, 2.4, -0.01 } },
	},
}

local function figureIndex(id)
	local parts = {}
	for i, p in ipairs(FIGURE.parts) do
		parts[i] = {
			name = p.name,
			chunks = { p.name .. "_G1" },
			bytes = 0,
			vertexCount = 3,
			triangleCount = 1,
			bboxMin = table.clone(p.bboxMin),
			bboxMax = table.clone(p.bboxMax),
			pivot = p.pivot and table.clone(p.pivot) or nil,
		}
	end
	return {
		id = id,
		version = 2,
		kind = "figure",
		texture = { chunks = 1, bytes = 0, width = 2, height = 2, format = "png" },
		bboxMin = table.clone(FIGURE.bboxMin),
		bboxMax = table.clone(FIGURE.bboxMax),
		parts = parts,
	}
end

local function vestIndex()
	return {
		id = "CourierVest",
		version = 2,
		kind = "accessory",
		texture = nil,
		bboxMin = { -1.15, -0.95, -0.65 },
		bboxMax = { 1.15, 0.95, 0.65 },
		parts = { { name = "Body", chunks = { "Body_G1" }, bytes = 0, vertexCount = 3, triangleCount = 1, bboxMin = { -1.15, -0.95, -0.65 }, bboxMax = { 1.15, 0.95, 0.65 } } },
	}
end

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

local ALL_FIGURES = { "NPCStaff", "NPCWorker", "NPCDriver", "NPCCustomerA", "NPCCustomerB", "NPCPedestrianA", "NPCPedestrianB", "NPCPedestrianC" }

local function indexFor(id)
	if id == "CourierVest" then
		return vestIndex()
	elseif id == "Bicycle" or id == "Scooter" or id == "Van" then
		return vehicleIndex(id)
	end
	return figureIndex(id)
end

-- MeshData stand-in over the given ids (figures, CourierVest and vehicles by name).
local function meshDataStub(ids)
	local set = {}
	for _, id in ipairs(ids) do
		set[id] = true
	end
	return {
		list = function()
			local out = table.clone(ids)
			table.sort(out)
			return out
		end,
		has = function(id)
			return set[id] == true
		end,
		index = function(id)
			assert(set[id], "no data for " .. tostring(id))
			return indexFor(id)
		end,
		kind = function(id)
			assert(set[id], "no data for " .. tostring(id))
			return indexFor(id).kind
		end,
	}
end

local NONE = { has = function() return false end }

local function withStub(ids)
	local FigureRig = requireShared("Util/FigureRig")
	FigureRig._setMeshData(meshDataStub(ids))
	return FigureRig
end

-------------------------------------------------------------------------------
-- Decoder vectors for the controller (one triangle, 2x2 PNG)
-------------------------------------------------------------------------------

local PNG_PIXELS = { 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 128 }

local function decodedGeometry()
	return {
		vertexCount = 3,
		triangleCount = 1,
		bboxMin = Vector3.new(-1, 0, 0),
		bboxMax = Vector3.new(1, 2, 0),
		positions = { Vector3.new(-1, 0, 0), Vector3.new(1, 0, 0), Vector3.new(0, 2, 0) },
		normals = { Vector3.new(0, 0, 1), Vector3.new(0, 0, 1), Vector3.new(0, 0, 1) },
		uvs = { Vector2.new(0, 1), Vector2.new(1, 1), Vector2.new(0.5, 0) },
		triangles = { 1, 2, 3 },
	}
end

local function decodedImage()
	local rgba = buffer.create(16)
	for i, v in ipairs(PNG_PIXELS) do
		buffer.writeu8(rgba, i - 1, v)
	end
	return { width = 2, height = 2, rgba = rgba }
end

-- Decoder set for EmbeddedMeshController._setDecoders; opts = { delay = s, failPart = name }
local function decoderStub(ids, opts)
	opts = opts or {}
	local stub = { calls = { loadPart = {}, loadTexture = 0, decodePng = 0, decodeMesh = 0 }, order = {} }
	stub.list = function()
		return table.clone(ids)
	end
	stub.index = function(id)
		return indexFor(id)
	end
	stub.loadPart = function(id, partName, options)
		table.insert(stub.calls.loadPart, id .. "/" .. partName)
		table.insert(stub.order, id)
		if opts.delay then
			task.wait(opts.delay)
		end
		if options and type(options.onProgress) == "function" then
			options.onProgress(8, 8)
		end
		if opts.failPart == partName then
			error("bad part blob (simulated)")
		end
		return buffer.fromstring(partName .. "-blob")
	end
	stub.loadTexture = function(id, options)
		stub.calls.loadTexture += 1
		if options and type(options.onProgress) == "function" then
			options.onProgress(4, 4)
		end
		return buffer.create(4)
	end
	stub.decodePng = function(png, options)
		stub.calls.decodePng += 1
		if options and type(options.onProgress) == "function" then
			options.onProgress(1)
		end
		return decodedImage()
	end
	stub.decodeMesh = function(blob)
		stub.calls.decodeMesh += 1
		expect(buffer.len(blob)).toBeGreaterThan(0)
		return decodedGeometry()
	end
	return stub
end

local function childrenNamed(parent, name)
	local out = {}
	for _, child in ipairs(parent:GetChildren()) do
		if child.Name == name then
			table.insert(out, child)
		end
	end
	return out
end

-------------------------------------------------------------------------------
-- FigureRig
-------------------------------------------------------------------------------

describe("FigureRig", function()
	local FigureRig, CollectionService

	beforeEach(function()
		shim.reset()
		shim.setContext("server")
		CollectionService = game:GetService("CollectionService")
		FigureRig = withStub({ "NPCStaff", "NPCCustomerA", "CourierVest" })
	end)

	it("reports figures only (never throws) and maps NPC kinds to figure ids", function()
		expect(FigureRig.ROOT_HEIGHT).toBe(3)
		expect(FigureRig.has("NPCStaff")).toBe(true)
		expect(FigureRig.has("CourierVest")).toBe(false) -- an accessory, not a figure
		expect(FigureRig.hasEntry("CourierVest")).toBe(true)
		expect(FigureRig.hasEntry("CourierVest", "accessory")).toBe(true)
		expect(FigureRig.has("NPCWorker")).toBe(false)
		expect(FigureRig.has("")).toBe(false)
		expect(FigureRig.has(nil)).toBe(false)
		FigureRig._setMeshData({ has = function() error("boom") end })
		expect(FigureRig.has("NPCStaff")).toBe(false)
		FigureRig._setMeshData(NONE)
		expect(FigureRig.has("NPCStaff")).toBe(false)

		expect(FigureRig.idForKind("Staff", 0)).toBe("NPCStaff")
		expect(FigureRig.idForKind("Staff", 17)).toBe("NPCStaff")
		expect(FigureRig.idForKind("Worker", 3)).toBe("NPCWorker")
		expect(FigureRig.idForKind("Driver", 101)).toBe("NPCDriver")
		expect(FigureRig.idForKind("Customer", 0)).toBe("NPCCustomerA")
		expect(FigureRig.idForKind("Customer", 1)).toBe("NPCCustomerB")
		expect(FigureRig.idForKind("Customer", 6)).toBe("NPCCustomerA")
		expect(FigureRig.idForKind("Pedestrian", 0)).toBe("NPCPedestrianA")
		expect(FigureRig.idForKind("Pedestrian", 1)).toBe("NPCPedestrianB")
		expect(FigureRig.idForKind("Pedestrian", 2)).toBe("NPCPedestrianC")
		expect(FigureRig.idForKind("Pedestrian", 5)).toBe("NPCPedestrianC")
		expect(FigureRig.idForKind("Pedestrian", nil)).toBe("NPCPedestrianA")
		expect(FigureRig.idForKind("Pedestrian", -4)).toBe("NPCPedestrianB")
		expect(FigureRig.idForKind("Nope", 1)).toBe("NPCPedestrianB")
	end)

	it("builds Root + one tagged placeholder per index part with the bbox sizes and attributes", function()
		local model = FigureRig.build("NPCStaff", { name = "Staff", collisionGroup = "NPCs" })
		expect(model.Name).toBe("Staff")
		expect(model.Parent).toBeNil()
		expect(model:GetAttribute("FigureId")).toBe("NPCStaff")
		local root = model.PrimaryPart
		expect(root).toBeTruthy()
		expect(root.Name).toBe("Root")
		expect(root.Size).toBeCloseTo(Vector3.new(2, 2, 1), 1e-6)
		expect(root.Transparency).toBe(1)
		expect(root.Anchored).toBe(true)
		expect(root.CanCollide).toBe(false)
		expect(root.CFrame).toBeCloseTo(CFrame.new(0, ROOT_HEIGHT, 0), 1e-6)
		expect(root.CollisionGroup).toBe("NPCs")
		expect(CollectionService:HasTag(root, TAG)).toBe(false)

		for _, entry in ipairs(FIGURE.parts) do
			local part = model:FindFirstChild(entry.name)
			expect(part).toBeTruthy()
			expect(part.ClassName).toBe("Part")
			expect(part.Transparency).toBe(1)
			expect(part.Size).toBeCloseTo(vecOf(entry.bboxMax) - vecOf(entry.bboxMin), 1e-6)
			expect(part.Massless).toBe(true)
			expect(part.CanCollide).toBe(false)
			expect(part.CanQuery).toBe(false)
			expect(part.CanTouch).toBe(false)
			expect(part.Anchored).toBe(false)
			expect(part.CollisionGroup).toBe("NPCs")
			expect(part:GetAttribute("EmbeddedMesh")).toBe("NPCStaff")
			expect(part:GetAttribute("EmbeddedPart")).toBe(entry.name)
			expect(CollectionService:HasTag(part, TAG)).toBe(true)
			-- At rest every placeholder sits on its index bbox centre (feet at the origin).
			local centre = (vecOf(entry.bboxMin) + vecOf(entry.bboxMax)) / 2
			expect(part.Position).toBeCloseTo(centre, 1e-5)
		end
		-- Body is welded to the Root; the legs hang off hip Motor6Ds.
		local bodyWeld = model.Body:FindFirstChildWhichIsA("WeldConstraint")
		expect(bodyWeld).toBeTruthy()
		expect(bodyWeld.Part0).toBe(root)
		expect(bodyWeld.Part1).toBe(model.Body)
		expect(model.Body:FindFirstChildWhichIsA("Motor6D")).toBeNil()
		expect(model.LegL:FindFirstChild("LeftHip").ClassName).toBe("Motor6D")
		expect(model.LegR:FindFirstChild("RightHip").ClassName).toBe("Motor6D")
		-- Tagged placeholders are visible to CollectionService once parented.
		model.Parent = workspace
		local tagged = CollectionService:GetTagged(TAG)
		expect(tagged).toContain(model.Body)
		expect(tagged).toContain(model.LegL)
		expect(tagged).toContain(model.LegR)
		-- Options: an unanchored root.
		local loose = FigureRig.build("NPCStaff", { anchored = false })
		expect(loose.Name).toBe("NPCStaff")
		expect(loose.PrimaryPart.Anchored).toBe(false)
		expect(#shim.warnings).toBe(0)
	end)

	it("hip Motor6Ds use C0 = pivot - rootCentre and C1 = pivot - bboxCentre and swing about the hip", function()
		local model = FigureRig.build("NPCStaff")
		local root = model.PrimaryPart
		local rootCentre = Vector3.new(0, ROOT_HEIGHT, 0)
		for _, spec in ipairs({ { part = "LegL", motor = "LeftHip" }, { part = "LegR", motor = "RightHip" } }) do
			local entry
			for _, e in ipairs(FIGURE.parts) do
				if e.name == spec.part then
					entry = e
				end
			end
			local pivot = vecOf(entry.pivot)
			local bboxCentre = (vecOf(entry.bboxMin) + vecOf(entry.bboxMax)) / 2
			local leg = model[spec.part]
			local motor = leg[spec.motor]
			expect(motor.Part0).toBe(root)
			expect(motor.Part1).toBe(leg)
			expect(motor.C0).toBeCloseTo(CFrame.new(pivot - rootCentre), 1e-6)
			expect(motor.C1).toBeCloseTo(CFrame.new(pivot - bboxCentre), 1e-6)
			expect(motor.Transform).toBeCloseTo(CFrame.identity, 1e-6)
			-- Identity transform: Part0 * C0 * Transform * C1^-1 is the placeholder's rest CFrame, whose
			-- position is the index bbox centre relative to the feet.
			local rest = root.CFrame * motor.C0 * motor.Transform * motor.C1:Inverse()
			expect(rest).toBeCloseTo(leg.CFrame, 1e-6)
			expect(rest.Position).toBeCloseTo(bboxCentre, 1e-6)
			-- The joint point of that chain is the hip pivot.
			expect((root.CFrame * motor.C0).Position).toBeCloseTo(pivot, 1e-6)
			-- A 0.5 rad swing rotates the leg about the hip: the hip point stays put, the leg centre
			-- keeps its distance from it and moves forward/up by the expected rotation.
			local swing = CFrame.Angles(0.5, 0, 0)
			local swung = root.CFrame * motor.C0 * swing * motor.C1:Inverse()
			local hipAfter = (swung * motor.C1).Position
			expect(hipAfter).toBeCloseTo(pivot, 1e-6)
			local offset = bboxCentre - pivot
			expect((swung.Position - pivot).Magnitude).toBeCloseTo(offset.Magnitude, 1e-6)
			expect(swung.Position).toBeCloseTo(pivot + swing:VectorToWorldSpace(offset), 1e-6)
			expect(swung.Position).never.toBeCloseTo(bboxCentre, 1e-3)
			-- The leg's own axes rotate with it.
			expect(swung.LookVector).toBeCloseTo((CFrame.new(rootCentre) * swing).LookVector, 1e-6)
		end
	end)

	it("setWalkPose swings the hips in opposite phase and setIdlePose resets them", function()
		local model = FigureRig.build("NPCCustomerA")
		local left, right = model.LegL.LeftHip, model.LegR.RightHip
		FigureRig.setWalkPose(model, math.pi / 2)
		expect(left.Transform).toBeCloseTo(CFrame.Angles(0.55, 0, 0), 1e-6)
		expect(right.Transform).toBeCloseTo(CFrame.Angles(-0.55, 0, 0), 1e-6)
		FigureRig.setWalkPose(model, -math.pi / 2, 0.3)
		expect(left.Transform).toBeCloseTo(CFrame.Angles(-0.3, 0, 0), 1e-6)
		expect(right.Transform).toBeCloseTo(CFrame.Angles(0.3, 0, 0), 1e-6)
		FigureRig.setIdlePose(model)
		expect(left.Transform).toBeCloseTo(CFrame.identity, 1e-6)
		expect(right.Transform).toBeCloseTo(CFrame.identity, 1e-6)
		-- A model without legs (vest-like) is a no-op, no error.
		local bare = Instance.new("Model")
		FigureRig.setWalkPose(bare, 1)
		FigureRig.setIdlePose(bare)
	end)

	it("place puts the feet on the position facing the flat direction", function()
		local model = FigureRig.build("NPCStaff")
		FigureRig.place(model, Vector3.new(10, 2, -5), Vector3.new(1, 0.7, 0))
		local root = model.PrimaryPart
		expect(root.Position).toBeCloseTo(Vector3.new(10, 2 + ROOT_HEIGHT, -5), 1e-5)
		expect(root.CFrame.LookVector).toBeCloseTo(Vector3.new(1, 0, 0), 1e-5)
		-- The whole rig moved with the root: the body keeps its offset from the root and the leg
		-- soles are on the ground.
		local body = model.Body
		local bodyCentre = (vecOf(FIGURE.parts[1].bboxMin) + vecOf(FIGURE.parts[1].bboxMax)) / 2
		expect(root.CFrame:PointToObjectSpace(body.Position)).toBeCloseTo(bodyCentre - Vector3.new(0, ROOT_HEIGHT, 0), 1e-5)
		expect(model.LegL.Position.Y - model.LegL.Size.Y / 2).toBeCloseTo(2, 1e-5)
		-- Facing defaults to -Z and a zero vector is ignored.
		FigureRig.place(model, Vector3.new(0, 0, 0), Vector3.new(0, 1, 0))
		expect(root.CFrame.LookVector).toBeCloseTo(Vector3.new(0, 0, -1), 1e-5)
		FigureRig.place(model, Vector3.new(1, 0, 1))
		expect(root.CFrame.LookVector).toBeCloseTo(Vector3.new(0, 0, -1), 1e-5)
		expect(root.Position).toBeCloseTo(Vector3.new(1, ROOT_HEIGHT, 1), 1e-5)
	end)

	it("build errors clearly without data", function()
		expect(function()
			FigureRig.build("NPCWorker")
		end).toThrow("NPCWorker")
		FigureRig._setMeshData(NONE)
		expect(function()
			FigureRig.build("NPCStaff")
		end).toThrow()
	end)

	it("builds a rig from the real NPCStaff index when the data modules are present", function()
		FigureRig._setMeshData(nil)
		local MeshData = FigureRig.getMeshData()
		if not (MeshData and MeshData.has("NPCStaff") and MeshData.VERSION == 2) then
			print("[figures.spec] real MeshData v2 not present; real-index rig skipped")
			return
		end
		expect(FigureRig.has("NPCStaff")).toBe(true)
		expect(FigureRig.has("CourierVest")).toBe(false)
		expect(FigureRig.hasEntry("CourierVest", "accessory")).toBe(true)
		local index = MeshData.index("NPCStaff")
		local model = FigureRig.build("NPCStaff")
		local names = {}
		for _, child in ipairs(model:GetChildren()) do
			if child:IsA("BasePart") then
				table.insert(names, child.Name)
			end
		end
		table.sort(names)
		expect(names).toEqual({ "Body", "LegL", "LegR", "Root" })
		for _, entry in ipairs(index.parts) do
			local part = model[entry.name]
			expect(part.Size).toBeCloseTo(vecOf(entry.bboxMax) - vecOf(entry.bboxMin), 1e-4)
			expect(part.Position).toBeCloseTo((vecOf(entry.bboxMin) + vecOf(entry.bboxMax)) / 2, 1e-4)
			if entry.pivot then
				local motor = part:FindFirstChildWhichIsA("Motor6D")
				expect(motor).toBeTruthy()
				expect(motor.C0.Position).toBeCloseTo(vecOf(entry.pivot) - Vector3.new(0, ROOT_HEIGHT, 0), 1e-4)
			end
		end
		-- The figure stands on the ground 5.2 studs tall with its left leg on -x.
		expect(model.LegL.Position.Y - model.LegL.Size.Y / 2).toBeCloseTo(0, 1e-3)
		expect(model.Body.Position.Y + model.Body.Size.Y / 2).toBeCloseTo(5.2, 1e-3)
		expect(model.LegL.Position.X).toBeLessThan(model.LegR.Position.X)
	end)
end)

-------------------------------------------------------------------------------
-- NPCBuilder on rigs
-------------------------------------------------------------------------------

describe("NPCBuilder with embedded figures", function()
	local NPCBuilder, FigureRig, CollectionService

	beforeEach(function()
		shim.reset()
		shim.setContext("server")
		CollectionService = game:GetService("CollectionService")
		FigureRig = withStub({ "NPCStaff", "NPCWorker", "NPCDriver", "NPCCustomerA", "NPCCustomerB" })
		NPCBuilder = requireBuilder("NPCBuilder")
	end)

	it("builds rigs for Staff / Worker / Driver / Customer with the NPC attributes, tag and name tag", function()
		for _, kind in ipairs({ "Staff", "Worker", "Driver", "Customer" }) do
			local model = NPCBuilder.build(kind, 7, { name = "Ava" })
			expect(NPCBuilder.isRig(model)).toBe(true)
			expect(model.Name).toBe(kind)
			expect(model:GetAttribute("NPCKind")).toBe(kind)
			expect(model:GetAttribute("Seed")).toBe(7)
			expect(model:GetAttribute("FigureId")).toBe(FigureRig.idForKind(kind, 7))
			expect(CollectionService:HasTag(model, "CityNPC")).toBe(true)
			expect(model.PrimaryPart.Name).toBe("Root")
			expect(model.PrimaryPart.Anchored).toBe(false)
			expect(model:FindFirstChild("Torso")).toBeNil()
			expect(model:FindFirstChild("Head")).toBeNil()
			for _, partName in ipairs({ "Body", "LegL", "LegR" }) do
				local part = model[partName]
				expect(part.CollisionGroup).toBe("NPCs")
				expect(part.Anchored).toBe(false)
				expect(part:GetAttribute("EmbeddedPart")).toBe(partName)
				expect(CollectionService:HasTag(part, TAG)).toBe(true)
			end
			local tag = model.Body:FindFirstChild("NameTag")
			expect(tag).toBeTruthy()
			expect(tag.Label.Text).toBe("Ava")
			-- The label floats above the head (body top + clearance).
			expect(model.Body.Position.Y + tag.StudsOffset.Y).toBeGreaterThan(5.2)
		end
		expect(NPCBuilder.build("Customer", 1, nil):GetAttribute("FigureId")).toBe("NPCCustomerB")
		expect(NPCBuilder.build("Worker", 2, nil).Body:FindFirstChild("NameTag")).toBeNil()
		expect(#shim.warnings).toBe(0)
	end)

	it("falls back to the generated figure when the kind has no embedded data", function()
		-- Pedestrians are not in the stub: generated figure.
		local pedestrian = NPCBuilder.build("Pedestrian", 3, nil)
		expect(NPCBuilder.isRig(pedestrian)).toBe(false)
		expect(pedestrian:FindFirstChild("Torso")).toBeTruthy()
		expect(pedestrian:FindFirstChild("LegL")).toBeNil()
		expect(NPCBuilder.figureIdFor("Pedestrian", 3)).toBeNil()
		expect(NPCBuilder.figureIdFor("Staff", 3)).toBe("NPCStaff")
		-- Without any data every kind is generated.
		FigureRig._setMeshData(NONE)
		local staff = NPCBuilder.build("Staff", 1, { name = "Priya" })
		expect(NPCBuilder.isRig(staff)).toBe(false)
		expect(staff.Head.NameTag.Label.Text).toBe("Priya")
		NPCBuilder.setWalkPose(staff, 1)
		expect(staff.LeftLeg.LeftHip.Transform).never.toBeCloseTo(CFrame.identity, 1e-6)
	end)

	it("place / freeze / setWalkPose / setIdlePose delegate to FigureRig for rigs", function()
		local staff = NPCBuilder.build("Staff", 1, nil)
		NPCBuilder.place(staff, Vector3.new(10, 2, 10), Vector3.new(1, 0, 0), true)
		expect(staff.PrimaryPart.Anchored).toBe(true)
		expect(staff.PrimaryPart.Position).toBeCloseTo(Vector3.new(10, 5, 10), 1e-4)
		expect(staff.PrimaryPart.CFrame.LookVector.X).toBeCloseTo(1, 1e-4)
		expect(staff.LegL.Position.Y - staff.LegL.Size.Y / 2).toBeCloseTo(2, 1e-4)
		-- Only the root is anchored by place; freeze anchors every placeholder (static server NPC).
		expect(staff.Body.Anchored).toBe(false)
		NPCBuilder.freeze(staff)
		for _, d in ipairs(staff:GetDescendants()) do
			if d:IsA("BasePart") then
				expect(d.Anchored).toBe(true)
			end
		end
		NPCBuilder.setWalkPose(staff, math.pi / 2)
		expect(staff.LegL.LeftHip.Transform).toBeCloseTo(CFrame.Angles(0.55, 0, 0), 1e-6)
		expect(staff.LegR.RightHip.Transform).toBeCloseTo(CFrame.Angles(-0.55, 0, 0), 1e-6)
		NPCBuilder.setIdlePose(staff)
		expect(staff.LegL.LeftHip.Transform).toBeCloseTo(CFrame.identity, 1e-6)
		-- place without anchoring keeps the root loose.
		local loose = NPCBuilder.build("Driver", 2, nil)
		NPCBuilder.place(loose, Vector3.new(0, 0, 0), nil, false)
		expect(loose.PrimaryPart.Anchored).toBe(false)
	end)

	it("CityBuilder staff and DepotBuilder drivers are frozen rigs with their name tags", function()
		local ReplicatedStorage = game:GetService("ReplicatedStorage")
		local CityBuilder = requireBuilder("CityBuilder")
		local layoutModule = ReplicatedStorage.Shared:FindFirstChild("City") and ReplicatedStorage.Shared.City:FindFirstChild("CityLayout")
		if not layoutModule then
			print("[figures.spec] CityLayout missing; CityBuilder staff check skipped")
			return
		end
		local layout = require(layoutModule)
		local folders = {
			city = Instance.new("Folder"),
			pickup = Instance.new("Folder"),
			destinations = Instance.new("Folder"),
			depots = Instance.new("Folder"),
		}
		for _, folder in pairs(folders) do
			folder.Parent = workspace
		end
		local ok, err = pcall(CityBuilder.build, layout, folders)
		expect(ok).toBe(true, tostring(err))
		local checked = 0
		for _, business in ipairs(folders.pickup:GetChildren()) do
			local staff = business:FindFirstChild("Staff")
			if staff then
				checked += 1
				expect(staff:GetAttribute("FigureId")).toBe("NPCStaff")
				expect(staff:FindFirstChild("LegL")).toBeTruthy()
				expect(staff.Body:FindFirstChild("NameTag")).toBeTruthy()
				for _, d in ipairs(staff:GetDescendants()) do
					if d:IsA("BasePart") then
						expect(d.Anchored).toBe(true)
					end
				end
			end
		end
		expect(checked).toBeGreaterThan(0)
	end)
end)

-------------------------------------------------------------------------------
-- Client: CityLife pedestrians, door customer
-------------------------------------------------------------------------------

local LAYOUT = {
	name = "FigureTestCity",
	bounds = { minX = -400, maxX = 400, minZ = -400, maxZ = 400 },
	groundY = 0,
	killY = -60,
	neighborhoods = {},
	roads = {},
	water = {},
	bridges = {},
	buildings = {},
	businesses = {},
	destinations = {
		{ id = "D_Near", address = "1 Main Street", neighborhood = "Downtown", kind = "Apartment", door = { x = 120, z = -12 }, facing = { x = 0, z = 1 }, arrivalPoint = { x = 120, z = -5 }, accepts = { Small = true, Medium = true, Large = false } },
		{ id = "D_Far", address = "3 South Road", neighborhood = "Industrial", kind = "House", door = { x = 12, z = 260 }, facing = { x = -1, z = 0 }, arrivalPoint = { x = 5, z = 260 }, accepts = { Small = true, Medium = true, Large = true } },
	},
	landmarks = {},
	hub = { spawn = { x = 0, z = 30, facing = { x = 0, z = -1 } }, vehiclePads = {}, kiosk = { x = 0, z = 40 } },
	depotPlots = { { id = "P1", x = 80, z = 80, w = 40, d = 30, facing = { x = 0, z = -1 }, parking = {} } },
	pedestrianPaths = { { id = "Loop", loop = true, points = { { x = 0, z = 0 }, { x = 20, z = 0 }, { x = 20, z = 20 }, { x = 0, z = 20 } } } },
	parkedVehicles = {},
	props = {},
	bikeShortcuts = {},
}

-- Callers reset the shim and install the MeshData stand-in first (a reset would discard it).
local function clientSetup(controllerNames)
	local root = clientRoot()
	local ClientState = require(root.ClientState)
	ClientState.setLayout(LAYOUT)
	local ctx = { state = ClientState, layout = LAYOUT, controllers = {} }
	local ordered = {}
	for _, name in ipairs(controllerNames) do
		local controller = require(root.Controllers[name])
		ctx.controllers[name] = controller
		table.insert(ordered, controller)
	end
	for _, controller in ipairs(ordered) do
		controller.Init(ctx)
	end
	for _, controller in ipairs(ordered) do
		controller.Start()
	end
	return ctx, ClientState
end

describe("CityLifeController with embedded figures", function()
	it("builds pedestrian, customer and worker rigs and walks the pedestrians", function()
		shim.reset()
		shim.setContext("client")
		local FigureRig = withStub(ALL_FIGURES)
		local ctx = clientSetup({ "CityLifeController" })
		local CityLife = ctx.controllers.CityLifeController
		shim.advance(2.5)
		local walkers, idlers = CityLife.GetCounts()
		expect(walkers).toBe(3)
		expect(idlers).toBe(3) -- 2 customers + 1 depot worker
		local folder = game:GetService("Workspace").CurrentCamera.ClientFX.NPCs
		local pedestrians, customers, workers = {}, {}, {}
		for _, child in ipairs(folder:GetChildren()) do
			if child.Name == "Pedestrian" then
				table.insert(pedestrians, child)
			elseif child.Name == "Customer" then
				table.insert(customers, child)
			elseif child.Name == "Worker" then
				table.insert(workers, child)
			end
		end
		expect(#pedestrians).toBe(3)
		expect(#customers).toBe(2)
		expect(#workers).toBe(1)
		for _, figure in ipairs(pedestrians) do
			expect(string.sub(figure:GetAttribute("FigureId"), 1, 13)).toBe("NPCPedestrian")
			expect(figure:GetAttribute("NPCKind")).toBe("Pedestrian")
			expect(figure.Root.Anchored).toBe(true)
			expect(figure:FindFirstChild("Torso")).toBeNil()
			for _, part in ipairs(figure:GetDescendants()) do
				if part:IsA("BasePart") then
					expect(part.CanCollide).toBe(false)
					expect(part.CanQuery).toBe(false)
					expect(part.CanTouch).toBe(false)
					if part.Name ~= "Root" then
						expect(part.Anchored).toBe(false)
						expect(game:GetService("CollectionService"):HasTag(part, TAG)).toBe(true)
					end
				end
			end
		end
		for _, figure in ipairs(customers) do
			expect(string.sub(figure:GetAttribute("FigureId"), 1, 11)).toBe("NPCCustomer")
			expect(figure.LegL.LeftHip.Transform).toBeCloseTo(CFrame.identity, 1e-6)
		end
		expect(workers[1]:GetAttribute("FigureId")).toBe("NPCWorker")
		-- Walking: the root moves along the loop and the hip transforms swing.
		local figure = pedestrians[1]
		local before = figure.Root.Position
		local transforms = {}
		for i = 1, 4 do
			shim.advance(0.25)
			transforms[i] = figure.LegL.LeftHip.Transform
		end
		expect((figure.Root.Position - before).Magnitude).toBeGreaterThan(3)
		local changed = false
		for i = 2, 4 do
			if (transforms[i].Position - transforms[i - 1].Position).Magnitude > 1e-9 or math.abs(select(1, transforms[i]:ToEulerAnglesXYZ()) - select(1, transforms[i - 1]:ToEulerAnglesXYZ())) > 1e-4 then
				changed = true
			end
		end
		expect(changed).toBe(true)
		expect(figure.LegL.LeftHip.Transform).never.toBeCloseTo(figure.LegR.RightHip.Transform, 1e-6)
		-- Feet stay on the ground while walking.
		expect(figure.Root.Position.Y).toBeCloseTo(ROOT_HEIGHT, 1e-4)
		-- Far away figures are hidden (parented out) and shown again.
		local camera = game:GetService("Workspace").CurrentCamera
		camera.CFrame = CFrame.new(5000, 0, 5000)
		shim.advance(0.2)
		expect(figure.Parent).toBeNil()
		camera.CFrame = CFrame.new(0, 10, 0)
		shim.advance(0.2)
		expect(figure.Parent).toBe(folder)
		expect(#shim.warnings).toBe(0)
		FigureRig._setMeshData(nil)
	end)

	it("keeps the generated figure for kinds without data", function()
		shim.reset()
		shim.setContext("client")
		withStub({ "NPCWorker" })
		local ctx = clientSetup({ "CityLifeController" })
		shim.advance(2.5)
		local folder = game:GetService("Workspace").CurrentCamera.ClientFX.NPCs
		local generated, rigs = 0, 0
		for _, child in ipairs(folder:GetChildren()) do
			if child:GetAttribute("FigureId") then
				rigs += 1
				expect(child.Name).toBe("Worker")
			else
				generated += 1
				expect(child:FindFirstChild("Torso")).toBeTruthy()
			end
		end
		expect(rigs).toBe(1)
		expect(generated).toBe(5)
		shim.advance(0.5)
		expect(#shim.warnings).toBe(0)
	end)
end)

describe("EffectsController door customer", function()
	local function makeDoor(destinationId, cframe)
		local destinations = game:GetService("Workspace"):FindFirstChild("DeliveryDestinations")
		if not destinations then
			destinations = Instance.new("Folder")
			destinations.Name = "DeliveryDestinations"
			destinations.Parent = workspace
		end
		local model = Instance.new("Model")
		model.Name = destinationId
		local door = Instance.new("Part")
		door.Name = "Door"
		door.Size = Vector3.new(4, 7, 0.6)
		door.CFrame = cframe
		door.Anchored = true
		door.Parent = model
		model.Parent = destinations
		return door
	end

	it("places an idle customer rig in the doorway facing outward for 3.5 s, then removes it", function()
		shim.reset()
		shim.setContext("client")
		local FigureRig = withStub({ "NPCCustomerA", "NPCCustomerB" })
		local ctx, ClientState = clientSetup({ "EffectsController" })
		local Effects = ctx.controllers.EffectsController
		makeDoor("D_Near", CFrame.new(120, 3.5, -12))
		shim.tweensInstant = true
		ClientState.WorldEvent:Fire({ kind = "DoorReaction", destinationId = "D_Near", line = "Thanks!" })
		shim.advance(0.05)
		local fx = game:GetService("Workspace").CurrentCamera.ClientFX
		expect(fx:FindFirstChild("SpeechBubble")).toBeTruthy()
		local customer = fx:FindFirstChild("DoorCustomer")
		expect(customer).toBeTruthy()
		expect(customer:GetAttribute("DestinationId")).toBe("D_Near")
		expect(string.sub(customer:GetAttribute("FigureId"), 1, 11)).toBe("NPCCustomer")
		expect(customer.Root.Anchored).toBe(true)
		-- Feet at the door's base plus facing * 1.2 (the layout facing, +Z here), looking outward.
		expect(customer.Root.Position).toBeCloseTo(Vector3.new(120, ROOT_HEIGHT, -12 + 1.2), 1e-4)
		expect(customer.Root.CFrame.LookVector).toBeCloseTo(Vector3.new(0, 0, 1), 1e-4)
		expect(customer.LegL.LeftHip.Transform).toBeCloseTo(CFrame.identity, 1e-6)
		expect(game:GetService("CollectionService"):HasTag(customer.Body, TAG)).toBe(true)
		-- A second reaction while the customer is out does not stack another one.
		ClientState.WorldEvent:Fire({ kind = "DoorReaction", destinationId = "D_Near" })
		shim.advance(0.05)
		expect(#childrenNamed(fx, "DoorCustomer")).toBe(1)
		shim.advance(3.6)
		expect(fx:FindFirstChild("DoorCustomer")).toBeNil()
		-- Same destination again after it left: a fresh customer.
		ClientState.WorldEvent:Fire({ kind = "DoorReaction", destinationId = "D_Near" })
		shim.advance(0.05)
		expect(fx:FindFirstChild("DoorCustomer")).toBeTruthy()
		expect(#shim.warnings).toBe(0)
	end)

	it("uses the layout door and facing when the destination is not streamed in", function()
		shim.reset()
		shim.setContext("client")
		withStub({ "NPCCustomerA", "NPCCustomerB" })
		local ctx, ClientState = clientSetup({ "EffectsController" })
		ClientState.WorldEvent:Fire({ kind = "DoorReaction", destinationId = "D_Far" })
		shim.advance(0.05)
		local fx = game:GetService("Workspace").CurrentCamera.ClientFX
		local customer = fx:FindFirstChild("DoorCustomer")
		expect(customer).toBeTruthy()
		expect(customer.Root.Position).toBeCloseTo(Vector3.new(12 - 1.2, ROOT_HEIGHT, 260), 1e-4)
		expect(customer.Root.CFrame.LookVector).toBeCloseTo(Vector3.new(-1, 0, 0), 1e-4)
		-- Direct API with an explicit facing.
		local model = ctx.controllers.EffectsController.ShowDoorCustomer("D_Near", Vector3.new(0, 0, 0), Vector3.new(0, 0, -1))
		expect(model).toBeTruthy()
		expect(model.Root.Position).toBeCloseTo(Vector3.new(0, ROOT_HEIGHT, -1.2), 1e-4)
		expect(#shim.warnings).toBe(0)
	end)

	it("skips the customer silently without embedded people data", function()
		shim.reset()
		shim.setContext("client")
		requireShared("Util/FigureRig")._setMeshData(NONE)
		local ctx, ClientState = clientSetup({ "EffectsController" })
		makeDoor("D_Near", CFrame.new(120, 3.5, -12))
		shim.tweensInstant = true
		ClientState.WorldEvent:Fire({ kind = "DoorReaction", destinationId = "D_Near", line = "Thanks!" })
		shim.advance(0.05)
		local fx = game:GetService("Workspace").CurrentCamera.ClientFX
		expect(fx:FindFirstChild("SpeechBubble")).toBeTruthy()
		expect(fx:FindFirstChild("Confetti")).toBeTruthy()
		expect(fx:FindFirstChild("DoorCustomer")).toBeNil()
		expect(ctx.controllers.EffectsController.ShowDoorCustomer("D_Near", Vector3.zero, Vector3.zAxis)).toBeNil()
		expect(#shim.warnings).toBe(0)
	end)
end)

-------------------------------------------------------------------------------
-- ShopService.ApplyUniform (embedded vest placeholder)
-------------------------------------------------------------------------------

describe("ShopService.ApplyUniform with the embedded vest", function()
	local Shop, FigureRig, player, profile

	local function serverSetup(ids)
		shim.reset()
		shim.setContext("server")
		FigureRig = withStub(ids)
		local ReplicatedStorage = game:GetService("ReplicatedStorage")
		local Remotes = require(ReplicatedStorage.Shared.Util.Remotes)
		Remotes.createAll()
		profile = { ownedVehicles = {}, cosmetics = { owned = {}, equipped = { Uniform = "Uniform_Orange" } } }
		Shop = requireService("ShopService")
		Shop.Init({
			services = { PlayerDataService = { GetProfile = function() return profile end, GetPublicProfile = function() return profile end } },
			remotes = Remotes,
			isStudio = false,
		})
		player = shim.addPlayer("Courier", 801)
		shim.spawnCharacter(player, CFrame.new(10, 3, 20))
	end

	it("creates the tagged placeholder welded to the torso with MeshColor and updates it in place", function()
		serverSetup({ "CourierVest" })
		expect(Shop.HasEmbeddedVest()).toBe(true)
		Shop.ApplyUniform(player)
		local character = player.Character
		local torso = character:FindFirstChild("UpperTorso")
		local vest = character:FindFirstChild("CourierVest")
		expect(vest).toBeTruthy()
		expect(vest.ClassName).toBe("Part")
		expect(vest.Size).toBeCloseTo(Vector3.new(2.3, 1.9, 1.3), 1e-6)
		expect(vest.Transparency).toBe(1)
		expect(vest.Massless).toBe(true)
		expect(vest.CanCollide).toBe(false)
		expect(vest.CanQuery).toBe(false)
		expect(vest.CanTouch).toBe(false)
		expect(vest:GetAttribute("EmbeddedMesh")).toBe("CourierVest")
		expect(vest:GetAttribute("EmbeddedPart")).toBe("Body")
		expect(vest:GetAttribute("MeshColor")).toEqual(Color3.fromRGB(250, 140, 40))
		expect(game:GetService("CollectionService"):HasTag(vest, TAG)).toBe(true)
		expect(vest.CFrame).toBeCloseTo(torso.CFrame * CFrame.new(0, -0.1, 0), 1e-5)
		expect(vest:FindFirstChild("VestTrim")).toBeNil()
		local weld = vest:FindFirstChildWhichIsA("WeldConstraint")
		expect(weld).toBeTruthy()
		expect(weld.Part0).toBe(torso)
		expect(weld.Part1).toBe(vest)
		expect(game:GetService("CollectionService"):GetTagged(TAG)).toContain(vest)

		-- Re-applying with another uniform keeps the same part and only changes MeshColor.
		local changes = 0
		vest:GetAttributeChangedSignal("MeshColor"):Connect(function()
			changes += 1
		end)
		profile.cosmetics.equipped.Uniform = "Uniform_Blue"
		Shop.ApplyUniform(player)
		expect(character:FindFirstChild("CourierVest")).toBe(vest)
		expect(vest:GetAttribute("MeshColor")).toEqual(Color3.fromRGB(50, 110, 200))
		expect(changes).toBe(1)
		expect(#childrenNamed(character, "CourierVest")).toBe(1)
		-- A stale generated vest is replaced by the placeholder.
		local generated = Instance.new("Part")
		generated.Name = "CourierVest"
		vest:Destroy()
		generated.Parent = character
		Shop.ApplyUniform(player)
		local fresh = character:FindFirstChild("CourierVest")
		expect(fresh).never.toBe(generated)
		expect(fresh:GetAttribute("EmbeddedMesh")).toBe("CourierVest")
		expect(#shim.warnings).toBe(0)
	end)

	it("keeps the generated vest without embedded data", function()
		serverSetup({ "NPCStaff" })
		expect(Shop.HasEmbeddedVest()).toBe(false)
		Shop.ApplyUniform(player)
		local vest = player.Character:FindFirstChild("CourierVest")
		expect(vest).toBeTruthy()
		expect(vest:GetAttribute("EmbeddedMesh")).toBeNil()
		expect(vest.Color).toEqual(Color3.fromRGB(250, 140, 40))
		expect(vest:FindFirstChild("VestTrim")).toBeTruthy()
		expect(game:GetService("CollectionService"):HasTag(vest, TAG)).toBe(false)
	end)
end)

-------------------------------------------------------------------------------
-- EmbeddedMeshController: multi-part figures, the untextured vest, rig dressing, priority
-------------------------------------------------------------------------------

describe("EmbeddedMeshController multi-part", function()
	local Controller, FigureRig, CollectionService

	local function controllerSetup(ids, opts)
		shim.reset()
		shim.setContext("client")
		CollectionService = game:GetService("CollectionService")
		FigureRig = withStub(ids)
		Controller = require(clientRoot().Controllers.EmbeddedMeshController)
		local stub = decoderStub(ids, opts)
		Controller._setDecoders(stub)
		Controller.Init({ state = { get = function() return nil end }, controllers = {} })
		return stub
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

	it("builds one EditableImage per textured entry and one MeshPart per part, untextured for the vest", function()
		local stub = controllerSetup({ "NPCStaff", "CourierVest" })
		local loaded = {}
		Controller.Loaded:Connect(function(id)
			table.insert(loaded, id)
		end)
		Controller.Start()
		shim.advance(0.3)
		expect(loaded).toEqual({ "CourierVest", "NPCStaff" }) -- priority order
		expect(Controller.IsReady("NPCStaff")).toBe(true)
		expect(Controller.IsReady("CourierVest")).toBe(true)
		expect(Controller.ListParts("NPCStaff")).toEqual({ "Body", "LegL", "LegR" })
		expect(Controller.ListParts("CourierVest")).toEqual({ "Body" })
		expect(stub.calls.loadPart).toEqual({ "CourierVest/Body", "NPCStaff/Body", "NPCStaff/LegL", "NPCStaff/LegR" })
		expect(stub.calls.loadTexture).toBe(1)
		expect(stub.calls.decodePng).toBe(1)
		expect(stub.calls.decodeMesh).toBe(4)
		expect(callsOf("CreateEditableImage")).toBe(1)
		expect(callsOf("CreateEditableMesh")).toBe(4)
		expect(callsOf("CreateMeshPartAsync")).toBe(4)

		local body = Controller.GetMeshPart("NPCStaff") -- default part "Body"
		expect(body).toBe(Controller.GetMeshPart("NPCStaff", "Body"))
		local legL = Controller.GetMeshPart("NPCStaff", "LegL")
		local legR = Controller.GetMeshPart("NPCStaff", "LegR")
		expect(legL).toBeTruthy()
		expect(legR).toBeTruthy()
		expect(legL).never.toBe(legR)
		-- Every figure part shares the entry's EditableImage and is sized by its index bbox.
		local image = body.TextureContent.Object
		expect(image.ClassName).toBe("EditableImage")
		expect(legL.TextureContent.Object).toBe(image)
		expect(legR.TextureContent.Object).toBe(image)
		for i, entry in ipairs(FIGURE.parts) do
			local part = Controller.GetMeshPart("NPCStaff", entry.name)
			expect(part.Name).toBe("EmbeddedMesh")
			expect(part.Parent).toBeNil()
			expect(part.Size).toBeCloseTo(vecOf(entry.bboxMax) - vecOf(entry.bboxMin), 1e-6)
			expect(part.MeshContent.Object.ClassName).toBe("EditableMesh")
			expect(part.Massless).toBe(true)
			expect(part.CanCollide).toBe(false)
			expect(part.CastShadow).toBe(true)
			expect(i).toBeGreaterThan(0)
		end
		-- The vest has no texture, a grey default colour and the accessory bbox size.
		local vest = Controller.GetMeshPart("CourierVest")
		expect(vest.TextureContent).toBeNil()
		expect(vest.Size).toBeCloseTo(Vector3.new(2.3, 1.9, 1.3), 1e-6)
		expect(vest.Material).toBe(Enum.Material.SmoothPlastic)
		local stats = Controller.DecodeStats.NPCStaff
		expect(stats.parts).toBe(3)
		expect(stats.textureSeconds).toBeGreaterThanOrEqual(0)
		expect(Controller.DecodeStats.CourierVest.parts).toBe(1)
		expect(Controller.DecodeStats.CourierVest.textureSeconds).toBe(0)
		expect(#shim.warnings).toBe(0)
	end)

	it("dresses a FigureRig built on the client: one welded clone per placeholder part", function()
		controllerSetup({ "NPCPedestrianB" })
		Controller.Start()
		shim.advance(0.3)
		expect(Controller.IsReady("NPCPedestrianB")).toBe(true)
		local rig = FigureRig.build("NPCPedestrianB", { name = "Pedestrian", anchored = true })
		FigureRig.place(rig, Vector3.new(30, 0, 10), Vector3.new(1, 0, 0))
		rig.Parent = workspace
		for _, entry in ipairs(FIGURE.parts) do
			local placeholder = rig[entry.name]
			local clones = childrenNamed(placeholder, "EmbeddedMesh")
			expect(#clones).toBe(1)
			local clone = clones[1]
			expect(clone:IsA("MeshPart")).toBe(true)
			expect(clone).never.toBe(Controller.GetMeshPart("NPCPedestrianB", entry.name))
			expect(clone.MeshContent).toBe(Controller.GetMeshPart("NPCPedestrianB", entry.name).MeshContent)
			expect(clone.CFrame).toBeCloseTo(placeholder.CFrame, 1e-5)
			expect(clone.Anchored).toBe(false) -- placeholders are unanchored (only Root is anchored)
			expect(clone.Massless).toBe(true)
			expect(clone.CanCollide).toBe(false)
			expect(clone.TextureContent.Object.ClassName).toBe("EditableImage")
			local weld = clone:FindFirstChildWhichIsA("WeldConstraint")
			expect(weld).toBeTruthy()
			expect(weld.Part0).toBe(placeholder)
			expect(weld.Part1).toBe(clone)
			expect(placeholder.Transparency).toBe(1)
		end
		expect(rig.Root:FindFirstChild("EmbeddedMesh")).toBeNil()
		-- Hiding and showing the rig (CityLife pause) does not duplicate the clones.
		rig.Parent = nil
		rig.Parent = workspace
		Controller.Refresh()
		expect(#childrenNamed(rig.LegL, "EmbeddedMesh")).toBe(1)
		-- A frozen (anchored) placeholder gets an anchored clone instead of a weld.
		local static = FigureRig.build("NPCPedestrianB")
		for _, d in ipairs(static:GetDescendants()) do
			if d:IsA("BasePart") then
				d.Anchored = true
			end
		end
		static.Parent = workspace
		local shown = static.Body.EmbeddedMesh
		expect(shown.Anchored).toBe(true)
		expect(shown:FindFirstChildWhichIsA("WeldConstraint")).toBeNil()
		expect(#shim.warnings).toBe(0)
	end)

	it("tints the untextured vest clone with MeshColor and follows attribute changes", function()
		controllerSetup({ "CourierVest" })
		Controller.Start()
		shim.advance(0.3)
		local placeholder = Instance.new("Part")
		placeholder.Name = "CourierVest"
		placeholder.Size = Vector3.new(2.3, 1.9, 1.3)
		placeholder.Transparency = 1
		placeholder.Anchored = false
		placeholder.CFrame = CFrame.new(1, 2, 3)
		placeholder:SetAttribute("EmbeddedMesh", "CourierVest")
		placeholder:SetAttribute("EmbeddedPart", "Body")
		placeholder:SetAttribute("MeshColor", Color3.fromRGB(250, 140, 40))
		CollectionService:AddTag(placeholder, TAG)
		placeholder.Parent = workspace
		local clone = placeholder:FindFirstChild("EmbeddedMesh")
		expect(clone).toBeTruthy()
		expect(clone.Color).toEqual(Color3.fromRGB(250, 140, 40))
		expect(clone.Material).toBe(Enum.Material.SmoothPlastic)
		expect(clone.TextureContent).toBeNil()
		expect(clone:FindFirstChildWhichIsA("WeldConstraint").Part0).toBe(placeholder)
		-- The uniform changes: the clone follows the attribute.
		placeholder:SetAttribute("MeshColor", Color3.fromRGB(50, 110, 200))
		expect(clone.Color).toEqual(Color3.fromRGB(50, 110, 200))
		-- Streaming the placeholder out and in keeps one clone that still follows the colour.
		placeholder.Parent = nil
		placeholder.Parent = workspace
		expect(#childrenNamed(placeholder, "EmbeddedMesh")).toBe(1)
		placeholder:SetAttribute("MeshColor", Color3.fromRGB(25, 25, 30))
		expect(placeholder.EmbeddedMesh.Color).toEqual(Color3.fromRGB(25, 25, 30))
		-- Without MeshColor the clone keeps the template's default colour.
		local plain = placeholder:Clone()
		plain:SetAttribute("MeshColor", nil)
		plain.EmbeddedMesh:Destroy()
		plain.Parent = workspace
		expect(plain.EmbeddedMesh.Color).toEqual(Controller.GetMeshPart("CourierVest").Color)
		expect(#shim.warnings).toBe(0)
	end)

	it("orders the decode by PRIORITY and warns once per failed entry, tinting failed boxes", function()
		expect(require(clientRoot().Controllers.EmbeddedMeshController).DecodeOrder({ "Van", "NPCWorker", "Zzz", "CourierVest", "Aaa", "Bicycle" })).toEqual({ "CourierVest", "Bicycle", "NPCWorker", "Van", "Zzz", "Aaa" })
		local stub = controllerSetup({ "NPCStaff", "CourierVest", "NPCWorker" }, { failPart = "LegR" })
		-- A vest placeholder present before the decode, with a colour.
		local placeholder = Instance.new("Part")
		placeholder.Transparency = 1
		placeholder:SetAttribute("EmbeddedMesh", "NPCStaff")
		placeholder:SetAttribute("EmbeddedPart", "Body")
		placeholder:SetAttribute("MeshColor", Color3.fromRGB(10, 20, 30))
		CollectionService:AddTag(placeholder, TAG)
		placeholder.Parent = workspace
		Controller.Start()
		shim.advance(0.5)
		expect(stub.order[1]).toBe("CourierVest")
		expect(stub.order[2]).toBe("NPCStaff")
		expect(Controller.IsReady("CourierVest")).toBe(true)
		-- Figures fail on their LegR part: one warning each, no parts cached, placeholders boxed.
		expect(Controller.IsReady("NPCStaff")).toBe(false)
		expect(Controller.HasFailed("NPCStaff")).toBe(true)
		expect(Controller.HasFailed("NPCWorker")).toBe(true)
		expect(Controller.GetMeshPart("NPCStaff", "Body")).toBeNil()
		expect(#shim.warnings).toBe(2)
		expect(shim.warnings[1]).toMatch("NPCStaff")
		expect(shim.warnings[2]).toMatch("NPCWorker")
		expect(placeholder.Transparency).toBeCloseTo(Controller.FAILED_TRANSPARENCY, 1e-6)
		expect(placeholder.Color).toEqual(Color3.fromRGB(10, 20, 30))
		expect(placeholder:FindFirstChild("EmbeddedMesh")).toBeNil()
		-- A rig added afterwards gets the same treatment (grey boxes, no MeshColor).
		local rig = FigureRig.build("NPCWorker")
		rig.Parent = workspace
		expect(rig.Body.Transparency).toBeCloseTo(Controller.FAILED_TRANSPARENCY, 1e-6)
		expect(rig.LegL.Transparency).toBeCloseTo(Controller.FAILED_TRANSPARENCY, 1e-6)
		expect(Controller.Load("NPCWorker")).toBe(false)
		expect(#shim.warnings).toBe(2)
	end)
end)
