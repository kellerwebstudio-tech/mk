--!nonstrict
-- VehicleService: server-authoritative vehicle lifecycle (spawn, mount, dismount, recover, despawn),
-- collision groups, watchdog and position queries. See docs/ARCHITECTURE.md 5.4 and docs/VEHICLES.md.

local CollectionService = game:GetService("CollectionService")
local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)
local Signal = require(Shared.Util.Signal)
local Maid = require(Shared.Util.Maid)
local Remotes = require(Shared.Util.Remotes)
local EconomyConfig = require(Shared.Config.EconomyConfig)
local VehicleDefinitions = require(Shared.Definitions.VehicleDefinitions)
local CosmeticDefinitions = require(Shared.Definitions.CosmeticDefinitions)
local RouteGraph = require(Shared.City.RouteGraph)

-- Builders live beside the Services folder. Resolved at load; ctx.builders may override (tests).
local ServerRoot = script.Parent.Parent
local BuildersFolder = ServerRoot:FindFirstChild("Builders")
local vehicleBuilderModule = BuildersFolder and BuildersFolder:FindFirstChild("VehicleBuilder")
local DefaultVehicleBuilder: any = if vehicleBuilderModule then require(vehicleBuilderModule) else nil

type VehicleRecord = Types.VehicleRecord
type VehicleState = Types.VehicleState

local COLLISION_GROUPS = { "Players", "Vehicles", "NPCs", "Packages" }
local WATCHDOG_INTERVAL = 2
local SEAT_VERIFY_TIME = 0.3
local SEAT_POLL = 0.05
local SPAWN_ROAD_RANGE = 80
local GROUND_RAY_UP = 4
local GROUND_RAY_LENGTH = 80
local DISMOUNT_RAISE = 3

local VehicleService = {}

VehicleService.StateChanged = Signal.new()
VehicleService.Mounted = Signal.new()
VehicleService.Dismounted = Signal.new()
VehicleService.Despawned = Signal.new()

local ctx: any = nil
local VehicleBuilder: any = nil
local records: { [Player]: VehicleRecord } = {}
local playerMaids: { [Player]: any } = {}
local running = false

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local function ok(extra: any?)
	return Remotes.ok(extra)
end

local function fail(code: string, message: string?, extra: any?)
	return Remotes.fail(code, message, extra)
end

local function notify(player: Player, text: string, kind: string)
	pcall(function()
		ctx.remotes.getEvent("Notify"):FireClient(player, { text = text, kind = kind, duration = 4 })
	end)
end

local function layoutValue(key: string, default: number): number
	local layout = ctx and ctx.layout
	local value = layout and layout[key]
	if type(value) == "number" then
		return value
	end
	return default
end

local function getHumanoid(character: Model?): Humanoid?
	if not character then
		return nil
	end
	return character:FindFirstChildOfClass("Humanoid")
end

local function getRootPart(character: Model?): BasePart?
	if not character then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function isAlive(player: Player): (Model?, Humanoid?)
	local character = player.Character
	local humanoid = getHumanoid(character)
	if character and humanoid and humanoid.Health > 0 and character.Parent ~= nil then
		return character, humanoid
	end
	return nil, nil
end

local function characterPosition(player: Player): Vector3?
	local root = getRootPart(player.Character)
	return root and root.Position or nil
end

local function flatLook(cf: CFrame): Vector3
	local look = cf.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 1e-3 then
		return Vector3.new(0, 0, -1)
	end
	return flat.Unit
end

local function setPartsCollisionGroup(root: Instance, group: string)
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("BasePart") then
			pcall(function()
				descendant.CollisionGroup = group
			end)
		end
	end
	if root:IsA("BasePart") then
		pcall(function()
			root.CollisionGroup = group
		end)
	end
end

local function getRuntimeFolder(): Instance
	local runtime = Workspace:FindFirstChild("Runtime")
	if not runtime then
		runtime = Instance.new("Folder")
		runtime.Name = "Runtime"
		runtime.Parent = Workspace
	end
	local vehicles = runtime:FindFirstChild("Vehicles")
	if not vehicles then
		vehicles = Instance.new("Folder")
		vehicles.Name = "Vehicles"
		vehicles.Parent = runtime
	end
	return vehicles
