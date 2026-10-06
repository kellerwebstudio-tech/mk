--!strict
-- PackageBuilder: visible delivery packages (bags, pizza boxes, parcels) that are welded to the
-- courier's vehicle cargo slots or to the character's back. OrderService owns the models
-- (packageModels[orderId]) and sets the OrderId attribute.
--
-- Model "Package" (PrimaryPart Root; attributes OrderId, PackageKey; tag "Package")
--   Root   (box sized per OrderDefinitions.PackageVisuals, label SurfaceGui)
--   Strap / Lid (accent-coloured detail welded to Root)
--   AttachWeld (WeldConstraint created by attachToVehicle/attachToCharacter, destroyed by detach)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local PhysicsService = game:GetService("PhysicsService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Definitions = Shared:WaitForChild("Definitions")
local OrderDefinitions = require(Definitions:WaitForChild("OrderDefinitions"))
local VehicleBuilder = require(script.Parent:WaitForChild("VehicleBuilder"))

local PackageBuilder = {}

export type RGB = { number }
export type PackageStyle = { color: RGB?, accent: RGB? }

PackageBuilder.COLLISION_GROUP = "Packages"
PackageBuilder.TAG = "Package"
PackageBuilder.WELD_NAME = "AttachWeld"
PackageBuilder.CHARACTER_STACK_SPACING = 0.1 -- gap between packages stacked on the back

local function rgb(c: RGB): Color3
	return Color3.fromRGB(c[1], c[2], c[3])
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

local function makePart(name: string, size: Vector3, color: Color3, material: Enum.Material): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Material = material
	part.Massless = true
	part.Anchored = false
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = size.Magnitude >= 1
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.CollisionGroup = PackageBuilder.COLLISION_GROUP
	return part
end

local function addLabel(root: BasePart, face: Enum.NormalId, text: string, color: Color3)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Label"
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 60
	gui.LightInfluence = 0.8
	gui.Parent = root
	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.Size = UDim2.fromScale(0.9, 0.6)
	label.Position = UDim2.fromScale(0.05, 0.2)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = color
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.Parent = gui
end

local function findWeld(model: Model): WeldConstraint?
	local root = model.PrimaryPart
	if not root then
		return nil
	end
	local weld = root:FindFirstChild(PackageBuilder.WELD_NAME)
	if weld and weld:IsA("WeldConstraint") then
		return weld
	end
	return nil
end

local function weldRoot(model: Model, host: BasePart)
	local root = model.PrimaryPart
	assert(root, "Package model has no PrimaryPart")
	local existing = findWeld(model)
	if existing then
		existing:Destroy()
	end
	local weld = Instance.new("WeldConstraint")
	weld.Name = PackageBuilder.WELD_NAME
	weld.Part0 = host
	weld.Part1 = root
	weld.Parent = root
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = false
		end
	end
end

--[[
	Builds a package model for the given package key ("FoodBag" | "PizzaBox" | "DrinkCarrier" |
	"GroceryBag" | "Parcel"). style = { color = {r,g,b}?, accent = {r,g,b}? } from the equipped
	BagStyle cosmetic (CosmeticDefinitions data). The model has no Parent until attached.
]]
function PackageBuilder.build(packageKey: string, style: PackageStyle?): Model
	ensureCollisionGroup(PackageBuilder.COLLISION_GROUP)
	local visuals = (OrderDefinitions.PackageVisuals :: any)[packageKey] or OrderDefinitions.PackageVisuals.FoodBag
	local baseColor = if style and style.color then rgb(style.color) else rgb(visuals.color)
	local accentColor = if style and style.accent then rgb(style.accent) else rgb(visuals.accent)
	local size = Vector3.new(visuals.size[1], visuals.size[2], visuals.size[3])

	local model = Instance.new("Model")
	model.Name = "Package"
	model:SetAttribute("PackageKey", packageKey)
	model:SetAttribute("OrderId", "")

	local root = makePart("Root", size, baseColor, materialFrom(visuals.material))
	root.CFrame = CFrame.new(0, size.Y / 2, 0)
	root.Parent = model
	model.PrimaryPart = root

	local flat = size.Y < 0.5
	if flat then
		-- Pizza box style: a thin lid band on top in the accent colour, label on the lid.
		local lid = makePart("Lid", Vector3.new(size.X * 0.92, 0.06, size.Z * 0.92), accentColor, Enum.Material.SmoothPlastic)
		lid.CFrame = root.CFrame * CFrame.new(0, size.Y / 2 + 0.03, 0)
		lid.Parent = model
		local weld = Instance.new("WeldConstraint")
		weld.Name = "DetailWeld"
		weld.Part0 = root
		weld.Part1 = lid
		weld.Parent = lid
		addLabel(root, Enum.NormalId.Front, visuals.label, accentColor)
	else
		-- Bag/parcel style: a strap wrapped around the middle, label on the front face.
		local strap = makePart("Strap", Vector3.new(size.X + 0.06, size.Y * 0.28, size.Z + 0.06), accentColor, Enum.Material.Fabric)
		strap.CFrame = root.CFrame
		strap.Parent = model
		local weld = Instance.new("WeldConstraint")
		weld.Name = "DetailWeld"
		weld.Part0 = root
		weld.Part1 = strap
		weld.Parent = strap
		addLabel(root, Enum.NormalId.Front, visuals.label, accentColor)
	end

	CollectionService:AddTag(model, PackageBuilder.TAG)
	return model
end

-- Welds the package into cargo slot `slotIndex` (1-based) of the vehicle record.
function PackageBuilder.attachToVehicle(model: Model, record: any, slotIndex: number)
	local chassis: BasePart = record.chassis
	local root = model.PrimaryPart
	assert(root, "Package model has no PrimaryPart")
	root.CFrame = chassis.CFrame * VehicleBuilder.getSlotCFrame(record.vehicleId, slotIndex)
	weldRoot(model, chassis)
	local vehicleModel: Model = record.model
	local cargo = vehicleModel:FindFirstChild("Cargo")
	model.Parent = cargo or vehicleModel
end

-- Welds the package onto the character's back (UpperTorso, Torso or HumanoidRootPart), stacking up.
function PackageBuilder.attachToCharacter(model: Model, character: Model, slotIndex: number)
	local torso = character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso") or character:FindFirstChild("HumanoidRootPart")
	assert(torso and torso:IsA("BasePart"), "Character has no torso part")
	local host = torso :: BasePart
	local root = model.PrimaryPart
	assert(root, "Package model has no PrimaryPart")
	local index = math.max(1, math.floor(slotIndex))
	local lift = (index - 1) * (root.Size.Y + PackageBuilder.CHARACTER_STACK_SPACING)
	local backOffset = host.Size.Z / 2 + root.Size.Z / 2 + 0.1
	root.CFrame = host.CFrame * CFrame.new(0, -host.Size.Y / 2 + root.Size.Y / 2 + lift, backOffset)
	weldRoot(model, host)
	model.Parent = character
end

-- Removes the attachment weld and takes the model out of the world (kept for re-attachment).
function PackageBuilder.detach(model: Model)
	local weld = findWeld(model)
	if weld then
		weld:Destroy()
	end
	model.Parent = nil
end

function PackageBuilder.destroy(model: Model)
	local weld = findWeld(model)
	if weld then
		weld:Destroy()
	end
	model:Destroy()
end

return PackageBuilder
