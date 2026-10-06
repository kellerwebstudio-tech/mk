--!nonstrict
-- HUD: the always-visible layer. Top-left cash + reputation (with progress to the next business
-- unlock) and an active-order mini list; top-right capacity meter plus Orders / Menu buttons;
-- bottom-centre compact navigation strip; bottom-right vehicle readout. The centre of the screen
-- stays empty so the road is visible. The root is a CanvasGroup so it can dim behind modals.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Definitions = Shared:WaitForChild("Definitions")
local BusinessDefinitions = require(Definitions:WaitForChild("BusinessDefinitions"))
local UIKit = require(script.Parent:WaitForChild("UIKit"))

local HUD = {}

HUD.MINI_ROWS = 3
HUD.LATE_SOON_FRACTION = 0.25
HUD.NAV_WIDTH_MAX = 420
HUD.NAV_WIDTH_MIN = 300
HUD.SIDE_RESERVE = 196 -- minimap (180 + margins) on the left, vehicle readout on the right

local TURN_GLYPHS = {
	Left = "<-",
	Right = "->",
	Straight = "^",
	SlightLeft = "<-",
	SlightRight = "->",
	UTurn = "U-turn",
	Arrive = "*",
}
local TURN_WORDS = {
	Left = "Turn left",
	Right = "Turn right",
	Straight = "Straight on",
	SlightLeft = "Slight left",
	SlightRight = "Slight right",
	UTurn = "Make a U-turn",
	Arrive = "Arrive",
}

local ctx = nil
local root: any = nil
local refs: { [string]: any } = {}
local miniRows: { any } = {}
local lastNav = nil

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

-- Sorted distinct reputation thresholds of businesses (excluding 0).
local function repThresholds(): { { rep: number, name: string } }
	local list = {}
	for _, id in ipairs(BusinessDefinitions.Order) do
		local def = BusinessDefinitions.Businesses[id]
		if def and def.repRequired > 0 then
			table.insert(list, { rep = def.repRequired, name = def.name })
		end
	end
	table.sort(list, function(a, b)
		return a.rep < b.rep
	end)
	return list
end

function HUD.NextUnlock(reputation: number): (number?, number, string?)
	local previous = 0
	for _, entry in ipairs(repThresholds()) do
		if reputation < entry.rep then
			return entry.rep, previous, entry.name
		end
		previous = entry.rep
	end
	return nil, previous, nil
end

local function stateGet(key: string)
	return ctx and ctx.state and ctx.state.get(key)
end

local function orderStateText(order: any): string
	if order.state == "Accepted" then
		local readyAt = tonumber(order.readyAt) or ((tonumber(order.acceptedAt) or 0) + (tonumber(order.prepTime) or 0))
		local left = readyAt - ctx.state.serverNow()
		if left > 0.5 then
			return "Preparing " .. UIKit.formatSeconds(left)
		end
		return "Ready"
	elseif order.state == "ReadyForPickup" then
		return "Ready"
	elseif order.state == "Collected" then
		return "Carrying"
	end
	return tostring(order.state)
end

-------------------------------------------------------------------------------
-- Build
-------------------------------------------------------------------------------