end

local function raycastParamsExcluding(model: Model?): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude: { Instance } = {}
	if model then
		table.insert(exclude, model)
	end
	local runtime = Workspace:FindFirstChild("Runtime")
	if runtime then
		table.insert(exclude, runtime)
	end
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character then
			table.insert(exclude, player.Character)
		end
	end
	params.FilterDescendantsInstances = exclude
	params.IgnoreWater = false
	return params
end

-- Ground height under a position (raycast), falling back to the layout ground level.
local function groundHeightAt(position: Vector3, model: Model?): number
	local origin = position + Vector3.new(0, GROUND_RAY_UP, 0)
	local okCast, result = pcall(function()
		return Workspace:Raycast(origin, Vector3.new(0, -GROUND_RAY_LENGTH, 0), raycastParamsExcluding(model))
	end)
	if okCast and result and result.Position then
		return result.Position.Y
	end
	return layoutValue("groundY", 0)
end

local function zeroVelocity(record: VehicleRecord)
	local chassis = record.chassis
	pcall(function()
		chassis.AssemblyLinearVelocity = Vector3.zero
		chassis.AssemblyAngularVelocity = Vector3.zero
	end)
	local velocity = chassis:FindFirstChild("Velocity")
	if velocity and velocity:IsA("LinearVelocity") then
		pcall(function()
			velocity.VectorVelocity = Vector3.zero
		end)
	end
end

local function setNetworkOwner(record: VehicleRecord, player: Player?)
	pcall(function()
		record.chassis:SetNetworkOwner(player)
	end)
end

-- Points the chassis AlignOrientation (OneAttachment mode: a world-space target) at the chassis'
-- current rotation. VehicleBuilder writes it once at identity; Model:PivotTo never rewrites a
-- constraint target, so without this every unanchored moment before the owner client's first
-- step (Mount seat verification, server-simulated) yaws the vehicle toward world -Z.
local function syncAlign(chassis: BasePart)
	local align = chassis:FindFirstChild("Align")
	if align and align:IsA("AlignOrientation") then
		pcall(function()
			align.CFrame = chassis.CFrame.Rotation
		end)
	end
end

local function definitionFor(record: VehicleRecord)
	return VehicleDefinitions.get(record.vehicleId) or VehicleDefinitions.Vehicles.Bicycle
end

local function firePublicState(player: Player, state: string, record: VehicleRecord?)
	pcall(function()
		ctx.remotes.getEvent("VehicleStateChanged"):FireClient(player, {
			state = state,
			vehicleId = record and record.vehicleId or nil,
			model = record and record.model or nil,
		})
	end)
end

local function setState(player: Player, record: VehicleRecord, state: VehicleState)
	record.state = state
	pcall(function()
		record.model:SetAttribute("State", state)
	end)
	VehicleService.StateChanged:Fire(player, state, record)
	firePublicState(player, state, record)
end

local function cityService()
	return ctx and ctx.services and ctx.services.CityService
end

local function antiCheat()
	return ctx and ctx.services and ctx.services.AntiCheatService
end

-- Tells AntiCheat that the server moved the character to `newPosition`. Only call this when the
-- character actually moves (dismount, recover while driving, respawn), never on vehicle spawn.
local function noteTeleport(player: Player, seconds: number, newPosition: Vector3?)
	local anti = antiCheat()
	if anti and anti.NotePlausibleTeleport then
		pcall(anti.NotePlausibleTeleport, player, seconds, newPosition)
	end
end

-- Nearest road point for a mask using CityService or the graph directly.
local function nearestRoadPoint(position: Vector3, mask: number): (Vector3?, number, Vector3?)
	local city = cityService()
	if city and city.GetNearestRoadPoint then
		local okCall, point, distance = pcall(city.GetNearestRoadPoint, position, mask)
		if okCall and point then
			return point, distance, nil
		end
	end
	local graph = ctx and ctx.graph
	if graph and graph.edges and #graph.edges > 0 then
		local point, edge, _, distance = RouteGraph.nearestPointOnGraph(graph, position, mask)
		if point and edge then
			local a = graph.nodes[edge.a].position
			local b = graph.nodes[edge.b].position
			return point, distance, (b - a)
		end
	end
	return nil, math.huge, nil
