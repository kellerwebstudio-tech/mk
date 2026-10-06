--!nonstrict
-- SettingsController: mirrors profile.settings into ClientState.settings, applies them live
-- (camera sensitivity, reduced motion, audio volumes are read by Camera/Audio controllers through
-- ClientState.settings and notified through SettingsController.Applied) and saves changes to the
-- server through SaveSettings with a 1.5 s debounce.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Util = Shared:WaitForChild("Util")
local Signal = require(Util:WaitForChild("Signal"))
local TableUtil = require(Util:WaitForChild("TableUtil"))

local SettingsController = {}

SettingsController.SAVE_DEBOUNCE = 1.5

SettingsController.DEFAULTS = {
	cameraSensitivity = 1,
	reducedMotion = false,
	autoRecenter = true,
	musicVolume = 0.6,
	sfxVolume = 0.8,
	showMinimap = true,
	invertCameraY = false,
}

-- Fired after settings were applied: (settings: table)
SettingsController.Applied = Signal.new()

local ctx = nil
local settings: { [string]: any } = TableUtil.deepCopy(SettingsController.DEFAULTS)
local dirty = false
local saveToken = 0
local saving = false

local function sanitize(raw: any): { [string]: any }
	local result = TableUtil.deepCopy(SettingsController.DEFAULTS)
	if type(raw) ~= "table" then
		return result
	end
	for key, default in pairs(SettingsController.DEFAULTS) do
		local value = raw[key]
		if type(value) == type(default) then
			if type(value) == "number" then
				if TableUtil.isFiniteNumber(value) then
					if key == "cameraSensitivity" then
						result[key] = math.clamp(value, 0.2, 3)
					else
						result[key] = math.clamp(value, 0, 1)
					end
				end
			else
				result[key] = value
			end
		end
	end
	return result
end

-- Pushes the current settings into ClientState and tells the other controllers.
local function apply()
	local snapshot = TableUtil.deepCopy(settings)
	ctx.state.set("settings", snapshot)
	local controllers = ctx.controllers or {}
	for _, name in ipairs({ "CameraController", "AudioController" }) do
		local controller = controllers[name]
		if controller and type(controller.ApplySettings) == "function" then
			local ok, err = pcall(controller.ApplySettings, snapshot)
			if not ok then
				warn("[SettingsController] " .. name .. ".ApplySettings failed: " .. tostring(err))
			end
		end
	end
	SettingsController.Applied:Fire(snapshot)
end

local function saveNow()
	if saving then
		return
	end
	saving = true
	dirty = false
	local payload = TableUtil.deepCopy(settings)
	local ok, result = pcall(function()
		return ctx.remotes.getFunction("SaveSettings"):InvokeServer(payload)
	end)
	saving = false
	if not ok then
		warn("[SettingsController] SaveSettings failed: " .. tostring(result))
		return
	end
	if type(result) == "table" and result.ok and type(result.settings) == "table" then
		-- The server may have clamped values; adopt them without triggering another save.
		local merged = sanitize(result.settings)
		if not TableUtil.deepEquals(merged, settings) then
			settings = merged
			apply()
		end
	elseif type(result) == "table" and result.ok == false then
		warn("[SettingsController] SaveSettings rejected: " .. tostring(result.message or result.error))
	end
	if dirty then
		SettingsController.ScheduleSave()
	end
end

function SettingsController.ScheduleSave()
	dirty = true
	saveToken += 1
	local token = saveToken
	task.delay(SettingsController.SAVE_DEBOUNCE, function()
		if token == saveToken and dirty then
			saveNow()
		end
	end)
end

function SettingsController.Get(key: string): any
	return settings[key]
end

function SettingsController.GetAll(): { [string]: any }
	return TableUtil.deepCopy(settings)
end

-- Changes one setting locally (applied at once) and saves it to the server after the debounce.
function SettingsController.Set(key: string, value: any)
	if SettingsController.DEFAULTS[key] == nil then
		warn("[SettingsController] unknown setting " .. tostring(key))
		return
	end
	local candidate = TableUtil.deepCopy(settings)
	candidate[key] = value
	local cleaned = sanitize(candidate)
	if cleaned[key] == settings[key] then
		return
	end
	settings = cleaned
	apply()
	SettingsController.ScheduleSave()
end

function SettingsController.Init(context)
	ctx = context
end

function SettingsController.Start()
	ctx.state.onChange("profile", function(profile)
		if type(profile) ~= "table" then
			return
		end
		if dirty then
			-- A local change is pending; keep it until the save round-trip settles it.
			return
		end
		local incoming = sanitize(profile.settings)
		if not TableUtil.deepEquals(incoming, settings) then
			settings = incoming
			apply()
		elseif ctx.state.get("settings") == nil then
			apply()
		end
	end)
	if ctx.state.get("settings") == nil then
		apply()
	end
end

return SettingsController
