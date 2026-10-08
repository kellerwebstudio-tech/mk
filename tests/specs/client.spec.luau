--!nonstrict
-- tests/specs/client.spec.luau
-- Offline specs for the client runtime: ClientState, the pure vehicle model, navigation target
-- selection, interaction proximity gating, input gating, audio, tutorial, settings, cosmetics
-- and the bootstrap script. The UIController is written by another agent, so every spec stubs it.

-- The shim's StarterPlayer constructor pre-creates an empty StarterPlayerScripts and the bundled
-- tree adds a second one holding DeliveryDashClient, so shim.requirePath("StarterPlayer/...") hits
-- the empty one. The client root is therefore located by scanning StarterPlayer's children.
local function clientRoot()
	local starterPlayer = game:GetService("StarterPlayer")
	for _, child in ipairs(starterPlayer:GetChildren()) do
		local root = child:FindFirstChild("DeliveryDashClient")
		if root then
			return root
		end
	end
	error("DeliveryDashClient not found under StarterPlayer")
end

local function clientInstance(relativePath)
	local current = clientRoot()
	for segment in relativePath:gmatch("[^/]+") do
		local nxt = current:FindFirstChild(segment)
		if not nxt then
			error("No client instance at " .. relativePath .. " (missing " .. segment .. ")")
		end
		current = nxt
	end
	return current
end

local function requireClient(relativePath)
	return require(clientInstance(relativePath))
end

local function requireShared(path)
	local node = game:GetService("ReplicatedStorage").Shared
	for segment in string.gmatch(path, "[^/]+") do
		node = node[segment]
	end
	return require(node)
end

-- Every `it` starts from a fresh DataModel, so services are looked up lazily through `game`.
local function svc(name)
	return game:GetService(name)
end

local function v3(x, y, z)
	return Vector3.new(x, y, z)
end

-------------------------------------------------------------------------------
-- Fake layout: a cross of roads plus a bicycle-only alley, two businesses, two destinations
-------------------------------------------------------------------------------

local LAYOUT = {
	name = "ClientTestCity",
	bounds = { minX = -400, maxX = 400, minZ = -400, maxZ = 400 },
	groundY = 0,
	killY = -60,
	neighborhoods = {
		{ id = "Downtown", name = "Downtown", center = { x = 0, z = -50 }, bounds = { minX = -400, maxX = 400, minZ = -400, maxZ = 100 }, accent = { r = 1, g = 0.5, b = 0.2 } },
		{ id = "Industrial", name = "Dockside", center = { x = 0, z = 300 }, bounds = { minX = -400, maxX = 400, minZ = 150, maxZ = 400 }, accent = { r = 0.4, g = 0.55, b = 0.8 } },
	},
	roads = {
		{ id = "Main", name = "Main Street", kind = "Road", width = 12, points = { { x = -300, z = 0 }, { x = 300, z = 0 } }, sidewalk = true, oneWay = false },
		{ id = "North", name = "North Avenue", kind = "Street", width = 8, points = { { x = 0, z = 0 }, { x = 0, z = -300 } }, sidewalk = true, oneWay = false },
		{ id = "South", name = "South Road", kind = "Road", width = 12, points = { { x = 0, z = 0 }, { x = 0, z = 300 } }, sidewalk = true, oneWay = false },
		{ id = "Alley", name = "Back Alley", kind = "Alley", width = 5, points = { { x = -100, z = 0 }, { x = -100, z = -200 } }, sidewalk = false, oneWay = false },
	},
	water = {},
	bridges = {},
	buildings = {},
	businesses = {
		{ id = "SliceStreetPizza", name = "Slice Street Pizza", neighborhood = "Downtown", door = { x = -20, z = -14 }, facing = { x = 0, z = 1 }, pickupPoint = { x = -20, z = -9 }, arrivalPoint = { x = -20, z = -5 } },
		{ id = "BeanAndBunCafe", name = "Bean & Bun Cafe", neighborhood = "Downtown", door = { x = 60, z = 14 }, facing = { x = 0, z = -1 }, pickupPoint = { x = 60, z = 9 }, arrivalPoint = { x = 60, z = 5 } },
	},
	destinations = {
		{ id = "D_Near", address = "1 Main Street", neighborhood = "Downtown", kind = "Apartment", door = { x = 120, z = -12 }, facing = { x = 0, z = 1 }, arrivalPoint = { x = 120, z = -5 }, accepts = { Small = true, Medium = true, Large = false } },
		{ id = "D_Far", address = "3 South Road", neighborhood = "Industrial", kind = "House", door = { x = 12, z = 260 }, facing = { x = -1, z = 0 }, arrivalPoint = { x = 5, z = 260 }, accepts = { Small = true, Medium = true, Large = true } },
	},
	landmarks = { plaza = { x = 0, z = 0, r = 30 }, park = { x = 200, z = -200, w = 40, d = 40 }, hub = { x = 0, z = 30 } },
	hub = { spawn = { x = 0, z = 30, facing = { x = 0, z = -1 } }, vehiclePads = { { x = 10, z = 30, facing = { x = 0, z = -1 } } }, kiosk = { x = 0, z = 40 } },
	depotPlots = { { id = "P1", x = 80, z = 80, w = 40, d = 30, facing = { x = 0, z = -1 }, parking = {} } },
	pedestrianPaths = { { id = "Loop", loop = true, points = { { x = 0, z = 0 }, { x = 20, z = 0 }, { x = 20, z = 20 }, { x = 0, z = 20 } } } },
	parkedVehicles = {},
	props = {},
	bikeShortcuts = {},
}

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local function makeOrder(id, state, businessId, destinationId, extra)
	local order = {
		id = id,
		userId = 1,
		businessId = businessId or "SliceStreetPizza",
		destinationId = destinationId or "D_Near",
		itemCategory = "Pizza",
		size = "Small",
		sizeUnits = 1,
		packageKey = "PizzaBox",
		itemLabel = "Margherita pizza",
		basePay = 40,
		tipMax = 12,
		repReward = 6,
		timeLimit = nil,
		availableUntil = os.clock() + 100,
		prepTime = 0,
		routeDistance = 200,
		createdAt = os.clock(),
		state = state or "Accepted",
	}
	for key, value in pairs(extra or {}) do
		order[key] = value
	end
	return order
end

-- UIController stand-in recording every call it receives.
local function newUIStub()
	local Signal = shim.requirePath("ReplicatedStorage/Shared/Util/Signal")
	local ui = {
		modal = false,
		prompt = nil,
		notifications = {},
		openedScreens = {},
		navigation = nil,
		minimap = nil,
		results = {},
		tutorial = nil,
		tutorialCalls = 0,
		hud = nil,
		depotFor = nil,
		ModalChanged = Signal.new(),
		TutorialContinue = Signal.new(),
		PromptActivated = Signal.new(),
	}
	function ui.Init() end
	function ui.Start() end
	function ui.ShowPrompt(spec)
		ui.prompt = spec
	end
	function ui.HidePrompt()
		ui.prompt = nil
	end
	function ui.Notify(text, kind, duration)
		table.insert(ui.notifications, { text = text, kind = kind, duration = duration })
	end
	function ui.OpenScreen(name)
		table.insert(ui.openedScreens, name)
	end
	function ui.CloseScreen() end
	function ui.ToggleScreen(name)
		table.insert(ui.openedScreens, name)
	end
	function ui.IsModalOpen()
		return ui.modal
	end
	function ui.SetNavigation(nav)
		ui.navigation = nav
	end
	function ui.SetMinimap(data)
		ui.minimap = data
	end
	function ui.ShowResults(payout, order)
		table.insert(ui.results, { payout = payout, order = order })
	end
	function ui.SetTutorial(spec)
		ui.tutorial = spec
		ui.tutorialCalls += 1
	end
	function ui.SetVehicleHud(data)
		ui.hud = data
	end
	function ui.GetScreenGui()
		return nil
	end
	function ui.OpenDepotFor(plotId)
		ui.depotFor = plotId
	end
	return ui
end

local function buildGraph(layout)
	local ok, RouteGraph = pcall(shim.requirePath, "ReplicatedStorage/Shared/City/RouteGraph")
	if ok and RouteGraph then
		return RouteGraph.build(layout)
	end
	-- Stub graph: straight lines only (used only if RouteGraph were missing).
	return { nodes = {}, edges = {}, adjacency = {} }
end

-- Creates every remote with a default "ok" handler; opts.handlers overrides per name.
local function createRemotes(handlers)
	local Remotes = shim.requirePath("ReplicatedStorage/Shared/Util/Remotes")
	Remotes.createAll()
	for _, name in ipairs(Remotes.Functions) do
		local remote = Remotes.getFunction(name)
		remote.OnServerInvoke = (handlers and handlers[name]) or function()
			return { ok = true }
		end
	end
	return Remotes
end

-- Builds the ClientContext, requires the named controllers, stubs the UI and runs Init/Start.
local function setup(controllerNames, opts)
	opts = opts or {}
	shim.setContext("client")
	local ClientState = requireClient("ClientState")
	local layout = opts.layout or LAYOUT
	ClientState.setLayout(layout)
	local Remotes = createRemotes(opts.handlers)
	local ui = newUIStub()
	local ctx = {
		state = ClientState,
		remotes = Remotes,
		layout = layout,
		graph = opts.graph or (opts.noGraph and nil or buildGraph(layout)),
		controllers = { UIController = ui },
	}
	local ordered = {}
	for _, name in ipairs(controllerNames) do
		local controller = requireClient("Controllers/" .. name)
		ctx.controllers[name] = controller
		table.insert(ordered, controller)
	end
	for _, controller in ipairs(ordered) do
		controller.Init(ctx)
	end
	for _, controller in ipairs(ordered) do
		controller.Start()
	end
	return ctx, ui, ClientState
end