end

-- Safe respawn CFrame (road point raised to the vehicle's ride height, facing along the edge).
-- CityService.GetSafeRespawnCFrame takes the raise as its third argument (5.3); the fallback
-- computes the same thing from the graph.
local function safeRespawnCFrame(position: Vector3, mask: number, rideHeight: number): CFrame
	local city = cityService()
	if city and city.GetSafeRespawnCFrame then
		local okCall, cf = pcall(city.GetSafeRespawnCFrame, position, mask, rideHeight)
		if okCall and typeof(cf) == "CFrame" then
			return cf
		end
	end
	local point, _, direction = nearestRoadPoint(position, mask)
	if point then
		local dir = direction or Vector3.new(0, 0, -1)
		if dir.Magnitude < 1e-3 then
			dir = Vector3.new(0, 0, -1)
		end
		return CFrame.lookAlong(point + Vector3.new(0, rideHeight, 0), dir.Unit)
	end
	return CFrame.new(position + Vector3.new(0, rideHeight, 0))
end

local function hubSpawnCFrame(): CFrame?
	local city = cityService()
	if city and city.GetHubSpawn then
		local okCall, cf = pcall(city.GetHubSpawn)
		if okCall and cf then
			return cf
		end
	end
	local world = ctx and ctx.world
	if world and world.hubSpawn then
		return world.hubSpawn
	end
	return nil
end

local function vehiclePadCFrame(): CFrame?
	local city = cityService()
	if city and city.GetFreeVehiclePad then
		local okCall, cf = pcall(city.GetFreeVehiclePad)
		if okCall and cf then
			return cf
		end
	end
	local world = ctx and ctx.world
	if world and world.vehiclePads and world.vehiclePads[1] then
		return world.vehiclePads[1]
	end
	return hubSpawnCFrame()
end

local function computeSpawnCFrame(player: Player, def): CFrame
	local rideHeight = def.handling.rideHeight
	local position = characterPosition(player)
	if position then
		local point, distance = nearestRoadPoint(position, def.mask)
		if point and distance <= SPAWN_ROAD_RANGE then
			return safeRespawnCFrame(position, def.mask, rideHeight)
		end
	end
	local pad = vehiclePadCFrame()
	if pad then
		return pad + Vector3.new(0, rideHeight, 0)
	end
	return CFrame.new((position or Vector3.zero) + Vector3.new(0, rideHeight, 0))
end

local function isInsideBounds(position: Vector3): boolean
	local layout = ctx and ctx.layout
	local bounds = layout and layout.bounds
	if type(bounds) ~= "table" then
		return true
	end
	return position.X >= bounds.minX and position.X <= bounds.maxX and position.Z >= bounds.minZ and position.Z <= bounds.maxZ
end

-------------------------------------------------------------------------------
-- Model construction
-------------------------------------------------------------------------------

local function buildModel(player: Player, vehicleId: string): (Model?, string?)
	if not VehicleBuilder or not VehicleBuilder.build then
		return nil, "VehicleBuilder unavailable"
	end
	local def = VehicleDefinitions.get(vehicleId)
	local playerData = ctx.services.PlayerDataService
	local profile = playerData and playerData.GetProfile(player)
	local equipped = profile and profile.cosmetics and profile.cosmetics.equipped or nil
	local colors = CosmeticDefinitions.vehicleColors(vehicleId, equipped, def.defaultColors)
	local okBuild, built = pcall(VehicleBuilder.build, vehicleId, player.UserId, colors)
	if not okBuild or typeof(built) ~= "Instance" then
		return nil, tostring(built)
	end
	return built :: Model, nil
end

local function findRecordParts(model: Model): (BasePart?, VehicleSeat?, BasePart?, Attachment?)
	local chassis = model:FindFirstChild("Chassis")
	local seat = model:FindFirstChild("Seat")
	local bodyRoot = model:FindFirstChild("BodyRoot")
	local cargo = chassis and chassis:FindFirstChild("CargoAttachment")
	if chassis and not chassis:IsA("BasePart") then
		chassis = nil
	end
	if seat and not seat:IsA("VehicleSeat") then
		seat = model:FindFirstChildOfClass("VehicleSeat")
	end
	if bodyRoot and not bodyRoot:IsA("BasePart") then
		bodyRoot = nil
	end
	return chassis :: any, seat :: any, (bodyRoot or chassis) :: any, cargo :: any
end

local function capacityFor(player: Player, vehicleId: string): number
	local progression = ctx.services.ProgressionService
	local playerData = ctx.services.PlayerDataService
	local profile = playerData and playerData.GetProfile(player)
	if progression and profile then
		return progression.GetCapacityForVehicle(profile, vehicleId)
	end
	local def = VehicleDefinitions.get(vehicleId)
	return def and def.baseCapacity or EconomyConfig.onFootCapacity
end

-- Creates the model and record for a Parked vehicle at `cf`. Returns the record or nil + reason.
local function createVehicle(player: Player, vehicleId: string, cf: CFrame): (VehicleRecord?, string?)
	local model, reason = buildModel(player, vehicleId)
	if not model then
		return nil, reason
	end
	local chassis, seat, bodyRoot, cargo = findRecordParts(model)
	if not chassis or not seat then
		model:Destroy()
		return nil, "Vehicle model is missing Chassis or Seat"
	end
	if not cargo then
		cargo = Instance.new("Attachment")
		cargo.Name = "CargoAttachment"
		cargo.Parent = chassis
	end
	model.Name = "Vehicle"
	if model.PrimaryPart == nil then
		model.PrimaryPart = chassis
	end
	model:SetAttribute("OwnerUserId", player.UserId)
	model:SetAttribute("VehicleId", vehicleId)
	model:SetAttribute("State", "Parked")
	model:SetAttribute("Capacity", capacityFor(player, vehicleId))
	pcall(function()
		model.ModelStreamingMode = Enum.ModelStreamingMode.PersistentPerPlayer
	end)
	setPartsCollisionGroup(model, "Vehicles")
	pcall(function()
		seat.Disabled = true
	end)
	chassis.Anchored = true
	pcall(function()
		CollectionService:AddTag(model, "DeliveryVehicle")
	end)
	model.Parent = getRuntimeFolder()
	pcall(function()
		model:AddPersistentPlayer(player)
	end)
	model:PivotTo(cf)
	syncAlign(chassis)

	local record: VehicleRecord = {
		model = model,
		chassis = chassis,
		seat = seat,
		bodyRoot = bodyRoot or chassis,
		vehicleId = vehicleId,
		state = "Parked",
		ownerUserId = player.UserId,
		lastSafePosition = cf.Position,
		cargoAttachment = cargo,
		spawnedAt = os.clock(),
		lastRecoverAt = -math.huge,
	}
	setNetworkOwner(record, nil)
	return record, nil
end

-------------------------------------------------------------------------------
-- Internal state transitions
-------------------------------------------------------------------------------

local function snapToGround(record: VehicleRecord)
	local def = definitionFor(record)
	local chassis = record.chassis
	local position = chassis.Position
	local groundY = groundHeightAt(position, record.model)
	local target = Vector3.new(position.X, groundY + def.handling.rideHeight, position.Z)
	record.model:PivotTo(CFrame.lookAlong(target, flatLook(chassis.CFrame)))
	syncAlign(chassis)
end

local function unseat(record: VehicleRecord, humanoid: Humanoid?)
	if humanoid then
		pcall(function()
			humanoid.Sit = false
			humanoid.Jump = true
		end)
	end
	local weld = record.seat:FindFirstChild("SeatWeld")
	if weld then
		weld:Destroy()
	end
	pcall(function()
		record.seat.Disabled = true
	end)
end

-- Dismount logic shared by Dismount, Died, watchdog and Despawn. Leaves the vehicle Parked.
local function doDismount(player: Player, record: VehicleRecord, moveCharacter: boolean)
	setState(player, record, "Dismounting")
	local character = player.Character
	local humanoid = getHumanoid(character)
	setNetworkOwner(record, nil)
	unseat(record, humanoid)
	if moveCharacter and character and humanoid and humanoid.Health > 0 then
		local def = definitionFor(record)
		local attachment = record.chassis:FindFirstChild("DismountAttachment")
		local localOffset
		if attachment and attachment:IsA("Attachment") then
			localOffset = attachment.Position
		else
			local o = def.dismountOffset
			localOffset = Vector3.new(o[1], o[2], o[3])
		end
		local worldPosition = record.chassis.CFrame:PointToWorldSpace(localOffset) + Vector3.new(0, DISMOUNT_RAISE, 0)
		pcall(function()
			character:PivotTo(CFrame.lookAlong(worldPosition, flatLook(record.chassis.CFrame)))
		end)
		noteTeleport(player, 1, worldPosition)
	end
	snapToGround(record)
	zeroVelocity(record)
	record.chassis.Anchored = true
	setState(player, record, "Parked")
	VehicleService.Dismounted:Fire(player, record)
end

local function clearRecord(player: Player, record: VehicleRecord, destroyModel: boolean)
	if records[player] ~= record then
		return
	end
	records[player] = nil
	if destroyModel and record.model then
		pcall(function()
			record.model:RemovePersistentPlayer(player)
		end)
		record.model:Destroy()
	end
	VehicleService.Despawned:Fire(player)
	VehicleService.StateChanged:Fire(player, "Despawning", nil)
	firePublicState(player, "Despawning", nil)
end

local function doDespawn(player: Player, record: VehicleRecord)
	if record.state == "Driving" or record.state == "Mounting" or record.state == "Recovering" then
		doDismount(player, record, true)
	end
	record.state = "Despawning"
	pcall(function()
		record.model:SetAttribute("State", "Despawning")
	end)
	clearRecord(player, record, true)
end

local function doRecover(player: Player, record: VehicleRecord): boolean
	local def = definitionFor(record)
	local previous = record.state
	if previous ~= "Driving" and previous ~= "Parked" then
		return false
	end
	setState(player, record, "Recovering")
	local cf = safeRespawnCFrame(record.lastSafePosition, def.mask, def.handling.rideHeight)
	zeroVelocity(record)
	record.model:PivotTo(cf)
	syncAlign(record.chassis)
	if previous == "Driving" then
		-- The rider is welded to the seat; move the character explicitly so it never lags behind.
		local character = player.Character
		if character then
			pcall(function()
				character:PivotTo(record.seat.CFrame + Vector3.new(0, 1.5, 0))
			end)
		end
		-- Only a riding player was moved; a Parked recover moves the vehicle alone, so the
		-- character sampler must not be reset for it.
		noteTeleport(player, 3, record.chassis.Position)
	else
		record.chassis.Anchored = true
	end
	record.lastSafePosition = cf.Position
	record.lastRecoverAt = os.clock()
	setState(player, record, previous)
	return true
end

-- Enables/disables the VehicleSeat. Disabled seats cannot be sat on by touching; the seat is
-- enabled only while the owner rides so throttle/steer input is delivered by the engine.
local function setSeatEnabled(record: VehicleRecord, enabled: boolean)
	pcall(function()
		record.seat.Disabled = not enabled
	end)
end

-- Seats the humanoid and verifies it, retrying once by toggling Disabled. May yield.
local function trySeat(record: VehicleRecord, humanoid: Humanoid): boolean
	local seat = record.seat
	local function waitSeated(): boolean
		if seat.Occupant == humanoid then
			return true
		end
		local deadline = os.clock() + SEAT_VERIFY_TIME
		while os.clock() < deadline do
			task.wait(SEAT_POLL)
			if seat.Occupant == humanoid then
				return true
			end
			if record.state ~= "Mounting" then
				return false
			end
		end
		return seat.Occupant == humanoid
	end
	-- The seat is enabled for the whole ride so the engine feeds ThrottleFloat/SteerFloat to the
	-- occupant; it is disabled again when the vehicle parks (see setSeatEnabled) so nobody can
	-- sit by touching it. Ownership is still enforced by the watchdog.
	setSeatEnabled(record, true)
	pcall(function()
		seat:Sit(humanoid)
	end)
	if waitSeated() then
		return true
	end
	if record.state ~= "Mounting" then
		return false
	end
	-- Retry once: toggle Disabled and sit again after a short delay.
	setSeatEnabled(record, false)
	task.wait(EconomyConfig.mountRetryDelay)
	if record.state ~= "Mounting" then
		return false
	end
	setSeatEnabled(record, true)
	pcall(function()
		seat:Sit(humanoid)
	end)
	local seated = waitSeated()
	if not seated then
		setSeatEnabled(record, false)
	end
	return seated
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

function VehicleService.Spawn(player: Player, vehicleId: string)
	if type(vehicleId) ~= "string" then
		return fail("Invalid", "Invalid vehicle")
	end
	local def = VehicleDefinitions.get(vehicleId)
	if not def then
		return fail("NotFound", "Unknown vehicle")
	end
	local playerData = ctx.services.PlayerDataService
	local profile = playerData and playerData.GetProfile(player)
	if not profile then
		return fail("Locked", "Your profile is still loading")
	end
	if not profile.ownedVehicles[vehicleId] then
		return fail("Locked", "You don't own the " .. def.displayName)
	end
	local existing = records[player]
	if existing then
		doDespawn(player, existing)
	end
	local cf = computeSpawnCFrame(player, def)
	local record, reason = createVehicle(player, vehicleId, cf)
	if not record then
		warn("[VehicleService] spawn failed for", player.Name, reason)
		return fail("Internal", "Could not spawn the vehicle")
	end
	records[player] = record
	-- The character does not move on spawn (the vehicle appears beside it), so AntiCheat is NOT told
	-- about a teleport here; doing so would let a client reset the sampler on demand.
	setState(player, record, "Parked")
	return ok({ vehicleId = vehicleId })
end

function VehicleService.Despawn(player: Player)
	local record = records[player]
	if not record then
		return fail("NotFound", "No vehicle to despawn")
	end
	doDespawn(player, record)
	return ok()
end

-- targetModel is optional: when the client points at a specific vehicle it must be the player's own.
function VehicleService.Mount(player: Player, targetModel: Model?)
	local record = records[player]
	if targetModel ~= nil then
		if typeof(targetModel) ~= "Instance" or not record or targetModel ~= record.model then
			return fail("NotOwner", "That isn't your vehicle")
		end
	end
	if not record then
		return fail("NotFound", "Spawn a vehicle first")
	end
	if record.state ~= "Parked" then
		return fail("WrongState", "The vehicle isn't parked")
	end
	local character, humanoid = isAlive(player)
	if not character or not humanoid then
		return fail("Invalid", "No character")
	end
	if humanoid.SeatPart ~= nil or humanoid.Sit then
		return fail("WrongState", "You're already seated")
	end
	local root = getRootPart(character)
	if not root then
		return fail("Invalid", "No character")
	end
	if (root.Position - record.chassis.Position).Magnitude > EconomyConfig.mountDistance then
		return fail("TooFar", "Get closer to your vehicle")
	end

	setState(player, record, "Mounting")
	-- The chassis is simulated by the server until ownership passes to the rider below; make sure
	-- the orientation target is the parked heading before anything can act on it.
	syncAlign(record.chassis)
	record.chassis.Anchored = false
	local seated = trySeat(record, humanoid)
	if records[player] ~= record or record.state ~= "Mounting" then
		return fail("WrongState", "Mount interrupted")
	end
	if not seated then
		unseat(record, humanoid)
		zeroVelocity(record)
		record.chassis.Anchored = true
		setState(player, record, "Parked")
		notify(player, "Couldn't get on the vehicle. Try again.", "warning")
		return fail("Invalid", "Couldn't get on the vehicle. Try again.")
	end
	setNetworkOwner(record, player)
	setState(player, record, "Driving")
	VehicleService.Mounted:Fire(player, record)
	return ok({ vehicleId = record.vehicleId })
end

function VehicleService.Dismount(player: Player)
	local record = records[player]
	if not record then
		return fail("NotFound", "No vehicle")
	end
	if record.state ~= "Driving" then
		return fail("WrongState", "You're not driving")
	end
	doDismount(player, record, true)
	return ok()
end

function VehicleService.Recover(player: Player)
	local record = records[player]
	if not record then
		return fail("NotFound", "No vehicle")
	end
	if record.state ~= "Driving" and record.state ~= "Parked" then
		return fail("WrongState", "Can't recover right now")
	end
	local now = os.clock()
	if now - record.lastRecoverAt < EconomyConfig.recoverCooldown then
		return fail("Cooldown", "Recovering too fast", { secondsLeft = EconomyConfig.recoverCooldown - (now - record.lastRecoverAt) })
	end
	if not doRecover(player, record) then
		return fail("WrongState", "Can't recover right now")
	end
	return ok()
end

function VehicleService.GetVehicle(player: Player): VehicleRecord?
	return records[player]
end

function VehicleService.GetState(player: Player): VehicleState?
	local record = records[player]
	return record and record.state or nil
end

function VehicleService.IsDriving(player: Player): boolean
	local record = records[player]
	return record ~= nil and record.state == "Driving"
end

function VehicleService.GetCurrentVehicleId(player: Player): string?
	local record = records[player]
	return record and record.vehicleId or nil
end

function VehicleService.GetPlayerPosition(player: Player): Vector3?
	local record = records[player]
	if record and record.state == "Driving" then
		return record.chassis.Position
	end
	return characterPosition(player)
end

function VehicleService.GetVehicleMask(player: Player): number
	local record = records[player]
	if record and record.state == "Driving" then
		return VehicleDefinitions.maskForVehicle(record.vehicleId)
	end
	return VehicleDefinitions.Mask.Foot
end

-- Capacity units available right now: the spawned vehicle's capacity, or on-foot capacity.
function VehicleService.GetCapacityUnits(player: Player): number
	local record = records[player]
	local progression = ctx.services.ProgressionService
	local playerData = ctx.services.PlayerDataService
	local profile = playerData and playerData.GetProfile(player)
	if progression and profile then
		return progression.GetCapacityForVehicle(profile, record and record.vehicleId or nil)
	end
	if record then
		local def = VehicleDefinitions.get(record.vehicleId)
		return def and def.baseCapacity or EconomyConfig.onFootCapacity
	end
	return EconomyConfig.onFootCapacity
end

-- Refreshes the Capacity attribute after an upgrade purchase.
function VehicleService.RefreshCapacity(player: Player)
	local record = records[player]
	if not record then
		return
	end
	pcall(function()
		record.model:SetAttribute("Capacity", capacityFor(player, record.vehicleId))
	end)
end

-------------------------------------------------------------------------------
-- Player / character handling
-------------------------------------------------------------------------------

local function onDied(player: Player)
	local record = records[player]
	if record and (record.state == "Driving" or record.state == "Mounting") then
		doDismount(player, record, false)
	end
end

local function onCharacterAdded(player: Player, character: Model)
	local maid = playerMaids[player]
	setPartsCollisionGroup(character, "Players")
	local descendantConnection = character.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("BasePart") then
			pcall(function()
				descendant.CollisionGroup = "Players"
			end)
		end
	end)
	if maid then
		maid:Set("characterDescendants", descendantConnection)
	end
	local humanoid = getHumanoid(character)
	if not humanoid then
		humanoid = character:WaitForChild("Humanoid", 5) :: any
	end
	if humanoid then
		local diedConnection = humanoid.Died:Connect(function()
			onDied(player)
		end)
		if maid then
			maid:Set("humanoidDied", diedConnection)
		end
	end

	-- A vehicle that was lost (destroyed externally) is rebuilt Parked at a hub pad.
	local record = records[player]
	if record and record.model.Parent == nil then
		local def = definitionFor(record)
		local pad = vehiclePadCFrame()
		local cf = if pad then pad + Vector3.new(0, def.handling.rideHeight, 0) else CFrame.new(record.lastSafePosition)
		local rebuilt = createVehicle(player, record.vehicleId, cf)
		records[player] = nil
		if rebuilt then
			records[player] = rebuilt
			setState(player, rebuilt, "Parked")
		end
	end

	-- Characters spawn at the hub.
	local hub = hubSpawnCFrame()
	local placedAt: Vector3? = nil
	if hub then
		local root = getRootPart(character) or character:WaitForChild("HumanoidRootPart", 5)
		if root and character.Parent ~= nil then
			local target = hub + Vector3.new(0, 3, 0)
			pcall(function()
				character:PivotTo(target)
			end)
			placedAt = target.Position
		end
	end
	noteTeleport(player, 3, placedAt)
