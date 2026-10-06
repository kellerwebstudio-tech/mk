--!strict
-- NPCBuilder: simple part-based figures (no Humanoid) used for business staff, depot drivers,
-- and client-side pedestrians/customers. Every limb is joined to the Root through a Motor6D so
-- NPCBuilder.setWalkPose can animate it by writing Motor6D.Transform.
--
-- Model layout:
--   Model "<Kind>" (PrimaryPart Root, attribute NPCKind, tag "CityNPC")
--     Root   (invisible 2x2x1 Part at the torso centre; the caller anchors it for static NPCs)
--     Torso, Head, LeftArm, RightArm, LeftLeg, RightLeg (Motor6D "TorsoJoint", "Neck",
--       "LeftShoulder", "RightShoulder", "LeftHip", "RightHip", Part0 = Root, parented to the limb)
--     optional accessories (Cap, Brim, Apron, Vest, HardHat, Beanie) welded to Head/Torso
--     optional "NameTag" BillboardGui on the Head when options.name is given
-- The figure stands on y = Root.Position.Y - 3 (legs are 2 tall, hip joint 1 below the root centre).

local CollectionService = game:GetService("CollectionService")
local PhysicsService = game:GetService("PhysicsService")

local NPCBuilder = {}

export type NPCKind = "Pedestrian" | "Staff" | "Customer" | "Worker" | "Driver"
export type RGB = { number }
export type NPCOptions = { name: string?, shirt: RGB?, pants: RGB? }

NPCBuilder.COLLISION_GROUP = "NPCs"
NPCBuilder.TAG = "CityNPC"
NPCBuilder.FOOT_OFFSET = 3 -- studs from the Root centre down to the soles

-- Height of the root centre above the ground; callers use this to place the figure on a surface.
NPCBuilder.ROOT_HEIGHT = 3

local SKIN_TONES: { RGB } = {
	{ 255, 220, 190 }, { 240, 195, 160 }, { 222, 170, 125 }, { 190, 135, 90 }, { 150, 100, 60 }, { 110, 70, 40 },
}
local CASUAL_SHIRTS: { RGB } = {
	{ 230, 80, 70 }, { 70, 130, 200 }, { 240, 200, 70 }, { 90, 170, 110 }, { 200, 120, 200 }, { 240, 240, 240 },
	{ 60, 60, 70 }, { 250, 150, 60 }, { 120, 200, 220 }, { 170, 90, 60 },
}
local PANTS_COLORS: { RGB } = {
	{ 50, 60, 90 }, { 40, 40, 45 }, { 110, 90, 70 }, { 90, 110, 130 }, { 200, 190, 170 }, { 70, 90, 60 },
}
local HAIR_COLORS: { RGB } = { { 40, 30, 25 }, { 90, 60, 35 }, { 200, 160, 90 }, { 120, 120, 125 }, { 160, 60, 40 } }

local function rgb(c: RGB): Color3
	return Color3.fromRGB(c[1], c[2], c[3])
end

