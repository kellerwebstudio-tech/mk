--!nonstrict
-- ContractService: the Neighborhood Lunch Rush (docs/ARCHITECTURE.md 5.6).
--
-- One global cycle: Idle -> Open (window) -> Grace (joined batches finish) -> Idle (cooldown), the
-- neighbourhood rotating every rush. While Open, each eligible player receives personal offers
-- (contract orders created through OrderService and injected into their board, never auto-accepted).
-- Join accepts 2-4 offered ids in one go; delivering all of them before the deadline grants the
-- contract bonus through RewardService. Everything the client sees arrives as personalised
-- ContractUpdated pushes (ContractPublicState).
--
-- Times are os.clock() values; payloads carry serverTime so clients can compute offsets.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)
local Remotes = require(Shared.Util.Remotes)
local TableUtil = require(Shared.Util.TableUtil)
local ContractDefinitions = require(Shared.Definitions.ContractDefinitions)
local OrderDefinitions = require(Shared.Definitions.OrderDefinitions)
local BusinessDefinitions = require(Shared.Definitions.BusinessDefinitions)
local EconomyConfig = require(Shared.Config.EconomyConfig)

type Order = Types.Order
type Profile = Types.Profile
type ContractPublicState = Types.ContractPublicState

type Joined = {
	orderIds: { string },
	deadline: number,
	required: number,
	done: number,
	orders: { Order },
	counted: { [string]: boolean },
	completed: boolean,
	failed: boolean,
}

type PlayerState = {
	rushId: string?,
	offers: { Order },
	offerIds: { [string]: boolean },
	joined: Joined?,
	pushScheduled: boolean,
}

type Cycle = {
	id: string?,
	neighborhood: string?,
	opensAt: number?,
	closesAt: number?,
	graceEndsAt: number?,
	status: "Idle" | "Open" | "Grace",
	nextAt: number,
	rotation: number, -- index into def.neighborhoods for the NEXT rush
	counter: number,
}

local ContractService = {}

ContractService.TICK_INTERVAL = 1 -- seconds between cycle checks
ContractService.INITIAL_DELAY = 120 -- seconds after server start until the first rush opens

local def = ContractDefinitions.LunchRush

local ctx: any = nil
local running = false
local rng = Random.new()
local players: { [Player]: PlayerState } = {}
local cycle: Cycle = {
	id = nil,
	neighborhood = nil,
	opensAt = nil,
	closesAt = nil,
	graceEndsAt = nil,
	status = "Idle",
	nextAt = math.huge,
	rotation = 1,
	counter = 0,
}

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local function ok(extra)
	return Remotes.ok(extra)
end

local function fail(code: string, message: string?, extra)
	return Remotes.fail(code, message, extra)
end

local function service(name: string)
	return ctx and ctx.services and ctx.services[name]
end

local function getProfile(player: Player): Profile?
	local playerData = service("PlayerDataService")
	return playerData and playerData.GetProfile(player) or nil
end

local function fireEvent(name: string, player: Player, payload)
	pcall(function()
		ctx.remotes.getEvent(name):FireClient(player, payload)
	end)
end

local function notify(player: Player, text: string, kind: string, duration: number?)
	fireEvent("Notify", player, { text = text, kind = kind, duration = duration })
end

local function getState(player: Player): PlayerState
	local st = players[player]
	if not st then
		st = { rushId = nil, offers = {}, offerIds = {}, joined = nil, pushScheduled = false }
		players[player] = st
	end
	return st
end

local function removeOffer(st: PlayerState, orderId: string)
	if not st.offerIds[orderId] then
		return
	end
	st.offerIds[orderId] = nil
	for index, order in ipairs(st.offers) do
		if order.id == orderId then
			table.remove(st.offers, index)
			break
		end
	end
end

local function clearOffers(st: PlayerState)
	st.offers = {}
	st.offerIds = {}
end

