--!nonstrict
-- OrderService: server-authoritative order board and delivery lifecycle
-- (Available -> Accepted -> ReadyForPickup -> Collected -> Delivered, plus Cancelled/Expired),
-- pricing, generation, package visuals and OrdersUpdated replication. See docs/ARCHITECTURE.md 5.5.

local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)
local Signal = require(Shared.Util.Signal)
local Remotes = require(Shared.Util.Remotes)
local TableUtil = require(Shared.Util.TableUtil)
local EconomyConfig = require(Shared.Config.EconomyConfig)
local BusinessDefinitions = require(Shared.Definitions.BusinessDefinitions)
local OrderDefinitions = require(Shared.Definitions.OrderDefinitions)
local VehicleDefinitions = require(Shared.Definitions.VehicleDefinitions)
local CosmeticDefinitions = require(Shared.Definitions.CosmeticDefinitions)
local RouteGraph = require(Shared.City.RouteGraph)

local ServerRoot = script.Parent.Parent
local BuildersFolder = ServerRoot:FindFirstChild("Builders")
local packageBuilderModule = BuildersFolder and BuildersFolder:FindFirstChild("PackageBuilder")
local DefaultPackageBuilder: any = if packageBuilderModule then require(packageBuilderModule) else nil

type Order = Types.Order
type OrderSpec = Types.OrderSpec
type CapacityInfo = Types.CapacityInfo
type Profile = Types.Profile

type PlayerOrders = {
	available: { Order },
	active: { Order },
	packages: { [string]: Model },
	generatorEnabled: boolean,
	replicateScheduled: boolean,
	lastReplicate: number,
}

local REPLICATE_INTERVAL = 0.5 -- at most 2 OrdersUpdated per second per player
local STRAIGHT_LINE_FACTOR = 1.3 -- route estimate when the graph has no path
local DISTANCE_BAND_SLACK = 0.6 -- straight-line pre-filter: >= minDistance * slack
local TUTORIAL_AVAILABLE_FOR = 24 * 3600
local GENERATION_ATTEMPTS = 12
local BAG_STYLE_KEYS = { FoodBag = true, GroceryBag = true }

local OrderService = {}

OrderService.OrderAccepted = Signal.new()
OrderService.OrderReady = Signal.new()
OrderService.OrderCollected = Signal.new()
OrderService.OrderDelivered = Signal.new()
OrderService.OrderRemoved = Signal.new()

local ctx: any = nil
local PackageBuilder: any = nil
local states: { [Player]: PlayerOrders } = {}
local ordersById: { [string]: Order } = {}
local destinationInfo: { [string]: any }? = nil
local rng = Random.new()
local running = false

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local function ok(extra)
	return Remotes.ok(extra)
end

local function fail(code: string, message: string?, extra)
	return Remotes.fail(code, message, extra)
end

local function round(value: number): number
	return math.floor(value + 0.5)
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

local function getState(player: Player): PlayerOrders
	local st = states[player]
	if not st then
		st = {
			available = {},
			active = {},
			packages = {},
			generatorEnabled = false,
			replicateScheduled = false,
			lastReplicate = -math.huge,
		}
		states[player] = st
	end
	return st
end

local function removeFromList(list: { Order }, order: Order): boolean
	for index, item in ipairs(list) do
		if item == order then
			table.remove(list, index)
			return true
		end
	end
	return false
end

local function isActiveState(state: string): boolean
	return state == "Accepted" or state == "ReadyForPickup" or state == "Collected"
end

-- Layout destination entries indexed by id (neighbourhood, kind, accepts).
local function getDestinationInfo(destinationId: string)
	local index = destinationInfo
	if index == nil then
		index = {}
		local layout = ctx and ctx.layout
		if type(layout) == "table" and type(layout.destinations) == "table" then
			for _, entry in ipairs(layout.destinations) do
				if type(entry) == "table" and entry.id then
					index[entry.id] = entry
				end
			end
		end
		destinationInfo = index
	end
	return index[destinationId]
