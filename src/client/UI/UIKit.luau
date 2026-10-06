--!nonstrict
-- UIKit: theme tokens, programmatic widget builders, responsive scaling, formatting and glyph
-- helpers shared by every UI module. Everything is built from plain Instances (no assets), so the
-- offline harness can mount every screen. Every status is conveyed with text or glyphs as well as
-- colour.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Util = Shared:WaitForChild("Util")
local Definitions = Shared:WaitForChild("Definitions")
local MathUtil = require(Util:WaitForChild("MathUtil"))
local InputActions = require(Shared:WaitForChild("InputActions"))
local BusinessDefinitions = require(Definitions:WaitForChild("BusinessDefinitions"))

local UIKit = {}

-------------------------------------------------------------------------------
-- Theme
-------------------------------------------------------------------------------

UIKit.Theme = {
	panel = Color3.fromRGB(24, 26, 32),
	panelAlt = Color3.fromRGB(36, 39, 48),
	panelLight = Color3.fromRGB(48, 52, 64),
	stroke = Color3.fromRGB(70, 74, 88),
	text = Color3.fromRGB(245, 245, 245),
	textDim = Color3.fromRGB(178, 184, 196),
	textOnAccent = Color3.fromRGB(20, 16, 10),
	accent = Color3.fromRGB(250, 140, 40),
	accentDark = Color3.fromRGB(200, 105, 25),
	success = Color3.fromRGB(80, 200, 120),
	warning = Color3.fromRGB(240, 180, 60),
	error = Color3.fromRGB(230, 80, 70),
	info = Color3.fromRGB(90, 160, 230),
	pickup = Color3.fromRGB(90, 170, 240),
	deliver = Color3.fromRGB(250, 140, 40),
	scrim = Color3.fromRGB(0, 0, 0),
	fontBold = Enum.Font.GothamBold,
	font = Enum.Font.Gotham,
}

UIKit.MIN_TEXT = 14
UIKit.MAX_TEXT = 28
UIKit.MIN_HIT = 44 -- minimum touch hit size in pixels
UIKit.MODAL_CLOSE_WIDTH = 110
UIKit.BASE_VIEWPORT = Vector2.new(1280, 720)
UIKit.SCALE_MIN = 0.75
UIKit.SCALE_MAX = 1.25
UIKit.TOUCH_SCALE_BOOST = 1.15

local KIND_COLORS = {
	info = UIKit.Theme.info,
	success = UIKit.Theme.success,
	warning = UIKit.Theme.warning,
	error = UIKit.Theme.error,
}

-- Text prefixes so a status never relies on colour alone.
UIKit.KindPrefix = {
	info = "i",
	success = "OK",
	warning = "!",
	error = "X",
}

function UIKit.kindColor(kind: string?): Color3
	return KIND_COLORS[kind or "info"] or UIKit.Theme.info
end

-- {r, g, b} (0-255) or {r=, g=, b=} (0-1) tables to Color3.
function UIKit.rgb(color: any, fallback: Color3?): Color3
	if typeof(color) == "Color3" then
		return color
	end
	if type(color) == "table" then
		if type(color[1]) == "number" then
			return Color3.fromRGB(color[1], color[2] or 0, color[3] or 0)
		elseif type(color.r) == "number" then
			return Color3.new(color.r, color.g or 0, color.b or 0)
		end
	end
	return fallback or UIKit.Theme.accent
end

-------------------------------------------------------------------------------
-- Formatting
-------------------------------------------------------------------------------

function UIKit.formatCash(amount: number?): string
	return MathUtil.formatCash(tonumber(amount) or 0)
end

function UIKit.formatTime(seconds: number?): string
	return MathUtil.formatTime(tonumber(seconds) or 0)
end

function UIKit.formatDistance(studs: number?): string
	return MathUtil.formatDistance(tonumber(studs) or 0) .. " studs"
end

-- Integer with thousands separators ("1,200").
function UIKit.formatNumber(value: number?): string
	local rounded = math.floor((tonumber(value) or 0) + 0.5)
	local text = tostring(math.abs(rounded))
	local formatted = text:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if formatted:sub(1, 1) == "," then
		formatted = formatted:sub(2)
	end
	return (if rounded < 0 then "-" else "") .. formatted
end

-- Distance without the unit suffix (compact HUD readouts).
function UIKit.formatStuds(studs: number?): string
	return MathUtil.formatDistance(tonumber(studs) or 0)
end

function UIKit.formatUnits(units: number?): string
	local n = tonumber(units) or 0
	return string.format("%d unit%s", n, n == 1 and "" or "s")
end

function UIKit.formatSeconds(seconds: number?): string
	local n = math.max(0, math.floor((tonumber(seconds) or 0) + 0.5))
	if n >= 60 then
		return MathUtil.formatTime(n)
	end
	return tostring(n) .. "s"
end

-- Glyph for an action on a device family ("Keyboard" | "Gamepad" | "Touch").
function UIKit.glyph(actionName: string, device: string?): string
	local family = InputActions.Glyphs[device or "Keyboard"] or InputActions.Glyphs.Keyboard
	return family[actionName] or InputActions.Glyphs.Keyboard[actionName] or "?"
end

-- Human title of an action ("Interact", "Ride", ...).
function UIKit.actionTitle(actionName: string): string
	for _, binding in ipairs(InputActions.Bindings) do
		if binding.name == actionName then
			return binding.title
		end
	end
	return actionName
end

-------------------------------------------------------------------------------
-- Definitions lookups (names and addresses used across screens)
-------------------------------------------------------------------------------

