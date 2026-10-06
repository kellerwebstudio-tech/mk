--!nonstrict
-- SettingsMenu: camera sensitivity, reduced motion, auto-recenter, invert Y, music/sfx volumes,
-- minimap toggle, a per-device controls reference and a Recover vehicle button. Changes go through
-- SettingsController.Set when present (it writes ClientState.settings at once and debounces
-- SaveSettings); otherwise the menu writes ClientState.settings itself and debounces the remote.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Util = Shared:WaitForChild("Util")
local TableUtil = require(Util:WaitForChild("TableUtil"))
local InputActions = require(Shared:WaitForChild("InputActions"))
local UIKit = require(script.Parent:WaitForChild("UIKit"))

local SettingsMenu = {}

SettingsMenu.Name = "Settings"
SettingsMenu.SAVE_DEBOUNCE = 1.5

SettingsMenu.DEFAULTS = {
	cameraSensitivity = 1,
	reducedMotion = false,
	autoRecenter = true,
	musicVolume = 0.6,
	sfxVolume = 0.8,
	showMinimap = true,
	invertCameraY = false,
}

local ctx = nil
local modal = nil
local widgets: { [string]: any } = {}
local controlsList: any = nil
local saveToken = 0
local recovering = false

local function currentSettings(): { [string]: any }
	local settings = ctx.state.get("settings")
	local result = TableUtil.deepCopy(SettingsMenu.DEFAULTS)
	if type(settings) == "table" then
		for key in pairs(SettingsMenu.DEFAULTS) do
			if settings[key] ~= nil then
				result[key] = settings[key]
			end
		end
	end
	return result
end

local function scheduleSave(snapshot: { [string]: any })
	saveToken += 1
	local token = saveToken
	task.delay(SettingsMenu.SAVE_DEBOUNCE, function()
		if token ~= saveToken then
			return
		end
		local result = UIKit.invoke(ctx, "SaveSettings", snapshot)
		if not result.ok then
			UIKit.notify(ctx, "Settings could not be saved: " .. tostring(result.message or result.error), "warning", 4)
		end
	end)
end

-- Applies one setting locally at once and saves it (debounced).
function SettingsMenu.Apply(key: string, value: any)
	local controller = ctx.controllers and ctx.controllers.SettingsController
	if controller and type(controller.Set) == "function" then
		controller.Set(key, value)
		return
	end
	local snapshot = currentSettings()
	snapshot[key] = value
	ctx.state.set("settings", snapshot)
	scheduleSave(snapshot)
end

local function recoverVehicle()
	if recovering then
		return
	end
	recovering = true
	task.spawn(function()
		local result = UIKit.invoke(ctx, "RecoverVehicle")
		recovering = false
		if result.ok then
			UIKit.notify(ctx, "Vehicle recovered to the road.", "success", 3)
		else
			UIKit.notify(ctx, tostring(result.message or result.error or "Could not recover"), "warning", 4)
		end
	end)
end

