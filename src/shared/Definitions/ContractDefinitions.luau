--!strict
-- Special contracts. First release: Neighborhood Lunch Rush.

export type ContractDefinition = {
	id: string,
	name: string,
	description: string,
	cooldown: number, -- seconds between the end of one rush (incl. grace) and the next opening
	window: number, -- seconds the rush stays joinable
	grace: number, -- extra seconds after the window for joined batches to finish
	offerCount: number,
	minBatch: number,
	maxBatch: number,
	bonusFraction: number, -- bonus = batch base pay sum * fraction + flatBonus
	flatBonus: number,
	repBonus: number,
	requirements: { reputation: number, deliveries: number, tutorial: boolean },
	neighborhoods: { string },
	sizes: { string },
	businessesByNeighborhood: { [string]: { string } },
}

local ContractDefinitions = {}

ContractDefinitions.LunchRush = {
	id = "LunchRush",
	name = "Neighborhood Lunch Rush",
	description = "Several compatible orders open at once in one neighborhood. Pick a batch you can carry, deliver them all before the deadline, and earn a bonus on top of normal pay.",
	cooldown = 480,
	window = 240,
	grace = 180,
	offerCount = 5,
	minBatch = 2,
	maxBatch = 4,
	bonusFraction = 0.4,
	flatBonus = 60,
	repBonus = 50,
	requirements = { reputation = 50, deliveries = 5, tutorial = true },
	neighborhoods = { "Downtown", "Residential", "Industrial" },
	sizes = { "Small", "Medium" },
	businessesByNeighborhood = {
		Downtown = { "BeanAndBunCafe", "SliceStreetPizza" },
		Residential = { "SliceStreetPizza", "FreshLaneMarket" },
		Industrial = { "CrateAndCoSupply", "FreshLaneMarket" },
	},
} :: ContractDefinition

ContractDefinitions.All = { LunchRush = ContractDefinitions.LunchRush }

return ContractDefinitions
