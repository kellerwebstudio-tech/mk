--!nonstrict
-- CameraController: scriptable follow camera while driving (docs/VEHICLES.md "Camera").
-- Pivot behind/above the chassis using the per-vehicle handling offsets, exponential smoothing,
-- look-ahead toward heading + steer, orbit by mouse right-drag / touch drag / gamepad right stick,
-- auto-recenter, the RecenterCamera action, speed FOV and reduced-motion mode. Restores the
-- default Roblox camera (CameraType.Custom + humanoid subject) when not driving.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Util = Shared:WaitForChild("Util")
local MathUtil = require(Util:WaitForChild("MathUtil"))
local InputActions = require(Shared:WaitForChild("InputActions"))
local VehicleDefinitions = require(Shared:WaitForChild("Definitions"):WaitForChild("VehicleDefinitions"))

local CameraController = {}

CameraController.BASE_FOV = 70
CameraController.POSITION_DAMP = 8
CameraController.ORIENTATION_DAMP = 10
CameraController.REDUCED_MOTION_DAMP = 20
CameraController.RECENTER_IDLE = 2.5
CameraController.RECENTER_DAMP = 4
CameraController.SNAP_DAMP = 12
CameraController.MOUSE_YAW_RATE = 0.0035 -- radians per pixel at sensitivity 1
CameraController.MOUSE_PITCH_RATE = 0.0025
CameraController.TOUCH_YAW_RATE = 0.006
CameraController.TOUCH_PITCH_RATE = 0.004
CameraController.STICK_YAW_RATE = 2.6 -- radians per second at full deflection
CameraController.STICK_PITCH_RATE = 1.6
CameraController.PITCH_MIN = math.rad(-10)
CameraController.PITCH_MAX = math.rad(45)
CameraController.BIND_NAME = "DDC_FollowCamera"

local ctx = nil
local driving = false
local bound = false
local speedFraction = 0
local orbitYaw = 0
local orbitPitch = 0
local lastOrbitInput = -math.huge
local recentering = false
local stickInput = Vector2.zero
local rightMouseDown = false
local activeTouch = nil
local cameraPosition = nil
local cameraLook = nil
local settings = { cameraSensitivity = 1, reducedMotion = false, autoRecenter = true, invertCameraY = false }

local function controller(name: string)
	return ctx and ctx.controllers and ctx.controllers[name] or nil
end

local function camera(): Camera?
	return Workspace.CurrentCamera
end

function CameraController.ApplySettings(newSettings: any)
	if type(newSettings) ~= "table" then
		return
	end
	for key in pairs(settings) do
		if newSettings[key] ~= nil then
			settings[key] = newSettings[key]
		end
	end
	if settings.reducedMotion then
		local cam = camera()
		if cam and driving then
			cam.FieldOfView = CameraController.BASE_FOV
		end
	end
end

function CameraController.SetSpeedFraction(fraction: number)
	speedFraction = math.clamp(tonumber(fraction) or 0, 0, 1)
end

function CameraController.Recenter()
	recentering = true
end

function CameraController.GetOrbit(): (number, number)
	return orbitYaw, orbitPitch
end

-- Pure helper (also used by specs): camera offset from the pivot for a forward direction and orbit.
-- Positive pitch moves the camera up; positive yaw swings it around the pivot toward the vehicle's right side.
function CameraController.OrbitOffset(forwardFlat: Vector3, distance: number, yaw: number, pitch: number): Vector3
	local right = Vector3.new(-forwardFlat.Z, 0, forwardFlat.X)
	local behind = -forwardFlat * distance
	local rotation = CFrame.fromAxisAngle(Vector3.yAxis, yaw) * CFrame.fromAxisAngle(right, -pitch)
	return rotation:VectorToWorldSpace(behind)
end

function CameraController.IsDriving(): boolean
	return driving
end

-------------------------------------------------------------------------------
-- Orbit input
-------------------------------------------------------------------------------

local function applyOrbitDelta(dYaw: number, dPitch: number)
	local sensitivity = settings.cameraSensitivity or 1
	local invert = settings.invertCameraY and -1 or 1
	orbitYaw = math.clamp(orbitYaw + dYaw * sensitivity, -math.pi, math.pi)
	orbitPitch = math.clamp(orbitPitch + dPitch * sensitivity * invert, CameraController.PITCH_MIN, CameraController.PITCH_MAX)
	lastOrbitInput = os.clock()
	recentering = false
end

-- Public orbit nudge (radians): used by specs and by any UI control that wants to orbit.
function CameraController.ApplyOrbitDelta(dYaw: number, dPitch: number)
	applyOrbitDelta(tonumber(dYaw) or 0, tonumber(dPitch) or 0)
