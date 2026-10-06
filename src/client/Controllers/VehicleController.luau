--!nonstrict
-- VehicleController: owner-side arcade "ground-follow" driving model (docs/VEHICLES.md).
-- Runs on Heartbeat while ClientState.vehicle.state == "Driving" and the local humanoid sits in the
-- vehicle's Seat. The per-frame maths lives in the pure function VehicleController._stepModel so it
-- can be unit-tested without Instances; the loop probes the ground with three raycasts, feeds the
-- model and applies the result to the LinearVelocity / AlignOrientation constraints.
-- Also: cosmetic wheel spin + body lean for the owner, cosmetic wheel spin for nearby vehicles of
-- other players (no remotes), safety recovery requests and the speed/engine/HUD feeds.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Util = Shared:WaitForChild("Util")
local Definitions = Shared:WaitForChild("Definitions")
local City = Shared:WaitForChild("City")
local MathUtil = require(Util:WaitForChild("MathUtil"))
local VehicleDefinitions = require(Definitions:WaitForChild("VehicleDefinitions"))
local UpgradeDefinitions = require(Definitions:WaitForChild("UpgradeDefinitions"))
local RouteGraph = require(City:WaitForChild("RouteGraph"))
local InputActions = require(Shared:WaitForChild("InputActions"))

local VehicleController = {}

VehicleController.MIN_DT = 1 / 240
VehicleController.MAX_DT = 1 / 20
VehicleController.MAX_FORCE_PER_MASS = 1200
VehicleController.RECOVER_INTERVAL = 3 -- seconds between RecoverVehicle requests
VehicleController.BELOW_ROAD_LIMIT = 60 -- studs below the nearest road point before recovery
VehicleController.BELOW_ROAD_TIME = 2
VehicleController.FLIPPED_TIME = 1.5
VehicleController.COSMETIC_INTERVAL = 0.05
VehicleController.COSMETIC_RANGE = 200
VehicleController.DEFAULT_GRAVITY = 196.2

export type StepState = {
	heading: number,
	speed: number,
	steer: number,
	vy: number,
	blockedTimer: number,
	posY: number,
	actualForwardSpeed: number,
	-- outputs (filled by _stepModel)
	velocity: Vector3?,
	forwardOnGround: Vector3?,
	driveGrounded: boolean?,
	bumped: boolean?,
	maxSpeedEffective: number?,
}

export type StepInput = { throttle: number, steer: number, brake: boolean }
export type StepProbe = { grounded: boolean, groundY: number, normal: Vector3, hasHit: boolean, slopeOk: boolean }

-------------------------------------------------------------------------------
-- Pure per-frame model
-------------------------------------------------------------------------------

