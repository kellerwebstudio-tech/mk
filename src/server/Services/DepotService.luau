--!nonstrict
-- DepotService: depot ownership, per-session plot assignment, driver slots, assignments and
-- exactly-once collection of NPC driver earnings (docs/ARCHITECTURE.md 5.7).
--
-- Plots: `ctx.world.depotPlots` (built by CityBuilder) is the registry. A plot is claimed for the
-- session when an owner's profile loads (first free plot in id order) and released when they leave;
-- the plot model carries `PlotId`, `OwnerUserId` (0 = free) and `OwnerName` attributes.
-- Visuals go through DepotBuilder (apply/clear/setVanPresent), always guarded with pcall.
-- Simulation (assignment timing, completion) lives in DriverService; this service owns validation,
-- spending, profile mutation, proximity checks and replication (DepotUpdated, WorldEvent, Notify).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)
local Remotes = require(Shared.Util.Remotes)
local TableUtil = require(Shared.Util.TableUtil)
local EconomyConfig = require(Shared.Config.EconomyConfig)
local DepotDefinitions = require(Shared.Definitions.DepotDefinitions)

-- The builder module is optional at require time (guarded) and can be injected via ctx.builders.
local ServerRoot = script.Parent.Parent
local BuildersFolder = ServerRoot:FindFirstChild("Builders")
local depotBuilderModule = BuildersFolder and BuildersFolder:FindFirstChild("DepotBuilder")
local DefaultDepotBuilder: any = nil
if depotBuilderModule then
	local okRequire, result = pcall(require, depotBuilderModule)
	if okRequire and type(result) == "table" then
		DefaultDepotBuilder = result
	else
		warn("[DepotService] DepotBuilder failed to load:", result)
	end
end

type Profile = Types.Profile
type DriverSlot = Types.DriverSlot
type DepotPlotWorld = Types.DepotPlotWorld
type DepotPublicState = Types.DepotPublicState
type DepotCategoryView = Types.DepotCategoryView

local DepotService = {}

local ctx: any = nil
local DepotBuilder: any = nil
local rng = Random.new()

local plotIds: { string } = {} -- sorted plot ids (claim order)
local plotOwner: { [string]: Player } = {} -- plotId -> owner for this session
local ownerPlot: { [Player]: string } = {} -- player -> plotId
local pushScheduled: { [Player]: boolean } = {}

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

local function fireAll(name: string, payload)
	pcall(function()
		ctx.remotes.getEvent(name):FireAllClients(payload)
	end)
end

local function notify(player: Player, text: string, kind: string, duration: number?)
	fireEvent("Notify", player, { text = text, kind = kind, duration = duration })
end

local function formatNumber(value: number): string
	local text = tostring(math.floor(value + 0.5))
	local formatted = text:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if formatted:sub(1, 1) == "," then
		formatted = formatted:sub(2)
	end
	return formatted
end

local function plots(): { [string]: DepotPlotWorld }
	local world = ctx and ctx.world
	local registry = world and world.depotPlots
	return if type(registry) == "table" then registry else {}
end

local function refreshPlotIds()
	plotIds = {}
	for plotId in pairs(plots()) do
		table.insert(plotIds, plotId)
	end
	table.sort(plotIds)
end

local function getPlot(player: Player): DepotPlotWorld?
	local plotId = ownerPlot[player]
	return plotId and plots()[plotId] or nil
end

local function setPlotAttributes(plot: DepotPlotWorld, ownerUserId: number, ownerName: string)
	local model = plot.model
	if typeof(model) ~= "Instance" then
		return
	end
	pcall(function()
		model:SetAttribute("PlotId", plot.plotId or model.Name)
		model:SetAttribute("OwnerUserId", ownerUserId)
		model:SetAttribute("OwnerName", ownerName)
	end)
end

local function builderApply(player: Player, plot: DepotPlotWorld, profile: Profile)
	if DepotBuilder and type(DepotBuilder.apply) == "function" then
		local okApply, err = pcall(DepotBuilder.apply, plot, profile, player.Name, player.UserId)
		if not okApply then
			warn("[DepotService] DepotBuilder.apply failed:", err)
		end
	end
end

local function builderClear(plot: DepotPlotWorld)
	if DepotBuilder and type(DepotBuilder.clear) == "function" then
		local okClear, err = pcall(DepotBuilder.clear, plot)
		if not okClear then
			warn("[DepotService] DepotBuilder.clear failed:", err)
		end
	end
end

local function hiredCount(profile: Profile?): number
	local count = 0
	local drivers = profile and profile.depot and profile.depot.drivers
	for _, slot in ipairs(drivers or {}) do
		if slot.hired then
			count += 1
		end
	end
	return count
