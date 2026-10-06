--!strict
-- Cosmetics are purely visual. Slots: BikeColor, ScooterSkin, VanPaint, VanDecal, BagStyle, Uniform, DepotSign, DepotDecor.
-- Each slot has a default item that every player owns. Prices are Cash; paid variants are granted via MonetizationConfig.

export type CosmeticDefinition = {
	id: string,
	slot: string,
	name: string,
	price: number,
	repRequired: number,
	default: boolean?,
	paidOnly: boolean?,
	data: { [string]: any },
	order: number,
}

local CosmeticDefinitions = {}

CosmeticDefinitions.Slots = { "BikeColor", "ScooterSkin", "VanPaint", "VanDecal", "BagStyle", "Uniform", "DepotSign", "DepotDecor" }

CosmeticDefinitions.SlotLabels = {
	BikeColor = "Bicycle colour",
	ScooterSkin = "Scooter skin",
	VanPaint = "Van paint",
	VanDecal = "Van decal",
	BagStyle = "Delivery bag",
	Uniform = "Courier uniform",
	DepotSign = "Depot sign",
	DepotDecor = "Depot decoration",
}

CosmeticDefinitions.Items = {
	-- Bicycle colours (Primary / Accent)
	{ id = "BikeColor_Red", slot = "BikeColor", name = "Dash Red", price = 0, repRequired = 0, default = true, data = { Primary = { 226, 76, 60 }, Accent = { 240, 230, 200 } }, order = 1 },
	{ id = "BikeColor_Mint", slot = "BikeColor", name = "Mint Cruiser", price = 150, repRequired = 0, data = { Primary = { 120, 210, 180 }, Accent = { 250, 250, 245 } }, order = 2 },
	{ id = "BikeColor_Midnight", slot = "BikeColor", name = "Midnight", price = 300, repRequired = 30, data = { Primary = { 40, 45, 70 }, Accent = { 230, 200, 90 } }, order = 3 },
	{ id = "BikeColor_Sunset", slot = "BikeColor", name = "Sunset", price = 450, repRequired = 80, data = { Primary = { 250, 140, 60 }, Accent = { 120, 40, 80 } }, order = 4 },
	{ id = "BikeColor_Neon", slot = "BikeColor", name = "Neon Pulse", price = 0, repRequired = 0, paidOnly = true, data = { Primary = { 80, 255, 120 }, Accent = { 255, 80, 220 } }, order = 5 },

	-- Scooter skins
	{ id = "ScooterSkin_Sky", slot = "ScooterSkin", name = "Sky Blue", price = 0, repRequired = 0, default = true, data = { Primary = { 64, 160, 220 }, Accent = { 245, 245, 240 } }, order = 1 },
	{ id = "ScooterSkin_Cream", slot = "ScooterSkin", name = "Vintage Cream", price = 600, repRequired = 150, data = { Primary = { 245, 230, 190 }, Accent = { 120, 70, 50 } }, order = 2 },
	{ id = "ScooterSkin_Cherry", slot = "ScooterSkin", name = "Cherry Bomb", price = 900, repRequired = 200, data = { Primary = { 200, 40, 60 }, Accent = { 30, 30, 30 } }, order = 3 },
	{ id = "ScooterSkin_Neon", slot = "ScooterSkin", name = "Neon Pulse", price = 0, repRequired = 0, paidOnly = true, data = { Primary = { 255, 80, 220 }, Accent = { 80, 255, 120 } }, order = 4 },

	-- Van paint and decals
	{ id = "VanPaint_White", slot = "VanPaint", name = "Fleet White", price = 0, repRequired = 0, default = true, data = { Primary = { 245, 245, 245 }, Accent = { 226, 76, 60 } }, order = 1 },
	{ id = "VanPaint_Navy", slot = "VanPaint", name = "Navy Pro", price = 1500, repRequired = 600, data = { Primary = { 35, 55, 110 }, Accent = { 240, 200, 60 } }, order = 2 },
	{ id = "VanPaint_Forest", slot = "VanPaint", name = "Forest", price = 1800, repRequired = 700, data = { Primary = { 50, 110, 70 }, Accent = { 230, 230, 220 } }, order = 3 },
	{ id = "VanPaint_Neon", slot = "VanPaint", name = "Neon Pulse", price = 0, repRequired = 0, paidOnly = true, data = { Primary = { 30, 30, 40 }, Accent = { 80, 255, 120 } }, order = 4 },
	{ id = "VanDecal_Plain", slot = "VanDecal", name = "No decal", price = 0, repRequired = 0, default = true, data = { Decal = { 245, 245, 245 } }, order = 1 },
	{ id = "VanDecal_Stripe", slot = "VanDecal", name = "Blue Stripe", price = 500, repRequired = 600, data = { Decal = { 40, 90, 180 } }, order = 2 },
	{ id = "VanDecal_Gold", slot = "VanDecal", name = "Gold Badge", price = 2500, repRequired = 900, data = { Decal = { 230, 190, 70 } }, order = 3 },

	-- Delivery bag styles
	{ id = "Bag_Classic", slot = "BagStyle", name = "Classic", price = 0, repRequired = 0, default = true, data = { color = { 215, 170, 110 }, accent = { 160, 110, 60 } }, order = 1 },
	{ id = "Bag_Teal", slot = "BagStyle", name = "Teal Insulated", price = 300, repRequired = 50, data = { color = { 60, 160, 160 }, accent = { 240, 240, 240 } }, order = 2 },
	{ id = "Bag_Black", slot = "BagStyle", name = "Stealth", price = 600, repRequired = 120, data = { color = { 35, 35, 40 }, accent = { 200, 60, 60 } }, order = 3 },
	{ id = "Bag_Deluxe", slot = "BagStyle", name = "Deluxe", price = 0, repRequired = 0, paidOnly = true, data = { color = { 240, 200, 80 }, accent = { 60, 40, 20 } }, order = 4 },

	-- Courier uniforms (vest colour)
	{ id = "Uniform_Orange", slot = "Uniform", name = "Dash Orange", price = 0, repRequired = 0, default = true, data = { vest = { 250, 140, 40 }, trim = { 255, 255, 255 } }, order = 1 },
	{ id = "Uniform_Blue", slot = "Uniform", name = "Courier Blue", price = 250, repRequired = 20, data = { vest = { 50, 110, 200 }, trim = { 255, 255, 255 } }, order = 2 },
	{ id = "Uniform_Green", slot = "Uniform", name = "Eco Green", price = 400, repRequired = 80, data = { vest = { 60, 160, 90 }, trim = { 240, 240, 200 } }, order = 3 },
	{ id = "Uniform_Elite", slot = "Uniform", name = "Elite Black", price = 0, repRequired = 0, paidOnly = true, data = { vest = { 25, 25, 30 }, trim = { 240, 200, 80 } }, order = 4 },

	-- Depot signs and decorations
	{ id = "DepotSign_Classic", slot = "DepotSign", name = "Classic Sign", price = 0, repRequired = 0, default = true, data = { color = { 240, 240, 240 }, text = { 30, 30, 30 } }, order = 1 },
	{ id = "DepotSign_Bold", slot = "DepotSign", name = "Bold Sign", price = 1200, repRequired = 1000, data = { color = { 226, 76, 60 }, text = { 255, 255, 255 } }, order = 2 },
	{ id = "DepotSign_Neon", slot = "DepotSign", name = "Neon Sign", price = 0, repRequired = 0, paidOnly = true, data = { color = { 30, 30, 40 }, text = { 80, 255, 200 }, neon = true }, order = 3 },
	{ id = "DepotDecor_None", slot = "DepotDecor", name = "Plain yard", price = 0, repRequired = 0, default = true, data = { style = "None" }, order = 1 },
	{ id = "DepotDecor_Planters", slot = "DepotDecor", name = "Planters & flags", price = 1500, repRequired = 1000, data = { style = "Planters" }, order = 2 },
	{ id = "DepotDecor_Lights", slot = "DepotDecor", name = "String lights", price = 0, repRequired = 0, paidOnly = true, data = { style = "Lights" }, order = 3 },
} :: { CosmeticDefinition }

