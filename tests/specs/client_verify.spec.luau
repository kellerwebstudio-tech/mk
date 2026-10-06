--!nonstrict
-- tests/specs/client_verify.spec.luau
-- Verification specs for the client controllers: regression tests for the defects fixed during the
-- adversarial review (camera pitch direction, depot prompt anchor, navigation recompute budget and
-- turn text, vehicle ground-probe filter, brake priority and the drive-input fallback).

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

local function requireClient(relativePath)
	local current = clientRoot()
	for segment in relativePath:gmatch("[^/]+") do
		current = current:FindFirstChild(segment) or error("No client instance at " .. relativePath)
	end
	return require(current)
end

local function svc(name)
	return game:GetService(name)
end

local function v3(x, y, z)
	return Vector3.new(x, y, z)
end

local LAYOUT = {
	name = "VerifyCity",
	bounds = { minX = -400, maxX = 400, minZ = -400, maxZ = 400 },
	groundY = 0,
	killY = -60,
	neighborhoods = {
		{ id = "Downtown", name = "Downtown", center = { x = 0, z = -50 }, bounds = { minX = -400, maxX = 400, minZ = -400, maxZ = 100 }, accent = { r = 1, g = 0.5, b = 0.2 } },
	},
	roads = {
		{ id = "Main", name = "Main Street", kind = "Road", width = 12, points = { { x = -300, z = 0 }, { x = 300, z = 0 } }, sidewalk = true, oneWay = false },
		{ id = "South", name = "South Road", kind = "Road", width = 12, points = { { x = 0, z = 0 }, { x = 0, z = 300 } }, sidewalk = true, oneWay = false },
	},
	water = {},
	bridges = {},
	buildings = {},
	businesses = {
		{ id = "SliceStreetPizza", name = "Slice Street Pizza", neighborhood = "Downtown", door = { x = -20, z = -14 }, facing = { x = 0, z = 1 }, pickupPoint = { x = -20, z = -9 }, arrivalPoint = { x = -20, z = -5 } },
	},
	destinations = {
		{ id = "D_Far", address = "3 South Road", neighborhood = "Downtown", kind = "House", door = { x = 12, z = 260 }, facing = { x = -1, z = 0 }, arrivalPoint = { x = 5, z = 260 }, accepts = { Small = true, Medium = true, Large = true } },
	},
	landmarks = { plaza = { x = 0, z = 0, r = 30 }, park = { x = 200, z = -200, w = 40, d = 40 }, hub = { x = 0, z = 30 } },
	hub = { spawn = { x = 0, z = 30, facing = { x = 0, z = -1 } }, vehiclePads = { { x = 10, z = 30, facing = { x = 0, z = -1 } } }, kiosk = { x = -300, z = -300 } },
	depotPlots = { { id = "P1", x = 80, z = 80, w = 60, d = 50, facing = { x = 0, z = -1 }, parking = {} } },
	pedestrianPaths = {},
	parkedVehicles = {},
	props = {},
	bikeShortcuts = {},
}

local function makeOrder(id, state, businessId, destinationId)
	return {
		id = id,
		userId = 1,
		businessId = businessId or "SliceStreetPizza",
		destinationId = destinationId or "D_Far",
		itemCategory = "Pizza",
		size = "Small",
		sizeUnits = 1,
		packageKey = "PizzaBox",
		itemLabel = "Margherita pizza",
		basePay = 40,
		tipMax = 12,
		repReward = 6,
		availableUntil = os.clock() + 100,
		prepTime = 0,
		routeDistance = 200,
		createdAt = os.clock(),
		state = state or "Accepted",
	}
end

local function newUIStub()
	local Signal = shim.requirePath("ReplicatedStorage/Shared/Util/Signal")
	local ui = {
		modal = false,
		prompt = nil,
		notifications = {},
		navigation = nil,
		minimap = nil,
		ModalChanged = Signal.new(),
		TutorialContinue = Signal.new(),
		PromptActivated = Signal.new(),
	}
	function ui.ShowPrompt(spec)
		ui.prompt = spec
	end
	function ui.HidePrompt()
		ui.prompt = nil
	end
	function ui.Notify(text, kind, duration)
		table.insert(ui.notifications, { text = text, kind = kind, duration = duration })
	end
	function ui.OpenScreen() end
	function ui.IsModalOpen()
		return ui.modal
	end
	function ui.SetNavigation(nav)
		ui.navigation = nav
	end
	function ui.SetMinimap(data)
		ui.minimap = data
	end
	function ui.SetVehicleHud() end
	function ui.SetTutorial() end
	function ui.ShowResults() end
	function ui.OpenDepotFor() end
	return ui
