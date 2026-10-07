--!nonstrict
-- CosmeticsController: resolves the player's vehicle paint from the profile and builds
-- cosmetic-only display vehicles for shop previews (ViewportFrames) on the client. The display
-- builder mirrors the visual part of the server VehicleBuilder (same shapes, offsets and the
-- CFrame.new(offset) * CFrame.Angles(rad x, rad y, rad z) rotation convention); no constraints,
-- all parts anchored.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Definitions = Shared:WaitForChild("Definitions")
local Config = Shared:WaitForChild("Config")
local VehicleDefinitions = require(Definitions:WaitForChild("VehicleDefinitions"))
local CosmeticDefinitions = require(Definitions:WaitForChild("CosmeticDefinitions"))
local MeshAssets = require(Config:WaitForChild("MeshAssets"))

local CosmeticsController = {}

CosmeticsController.SMALL_PART_SIZE = 1
-- Mesh vehicles: the server publishes a cosmetic copy under
-- ReplicatedStorage.SharedAssets.VehicleDisplays.<VehicleId> (clients cannot create MeshParts from
-- ids). How long BuildDisplayVehicle waits for it before falling back to the generated preview.
-- For an embedded vehicle (MeshAssets.isEmbedded) the published display holds the invisible
-- "MeshBody" placeholder (tag "EmbeddedMeshBody"); the clone keeps the tag, so
-- EmbeddedMeshController dresses it with the rebuilt mesh as soon as the preview is parented
-- (or when the mesh finishes decoding: it re-dresses every tagged placeholder on Loaded).
CosmeticsController.DISPLAYS_FOLDER = "VehicleDisplays"
CosmeticsController.DISPLAY_WAIT = 1

export type RGB = { number }
export type Colors = { Primary: RGB, Accent: RGB, Decal: RGB }

local ctx = nil

local function rgb(c: RGB): Color3
	return Color3.fromRGB(c[1], c[2], c[3])
end

local function vec(t: { number }): Vector3
	return Vector3.new(t[1], t[2], t[3])
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

-- Paint colours for a vehicle from the profile's equipped cosmetics (defaults when unknown).
function CosmeticsController.GetVehicleColors(vehicleId: string, profileOverride: any?): Colors
	local def = VehicleDefinitions.get(vehicleId) or VehicleDefinitions.Vehicles.Bicycle
	local profile = profileOverride or (ctx and ctx.state.get("profile")) or nil
	local equipped = profile and type(profile.cosmetics) == "table" and profile.cosmetics.equipped or nil
	return CosmeticDefinitions.vehicleColors(def.id, equipped, def.defaultColors)
end

-- Colours for the equipped delivery bag / uniform (for UI previews).
function CosmeticsController.GetEquippedCosmetic(slot: string): any?
	local profile = ctx and ctx.state.get("profile") or nil
	local equipped = profile and type(profile.cosmetics) == "table" and profile.cosmetics.equipped or nil
	local id = equipped and equipped[slot] or CosmeticDefinitions.Defaults[slot]
	return id and CosmeticDefinitions.get(id) or nil
end

local function makeVisualPart(spec: any, palette: { [string]: Color3 }, chassisCFrame: CFrame): BasePart
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
	if type(spec.color) == "string" then
		part.Color = palette[spec.color] or Color3.fromRGB(255, 255, 255)
		part:SetAttribute("PaintSlot", spec.color)
	else
		part.Color = rgb(spec.color)
	end
	part.Material = materialFrom(spec.material)
	part.Transparency = spec.transparency or 0
	part.Reflectance = spec.reflectance or 0
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	local largest = math.max(spec.size[1], spec.size[2], spec.size[3])
	part.CastShadow = largest >= CosmeticsController.SMALL_PART_SIZE
	return part
end

local function makeWheelPart(spec: any, chassisCFrame: CFrame): Part
	local wheel = Instance.new("Part")
	wheel.Name = spec.name
	wheel.Shape = Enum.PartType.Cylinder
	wheel.Size = Vector3.new(spec.width, spec.radius * 2, spec.radius * 2)
	wheel.CFrame = chassisCFrame * CFrame.new(vec(spec.offset))
	wheel.Color = if spec.color then rgb(spec.color) else Color3.fromRGB(28, 28, 30)
	wheel.Material = Enum.Material.Rubber
	wheel.Anchored = true
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