-- state: {heading, speed, steer, vy, blockedTimer, posY, actualForwardSpeed}
-- input: {throttle, steer, brake}; probe: {grounded, groundY, normal, hasHit, slopeOk}
-- handling: VehicleDefinitions handling table (+ optional speedMultiplier, gravity).
-- Mutates and returns state. posY is integrated with vy for offline tests; the Heartbeat loop
-- overwrites it with the real chassis height every frame.
function VehicleController._stepModel(state: StepState, input: StepInput, probe: StepProbe, handling: any, dt: number): StepState
	dt = math.clamp(dt, VehicleController.MIN_DT, VehicleController.MAX_DT)
	local gravity = handling.gravity or VehicleController.DEFAULT_GRAVITY
	local speedMultiplier = handling.speedMultiplier or 1
	local maxSpeedEffective = handling.maxSpeed * speedMultiplier
	state.maxSpeedEffective = maxSpeedEffective

	local normal = probe.normal
	if typeof(normal) ~= "Vector3" or normal.Magnitude < 1e-3 then
		normal = Vector3.yAxis
	else
		normal = normal.Unit
	end

	local throttle = math.clamp(tonumber(input.throttle) or 0, -1, 1)
	local steerInput = math.clamp(tonumber(input.steer) or 0, -1, 1)
	local brake = input.brake == true

	local driveGrounded = probe.grounded == true and probe.slopeOk ~= false
	state.driveGrounded = driveGrounded

	local forwardFlat = MathUtil.directionFromHeading(state.heading)

	-- 1. Too steep: slide along the slope under emulated gravity (no drive, no steering).
	if probe.grounded == true and probe.slopeOk == false then
		local cosSlope = math.clamp(normal.Y, -1, 1)
		local sinSlope = math.sqrt(math.max(0, 1 - cosSlope * cosSlope))
		-- Downhill direction = gravity minus its component along the normal, flattened.
		local downhill = Vector3.new(-normal.X, 0, -normal.Z)
		if downhill.Magnitude > 1e-4 then
			downhill = downhill.Unit
			state.speed += gravity * sinSlope * dt * forwardFlat:Dot(downhill)
		end
	end

	-- 2. Speed.
	if driveGrounded then
		local speed = state.speed
		if brake then
			speed = MathUtil.moveToward(speed, 0, handling.brakeDeceleration * dt)
		elseif throttle > 0 then
			if speed < 0 then
				speed = MathUtil.moveToward(speed, 0, handling.brakeDeceleration * dt)
			else
				speed = math.min(speed + handling.acceleration * throttle * dt, maxSpeedEffective)
			end
		elseif throttle < 0 then
			if speed > 1 then
				speed = MathUtil.moveToward(speed, 0, handling.brakeDeceleration * dt)
			else
				speed = math.max(speed + throttle * handling.acceleration * 0.6 * dt, -handling.reverseSpeed)
			end
		else
			speed = MathUtil.moveToward(speed, 0, handling.coastDeceleration * dt)
		end
		state.speed = speed
	end

	-- 3. Steering (smoothed always; the heading only changes on the ground while moving).
	state.steer = MathUtil.damp(state.steer, steerInput, handling.steerResponse, dt)
	local absSpeed = math.abs(state.speed)
	if driveGrounded and absSpeed >= 0.5 then
		local f = math.clamp(absSpeed / handling.turnFullSpeed, handling.minTurnFactor, 1)
		local span = math.max(handling.maxSpeed - handling.turnFullSpeed, 1e-3)
		local highSpeedT = math.clamp((absSpeed - handling.turnFullSpeed) / span, 0, 1)
		f *= MathUtil.lerp(1, handling.highSpeedTurnFactor, highSpeedT)
		state.heading -= state.steer * handling.turnRate * f * dt * MathUtil.sign(state.speed)
		state.heading = MathUtil.wrapAngle(state.heading)
		forwardFlat = MathUtil.directionFromHeading(state.heading)
	end

	-- 4. Forward direction on the ground plane.
	local forwardOnGround = forwardFlat - normal * forwardFlat:Dot(normal)
	if forwardOnGround.Magnitude < 1e-4 then
		forwardOnGround = forwardFlat
	else
		forwardOnGround = forwardOnGround.Unit
	end
	state.forwardOnGround = forwardOnGround

	-- 6. Blocked detection (applied before the velocity so the slowdown is immediate).
	state.bumped = false
	local actual = math.abs(tonumber(state.actualForwardSpeed) or 0)
	if absSpeed > 6 and actual < absSpeed * handling.blockedSpeedFraction then
		state.blockedTimer += dt
		if state.blockedTimer > handling.blockedTime then
			state.speed *= handling.bumpSlowdown
			state.bumped = true
			state.blockedTimer = 0
		end
	else
		state.blockedTimer = 0
	end

	-- 5. Velocity: ride-height controller when a ground hit exists, emulated gravity otherwise.
	if probe.hasHit then
		local targetY = probe.groundY + handling.rideHeight
		state.vy = math.clamp((targetY - state.posY) * handling.verticalGain, -handling.maxClimbRate, handling.maxClimbRate)
	else
		state.vy = math.max(state.vy - gravity * dt, -handling.maxFallSpeed)
	end
	state.velocity = forwardOnGround * state.speed + Vector3.new(0, state.vy, 0)
	state.posY += state.vy * dt
	return state
end

-------------------------------------------------------------------------------
-- Runtime
-------------------------------------------------------------------------------