local function buildTopLeft(parent: Instance)
	local panel = UIKit.panel(parent, {
		name = "Wallet",
		color = UIKit.Theme.panel,
		transparency = 0.15,
		size = UDim2.new(0, 230, 0, 82),
		position = UDim2.new(0, 8, 0, 8),
		corner = 10,
	})
	UIKit.padding(panel, 6, 10, 6)
	refs.cash = UIKit.label(panel, "$0", { name = "Cash", bold = true, color = UIKit.Theme.success, size = UDim2.new(1, 0, 0, 28), maxSize = 26 })
	refs.rep = UIKit.label(panel, "Rep 0", { name = "Rep", size = UDim2.new(1, 0, 0, 18), position = UDim2.new(0, 0, 0, 28), maxSize = 16 })
	refs.repBar = UIKit.progressBar(panel, { name = "RepBar", size = UDim2.new(1, 0, 0, 6), position = UDim2.new(0, 0, 0, 50), color = UIKit.Theme.accent })
	refs.repNext = UIKit.label(panel, "", { name = "RepNext", color = UIKit.Theme.textDim, size = UDim2.new(1, 0, 0, 14), position = UDim2.new(0, 0, 0, 56), minSize = 12, maxSize = 13 })

	-- Active-order mini list (tap opens the Deliveries screen).
	local mini = Instance.new("TextButton")
	mini.Name = "MiniOrders"
	mini.AutoButtonColor = false
	mini.Text = ""
	mini.BackgroundColor3 = UIKit.Theme.panel
	mini.BackgroundTransparency = 0.2
	mini.BorderSizePixel = 0
	mini.Size = UDim2.new(0, 230, 0, 30 + HUD.MINI_ROWS * 24)
	mini.Position = UDim2.new(0, 8, 0, 96)
	mini.Visible = false
	UIKit.corner(mini, 10)
	UIKit.padding(mini, 4, 8, 4)
	mini.Activated:Connect(function()
		UIKit.openScreen(ctx, "Deliveries")
	end)
	mini.Parent = parent
	refs.mini = mini
	refs.miniTitle = UIKit.label(mini, "Deliveries", { name = "Title", bold = true, color = UIKit.Theme.textDim, size = UDim2.new(1, 0, 0, 20), maxSize = 14 })
	for index = 1, HUD.MINI_ROWS do
		local row = UIKit.panel(mini, { name = "Row" .. index, transparency = 1, corner = false, size = UDim2.new(1, 0, 0, 22), position = UDim2.new(0, 0, 0, 22 + (index - 1) * 24) })
		local kind = UIKit.pill(row, "P", { name = "Kind", width = 24, size = UDim2.new(0, 24, 0, 20), color = UIKit.Theme.pickup, textColor = UIKit.Theme.textOnAccent, maxSize = 14 })
		kind.Position = UDim2.new(0, 0, 0.5, 0)
		kind.AnchorPoint = Vector2.new(0, 0.5)
		local name = UIKit.label(row, "", { name = "Name", size = UDim2.new(1, -92, 1, 0), position = UDim2.new(0, 30, 0, 0), maxSize = 14 })
		local distance = UIKit.label(row, "", { name = "Distance", color = UIKit.Theme.textDim, size = UDim2.new(0, 60, 1, 0), position = UDim2.new(1, -60, 0, 0), align = "Right", maxSize = 14 })
		miniRows[index] = { frame = row, kind = kind, name = name, distance = distance }
	end
end

local function buildTopRight(parent: Instance)
	local panel = UIKit.panel(parent, {
		name = "Capacity",
		color = UIKit.Theme.panel,
		transparency = 0.15,
		size = UDim2.new(0, 170, 0, 50),
		position = UDim2.new(1, -8, 0, 8),
		anchor = Vector2.new(1, 0),
		corner = 10,
	})
	UIKit.padding(panel, 6, 10, 6)
	refs.loadText = UIKit.label(panel, "Load 0/1", { name = "LoadText", bold = true, size = UDim2.new(1, 0, 0, 22), maxSize = 18 })
	refs.loadBar = UIKit.progressBar(panel, { name = "LoadBar", size = UDim2.new(1, 0, 0, 8), position = UDim2.new(0, 0, 0, 28), color = UIKit.Theme.accent })

	local buttons = UIKit.row(parent, { name = "Buttons", size = UDim2.new(0, 230, 0, UIKit.MIN_HIT), position = UDim2.new(1, -8, 0, 66), anchor = Vector2.new(1, 0), gap = 8, halign = "Right" })
	refs.ordersButton = UIKit.primaryButton(buttons, "Orders", function()
		UIKit.openScreen(ctx, "Orders")
	end, { name = "OrdersButton", size = UDim2.new(0, 110, 0, UIKit.MIN_HIT), layoutOrder = 1 })
	refs.menuButton = UIKit.button(buttons, "Menu", function()
		UIKit.openScreen(ctx, "Menu")
	end, { name = "MenuButton", size = UDim2.new(0, 100, 0, UIKit.MIN_HIT), layoutOrder = 2 })
