--!nonstrict
-- ProgressionService: pure functions over a Profile (unlocks, capacity, multipliers, purchase checks,
-- milestones). It never touches Instances or remotes, so other services and tests can call it freely.
-- See docs/ARCHITECTURE.md section 5.2.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)
local EconomyConfig = require(Shared.Config.EconomyConfig)
local MonetizationConfig = require(Shared.Config.MonetizationConfig)
local BusinessDefinitions = require(Shared.Definitions.BusinessDefinitions)
local VehicleDefinitions = require(Shared.Definitions.VehicleDefinitions)
local UpgradeDefinitions = require(Shared.Definitions.UpgradeDefinitions)
local CosmeticDefinitions = require(Shared.Definitions.CosmeticDefinitions)
local ContractDefinitions = require(Shared.Definitions.ContractDefinitions)
local DepotDefinitions = require(Shared.Definitions.DepotDefinitions)

type Profile = Types.Profile

local ProgressionService = {}

function ProgressionService.Init(ctx)
	-- Pure module: nothing to wire.
end

function ProgressionService.Start() end

-------------------------------------------------------------------------------
-- Unlocks
-------------------------------------------------------------------------------

function ProgressionService.IsBusinessUnlocked(profile: Profile, businessId: string): boolean
	local business = BusinessDefinitions.get(businessId)
	if not business then
		return false
	end
	return (profile.reputation or 0) >= business.repRequired
end

function ProgressionService.GetUnlockedBusinesses(profile: Profile): { string }
	local result = {}
	for _, businessId in ipairs(BusinessDefinitions.Order) do
		if ProgressionService.IsBusinessUnlocked(profile, businessId) then
			table.insert(result, businessId)
		end
	end
	return result
end

function ProgressionService.IsMultiOrderUnlocked(profile: Profile): boolean
	return profile.tutorial.completed == true and (profile.stats.deliveries or 0) >= EconomyConfig.multiOrderUnlockDeliveries
end

function ProgressionService.GetUpgradeLevel(profile: Profile, upgradeId: string): number
	local level = profile.upgrades[upgradeId]
	if type(level) == "number" then
		return level
	end
	return 0
end

-------------------------------------------------------------------------------
-- Capacity, speed, tips
-------------------------------------------------------------------------------

-- Capacity in order units for a vehicle (nil = on foot). Unknown vehicle ids count as on foot.
function ProgressionService.GetCapacityForVehicle(profile: Profile, vehicleId: string?): number
	if vehicleId == nil then
		return EconomyConfig.onFootCapacity
	end
	local def = VehicleDefinitions.get(vehicleId)
	if not def then
		return EconomyConfig.onFootCapacity
	end
	local capacity = def.baseCapacity
	for upgradeId, level in pairs(profile.upgrades) do
		if type(level) == "number" and level > 0 then
			local upgrade = UpgradeDefinitions.get(upgradeId)
			local bonus = upgrade and upgrade.effect.capacityBonus
			if bonus and bonus.vehicle == vehicleId then
				capacity += bonus.amount * level
			end
		end
	end
	return capacity
end

-- Best capacity over every owned vehicle (never below on-foot capacity).
function ProgressionService.GetMaxCapacity(profile: Profile): number
	local best = EconomyConfig.onFootCapacity
	for vehicleId, owned in pairs(profile.ownedVehicles) do
		if owned then
			best = math.max(best, ProgressionService.GetCapacityForVehicle(profile, vehicleId))
		end
	end
	return best
end

function ProgressionService.GetSpeedMultiplier(profile: Profile, vehicleId: string): number
	local multiplier = 1
	for upgradeId, level in pairs(profile.upgrades) do
		if type(level) == "number" and level > 0 then
			local upgrade = UpgradeDefinitions.get(upgradeId)
			local bonus = upgrade and upgrade.effect.speedBonus
			if bonus and bonus.vehicle == vehicleId then
				multiplier += bonus.amount * level
			end
		end
	end
	return multiplier
end

function ProgressionService.GetTipMultiplier(profile: Profile): number
	local multiplier = 1
	for upgradeId, level in pairs(profile.upgrades) do
		if type(level) == "number" and level > 0 then
			local upgrade = UpgradeDefinitions.get(upgradeId)
			if upgrade and upgrade.effect.tipBonus then
				multiplier += upgrade.effect.tipBonus * level
			end
		end
	end
	return multiplier
end

-------------------------------------------------------------------------------
-- Purchase checks: (true) or (false, reasonCode)
-------------------------------------------------------------------------------

