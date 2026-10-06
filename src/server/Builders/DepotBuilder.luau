--!nonstrict
-- DepotBuilder: builds/refreshes an owner's depot on a depot plot (office, sign, decoration,
-- display vans + driver NPCs per hired slot) and clears it back to a FOR SALE plot.
-- Everything the builder creates lives in the plot model's "Built" folder so clear() is exact.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Definitions = Shared:WaitForChild("Definitions")
local CosmeticDefinitions = require(Definitions:WaitForChild("CosmeticDefinitions"))
local VehicleDefinitions = require(Definitions:WaitForChild("VehicleDefinitions"))
local VehicleBuilder = require(script.Parent:WaitForChild("VehicleBuilder"))
local NPCBuilder = require(script.Parent:WaitForChild("NPCBuilder"))

local DepotBuilder = {}

DepotBuilder.FOR_SALE_TEXT = "FOR SALE - Depot"
DepotBuilder.BUILT_FOLDER = "Built"
DepotBuilder.OFFICE_SIZE = Vector3.new(14, 9, 10)

local FOR_SALE_COLOR = Color3.fromRGB(240, 240, 240)
local FOR_SALE_TEXT_COLOR = Color3.fromRGB(30, 30, 30)

-- Accepts a Color3, a {r, g, b} array (0-255, as in Definitions) or a keyed { r =, g =, b = } table
-- (0-1 floats, as authored in CityLayout; values above 1 are treated as 0-255).
local function rgb(c): Color3
	if typeof(c) == "Color3" then
		return c
	end
	if type(c) ~= "table" then
		return Color3.fromRGB(200, 200, 200)
	end
	local r, g, b
	if c.r ~= nil then
		r, g, b = c.r or 0, c.g or 0, c.b or 0
		if math.max(r, g, b) > 1 then
			return Color3.fromRGB(r, g, b)
		end
		return Color3.new(r, g, b)
	end
	r, g, b = c[1] or 0, c[2] or 0, c[3] or 0
	if r % 1 ~= 0 or g % 1 ~= 0 or b % 1 ~= 0 then
		return Color3.new(math.clamp(r, 0, 1), math.clamp(g, 0, 1), math.clamp(b, 0, 1))
	end
	return Color3.fromRGB(r, g, b)
end

local function mk(props): BasePart
	local part = Instance.new(props.class or "Part")
	part.Name = props.name or "Part"
	if props.shape and part:IsA("Part") then
		part.Shape = props.shape
	end
	part.Size = props.size
	part.CFrame = props.cframe
	part.Color = props.color or Color3.fromRGB(200, 200, 196)
	part.Material = props.material or Enum.Material.SmoothPlastic
	part.Anchored = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	if props.transparency then
		part.Transparency = props.transparency
	end
	local collide = props.collide == true
	part.CanCollide = collide
	part.CanQuery = collide
	part.CanTouch = collide
	part.CastShadow = props.castShadow ~= false
	part.Parent = props.parent
	return part
end

local function builtFolder(plotWorld, create: boolean): Folder?
	local model: Model = plotWorld.model
	local folder = model:FindFirstChild(DepotBuilder.BUILT_FOLDER)
	if folder == nil and create then
		folder = Instance.new("Folder")
		folder.Name = DepotBuilder.BUILT_FOLDER
		folder.Parent = model
	end
	return folder
end

local function plotSize(plotWorld): (number, number)
	local model: Model = plotWorld.model
	local w = model:GetAttribute("PlotWidth")
	local d = model:GetAttribute("PlotDepth")
	return (if type(w) == "number" then w else 40), (if type(d) == "number" then d else 30)
end

-- Writes text/colours into every SurfaceGui label on the sign part.
local function setSign(signPart: BasePart?, text: string, signColor: Color3, textColor: Color3, neon: boolean)
	if not signPart then
		return
	end
	signPart.Color = signColor
	signPart.Material = if neon then Enum.Material.Neon else Enum.Material.SmoothPlastic
	for _, gui in ipairs(signPart:GetChildren()) do
		if gui:IsA("SurfaceGui") then
			for _, label in ipairs(gui:GetChildren()) do
				if label:IsA("TextLabel") then
					label.Text = text
					label.TextColor3 = textColor
				end
			end
		end
	end
