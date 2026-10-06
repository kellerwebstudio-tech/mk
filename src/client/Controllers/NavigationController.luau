--!nonstrict
-- NavigationController: picks the current stop (ClientState.getOrderedStops honouring stopOrder,
-- cycled with the NextStop action), finds a route on the shared RouteGraph with the current
-- vehicle mask, draws pooled neon markers along the next 240 studs, a destination billboard,
-- feeds turn instructions to UIController.SetNavigation and the minimap at 10 Hz.
-- It never raycasts.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Util = Shared:WaitForChild("Util")
local City = Shared:WaitForChild("City")
local MathUtil = require(Util:WaitForChild("MathUtil"))
local RouteGraph = require(City:WaitForChild("RouteGraph"))
local InputActions = require(Shared:WaitForChild("InputActions"))
local VehicleDefinitions = require(Shared:WaitForChild("Definitions"):WaitForChild("VehicleDefinitions"))

local NavigationController = {}

NavigationController.UPDATE_INTERVAL = 0.1 -- 10 Hz
NavigationController.RECOMPUTE_INTERVAL = 4
NavigationController.OFF_ROUTE_DISTANCE = 24
NavigationController.MARKER_POOL = 40
NavigationController.MARKER_SPACING = 10
NavigationController.MARKER_RANGE = 240
NavigationController.MARKER_SIZE = 1.5
NavigationController.ARRIVE_DISTANCE = 14
NavigationController.PICKUP_COLOR = Color3.fromRGB(255, 150, 40)
NavigationController.DELIVER_COLOR = Color3.fromRGB(70, 220, 120)

local ctx = nil
local fxFolder: Instance? = nil
local markerFolder: Instance? = nil
local markers: { BasePart } = {}
local billboardPart: BasePart? = nil
local billboardLabel: TextLabel? = nil
local billboardIcon: Frame? = nil
local path: { Vector3 }? = nil
local pathLength = 0
local pathMask = 0
local turns = {}
local lastCompute = -math.huge
local targetKey: string? = nil
local targetIndex = 1
local stopsKey = ""
local accumulator = 0
local currentTarget = nil
local currentStops = {}
local navActive = false

local function controller(name: string)
	return ctx and ctx.controllers and ctx.controllers[name] or nil
end

local function callUI(method: string, ...)
	local ui = controller("UIController")
	if ui and type(ui[method]) == "function" then
		local ok, err = pcall(ui[method], ...)
		if not ok then
			warn("[NavigationController] UIController." .. method .. " failed: " .. tostring(err))
		end
	end
end

-------------------------------------------------------------------------------
-- Client FX instances
-------------------------------------------------------------------------------

local function getOrCreateFolder(parent: Instance, name: string): Instance
	local existing = parent:FindFirstChild(name)
	if existing then
		return existing
	end
	local created = Instance.new("Folder")
	created.Name = name
	created.Parent = parent
	return created
end

local function ensureFolders()
	local camera = Workspace.CurrentCamera
	if not camera then
		return false
	end
	if not fxFolder or fxFolder.Parent ~= camera then
		fxFolder = getOrCreateFolder(camera, "ClientFX")
	end
	local fx = fxFolder :: Instance
	if not markerFolder or markerFolder.Parent ~= fx then
		markerFolder = getOrCreateFolder(fx, "RouteMarkers")
	end
	return true
end

local function makeMarker(index: number): BasePart
	local part = Instance.new("Part")
	part.Name = "Marker" .. index
	part.Size = Vector3.new(NavigationController.MARKER_SIZE, NavigationController.MARKER_SIZE, NavigationController.MARKER_SIZE)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Transparency = 1
	part.Shape = Enum.PartType.Ball
	part.Color = NavigationController.PICKUP_COLOR
	part.Parent = markerFolder
	return part
end

local function ensureMarkers()
	if not ensureFolders() then
		return
	end
	for index = 1, NavigationController.MARKER_POOL do
		local marker = markers[index]
		if not marker or marker.Parent ~= markerFolder then
			markers[index] = makeMarker(index)
		end
	end
end

