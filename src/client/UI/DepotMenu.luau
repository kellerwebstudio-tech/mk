--!nonstrict
-- DepotMenu: depot purchase (requirements + Buy), and once owned: plot id, driver slot cards
-- (hire / idle / assignment progress / returned earnings), category picker, Assign, Unlock slot 2,
-- Collect earnings (explains "Go to your depot to collect" on TooFar) and the "Depots in this
-- server" list from DepotPublicState.publicPlots.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Definitions = Shared:WaitForChild("Definitions")
local DepotDefinitions = require(Definitions:WaitForChild("DepotDefinitions"))
local UIKit = require(script.Parent:WaitForChild("UIKit"))

local DepotMenu = {}

DepotMenu.Name = "Depot"

local ctx = nil
local modal = nil
local list: any = nil
local selectedCategory: string? = nil
local visitingPlotId: string? = nil
local busy: { [string]: boolean } = {}
local progressRefs = {}
local collectNote: any = nil
local collectHint: string? = nil -- explanation after a failed Collect (survives re-renders)
local refreshProgress

-------------------------------------------------------------------------------
-- Pure helpers
-------------------------------------------------------------------------------

-- nil when the depot can be bought, else the reason.
function DepotMenu.PurchaseReason(profile: any): string?
	local rep = profile and tonumber(profile.reputation) or 0
	local cash = profile and tonumber(profile.cash) or 0
	if rep < DepotDefinitions.repRequired then
		return string.format("Needs %s Rep", UIKit.formatNumber(DepotDefinitions.repRequired))
	end
	if cash < DepotDefinitions.price then
		return string.format("Not enough cash: %s more", UIKit.formatCash(DepotDefinitions.price - cash))
	end
	return nil
end

local function categories(depot: any): { any }
	if type(depot) == "table" and type(depot.categories) == "table" and #depot.categories > 0 then
		return depot.categories
	end
	local result = {}
	for _, id in ipairs(DepotDefinitions.CategoryOrder) do
		local def = DepotDefinitions.Categories[id]
		table.insert(result, { id = id, name = def.name, unlocked = false, duration = def.duration, revenue = def.revenue, cost = def.cost, net = def.revenue - def.cost, requirement = string.format("Requires %d Rep", def.repRequired) })
	end
	return result
end

local function categoryById(depot: any, id: string?): any
	for _, category in ipairs(categories(depot)) do
		if category.id == id then
			return category
		end
	end
	return nil
end

-- "Idle" | "Working" | "Returned" | "Empty"
function DepotMenu.SlotStatus(slot: any): string
	if type(slot) ~= "table" or not slot.hired then
		return "Empty"
	end
	local assignment = slot.assignment
	if type(assignment) == "table" then
		if assignment.completed then
			return "Returned"
		end
		return "Working"
	end
	if (tonumber(slot.pending) or 0) > 0 then
		return "Returned"
	end
	return "Idle"
end

-------------------------------------------------------------------------------
-- Remote actions
-------------------------------------------------------------------------------

local function run(key: string, remoteName: string, successText: string, onFail: ((any) -> ())?, ...: any)
	if busy[key] then
		return
	end
	busy[key] = true
	DepotMenu.Update()
	local args = table.pack(...)
	task.spawn(function()
		local result = UIKit.invoke(ctx, remoteName, table.unpack(args, 1, args.n))
		busy[key] = nil
		if result.ok then
			-- DepotService notifies every successful purchase / unlock / hire / assign / collect
			-- itself; a successText here is only for actions the server stays silent about.
			if successText ~= "" then
				UIKit.notify(ctx, successText, "success", 3)
			end
		else
			if onFail then
				onFail(result)
			end
			UIKit.notify(ctx, tostring(result.message or result.error or "Request failed"), "error", 4)
		end
		DepotMenu.Update()
	end)
end

-------------------------------------------------------------------------------
-- Rendering
-------------------------------------------------------------------------------

