--!nonstrict
-- TutorialService: the first-session step machine (steps 0-9) driven by Order/Vehicle signals and
-- dismissable client acknowledgements. See docs/ARCHITECTURE.md 5.11.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)
local Signal = require(Shared.Util.Signal)
local Remotes = require(Shared.Util.Remotes)
local EconomyConfig = require(Shared.Config.EconomyConfig)
local OrderDefinitions = require(Shared.Definitions.OrderDefinitions)
local VehicleDefinitions = require(Shared.Definitions.VehicleDefinitions)
local RouteGraph = require(Shared.City.RouteGraph)

type Profile = Types.Profile
type Order = Types.Order

local TUTORIAL_BUSINESS = "SliceStreetPizza"
local STEP_DONE = 9
local STEP_BUY_UPGRADE = 8
local TUTORIAL_UPGRADE = "BasketI"
local POLL_INTERVAL = 1
local PICKUP_PROXIMITY_SLACK = 6

-- Steps that the client may dismiss with AdvanceTutorial(step).
local DISMISSABLE = { [0] = true, [6] = true, [8] = true, [9] = true }

local HINTS = {
	[0] = { title = "Welcome to Delivery Dash City", body = "You're a courier. Orders appear on your Dash app; pick them up at the business and ride them to the customer.", hint = "Tap Continue" },
	[1] = { title = "Your first order", body = "Slice Street Pizza has a pizza waiting. Open the order board and accept it.", hint = "Open Orders and press Accept" },
	[2] = { title = "Get on your bike", body = "Your courier bicycle is parked nearby. Walk up to it and hop on.", hint = "Press Ride next to the bike" },

	[3] = { title = "Ride to Slice Street", body = "Follow the route markers to the pizzeria. Alleys and bike paths are bicycle-only shortcuts.", hint = "Follow the glowing markers" },
	[4] = { title = "Collect the order", body = "Stop at the counter and grab the pizza.", hint = "Press Interact at the counter" },
	[5] = { title = "Deliver it", body = "Ride to the customer's door and hand it over before it gets cold.", hint = "Press Interact at the door" },
	[6] = { title = "You got paid!", body = "Base pay plus a tip for being quick. Cash buys upgrades; reputation unlocks new businesses and vehicles.", hint = "Tap Continue" },
	[7] = { title = "Second delivery", body = "Another order is up. Try a different route this time: the alley shortcut is bicycle-only.", hint = "Accept and deliver the order" },
	[8] = { title = "First upgrade", body = "Open the shop and buy Basket I to carry an extra order at once.", hint = "Open the Menu, then Upgrades" },
	[9] = { title = "You're ready", body = "The city is yours. Deliver more to unlock new businesses, the scooter, contracts and your own depot.", hint = "" },
}

-- Step 2 variant shown while the player has no vehicle spawned yet (a bike only exists after the
-- hub pad prompt); the server-sent text wins over the client fallback.
local HINT_STEP2_NO_VEHICLE = { title = "Get a bike", body = "Walk to a vehicle pad at the Dash Hub and take your courier bicycle, then hop on. You can also walk the first order if you like.", hint = "Press Take vehicle at the pad" }

type TutorialState = {
	step: number,
	firstOrderId: string?,
	secondOrderId: string?,
}

local TutorialService = {}

TutorialService.StepChanged = Signal.new()

local ctx: any = nil
local states: { [Player]: TutorialState } = {}
local tutorialDestinations: { string }? = nil
local running = false

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local function service(name: string)
	return ctx and ctx.services and ctx.services[name]
end

local function getProfile(player: Player): Profile?
	local playerData = service("PlayerDataService")
	return playerData and playerData.GetProfile(player) or nil
end

-- Text for a step. With a player, step 2 reflects whether a vehicle exists yet.
function TutorialService.GetHint(step: number, player: Player?)
	local hint = HINTS[step] or HINTS[0]
	if step == 2 and player ~= nil then
		local vehicles = service("VehicleService")
		if vehicles and vehicles.GetVehicle and vehicles.GetVehicle(player) == nil then
			hint = HINT_STEP2_NO_VEHICLE
		end
	end
	return { title = hint.title, body = hint.body, hint = hint.hint }
