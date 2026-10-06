--!strict
-- Order sizes, item categories, package visuals keys, customer reaction lines and generation helpers.

export type SizeDef = { id: string, units: number, label: string }
export type CategoryDef = { id: string, packageKey: string, label: string }

local OrderDefinitions = {}

OrderDefinitions.Sizes = {
	Small = { id = "Small", units = 1, label = "Small" },
	Medium = { id = "Medium", units = 2, label = "Medium" },
	Large = { id = "Large", units = 4, label = "Large" },
} :: { [string]: SizeDef }

OrderDefinitions.SizeOrder = { "Small", "Medium", "Large" }

OrderDefinitions.Categories = {
	Food = { id = "Food", packageKey = "FoodBag", label = "Food" },
	Pizza = { id = "Pizza", packageKey = "PizzaBox", label = "Pizza" },
	Drinks = { id = "Drinks", packageKey = "DrinkCarrier", label = "Drinks" },
	Grocery = { id = "Grocery", packageKey = "GroceryBag", label = "Groceries" },
	Parcel = { id = "Parcel", packageKey = "Parcel", label = "Parcel" },
} :: { [string]: CategoryDef }

OrderDefinitions.PackageKeys = { "FoodBag", "PizzaBox", "DrinkCarrier", "GroceryBag", "Parcel" }

-- Visual description of each package model (used by PackageBuilder). Sizes in studs.
OrderDefinitions.PackageVisuals = {
	FoodBag = { size = { 1.1, 0.9, 0.8 }, color = { 215, 170, 110 }, material = "Fabric", accent = { 160, 110, 60 }, label = "FOOD" },
	PizzaBox = { size = { 1.5, 0.25, 1.5 }, color = { 235, 215, 180 }, material = "SmoothPlastic", accent = { 200, 60, 50 }, label = "PIZZA" },
	DrinkCarrier = { size = { 1.2, 0.7, 0.7 }, color = { 240, 240, 235 }, material = "SmoothPlastic", accent = { 90, 150, 220 }, label = "DRINKS" },
	GroceryBag = { size = { 1.2, 1.3, 0.9 }, color = { 120, 180, 110 }, material = "Fabric", accent = { 60, 120, 70 }, label = "MARKET" },
	Parcel = { size = { 1.6, 1.2, 1.3 }, color = { 190, 150, 100 }, material = "SmoothPlastic", accent = { 110, 80, 50 }, label = "FRAGILE" },
}

-- Destination kinds and the sizes they accept by default (destinations can override with `accepts`).
OrderDefinitions.KindAccepts = {
	Apartment = { Small = true, Medium = true, Large = false },
	House = { Small = true, Medium = true, Large = true },
	Shop = { Small = true, Medium = true, Large = true },
	Warehouse = { Small = false, Medium = true, Large = true },
	LoadingBay = { Small = false, Medium = true, Large = true },
}

-- Customer lines shown at the door, by item category.
OrderDefinitions.CustomerLines = {
	Food = { "Oh nice, lunch is here!", "You're a lifesaver, thanks!", "Smells amazing. Thank you!", "Right on time!" },
	Pizza = { "PIZZA! Thank you!", "The kids will be thrilled.", "Still hot? Perfect.", "Movie night is saved!" },
	Drinks = { "Coffee! You're the best.", "Ahh, exactly what I needed.", "Thanks, careful with the lids!", "Iced and ready, thank you!" },
	Grocery = { "Thanks for carrying all that!", "Groceries, finally. Thank you!", "I'll take those, cheers!", "Everything's here, great job." },
	Parcel = { "Sign here... perfect, thanks!", "Our parts arrived, nice work.", "Right to the loading bay, thank you.", "That was quick!" },
}

OrderDefinitions.LateLines = { "A bit late, but thank you.", "Took a while, huh? Thanks anyway.", "Got here in the end, appreciate it." }

-- Pickup lines shown at the counter (business-specific lines live in BusinessDefinitions).
OrderDefinitions.PickupLines = { "Order's ready, go go go!", "Here you go, ride safe.", "All packed. Thanks courier!" }

function OrderDefinitions.unitsFor(size: string): number
	local def = OrderDefinitions.Sizes[size]
	return if def then def.units else 1
end

function OrderDefinitions.packageKeyFor(category: string): string
	local def = OrderDefinitions.Categories[category]
	return if def then def.packageKey else "FoodBag"
end

function OrderDefinitions.routeKey(businessId: string, destinationId: string): string
	return businessId .. ">" .. destinationId
end

return OrderDefinitions