local ctx = nil
local refs = nil -- resolved vehicle instances (see resolveVehicle)
local active = false
local state: StepState = nil
local maxForceTimer = 0
local roadCheckTimer = 0
local belowRoadTimer = 0
local flippedTimer = 0
local lastRecoverAt = -math.huge
local cosmeticTimer = 0
local otherSpin = setmetatable({}, { __mode = "k" }) -- wheel part -> accumulated spin
local speedFraction = 0
local raycastParams = nil
local resolving = false

local function newState(): StepState
	return { heading = 0, speed = 0, steer = 0, vy = 0, blockedTimer = 0, posY = 0, actualForwardSpeed = 0 }
end

local function controller(name: string)
	return ctx and ctx.controllers and ctx.controllers[name] or nil
end

local function callController(name: string, method: string, ...)
	local target = controller(name)
	if target and type(target[method]) == "function" then
		local ok, err = pcall(target[method], ...)
		if not ok then
			warn("[VehicleController] " .. name .. "." .. method .. " failed: " .. tostring(err))
		end
	end
end

local function localPlayerId(): number
	local player = Players.LocalPlayer
	return player and player.UserId or 0
end

local function localHumanoid(): Humanoid?
	local player = Players.LocalPlayer
	local character = player and player.Character
	return character and character:FindFirstChildOfClass("Humanoid") or nil
end

local function runtimeVehiclesFolder(): Instance?
	local runtime = Workspace:FindFirstChild("Runtime")
	return runtime and runtime:FindFirstChild("Vehicles") or nil
end

local function findOwnModel(): Model?
	local vehicle = ctx.state.get("vehicle")
	if vehicle and typeof(vehicle.model) == "Instance" and vehicle.model:IsA("Model") and vehicle.model.Parent then
		return vehicle.model :: Model
	end
	local folder = runtimeVehiclesFolder()
	if not folder then
		return nil
	end
	local userId = localPlayerId()
	for _, model in ipairs(folder:GetChildren()) do
		if model:IsA("Model") and model:GetAttribute("OwnerUserId") == userId then
			return model
		end
	end
	return nil
end

-- Speed multiplier from the profile's upgrades (mirrors ProgressionService.GetSpeedMultiplier).
function VehicleController.GetSpeedMultiplier(vehicleId: string): number
	local profile = ctx and ctx.state.get("profile")
	local multiplier = 1
	if profile and type(profile.upgrades) == "table" then
		for upgradeId, level in pairs(profile.upgrades) do
			if type(level) == "number" and level > 0 then
				local upgrade = UpgradeDefinitions.get(upgradeId)
				local bonus = upgrade and upgrade.effect.speedBonus
				if bonus and bonus.vehicle == vehicleId then
					multiplier += bonus.amount * level
				end
			end
		end
	end
	return multiplier
end

-- Resolves every instance the loop needs; yields (WaitForChild with timeouts) so call from a task.
local function resolveVehicle()
	if resolving then
		return
	end
	resolving = true
	local okResolve, err = pcall(function()
		local model = findOwnModel()
		if not model then
			refs = nil
			return
		end
		local vehicleId = model:GetAttribute("VehicleId")
		local vehicle = ctx.state.get("vehicle")
		if type(vehicleId) ~= "string" then
			vehicleId = vehicle and vehicle.vehicleId or "Bicycle"
		end
		local def = VehicleDefinitions.get(vehicleId) or VehicleDefinitions.Vehicles.Bicycle
		local chassis = model:WaitForChild("Chassis", 10)
		local seat = model:WaitForChild("Seat", 10)
		local bodyRoot = model:WaitForChild("BodyRoot", 10)
		if not chassis or not seat or not bodyRoot then
			refs = nil
			return
		end
		local align = chassis:WaitForChild("Align", 5)
		local velocity = chassis:WaitForChild("Velocity", 5)
		local wheelsFolder = model:WaitForChild("Wheels", 5)
		local wheels = {}
		if wheelsFolder then
			for _, wheel in ipairs(wheelsFolder:GetChildren()) do
				if wheel:IsA("BasePart") then
					local motor = wheel:FindFirstChild("WheelMotor")
					table.insert(wheels, {
						part = wheel,
						motor = motor,
						radius = tonumber(wheel:GetAttribute("Radius")) or 1,
						steerable = wheel:GetAttribute("Steerable") == true,
						spin = 0,
					})
				end
			end
		end
		refs = {
			model = model,
			chassis = chassis,
			seat = seat,
			bodyRoot = bodyRoot,
			bodyMotor = bodyRoot:FindFirstChild("BodyMotor"),
			align = align,
			velocity = velocity,
			wheels = wheels,
			vehicleId = vehicleId,
			def = def,
			handling = def.handling,
			chassisLength = def.chassisSize[3],
		}
	end)
	resolving = false
	if not okResolve then
		warn("[VehicleController] resolve failed: " .. tostring(err))
		refs = nil
	end