end

local function isValidSlot(slot: any): boolean
	return type(slot) == "number" and slot == math.floor(slot) and slot >= 1 and slot <= DepotDefinitions.maxSlots
end

local function newSlot(): DriverSlot
	return { hired = false, pending = 0 }
end

-- Makes sure the drivers array has an entry for every slot up to maxSlots.
local function ensureSlots(depot)
	if type(depot.drivers) ~= "table" then
		depot.drivers = {}
	end
	for index = 1, DepotDefinitions.maxSlots do
		local slot = depot.drivers[index]
		if type(slot) ~= "table" then
			depot.drivers[index] = newSlot()
		else
			if slot.hired == nil then
				slot.hired = false
			end
			if type(slot.pending) ~= "number" then
				slot.pending = 0
			end
		end
	end
end

local function pickDriverName(depot): string
	local used = {}
	for _, slot in ipairs(depot.drivers or {}) do
		if slot.name then
			used[slot.name] = true
		end
	end
	local candidates = {}
	for _, name in ipairs(DepotDefinitions.driverNames) do
		if not used[name] then
			table.insert(candidates, name)
		end
	end
	if #candidates == 0 then
		candidates = DepotDefinitions.driverNames
	end
	return candidates[rng:NextInteger(1, #candidates)]
end

-------------------------------------------------------------------------------
-- Public state
-------------------------------------------------------------------------------

-- Plots overview for social visits: every plot with its current session owner (0 = free).
function DepotService.GetPublicPlots(): { { plotId: string, ownerName: string, ownerUserId: number, drivers: number } }
	local result = {}
	for _, plotId in ipairs(plotIds) do
		local owner = plotOwner[plotId]
		local entry = { plotId = plotId, ownerName = "", ownerUserId = 0, drivers = 0 }
		if owner then
			entry.ownerName = owner.Name
			entry.ownerUserId = owner.UserId
			entry.drivers = hiredCount(getProfile(owner))
		end
		table.insert(result, entry)
	end
	return result
end

local function categoriesView(profile: Profile?): { DepotCategoryView }
	local progression = service("ProgressionService")
	local unlocked = {}
	if profile and progression and progression.GetUnlockedDriverCategories then
		for _, id in ipairs(progression.GetUnlockedDriverCategories(profile)) do
			unlocked[id] = true
		end
	elseif profile then
		for id, def in pairs(DepotDefinitions.Categories) do
			if (profile.reputation or 0) >= def.repRequired then
				unlocked[id] = true
			end
		end
	end
	local result = {}
	for _, id in ipairs(DepotDefinitions.CategoryOrder) do
		local def = DepotDefinitions.get(id)
		if def then
			local isUnlocked = unlocked[id] == true
			table.insert(result, {
				id = def.id,
				name = def.name,
				unlocked = isUnlocked,
				duration = def.duration,
				revenue = def.revenue,
				cost = def.cost,
				net = def.revenue - def.cost,
				requirement = if isUnlocked then nil else ("Requires " .. formatNumber(def.repRequired) .. " Rep"),
			})
		end
	end
	return result
end

function DepotService.GetStateFor(player: Player): DepotPublicState
	local profile = getProfile(player)
	local depot = profile and profile.depot
	local drivers = {}
	local pendingTotal = 0
	if depot and type(depot.drivers) == "table" then
		drivers = TableUtil.deepCopy(depot.drivers)
		for _, slot in ipairs(depot.drivers) do
			pendingTotal += slot.pending or 0
		end
	end
	local state: any = {
		owned = depot ~= nil and depot.owned == true,
		plotId = ownerPlot[player],
		slotsUnlocked = depot and depot.slotsUnlocked or 0,
		drivers = drivers,
		pendingTotal = pendingTotal,
		categories = categoriesView(profile),
		publicPlots = DepotService.GetPublicPlots(),
		serverTime = os.clock(),
	}
	return state
end

-- Coalesced DepotUpdated push (several changes in one frame produce one event).
local function flushPush(player: Player)
	pushScheduled[player] = nil
	if player.Parent == nil then
		return
	end
	fireEvent("DepotUpdated", player, DepotService.GetStateFor(player))
end

function DepotService.PushState(player: Player)
	if pushScheduled[player] then
		return
	end
	pushScheduled[player] = true
	task.defer(flushPush, player)
end

local function pushAll()
	for _, player in ipairs(Players:GetPlayers()) do
		DepotService.PushState(player)
	end
end

-------------------------------------------------------------------------------
-- Plot assignment
-------------------------------------------------------------------------------

-- Claims the first free plot for the player (idempotent). Returns the plot id or nil when none is free.
function DepotService.ClaimPlot(player: Player): string?
	local existing = ownerPlot[player]
	if existing then
		return existing
	end
	local registry = plots()
	if #plotIds == 0 then
		refreshPlotIds()
	end
	for _, plotId in ipairs(plotIds) do
		if not plotOwner[plotId] and registry[plotId] then
			local plot = registry[plotId]
			plotOwner[plotId] = player
			ownerPlot[player] = plotId
			setPlotAttributes(plot, player.UserId, player.Name)
			local profile = getProfile(player)
			if profile then
				builderApply(player, plot, profile)
			end
			pushAll()
			return plotId
		end
	end
	return nil
end

function DepotService.ReleasePlot(player: Player): boolean
	local plotId = ownerPlot[player]
	if not plotId then
		return false
	end
	ownerPlot[player] = nil
	plotOwner[plotId] = nil
	local plot = plots()[plotId]
	if plot then
		builderClear(plot)
		setPlotAttributes(plot, 0, "")
	end
	pushAll()
	return true
end

function DepotService.GetPlotId(player: Player): string?
	return ownerPlot[player]
end

function DepotService.GetPlot(player: Player): DepotPlotWorld?
	return getPlot(player)
end

-- Rebuilds the owner's depot visuals (after cosmetics or driver changes).
function DepotService.RefreshVisuals(player: Player)
	local plot = getPlot(player)
	local profile = getProfile(player)
	if plot and profile then
		builderApply(player, plot, profile)
		-- Re-apply van presence: drivers that are out keep their van away.
		for index, slot in ipairs(profile.depot.drivers or {}) do
			local assignment = slot.assignment
			if type(assignment) == "table" and not assignment.completed then
				DepotService.SetVanPresent(player, index, false)
			end
		end
	end
end

-- Shows/hides a slot's van (driver departed/returned) and tells every client. Returns true when
-- the player has a plot this session.
function DepotService.SetVanPresent(player: Player, slot: number, present: boolean): boolean
	local plotId = ownerPlot[player]
	local plot = plotId and plots()[plotId] or nil
	if not plot then
		return false
	end
	if DepotBuilder and type(DepotBuilder.setVanPresent) == "function" then
		local okSet, err = pcall(DepotBuilder.setVanPresent, plot, slot, present == true)
		if not okSet then
			warn("[DepotService] DepotBuilder.setVanPresent failed:", err)
		end
	end
	fireAll("WorldEvent", { kind = if present then "DriverReturn" else "DriverDepart", plotId = plotId, slot = slot })
	return true
end

-------------------------------------------------------------------------------
-- Purchases and driver management
-------------------------------------------------------------------------------

function DepotService.Purchase(player: Player)
	local profile = getProfile(player)
	if not profile then
		return fail("Locked", "Your profile is still loading")
	end
	local progression = service("ProgressionService")
	local playerData = service("PlayerDataService")
	if progression and progression.CanPurchaseDepot then
		local can, reason = progression.CanPurchaseDepot(profile)
		if not can then
			local messages = {
				AlreadyOwned = "You already own a depot",
				Requirements = "Requires " .. formatNumber(EconomyConfig.depotRepRequired) .. " Rep",
				Insufficient = "Not enough cash",
			}
			return fail(reason or "Requirements", messages[reason] or "You can't buy a depot yet")
		end
	elseif profile.depot.owned then
		return fail("AlreadyOwned", "You already own a depot")
	end
	if not playerData.TrySpendCash(player, EconomyConfig.depotPrice, "Depot") then
		return fail("Insufficient", "Not enough cash")
	end
	playerData.Update(player, function(p: Profile)
		local depot = p.depot
		depot.owned = true
		depot.slotsUnlocked = 1
		depot.drivers = {}
		ensureSlots(depot)
	end)
	local plotId = DepotService.ClaimPlot(player)
	if not plotId then
		warn("[DepotService] no free depot plot for", player.Name)
	end
	notify(player, "Depot purchased! Hire a driver to start earning.", "success")
	DepotService.PushState(player)
	return ok({ depot = DepotService.GetStateFor(player) })
end

function DepotService.UnlockSlot(player: Player)
	local profile = getProfile(player)
	if not profile then
		return fail("Locked", "Your profile is still loading")
	end
	local depot = profile.depot
	if not depot.owned then
		return fail("Locked", "Buy a depot first")
	end
	if (depot.slotsUnlocked or 0) >= DepotDefinitions.maxSlots then
		return fail("AlreadyOwned", "All driver slots are unlocked")
	end
	local playerData = service("PlayerDataService")
	if not playerData.TrySpendCash(player, DepotDefinitions.slot2Cost, "DepotSlot") then
		return fail("Insufficient", "Not enough cash")
	end
	playerData.Update(player, function(p: Profile)
		p.depot.slotsUnlocked = math.min(DepotDefinitions.maxSlots, (p.depot.slotsUnlocked or 0) + 1)
		ensureSlots(p.depot)
	end)
	notify(player, "Driver slot unlocked", "success")
	DepotService.PushState(player)
	return ok({ depot = DepotService.GetStateFor(player) })
end

function DepotService.HireDriver(player: Player, slot: number)
	local profile = getProfile(player)
	if not profile then
		return fail("Locked", "Your profile is still loading")
	end
	local depot = profile.depot
	if not depot.owned then
		return fail("Locked", "Buy a depot first")
	end
	if not isValidSlot(slot) then
		return fail("Invalid", "Invalid slot")
	end
	if slot > (depot.slotsUnlocked or 0) then
		return fail("Locked", "Unlock that slot first")
	end
	local entry = depot.drivers and depot.drivers[slot]
	if entry and entry.hired then
		return fail("AlreadyOwned", "That slot already has a driver")
	end
	local playerData = service("PlayerDataService")
	if not playerData.TrySpendCash(player, DepotDefinitions.hireCost, "HireDriver") then
		return fail("Insufficient", "Not enough cash")
	end
	local hiredName = nil
	playerData.Update(player, function(p: Profile)
		ensureSlots(p.depot)
		local target = p.depot.drivers[slot]
		target.hired = true
		target.name = pickDriverName(p.depot)
		target.pending = target.pending or 0
		hiredName = target.name
	end)
	local plot = getPlot(player)
	if plot then
		builderApply(player, plot, getProfile(player) :: Profile)
	end
	notify(player, string.format("%s joined your depot", tostring(hiredName or "A driver")), "success")
	pushAll() -- hired driver count shows on public plots
	return ok({ depot = DepotService.GetStateFor(player) })
end

function DepotService.AssignDriver(player: Player, slot: number, category: string)
	local profile = getProfile(player)
	if not profile then
		return fail("Locked", "Your profile is still loading")
	end
	local depot = profile.depot
	if not depot.owned then
		return fail("Locked", "Buy a depot first")
	end
	if not isValidSlot(slot) or slot > (depot.slotsUnlocked or 0) then
		return fail("Invalid", "Invalid slot")
	end
	local entry = depot.drivers and depot.drivers[slot]
	if not entry or not entry.hired then
		return fail("NotFound", "Hire a driver for that slot first")
	end
	local def = type(category) == "string" and DepotDefinitions.get(category) or nil
	if not def then
		return fail("NotFound", "Unknown assignment")
	end
	if (profile.reputation or 0) < def.repRequired then
		return fail("Requirements", "Requires " .. formatNumber(def.repRequired) .. " Rep")
	end
	local drivers = service("DriverService")
	local now = os.time()
	local current = entry.assignment
	if type(current) == "table" and not current.completed and current.endsAt > now then
		return fail("WrongState", "That driver is still out on a run")
	end
	local playerData = service("PlayerDataService")
	if not playerData.TrySpendCash(player, def.cost, "DriverAssignment") then
		return fail("Insufficient", "Not enough cash for the operating cost")
	end
	local assignment = nil
	playerData.Update(player, function(p: Profile)
		ensureSlots(p.depot)
		local target = p.depot.drivers[slot]
		-- A finished-but-uncollected run keeps its earnings: settle it into pending, then clear it.
		if drivers and drivers.Complete then
			drivers.Complete(target, now)
		elseif type(target.assignment) == "table" and not target.assignment.completed and target.assignment.endsAt <= now then
			target.assignment.completed = true
			target.pending = (target.pending or 0) + (target.assignment.revenue or 0)
		end
		target.assignment = nil
		if drivers and drivers.CreateAssignment then
			assignment = drivers.CreateAssignment(def.id, now)
		else
			assignment = {
				id = game:GetService("HttpService"):GenerateGUID(false),
				category = def.id,
				startedAt = now,
				endsAt = now + def.duration,
				revenue = def.revenue,
				cost = def.cost,
				net = def.revenue - def.cost,
				completed = false,
			}
		end
		target.assignment = assignment
	end)
	DepotService.SetVanPresent(player, slot, false)
	notify(player, string.format("%s left for %s", tostring(entry.name or "Your driver"), def.name), "info")
	DepotService.PushState(player)
	return ok({ depot = DepotService.GetStateFor(player), assignment = assignment })
end

function DepotService.Collect(player: Player)
	local profile = getProfile(player)
	if not profile then
		return fail("Locked", "Your profile is still loading")
	end
	local depot = profile.depot
	if not depot.owned then
		return fail("Locked", "Buy a depot first")
	end
	local plot = getPlot(player)
	if not plot then
		return fail("NotFound", "Your depot plot isn't ready")
	end
	local vehicles = service("VehicleService")
	local position = vehicles and vehicles.GetPlayerPosition and vehicles.GetPlayerPosition(player) or nil
	if not position then
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		position = root and root.Position or nil
	end
	if not position then
		return fail("Invalid", "No position")
	end
	local anchor = plot.origin.Position
	if (position - anchor).Magnitude > EconomyConfig.depotInteractDistance then
		return fail("TooFar", "Walk up to your depot to collect")
	end
	local total = 0
	for _, slot in ipairs(depot.drivers or {}) do
		total += slot.pending or 0
	end
	total = math.floor(total + 0.5)
	if total <= 0 then
		return fail("WrongState", "Nothing to collect yet")
	end
	local playerData = service("PlayerDataService")
	-- Exactly-once: zero every slot before any cash moves, remembering the amounts for a rollback.
	local snapshot = {}
	playerData.Update(player, function(p: Profile)
		for index, slot in ipairs(p.depot.drivers or {}) do
			snapshot[index] = slot.pending or 0
			slot.pending = 0
			if type(slot.assignment) == "table" and slot.assignment.completed then
				slot.assignment = nil
			end
		end
	end)
	if not playerData.AddCash(player, total, "DepotCollect") then
		playerData.Update(player, function(p: Profile)
			for index, amount in pairs(snapshot) do
				local slot = p.depot.drivers[index]
				if slot then
					slot.pending = (slot.pending or 0) + amount
				end
			end
		end)
		return fail("Internal", "Could not collect right now")
	end
	playerData.Update(player, function(p: Profile)
		local stats: any = p.stats
		stats.totalEarned = (stats.totalEarned or 0) + total
	end)
	notify(player, "Collected $" .. formatNumber(total) .. " from your drivers", "success")
	DepotService.PushState(player)
	return ok({ collected = total, depot = DepotService.GetStateFor(player) })
end

-- Aliases matching the remote names (InteractionService tries both).
DepotService.PurchaseDepot = DepotService.Purchase
DepotService.UnlockDriverSlot = DepotService.UnlockSlot
DepotService.CollectDepotEarnings = DepotService.Collect

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

local function onProfileLoaded(player: Player, profile: Profile)
	if profile.depot and profile.depot.owned then
		local playerData = service("PlayerDataService")
		-- Older profiles may lack slot entries; make the structure complete once.
		if type(profile.depot.drivers) ~= "table" or #profile.depot.drivers < DepotDefinitions.maxSlots then
			local applied = playerData and playerData.Update(player, function(p: Profile)
				ensureSlots(p.depot)
			end)
			if not applied then
				ensureSlots(profile.depot)
			end
		end
		DepotService.ClaimPlot(player)
		-- Drivers that are still out keep their van away.
		for index, slot in ipairs(profile.depot.drivers or {}) do
			local assignment = slot.assignment
			if type(assignment) == "table" and not assignment.completed then
				DepotService.SetVanPresent(player, index, false)
			end
		end
	end
	DepotService.PushState(player)
end

local function onPlayerRemoving(player: Player)
	DepotService.ReleasePlot(player)
	pushScheduled[player] = nil
end

function DepotService.Init(context)
	ctx = context
	DepotBuilder = (ctx.builders and ctx.builders.DepotBuilder) or DefaultDepotBuilder
	refreshPlotIds()
end

function DepotService.Start()
	refreshPlotIds()
	local playerData = service("PlayerDataService")
	if playerData and playerData.ProfileLoaded then
		playerData.ProfileLoaded:Connect(function(player: Player, profile: Profile)
			local okLoad, err = pcall(onProfileLoaded, player, profile)
			if not okLoad then
				warn("[DepotService] ProfileLoaded handler failed:", err)
			end
		end)
		for _, player in ipairs(Players:GetPlayers()) do
			local profile = playerData.GetProfile(player)
			if profile then
				pcall(onProfileLoaded, player, profile)
			end
		end
	end
	Players.PlayerRemoving:Connect(onPlayerRemoving)
end

return DepotService