end

local function onPlayerAdded(player: Player)
	if playerMaids[player] then
		return
	end
	local maid = Maid.new()
	playerMaids[player] = maid
	maid:GiveTask(player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end))
	if player.Character then
		task.spawn(onCharacterAdded, player, player.Character)
	end
end

local function onPlayerRemoving(player: Player)
	local record = records[player]
	if record then
		doDespawn(player, record)
	end
	local maid = playerMaids[player]
	if maid then
		maid:DoCleaning()
		playerMaids[player] = nil
	end
end

-- Watchdog: unauthorized occupants, lost riders, falling vehicles and safe-position tracking.
local function watchdogPass()
	local killY = layoutValue("killY", -60)
	local groundY = layoutValue("groundY", 0)
	for player, record in pairs(records) do
		if record.model.Parent == nil then
			-- Destroyed externally: clear the record and let the player spawn again.
			clearRecord(player, record, false)
			notify(player, "Your vehicle was lost. Spawn a new one from the menu.", "warning")
			continue
		end
		if record.state == "Driving" then
			local occupant = record.seat.Occupant
			local ownerHumanoid = getHumanoid(player.Character)
			if occupant ~= nil and occupant ~= ownerHumanoid then
				pcall(function()
					occupant.Sit = false
					occupant.Jump = true
				end)
				local weld = record.seat:FindFirstChild("SeatWeld")
				if weld then
					weld:Destroy()
				end
			elseif occupant == nil or ownerHumanoid == nil or ownerHumanoid.Health <= 0 then
				doDismount(player, record, ownerHumanoid ~= nil and ownerHumanoid.Health > 0)
			end
		elseif record.state == "Parked" then
			local occupant = record.seat.Occupant
			if occupant ~= nil then
				pcall(function()
					occupant.Sit = false
					occupant.Jump = true
				end)
			end
		end
		if records[player] ~= record then
			continue
		end
		local position = record.chassis.Position
		if position.Y < killY then
			doRecover(player, record)
		elseif isInsideBounds(position) and position.Y > groundY - 5 then
			record.lastSafePosition = position
		end
	end