end

local function buildRaycastParams(): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = false
	local filter = {}
	local folder = runtimeVehiclesFolder()
	if folder then
		table.insert(filter, folder)
	end
	local runtime = Workspace:FindFirstChild("Runtime")
	local packages = runtime and runtime:FindFirstChild("Packages")
	if packages then
		table.insert(filter, packages)
	end
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character then
			table.insert(filter, player.Character)
		end
	end
	local camera = Workspace.CurrentCamera
	local fx = camera and camera:FindFirstChild("ClientFX")
	if fx then
		table.insert(filter, fx)
	end
	params.FilterDescendantsInstances = filter
	return params
end

-- Three downward raycasts -> probe table for _stepModel.
local function probeGround(chassis: BasePart, forward: Vector3, handling: any, length: number): StepProbe
	local origin = chassis.Position
	local rayLength = handling.rideHeight + handling.probeExtra + 2
	local offsets = { forward * (length / 2 * 0.8), Vector3.zero, -forward * (length / 2 * 0.8) }
	local hits = {}
	local centreHit = nil
	for index, offset in ipairs(offsets) do
		local from = origin + offset + Vector3.new(0, 2, 0)
		local okCast, result = pcall(function()
			return Workspace:Raycast(from, Vector3.new(0, -rayLength, 0), raycastParams)
		end)
		if okCast and result then
			table.insert(hits, result)
			if index == 2 then
				centreHit = result
			end
		end
	end
	local probe: StepProbe = { grounded = false, groundY = origin.Y - handling.rideHeight, normal = Vector3.yAxis, hasHit = false, slopeOk = true }
	if #hits == 0 then
		return probe
	end
	local gy = -math.huge
	local normalSum = Vector3.zero
	local nearest = math.huge
	for _, hit in ipairs(hits) do
		gy = math.max(gy, hit.Position.Y)
		normalSum += hit.Normal
		nearest = math.min(nearest, origin.Y - hit.Position.Y)
	end
	local normal = Vector3.yAxis
	if normalSum.Magnitude > 1e-4 then
		normal = normalSum.Unit
	end
	probe.groundY = gy
	probe.normal = normal
	probe.hasHit = nearest <= handling.rideHeight + handling.probeExtra
	if centreHit then
		probe.grounded = (origin.Y - centreHit.Position.Y) <= handling.rideHeight + 1.25
	end
	local slope = math.deg(math.acos(math.clamp(normal.Y, -1, 1)))
	probe.slopeOk = slope <= handling.maxSlopeDegrees
	return probe
end

local function isSeatedInVehicle(): boolean
	if not refs then
		return false
	end
	local humanoid = localHumanoid()
	return humanoid ~= nil and humanoid.SeatPart == refs.seat
end

local function shouldRun(): boolean
	local vehicle = ctx.state.get("vehicle")
	if not vehicle or vehicle.state ~= "Driving" then
		return false
	end
	if not refs or not refs.model.Parent then
		return false
	end
	return isSeatedInVehicle()
end

local function capacityText(): string
	local orders = ctx.state.get("orders")
	local capacity = orders and orders.capacity
	if capacity and type(capacity.load) == "number" and type(capacity.current) == "number" then
		return string.format("%d/%d", capacity.load, capacity.current)
	end
	return ""