end

local function createRemotes()
	local Remotes = shim.requirePath("ReplicatedStorage/Shared/Util/Remotes")
	Remotes.createAll()
	for _, name in ipairs(Remotes.Functions) do
		Remotes.getFunction(name).OnServerInvoke = function()
			return { ok = true }
		end
	end
	return Remotes
end

local function setup(controllerNames)
	shim.setContext("client")
	local ClientState = requireClient("ClientState")
	ClientState.setLayout(LAYOUT)
	local RouteGraph = shim.requirePath("ReplicatedStorage/Shared/City/RouteGraph")
	local ui = newUIStub()
	local ctx = {
		state = ClientState,
		remotes = createRemotes(),
		layout = LAYOUT,
		graph = RouteGraph.build(LAYOUT),
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
	return shim.spawnCharacter(svc("Players").LocalPlayer, CFrame.new(x, 3, z))
end

local function moveTo(character, x, z)
	character:PivotTo(CFrame.new(x, 3, z))
end

local function setOrders(ClientState, active)
	ClientState.set("orders", { available = {}, active = active, capacity = { current = 1, max = 1, load = 0, committed = #active }, serverTime = os.clock() })
end

-- Minimal vehicle model with the parts the controllers resolve (ARCHITECTURE 8.3).
local function buildVehicleModel(vehicleId, ownerUserId, position)
	local VehicleDefinitions = shim.requirePath("ReplicatedStorage/Shared/Definitions/VehicleDefinitions")
	local def = VehicleDefinitions.get(vehicleId)
	local model = Instance.new("Model")
	model.Name = "Vehicle"
	model:SetAttribute("OwnerUserId", ownerUserId)
	model:SetAttribute("VehicleId", vehicleId)
	model:SetAttribute("State", "Parked")

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

	local wheels = Instance.new("Folder")
	wheels.Name = "Wheels"
	wheels.Parent = model

	local runtime = svc("Workspace"):FindFirstChild("Runtime")
	local folder = runtime and runtime:FindFirstChild("Vehicles")
	model.Parent = folder or svc("Workspace")
	return model, chassis, seat, velocity
end

-------------------------------------------------------------------------------
-- CameraController
-------------------------------------------------------------------------------

describe("CameraController orbit", function()
	it("OrbitOffset keeps the camera behind at zero orbit, raises it for positive pitch and lowers it for negative pitch", function()
		local Camera = requireClient("Controllers/CameraController")
		local forward = v3(0, 0, -1)
		local flat = Camera.OrbitOffset(forward, 13, 0, 0)
		expect(flat).toBeCloseTo(v3(0, 0, 13), 1e-6)

		local up = Camera.OrbitOffset(forward, 13, 0, math.rad(30))
		expect(up.Y).toBeGreaterThan(6)
		expect(up.Z).toBeGreaterThan(11)
		expect(math.abs(up.X)).toBeLessThan(1e-6)

		local down = Camera.OrbitOffset(forward, 13, 0, math.rad(-10))
		expect(down.Y).toBeLessThan(-2)
		expect(down.Y).toBeGreaterThan(-3)

		-- Positive yaw orbits the camera around toward the vehicle's right side (+X when facing -Z).
		local side = Camera.OrbitOffset(forward, 13, math.rad(90), 0)
		expect(side.X).toBeGreaterThan(12)
		expect(math.abs(side.Z)).toBeLessThan(1e-6)
	end)

	it("clamps the pitch to -10..45 degrees and never swings the camera 45 degrees below the vehicle", function()
		local ctx, _, ClientState = setup({ "InputController", "CameraController" })
		local Camera = ctx.controllers.CameraController
		spawnAt(0, 0)
		local model, chassis = buildVehicleModel("Bicycle", 1, v3(0, 0, 0))
		ClientState.set("vehicle", { state = "Driving", vehicleId = "Bicycle", model = model })
		shim.step(1 / 60)
		local camera = svc("Workspace").CurrentCamera
		expect(camera.CameraType).toBe(Enum.CameraType.Scriptable)

		local handling = shim.requirePath("ReplicatedStorage/Shared/Definitions/VehicleDefinitions").get("Bicycle").handling
		local pivotY = chassis.Position.Y + handling.cameraHeight

		Camera.ApplyOrbitDelta(0, 10) -- way past the clamp
		local _, pitch = Camera.GetOrbit()
		expect(pitch).toBeCloseTo(Camera.PITCH_MAX, 1e-9)
		for _ = 1, 90 do
			shim.step(1 / 60)
		end
		expect(camera.CFrame.Position.Y).toBeGreaterThan(pivotY + 5)

		Camera.ApplyOrbitDelta(0, -10)
		local _, pitchLow = Camera.GetOrbit()
		expect(pitchLow).toBeCloseTo(Camera.PITCH_MIN, 1e-9)
		for _ = 1, 120 do
			shim.step(1 / 60)
		end
		-- At most 10 degrees below the pivot: the camera stays above the ground.
		expect(camera.CFrame.Position.Y).toBeLessThan(pivotY)
		expect(camera.CFrame.Position.Y).toBeGreaterThan(pivotY - 3)
		expect(camera.CFrame.Position.Y).toBeGreaterThan(0)
	end)
end)

-------------------------------------------------------------------------------
-- InteractionController depot prompt
-------------------------------------------------------------------------------

describe("InteractionController depot prompt", function()
	it("anchors on the plot origin (DepotService.Collect distance) and not on the sign", function()
		local ctx, ui, ClientState = setup({ "InputController", "InteractionController" })
		local Interaction = ctx.controllers.InteractionController
		local EconomyConfig = shim.requirePath("ReplicatedStorage/Shared/Config/EconomyConfig")

		-- Plot model as CityBuilder builds it: Ground slab centred on the origin, the sign ~32 studs
		-- away at the front-left corner.
		local plots = workspaceFolder("DepotPlots")
		local plot = Instance.new("Model")
		plot.Name = "P1"
		plot:SetAttribute("PlotId", "P1")
		local ground = Instance.new("Part")
		ground.Name = "Ground"
		ground.Size = v3(60, 0.4, 50)
		ground.CFrame = CFrame.new(80, -0.2, 80)
		ground.Anchored = true
		ground.Parent = plot
		local sign = Instance.new("Part")
		sign.Name = "Sign"
		sign.Size = v3(4, 2, 0.3)
		sign.CFrame = CFrame.new(80 - 24, 4, 80 - 22)
		sign.Anchored = true
		sign.Parent = plot
		plot.Parent = plots

		ClientState.set("depot", { owned = true, plotId = "P1", pendingTotal = 120, drivers = {}, slotsUnlocked = 1, categories = {} })
		local character = spawnAt(sign.Position.X, sign.Position.Z)
		Interaction.Refresh()
		-- Standing at the sign is 32.6 studs from the origin: Collect would fail with TooFar.
		expect(ui.prompt).toBeNil()

		moveTo(character, 80, 80)
		Interaction.Refresh()
		expect(ui.prompt).never.toBeNil()
		expect(ui.prompt.kind).toBe("depot")
		expect(ui.prompt.detail).toBe("Collect $120")

		local limit = EconomyConfig.depotInteractDistance - Interaction.PROMPT_MARGIN
		moveTo(character, 80 + limit - 0.5, 80)
		Interaction.Refresh()
		expect(ui.prompt).never.toBeNil()
		moveTo(character, 80 + limit + 1, 80)
		Interaction.Refresh()
		expect(ui.prompt).toBeNil()
	end)
end)

-------------------------------------------------------------------------------
-- NavigationController
-------------------------------------------------------------------------------

describe("NavigationController budget and turn text", function()
	it("rate-limits off-route recomputes to one per OFF_ROUTE_MIN_INTERVAL", function()
		local ctx, _, ClientState = setup({ "InputController", "NavigationController" })
		local Navigation = ctx.controllers.NavigationController
		local character = spawnAt(-200, 0)
		setOrders(ClientState, { makeOrder("A", "Accepted") })
		Navigation.Refresh()
		local path = Navigation.GetPath()
		expect(path).never.toBeNil()
		expect(path[1]).toBeCloseTo(v3(-200, 3, 0), 1e-6)

		-- 60 studs off the polyline: the first off-route recompute waits for the minimum interval.
		moveTo(character, -200, 60)
		Navigation.Refresh()
		expect(Navigation.GetPath()[1]).toBeCloseTo(v3(-200, 3, 0), 1e-6)
		shim.advance(Navigation.OFF_ROUTE_MIN_INTERVAL * 0.5)
		expect(Navigation.GetPath()[1]).toBeCloseTo(v3(-200, 3, 0), 1e-6)
		shim.advance(Navigation.OFF_ROUTE_MIN_INTERVAL * 0.7)
		expect(Navigation.GetPath()[1]).toBeCloseTo(v3(-200, 3, 60), 1e-6)
	end)

	it("says Straight (not Arrive) while the stop is far ahead with no turn left", function()
		local ctx, ui, ClientState = setup({ "InputController", "NavigationController" })
		local Navigation = ctx.controllers.NavigationController
		-- Streamed destination whose door sits exactly on South Road, so the route has no turn.
		local destinations = workspaceFolder("DeliveryDestinations")
		local model = Instance.new("Model")
		model.Name = "D_Far"
		model:SetAttribute("DestinationId", "D_Far")
		local door = Instance.new("Part")
		door.Name = "Door"
		door.Size = v3(4, 6, 0.4)
		door.CFrame = CFrame.new(0, 3, 260)
		door.Anchored = true
		door.Parent = model
		model.Parent = destinations

		local character = spawnAt(0, 50)
		setOrders(ClientState, { makeOrder("B", "Collected", "SliceStreetPizza", "D_Far") })
		Navigation.Refresh()
		expect(ui.navigation.active).toBe(true)
		expect(ui.navigation.stopKind).toBe("deliver")
		expect(ui.navigation.turnKind).toBe("Straight")
		expect(ui.navigation.turnDistance).toBeGreaterThan(200)

		moveTo(character, 0, 250)
		shim.advance(Navigation.OFF_ROUTE_MIN_INTERVAL + 0.2)
		expect(ui.navigation.turnKind).toBe("Arrive")
		expect(ui.navigation.turnDistance).toBeLessThan(15)
	end)
end)

-------------------------------------------------------------------------------
-- VehicleController ground probe
-------------------------------------------------------------------------------

describe("VehicleController ground probe", function()
	it("raycasts as the Vehicles collision group and refreshes the character exclude list", function()
		local ctx, _, ClientState = setup({ "InputController", "VehicleController" })
		local VehicleController = ctx.controllers.VehicleController
		local captured = nil
		shim.setRaycast(function(origin, direction, params)
			captured = params
			if direction.Y >= 0 or origin.Y < 0 then
				return nil
			end
			local t = origin.Y / -direction.Y
			if t > 1 then
				return nil
			end
			return {
				Position = v3(origin.X, 0, origin.Z),
				Normal = v3(0, 1, 0),
				Material = Enum.Material.Concrete,
				Instance = svc("Workspace").Terrain,
				Distance = origin.Y,
			}
		end)
		local character = spawnAt(0, 0)
		local model, _, seat = buildVehicleModel("Bicycle", 1, v3(0, 0, 0))
		seat:Sit(character.Humanoid)
		ClientState.set("vehicle", { state = "Driving", vehicleId = "Bicycle", model = model })
		shim.advance(0.2)
		expect(VehicleController.IsActive()).toBe(true)
		expect(captured).never.toBeNil()
		expect(captured.CollisionGroup).toBe("Vehicles")
		expect(captured.FilterType).toBe(Enum.RaycastFilterType.Exclude)

		local function filterHas(instance)
			for _, entry in ipairs(captured.FilterDescendantsInstances) do
				if entry == instance then
					return true
				end
			end
			return false
		end
		local vehiclesFolder = svc("Workspace").Runtime.Vehicles
		expect(filterHas(vehiclesFolder)).toBe(true)
		expect(filterHas(character)).toBe(true)

		-- A player that spawns later is excluded after the periodic refresh.
		local other = shim.addPlayer("Other", 2)
		local otherCharacter = shim.spawnCharacter(other, CFrame.new(10, 3, 0))
		shim.advance(0.2)
		expect(filterHas(otherCharacter)).toBe(false)
		shim.advance(VehicleController.RAYCAST_REFRESH_INTERVAL + 0.2)
		expect(filterHas(otherCharacter)).toBe(true)
	end)
end)

-------------------------------------------------------------------------------
-- InputController
-------------------------------------------------------------------------------

describe("InputController brake and drive fallback", function()
	local InputActions

	beforeEach(function()
		InputActions = shim.requirePath("ReplicatedStorage/Shared/InputActions")
	end)

	it("binds Brake above a Default-priority jump action so Space brakes instead of ejecting the rider", function()
		local ctx, _, ClientState = setup({ "InputController" })
		local Input = ctx.controllers.InputController
		ClientState.set("vehicle", { state = "Driving", vehicleId = "Bicycle", model = nil })
		local jumpCalls = 0
		-- Bound after the controller, at the same priority InputActions uses: without the bump this
		-- later binding would win the key.
		svc("ContextActionService"):BindActionAtPriority("TestJump", function()
			jumpCalls += 1
			return Enum.ContextActionResult.Sink
		end, false, Enum.ContextActionPriority.Default.Value, Enum.KeyCode.Space)

		shim.input.press(Enum.KeyCode.Space)
		expect(Input.IsDown(InputActions.Names.Brake)).toBe(true)
		expect(jumpCalls).toBe(0)
		local _, _, brake = Input.GetDriveInput()
		expect(brake).toBe(true)
		shim.input.release(Enum.KeyCode.Space)
		expect(Input.IsDown(InputActions.Names.Brake)).toBe(false)
		svc("ContextActionService"):UnbindAction("TestJump")
	end)

	it("swallows the gamepad jump button only while driving", function()
		local ctx, _, ClientState = setup({ "InputController" })
		local jumpCalls = 0
		svc("ContextActionService"):BindActionAtPriority("TestGamepadJump", function()
			jumpCalls += 1
			return Enum.ContextActionResult.Sink
		end, false, Enum.ContextActionPriority.Default.Value, Enum.KeyCode.ButtonA)

		shim.input.tap(Enum.KeyCode.ButtonA, Enum.UserInputType.Gamepad1)
		expect(jumpCalls).toBe(2) -- Begin + End reach the jump action on foot

		ClientState.set("vehicle", { state = "Driving", vehicleId = "Bicycle", model = nil })
		shim.input.tap(Enum.KeyCode.ButtonA, Enum.UserInputType.Gamepad1)
		expect(jumpCalls).toBe(2)

		ClientState.set("vehicle", { state = "Parked", vehicleId = "Bicycle", model = nil })
		shim.input.tap(Enum.KeyCode.ButtonA, Enum.UserInputType.Gamepad1)
		expect(jumpCalls).toBe(4)
		svc("ContextActionService"):UnbindAction("TestGamepadJump")
		expect(ctx.controllers.InputController.IsDown(InputActions.Names.Brake)).toBe(false)
	end)

	it("falls back to keyboard keys and the humanoid move direction when the seat floats are zero", function()
		local ctx = setup({ "InputController" })
		local Input = ctx.controllers.InputController
		local character = spawnAt(0, 0)
		local seat = Instance.new("VehicleSeat")
		seat.Name = "Seat"
		seat.CFrame = CFrame.new(0, 2, 0) -- facing -Z
		seat.Parent = svc("Workspace")
		seat:Sit(character.Humanoid)

		local throttle, steer = Input.GetDriveInput()
		expect(throttle).toBe(0)
		expect(steer).toBe(0)

		shim.input.press(Enum.KeyCode.W)
		shim.input.press(Enum.KeyCode.D)
		throttle, steer = Input.GetDriveInput()
		expect(throttle).toBe(1)
		expect(steer).toBe(1)
		shim.input.release(Enum.KeyCode.W)
		shim.input.release(Enum.KeyCode.D)
		shim.input.press(Enum.KeyCode.Down)
		shim.input.press(Enum.KeyCode.Left)
		throttle, steer = Input.GetDriveInput()
		expect(throttle).toBe(-1)
		expect(steer).toBe(-1)
		shim.input.release(Enum.KeyCode.Down)
		shim.input.release(Enum.KeyCode.Left)

		-- Camera-relative move direction (touch thumbstick / PlayerModule) projected on the seat axes.
		character.Humanoid:Move(v3(0, 0, -1))
		throttle, steer = Input.GetDriveInput()
		expect(throttle).toBeCloseTo(1, 1e-6)
		expect(math.abs(steer)).toBeLessThan(1e-6)
		character.Humanoid:Move(v3(1, 0, 0))
		throttle, steer = Input.GetDriveInput()
		expect(steer).toBeCloseTo(1, 1e-6)
		character.Humanoid:Move(Vector3.zero)

		-- The seat floats win whenever the engine provides them.
		shim.input.press(Enum.KeyCode.W)
		seat.ThrottleFloat = -0.5
		seat.SteerFloat = 0.25
		throttle, steer = Input.GetDriveInput()
		expect(throttle).toBe(-0.5)
		expect(steer).toBe(0.25)
		shim.input.release(Enum.KeyCode.W)
	end)
end)