local function findById(list: any, id: string): any
	if type(list) ~= "table" then
		return nil
	end
	for _, entry in ipairs(list) do
		if type(entry) == "table" and entry.id == id then
			return entry
		end
	end
	return nil
end

function UIKit.businessDef(businessId: string): any
	return BusinessDefinitions.get(businessId)
end

function UIKit.businessName(businessId: string): string
	local def = BusinessDefinitions.get(businessId)
	return def and def.name or tostring(businessId)
end

function UIKit.businessShortName(businessId: string): string
	local def = BusinessDefinitions.get(businessId)
	return def and def.shortName or tostring(businessId)
end

function UIKit.businessAccent(businessId: string): Color3
	local def = BusinessDefinitions.get(businessId)
	return UIKit.rgb(def and def.accent, UIKit.Theme.accent)
end

function UIKit.destinationInfo(ctx: any, destinationId: string): { address: string, neighborhood: string?, kind: string? }
	local layout = ctx and ctx.layout
	local entry = layout and findById(layout.destinations, destinationId)
	if entry then
		return { address = entry.address or destinationId, neighborhood = entry.neighborhood, kind = entry.kind }
	end
	return { address = tostring(destinationId), neighborhood = nil, kind = nil }
end

function UIKit.neighborhoodName(ctx: any, neighborhoodId: string?): string
	if not neighborhoodId then
		return ""
	end
	local layout = ctx and ctx.layout
	local entry = layout and findById(layout.neighborhoods, neighborhoodId)
	return entry and entry.name or tostring(neighborhoodId)
end

-- Short human label for a destination (address without the neighbourhood suffix if any).
function UIKit.shortAddress(address: string): string
	local short = string.gsub(address, ",.*$", "")
	return short
end

-------------------------------------------------------------------------------
-- Player helpers
-------------------------------------------------------------------------------

function UIKit.playerGui(): Instance?
	local player = Players.LocalPlayer
	if not player then
		return nil
	end
	local gui = player:FindFirstChildOfClass("PlayerGui")
	if gui then
		return gui
	end
	return player:WaitForChild("PlayerGui", 10)
end

function UIKit.playerPosition(ctx: any): Vector3?
	local state = ctx and ctx.state
	if state and type(state.getPlayerPosition) == "function" then
		local ok, position = pcall(state.getPlayerPosition)
		if ok and typeof(position) == "Vector3" then
			return position
		end
	end
	local vehicle = state and state.get("vehicle")
	if vehicle and vehicle.state == "Driving" and typeof(vehicle.model) == "Instance" then
		local chassis = vehicle.model:FindFirstChild("Chassis")
		if chassis and chassis:IsA("BasePart") then
			return chassis.Position
		end
	end
	local player = Players.LocalPlayer
	local character = player and player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root.Position
	end
	return nil
end

function UIKit.distanceTo(ctx: any, position: Vector3?): number?
	local from = UIKit.playerPosition(ctx)
	if not from or typeof(position) ~= "Vector3" then
		return nil
	end
	return MathUtil.horizontalDistance(from, position)
end

-- Invokes a RemoteFunction (yields). Never throws; failures come back as a Result table.
function UIKit.invoke(ctx: any, remoteName: string, ...: any): any
	local args = table.pack(...)
	local ok, result = pcall(function()
		local remote = ctx.remotes.getFunction(remoteName)
		return remote:InvokeServer(table.unpack(args, 1, args.n))
	end)
	if not ok then
		warn("[UIKit] " .. remoteName .. " failed: " .. tostring(result))
		return { ok = false, error = "Internal", message = "Something went wrong, try again." }
	end
	if type(result) ~= "table" then
		return { ok = false, error = "Internal", message = "No response from the server." }
	end
	return result
end

-- Routes a toast through UIController when it is present (screens never require the controller).
function UIKit.notify(ctx: any, text: string, kind: string?, duration: number?)
	local controller = ctx and ctx.controllers and ctx.controllers.UIController
	if controller and type(controller.Notify) == "function" then
		pcall(controller.Notify, text, kind or "info", duration)
	end
end

function UIKit.openScreen(ctx: any, name: string)
	local controller = ctx and ctx.controllers and ctx.controllers.UIController
	if controller and type(controller.OpenScreen) == "function" then
		pcall(controller.OpenScreen, name)
	end
end

function UIKit.device(ctx: any): string
	local input = ctx and ctx.controllers and ctx.controllers.InputController
	if input then
		if type(input.IsTouch) == "function" and input.IsTouch() then
			return "Touch"
		elseif type(input.IsGamepad) == "function" and input.IsGamepad() then
			return "Gamepad"
		end
	end
	local device = ctx and ctx.state and ctx.state.get("device")
	if device == "Touch" or device == "Gamepad" then
		return device
	end
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		return "Touch"
	elseif UserInputService.GamepadEnabled and not UserInputService.KeyboardEnabled then
		return "Gamepad"
	end
	return "Keyboard"
end

-------------------------------------------------------------------------------
-- Responsive scale
-------------------------------------------------------------------------------

local touchOverride: boolean? = nil
local gamepadOverride: boolean? = nil

function UIKit.setTouch(isTouch: boolean?)
	touchOverride = isTouch
end

-- Close buttons of every modal (weak keys) so their gamepad hint follows device changes.
local modalCloseButtons: { [TextButton]: boolean } = setmetatable({}, { __mode = "k" }) :: any

-- "Close (B)" for controller players (B closes the open modal in UIController), plain "Close" otherwise.
function UIKit.closeButtonText(): string
	return if UIKit.usesGamepadSelection() then "Close (B)" else "Close"
end

