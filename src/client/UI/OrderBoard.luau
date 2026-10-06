--!nonstrict
-- OrderBoard: modal with "Available" and "Lunch Rush" tabs. Available lists the board with an
-- Accept button per order (disabled locally with a reason when capacity or the multi-order lock
-- forbids it; server error messages are shown too). Lunch Rush shows the ContractPublicState with
-- offer checkboxes, a Join button, joined progress and a bonus preview.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Definitions = Shared:WaitForChild("Definitions")
local EconomyConfig = require(Config:WaitForChild("EconomyConfig"))
local ContractDefinitions = require(Definitions:WaitForChild("ContractDefinitions"))
local OrderDefinitions = require(Definitions:WaitForChild("OrderDefinitions"))
local UIKit = require(script.Parent:WaitForChild("UIKit"))

local OrderBoard = {}

OrderBoard.Name = "Orders"

local ctx = nil
local modal = nil
local tabs = nil
local pages: { [string]: any } = {}
local rowRefs = {} -- orderId -> { expires = TextLabel, reason = TextLabel, accept = TextButton }
local contractRefs: { [string]: any } = {}
local selectedOffers: { [string]: boolean } = {}
local busyOrders: { [string]: boolean } = {}
local serverMessages: { [string]: string } = {} -- last server rejection per order (survives re-renders)
local joining = false
local joinMessage: string? = nil -- last server rejection of Join (survives re-renders)
local joinMessageContractId: string? = nil
local currentTab = "Available"

-------------------------------------------------------------------------------
-- Pure helpers (also used by tests)
-------------------------------------------------------------------------------

local function tutorialComplete(state): boolean
	local profile = state.get("profile")
	if profile and type(profile.tutorial) == "table" and profile.tutorial.completed then
		return true
	end
	local tutorial = state.get("tutorial")
	return tutorial ~= nil and tutorial.completed == true
end

-- nil when the order can be accepted, else the reason text.
function OrderBoard.AcceptReason(order: any, state: any): string?
	local orders = state.get("orders") or {}
	local profile = state.get("profile")
	local active = type(orders.active) == "table" and orders.active or {}
	local capacity = orders.capacity
	local units = tonumber(order.sizeUnits) or OrderDefinitions.unitsFor(order.size or "Small")

	if #active > 0 then
		local deliveries = profile and profile.stats and tonumber(profile.stats.deliveries) or 0
		local unlocked = tutorialComplete(state) and deliveries >= EconomyConfig.multiOrderUnlockDeliveries
		if not unlocked then
			if not tutorialComplete(state) then
				return "Finish your current delivery first (tutorial)"
			end
			return string.format("Finish your current delivery first (carrying several orders unlocks after %d deliveries)", EconomyConfig.multiOrderUnlockDeliveries)
		end
	end
	if type(capacity) == "table" then
		local committed = tonumber(capacity.committed) or 0
		local max = tonumber(capacity.max) or 1
		if committed + units > max then
			return string.format("Not enough capacity: needs %s, %d of %d free", UIKit.formatUnits(units), math.max(0, max - committed), max)
		end
	end
	return nil
end

function OrderBoard.BonusPreview(offers: { any }): (number, number)
	local base = 0
	for _, order in ipairs(offers) do
		base += tonumber(order.basePay) or 0
	end
	local def = ContractDefinitions.LunchRush
	return math.floor(base * def.bonusFraction + def.flatBonus + 0.5), def.repBonus
end

local function sizeText(order: any): string
	local units = tonumber(order.sizeUnits) or OrderDefinitions.unitsFor(order.size or "Small")
	return string.format("%s (%s)", tostring(order.size or "Small"), UIKit.formatUnits(units))
end

local function payText(order: any): string
	return string.format("%s + up to %s tip", UIKit.formatCash(order.basePay), UIKit.formatCash(order.tipMax))
end

-------------------------------------------------------------------------------
-- Available tab
-------------------------------------------------------------------------------

