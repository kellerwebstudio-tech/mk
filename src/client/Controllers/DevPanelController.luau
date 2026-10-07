--!nonstrict
-- DevPanelController: STUDIO-ONLY developer panel (docs/DEVTOOLS.md). Dormant unless
-- RunService:IsStudio() is true AND the server created ReplicatedStorage.Remotes.DevCommand
-- (DevService, itself Studio-only); Init/Start return early otherwise and nothing is built.
-- In Studio: a small "DEV" button top-right plus F6 toggle a right-side column with cheats,
-- teleports, event triggers, a live handling tuner (HandlingOverrides) and a report dump.
-- The panel lives in its own ScreenGui "DDC_Dev" (DisplayOrder above the menus), never touches
-- UIController's screens and is NOT a modal: UIController.IsModalOpen stays false, so you can
-- tune while driving. Only the panel frame itself is Active (sinks clicks inside it); the rest of
-- the screen passes input through as usual.

local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Util = Shared:WaitForChild("Util")
local Definitions = Shared:WaitForChild("Definitions")
local MathUtil = require(Util:WaitForChild("MathUtil"))
local VehicleDefinitions = require(Definitions:WaitForChild("VehicleDefinitions"))

local ClientRoot = script.Parent.Parent
local UIKit = require(ClientRoot:WaitForChild("UI"):WaitForChild("UIKit"))
local HandlingOverrides = require(ClientRoot:WaitForChild("HandlingOverrides"))

local DevPanelController = {}

DevPanelController.REMOTE_NAME = "DevCommand"
DevPanelController.REMOTE_WAIT = 10
DevPanelController.GUI_NAME = "DDC_Dev"
DevPanelController.DISPLAY_ORDER = 50 -- above DDC_Menus (20)
DevPanelController.ACTION_NAME = "DDC_DevPanelToggle"
DevPanelController.TOGGLE_KEY = Enum.KeyCode.F6
DevPanelController.PANEL_WIDTH = 360
DevPanelController.BUTTON_HEIGHT = 32
DevPanelController.TEXT_SIZE = 14
DevPanelController.CONFIRM_WINDOW = 4
DevPanelController.TARGET_LIST_HEIGHT = 220
DevPanelController.VEHICLE_IDS = { "Bicycle", "Scooter", "Van" }
DevPanelController.NEIGHBORHOODS = { "Downtown", "Residential", "Industrial" }
DevPanelController.SECTIONS = { "Economy", "Vehicles", "Teleport", "Events", "Handling", "Report" }

-- Tunable handling keys with their stepper increments (and a floor where a zero would break the model).
DevPanelController.HANDLING_KEYS = {
	{ key = "maxSpeed", step = 2, min = 1 },
	{ key = "reverseSpeed", step = 1, min = 0 },
	{ key = "acceleration", step = 2, min = 0 },
	{ key = "brakeDeceleration", step = 2, min = 0 },
	{ key = "coastDeceleration", step = 1, min = 0 },
	{ key = "turnRate", step = 0.1, min = 0 },
	{ key = "turnFullSpeed", step = 1, min = 1 },
	{ key = "minTurnFactor", step = 0.05, min = 0 },
	{ key = "highSpeedTurnFactor", step = 0.05, min = 0 },
	{ key = "steerResponse", step = 1, min = 0 },
	{ key = "rideHeight", step = 0.1, min = 0.2 },
	{ key = "verticalGain", step = 1, min = 0 },
	{ key = "maxClimbRate", step = 5, min = 0 },
	{ key = "leanAngle", step = 1, min = 0 },
	{ key = "wheelSteerAngle", step = 2, min = 0 },
	{ key = "cameraDistance", step = 1, min = 1 },
	{ key = "cameraHeight", step = 0.5, min = 0 },
	{ key = "cameraLookAhead", step = 1, min = 0 },
	{ key = "fovSpeedBoost", step = 1, min = 0 },
	{ key = "maxSlopeDegrees", step = 2, min = 0 },
}