local function pick<T>(rng: Random, list: { T }): T
	return list[rng:NextInteger(1, #list)]
end

local function ensureCollisionGroup(name: string)
	local ok, registered = pcall(function()
		return PhysicsService:IsCollisionGroupRegistered(name)
	end)
	if ok and registered == false then
		pcall(function()
			PhysicsService:RegisterCollisionGroup(name)
		end)
	end
end

-- Creates one figure part with the shared NPC defaults.
local function makePart(name: string, size: Vector3, color: Color3, material: Enum.Material?): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Material = material or Enum.Material.SmoothPlastic
	part.Anchored = false
	part.Massless = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.CollisionGroup = NPCBuilder.COLLISION_GROUP
	return part
end

-- Joins `part` to `root` with a Motor6D. c0 is the joint pivot in root space; c1 is the joint pivot
-- in part space. The part is positioned so that the joint is at rest (Transform = identity).
local function joint(name: string, root: BasePart, part: BasePart, c0: CFrame, c1: CFrame): Motor6D
	part.CFrame = root.CFrame * c0 * c1:Inverse()
	local motor = Instance.new("Motor6D")
	motor.Name = name
	motor.Part0 = root
	motor.Part1 = part
	motor.C0 = c0
	motor.C1 = c1
	motor.Parent = part
	return motor
end

-- Welds an accessory to a body part at the given offset (in the body part's space).
local function accessory(name: string, host: BasePart, size: Vector3, offset: CFrame, color: Color3, material: Enum.Material?, parent: Instance): Part
	local part = makePart(name, size, color, material)
	part.CastShadow = false
	part.CFrame = host.CFrame * offset
	part.Parent = parent
	local weld = Instance.new("WeldConstraint")
	weld.Name = "AccessoryWeld"
	weld.Part0 = host
	weld.Part1 = part
	weld.Parent = part
	return part
end

type Outfit = { skin: Color3, shirt: Color3, pants: Color3, hair: Color3 }

local function outfitFor(kind: string, rng: Random, options: NPCOptions?): Outfit
	local shirt: RGB
	local pants: RGB
	if kind == "Staff" then
		shirt = { 245, 245, 240 }
		pants = { 40, 40, 45 }
	elseif kind == "Worker" then
		shirt = { 90, 100, 110 }
		pants = { 60, 70, 90 }
	elseif kind == "Driver" then
		shirt = { 250, 140, 40 }
		pants = { 50, 60, 90 }
	else
		shirt = pick(rng, CASUAL_SHIRTS)
		pants = pick(rng, PANTS_COLORS)
	end
	if options and options.shirt then
		shirt = options.shirt
	end
	if options and options.pants then
		pants = options.pants
	end
	return {
		skin = rgb(pick(rng, SKIN_TONES)),
		shirt = rgb(shirt),
		pants = rgb(pants),
		hair = rgb(pick(rng, HAIR_COLORS)),
	}
end

local function addNameTag(head: BasePart, name: string)
	local gui = Instance.new("BillboardGui")
	gui.Name = "NameTag"
	gui.Size = UDim2.new(0, 160, 0, 36)
	gui.StudsOffset = Vector3.new(0, 1.4, 0)
	gui.MaxDistance = 80
	gui.LightInfluence = 0
	gui.AlwaysOnTop = false
	gui.Parent = head
	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = name
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextStrokeTransparency = 0.4
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.Parent = gui
end

--[[
	Builds an NPC figure.
	kind: "Pedestrian" | "Staff" | "Customer" | "Worker" | "Driver"
	seed: deterministic appearance seed (nil = 0)
	options: { name?, shirt = {r,g,b}?, pants = {r,g,b}? } — Staff aprons use options.shirt as the accent.
	The returned model has no Parent; the caller pivots it (Root is the PrimaryPart) and anchors
	Root when the figure is static.
]]
function NPCBuilder.build(kind: string, seed: number?, options: NPCOptions?): Model
	ensureCollisionGroup(NPCBuilder.COLLISION_GROUP)
	local rng = Random.new(seed or 0)
	local outfit = outfitFor(kind, rng, options)

	local model = Instance.new("Model")
	model.Name = kind
	model:SetAttribute("NPCKind", kind)
	model:SetAttribute("Seed", seed or 0)

	local root = makePart("Root", Vector3.new(2, 2, 1), Color3.fromRGB(255, 255, 255))
	root.Transparency = 1
	root.CastShadow = false
	root.CFrame = CFrame.new(0, NPCBuilder.ROOT_HEIGHT, 0)
	root.Parent = model
	model.PrimaryPart = root

	local torso = makePart("Torso", Vector3.new(2, 2, 1), outfit.shirt)
	torso.Parent = model
	joint("TorsoJoint", root, torso, CFrame.new(), CFrame.new())

	local head = makePart("Head", Vector3.new(1.2, 1.2, 1.2), outfit.skin)
	head.Parent = model
	joint("Neck", root, head, CFrame.new(0, 1, 0), CFrame.new(0, -0.6, 0))

	local leftArm = makePart("LeftArm", Vector3.new(1, 2, 1), outfit.shirt)
	leftArm.Parent = model
	joint("LeftShoulder", root, leftArm, CFrame.new(-1.5, 1, 0), CFrame.new(0, 1, 0))

	local rightArm = makePart("RightArm", Vector3.new(1, 2, 1), outfit.shirt)
	rightArm.Parent = model
	joint("RightShoulder", root, rightArm, CFrame.new(1.5, 1, 0), CFrame.new(0, 1, 0))

	local leftLeg = makePart("LeftLeg", Vector3.new(1, 2, 1), outfit.pants)
	leftLeg.Parent = model
	joint("LeftHip", root, leftLeg, CFrame.new(-0.5, -1, 0), CFrame.new(0, 1, 0))

	local rightLeg = makePart("RightLeg", Vector3.new(1, 2, 1), outfit.pants)
	rightLeg.Parent = model
	joint("RightHip", root, rightLeg, CFrame.new(0.5, -1, 0), CFrame.new(0, 1, 0))

	-- Hair for everyone except hard-hat workers (a flat slab on top of the head).
	if kind ~= "Worker" then
		accessory("Hair", head, Vector3.new(1.25, 0.35, 1.25), CFrame.new(0, 0.7, 0), outfit.hair, nil, model)
	end

	-- Kind-specific accessories.
	if kind == "Staff" then
		local accent = if options and options.shirt then rgb(options.shirt) else Color3.fromRGB(200, 60, 50)
		accessory("Cap", head, Vector3.new(1.3, 0.4, 1.3), CFrame.new(0, 0.85, 0), accent, nil, model)
		accessory("Brim", head, Vector3.new(1.3, 0.12, 0.7), CFrame.new(0, 0.72, -0.9), accent, nil, model)
		accessory("Apron", torso, Vector3.new(2.05, 1.6, 0.2), CFrame.new(0, -0.3, -0.58), accent, Enum.Material.Fabric, model)
	elseif kind == "Worker" then
		accessory("Vest", torso, Vector3.new(2.15, 1.5, 1.15), CFrame.new(0, 0.1, 0), Color3.fromRGB(230, 255, 60), Enum.Material.Fabric, model)
		accessory("HardHat", head, Vector3.new(1.4, 0.6, 1.4), CFrame.new(0, 0.85, 0), Color3.fromRGB(250, 200, 40), nil, model)
	elseif kind == "Driver" then
		accessory("Cap", head, Vector3.new(1.3, 0.4, 1.3), CFrame.new(0, 0.85, 0), Color3.fromRGB(40, 55, 100), nil, model)
		accessory("Brim", head, Vector3.new(1.3, 0.12, 0.7), CFrame.new(0, 0.72, -0.9), Color3.fromRGB(40, 55, 100), nil, model)
	elseif kind == "Pedestrian" then
		if rng:NextNumber() < 0.3 then
			accessory("Beanie", head, Vector3.new(1.3, 0.5, 1.3), CFrame.new(0, 0.8, 0), rgb(pick(rng, CASUAL_SHIRTS)), Enum.Material.Fabric, model)
		end
	end

	if options and options.name and options.name ~= "" then
		addNameTag(head, options.name)
	end

	CollectionService:AddTag(model, NPCBuilder.TAG)
	return model
end

-- Swings arms and legs from sin(phase). phase advances with walking distance (radians).
function NPCBuilder.setWalkPose(model: Model, phase: number)
	local swing = math.sin(phase) * 0.7
	local function setMotor(limbName: string, motorName: string, angle: number)
		local limb = model:FindFirstChild(limbName)
		if limb then
			local motor = limb:FindFirstChild(motorName)
			if motor and motor:IsA("Motor6D") then
				motor.Transform = CFrame.Angles(angle, 0, 0)
			end
		end
	end
	setMotor("LeftArm", "LeftShoulder", swing)
	setMotor("RightArm", "RightShoulder", -swing)
	setMotor("LeftLeg", "LeftHip", -swing)
	setMotor("RightLeg", "RightHip", swing)
end

-- Resets the pose to standing.
function NPCBuilder.setIdlePose(model: Model)
	NPCBuilder.setWalkPose(model, 0)
end

-- Places the figure so its feet rest on `position` and it looks along `facing` (flat).
function NPCBuilder.place(model: Model, position: Vector3, facing: Vector3?, anchored: boolean?)
	local look = facing or Vector3.new(0, 0, -1)
	look = Vector3.new(look.X, 0, look.Z)
	if look.Magnitude < 1e-3 then
		look = Vector3.new(0, 0, -1)
	end
	local origin = position + Vector3.new(0, NPCBuilder.ROOT_HEIGHT, 0)
	model:PivotTo(CFrame.lookAt(origin, origin + look.Unit))
	local root = model.PrimaryPart
	if root and anchored ~= false then
		root.Anchored = true
	end
end

-- Anchors every part of a static figure (no physics at all; Motor6D animation is then a no-op).
-- Server-side scenery NPCs (business staff, depot drivers) use this; animated client NPCs do not.
function NPCBuilder.freeze(model: Model)
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
		end
	end
end

return NPCBuilder