end

local function sendUpdate(player: Player, step: number, completed: boolean)
	local hint = TutorialService.GetHint(step, player)
	pcall(function()
		ctx.remotes.getEvent("TutorialUpdated"):FireClient(player, {
			step = step,
			completed = completed,
			title = hint.title,
			body = hint.body,
			hint = hint.hint,
		})
	end)
end

-- Destinations reachable from the tutorial business, sorted by bicycle route distance.
local function getTutorialDestinations(): { string }
	if tutorialDestinations then
		return tutorialDestinations
	end
	local world = ctx and ctx.world
	local result = {}
	if world and world.businesses and world.destinations and world.businesses[TUTORIAL_BUSINESS] then
		local pickup = world.businesses[TUTORIAL_BUSINESS].pickupPosition
		local entries = {}
		local layoutInfo = {}
		local layout = ctx.layout
		if type(layout) == "table" and type(layout.destinations) == "table" then
			for _, entry in ipairs(layout.destinations) do
				if entry.id then
					layoutInfo[entry.id] = entry
				end
			end
		end
		for destinationId, destination in pairs(world.destinations) do
			local info = layoutInfo[destinationId]
			local accepts = info and (info.accepts or OrderDefinitions.KindAccepts[info.kind]) or nil
			if accepts == nil or accepts.Small then
				local distance
				local graph = ctx.graph
				if graph and graph.edges and #graph.edges > 0 then
					local okPath, path, length = pcall(RouteGraph.findPath, graph, pickup, destination.doorPosition, VehicleDefinitions.Mask.Bicycle)
					if okPath and path and length < math.huge then
						distance = length
					end
				end
				if not distance then
					distance = (destination.doorPosition - pickup).Magnitude * 1.3
				end
				table.insert(entries, { id = destinationId, distance = distance })
			end
		end
		table.sort(entries, function(a, b)
			if a.distance == b.distance then
				return a.id < b.id
			end
			return a.distance < b.distance
		end)
		for _, entry in ipairs(entries) do
			table.insert(result, entry.id)
		end
	end
	if #result > 0 then
		tutorialDestinations = result
	end
	return result
end

