--!nonstrict
-- DriverService: NPC driver assignment simulation for the depot (docs/ARCHITECTURE.md 5.7).
-- The simulation itself is pure (CreateAssignment / Complete / CompleteDue operate on profile
-- tables with explicit timestamps); the service part runs the 5 s tick over online depot owners,
-- settles already-due assignments when a profile loads (offline completion of the single paid
-- assignment, never a requeue) and asks DepotService for the depart/return visuals and pushes.
--
-- Timestamps are os.time() because assignments persist across sessions.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)
local Signal = require(Shared.Util.Signal)
local DepotDefinitions = require(Shared.Definitions.DepotDefinitions)

type Profile = Types.Profile
type DriverSlot = Types.DriverSlot
type DriverAssignment = Types.DriverAssignment

local DriverService = {}

DriverService.TICK_INTERVAL = 5 -- seconds between completion passes (section 11 budget)

-- Fired when an assignment completes while the owner is online: (player, slotIndex, assignment).
DriverService.AssignmentCompleted = Signal.new()

local ctx: any = nil
local running = false

local function service(name: string)
	return ctx and ctx.services and ctx.services[name]
end

-------------------------------------------------------------------------------
-- Pure simulation
-------------------------------------------------------------------------------

-- Builds a fresh assignment for a driver category starting at `now` (os.time()).
-- The operating cost is paid up front by DepotService; `net` is informational.
function DriverService.CreateAssignment(category: string, now: number): DriverAssignment
	local def = DepotDefinitions.get(category)
	assert(def ~= nil, "Unknown driver category " .. tostring(category))
	local startedAt = math.floor(now)
	return {
		id = HttpService:GenerateGUID(false),
		category = def.id,
		startedAt = startedAt,
		endsAt = startedAt + def.duration,
		revenue = def.revenue,
		cost = def.cost,
		net = def.revenue - def.cost,
		completed = false,
	}
end

-- Marks the slot's assignment completed when it is due and moves its revenue into the slot's
-- pending (uncollected) cash exactly once. Returns true only when this call completed it.
function DriverService.Complete(slot: DriverSlot, now: number): boolean
	local assignment = slot and slot.assignment
	if type(assignment) ~= "table" or assignment.completed then
		return false
	end
	if type(assignment.endsAt) ~= "number" or assignment.endsAt > now then
		return false
	end
	assignment.completed = true
	slot.pending = (slot.pending or 0) + (assignment.revenue or 0)
	return true
end

-- Completes every due assignment on the profile. Returns the number completed by this call.
function DriverService.CompleteDue(profile: Profile, now: number): number
	local depot = profile and profile.depot
	if type(depot) ~= "table" or type(depot.drivers) ~= "table" then
		return 0
	end
	local count = 0
	for _, slot in ipairs(depot.drivers) do
		if DriverService.Complete(slot, now) then
			count += 1
		end
	end
	return count
end

-- Indices of slots that are currently out on an unfinished assignment.
function DriverService.GetActiveSlots(profile: Profile): { number }
	local result = {}
	local depot = profile and profile.depot
	if type(depot) ~= "table" or type(depot.drivers) ~= "table" then
		return result
	end
	for index, slot in ipairs(depot.drivers) do
		local assignment = slot.assignment
		if type(assignment) == "table" and not assignment.completed then
			table.insert(result, index)
		end
	end
	return result
end

-------------------------------------------------------------------------------
-- Service part
-------------------------------------------------------------------------------

-- Runs the completion pass for one online player. Returns the slot indices completed now.
local function settlePlayer(player: Player, now: number): { number }
	local playerData = service("PlayerDataService")
	if not playerData then
		return {}
	end
	local profile = playerData.GetProfile(player)
	if not profile or not profile.depot or not profile.depot.owned then
		return {}
	end
	-- Quick check without a profile update (avoids marking every owner dirty each tick).
	local due = false
	for _, slot in ipairs(profile.depot.drivers or {}) do
		local assignment = slot.assignment
		if type(assignment) == "table" and not assignment.completed and assignment.endsAt <= now then
			due = true
			break
		end
	end
	if not due then
		return {}
	end
	local completedSlots = {}
	local completedAssignments = {}
	playerData.Update(player, function(p: Profile)
		for index, slot in ipairs(p.depot.drivers or {}) do
			if DriverService.Complete(slot, now) then
				table.insert(completedSlots, index)
				table.insert(completedAssignments, slot.assignment)
			end
		end
	end)
	local depot = service("DepotService")
	for i, slotIndex in ipairs(completedSlots) do
		if depot and depot.SetVanPresent then
			pcall(depot.SetVanPresent, player, slotIndex, true)
		end
		DriverService.AssignmentCompleted:Fire(player, slotIndex, completedAssignments[i])
	end
	if #completedSlots > 0 and depot and depot.PushState then
		pcall(depot.PushState, player)
	end
	return completedSlots
end

-- One completion pass over every online depot owner. Returns the total completed.
function DriverService.Tick(): number
	local now = os.time()
	local total = 0
	for _, player in ipairs(Players:GetPlayers()) do
		local okTick, result = pcall(settlePlayer, player, now)
		if okTick then
			total += #result
		else
			warn("[DriverService] tick error:", result)
		end
	end
	return total
end

-- Settles assignments that finished while the player was offline. Only the one paid assignment per
-- slot completes (into pending); nothing new starts offline. Returns the number completed.
function DriverService.OnProfileLoaded(player: Player, profile: Profile): number
	if not profile or not profile.depot or not profile.depot.owned then
		return 0
	end
	local now = os.time()
	local playerData = service("PlayerDataService")
	local completed = 0
	local completedSlots = {}
	local completedAssignments = {}
	local function settle(p: Profile)
		for index, slot in ipairs(p.depot.drivers or {}) do
			if DriverService.Complete(slot, now) then
				completed += 1
				table.insert(completedSlots, index)
				table.insert(completedAssignments, slot.assignment)
			end
		end
	end
	local applied = false
	if playerData and playerData.Update then
		applied = playerData.Update(player, settle) == true
	end
	if not applied then
		settle(profile)
	end
	local depot = service("DepotService")
	if depot then
		-- Vans of drivers that are still out stay away; completed ones are back.
		for index, slot in ipairs(profile.depot.drivers or {}) do
			local assignment = slot.assignment
			if type(assignment) == "table" and depot.SetVanPresent then
				pcall(depot.SetVanPresent, player, index, assignment.completed == true)
			end
		end
		if depot.PushState then
			pcall(depot.PushState, player)
		end
	end
	for i, slotIndex in ipairs(completedSlots) do
		DriverService.AssignmentCompleted:Fire(player, slotIndex, completedAssignments[i])
	end
	return completed
end

function DriverService.Init(context)
	ctx = context
end

function DriverService.Start()
	local playerData = service("PlayerDataService")
	if playerData and playerData.ProfileLoaded then
		playerData.ProfileLoaded:Connect(function(player: Player, profile: Profile)
			local okLoad, err = pcall(DriverService.OnProfileLoaded, player, profile)
			if not okLoad then
				warn("[DriverService] OnProfileLoaded failed:", err)
			end
		end)
		for _, player in ipairs(Players:GetPlayers()) do
			local profile = playerData.GetProfile(player)
			if profile then
				pcall(DriverService.OnProfileLoaded, player, profile)
			end
		end
	end
	running = true
	task.spawn(function()
		while running do
			task.wait(DriverService.TICK_INTERVAL)
			DriverService.Tick()
		end
	end)
end

-- Stops the tick loop (tests / shutdown).
function DriverService.Stop()
	running = false
end

return DriverService