end

local function equippedCosmetic(profile, slot: string)
	local equipped = profile and profile.cosmetics and profile.cosmetics.equipped
	local id = if equipped then equipped[slot] else nil
	local item = if id then CosmeticDefinitions.get(id) else nil
	if not item then
		local defaultId = CosmeticDefinitions.Defaults[slot]
		item = if defaultId then CosmeticDefinitions.get(defaultId) else nil
	end
	return item
end

-- Picks the office position: the candidate corner farthest from every parking spot.
local function officeFrame(plotWorld, w: number, d: number): CFrame
	local origin: CFrame = plotWorld.origin
	local size = DepotBuilder.OFFICE_SIZE
	local candidates = {
		CFrame.new(-w / 2 + size.X / 2 + 1, 0, d / 2 - size.Z / 2 - 1),
		CFrame.new(w / 2 - size.X / 2 - 1, 0, d / 2 - size.Z / 2 - 1),
		CFrame.new(0, 0, d / 2 - size.Z / 2 - 1),
		CFrame.new(-w / 2 + size.X / 2 + 1, 0, -d / 2 + size.Z / 2 + 6),
		CFrame.new(w / 2 - size.X / 2 - 1, 0, -d / 2 + size.Z / 2 + 6),
	}
	local best, bestScore = candidates[1], -math.huge
	for _, local_ in ipairs(candidates) do
		local world = origin * local_
		local score = math.huge
		for _, spot in ipairs(plotWorld.parking or {}) do
			score = math.min(score, (world.Position - spot.Position).Magnitude)
		end
		if score > bestScore then
			best, bestScore = local_, score
		end
	end
	return origin * best
end

local function buildOffice(plotWorld, folder: Folder, w: number, d: number)
	local frame = officeFrame(plotWorld, w, d)
	local size = DepotBuilder.OFFICE_SIZE
	local office = Instance.new("Model")
	office.Name = "Office"
	office.Parent = folder
	local body = mk({
		name = "Body",
		size = size,
		cframe = frame * CFrame.new(0, size.Y / 2, 0),
		color = Color3.fromRGB(196, 120, 90),
		material = Enum.Material.Brick,
		parent = office,
		collide = true,
	})
	office.PrimaryPart = body
	mk({ name = "RoofLip", size = Vector3.new(size.X + 1, 0.6, size.Z + 1), cframe = frame * CFrame.new(0, size.Y - 0.2, 0), color = Color3.fromRGB(120, 80, 60), material = Enum.Material.Concrete, parent = office })
	mk({ name = "Awning", size = Vector3.new(8, 0.3, 3), cframe = frame * CFrame.new(0, 7, -size.Z / 2 - 1.5), color = Color3.fromRGB(250, 150, 50), material = Enum.Material.Fabric, parent = office })
	mk({ name = "Door", size = Vector3.new(3.2, 6, 0.3), cframe = frame * CFrame.new(0, 3, -size.Z / 2 - 0.2), color = Color3.fromRGB(70, 45, 30), material = Enum.Material.Wood, parent = office })
	mk({ name = "Window", size = Vector3.new(size.X + 0.2, 1.6, size.Z + 0.2), cframe = frame * CFrame.new(0, 5, 0), color = Color3.fromRGB(40, 55, 70), material = Enum.Material.Glass, transparency = 0.15, parent = office })
end