end

local function buildNavStrip(parent: Instance)
	local strip = UIKit.panel(parent, {
		name = "NavStrip",
		color = UIKit.Theme.panel,
		transparency = 0.1,
		size = UDim2.new(0, 420, 0, 76),
		position = UDim2.new(0.5, 0, 1, -8),
		anchor = Vector2.new(0.5, 1),
		corner = 12,
		stroke = true,
		visible = false,
	})
	refs.nav = strip
	refs.turnGlyph = UIKit.label(strip, "^", {
		name = "TurnGlyph",
		bg = UIKit.Theme.accent,
		color = UIKit.Theme.textOnAccent,
		bold = true,
		align = "Center",
		size = UDim2.new(0, 64, 0, 60),
		position = UDim2.new(0, 8, 0.5, 0),
		anchor = Vector2.new(0, 0.5),
		maxSize = 26,
		corner = 10,
	})
	refs.turnText = UIKit.label(strip, "", { name = "TurnText", bold = true, size = UDim2.new(1, -170, 0, 26), position = UDim2.new(0, 80, 0, 6), maxSize = 20 })
	refs.destination = UIKit.label(strip, "", { name = "Destination", size = UDim2.new(1, -170, 0, 22), position = UDim2.new(0, 80, 0, 30), maxSize = 16 })
	refs.address = UIKit.label(strip, "", { name = "Address", color = UIKit.Theme.textDim, size = UDim2.new(1, -170, 0, 18), position = UDim2.new(0, 80, 0, 52), minSize = 12, maxSize = 14 })
	refs.distance = UIKit.label(strip, "", { name = "Distance", bold = true, align = "Right", size = UDim2.new(0, 80, 0, 26), position = UDim2.new(1, -8, 0, 6), anchor = Vector2.new(1, 0), maxSize = 20 })
	refs.timer = UIKit.label(strip, "", { name = "Timer", align = "Right", size = UDim2.new(0, 110, 0, 20), position = UDim2.new(1, -8, 0, 32), anchor = Vector2.new(1, 0), maxSize = 16 })
	refs.timerNote = UIKit.label(strip, "", { name = "TimerNote", align = "Right", color = UIKit.Theme.warning, bold = true, size = UDim2.new(0, 110, 0, 18), position = UDim2.new(1, -8, 0, 52), anchor = Vector2.new(1, 0), minSize = 12, maxSize = 14 })
end

local function buildVehicleHud(parent: Instance)
	local panel = UIKit.panel(parent, {
		name = "VehicleHud",
		color = UIKit.Theme.panel,
		transparency = 0.2,
		size = UDim2.new(0, 150, 0, 56),
		position = UDim2.new(1, -8, 1, -8),
		anchor = Vector2.new(1, 1),
		corner = 10,
		visible = false,
	})
	UIKit.padding(panel, 6, 10, 6)
	refs.vehicleName = UIKit.label(panel, "", { name = "VehicleName", bold = true, size = UDim2.new(1, 0, 0, 20), maxSize = 16 })
	refs.speedBar = UIKit.progressBar(panel, { name = "SpeedBar", size = UDim2.new(1, 0, 0, 6), position = UDim2.new(0, 0, 0, 24), color = UIKit.Theme.info })
	refs.vehicleLoad = UIKit.label(panel, "", { name = "VehicleLoad", color = UIKit.Theme.textDim, size = UDim2.new(1, 0, 0, 14), position = UDim2.new(0, 0, 0, 32), minSize = 12, maxSize = 13 })
end

function HUD.Mount(parent: Instance, context: any): CanvasGroup
	ctx = context
	root = Instance.new("CanvasGroup")
	root.Name = "HUD"
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromScale(1, 1)
	root.Parent = parent

	buildTopLeft(root)
	buildTopRight(root)
	buildNavStrip(root)
	buildVehicleHud(root)
	HUD.Update()
	HUD.Relayout()
	pcall(function()
		root:GetPropertyChangedSignal("AbsoluteSize"):Connect(HUD.Relayout)
	end)
	return root
