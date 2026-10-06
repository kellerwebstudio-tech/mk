--!nonstrict
-- InteractionController: proximity scanning (every 0.15 s) for pickups, deliveries, the own
-- vehicle, the own depot plot and the hub kiosk. Shows one prompt through UIController and acts
-- on the Interact / MountDismount actions by calling the matching remotes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Util = Shared:WaitForChild("Util")
local Config = Shared:WaitForChild("Config")
local MathUtil = require(Util:WaitForChild("MathUtil"))
local EconomyConfig = require(Config:WaitForChild("EconomyConfig"))
local InputActions = require(Shared:WaitForChild("InputActions"))

local InteractionController = {}

InteractionController.SCAN_INTERVAL = 0.15
InteractionController.PROMPT_MARGIN = 2 -- prompts appear this much inside the server distance
InteractionController.KIOSK_DISTANCE = 12
InteractionController.PAD_SPAWN_DISTANCE = 20
InteractionController.DISMOUNT_MAX_SPEED = 2

local ctx = nil
local accumulator = 0
local current = nil -- current candidate {kind, text, action, detail, orderId?, plotId?}
local shownSignature: string? = nil
local busy = false
local mountVisible = false

local function controller(name: string)
	return ctx and ctx.controllers and ctx.controllers[name] or nil
end

local function callController(name: string, method: string, ...)
	local target = controller(name)
	if target and type(target[method]) == "function" then
		local ok, result = pcall(target[method], ...)
		if not ok then
			warn("[InteractionController] " .. name .. "." .. method .. " failed: " .. tostring(result))
			return nil
		end
		return result
	end
	return nil
end

local function notify(text: string, kind: string)
	callController("UIController", "Notify", text, kind, 3)
end

local function playerPosition(): Vector3?
	return ctx.state.getPlayerPosition()
end

local function flatDistance(a: Vector3, b: Vector3): number
	return MathUtil.horizontalDistance(a, b)
end

local function vehicleSpeed(): number
	local vehicleController = controller("VehicleController")
	if vehicleController and type(vehicleController.GetSpeed) == "function" then
		return math.abs(vehicleController.GetSpeed())
	end
	return 0
end

-------------------------------------------------------------------------------
-- Candidate scanning
-------------------------------------------------------------------------------

local function orderCandidate(position: Vector3)
	local best = nil
	local bestDistance = math.huge
	for _, order in ipairs(ctx.state.getActiveOrders()) do
		local state = order.state
		if state == "Accepted" or state == "ReadyForPickup" then
			local point = ctx.state.getBusinessPickupPosition(order.businessId)
			if point then
				local distance = flatDistance(position, point)
				if distance <= EconomyConfig.pickupDistance - InteractionController.PROMPT_MARGIN and distance < bestDistance then
					local now = ctx.state.serverNow()
					local ready = state == "ReadyForPickup" or (type(order.readyAt) == "number" and now >= order.readyAt)
					if ready then
						best = { kind = "pickup", text = "Collect order", detail = order.itemLabel, action = InputActions.Names.Interact, orderId = order.id }
					else
						local seconds = math.max(1, math.ceil((order.readyAt or now) - now))
						best = { kind = "wait", text = string.format("Preparing... %ds", seconds), detail = order.itemLabel, action = InputActions.Names.Interact, orderId = order.id, waitSeconds = seconds }
					end
					bestDistance = distance
				end
			end
		elseif state == "Collected" then
			local door = ctx.state.getDestinationDoorPosition(order.destinationId)
			local arrival = ctx.state.getDestinationArrivalPosition(order.destinationId)
			local doorDistance = door and flatDistance(position, door) or math.huge
			local arrivalDistance = arrival and flatDistance(position, arrival) or math.huge
			local inRange = doorDistance <= EconomyConfig.deliveryDistance - InteractionController.PROMPT_MARGIN
				or arrivalDistance <= EconomyConfig.deliveryArrivalDistance - InteractionController.PROMPT_MARGIN
			local distance = math.min(doorDistance, arrivalDistance)
			if inRange and distance < bestDistance then
				best = { kind = "deliver", text = "Deliver order", detail = ctx.state.getDestinationAddress(order.destinationId), action = InputActions.Names.Interact, orderId = order.id }
				bestDistance = distance
			end
		end
	end
	return best
end

local function ownVehicleChassis(): BasePart?
	local vehicle = ctx.state.get("vehicle")
	if not vehicle then
		return nil
	end
	local model = vehicle.model
	if typeof(model) ~= "Instance" or not model.Parent then
		local vehicleController = controller("VehicleController")
		model = vehicleController and type(vehicleController.GetModel) == "function" and vehicleController.GetModel() or nil
	end
	if typeof(model) == "Instance" then
		local chassis = model:FindFirstChild("Chassis")
		if chassis and chassis:IsA("BasePart") then
			return chassis
		end
	end
	return nil
