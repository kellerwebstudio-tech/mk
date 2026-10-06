--!nonstrict
-- tests/specs/ui.spec.luau — client UI specs (UIKit, UIController, screens) against a minimal
-- in-spec fake ClientState that implements the documented interface.

-- The shim pre-creates an empty StarterPlayerScripts and the bundled tree adds a second one that
-- holds DeliveryDashClient, so the client root is located by scanning StarterPlayer's children.
local function clientRoot()
	local starterPlayer = game:GetService("StarterPlayer")
	for _, child in ipairs(starterPlayer:GetChildren()) do
		local root = child:FindFirstChild("DeliveryDashClient")
		if root then
			return root
		end
	end
	error("DeliveryDashClient not found under StarterPlayer")
end

local function requireClient(path: string)
	local current = clientRoot()
	for segment in path:gmatch("[^/]+") do
		local nxt = current:FindFirstChild(segment)
		if not nxt then
			error("No client instance at " .. path .. " (missing " .. segment .. ")")
		end
		current = nxt
	end
	return require(current)
end

-- Creates the remote folder (server context) and switches to the client.
local function setupClient()
	shim.setContext("server")
	local Remotes = shim.requirePath("ReplicatedStorage/Shared/Util/Remotes")
	Remotes.createAll()
	shim.setContext("client")
	return Remotes
end

local function v3(x, y, z)
	return Vector3.new(x, y, z)
end

-- Minimal fake ClientState implementing get/set/onChange/Changed/serverNow/getActiveOrder/
-- getOrderedStops/getPlayerPosition/OrderEvent/WorldEvent.
local function makeFakeState(initial)
	local Signal = shim.requirePath("ReplicatedStorage/Shared/Util/Signal")
	local values = initial or {}
	values.orders = values.orders or { available = {}, active = {}, capacity = nil, serverTime = nil }
	values.vehicle = values.vehicle or { state = nil, vehicleId = nil, model = nil }
	values.tutorial = values.tutorial or { step = 0, completed = true }
	values.stopOrder = values.stopOrder or {}
	values.serverTimeOffset = values.serverTimeOffset or 0
	values.device = values.device or "Keyboard"
	values.positions = values.positions or {}

	local state = {}
	state.Changed = Signal.new()
	state.OrderEvent = Signal.new()
	state.WorldEvent = Signal.new()
	state.playerPosition = v3(0, 0, 0)

	function state.get(key)
		return values[key]
	end
	function state.set(key, value)
		local previous = values[key]
		values[key] = value
		if previous ~= value or type(value) == "table" then
			state.Changed:Fire(key, value)
		end
	end
	function state.onChange(key, fn)
		local connection = state.Changed:Connect(function(changedKey, value)
			if changedKey == key then
				fn(value)
			end
		end)
		task.spawn(fn, values[key])
		return connection
	end
	function state.serverNow()
		return os.clock() + (values.serverTimeOffset or 0)
	end
	function state.getActiveOrder(orderId)
		for _, order in ipairs(values.orders.active or {}) do
			if order.id == orderId then
				return order
			end
		end
		return nil
	end
	function state.getPlayerPosition()
		return state.playerPosition
	end
	local function stopFor(order)
		local kind = if order.state == "Collected" then "deliver" else "pickup"
		local key = if kind == "pickup" then order.businessId else order.destinationId
		return {
			order = order,
			kind = kind,
			position = values.positions[key] or v3(0, 0, 0),
			label = key,
			address = key,
		}
	end
	function state.getOrderedStops()
		local result, remaining, byId = {}, {}, {}
		for _, order in ipairs(values.orders.active or {}) do
			if order.state == "Accepted" or order.state == "ReadyForPickup" or order.state == "Collected" then
				local stop = stopFor(order)
				byId[order.id] = stop
				table.insert(remaining, stop)
			end
		end
		for _, id in ipairs(values.stopOrder or {}) do
			local stop = byId[id]
			if stop then
				table.insert(result, stop)
				byId[id] = nil
				for index, candidate in ipairs(remaining) do
					if candidate == stop then
						table.remove(remaining, index)
						break
					end
				end
			end
		end
		for _, stop in ipairs(remaining) do
			table.insert(result, stop)
		end
		return result
	end
	return state
end

local function makeProfile(overrides)
	local profile = {
		schemaVersion = 1,
		cash = 100,
		reputation = 0,
		ownedVehicles = { Bicycle = true },
		equippedVehicle = "Bicycle",
		upgrades = {},
		depot = { owned = false, slotsUnlocked = 0, drivers = {} },
		cosmetics = { owned = {}, equipped = {} },
		tutorial = { completed = true, step = 9 },
		stats = { deliveries = 10, totalEarned = 0, bestTimes = {}, distance = 0, contractsCompleted = 0, lateDeliveries = 0 },
		settings = { cameraSensitivity = 1, reducedMotion = false, autoRecenter = true, musicVolume = 0.6, sfxVolume = 0.8, showMinimap = true, invertCameraY = false },
	}
	for key, value in pairs(overrides or {}) do
		profile[key] = value
	end
	return profile
end

local function makeOrder(overrides)
	local order = {
		id = "order-1",
		userId = 1,
		businessId = "SliceStreetPizza",
		destinationId = "dest-1",
		itemCategory = "Pizza",
		size = "Small",
		sizeUnits = 1,
		packageKey = "PizzaBox",
		itemLabel = "Margherita pizza",
		basePay = 40,
		tipMax = 12,
		repReward = 6,
		timeLimit = 120,
		availableUntil = os.clock() + 90,
		prepTime = 8,
		routeDistance = 250,
		createdAt = os.clock(),
		state = "Available",
	}
	for key, value in pairs(overrides or {}) do
		order[key] = value
	end
	return order
end

local function makeCtx(state, extra)
	local ctx = {
		state = state,
		remotes = shim.requirePath("ReplicatedStorage/Shared/Util/Remotes"),
		layout = {
			groundY = 0,
			neighborhoods = { { id = "Downtown", name = "Downtown" }, { id = "Residential", name = "Maple Hill" } },
			businesses = { { id = "SliceStreetPizza", name = "Slice Street Pizza" } },
			destinations = { { id = "dest-1", address = "12 Plaza Apartments", neighborhood = "Downtown", kind = "Apartment" } },
		},
		graph = nil,
		controllers = {},
	}
	for key, value in pairs(extra or {}) do
		ctx[key] = value
	end
	return ctx
end

local function findDescendant(root, name)
	return root:FindFirstChild(name, true)
end

-- Height needed by a vertically listed card: visible children + list gaps + UIPadding.
local function listedContentHeight(card)
	local layout = card:FindFirstChildOfClass("UIListLayout")
	local padding = card:FindFirstChildOfClass("UIPadding")
	local total, count = 0, 0
	for _, child in ipairs(card:GetChildren()) do
		if child:IsA("GuiObject") and child.Visible then
			total += child.Size.Y.Offset
			count += 1
		end
	end
	if layout and count > 1 then
		total += layout.Padding.Offset * (count - 1)
	end
	if padding then
		total += padding.PaddingTop.Offset + padding.PaddingBottom.Offset
	end
	return total
end

-- Height needed by absolutely positioned children (offset-only layouts) + UIPadding.
local function absoluteContentHeight(panel)
	local padding = panel:FindFirstChildOfClass("UIPadding")
	local bottom = 0
	for _, child in ipairs(panel:GetChildren()) do
		if child:IsA("GuiObject") and child.Visible then
			bottom = math.max(bottom, child.Position.Y.Offset + child.Size.Y.Offset)
		end
	end
	if padding then
		bottom += padding.PaddingTop.Offset + padding.PaddingBottom.Offset
	end
	return bottom