-- Tells focus() whether a gamepad is the active device (set by UIController from ClientState.device).
function UIKit.setGamepad(isGamepad: boolean?)
	gamepadOverride = isGamepad
	local text = UIKit.closeButtonText()
	for button in pairs(modalCloseButtons) do
		if button.Parent then
			button.Text = text
		end
	end
end

-- True when GuiService selection should be driven: the last input device is a gamepad, or one is
-- plugged in and no override has been given yet.
function UIKit.usesGamepadSelection(): boolean
	if gamepadOverride ~= nil then
		return gamepadOverride
	end
	return UserInputService.GamepadEnabled == true
end

local function isTouchDevice(): boolean
	if touchOverride ~= nil then
		return touchOverride
	end
	return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

-- Whether layouts should use their touch variant (UIController.applyDevice sets the override).
function UIKit.isTouchLayout(): boolean
	return isTouchDevice()
end

function UIKit.viewportSize(): Vector2
	local camera = workspace.CurrentCamera
	if camera then
		local okSize, size = pcall(function()
			return camera.ViewportSize
		end)
		if okSize and typeof(size) == "Vector2" and size.X > 0 and size.Y > 0 then
			return size
		end
	end
	return UIKit.BASE_VIEWPORT
end

-- 1 at 1280x720, clamped to [0.75, 1.25]; touch devices get a boost for finger-sized targets.
function UIKit.computeScale(viewport: Vector2, touch: boolean?): number
	local base = math.min(viewport.X / UIKit.BASE_VIEWPORT.X, viewport.Y / UIKit.BASE_VIEWPORT.Y)
	if touch then
		base *= UIKit.TOUCH_SCALE_BOOST
	end
	return math.clamp(base, UIKit.SCALE_MIN, UIKit.SCALE_MAX)
end

function UIKit.updateScale(gui: ScreenGui)
	local scale = gui:FindFirstChild("Scale")
	if scale and scale:IsA("UIScale") then
		scale.Scale = UIKit.computeScale(UIKit.viewportSize(), isTouchDevice())
	end
end

-- Width of a ScreenGui in scaled (design) units: AbsoluteSize / UIScale.
function UIKit.contentWidth(gui: Instance?): number
	if not gui then
		return UIKit.BASE_VIEWPORT.X
	end
	local okSize, size = pcall(function()
		return (gui :: any).AbsoluteSize
	end)
	local width = if okSize and typeof(size) == "Vector2" and size.X > 0 then size.X else UIKit.BASE_VIEWPORT.X
	local scale = gui:FindFirstChild("Scale")
	if scale and scale:IsA("UIScale") and scale.Scale > 0 then
		width /= scale.Scale
	end
	return width
end

-- ScreenGui with UIScale and safe-area aware padding container ("Root").
function UIKit.makeScreenGui(name: string, displayOrder: number?, parent: Instance?): ScreenGui
	local gui = Instance.new("ScreenGui")
	gui.Name = name
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = displayOrder or 0

	local scale = Instance.new("UIScale")
	scale.Name = "Scale"
	scale.Scale = UIKit.computeScale(UIKit.viewportSize(), isTouchDevice())
	scale.Parent = gui

	local camera = workspace.CurrentCamera
	if camera then
		pcall(function()
			camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
				UIKit.updateScale(gui)
			end)
		end)
	end
	pcall(function()
		gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			UIKit.updateScale(gui)
		end)
	end)

	gui.Parent = parent or UIKit.playerGui()
	return gui
end

-- Safe-area padding (keeps content off the rounded corners / notch region on phones).
function UIKit.safePadding(parent: Instance, pixels: number?): UIPadding
	local padding = Instance.new("UIPadding")
	padding.Name = "SafePadding"
	local p = UDim.new(0, pixels or 8)
	padding.PaddingLeft = p
	padding.PaddingRight = p
	padding.PaddingTop = p
	padding.PaddingBottom = p
	padding.Parent = parent
	return padding
end

-------------------------------------------------------------------------------
-- Primitive builders
-------------------------------------------------------------------------------

local function applyCommon(instance: GuiObject, props: any)
	props = props or {}
	if props.name then
		instance.Name = props.name
	end
	if props.size then
		instance.Size = props.size
	end
	if props.position then
		instance.Position = props.position
	end
	if props.anchor then
		instance.AnchorPoint = props.anchor
	end
	if props.layoutOrder then
		instance.LayoutOrder = props.layoutOrder
	end
	if props.zindex then
		instance.ZIndex = props.zindex
	end
	if props.visible ~= nil then
		instance.Visible = props.visible
	end
	if props.clips ~= nil then
		instance.ClipsDescendants = props.clips
	end
	if props.automaticSize then
		instance.AutomaticSize = props.automaticSize
	end
end

function UIKit.corner(parent: Instance, radius: number?): UICorner
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius or 10)
	corner.Parent = parent
	return corner
end

function UIKit.stroke(parent: Instance, color: Color3?, thickness: number?, transparency: number?): UIStroke
	local stroke = Instance.new("UIStroke")
	stroke.Color = color or UIKit.Theme.stroke
	stroke.Thickness = thickness or 1
	stroke.Transparency = transparency or 0
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = parent
	return stroke
end

function UIKit.padding(parent: Instance, all: number?, horizontal: number?, vertical: number?): UIPadding
	local padding = Instance.new("UIPadding")
	local h = UDim.new(0, horizontal or all or 8)
	local v = UDim.new(0, vertical or all or 8)
	padding.PaddingLeft = h
	padding.PaddingRight = h
	padding.PaddingTop = v
	padding.PaddingBottom = v
	padding.Parent = parent
	return padding
end

