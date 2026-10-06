--!nonstrict
-- ClientBootstrap: builds the ClientContext, requires every controller, Inits then Starts them in
-- the documented order (docs/ARCHITECTURE.md section 7), seeds ClientState from GetSnapshot and
-- forwards every server -> client RemoteEvent into ClientState / the UI.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Util = Shared:WaitForChild("Util")
local Remotes = require(Util:WaitForChild("Remotes"))

local ClientRoot = script.Parent
local ClientState = require(ClientRoot:WaitForChild("ClientState"))
local ControllersFolder = ClientRoot:FindFirstChild("Controllers") or script:FindFirstChild("Controllers") or ClientRoot:WaitForChild("Controllers")

local CONTROLLER_ORDER = {
	"SettingsController",
	"UIController",
	"InputController",
	"CameraController",
	"VehicleController",
	"NavigationController",
	"InteractionController",
	"AudioController",
	"EffectsController",
	"CityLifeController",
	"CosmeticsController",
	"TutorialController",
}

local SNAPSHOT_TIMEOUT = 30
local HEARTBEAT_INTERVAL = 1

-------------------------------------------------------------------------------
-- CoreGui setup
-------------------------------------------------------------------------------

local function configureCoreGui()
	task.spawn(function()
		for attempt = 1, 10 do
			local ok = pcall(function()
				StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
				StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.EmotesMenu, false)
				StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)
				StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, true)
				StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Chat, true)
			end)
			if ok then
				return
			end
			task.wait(attempt * 0.5)
		end
	end)
end

-------------------------------------------------------------------------------
-- Layout and graph
-------------------------------------------------------------------------------

local layout = nil
local graph = nil
do
	local cityFolder = Shared:WaitForChild("City", 10)
	local layoutModule = cityFolder and cityFolder:WaitForChild("CityLayout", 10)
	local graphModule = cityFolder and cityFolder:WaitForChild("RouteGraph", 10)
	if layoutModule then
		local okLayout, result = pcall(require, layoutModule)
		if okLayout then
			layout = result
		else
			warn("[ClientBootstrap] CityLayout failed to load: " .. tostring(result))
		end
	else
		warn("[ClientBootstrap] CityLayout module not found")
	end
	if graphModule and layout then
		local okGraph, RouteGraph = pcall(require, graphModule)
		if okGraph then
			local okBuild, built = pcall(RouteGraph.build, layout)
			if okBuild then
				graph = built
			else
				warn("[ClientBootstrap] RouteGraph.build failed: " .. tostring(built))
			end
		else
			warn("[ClientBootstrap] RouteGraph failed to load: " .. tostring(RouteGraph))
		end
	end
end
ClientState.setLayout(layout)

local ctx = {
	state = ClientState,
	remotes = Remotes,
	layout = layout,
	graph = graph,
	controllers = {},
}

-------------------------------------------------------------------------------
-- Controllers
-------------------------------------------------------------------------------

local ordered = {}
local seen = {}

local function addController(name: string, module: Instance)
	if seen[name] then
		return
	end
	seen[name] = true
	local okRequire, controller = pcall(require, module)
	if not okRequire then
		warn(string.format("[ClientBootstrap] failed to require %s: %s", name, tostring(controller)))
		return
	end
	if type(controller) ~= "table" then
		warn(string.format("[ClientBootstrap] %s did not return a table", name))
		return
	end
	ctx.controllers[name] = controller
	table.insert(ordered, { name = name, controller = controller })
end

for _, name in ipairs(CONTROLLER_ORDER) do
	local module = ControllersFolder:FindFirstChild(name)
	if module and module:IsA("ModuleScript") then
		addController(name, module)
	else
		warn(string.format("[ClientBootstrap] controller %s not found", name))
	end
end
for _, module in ipairs(ControllersFolder:GetChildren()) do
	if module:IsA("ModuleScript") and not seen[module.Name] then
		addController(module.Name, module)
	end
end

for _, entry in ipairs(ordered) do
	if type(entry.controller.Init) == "function" then
		local okInit, err = pcall(entry.controller.Init, ctx)
		if not okInit then
			warn(string.format("[ClientBootstrap] %s.Init failed: %s", entry.name, tostring(err)))
		end
	end
end

for _, entry in ipairs(ordered) do
	if type(entry.controller.Start) == "function" then
		local okStart, err = pcall(entry.controller.Start)
		if not okStart then
			warn(string.format("[ClientBootstrap] %s.Start failed: %s", entry.name, tostring(err)))
		end
	end
end

configureCoreGui()

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local function ui()
	return ctx.controllers.UIController
end

local function callUI(method: string, ...)
	local controller = ui()
	if controller and type(controller[method]) == "function" then
		local ok, err = pcall(controller[method], ...)
		if not ok then
			warn("[ClientBootstrap] UIController." .. method .. " failed: " .. tostring(err))
		end
	end
end

local function applyServerTime(serverTime: any)
	if type(serverTime) == "number" then
		ClientState.set("serverTimeOffset", serverTime - os.clock())
	end
end

local function applyOrders(orders: any)
	if type(orders) ~= "table" then
		return
	end
	ClientState.set("orders", {
		available = type(orders.available) == "table" and orders.available or {},
		active = type(orders.active) == "table" and orders.active or {},
		capacity = orders.capacity,
		serverTime = orders.serverTime,
	})
	applyServerTime(orders.serverTime)
end