end

local function destinationAccepts(destinationId: string, size: string): boolean
	local info = getDestinationInfo(destinationId)
	if not info then
		return true
	end
	local accepts = info.accepts or OrderDefinitions.KindAccepts[info.kind]
	if type(accepts) ~= "table" then
		return true
	end
	return accepts[size] == true
end

local function pickWeighted(items: { any }): any?
	local total = 0
	for _, item in ipairs(items) do
		total += math.max(item.weight or 1, 0)
	end
	if total <= 0 then
		return items[1]
	end
	local roll = rng:NextNumber(0, total)
	local acc = 0
	for _, item in ipairs(items) do
		acc += math.max(item.weight or 1, 0)
		if roll <= acc then
			return item
		end
	end
	return items[#items]
end

local function pickLine(lines: { string }?): string
	if type(lines) ~= "table" or #lines == 0 then
		return "Thanks!"
	end
	return lines[rng:NextInteger(1, #lines)]
end

local function generateOrderId(): string
	for _ = 1, 8 do
		local guid = HttpService:GenerateGUID(false)
		local short = string.sub(string.gsub(guid, "-", ""), 1, 10)
		if not ordersById[short] then
			return short
		end
	end
	return string.sub(string.gsub(HttpService:GenerateGUID(false), "-", ""), 1, 16)
end

local function positionsFor(businessId: string, destinationId: string): (Vector3?, Vector3?, Vector3?)
	local world = ctx and ctx.world
	if not world then
		return nil, nil, nil
	end
	local business = world.businesses and world.businesses[businessId]
	local destination = world.destinations and world.destinations[destinationId]
	local pickup = business and business.pickupPosition
	local door = destination and destination.doorPosition
	local arrival = destination and destination.arrivalPosition
	return pickup, door, arrival
end

-- Route distance along the bicycle graph (fallback: straight line * 1.3).
local function routeDistanceBetween(from: Vector3, to: Vector3): number
	local graph = ctx and ctx.graph
	if graph and graph.edges and #graph.edges > 0 then
		local okPath, path, length = pcall(RouteGraph.findPath, graph, from, to, VehicleDefinitions.Mask.Bicycle)
		if okPath and path and length and length < math.huge then
			return length
		end
	end
	return (to - from).Magnitude * STRAIGHT_LINE_FACTOR
end

-------------------------------------------------------------------------------
-- Replication
-------------------------------------------------------------------------------

function OrderService.GetCapacityInfo(player: Player): CapacityInfo
	local st = getState(player)
	local profile = getProfile(player)
	local progression = service("ProgressionService")
	local vehicles = service("VehicleService")
	local current = EconomyConfig.onFootCapacity
	if vehicles and vehicles.GetCapacityUnits then
		current = vehicles.GetCapacityUnits(player)
	elseif profile and progression then
		current = progression.GetCapacityForVehicle(profile, nil)
	end
	local max = current
	if profile and progression then
		max = math.max(progression.GetMaxCapacity(profile), current)
	end
	local load, committed = 0, 0
	for _, order in ipairs(st.active) do
		committed += order.sizeUnits
		if order.state == "Collected" then
			load += order.sizeUnits
		end
	end
	return { current = current, max = max, load = load, committed = committed }
end

local function flushReplicate(player: Player, st: PlayerOrders)
	st.replicateScheduled = false
	if states[player] ~= st then
		return
	end
	st.lastReplicate = os.clock()
	fireEvent("OrdersUpdated", player, {
		available = st.available,
		active = st.active,
		serverTime = os.clock(),
		capacity = OrderService.GetCapacityInfo(player),
	})
end

local function replicate(player: Player)
	local st = states[player]
	if not st or st.replicateScheduled then
		return
	end
	st.replicateScheduled = true
	local waitFor = (st.lastReplicate + REPLICATE_INTERVAL) - os.clock()
	if waitFor <= 0 then
		task.defer(flushReplicate, player, st)
	else
		task.delay(waitFor, flushReplicate, player, st)
	end
end

-------------------------------------------------------------------------------
-- Package visuals
-------------------------------------------------------------------------------

local function destroyPackage(st: PlayerOrders, orderId: string)
	local model = st.packages[orderId]
	if not model then
		return
	end
	st.packages[orderId] = nil
	if PackageBuilder and PackageBuilder.detach then
		pcall(PackageBuilder.detach, model)
	end
	pcall(function()
		model:Destroy()
	end)
end

local function ensurePackage(player: Player, st: PlayerOrders, order: Order): Model?
	if not PackageBuilder or not PackageBuilder.build then
		return nil
	end
	local existing = st.packages[order.id]
	if existing and existing.Parent ~= nil then
		return existing
	end
	-- Bag-type packages take the colours of the equipped BagStyle cosmetic ({ color, accent }).
	local style = nil
	if BAG_STYLE_KEYS[order.packageKey] then
		local profile = getProfile(player)
		local styleId = profile and profile.cosmetics and profile.cosmetics.equipped and profile.cosmetics.equipped.BagStyle or nil
		local cosmetic = styleId and CosmeticDefinitions.get(styleId) or nil
		if cosmetic and type(cosmetic.data) == "table" then
			style = { color = cosmetic.data.color, accent = cosmetic.data.accent }
		end
	end
	local okBuild, built = pcall(PackageBuilder.build, order.packageKey, style)
	if not okBuild or typeof(built) ~= "Instance" then
		return nil
	end
	local model = built :: Model
	pcall(function()
		model:SetAttribute("OrderId", order.id)
		model:SetAttribute("PackageKey", order.packageKey)
		CollectionService:AddTag(model, "Package")
	end)
	st.packages[order.id] = model
	return model
end

-- Attaches every Collected order's package to the vehicle (driving) or the character.
local function refreshPackages(player: Player)
	local st = states[player]
	if not st or not PackageBuilder then
		return
	end
	local vehicles = service("VehicleService")
	local driving = vehicles and vehicles.IsDriving and vehicles.IsDriving(player) or false
	local record = vehicles and vehicles.GetVehicle and vehicles.GetVehicle(player) or nil
	local character = player.Character
	local slot = 0
	for _, order in ipairs(st.active) do
		if order.state == "Collected" then
			local model = ensurePackage(player, st, order)
			if model then
				slot += 1
				if driving and record and PackageBuilder.attachToVehicle then
					pcall(PackageBuilder.attachToVehicle, model, record, slot)
				elseif character and character.Parent ~= nil and PackageBuilder.attachToCharacter then
					pcall(PackageBuilder.attachToCharacter, model, character, slot)
				elseif PackageBuilder.detach then
					pcall(PackageBuilder.detach, model)
				end
			end
		end
	end
end

-- Rebuilds package visuals (e.g. after a bag style change).
function OrderService.RefreshPackages(player: Player)
	local st = states[player]
	if not st then
		return
	end
	for orderId in pairs(st.packages) do
		destroyPackage(st, orderId)
	end
	refreshPackages(player)
end

-------------------------------------------------------------------------------
-- Order creation
-------------------------------------------------------------------------------

local function sizeIndex(size: string): number
	for index, id in ipairs(OrderDefinitions.SizeOrder) do
		if id == size then
			return index
		end
	end
	return 1
end

local function chooseItem(business, size: string?, category: string?): any?
	local items = business.items or {}
	local function matching(bySize: boolean, byCategory: boolean)
		local result = {}
		for _, item in ipairs(items) do
			if (not bySize or item.size == size) and (not byCategory or item.category == category) then
				table.insert(result, item)
			end
		end
		return result
	end
	local candidates = matching(size ~= nil, category ~= nil)
	if #candidates == 0 then
		candidates = matching(size ~= nil, false)
	end
	if #candidates == 0 then
		candidates = matching(false, category ~= nil)
	end
	if #candidates == 0 then
		candidates = items
	end
	if #candidates == 0 then
		return nil
	end
	return pickWeighted(candidates)
end

function OrderService.CreateOrder(player: Player, spec: OrderSpec): Order
	assert(type(spec) == "table", "OrderSpec required")
	local business = BusinessDefinitions.get(spec.businessId)
	assert(business, "Unknown business " .. tostring(spec.businessId))
	assert(type(spec.destinationId) == "string", "destinationId required")

	local item = chooseItem(business, spec.size, spec.itemCategory)
	local size = spec.size or (item and item.size) or "Small"
	local category = spec.itemCategory or (item and item.category) or "Food"
	local itemLabel = item and item.label or (OrderDefinitions.Categories[category] and OrderDefinitions.Categories[category].label) or "Order"
	local units = OrderDefinitions.unitsFor(size)
	local packageKey = OrderDefinitions.packageKeyFor(category)

	local pickup, door = positionsFor(spec.businessId, spec.destinationId)
	local routeDistance = 0
	if pickup and door then
		routeDistance = routeDistanceBetween(pickup, door)
	end

	local sizeBonus = EconomyConfig.sizeBonus[size] or 0
	local basePay
	if spec.basePayOverride ~= nil then
		basePay = round(spec.basePayOverride)
	else
		basePay = round((business.basePay + business.perStud * routeDistance) * (1 + sizeBonus))
	end
	local tipMax = round(basePay * (business.tipFraction or EconomyConfig.defaultTipFraction))
	local repReward = business.repPerDelivery + (sizeIndex(size) - 1)

	local timeLimit: number? = nil
	if spec.isTutorial then
		timeLimit = spec.timeLimit
	elseif spec.timeLimit ~= nil then
		timeLimit = spec.timeLimit
	else
		local estimated = routeDistance / EconomyConfig.estimatedSpeedForTiming * EconomyConfig.timeLimitMultiplier
		timeLimit = math.max(EconomyConfig.minTimeLimit, round(estimated))
	end

	local prepTime
	if spec.prepTimeOverride ~= nil then
		prepTime = math.max(0, spec.prepTimeOverride)
	else
		prepTime = rng:NextInteger(business.prepTime.min, business.prepTime.max)
	end

	local availableFor = spec.availableFor
	if availableFor == nil then
		availableFor = if spec.isTutorial then TUTORIAL_AVAILABLE_FOR else EconomyConfig.boardLifetime
	end
	local now = os.clock()
	local order: Order = {
		id = generateOrderId(),
		userId = player.UserId,
		businessId = spec.businessId,
		destinationId = spec.destinationId,
		itemCategory = category,
		size = size,
		sizeUnits = units,
		packageKey = packageKey,
		itemLabel = itemLabel,
		basePay = basePay,
		tipMax = tipMax,
		repReward = repReward,
		timeLimit = timeLimit,
		availableUntil = now + availableFor,
		prepTime = prepTime,
		routeDistance = routeDistance,
		createdAt = now,
		state = "Available",
		contractId = spec.contractId,
		isTutorial = spec.isTutorial or nil,
		rewardGranted = false,
	}
	return order
end

function OrderService.InjectOrders(player: Player, orders: { Order })
	local st = getState(player)
	for _, order in ipairs(orders) do
		if type(order) == "table" and order.id then
			order.userId = player.UserId
			order.state = "Available"
			if not ordersById[order.id] then
				ordersById[order.id] = order
				table.insert(st.available, order)
			end
		end
	end
	replicate(player)
end

-------------------------------------------------------------------------------
-- Generation
-------------------------------------------------------------------------------

local function usedDestinations(st: PlayerOrders): { [string]: boolean }
	local used = {}
	for _, order in ipairs(st.available) do
		used[order.destinationId] = true
	end
	for _, order in ipairs(st.active) do
		used[order.destinationId] = true
	end
	return used
end

-- Picks a business/destination/item combination the player can take right now.
local function pickSpec(player: Player, profile: Profile, st: PlayerOrders, maxCapacity: number): OrderSpec?
	local world = ctx and ctx.world
	if not world or not world.businesses or not world.destinations then
		return nil
	end
	local progression = service("ProgressionService")
	local businessIds = progression and progression.GetUnlockedBusinesses(profile) or BusinessDefinitions.Order
	local unlocked = {}
	for _, businessId in ipairs(businessIds) do
		if world.businesses[businessId] then
			table.insert(unlocked, businessId)
		end
	end
	if #unlocked == 0 then
		return nil
	end
	TableUtil.shuffle(unlocked, rng)
	local used = usedDestinations(st)
	for _, businessId in ipairs(unlocked) do
		local business = BusinessDefinitions.get(businessId)
		local profileDef = business.deliveryProfile
		local pickupPosition = world.businesses[businessId].pickupPosition
		local candidates = {}
		for destinationId, destination in pairs(world.destinations) do
			if used[destinationId] then
				continue
			end
			local info = getDestinationInfo(destinationId)
			if info then
				if profileDef.neighborhoods and not profileDef.neighborhoods[info.neighborhood] then
					continue
				end
				if profileDef.kinds and not profileDef.kinds[info.kind] then
					continue
				end
			end
			local distance = (destination.doorPosition - pickupPosition).Magnitude
			if distance < profileDef.minDistance * DISTANCE_BAND_SLACK or distance > profileDef.maxDistance then
				continue
			end
			local items = {}
			for _, item in ipairs(business.items) do
				if OrderDefinitions.unitsFor(item.size) <= maxCapacity and destinationAccepts(destinationId, item.size) then
					table.insert(items, item)
				end
			end
			if #items > 0 then
				table.insert(candidates, { destinationId = destinationId, items = items })
			end
		end
		if #candidates > 0 then
			local candidate = candidates[rng:NextInteger(1, #candidates)]
			local item = pickWeighted(candidate.items)
			return {
				businessId = businessId,
				destinationId = candidate.destinationId,
				size = item.size,
				itemCategory = item.category,
			}
		end
	end
	return nil
end

local function countNormalAvailable(st: PlayerOrders): number
	local count = 0
	for _, order in ipairs(st.available) do
		if not order.contractId and not order.isTutorial then
			count += 1
		end
	end
	return count
end

local function generateFor(player: Player)
	local st = states[player]
	if not st or not st.generatorEnabled then
		return
	end
	local profile = getProfile(player)
	if not profile then
		return
	end
	local progression = service("ProgressionService")
	local maxCapacity = progression and progression.GetMaxCapacity(profile) or EconomyConfig.onFootCapacity
	local count = countNormalAvailable(st)
	local target
	if count < EconomyConfig.boardMin then
		target = EconomyConfig.boardMin
	elseif count < EconomyConfig.boardMax then
		target = count + 1
	else
		return
	end
	local attempts = 0
	local added = false
	while count < target and attempts < GENERATION_ATTEMPTS do
		attempts += 1
		local spec = pickSpec(player, profile, st, maxCapacity)
		if not spec then
			break
		end
		local order = OrderService.CreateOrder(player, spec)
		ordersById[order.id] = order
		table.insert(st.available, order)
		count += 1
		added = true
	end
	if added then
		replicate(player)
	end
end

function OrderService.SetGeneratorEnabled(player: Player, enabled: boolean)
	local st = getState(player)
	st.generatorEnabled = enabled == true
	if st.generatorEnabled then
		generateFor(player)
	end
end

function OrderService.IsGeneratorEnabled(player: Player): boolean
	local st = states[player]
	return st ~= nil and st.generatorEnabled
end

-------------------------------------------------------------------------------
-- Lifecycle transitions
-------------------------------------------------------------------------------

local function finishOrder(player: Player, st: PlayerOrders, order: Order)
	ordersById[order.id] = nil
	removeFromList(st.available, order)
	removeFromList(st.active, order)
	destroyPackage(st, order.id)
end

local function markReady(player: Player, order: Order, now: number)
	order.state = "ReadyForPickup"
	order.readyAt = order.readyAt or now
	OrderService.OrderReady:Fire(player, order)
	fireEvent("OrderEvent", player, { kind = "Ready", orderId = order.id, order = order })
end

local function expireOrder(player: Player, st: PlayerOrders, order: Order)
	order.state = "Expired"
	finishOrder(player, st, order)
	OrderService.OrderRemoved:Fire(player, order, "Expired")
	fireEvent("OrderEvent", player, { kind = "Expired", orderId = order.id, order = order })
end

local function tickPlayer(player: Player, st: PlayerOrders, now: number)
	local changed = false
	for index = #st.available, 1, -1 do
		local order = st.available[index]
		if now >= order.availableUntil then
			expireOrder(player, st, order)
			changed = true
		end
	end
	for _, order in ipairs(table.clone(st.active)) do
		if order.state == "Accepted" and order.readyAt and now >= order.readyAt then
			markReady(player, order, now)
			changed = true
		end
		if order.timeLimit and order.acceptedAt and not (order :: any).lateNotified and now > order.acceptedAt + order.timeLimit then
			(order :: any).lateNotified = true
			fireEvent("OrderEvent", player, { kind = "Late", orderId = order.id, order = order })
		end
	end
	if changed then
		replicate(player)
	end
end

-- Finds an order owned by the player (any list). Returns order or nil.
local function findOwned(player: Player, orderId: any): Order?
	if type(orderId) ~= "string" then
		return nil
	end
	local order = ordersById[orderId]
	if not order or order.userId ~= player.UserId then
		return nil
	end
	return order
end

function OrderService.GetAvailable(player: Player): { Order }
	local st = states[player]
	return st and table.clone(st.available) or {}
end

function OrderService.GetActive(player: Player): { Order }
	local st = states[player]
	return st and table.clone(st.active) or {}
end

function OrderService.GetOrder(orderId: string): Order?
	return ordersById[orderId]
end

-- opts: { viaContract: boolean? }. Contract offers (order.contractId ~= nil) can only be accepted
-- through ContractService.Join (which passes viaContract); the AcceptOrder remote passes no opts,
-- so a client cannot take a single Lunch Rush offer outside the batch rules.
function OrderService.Accept(player: Player, orderId: string, opts)
	local st = states[player]
	local order = findOwned(player, orderId)
	if not st or not order then
		return fail("NotFound", "That order is no longer available")
	end
	if order.state ~= "Available" then
		return fail("WrongState", "That order was already accepted")
	end
	if order.contractId ~= nil and not (type(opts) == "table" and opts.viaContract == true) then
		return fail("Locked", "Join the Lunch Rush from the Contract tab")
	end
	local profile = getProfile(player)
	if not profile then
		return fail("Locked", "Your profile is still loading")
	end
	local progression = service("ProgressionService")
	if progression and not progression.IsMultiOrderUnlocked(profile) and #st.active > 0 then
		return fail("Locked", "Finish your current delivery first")
	end
	local capacity = OrderService.GetCapacityInfo(player)
	if capacity.committed + order.sizeUnits > capacity.max then
		return fail("NoCapacity", "You can't carry that much")
	end
	local now = os.clock()
	removeFromList(st.available, order)
	order.state = "Accepted"
	order.acceptedAt = now
	order.readyAt = now + (order.prepTime or 0)
	table.insert(st.active, order)
	OrderService.OrderAccepted:Fire(player, order)
	fireEvent("OrderEvent", player, { kind = "Accepted", orderId = order.id, order = order })
	if (order.prepTime or 0) <= 0 then
		markReady(player, order, now)
	end
	replicate(player)
	return ok({ order = order })
end

-- opts: { silent: boolean?, noPenalty: boolean?, reason: string? } (used by ContractService/cleanup)
function OrderService.Cancel(player: Player, orderId: string, opts)
	opts = opts or {}
	local st = states[player]
	local order = findOwned(player, orderId)
	if not st or not order then
		return fail("NotFound", "Unknown order")
	end
	if order.state ~= "Available" and not isActiveState(order.state) then
		return fail("WrongState", "That order can't be cancelled")
	end
	local wasCollected = order.state == "Collected"
	if wasCollected and not opts.noPenalty then
		local playerData = service("PlayerDataService")
		if playerData then
			playerData.Update(player, function(profile)
				profile.reputation = math.max(0, (profile.reputation or 0) - EconomyConfig.cancelCollectedPenalty)
			end)
		end
	end
	order.state = "Cancelled"
	finishOrder(player, st, order)
	OrderService.OrderRemoved:Fire(player, order, opts.reason or "Cancelled")
	if not opts.silent then
		fireEvent("OrderEvent", player, { kind = "Cancelled", orderId = order.id, order = order })
	end
	replicate(player)
	return ok()
end

local function playerPosition(player: Player): Vector3?
	local vehicles = service("VehicleService")
	if vehicles and vehicles.GetPlayerPosition then
		return vehicles.GetPlayerPosition(player)
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return root and root.Position or nil
end

local function positionCheck(player: Player): boolean
	local anti = service("AntiCheatService")
	if anti and anti.CheckPosition then
		return anti.CheckPosition(player)
	end
	return true
end

function OrderService.RequestPickup(player: Player, orderId: string)
	local st = states[player]
	local order = findOwned(player, orderId)
	if not st or not order or not isActiveState(order.state) then
		return fail("NotFound", "Unknown order")
	end
	local now = os.clock()
	if order.state == "Accepted" then
		if order.readyAt and now < order.readyAt then
			local secondsLeft = math.ceil(order.readyAt - now)
			return fail("NotReady", "The order is still being prepared", { secondsLeft = secondsLeft })
		end
		markReady(player, order, now)
	end
	if order.state ~= "ReadyForPickup" then
		return fail("WrongState", "That order was already collected")
	end
	local position = playerPosition(player)
	local pickup = positionsFor(order.businessId, order.destinationId)
	if not position or not pickup then
		return fail("Invalid", "No position")
	end
	if (position - pickup).Magnitude > EconomyConfig.pickupDistance then
		return fail("TooFar", "Get closer to the counter")
	end
	local capacity = OrderService.GetCapacityInfo(player)
	if capacity.load + order.sizeUnits > capacity.current then
		return fail("NoCapacity", "No room for that order on your vehicle")
	end
	if not positionCheck(player) then
		return fail("PositionCheck", "Hold on a moment and try again")
	end
	order.state = "Collected"
	order.collectedAt = now
	refreshPackages(player)
	OrderService.OrderCollected:Fire(player, order)
	fireEvent("OrderEvent", player, { kind = "Collected", orderId = order.id, order = order })
	local business = BusinessDefinitions.get(order.businessId)
	local lines = business and business.dialogue and business.dialogue.handoff or OrderDefinitions.PickupLines
	fireEvent("WorldEvent", player, { kind = "PickupReaction", businessId = order.businessId, line = pickLine(lines) })
	replicate(player)
	return ok({ order = order })
end

function OrderService.RequestDelivery(player: Player, orderId: string)
	local st = states[player]
	local order = findOwned(player, orderId)
	if not st or not order or not isActiveState(order.state) then
		return fail("NotFound", "Unknown order")
	end
	if order.state ~= "Collected" then
		return fail("WrongState", "Collect the order first")
	end
	local position = playerPosition(player)
	local _, door, arrival = positionsFor(order.businessId, order.destinationId)
	if not position or not door then
		return fail("Invalid", "No position")
	end
	local nearDoor = (position - door).Magnitude <= EconomyConfig.deliveryDistance
	local nearArrival = arrival ~= nil and (position - arrival).Magnitude <= EconomyConfig.deliveryArrivalDistance
	if not nearDoor and not nearArrival then
		return fail("TooFar", "Get closer to the door")
	end
	if not positionCheck(player) then
		return fail("PositionCheck", "Hold on a moment and try again")
	end
	local now = os.clock()
	order.state = "Delivered"
	order.deliveredAt = now
	-- Reward is granted synchronously before anything can yield; rewardGranted guards duplicates.
	local payout = nil
	local rewards = service("RewardService")
	if rewards then
		payout = rewards.GrantDeliveryPayout(player, order)
	end
	finishOrder(player, st, order)
	OrderService.OrderDelivered:Fire(player, order, payout)
	fireEvent("OrderEvent", player, { kind = "Delivered", orderId = order.id, order = order, payout = payout })
	local late = payout ~= nil and payout.lateSeconds > 0
	local lines = if late then OrderDefinitions.LateLines else OrderDefinitions.CustomerLines[order.itemCategory]
	fireEvent("WorldEvent", player, { kind = "DoorReaction", destinationId = order.destinationId, line = pickLine(lines) })
	refreshPackages(player)
	replicate(player)
	return ok({ payout = payout, order = order })
end

-------------------------------------------------------------------------------
-- Player lifecycle
-------------------------------------------------------------------------------

local function onProfileLoaded(player: Player, profile: Profile)
	local st = getState(player)
	st.generatorEnabled = profile.tutorial.completed == true
	if st.generatorEnabled then
		generateFor(player)
	end
	replicate(player)
end

local function onPlayerRemoving(player: Player)
	local st = states[player]
	if not st then
		return
	end
	for _, order in ipairs(table.clone(st.active)) do
		order.state = "Cancelled"
		ordersById[order.id] = nil
		OrderService.OrderRemoved:Fire(player, order, "Disconnected")
	end
	for _, order in ipairs(st.available) do
		ordersById[order.id] = nil
	end
	for orderId in pairs(st.packages) do
		destroyPackage(st, orderId)
	end
	states[player] = nil
end

function OrderService.Init(context)
	ctx = context
	PackageBuilder = (ctx.builders and ctx.builders.PackageBuilder) or DefaultPackageBuilder
	destinationInfo = nil
end

function OrderService.Start()
	local playerData = service("PlayerDataService")
	if playerData then
		playerData.ProfileLoaded:Connect(onProfileLoaded)
		for _, player in ipairs(Players:GetPlayers()) do
			local profile = playerData.GetProfile(player)
			if profile then
				onProfileLoaded(player, profile)
			end
		end
	end
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function()
			task.defer(refreshPackages, player)
		end)
	end)
	for _, player in ipairs(Players:GetPlayers()) do
		player.CharacterAdded:Connect(function()
			task.defer(refreshPackages, player)
		end)
	end

	local vehicles = service("VehicleService")
	if vehicles then
		vehicles.Mounted:Connect(function(player)
			refreshPackages(player)
		end)
		vehicles.Dismounted:Connect(function(player)
			refreshPackages(player)
		end)
	end

	running = true
	-- Generator loop
	task.spawn(function()
		while running do
			task.wait(EconomyConfig.generationInterval)
			for player in pairs(states) do
				local okGen, err = pcall(generateFor, player)
				if not okGen then
					warn("[OrderService] generation error:", err)
				end
			end
		end
	end)
	-- Tick loop
	task.spawn(function()
		while running do
			task.wait(EconomyConfig.orderTickInterval)
			local now = os.clock()
			for player, st in pairs(states) do
				local okTick, err = pcall(tickPlayer, player, st, now)
				if not okTick then
					warn("[OrderService] tick error:", err)
				end
			end
		end
	end)
end

-- Exposed for tests and tooling: run one generation pass / one tick immediately.
function OrderService.RunGeneration(player: Player)
	generateFor(player)
end

function OrderService.RunTick()
	local now = os.clock()
	for player, st in pairs(states) do
		tickPlayer(player, st, now)
	end
end

return OrderService