-- Frame with optional corner/stroke/padding.
function UIKit.panel(parent: Instance?, props: any): Frame
	props = props or {}
	-- props.class = "CanvasGroup" for containers that must clip rotated children (a plain Frame's
	-- ClipsDescendants does not clip rotated descendants; a CanvasGroup rasterises and does).
	local frame = Instance.new(props.class or "Frame")
	frame.Name = props.name or "Panel"
	frame.BackgroundColor3 = props.color or UIKit.Theme.panel
	frame.BackgroundTransparency = props.transparency or 0
	frame.BorderSizePixel = 0
	frame.Size = props.size or UDim2.fromScale(1, 1)
	applyCommon(frame, props)
	if props.corner ~= false then
		UIKit.corner(frame, type(props.corner) == "number" and props.corner or 10)
	end
	if props.stroke then
		UIKit.stroke(frame, typeof(props.stroke) == "Color3" and props.stroke or nil)
	end
	if props.padding then
		UIKit.padding(frame, props.padding)
	end
	frame.Parent = parent
	return frame
end

-- Readable text label: TextScaled with a 14..28 px size constraint.
function UIKit.label(parent: Instance?, text: string, props: any): TextLabel
	props = props or {}
	local label = Instance.new("TextLabel")
	label.Name = props.name or "Label"
	label.BackgroundTransparency = if props.bg then 0 else 1
	label.BackgroundColor3 = props.bg or UIKit.Theme.panelAlt
	label.BorderSizePixel = 0
	label.Text = text or ""
	label.TextColor3 = props.color or UIKit.Theme.text
	label.Font = if props.bold then UIKit.Theme.fontBold else (props.font or UIKit.Theme.font)
	label.TextScaled = props.scaled ~= false
	label.TextSize = props.textSize or 18
	label.TextWrapped = props.wrap ~= false
	label.TextXAlignment = Enum.TextXAlignment[props.align or "Left"]
	label.TextYAlignment = Enum.TextYAlignment[props.valign or "Center"]
	label.TextTransparency = props.textTransparency or 0
	label.RichText = props.rich == true
	label.Size = props.size or UDim2.new(1, 0, 0, 24)
	applyCommon(label, props)
	if label.TextScaled then
		local constraint = Instance.new("UITextSizeConstraint")
		constraint.MinTextSize = props.minSize or UIKit.MIN_TEXT
		constraint.MaxTextSize = props.maxSize or UIKit.MAX_TEXT
		constraint.Parent = label
	end
	if props.bg and props.corner ~= false then
		UIKit.corner(label, type(props.corner) == "number" and props.corner or 8)
	end
	label.Parent = parent
	return label
end

local function setButtonVisual(button: TextButton, state: string)
	local base = button:GetAttribute("BaseColor")
	if typeof(base) ~= "Color3" then
		return
	end
	if button:GetAttribute("Disabled") then
		button.BackgroundColor3 = base:Lerp(UIKit.Theme.panel, 0.55)
		return
	end
	if state == "hover" then
		button.BackgroundColor3 = base:Lerp(Color3.new(1, 1, 1), 0.12)
	elseif state == "press" then
		button.BackgroundColor3 = base:Lerp(Color3.new(0, 0, 0), 0.2)
	else
		button.BackgroundColor3 = base
	end
end

-- TextButton with corner, stroke, hover/press feedback, 44x44 minimum hit size.
function UIKit.button(parent: Instance?, text: string, onClick: (() -> ())?, props: any): TextButton
	props = props or {}
	local button = Instance.new("TextButton")
	button.Name = props.name or "Button"
	button.AutoButtonColor = false
	button.Selectable = true
	button.Active = true
	button.BorderSizePixel = 0
	button.BackgroundColor3 = props.color or UIKit.Theme.panelLight
	button:SetAttribute("BaseColor", props.color or UIKit.Theme.panelLight)
	button:SetAttribute("Disabled", false)
	button.Text = text or ""
	button.TextColor3 = props.textColor or UIKit.Theme.text
	button.Font = if props.bold ~= false then UIKit.Theme.fontBold else UIKit.Theme.font
	button.TextScaled = true
	button.TextWrapped = true
	button.Size = props.size or UDim2.new(0, 120, 0, UIKit.MIN_HIT)
	applyCommon(button, props)

	local constraint = Instance.new("UITextSizeConstraint")
	constraint.MinTextSize = props.minSize or UIKit.MIN_TEXT
	constraint.MaxTextSize = props.maxSize or 22
	constraint.Parent = button

	local sizeConstraint = Instance.new("UISizeConstraint")
	sizeConstraint.MinSize = Vector2.new(props.minWidth or UIKit.MIN_HIT, UIKit.MIN_HIT)
	sizeConstraint.Parent = button

	UIKit.corner(button, props.corner or 8)
	UIKit.stroke(button, props.strokeColor or UIKit.Theme.stroke, 1, 0.2)
	UIKit.padding(button, 0, 10, 4)

	button.MouseEnter:Connect(function()
		setButtonVisual(button, "hover")
	end)
	button.MouseLeave:Connect(function()
		setButtonVisual(button, "idle")
	end)
	button.MouseButton1Down:Connect(function()
		setButtonVisual(button, "press")
	end)
	button.MouseButton1Up:Connect(function()
		setButtonVisual(button, "hover")
	end)
	button.SelectionGained:Connect(function()
		setButtonVisual(button, "hover")
	end)
	button.SelectionLost:Connect(function()
		setButtonVisual(button, "idle")
	end)
	button.Activated:Connect(function()
		if button:GetAttribute("Disabled") then
			return
		end
		if onClick then
			onClick()
		end
	end)
	if props.disabled then
		UIKit.setButtonEnabled(button, false)
	end
	button.Parent = parent
	return button