function ProgressionService.CanPurchaseVehicle(profile: Profile, vehicleId: string): (boolean, string?)
	local def = VehicleDefinitions.get(vehicleId)
	if not def then
		return false, "NotFound"
	end
	if profile.ownedVehicles[vehicleId] then
		return false, "AlreadyOwned"
	end
	if (profile.reputation or 0) < def.repRequired then
		return false, "Requirements"
	end
	if (profile.cash or 0) < def.price then
		return false, "Insufficient"
	end
	return true, nil
end

function ProgressionService.CanPurchaseUpgrade(profile: Profile, upgradeId: string): (boolean, string?)
	local def = UpgradeDefinitions.get(upgradeId)
	if not def then
		return false, "NotFound"
	end
	if ProgressionService.GetUpgradeLevel(profile, upgradeId) > 0 then
		return false, "AlreadyOwned"
	end
	if def.requiresVehicle and not profile.ownedVehicles[def.requiresVehicle] then
		return false, "Requirements"
	end
	if def.requiresUpgrade and ProgressionService.GetUpgradeLevel(profile, def.requiresUpgrade) <= 0 then
		return false, "Requirements"
	end
	if (profile.reputation or 0) < def.repRequired then
		return false, "Requirements"
	end
	if (profile.cash or 0) < def.price then
		return false, "Insufficient"
	end
	return true, nil
end

function ProgressionService.CanPurchaseCosmetic(profile: Profile, cosmeticId: string): (boolean, string?)
	local def = CosmeticDefinitions.get(cosmeticId)
	if not def then
		return false, "NotFound"
	end
	if profile.cosmetics.owned[cosmeticId] then
		return false, "AlreadyOwned"
	end
	if def.paidOnly then
		-- Paid cosmetics are granted through MonetizationConfig products only; never purchasable with cash.
		return false, "Locked"
	end
	if (profile.reputation or 0) < def.repRequired then
		return false, "Requirements"
	end
	if (profile.cash or 0) < def.price then
		return false, "Insufficient"
	end
	return true, nil
end

function ProgressionService.CanPurchaseDepot(profile: Profile): (boolean, string?)
	if profile.depot.owned then
		return false, "AlreadyOwned"
	end
	if (profile.reputation or 0) < EconomyConfig.depotRepRequired then
		return false, "Requirements"
	end
	if (profile.cash or 0) < EconomyConfig.depotPrice then
		return false, "Insufficient"
	end
	return true, nil
end

function ProgressionService.IsContractUnlocked(profile: Profile, contractId: string): (boolean, string?)
	local def = ContractDefinitions.All[contractId]
	if not def then
		return false, "NotFound"
	end
	local req = def.requirements
	if req.tutorial and not profile.tutorial.completed then
		return false, "Requirements"
	end
	if (profile.reputation or 0) < req.reputation then
		return false, "Requirements"
	end
	if (profile.stats.deliveries or 0) < req.deliveries then
		return false, "Requirements"
	end
	return true, nil
end

function ProgressionService.GetUnlockedDriverCategories(profile: Profile): { string }
	local result = {}
	for _, categoryId in ipairs(DepotDefinitions.CategoryOrder) do
		local category = DepotDefinitions.get(categoryId)
		if category and (profile.reputation or 0) >= category.repRequired then
			table.insert(result, categoryId)
		end
	end
	return result
end

-- Whether a cosmetic can ever be granted in this build (paid cosmetics need monetization enabled).
function ProgressionService.IsCosmeticGrantable(cosmeticId: string): boolean
	local def = CosmeticDefinitions.get(cosmeticId)
	if not def then
		return false
	end
	if def.paidOnly then
		return MonetizationConfig.enabled == true
	end
	return true
end

-------------------------------------------------------------------------------
-- Milestones
-------------------------------------------------------------------------------

-- Grants reputation for newly reached delivery milestones (idempotent via stats.milestonesGranted).
-- Returns the reputation granted by this call.
function ProgressionService.ApplyMilestones(profile: Profile): number
	local stats: any = profile.stats
	if type(stats.milestonesGranted) ~= "table" then
		stats.milestonesGranted = {}
	end
	local granted = 0
	local deliveries = stats.deliveries or 0
	for _, milestone in ipairs(EconomyConfig.milestones) do
		local key = tostring(milestone.deliveries)
		if deliveries >= milestone.deliveries and not stats.milestonesGranted[key] then
			stats.milestonesGranted[key] = true
			granted += milestone.rep
		end
	end
	if granted > 0 then
		profile.reputation = (profile.reputation or 0) + granted
	end
	return granted
end

return ProgressionService