end

local function sendHud()
	local vehicle = ctx.state.get("vehicle")
	callController("UIController", "SetVehicleHud", {
		state = vehicle and vehicle.state or nil,
		vehicleId = refs and refs.vehicleId or (vehicle and vehicle.vehicleId) or nil,
		speedFraction = speedFraction,
		loadText = capacityText(),
	})
end

local function activate()
	active = true
	state = newState()
	local chassis = refs.chassis
	state.heading = MathUtil.headingFromDirection(chassis.CFrame.LookVector)
	state.posY = chassis.Position.Y
	raycastParams = buildRaycastParams()
	maxForceTimer = 0
	roadCheckTimer = 0
	belowRoadTimer = 0
	flippedTimer = 0
	pcall(function()
		refs.velocity.MaxForce = chassis.AssemblyMass * VehicleController.MAX_FORCE_PER_MASS
		refs.velocity.VectorVelocity = Vector3.zero
	end)
end

local function deactivate()
	active = false
	speedFraction = 0
	if refs then
		pcall(function()
			refs.velocity.VectorVelocity = Vector3.zero
		end)
		for _, wheel in ipairs(refs.wheels) do
			if wheel.motor then
				pcall(function()
					wheel.motor.Transform = CFrame.Angles(wheel.spin, 0, 0)
				end)
			end
		end
		if refs.bodyMotor then
			pcall(function()
				refs.bodyMotor.Transform = CFrame.identity
			end)
		end
	end
	callController("AudioController", "SetEngine", 0, false, true)
	callController("AudioController", "StopEngine")
	callController("CameraController", "SetSpeedFraction", 0)
	sendHud()
end

local function requestRecover(reason: string)
	local now = os.clock()
	if now - lastRecoverAt < VehicleController.RECOVER_INTERVAL then
		return
	end
	lastRecoverAt = now
	task.spawn(function()
		local ok, result = pcall(function()
			return ctx.remotes.getFunction("RecoverVehicle"):InvokeServer()
		end)
		if not ok then
			warn("[VehicleController] RecoverVehicle failed (" .. reason .. "): " .. tostring(result))
		end
	end)
end

local function applyCosmetics(dt: number, reducedMotion: boolean)
	local handling = refs.handling
	for _, wheel in ipairs(refs.wheels) do
		if wheel.motor then
			wheel.spin -= state.speed * dt / math.max(wheel.radius, 0.1)
			wheel.spin = wheel.spin % (2 * math.pi)
			local transform
			if wheel.steerable then
				transform = CFrame.Angles(0, -state.steer * math.rad(handling.wheelSteerAngle), 0) * CFrame.Angles(wheel.spin, 0, 0)
			else
				transform = CFrame.Angles(wheel.spin, 0, 0)
			end
			wheel.motor.Transform = transform
		end
	end
	if refs.bodyMotor and handling.leanAngle > 0 then
		local lean = 0
		if not reducedMotion then
			local factor = math.clamp(math.abs(state.speed) / handling.maxSpeed, 0, 1)
			lean = -state.steer * math.rad(handling.leanAngle) * factor
		end
		refs.bodyMotor.Transform = CFrame.Angles(0, 0, lean)
	end
end

local function safetyChecks(dt: number, chassis: BasePart)
	local position = chassis.Position
	local layout = ctx.layout
	local killY = layout and type(layout.killY) == "number" and layout.killY or -60
	if position.Y < killY then
		requestRecover("below killY")
		return
	end
	-- Distance below the nearest road point, sampled twice a second (graph projection is O(edges)).
	roadCheckTimer += dt
	if roadCheckTimer >= 0.5 then
		roadCheckTimer = 0
		local graph = ctx.graph
		if graph then
			local okNear, point = pcall(function()
				local nearest = RouteGraph.nearestPointOnGraph(graph, position, VehicleDefinitions.Mask.Foot)
				return nearest
			end)
			if okNear and typeof(point) == "Vector3" then
				if point.Y - position.Y > VehicleController.BELOW_ROAD_LIMIT then
					belowRoadTimer += 0.5
				else
					belowRoadTimer = 0
				end
			end
		end
	end
	if belowRoadTimer >= VehicleController.BELOW_ROAD_TIME then
		belowRoadTimer = 0
		requestRecover("below road")
		return
	end
	if chassis.CFrame.UpVector.Y < 0.2 then
		flippedTimer += dt
		if flippedTimer >= VehicleController.FLIPPED_TIME then
			flippedTimer = 0
			requestRecover("flipped")
		end
	else
		flippedTimer = 0
	end