end

function UIKit.setButtonEnabled(button: TextButton, enabled: boolean)
	button:SetAttribute("Disabled", not enabled)
	button.Selectable = enabled
	button.TextColor3 = if enabled then (button:GetAttribute("TextColor") or UIKit.Theme.text) else UIKit.Theme.textDim
	setButtonVisual(button, "idle")
end

function UIKit.setButtonColor(button: TextButton, color: Color3, textColor: Color3?)
	button:SetAttribute("BaseColor", color)
	if textColor then
		button:SetAttribute("TextColor", textColor)
		if not button:GetAttribute("Disabled") then
			button.TextColor3 = textColor
		end
	end
	setButtonVisual(button, "idle")
end

function UIKit.isButtonEnabled(button: TextButton): boolean
	return not button:GetAttribute("Disabled")
end

-- Accent-coloured primary button.
function UIKit.primaryButton(parent: Instance?, text: string, onClick: (() -> ())?, props: any): TextButton
	props = props or {}
	props.color = props.color or UIKit.Theme.accent
	props.textColor = props.textColor or UIKit.Theme.textOnAccent
	local button = UIKit.button(parent, text, onClick, props)
	button:SetAttribute("TextColor", props.textColor)
	return button
end

-------------------------------------------------------------------------------
-- Layouts
-------------------------------------------------------------------------------

