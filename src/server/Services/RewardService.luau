--!nonstrict
-- RewardService: computes and grants delivery payouts and contract bonuses exactly once.
-- See docs/ARCHITECTURE.md section 5.12.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)
local TableUtil = require(Shared.Util.TableUtil)
local EconomyConfig = require(Shared.Config.EconomyConfig)
local OrderDefinitions = require(Shared.Definitions.OrderDefinitions)
local ContractDefinitions = require(Shared.Definitions.ContractDefinitions)

type Order = Types.Order
type Payout = Types.Payout
type Profile = Types.Profile

local RewardService = {}

local ctx: any = nil

local function round(value: number): number
	return math.floor(value + 0.5)
end

function RewardService.Init(context)
	ctx = context
end

function RewardService.Start() end

-- Timeliness factor: 1 inside the time limit, linear to 0 at timeLimit * lateCutoffMultiplier.
-- Untimed orders are always 1. Returns (factor, lateSeconds).
local function timeliness(order: Order, now: number): (number, number)
	local timeLimit = order.timeLimit
	local acceptedAt = order.acceptedAt
	if not timeLimit or not acceptedAt or timeLimit <= 0 then
		return 1, 0
	end
	local elapsed = now - acceptedAt
	if elapsed <= timeLimit then
		return 1, 0
	end
	local late = elapsed - timeLimit
	local cutoff = timeLimit * (EconomyConfig.lateCutoffMultiplier - 1)
	if cutoff <= 0 then
		return 0, late
	end
	return math.clamp(1 - late / cutoff, 0, 1), late
end

function RewardService.ComputePayout(order: Order, profile: Profile, now: number): Payout
	local progression = ctx and ctx.services and ctx.services.ProgressionService
	local tipMultiplier = 1
	if progression and profile then
		tipMultiplier = progression.GetTipMultiplier(profile)
	end
	local factor, late = timeliness(order, now)
	local base = round(order.basePay)
	local tip = round((order.tipMax or 0) * tipMultiplier * factor)
	local acceptedAt = order.acceptedAt or now
	return {
		base = base,
		tip = tip,
		total = base + tip,
		rep = round(order.repReward or 0),
		lateSeconds = late,
		timelinessFactor = factor,
		newRecord = false,
		deliveryTime = math.max(0, now - acceptedAt),
	}
end

-- Grants the payout for a delivered order exactly once. Returns nil when already granted.
function RewardService.GrantDeliveryPayout(player: Player, order: Order): Payout?
	if order.rewardGranted then
		return nil
	end
	order.rewardGranted = true

	local playerData = ctx.services.PlayerDataService
	local progression = ctx.services.ProgressionService
	local profile = playerData.GetProfile(player)
	if not profile then
		return nil
	end
	local now = order.deliveredAt or os.clock()
	local payout = RewardService.ComputePayout(order, profile, now)

	playerData.AddCash(player, payout.total, "Delivery")
	playerData.AddReputation(player, payout.rep, "Delivery")
	local milestoneRep = 0
	playerData.Update(player, function(p: Profile)
		local stats: any = p.stats
		stats.deliveries = (stats.deliveries or 0) + 1
		stats.totalEarned = (stats.totalEarned or 0) + payout.total
		stats.distance = (stats.distance or 0) + (order.routeDistance or 0)
		if payout.lateSeconds > 0 then
			stats.lateDeliveries = (stats.lateDeliveries or 0) + 1
		end
		if type(stats.bestTimes) ~= "table" then
			stats.bestTimes = {}
		end
		local key = OrderDefinitions.routeKey(order.businessId, order.destinationId)
		local deliveryTime = round((payout.deliveryTime or 0) * 10) / 10
		local previous = stats.bestTimes[key]
		if previous == nil or deliveryTime < previous then
			stats.bestTimes[key] = deliveryTime
			payout.newRecord = previous ~= nil
		end
		if progression then
			milestoneRep = progression.ApplyMilestones(p)
		end
	end)
	local extended: any = payout
	extended.milestoneRep = milestoneRep
	return payout
end

-- Bonus for a completed contract batch: fraction of the batch base pay plus a flat bonus and rep.
function RewardService.GrantContractBonus(player: Player, contractId: string, orders: { Order }): number
	local def = ContractDefinitions.All[contractId] or ContractDefinitions.LunchRush
	local baseSum = 0
	for _, order in ipairs(orders) do
		baseSum += order.basePay or 0
	end
	local bonus = round(baseSum * def.bonusFraction + def.flatBonus)
	local playerData = ctx.services.PlayerDataService
	playerData.AddCash(player, bonus, "ContractBonus")
	playerData.AddReputation(player, def.repBonus or EconomyConfig.contractBonusRep, "ContractBonus")
	playerData.Update(player, function(profile: Profile)
		local stats: any = profile.stats
		stats.contractsCompleted = (stats.contractsCompleted or 0) + 1
		stats.totalEarned = (stats.totalEarned or 0) + bonus
	end)
	return bonus
end

-- Deep copy helper for payloads sent to clients.
function RewardService.CopyPayout(payout: Payout): Payout
	return TableUtil.deepCopy(payout)
end

return RewardService