end

-- Touch drags that start on the thumbstick (bottom-left) or the button cluster (bottom-right) are ignored.
local function touchIsOrbitArea(position: Vector3): boolean
	local cam = camera()
	local viewport = cam and cam.ViewportSize or Vector2.new(1280, 720)
	local x, y = position.X, position.Y
	if y > viewport.Y * 0.5 then
		if x < viewport.X * 0.35 then
			return false
		end
		if x > viewport.X * 0.65 then
			return false
		end
	end
	return true
end

local function onInputBegan(input: InputObject, processed: boolean)
	if input.UserInputType == Enum.UserInputType.MouseButton2 then
		rightMouseDown = true
	elseif input.UserInputType == Enum.UserInputType.Touch and not processed and activeTouch == nil then
		if touchIsOrbitArea(input.Position) then
			activeTouch = input
		end
	end
end

local function onInputChanged(input: InputObject, processed: boolean)
	if not driving then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseMovement then
		if rightMouseDown then
			local delta = input.Delta
			-- Dragging down raises the camera (looks down), like the default Roblox camera.
			applyOrbitDelta(-delta.X * CameraController.MOUSE_YAW_RATE, delta.Y * CameraController.MOUSE_PITCH_RATE)
		end
	elseif input.UserInputType == Enum.UserInputType.Touch then
		if activeTouch == input then
			local delta = input.Delta
			applyOrbitDelta(-delta.X * CameraController.TOUCH_YAW_RATE, delta.Y * CameraController.TOUCH_PITCH_RATE)
		end
	elseif input.KeyCode == Enum.KeyCode.Thumbstick2 then
		local position = input.Position
		local vector = Vector2.new(position.X, position.Y)
		if vector.Magnitude < 0.15 then
			vector = Vector2.zero
		end
		stickInput = vector
	end
end

local function onInputEnded(input: InputObject)
	if input.UserInputType == Enum.UserInputType.MouseButton2 then
		rightMouseDown = false
	elseif input.UserInputType == Enum.UserInputType.Touch then
		if activeTouch == input then
			activeTouch = nil
		end
	elseif input.KeyCode == Enum.KeyCode.Thumbstick2 then
		stickInput = Vector2.zero
	end
end

-------------------------------------------------------------------------------
-- Per-frame update
-------------------------------------------------------------------------------

local function handlingFor(): any
	local vehicleController = controller("VehicleController")
	local handling = vehicleController and type(vehicleController.GetHandling) == "function" and vehicleController.GetHandling() or nil
	if handling then
		return handling
	end
	local vehicle = ctx.state.get("vehicle")
	local def = vehicle and vehicle.vehicleId and VehicleDefinitions.get(vehicle.vehicleId) or VehicleDefinitions.Vehicles.Bicycle
	return def.handling
end

local function chassisFor(): BasePart?
	local vehicleController = controller("VehicleController")
	local chassis = vehicleController and type(vehicleController.GetChassis) == "function" and vehicleController.GetChassis() or nil
	if chassis then
		return chassis
	end
	local vehicle = ctx.state.get("vehicle")
	if vehicle and typeof(vehicle.model) == "Instance" then
		local part = vehicle.model:FindFirstChild("Chassis")
		if part and part:IsA("BasePart") then
			return part
		end
	end
	return nil
end

local function steerFor(): number
	local vehicleController = controller("VehicleController")
	if vehicleController and type(vehicleController.GetSteer) == "function" then
		return vehicleController.GetSteer()
	end
	return 0
end

local function restoreDefaultCamera()
	local cam = camera()
	if not cam then
		return
	end
	pcall(function()
		cam.CameraType = Enum.CameraType.Custom
		cam.FieldOfView = CameraController.BASE_FOV
		local player = Players.LocalPlayer
		local character = player and player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			cam.CameraSubject = humanoid
		end
	end)
	cameraPosition = nil
	cameraLook = nil
end