function UIKit.listLayout(parent: Instance, direction: string?, padding: number?, props: any): UIListLayout
	props = props or {}
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection[direction or "Vertical"]
	layout.Padding = UDim.new(0, padding or 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.HorizontalAlignment = Enum.HorizontalAlignment[props.halign or "Left"]
	layout.VerticalAlignment = Enum.VerticalAlignment[props.valign or "Top"]
	if props.wraps ~= nil then
		layout.Wraps = props.wraps
	end
	layout.Parent = parent
	return layout
end

-- Horizontal container.
function UIKit.row(parent: Instance?, props: any): Frame
	props = props or {}
	props.corner = props.corner or false
	props.transparency = props.transparency or 1
	props.name = props.name or "Row"
	props.size = props.size or UDim2.new(1, 0, 0, UIKit.MIN_HIT)
	local frame = UIKit.panel(parent, props)
	UIKit.listLayout(frame, "Horizontal", props.gap or 8, { halign = props.halign, valign = props.valign or "Center" })
	return frame
end

-- Vertical container.
function UIKit.column(parent: Instance?, props: any): Frame
	props = props or {}
	props.corner = props.corner or false
	props.transparency = props.transparency or 1
	props.name = props.name or "Column"
	props.size = props.size or UDim2.fromScale(1, 1)
	local frame = UIKit.panel(parent, props)
	UIKit.listLayout(frame, "Vertical", props.gap or 6, { halign = props.halign, valign = props.valign })
	return frame
end

-- Vertical scrolling list with automatic canvas height.
function UIKit.scrollList(parent: Instance?, props: any): ScrollingFrame
	props = props or {}
	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = props.name or "List"
	scroll.BackgroundTransparency = props.transparency or 1
	scroll.BackgroundColor3 = props.color or UIKit.Theme.panel
	scroll.BorderSizePixel = 0
	scroll.Size = props.size or UDim2.fromScale(1, 1)
	scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.ScrollingDirection = Enum.ScrollingDirection.Y
	scroll.ScrollBarThickness = 6
	scroll.ScrollBarImageColor3 = UIKit.Theme.textDim
	scroll.ElasticBehavior = Enum.ElasticBehavior.WhenScrollable
	scroll.Selectable = false
	applyCommon(scroll, props)
	UIKit.listLayout(scroll, "Vertical", props.gap or 6, { halign = props.halign })
	UIKit.padding(scroll, 0, props.paddingX or 4, props.paddingY or 4)
	scroll.Parent = parent
	return scroll
end

function UIKit.divider(parent: Instance?, props: any): Frame
	props = props or {}
	local line = Instance.new("Frame")
	line.Name = props.name or "Divider"
	line.BackgroundColor3 = props.color or UIKit.Theme.stroke
	line.BorderSizePixel = 0
	line.Size = props.size or UDim2.new(1, 0, 0, 1)
	applyCommon(line, props)
	line.Parent = parent
	return line
end

-- Small rounded tag with text.
function UIKit.pill(parent: Instance?, text: string, props: any): TextLabel
	props = props or {}
	local pill = UIKit.label(parent, text, {
		name = props.name or "Pill",
		bg = props.color or UIKit.Theme.panelLight,
		color = props.textColor or UIKit.Theme.text,
		bold = true,
		align = "Center",
		size = props.size or UDim2.new(0, props.width or 90, 0, 24),
		minSize = 14,
		maxSize = props.maxSize or 16,
		layoutOrder = props.layoutOrder,
		corner = 12,
		automaticSize = props.automaticSize,
	})
	UIKit.padding(pill, 0, 8, 2)
	return pill
end

-- Progress bar; returns handle with set(fraction, color?).
function UIKit.progressBar(parent: Instance?, props: any): any
	props = props or {}
	local track = UIKit.panel(parent, {
		name = props.name or "ProgressBar",
		color = props.trackColor or UIKit.Theme.panelLight,
		size = props.size or UDim2.new(1, 0, 0, 8),
		corner = 4,
		layoutOrder = props.layoutOrder,
		position = props.position,
		anchor = props.anchor,
		clips = true,
	})
	local fill = UIKit.panel(track, {
		name = "Fill",
		color = props.color or UIKit.Theme.accent,
		size = UDim2.fromScale(0, 1),
		corner = 4,
	})
	local handle = { frame = track, fill = fill }
	function handle.set(fraction: number, color: Color3?)
		local f = math.clamp(tonumber(fraction) or 0, 0, 1)
		fill.Size = UDim2.fromScale(f, 1)
		if color then
			fill.BackgroundColor3 = color
		end
		track:SetAttribute("Fraction", f)
	end
	handle.set(props.value or 0)
	return handle
end

-- Tab strip. onSelect(name) runs when a tab is chosen; select(name) programmatically.
function UIKit.tabs(parent: Instance?, names: { string }, onSelect: (string) -> (), props: any): any
	props = props or {}
	local strip = UIKit.row(parent, { name = props.name or "Tabs", size = UDim2.new(1, 0, 0, UIKit.MIN_HIT), gap = 6, layoutOrder = props.layoutOrder })
	local handle = { frame = strip, buttons = {}, current = nil }
	local function paint()
		for name, button in pairs(handle.buttons) do
			if name == handle.current then
				UIKit.setButtonColor(button, UIKit.Theme.accent, UIKit.Theme.textOnAccent)
				button.Text = "[" .. name .. "]"
			else
				UIKit.setButtonColor(button, UIKit.Theme.panelLight, UIKit.Theme.text)
				button.Text = name
			end
		end
	end
	function handle.select(name: string, silent: boolean?)
		if not handle.buttons[name] then
			return
		end
		handle.current = name
		paint()
		if not silent then
			onSelect(name)
		end
	end
	for index, name in ipairs(names) do
		local button = UIKit.button(strip, name, function()
			handle.select(name)
		end, { name = "Tab_" .. name, size = UDim2.new(0, props.tabWidth or 150, 0, UIKit.MIN_HIT), layoutOrder = index })
		handle.buttons[name] = button
	end
	handle.select(names[1], true)
	return handle
end

-- Toggle switch rendered as a button with "[ON]/[OFF]" text (never colour alone).
function UIKit.toggle(parent: Instance?, text: string, value: boolean, onChange: (boolean) -> (), props: any): any
	props = props or {}
	local row = UIKit.row(parent, { name = props.name or ("Toggle_" .. text), size = UDim2.new(1, 0, 0, UIKit.MIN_HIT), layoutOrder = props.layoutOrder })
	UIKit.label(row, text, { size = UDim2.new(1, -110, 1, 0), layoutOrder = 1, maxSize = 20 })
	local handle = { frame = row, value = value == true }
	local button
	local function paint()
		button.Text = if handle.value then "ON" else "OFF"
		UIKit.setButtonColor(button, if handle.value then UIKit.Theme.success else UIKit.Theme.panelLight, if handle.value then UIKit.Theme.textOnAccent else UIKit.Theme.text)
	end
	button = UIKit.button(row, "", function()
		handle.value = not handle.value
		paint()
		onChange(handle.value)
	end, { name = "ToggleButton", size = UDim2.new(0, 96, 0, UIKit.MIN_HIT), layoutOrder = 2 })
	function handle.set(newValue: boolean)
		handle.value = newValue == true
		paint()
	end
	handle.button = button
	paint()
	return handle
end

-- Slider with -/+ buttons (controller and touch friendly) plus drag on the track.
function UIKit.slider(parent: Instance?, text: string, props: any): any
	props = props or {}
	local minValue = props.min or 0
	local maxValue = props.max or 1
	local step = props.step or 0.1
	local onChange = props.onChange or function() end
	local format = props.format or function(v: number)
		return string.format("%.1f", v)
	end

	local container = UIKit.column(parent, { name = props.name or ("Slider_" .. text), size = UDim2.new(1, 0, 0, 78), gap = 4, layoutOrder = props.layoutOrder })
	local header = UIKit.row(container, { name = "Header", size = UDim2.new(1, 0, 0, 24), layoutOrder = 1 })
	UIKit.label(header, text, { size = UDim2.new(1, -90, 1, 0), layoutOrder = 1, maxSize = 20 })
	local valueLabel = UIKit.label(header, "", { name = "Value", size = UDim2.new(0, 84, 1, 0), align = "Right", layoutOrder = 2, maxSize = 20, color = UIKit.Theme.accent, bold = true })

	local controls = UIKit.row(container, { name = "Controls", size = UDim2.new(1, 0, 0, UIKit.MIN_HIT), gap = 8, layoutOrder = 2 })
	local handle = { frame = container, value = math.clamp(props.value or minValue, minValue, maxValue) }
	local bar

	local function paint()
		valueLabel.Text = format(handle.value)
		bar.set((handle.value - minValue) / math.max(1e-6, maxValue - minValue))
	end
	local function commit(newValue: number, fire: boolean)
		local snapped = math.floor(newValue / step + 0.5) * step
		snapped = math.clamp(snapped, minValue, maxValue)
		if math.abs(snapped - handle.value) < 1e-6 then
			return
		end
		handle.value = snapped
		paint()
		if fire then
			onChange(snapped)
		end
	end

	UIKit.button(controls, "-", function()
		commit(handle.value - step, true)
	end, { name = "Minus", size = UDim2.new(0, UIKit.MIN_HIT, 0, UIKit.MIN_HIT), layoutOrder = 1 })
	local trackHolder = UIKit.panel(controls, { name = "TrackHolder", transparency = 1, corner = false, size = UDim2.new(1, -2 * UIKit.MIN_HIT - 16, 1, 0), layoutOrder = 2 })
	trackHolder.Active = true
	bar = UIKit.progressBar(trackHolder, { name = "Track", size = UDim2.new(1, 0, 0, 10), position = UDim2.fromScale(0, 0.5), anchor = Vector2.new(0, 0.5) })
	UIKit.button(controls, "+", function()
		commit(handle.value + step, true)
	end, { name = "Plus", size = UDim2.new(0, UIKit.MIN_HIT, 0, UIKit.MIN_HIT), layoutOrder = 3 })

	-- Drag / tap on the track.
	local dragging = false
	local function valueFromInput(input: InputObject)
		local size = trackHolder.AbsoluteSize.X
		if size <= 0 then
			return handle.value
		end
		local fraction = math.clamp((input.Position.X - trackHolder.AbsolutePosition.X) / size, 0, 1)
		return minValue + fraction * (maxValue - minValue)
	end
	trackHolder.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			commit(valueFromInput(input), true)
		end
	end)
	trackHolder.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			commit(valueFromInput(input), true)
		end
	end)
	trackHolder.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)

	function handle.set(newValue: number)
		handle.value = math.clamp(tonumber(newValue) or minValue, minValue, maxValue)
		paint()
	end
	paint()
	return handle
