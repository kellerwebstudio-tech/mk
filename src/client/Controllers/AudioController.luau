--!nonstrict
-- AudioController: pooled one-shot sounds (AudioConfig keys; empty ids are skipped), the vehicle
-- engine loop (pitch by speed fraction + brake one-shot), crossfaded ambience zones and the
-- order-event cues. Volumes follow settings.sfxVolume / musicVolume.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Util = Shared:WaitForChild("Util")
local Config = Shared:WaitForChild("Config")
local MathUtil = require(Util:WaitForChild("MathUtil"))
local AudioConfig = require(Config:WaitForChild("AudioConfig"))

local AudioController = {}

AudioController.POOL_PER_KEY = 4
AudioController.AMBIENCE_FADE = 1.5
AudioController.ZONE_INTERVAL = 0.5
AudioController.RESTAURANT_RADIUS = 40
AudioController.AMBIENCE_KEYS = { "CityAmbience", "RestaurantAmbience", "ParkAmbience", "IndustrialAmbience" }

local ctx = nil
local sfxFolder: Instance? = nil
local ambienceFolder: Instance? = nil
local pools: { [string]: { Sound } } = {}
local ambienceSounds: { [string]: Sound } = {}
local ambienceTweens: { [string]: Tween } = {}
local currentZone: string? = nil
local zoneTimer = 0
local sfxVolume = 0.8
local musicVolume = 0.6
local engineSound: Sound? = nil
local engineModel: Instance? = nil
local engineKey: string? = nil
local enginePlaying = false
local wasBraking = false

local function soundDef(key: string)
	local def = AudioConfig.sounds[key]
	if type(def) ~= "table" or type(def.id) ~= "string" or def.id == "" then
		return nil
	end
	return def
end

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
	if not sfxFolder or sfxFolder.Parent ~= SoundService then
		sfxFolder = getOrCreateFolder(SoundService, "DDC_SFX")
	end
	if not ambienceFolder or ambienceFolder.Parent ~= SoundService then
		ambienceFolder = getOrCreateFolder(SoundService, "DDC_Ambience")
	end
end

local function effectiveSfx(def): number
	return (def.volume or 0.5) * (AudioConfig.masterVolume or 1) * sfxVolume
end

local function effectiveAmbience(def): number
	return (def.volume or 0.3) * (AudioConfig.masterVolume or 1) * musicVolume
end

-------------------------------------------------------------------------------
-- One-shots
-------------------------------------------------------------------------------

-- Plays a one-shot from AudioConfig. Returns the Sound used (nil when the key is silent/unknown).
function AudioController.Play(key: string): Sound?
	local def = soundDef(key)
	if not def then
		return nil
	end
	ensureFolders()
	local pool = pools[key]
	if not pool then
		pool = {}
		pools[key] = pool
	end
	local chosen: Sound? = nil
	for _, candidate in ipairs(pool) do
		if candidate.Parent and not candidate.IsPlaying then
			chosen = candidate
			break
		end
	end
	if not chosen then
		if #pool >= AudioController.POOL_PER_KEY then
			local recycled = table.remove(pool, 1) :: Sound
			table.insert(pool, recycled)
			chosen = recycled
		else
			local created = Instance.new("Sound")
			created.Name = key
			created.SoundId = def.id
			created.Looped = def.loop == true
			created.Parent = sfxFolder
			table.insert(pool, created)
			chosen = created
		end
	end
	local sound: Sound = chosen :: Sound
	sound.Volume = effectiveSfx(def)
	sound.PlaybackSpeed = def.pitch or 1
	if sound.IsPlaying then
		pcall(function()
			sound:Stop()
		end)
	end
	pcall(function()
		sound:Play()
	end)
	return sound
end

function AudioController.GetPoolSize(key: string): number
	local pool = pools[key]
	return pool and #pool or 0
end

-------------------------------------------------------------------------------
-- Engine
-------------------------------------------------------------------------------

local function resolveEngine(): Sound?
	local vehicle = ctx.state.get("vehicle")
	local model = vehicle and vehicle.model
	if typeof(model) ~= "Instance" then
		local vehicleController = ctx.controllers and ctx.controllers.VehicleController
		model = vehicleController and type(vehicleController.GetModel) == "function" and vehicleController.GetModel() or nil
	end
	if typeof(model) ~= "Instance" then
		engineSound, engineModel, engineKey = nil, nil, nil
		return nil
	end
	if engineModel == model and engineSound and engineSound.Parent then
		return engineSound
	end
	local chassis = model:FindFirstChild("Chassis")
	local sound = chassis and chassis:FindFirstChild("EngineSound")
	engineModel = model
	if sound and sound:IsA("Sound") and sound.SoundId ~= "" then
		engineSound = sound
		-- Match the config entry by id so the configured base volume is known.
		engineKey = nil
		for key, def in pairs(AudioConfig.sounds) do
			if def.id == sound.SoundId and def.loop then
				engineKey = key
				break
			end
		end
	else
		engineSound = nil
		engineKey = nil
	end
	return engineSound
end

-- Called every frame by VehicleController while driving.
function AudioController.SetEngine(speedFraction: number, braking: boolean, grounded: boolean)
	speedFraction = math.clamp(tonumber(speedFraction) or 0, 0, 1)
	local sound = resolveEngine()
	if sound then
		local def = engineKey and AudioConfig.sounds[engineKey] or nil
		local baseVolume = def and def.volume or 0.4
		sound.PlaybackSpeed = MathUtil.lerp(AudioConfig.enginePitchMin, AudioConfig.enginePitchMax, speedFraction)
		sound.Volume = baseVolume * (AudioConfig.masterVolume or 1) * sfxVolume * (grounded and 1 or 0.6) * (0.5 + 0.5 * speedFraction)
		if not enginePlaying then
			enginePlaying = true
			sound.Looped = true
			pcall(function()
				sound:Play()
			end)
		end
	end
	if braking and not wasBraking and speedFraction > 0.15 then
		AudioController.Play("Brake")
	end
	wasBraking = braking == true
