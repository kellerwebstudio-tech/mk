--!nonstrict
-- HandlingOverrides: client-side, session-only overrides of VehicleDefinitions handling values for
-- live tuning in Studio (docs/DEVTOOLS.md). With no overrides `get` returns the definition's own
-- handling table (same identity), so behaviour is byte-for-byte the shipped one; with overrides it
-- returns a merged copy. VehicleController and CameraController read handling through `get` and
-- refresh on `Changed`. Overrides never leave the client and never persist.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Util = Shared:WaitForChild("Util")
local Definitions = Shared:WaitForChild("Definitions")
local Signal = require(Util:WaitForChild("Signal"))
local VehicleDefinitions = require(Definitions:WaitForChild("VehicleDefinitions"))

local HandlingOverrides = {}

-- Fired with (vehicleId) after set / reset changed something.
HandlingOverrides.Changed = Signal.new()

-- Snippet / panel order: the VehicleDefinitions.Handling fields in their declared order.
HandlingOverrides.KEY_ORDER = {
	"maxSpeed",
	"reverseSpeed",
	"acceleration",
	"brakeDeceleration",
	"coastDeceleration",
	"turnRate",
	"turnFullSpeed",
	"minTurnFactor",
	"highSpeedTurnFactor",
	"steerResponse",
	"rideHeight",
	"probeExtra",
	"verticalGain",
	"maxClimbRate",
	"maxFallSpeed",
	"leanAngle",
	"wheelSteerAngle",
	"blockedSpeedFraction",
	"blockedTime",
	"bumpSlowdown",
	"maxSlopeDegrees",
	"cameraDistance",
	"cameraHeight",
	"cameraLookAhead",
	"fovSpeedBoost",
}

local overrides: { [string]: { [string]: number } } = {}
local merged: { [string]: any } = {} -- vehicleId -> cached merged copy (rebuilt on change)

local function definition(vehicleId: any)
	if type(vehicleId) ~= "string" then
		return nil
	end
	return VehicleDefinitions.get(vehicleId)
end

local function isFinite(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- Handling table for a vehicle: the definition's own table when nothing is overridden, otherwise
-- a merged copy (definition values with the overrides applied). Unknown ids fall back to Bicycle.
function HandlingOverrides.get(vehicleId: string): any
	local def = definition(vehicleId) or VehicleDefinitions.Vehicles.Bicycle
	local id = def and def.id or vehicleId
	local current = overrides[id]
	if current == nil or next(current) == nil then
		return def.handling
	end
	local cached = merged[id]
	if cached then
		return cached
	end
	local copy = table.clone(def.handling)
	for key, value in pairs(current) do
		copy[key] = value
	end
	merged[id] = copy
	return copy
end

-- Default (definition) value of a handling key, nil for unknown keys.
function HandlingOverrides.getDefault(vehicleId: string, key: string): number?
	local def = definition(vehicleId)
	local value = def and def.handling[key]
	return if type(value) == "number" then value else nil
end

-- Sets one override. Returns true when the stored overrides changed. A value equal to the
-- definition's own value removes the override. Unknown vehicles / keys / non-finite values are
-- ignored (false).
function HandlingOverrides.set(vehicleId: string, key: string, value: number): boolean
	local def = definition(vehicleId)
	if not def or type(key) ~= "string" or type(def.handling[key]) ~= "number" or not isFinite(value) then
		return false
	end
	local current = overrides[vehicleId]
	local stored = current and current[key]
	if value == def.handling[key] then
		if stored == nil then
			return false
		end
		current[key] = nil
		if next(current) == nil then
			overrides[vehicleId] = nil
		end
	else
		if stored == value then
			return false
		end
		if not current then
			current = {}
			overrides[vehicleId] = current
		end
		current[key] = value
	end
	merged[vehicleId] = nil
	HandlingOverrides.Changed:Fire(vehicleId)
	return true
end

-- Drops every override of a vehicle. Returns true when there was something to drop.
function HandlingOverrides.reset(vehicleId: string): boolean
	if overrides[vehicleId] == nil then
		return false
	end
	overrides[vehicleId] = nil
	merged[vehicleId] = nil
	HandlingOverrides.Changed:Fire(vehicleId)
	return true
end

-- Copy of the overrides of a vehicle ({key = value}; empty when none).
function HandlingOverrides.getOverrides(vehicleId: string): { [string]: number }
	local current = overrides[vehicleId]
	return if current then table.clone(current) else {}
end

function HandlingOverrides.hasOverrides(vehicleId: string): boolean
	local current = overrides[vehicleId]
	return current ~= nil and next(current) ~= nil
end

local function formatNumber(value: number): string
	if value == math.floor(value) and math.abs(value) < 1e15 then
		return string.format("%d", value)
	end
	return string.format("%.6g", value)
end

HandlingOverrides.formatNumber = formatNumber

-- Luau text of the FULL merged handling table, ready to paste over `handling = { ... }` in
-- VehicleDefinitions. Overridden keys carry a trailing comment.
function HandlingOverrides.snippet(vehicleId: string): string
	local def = definition(vehicleId) or VehicleDefinitions.Vehicles.Bicycle
	local handling = HandlingOverrides.get(def.id)
	local current = overrides[def.id] or {}
	local lines = { "handling = {" }
	local seen = {}
	local function emit(key: string)
		local value = handling[key]
		if type(value) ~= "number" or seen[key] then
			return
		end
		seen[key] = true
		local suffix = ""
		if current[key] ~= nil then
			suffix = string.format(" -- was %s", formatNumber(def.handling[key]))
		end
		table.insert(lines, string.format("\t%s = %s,%s", key, formatNumber(value), suffix))
	end
	for _, key in ipairs(HandlingOverrides.KEY_ORDER) do
		emit(key)
	end
	local extra = {}
	for key, value in pairs(handling) do
		if type(value) == "number" and not seen[key] then
			table.insert(extra, key)
		end
	end
	table.sort(extra)
	for _, key in ipairs(extra) do
		emit(key)
	end
	table.insert(lines, "},")
	return table.concat(lines, "\n")
end

-- Clears everything (tests / "Reset to defaults" for every vehicle).
function HandlingOverrides.resetAll()
	local ids = {}
	for vehicleId in pairs(overrides) do
		table.insert(ids, vehicleId)
	end
	table.sort(ids)
	for _, vehicleId in ipairs(ids) do
		HandlingOverrides.reset(vehicleId)
	end
end

return HandlingOverrides