end

-------------------------------------------------------------------------------
-- Modal
-------------------------------------------------------------------------------

-- Modal panel with a header (title + Close button) and a body frame. props.onClose runs on Close.
function UIKit.modal(parent: Instance?, title: string, props: any): any
	props = props or {}
	local frame = UIKit.panel(parent, {
		name = props.name or ("Modal_" .. title),
		size = props.size or UDim2.fromScale(0.92, 0.9),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
		color = UIKit.Theme.panel,
		corner = 14,
		stroke = true,
		visible = props.visible == true,
		zindex = props.zindex or 2,
	})
	local sizeConstraint = Instance.new("UISizeConstraint")
	sizeConstraint.MaxSize = props.maxSize or Vector2.new(900, 640)
	sizeConstraint.MinSize = Vector2.new(300, 220)
	sizeConstraint.Parent = frame
	UIKit.padding(frame, 12)

	local header = UIKit.row(frame, { name = "Header", size = UDim2.new(1, 0, 0, UIKit.MIN_HIT), layoutOrder = 1 })
	local titleLabel = UIKit.label(header, title, { name = "Title", bold = true, size = UDim2.new(1, -(UIKit.MODAL_CLOSE_WIDTH + 8), 1, 0), maxSize = 26, layoutOrder = 1 })
	local closeButton = UIKit.button(header, UIKit.closeButtonText(), function()
		if props.onClose then
			props.onClose()
		end
	end, { name = "CloseButton", size = UDim2.new(0, UIKit.MODAL_CLOSE_WIDTH, 0, UIKit.MIN_HIT), layoutOrder = 2 })
	modalCloseButtons[closeButton] = true
	header:FindFirstChildOfClass("UIListLayout").HorizontalAlignment = Enum.HorizontalAlignment.Left

	local body = UIKit.panel(frame, {
		name = "Body",
		transparency = 1,
		corner = false,
		size = UDim2.new(1, 0, 1, -(UIKit.MIN_HIT + 8)),
		position = UDim2.new(0, 0, 0, UIKit.MIN_HIT + 8),
	})

	local handle = { frame = frame, header = header, body = body, closeButton = closeButton, titleLabel = titleLabel }
	function handle.setTitle(text: string)
		titleLabel.Text = text
	end
	return handle
end

-- First visible, enabled button in the tree (depth-first) for controller focus.
function UIKit.firstSelectable(root: Instance): GuiButton?
	for _, child in ipairs(root:GetChildren()) do
		if child:IsA("GuiObject") and child.Visible then
			if child:IsA("GuiButton") and child.Selectable and not child:GetAttribute("Disabled") then
				return child
			end
			local nested = UIKit.firstSelectable(child)
			if nested then
				return nested
			end
		end
	end
	return nil
end

-- Moves controller selection to `preferred`, else to the first selectable in root's "Body" (so a
-- modal opens on its content rather than its Close button), else anywhere in root. Mouse/keyboard
-- and touch players never get a selection box (it renders on every device once set).
function UIKit.focus(root: Instance?, preferred: GuiButton?)
	if not UIKit.usesGamepadSelection() then
		return
	end
	local target = preferred
	if not target and root then
		local body = root:FindFirstChild("Body")
		target = (body and UIKit.firstSelectable(body)) or UIKit.firstSelectable(root)
	end
	pcall(function()
		GuiService.SelectedObject = target
	end)
end

function UIKit.clearFocus()
	pcall(function()
		GuiService.SelectedObject = nil
	end)
end

-- Gamepad selection containment. Roblox navigates GuiService.SelectedObject across every visible
-- Selectable GuiObject in PlayerGui regardless of ScreenGui, DisplayOrder or a covering scrim, so a
-- modal registers itself as a selection parent: D-pad / thumbstick navigation then stays inside it
-- instead of jumping to the dimmed HUD buttons behind it. One group ("DDC_Modal") follows the
-- currently visible screen; releaseSelection() removes it when the modal closes.
UIKit.SELECTION_GROUP = "DDC_Modal"
local selectionRoot: Instance? = nil

function UIKit.containSelection(root: Instance?)
	pcall(function()
		GuiService:RemoveSelectionGroup(UIKit.SELECTION_GROUP)
	end)
	selectionRoot = nil
	if root then
		local ok = pcall(function()
			GuiService:AddSelectionParent(UIKit.SELECTION_GROUP, root)
		end)
		if ok then
			selectionRoot = root
		end
	end
end

function UIKit.releaseSelection()
	UIKit.containSelection(nil)
end

-- The root selection is currently contained to (nil when no group is registered).
function UIKit.getSelectionRoot(): Instance?
	return selectionRoot
end