local function renderNotOwned(profile: any)
	local card = UIKit.card(list, { name = "Purchase", height = 190, layoutOrder = 1 })
	UIKit.label(card, "Own a depot", { name = "Title", bold = true, size = UDim2.new(1, 0, 0, 28), maxSize = 22, layoutOrder = 1 })
	UIKit.label(card, "A depot gives you two NPC driver slots. Drivers run paid assignments while you keep delivering, and you collect their earnings at your plot.", { name = "Description", color = UIKit.Theme.textDim, size = UDim2.new(1, 0, 0, 44), valign = "Top", maxSize = 15, layoutOrder = 2 })
	UIKit.label(card, string.format("Requirements: %s and %s Rep", UIKit.formatCash(DepotDefinitions.price), UIKit.formatNumber(DepotDefinitions.repRequired)), { name = "Requirements", size = UDim2.new(1, 0, 0, 22), maxSize = 16, layoutOrder = 3 })
	UIKit.label(card, string.format("You have %s and %d Rep", UIKit.formatCash(profile and profile.cash or 0), profile and tonumber(profile.reputation) or 0), { name = "Balance", color = UIKit.Theme.textDim, size = UDim2.new(1, 0, 0, 20), maxSize = 15, layoutOrder = 4 })
	local actions = UIKit.row(card, { name = "Actions", size = UDim2.new(1, 0, 0, UIKit.MIN_HIT), layoutOrder = 5 })
	local reason = DepotMenu.PurchaseReason(profile)
	local button = UIKit.primaryButton(actions, if busy.purchase then "..." else "Buy Depot", function()
		run("purchase", "PurchaseDepot", "")
	end, { name = "BuyDepotButton", size = UDim2.new(0, 160, 0, UIKit.MIN_HIT), layoutOrder = 1 })
	if reason or busy.purchase then
		UIKit.setButtonEnabled(button, false)
	end
	UIKit.label(actions, reason or "", { name = "ReasonLabel", color = UIKit.Theme.warning, size = UDim2.new(1, -170, 1, 0), layoutOrder = 2, maxSize = 15 })
end

local function renderCategoryPicker(depot: any, order: number): number
	UIKit.label(list, "Assignment category", { name = "CategoryTitle", bold = true, size = UDim2.new(1, 0, 0, 26), maxSize = 18, layoutOrder = order })
	for _, category in ipairs(categories(depot)) do
		order += 1
		local selected = selectedCategory == category.id
		local card = UIKit.card(list, { name = "Category_" .. category.id, height = 62, layoutOrder = order, list = false, stroke = if selected then UIKit.Theme.accent else nil })
		card:SetAttribute("Unlocked", category.unlocked == true)
		local pick = UIKit.button(card, if selected then "[x]" else "[ ]", function()
			selectedCategory = category.id
			DepotMenu.Update()
		end, { name = "PickButton", size = UDim2.new(0, UIKit.MIN_HIT, 0, UIKit.MIN_HIT), position = UDim2.new(0, 0, 0.5, 0), anchor = Vector2.new(0, 0.5) })
		UIKit.setButtonEnabled(pick, category.unlocked == true)
		UIKit.label(card, category.name .. (if category.unlocked then "" else "  (locked)"), { name = "Name", bold = true, size = UDim2.new(1, -56, 0, 22), position = UDim2.new(0, 52, 0, 0), maxSize = 16 })
		local detail = string.format("%s run  -  revenue %s  -  cost %s up front  -  net %s", UIKit.formatTime(category.duration), UIKit.formatCash(category.revenue), UIKit.formatCash(category.cost), UIKit.formatCash(category.net))
		if not category.unlocked and category.requirement then
			detail = tostring(category.requirement) .. "  -  " .. detail
		end
		UIKit.label(card, detail, { name = "Detail", color = UIKit.Theme.textDim, size = UDim2.new(1, -56, 0, 20), position = UDim2.new(0, 52, 0, 24), maxSize = 13 })
	end
	return order
end