local function acceptOrder(orderId: string)
	if busyOrders[orderId] then
		return
	end
	busyOrders[orderId] = true
	local refs = rowRefs[orderId]
	if refs then
		UIKit.setButtonEnabled(refs.accept, false)
		refs.accept.Text = "..."
	end
	task.spawn(function()
		local result = UIKit.invoke(ctx, "AcceptOrder", orderId)
		busyOrders[orderId] = nil
		if result.ok then
			serverMessages[orderId] = nil
			UIKit.notify(ctx, "Order accepted. Head to the pickup.", "success", 3)
		else
			local message = tostring(result.message or result.error or "Could not accept")
			serverMessages[orderId] = message
			UIKit.notify(ctx, message, "error", 4)
		end
		OrderBoard.Update()
	end)
end

local function buildOrderRow(parent: Instance, order: any, index: number): Frame
	local card = UIKit.card(parent, { name = "Order_" .. tostring(order.id), height = 150, layoutOrder = index, stroke = UIKit.businessAccent(order.businessId) })
	card:SetAttribute("OrderId", order.id)

	local top = UIKit.row(card, { name = "Top", size = UDim2.new(1, 0, 0, 26), layoutOrder = 1 })
	UIKit.pill(top, UIKit.businessShortName(order.businessId), { name = "Business", color = UIKit.businessAccent(order.businessId), textColor = UIKit.Theme.textOnAccent, width = 110, layoutOrder = 1 })
	UIKit.label(top, tostring(order.itemLabel or ""), { name = "Item", bold = true, size = UDim2.new(1, -260, 1, 0), layoutOrder = 2, maxSize = 20 })
	UIKit.label(top, payText(order), { name = "Pay", color = UIKit.Theme.success, bold = true, align = "Right", size = UDim2.new(0, 140, 1, 0), layoutOrder = 3, maxSize = 16 })

	local info = UIKit.destinationInfo(ctx, order.destinationId)
	UIKit.label(card, string.format("To: %s  -  %s", info.address, UIKit.neighborhoodName(ctx, info.neighborhood)), { name = "Destination", size = UDim2.new(1, 0, 0, 20), layoutOrder = 2, maxSize = 16 })

	local meta = {
		sizeText(order),
		UIKit.formatDistance(order.routeDistance),
	}
	if type(order.timeLimit) == "number" then
		table.insert(meta, "Limit " .. UIKit.formatTime(order.timeLimit))
	end
	local metaRow = UIKit.row(card, { name = "Meta", size = UDim2.new(1, 0, 0, 20), layoutOrder = 3 })
	UIKit.label(metaRow, table.concat(meta, "  -  "), { name = "MetaText", color = UIKit.Theme.textDim, size = UDim2.new(1, -140, 1, 0), layoutOrder = 1, maxSize = 15 })
	local expires = UIKit.label(metaRow, "", { name = "Expires", color = UIKit.Theme.warning, align = "Right", size = UDim2.new(0, 134, 1, 0), layoutOrder = 2, maxSize = 15 })

	local actions = UIKit.row(card, { name = "Actions", size = UDim2.new(1, 0, 0, UIKit.MIN_HIT), layoutOrder = 4 })
	local accept = UIKit.primaryButton(actions, "Accept", function()
		acceptOrder(order.id)
	end, { name = "AcceptButton", size = UDim2.new(0, 120, 0, UIKit.MIN_HIT), layoutOrder = 1 })
	local reason = UIKit.label(actions, "", { name = "ReasonLabel", color = UIKit.Theme.warning, size = UDim2.new(1, -130, 1, 0), layoutOrder = 2, maxSize = 15 })

	local blockReason = OrderBoard.AcceptReason(order, ctx.state)
	if blockReason then
		UIKit.setButtonEnabled(accept, false)
		reason.Text = blockReason
	elseif serverMessages[order.id] then
		reason.Text = "Server: " .. serverMessages[order.id]
	else
		reason.Text = ""
	end
	if busyOrders[order.id] then
		UIKit.setButtonEnabled(accept, false)
		accept.Text = "..."
	end
	rowRefs[order.id] = { expires = expires, reason = reason, accept = accept, availableUntil = order.availableUntil }
	return card