-- The project tree already defines Workspace.PickupLocations / DeliveryDestinations / Runtime, so
-- world fixtures reuse those folders instead of creating a second one with the same name.
local function workspaceFolder(name)
	local workspace = svc("Workspace")
	local existing = workspace:FindFirstChild(name)
	if existing then
		return existing
	end
	local created = Instance.new("Folder")
	created.Name = name
	created.Parent = workspace
	return created
end

local function spawnAt(x, z)
	local player = svc("Players").LocalPlayer
	local character = shim.spawnCharacter(player, CFrame.new(x, 3, z))
	return character
end

local function moveTo(character, x, z)
	character:PivotTo(CFrame.new(x, 3, z))
end

-- Minimal vehicle model matching VehicleBuilder's structure (ARCHITECTURE 8.3).
local function buildVehicleModel(vehicleId, ownerUserId, position)
	local VehicleDefinitions = shim.requirePath("ReplicatedStorage/Shared/Definitions/VehicleDefinitions")
	local def = VehicleDefinitions.get(vehicleId)
	local model = Instance.new("Model")
	model.Name = "Vehicle"
	model:SetAttribute("OwnerUserId", ownerUserId)
	model:SetAttribute("VehicleId", vehicleId)
	model:SetAttribute("State", "Parked")
	model:SetAttribute("Capacity", def.baseCapacity)

	local chassis = Instance.new("Part")
	chassis.Name = "Chassis"
	chassis.Size = v3(def.chassisSize[1], def.chassisSize[2], def.chassisSize[3])
	chassis.CFrame = CFrame.new(position + v3(0, def.handling.rideHeight, 0))
	chassis.Anchored = true
	chassis.Transparency = 1
	chassis.Parent = model
	model.PrimaryPart = chassis

	local root = Instance.new("Attachment")
	root.Name = "RootAttachment"
	root.Parent = chassis
	local align = Instance.new("AlignOrientation")
	align.Name = "Align"
	align.Attachment0 = root
	align.Parent = chassis
	local velocity = Instance.new("LinearVelocity")
	velocity.Name = "Velocity"
	velocity.Attachment0 = root
	velocity.VectorVelocity = Vector3.zero
	velocity.Parent = chassis
	local cargo = Instance.new("Attachment")
	cargo.Name = "CargoAttachment"
	cargo.Parent = chassis
	local dismount = Instance.new("Attachment")
	dismount.Name = "DismountAttachment"
	dismount.Parent = chassis
	local engine = Instance.new("Sound")
	engine.Name = "EngineSound"
	engine.SoundId = ""
	engine.Parent = chassis

	local bodyRoot = Instance.new("Part")
	bodyRoot.Name = "BodyRoot"
	bodyRoot.Size = v3(1, 1, 1)
	bodyRoot.Transparency = 1
	bodyRoot.CanCollide = false
	bodyRoot.Massless = true
	bodyRoot.CFrame = chassis.CFrame
	bodyRoot.Parent = model
	local bodyMotor = Instance.new("Motor6D")
	bodyMotor.Name = "BodyMotor"
	bodyMotor.Part0 = chassis
	bodyMotor.Part1 = bodyRoot
	bodyMotor.Parent = bodyRoot

	local seat = Instance.new("VehicleSeat")
	seat.Name = "Seat"
	seat.Disabled = true
	seat.CFrame = chassis.CFrame * CFrame.new(def.seatOffset[1], def.seatOffset[2], def.seatOffset[3])
	seat.Parent = model

	local body = Instance.new("Folder")
	body.Name = "Body"
	body.Parent = model

	local wheels = Instance.new("Folder")
	wheels.Name = "Wheels"
	for _, spec in ipairs(def.visual.wheels) do
		local wheel = Instance.new("Part")
		wheel.Name = spec.name
		wheel.Shape = Enum.PartType.Cylinder
		wheel.Size = v3(spec.width, spec.radius * 2, spec.radius * 2)
		wheel.CFrame = chassis.CFrame * CFrame.new(spec.offset[1], spec.offset[2], spec.offset[3])
		wheel:SetAttribute("Steerable", spec.steerable)
		wheel:SetAttribute("Radius", spec.radius)
		local motor = Instance.new("Motor6D")
		motor.Name = "WheelMotor"
		motor.Part0 = bodyRoot
		motor.Part1 = wheel
		motor.Parent = wheel
		wheel.Parent = wheels
	end
	wheels.Parent = model

	local cargoFolder = Instance.new("Folder")
	cargoFolder.Name = "Cargo"
	cargoFolder.Parent = model

	local runtime = svc("Workspace"):FindFirstChild("Runtime")
	local folder = runtime and runtime:FindFirstChild("Vehicles")
	model.Parent = folder or svc("Workspace")
	return model, chassis, seat, velocity
end