end

local function vehicleCandidate(position: Vector3)
	local vehicle = ctx.state.get("vehicle")
	if not vehicle or not vehicle.state then
		return nil
	end
	if vehicle.state == "Parked" then
		local chassis = ownVehicleChassis()
		if chassis and flatDistance(position, chassis.Position) <= EconomyConfig.mountDistance - InteractionController.PROMPT_MARGIN then
			return { kind = "mount", text = "Ride", action = InputActions.Names.MountDismount, detail = vehicle.vehicleId }
		end
	elseif vehicle.state == "Driving" then
		if vehicleSpeed() < InteractionController.DISMOUNT_MAX_SPEED then
			return { kind = "dismount", text = "Dismount", action = InputActions.Names.MountDismount, detail = vehicle.vehicleId }
		end
	end
	return nil
end

local function depotCandidate(position: Vector3)
	local depot = ctx.state.get("depot")
	if not depot or not depot.owned or type(depot.plotId) ~= "string" then
		return nil
	end
	local plotsFolder = Workspace:FindFirstChild("DepotPlots")
	local plot = plotsFolder and plotsFolder:FindFirstChild(depot.plotId)
	local point: Vector3? = nil
	if plot then
		local sign = plot:FindFirstChild("Sign")
		if sign and sign:IsA("BasePart") then
			point = sign.Position
		else
			local okPivot, pivot = pcall(function()
				return plot:GetPivot()
			end)
			if okPivot then
				point = pivot.Position
			end
		end
	else
		local layout = ctx.layout
		for _, entry in ipairs(layout and layout.depotPlots or {}) do
			if entry.id == depot.plotId then
				point = Vector3.new(entry.x, layout.groundY or 0, entry.z)
			end
		end
	end
	if point and flatDistance(position, point) <= EconomyConfig.depotInteractDistance - InteractionController.PROMPT_MARGIN then
		local pending = type(depot.pendingTotal) == "number" and depot.pendingTotal or 0
		local detail = pending > 0 and ("Collect " .. MathUtil.formatCash(pending)) or "Manage drivers"
		return { kind = "depot", text = "Open depot", action = InputActions.Names.Interact, detail = detail, plotId = depot.plotId }
	end
	return nil
end

local function kioskCandidate(position: Vector3)
	local layout = ctx.layout
	local kiosk = layout and layout.hub and layout.hub.kiosk
	if not kiosk then
		return nil
	end
	local point = Vector3.new(kiosk.x, layout.groundY or 0, kiosk.z)
	if flatDistance(position, point) <= InteractionController.KIOSK_DISTANCE then
		return { kind = "depot", text = "Order board", action = InputActions.Names.Interact, detail = "Browse orders", kiosk = true }
	end
	return nil
end

local function nearVehiclePad(position: Vector3): boolean
	local layout = ctx.layout
	local pads = layout and layout.hub and layout.hub.vehiclePads or {}
	for _, pad in ipairs(pads) do
		if flatDistance(position, Vector3.new(pad.x, layout.groundY or 0, pad.z)) <= InteractionController.PAD_SPAWN_DISTANCE then
			return true
		end
	end
	return false
end

local function spawnCandidate(position: Vector3)
	local vehicle = ctx.state.get("vehicle")
	if vehicle and vehicle.state then
		return nil
	end
	local profile = ctx.state.get("profile")
	if not profile then
		return nil
	end
	if nearVehiclePad(position) then
		return { kind = "mount", text = "Take vehicle", action = InputActions.Names.MountDismount, detail = profile.equippedVehicle, spawn = true }
	end
	return nil
end

-- Priority: order stops, then depot/kiosk, then vehicle (mount/dismount/spawn).
local function pickCandidate(position: Vector3)
	local order = orderCandidate(position)
	if order then
		return order
	end
	local depot = depotCandidate(position)
	if depot then
		return depot
	end
	local kiosk = kioskCandidate(position)
	if kiosk then
		return kiosk
	end
	return vehicleCandidate(position) or spawnCandidate(position)
end

local function signatureOf(candidate): string
	if not candidate then
		return ""
	end
	return table.concat({ candidate.kind, candidate.text, tostring(candidate.detail), tostring(candidate.orderId) }, "|")
end

local function showCandidate(candidate)
	current = candidate
	local signature = signatureOf(candidate)
	if signature == shownSignature then
		return
	end
	shownSignature = signature
	if candidate then
		callController("UIController", "ShowPrompt", { text = candidate.text, action = candidate.action, kind = candidate.kind, detail = candidate.detail })
	else
		callController("UIController", "HidePrompt")
	end
	callController("InputController", "SetActionVisible", InputActions.Names.Interact, candidate ~= nil and candidate.action == InputActions.Names.Interact)
end