local function ensureBillboard()
	if not ensureFolders() then
		return
	end
	if billboardPart and billboardPart.Parent == fxFolder then
		return
	end
	local part = Instance.new("Part")
	part.Name = "DestinationBillboard"
	part.Size = Vector3.new(1, 1, 1)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.CastShadow = false

	local gui = Instance.new("BillboardGui")
	gui.Name = "Gui"
	gui.AlwaysOnTop = true
	gui.MaxDistance = 5000
	gui.Size = UDim2.fromOffset(190, 56)
	gui.StudsOffset = Vector3.new(0, 2, 0)
	gui.LightInfluence = 0
	gui.Enabled = false
	gui.Parent = part

	local frame = Instance.new("Frame")
	frame.Name = "Panel"
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
	frame.BackgroundTransparency = 0.25
	frame.BorderSizePixel = 0
	frame.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = frame

	local icon = Instance.new("Frame")
	icon.Name = "Icon"
	icon.Size = UDim2.fromOffset(18, 18)
	icon.Position = UDim2.new(0, 12, 0.5, -9)
	icon.BackgroundColor3 = NavigationController.PICKUP_COLOR
	icon.BorderSizePixel = 0
	icon.Parent = frame
	local iconCorner = Instance.new("UICorner")
	iconCorner.Name = "Round"
	iconCorner.CornerRadius = UDim.new(1, 0)
	iconCorner.Parent = icon

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.Size = UDim2.new(1, -44, 1, 0)
	label.Position = UDim2.new(0, 38, 0, 0)
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextStrokeTransparency = 0.5
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.Text = ""
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = frame

	part.Parent = fxFolder
	billboardPart = part
	billboardLabel = label
	billboardIcon = icon
end

local function hideMarkers(fromIndex: number)
	for index = fromIndex, #markers do
		local marker = markers[index]
		if marker then
			marker.Transparency = 1
		end
	end
end

local function hideBillboard()
	if billboardPart then
		local gui = billboardPart:FindFirstChild("Gui")
		if gui then
			gui.Enabled = false
		end
	end
end

-------------------------------------------------------------------------------
-- Target selection
-------------------------------------------------------------------------------

local function stopKey(stop: any): string
	return tostring(stop.order.id) .. ":" .. tostring(stop.kind)
end

local function currentMask(): number
	local vehicle = ctx.state.get("vehicle")
	if vehicle and vehicle.state == "Driving" and vehicle.vehicleId then
		return VehicleDefinitions.maskForVehicle(vehicle.vehicleId)
	end
	return VehicleDefinitions.Mask.Foot
end

local function playerPosition(): Vector3?
	return ctx.state.getPlayerPosition()
end

local function playerHeading(): number
	local vehicle = ctx.state.get("vehicle")
	if vehicle and vehicle.state == "Driving" then
		local vehicleController = controller("VehicleController")
		local chassis = vehicleController and type(vehicleController.GetChassis) == "function" and vehicleController.GetChassis() or nil
		if chassis then
			return MathUtil.headingFromDirection(chassis.CFrame.LookVector)
		end
	end
	local player = Players.LocalPlayer
	local character = player and player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root then
		return MathUtil.headingFromDirection(root.CFrame.LookVector)
	end
	local camera = Workspace.CurrentCamera
	if camera then
		return MathUtil.headingFromDirection(MathUtil.flatten(camera.CFrame.LookVector))
	end
	return 0
end

-- Chooses the stop at targetIndex among the ordered stops; resets the index when the stop set changes.
local function selectTarget(position: Vector3?)
	local stops = ctx.state.getOrderedStops(position)
	currentStops = stops
	local keys = {}
	for _, stop in ipairs(stops) do
		table.insert(keys, stopKey(stop))
	end
	local key = table.concat(keys, "|")
	if key ~= stopsKey then
		stopsKey = key
		-- Keep the selected stop if it still exists, else go back to the first.
		local found = nil
		for index, stop in ipairs(stops) do
			if stopKey(stop) == targetKey then
				found = index
				break
			end
		end
		targetIndex = found or 1
	end
	if #stops == 0 then
		currentTarget = nil
		targetKey = nil
		return nil
	end
	if targetIndex > #stops then
		targetIndex = 1
	end
	currentTarget = stops[targetIndex]
	targetKey = stopKey(currentTarget)
	return currentTarget
end

