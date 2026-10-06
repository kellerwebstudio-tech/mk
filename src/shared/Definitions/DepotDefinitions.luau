--!strict
-- Depot and NPC driver economy. See docs/DESIGN.md for the model (requires playtesting).

export type DriverCategory = {
	id: string,
	name: string,
	description: string,
	duration: number, -- seconds
	revenue: number,
	cost: number, -- paid up front when assigning
	repRequired: number,
	vehicle: string,
	order: number,
}

local DepotDefinitions = {}

DepotDefinitions.price = 12000
DepotDefinitions.repRequired = 1000
DepotDefinitions.slot2Cost = 6000
DepotDefinitions.hireCost = 2500
DepotDefinitions.maxSlots = 2

DepotDefinitions.driverNames = { "Ava", "Benji", "Chloe", "Dev", "Esme", "Finn", "Gus", "Hana", "Ivo", "Juno", "Kai", "Lena", "Milo", "Nia", "Otis", "Pia" }

DepotDefinitions.CategoryOrder = { "DowntownFood", "ResidentialGrocery", "IndustrialParcel" }

DepotDefinitions.Categories = {
	DowntownFood = {
		id = "DowntownFood", name = "Downtown Food Run", description = "Café and pizza deliveries around the plaza.",
		duration = 600, revenue = 900, cost = 300, repRequired = 1000, vehicle = "Scooter", order = 1,
	},
	ResidentialGrocery = {
		id = "ResidentialGrocery", name = "Maple Hill Groceries", description = "Grocery rounds across the hill.",
		duration = 720, revenue = 1300, cost = 450, repRequired = 1200, vehicle = "Van", order = 2,
	},
	IndustrialParcel = {
		id = "IndustrialParcel", name = "Dockside Parcels", description = "Bulk parcel runs between warehouses.",
		duration = 900, revenue = 1900, cost = 700, repRequired = 1500, vehicle = "Van", order = 3,
	},
} :: { [string]: DriverCategory }

function DepotDefinitions.get(id: string): DriverCategory?
	return DepotDefinitions.Categories[id]
end

return DepotDefinitions