-------------------------------------------------------------------------------
-- Tweens
-------------------------------------------------------------------------------

function UIKit.tween(instance: Instance, goal: { [string]: any }, duration: number?, style: Enum.EasingStyle?): Tween
	local tween = TweenService:Create(instance, TweenInfo.new(duration or 0.2, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out), goal)
	tween:Play()
	return tween
end

-- Fades a GuiObject (and its direct text/stroke) in from transparent.
function UIKit.fadeIn(instance: GuiObject, duration: number?, targetTransparency: number?)
	local target = targetTransparency or 0
	instance.Visible = true
	instance.BackgroundTransparency = 1
	UIKit.tween(instance, { BackgroundTransparency = target }, duration or 0.2)
end

function UIKit.fadeOut(instance: GuiObject, duration: number?, onDone: (() -> ())?)
	local tween = UIKit.tween(instance, { BackgroundTransparency = 1 }, duration or 0.2)
	tween.Completed:Connect(function()
		instance.Visible = false
		if onDone then
			onDone()
		end
	end)
end

-------------------------------------------------------------------------------
-- Prompt frame (shared by every interaction prompt)
-------------------------------------------------------------------------------

-- spec = { text, action, kind, detail? }; onActivated(actionName) runs when the frame is tapped.
function UIKit.promptFrame(parent: Instance?, spec: any, device: string, onActivated: ((string) -> ())?): TextButton
	local kindColor = if spec.kind == "pickup" then UIKit.Theme.pickup
		elseif spec.kind == "deliver" then UIKit.Theme.deliver
		elseif spec.kind == "wait" then UIKit.Theme.warning
		else UIKit.Theme.panelLight

	local frame = Instance.new("TextButton")
	frame.Name = "Prompt"
	frame.AutoButtonColor = false
	frame.Selectable = false
	frame.Text = ""
	frame.BackgroundColor3 = UIKit.Theme.panel
	frame.BackgroundTransparency = 0.1
	frame.BorderSizePixel = 0
	frame.AnchorPoint = Vector2.new(0.5, 1)
	frame.Position = UDim2.new(0.5, 0, 1, -96)
	frame.Size = UDim2.new(0, 360, 0, 64)
	frame:SetAttribute("Action", spec.action)
	frame:SetAttribute("Kind", spec.kind)
	UIKit.corner(frame, 12)
	UIKit.stroke(frame, kindColor, 2)

	local glyphBox = UIKit.label(frame, UIKit.glyph(spec.action, device), {
		name = "Glyph",
		bg = kindColor,
		color = UIKit.Theme.textOnAccent,
		bold = true,
		align = "Center",
		size = UDim2.new(0, 52, 0, 52),
		position = UDim2.new(0, 6, 0.5, 0),
		anchor = Vector2.new(0, 0.5),
		maxSize = 22,
		corner = 10,
	})
	glyphBox:SetAttribute("Device", device)

	local textLabel = UIKit.label(frame, spec.text or "", {
		name = "Text",
		bold = true,
		size = UDim2.new(1, -72, 0, if spec.detail then 30 else 52),
		position = UDim2.new(0, 64, 0, 6),
		maxSize = 22,
	})
	if spec.detail then
		UIKit.label(frame, spec.detail, {
			name = "Detail",
			color = UIKit.Theme.textDim,
			size = UDim2.new(1, -72, 0, 22),
			position = UDim2.new(0, 64, 0, 36),
			maxSize = 16,
		})
	end
	if device == "Touch" then
		textLabel.Text = (spec.text or "") .. "  (tap)"
	end
	frame.Activated:Connect(function()
		if onActivated then
			onActivated(spec.action)
		end
	end)
	frame.Parent = parent
	return frame
end

-------------------------------------------------------------------------------
-- Misc
-------------------------------------------------------------------------------

-- Destroys every child except layout/constraint objects.
function UIKit.clearChildren(parent: Instance)
	for _, child in ipairs(parent:GetChildren()) do
		if not (child:IsA("UIBase") or child:IsA("UIComponent") or child:IsA("UIConstraint") or child:IsA("UILayout")) then
			child:Destroy()
		end
	end
end

-- Key/value line used in cards: "Label   value".
function UIKit.statLine(parent: Instance?, keyText: string, valueText: string, props: any): any
	props = props or {}
	local row = UIKit.row(parent, { name = props.name or ("Stat_" .. keyText), size = UDim2.new(1, 0, 0, props.height or 22), layoutOrder = props.layoutOrder, gap = 6 })
	local key = UIKit.label(row, keyText, { name = "Key", color = UIKit.Theme.textDim, size = UDim2.new(0.45, 0, 1, 0), layoutOrder = 1, maxSize = props.maxSize or 16 })
	local value = UIKit.label(row, valueText, { name = "Value", color = props.valueColor or UIKit.Theme.text, bold = props.bold, size = UDim2.new(0.55, -6, 1, 0), align = "Right", layoutOrder = 2, maxSize = props.maxSize or 16 })
	return { frame = row, key = key, value = value }
end

-- Standard card panel for lists.
function UIKit.card(parent: Instance?, props: any): Frame
	props = props or {}
	local card = UIKit.panel(parent, {
		name = props.name or "Card",
		color = props.color or UIKit.Theme.panelAlt,
		size = props.size or UDim2.new(1, -8, 0, props.height or 120),
		corner = 10,
		stroke = props.stroke,
		layoutOrder = props.layoutOrder,
		automaticSize = props.automaticSize,
	})
	UIKit.padding(card, props.padding or 8)
	if props.list ~= false then
		UIKit.listLayout(card, "Vertical", props.gap or 4)
	end
	return card
end

return UIKit
