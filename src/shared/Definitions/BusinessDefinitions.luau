--!strict
-- The four original pickup businesses. Positions live in CityLayout (by id); this file holds
-- economy, items, dialogue and the delivery profile used by the order generator.

export type BusinessItem = { label: string, category: string, size: string, weight: number }
export type DeliveryProfile = {
	neighborhoods: { [string]: boolean },
	minDistance: number,
	maxDistance: number,
	kinds: { [string]: boolean }?,
}
export type BusinessDefinition = {
	id: string,
	name: string,
	shortName: string,
	type: string, -- "Pizza" | "Cafe" | "Market" | "Warehouse"
	neighborhood: string,
	repRequired: number,
	basePay: number,
	perStud: number,
	tipFraction: number,
	repPerDelivery: number,
	prepTime: { min: number, max: number },
	items: { BusinessItem },
	deliveryProfile: DeliveryProfile,
	staffName: string,
	signText: string,
	tagline: string,
	dialogue: { greeting: { string }, handoff: { string }, waiting: { string } },
	ambience: string,
	accent: { number },
	order: number,
}

local BusinessDefinitions = {}

BusinessDefinitions.Order = { "BeanAndBunCafe", "SliceStreetPizza", "FreshLaneMarket", "CrateAndCoSupply" }

BusinessDefinitions.Businesses = {
	BeanAndBunCafe = {
		id = "BeanAndBunCafe",
		name = "Bean & Bun Café",
		shortName = "Bean & Bun",
		type = "Cafe",
		neighborhood = "Downtown",
		repRequired = 0,
		basePay = 22,
		perStud = 0.10,
		tipFraction = 0.30,
		repPerDelivery = 5,
		prepTime = { min = 4, max = 9 },
		items = {
			{ label = "2 flat whites", category = "Drinks", size = "Small", weight = 5 },
			{ label = "Breakfast bun box", category = "Food", size = "Small", weight = 5 },
			{ label = "Iced latte tray", category = "Drinks", size = "Small", weight = 4 },
			{ label = "Office pastry platter", category = "Food", size = "Medium", weight = 2 },
		},
		deliveryProfile = { neighborhoods = { Downtown = true }, minDistance = 100, maxDistance = 280 },
		staffName = "Priya",
		signText = "BEAN & BUN",
		tagline = "Coffee, buns, and a very fast counter.",
		dialogue = {
			greeting = { "Morning! Your order's on the counter.", "Hey courier, grab the tray marked for you.", "Careful, the lids are loose today." },
			handoff = { "Go go go, it's getting cold!", "Ride safe!", "Tell them Priya says hi." },
			waiting = { "Almost done, steaming the milk...", "One sec, boxing the buns." },
		},
		ambience = "RestaurantAmbience",
		accent = { 150, 95, 60 },
		order = 1,
	},
	SliceStreetPizza = {
		id = "SliceStreetPizza",
		name = "Slice Street Pizza",
		shortName = "Slice Street",
		type = "Pizza",
		neighborhood = "Downtown",
		repRequired = 0,
		basePay = 28,
		perStud = 0.09,
		tipFraction = 0.30,
		repPerDelivery = 6,
		prepTime = { min = 6, max = 12 },
		items = {
			{ label = "Margherita pizza", category = "Pizza", size = "Small", weight = 5 },
			{ label = "Pepperoni pizza", category = "Pizza", size = "Small", weight = 5 },
			{ label = "2 large pizzas", category = "Pizza", size = "Medium", weight = 2 },
			{ label = "Party order (4 boxes)", category = "Pizza", size = "Large", weight = 1 },
		},
		deliveryProfile = { neighborhoods = { Downtown = true, Residential = true }, minDistance = 130, maxDistance = 440 },
		staffName = "Gio",
		signText = "SLICE STREET",
		tagline = "Hot slices, hotter couriers.",
		dialogue = {
			greeting = { "Courier! Box is on the pass, still bubbling.", "There you are. Keep it flat, yeah?", "Pizza's up. Don't tilt it!" },
			handoff = { "Thirty minutes or it's free... kidding, go!", "Keep it level, ride fast.", "Bring back the bag next time, ha." },
			waiting = { "Still in the oven, two more minutes.", "Just cutting it now." },
		},
		ambience = "RestaurantAmbience",
		accent = { 200, 60, 50 },
		order = 2,
	},
	FreshLaneMarket = {
		id = "FreshLaneMarket",
		name = "Fresh Lane Market",
		shortName = "Fresh Lane",
		type = "Market",
		neighborhood = "Residential",
		repRequired = 120,
		basePay = 35,
		perStud = 0.10,
		tipFraction = 0.25,
		repPerDelivery = 9,
		prepTime = { min = 8, max = 14 },
		items = {
			{ label = "Weekly groceries", category = "Grocery", size = "Medium", weight = 5 },
			{ label = "Fruit & veg box", category = "Grocery", size = "Small", weight = 3 },
			{ label = "Family shop (4 bags)", category = "Grocery", size = "Large", weight = 2 },
		},
		deliveryProfile = { neighborhoods = { Residential = true, Downtown = true }, minDistance = 160, maxDistance = 480, kinds = { House = true, Apartment = true, Shop = true } },
		staffName = "Marco",
		signText = "FRESH LANE",
		tagline = "Groceries to your door before the ice cream melts.",
		dialogue = {
			greeting = { "Bags are packed by the door, courier.", "Heavy one today, mind your back.", "Eggs on top. Please." },
			handoff = { "Thanks! The hill's steep, take the park path.", "Appreciate it, safe ride.", "Say hi to Maple Hill for me." },
			waiting = { "Still bagging the cold stuff.", "Nearly there, just the bread." },
		},
		ambience = "RestaurantAmbience",
		accent = { 70, 150, 90 },
		order = 3,
	},
	CrateAndCoSupply = {
		id = "CrateAndCoSupply",
		name = "Crate & Co. Supply",
		shortName = "Crate & Co.",
		type = "Warehouse",
		neighborhood = "Industrial",
		repRequired = 500,
		basePay = 60,
		perStud = 0.12,
		tipFraction = 0.20,
		repPerDelivery = 14,
		prepTime = { min = 10, max = 18 },
		items = {
			{ label = "Spare parts crate", category = "Parcel", size = "Medium", weight = 5 },
			{ label = "Pallet of supplies", category = "Parcel", size = "Large", weight = 4 },
			{ label = "Shop restock boxes", category = "Parcel", size = "Medium", weight = 3 },
		},
		deliveryProfile = { neighborhoods = { Industrial = true, Downtown = true }, minDistance = 220, maxDistance = 650, kinds = { LoadingBay = true, Warehouse = true, Shop = true } },
		staffName = "Dee",
		signText = "CRATE & CO.",
		tagline = "If it fits in a van, we ship it.",
		dialogue = {
			greeting = { "Forklift's loading your bay now.", "Manifest says it's yours. Sign and go.", "Strapped and ready, courier." },
			handoff = { "Loading bay B, don't miss the turn.", "Drive safe, those are fragile.", "Back before the whistle, yeah?" },
			waiting = { "Still on the forklift.", "Wrapping the pallet, hang on." },
		},
		ambience = "IndustrialAmbience",
		accent = { 230, 160, 40 },
		order = 4,
	},
} :: { [string]: BusinessDefinition }

function BusinessDefinitions.get(id: string): BusinessDefinition?
	return BusinessDefinitions.Businesses[id]
end

return BusinessDefinitions