local function renderSlot(depot: any, slotIndex: number, order: number)
	local slots = type(depot.drivers) == "table" and depot.drivers or {}
	local slot = slots[slotIndex]
	local unlocked = slotIndex <= (tonumber(depot.slotsUnlocked) or 0)
	local status = if unlocked then DepotMenu.SlotStatus(slot) else "Locked"
	local card = UIKit.card(list, { name = "Slot" .. slotIndex, height = 150, layoutOrder = order })
	card:SetAttribute("Status", status)
	UIKit.label(card, string.format("Driver slot %d  -  %s", slotIndex, status), { name = "Title", bold = true, size = UDim2.new(1, 0, 0, 24), maxSize = 18, layoutOrder = 1 })

	if status == "Locked" then
		UIKit.label(card, string.format("Unlock a second driver for %s.", UIKit.formatCash(DepotDefinitions.slot2Cost)), { name = "Detail", color = UIKit.Theme.textDim, size = UDim2.new(1, 0, 0, 20), maxSize = 15, layoutOrder = 2 })
		local button = UIKit.primaryButton(card, if busy.unlock then "..." else string.format("Unlock slot %d (%s)", slotIndex, UIKit.formatCash(DepotDefinitions.slot2Cost)), function()
			run("unlock", "UnlockDriverSlot", "")
		end, { name = "UnlockButton", size = UDim2.new(0, 230, 0, UIKit.MIN_HIT), layoutOrder = 3 })
		if busy.unlock then
			UIKit.setButtonEnabled(button, false)
		end
		return
	end

	if status == "Empty" then
		UIKit.label(card, string.format("No driver yet. Hire one for %s.", UIKit.formatCash(DepotDefinitions.hireCost)), { name = "Detail", color = UIKit.Theme.textDim, size = UDim2.new(1, 0, 0, 20), maxSize = 15, layoutOrder = 2 })
		local key = "hire" .. slotIndex
		local button = UIKit.primaryButton(card, if busy[key] then "..." else string.format("Hire for %s", UIKit.formatCash(DepotDefinitions.hireCost)), function()
			run(key, "HireDriver", "", nil, slotIndex)
		end, { name = "HireButton", size = UDim2.new(0, 200, 0, UIKit.MIN_HIT), layoutOrder = 3 })
		if busy[key] then
			UIKit.setButtonEnabled(button, false)
		end
		return
	end

	local name = tostring(slot.name or "Driver")
	local assignment = slot.assignment
	if status == "Working" and type(assignment) == "table" then
		local category = categoryById(depot, assignment.category)
		UIKit.label(card, string.format("%s is out on %s", name, category and category.name or tostring(assignment.category)), { name = "Detail", size = UDim2.new(1, 0, 0, 20), maxSize = 15, layoutOrder = 2 })
		local timeLabel = UIKit.label(card, "", { name = "TimeLeft", color = UIKit.Theme.textDim, size = UDim2.new(1, 0, 0, 18), maxSize = 14, layoutOrder = 3 })
		local bar = UIKit.progressBar(card, { name = "Progress", size = UDim2.new(1, 0, 0, 10), layoutOrder = 4, color = UIKit.Theme.info })
		UIKit.label(card, string.format("Net on return: %s (revenue %s, cost %s already paid)", UIKit.formatCash(assignment.net), UIKit.formatCash(assignment.revenue), UIKit.formatCash(assignment.cost)), { name = "NetPreview", color = UIKit.Theme.success, size = UDim2.new(1, 0, 0, 18), maxSize = 14, layoutOrder = 5 })
		table.insert(progressRefs, { label = timeLabel, bar = bar, assignment = assignment })
		return
	end

	if status == "Returned" then
		local pending = tonumber(slot.pending) or 0
		if pending <= 0 and type(assignment) == "table" then
			pending = tonumber(assignment.revenue) or 0
		end
		UIKit.label(card, string.format("%s is back. Returned: %s to collect.", name, UIKit.formatCash(pending)), { name = "Detail", color = UIKit.Theme.success, size = UDim2.new(1, 0, 0, 20), maxSize = 15, layoutOrder = 2 })
	else
		UIKit.label(card, string.format("%s is idle and ready for an assignment.", name), { name = "Detail", color = UIKit.Theme.textDim, size = UDim2.new(1, 0, 0, 20), maxSize = 15, layoutOrder = 2 })
	end

	local actions = UIKit.row(card, { name = "Actions", size = UDim2.new(1, 0, 0, UIKit.MIN_HIT), layoutOrder = 6 })
	local category = categoryById(depot, selectedCategory)
	local key = "assign" .. slotIndex
	local reason = nil
	if not category then
		reason = "Pick a category below"
	elseif not category.unlocked then
		reason = tostring(category.requirement or "Category locked")
	end
	local assign = UIKit.primaryButton(actions, if busy[key] then "..." else (if category then string.format("Assign (%s)", UIKit.formatCash(category.cost)) else "Assign"), function()
		run(key, "AssignDriver", "", nil, slotIndex, selectedCategory)
	end, { name = "AssignButton", size = UDim2.new(0, 170, 0, UIKit.MIN_HIT), layoutOrder = 1 })
	if reason or busy[key] then
		UIKit.setButtonEnabled(assign, false)
	end
	UIKit.label(actions, reason or "", { name = "ReasonLabel", color = UIKit.Theme.warning, size = UDim2.new(1, -180, 1, 0), layoutOrder = 2, maxSize = 14 })