local ctx: any = nil
local studio = false
local remote: RemoteFunction? = nil
local enabled = false
local open = false
local gui: ScreenGui? = nil
local panel: Frame? = nil
local devButton: TextButton? = nil
local sections: { [string]: Frame } = {}
local steppers: { [string]: any } = {}
local targetList: ScrollingFrame? = nil
local handlingTabs: any = nil
local handlingVehicleId = "Bicycle"
local lastAutoVehicleId: string? = nil
local resetArmedUntil = 0
local resetButton: TextButton? = nil
local commandLog: { { command: string, args: any, result: any } } = {}

-------------------------------------------------------------------------------
-- Remote helpers
-------------------------------------------------------------------------------

local function toast(text: string, kind: string?)
	UIKit.notify(ctx, text, kind or "info", 3)
end

-- Synchronous invoke (yields on the remote). Returns a response table, never throws.
function DevPanelController.Invoke(command: string, args: any): any
	if not remote then
		return { ok = false, error = "Unavailable", message = "Dev commands are Studio-only" }
	end
	local okCall, result = pcall(function()
		return remote:InvokeServer(command, args)
	end)
	if not okCall then
		result = { ok = false, error = "Internal", message = tostring(result) }
	elseif type(result) ~= "table" then
		result = { ok = false, error = "Internal", message = "Bad response" }
	end
	table.insert(commandLog, { command = command, args = args, result = result })
	if #commandLog > 50 then
		table.remove(commandLog, 1)
	end
	return result
end

-- Fire-and-forget with a toast on failure (and an optional success callback / toast).
local function run(command: string, args: any, onOk: ((any) -> ())?, successText: string?)
	task.spawn(function()
		local result = DevPanelController.Invoke(command, args)
		if result.ok then
			if successText then
				toast(successText, "success")
			end
			if onOk then
				onOk(result)
			end
		else
			toast(command .. ": " .. tostring(result.message or result.error), "error")
		end
	end)
end

-------------------------------------------------------------------------------
-- UI helpers (compact variants of the UIKit widgets: 32 px rows, 14-16 px text)
-------------------------------------------------------------------------------

local function compact(instance: GuiObject)
	local sizeConstraint = instance:FindFirstChildOfClass("UISizeConstraint")
	if sizeConstraint then
		sizeConstraint.MinSize = Vector2.new(DevPanelController.BUTTON_HEIGHT, DevPanelController.BUTTON_HEIGHT)
	end
	local textConstraint = instance:FindFirstChildOfClass("UITextSizeConstraint")
	if textConstraint then
		textConstraint.MinTextSize = DevPanelController.TEXT_SIZE
		textConstraint.MaxTextSize = 16
	end
end

local function button(parent: Instance, text: string, onClick: () -> (), props: any): TextButton
	props = props or {}
	props.size = props.size or UDim2.new(1, 0, 0, DevPanelController.BUTTON_HEIGHT)
	props.minSize = DevPanelController.TEXT_SIZE
	props.maxSize = 16
	local created = UIKit.button(parent, text, onClick, props)
	compact(created)
	return created
end

local function label(parent: Instance, text: string, props: any): TextLabel
	props = props or {}
	props.size = props.size or UDim2.new(1, 0, 0, DevPanelController.BUTTON_HEIGHT)
	props.scaled = false
	props.textSize = props.textSize or DevPanelController.TEXT_SIZE
	return UIKit.label(parent, text, props)
end

local function contentWidth(): number
	return DevPanelController.PANEL_WIDTH - 24 -- panel padding + scrollbar
end

