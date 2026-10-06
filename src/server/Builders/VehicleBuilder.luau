--!strict
-- VehicleBuilder: builds vehicle models from the declarative visual specs in VehicleDefinitions.
-- Structure (docs/ARCHITECTURE.md section 8.3):
--   Model "Vehicle" (Attributes OwnerUserId, VehicleId, State, Capacity; tag "DeliveryVehicle")
--     Chassis (PrimaryPart: invisible box, CollisionGroup "Vehicles", anchored until mounted)
--       RootAttachment, Align (AlignOrientation), Velocity (LinearVelocity),
--       CargoAttachment, DismountAttachment, EngineSound (Sound)
--     BodyRoot (invisible, Massless) + Motor6D "BodyMotor" (Part0 = Chassis, Part1 = BodyRoot)
--     Seat (VehicleSeat, Disabled, welded to BodyRoot)
--     Body (Folder of cosmetic parts welded to BodyRoot; attribute PaintSlot where recolourable)
--     Wheels (Folder of cylinders joined to BodyRoot through Motor6D "WheelMotor")
--     Cargo (Folder; packages are parented here by PackageBuilder)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local PhysicsService = game:GetService("PhysicsService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Definitions = Shared:WaitForChild("Definitions")
local Config = Shared:WaitForChild("Config")
local VehicleDefinitions = require(Definitions:WaitForChild("VehicleDefinitions"))
local AudioConfig = require(Config:WaitForChild("AudioConfig"))

local VehicleBuilder = {}

export type RGB = { number }
export type Colors = { Primary: RGB?, Accent: RGB?, Decal: RGB? }

VehicleBuilder.COLLISION_GROUP = "Vehicles"
VehicleBuilder.TAG = "DeliveryVehicle"
VehicleBuilder.SMALL_PART_SIZE = 1 -- parts whose largest dimension is below this cast no shadow

local function rgb(c: RGB): Color3
	return Color3.fromRGB(c[1], c[2], c[3])
end

local function vec(t: { number }): Vector3
	return Vector3.new(t[1], t[2], t[3])
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

local function getDefinition(vehicleId: string): VehicleDefinitions.VehicleDefinition
	local def = VehicleDefinitions.get(vehicleId)
	assert(def ~= nil, "Unknown vehicle id " .. tostring(vehicleId))
	return def :: VehicleDefinitions.VehicleDefinition
end

-- Resolves the three paint colours, falling back to the vehicle defaults.
local function resolveColors(def: VehicleDefinitions.VehicleDefinition, colors: Colors?): { [string]: Color3 }
	local defaults = def.defaultColors
	local function pickColor(slot: string): Color3
		local override = if colors then (colors :: any)[slot] else nil
		if type(override) == "table" and #override >= 3 then
			return rgb(override)
		end
		return rgb((defaults :: any)[slot])
	end
	return { Primary = pickColor("Primary"), Accent = pickColor("Accent"), Decal = pickColor("Decal") }
end

local function materialFrom(name: string?): Enum.Material
	if name then
		local ok, material = pcall(function()
			return (Enum.Material :: any)[name]
		end)
		if ok and material then
			return material
		end
	end
	return Enum.Material.SmoothPlastic
end

-- Creates a cosmetic part from a visual spec. Returns the part and the paint slot name (or nil).
local function makeVisualPart(spec: VehicleDefinitions.VisualPart, palette: { [string]: Color3 }, chassisCFrame: CFrame): (BasePart, string?)
	local part: BasePart
	if spec.shape == "Wedge" then
		part = Instance.new("WedgePart")
	else
		local p = Instance.new("Part")
		if spec.shape == "Cylinder" then
			p.Shape = Enum.PartType.Cylinder
		elseif spec.shape == "Ball" then
			p.Shape = Enum.PartType.Ball
		else
			p.Shape = Enum.PartType.Block
		end
		part = p
	end
	part.Name = spec.name
	part.Size = vec(spec.size)
	local offset = CFrame.new(vec(spec.offset))
	if spec.rot then
		offset = offset * CFrame.Angles(math.rad(spec.rot[1]), math.rad(spec.rot[2]), math.rad(spec.rot[3]))
	end
	part.CFrame = chassisCFrame * offset

	local slot: string? = nil
	if type(spec.color) == "string" then
		slot = spec.color
		part.Color = palette[spec.color] or Color3.fromRGB(255, 255, 255)
		part:SetAttribute("PaintSlot", spec.color)
	else
		part.Color = rgb(spec.color)
	end
	part.Material = materialFrom(spec.material)
	part.Transparency = spec.transparency or 0
	part.Reflectance = spec.reflectance or 0
	part.Massless = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	local largest = math.max(spec.size[1], spec.size[2], spec.size[3])
	part.CastShadow = largest >= VehicleBuilder.SMALL_PART_SIZE
	return part, slot
end

local function makeWheelPart(spec: VehicleDefinitions.WheelSpec, chassisCFrame: CFrame): Part
	local wheel = Instance.new("Part")
	wheel.Name = spec.name
	wheel.Shape = Enum.PartType.Cylinder
	wheel.Size = Vector3.new(spec.width, spec.radius * 2, spec.radius * 2)
	wheel.CFrame = chassisCFrame * CFrame.new(vec(spec.offset))
	wheel.Color = if spec.color then rgb(spec.color) else Color3.fromRGB(28, 28, 30)
	wheel.Material = Enum.Material.Rubber
	wheel.Massless = true
	wheel.CanCollide = false
	wheel.CanQuery = false
	wheel.CanTouch = false
	wheel.CastShadow = true
	wheel.TopSurface = Enum.SurfaceType.Smooth
	wheel.BottomSurface = Enum.SurfaceType.Smooth
	wheel:SetAttribute("Steerable", spec.steerable == true)
	wheel:SetAttribute("Radius", spec.radius)
	return wheel
end

local function weldTo(root: BasePart, part: BasePart)
	local weld = Instance.new("WeldConstraint")
	weld.Name = "BodyWeld"
	weld.Part0 = root
	weld.Part1 = part
	weld.Parent = part
end

-- Chassis: invisible physics box the controller drives through constraints.
local function makeChassis(def: VehicleDefinitions.VehicleDefinition): Part
	local chassis = Instance.new("Part")
	chassis.Name = "Chassis"
	chassis.Shape = Enum.PartType.Block
	chassis.Size = vec(def.chassisSize)
	chassis.CFrame = CFrame.new(0, def.handling.rideHeight, 0)
	chassis.Transparency = 1
	chassis.CanCollide = true
	chassis.CanQuery = false
	chassis.CanTouch = false
	chassis.CastShadow = false
	chassis.Anchored = true
	chassis.Massless = false
	chassis.CollisionGroup = VehicleBuilder.COLLISION_GROUP
	chassis.CustomPhysicalProperties = PhysicalProperties.new(0.7, 0.3, 0, 1, 1)
	chassis.TopSurface = Enum.SurfaceType.Smooth
	chassis.BottomSurface = Enum.SurfaceType.Smooth

	local rootAttachment = Instance.new("Attachment")
	rootAttachment.Name = "RootAttachment"
	rootAttachment.Position = Vector3.zero
	rootAttachment.Parent = chassis

	local align = Instance.new("AlignOrientation")
	align.Name = "Align"
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = rootAttachment
	align.RigidityEnabled = false
	align.MaxTorque = 1e7
	align.Responsiveness = 30
	align.MaxAngularVelocity = 12
	align.CFrame = chassis.CFrame.Rotation
	align.Enabled = true
	align.Parent = chassis

	local velocity = Instance.new("LinearVelocity")
	velocity.Name = "Velocity"
	velocity.Attachment0 = rootAttachment
	velocity.RelativeTo = Enum.ActuatorRelativeTo.World
	velocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	velocity.VectorVelocity = Vector3.zero
	velocity.MaxForce = 1e6
	velocity.Enabled = true
	velocity.Parent = chassis

	local cargo = Instance.new("Attachment")
	cargo.Name = "CargoAttachment"
	cargo.Position = vec(def.cargoOffset)
	cargo.Parent = chassis

	local dismount = Instance.new("Attachment")
	dismount.Name = "DismountAttachment"
	dismount.Position = vec(def.dismountOffset)
	dismount.Parent = chassis

	if def.engineSound then
		local soundDef = (AudioConfig.sounds :: any)[def.engineSound]
		local sound = Instance.new("Sound")
		sound.Name = "EngineSound"
		sound.SoundId = if soundDef then soundDef.id else ""
		sound.Volume = if soundDef then soundDef.volume else 0.5
		sound.Looped = true
		sound.RollOffMaxDistance = 120
		sound.RollOffMinDistance = 8
		sound.Parent = chassis
	end

	return chassis
end

local function makeBodyRoot(chassis: BasePart): Part
	local bodyRoot = Instance.new("Part")
	bodyRoot.Name = "BodyRoot"
	bodyRoot.Size = Vector3.new(1, 1, 1)
	bodyRoot.CFrame = chassis.CFrame
	bodyRoot.Transparency = 1
	bodyRoot.Massless = true
	bodyRoot.CanCollide = false
	bodyRoot.CanQuery = false
	bodyRoot.CanTouch = false
	bodyRoot.CastShadow = false
	bodyRoot.Anchored = false
	bodyRoot.CollisionGroup = VehicleBuilder.COLLISION_GROUP
	local motor = Instance.new("Motor6D")
	motor.Name = "BodyMotor"
	motor.Part0 = chassis
	motor.Part1 = bodyRoot
	motor.C0 = CFrame.new()
	motor.C1 = CFrame.new()
	motor.Parent = bodyRoot
	return bodyRoot
end

local function makeSeat(def: VehicleDefinitions.VehicleDefinition, chassis: BasePart, bodyRoot: BasePart): VehicleSeat
	local seat = Instance.new("VehicleSeat")
	seat.Name = "Seat"
	local twoWheeler = def.id == "Bicycle" or def.id == "Scooter"
	seat.Size = if twoWheeler then Vector3.new(1.4, 0.4, 1.4) else Vector3.new(2, 0.5, 2)
	seat.CFrame = chassis.CFrame * CFrame.new(vec(def.seatOffset))
	seat.Transparency = 1
	seat.Disabled = true
	seat.MaxSpeed = 0
	seat.Torque = 0
	seat.TurnSpeed = 0
	seat.HeadsUpDisplay = false
	seat.Massless = true
	seat.CanCollide = false
	seat.CanQuery = false
	seat.CanTouch = false
	seat.CastShadow = false
	seat.Anchored = false
	seat.CollisionGroup = VehicleBuilder.COLLISION_GROUP
	weldTo(bodyRoot, seat)
	return seat
end

--[[
	Builds a drivable vehicle model. colors = { Primary = {r,g,b}, Accent = {r,g,b}, Decal = {r,g,b} }
	(missing entries fall back to the definition defaults). The model has no Parent; VehicleService
	pivots it into place, parents it under Workspace.Runtime.Vehicles and manages its state.
]]
function VehicleBuilder.build(vehicleId: string, ownerUserId: number, colors: Colors?): Model
	local def = getDefinition(vehicleId)
	ensureCollisionGroup(VehicleBuilder.COLLISION_GROUP)
	local palette = resolveColors(def, colors)

	local model = Instance.new("Model")
	model.Name = "Vehicle"

	local chassis = makeChassis(def)
	chassis.Parent = model
	model.PrimaryPart = chassis

	local bodyRoot = makeBodyRoot(chassis)
	bodyRoot.Parent = model

	local seat = makeSeat(def, chassis, bodyRoot)
	seat.Parent = model

	local bodyFolder = Instance.new("Folder")
	bodyFolder.Name = "Body"
	for _, spec in ipairs(def.visual.parts) do
		local part = makeVisualPart(spec, palette, chassis.CFrame)
		part.CollisionGroup = VehicleBuilder.COLLISION_GROUP
		part.Anchored = false
		weldTo(bodyRoot, part)
		part.Parent = bodyFolder
	end
	bodyFolder.Parent = model

	local wheelFolder = Instance.new("Folder")
	wheelFolder.Name = "Wheels"
	for _, spec in ipairs(def.visual.wheels) do
		local wheel = makeWheelPart(spec, chassis.CFrame)
		wheel.CollisionGroup = VehicleBuilder.COLLISION_GROUP
		wheel.Anchored = false
		local motor = Instance.new("Motor6D")
		motor.Name = "WheelMotor"
		motor.Part0 = bodyRoot
		motor.Part1 = wheel
		motor.C0 = CFrame.new(vec(spec.offset))
		motor.C1 = CFrame.new()
		motor.Parent = wheel
		wheel.Parent = wheelFolder
	end
	wheelFolder.Parent = model

	local cargoFolder = Instance.new("Folder")
	cargoFolder.Name = "Cargo"
	cargoFolder.Parent = model

	model:SetAttribute("OwnerUserId", ownerUserId)
	model:SetAttribute("VehicleId", vehicleId)
	model:SetAttribute("State", "Parked")
	model:SetAttribute("Capacity", def.baseCapacity)
	CollectionService:AddTag(model, VehicleBuilder.TAG)
	return model
end

-- Recolours every part carrying a PaintSlot attribute from the colour table.
function VehicleBuilder.applyCosmetics(model: Model, colors: Colors?)
	if not colors then
		return
	end
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			local slot = descendant:GetAttribute("PaintSlot")
			if type(slot) == "string" then
				local color = (colors :: any)[slot]
				if type(color) == "table" and #color >= 3 then
					descendant.Color = rgb(color)
				end
			end
		end
	end
end

-- Cargo slot offset (relative to the chassis) for the 1-based slot index.
-- column = (i-1) % columns, row = floor((i-1)/columns) % rows, layer = floor((i-1)/(columns*rows)).
function VehicleBuilder.getSlotCFrame(vehicleId: string, slotIndex: number): CFrame
	local def = getDefinition(vehicleId)
	local layout = def.cargoLayout
	local i = math.max(0, math.floor(slotIndex) - 1)
	local columns = math.max(1, layout.columns)
	local rows = math.max(1, layout.rows)
	local column = i % columns
	local row = math.floor(i / columns) % rows
	local layer = math.floor(i / (columns * rows))
	local base = def.cargoOffset
	return CFrame.new(
		base[1] + column * layout.spacingX,
		base[2] + row * layout.spacingY,
		base[3] + layer * layout.spacingZ
	)
end

-- Number of distinct slots before layers start repeating positions (columns * rows per layer).
function VehicleBuilder.getSlotsPerLayer(vehicleId: string): number
	local def = getDefinition(vehicleId)
	return math.max(1, def.cargoLayout.columns) * math.max(1, def.cargoLayout.rows)
end

--[[
	Cosmetic-only copy for shop previews and depot displays: Chassis (invisible, PrimaryPart) plus
	Body and Wheels parts, all anchored, no constraints, motors, seat or attributes that would make
	VehicleService treat it as a real vehicle. Pivot it with Model:PivotTo (the pivot is the chassis
	centre, handling.rideHeight above the ground).
]]
function VehicleBuilder.buildDisplay(vehicleId: string, colors: Colors?): Model
	local def = getDefinition(vehicleId)
	local palette = resolveColors(def, colors)

	local model = Instance.new("Model")
	model.Name = "VehicleDisplay"
	model:SetAttribute("VehicleId", vehicleId)
	model:SetAttribute("Display", true)

	local chassis = Instance.new("Part")
	chassis.Name = "Chassis"
	chassis.Size = vec(def.chassisSize)
	chassis.CFrame = CFrame.new(0, def.handling.rideHeight, 0)
	chassis.Transparency = 1
	chassis.Anchored = true
	chassis.CanCollide = false
	chassis.CanQuery = false
	chassis.CanTouch = false
	chassis.CastShadow = false
	chassis.Parent = model
	model.PrimaryPart = chassis

	local bodyFolder = Instance.new("Folder")
	bodyFolder.Name = "Body"
	for _, spec in ipairs(def.visual.parts) do
		local part = makeVisualPart(spec, palette, chassis.CFrame)
		part.Anchored = true
		part.Massless = false
		part.Parent = bodyFolder
	end
	bodyFolder.Parent = model

	local wheelFolder = Instance.new("Folder")
	wheelFolder.Name = "Wheels"
	for _, spec in ipairs(def.visual.wheels) do
		local wheel = makeWheelPart(spec, chassis.CFrame)
		wheel.Anchored = true
		wheel.Massless = false
		wheel.Parent = wheelFolder
	end
	wheelFolder.Parent = model

	return model
end

-- Ride height of the vehicle (distance from the chassis centre to the ground); handy for placing displays.
function VehicleBuilder.getRideHeight(vehicleId: string): number
	return getDefinition(vehicleId).handling.rideHeight
end

return VehicleBuilder
