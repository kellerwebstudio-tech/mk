--!nonstrict
-- UIController: owns the two ScreenGuis ("DDC_HUD" for the always-visible layer, "DDC_Menus" for
-- modal screens), the screen registry, the interaction prompt, toasts, results, tutorial banner,
-- minimap and vehicle readout. Other controllers call the public interface documented in
-- docs/ARCHITECTURE.md section 7.6; the UI reads ClientState directly and calls remotes itself.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Util = Shared:WaitForChild("Util")
local Signal = require(Util:WaitForChild("Signal"))
local InputActions = require(Shared:WaitForChild("InputActions"))

local ClientRoot = script.Parent.Parent
local UIFolder = ClientRoot:WaitForChild("UI")
local UIKit = require(UIFolder:WaitForChild("UIKit"))
local HUD = require(UIFolder:WaitForChild("HUD"))
local OrderBoard = require(UIFolder:WaitForChild("OrderBoard"))
local ActiveDeliveries = require(UIFolder:WaitForChild("ActiveDeliveries"))
local ShopMenu = require(UIFolder:WaitForChild("ShopMenu"))
local UpgradeMenu = require(UIFolder:WaitForChild("UpgradeMenu"))
local DepotMenu = require(UIFolder:WaitForChild("DepotMenu"))
local SettingsMenu = require(UIFolder:WaitForChild("SettingsMenu"))
local ResultsToast = require(UIFolder:WaitForChild("ResultsToast"))
local Notifications = require(UIFolder:WaitForChild("Notifications"))
local TutorialBanner = require(UIFolder:WaitForChild("TutorialBanner"))
local Minimap = require(UIFolder:WaitForChild("Minimap"))

local UIController = {}

UIController.HUD_DISPLAY_ORDER = 10
UIController.MENU_DISPLAY_ORDER = 20
UIController.TICK_INTERVAL = 1

UIController.ModalChanged = Signal.new() -- (isOpen: boolean)
UIController.TutorialContinue = Signal.new() -- ()
UIController.PromptActivated = Signal.new() -- (actionName: string)

local ctx = nil
local hudGui: any = nil
local menuGui: any = nil
local scrim: any = nil
local topCenter: any = nil
local prompt: any = nil
local lastPromptSpec = nil
local currentScreen: string? = nil
local screens: { [string]: any } = {}
local started = false

-------------------------------------------------------------------------------
-- Menu hub screen (buttons to every other screen + vehicle actions + depots list)
-------------------------------------------------------------------------------

local MenuHub = { Name = "Menu" }
local hubRefs: { [string]: any } = {}
local hubBusy = false

local function vehicleActionText(): (string, string)
	local vehicle = ctx.state.get("vehicle")
	local profile = ctx.state.get("profile")
	if vehicle and vehicle.state ~= nil and vehicle.state ~= "Despawning" then
		return "Despawn vehicle", "DespawnVehicle"
	end
	local equipped = profile and profile.equippedVehicle or "Bicycle"
	return string.format("Spawn vehicle (%s)", tostring(equipped)), "SpawnVehicle"
end

local function runHubAction(remoteName: string, argument: any)
	if hubBusy then
		return
	end
	hubBusy = true
	MenuHub.Update()
	task.spawn(function()
		local result = UIKit.invoke(ctx, remoteName, argument)
		hubBusy = false
		if not result.ok then
			UIKit.notify(ctx, tostring(result.message or result.error or "Request failed"), "error", 4)
		elseif remoteName == "RecoverVehicle" then
			UIKit.notify(ctx, "Vehicle recovered to the road.", "success", 3)
		end
		MenuHub.Update()
	end)
end