local function applyProfile(profile: any)
	if type(profile) ~= "table" then
		return
	end
	ClientState.set("profile", profile)
	if type(profile.tutorial) == "table" then
		local current = ClientState.get("tutorial") or {}
		if current.step ~= profile.tutorial.step or current.completed ~= profile.tutorial.completed then
			ClientState.set("tutorial", {
				step = profile.tutorial.step,
				completed = profile.tutorial.completed,
				title = current.step == profile.tutorial.step and current.title or nil,
				body = current.step == profile.tutorial.step and current.body or nil,
				hint = current.step == profile.tutorial.step and current.hint or nil,
			})
		end
	end
end

local function applyVehicle(vehicle: any)
	if type(vehicle) ~= "table" then
		ClientState.set("vehicle", { state = nil, vehicleId = nil, model = nil })
		return
	end
	local current = ClientState.get("vehicle") or {}
	local model = vehicle.model
	if typeof(model) ~= "Instance" then
		model = (vehicle.state ~= nil and vehicle.state ~= "Despawning") and current.model or nil
	end
	ClientState.set("vehicle", {
		state = vehicle.state,
		vehicleId = vehicle.vehicleId,
		model = model,
	})
end

local function applyTutorial(payload: any)
	if type(payload) ~= "table" then
		return
	end
	ClientState.set("tutorial", {
		step = tonumber(payload.step) or 0,
		completed = payload.completed == true,
		title = payload.title,
		body = payload.body,
		hint = payload.hint,
	})
end

-------------------------------------------------------------------------------
-- Snapshot
-------------------------------------------------------------------------------

local function fetchSnapshot()
	local deadline = os.clock() + SNAPSHOT_TIMEOUT
	local attempt = 0
	while os.clock() < deadline do
		attempt += 1
		local ok, result = pcall(function()
			return Remotes.getFunction("GetSnapshot"):InvokeServer()
		end)
		if ok and type(result) == "table" and result.ok and type(result.profile) == "table" then
			applyServerTime(result.serverTime)
			applyProfile(result.profile)
			applyOrders(result.orders)
			applyVehicle(result.vehicle)
			if result.contract ~= nil then
				ClientState.set("contract", result.contract)
			end
			if result.depot ~= nil then
				ClientState.set("depot", result.depot)
			end
			if type(result.tutorial) == "table" then
				applyTutorial(result.tutorial)
			end
			return true
		end
		if not ok then
			warn("[ClientBootstrap] GetSnapshot failed: " .. tostring(result))
		end
		task.wait(math.min(1 + attempt * 0.5, 3))
	end
	warn("[ClientBootstrap] GetSnapshot did not return a profile within " .. SNAPSHOT_TIMEOUT .. " s")
	callUI("Notify", "Still loading your profile...", "warning", 5)
	return false
end

-------------------------------------------------------------------------------
-- Server -> client events
-------------------------------------------------------------------------------

local function connectEvent(name: string, handler: (any) -> ())
	local ok, event = pcall(Remotes.getEvent, name)
	if not ok or not event then
		warn("[ClientBootstrap] remote event " .. name .. " unavailable")
		return
	end
	event.OnClientEvent:Connect(function(payload)
		local okHandle, err = pcall(handler, payload)
		if not okHandle then
			warn("[ClientBootstrap] " .. name .. " handler failed: " .. tostring(err))
		end
	end)
end

local function subscribe()
	connectEvent("ProfileUpdated", applyProfile)
	connectEvent("OrdersUpdated", applyOrders)
	connectEvent("OrderEvent", function(payload)
		if type(payload) ~= "table" then
			return
		end
		ClientState.OrderEvent:Fire(payload)
		if payload.kind == "Delivered" and type(payload.payout) == "table" and type(payload.order) == "table" then
			callUI("ShowResults", payload.payout, payload.order)
		end
	end)
	connectEvent("VehicleStateChanged", applyVehicle)
	connectEvent("ContractUpdated", function(payload)
		ClientState.set("contract", payload)
		if type(payload) == "table" then
			applyServerTime(payload.serverTime)
		end
	end)
	connectEvent("DepotUpdated", function(payload)
		ClientState.set("depot", payload)
		if type(payload) == "table" then
			applyServerTime(payload.serverTime)
		end
	end)
	connectEvent("TutorialUpdated", applyTutorial)
	connectEvent("Notify", function(payload)
		if type(payload) == "table" and type(payload.text) == "string" then
			callUI("Notify", payload.text, payload.kind or "info", payload.duration)
		end
	end)
	connectEvent("WorldEvent", function(payload)
		if type(payload) == "table" then
			ClientState.WorldEvent:Fire(payload)
		end
	end)
end

-- Telemetry heartbeat (at most once per second; never used for rewards).
local function startHeartbeat()
	local okEvent, event = pcall(Remotes.getEvent, "ClientHeartbeat")
	if not okEvent or not event then
		return
	end
	local elapsed = 0
	RunService.Heartbeat:Connect(function(dt)
		elapsed += dt
		if elapsed < HEARTBEAT_INTERVAL then
			return
		end
		elapsed = 0
		local vehicleController = ctx.controllers.VehicleController
		local speed = 0
		if vehicleController and type(vehicleController.GetSpeed) == "function" then
			speed = vehicleController.GetSpeed()
		end
		pcall(function()
			event:FireServer({ vehicleSpeed = speed })
		end)
	end)
end

-- Subscribe before fetching so nothing sent during the snapshot round-trip is missed.
subscribe()
task.spawn(fetchSnapshot)
startHeartbeat()

print(string.format("Delivery Dash City client ready (%d controllers) for %s", #ordered, Players.LocalPlayer and Players.LocalPlayer.Name or "?"))