end

local function renderOwned(depot: any)
	local order = 1
	UIKit.label(list, string.format("Your depot  -  plot %s", tostring(depot.plotId or "?")), { name = "PlotTitle", bold = true, size = UDim2.new(1, 0, 0, 28), maxSize = 22, layoutOrder = order })

	order += 1
	local pending = tonumber(depot.pendingTotal) or 0
	local collectCard = UIKit.card(list, { name = "Collect", height = 96, layoutOrder = order })
	UIKit.label(collectCard, string.format("Pending earnings: %s", UIKit.formatCash(pending)), { name = "PendingText", bold = true, color = if pending > 0 then UIKit.Theme.success else UIKit.Theme.text, size = UDim2.new(1, 0, 0, 24), maxSize = 18, layoutOrder = 1 })
	local collectRow = UIKit.row(collectCard, { name = "Actions", size = UDim2.new(1, 0, 0, UIKit.MIN_HIT), layoutOrder = 2 })
	local collect = UIKit.primaryButton(collectRow, if busy.collect then "..." else "Collect earnings", function()
		collectHint = nil
		run("collect", "CollectDepotEarnings", "", function(result)
			if result.error == "TooFar" then
				collectHint = "Go to your depot to collect."
			else
				collectHint = tostring(result.message or result.error or "")
			end
		end)
	end, { name = "CollectButton", size = UDim2.new(0, 180, 0, UIKit.MIN_HIT), layoutOrder = 1 })
	if pending <= 0 or busy.collect then
		UIKit.setButtonEnabled(collect, false)
	end
	if pending <= 0 then
		collectHint = nil
	end
	collectNote = UIKit.label(collectRow, collectHint or (if pending > 0 then "Collect at your depot plot." else ""), { name = "CollectNote", color = UIKit.Theme.textDim, size = UDim2.new(1, -190, 1, 0), layoutOrder = 2, maxSize = 14 })

	for slotIndex = 1, DepotDefinitions.maxSlots do
		order += 1
		renderSlot(depot, slotIndex, order)
	end
	order += 1
	order = renderCategoryPicker(depot, order)
	return order
end

local function renderPublicPlots(depot: any, order: number)
	local plots = type(depot) == "table" and depot.publicPlots
	if type(plots) ~= "table" or #plots == 0 then
		return
	end
	order += 1
	UIKit.label(list, "Depots in this server", { name = "PublicTitle", bold = true, size = UDim2.new(1, 0, 0, 26), maxSize = 18, layoutOrder = order })
	for _, plot in ipairs(plots) do
		order += 1
		local owned = (tonumber(plot.ownerUserId) or 0) ~= 0
		-- DepotService sends `drivers` as the hired-slot count (ARCHITECTURE section 12); a slot
		-- array is tolerated for older payloads.
		local hired = tonumber(plot.drivers) or 0
		if type(plot.drivers) == "table" then
			hired = 0
			for _, slot in ipairs(plot.drivers) do
				if type(slot) == "table" and slot.hired then
					hired += 1
				end
			end
		end
		local text = if owned then string.format("Plot %s  -  %s  -  %d driver%s", tostring(plot.plotId), tostring(plot.ownerName), hired, hired == 1 and "" or "s") else string.format("Plot %s  -  for sale", tostring(plot.plotId))
		local line = UIKit.label(list, text, { name = "Plot_" .. tostring(plot.plotId), color = if owned then UIKit.Theme.text else UIKit.Theme.textDim, size = UDim2.new(1, 0, 0, 22), maxSize = 15, layoutOrder = order })
		if visitingPlotId and plot.plotId == visitingPlotId then
			line.TextColor3 = UIKit.Theme.accent
			line.Text = text .. "  (you are here)"
		end
	end
