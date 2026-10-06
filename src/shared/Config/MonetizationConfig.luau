--!strict
-- Monetization is DISABLED until real product / game pass IDs are configured.
-- Never invent IDs. To enable a product, create it in the Creator Dashboard and paste its ID here.
-- Everything sold here is cosmetic or a private server; core progression is always earnable through play.

export type ProductEntry = {
	id: string, -- internal key
	kind: "DeveloperProduct" | "GamePass",
	assetId: number?, -- nil = disabled
	title: string,
	grants: { cosmetics: { string }? },
}

local MonetizationConfig = {
	enabled = false, -- flipped to true automatically when at least one assetId is set

	products = {
		{ id = "SkinPack_Neon", kind = "GamePass", assetId = nil, title = "Neon Vehicle Skins", grants = { cosmetics = { "VanPaint_Neon", "ScooterSkin_Neon", "BikeColor_Neon" } } },
		{ id = "Outfit_Courier", kind = "GamePass", assetId = nil, title = "Elite Courier Outfit", grants = { cosmetics = { "Uniform_Elite" } } },
		{ id = "BagPack_Deluxe", kind = "GamePass", assetId = nil, title = "Deluxe Bag Styles", grants = { cosmetics = { "Bag_Deluxe" } } },
		{ id = "DepotTheme_Night", kind = "GamePass", assetId = nil, title = "Night Depot Theme", grants = { cosmetics = { "DepotSign_Neon", "DepotDecor_Lights" } } },
	} :: { ProductEntry },
}

for _, product in ipairs(MonetizationConfig.products) do
	if product.assetId ~= nil then
		MonetizationConfig.enabled = true
	end
end

return MonetizationConfig
