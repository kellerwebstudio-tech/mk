--!nonstrict
-- UpgradeMenu: every UpgradeDefinitions.Order entry with name, description, price, requirement
-- text and an Owned / Buy / Locked state. Basket I is highlighted during tutorial step 8.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Definitions = Shared:WaitForChild("Definitions")
local UpgradeDefinitions = require(Definitions:WaitForChild("UpgradeDefinitions"))
local VehicleDefinitions = require(Definitions:WaitForChild("VehicleDefinitions"))
local UIKit = require(script.Parent:WaitForChild("UIKit"))

local UpgradeMenu = {}

UpgradeMenu.Name = "Upgrades"
UpgradeMenu.TUTORIAL_HIGHLIGHT_STEP = 8
UpgradeMenu.TUTORIAL_HIGHLIGHT_ID = "BasketI"

local ctx = nil
local modal = nil
local list: any = nil
local balanceLabel: any = nil
local busy: { [string]: boolean } = {}

-- Returns (state, reason): state is "Owned" | "Buy" | "Locked".
function UpgradeMenu.Evaluate(profile: any, def: any): (string, string?)
	local upgrades = profile and profile.upgrades or {}
	if (tonumber(upgrades[def.id]) or 0) >= 1 then
		return "Owned", nil
	end
	local rep = profile and tonumber(profile.reputation) or 0
	local cash = profile and tonumber(profile.cash) or 0
	if def.requiresVehicle and not (profile and profile.ownedVehicles and profile.ownedVehicles[def.requiresVehicle]) then
		local vehicle = VehicleDefinitions.Vehicles[def.requiresVehicle]
		return "Locked", "Requires the " .. (vehicle and vehicle.displayName or def.requiresVehicle)
	end
	if def.requiresUpgrade and (tonumber(upgrades[def.requiresUpgrade]) or 0) < 1 then
		local required = UpgradeDefinitions.Upgrades[def.requiresUpgrade]
		return "Locked", "Requires " .. (required and required.name or def.requiresUpgrade)
	end
	if rep < (def.repRequired or 0) then
		return "Locked", string.format("Needs %d Rep", def.repRequired)
	end
	if cash < (def.price or 0) then
		return "Locked", string.format("Not enough cash: %s more", UIKit.formatCash(def.price - cash))
	end
	return "Buy", nil
end

function UpgradeMenu.RequirementText(def: any): string
	local parts = {}
	if (def.repRequired or 0) > 0 then
		table.insert(parts, string.format("%d Rep", def.repRequired))
	end
	if def.requiresUpgrade then
		local required = UpgradeDefinitions.Upgrades[def.requiresUpgrade]
		table.insert(parts, required and required.name or def.requiresUpgrade)
	end
	if def.requiresVehicle then
		local vehicle = VehicleDefinitions.Vehicles[def.requiresVehicle]
		table.insert(parts, vehicle and vehicle.displayName or def.requiresVehicle)
	end
	if #parts == 0 then
		return "No requirements"
	end
	return "Requires " .. table.concat(parts, ", ")
end

local function purchase(upgradeId: string)
	if busy[upgradeId] then
		return
	end
	busy[upgradeId] = true
	UpgradeMenu.Update()
	task.spawn(function()
		local result = UIKit.invoke(ctx, "PurchaseUpgrade", upgradeId)
		busy[upgradeId] = nil
		if result.ok then
			local def = UpgradeDefinitions.Upgrades[upgradeId]
			UIKit.notify(ctx, string.format("Bought %s!", def and def.name or upgradeId), "success", 3)
		else
			UIKit.notify(ctx, tostring(result.message or result.error or "Purchase failed"), "error", 4)
		end
		UpgradeMenu.Update()
	end)
end

