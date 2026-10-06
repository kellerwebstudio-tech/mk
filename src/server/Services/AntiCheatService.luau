--!nonstrict
-- AntiCheatService: samples each player's position once per second and flags implausible movement.
-- A flag only blocks reward-bearing interactions (pickup/delivery) for a few seconds; it never kicks.
-- See docs/ARCHITECTURE.md section 5.10.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local EconomyConfig = require(Shared.Config.EconomyConfig)
local VehicleDefinitions = require(Shared.Definitions.VehicleDefinitions)

-- Max plausible speed on foot (walking plus a generous allowance for falling/jumping).
local FOOT_MAX_SPEED = 50

type Sample = {
	lastPosition: Vector3?,
	lastTime: number,
	strikes: number,
	flaggedUntil: number,
	suppressUntil: number,
}

local AntiCheatService = {}

local ctx: any = nil
local samples: { [Player]: Sample } = {}
local running = false

local function getSample(player: Player): Sample
	local sample = samples[player]
	if not sample then
		sample = { lastPosition = nil, lastTime = os.clock(), strikes = 0, flaggedUntil = 0, suppressUntil = 0 }
		samples[player] = sample
	end
	return sample
end

local function characterPosition(player: Player): Vector3?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root then
		return (root :: BasePart).Position
	end
	return nil
end

local function currentPosition(player: Player): Vector3?
	local vehicles = ctx and ctx.services and ctx.services.VehicleService
	if vehicles and vehicles.GetPlayerPosition then
		local ok, position = pcall(vehicles.GetPlayerPosition, player)
		if ok and position then
			return position
		end
	end
	return characterPosition(player)
end

-- Max speed the player could legitimately move at right now (studs/s).
local function maxSpeedFor(player: Player): number
	local vehicles = ctx and ctx.services and ctx.services.VehicleService
	if vehicles and vehicles.IsDriving and vehicles.IsDriving(player) then
		local vehicleId = vehicles.GetCurrentVehicleId and vehicles.GetCurrentVehicleId(player)
		local def = vehicleId and VehicleDefinitions.get(vehicleId)
		if def then
			local multiplier = 1
			local progression = ctx.services.ProgressionService
			local playerData = ctx.services.PlayerDataService
			local profile = playerData and playerData.GetProfile(player)
			if progression and profile then
				multiplier = progression.GetSpeedMultiplier(profile, vehicleId)
			end
			return def.handling.maxSpeed * multiplier
		end
	end
	return FOOT_MAX_SPEED
end

local function samplePlayer(player: Player, now: number)
	local sample = getSample(player)
	local position = currentPosition(player)
	if not position then
		sample.lastPosition = nil
		sample.lastTime = now
		return
	end
	if now < sample.suppressUntil then
		-- Inside a server-announced teleport window: keep the server-chosen reference point and do
		-- not adopt whatever the client reports; the first sample after the window compares
		-- against it over the whole elapsed time.
		return
	end
	local elapsed = now - sample.lastTime
	local previous = sample.lastPosition
	if previous and elapsed > 0 then
		local allowed = (maxSpeedFor(player) * EconomyConfig.speedTolerance + EconomyConfig.speedSlack) * elapsed
		local travelled = (position - previous).Magnitude
		if travelled > allowed then
			sample.strikes += 1
			sample.flaggedUntil = now + EconomyConfig.flagDuration
		end
	end
	sample.lastPosition = position
	sample.lastTime = now
end

function AntiCheatService.Init(context)
	ctx = context
end

function AntiCheatService.Start()
	Players.PlayerRemoving:Connect(function(player)
		samples[player] = nil
	end)
	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function()
			-- Respawns teleport the character; never count that as movement.
			AntiCheatService.NotePlausibleTeleport(player, 3)
		end)
	end)
	running = true
	task.spawn(function()
		while running do
			task.wait(EconomyConfig.positionSampleInterval)
			local now = os.clock()
			for _, player in ipairs(Players:GetPlayers()) do
				samplePlayer(player, now)
			end
		end
	end)
end

-- Called when the SERVER moves a player (dismount, recover while driving, respawn): suppresses
-- movement checks for `seconds` and records `newPosition` (the server-chosen destination) as the
-- reference point for the next comparison. Never call it for client-reported movement or for
-- actions that do not move the character (e.g. spawning a parked vehicle).
function AntiCheatService.NotePlausibleTeleport(player: Player, seconds: number, newPosition: Vector3?)
	local sample = getSample(player)
	local now = os.clock()
	sample.suppressUntil = math.max(sample.suppressUntil, now + (seconds or 3))
	if typeof(newPosition) == "Vector3" then
		sample.lastPosition = newPosition
	else
		sample.lastPosition = currentPosition(player)
	end
	sample.lastTime = now
end

-- False while the player is flagged for implausible movement.
function AntiCheatService.CheckPosition(player: Player): boolean
	local sample = samples[player]
	if not sample then
		return true
	end
	return sample.flaggedUntil <= os.clock()
end

function AntiCheatService.GetStrikes(player: Player): number
	local sample = samples[player]
	return if sample then sample.strikes else 0
end

-- Runs one sampling pass immediately (used by tests and by services that want a fresh check).
function AntiCheatService.SampleNow(player: Player)
	samplePlayer(player, os.clock())
end

return AntiCheatService