function NavigationController.NextStop()
	if #currentStops == 0 then
		return
	end
	targetIndex = targetIndex % #currentStops + 1
	currentTarget = currentStops[targetIndex]
	targetKey = stopKey(currentTarget)
	path = nil
	lastCompute = -math.huge
end

function NavigationController.GetCurrentTarget()
	return currentTarget
end

function NavigationController.GetPath(): { Vector3 }?
	return path
end

function NavigationController.GetStops()
	return currentStops
end

-------------------------------------------------------------------------------
-- Route computation
-------------------------------------------------------------------------------

local function computePath(from: Vector3, to: Vector3, mask: number)
	local graph = ctx.graph
	local found: { Vector3 }? = nil
	local length = math.huge
	if graph then
		local okPath, p, len = pcall(function()
			return RouteGraph.findPath(graph, from, to, mask)
		end)
		if okPath and p and #p >= 1 then
			found = p
			length = len
		end
	end
	local result: { Vector3 }
	if not found then
		result = { from, to }
		length = (to - from).Magnitude
	else
		result = found
		-- Walk from the player to the road, then from the road to the door.
		if (result[1] - from).Magnitude > 1 then
			table.insert(result, 1, from)
		end
		if (result[#result] - to).Magnitude > 1 then
			table.insert(result, to)
		end
		length = RouteGraph.distanceAlongPath(result)
	end
	path = result
	pathLength = length
	pathMask = mask
	turns = RouteGraph.turnInstructions(result)
	lastCompute = os.clock()
end

-- Distance of the player along the path (projection on the nearest segment).
local function progressAlong(position: Vector3): (number, number, number)
	if not path or #path < 2 then
		return 0, 1, math.huge
	end
	local offRoute, segmentIndex = RouteGraph.distanceToPolyline(path, position)
	local distance = 0
	for index = 2, segmentIndex do
		distance += (path[index] - path[index - 1]).Magnitude
	end
	local a, b = path[segmentIndex], path[segmentIndex + 1]
	local ab = b - a
	local len2 = ab:Dot(ab)
	local t = 0
	if len2 > 1e-6 then
		t = math.clamp((position - a):Dot(ab) / len2, 0, 1)
	end
	distance += t * ab.Magnitude
	return distance, segmentIndex, offRoute
end

-- Point on the path at the given distance from its start.
local function pointAlong(distance: number): Vector3
	local points = path :: { Vector3 }
	local remaining = distance
	for index = 2, #points do
		local a, b = points[index - 1], points[index]
		local segment = (b - a).Magnitude
		if remaining <= segment or index == #points then
			if segment < 1e-6 then
				return b
			end
			return a + (b - a) * math.clamp(remaining / segment, 0, 1)
		end
		remaining -= segment
	end
	return points[#points]
end

local function placeMarkers(progress: number, kind: string)
	ensureMarkers()
	if not path or #path < 2 then
		hideMarkers(1)
		return
	end
	local color = kind == "deliver" and NavigationController.DELIVER_COLOR or NavigationController.PICKUP_COLOR
	local shape = kind == "deliver" and Enum.PartType.Block or Enum.PartType.Ball
	local count = 0
	local distance = progress + NavigationController.MARKER_SPACING
	local limit = math.min(pathLength, progress + NavigationController.MARKER_RANGE)
	while distance <= limit and count < NavigationController.MARKER_POOL do
		count += 1
		local marker = markers[count]
		local point = pointAlong(distance)
		marker.Shape = shape
		marker.Color = color
		marker.CFrame = CFrame.new(point + Vector3.new(0, 1.5, 0))
		marker.Transparency = 0.15
		distance += NavigationController.MARKER_SPACING
	end
	hideMarkers(count + 1)
end

local function updateBillboard(target, distance: number)
	ensureBillboard()
	if not billboardPart then
		return
	end
	billboardPart.CFrame = CFrame.new(target.position + Vector3.new(0, 7, 0))
	local gui = billboardPart:FindFirstChild("Gui")
	if gui then
		gui.Enabled = true
	end
	if billboardLabel then
		billboardLabel.Text = string.format("%s  %s", target.kind == "deliver" and "DELIVER" or "PICKUP", MathUtil.formatDistance(distance))
	end
	if billboardIcon then
		local round = billboardIcon:FindFirstChild("Round")
		if target.kind == "deliver" then
			billboardIcon.BackgroundColor3 = NavigationController.DELIVER_COLOR
			if round then
				round.CornerRadius = UDim.new(0, 3)
			end
		else
			billboardIcon.BackgroundColor3 = NavigationController.PICKUP_COLOR
			if round then
				round.CornerRadius = UDim.new(1, 0)
			end
		end
	end
end

local function nextTurn(progress: number): (string?, number?)
	for _, turn in ipairs(turns) do
		if turn.distanceFromStart > progress - 2 then
			return turn.kind, math.max(0, turn.distanceFromStart - progress)
		end
	end
	return nil, nil
end

local function timeLeftFor(order: any): number?
	if type(order) ~= "table" or type(order.timeLimit) ~= "number" or type(order.acceptedAt) ~= "number" then
		return nil
	end
	return order.acceptedAt + order.timeLimit - ctx.state.serverNow()
end

local function clearNavigation()
	path = nil
	turns = {}
	hideMarkers(1)
	hideBillboard()
	if navActive then
		navActive = false
		callUI("SetNavigation", { active = false })
	end
	local position = playerPosition()
	callUI("SetMinimap", {
		playerPosition = position or Vector3.zero,
		heading = playerHeading(),
		stops = {},
		path = nil,
	})
end

local function update()
	local position = playerPosition()
	local target = selectTarget(position)
	if not target or not position then
		clearNavigation()
		return
	end

	local mask = currentMask()
	local needCompute = path == nil or mask ~= pathMask or os.clock() - lastCompute >= NavigationController.RECOMPUTE_INTERVAL
	local progress, _, offRoute = 0, 1, 0
	if path then
		progress, _, offRoute = progressAlong(position)
		if offRoute > NavigationController.OFF_ROUTE_DISTANCE then
			needCompute = true
		end
		if (path[#path] - target.position).Magnitude > 1 then
			needCompute = true
		end
	end
	if needCompute then
		computePath(position, target.position, mask)
		progress = progressAlong(position)
	end

	local remaining = math.max(0, pathLength - progress)
	local straight = MathUtil.horizontalDistance(position, target.position)
	local distance = math.max(remaining, straight)
	placeMarkers(progress, target.kind)
	updateBillboard(target, distance)

	local turnKind, turnDistance = nextTurn(progress)
	if straight <= NavigationController.ARRIVE_DISTANCE * 2 or turnKind == nil then
		turnKind = "Arrive"
		turnDistance = distance
	end
	navActive = true
	callUI("SetNavigation", {
		active = true,
		label = target.label,
		stopKind = target.kind,
		distance = distance,
		turnKind = turnKind,
		turnDistance = turnDistance,
		timeLeft = timeLeftFor(target.order),
		address = target.address,
	})

	local stops = {}
	for _, stop in ipairs(currentStops) do
		table.insert(stops, { position = stop.position, kind = stop.kind, current = stop == target })
	end
	callUI("SetMinimap", {
		playerPosition = position,
		heading = playerHeading(),
		stops = stops,
		path = path,
	})
end

-- Runs one navigation update immediately (used by tests and by state changes).
function NavigationController.Refresh()
	local ok, err = pcall(update)
	if not ok then
		warn("[NavigationController] update failed: " .. tostring(err))
	end
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

function NavigationController.Init(context)
	ctx = context
end

function NavigationController.Start()
	local input = controller("InputController")
	if input and input.Pressed then
		input.Pressed:Connect(function(actionName)
			if actionName == InputActions.Names.NextStop then
				NavigationController.NextStop()
				NavigationController.Refresh()
			end
		end)
	end

	-- Orders changing (accept/cancel/collect) or the stop order being edited triggers a recompute.
	ctx.state.Changed:Connect(function(key)
		if key == "orders" or key == "stopOrder" then
			path = nil
			lastCompute = -math.huge
		end
	end)

	RunService.Heartbeat:Connect(function(dt)
		accumulator += dt
		if accumulator >= NavigationController.UPDATE_INTERVAL then
			accumulator = 0
			NavigationController.Refresh()
		end
	end)
end

return NavigationController