CosmeticDefinitions.ById = {} :: { [string]: CosmeticDefinition }
CosmeticDefinitions.Defaults = {} :: { [string]: string }
for _, item in ipairs(CosmeticDefinitions.Items) do
	CosmeticDefinitions.ById[item.id] = item
	if item.default then
		CosmeticDefinitions.Defaults[item.slot] = item.id
	end
end

function CosmeticDefinitions.get(id: string): CosmeticDefinition?
	return CosmeticDefinitions.ById[id]
end

function CosmeticDefinitions.itemsForSlot(slot: string): { CosmeticDefinition }
	local result = {}
	for _, item in ipairs(CosmeticDefinitions.Items) do
		if item.slot == slot then
			table.insert(result, item)
		end
	end
	table.sort(result, function(a, b)
		return a.order < b.order
	end)
	return result
end

-- Resolves the paint colours for a vehicle from the equipped cosmetics table (slot -> cosmeticId).
function CosmeticDefinitions.vehicleColors(vehicleId: string, equipped: { [string]: string }?, defaults: { Primary: { number }, Accent: { number }, Decal: { number } }): { Primary: { number }, Accent: { number }, Decal: { number } }
	local colors = { Primary = defaults.Primary, Accent = defaults.Accent, Decal = defaults.Decal }
	if not equipped then
		return colors
	end
	local paintSlot = if vehicleId == "Bicycle" then "BikeColor" elseif vehicleId == "Scooter" then "ScooterSkin" else "VanPaint"
	local paint = CosmeticDefinitions.ById[equipped[paintSlot] or ""]
	if paint then
		colors.Primary = paint.data.Primary or colors.Primary
		colors.Accent = paint.data.Accent or colors.Accent
	end
	if vehicleId == "Van" then
		local decal = CosmeticDefinitions.ById[equipped.VanDecal or ""]
		if decal and decal.data.Decal then
			colors.Decal = decal.data.Decal
		end
	end
	return colors
end

return CosmeticDefinitions