local function buildDecor(plotWorld, folder: Folder, style: string, w: number, d: number)
	local origin: CFrame = plotWorld.origin
	local decor = Instance.new("Model")
	decor.Name = "Decor"
	decor.Parent = folder
	if style == "Planters" then
		for i = 0, 3 do
			local x = -w / 2 + 4 + (w - 8) * i / 3
			local frame = origin * CFrame.new(x, 0, -d / 2 + 1.5)
			mk({ name = "Planter", size = Vector3.new(4, 1.6, 2), cframe = frame * CFrame.new(0, 0.8, 0), color = Color3.fromRGB(150, 150, 145), material = Enum.Material.Concrete, parent = decor, collide = true })
			mk({ name = "PlanterGreen", size = Vector3.new(3.6, 1, 1.6), cframe = frame * CFrame.new(0, 1.9, 0), color = Color3.fromRGB(210, 90, 110), material = Enum.Material.Grass, parent = decor })
		end
		for side = -1, 1, 2 do
			local frame = origin * CFrame.new(side * (w / 2 - 2), 0, -d / 2 + 4)
			mk({ name = "FlagPole", size = Vector3.new(0.3, 14, 0.3), cframe = frame * CFrame.new(0, 7, 0), color = Color3.fromRGB(220, 220, 225), material = Enum.Material.Metal, parent = decor })
			mk({ name = "Flag", size = Vector3.new(0.1, 2.4, 4), cframe = frame * CFrame.new(0, 12.5, 2.2), color = Color3.fromRGB(250, 150, 50), material = Enum.Material.Fabric, parent = decor })
		end
	elseif style == "Lights" then
		local count = 8
		local height = 9
		for side = -1, 1, 2 do
			local frame = origin * CFrame.new(side * (w / 2 - 1.5), 0, -d / 2 + 2)
			mk({ name = "LightPole", size = Vector3.new(0.3, height, 0.3), cframe = frame * CFrame.new(0, height / 2, 0), color = Color3.fromRGB(60, 60, 65), material = Enum.Material.Metal, parent = decor })
		end
		local span = w - 3
		mk({ name = "Wire", size = Vector3.new(span, 0.08, 0.08), cframe = origin * CFrame.new(0, height - 0.2, -d / 2 + 2), color = Color3.fromRGB(30, 30, 30), material = Enum.Material.Metal, parent = decor, castShadow = false })
		for i = 1, count do
			local x = -span / 2 + span * (i - 0.5) / count
			local sag = 0.6 * math.sin(math.pi * (i - 0.5) / count)
			local bulb = mk({ name = "Bulb", shape = Enum.PartType.Ball, size = Vector3.new(0.6, 0.6, 0.6), cframe = origin * CFrame.new(x, height - 0.6 - sag, -d / 2 + 2), color = Color3.fromRGB(255, 230, 150), material = Enum.Material.Neon, parent = decor, castShadow = false })
			if i % 2 == 1 then
				local light = Instance.new("PointLight")
				light.Range = 10
				light.Brightness = 0.8
				light.Color = Color3.fromRGB(255, 230, 150)
				light.Parent = bulb
			end
		end
	end
end

local function buildSlot(plotWorld, folder: Folder, slotIndex: number, slot)
	local parking: CFrame? = plotWorld.parking[slotIndex]
	if not parking then
		return
	end
	local group = Instance.new("Model")
	group.Name = "Slot" .. slotIndex
	group:SetAttribute("Slot", slotIndex)
	group.Parent = folder

	local vanDef = VehicleDefinitions.get("Van")
	local colors = if vanDef then vanDef.defaultColors else nil
	local van = VehicleBuilder.buildDisplay("Van", colors)
	van.Name = "Van"
	van:PivotTo(parking * CFrame.new(0, VehicleBuilder.getRideHeight("Van"), 0))
	van.Parent = group

	local driver = NPCBuilder.build("Driver", slotIndex * 101, { name = slot.name })
	driver.Name = "Driver"
	-- Beside the van on the driver's side, facing the street (the parking spot's -Z).
	local standPos = (parking * CFrame.new(-5, 0, -2)).Position
	NPCBuilder.place(driver, standPos, -parking.LookVector, true)
	NPCBuilder.freeze(driver)
	driver.Parent = group
	group.PrimaryPart = van.PrimaryPart