end

function AudioController.StopEngine()
	wasBraking = false
	if enginePlaying then
		enginePlaying = false
		if engineSound then
			pcall(function()
				engineSound:Stop()
			end)
		end
	end
end

-------------------------------------------------------------------------------
-- Ambience zones
-------------------------------------------------------------------------------

local function ensureAmbience(key: string): Sound?
	local existing = ambienceSounds[key]
	if existing and existing.Parent then
		return existing
	end
	local def = soundDef(key)
	if not def then
		return nil
	end
	ensureFolders()
	local sound = Instance.new("Sound")
	sound.Name = key
	sound.SoundId = def.id
	sound.Looped = true
	sound.Volume = 0
	sound.Parent = ambienceFolder
	ambienceSounds[key] = sound
	return sound
end

local function insideRect(position: Vector3, bounds): boolean
	return position.X >= bounds.minX and position.X <= bounds.maxX and position.Z >= bounds.minZ and position.Z <= bounds.maxZ
end

-- Zone for a position: restaurant near a business, park inside the park, industrial inside Dockside.
function AudioController.ZoneFor(position: Vector3): string
	local layout = ctx.layout
	if not layout then
		return "CityAmbience"
	end
	local groundY = layout.groundY or 0
	for _, business in ipairs(layout.businesses or {}) do
		local point = business.pickupPoint or business.door
		if point and MathUtil.horizontalDistance(position, Vector3.new(point.x, groundY, point.z)) <= AudioController.RESTAURANT_RADIUS then
			return "RestaurantAmbience"
		end
	end
	local park = layout.landmarks and layout.landmarks.park
	if park and insideRect(position, { minX = park.x - park.w / 2, maxX = park.x + park.w / 2, minZ = park.z - park.d / 2, maxZ = park.z + park.d / 2 }) then
		return "ParkAmbience"
	end
	for _, neighborhood in ipairs(layout.neighborhoods or {}) do
		if neighborhood.id == "Industrial" and neighborhood.bounds and insideRect(position, neighborhood.bounds) then
			return "IndustrialAmbience"
		end
	end
	return "CityAmbience"
end

local function fadeAmbience(key: string, target: number)
	local sound = ensureAmbience(key)
	if not sound then
		return
	end
	local existingTween = ambienceTweens[key]
	if existingTween then
		pcall(function()
			existingTween:Cancel()
		end)
	end
	if target > 0 and not sound.IsPlaying then
		pcall(function()
			sound:Play()
		end)
	end
	local tween = TweenService:Create(sound, TweenInfo.new(AudioController.AMBIENCE_FADE, Enum.EasingStyle.Linear), { Volume = target })
	ambienceTweens[key] = tween
	tween.Completed:Connect(function()
		if ambienceTweens[key] == tween then
			ambienceTweens[key] = nil
		end
		if target <= 0 and sound.Volume <= 0.001 then
			pcall(function()
				sound:Stop()
			end)
		end
	end)
	tween:Play()
end

function AudioController.SetZone(zone: string)
	if zone == currentZone then
		return
	end
	currentZone = zone
	for _, key in ipairs(AudioController.AMBIENCE_KEYS) do
		local def = soundDef(key)
		if def then
			fadeAmbience(key, key == zone and effectiveAmbience(def) or 0)
		end
	end
end

function AudioController.GetZone(): string?
	return currentZone
end

local function updateZone()
	local position = ctx.state.getPlayerPosition()
	if not position then
		return
	end
	AudioController.SetZone(AudioController.ZoneFor(position))
end

-------------------------------------------------------------------------------
-- Settings
-------------------------------------------------------------------------------

function AudioController.ApplySettings(settings: any)
	if type(settings) ~= "table" then
		return
	end
	if type(settings.sfxVolume) == "number" then
		sfxVolume = math.clamp(settings.sfxVolume, 0, 1)
	end
	if type(settings.musicVolume) == "number" then
		musicVolume = math.clamp(settings.musicVolume, 0, 1)
	end
	-- Re-level the active ambience immediately.
	if currentZone then
		local def = soundDef(currentZone)
		local sound = def and ambienceSounds[currentZone]
		if def and sound and not ambienceTweens[currentZone] then
			sound.Volume = effectiveAmbience(def)
		end
	end
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

function AudioController.Init(context)
	ctx = context
end

function AudioController.Start()
	ctx.state.onChange("settings", AudioController.ApplySettings)

	ctx.state.OrderEvent:Connect(function(payload)
		if type(payload) ~= "table" then
			return
		end
		local kind = payload.kind
		if kind == "Accepted" then
			AudioController.Play("OrderAccepted")
		elseif kind == "Collected" then
			AudioController.Play("Pickup")
		elseif kind == "Delivered" then
			if payload.payout and payload.payout.newRecord then
				AudioController.Play("NewRecord")
			else
				AudioController.Play("Payment")
			end
		elseif kind == "Cancelled" or kind == "Expired" then
			AudioController.Play("Error")
		elseif kind == "Ready" then
			AudioController.Play("Notify")
		end
	end)

	ctx.state.onChange("vehicle", function(vehicle)
		if not vehicle or vehicle.state ~= "Driving" then
			AudioController.StopEngine()
		end
		engineModel = nil
	end)

	RunService.Heartbeat:Connect(function(dt)
		zoneTimer += dt
		if zoneTimer >= AudioController.ZONE_INTERVAL then
			zoneTimer = 0
			pcall(updateZone)
		end
	end)
end

return AudioController