end

-- Narrow (phone) viewports: the bottom nav strip shrinks so it never covers the minimap or the
-- vehicle readout. Width is measured in scaled design units.
function HUD.Relayout()
	if not root then
		return
	end
	local width = UIKit.contentWidth(root.Parent)
	local navWidth = math.clamp(width - 2 * HUD.SIDE_RESERVE - 16, HUD.NAV_WIDTH_MIN, HUD.NAV_WIDTH_MAX)
	refs.nav.Size = UDim2.new(0, navWidth, 0, 76)
end

-------------------------------------------------------------------------------
-- Updates
-------------------------------------------------------------------------------

local function updateWallet()
	local profile = stateGet("profile")
	local cash = profile and tonumber(profile.cash) or 0
	local rep = profile and tonumber(profile.reputation) or 0
	refs.cash.Text = UIKit.formatCash(cash)
	refs.rep.Text = string.format("Rep %d", rep)
	local nextRep, previousRep, nextName = HUD.NextUnlock(rep)
	if nextRep then
		local span = math.max(1, nextRep - previousRep)
		refs.repBar.set((rep - previousRep) / span)
		refs.repNext.Text = string.format("%d Rep unlocks %s", nextRep, nextName)
	else
		refs.repBar.set(1)
		refs.repNext.Text = "All businesses unlocked"
	end
end

local function updateCapacity()
	local orders = stateGet("orders")
	local capacity = orders and orders.capacity
	if type(capacity) == "table" then
		local load = tonumber(capacity.load) or 0
		local current = math.max(1, tonumber(capacity.current) or 1)
		refs.loadText.Text = string.format("Load %d/%d", load, current)
		refs.loadBar.set(load / current, if load >= current then UIKit.Theme.warning else UIKit.Theme.accent)
	else
		refs.loadText.Text = "Load 0/1"
		refs.loadBar.set(0)
	end
end

local function updateMiniList()
	local stops = {}
	if ctx and ctx.state and type(ctx.state.getOrderedStops) == "function" then
		local ok, result = pcall(ctx.state.getOrderedStops)
		if ok and type(result) == "table" then
			stops = result
		end
	end
	local count = #stops
	refs.mini.Visible = count > 0
	if count == 0 then
		return
	end
	refs.miniTitle.Text = string.format("Deliveries (%d)%s", count, if count > HUD.MINI_ROWS then " - tap for all" else "")
	for index, row in ipairs(miniRows) do
		local stop = stops[index]
		if stop then
			local isPickup = stop.kind == "pickup"
			row.kind.Text = if isPickup then "P" else "D"
			row.kind.BackgroundColor3 = if isPickup then UIKit.Theme.pickup else UIKit.Theme.deliver
			local name = if isPickup then UIKit.businessShortName(stop.order.businessId) else UIKit.shortAddress(stop.address or stop.label or "")
			row.name.Text = string.format("%s - %s", name, orderStateText(stop.order))
			local distance = UIKit.distanceTo(ctx, stop.position)
			row.distance.Text = if distance then UIKit.formatStuds(distance) else ""
			row.frame.Visible = true
		else
			row.frame.Visible = false
		end
	end
end

-- Full refresh from ClientState (profile / orders).
function HUD.Update()
	if not root then
		return
	end
	updateWallet()
	updateCapacity()
	updateMiniList()
end

-- Once per second: countdowns and distances in the mini list.
function HUD.Tick()
	if root and refs.mini.Visible then
		updateMiniList()
	end
end

