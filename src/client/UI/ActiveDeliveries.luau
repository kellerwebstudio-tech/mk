--!nonstrict
-- ActiveDeliveries: the player's active orders as an ordered list of stops. Up/Down/Set-as-next
-- rewrite ClientState.stopOrder, Cancel asks for confirmation (and warns about the -2 Rep penalty
-- for collected orders), "Suggested order" sorts stops nearest-neighbour from the player.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local EconomyConfig = require(Config:WaitForChild("EconomyConfig"))
local UIKit = require(script.Parent:WaitForChild("UIKit"))

local ActiveDeliveries = {}

ActiveDeliveries.Name = "Deliveries"

local ctx = nil
local modal = nil
local list: any = nil
local header: { [string]: any } = {}
local pendingCancel: string? = nil
local busy: { [string]: boolean } = {}
local rowRefs: { [string]: any } = {}

-------------------------------------------------------------------------------
-- Ordering helpers (pure)
-------------------------------------------------------------------------------

local function stops(): { any }
	if ctx and ctx.state and type(ctx.state.getOrderedStops) == "function" then
		local ok, result = pcall(ctx.state.getOrderedStops)
		if ok and type(result) == "table" then
			return result
		end
	end
	return {}
end

local function idsOf(stopList: { any }): { string }
	local ids = {}
	for _, stop in ipairs(stopList) do
		table.insert(ids, stop.order.id)
	end
	return ids
end

local function writeOrder(ids: { string })
	ctx.state.set("stopOrder", ids)
	ActiveDeliveries.Update()
end

-- Greedy nearest-neighbour chain from `from` over the current stops. Every order contributes a
-- single stop (its pickup while not collected, its door once collected), so pickups naturally
-- precede their deliveries.
function ActiveDeliveries.SuggestOrder(stopList: { any }, from: Vector3?): { string }
	local remaining = table.clone(stopList)
	local result = {}
	local origin = from
	while #remaining > 0 do
		local bestIndex = 1
		if origin then
			local bestDistance = math.huge
			for index, stop in ipairs(remaining) do
				local dx = stop.position.X - origin.X
				local dz = stop.position.Z - origin.Z
				local d = dx * dx + dz * dz
				if d < bestDistance then
					bestDistance = d
					bestIndex = index
				end
			end
		end
		local chosen = table.remove(remaining, bestIndex)
		table.insert(result, chosen.order.id)
		origin = chosen.position
	end
	return result
end

function ActiveDeliveries.MoveUp(index: number)
	local ids = idsOf(stops())
	if index <= 1 or index > #ids then
		return
	end
	ids[index - 1], ids[index] = ids[index], ids[index - 1]
	writeOrder(ids)
end

function ActiveDeliveries.MoveDown(index: number)
	local ids = idsOf(stops())
	if index < 1 or index >= #ids then
		return
	end
	ids[index], ids[index + 1] = ids[index + 1], ids[index]
	writeOrder(ids)
end

function ActiveDeliveries.SetNext(orderId: string)
	local ids = idsOf(stops())
	local position = table.find(ids, orderId)
	if not position then
		return
	end
	table.remove(ids, position)
	table.insert(ids, 1, orderId)
	writeOrder(ids)
end

function ActiveDeliveries.ApplySuggested()
	local ids = ActiveDeliveries.SuggestOrder(stops(), UIKit.playerPosition(ctx))
	writeOrder(ids)
end

local function stateText(order: any): string
	if order.state == "Accepted" then
		local readyAt = tonumber(order.readyAt) or ((tonumber(order.acceptedAt) or 0) + (tonumber(order.prepTime) or 0))
		local left = readyAt - ctx.state.serverNow()
		if left > 0.5 then
			return "Preparing " .. UIKit.formatSeconds(left)
		end
		return "Ready"
	elseif order.state == "ReadyForPickup" then
		return "Ready for pickup"
	elseif order.state == "Collected" then
		return "Carrying"
	end
	return tostring(order.state or "")
end

local function cancelOrder(orderId: string)
	if busy[orderId] then
		return
	end
	busy[orderId] = true
	pendingCancel = nil
	task.spawn(function()
		local result = UIKit.invoke(ctx, "CancelOrder", orderId)
		busy[orderId] = nil
		if result.ok then
			UIKit.notify(ctx, "Order cancelled.", "info", 3)
		else
			UIKit.notify(ctx, tostring(result.message or result.error or "Could not cancel"), "error", 4)
		end
		ActiveDeliveries.Update()
	end)
end

-------------------------------------------------------------------------------
-- Rendering
-------------------------------------------------------------------------------