-- A row of equally wide buttons. specs: { {text, onClick, color?}, ... }
local function buttonRow(parent: Instance, specs: { any }, order: number): Frame
	local gap = 6
	local row = UIKit.row(parent, { name = "ButtonRow", size = UDim2.new(1, 0, 0, DevPanelController.BUTTON_HEIGHT), gap = gap, layoutOrder = order })
	local width = math.floor((contentWidth() - gap * (#specs - 1)) / #specs)
	for index, spec in ipairs(specs) do
		button(row, spec.text, spec.onClick, { name = spec.name or ("Button_" .. spec.text), size = UDim2.new(0, width, 0, DevPanelController.BUTTON_HEIGHT), color = spec.color, layoutOrder = index })
	end
	return row
end

local function section(parent: Instance, name: string, order: number): Frame
	local frame = UIKit.column(parent, { name = "Section_" .. name, size = UDim2.new(1, 0, 0, 0), gap = 4, layoutOrder = order, automaticSize = Enum.AutomaticSize.Y })
	label(frame, name, { name = "Header", bold = true, textSize = 16, color = UIKit.Theme.accent, layoutOrder = 0 })
	sections[name] = frame
	return frame
end

-------------------------------------------------------------------------------
-- Handling tuner
-------------------------------------------------------------------------------

local function cleanNumber(value: number): number
	return tonumber(string.format("%.6g", value)) or value
end

local function specFor(key: string): any
	for _, spec in ipairs(DevPanelController.HANDLING_KEYS) do
		if spec.key == key then
			return spec
		end
	end
	return nil
end

local function refreshStepper(key: string)
	local stepper = steppers[key]
	if not stepper then
		return
	end
	local handling = HandlingOverrides.get(handlingVehicleId)
	local value = handling[key]
	local overridden = HandlingOverrides.getOverrides(handlingVehicleId)[key] ~= nil
	stepper.box.Text = if type(value) == "number" then HandlingOverrides.formatNumber(value) else "?"
	stepper.nameLabel.Text = if overridden then key .. " *" else key
	stepper.nameLabel.TextColor3 = if overridden then UIKit.Theme.accent else UIKit.Theme.text
end

local function refreshAllSteppers()
	for key in pairs(steppers) do
		refreshStepper(key)
	end
end

-- Applies a tuned value for the current vehicle: HandlingOverrides for the client model and, for
-- maxSpeed, the server speed cap so the anti-cheat sampler tolerates the new top speed.
function DevPanelController.ApplyHandling(key: string, value: number)
	local spec = specFor(key)
	if not spec or type(value) ~= "number" or value ~= value then
		return
	end
	value = cleanNumber(math.max(value, spec.min or 0))
	local vehicleId = handlingVehicleId
	HandlingOverrides.set(vehicleId, key, value)
	if key == "maxSpeed" then
		local default = HandlingOverrides.getDefault(vehicleId, key) or 0
		run("SetSpeedCap", { vehicleId = vehicleId, maxSpeed = if value > default then value else 0 })
	end
	refreshStepper(key)
end

function DevPanelController.StepHandling(key: string, direction: number)
	local spec = specFor(key)
	if not spec then
		return
	end
	local current = HandlingOverrides.get(handlingVehicleId)[key] or 0
	local stepped = MathUtil.round(current + spec.step * direction, spec.step)
	DevPanelController.ApplyHandling(key, stepped)
end

function DevPanelController.SetHandlingVehicle(vehicleId: string)
	if not VehicleDefinitions.get(vehicleId) then
		return
	end
	handlingVehicleId = vehicleId
	if handlingTabs and handlingTabs.current ~= vehicleId then
		handlingTabs.select(vehicleId, true)
	end
	refreshAllSteppers()
end

function DevPanelController.GetHandlingVehicle(): string
	return handlingVehicleId
end

local function resetHandling()
	local vehicleId = handlingVehicleId
	HandlingOverrides.reset(vehicleId)
	run("SetSpeedCap", { vehicleId = vehicleId, maxSpeed = 0 })
	refreshAllSteppers()
	toast(vehicleId .. " handling reset to defaults", "info")
end

local function printSnippet()
	local text = HandlingOverrides.snippet(handlingVehicleId)
	print(string.format("-- %s handling (paste into VehicleDefinitions.Vehicles.%s)\n%s", handlingVehicleId, handlingVehicleId, text))
	toast("Snippet printed to Output", "success")
end

local function buildStepper(parent: Instance, spec: any, order: number)
	local gap = 4
	local small = 36
	local boxWidth = 72
	local row = UIKit.row(parent, { name = "Stepper_" .. spec.key, size = UDim2.new(1, 0, 0, DevPanelController.BUTTON_HEIGHT), gap = gap, layoutOrder = order })
	local minus = button(row, "-", function()
		DevPanelController.StepHandling(spec.key, -1)
	end, { name = "Minus", size = UDim2.new(0, small, 0, DevPanelController.BUTTON_HEIGHT), layoutOrder = 1 })
	local nameWidth = contentWidth() - small * 2 - boxWidth - gap * 3
	local nameLabel = label(row, spec.key, { name = "Name", size = UDim2.new(0, nameWidth, 0, DevPanelController.BUTTON_HEIGHT), layoutOrder = 2 })
	local box = Instance.new("TextBox")
	box.Name = "Value"
	box.Size = UDim2.new(0, boxWidth, 0, DevPanelController.BUTTON_HEIGHT)
	box.BackgroundColor3 = UIKit.Theme.panelAlt
	box.BorderSizePixel = 0
	box.TextColor3 = UIKit.Theme.text
	box.Font = UIKit.Theme.fontBold
	box.TextSize = DevPanelController.TEXT_SIZE
	box.TextScaled = false
	box.ClearTextOnFocus = false
	box.Text = ""
	box.LayoutOrder = 3
	UIKit.corner(box, 6)
	box.Parent = row
	box.FocusLost:Connect(function()
		local value = tonumber(box.Text)
		if value then
			DevPanelController.ApplyHandling(spec.key, value)
		else
			refreshStepper(spec.key)
		end
	end)
	local plus = button(row, "+", function()
		DevPanelController.StepHandling(spec.key, 1)
	end, { name = "Plus", size = UDim2.new(0, small, 0, DevPanelController.BUTTON_HEIGHT), layoutOrder = 4 })
	steppers[spec.key] = { row = row, minus = minus, plus = plus, box = box, nameLabel = nameLabel, spec = spec }
end

-------------------------------------------------------------------------------
-- Report
-------------------------------------------------------------------------------

local function formatReport(report: any): string
	local lines = {}
	table.insert(lines, "[DevService] Report")
	table.insert(lines, string.format("  cash %s  rep %s  deliveries %s  tutorial step %s%s",
		tostring(report.cash), tostring(report.reputation), tostring(report.deliveries), tostring(report.tutorialStep),
		if report.tutorialCompleted then " (completed)" else ""))
	local vehicle = report.vehicle or {}
	table.insert(lines, string.format("  vehicle: %s %s", tostring(vehicle.state or "none"), tostring(vehicle.vehicleId or "")))
	local orders = report.activeOrders or {}
	table.insert(lines, string.format("  active orders: %d", #orders))
	for _, order in ipairs(orders) do
		table.insert(lines, string.format("    - %s %s %s -> %s", tostring(order.id), tostring(order.state), tostring(order.business), tostring(order.destination)))
	end
	local contract = report.contract or {}
	table.insert(lines, string.format("  contract: %s %s %s", tostring(contract.status or "?"), tostring(contract.neighborhood or ""), tostring(contract.id or "")))
	local depot = report.depot or {}
	table.insert(lines, string.format("  depot: owned=%s plot=%s pending=%s", tostring(depot.owned), tostring(depot.plot or "-"), tostring(depot.pending or 0)))
	table.insert(lines, string.format("  anti-cheat strikes: %s", tostring(report.antiCheatStrikes or 0)))
	return table.concat(lines, "\n")
end

DevPanelController.formatReport = formatReport

local function printReport()
	run("Report", nil, function(report)
		print(formatReport(report))
		toast("Report printed to Output", "success")
	end)
end

-------------------------------------------------------------------------------
-- Teleport targets
-------------------------------------------------------------------------------

function DevPanelController.RefreshTargets()
	if not targetList then
		return
	end
	run("ListTargets", nil, function(result)
		if not targetList then
			return
		end
		UIKit.clearChildren(targetList)
		local targets = type(result.targets) == "table" and result.targets or {}
		for index, target in ipairs(targets) do
			local text = tostring(target.label or target.id)
			if target.kind == "destination" then
				text = "Deliver: " .. text
			elseif target.kind == "business" then
				text = "Pickup: " .. text
			end
			button(targetList, text, function()
				run("Teleport", { target = target.id }, nil, "Teleported to " .. tostring(target.label or target.id))
			end, { name = "Target_" .. tostring(target.id), size = UDim2.new(1, -8, 0, DevPanelController.BUTTON_HEIGHT), layoutOrder = index })
		end
		if #targets == 0 then
			label(targetList, "No targets (world not built)", { name = "Empty" })
		end
	end)
end

-------------------------------------------------------------------------------
-- Panel
-------------------------------------------------------------------------------

local function armReset()
	local now = os.clock()
	if now < resetArmedUntil then
		resetArmedUntil = 0
		if resetButton then
			resetButton.Text = "Reset profile"
		end
		run("ResetProfile", nil, nil, "Profile reset to defaults")
		return
	end
	resetArmedUntil = now + DevPanelController.CONFIRM_WINDOW
	if resetButton then
		resetButton.Text = "Tap again to confirm"
		task.delay(DevPanelController.CONFIRM_WINDOW, function()
			if resetButton and os.clock() >= resetArmedUntil then
				resetButton.Text = "Reset profile"
			end
		end)
	end
end

local function buildEconomy(parent: Instance, order: number)
	local frame = section(parent, "Economy", order)
	buttonRow(frame, {
		{ text = "+$1k", onClick = function() run("GrantCash", { amount = 1000 }, nil, "+$1,000") end },
		{ text = "+$10k", onClick = function() run("GrantCash", { amount = 10000 }, nil, "+$10,000") end },
		{ text = "+100 Rep", onClick = function() run("GrantRep", { amount = 100 }, nil, "+100 Rep") end },
		{ text = "+1000 Rep", onClick = function() run("GrantRep", { amount = 1000 }, nil, "+1,000 Rep") end },
	}, 1)
	buttonRow(frame, {
		{ text = "Unlock all", onClick = function() run("UnlockAll", nil, nil, "Everything unlocked") end },
		{ text = "Skip tutorial", onClick = function() run("SkipTutorial", nil, nil, "Tutorial completed") end },
	}, 2)
	local row = buttonRow(frame, {
		{ text = "Reset profile", name = "Button_ResetProfile", onClick = armReset, color = UIKit.Theme.error },
	}, 3)
	resetButton = row:FindFirstChild("Button_ResetProfile") :: TextButton
end

local function buildVehicles(parent: Instance, order: number)
	local frame = section(parent, "Vehicles", order)
	label(frame, "Own + spawn:", { layoutOrder = 1 })
	local specs = {}
	for _, vehicleId in ipairs(DevPanelController.VEHICLE_IDS) do
		table.insert(specs, { text = vehicleId, name = "Button_Own_" .. vehicleId, onClick = function()
			run("OwnVehicle", { vehicleId = vehicleId }, nil, vehicleId .. " spawned")
		end })
	end
	buttonRow(frame, specs, 2)
	buttonRow(frame, {
		{ text = "Despawn", onClick = function() run("Despawn", nil, nil, "Vehicle despawned") end },
		{ text = "Recover", onClick = function() run("Recover", nil, nil, "Vehicle recovered") end },
	}, 3)
end

local function buildTeleport(parent: Instance, order: number)
	local frame = section(parent, "Teleport", order)
	buttonRow(frame, {
		{ text = "Refresh targets", onClick = DevPanelController.RefreshTargets },
	}, 1)
	local list = UIKit.scrollList(frame, { name = "Targets", size = UDim2.new(1, 0, 0, DevPanelController.TARGET_LIST_HEIGHT), gap = 4, layoutOrder = 2, transparency = 0.6 })
	UIKit.corner(list, 8)
	targetList = list
end

local function buildEvents(parent: Instance, order: number)
	local frame = section(parent, "Events", order)
	label(frame, "Open Lunch Rush:", { layoutOrder = 1 })
	local specs = {}
	for _, neighborhood in ipairs(DevPanelController.NEIGHBORHOODS) do
		table.insert(specs, { text = neighborhood, name = "Button_Rush_" .. neighborhood, onClick = function()
			run("OpenLunchRush", { neighborhood = neighborhood }, nil, "Lunch Rush opened in " .. neighborhood)
		end })
	end
	buttonRow(frame, specs, 2)
	buttonRow(frame, {
		{ text = "Finish driver assignments", onClick = function()
			run("FinishDrivers", nil, function(result)
				toast(string.format("Drivers: %d forced, %d completed", tonumber(result.forced) or 0, tonumber(result.completed) or 0), "success")
			end)
		end },
	}, 3)
	buttonRow(frame, {
		{ text = "Fill order board", onClick = function()
			run("FillBoard", nil, function(result)
				toast(result.message or string.format("Board: +%d (%d available)", tonumber(result.added) or 0, tonumber(result.available) or 0), if result.message then "warning" else "success")
			end)
		end },
		{ text = "Ready my orders", onClick = function()
			run("ReadyOrders", nil, function(result)
				toast(string.format("%d order(s) ready for pickup", tonumber(result.readied) or 0), "success")
			end)
		end },
	}, 4)
end

local function buildHandling(parent: Instance, order: number)
	local frame = section(parent, "Handling", order)
	handlingTabs = UIKit.tabs(frame, DevPanelController.VEHICLE_IDS, function(name)
		DevPanelController.SetHandlingVehicle(name)
	end, { name = "VehicleTabs", tabWidth = math.floor((contentWidth() - 12) / 3), layoutOrder = 1 })
	for _, tab in pairs(handlingTabs.buttons) do
		tab.Size = UDim2.new(0, math.floor((contentWidth() - 12) / 3), 0, DevPanelController.BUTTON_HEIGHT)
		compact(tab)
	end
	handlingTabs.frame.Size = UDim2.new(1, 0, 0, DevPanelController.BUTTON_HEIGHT)
	for index, spec in ipairs(DevPanelController.HANDLING_KEYS) do
		buildStepper(frame, spec, 1 + index)
	end
	buttonRow(frame, {
		{ text = "Reset to defaults", onClick = resetHandling },
		{ text = "Print snippet", onClick = printSnippet },
	}, 2 + #DevPanelController.HANDLING_KEYS)
	handlingTabs.select(handlingVehicleId, true)
	refreshAllSteppers()
end

local function buildReport(parent: Instance, order: number)
	local frame = section(parent, "Report", order)
	buttonRow(frame, {
		{ text = "Print report to Output", onClick = printReport },
	}, 1)
end

local function buildPanel()
	local screen = UIKit.makeScreenGui(DevPanelController.GUI_NAME, DevPanelController.DISPLAY_ORDER)
	gui = screen
	-- IgnoreGuiInset false + CoreUISafeInsets (UIKit default): nothing here captures input unless
	-- it is a GuiObject with Active = true, so an open panel only eats clicks inside its frame.

	devButton = button(screen, "DEV", function()
		DevPanelController.Toggle()
	end, { name = "DevButton", size = UDim2.new(0, 56, 0, DevPanelController.BUTTON_HEIGHT), position = UDim2.new(1, -8, 0, 8), anchor = Vector2.new(1, 0), color = UIKit.Theme.accent, textColor = UIKit.Theme.textOnAccent })

	local root = UIKit.panel(screen, {
		name = "Panel",
		size = UDim2.new(0, DevPanelController.PANEL_WIDTH, 1, -(DevPanelController.BUTTON_HEIGHT + 24)),
		position = UDim2.new(1, -8, 0, DevPanelController.BUTTON_HEIGHT + 16),
		anchor = Vector2.new(1, 0),
		transparency = 0.08,
		stroke = true,
		padding = 8,
		visible = false,
	})
	root.Active = true
	panel = root

	local header = UIKit.row(root, { name = "Header", size = UDim2.new(1, 0, 0, DevPanelController.BUTTON_HEIGHT), gap = 6 })
	label(header, "Dev panel (Studio only)  F6", { name = "Title", bold = true, textSize = 16, size = UDim2.new(1, -60, 0, DevPanelController.BUTTON_HEIGHT) })
	button(header, "X", function()
		DevPanelController.SetOpen(false)
	end, { name = "Close", size = UDim2.new(0, 48, 0, DevPanelController.BUTTON_HEIGHT) })

	local list = UIKit.scrollList(root, { name = "Sections", size = UDim2.new(1, 0, 1, -(DevPanelController.BUTTON_HEIGHT + 8)), position = UDim2.new(0, 0, 0, DevPanelController.BUTTON_HEIGHT + 8), gap = 10 })

	local vehicle = ctx.state.get("vehicle")
	if vehicle and type(vehicle.vehicleId) == "string" and VehicleDefinitions.get(vehicle.vehicleId) then
		handlingVehicleId = vehicle.vehicleId
		lastAutoVehicleId = vehicle.vehicleId
	end

	buildEconomy(list, 1)
	buildVehicles(list, 2)
	buildTeleport(list, 3)
	buildEvents(list, 4)
	buildHandling(list, 5)
	buildReport(list, 6)

	DevPanelController.RefreshTargets()
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

function DevPanelController.IsEnabled(): boolean
	return enabled
end

function DevPanelController.IsOpen(): boolean
	return open
end

function DevPanelController.SetOpen(value: boolean)
	if not enabled or not panel then
		return
	end
	open = value == true
	panel.Visible = open
end

function DevPanelController.Toggle()
	DevPanelController.SetOpen(not open)
end

function DevPanelController.GetGui(): ScreenGui?
	return gui
end

function DevPanelController.GetPanel(): Frame?
	return panel
end

function DevPanelController.GetSection(name: string): Frame?
	return sections[name]
end

function DevPanelController.GetStepper(key: string): any
	return steppers[key]
end

function DevPanelController.GetTargetList(): ScrollingFrame?
	return targetList
end

function DevPanelController.GetCommandLog()
	return commandLog
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

local function enable(found: RemoteFunction)
	remote = found
	enabled = true
	local okBuild, err = pcall(buildPanel)
	if not okBuild then
		warn("[DevPanelController] panel build failed: " .. tostring(err))
		return
	end
	pcall(function()
		ContextActionService:BindAction(DevPanelController.ACTION_NAME, function(_, inputState)
			if inputState == Enum.UserInputState.Begin then
				DevPanelController.Toggle()
			end
			return Enum.ContextActionResult.Sink
		end, false, DevPanelController.TOGGLE_KEY)
	end)
	ctx.state.onChange("vehicle", function(vehicle)
		local vehicleId = vehicle and vehicle.vehicleId
		if type(vehicleId) == "string" and vehicleId ~= lastAutoVehicleId and VehicleDefinitions.get(vehicleId) then
			lastAutoVehicleId = vehicleId
			DevPanelController.SetHandlingVehicle(vehicleId)
		end
	end)
	HandlingOverrides.Changed:Connect(function(vehicleId)
		if vehicleId == handlingVehicleId then
			refreshAllSteppers()
		end
	end)
	print("[DevPanelController] Studio dev panel ready (F6 or the DEV button)")
end

function DevPanelController.Init(context)
	ctx = context
	studio = RunService:IsStudio() == true
	enabled = false
	remote = nil
	if not studio then
		return
	end
end

function DevPanelController.Start()
	if not studio then
		return
	end
	task.spawn(function()
		local folder = ReplicatedStorage:WaitForChild("Remotes", DevPanelController.REMOTE_WAIT)
		local found = folder and folder:WaitForChild(DevPanelController.REMOTE_NAME, DevPanelController.REMOTE_WAIT)
		if not found or not found:IsA("RemoteFunction") then
			return -- no DevService on this server: stay dormant
		end
		enable(found)
	end)
end

return DevPanelController