--[[
	Builds a cosmetic-only vehicle (Chassis as invisible PrimaryPart + Body + Wheels folders),
	anchored, no constraints, and parents it to `parent` (a ViewportFrame/WorldModel or nil).
	`colors` overrides the profile paint. The pivot is the chassis centre, rideHeight above y = 0.
]]
-- The server-published display template for a mesh vehicle, or nil (not a mesh vehicle, not
-- published yet after DISPLAY_WAIT seconds, or the server fell back to generated parts).
local function findPublishedDisplay(vehicleId: string): Model?
	if not MeshAssets.usesCustomMesh(vehicleId) then
		return nil
	end
	local sharedAssets = ReplicatedStorage:FindFirstChild("SharedAssets")
	if not sharedAssets then
		return nil
	end
	local displays = sharedAssets:FindFirstChild(CosmeticsController.DISPLAYS_FOLDER)
		or sharedAssets:WaitForChild(CosmeticsController.DISPLAYS_FOLDER, CosmeticsController.DISPLAY_WAIT)
	if not displays then
		return nil
	end
	local template = displays:FindFirstChild(vehicleId) or displays:WaitForChild(vehicleId, CosmeticsController.DISPLAY_WAIT)
	if template and template:IsA("Model") then
		return template
	end
	return nil
end

function CosmeticsController.BuildDisplayVehicle(vehicleId: string, parent: Instance?, colors: Colors?): Model
	local def = VehicleDefinitions.get(vehicleId) or VehicleDefinitions.Vehicles.Bicycle
	local resolved = colors or CosmeticsController.GetVehicleColors(def.id)

	-- Mesh vehicle: clone the server's display (texture carries the look; PaintSlot parts, if any,
	-- still get the player's colours).
	local published = findPublishedDisplay(def.id)
	if published then
		local clone = published:Clone()
		clone.Name = "VehicleDisplay"
		clone:SetAttribute("VehicleId", def.id)
		clone:SetAttribute("Display", true)
		for _, part in ipairs(clone:GetDescendants()) do
			if part:IsA("BasePart") then
				part.Anchored = true
				part.CanCollide = false
			end
		end
		-- Embedded vehicle: drop any mesh a previous dressing left on the template (the controller
		-- attaches a fresh clone for this preview once it is parented).
		for _, part in ipairs(clone:GetDescendants()) do
			if part.Name == "EmbeddedMesh" and part.Parent and part.Parent.Name == "MeshBody" then
				part:Destroy()
			end
		end
		CosmeticsController.ApplyColors(clone, resolved)
		if parent then
			clone.Parent = parent
		end
		return clone
	end

	local palette = {
		Primary = rgb(resolved.Primary or def.defaultColors.Primary),
		Accent = rgb(resolved.Accent or def.defaultColors.Accent),
		Decal = rgb(resolved.Decal or def.defaultColors.Decal),
	}

	local model = Instance.new("Model")
	model.Name = "VehicleDisplay"
	model:SetAttribute("VehicleId", def.id)
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
		part.Parent = bodyFolder
	end
	bodyFolder.Parent = model

	local wheelFolder = Instance.new("Folder")
	wheelFolder.Name = "Wheels"
	for _, spec in ipairs(def.visual.wheels) do
		local wheel = makeWheelPart(spec, chassis.CFrame)
		wheel.Parent = wheelFolder
	end
	wheelFolder.Parent = model

	if parent then
		model.Parent = parent
	end
	return model
end

-- Recolours PaintSlot parts of a display (or any) vehicle model.
function CosmeticsController.ApplyColors(model: Model, colors: Colors)
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") and not descendant:IsA("MeshPart") then
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

-- Extents of a display model (for framing a ViewportFrame camera).
function CosmeticsController.GetDisplayRadius(vehicleId: string): number
	local def = VehicleDefinitions.get(vehicleId) or VehicleDefinitions.Vehicles.Bicycle
	local mesh = def.mesh
	if mesh and MeshAssets.usesCustomMesh(def.id) then
		-- Mesh body (uploaded or embedded): its bounding box (plus offset) bounds the whole vehicle.
		local size = mesh.body.size
		return vec(mesh.body.offset).Magnitude + math.max(size[1], size[2], size[3]) * 0.75
	end
	local size = def.chassisSize
	local radius = math.max(size[1], size[3]) * 0.75
	for _, spec in ipairs(def.visual.parts) do
		local reach = vec(spec.offset).Magnitude + math.max(spec.size[1], spec.size[2], spec.size[3]) / 2
		radius = math.max(radius, reach)
	end
	return radius
end

function CosmeticsController.Init(context)
	ctx = context
end

function CosmeticsController.Start()
	-- Purely on demand; nothing to run.
end

return CosmeticsController