end

local function updateCountdowns()
	local now = ctx.state.serverNow()
	for _, refs in pairs(rowRefs) do
		if refs.expires.Parent then
			local left = (tonumber(refs.availableUntil) or now) - now
			if left > 36000 then
				refs.expires.Text = ""
			else
				refs.expires.Text = "Expires in " .. UIKit.formatSeconds(math.max(0, left))
			end
		end
	end
end

local function renderAvailable()
	local list = pages.Available.list
	UIKit.clearChildren(list)
	rowRefs = {}
	local orders = ctx.state.get("orders") or {}
	local available = type(orders.available) == "table" and orders.available or {}
	-- Forget server messages for orders that left the board.
	local present = {}
	for _, order in ipairs(available) do
		present[order.id] = true
	end
	for id in pairs(serverMessages) do
		if not present[id] then
			serverMessages[id] = nil
		end
	end
	-- Contract offers live on the Lunch Rush tab.
	local shown = 0
	for _, order in ipairs(available) do
		if not order.contractId then
			shown += 1
			buildOrderRow(list, order, shown)
		end
	end
	if shown == 0 then
		UIKit.label(list, "No orders right now. New orders arrive every few seconds.", { name = "Empty", color = UIKit.Theme.textDim, align = "Center", size = UDim2.new(1, 0, 0, 60), maxSize = 18 })
	end
	local capacity = orders.capacity
	if type(capacity) == "table" then
		pages.Available.summary.Text = string.format("Committed %d of %d units  -  carrying %d", tonumber(capacity.committed) or 0, tonumber(capacity.max) or 1, tonumber(capacity.load) or 0)
	else
		pages.Available.summary.Text = ""
	end
	updateCountdowns()
end

-------------------------------------------------------------------------------
-- Lunch Rush tab
-------------------------------------------------------------------------------

local function selectedList(offers: { any }): { any }
	local picked = {}
	for _, order in ipairs(offers) do
		if selectedOffers[order.id] then
			table.insert(picked, order)
		end
	end
	return picked
end

local function joinContract(contract: any)
	if joining then
		return
	end
	local offers = type(contract.offers) == "table" and contract.offers or {}
	local ids = {}
	for _, order in ipairs(selectedList(offers)) do
		table.insert(ids, order.id)
	end
	joining = true
	task.spawn(function()
		local result = UIKit.invoke(ctx, "JoinContract", contract.id or ContractDefinitions.LunchRush.id, ids)
		joining = false
		if result.ok then
			selectedOffers = {}
			joinMessage = nil
			UIKit.notify(ctx, "Joined the Lunch Rush. Deliver the batch before the deadline!", "success", 4)
		else
			local message = tostring(result.message or result.error or "Could not join")
			joinMessage = message
			joinMessageContractId = contract.id
			UIKit.notify(ctx, message, "error", 4)
		end
		OrderBoard.Update()
	end)
end

local function contractStatusText(contract: any): (string, string)
	local now = ctx.state.serverNow()
	local neighborhood = UIKit.neighborhoodName(ctx, contract.neighborhood)
	if contract.status == "Open" then
		local closes = (tonumber(contract.closesAt) or now) - now
		return string.format("OPEN in %s", neighborhood), string.format("Joinable for %s", UIKit.formatTime(math.max(0, closes)))
	elseif contract.status == "Grace" then
		local graceEnds = (tonumber(contract.graceEndsAt) or now) - now
		return string.format("Finishing in %s", neighborhood), string.format("Batches must finish within %s", UIKit.formatTime(math.max(0, graceEnds)))
	end
	local nextAt = (tonumber(contract.nextAt) or now) - now
	return "No rush right now", string.format("Next Lunch Rush in %s", UIKit.formatTime(math.max(0, nextAt)))