end

local function stepOwner(dt: number)
	local chassis = refs.chassis
	local handling = refs.handling
	local input = controller("InputController")
	local throttle, steerInput, brake = 0, 0, false
	if input and type(input.GetDriveInput) == "function" then
		local okInput, t, s, b = pcall(input.GetDriveInput)
		if okInput then
			throttle, steerInput, brake = t or 0, s or 0, b == true
		end
	end

	local forwardFlat = MathUtil.directionFromHeading(state.heading)
	local probe = probeGround(chassis, forwardFlat, handling, refs.chassisLength)

	state.posY = chassis.Position.Y
	local previousForward = state.forwardOnGround or forwardFlat
	local assemblyVelocity = chassis.AssemblyLinearVelocity or Vector3.zero
	state.actualForwardSpeed = assemblyVelocity:Dot(previousForward)

	local stepHandling = refs.stepHandling
	if not stepHandling or stepHandling.speedMultiplier ~= VehicleController.GetSpeedMultiplier(refs.vehicleId) then
		stepHandling = setmetatable({ speedMultiplier = VehicleController.GetSpeedMultiplier(refs.vehicleId), gravity = Workspace.Gravity }, { __index = handling })
		refs.stepHandling = stepHandling
	end

	VehicleController._stepModel(state, { throttle = throttle, steer = steerInput, brake = brake }, probe, stepHandling, dt)

	-- Apply to the constraints.
	local position = chassis.Position
	local target = CFrame.lookAt(position, position + state.forwardOnGround, probe.normal)
	refs.align.CFrame = target.Rotation
	refs.velocity.VectorVelocity = state.velocity
	maxForceTimer += dt
	if maxForceTimer >= 1 then
		maxForceTimer = 0
		refs.velocity.MaxForce = chassis.AssemblyMass * VehicleController.MAX_FORCE_PER_MASS
	end
	chassis:SetAttribute("Speed", state.speed)

	if state.bumped then
		callController("AudioController", "Play", "Bump")
	end

	local settings = ctx.state.get("settings")
	local reducedMotion = settings and settings.reducedMotion == true
	applyCosmetics(dt, reducedMotion)

	speedFraction = math.clamp(math.abs(state.speed) / math.max(state.maxSpeedEffective or handling.maxSpeed, 1), 0, 1)
	callController("CameraController", "SetSpeedFraction", speedFraction)
	callController("AudioController", "SetEngine", speedFraction, brake and math.abs(state.speed) > 0.5, probe.grounded)
	sendHud()
	safetyChecks(dt, chassis)
end