local function setOrders(ClientState, active, available)
	ClientState.set("orders", { available = available or {}, active = active, capacity = { current = 1, max = 1, load = 0, committed = #active }, serverTime = os.clock() })
end

-------------------------------------------------------------------------------
-- ClientState
-------------------------------------------------------------------------------

describe("ClientState", function()
	local ClientState

	beforeEach(function()
		shim.setContext("client")
		ClientState = requireClient("ClientState")
		ClientState.setLayout(LAYOUT)
	end)

	it("stores values and fires Changed on new references and on tables", function()
		local fired = {}
		ClientState.Changed:Connect(function(key, value)
			table.insert(fired, key)
		end)
		ClientState.set("serverTimeOffset", 5)
		ClientState.set("serverTimeOffset", 5) -- same number: no event
		ClientState.set("serverTimeOffset", 6)
		local profile = { cash = 10 }
		ClientState.set("profile", profile)
		ClientState.set("profile", profile) -- tables always re-fire (snapshots)
		expect(ClientState.get("serverTimeOffset")).toBe(6)
		expect(ClientState.get("profile")).toBe(profile)
		expect(fired).toEqual({ "serverTimeOffset", "serverTimeOffset", "profile", "profile" })
	end)

	it("onChange calls immediately and again on every change of that key", function()
		local seen = {}
		local connection = ClientState.onChange("device", function(value)
			table.insert(seen, value)
		end)
		ClientState.set("device", "Touch")
		ClientState.set("profile", { cash = 1 }) -- other key: ignored
		ClientState.set("device", "Gamepad")
		expect(seen).toEqual({ "Keyboard", "Touch", "Gamepad" })
		connection:Disconnect()
		ClientState.set("device", "Keyboard")
		expect(#seen).toBe(3)
	end)

	it("serverNow applies the measured offset", function()
		ClientState.set("serverTimeOffset", 250)
		expect(ClientState.serverNow()).toBeCloseTo(os.clock() + 250, 1e-6)
	end)

	it("finds active orders by id", function()
		setOrders(ClientState, { makeOrder("A"), makeOrder("B", "Collected") })
		expect(ClientState.getActiveOrder("B").state).toBe("Collected")
		expect(ClientState.getActiveOrder("nope")).toBeNil()
	end)

	it("builds stops with pickup/deliver kinds and ground-level layout positions", function()
		spawnAt(0, 0)
		setOrders(ClientState, { makeOrder("A", "ReadyForPickup", "SliceStreetPizza"), makeOrder("B", "Collected", "BeanAndBunCafe", "D_Far") })
		local stops = ClientState.getOrderedStops()
		expect(#stops).toBe(2)
		expect(stops[1].kind).toBe("pickup")
		expect(stops[1].order.id).toBe("A")
		expect(stops[1].position).toBeCloseTo(v3(-20, 0, -9), 1e-6)
		expect(stops[1].label).toBe("Slice Street Pizza")
		expect(stops[2].kind).toBe("deliver")
		expect(stops[2].position).toBeCloseTo(v3(12, 0, 260), 1e-6)
		expect(stops[2].address).toBe("3 South Road")
	end)

	it("orders stops nearest-first from the player by default", function()
		spawnAt(0, 0)
		setOrders(ClientState, {
			makeOrder("B", "Collected", "SliceStreetPizza", "D_Far"), -- (12, 260)
			makeOrder("C", "Accepted", "BeanAndBunCafe"), -- (60, 9)
			makeOrder("A", "Accepted", "SliceStreetPizza"), -- (-20, -9)
		})
		local ids = {}
		for _, stop in ipairs(ClientState.getOrderedStops()) do
			table.insert(ids, stop.order.id)
		end
		expect(ids).toEqual({ "A", "C", "B" })
	end)

	it("puts stopOrder ids first and chains nearest-first from the last ordered stop", function()
		spawnAt(0, 0)
		setOrders(ClientState, {
			makeOrder("A", "Accepted", "SliceStreetPizza"), -- (-20, -9)
			makeOrder("B", "Collected", "SliceStreetPizza", "D_Far"), -- (12, 260)
			makeOrder("C", "Accepted", "BeanAndBunCafe"), -- (60, 9)
		})
		ClientState.set("stopOrder", { "B", "missing" })
		local ids = {}
		for _, stop in ipairs(ClientState.getOrderedStops()) do
			table.insert(ids, stop.order.id)
		end
		-- From (12, 260): C is ~256 away, A ~271 away.
		expect(ids).toEqual({ "B", "C", "A" })
	end)

	it("prefers streamed world instances for stop positions and falls back to the layout", function()
		local pickups = workspaceFolder("PickupLocations")
		local business = Instance.new("Model")
		business.Name = "SliceStreetPizza"
		business:SetAttribute("BusinessId", "SliceStreetPizza")
		local pad = Instance.new("Part")
		pad.Name = "PickupPad"
		pad.Size = v3(10, 0.2, 10)
		pad.CFrame = CFrame.new(-25, 0.1, -9)
		pad.Parent = business
		business.Parent = pickups

		local destinations = workspaceFolder("DeliveryDestinations")
		local destination = Instance.new("Model")
		destination.Name = "D_Near"
		local door = Instance.new("Part")
		door.Name = "Door"
		door.Size = v3(4, 7, 0.6)
		door.CFrame = CFrame.new(121, 3.5, -12)
		door.Parent = destination
		local arrival = Instance.new("Part")
		arrival.Name = "ArrivalPad"
		arrival.Size = v3(8, 0.2, 8)
		arrival.CFrame = CFrame.new(119, 0.1, -5)
		arrival.Parent = destination
		destination.Parent = destinations

		expect(ClientState.getBusinessPickupPosition("SliceStreetPizza")).toBeCloseTo(v3(-25, 0.2, -9), 1e-6)
		expect(ClientState.getDestinationDoorPosition("D_Near")).toBeCloseTo(v3(121, 0, -12), 1e-6)
		expect(ClientState.getDestinationArrivalPosition("D_Near")).toBeCloseTo(v3(119, 0.2, -5), 1e-6)
		-- Not streamed: layout fallback.
		expect(ClientState.getBusinessPickupPosition("BeanAndBunCafe")).toBeCloseTo(v3(60, 0, 9), 1e-6)
		expect(ClientState.getDestinationDoorPosition("D_Far")).toBeCloseTo(v3(12, 0, 260), 1e-6)
		expect(ClientState.getDestinationDoorPosition("D_Unknown")).toBeNil()
	end)

	it("reports the chassis position while driving and the character otherwise", function()
		local character = spawnAt(5, 5)
		expect(ClientState.getPlayerPosition()).toBeCloseTo(character.HumanoidRootPart.Position, 1e-6)
		local model = buildVehicleModel("Bicycle", 1, v3(40, 0, 40))
		ClientState.set("vehicle", { state = "Driving", vehicleId = "Bicycle", model = model })
		expect(ClientState.getPlayerPosition()).toBeCloseTo(model.Chassis.Position, 1e-6)
	end)
end)

-------------------------------------------------------------------------------
-- VehicleController._stepModel (pure)
-------------------------------------------------------------------------------

describe("VehicleController._stepModel", function()
	local VehicleController
	local handling
	local DT = 1 / 60

	local function groundProbe()
		return { grounded = true, groundY = 0, normal = Vector3.yAxis, hasHit = true, slopeOk = true }
	end

	local function airProbe()
		return { grounded = false, groundY = 0, normal = Vector3.yAxis, hasHit = false, slopeOk = true }
	end

	local function newState(overrides)
		local state = { heading = 0, speed = 0, steer = 0, vy = 0, blockedTimer = 0, posY = handling.rideHeight, actualForwardSpeed = 0 }
		for key, value in pairs(overrides or {}) do
			state[key] = value
		end
		return state
	end

	-- Steps the model `seconds` with constant input; the chassis is assumed free to move
	-- (actualForwardSpeed tracks the commanded speed) unless `blocked` is set.
	local function run(state, input, probe, seconds, extraHandling, blocked)
		local h = extraHandling or handling
		local maxSeen = 0
		local steps = math.floor(seconds / DT + 0.5)
		for _ = 1, steps do
			VehicleController._stepModel(state, input, probe, h, DT)
			maxSeen = math.max(maxSeen, math.abs(state.speed))
			state.actualForwardSpeed = blocked and 0 or state.speed
		end
		return maxSeen
	end

	beforeEach(function()
		shim.setContext("client")
		VehicleController = requireClient("Controllers/VehicleController")
		local VehicleDefinitions = shim.requirePath("ReplicatedStorage/Shared/Definitions/VehicleDefinitions")
		handling = VehicleDefinitions.Vehicles.Bicycle.handling
	end)

	it("accelerates under throttle up to maxSpeed and never beyond", function()
		local state = newState()
		local maxSeen = run(state, { throttle = 1, steer = 0, brake = false }, groundProbe(), 6)
		expect(state.speed).toBeCloseTo(handling.maxSpeed, 1e-6)
		expect(maxSeen).toBeLessThanOrEqual(handling.maxSpeed + 1e-9)
		expect(state.velocity).toBeCloseTo(v3(0, 0, -handling.maxSpeed), 1e-6)
		expect(state.forwardOnGround).toBeCloseTo(v3(0, 0, -1), 1e-6)
	end)

	it("applies the upgrade speed multiplier to the effective top speed", function()
		local boosted = setmetatable({ speedMultiplier = 1.05 }, { __index = handling })
		local state = newState()
		run(state, { throttle = 1, steer = 0, brake = false }, groundProbe(), 6, boosted)
		expect(state.speed).toBeCloseTo(handling.maxSpeed * 1.05, 1e-6)
		expect(state.maxSpeedEffective).toBeCloseTo(handling.maxSpeed * 1.05, 1e-6)
	end)

	it("brakes to a stop within the expected time", function()
		local state = newState({ speed = handling.maxSpeed })
		local expected = handling.maxSpeed / handling.brakeDeceleration
		run(state, { throttle = 0, steer = 0, brake = true }, groundProbe(), expected * 0.5)
		expect(state.speed).toBeGreaterThan(0)
		run(state, { throttle = 0, steer = 0, brake = true }, groundProbe(), expected * 0.5 + 0.1)
		expect(state.speed).toBe(0)
	end)

	it("coasts down without input and reverses slowly on negative throttle", function()
		local state = newState({ speed = 10 })
		run(state, { throttle = 0, steer = 0, brake = false }, groundProbe(), 0.5)
		expect(state.speed).toBeCloseTo(10 - handling.coastDeceleration * 0.5, 0.05)
		state = newState({ speed = 0 })
		run(state, { throttle = -1, steer = 0, brake = false }, groundProbe(), 3)
		expect(state.speed).toBeCloseTo(-handling.reverseSpeed, 1e-6)
	end)

	it("turns the heading left (increasing) for negative steer when moving forward", function()
		local state = newState({ speed = 20 })
		run(state, { throttle = 0.5, steer = -1, brake = false }, groundProbe(), 1)
		expect(state.heading).toBeGreaterThan(0.2)
		expect(state.steer).toBeLessThan(-0.9)
		-- Positive steer mirrors to the right.
		state = newState({ speed = 20 })
		run(state, { throttle = 0.5, steer = 1, brake = false }, groundProbe(), 1)
		expect(state.heading).toBeLessThan(-0.2)
	end)

	it("mirrors steering while reversing like a real vehicle", function()
		local state = newState({ speed = -handling.reverseSpeed })
		run(state, { throttle = -1, steer = -1, brake = false }, groundProbe(), 1)
		expect(state.speed).toBeLessThan(0)
		expect(state.heading).toBeLessThan(-0.05)
	end)

	it("keeps the heading when nearly stopped", function()
		local state = newState({ speed = 0.2 })
		VehicleController._stepModel(state, { throttle = 0, steer = 1, brake = false }, groundProbe(), handling, DT)
		expect(state.heading).toBe(0)
	end)

	it("converges the ride height toward rideHeight on the ground", function()
		local state = newState({ posY = handling.rideHeight + 4 })
		run(state, { throttle = 0, steer = 0, brake = false }, groundProbe(), 2)
		expect(state.posY).toBeCloseTo(handling.rideHeight, 0.05)
		expect(math.abs(state.vy)).toBeLessThan(0.5)
		-- Below the target: climbs, capped at maxClimbRate.
		state = newState({ posY = handling.rideHeight - 10 })
		VehicleController._stepModel(state, { throttle = 0, steer = 0, brake = false }, groundProbe(), handling, DT)
		expect(state.vy).toBeCloseTo(handling.maxClimbRate, 1e-6)
	end)

	it("emulates gravity while airborne and freezes drive input", function()
		local state = newState({ speed = 15, posY = 20 })
		local gravityHandling = setmetatable({ gravity = 196.2 }, { __index = handling })
		run(state, { throttle = 1, steer = 1, brake = false }, airProbe(), 0.5, gravityHandling)
		expect(state.vy).toBeCloseTo(-196.2 * 0.5, 0.5)
		expect(state.vy).toBeGreaterThanOrEqual(-handling.maxFallSpeed)
		expect(state.posY).toBeLessThan(20)
		expect(state.speed).toBeCloseTo(15, 1e-6) -- no acceleration in the air
		expect(state.heading).toBe(0) -- no steering in the air
		expect(state.driveGrounded).toBe(false)
	end)

	it("clamps the fall speed at maxFallSpeed", function()
		local state = newState({ posY = 500 })
		run(state, { throttle = 0, steer = 0, brake = false }, airProbe(), 3)
		expect(state.vy).toBeCloseTo(-handling.maxFallSpeed, 1e-6)
	end)

	it("halves the speed after being blocked for blockedTime", function()
		local state = newState({ speed = 20 })
		-- One frame under the threshold: still fine.
		run(state, { throttle = 0, steer = 0, brake = false }, groundProbe(), handling.blockedTime * 0.5, nil, true)
		expect(state.bumped).toBe(false)
		expect(state.blockedTimer).toBeGreaterThan(0)
		local before = state.speed
		run(state, { throttle = 0, steer = 0, brake = false }, groundProbe(), handling.blockedTime, nil, true)
		expect(state.speed).toBeLessThan(before * handling.bumpSlowdown + 0.5)
		expect(state.blockedTimer).toBeLessThan(handling.blockedTime)
	end)

	it("treats a too-steep slope as not drivable", function()
		local state = newState({ speed = 10 })
		local tilted = { grounded = true, groundY = 0, normal = Vector3.new(0, math.cos(math.rad(60)), math.sin(math.rad(60))).Unit, hasHit = true, slopeOk = false }
		run(state, { throttle = 1, steer = 1, brake = false }, tilted, 0.5)
		expect(state.driveGrounded).toBe(false)
		expect(state.heading).toBe(0)
		expect(state.speed).toBeLessThan(10) -- slides back under gravity (facing uphill)
	end)

	it("clamps dt and tolerates missing input fields", function()
		local state = newState()
		VehicleController._stepModel(state, {}, groundProbe(), handling, 10)
		expect(state.speed).toBe(0)
		expect(state.velocity).toBeCloseTo(v3(0, 0, 0), 1e-6)
		VehicleController._stepModel(state, { throttle = 1 }, { grounded = true, groundY = 0, normal = Vector3.zero, hasHit = true, slopeOk = true }, handling, 1 / 1000)
		expect(state.speed).toBeCloseTo(handling.acceleration / 240, 1e-6)
	end)
end)

-------------------------------------------------------------------------------
-- VehicleController runtime (owner loop against a model in the virtual DataModel)
-------------------------------------------------------------------------------

describe("VehicleController runtime", function()
	it("drives the LinearVelocity while Driving and seated, and zeroes it on stop", function()
		local ctx, ui, ClientState = setup({ "InputController", "VehicleController" })
		local character = spawnAt(0, 0)
		local model, chassis, seat, velocity = buildVehicleModel("Bicycle", 1, v3(0, 0, 0))
		seat:Sit(character.Humanoid)
		seat.ThrottleFloat = 1
		ClientState.set("vehicle", { state = "Driving", vehicleId = "Bicycle", model = model })
		shim.advance(0.2)
		local VehicleController = ctx.controllers.VehicleController
		expect(VehicleController.IsActive()).toBe(true)
		expect(VehicleController.GetSpeed()).toBeGreaterThan(1)
		expect(VehicleController.IsGrounded()).toBe(true)
		expect(velocity.VectorVelocity.Z).toBeLessThan(-1)
		expect(VehicleController.GetSpeedFraction()).toBeGreaterThan(0)
		expect(ui.hud).never.toBeNil()
		expect(ui.hud.state).toBe("Driving")
		expect(chassis:GetAttribute("Speed")).toBeGreaterThan(0)
		expect(VehicleController.GetModel()).toBe(model)

		ClientState.set("vehicle", { state = "Parked", vehicleId = "Bicycle", model = model })
		shim.advance(0.1)
		expect(VehicleController.IsActive()).toBe(false)
		expect(velocity.VectorVelocity).toBeCloseTo(Vector3.zero, 1e-6)
		expect(VehicleController.GetSpeed()).toBe(0)
	end)

	it("drives a mesh vehicle (empty Wheels folder) without warnings and still leans via BodyMotor", function()
		local ctx, _, ClientState = setup({ "InputController", "VehicleController" })
		local MeshAssets = shim.requirePath("ReplicatedStorage/Shared/Config/MeshAssets")
		MeshAssets.Vehicles.Scooter.body.meshId = 7001
		MeshAssets.Vehicles.Scooter.body.textureId = 7002
		local VehicleBuilder = require(svc("ServerScriptService").DeliveryDash.Builders.VehicleBuilder)
		local model = VehicleBuilder.build("Scooter", 1, nil)
		MeshAssets.Vehicles.Scooter.body.meshId = 0
		MeshAssets.Vehicles.Scooter.body.textureId = 0
		expect(#model.Wheels:GetChildren()).toBe(0)
		expect(model.Body:FindFirstChild("MeshBody")).toBeTruthy()
		model:PivotTo(CFrame.new(0, 1.5, 0))
		model.Parent = workspaceFolder("Runtime")
		local character = spawnAt(0, 0)
		local seat = model.Seat
		seat:Sit(character.Humanoid)
		seat.ThrottleFloat = 1
		seat.SteerFloat = 1
		ClientState.set("vehicle", { state = "Driving", vehicleId = "Scooter", model = model })
		shim.advance(0.5)
		local VehicleController = ctx.controllers.VehicleController
		expect(VehicleController.IsActive()).toBe(true)
		expect(VehicleController.GetSpeed()).toBeGreaterThan(1)
		-- Lean (two-wheeler) still works through BodyMotor; a right turn rolls about Z.
		local _, _, roll = model.BodyRoot.BodyMotor.Transform:ToEulerAnglesXYZ()
		expect(math.abs(roll)).toBeGreaterThan(0.001)
		shim.advance(1)
		expect(#shim.warnings).toBe(0)
		ClientState.set("vehicle", { state = "Parked", vehicleId = "Scooter", model = model })
		shim.advance(0.1)
		expect(VehicleController.IsActive()).toBe(false)
		expect(#shim.warnings).toBe(0)
	end)

	it("does not run when the local humanoid is not in the vehicle seat", function()
		local ctx, _, ClientState = setup({ "InputController", "VehicleController" })
		spawnAt(0, 0)
		local model = buildVehicleModel("Bicycle", 1, v3(0, 0, 0))
		ClientState.set("vehicle", { state = "Driving", vehicleId = "Bicycle", model = model })
		shim.advance(0.2)
		expect(ctx.controllers.VehicleController.IsActive()).toBe(false)
	end)

	it("resolves a model that streams in after the state event", function()
		local ctx, _, ClientState = setup({ "InputController", "VehicleController" })
		local character = spawnAt(0, 0)
		ClientState.set("vehicle", { state = "Driving", vehicleId = "Bicycle", model = nil })
		shim.advance(0.5)
		expect(ctx.controllers.VehicleController.GetModel()).toBeNil()
		local model, _, seat = buildVehicleModel("Bicycle", 1, v3(0, 0, 0))
		seat:Sit(character.Humanoid)
		shim.advance(1.5)
		expect(ctx.controllers.VehicleController.GetModel()).toBe(model)
		expect(ctx.controllers.VehicleController.IsActive()).toBe(true)
	end)

	it("computes the speed multiplier from profile upgrades", function()
		local ctx, _, ClientState = setup({ "VehicleController" })
		ClientState.set("profile", { upgrades = { TunedGears = 1, BasketI = 1 } })
		expect(ctx.controllers.VehicleController.GetSpeedMultiplier("Bicycle")).toBeCloseTo(1.05, 1e-6)
		expect(ctx.controllers.VehicleController.GetSpeedMultiplier("Van")).toBe(1)
	end)

	it("rate-limits recovery requests to one per 3 s", function()
		local calls = 0
		local ctx = setup({ "VehicleController" }, {
			handlers = {
				RecoverVehicle = function()
					calls += 1
					return { ok = true }
				end,
			},
		})
		local VehicleController = ctx.controllers.VehicleController
		VehicleController.RequestRecover()
		VehicleController.RequestRecover()
		shim.advance(0.1)
		expect(calls).toBe(1)
		shim.advance(3)
		VehicleController.RequestRecover()
		shim.advance(0.1)
		expect(calls).toBe(2)
	end)
end)

-------------------------------------------------------------------------------
-- NavigationController
-------------------------------------------------------------------------------

describe("NavigationController", function()
	local InputActions

	beforeEach(function()
		InputActions = shim.requirePath("ReplicatedStorage/Shared/InputActions")
	end)

	local function markerFolder()
		local fx = svc("Workspace").CurrentCamera:FindFirstChild("ClientFX")
		return fx and fx:FindFirstChild("RouteMarkers")
	end

	local function visibleMarkers()
		local folder = markerFolder()
		local count = 0
		if folder then
			for _, part in ipairs(folder:GetChildren()) do
				if part:IsA("BasePart") and part.Transparency < 1 then
					count += 1
				end
			end
		end
		return count
	end

	it("targets the first ordered stop, routes on the graph and feeds the HUD and minimap", function()
		local ctx, ui, ClientState = setup({ "InputController", "NavigationController" })
		spawnAt(0, 0)
		setOrders(ClientState, { makeOrder("A", "Accepted", "SliceStreetPizza"), makeOrder("B", "Collected", "SliceStreetPizza", "D_Far") })
		local Navigation = ctx.controllers.NavigationController
		Navigation.Refresh()
		local target = Navigation.GetCurrentTarget()
		expect(target).never.toBeNil()
		expect(target.kind).toBe("pickup")
		expect(target.order.id).toBe("A")
		local path = Navigation.GetPath()
		expect(path).never.toBeNil()
		expect(#path).toBeGreaterThanOrEqual(2)
		expect(path[#path]).toBeCloseTo(target.position, 1e-6)
		expect(ui.navigation.active).toBe(true)
		expect(ui.navigation.stopKind).toBe("pickup")
		expect(ui.navigation.label).toBe("Slice Street Pizza")
		expect(ui.navigation.distance).toBeGreaterThan(10)
		expect(ui.navigation.turnKind).never.toBeNil()
		expect(ui.minimap).never.toBeNil()
		expect(#ui.minimap.stops).toBe(2)
		expect(ui.minimap.stops[1].current).toBe(true)
		expect(ui.minimap.stops[2].current).toBe(false)
		expect(visibleMarkers()).toBeGreaterThan(0)
		expect(visibleMarkers()).toBeLessThanOrEqual(40)
	end)

	it("cycles the target with the NextStop action and honours stopOrder", function()
		local ctx, ui, ClientState = setup({ "InputController", "NavigationController" })
		spawnAt(0, 0)
		setOrders(ClientState, { makeOrder("A", "Accepted", "SliceStreetPizza"), makeOrder("B", "Collected", "SliceStreetPizza", "D_Far") })
		local Navigation = ctx.controllers.NavigationController
		Navigation.Refresh()
		expect(Navigation.GetCurrentTarget().order.id).toBe("A")

		shim.triggerAction(InputActions.Names.NextStop, Enum.UserInputState.Begin)
		shim.triggerAction(InputActions.Names.NextStop, Enum.UserInputState.End)
		shim.advance(0.05)
		expect(Navigation.GetCurrentTarget().order.id).toBe("B")
		expect(Navigation.GetCurrentTarget().kind).toBe("deliver")
		expect(ui.navigation.stopKind).toBe("deliver")
		expect(ui.navigation.address).toBe("3 South Road")

		Navigation.NextStop()
		Navigation.Refresh()
		expect(Navigation.GetCurrentTarget().order.id).toBe("A")

		ClientState.set("stopOrder", { "B" })
		Navigation.Refresh()
		expect(Navigation.GetCurrentTarget().order.id).toBe("B")
	end)

	it("clears markers, billboard and HUD when there are no stops", function()
		local ctx, ui, ClientState = setup({ "NavigationController" })
		spawnAt(0, 0)
		setOrders(ClientState, { makeOrder("A", "Accepted", "SliceStreetPizza") })
		local Navigation = ctx.controllers.NavigationController
		Navigation.Refresh()
		expect(visibleMarkers()).toBeGreaterThan(0)
		setOrders(ClientState, {})
		Navigation.Refresh()
		expect(Navigation.GetCurrentTarget()).toBeNil()
		expect(Navigation.GetPath()).toBeNil()
		expect(visibleMarkers()).toBe(0)
		expect(ui.navigation.active).toBe(false)
		local billboard = svc("Workspace").CurrentCamera.ClientFX:FindFirstChild("DestinationBillboard")
		expect(billboard).never.toBeNil()
		expect(billboard.Gui.Enabled).toBe(false)
		expect(#ui.minimap.stops).toBe(0)
	end)

	it("updates on the Heartbeat cadence and recomputes when the stop set changes", function()
		local ctx, ui, ClientState = setup({ "NavigationController" })
		spawnAt(0, 0)
		setOrders(ClientState, { makeOrder("A", "Accepted", "SliceStreetPizza") })
		shim.advance(0.3)
		expect(ui.navigation.active).toBe(true)
		expect(ui.navigation.label).toBe("Slice Street Pizza")
		setOrders(ClientState, { makeOrder("A", "Collected", "SliceStreetPizza", "D_Near") })
		shim.advance(0.3)
		expect(ui.navigation.stopKind).toBe("deliver")
		expect(ui.navigation.address).toBe("1 Main Street")
	end)

	it("routes with the real city layout when available", function()
		local okLayout, CityLayout = pcall(shim.requirePath, "ReplicatedStorage/Shared/City/CityLayout")
		if not okLayout then
			return
		end
		local ctx, ui, ClientState = setup({ "NavigationController" }, { layout = CityLayout })
		spawnAt(CityLayout.hub.spawn.x, CityLayout.hub.spawn.z)
		local business = CityLayout.businesses[1]
		local destination = CityLayout.destinations[1]
		setOrders(ClientState, { makeOrder("A", "Accepted", business.id, destination.id) })
		ctx.controllers.NavigationController.Refresh()
		local path = ctx.controllers.NavigationController.GetPath()
		expect(path).never.toBeNil()
		expect(#path).toBeGreaterThan(2)
		expect(ui.navigation.active).toBe(true)
		expect(ui.navigation.distance).toBeGreaterThan(50)
	end)
end)

-------------------------------------------------------------------------------
-- InteractionController
-------------------------------------------------------------------------------

describe("InteractionController", function()
	local InputActions
	local EconomyConfig

	beforeEach(function()
		InputActions = shim.requirePath("ReplicatedStorage/Shared/InputActions")
		EconomyConfig = shim.requirePath("ReplicatedStorage/Shared/Config/EconomyConfig")
	end)

	local function press(name)
		shim.triggerAction(name, Enum.UserInputState.Begin)
		shim.triggerAction(name, Enum.UserInputState.End)
	end

	it("shows the collect prompt inside pickupDistance - 2 and hides it outside", function()
		local ctx, ui, ClientState = setup({ "InputController", "InteractionController" })
		local character = spawnAt(-20, -9 + (EconomyConfig.pickupDistance - 4))
		setOrders(ClientState, { makeOrder("A", "ReadyForPickup", "SliceStreetPizza") })
		local Interaction = ctx.controllers.InteractionController
		Interaction.Refresh()
		expect(ui.prompt).never.toBeNil()
		expect(ui.prompt.text).toBe("Collect order")
		expect(ui.prompt.kind).toBe("pickup")
		expect(ui.prompt.action).toBe(InputActions.Names.Interact)
		expect(ui.prompt.detail).toBe("Margherita pizza")
		expect(svc("ContextActionService"):GetButton(InputActions.Names.Interact).Visible).toBe(true)

		moveTo(character, -20, -9 + EconomyConfig.pickupDistance + 1)
		Interaction.Refresh()
		expect(ui.prompt).toBeNil()
		expect(Interaction.GetCurrentPrompt()).toBeNil()
		expect(svc("ContextActionService"):GetButton(InputActions.Names.Interact).Visible).toBe(false)
	end)

	it("shows the preparing countdown while the order is not ready", function()
		local ctx, ui, ClientState = setup({ "InputController", "InteractionController" })
		spawnAt(-20, -9)
		ClientState.set("serverTimeOffset", 100)
		setOrders(ClientState, { makeOrder("A", "Accepted", "SliceStreetPizza", nil, { readyAt = ClientState.serverNow() + 7.2 }) })
		ctx.controllers.InteractionController.Refresh()
		expect(ui.prompt.kind).toBe("wait")
		expect(ui.prompt.text).toBe("Preparing... 8s")
		shim.advance(8)
		ctx.controllers.InteractionController.Refresh()
		expect(ui.prompt.kind).toBe("pickup")
	end)

	it("calls RequestPickup on Interact and shows the seconds left on NotReady", function()
		local received = {}
		local ctx, ui, ClientState = setup({ "InputController", "InteractionController" }, {
			handlers = {
				RequestPickup = function(player, orderId)
					table.insert(received, orderId)
					return { ok = false, error = "NotReady", message = "Not ready", secondsLeft = 4.2 }
				end,
			},
		})
		spawnAt(-20, -9)
		setOrders(ClientState, { makeOrder("A", "ReadyForPickup", "SliceStreetPizza") })
		ctx.controllers.InteractionController.Refresh()
		press(InputActions.Names.Interact)
		shim.advance(0.1)
		expect(received).toEqual({ "A" })
		expect(#ui.notifications).toBe(1)
		expect(ui.notifications[1].text).toMatch("5 s")
		expect(ui.notifications[1].kind).toBe("info")
	end)

	it("reports other errors through Notify and delivers Collected orders at the door", function()
		local calls = {}
		local ctx, ui, ClientState = setup({ "InputController", "InteractionController" }, {
			handlers = {
				RequestDelivery = function(player, orderId)
					table.insert(calls, orderId)
					if #calls == 1 then
						return { ok = false, error = "TooFar", message = "Too far from the door" }
					end
					return { ok = true }
				end,
			},
		})
		spawnAt(120, -12 + (EconomyConfig.deliveryDistance - 4))
		setOrders(ClientState, { makeOrder("A", "Collected", "SliceStreetPizza", "D_Near") })
		ctx.controllers.InteractionController.Refresh()
		expect(ui.prompt.kind).toBe("deliver")
		expect(ui.prompt.text).toBe("Deliver order")
		expect(ui.prompt.detail).toBe("1 Main Street")
		press(InputActions.Names.Interact)
		shim.advance(0.1)
		expect(calls).toEqual({ "A" })
		expect(ui.notifications[1].text).toBe("Too far from the door")
		expect(ui.notifications[1].kind).toBe("warning")
		press(InputActions.Names.Interact)
		shim.advance(0.1)
		expect(#calls).toBe(2)
		expect(#ui.notifications).toBe(1)
	end)

	it("accepts the arrival pad as a delivery point", function()
		local ctx, ui, ClientState = setup({ "InteractionController" })
		spawnAt(5, 260 + (EconomyConfig.deliveryArrivalDistance - 4))
		setOrders(ClientState, { makeOrder("A", "Collected", "SliceStreetPizza", "D_Far") })
		ctx.controllers.InteractionController.Refresh()
		expect(ui.prompt.kind).toBe("deliver")
	end)

	it("offers Ride near the own Parked vehicle and Dismount only when slow", function()
		local mounted = 0
		local ctx, ui, ClientState = setup({ "InputController", "InteractionController" }, {
			handlers = {
				MountVehicle = function()
					mounted += 1
					return { ok = true }
				end,
			},
		})
		spawnAt(0, 0)
		local model = buildVehicleModel("Bicycle", 1, v3(8, 0, 0))
		ClientState.set("vehicle", { state = "Parked", vehicleId = "Bicycle", model = model })
		local Interaction = ctx.controllers.InteractionController
		Interaction.Refresh()
		expect(ui.prompt.kind).toBe("mount")
		expect(ui.prompt.text).toBe("Ride")
		expect(ui.prompt.action).toBe(InputActions.Names.MountDismount)
		expect(svc("ContextActionService"):GetButton(InputActions.Names.MountDismount).Visible).toBe(true)
		press(InputActions.Names.MountDismount)
		shim.advance(0.1)
		expect(mounted).toBe(1)

		ClientState.set("vehicle", { state = "Driving", vehicleId = "Bicycle", model = model })
		Interaction.Refresh()
		expect(ui.prompt.kind).toBe("dismount")

		-- A fast vehicle hides the dismount prompt (VehicleController reports the speed).
		ctx.controllers.VehicleController = { GetSpeed = function()
			return 12
		end }
		Interaction.Refresh()
		expect(ui.prompt).toBeNil()
		expect(svc("ContextActionService"):GetButton(InputActions.Names.MountDismount).Visible).toBe(false)
	end)

	it("never prompts for another player's vehicle", function()
		local ctx, ui, ClientState = setup({ "InteractionController" })
		spawnAt(0, 0)
		buildVehicleModel("Bicycle", 999, v3(4, 0, 0))
		ClientState.set("vehicle", { state = nil, vehicleId = nil, model = nil })
		ctx.controllers.InteractionController.Refresh()
		expect(ui.prompt).toBeNil()
	end)

	it("spawns the equipped vehicle from a hub pad when none is spawned", function()
		local spawnedId = nil
		local ctx, ui, ClientState = setup({ "InputController", "InteractionController" }, {
			handlers = {
				SpawnVehicle = function(player, vehicleId)
					spawnedId = vehicleId
					return { ok = true, vehicleId = vehicleId }
				end,
			},
		})
		spawnAt(12, 34)
		ClientState.set("profile", { equippedVehicle = "Scooter", upgrades = {} })
		ctx.controllers.InteractionController.Refresh()
		expect(ui.prompt.text).toBe("Take vehicle")
		expect(ui.prompt.detail).toBe("Scooter")
		press(InputActions.Names.MountDismount)
		shim.advance(0.1)
		expect(spawnedId).toBe("Scooter")
	end)

	it("offers Take vehicle at the pad again after the vehicle despawns", function()
		local spawnedId = nil
		local ctx, ui, ClientState = setup({ "InputController", "InteractionController" }, {
			handlers = {
				SpawnVehicle = function(player, vehicleId)
					spawnedId = vehicleId
					return { ok = true, vehicleId = vehicleId }
				end,
			},
		})
		spawnAt(12, 34)
		ClientState.set("profile", { equippedVehicle = "Bicycle", upgrades = {} })
		local model = buildVehicleModel("Bicycle", 1, v3(200, 0, 200))
		ClientState.set("vehicle", { state = "Parked", vehicleId = "Bicycle", model = model })
		ctx.controllers.InteractionController.Refresh()
		-- A vehicle parked far away: nothing to do at the pad.
		expect(ui.prompt).toBeNil()

		-- The server's terminal event stored raw (the bootstrap normally maps it to nil first).
		ClientState.set("vehicle", { state = "Despawning", vehicleId = nil, model = nil })
		ctx.controllers.InteractionController.Refresh()
		expect(ui.prompt).never.toBeNil()
		expect(ui.prompt.text).toBe("Take vehicle")
		press(InputActions.Names.MountDismount)
		shim.advance(0.1)
		expect(spawnedId).toBe("Bicycle")

		-- And the normalised form behaves the same.
		spawnedId = nil
		ClientState.set("vehicle", { state = nil, vehicleId = nil, model = nil })
		ctx.controllers.InteractionController.Refresh()
		expect(ui.prompt.text).toBe("Take vehicle")
		press(InputActions.Names.MountDismount)
		shim.advance(0.1)
		expect(spawnedId).toBe("Bicycle")
	end)

	it("opens the order board at the kiosk and the depot screen at the own plot", function()
		local ctx, ui, ClientState = setup({ "InputController", "InteractionController" })
		spawnAt(0, 44)
		local Interaction = ctx.controllers.InteractionController
		Interaction.Refresh()
		expect(ui.prompt.text).toBe("Order board")
		press(InputActions.Names.Interact)
		shim.advance(0.05)
		expect(ui.openedScreens).toEqual({ "Orders" })

		ClientState.set("depot", { owned = true, plotId = "P1", pendingTotal = 350, drivers = {}, slotsUnlocked = 1, categories = {} })
		moveTo(svc("Players").LocalPlayer.Character, 80, 80)
		Interaction.Refresh()
		expect(ui.prompt.kind).toBe("depot")
		expect(ui.prompt.detail).toBe("Collect $350")
		press(InputActions.Names.Interact)
		shim.advance(0.05)
		expect(ui.depotFor).toBe("P1")
	end)
end)

-------------------------------------------------------------------------------
-- InputController
-------------------------------------------------------------------------------

describe("InputController", function()
	local InputActions

	beforeEach(function()
		InputActions = shim.requirePath("ReplicatedStorage/Shared/InputActions")
	end)

	it("returns no drive input and brake while a modal menu is open", function()
		local ctx, ui = setup({ "InputController" })
		local character = spawnAt(0, 0)
		local seat = Instance.new("VehicleSeat")
		seat.Name = "Seat"
		seat.Parent = svc("Workspace")
		seat:Sit(character.Humanoid)
		seat.ThrottleFloat = 1
		seat.SteerFloat = -0.5
		local Input = ctx.controllers.InputController
		local throttle, steer, brake = Input.GetDriveInput()
		expect(throttle).toBe(1)
		expect(steer).toBe(-0.5)
		expect(brake).toBe(false)
		ui.modal = true
		throttle, steer, brake = Input.GetDriveInput()
		expect(throttle).toBe(0)
		expect(steer).toBe(0)
		expect(brake).toBe(true)
	end)

	it("reads the seat floats, the Brake action and clamps the values", function()
		local ctx = setup({ "InputController" })
		local character = spawnAt(0, 0)
		local Input = ctx.controllers.InputController
		local throttle, steer, brake = Input.GetDriveInput()
		expect(throttle).toBe(0)
		expect(steer).toBe(0)
		expect(brake).toBe(false)
		local seat = Instance.new("VehicleSeat")
		seat.Parent = svc("Workspace")
		seat:Sit(character.Humanoid)
		seat.ThrottleFloat = 3
		seat.SteerFloat = 0.25
		shim.triggerAction(InputActions.Names.Brake, Enum.UserInputState.Begin)
		throttle, steer, brake = Input.GetDriveInput()
		expect(throttle).toBe(1)
		expect(steer).toBe(0.25)
		expect(brake).toBe(true)
		expect(Input.IsDown(InputActions.Names.Brake)).toBe(true)
		shim.triggerAction(InputActions.Names.Brake, Enum.UserInputState.End)
		local _, _, brakeAfter = Input.GetDriveInput()
		expect(brakeAfter).toBe(false)
	end)

	it("binds every action, fires Pressed/Released and requires a 1 s hold for Recover", function()
		local ctx = setup({ "InputController" })
		local Input = ctx.controllers.InputController
		for _, binding in ipairs(InputActions.Bindings) do
			expect(svc("ContextActionService"):GetBoundActionInfo(binding.name)).never.toBeNil()
		end
		local pressed, released = {}, {}
		Input.Pressed:Connect(function(name)
			table.insert(pressed, name)
		end)
		Input.Released:Connect(function(name)
			table.insert(released, name)
		end)
		shim.triggerAction(InputActions.Names.Interact, Enum.UserInputState.Begin)
		shim.triggerAction(InputActions.Names.Interact, Enum.UserInputState.End)
		expect(pressed).toEqual({ InputActions.Names.Interact })
		expect(released).toEqual({ InputActions.Names.Interact })

		-- Recover released early: nothing fires.
		shim.triggerAction(InputActions.Names.Recover, Enum.UserInputState.Begin)
		shim.advance(0.5)
		shim.triggerAction(InputActions.Names.Recover, Enum.UserInputState.End)
		shim.advance(0.6)
		expect(#pressed).toBe(1)
		-- Held for a second: fires.
		shim.triggerAction(InputActions.Names.Recover, Enum.UserInputState.Begin)
		shim.advance(1.05)
		expect(pressed[2]).toBe(InputActions.Names.Recover)
		shim.triggerAction(InputActions.Names.Recover, Enum.UserInputState.End)
	end)

	it("tracks the device from the last input type", function()
		local ctx, _, ClientState = setup({ "InputController" })
		local Input = ctx.controllers.InputController
		expect(ClientState.get("device")).toBe("Keyboard")
		expect(Input.IsTouch()).toBe(false)
		svc("UserInputService").LastInputTypeChanged:Fire(Enum.UserInputType.Gamepad1)
		expect(Input.IsGamepad()).toBe(true)
		expect(ClientState.get("device")).toBe("Gamepad")
		svc("UserInputService").LastInputTypeChanged:Fire(Enum.UserInputType.Touch)
		expect(Input.IsTouch()).toBe(true)
		expect(ClientState.get("device")).toBe("Touch")
		svc("UserInputService").LastInputTypeChanged:Fire(Enum.UserInputType.MouseMovement)
		expect(ClientState.get("device")).toBe("Keyboard")
	end)

	it("hides touch buttons on request and shows Brake only while driving", function()
		local ctx, _, ClientState = setup({ "InputController" })
		local Input = ctx.controllers.InputController
		local brakeButton = svc("ContextActionService"):GetButton(InputActions.Names.Brake)
		expect(brakeButton.Visible).toBe(false)
		ClientState.set("vehicle", { state = "Driving", vehicleId = "Bicycle", model = nil })
		expect(brakeButton.Visible).toBe(true)
		ClientState.set("vehicle", { state = "Parked", vehicleId = "Bicycle", model = nil })
		expect(brakeButton.Visible).toBe(false)
		Input.SetActionVisible(InputActions.Names.Interact, false)
		expect(svc("ContextActionService"):GetButton(InputActions.Names.Interact).Visible).toBe(false)
		expect(Input.IsActionVisible(InputActions.Names.Interact)).toBe(false)
		Input.SetActionVisible(InputActions.Names.Interact, true)
		expect(svc("ContextActionService"):GetButton(InputActions.Names.Interact).Visible).toBe(true)
	end)

	it("re-fires Pressed when the on-screen prompt is tapped", function()
		local ctx, ui = setup({ "InputController" })
		local pressed = {}
		ctx.controllers.InputController.Pressed:Connect(function(name)
			table.insert(pressed, name)
		end)
		ui.PromptActivated:Fire(InputActions.Names.MountDismount)
		expect(pressed).toEqual({ InputActions.Names.MountDismount })
	end)
end)

-------------------------------------------------------------------------------
-- AudioController
-------------------------------------------------------------------------------

describe("AudioController", function()
	local function sfxFolder()
		return svc("SoundService"):FindFirstChild("DDC_SFX")
	end

	it("skips empty sound ids and pools real ones", function()
		local ctx = setup({ "AudioController" })
		local Audio = ctx.controllers.AudioController
		expect(Audio.Play("BicycleChain")).toBeNil() -- id = ""
		expect(Audio.Play("Unknown")).toBeNil()
		expect(Audio.GetPoolSize("BicycleChain")).toBe(0)
		local sound = Audio.Play("UIClick")
		expect(sound).never.toBeNil()
		expect(sound.SoundId).toBe("rbxasset://sounds/button.wav")
		expect(sound.Parent).toBe(sfxFolder())
		expect(Audio.GetPoolSize("UIClick")).toBe(1)
		for _ = 1, 10 do
			Audio.Play("UIClick")
		end
		expect(Audio.GetPoolSize("UIClick")).toBeLessThanOrEqual(Audio.POOL_PER_KEY)
	end)

	it("scales one-shot volume by sfxVolume and the config", function()
		local ctx = setup({ "AudioController" })
		local Audio = ctx.controllers.AudioController
		local AudioConfig = shim.requirePath("ReplicatedStorage/Shared/Config/AudioConfig")
		Audio.ApplySettings({ sfxVolume = 0.5, musicVolume = 0.2 })
		local sound = Audio.Play("Payment")
		expect(sound.Volume).toBeCloseTo(AudioConfig.sounds.Payment.volume * AudioConfig.masterVolume * 0.5, 1e-6)
		local pitched = Audio.Play("NewRecord")
		expect(pitched.PlaybackSpeed).toBeCloseTo(1.2, 1e-6)
	end)

	it("maps positions to ambience zones and creates no sounds for silent ambience", function()
		local ctx = setup({ "AudioController" })
		local Audio = ctx.controllers.AudioController
		expect(Audio.ZoneFor(v3(-20, 0, -9))).toBe("RestaurantAmbience")
		expect(Audio.ZoneFor(v3(200, 0, -200))).toBe("ParkAmbience")
		expect(Audio.ZoneFor(v3(0, 0, 300))).toBe("IndustrialAmbience")
		expect(Audio.ZoneFor(v3(0, 0, -200))).toBe("CityAmbience")
		Audio.SetZone("ParkAmbience")
		expect(Audio.GetZone()).toBe("ParkAmbience")
		local ambience = svc("SoundService"):FindFirstChild("DDC_Ambience")
		expect(ambience == nil or #ambience:GetChildren() == 0).toBe(true)
	end)

	it("plays order cues from OrderEvent", function()
		local ctx, _, ClientState = setup({ "AudioController" })
		ClientState.OrderEvent:Fire({ kind = "Accepted", orderId = "A" })
		ClientState.OrderEvent:Fire({ kind = "Delivered", orderId = "A", payout = { total = 50, newRecord = true } })
		ClientState.OrderEvent:Fire({ kind = "Cancelled", orderId = "A" })
		local folder = sfxFolder()
		expect(folder:FindFirstChild("OrderAccepted")).never.toBeNil()
		expect(folder:FindFirstChild("NewRecord")).never.toBeNil()
		expect(folder:FindFirstChild("Payment")).toBeNil()
		expect(folder:FindFirstChild("Error")).never.toBeNil()
	end)

	it("plays a brake one-shot when braking starts at speed", function()
		local ctx = setup({ "AudioController" })
		local Audio = ctx.controllers.AudioController
		Audio.SetEngine(0.5, false, true)
		Audio.SetEngine(0.5, true, true)
		Audio.SetEngine(0.5, true, true)
		expect(Audio.GetPoolSize("Brake")).toBe(1)
		Audio.StopEngine()
	end)
end)

-------------------------------------------------------------------------------
-- TutorialController
-------------------------------------------------------------------------------

describe("TutorialController", function()
	it("shows server texts, falls back to local texts and advances only dismissable steps", function()
		local advanced = {}
		local ctx, ui, ClientState = setup({ "TutorialController" }, {
			handlers = {
				AdvanceTutorial = function(player, step)
					table.insert(advanced, step)
					return { ok = true, step = step + 1 }
				end,
			},
		})
		ClientState.set("tutorial", { step = 1, completed = false })
		expect(ui.tutorial.step).toBe(1)
		expect(ui.tutorial.title).toBe("Your first order")
		expect(ui.tutorial.dismissable).toBe(false)
		ui.TutorialContinue:Fire()
		shim.advance(0.05)
		expect(#advanced).toBe(0)

		ClientState.set("tutorial", { step = 6, completed = false, title = "Server title", body = "Server body", hint = "Server hint" })
		expect(ui.tutorial.title).toBe("Server title")
		expect(ui.tutorial.hint).toBe("Server hint")
		expect(ui.tutorial.dismissable).toBe(true)
		ui.TutorialContinue:Fire()
		shim.advance(0.05)
		expect(advanced).toEqual({ 6 })

		-- Finishing in-session: the server sends step 9 already completed (ProfileUpdated first,
		-- then TutorialUpdated with the texts); the "You're ready" card stays up until Continue.
		ClientState.set("tutorial", { step = 8, completed = false })
		expect(ui.tutorial.step).toBe(8)
		ClientState.set("tutorial", { step = 9, completed = true })
		expect(ui.tutorial).never.toBeNil()
		expect(ui.tutorial.title).toBe("You're ready")
		expect(ui.tutorial.hint).toBe("Tap Continue to finish")
		expect(ui.tutorial.dismissable).toBe(true)
		ClientState.set("tutorial", { step = 9, completed = true, title = "You're ready", body = "The city is yours.", hint = "" })
		expect(ui.tutorial.body).toBe("The city is yours.")
		expect(ui.tutorial.hint).toBe("Tap Continue to finish")
		ui.TutorialContinue:Fire()
		-- closes locally at once (the server acks without another TutorialUpdated)
		expect(ui.tutorial).toBeNil()
		shim.advance(0.05)
		expect(advanced).toEqual({ 6, 9 })
		-- a later re-send of the completed state (e.g. a profile refresh) does not bring it back
		ClientState.set("tutorial", { step = 9, completed = true, title = "You're ready" })
		expect(ui.tutorial).toBeNil()
	end)

	it("never shows the final card to a returning player whose tutorial is already complete", function()
		local ctx, ui, ClientState = setup({ "TutorialController" })
		ClientState.set("tutorial", { step = 9, completed = true, title = "You're ready", body = "The city is yours." })
		expect(ui.tutorial).toBeNil()
		expect(ctx.controllers.TutorialController.GetCurrentSpec()).toBeNil()
	end)

	it("shows no banner before the profile is known and tells the player when Continue is rejected", function()
		local calls = 0
		local ctx, ui, ClientState = setup({ "TutorialController" }, {
			handlers = {
				AdvanceTutorial = function()
					calls += 1
					return { ok = false, error = "Locked", message = "Your profile is still loading" }
				end,
			},
		})
		shim.advance(0.05)
		-- Default state: nothing is known about the player yet, so no welcome banner.
		expect(ClientState.get("tutorial")).toBeNil()
		expect(ui.tutorial).toBeNil()
		expect(ctx.controllers.TutorialController.GetCurrentSpec()).toBeNil()
		ui.TutorialContinue:Fire()
		shim.advance(0.05)
		expect(calls).toBe(0)
		expect(#ui.notifications).toBe(0)

		ClientState.set("tutorial", { step = 0, completed = false })
		expect(ui.tutorial.title).toBe("Welcome to Delivery Dash City")
		ui.TutorialContinue:Fire()
		shim.advance(0.05)
		expect(calls).toBe(1)
		expect(#ui.notifications).toBe(1)
		expect(ui.notifications[1].kind).toBe("warning")
		expect(ui.notifications[1].text).toMatch("loading")
	end)
end)

-------------------------------------------------------------------------------
-- SettingsController
-------------------------------------------------------------------------------

describe("SettingsController", function()
	it("mirrors profile settings, applies changes at once and saves after the debounce", function()
		local saved = {}
		local ctx, _, ClientState = setup({ "SettingsController", "AudioController", "CameraController" }, {
			handlers = {
				SaveSettings = function(player, settings)
					table.insert(saved, settings)
					return { ok = true, settings = settings }
				end,
			},
		})
		local Settings = ctx.controllers.SettingsController
		ClientState.set("profile", { settings = { cameraSensitivity = 1.5, reducedMotion = true, autoRecenter = true, musicVolume = 0.4, sfxVolume = 0.9, showMinimap = false, invertCameraY = false } })
		expect(ClientState.get("settings").cameraSensitivity).toBe(1.5)
		expect(Settings.Get("reducedMotion")).toBe(true)

		Settings.Set("sfxVolume", 0.3)
		Settings.Set("cameraSensitivity", 9) -- clamped to 3
		expect(ClientState.get("settings").sfxVolume).toBe(0.3)
		expect(Settings.Get("cameraSensitivity")).toBe(3)
		shim.advance(1)
		expect(#saved).toBe(0)
		shim.advance(0.6)
		expect(#saved).toBe(1)
		expect(saved[1].sfxVolume).toBe(0.3)
		expect(saved[1].cameraSensitivity).toBe(3)
		Settings.Set("unknown", true)
		shim.advance(2)
		expect(#saved).toBe(1)
	end)
end)

-------------------------------------------------------------------------------
-- CosmeticsController
-------------------------------------------------------------------------------

describe("CosmeticsController", function()
	it("resolves paint from the profile and builds an anchored display vehicle", function()
		local ctx, _, ClientState = setup({ "CosmeticsController" })
		local Cosmetics = ctx.controllers.CosmeticsController
		ClientState.set("profile", { cosmetics = { owned = {}, equipped = { BikeColor = "BikeColor_Mint", VanDecal = "VanDecal_Gold" } } })
		local colors = Cosmetics.GetVehicleColors("Bicycle")
		expect(colors.Primary).toEqual({ 120, 210, 180 })
		expect(Cosmetics.GetVehicleColors("Van").Decal).toEqual({ 230, 190, 70 })

		local holder = Instance.new("Folder")
		holder.Parent = svc("Workspace")
		local model = Cosmetics.BuildDisplayVehicle("Van", holder)
		expect(model.Parent).toBe(holder)
		expect(model.PrimaryPart.Name).toBe("Chassis")
		local VehicleDefinitions = shim.requirePath("ReplicatedStorage/Shared/Definitions/VehicleDefinitions")
		expect(#model.Body:GetChildren()).toBe(#VehicleDefinitions.Vehicles.Van.visual.parts)
		expect(#model.Wheels:GetChildren()).toBe(4)
		for _, part in ipairs(model:GetDescendants()) do
			if part:IsA("BasePart") then
				expect(part.Anchored).toBe(true)
				expect(part.CanCollide).toBe(false)
			end
		end
		local decal = model.Body:FindFirstChild("DecalL")
		expect(decal:GetAttribute("PaintSlot")).toBe("Decal")
		expect(decal.Color).toBeCloseTo(Color3.fromRGB(230, 190, 70), 1e-3)
		-- Rotation convention: offset then Angles(rad x, rad y, rad z).
		local windshield = model.Body:FindFirstChild("Windshield")
		local wsDef
		for _, part in ipairs(VehicleDefinitions.Vehicles.Van.visual.parts) do
			if part.name == "Windshield" then
				wsDef = part
			end
		end
		expect(wsDef).toBeTruthy()
		local expected = CFrame.new(0, VehicleDefinitions.Vehicles.Van.handling.rideHeight, 0)
			* CFrame.new(wsDef.offset[1], wsDef.offset[2], wsDef.offset[3])
			* CFrame.Angles(math.rad(wsDef.rot[1]), math.rad(wsDef.rot[2]), math.rad(wsDef.rot[3]))
		expect(windshield.CFrame).toBeCloseTo(expected, 1e-4)
	end)
end)

-------------------------------------------------------------------------------
-- EffectsController + CityLifeController (instances only)
-------------------------------------------------------------------------------

describe("EffectsController", function()
	it("reacts to door and pickup world events and to payouts", function()
		local ctx, _, ClientState = setup({ "EffectsController" })
		spawnAt(0, 0)
		local destinations = workspaceFolder("DeliveryDestinations")
		local model = Instance.new("Model")
		model.Name = "D_Near"
		local door = Instance.new("Part")
		door.Name = "Door"
		door.Size = v3(4, 7, 0.6)
		door.CFrame = CFrame.new(120, 3.5, -12)
		door.Anchored = true
		door.Parent = model
		model.Parent = destinations
		local closed = door.CFrame

		shim.tweensInstant = true
		ClientState.WorldEvent:Fire({ kind = "DoorReaction", destinationId = "D_Near", line = "Thanks!" })
		shim.advance(0.05)
		local fx = svc("Workspace").CurrentCamera.ClientFX
		expect(fx:FindFirstChild("SpeechBubble")).never.toBeNil()
		expect(fx.SpeechBubble.Bubble.Panel.Text.Text).toBe("Thanks!")
		expect(fx:FindFirstChild("Confetti")).never.toBeNil()
		expect((door.CFrame.Position - closed.Position).Magnitude).toBeGreaterThan(0.5)
		shim.advance(3.5)
		expect(door.CFrame).toBeCloseTo(closed, 1e-3)
		expect(fx:FindFirstChild("SpeechBubble")).toBeNil()

		ClientState.WorldEvent:Fire({ kind = "PickupReaction", businessId = "SliceStreetPizza", line = "Go go go!" })
		expect(fx:FindFirstChild("SpeechBubble")).never.toBeNil()
		ClientState.OrderEvent:Fire({ kind = "Delivered", orderId = "A", payout = { total = 57, newRecord = true } })
		expect(fx:FindFirstChild("PaymentPopup")).never.toBeNil()
		expect(fx.PaymentPopup.Popup.Text.Text).toBe("+$57")
		local gui = svc("Players").LocalPlayer.PlayerGui:FindFirstChild("DDC_Effects")
		expect(gui).never.toBeNil()
		expect(gui:FindFirstChild("Flash")).never.toBeNil()
	end)
end)

describe("CityLifeController", function()
	it("spawns walkers and idlers after 2 s with non-colliding anchored roots that move", function()
		-- Generated part figures (the embedded FigureRig path is covered by figures.spec.luau).
		requireShared("Util/FigureRig")._setMeshData({ has = function() return false end })
		local ctx = setup({ "CityLifeController" })
		local CityLife = ctx.controllers.CityLifeController
		shim.advance(1)
		expect(CityLife.GetCounts()).toBe(0)
		shim.advance(1.5)
		local walkers, idlers = CityLife.GetCounts()
		expect(walkers).toBe(3)
		expect(idlers).toBe(3) -- 2 customers (two destinations) + 1 depot worker
		local folder = svc("Workspace").CurrentCamera.ClientFX.NPCs
		local figure = nil
		for _, child in ipairs(folder:GetChildren()) do
			if child.Name == "Pedestrian" then
				figure = child
				break
			end
		end
		expect(figure).never.toBeNil()
		expect(figure.Root.Anchored).toBe(true)
		for _, part in ipairs(figure:GetDescendants()) do
			if part:IsA("BasePart") then
				expect(part.CanCollide).toBe(false)
				expect(part.CanQuery).toBe(false)
				expect(part.CanTouch).toBe(false)
			end
		end
		local before = figure.Root.Position
		shim.advance(1)
		expect((figure.Root.Position - before).Magnitude).toBeGreaterThan(3)
		expect(figure.LeftLeg.LeftHip.Transform).never.toBeCloseTo(CFrame.identity, 1e-6)
	end)
end)

-------------------------------------------------------------------------------
-- ClientBootstrap (integration through the virtual DataModel)
-------------------------------------------------------------------------------

describe("ClientBootstrap", function()
	it("seeds ClientState from GetSnapshot and forwards server events", function()
		shim.setContext("client")
		spawnAt(0, 0)
		local snapshotCalls = 0
		local Remotes = createRemotes({
			GetSnapshot = function()
				snapshotCalls += 1
				if snapshotCalls == 1 then
					return { ok = false, error = "Locked" }
				end
				return {
					ok = true,
					profile = { cash = 120, reputation = 10, equippedVehicle = "Bicycle", upgrades = {}, tutorial = { completed = false, step = 2 }, settings = { cameraSensitivity = 1, reducedMotion = false, autoRecenter = true, musicVolume = 0.6, sfxVolume = 0.8, showMinimap = true, invertCameraY = false }, cosmetics = { owned = {}, equipped = {} } },
					orders = { available = {}, active = {}, capacity = { current = 1, max = 1, load = 0, committed = 0 } },
					vehicle = { state = "Parked", vehicleId = "Bicycle" },
					contract = { status = "Idle", nextAt = os.clock() + 100, serverTime = os.clock() },
					depot = { owned = false, drivers = {}, slotsUnlocked = 0, pendingTotal = 0, categories = {}, publicPlots = {}, serverTime = os.clock() },
					tutorial = { completed = false, step = 2 },
					serverTime = os.clock() + 500,
				}
			end,
		})
		-- Keep the embedded mesh decode (EmbeddedMeshController.Start) out of this test: the real
		-- data modules would decode three 1024 px textures here. tests/specs/embedded_meshes.spec.luau covers it.
		local EmbeddedMeshController = require(clientInstance("Controllers").EmbeddedMeshController)
		EmbeddedMeshController._setDecoders({ list = function() return {} end })
		local thread = shim.runScript(clientInstance("ClientBootstrap"))
		shim.advance(3)
		local ClientState = requireClient("ClientState")
		expect(snapshotCalls).toBeGreaterThanOrEqual(2)
		expect(ClientState.get("profile").cash).toBe(120)
		expect(ClientState.get("serverTimeOffset")).toBeCloseTo(500, 0.01)
		expect(ClientState.get("vehicle").state).toBe("Parked")
		expect(ClientState.get("tutorial").step).toBe(2)
		expect(ClientState.get("contract").status).toBe("Idle")
		expect(ClientState.get("depot").owned).toBe(false)
		expect(ClientState.get("settings").sfxVolume).toBe(0.8)
		expect(ClientState.get("device")).toBe("Keyboard")

		local player = svc("Players").LocalPlayer
		local orderEvents, worldEvents = {}, {}
		ClientState.OrderEvent:Connect(function(payload)
			table.insert(orderEvents, payload.kind)
		end)
		ClientState.WorldEvent:Connect(function(payload)
			table.insert(worldEvents, payload.kind)
		end)
		Remotes.getEvent("OrdersUpdated"):FireClient(player, { available = { makeOrder("A", "Available") }, active = { makeOrder("B", "Accepted") }, serverTime = os.clock() + 600, capacity = { current = 1, max = 2, load = 0, committed = 1 } })
		Remotes.getEvent("OrderEvent"):FireClient(player, { kind = "Accepted", orderId = "B" })
		Remotes.getEvent("VehicleStateChanged"):FireClient(player, { state = "Despawning", vehicleId = nil })
		Remotes.getEvent("TutorialUpdated"):FireClient(player, { step = 3, completed = false, title = "Ride", body = "Go", hint = "Follow" })
		Remotes.getEvent("WorldEvent"):FireClient(player, { kind = "DriverDepart", plotId = "P1", slot = 1 })
		Remotes.getEvent("ProfileUpdated"):FireClient(player, { cash = 300, reputation = 10, equippedVehicle = "Bicycle", upgrades = {}, tutorial = { completed = false, step = 3 }, settings = { cameraSensitivity = 2, reducedMotion = false, autoRecenter = true, musicVolume = 0.6, sfxVolume = 0.8, showMinimap = true, invertCameraY = false }, cosmetics = { owned = {}, equipped = {} } })
		shim.advance(0.1)
		expect(#ClientState.get("orders").active).toBe(1)
		expect(ClientState.get("orders").capacity.max).toBe(2)
		expect(ClientState.get("serverTimeOffset")).toBeCloseTo(600, 0.2)
		expect(orderEvents).toEqual({ "Accepted" })
		expect(worldEvents).toEqual({ "DriverDepart" })
		-- Despawning is the server's terminal event: it is normalised to "no vehicle".
		expect(ClientState.get("vehicle").state).toBeNil()
		expect(ClientState.get("vehicle").vehicleId).toBeNil()
		expect(ClientState.get("vehicle").model).toBeNil()
		expect(ClientState.get("tutorial").step).toBe(3)
		expect(ClientState.get("tutorial").title).toBe("Ride")
		expect(ClientState.get("profile").cash).toBe(300)
		expect(ClientState.get("settings").cameraSensitivity).toBe(2)

		-- Telemetry heartbeat: at most one ClientHeartbeat per second.
		local heartbeats = 0
		for _, entry in ipairs(shim.remoteLog) do
			if entry.kind == "FireServer" and entry.remote.Name == "ClientHeartbeat" then
				heartbeats += 1
			end
		end
		expect(heartbeats).toBeGreaterThanOrEqual(2)
		expect(heartbeats).toBeLessThanOrEqual(4)
	end)
end)