local function injectTutorialOrder(player: Player, index: number): Order?
	local orders = service("OrderService")
	if not orders then
		return nil
	end
	local destinations = getTutorialDestinations()
	if #destinations == 0 then
		warn("[TutorialService] no tutorial destinations available")
		return nil
	end
	local destinationId = destinations[math.min(index, #destinations)]
	local pay = if index == 1 then EconomyConfig.tutorialFirstPay else EconomyConfig.tutorialSecondPay
	local okCreate, order = pcall(orders.CreateOrder, player, {
		businessId = TUTORIAL_BUSINESS,
		destinationId = destinationId,
		size = "Small",
		itemCategory = "Pizza",
		isTutorial = true,
		basePayOverride = pay,
		prepTimeOverride = 0,
		timeLimit = nil,
	})
	if not okCreate then
		warn("[TutorialService] CreateOrder failed:", order)
		return nil
	end
	orders.InjectOrders(player, { order })
	return order
end

-------------------------------------------------------------------------------
-- Step machine
-------------------------------------------------------------------------------

local setStep

local function enterStep(player: Player, state: TutorialState, step: number)
	if step == 1 then
		local order = injectTutorialOrder(player, 1)
		state.firstOrderId = order and order.id or nil
	elseif step == 7 then
		local order = injectTutorialOrder(player, 2)
		state.secondOrderId = order and order.id or nil
	elseif step == STEP_BUY_UPGRADE then
		local orders = service("OrderService")
		if orders then
			orders.SetGeneratorEnabled(player, true)
		end
	elseif step == STEP_DONE then
		local playerData = service("PlayerDataService")
		if playerData then
			playerData.AddReputation(player, EconomyConfig.tutorialCompletionBonus, "TutorialComplete")
		end
		local orders = service("OrderService")
		if orders then
			orders.SetGeneratorEnabled(player, true)
		end
	end
end

setStep = function(player: Player, step: number)
	local state = states[player]
	if not state then
		return
	end
	step = math.clamp(step, 0, STEP_DONE)
	state.step = step
	local completed = step >= STEP_DONE
	local playerData = service("PlayerDataService")
	if playerData then
		playerData.Update(player, function(profile: Profile)
			profile.tutorial.step = step
			profile.tutorial.completed = completed
		end)
	end
	pcall(function()
		player:SetAttribute("TutorialStep", step)
	end)
	enterStep(player, state, step)
	TutorialService.StepChanged:Fire(player, step)
	sendUpdate(player, step, completed)
end

local function onOrderAccepted(player: Player, order: Order)
	local state = states[player]
	if not state or not order.isTutorial then
		return
	end
	if state.step == 1 and order.id == state.firstOrderId then
		local vehicles = service("VehicleService")
		if vehicles and vehicles.IsDriving(player) then
			setStep(player, 3)
		else
			setStep(player, 2)
		end
	end
end

local function onMounted(player: Player)
	local state = states[player]
	if state and state.step == 2 then
		setStep(player, 3)
	end
end

-- A vehicle appearing (or vanishing) at step 2 changes the step-2 copy; re-send it.
local function onVehicleStateChanged(player: Player, vehicleState: string)
	local state = states[player]
	if state and state.step == 2 and (vehicleState == "Parked" or vehicleState == "Despawning") then
		sendUpdate(player, 2, false)
	end
end

-- Walking the first order is allowed (pickup/delivery are not vehicle-gated), so the collect
-- transition tolerates a skipped mount (step 2) as well as steps 3/4.
local function onOrderCollected(player: Player, order: Order)
	local state = states[player]
	if not state or not order.isTutorial then
		return
	end
	if state.step >= 2 and state.step <= 4 and order.id == state.firstOrderId then
		setStep(player, 5)
	end
end

local function onOrderDelivered(player: Player, order: Order)
	local state = states[player]
	if not state or not order.isTutorial then
		return
	end
	if state.step <= 5 and order.id == state.firstOrderId then
		setStep(player, 6)
	elseif state.step == 7 and order.id == state.secondOrderId then
		setStep(player, STEP_BUY_UPGRADE)
	end
end

local function onOrderRemoved(player: Player, order: Order, reason: string)
	local state = states[player]
	if not state or not order.isTutorial or reason == "Disconnected" then
		return
	end
	-- A cancelled/expired tutorial order is re-issued so the player can never get stuck.
	if order.id == state.firstOrderId and state.step >= 1 and state.step <= 5 then
		setStep(player, 1)
	elseif order.id == state.secondOrderId and state.step == 7 then
		setStep(player, 7)
	end
end

-- 1 s poll: pickup proximity for steps 2/3 (a walker reaches the counter without mounting) and
-- the upgrade purchase for step 8.
local function pollPlayer(player: Player, state: TutorialState)
	if state.step == 2 or state.step == 3 then
		local vehicles = service("VehicleService")
		local world = ctx.world
		local business = world and world.businesses and world.businesses[TUTORIAL_BUSINESS]
		local position = vehicles and vehicles.GetPlayerPosition(player)
		if business and position then
			if (position - business.pickupPosition).Magnitude <= EconomyConfig.pickupDistance + PICKUP_PROXIMITY_SLACK then
				setStep(player, 4)
			end
		end
	elseif state.step == STEP_BUY_UPGRADE then
		local progression = service("ProgressionService")
		local profile = getProfile(player)
		if progression and profile and progression.GetUpgradeLevel(profile, TUTORIAL_UPGRADE) > 0 then
			setStep(player, STEP_DONE)
		end
	end
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

function TutorialService.GetStep(player: Player): number?
	local state = states[player]
	return state and state.step or nil
end

function TutorialService.AdvanceTutorial(player: Player, step: number)
	local state = states[player]
	if not state then
		return Remotes.fail("Locked", "Your profile is still loading")
	end
	if type(step) ~= "number" or step ~= step or step ~= math.floor(step) then
		return Remotes.fail("Invalid", "Invalid step")
	end
	if step < state.step then
		-- Stale acknowledgement: nothing to do.
		return Remotes.ok({ step = state.step })
	end
	if step > state.step then
		return Remotes.fail("WrongState", "That step isn't active")
	end
	if not DISMISSABLE[step] then
		return Remotes.fail("Invalid", "That step completes itself")
	end
	if step == 0 then
		setStep(player, 1)
	elseif step == 6 then
		setStep(player, 7)
	elseif step == STEP_BUY_UPGRADE then
		setStep(player, STEP_DONE)
	end
	return Remotes.ok({ step = state.step })
end

local function onProfileLoaded(player: Player, profile: Profile)
	if profile.tutorial.completed then
		states[player] = nil
		pcall(function()
			player:SetAttribute("TutorialStep", STEP_DONE)
		end)
		local orders = service("OrderService")
		if orders then
			orders.SetGeneratorEnabled(player, true)
		end
		sendUpdate(player, STEP_DONE, true)
		return
	end
	local state: TutorialState = { step = 0, firstOrderId = nil, secondOrderId = nil }
	states[player] = state
	local resume = tonumber(profile.tutorial.step) or 0
	-- Orders are not persisted, so a returning player restarts the phase they were in.
	if resume >= 1 and resume <= 6 then
		resume = 1
	elseif resume > STEP_DONE then
		resume = STEP_DONE
	end
	setStep(player, resume)
end

-- Studio tooling (DevService "SkipTutorial"): completes the tutorial through the normal step-9
-- path (completion bonus, generator enabled, TutorialUpdated). Returns false when the profile is
-- missing or already completed. Outstanding tutorial orders are left to the caller.
function TutorialService.Complete(player: Player): boolean
	local profile = getProfile(player)
	if not profile then
		return false
	end
	local state = states[player]
	if not state then
		if profile.tutorial.completed then
			return false
		end
		state = { step = tonumber(profile.tutorial.step) or 0, firstOrderId = nil, secondOrderId = nil }
		states[player] = state
	end
	if state.step >= STEP_DONE then
		return false
	end
	setStep(player, STEP_DONE)
	return true
end

-- Studio tooling (DevService "ResetProfile"): forgets the in-session state and re-runs the
-- profile-load path, so a profile whose tutorial fields were reset starts again at step 0.
function TutorialService.Restart(player: Player): boolean
	local profile = getProfile(player)
	if not profile then
		return false
	end
	states[player] = nil
	onProfileLoaded(player, profile)
	return true
end

function TutorialService.Init(context)
	ctx = context
	tutorialDestinations = nil
end

function TutorialService.Start()
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
	local orders = service("OrderService")
	if orders then
		orders.OrderAccepted:Connect(onOrderAccepted)
		orders.OrderCollected:Connect(onOrderCollected)
		orders.OrderDelivered:Connect(onOrderDelivered)
		orders.OrderRemoved:Connect(onOrderRemoved)
	end
	local vehicles = service("VehicleService")
	if vehicles then
		vehicles.Mounted:Connect(onMounted)
		if vehicles.StateChanged then
			vehicles.StateChanged:Connect(onVehicleStateChanged)
		end
	end
	Players.PlayerRemoving:Connect(function(player)
		states[player] = nil
	end)
	running = true
	task.spawn(function()
		while running do
			task.wait(POLL_INTERVAL)
			for player, state in pairs(states) do
				local okPoll, err = pcall(pollPlayer, player, state)
				if not okPoll then
					warn("[TutorialService] poll error:", err)
				end
			end
		end
	end)
end

return TutorialService