-- Finds the time limit of the active order whose remaining time matches timeLeft (for the 25% rule).
local function timeLimitFor(timeLeft: number): number?
	local orders = stateGet("orders")
	local active = orders and orders.active
	if type(active) ~= "table" then
		return nil
	end
	local now = ctx.state.serverNow()
	local best, bestDelta = nil, 3
	for _, order in ipairs(active) do
		if type(order.timeLimit) == "number" and type(order.acceptedAt) == "number" then
			local remaining = order.acceptedAt + order.timeLimit - now
			local delta = math.abs(remaining - timeLeft)
			if delta < bestDelta then
				best, bestDelta = order.timeLimit, delta
			end
		end
	end
	return best
end

-- nav = { active, label?, stopKind?, distance?, turnKind?, turnDistance?, timeLeft?, address? }
function HUD.SetNavigation(nav: any)
	if not root then
		return
	end
	lastNav = nav
	if type(nav) ~= "table" or not nav.active then
		refs.nav.Visible = false
		return
	end
	local kind = nav.turnKind or "Straight"
	local glyph = TURN_GLYPHS[kind] or "^"
	local words = TURN_WORDS[kind] or kind
	refs.turnGlyph.Text = glyph
	refs.turnGlyph.BackgroundColor3 = if nav.stopKind == "pickup" then UIKit.Theme.pickup else UIKit.Theme.deliver
	if kind == "Arrive" then
		refs.turnText.Text = string.format("Arrive - %s", if nav.stopKind == "pickup" then "collect order" else "deliver")
	elseif type(nav.turnDistance) == "number" then
		refs.turnText.Text = string.format("%s in %s", words, UIKit.formatDistance(nav.turnDistance))
	else
		refs.turnText.Text = words
	end
	local prefix = if nav.stopKind == "pickup" then "PICKUP: " elseif nav.stopKind == "deliver" then "DELIVER: " else ""
	refs.destination.Text = prefix .. tostring(nav.label or "")
	refs.address.Text = tostring(nav.address or "")
	refs.distance.Text = if type(nav.distance) == "number" then UIKit.formatStuds(nav.distance) else ""

	local timeLeft = tonumber(nav.timeLeft)
	if timeLeft then
		local limit = timeLimitFor(timeLeft)
		local lateSoon = (limit and timeLeft <= limit * HUD.LATE_SOON_FRACTION) or (not limit and timeLeft <= 30)
		if timeLeft <= 0 then
			refs.timer.Text = "Late " .. UIKit.formatTime(-timeLeft)
			refs.timer.TextColor3 = UIKit.Theme.error
			refs.timerNote.Text = "Tip shrinking"
			refs.timerNote.TextColor3 = UIKit.Theme.error
		else
			refs.timer.Text = "Time " .. UIKit.formatTime(timeLeft)
			refs.timer.TextColor3 = if lateSoon then UIKit.Theme.warning else UIKit.Theme.text
			refs.timerNote.Text = if lateSoon then "Late soon" else ""
			refs.timerNote.TextColor3 = UIKit.Theme.warning
		end
		refs.timer.Visible = true
	else
		refs.timer.Text = ""
		refs.timerNote.Text = ""
	end
	refs.nav.Visible = true
end

function HUD.GetNavigation()
	return lastNav
end

-- data = { state?, vehicleId?, speedFraction, loadText }
function HUD.SetVehicleHud(data: any)
	if not root then
		return
	end
	local panel = root:FindFirstChild("VehicleHud")
	if type(data) ~= "table" or data.state ~= "Driving" then
		panel.Visible = false
		return
	end
	refs.vehicleName.Text = tostring(data.vehicleId or "Vehicle")
	refs.speedBar.set(math.clamp(tonumber(data.speedFraction) or 0, 0, 1))
	refs.vehicleLoad.Text = if data.loadText and data.loadText ~= "" then "Load " .. tostring(data.loadText) else ""
	panel.Visible = true
end

-- Dims the HUD while a modal is open.
function HUD.SetDimmed(dimmed: boolean)
	if not root then
		return
	end
	UIKit.tween(root, { GroupTransparency = if dimmed then 0.45 else 0 }, 0.15)
end

function HUD.GetRoot(): CanvasGroup?
	return root
end

function HUD.GetRefs()
	return refs
end

return HUD