local function buildRow(parent: Instance, def: any, index: number, profile: any, highlight: boolean)
	local state, reason = UpgradeMenu.Evaluate(profile, def)
	local card = UIKit.card(parent, { name = "Upgrade_" .. def.id, height = 138, layoutOrder = index, stroke = if highlight then UIKit.Theme.accent else nil })
	card:SetAttribute("State", state)

	local top = UIKit.row(card, { name = "Top", size = UDim2.new(1, 0, 0, 26), layoutOrder = 1 })
	UIKit.label(top, def.name, { name = "Name", bold = true, size = UDim2.new(1, -230, 1, 0), layoutOrder = 1, maxSize = 20 })
	if highlight then
		UIKit.pill(top, "Tutorial: buy this", { name = "TutorialTag", color = UIKit.Theme.accent, textColor = UIKit.Theme.textOnAccent, width = 130, layoutOrder = 2 })
	end
	UIKit.label(top, UIKit.formatCash(def.price), { name = "Price", bold = true, align = "Right", color = UIKit.Theme.success, size = UDim2.new(0, 90, 1, 0), layoutOrder = 3, maxSize = 18 })

	UIKit.label(card, def.description, { name = "Description", color = UIKit.Theme.textDim, size = UDim2.new(1, 0, 0, 20), layoutOrder = 2, maxSize = 15 })
	UIKit.label(card, UpgradeMenu.RequirementText(def), { name = "Requirements", color = UIKit.Theme.textDim, size = UDim2.new(1, 0, 0, 18), layoutOrder = 3, maxSize = 14 })

	local actions = UIKit.row(card, { name = "Actions", size = UDim2.new(1, 0, 0, UIKit.MIN_HIT), layoutOrder = 4 })
	local button
	if state == "Owned" then
		button = UIKit.button(actions, "Owned", nil, { name = "StateButton", size = UDim2.new(0, 120, 0, UIKit.MIN_HIT), layoutOrder = 1, color = UIKit.Theme.success, textColor = UIKit.Theme.textOnAccent })
		UIKit.setButtonEnabled(button, false)
	elseif state == "Buy" then
		button = UIKit.primaryButton(actions, if busy[def.id] then "..." else "Buy", function()
			purchase(def.id)
		end, { name = "StateButton", size = UDim2.new(0, 120, 0, UIKit.MIN_HIT), layoutOrder = 1 })
		if busy[def.id] then
			UIKit.setButtonEnabled(button, false)
		end
	else
		button = UIKit.button(actions, "Locked", nil, { name = "StateButton", size = UDim2.new(0, 120, 0, UIKit.MIN_HIT), layoutOrder = 1 })
		UIKit.setButtonEnabled(button, false)
	end
	UIKit.label(actions, reason or "", { name = "ReasonLabel", color = UIKit.Theme.warning, size = UDim2.new(1, -130, 1, 0), layoutOrder = 2, maxSize = 15 })
end

function UpgradeMenu.Mount(parent: Instance, context: any): Frame
	ctx = context
	modal = UIKit.modal(parent, "Upgrades", {
		name = "UpgradeMenu",
		onClose = function()
			local controller = ctx.controllers and ctx.controllers.UIController
			if controller and type(controller.CloseScreen) == "function" then
				controller.CloseScreen(UpgradeMenu.Name)
			end
		end,
	})
	balanceLabel = UIKit.label(modal.body, "", { name = "Balance", bold = true, size = UDim2.new(1, 0, 0, 24), maxSize = 18 })
	list = UIKit.scrollList(modal.body, { name = "List", size = UDim2.new(1, 0, 1, -30), position = UDim2.new(0, 0, 0, 30) })
	return modal.frame
end

function UpgradeMenu.Update()
	if not modal then
		return
	end
	local profile = ctx.state.get("profile")
	local tutorial = ctx.state.get("tutorial")
	local highlightId = nil
	if type(tutorial) == "table" and not tutorial.completed and tonumber(tutorial.step) == UpgradeMenu.TUTORIAL_HIGHLIGHT_STEP then
		highlightId = UpgradeMenu.TUTORIAL_HIGHLIGHT_ID
	end
	balanceLabel.Text = string.format("Balance %s  -  Rep %d", UIKit.formatCash(profile and profile.cash or 0), profile and tonumber(profile.reputation) or 0)
	UIKit.clearChildren(list)
	for index, id in ipairs(UpgradeDefinitions.Order) do
		local def = UpgradeDefinitions.Upgrades[id]
		if def then
			buildRow(list, def, index, profile, highlightId == id)
		end
	end
end

function UpgradeMenu.OnShow()
	UpgradeMenu.Update()
end

function UpgradeMenu.GetFrame(): Frame?
	return modal and modal.frame
end

function UpgradeMenu.GetList(): ScrollingFrame?
	return list
end

return UpgradeMenu