end

local function renderVisiting(depot: any): number
	if not visitingPlotId then
		return 0
	end
	local ownPlot = type(depot) == "table" and depot.plotId
	if ownPlot == visitingPlotId then
		return 0
	end
	local ownerName = "another courier"
	local plots = type(depot) == "table" and depot.publicPlots
	if type(plots) == "table" then
		for _, plot in ipairs(plots) do
			if plot.plotId == visitingPlotId and (tonumber(plot.ownerUserId) or 0) ~= 0 then
				ownerName = tostring(plot.ownerName)
			end
		end
	end
	UIKit.label(list, string.format("Visiting plot %s (%s's depot)", tostring(visitingPlotId), ownerName), { name = "Visiting", color = UIKit.Theme.accent, bold = true, size = UDim2.new(1, 0, 0, 24), maxSize = 16, layoutOrder = 0 })
	return 1
end

-- Fills the assignment progress bars / time-left labels from os.time().
function refreshProgress()
	local now = os.time()
	for _, refs in ipairs(progressRefs) do
		if refs.label.Parent then
			local assignment = refs.assignment
			local startedAt = tonumber(assignment.startedAt) or now
			local endsAt = tonumber(assignment.endsAt) or now
			local duration = math.max(1, endsAt - startedAt)
			local left = math.max(0, endsAt - now)
			refs.label.Text = if left > 0 then string.format("Back in %s", UIKit.formatTime(left)) else "Returning..."
			refs.bar.set(1 - left / duration)
		end
	end
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

function DepotMenu.Mount(parent: Instance, context: any): Frame
	ctx = context
	modal = UIKit.modal(parent, "Depot", {
		name = "DepotMenu",
		onClose = function()
			local controller = ctx.controllers and ctx.controllers.UIController
			if controller and type(controller.CloseScreen) == "function" then
				controller.CloseScreen(DepotMenu.Name)
			end
		end,
	})
	list = UIKit.scrollList(modal.body, { name = "List", gap = 8 })
	return modal.frame
end

function DepotMenu.Update()
	if not modal then
		return
	end
	UIKit.clearChildren(list)
	progressRefs = {}
	collectNote = nil
	local profile = ctx.state.get("profile")
	local depot = ctx.state.get("depot")
	local owned = (type(depot) == "table" and depot.owned) or (profile and type(profile.depot) == "table" and profile.depot.owned)
	renderVisiting(depot)
	local order
	if owned and type(depot) == "table" then
		modal.setTitle("Your Depot")
		order = renderOwned(depot)
	elseif owned then
		modal.setTitle("Your Depot")
		UIKit.label(list, "Loading depot information...", { name = "Loading", size = UDim2.new(1, 0, 0, 30), maxSize = 16, layoutOrder = 1 })
		order = 1
	else
		modal.setTitle("Depot")
		renderNotOwned(profile)
		order = 1
	end
	renderPublicPlots(depot, order)
	refreshProgress()
end

-- Assignment progress bars once per second.
function DepotMenu.Tick()
	if not modal or not modal.frame.Visible then
		return
	end
	refreshProgress()
end

function DepotMenu.OnShow()
	DepotMenu.Update()
end

function DepotMenu.OnHide()
	visitingPlotId = nil
end

-- Opened from a depot plot prompt: show whose plot it is.
function DepotMenu.SetVisitingPlot(plotId: string?)
	visitingPlotId = plotId
end

function DepotMenu.GetFrame(): Frame?
	return modal and modal.frame
end

function DepotMenu.GetList(): ScrollingFrame?
	return list
end

function DepotMenu.GetSelectedCategory(): string?
	return selectedCategory
end

return DepotMenu