function MenuHub.Mount(parent: Instance, context: any): Frame
	local modal = UIKit.modal(parent, "Menu", {
		name = "MenuHub",
		maxSize = Vector2.new(620, 620),
		onClose = function()
			UIController.CloseScreen("Menu")
		end,
	})
	hubRefs.modal = modal
	local list = UIKit.scrollList(modal.body, { name = "List", gap = 8 })
	hubRefs.list = list
	local entries = {
		{ "Orders", "Order board and Lunch Rush" },
		{ "Deliveries", "Active deliveries and stop order" },
		{ "Shop", "Vehicles and looks" },
		{ "Upgrades", "Baskets, bags, gears, shelving" },
		{ "Depot", "Your depot and NPC drivers" },
		{ "Settings", "Camera, audio, controls" },
	}
	for index, entry in ipairs(entries) do
		local row = UIKit.row(list, { name = "Entry_" .. entry[1], size = UDim2.new(1, -8, 0, UIKit.MIN_HIT), layoutOrder = index, gap = 10 })
		UIKit.primaryButton(row, entry[1], function()
			UIController.OpenScreen(entry[1])
		end, { name = "Open" .. entry[1], size = UDim2.new(0, 170, 0, UIKit.MIN_HIT), layoutOrder = 1 })
		UIKit.label(row, entry[2], { name = "Description", color = UIKit.Theme.textDim, size = UDim2.new(1, -180, 1, 0), layoutOrder = 2, maxSize = 15 })
	end
	UIKit.divider(list, { layoutOrder = 10, size = UDim2.new(1, -8, 0, 1) })
	local vehicleRow = UIKit.row(list, { name = "VehicleRow", size = UDim2.new(1, -8, 0, UIKit.MIN_HIT), layoutOrder = 11, gap = 10 })
	hubRefs.vehicleButton = UIKit.button(vehicleRow, "Spawn vehicle", function()
		local _, remoteName = vehicleActionText()
		local profile = ctx.state.get("profile")
		runHubAction(remoteName, if remoteName == "SpawnVehicle" then (profile and profile.equippedVehicle or "Bicycle") else nil)
	end, { name = "VehicleButton", size = UDim2.new(0, 220, 0, UIKit.MIN_HIT), layoutOrder = 1 })
	hubRefs.recoverButton = UIKit.button(vehicleRow, "Recover vehicle", function()
		runHubAction("RecoverVehicle", nil)
	end, { name = "RecoverButton", size = UDim2.new(0, 170, 0, UIKit.MIN_HIT), layoutOrder = 2 })
	hubRefs.depotsTitle = UIKit.label(list, "Depots in this server", { name = "DepotsTitle", bold = true, size = UDim2.new(1, -8, 0, 26), maxSize = 18, layoutOrder = 20, visible = false })
	hubRefs.depots = UIKit.column(list, { name = "Depots", size = UDim2.new(1, -8, 0, 0), gap = 2, layoutOrder = 21, automaticSize = Enum.AutomaticSize.Y })
	return modal.frame
end

function MenuHub.Update()
	if not hubRefs.modal then
		return
	end
	local text = vehicleActionText()
	hubRefs.vehicleButton.Text = if hubBusy then "..." else text
	UIKit.setButtonEnabled(hubRefs.vehicleButton, not hubBusy)
	local vehicle = ctx.state.get("vehicle")
	local canRecover = vehicle ~= nil and (vehicle.state == "Driving" or vehicle.state == "Parked")
	UIKit.setButtonEnabled(hubRefs.recoverButton, canRecover and not hubBusy)

	UIKit.clearChildren(hubRefs.depots)
	local depot = ctx.state.get("depot")
	local plots = type(depot) == "table" and depot.publicPlots
	local shown = 0
	if type(plots) == "table" then
		for index, plot in ipairs(plots) do
			local owned = (tonumber(plot.ownerUserId) or 0) ~= 0
			local text2 = if owned then string.format("Plot %s  -  %s", tostring(plot.plotId), tostring(plot.ownerName)) else string.format("Plot %s  -  for sale", tostring(plot.plotId))
			UIKit.label(hubRefs.depots, text2, { name = "Plot_" .. tostring(plot.plotId), color = if owned then UIKit.Theme.text else UIKit.Theme.textDim, size = UDim2.new(1, 0, 0, 22), maxSize = 15, layoutOrder = index })
			shown += 1
		end
	end
	hubRefs.depotsTitle.Visible = shown > 0
	hubRefs.depots.Size = UDim2.new(1, -8, 0, shown * 24)
end

function MenuHub.OnShow()
	MenuHub.Update()
end

function MenuHub.GetFrame(): Frame?
	return hubRefs.modal and hubRefs.modal.frame
end

-------------------------------------------------------------------------------
-- Screen registry
-------------------------------------------------------------------------------

local SCREEN_MODULES = {
	Orders = OrderBoard,
	Deliveries = ActiveDeliveries,
	Shop = ShopMenu,
	Upgrades = UpgradeMenu,
	Depot = DepotMenu,
	Settings = SettingsMenu,
	Menu = MenuHub,
}

