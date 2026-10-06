--!strict
-- Purchasable equipment upgrades. Effects are applied by ProgressionService.

export type UpgradeDefinition = {
	id: string,
	name: string,
	description: string,
	price: number,
	repRequired: number,
	requiresUpgrade: string?,
	requiresVehicle: string?,
	effect: {
		capacityBonus: { vehicle: string, amount: number }?,
		tipBonus: number?,
		speedBonus: { vehicle: string, amount: number }?,
	},
	order: number,
	category: string, -- "Bag" | "Capacity" | "Performance"
}

local UpgradeDefinitions = {}

UpgradeDefinitions.Order = {
	"BasketI", "BasketII", "ThermalBagI", "ThermalBagII", "TunedGears",
	"ScooterTopBoxI", "ScooterTopBoxII", "VanShelvingI", "VanShelvingII",
}

UpgradeDefinitions.Upgrades = {
	BasketI = {
		id = "BasketI", name = "Basket I", description = "A sturdier front basket. Bicycle capacity +1.",
		price = 75, repRequired = 0, effect = { capacityBonus = { vehicle = "Bicycle", amount = 1 } }, order = 1, category = "Capacity",
	},
	BasketII = {
		id = "BasketII", name = "Basket II", description = "Rear panniers. Bicycle capacity +1.",
		price = 350, repRequired = 60, requiresUpgrade = "BasketI", effect = { capacityBonus = { vehicle = "Bicycle", amount = 1 } }, order = 2, category = "Capacity",
	},
	ThermalBagI = {
		id = "ThermalBagI", name = "Thermal Bag I", description = "Keeps food hot and drinks cold. Tips up to +15%.",
		price = 200, repRequired = 0, effect = { tipBonus = 0.15 }, order = 3, category = "Bag",
	},
	ThermalBagII = {
		id = "ThermalBagII", name = "Thermal Bag II", description = "Pro insulation. Tips up to another +15%.",
		price = 900, repRequired = 100, requiresUpgrade = "ThermalBagI", effect = { tipBonus = 0.15 }, order = 4, category = "Bag",
	},
	TunedGears = {
		id = "TunedGears", name = "Tuned Gears", description = "Smoother drivetrain. Bicycle top speed +5%.",
		price = 250, repRequired = 40, effect = { speedBonus = { vehicle = "Bicycle", amount = 0.05 } }, order = 5, category = "Performance",
	},
	ScooterTopBoxI = {
		id = "ScooterTopBoxI", name = "Scooter Top Box I", description = "Bigger top box. Scooter capacity +1.",
		price = 900, repRequired = 150, requiresVehicle = "Scooter", effect = { capacityBonus = { vehicle = "Scooter", amount = 1 } }, order = 6, category = "Capacity",
	},
	ScooterTopBoxII = {
		id = "ScooterTopBoxII", name = "Scooter Top Box II", description = "Side cases. Scooter capacity +1.",
		price = 1800, repRequired = 250, requiresUpgrade = "ScooterTopBoxI", effect = { capacityBonus = { vehicle = "Scooter", amount = 1 } }, order = 7, category = "Capacity",
	},
	VanShelvingI = {
		id = "VanShelvingI", name = "Van Shelving I", description = "Organised shelving. Van capacity +2.",
		price = 3000, repRequired = 600, requiresVehicle = "Van", effect = { capacityBonus = { vehicle = "Van", amount = 2 } }, order = 8, category = "Capacity",
	},
	VanShelvingII = {
		id = "VanShelvingII", name = "Van Shelving II", description = "Roof storage. Van capacity +2.",
		price = 5000, repRequired = 800, requiresUpgrade = "VanShelvingI", effect = { capacityBonus = { vehicle = "Van", amount = 2 } }, order = 9, category = "Capacity",
	},
} :: { [string]: UpgradeDefinition }

function UpgradeDefinitions.get(id: string): UpgradeDefinition?
	return UpgradeDefinitions.Upgrades[id]
end

return UpgradeDefinitions