local function updateCamera(dt: number)
	local cam = camera()
	local chassis = chassisFor()
	if not cam or not chassis then
		return
	end
	dt = math.clamp(dt, 1 / 240, 1 / 15)
	local handling = handlingFor()
	local reduced = settings.reducedMotion == true

	-- Gamepad orbit is rate based.
	if stickInput.Magnitude > 0 then
		-- Right stick up looks up (camera lowers), matching the default gamepad camera.
		applyOrbitDelta(-stickInput.X * CameraController.STICK_YAW_RATE * dt, -stickInput.Y * CameraController.STICK_PITCH_RATE * dt)
	end

	-- Auto recenter / recenter action.
	local idle = os.clock() - lastOrbitInput
	if recentering or (settings.autoRecenter ~= false and idle > CameraController.RECENTER_IDLE and not rightMouseDown and activeTouch == nil) then
		local dampSpeed = recentering and CameraController.SNAP_DAMP or CameraController.RECENTER_DAMP
		orbitYaw = MathUtil.damp(orbitYaw, 0, dampSpeed, dt)
		orbitPitch = MathUtil.damp(orbitPitch, 0, dampSpeed, dt)
		if math.abs(orbitYaw) < 0.005 and math.abs(orbitPitch) < 0.005 then
			orbitYaw, orbitPitch = 0, 0
			recentering = false
		end
	end

	local chassisCF = chassis.CFrame
	local position = chassisCF.Position
	local forwardFlat = MathUtil.flatten(chassisCF.LookVector)
	if forwardFlat.Magnitude < 1e-3 then
		forwardFlat = Vector3.new(0, 0, -1)
	else
		forwardFlat = forwardFlat.Unit
	end
	local right = Vector3.new(-forwardFlat.Z, 0, forwardFlat.X)

	-- Orbit rotates the follow offset around the pivot.
	local pivot = position + Vector3.new(0, handling.cameraHeight, 0)
	local offset = CameraController.OrbitOffset(forwardFlat, handling.cameraDistance, orbitYaw, orbitPitch)
	local desiredPosition = pivot + offset
	local lookTarget = position + forwardFlat * handling.cameraLookAhead + right * steerFor() * 4
	if orbitYaw ~= 0 or orbitPitch ~= 0 then
		lookTarget = pivot
	end

	local positionDamp = reduced and CameraController.REDUCED_MOTION_DAMP or CameraController.POSITION_DAMP
	local lookDamp = reduced and CameraController.REDUCED_MOTION_DAMP or CameraController.ORIENTATION_DAMP
	if cameraPosition == nil then
		cameraPosition = desiredPosition
		cameraLook = lookTarget
	else
		cameraPosition = MathUtil.dampVector(cameraPosition, desiredPosition, positionDamp, dt)
		cameraLook = MathUtil.dampVector(cameraLook, lookTarget, lookDamp, dt)
	end

	local fov = CameraController.BASE_FOV
	if not reduced then
		fov += handling.fovSpeedBoost * speedFraction * speedFraction
	end
	cam.CameraType = Enum.CameraType.Scriptable
	cam.CFrame = CFrame.lookAt(cameraPosition, cameraLook)
	cam.FieldOfView = fov
end

local function setDriving(enabled: boolean)
	if enabled == driving then
		return
	end
	driving = enabled
	if enabled then
		orbitYaw, orbitPitch = 0, 0
		recentering = false
		cameraPosition = nil
		cameraLook = nil
		local cam = camera()
		if cam then
			pcall(function()
				cam.CameraType = Enum.CameraType.Scriptable
			end)
		end
	else
		restoreDefaultCamera()
	end
end

local function renderStep(dt: number)
	local vehicle = ctx.state.get("vehicle")
	local shouldDrive = vehicle ~= nil and vehicle.state == "Driving"
	if shouldDrive then
		local vehicleController = controller("VehicleController")
		if vehicleController and type(vehicleController.IsActive) == "function" then
			-- Only take over once the controller actually drives (seated and resolved).
			shouldDrive = vehicleController.IsActive() or chassisFor() ~= nil
		end
	end
	setDriving(shouldDrive)
	if driving then
		local ok, err = pcall(updateCamera, dt)
		if not ok then
			warn("[CameraController] update failed: " .. tostring(err))
		end
	end
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

function CameraController.Init(context)
	ctx = context
end

function CameraController.Start()
	ctx.state.onChange("settings", function(newSettings)
		CameraController.ApplySettings(newSettings)
	end)

	UserInputService.InputBegan:Connect(onInputBegan)
	UserInputService.InputChanged:Connect(onInputChanged)
	UserInputService.InputEnded:Connect(onInputEnded)

	local input = controller("InputController")
	if input and input.Pressed then
		input.Pressed:Connect(function(actionName)
			if actionName == InputActions.Names.RecenterCamera then
				CameraController.Recenter()
			end
		end)
	end

	local okBind = pcall(function()
		RunService:BindToRenderStep(CameraController.BIND_NAME, Enum.RenderPriority.Camera.Value + 1, renderStep)
	end)
	bound = okBind
	if not okBind then
		RunService.RenderStepped:Connect(renderStep)
	end
end

return CameraController