end

function VehicleService.Init(context)
	ctx = context
	VehicleBuilder = (ctx.builders and ctx.builders.VehicleBuilder) or DefaultVehicleBuilder
	for _, group in ipairs(COLLISION_GROUPS) do
		pcall(function()
			PhysicsService:RegisterCollisionGroup(group)
		end)
	end
	local function setCollidable(a: string, b: string, collidable: boolean)
		pcall(function()
			PhysicsService:CollisionGroupSetCollidable(a, b, collidable)
		end)
	end
	setCollidable("Vehicles", "Vehicles", false)
	setCollidable("Vehicles", "Players", false)
	setCollidable("Vehicles", "NPCs", false)
	setCollidable("Players", "NPCs", false)
	for _, group in ipairs(COLLISION_GROUPS) do
		setCollidable("Packages", group, false)
	end
	setCollidable("Packages", "Default", false)
end

function VehicleService.Start()
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in ipairs(Players:GetPlayers()) do
		onPlayerAdded(player)
	end
	running = true
	task.spawn(function()
		while running do
			task.wait(WATCHDOG_INTERVAL)
			local okPass, err = pcall(watchdogPass)
			if not okPass then
				warn("[VehicleService] watchdog error:", err)
			end
		end
	end)
end

-- Exposed for tests: runs one watchdog pass immediately.
function VehicleService.RunWatchdog()
	watchdogPass()
end

return VehicleService