local function buildRow(parent: Instance, stop: any, index: number, total: number)
	local order = stop.order
	local isPickup = stop.kind == "pickup"
	local card = UIKit.card(parent, { name = "Stop_" .. tostring(order.id), height = 140, layoutOrder = index, stroke = if index == 1 then UIKit.Theme.accent else nil })
	card:SetAttribute("OrderId", order.id)

	local top = UIKit.row(card, { name = "Top", size = UDim2.new(1, 0, 0, 26), layoutOrder = 1 })
	UIKit.pill(top, if isPickup then "P  PICKUP" else "D  DELIVER", { name = "Kind", color = if isPickup then UIKit.Theme.pickup else UIKit.Theme.deliver, textColor = UIKit.Theme.textOnAccent, width = 110, layoutOrder = 1 })
	local title = if isPickup then UIKit.businessName(order.businessId) else UIKit.destinationInfo(ctx, order.destinationId).address
	UIKit.label(top, string.format("%d. %s", index, title), { name = "Title", bold = true, size = UDim2.new(1, -200, 1, 0), layoutOrder = 2, maxSize = 18 })
	local distance = UIKit.distanceTo(ctx, stop.position)
	UIKit.label(top, if distance then UIKit.formatDistance(distance) else "", { name = "Distance", align = "Right", color = UIKit.Theme.textDim, size = UDim2.new(0, 80, 1, 0), layoutOrder = 3, maxSize = 16 })

	local destination = UIKit.destinationInfo(ctx, order.destinationId)
	UIKit.label(card, string.format("%s  ->  %s", tostring(order.itemLabel or ""), destination.address), { name = "Detail", color = UIKit.Theme.textDim, size = UDim2.new(1, 0, 0, 20), layoutOrder = 2, maxSize = 15 })
	local state = UIKit.label(card, stateText(order), { name = "State", color = if order.state == "Collected" then UIKit.Theme.success else UIKit.Theme.warning, size = UDim2.new(1, 0, 0, 20), layoutOrder = 3, maxSize = 15 })

	local actions = UIKit.row(card, { name = "Actions", size = UDim2.new(1, 0, 0, UIKit.MIN_HIT), layoutOrder = 4, gap = 6 })
	local up = UIKit.button(actions, "Up", function()
		ActiveDeliveries.MoveUp(index)
	end, { name = "UpButton", size = UDim2.new(0, 60, 0, UIKit.MIN_HIT), layoutOrder = 1 })
	local down = UIKit.button(actions, "Down", function()
		ActiveDeliveries.MoveDown(index)
	end, { name = "DownButton", size = UDim2.new(0, 72, 0, UIKit.MIN_HIT), layoutOrder = 2 })
	UIKit.setButtonEnabled(up, index > 1)
	UIKit.setButtonEnabled(down, index < total)
	local nextButton = UIKit.button(actions, "Set as next", function()
		ActiveDeliveries.SetNext(order.id)
	end, { name = "NextButton", size = UDim2.new(0, 120, 0, UIKit.MIN_HIT), layoutOrder = 3 })
	UIKit.setButtonEnabled(nextButton, index > 1)

	local cancelText = "Cancel"
	if pendingCancel == order.id then
		cancelText = if order.state == "Collected" then string.format("Confirm (-%d Rep)", EconomyConfig.cancelCollectedPenalty) else "Confirm cancel"
	end
	local cancel = UIKit.button(actions, cancelText, function()
		if pendingCancel == order.id then
			cancelOrder(order.id)
		else
			pendingCancel = order.id
			ActiveDeliveries.Update()
		end
	end, { name = "CancelButton", size = UDim2.new(0, 150, 0, UIKit.MIN_HIT), layoutOrder = 4, color = if pendingCancel == order.id then UIKit.Theme.error else UIKit.Theme.panelLight })
	if pendingCancel == order.id then
		UIKit.button(actions, "Keep", function()
			pendingCancel = nil
			ActiveDeliveries.Update()
		end, { name = "KeepButton", size = UDim2.new(0, 70, 0, UIKit.MIN_HIT), layoutOrder = 5 })
	end
	if busy[order.id] then
		UIKit.setButtonEnabled(cancel, false)
	end
	rowRefs[order.id] = { state = state, order = order }
end

function ActiveDeliveries.Mount(parent: Instance, context: any): Frame
	ctx = context
	modal = UIKit.modal(parent, "Active Deliveries", {
		name = "ActiveDeliveries",
		onClose = function()
			local controller = ctx.controllers and ctx.controllers.UIController
			if controller and type(controller.CloseScreen) == "function" then
				controller.CloseScreen(ActiveDeliveries.Name)
			end
		end,
	})
	local body = modal.body
	local toolbar = UIKit.row(body, { name = "Toolbar", size = UDim2.new(1, 0, 0, UIKit.MIN_HIT), gap = 8 })
	header.summary = UIKit.label(toolbar, "", { name = "Summary", color = UIKit.Theme.textDim, size = UDim2.new(1, -170, 1, 0), layoutOrder = 1, maxSize = 16 })
	header.suggest = UIKit.button(toolbar, "Suggested order", function()
		ActiveDeliveries.ApplySuggested()
	end, { name = "SuggestButton", size = UDim2.new(0, 160, 0, UIKit.MIN_HIT), layoutOrder = 2 })
	list = UIKit.scrollList(body, { name = "List", size = UDim2.new(1, 0, 1, -(UIKit.MIN_HIT + 8)), position = UDim2.new(0, 0, 0, UIKit.MIN_HIT + 8) })
	return modal.frame
end

function ActiveDeliveries.Update()
	if not modal then
		return
	end
	UIKit.clearChildren(list)
	rowRefs = {}
	local stopList = stops()
	local total = #stopList
	if pendingCancel then
		local stillThere = false
		for _, stop in ipairs(stopList) do
			if stop.order.id == pendingCancel then
				stillThere = true
			end
		end
		if not stillThere then
			pendingCancel = nil
		end
	end
	header.summary.Text = if total == 0 then "No active deliveries. Open Orders to accept one." else string.format("%d stop%s in order. Up/Down to reorder.", total, total == 1 and "" or "s")
	UIKit.setButtonEnabled(header.suggest, total > 1)
	for index, stop in ipairs(stopList) do
		buildRow(list, stop, index, total)
	end
end

function ActiveDeliveries.Tick()
	if not modal or not modal.frame.Visible then
		return
	end
	for _, refs in pairs(rowRefs) do
		if refs.state.Parent then
			refs.state.Text = stateText(refs.order)
		end
	end
end

function ActiveDeliveries.OnShow()
	pendingCancel = nil
	ActiveDeliveries.Update()
end

function ActiveDeliveries.GetFrame(): Frame?
	return modal and modal.frame
end

function ActiveDeliveries.GetList(): ScrollingFrame?
	return list
end

return ActiveDeliveries