local function eligibility(profile: Profile?): (boolean, string?)
	if not profile then
		return false, "Locked"
	end
	local progression = service("ProgressionService")
	if progression and progression.IsContractUnlocked then
		return progression.IsContractUnlocked(profile, def.id)
	end
	local req = def.requirements
	if req.tutorial and not profile.tutorial.completed then
		return false, "Requirements"
	end
	if (profile.reputation or 0) < req.reputation or (profile.stats.deliveries or 0) < req.deliveries then
		return false, "Requirements"
	end
	return true, nil
end

local function maxCapacity(profile: Profile): number
	local progression = service("ProgressionService")
	if progression and progression.GetMaxCapacity then
		return progression.GetMaxCapacity(profile)
	end
	return EconomyConfig.onFootCapacity
end

-- Layout destination entries in the rush neighbourhood that accept the given size.
local function destinationAccepts(entry, size: string): boolean
	local accepts = entry.accepts or OrderDefinitions.KindAccepts[entry.kind]
	if type(accepts) ~= "table" then
		return true
	end
	return accepts[size] == true
end

-- Whether a business may deliver to a layout destination entry according to its deliveryProfile
-- (neighbourhood and, when set, destination kind). The rush neighbourhood is the primary filter;
-- this keeps e.g. groceries off Industrial loading bays (BusinessDefinitions.deliveryProfile).
local function businessServes(businessId: string, entry): boolean
	local business = BusinessDefinitions.get(businessId)
	local profileDef = business and business.deliveryProfile
	if type(profileDef) ~= "table" then
		return true
	end
	if type(profileDef.neighborhoods) == "table" and not profileDef.neighborhoods[entry.neighborhood] then
		return false
	end
	if type(profileDef.kinds) == "table" and not profileDef.kinds[entry.kind] then
		return false
	end
	return true
end

local function neighborhoodDestinations(neighborhood: string): { any }
	local result = {}
	local layout = ctx and ctx.layout
	local world = ctx and ctx.world
	local worldDestinations = world and world.destinations
	if type(layout) == "table" and type(layout.destinations) == "table" then
		for _, entry in ipairs(layout.destinations) do
			if type(entry) == "table" and entry.id and entry.neighborhood == neighborhood then
				if worldDestinations == nil or worldDestinations[entry.id] ~= nil then
					table.insert(result, entry)
				end
			end
		end
	end
	return result
end

local function unlockedBusinesses(profile: Profile, neighborhood: string): { string }
	local progression = service("ProgressionService")
	local world = ctx and ctx.world
	local worldBusinesses = world and world.businesses
	local result = {}
	for _, businessId in ipairs(def.businessesByNeighborhood[neighborhood] or {}) do
		local unlocked = true
		if progression and progression.IsBusinessUnlocked then
			unlocked = progression.IsBusinessUnlocked(profile, businessId)
		end
		if unlocked and (worldBusinesses == nil or worldBusinesses[businessId] ~= nil) then
			table.insert(result, businessId)
		end
	end
	return result
end

-------------------------------------------------------------------------------
-- Public state + pushes
-------------------------------------------------------------------------------

local function publicJoined(joined: Joined?)
	if not joined then
		return nil
	end
	return {
		orderIds = table.clone(joined.orderIds),
		deadline = joined.deadline,
		required = joined.required,
		done = joined.done,
		completed = joined.completed,
		failed = joined.failed,
	}
end

function ContractService.GetStateFor(player: Player): ContractPublicState
	local st = players[player]
	local profile = getProfile(player)
	local eligible, reason = eligibility(profile)
	local state: any = {
		id = cycle.id,
		neighborhood = cycle.neighborhood,
		opensAt = cycle.opensAt,
		closesAt = cycle.closesAt,
		graceEndsAt = cycle.graceEndsAt,
		status = cycle.status,
		nextAt = cycle.nextAt,
		offers = nil,
		joined = nil,
		eligible = eligible,
		eligibilityReason = if eligible then nil else reason,
		serverTime = os.clock(),
	}
	if st and st.rushId ~= nil and st.rushId == cycle.id then
		if cycle.status == "Open" and #st.offers > 0 then
			state.offers = table.clone(st.offers)
		end
		state.joined = publicJoined(st.joined)
	end
	return state