local function screenFrame(name: string): Frame?
	local entry = screens[name]
	return entry and entry.frame
end

local function callScreen(name: string, method: string, ...)
	local entry = screens[name]
	local module = entry and entry.module
	if module and type(module[method]) == "function" then
		local ok, err = pcall(module[method], ...)
		if not ok then
			warn(string.format("[UIController] %s.%s failed: %s", name, method, tostring(err)))
		end
	end
end

local function setModalState(open: boolean)
	if scrim then
		scrim.Visible = open
	end
	HUD.SetDimmed(open)
	if not open then
		UIKit.clearFocus()
	end
end

function UIController.OpenScreen(name: string)
	local entry = screens[name]
	if not entry then
		warn("[UIController] unknown screen " .. tostring(name))
		return
	end
	local wasOpen = currentScreen ~= nil
	if currentScreen and currentScreen ~= name then
		local previous = screenFrame(currentScreen)
		callScreen(currentScreen, "OnHide")
		if previous then
			previous.Visible = false
		end
	end
	currentScreen = name
	entry.frame.Visible = true
	callScreen(name, "OnShow")
	UIKit.focus(entry.frame)
	if not wasOpen then
		setModalState(true)
		UIController.ModalChanged:Fire(true)
	end
end

function UIController.CloseScreen(name: string?)
	if not currentScreen then
		return
	end
	if name and name ~= currentScreen then
		return
	end
	local closing = currentScreen
	local frame = screenFrame(closing)
	callScreen(closing, "OnHide")
	if frame then
		frame.Visible = false
	end
	currentScreen = nil
	setModalState(false)
	UIController.ModalChanged:Fire(false)
end

function UIController.ToggleScreen(name: string)
	if currentScreen == name then
		UIController.CloseScreen(name)
	else
		UIController.OpenScreen(name)
	end
end

function UIController.IsModalOpen(): boolean
	return currentScreen ~= nil
end

function UIController.GetCurrentScreen(): string?
	return currentScreen
end