local function scan()
	local position = playerPosition()
	if not position then
		showCandidate(nil)
		return
	end
	local candidate = pickCandidate(position)
	showCandidate(candidate)

	-- The mount/dismount touch button is useful whenever a vehicle action is possible.
	local vehicleAction = vehicleCandidate(position) or spawnCandidate(position)
	local wantMount = vehicleAction ~= nil
	if wantMount ~= mountVisible then
		mountVisible = wantMount
		callController("InputController", "SetActionVisible", InputActions.Names.MountDismount, wantMount)
	end
end

-- Runs one scan immediately (tests and state changes).
function InteractionController.Refresh()
	local ok, err = pcall(scan)
	if not ok then
		warn("[InteractionController] scan failed: " .. tostring(err))
	end
end

function InteractionController.GetCurrentPrompt()
	return current
end

-------------------------------------------------------------------------------
-- Actions
-------------------------------------------------------------------------------

local function invoke(name: string, ...): any
	local okInvoke, result = pcall(function(...)
		return ctx.remotes.getFunction(name):InvokeServer(...)
	end, ...)
	if not okInvoke then
		warn("[InteractionController] " .. name .. " failed: " .. tostring(result))
		return { ok = false, error = "Internal", message = "Something went wrong, try again." }
	end
	if type(result) ~= "table" then
		return { ok = false, error = "Internal", message = "No response from the server." }
	end
	return result
end

local function handleResult(result, successSound: string?)
	if result.ok then
		if successSound then
			callController("AudioController", "Play", successSound)
		end
		return
	end
	if result.error == "NotReady" then
		local seconds = tonumber(result.secondsLeft) or 0
		notify(string.format("Not ready yet, %d s to go", math.max(1, math.ceil(seconds))), "info")
	else
		notify(result.message or result.error or "Action failed", "warning")
		callController("AudioController", "Play", "Error")
	end
end

local function onInteract()
	local candidate = current
	if not candidate or busy then
		return
	end
	if candidate.kind == "pickup" or candidate.kind == "wait" then
		busy = true
		task.spawn(function()
			local result = invoke("RequestPickup", candidate.orderId)
			busy = false
			handleResult(result, nil)
			InteractionController.Refresh()
		end)
	elseif candidate.kind == "deliver" then
		busy = true
		task.spawn(function()
			local result = invoke("RequestDelivery", candidate.orderId)
			busy = false
			handleResult(result, "Doorbell")
			InteractionController.Refresh()
		end)
	elseif candidate.kind == "depot" then
		callController("AudioController", "Play", "UIClick")
		if candidate.kiosk then
			callController("UIController", "OpenScreen", "Orders")
		else
			local ui = controller("UIController")
			if ui and type(ui.OpenDepotFor) == "function" then
				pcall(ui.OpenDepotFor, candidate.plotId)
			else
				callController("UIController", "OpenScreen", "Depot")
			end
		end
	end
end

local function onMountDismount()
	if busy then
		return
	end
	local vehicle = ctx.state.get("vehicle")
	local position = playerPosition()
	if not position then
		return
	end
	if vehicle and vehicle.state == "Driving" then
		if vehicleSpeed() >= InteractionController.DISMOUNT_MAX_SPEED then
			notify("Slow down to get off", "info")
			return
		end
		busy = true
		task.spawn(function()
			local result = invoke("DismountVehicle")
			busy = false
			handleResult(result, nil)
		end)
	elseif vehicle and vehicle.state == "Parked" then
		local chassis = ownVehicleChassis()
		if chassis and flatDistance(position, chassis.Position) <= EconomyConfig.mountDistance then
			busy = true
			task.spawn(function()
				local result = invoke("MountVehicle")
				busy = false
				handleResult(result, "Mount")
			end)
		else
			notify("Walk closer to your vehicle", "info")
		end
	elseif not vehicle or not vehicle.state then
		local profile = ctx.state.get("profile")
		if profile and nearVehiclePad(position) then
			busy = true
			task.spawn(function()
				local result = invoke("SpawnVehicle", profile.equippedVehicle)
				busy = false
				handleResult(result, "UIClick")
				InteractionController.Refresh()
			end)
		end
	end
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

function InteractionController.Init(context)
	ctx = context
end

function InteractionController.Start()
	local input = controller("InputController")
	if input and input.Pressed then
		input.Pressed:Connect(function(actionName)
			if actionName == InputActions.Names.Interact then
				onInteract()
			elseif actionName == InputActions.Names.MountDismount then
				onMountDismount()
			end
		end)
	end

	ctx.state.Changed:Connect(function(key)
		if key == "orders" or key == "vehicle" or key == "depot" then
			task.defer(InteractionController.Refresh)
		end
	end)

	RunService.Heartbeat:Connect(function(dt)
		accumulator += dt
		if accumulator >= InteractionController.SCAN_INTERVAL then
			accumulator = 0
			InteractionController.Refresh()
		end
	end)
end

return InteractionController