end

local function flushPush(player: Player, st: PlayerState)
	st.pushScheduled = false
	if players[player] ~= st or player.Parent == nil then
		return
	end
	fireEvent("ContractUpdated", player, ContractService.GetStateFor(player))
end

local function pushState(player: Player)
	local st = getState(player)
	if st.pushScheduled then
		return
	end
	st.pushScheduled = true
	task.defer(flushPush, player, st)
end

local function pushAll()
	for _, player in ipairs(Players:GetPlayers()) do
		pushState(player)
	end
end

-------------------------------------------------------------------------------
-- Offers
-------------------------------------------------------------------------------

-- Creates and injects this rush's offers for a player (no-op when ineligible or already offered).
local function createOffers(player: Player)
	if cycle.status ~= "Open" or not cycle.id then
		return
	end
	local st = getState(player)
	if st.rushId == cycle.id then
		return -- already has offers (or a batch) for this rush
	end
	local profile = getProfile(player)
	if not profile then
		return
	end
	local eligible = eligibility(profile)
	if not eligible then
		return
	end
	local orders = service("OrderService")
	if not orders or not orders.CreateOrder or not orders.InjectOrders then
		return
	end
	st.rushId = cycle.id
	st.joined = nil
	clearOffers(st)

	local neighborhood = cycle.neighborhood :: string
	local businesses = unlockedBusinesses(profile, neighborhood)
	local destinations = neighborhoodDestinations(neighborhood)
	if #businesses == 0 or #destinations == 0 then
		pushState(player)
		return
	end
	local capacity = maxCapacity(profile)
	local sizes = {}
	for _, size in ipairs(def.sizes) do
		if OrderDefinitions.unitsFor(size) <= capacity then
			table.insert(sizes, size)
		end
	end
	if #sizes == 0 then
		sizes = { def.sizes[1] }
	end
	TableUtil.shuffle(destinations, rng)
	local now = os.clock()
	local timeLimit = math.max(1, (cycle.graceEndsAt :: number) - now)
	local availableFor = math.max(1, (cycle.closesAt :: number) - now)
	local offers = {}
	for _, entry in ipairs(destinations) do
		if #offers >= def.offerCount then
			break
		end
		local acceptable = {}
		for _, size in ipairs(sizes) do
			if destinationAccepts(entry, size) then
				table.insert(acceptable, size)
			end
		end
		local servers = {}
		for _, businessId in ipairs(businesses) do
			if businessServes(businessId, entry) then
				table.insert(servers, businessId)
			end
		end
		if #acceptable > 0 and #servers > 0 then
			local size = acceptable[rng:NextInteger(1, #acceptable)]
			local businessId = servers[rng:NextInteger(1, #servers)]
			local okCreate, order = pcall(orders.CreateOrder, player, {
				businessId = businessId,
				destinationId = entry.id,
				size = size,
				contractId = cycle.id,
				timeLimit = timeLimit,
				availableFor = availableFor,
			})
			if okCreate and type(order) == "table" then
				table.insert(offers, order)
			else
				warn("[ContractService] CreateOrder failed:", order)
			end
		end
	end
	if #offers > 0 then
		orders.InjectOrders(player, offers)
		for _, order in ipairs(offers) do
			table.insert(st.offers, order)
			st.offerIds[order.id] = true
		end
		notify(player, string.format("Lunch Rush in %s! Pick a batch from the Contract tab.", tostring(neighborhood)), "info", 6)
	end
	pushState(player)
end

-- Cancels a player's offers that were not joined (window closed).
local function cancelOffers(player: Player, st: PlayerState)
	local orders = service("OrderService")
	for _, order in ipairs(table.clone(st.offers)) do
		if orders and orders.Cancel and order.state == "Available" then
			pcall(orders.Cancel, player, order.id, { silent = true, noPenalty = true, reason = "ContractClosed" })
		end
	end
	clearOffers(st)
end

-- Deadline passed: uncollected joined orders are cancelled without penalty; collected ones stay.
local function expireBatch(player: Player, st: PlayerState)
	local joined = st.joined
	if not joined or joined.completed then
		return
	end
	local orders = service("OrderService")
	local cancelled = 0
	for _, orderId in ipairs(joined.orderIds) do
		local order = orders and orders.GetOrder and orders.GetOrder(orderId) or nil
		if order and (order.state == "Accepted" or order.state == "ReadyForPickup") and orders.Cancel then
			local okCancel = pcall(orders.Cancel, player, orderId, { silent = true, noPenalty = true, reason = "ContractExpired" })
			if okCancel then
				cancelled += 1
			end
		end
	end
	joined.failed = true
	notify(player, "Lunch Rush deadline passed. Collected orders still pay base pay.", "warning", 6)
end

-------------------------------------------------------------------------------
-- Cycle transitions
-------------------------------------------------------------------------------

local function openRush(now: number)
	cycle.counter += 1
	local neighborhoods = def.neighborhoods
	local index = ((cycle.rotation - 1) % #neighborhoods) + 1
	cycle.id = string.format("%s-%d", def.id, cycle.counter)
	cycle.neighborhood = neighborhoods[index]
	cycle.rotation = index + 1
	cycle.opensAt = now
	cycle.closesAt = now + def.window
	cycle.graceEndsAt = cycle.closesAt + def.grace
	cycle.status = "Open"
	cycle.nextAt = cycle.graceEndsAt + def.cooldown
	for _, player in ipairs(Players:GetPlayers()) do
		local okOffers, err = pcall(createOffers, player)
		if not okOffers then
			warn("[ContractService] offers failed for", player.Name, err)
		end
	end
	pushAll()
end

local function closeWindow()
	cycle.status = "Grace"
	for player, st in pairs(players) do
		if st.rushId == cycle.id then
			pcall(cancelOffers, player, st)
		end
	end
	pushAll()
end

local function endRush(now: number)
	for player, st in pairs(players) do
		if st.rushId == cycle.id then
			pcall(expireBatch, player, st)
			st.joined = nil
			clearOffers(st)
		end
	end
	cycle.status = "Idle"
	cycle.id = nil
	cycle.neighborhood = nil
	cycle.opensAt = nil
	cycle.closesAt = nil
	cycle.graceEndsAt = nil
	cycle.nextAt = now + def.cooldown
	pushAll()
end

-- Advances the cycle to the state it should be in at `now`. Public so tests can drive it.
function ContractService.RunTick()
	local now = os.clock()
	if cycle.status == "Idle" then
		if now >= cycle.nextAt then
			openRush(now)
		end
	elseif cycle.status == "Open" then
		if now >= (cycle.closesAt :: number) then
			closeWindow()
		end
	elseif cycle.status == "Grace" then
		if now >= (cycle.graceEndsAt :: number) then
			endRush(now)
		end
	end
end

-- Read-only copy of the global cycle (tests / tooling).
function ContractService.GetCycle()
	return TableUtil.deepCopy(cycle)
end

-- Opens a rush right now (admin / tests). Optional neighbourhood override.
function ContractService.ForceOpen(neighborhood: string?)
	local now = os.clock()
	if cycle.status ~= "Idle" then
		if cycle.status == "Open" then
			closeWindow()
		end
		endRush(now)
	end
	if neighborhood then
		for index, id in ipairs(def.neighborhoods) do
			if id == neighborhood then
				cycle.rotation = index
			end
		end
	end
	openRush(now)
end

-------------------------------------------------------------------------------
-- Join
-------------------------------------------------------------------------------

function ContractService.Join(player: Player, contractId: string, orderIds: { string })
	local profile = getProfile(player)
	if not profile then
		return fail("Locked", "Your profile is still loading")
	end
	if cycle.status ~= "Open" or not cycle.id then
		return fail("WrongState", "There is no Lunch Rush open right now")
	end
	if contractId ~= cycle.id and contractId ~= def.id then
		return fail("NotFound", "That rush is over")
	end
	local eligible, reason = eligibility(profile)
	if not eligible then
		return fail(reason or "Requirements", "You haven't unlocked the Lunch Rush yet")
	end
	local st = getState(player)
	if st.rushId ~= cycle.id then
		return fail("NotFound", "You have no offers for this rush")
	end
	if st.joined then
		return fail("WrongState", "You already joined this rush")
	end
	if type(orderIds) ~= "table" then
		return fail("Invalid", "Pick the orders to join with")
	end
	local count = #orderIds
	if count < def.minBatch or count > def.maxBatch then
		return fail("Invalid", string.format("Pick between %d and %d orders", def.minBatch, def.maxBatch))
	end
	local orders = service("OrderService")
	if not orders or not orders.Accept then
		return fail("Internal", "Orders are unavailable")
	end
	local seen = {}
	local batch: { Order } = {}
	local units = 0
	for _, orderId in ipairs(orderIds) do
		if type(orderId) ~= "string" or seen[orderId] then
			return fail("Invalid", "Duplicate or invalid order id")
		end
		seen[orderId] = true
		if not st.offerIds[orderId] then
			return fail("NotFound", "That order isn't one of your offers")
		end
		local order = orders.GetOrder and orders.GetOrder(orderId) or nil
		if not order then
			for _, offer in ipairs(st.offers) do
				if offer.id == orderId then
					order = offer
				end
			end
		end
		if not order or order.state ~= "Available" or order.userId ~= player.UserId then
			return fail("WrongState", "That offer is no longer available")
		end
		table.insert(batch, order)
		units += order.sizeUnits or OrderDefinitions.unitsFor(order.size)
	end
	local capacity = maxCapacity(profile)
	if units > capacity then
		return fail("NoCapacity", string.format("That batch needs %d capacity; you have %d", units, capacity))
	end
	if orders.GetCapacityInfo then
		local info = orders.GetCapacityInfo(player)
		if info and (info.committed or 0) + units > (info.max or capacity) then
			return fail("NoCapacity", "Finish or cancel your other orders first")
		end
	end

	-- Accept every order; if one fails, roll the batch back so nothing half-joined remains.
	local accepted = {}
	for _, order in ipairs(batch) do
		local result = orders.Accept(player, order.id, { viaContract = true })
		if not result or not result.ok then
			for _, done in ipairs(accepted) do
				pcall(orders.Cancel, player, done.id, { silent = true, noPenalty = true, reason = "ContractJoinFailed" })
			end
			local code = result and result.error or "Internal"
			return fail(code, result and result.message or "Could not accept that batch")
		end
		table.insert(accepted, order)
	end

	local ids = {}
	for _, order in ipairs(accepted) do
		table.insert(ids, order.id)
		removeOffer(st, order.id)
	end
	st.joined = {
		orderIds = ids,
		deadline = cycle.graceEndsAt :: number,
		required = #accepted,
		done = 0,
		orders = accepted,
		counted = {},
		completed = false,
		failed = false,
	}
	notify(player, string.format("Lunch Rush joined: deliver %d orders before the deadline!", #accepted), "success", 5)
	pushState(player)
	return ok({ orders = accepted, joined = publicJoined(st.joined) })
end

ContractService.JoinContract = ContractService.Join

-------------------------------------------------------------------------------
-- Order signals
-------------------------------------------------------------------------------

local function onOrderDelivered(player: Player, order: Order)
	local st = players[player]
	local joined = st and st.joined
	if not joined or not order or joined.counted[order.id] then
		return
	end
	local inBatch = false
	for _, id in ipairs(joined.orderIds) do
		if id == order.id then
			inBatch = true
			break
		end
	end
	if not inBatch then
		return
	end
	joined.counted[order.id] = true
	joined.done += 1
	local now = os.clock()
	if joined.done >= joined.required and not joined.completed and not joined.failed then
		if now <= joined.deadline then
			joined.completed = true
			local rewards = service("RewardService")
			local bonus = 0
			if rewards and rewards.GrantContractBonus then
				local okBonus, result = pcall(rewards.GrantContractBonus, player, def.id, joined.orders)
				if okBonus then
					bonus = tonumber(result) or 0
				else
					warn("[ContractService] GrantContractBonus failed:", result)
				end
			end
			notify(player, string.format("Lunch Rush complete! Bonus $%d and +%d Rep", bonus, def.repBonus), "success", 6)
		else
			joined.failed = true
			notify(player, "Batch finished after the deadline: no bonus this time.", "warning", 5)
		end
	end
	pushState(player)
end

-- Defensive: an offer that became Accepted by any path leaves the offer list (Join removes its
-- own ids as well; OrderService refuses direct accepts of contract orders).
local function onOrderAccepted(player: Player, order: Order)
	local st = players[player]
	if st and order and st.offerIds[order.id] then
		removeOffer(st, order.id)
		pushState(player)
	end
end

local function onOrderRemoved(player: Player, order: Order, reason: string?)
	local st = players[player]
	if not st or not order then
		return
	end
	if st.offerIds[order.id] then
		removeOffer(st, order.id)
		pushState(player)
		return
	end
	local joined = st.joined
	if joined and not joined.completed and reason ~= "Delivered" then
		for _, id in ipairs(joined.orderIds) do
			if id == order.id and not joined.counted[id] then
				-- A joined order left without being delivered: the batch can no longer complete.
				joined.failed = true
				pushState(player)
				return
			end
		end
	end
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

local function onProfileLoaded(player: Player)
	if cycle.status == "Open" then
		local okOffers, err = pcall(createOffers, player)
		if not okOffers then
			warn("[ContractService] offers failed for", player.Name, err)
		end
	end
	pushState(player)
end

local function onPlayerRemoving(player: Player)
	players[player] = nil
end

function ContractService.Init(context)
	ctx = context
	players = {}
	cycle.status = "Idle"
	cycle.id = nil
	cycle.neighborhood = nil
	cycle.opensAt = nil
	cycle.closesAt = nil
	cycle.graceEndsAt = nil
	cycle.rotation = 1
	cycle.counter = 0
	cycle.nextAt = os.clock() + ContractService.INITIAL_DELAY
end

function ContractService.Start()
	local playerData = service("PlayerDataService")
	if playerData and playerData.ProfileLoaded then
		playerData.ProfileLoaded:Connect(function(player: Player)
			onProfileLoaded(player)
		end)
		for _, player in ipairs(Players:GetPlayers()) do
			if playerData.GetProfile(player) then
				onProfileLoaded(player)
			end
		end
	end
	local orders = service("OrderService")
	if orders then
		if orders.OrderAccepted then
			orders.OrderAccepted:Connect(onOrderAccepted)
		end
		if orders.OrderDelivered then
			orders.OrderDelivered:Connect(onOrderDelivered)
		end
		if orders.OrderRemoved then
			orders.OrderRemoved:Connect(onOrderRemoved)
		end
	end
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	running = true
	task.spawn(function()
		while running do
			task.wait(ContractService.TICK_INTERVAL)
			local okTick, err = pcall(ContractService.RunTick)
			if not okTick then
				warn("[ContractService] tick error:", err)
			end
		end
	end)
end

-- Stops the cycle loop (tests / shutdown).
function ContractService.Stop()
	running = false
end

return ContractService