end

local function renderContract()
	local list = pages["Lunch Rush"].list
	UIKit.clearChildren(list)
	contractRefs = {}
	local def = ContractDefinitions.LunchRush
	local contract = ctx.state.get("contract")

	UIKit.label(list, def.name, { name = "ContractName", bold = true, size = UDim2.new(1, 0, 0, 28), maxSize = 22, layoutOrder = 1 })
	UIKit.label(list, def.description, { name = "Description", color = UIKit.Theme.textDim, size = UDim2.new(1, 0, 0, 60), valign = "Top", maxSize = 15, layoutOrder = 2 })
	UIKit.label(list, string.format("Requires %d Rep and %d deliveries. Batch of %d-%d orders. Bonus: %d%% of base pay + %s + %d Rep.", def.requirements.reputation, def.requirements.deliveries, def.minBatch, def.maxBatch, def.bonusFraction * 100, UIKit.formatCash(def.flatBonus), def.repBonus), { name = "Rules", color = UIKit.Theme.textDim, size = UDim2.new(1, 0, 0, 40), maxSize = 14, layoutOrder = 3 })

	if type(contract) ~= "table" then
		UIKit.label(list, "Waiting for contract information...", { name = "Status", size = UDim2.new(1, 0, 0, 30), maxSize = 18, layoutOrder = 4 })
		return
	end

	local status, countdown = contractStatusText(contract)
	contractRefs.status = UIKit.label(list, status, { name = "Status", bold = true, color = if contract.status == "Open" then UIKit.Theme.success else UIKit.Theme.text, size = UDim2.new(1, 0, 0, 28), maxSize = 20, layoutOrder = 4 })
	contractRefs.countdown = UIKit.label(list, countdown, { name = "Countdown", color = UIKit.Theme.warning, size = UDim2.new(1, 0, 0, 22), maxSize = 16, layoutOrder = 5 })
	contractRefs.contract = contract

	if contract.eligible == false then
		UIKit.label(list, "Not eligible: " .. tostring(contract.eligibilityReason or "requirements not met"), { name = "Eligibility", color = UIKit.Theme.warning, size = UDim2.new(1, 0, 0, 24), maxSize = 16, layoutOrder = 6 })
	end

	local joined = contract.joined
	if type(joined) == "table" then
		local now = ctx.state.serverNow()
		local done = tonumber(joined.done) or 0
		local required = tonumber(joined.required) or 0
		local deadline = (tonumber(joined.deadline) or now) - now
		local text
		if joined.completed then
			text = string.format("Batch complete: %d/%d delivered. Bonus paid!", done, required)
		elseif joined.failed then
			text = string.format("Deadline passed: %d/%d delivered. Collected orders still pay base pay.", done, required)
		else
			text = string.format("%d/%d delivered, deadline %s", done, required, UIKit.formatTime(math.max(0, deadline)))
		end
		local card = UIKit.card(list, { name = "Joined", height = 70, layoutOrder = 7, stroke = UIKit.Theme.accent })
		contractRefs.joinedText = UIKit.label(card, text, { name = "JoinedText", bold = true, size = UDim2.new(1, 0, 0, 24), maxSize = 18, layoutOrder = 1 })
		contractRefs.joined = joined
		local bar = UIKit.progressBar(card, { name = "JoinedBar", size = UDim2.new(1, 0, 0, 10), layoutOrder = 2, color = UIKit.Theme.success })
		bar.set(if required > 0 then done / required else 0)
		return
	end

	local offers = type(contract.offers) == "table" and contract.offers or {}
	if contract.status ~= "Open" or #offers == 0 then
		if contract.status == "Open" then
			UIKit.label(list, "No offers for you in this neighbourhood right now.", { name = "NoOffers", color = UIKit.Theme.textDim, size = UDim2.new(1, 0, 0, 24), maxSize = 16, layoutOrder = 8 })
		end
		return
	end

	local orders = ctx.state.get("orders") or {}
	local maxCapacity = type(orders.capacity) == "table" and tonumber(orders.capacity.max) or 1
	-- Drop selections for offers that disappeared.
	local valid = {}
	for _, order in ipairs(offers) do
		valid[order.id] = true
	end
	for id in pairs(selectedOffers) do
		if not valid[id] then
			selectedOffers[id] = nil
		end
	end

	UIKit.label(list, string.format("Pick %d-%d offers you can carry (max %s):", def.minBatch, def.maxBatch, UIKit.formatUnits(maxCapacity)), { name = "PickHint", size = UDim2.new(1, 0, 0, 24), maxSize = 16, layoutOrder = 8 })

	for index, order in ipairs(offers) do
		local card = UIKit.card(list, { name = "Offer_" .. tostring(order.id), height = 70, layoutOrder = 10 + index, list = false })
		card:SetAttribute("OrderId", order.id)
		local checkbox = UIKit.button(card, if selectedOffers[order.id] then "[x]" else "[ ]", function()
			if selectedOffers[order.id] then
				selectedOffers[order.id] = nil
			else
				selectedOffers[order.id] = true
			end
			OrderBoard.Update()
		end, { name = "Checkbox", size = UDim2.new(0, UIKit.MIN_HIT, 0, UIKit.MIN_HIT), position = UDim2.new(0, 0, 0.5, 0), anchor = Vector2.new(0, 0.5) })
		checkbox:SetAttribute("Selected", selectedOffers[order.id] == true)
		local info = UIKit.destinationInfo(ctx, order.destinationId)
		UIKit.label(card, string.format("%s: %s", UIKit.businessShortName(order.businessId), tostring(order.itemLabel or "")), { name = "Title", bold = true, size = UDim2.new(1, -60, 0, 24), position = UDim2.new(0, 54, 0, 0), maxSize = 17 })
		UIKit.label(card, string.format("To %s  -  %s  -  %s  -  %s", info.address, sizeText(order), UIKit.formatDistance(order.routeDistance), payText(order)), { name = "Details", color = UIKit.Theme.textDim, size = UDim2.new(1, -60, 0, 24), position = UDim2.new(0, 54, 0, 26), maxSize = 14 })
	end

	local picked = selectedList(offers)
	local units = 0
	for _, order in ipairs(picked) do
		units += tonumber(order.sizeUnits) or OrderDefinitions.unitsFor(order.size or "Small")
	end
	local bonusCash, bonusRep = OrderBoard.BonusPreview(picked)
	local summary = UIKit.card(list, { name = "Summary", height = 140, layoutOrder = 100 })
	contractRefs.summary = UIKit.label(summary, string.format("Selected %d (need %d-%d)  -  %s of %d max", #picked, def.minBatch, def.maxBatch, UIKit.formatUnits(units), maxCapacity), { name = "SelectionText", size = UDim2.new(1, 0, 0, 22), maxSize = 16, layoutOrder = 1 })
	UIKit.label(summary, string.format("Bonus if all delivered on time: %s + %d Rep (on top of normal pay)", UIKit.formatCash(bonusCash), bonusRep), { name = "BonusPreview", color = UIKit.Theme.success, size = UDim2.new(1, 0, 0, 22), maxSize = 15, layoutOrder = 2 })
	contractRefs.error = UIKit.label(summary, "", { name = "JoinError", color = UIKit.Theme.warning, size = UDim2.new(1, 0, 0, 20), maxSize = 14, layoutOrder = 3 })

	local blocked = nil
	if #picked < def.minBatch or #picked > def.maxBatch then
		blocked = string.format("Select %d-%d offers", def.minBatch, def.maxBatch)
	elseif units > maxCapacity then
		blocked = string.format("Too many units for your best vehicle (%d of %d)", units, maxCapacity)
	elseif contract.eligible == false then
		blocked = tostring(contract.eligibilityReason or "Not eligible")
	end
	local joinButton = UIKit.primaryButton(summary, if joining then "..." else "Join Lunch Rush", function()
		joinContract(contract)
	end, { name = "JoinButton", size = UDim2.new(0, 200, 0, UIKit.MIN_HIT), layoutOrder = 4 })
	if blocked or joining then
		UIKit.setButtonEnabled(joinButton, false)
	end
	if joinMessage and joinMessageContractId ~= contract.id then
		joinMessage = nil -- a new rush: the old rejection no longer applies
	end
	if blocked then
		contractRefs.error.Text = blocked
	elseif joinMessage then
		contractRefs.error.Text = "Server: " .. joinMessage
	end
	contractRefs.joinButton = joinButton
end

local function updateContractCountdowns()
	local contract = contractRefs.contract
	if not contract or not contractRefs.countdown or not contractRefs.countdown.Parent then
		return
	end
	local status, countdown = contractStatusText(contract)
	contractRefs.status.Text = status
	contractRefs.countdown.Text = countdown
	local joined = contractRefs.joined
	if joined and contractRefs.joinedText and not joined.completed and not joined.failed then
		local deadline = (tonumber(joined.deadline) or 0) - ctx.state.serverNow()
		contractRefs.joinedText.Text = string.format("%d/%d delivered, deadline %s", tonumber(joined.done) or 0, tonumber(joined.required) or 0, UIKit.formatTime(math.max(0, deadline)))
	end
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

function OrderBoard.Mount(parent: Instance, context: any): Frame
	ctx = context
	modal = UIKit.modal(parent, "Dash Orders", {
		name = "OrderBoard",
		onClose = function()
			local controller = ctx.controllers and ctx.controllers.UIController
			if controller and type(controller.CloseScreen) == "function" then
				controller.CloseScreen(OrderBoard.Name)
			end
		end,
	})
	local body = modal.body
	tabs = UIKit.tabs(body, { "Available", "Lunch Rush" }, function(name)
		currentTab = name
		for pageName, page in pairs(pages) do
			page.frame.Visible = pageName == name
		end
		OrderBoard.Update()
		UIKit.focus(pages[name].frame, pages[name].firstButton)
	end, { name = "Tabs" })

	for _, name in ipairs({ "Available", "Lunch Rush" }) do
		local frame = UIKit.panel(body, { name = "Page_" .. name, transparency = 1, corner = false, size = UDim2.new(1, 0, 1, -(UIKit.MIN_HIT + 8)), position = UDim2.new(0, 0, 0, UIKit.MIN_HIT + 8), visible = name == "Available" })
		local summary = UIKit.label(frame, "", { name = "Summary", color = UIKit.Theme.textDim, size = UDim2.new(1, 0, 0, 20), maxSize = 15 })
		local list = UIKit.scrollList(frame, { name = "List", size = UDim2.new(1, 0, 1, -24), position = UDim2.new(0, 0, 0, 24) })
		pages[name] = { frame = frame, list = list, summary = summary }
	end
	return modal.frame
end

function OrderBoard.Update()
	if not modal then
		return
	end
	if currentTab == "Available" then
		renderAvailable()
	else
		renderContract()
	end
end

function OrderBoard.Tick()
	if not modal or not modal.frame.Visible then
		return
	end
	if currentTab == "Available" then
		updateCountdowns()
	else
		updateContractCountdowns()
	end
end

function OrderBoard.OnShow()
	OrderBoard.Update()
end

function OrderBoard.SelectTab(name: string)
	if tabs then
		tabs.select(name)
	end
end

function OrderBoard.GetTab(): string
	return currentTab
end

function OrderBoard.GetFrame(): Frame?
	return modal and modal.frame
end

function OrderBoard.GetList(tab: string?): ScrollingFrame?
	local page = pages[tab or currentTab]
	return page and page.list
end

function OrderBoard.GetSelectedOffers(): { [string]: boolean }
	return selectedOffers
end

return OrderBoard