-- Opens the Depot screen for a plot (own plot or a visit to someone else's).
function UIController.OpenDepotFor(plotId: string?)
	if type(DepotMenu.SetVisitingPlot) == "function" then
		DepotMenu.SetVisitingPlot(plotId)
	end
	UIController.OpenScreen("Depot")
end

-------------------------------------------------------------------------------
-- HUD layer API
-------------------------------------------------------------------------------

function UIController.ShowPrompt(spec: any)
	if type(spec) ~= "table" or not hudGui then
		return
	end
	UIController.HidePrompt()
	lastPromptSpec = spec
	prompt = UIKit.promptFrame(hudGui, spec, UIKit.device(ctx), function(actionName)
		UIController.PromptActivated:Fire(actionName)
	end)
end

function UIController.HidePrompt()
	lastPromptSpec = nil
	if prompt then
		prompt:Destroy()
		prompt = nil
	end
end

function UIController.GetPrompt(): TextButton?
	return prompt
end

function UIController.Notify(text: string, kind: string?, duration: number?)
	if type(text) ~= "string" then
		return
	end
	Notifications.Push(text, kind or "info", duration)
end

function UIController.SetNavigation(nav: any)
	HUD.SetNavigation(nav)
end

function UIController.SetMinimap(data: any)
	Minimap.Update(data)
end

function UIController.ShowResults(payout: any, order: any)
	ResultsToast.Show(payout, order)
end

function UIController.SetTutorial(spec: any)
	TutorialBanner.Set(spec)
end

function UIController.SetVehicleHud(data: any)
	HUD.SetVehicleHud(data)
end

function UIController.GetScreenGui(): ScreenGui
	return hudGui
end

function UIController.GetMenuGui(): ScreenGui
	return menuGui
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

local function applyDevice(device: string)
	UIKit.setTouch(device == "Touch")
	UIKit.setGamepad(device == "Gamepad")
	if hudGui then
		UIKit.updateScale(hudGui)
	end
	if menuGui then
		UIKit.updateScale(menuGui)
	end
	HUD.Relayout()
	if lastPromptSpec then
		UIController.ShowPrompt(lastPromptSpec)
	end
	if currentScreen == "Settings" then
		callScreen("Settings", "Update")
	end
end

function UIController.Init(context)
	ctx = context
	ctx.controllers = ctx.controllers or {}
	ctx.controllers.UIController = UIController

	local parent = UIKit.playerGui()
	hudGui = UIKit.makeScreenGui("DDC_HUD", UIController.HUD_DISPLAY_ORDER, parent)
	menuGui = UIKit.makeScreenGui("DDC_Menus", UIController.MENU_DISPLAY_ORDER, parent)
	menuGui.Enabled = true

	-- HUD layer.
	HUD.Mount(hudGui, ctx)
	topCenter = UIKit.panel(hudGui, { name = "TopCenter", transparency = 1, corner = false, size = UDim2.new(0, 460, 0, 420), position = UDim2.new(0.5, 0, 0, 8), anchor = Vector2.new(0.5, 0), zindex = 4 })
	UIKit.listLayout(topCenter, "Vertical", 8, { halign = "Center" })
	-- The top-centre stack shrinks between the wallet (left) and capacity (right) panels on phones.
	local function relayoutTopCenter()
		local width = UIKit.contentWidth(hudGui)
		topCenter.Size = UDim2.new(0, math.clamp(width - 2 * 240 - 16, 280, 460), 0, 420)
	end
	relayoutTopCenter()
	pcall(function()
		hudGui:GetPropertyChangedSignal("AbsoluteSize"):Connect(relayoutTopCenter)
	end)
	TutorialBanner.Mount(topCenter, ctx)
	ResultsToast.Mount(topCenter, ctx)
	Notifications.Mount(hudGui, ctx)
	Minimap.Mount(hudGui, ctx)

	-- Modal layer: scrim + screens.
	scrim = UIKit.panel(menuGui, { name = "Scrim", color = UIKit.Theme.scrim, transparency = 0.45, corner = false, size = UDim2.fromScale(1, 1), visible = false, zindex = 1 })
	scrim.Active = true
	for name, module in pairs(SCREEN_MODULES) do
		local ok, frame = pcall(module.Mount, menuGui, ctx)
		if ok and typeof(frame) == "Instance" then
			(frame :: any).Visible = false
			screens[name] = { module = module, frame = frame }
		else
			warn(string.format("[UIController] failed to mount screen %s: %s", name, tostring(frame)))
		end
	end

	TutorialBanner.Continue:Connect(function()
		UIController.TutorialContinue:Fire()
	end)
end

local function connectState()
	local state = ctx.state
	local function refresh(key: string)
		return function()
			if not started then
				return
			end
			if key == "profile" or key == "orders" or key == "tutorial" then
				HUD.Update()
			end
			if currentScreen then
				callScreen(currentScreen, "Update")
			end
		end
	end
	for _, key in ipairs({ "profile", "orders", "contract", "depot", "tutorial", "vehicle", "stopOrder" }) do
		state.onChange(key, refresh(key))
	end
	state.onChange("settings", function(settings)
		local show = true
		if type(settings) == "table" and settings.showMinimap == false then
			show = false
		end
		Minimap.SetVisible(show)
		if started and currentScreen == "Settings" then
			callScreen("Settings", "Update")
		end
	end)
	state.onChange("device", function(device)
		if type(device) == "string" then
			applyDevice(device)
		end
	end)
end

local function connectInput()
	local input = ctx.controllers and ctx.controllers.InputController
	if input and input.Pressed and type(input.Pressed.Connect) == "function" then
		input.Pressed:Connect(function(actionName)
			if actionName == InputActions.Names.ToggleOrders then
				UIController.ToggleScreen("Orders")
			elseif actionName == InputActions.Names.ToggleMenu then
				UIController.ToggleScreen("Menu")
			end
		end)
	end
	-- Gamepad B / Escape close the open modal.
	UserInputService.InputBegan:Connect(function(inputObject, gameProcessed)
		if not currentScreen then
			return
		end
		local key = inputObject.KeyCode
		if key == Enum.KeyCode.ButtonB or key == Enum.KeyCode.Escape then
			UIController.CloseScreen()
		end
	end)
end

function UIController.Start()
	started = true
	connectState()
	connectInput()
	HUD.Update()

	-- Once-per-second ticks for countdowns, distances and progress bars.
	task.spawn(function()
		while hudGui and hudGui.Parent do
			task.wait(UIController.TICK_INTERVAL)
			local ok, err = pcall(function()
				HUD.Tick()
				if currentScreen then
					callScreen(currentScreen, "Tick")
				end
			end)
			if not ok then
				warn("[UIController] tick failed: " .. tostring(err))
			end
		end
	end)
end

return UIController