local function buildControls(parent: Instance)
	UIKit.label(parent, "Controls", { name = "ControlsTitle", bold = true, size = UDim2.new(1, 0, 0, 26), maxSize = 20, layoutOrder = 50 })
	controlsList = UIKit.column(parent, { name = "Controls", size = UDim2.new(1, 0, 0, #InputActions.Bindings * 26 + 4), gap = 2, layoutOrder = 51 })
end

local function renderControls()
	if not controlsList then
		return
	end
	UIKit.clearChildren(controlsList)
	local device = UIKit.device(ctx)
	for index, binding in ipairs(InputActions.Bindings) do
		local line = UIKit.statLine(controlsList, binding.title .. " - " .. binding.description, UIKit.glyph(binding.name, device), { name = "Control_" .. binding.name, layoutOrder = index, height = 24, bold = true })
		line.key.Size = UDim2.new(0.75, 0, 1, 0)
		line.value.Size = UDim2.new(0.25, -6, 1, 0)
	end
end

function SettingsMenu.Mount(parent: Instance, context: any): Frame
	ctx = context
	modal = UIKit.modal(parent, "Settings", {
		name = "SettingsMenu",
		onClose = function()
			local controller = ctx.controllers and ctx.controllers.UIController
			if controller and type(controller.CloseScreen) == "function" then
				controller.CloseScreen(SettingsMenu.Name)
			end
		end,
	})
	local list = UIKit.scrollList(modal.body, { name = "List", gap = 8 })
	local settings = currentSettings()

	widgets.cameraSensitivity = UIKit.slider(list, "Camera sensitivity", {
		name = "CameraSensitivity", min = 0.2, max = 3, step = 0.1, value = settings.cameraSensitivity, layoutOrder = 1,
		onChange = function(value)
			SettingsMenu.Apply("cameraSensitivity", value)
		end,
	})
	widgets.invertCameraY = UIKit.toggle(list, "Invert camera Y", settings.invertCameraY, function(value)
		SettingsMenu.Apply("invertCameraY", value)
	end, { name = "InvertCameraY", layoutOrder = 2 })
	widgets.autoRecenter = UIKit.toggle(list, "Auto-recenter camera behind the vehicle", settings.autoRecenter, function(value)
		SettingsMenu.Apply("autoRecenter", value)
	end, { name = "AutoRecenter", layoutOrder = 3 })
	widgets.reducedMotion = UIKit.toggle(list, "Reduced motion (no speed FOV, softer camera)", settings.reducedMotion, function(value)
		SettingsMenu.Apply("reducedMotion", value)
	end, { name = "ReducedMotion", layoutOrder = 4 })
	widgets.musicVolume = UIKit.slider(list, "Music volume", {
		name = "MusicVolume", min = 0, max = 1, step = 0.1, value = settings.musicVolume, layoutOrder = 5,
		format = function(v)
			return string.format("%d%%", math.floor(v * 100 + 0.5))
		end,
		onChange = function(value)
			SettingsMenu.Apply("musicVolume", value)
		end,
	})
	widgets.sfxVolume = UIKit.slider(list, "Sound effects volume", {
		name = "SfxVolume", min = 0, max = 1, step = 0.1, value = settings.sfxVolume, layoutOrder = 6,
		format = function(v)
			return string.format("%d%%", math.floor(v * 100 + 0.5))
		end,
		onChange = function(value)
			SettingsMenu.Apply("sfxVolume", value)
		end,
	})
	widgets.showMinimap = UIKit.toggle(list, "Show minimap", settings.showMinimap, function(value)
		SettingsMenu.Apply("showMinimap", value)
	end, { name = "ShowMinimap", layoutOrder = 7 })

	UIKit.divider(list, { layoutOrder = 10 })
	local recoverRow = UIKit.row(list, { name = "RecoverRow", size = UDim2.new(1, 0, 0, UIKit.MIN_HIT), layoutOrder = 11 })
	UIKit.label(recoverRow, "Stuck or fallen? Put your vehicle back on the road.", { size = UDim2.new(1, -190, 1, 0), layoutOrder = 1, maxSize = 16 })
	UIKit.button(recoverRow, "Recover vehicle", recoverVehicle, { name = "RecoverButton", size = UDim2.new(0, 180, 0, UIKit.MIN_HIT), layoutOrder = 2 })

	UIKit.divider(list, { layoutOrder = 12 })
	buildControls(list)
	return modal.frame
end

-- Refreshes widgets from ClientState.settings (without firing onChange).
function SettingsMenu.Update()
	if not modal then
		return
	end
	local settings = currentSettings()
	widgets.cameraSensitivity.set(settings.cameraSensitivity)
	widgets.invertCameraY.set(settings.invertCameraY)
	widgets.autoRecenter.set(settings.autoRecenter)
	widgets.reducedMotion.set(settings.reducedMotion)
	widgets.musicVolume.set(settings.musicVolume)
	widgets.sfxVolume.set(settings.sfxVolume)
	widgets.showMinimap.set(settings.showMinimap)
	renderControls()
end

function SettingsMenu.OnShow()
	SettingsMenu.Update()
end

function SettingsMenu.GetFrame(): Frame?
	return modal and modal.frame
end

function SettingsMenu.GetWidgets()
	return widgets
end

return SettingsMenu