end

local function expectListedFits(card)
	expect(listedContentHeight(card)).toBeLessThanOrEqual(card.Size.Y.Offset)
end

local function cardsIn(list, prefix)
	local result = {}
	for _, child in ipairs(list:GetChildren()) do
		if child:IsA("Frame") and string.sub(child.Name, 1, #prefix) == prefix then
			table.insert(result, child)
		end
	end
	table.sort(result, function(a, b)
		return a.LayoutOrder < b.LayoutOrder
	end)
	return result
end

-------------------------------------------------------------------------------

describe("UIKit", function()
	it("builds a ScreenGui with a UIScale in range and safe insets", function()
		setupClient()
		local UIKit = requireClient("UI/UIKit")
		local gui = UIKit.makeScreenGui("TestGui", 5)
		expect(gui.ClassName).toBe("ScreenGui")
		expect(gui.ResetOnSpawn).toBe(false)
		expect(gui.IgnoreGuiInset).toBe(false)
		expect(gui.ScreenInsets).toBe(Enum.ScreenInsets.CoreUISafeInsets)
		expect(gui.ZIndexBehavior).toBe(Enum.ZIndexBehavior.Sibling)
		expect(gui.DisplayOrder).toBe(5)
		expect(gui.Parent).toBe(game:GetService("Players").LocalPlayer.PlayerGui)
		local scale = gui:FindFirstChild("Scale")
		expect(scale.ClassName).toBe("UIScale")
		expect(scale.Scale).toBeGreaterThanOrEqual(0.75)
		expect(scale.Scale).toBeLessThanOrEqual(1.25)
		expect(scale.Scale).toBeCloseTo(1, 0.01) -- 1280x720 viewport in the shim
		-- clamped at both ends and boosted on touch
		expect(UIKit.computeScale(Vector2.new(667, 375), false)).toBeCloseTo(0.75, 1e-6)
		expect(UIKit.computeScale(Vector2.new(3840, 2160), false)).toBeCloseTo(1.25, 1e-6)
		expect(UIKit.computeScale(Vector2.new(1280, 720), true)).toBeGreaterThan(1)
		expect(UIKit.computeScale(Vector2.new(1920, 1080), false)).toBeCloseTo(1.25, 1e-6)
	end)

	it("labels are TextScaled with a 14..28 constraint and buttons have a 44 px hit size", function()
		setupClient()
		local UIKit = requireClient("UI/UIKit")
		local gui = UIKit.makeScreenGui("TestGui", 1)
		local label = UIKit.label(gui, "Hello")
		expect(label.TextScaled).toBe(true)
		local constraint = label:FindFirstChildOfClass("UITextSizeConstraint")
		expect(constraint.MinTextSize).toBe(14)
		expect(constraint.MaxTextSize).toBe(28)
		local clicked = 0
		local button = UIKit.button(gui, "Press", function()
			clicked += 1
		end)
		expect(button.AutoButtonColor).toBe(false)
		expect(button.Selectable).toBe(true)
		expect(button:FindFirstChildOfClass("UISizeConstraint").MinSize).toEqual(Vector2.new(44, 44))
		expect(button:FindFirstChildOfClass("UICorner")).never.toBeNil()
		expect(button:FindFirstChildOfClass("UIStroke")).never.toBeNil()
		button.Activated:Fire()
		expect(clicked).toBe(1)
		UIKit.setButtonEnabled(button, false)
		button.Activated:Fire()
		expect(clicked).toBe(1)
		expect(UIKit.glyph("DDC_Interact", "Keyboard")).toBe("E")
		expect(UIKit.glyph("DDC_Interact", "Gamepad")).toBe("X")
		expect(UIKit.glyph("DDC_Interact", "Touch")).toBe("Tap")
		expect(UIKit.formatCash(1200)).toBe("$1,200")
	end)
end)

describe("UIController", function()
	local UIController, ctx, state

	beforeEach(function()
		setupClient()
		state = makeFakeState({ profile = makeProfile() })
		ctx = makeCtx(state)
		UIController = requireClient("Controllers/UIController")
		UIController.Init(ctx)
		UIController.Start()
	end)

	it("creates both ScreenGuis and registers itself in ctx.controllers", function()
		local playerGui = game:GetService("Players").LocalPlayer.PlayerGui
		expect(playerGui:FindFirstChild("DDC_HUD")).never.toBeNil()
		expect(playerGui:FindFirstChild("DDC_Menus")).never.toBeNil()
		expect(UIController.GetScreenGui().Name).toBe("DDC_HUD")
		expect(ctx.controllers.UIController).toBe(UIController)
		expect(findDescendant(UIController.GetScreenGui(), "Minimap")).never.toBeNil()
		expect(findDescendant(UIController.GetScreenGui(), "NavStrip")).never.toBeNil()
	end)

	it("Notify stacks toasts and expires them on shim.advance", function()
		local Notifications = requireClient("UI/Notifications")
		UIController.Notify("First", "info", 2)
		UIController.Notify("Second", "success", 5)
		UIController.Notify("Third", "error")
		expect(Notifications.Count()).toBe(3)
		local container = findDescendant(UIController.GetScreenGui(), "Notifications")
		expect(#container:GetChildren() - 1).toBe(3) -- minus the UIListLayout
		expect(findDescendant(container, "Prefix").Text).toBe("i")
		shim.advance(2.5)
		expect(Notifications.Count()).toBe(2)
		shim.advance(2) -- default duration 4 s -> Third expires at 4 s
		expect(Notifications.Count()).toBe(1)
		shim.advance(1)
		expect(Notifications.Count()).toBe(0)
	end)

	it("OpenScreen/CloseScreen toggle IsModalOpen and fire ModalChanged", function()
		local events = {}
		UIController.ModalChanged:Connect(function(open)
			table.insert(events, open)
		end)
		expect(UIController.IsModalOpen()).toBe(false)
		UIController.OpenScreen("Orders")
		expect(UIController.IsModalOpen()).toBe(true)
		expect(UIController.GetCurrentScreen()).toBe("Orders")
		-- switching screens keeps the modal open (no extra ModalChanged)
		UIController.OpenScreen("Shop")
		expect(UIController.GetCurrentScreen()).toBe("Shop")
		UIController.CloseScreen("Orders") -- not the current screen: ignored
		expect(UIController.IsModalOpen()).toBe(true)
		UIController.CloseScreen()
		expect(UIController.IsModalOpen()).toBe(false)
		task.wait()
		expect(events).toEqual({ true, false })
		UIController.ToggleScreen("Menu")
		expect(UIController.IsModalOpen()).toBe(true)
		UIController.ToggleScreen("Menu")
		expect(UIController.IsModalOpen()).toBe(false)
		-- the scrim follows the modal state
		local scrim = findDescendant(UIController.GetMenuGui(), "Scrim")
		expect(scrim.Visible).toBe(false)
		UIController.OpenScreen("Settings")
		expect(scrim.Visible).toBe(true)
	end)

	it("drives GuiService selection only for gamepad players and lands on the modal body", function()
		local GuiService = game:GetService("GuiService")
		-- keyboard / mouse: no selection box
		UIController.OpenScreen("Orders")
		expect(GuiService.SelectedObject).toBeNil()
		UIController.CloseScreen()
		-- gamepad: first selectable inside the Body (the tab strip), never the Close button
		state.set("device", "Gamepad")
		task.wait()
		UIController.OpenScreen("Orders")
		local selected = GuiService.SelectedObject
		expect(selected).never.toBeNil()
		expect(selected.Name).never.toBe("CloseButton")
		local board = findDescendant(UIController.GetMenuGui(), "OrderBoard")
		expect(selected:IsDescendantOf(board:FindFirstChild("Body"))).toBe(true)
		UIController.CloseScreen()
		expect(GuiService.SelectedObject).toBeNil()
		state.set("device", "Keyboard")
		task.wait()
	end)

	it("ShowPrompt creates the prompt frame with the device glyph and HidePrompt destroys it", function()
		local gui = UIController.GetScreenGui()
		UIController.ShowPrompt({ text = "Collect order", action = "DDC_Interact", kind = "pickup", detail = "Margherita pizza" })
		local prompt = gui:FindFirstChild("Prompt")
		expect(prompt).never.toBeNil()
		expect(prompt:FindFirstChild("Glyph").Text).toBe("E")
		expect(prompt:FindFirstChild("Text").Text).toBe("Collect order")
		expect(prompt:FindFirstChild("Detail").Text).toBe("Margherita pizza")
		local activated = {}
		UIController.PromptActivated:Connect(function(action)
			table.insert(activated, action)
		end)
		prompt.Activated:Fire()
		task.wait()
		expect(activated).toEqual({ "DDC_Interact" })
		-- replacing the prompt keeps exactly one frame
		UIController.ShowPrompt({ text = "Ride", action = "DDC_MountDismount", kind = "mount" })
		local count = 0
		for _, child in ipairs(gui:GetChildren()) do
			if child.Name == "Prompt" then
				count += 1
			end
		end
		expect(count).toBe(1)
		expect(gui:FindFirstChild("Prompt"):FindFirstChild("Glyph").Text).toBe("F")
		UIController.HidePrompt()
		expect(gui:FindFirstChild("Prompt")).toBeNil()
		-- device change re-renders the glyph
		UIController.ShowPrompt({ text = "Ride", action = "DDC_MountDismount", kind = "mount" })
		state.set("device", "Gamepad")
		task.wait()
		expect(gui:FindFirstChild("Prompt"):FindFirstChild("Glyph").Text).toBe("Y")
	end)

	it("SetNavigation updates the nav strip labels and the Late soon warning", function()
		local HUD = requireClient("UI/HUD")
		local refs = HUD.GetRefs()
		UIController.SetNavigation({ active = true, label = "Slice Street Pizza", stopKind = "pickup", distance = 240, turnKind = "Left", turnDistance = 40, address = "Slice Street", timeLeft = 100 })
		expect(refs.nav.Visible).toBe(true)
		expect(refs.turnGlyph.Text).toBe("<-")
		expect(refs.turnText.Text).toBe("Turn left in 40 studs")
		expect(refs.destination.Text).toBe("PICKUP: Slice Street Pizza")
		expect(refs.address.Text).toBe("Slice Street")
		expect(refs.distance.Text).toBe("240")
		expect(refs.timer.Text).toBe("Time 1:40")
		expect(refs.timerNote.Text).toBe("")
		-- an active order with a 120 s limit and 25 s left -> amber "Late soon"
		state.set("orders", { available = {}, active = { makeOrder({ state = "Collected", acceptedAt = state.serverNow() - 95, timeLimit = 120 }) }, capacity = { current = 1, max = 1, load = 1, committed = 1 } })
		UIController.SetNavigation({ active = true, label = "12 Plaza Apartments", stopKind = "deliver", distance = 1200, turnKind = "Arrive", turnDistance = 10, timeLeft = 25 })
		expect(refs.timerNote.Text).toBe("Late soon")
		expect(refs.turnText.Text).toBe("Arrive - deliver")
		expect(refs.distance.Text).toBe("1.2k")
		UIController.SetNavigation({ active = false })
		expect(refs.nav.Visible).toBe(false)
	end)

	it("HUD shows cash, reputation progress and the capacity meter from ClientState", function()
		local HUD = requireClient("UI/HUD")
		local refs = HUD.GetRefs()
		state.set("profile", makeProfile({ cash = 1234, reputation = 60 }))
		state.set("orders", { available = {}, active = {}, capacity = { current = 3, max = 3, load = 2, committed = 2 } })
		task.wait()
		expect(refs.cash.Text).toBe("$1,234")
		expect(refs.rep.Text).toBe("Rep 60")
		expect(refs.repNext.Text).toBe("120 Rep unlocks Fresh Lane Market")
		expect(refs.repBar.frame:GetAttribute("Fraction")).toBeCloseTo(0.5, 1e-6)
		expect(refs.loadText.Text).toBe("Load 2/3")
		-- fixed-height HUD panels hold their rows
		local wallet = findDescendant(UIController.GetScreenGui(), "Wallet")
		expect(absoluteContentHeight(wallet)).toBeLessThanOrEqual(wallet.Size.Y.Offset)
		local nextRep, previous = HUD.NextUnlock(600)
		expect(nextRep).toBeNil()
		expect(previous).toBe(500)
	end)

	it("ToggleOrders / ToggleMenu actions from InputController toggle the screens", function()
		local Signal = shim.requirePath("ReplicatedStorage/Shared/Util/Signal")
		local pressed = Signal.new()
		shim.setContext("client")
		local freshState = makeFakeState({ profile = makeProfile() })
		local freshCtx = makeCtx(freshState)
		freshCtx.controllers.InputController = { Pressed = pressed, IsTouch = function() return false end, IsGamepad = function() return false end }
		-- a second controller instance for this ctx (module is cached; re-Init is fine for the registry)
		local Controller = requireClient("Controllers/UIController")
		Controller.Init(freshCtx)
		Controller.Start()
		pressed:Fire("DDC_ToggleOrders")
		task.wait()
		expect(Controller.GetCurrentScreen()).toBe("Orders")
		pressed:Fire("DDC_ToggleOrders")
		task.wait()
		expect(Controller.IsModalOpen()).toBe(false)
		pressed:Fire("DDC_ToggleMenu")
		task.wait()
		expect(Controller.GetCurrentScreen()).toBe("Menu")
		-- gamepad B closes
		shim.input.press(Enum.KeyCode.ButtonB, Enum.UserInputType.Gamepad1)
		task.wait()
		expect(Controller.IsModalOpen()).toBe(false)
	end)

	it("ShowResults fills the card and hides it after 6 seconds; SetTutorial shows the banner", function()
		local toast = findDescendant(UIController.GetScreenGui(), "ResultsToast")
		UIController.ShowResults({ base = 40, tip = 12, total = 52, rep = 6, lateSeconds = 0, timelinessFactor = 1, newRecord = true }, makeOrder())
		expect(toast.Visible).toBe(true)
		expect(findDescendant(toast, "Total"):FindFirstChild("Value").Text).toBe("$52")
		expect(findDescendant(toast, "Record").Visible).toBe(true)
		expectListedFits(toast)
		shim.advance(6.5)
		expect(toast.Visible).toBe(false)

		local banner = findDescendant(UIController.GetScreenGui(), "TutorialBanner")
		UIController.SetTutorial({ step = 0, title = "Welcome", body = "Hi", hint = "Tap Continue", dismissable = true })
		expect(banner.Visible).toBe(true)
		expectListedFits(banner)
		expect(findDescendant(banner, "Title").Text).toBe("Welcome")
		local fired = 0
		UIController.TutorialContinue:Connect(function()
			fired += 1
		end)
		findDescendant(banner, "ContinueButton").Activated:Fire()
		task.wait()
		expect(fired).toBe(1)
		UIController.SetTutorial(nil)
		expect(banner.Visible).toBe(false)
	end)

	it("settings.showMinimap hides the minimap and SetMinimap places stop dots", function()
		local Minimap = requireClient("UI/Minimap")
		expect(Minimap.IsVisible()).toBe(true)
		state.set("settings", { showMinimap = false })
		task.wait()
		expect(Minimap.IsVisible()).toBe(false)
		state.set("settings", { showMinimap = true })
		task.wait()
		expect(Minimap.IsVisible()).toBe(true)
		UIController.SetMinimap({ playerPosition = v3(100, 0, -50), heading = 0, stops = { { position = v3(200, 0, -50), kind = "deliver", current = true } }, path = { v3(100, 0, -50), v3(150, 0, -50), v3(200, 0, -50) } })
		local frame = Minimap.GetFrame()
		-- rotated road / path segments are only clipped by a CanvasGroup
		expect(frame.ClassName).toBe("CanvasGroup")
		expect(frame.ClipsDescendants).toBe(true)
		local dot = findDescendant(frame, "Stop1")
		expect(dot.Visible).toBe(true)
		expect(dot.Text).toBe("D")
		expect(findDescendant(frame, "Stop2").Visible).toBe(false)
		expect(findDescendant(frame, "Path1").Visible).toBe(true)
		expect(findDescendant(frame, "Path3").Visible).toBe(false)
		-- the world container is offset so the player sits at the centre (90 - 100*0.35 = 55)
		expect(frame.World.Position.X.Offset).toBeCloseTo(55, 1e-6)
	end)

	it("moves the minimap out of the touch thumbstick zone (top-left, 140 px, translucent) on touch", function()
		local Minimap = requireClient("UI/Minimap")
		local frame = Minimap.GetFrame()
		-- keyboard: opaque 180 px bottom-left
		expect(Minimap.IsTouchLayout()).toBe(false)
		expect(frame.Size.X.Offset).toBe(180)
		expect(frame.AnchorPoint).toEqual(Vector2.new(0, 1))
		expect(frame.Position.Y.Scale).toBe(1)
		expect(frame.BackgroundTransparency).toBe(0)
		state.set("device", "Touch")
		task.wait()
		expect(Minimap.IsTouchLayout()).toBe(true)
		expect(frame.Size).toEqual(UDim2.fromOffset(140, 140))
		expect(frame.AnchorPoint).toEqual(Vector2.new(0, 0))
		expect(frame.Position).toEqual(UDim2.new(0, 8, 0, Minimap.TOUCH_TOP))
		expect(Minimap.TOUCH_TOP).toBeGreaterThanOrEqual(96 + 30 + 3 * 24 + 8) -- below the mini-order list
		expect(frame.BackgroundTransparency).toBeCloseTo(0.4, 1e-6)
		-- the map stays centred on the player for the new size (70 - 100*0.35 = 35)
		expect(findDescendant(frame, "Player").Position).toEqual(UDim2.fromOffset(70, 70))
		UIController.SetMinimap({ playerPosition = v3(100, 0, -50), heading = 0, stops = {} })
		expect(frame.World.Position.X.Offset).toBeCloseTo(35, 1e-6)
		-- back to keyboard restores the bottom-left layout
		state.set("device", "Keyboard")
		task.wait()
		expect(Minimap.IsTouchLayout()).toBe(false)
		expect(frame.Size.X.Offset).toBe(180)
		expect(frame.AnchorPoint).toEqual(Vector2.new(0, 1))
		expect(frame.BackgroundTransparency).toBe(0)
		expect(findDescendant(frame, "Player").Position).toEqual(UDim2.fromOffset(90, 90))
	end)

	it("narrows the toast column on phone viewports so it never crosses the top-centre stack", function()
		local UIKit = requireClient("UI/UIKit")
		local hud = UIController.GetScreenGui()
		local topCenter = findDescendant(hud, "TopCenter")
		local toasts = findDescendant(hud, "Notifications")
		-- 1280x720 keyboard: full-width column
		expect(topCenter.Size.X.Offset).toBe(460)
		expect(toasts.Size.X.Offset).toBe(340)
		-- 667x375 touch: scale clamps to 0.75 (design viewport 889x500)
		workspace.CurrentCamera.ViewportSize = Vector2.new(667, 375)
		state.set("device", "Touch")
		task.wait()
		expect(hud.Scale.Scale).toBeCloseTo(0.75, 1e-6)
		local width = UIKit.contentWidth(hud)
		expect(width).toBeCloseTo(667 / 0.75, 1e-3)
		local centreWidth = topCenter.Size.X.Offset
		expect(centreWidth).toBeLessThan(400)
		local sideWidth = toasts.Size.X.Offset
		expect(sideWidth).toBeGreaterThanOrEqual(200)
		expect(sideWidth).toBeLessThan(340)
		-- right-anchored column at (width - 8) must start at or after the centre stack's right edge
		local stackRight = width / 2 + centreWidth / 2
		local toastLeft = width - 8 - sideWidth
		expect(toastLeft).toBeGreaterThanOrEqual(stackRight)
		-- toasts fill the column width, so they shrink with it
		UIController.Notify("Lunch Rush complete!", "success", 2)
		expect(findDescendant(toasts, "Toast_1").Size.X.Scale).toBe(1)
		-- restoring the viewport widens the column again
		workspace.CurrentCamera.ViewportSize = Vector2.new(1280, 720)
		state.set("device", "Keyboard")
		task.wait()
		expect(toasts.Size.X.Offset).toBe(340)
		expect(topCenter.Size.X.Offset).toBe(460)
	end)

	it("contains gamepad selection to the open screen and labels Close with the B hint", function()
		local UIKit = requireClient("UI/UIKit")
		local menus = UIController.GetMenuGui()
		expect(UIKit.getSelectionRoot()).toBeNil()
		UIController.OpenScreen("Orders")
		expect(UIKit.getSelectionRoot()).toBe(findDescendant(menus, "OrderBoard"))
		-- the group follows a screen switch
		UIController.OpenScreen("Shop")
		expect(UIKit.getSelectionRoot()).toBe(findDescendant(menus, "ShopMenu"))
		UIController.CloseScreen()
		expect(UIKit.getSelectionRoot()).toBeNil()
		-- Close button hint follows the device
		local close = findDescendant(findDescendant(menus, "ShopMenu"), "CloseButton")
		expect(close.Text).toBe("Close")
		state.set("device", "Gamepad")
		task.wait()
		expect(close.Text).toBe("Close (B)")
		expect(findDescendant(findDescendant(menus, "MenuHub"), "CloseButton").Text).toBe("Close (B)")
		state.set("device", "Keyboard")
		task.wait()
		expect(close.Text).toBe("Close")
	end)
end)

describe("OrderBoard", function()
	local OrderBoard, state, ctx, gui

	beforeEach(function()
		local Remotes = setupClient()
		Remotes.getFunction("AcceptOrder").OnServerInvoke = function(_, orderId)
			if orderId == "order-bad" then
				return { ok = false, error = "NoCapacity", message = "Server says: no room" }
			end
			return { ok = true }
		end
		state = makeFakeState({
			profile = makeProfile(),
			orders = {
				available = { makeOrder({ id = "order-1" }), makeOrder({ id = "order-big", size = "Large", sizeUnits = 4, itemLabel = "Party order (4 boxes)", timeLimit = nil }) },
				active = {},
				capacity = { current = 1, max = 2, load = 0, committed = 0 },
			},
		})
		ctx = makeCtx(state)
		OrderBoard = requireClient("UI/OrderBoard")
		gui = Instance.new("ScreenGui")
		gui.Parent = game:GetService("Players").LocalPlayer.PlayerGui
		OrderBoard.Mount(gui, ctx)
		OrderBoard.Update()
	end)

	it("renders a row per available order with business, item, address, pay and countdown", function()
		local list = OrderBoard.GetList("Available")
		local cards = cardsIn(list, "Order_")
		expect(#cards).toBe(2)
		local first = cards[1]
		expect(first:GetAttribute("OrderId")).toBe("order-1")
		expect(findDescendant(first, "Business").Text).toBe("Slice Street")
		expect(findDescendant(first, "Item").Text).toBe("Margherita pizza")
		expect(findDescendant(first, "Pay").Text).toBe("$40 + up to $12 tip")
		expect(findDescendant(first, "Destination").Text).toBe("To: 12 Plaza Apartments  -  Downtown")
		expect(findDescendant(first, "MetaText").Text).toBe("Small (1 unit)  -  250 studs  -  Limit 2:00")
		expect(findDescendant(first, "Expires").Text).toBe("Expires in 1:30")
		expect(findDescendant(first, "AcceptButton"):GetAttribute("Disabled")).toBeFalsy()
		expect(findDescendant(first, "ReasonLabel").Text).toBe("")
		for _, card in ipairs(cards) do
			expectListedFits(card)
		end
		OrderBoard.GetFrame().Visible = true
		shim.advance(30)
		OrderBoard.Tick()
		expect(findDescendant(first, "Expires").Text).toBe("Expires in 1:00")
	end)

	it("disables Accept with the capacity reason when committed + units exceed max", function()
		local list = OrderBoard.GetList("Available")
		local big = findDescendant(list, "Order_order-big")
		expect(findDescendant(big, "AcceptButton"):GetAttribute("Disabled")).toBe(true)
		expect(findDescendant(big, "ReasonLabel").Text).toBe("Not enough capacity: needs 4 units, 2 of 2 free")
		expect(OrderBoard.AcceptReason(makeOrder({ sizeUnits = 4 }), state)).toBe("Not enough capacity: needs 4 units, 2 of 2 free")
		expect(OrderBoard.AcceptReason(makeOrder({ sizeUnits = 2 }), state)).toBeNil()
	end)

	it("disables Accept while multi-order is locked and shows the server message on failure", function()
		-- 2 deliveries (< 3) with an active order -> locked
		state.set("profile", makeProfile({ stats = { deliveries = 2 } }))
		state.set("orders", {
			available = { makeOrder({ id = "order-1" }) },
			active = { makeOrder({ id = "order-active", state = "Accepted" }) },
			capacity = { current = 1, max = 3, load = 0, committed = 1 },
		})
		OrderBoard.Update()
		local row = findDescendant(OrderBoard.GetList("Available"), "Order_order-1")
		expect(findDescendant(row, "AcceptButton"):GetAttribute("Disabled")).toBe(true)
		expect(findDescendant(row, "ReasonLabel").Text).toMatch("Finish your current delivery first")

		-- server rejection is surfaced in the row
		state.set("profile", makeProfile({ stats = { deliveries = 10 } }))
		state.set("orders", {
			available = { makeOrder({ id = "order-bad" }) },
			active = {},
			capacity = { current = 1, max = 3, load = 0, committed = 0 },
		})
		OrderBoard.Update()
		row = findDescendant(OrderBoard.GetList("Available"), "Order_order-bad")
		findDescendant(row, "AcceptButton").Activated:Fire()
		task.wait()
		task.wait()
		row = findDescendant(OrderBoard.GetList("Available"), "Order_order-bad")
		expect(findDescendant(row, "ReasonLabel").Text).toBe("Server: Server says: no room")
	end)

	it("Lunch Rush tab lists offers with checkboxes, units total and a Join button gated by batch size", function()
		local now = state.serverNow()
		state.set("contract", {
			id = "LunchRush-1",
			neighborhood = "Downtown",
			status = "Open",
			closesAt = now + 100,
			nextAt = now + 500,
			eligible = true,
			offers = {
				makeOrder({ id = "offer-1", contractId = "LunchRush-1", basePay = 40 }),
				makeOrder({ id = "offer-2", contractId = "LunchRush-1", basePay = 30, sizeUnits = 2, size = "Medium" }),
				makeOrder({ id = "offer-3", contractId = "LunchRush-1", basePay = 30 }),
			},
			serverTime = now,
		})
		OrderBoard.SelectTab("Lunch Rush")
		local list = OrderBoard.GetList("Lunch Rush")
		expect(findDescendant(list, "Status").Text).toBe("OPEN in Downtown")
		expect(findDescendant(list, "Countdown").Text).toBe("Joinable for 1:40")
		expect(#cardsIn(list, "Offer_")).toBe(3)
		local join = findDescendant(list, "JoinButton")
		expect(join:GetAttribute("Disabled")).toBe(true)
		expect(findDescendant(list, "JoinError").Text).toBe("Select 2-4 offers")
		findDescendant(findDescendant(list, "Offer_offer-1"), "Checkbox").Activated:Fire()
		findDescendant(findDescendant(list, "Offer_offer-2"), "Checkbox").Activated:Fire()
		list = OrderBoard.GetList("Lunch Rush")
		expect(findDescendant(list, "SelectionText").Text).toBe("Selected 2 (need 2-4)  -  3 units of 2 max")
		expect(findDescendant(list, "JoinError").Text).toBe("Too many units for your best vehicle (3 of 2)")
		-- bonus preview: 40% of (40 + 30) + 60 = 88, 50 rep
		expect(findDescendant(list, "BonusPreview").Text).toBe("Bonus if all delivered on time: $88 + 50 Rep (on top of normal pay)")
		findDescendant(findDescendant(list, "Offer_offer-2"), "Checkbox").Activated:Fire()
		findDescendant(findDescendant(list, "Offer_offer-3"), "Checkbox").Activated:Fire()
		list = OrderBoard.GetList("Lunch Rush")
		expect(findDescendant(list, "JoinButton"):GetAttribute("Disabled")).toBeFalsy()
		expectListedFits(findDescendant(list, "Summary"))
		-- a server rejection stays visible in the summary after the board re-renders
		local joinArgs = nil
		ctx.remotes.getFunction("JoinContract").OnServerInvoke = function(_, contractId, orderIds)
			joinArgs = { contractId = contractId, orderIds = orderIds }
			return { ok = false, error = "NoCapacity", message = "Server says: too heavy" }
		end
		findDescendant(list, "JoinButton").Activated:Fire()
		task.wait()
		task.wait()
		expect(joinArgs.contractId).toBe("LunchRush-1")
		expect(joinArgs.orderIds).toEqual({ "offer-1", "offer-3" })
		list = OrderBoard.GetList("Lunch Rush")
		expect(findDescendant(list, "JoinError").Text).toBe("Server: Server says: too heavy")
		OrderBoard.Update()
		list = OrderBoard.GetList("Lunch Rush")
		expect(findDescendant(list, "JoinError").Text).toBe("Server: Server says: too heavy")
		-- a new rush drops the stale message
		state.set("contract", { id = "LunchRush-2", neighborhood = "Downtown", status = "Open", closesAt = now + 100, nextAt = now + 500, eligible = true, offers = { makeOrder({ id = "offer-9", contractId = "LunchRush-2" }) }, serverTime = now })
		OrderBoard.Update()
		list = OrderBoard.GetList("Lunch Rush")
		expect(findDescendant(list, "JoinError").Text).toBe("Select 2-4 offers")
		-- joined progress
		state.set("contract", { id = "LunchRush-1", neighborhood = "Downtown", status = "Grace", graceEndsAt = now + 83, nextAt = now + 500, joined = { orderIds = { "offer-1", "offer-3" }, deadline = now + 83, required = 2, done = 1 }, serverTime = now })
		OrderBoard.Update()
		list = OrderBoard.GetList("Lunch Rush")
		expect(findDescendant(list, "JoinedText").Text).toBe("1/2 delivered, deadline 1:23")
	end)
end)

describe("ActiveDeliveries", function()
	local ActiveDeliveries, state, ctx

	beforeEach(function()
		local Remotes = setupClient()
		Remotes.getFunction("CancelOrder").OnServerInvoke = function()
			return { ok = true }
		end
		state = makeFakeState({
			profile = makeProfile(),
			orders = {
				available = {},
				active = {
					makeOrder({ id = "a", state = "Accepted", acceptedAt = os.clock(), readyAt = os.clock() + 8 }),
					makeOrder({ id = "b", state = "Collected", destinationId = "dest-1" }),
					makeOrder({ id = "c", state = "ReadyForPickup", businessId = "BeanAndBunCafe" }),
				},
				capacity = { current = 3, max = 3, load = 1, committed = 4 },
			},
			positions = { SliceStreetPizza = v3(100, 0, 0), ["dest-1"] = v3(10, 0, 0), BeanAndBunCafe = v3(50, 0, 0) },
		})
		ctx = makeCtx(state)
		ActiveDeliveries = requireClient("UI/ActiveDeliveries")
		local gui = Instance.new("ScreenGui")
		gui.Parent = game:GetService("Players").LocalPlayer.PlayerGui
		ActiveDeliveries.Mount(gui, ctx)
		ActiveDeliveries.Update()
	end)

	it("renders stops with kind, state and distance", function()
		local cards = cardsIn(ActiveDeliveries.GetList(), "Stop_")
		expect(#cards).toBe(3)
		expect(findDescendant(cards[1], "Kind").Text).toBe("P  PICKUP")
		expect(findDescendant(cards[1], "Title").Text).toBe("1. Slice Street Pizza")
		expect(findDescendant(cards[1], "State").Text).toBe("Preparing 8s")
		expect(findDescendant(cards[1], "Distance").Text).toBe("100 studs")
		expect(findDescendant(cards[2], "Kind").Text).toBe("D  DELIVER")
		expect(findDescendant(cards[2], "Title").Text).toBe("2. 12 Plaza Apartments")
		expect(findDescendant(cards[2], "State").Text).toBe("Carrying")
		expect(findDescendant(cards[3], "State").Text).toBe("Ready for pickup")
		expect(findDescendant(cards[1], "UpButton"):GetAttribute("Disabled")).toBe(true)
		expect(findDescendant(cards[3], "DownButton"):GetAttribute("Disabled")).toBe(true)
		for _, card in ipairs(cards) do
			expectListedFits(card)
		end
	end)

	it("Up/Down/Set as next write ClientState.stopOrder", function()
		local cards = cardsIn(ActiveDeliveries.GetList(), "Stop_")
		findDescendant(cards[2], "UpButton").Activated:Fire()
		expect(state.get("stopOrder")).toEqual({ "b", "a", "c" })
		cards = cardsIn(ActiveDeliveries.GetList(), "Stop_")
		expect(cards[1]:GetAttribute("OrderId")).toBe("b")
		findDescendant(cards[1], "DownButton").Activated:Fire()
		expect(state.get("stopOrder")).toEqual({ "a", "b", "c" })
		cards = cardsIn(ActiveDeliveries.GetList(), "Stop_")
		findDescendant(cards[3], "NextButton").Activated:Fire()
		expect(state.get("stopOrder")).toEqual({ "c", "a", "b" })
	end)

	it("Suggested order sorts nearest-neighbour from the player and Cancel asks for confirmation", function()
		state.playerPosition = v3(0, 0, 0)
		findDescendant(ActiveDeliveries.GetFrame(), "SuggestButton").Activated:Fire()
		-- dest-1 at 10, cafe at 50, pizza at 100
		expect(state.get("stopOrder")).toEqual({ "b", "c", "a" })
		local cards = cardsIn(ActiveDeliveries.GetList(), "Stop_")
		local cancel = findDescendant(cards[1], "CancelButton")
		expect(cancel.Text).toBe("Cancel")
		cancel.Activated:Fire()
		cards = cardsIn(ActiveDeliveries.GetList(), "Stop_")
		cancel = findDescendant(cards[1], "CancelButton")
		expect(cancel.Text).toBe("Confirm (-2 Rep)") -- collected order warns about the penalty
		expect(findDescendant(cards[1], "KeepButton")).never.toBeNil()
		local calls = 0
		ctx.remotes.getFunction("CancelOrder").OnServerInvoke = function(_, orderId)
			calls += 1
			expect(orderId).toBe("b")
			return { ok = true }
		end
		cancel.Activated:Fire()
		task.wait()
		expect(calls).toBe(1)
	end)
end)

describe("ShopMenu", function()
	local ShopMenu, state, ctx

	beforeEach(function()
		setupClient()
		state = makeFakeState({ profile = makeProfile({ cash = 300, reputation = 100 }) })
		ctx = makeCtx(state)
		ShopMenu = requireClient("UI/ShopMenu")
		local gui = Instance.new("ScreenGui")
		gui.Parent = game:GetService("Players").LocalPlayer.PlayerGui
		ShopMenu.Mount(gui, ctx)
		ShopMenu.Update()
	end)

	it("shows Equipped / rep / cash reasons for vehicles", function()
		local list = ShopMenu.GetList("Vehicles")
		local bicycle = findDescendant(list, "Vehicle_Bicycle")
		local scooter = findDescendant(list, "Vehicle_Scooter")
		local van = findDescendant(list, "Vehicle_Van")
		expect(bicycle:GetAttribute("State")).toBe("Equipped")
		expect(findDescendant(bicycle, "StateButton").Text).toBe("Equipped")
		expect(scooter:GetAttribute("State")).toBe("Locked")
		expect(findDescendant(scooter, "ReasonLabel").Text).toBe("Needs 150 Rep")
		expect(findDescendant(van, "ReasonLabel").Text).toBe("Needs 600 Rep")
		expect(findDescendant(scooter, "Preview").ClassName).toBe("ViewportFrame")
		-- enough rep, not enough cash
		state.set("profile", makeProfile({ cash = 300, reputation = 200 }))
		ShopMenu.Update()
		scooter = findDescendant(ShopMenu.GetList("Vehicles"), "Vehicle_Scooter")
		expect(findDescendant(scooter, "ReasonLabel").Text).toBe("Not enough cash: $1,200 more")
		-- affordable -> Buy; owned but not equipped -> Equip
		state.set("profile", makeProfile({ cash = 2000, reputation = 200 }))
		ShopMenu.Update()
		scooter = findDescendant(ShopMenu.GetList("Vehicles"), "Vehicle_Scooter")
		expect(scooter:GetAttribute("State")).toBe("Buy")
		expect(findDescendant(scooter, "StateButton").Text).toBe("Buy $1,500")
		state.set("profile", makeProfile({ cash = 0, ownedVehicles = { Bicycle = true, Scooter = true }, equippedVehicle = "Bicycle" }))
		ShopMenu.Update()
		scooter = findDescendant(ShopMenu.GetList("Vehicles"), "Vehicle_Scooter")
		expect(scooter:GetAttribute("State")).toBe("Equip")
	end)

	it("reuses vehicle previews and buttons across Update() and rebuilds a preview only when its paint changes", function()
		local list = ShopMenu.GetList("Vehicles")
		local scooter = findDescendant(list, "Vehicle_Scooter")
		local preview = findDescendant(scooter, "Preview")
		local button = findDescendant(scooter, "StateButton")
		local model = preview:FindFirstChildOfClass("Model")
		expect(model).never.toBeNil()
		-- ProfileUpdated-style refreshes keep the card, the viewport, its model and the button
		state.set("profile", makeProfile({ cash = 2000, reputation = 200 }))
		ShopMenu.Update()
		ShopMenu.Update()
		expect(findDescendant(list, "Vehicle_Scooter")).toBe(scooter)
		expect(findDescendant(scooter, "Preview")).toBe(preview)
		expect(preview:FindFirstChildOfClass("Model")).toBe(model)
		expect(findDescendant(scooter, "StateButton")).toBe(button)
		expect(button.Text).toBe("Buy $1,500")
		expect(button:GetAttribute("Disabled")).toBe(false)
		expect(scooter:GetAttribute("State")).toBe("Buy")
		-- a gamepad-selected button survives the refresh
		local GuiService = game:GetService("GuiService")
		GuiService.SelectedObject = button
		ShopMenu.Update()
		expect(GuiService.SelectedObject).toBe(button)
		expect(button.Parent).never.toBeNil()
		-- equipped vehicle: same button, now disabled and marked Equipped
		state.set("profile", makeProfile({ cash = 0, ownedVehicles = { Bicycle = true, Scooter = true }, equippedVehicle = "Scooter" }))
		ShopMenu.Update()
		expect(findDescendant(scooter, "StateButton")).toBe(button)
		expect(button.Text).toBe("Equipped")
		expect(button:GetAttribute("Disabled")).toBe(true)
		expect(scooter:FindFirstChildOfClass("UIStroke").Enabled).toBe(true)
		expect(findDescendant(list, "Vehicle_Bicycle"):FindFirstChildOfClass("UIStroke").Enabled).toBe(false)
		-- a paint change (CosmeticsController colours) rebuilds just that preview
		local colors = { Primary = { 200, 40, 40 }, Accent = { 20, 20, 20 }, Decal = { 255, 255, 255 } }
		ctx.controllers.CosmeticsController = {
			GetVehicleColors = function(vehicleId)
				return colors
			end,
		}
		ShopMenu.Update()
		local rebuilt = findDescendant(scooter, "Preview")
		expect(rebuilt).never.toBe(preview)
		expect(preview.Parent).toBeNil()
		ShopMenu.Update()
		expect(findDescendant(scooter, "Preview")).toBe(rebuilt)
		colors = { Primary = { 10, 200, 90 }, Accent = { 20, 20, 20 }, Decal = { 255, 255, 255 } }
		ShopMenu.Update()
		expect(findDescendant(scooter, "Preview")).never.toBe(rebuilt)
		expect(findDescendant(scooter, "StateButton")).toBe(button)
	end)

	it("Looks tab shows Owned/Equipped/Buy/Store only states with swatches", function()
		ShopMenu.SelectTab("Looks")
		local list = ShopMenu.GetList("Looks")
		local red = findDescendant(list, "Cosmetic_BikeColor_Red")
		expect(red:GetAttribute("State")).toBe("Equipped") -- default item
		expect(red:FindFirstChild("Swatch1")).never.toBeNil()
		expect(red:FindFirstChild("Swatch2")).never.toBeNil()
		local mint = findDescendant(list, "Cosmetic_BikeColor_Mint")
		expect(mint:GetAttribute("State")).toBe("Buy")
		local sunset = findDescendant(list, "Cosmetic_BikeColor_Sunset")
		expect(sunset:GetAttribute("State")).toBe("Locked")
		expect(findDescendant(sunset, "ReasonLabel").Text).toBe("Not enough cash: $150 more")
		local neon = findDescendant(list, "Cosmetic_BikeColor_Neon")
		expect(neon:GetAttribute("State")).toBe("StoreOnly")
		expect(findDescendant(neon, "StateButton").Text).toBe("Store only")
		expect(findDescendant(neon, "StateButton"):GetAttribute("Disabled")).toBe(true)
	end)
end)

describe("UpgradeMenu", function()
	it("shows Owned / Buy / Locked with reasons and highlights Basket I in tutorial step 8", function()
		setupClient()
		local state = makeFakeState({ profile = makeProfile({ cash = 100, reputation = 10, upgrades = { ThermalBagI = 1 } }), tutorial = { step = 8, completed = false } })
		local ctx = makeCtx(state)
		local UpgradeMenu = requireClient("UI/UpgradeMenu")
		local gui = Instance.new("ScreenGui")
		gui.Parent = game:GetService("Players").LocalPlayer.PlayerGui
		UpgradeMenu.Mount(gui, ctx)
		UpgradeMenu.Update()
		local list = UpgradeMenu.GetList()
		local basket = findDescendant(list, "Upgrade_BasketI")
		for _, card in ipairs(cardsIn(list, "Upgrade_")) do
			expectListedFits(card)
		end
		expect(basket:GetAttribute("State")).toBe("Buy")
		expect(findDescendant(basket, "TutorialTag")).never.toBeNil()
		expect(findDescendant(list, "Upgrade_ThermalBagI"):GetAttribute("State")).toBe("Owned")
		local basket2 = findDescendant(list, "Upgrade_BasketII")
		expect(basket2:GetAttribute("State")).toBe("Locked")
		expect(findDescendant(basket2, "ReasonLabel").Text).toBe("Requires Basket I")
		local gears = findDescendant(list, "Upgrade_TunedGears")
		expect(findDescendant(gears, "ReasonLabel").Text).toBe("Needs 40 Rep")
		local topBox = findDescendant(list, "Upgrade_ScooterTopBoxI")
		expect(findDescendant(topBox, "ReasonLabel").Text).toBe("Requires the City Scooter")
		expect(UpgradeMenu.RequirementText(shim.requirePath("ReplicatedStorage/Shared/Definitions/UpgradeDefinitions").Upgrades.BasketII)).toBe("Requires 60 Rep, Basket I")
	end)
end)

describe("DepotMenu", function()
	local DepotMenu, state, ctx

	local function mount(initial)
		local Remotes = setupClient()
		Remotes.getFunction("CollectDepotEarnings").OnServerInvoke = function()
			return { ok = false, error = "TooFar", message = "You are too far from your depot" }
		end
		state = makeFakeState(initial)
		ctx = makeCtx(state)
		DepotMenu = requireClient("UI/DepotMenu")
		local gui = Instance.new("ScreenGui")
		gui.Parent = game:GetService("Players").LocalPlayer.PlayerGui
		DepotMenu.Mount(gui, ctx)
		DepotMenu.Update()
	end

	it("renders requirements and a disabled Buy Depot button when not owned", function()
		mount({ profile = makeProfile({ cash = 5000, reputation = 1200 }), depot = { owned = false, slotsUnlocked = 0, drivers = {}, pendingTotal = 0, categories = {}, serverTime = os.clock(), publicPlots = { { plotId = "PlotA", ownerName = "Zed", ownerUserId = 5, drivers = { { hired = true } } }, { plotId = "PlotB", ownerName = "", ownerUserId = 0, drivers = {} } } } })
		local list = DepotMenu.GetList()
		expect(findDescendant(list, "Purchase")).never.toBeNil()
		expect(findDescendant(list, "Requirements").Text).toBe("Requirements: $12,000 and 1,000 Rep")
		local buy = findDescendant(list, "BuyDepotButton")
		expectListedFits(findDescendant(list, "Purchase"))
		expect(buy:GetAttribute("Disabled")).toBe(true)
		expect(findDescendant(list, "ReasonLabel").Text).toBe("Not enough cash: $7,000 more")
		expect(findDescendant(list, "PublicTitle")).never.toBeNil()
		expect(findDescendant(list, "Plot_PlotA").Text).toBe("Plot PlotA  -  Zed  -  1 driver")
		expect(findDescendant(list, "Plot_PlotB").Text).toBe("Plot PlotB  -  for sale")
		state.set("profile", makeProfile({ cash = 20000, reputation = 1200 }))
		DepotMenu.Update()
		expect(findDescendant(DepotMenu.GetList(), "BuyDepotButton"):GetAttribute("Disabled")).toBe(false)
	end)

	it("renders slot cards, category picker, assignment progress and the TooFar collect note when owned", function()
		local now = os.time()
		mount({
			profile = makeProfile({ cash = 5000, reputation = 1200, depot = { owned = true, slotsUnlocked = 1, drivers = {} } }),
			depot = {
				owned = true,
				plotId = "PlotA",
				slotsUnlocked = 1,
				drivers = {
					{ hired = true, name = "Ava", pending = 0, assignment = { id = "as1", category = "DowntownFood", startedAt = now - 300, endsAt = now + 300, revenue = 900, cost = 300, net = 600, completed = false } },
					{ hired = false, pending = 0 },
				},
				pendingTotal = 450,
				categories = {
					{ id = "DowntownFood", name = "Downtown Food Run", unlocked = true, duration = 600, revenue = 900, cost = 300, net = 600 },
					{ id = "ResidentialGrocery", name = "Maple Hill Groceries", unlocked = false, duration = 720, revenue = 1300, cost = 450, net = 850, requirement = "Requires 1,200 Rep" },
				},
				serverTime = os.clock(),
			},
		})
		local list = DepotMenu.GetList()
		expect(findDescendant(list, "PlotTitle").Text).toBe("Your depot  -  plot PlotA")
		expect(findDescendant(list, "PendingText").Text).toBe("Pending earnings: $450")
		local slot1 = findDescendant(list, "Slot1")
		expectListedFits(slot1)
		expectListedFits(findDescendant(list, "Collect"))
		expect(slot1:GetAttribute("Status")).toBe("Working")
		expect(findDescendant(slot1, "TimeLeft").Text).toBe("Back in 5:00")
		expect(findDescendant(slot1, "Progress"):GetAttribute("Fraction")).toBeCloseTo(0.5, 1e-6)
		expect(findDescendant(slot1, "NetPreview").Text).toMatch("Net on return: %$600")
		local slot2 = findDescendant(list, "Slot2")
		expect(slot2:GetAttribute("Status")).toBe("Locked")
		expect(findDescendant(slot2, "UnlockButton").Text).toBe("Unlock slot 2 ($6,000)")
		expect(findDescendant(list, "Category_DowntownFood"):GetAttribute("Unlocked")).toBe(true)
		expect(findDescendant(findDescendant(list, "Category_ResidentialGrocery"), "PickButton"):GetAttribute("Disabled")).toBe(true)
		-- Collect while too far away explains what to do
		findDescendant(list, "CollectButton").Activated:Fire()
		task.wait()
		task.wait()
		expect(findDescendant(DepotMenu.GetList(), "CollectNote").Text).toBe("Go to your depot to collect.")

		-- idle driver: Assign needs a category, then picks one
		state.set("depot", {
			owned = true, plotId = "PlotA", slotsUnlocked = 2, pendingTotal = 0, serverTime = os.clock(),
			drivers = { { hired = true, name = "Ava", pending = 0 }, { hired = false, pending = 0 } },
			categories = { { id = "DowntownFood", name = "Downtown Food Run", unlocked = true, duration = 600, revenue = 900, cost = 300, net = 600 } },
		})
		DepotMenu.Update()
		list = DepotMenu.GetList()
		expect(findDescendant(list, "Slot1"):GetAttribute("Status")).toBe("Idle")
		expect(findDescendant(findDescendant(list, "Slot1"), "AssignButton"):GetAttribute("Disabled")).toBe(true)
		expect(findDescendant(findDescendant(list, "Slot1"), "ReasonLabel").Text).toBe("Pick a category below")
		expect(findDescendant(list, "Slot2"):GetAttribute("Status")).toBe("Empty")
		expect(findDescendant(findDescendant(list, "Slot2"), "HireButton").Text).toBe("Hire for $2,500")
		findDescendant(findDescendant(list, "Category_DowntownFood"), "PickButton").Activated:Fire()
		list = DepotMenu.GetList()
		expect(DepotMenu.GetSelectedCategory()).toBe("DowntownFood")
		expect(findDescendant(findDescendant(list, "Slot1"), "AssignButton"):GetAttribute("Disabled")).toBe(false)
		expect(findDescendant(findDescendant(list, "Slot1"), "AssignButton").Text).toBe("Assign ($300)")
	end)
end)

describe("SettingsMenu", function()
	it("writes ClientState.settings immediately and saves through SaveSettings after the debounce", function()
		local Remotes = setupClient()
		local saved = {}
		Remotes.getFunction("SaveSettings").OnServerInvoke = function(_, settings)
			table.insert(saved, settings)
			return { ok = true, settings = settings }
		end
		local state = makeFakeState({ profile = makeProfile(), settings = { cameraSensitivity = 1, reducedMotion = false, autoRecenter = true, musicVolume = 0.6, sfxVolume = 0.8, showMinimap = true, invertCameraY = false } })
		local ctx = makeCtx(state)
		local SettingsMenu = requireClient("UI/SettingsMenu")
		local gui = Instance.new("ScreenGui")
		gui.Parent = game:GetService("Players").LocalPlayer.PlayerGui
		SettingsMenu.Mount(gui, ctx)
		SettingsMenu.Update()
		local widgets = SettingsMenu.GetWidgets()
		widgets.showMinimap.button.Activated:Fire()
		expect(state.get("settings").showMinimap).toBe(false)
		widgets.cameraSensitivity.frame.Controls.Plus.Activated:Fire()
		expect(state.get("settings").cameraSensitivity).toBeCloseTo(1.1, 1e-6)
		expect(#saved).toBe(0)
		shim.advance(2)
		expect(#saved).toBe(1)
		expect(saved[1].showMinimap).toBe(false)
		expect(saved[1].cameraSensitivity).toBeCloseTo(1.1, 1e-6)
		-- controls reference uses the device glyphs
		expect(findDescendant(SettingsMenu.GetFrame(), "Control_DDC_Interact").Value.Text).toBe("E")
	end)
end)