-- Cosmetic wheel spin for vehicles owned by other players (within range of the camera).
local function stepOthers(dt: number)
	local folder = runtimeVehiclesFolder()
	if not folder then
		return
	end
	local camera = Workspace.CurrentCamera
	local viewpoint = camera and camera.CFrame.Position or Vector3.zero
	local userId = localPlayerId()
	for _, model in ipairs(folder:GetChildren()) do
		if model:IsA("Model") and model:GetAttribute("OwnerUserId") ~= userId then
			local chassis = model:FindFirstChild("Chassis")
			local wheels = model:FindFirstChild("Wheels")
			if chassis and chassis:IsA("BasePart") and wheels and (chassis.Position - viewpoint).Magnitude <= VehicleController.COSMETIC_RANGE then
				local velocity = chassis.AssemblyLinearVelocity or Vector3.zero
				local cf = chassis.CFrame
				local forwardSpeed = velocity:Dot(cf.LookVector)
				local lateral = velocity:Dot(cf.RightVector)
				local steerVisual = 0
				if math.abs(lateral) > 1 and math.abs(forwardSpeed) > 2 then
					steerVisual = MathUtil.sign(lateral) * math.rad(12)
				end
				for _, wheel in ipairs(wheels:GetChildren()) do
					local motor = wheel:FindFirstChild("WheelMotor")
					if motor and wheel:IsA("BasePart") then
						local radius = tonumber(wheel:GetAttribute("Radius")) or 1
						local spin = (otherSpin[wheel] or 0) - forwardSpeed * dt / math.max(radius, 0.1)
						spin = spin % (2 * math.pi)
						otherSpin[wheel] = spin
						if wheel:GetAttribute("Steerable") == true then
							motor.Transform = CFrame.Angles(0, -steerVisual, 0) * CFrame.Angles(spin, 0, 0)
						else
							motor.Transform = CFrame.Angles(spin, 0, 0)
						end
					end
				end
			end
		end
	end
end

local function heartbeat(dt: number)
	if refs and not refs.model.Parent then
		refs = nil
	end
	local wantRun = shouldRun()
	if wantRun and not active then
		activate()
	elseif not wantRun and active then
		deactivate()
	end
	if active then
		local okStep, err = pcall(stepOwner, dt)
		if not okStep then
			warn("[VehicleController] step failed: " .. tostring(err))
		end
	end
	cosmeticTimer += dt
	if cosmeticTimer >= VehicleController.COSMETIC_INTERVAL then
		local elapsed = cosmeticTimer
		cosmeticTimer = 0
		pcall(stepOthers, elapsed)
	end
end

-------------------------------------------------------------------------------
-- Public accessors
-------------------------------------------------------------------------------

function VehicleController.GetSpeed(): number
	return active and state and state.speed or 0
end

function VehicleController.GetSteer(): number
	return active and state and state.steer or 0
end

function VehicleController.IsGrounded(): boolean
	return active and state and state.driveGrounded == true or false
end

function VehicleController.GetSpeedFraction(): number
	return speedFraction
end

function VehicleController.GetHeading(): number
	return active and state and state.heading or 0
end

function VehicleController.IsActive(): boolean
	return active
end

function VehicleController.GetChassis(): BasePart?
	return refs and refs.chassis or nil
end

function VehicleController.GetModel(): Model?
	return refs and refs.model or nil
end

function VehicleController.GetHandling(): any
	return refs and refs.handling or nil
end

function VehicleController.GetVehicleId(): string?
	return refs and refs.vehicleId or nil
end

-- Explicit recovery request (Recover action); honours the 3 s rate limit.
function VehicleController.RequestRecover()
	requestRecover("manual")
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

function VehicleController.Init(context)
	ctx = context
end

function VehicleController.Start()
	ctx.state.onChange("vehicle", function(vehicle)
		task.spawn(function()
			if vehicle and vehicle.state and vehicle.state ~= "Despawning" then
				resolveVehicle()
			else
				refs = nil
			end
			if not shouldRun() and active then
				deactivate()
			end
		end)
	end)

	-- Late streaming: a vehicle model appearing in the runtime folder re-resolves.
	task.spawn(function()
		local runtime = Workspace:WaitForChild("Runtime", 30)
		local folder = runtime and runtime:WaitForChild("Vehicles", 30)
		if folder then
			folder.ChildAdded:Connect(function(child)
				if child:GetAttribute("OwnerUserId") == localPlayerId() then
					task.defer(resolveVehicle)
				end
			end)
		end
	end)

	local input = controller("InputController")
	if input and input.Pressed then
		input.Pressed:Connect(function(actionName)
			if actionName == InputActions.Names.Recover then
				local vehicle = ctx.state.get("vehicle")
				if vehicle and (vehicle.state == "Driving" or vehicle.state == "Parked") then
					requestRecover("action")
				end
			end
		end)
	end

	RunService.Heartbeat:Connect(heartbeat)
end

return VehicleController