end

--[[
	Builds or refreshes the depot on the plot for its owner.
	plotWorld: DepotPlotWorld ({ model, origin, parking, signPart, plotId })
	profile: the owner's Profile (depot.drivers + cosmetics.equipped drive the visuals)
	ownerName: display name for the sign
	ownerUserId (optional): written to the OwnerUserId attribute when given; DepotService may also
	set it itself when claiming the plot.
]]
function DepotBuilder.apply(plotWorld, profile, ownerName: string, ownerUserId: number?)
	local model: Model = plotWorld.model
	local folder = builtFolder(plotWorld, true) :: Folder
	folder:ClearAllChildren()

	local w, d = plotSize(plotWorld)
	buildOffice(plotWorld, folder, w, d)

	-- Sign cosmetics
	local signItem = equippedCosmetic(profile, "DepotSign")
	local signData = if signItem then signItem.data else nil
	local signColor = if signData and signData.color then rgb(signData.color) else FOR_SALE_COLOR
	local textColor = if signData and signData.text then rgb(signData.text) else FOR_SALE_TEXT_COLOR
	local neon = signData ~= nil and signData.neon == true
	setSign(plotWorld.signPart, ownerName .. "'s Depot", signColor, textColor, neon)

	-- Decoration cosmetics
	local decorItem = equippedCosmetic(profile, "DepotDecor")
	local decorStyle = if decorItem and decorItem.data and decorItem.data.style then decorItem.data.style else "None"
	buildDecor(plotWorld, folder, decorStyle, w, d)

	-- Hired drivers: display van + driver NPC per slot
	local drivers = if profile and profile.depot and profile.depot.drivers then profile.depot.drivers else {}
	for slotIndex, slot in ipairs(drivers) do
		if slot.hired then
			buildSlot(plotWorld, folder, slotIndex, slot)
		end
	end

	if ownerUserId ~= nil then
		model:SetAttribute("OwnerUserId", ownerUserId)
	end
	model:SetAttribute("OwnerName", ownerName)
end

-- Removes everything apply() built and resets the plot to FOR SALE.
function DepotBuilder.clear(plotWorld)
	local model: Model = plotWorld.model
	local folder = builtFolder(plotWorld, false)
	if folder then
		folder:ClearAllChildren()
	end
	setSign(plotWorld.signPart, DepotBuilder.FOR_SALE_TEXT, FOR_SALE_COLOR, FOR_SALE_TEXT_COLOR, false)
	model:SetAttribute("OwnerUserId", 0)
	model:SetAttribute("OwnerName", "")
end

-- Shows/hides the van and driver of a slot (DriverService depart/return visuals).
function DepotBuilder.setVanPresent(plotWorld, slot: number, present: boolean)
	local folder = builtFolder(plotWorld, false)
	if not folder then
		return
	end
	local group = folder:FindFirstChild("Slot" .. slot)
	if not group then
		return
	end
	group:SetAttribute("Present", present)
	for _, descendant in ipairs(group:GetDescendants()) do
		if descendant:IsA("BasePart") then
			local base = descendant:GetAttribute("BaseTransparency")
			if base == nil then
				base = descendant.Transparency
				descendant:SetAttribute("BaseTransparency", base)
			end
			descendant.Transparency = if present then base else 1
		elseif descendant:IsA("BillboardGui") or descendant:IsA("SurfaceGui") then
			descendant.Enabled = present
		elseif descendant:IsA("PointLight") then
			descendant.Enabled = present
		end
	end
end

-- True when the slot's van is currently shown (defaults to true after apply).
function DepotBuilder.isVanPresent(plotWorld, slot: number): boolean
	local folder = builtFolder(plotWorld, false)
	local group = if folder then folder:FindFirstChild("Slot" .. slot) else nil
	if not group then
		return false
	end
	local present = group:GetAttribute("Present")
	return present ~= false
end

return DepotBuilder
