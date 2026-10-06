--!nonstrict
-- ShopMenu: "Vehicles" (cards with a ViewportFrame preview, stats, price, requirements and
-- Buy / Equip / Equipped states) and "Looks" (cosmetics per slot with colour swatches and
-- Owned / Equipped / Buy / Store only states). Purchases and equips go through remotes; the
-- screen refreshes on ProfileUpdated through UIController. Vehicle cards are built once and
-- updated in place (texts, button state, stroke), so the ViewportFrame previews survive the
-- up-to-4/s ProfileUpdated refreshes and a gamepad-selected button is never destroyed; a preview
-- is only rebuilt when the equipped paint / decal for that vehicle changes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Definitions = Shared:WaitForChild("Definitions")
local VehicleDefinitions = require(Definitions:WaitForChild("VehicleDefinitions"))
local UpgradeDefinitions = require(Definitions:WaitForChild("UpgradeDefinitions"))
local CosmeticDefinitions = require(Definitions:WaitForChild("CosmeticDefinitions"))
local UIKit = require(script.Parent:WaitForChild("UIKit"))

local ShopMenu = {}

ShopMenu.Name = "Shop"

local ctx = nil
local modal = nil
local tabs = nil
local pages: { [string]: any } = {}
local currentTab = "Vehicles"
local busy: { [string]: boolean } = {}
local previews: { [string]: Model } = {}
-- vehicleId -> { card, stroke, preview (ViewportFrame), signature, stats, button, reason, state }
local vehicleCards: { [string]: any } = {}

-------------------------------------------------------------------------------
-- Pure evaluation (also used by tests)
-------------------------------------------------------------------------------

-- (state, reason): "Equipped" | "Equip" | "Buy" | "Locked"
function ShopMenu.VehicleState(profile: any, def: any): (string, string?)
	local owned = profile and profile.ownedVehicles and profile.ownedVehicles[def.id]
	if owned or def.price == 0 and def.id == "Bicycle" then
		if profile and profile.equippedVehicle == def.id then
			return "Equipped", nil
		end
		return "Equip", nil
	end
	local rep = profile and tonumber(profile.reputation) or 0
	local cash = profile and tonumber(profile.cash) or 0
	if rep < (def.repRequired or 0) then
		return "Locked", string.format("Needs %d Rep", def.repRequired)
	end
	if cash < (def.price or 0) then
		return "Locked", string.format("Not enough cash: %s more", UIKit.formatCash(def.price - cash))
	end
	return "Buy", nil
end

-- (state, reason): "Equipped" | "Equip" | "Buy" | "Locked" | "StoreOnly"
function ShopMenu.CosmeticState(profile: any, item: any): (string, string?)
	local cosmetics = profile and profile.cosmetics or {}
	local ownedTable = cosmetics.owned or {}
	local equipped = cosmetics.equipped or {}
	local owned = item.default == true or ownedTable[item.id] == true
	local isEquipped = equipped[item.slot] == item.id or (equipped[item.slot] == nil and item.default == true)
	if owned then
		return if isEquipped then "Equipped" else "Equip", nil
	end
	if item.paidOnly then
		return "StoreOnly", "Store only"
	end
	local rep = profile and tonumber(profile.reputation) or 0
	local cash = profile and tonumber(profile.cash) or 0
	if rep < (item.repRequired or 0) then
		return "Locked", string.format("Needs %d Rep", item.repRequired)
	end
	if cash < (item.price or 0) then
		return "Locked", string.format("Not enough cash: %s more", UIKit.formatCash(item.price - cash))
	end
	return "Buy", nil
end

function ShopMenu.CapacityFor(profile: any, def: any): number
	local capacity = def.baseCapacity or 1
	local upgrades = profile and profile.upgrades or {}
	for id, upgrade in pairs(UpgradeDefinitions.Upgrades) do
		local bonus = upgrade.effect and upgrade.effect.capacityBonus
		if bonus and bonus.vehicle == def.id and (tonumber(upgrades[id]) or 0) >= 1 then
			capacity += bonus.amount
		end
	end
	return capacity
end

function ShopMenu.AccessText(def: any): string
	if def.mask == 1 then
		return "Alleys OK (every road, bike path and alley)"
	elseif def.mask == 2 then
		return "Streets OK, no alleys or bike paths"
	end
	return "Roads only"
end

-------------------------------------------------------------------------------
-- Remote actions
-------------------------------------------------------------------------------

local function run(key: string, remoteName: string, argument: string, successText: string)
	if busy[key] then
		return
	end
	busy[key] = true
	ShopMenu.Update()
	task.spawn(function()
		local result = UIKit.invoke(ctx, remoteName, argument)
		busy[key] = nil
		if result.ok then
			-- Purchases are announced by ShopService's Notify; only equips toast locally.
			if successText ~= "" then
				UIKit.notify(ctx, successText, "success", 3)
			end
		else
			UIKit.notify(ctx, tostring(result.message or result.error or "Request failed"), "error", 4)
		end
		ShopMenu.Update()
	end)
end

-------------------------------------------------------------------------------
-- Vehicle preview
-------------------------------------------------------------------------------

-- Stable string for the colours a preview was built with (equipped paint / decal), so Update()
-- can tell when the cached preview is stale.
local function previewSignature(def: any): string
	local cosmetics = ctx.controllers and ctx.controllers.CosmeticsController
	if cosmetics and type(cosmetics.GetVehicleColors) == "function" then
		local ok, colors = pcall(cosmetics.GetVehicleColors, def.id)
		if ok and type(colors) == "table" then
			local parts = {}
			for _, key in ipairs({ "Primary", "Accent", "Decal" }) do
				local value = colors[key]
				if type(value) == "table" then
					table.insert(parts, string.format("%s=%s,%s,%s", key, tostring(value[1]), tostring(value[2]), tostring(value[3])))
				else
					table.insert(parts, key .. "=" .. tostring(value))
				end
			end
			return table.concat(parts, ";")
		end
	end
	return "default"
end

local function buildPreview(parent: Instance, def: any)
	local viewport = Instance.new("ViewportFrame")
	viewport.Name = "Preview"
	viewport.BackgroundColor3 = UIKit.Theme.panelLight
	viewport.BackgroundTransparency = 0.2
	viewport.BorderSizePixel = 0
	viewport.Size = UDim2.new(0, 130, 0, 130)
	viewport.Ambient = Color3.fromRGB(200, 200, 210)
	viewport.LightColor = Color3.fromRGB(255, 250, 240)
	viewport.LightDirection = Vector3.new(-1, -2, -1)
	UIKit.corner(viewport, 10)
	viewport.Parent = parent

	local model: any = nil
	local radius = 6
	local cosmetics = ctx.controllers and ctx.controllers.CosmeticsController
	if cosmetics and type(cosmetics.BuildDisplayVehicle) == "function" then
		local ok, built = pcall(cosmetics.BuildDisplayVehicle, def.id, viewport)
		if ok and typeof(built) == "Instance" then
			model = built
			if type(cosmetics.GetDisplayRadius) == "function" then
				local okRadius, r = pcall(cosmetics.GetDisplayRadius, def.id)
				if okRadius and type(r) == "number" and r > 0 then
					radius = r
				end
			end
		else
			warn("[ShopMenu] BuildDisplayVehicle failed for " .. def.id .. ": " .. tostring(built))
		end
	end
	if not model then
		-- Fallback: a coloured box in the vehicle's primary colour.
		model = Instance.new("Model")
		model.Name = "Display_" .. def.id
		local box = Instance.new("Part")
		box.Name = "Box"
		box.Anchored = true
		box.CanCollide = false
		local size = def.chassisSize or { 4, 2, 6 }
		box.Size = Vector3.new(size[1], size[2], size[3])
		box.Color = UIKit.rgb(def.defaultColors and def.defaultColors.Primary, UIKit.Theme.accent)
		box.Material = Enum.Material.SmoothPlastic
		box.CFrame = CFrame.new(0, size[2] / 2, 0)
		box.Parent = model
		model.PrimaryPart = box
		model.Parent = viewport
		radius = math.max(size[1], size[3]) * 0.7
	end
	previews[def.id] = model

	local camera = Instance.new("Camera")
	camera.Name = "PreviewCamera"
	local height = (def.handling and def.handling.rideHeight or 1.5) + 0.5
	camera.CFrame = CFrame.lookAt(Vector3.new(radius * 1.5, height + radius * 0.8, radius * 1.5), Vector3.new(0, height, 0))
	camera.FieldOfView = 50
	camera.Parent = viewport
	viewport.CurrentCamera = camera
	return viewport
end

-------------------------------------------------------------------------------
-- Vehicles tab
-------------------------------------------------------------------------------

local function vehicleKey(def: any): string
	return "vehicle:" .. def.id
end

-- Builds the static part of a vehicle card once; everything state-dependent lives in updateVehicleCard.
local function buildVehicleCard(parent: Instance, def: any, index: number)
	local card = UIKit.card(parent, { name = "Vehicle_" .. def.id, height = 190, layoutOrder = index, list = false, stroke = UIKit.Theme.success })
	local stroke = card:FindFirstChildOfClass("UIStroke")
	local entry: any = { card = card, stroke = stroke, state = "Locked" }
	entry.preview = buildPreview(card, def)
	entry.signature = previewSignature(def)

	local column = UIKit.column(card, { name = "Info", size = UDim2.new(1, -140, 1, 0), position = UDim2.new(0, 140, 0, 0), gap = 2 })
	UIKit.label(column, def.displayName, { name = "Name", bold = true, size = UDim2.new(1, 0, 0, 26), maxSize = 20, layoutOrder = 1 })
	UIKit.label(column, def.description, { name = "Description", color = UIKit.Theme.textDim, size = UDim2.new(1, 0, 0, 36), valign = "Top", maxSize = 14, layoutOrder = 2 })
	entry.stats = UIKit.label(column, "", { name = "Stats", size = UDim2.new(1, 0, 0, 20), maxSize = 14, layoutOrder = 3 })
	local priceText = if def.price > 0 then string.format("%s  -  needs %d Rep", UIKit.formatCash(def.price), def.repRequired) else "Free starter vehicle"
	UIKit.label(column, priceText, { name = "Price", color = UIKit.Theme.success, bold = true, size = UDim2.new(1, 0, 0, 20), maxSize = 15, layoutOrder = 4 })

	local actions = UIKit.row(column, { name = "Actions", size = UDim2.new(1, 0, 0, UIKit.MIN_HIT), layoutOrder = 5 })
	-- One button whose action follows the current state (Equip / Buy); Equipped / Locked disable it.
	entry.button = UIKit.button(actions, "Locked", function()
		if entry.state == "Equip" then
			run(vehicleKey(def), "EquipVehicle", def.id, def.displayName .. " equipped.")
		elseif entry.state == "Buy" then
			run(vehicleKey(def), "PurchaseVehicle", def.id, "")
		end
	end, { name = "StateButton", size = UDim2.new(0, 130, 0, UIKit.MIN_HIT), layoutOrder = 1 })
	entry.reason = UIKit.label(actions, "", { name = "ReasonLabel", color = UIKit.Theme.warning, size = UDim2.new(1, -160, 1, 0), layoutOrder = 2, maxSize = 15 })
	vehicleCards[def.id] = entry
	return entry
end

local function updateVehicleCard(entry: any, def: any, profile: any)
	local state, reason = ShopMenu.VehicleState(profile, def)
	entry.state = state
	entry.card:SetAttribute("State", state)
	if entry.stroke then
		entry.stroke.Enabled = state == "Equipped"
	end
	entry.stats.Text = string.format("Speed %d studs/s  -  Capacity %d  -  %s", def.handling.maxSpeed, ShopMenu.CapacityFor(profile, def), ShopMenu.AccessText(def))

	-- Rebuild the preview only when the equipped colours for this vehicle changed.
	local signature = previewSignature(def)
	if signature ~= entry.signature then
		if entry.preview then
			entry.preview:Destroy()
		end
		entry.preview = buildPreview(entry.card, def)
		entry.signature = signature
	end

	local button = entry.button
	local isBusy = busy[vehicleKey(def)] == true
	local enabled = false
	if state == "Equipped" then
		button.Text = "Equipped"
		UIKit.setButtonColor(button, UIKit.Theme.success, UIKit.Theme.textOnAccent)
	elseif state == "Equip" then
		button.Text = if isBusy then "..." else "Equip"
		UIKit.setButtonColor(button, UIKit.Theme.accent, UIKit.Theme.textOnAccent)
		enabled = not isBusy
	elseif state == "Buy" then
		button.Text = if isBusy then "..." else "Buy " .. UIKit.formatCash(def.price)
		UIKit.setButtonColor(button, UIKit.Theme.accent, UIKit.Theme.textOnAccent)
		enabled = not isBusy
	else
		button.Text = "Locked"
		UIKit.setButtonColor(button, UIKit.Theme.panelLight, UIKit.Theme.text)
	end
	button.Size = UDim2.new(0, if state == "Buy" then 150 else 130, 0, UIKit.MIN_HIT)
	UIKit.setButtonEnabled(button, enabled)
	entry.reason.Text = reason or ""
end

local function renderVehicles()
	local list = pages.Vehicles.list
	local profile = ctx.state.get("profile")
	pages.Vehicles.balance.Text = string.format("Balance %s  -  Rep %d", UIKit.formatCash(profile and profile.cash or 0), profile and tonumber(profile.reputation) or 0)
	for index, id in ipairs(VehicleDefinitions.Order) do
		local def = VehicleDefinitions.Vehicles[id]
		if def then
			local entry = vehicleCards[id]
			if not entry or entry.card.Parent ~= list then
				entry = buildVehicleCard(list, def, index)
			end
			updateVehicleCard(entry, def, profile)
		end
	end
end

-------------------------------------------------------------------------------
-- Looks tab
-------------------------------------------------------------------------------

-- First two colour-like values in item.data, for swatches.
local function swatchColors(item: any): { Color3 }
	local colors = {}
	local order = { "Primary", "Accent", "Decal", "color", "accent", "vest", "trim", "text" }
	for _, key in ipairs(order) do
		local value = item.data and item.data[key]
		if type(value) == "table" and type(value[1]) == "number" then
			table.insert(colors, UIKit.rgb(value))
			if #colors == 2 then
				break
			end
		end
	end
	return colors
end

local function buildCosmeticRow(parent: Instance, item: any, index: number, profile: any)
	local state, reason = ShopMenu.CosmeticState(profile, item)
	local card = UIKit.card(parent, { name = "Cosmetic_" .. item.id, height = 60, layoutOrder = index, list = false })
	card:SetAttribute("State", state)
	local swatches = swatchColors(item)
	for swatchIndex, color in ipairs(swatches) do
		local swatch = UIKit.panel(card, { name = "Swatch" .. swatchIndex, color = color, size = UDim2.new(0, 22, 0, 22), position = UDim2.new(0, (swatchIndex - 1) * 26, 0.5, 0), anchor = Vector2.new(0, 0.5), corner = 6, stroke = true })
		swatch.ZIndex = 2
	end
	local textLeft = 8 + #swatches * 26
	UIKit.label(card, item.name, { name = "Name", bold = true, size = UDim2.new(1, -(textLeft + 300), 0, 22), position = UDim2.new(0, textLeft, 0, 0), maxSize = 17 })
	local priceText
	if item.paidOnly then
		priceText = "Store only"
	elseif item.price == 0 then
		priceText = "Free"
	else
		priceText = UIKit.formatCash(item.price) .. (if (item.repRequired or 0) > 0 then string.format("  -  %d Rep", item.repRequired) else "")
	end
	UIKit.label(card, priceText, { name = "Price", color = UIKit.Theme.textDim, size = UDim2.new(1, -(textLeft + 300), 0, 18), position = UDim2.new(0, textLeft, 0, 24), maxSize = 14 })

	local actions = UIKit.row(card, { name = "Actions", size = UDim2.new(0, 290, 1, 0), position = UDim2.new(1, 0, 0, 0), anchor = Vector2.new(1, 0), halign = "Right" })
	local key = "cosmetic:" .. item.id
	local button
	if state == "Equipped" then
		button = UIKit.button(actions, "Equipped", nil, { name = "StateButton", size = UDim2.new(0, 110, 0, UIKit.MIN_HIT), layoutOrder = 2, color = UIKit.Theme.success, textColor = UIKit.Theme.textOnAccent })
		UIKit.setButtonEnabled(button, false)
	elseif state == "Equip" then
		button = UIKit.primaryButton(actions, if busy[key] then "..." else "Equip", function()
			run(key, "EquipCosmetic", item.id, item.name .. " equipped.")
		end, { name = "StateButton", size = UDim2.new(0, 110, 0, UIKit.MIN_HIT), layoutOrder = 2 })
	elseif state == "Buy" then
		button = UIKit.primaryButton(actions, if busy[key] then "..." else "Buy", function()
			run(key, "PurchaseCosmetic", item.id, "")
		end, { name = "StateButton", size = UDim2.new(0, 110, 0, UIKit.MIN_HIT), layoutOrder = 2 })
	else
		button = UIKit.button(actions, if state == "StoreOnly" then "Store only" else "Locked", nil, { name = "StateButton", size = UDim2.new(0, 110, 0, UIKit.MIN_HIT), layoutOrder = 2 })
		UIKit.setButtonEnabled(button, false)
	end
	if busy[key] then
		UIKit.setButtonEnabled(button, false)
	end
	UIKit.label(actions, if state == "StoreOnly" then "" else (reason or ""), { name = "ReasonLabel", color = UIKit.Theme.warning, align = "Right", size = UDim2.new(0, 170, 1, 0), layoutOrder = 1, maxSize = 13 })
end

local function renderLooks()
	local list = pages.Looks.list
	UIKit.clearChildren(list)
	local profile = ctx.state.get("profile")
	pages.Looks.balance.Text = string.format("Balance %s  -  Rep %d", UIKit.formatCash(profile and profile.cash or 0), profile and tonumber(profile.reputation) or 0)
	local order = 0
	for _, slot in ipairs(CosmeticDefinitions.Slots) do
		order += 1
		UIKit.label(list, CosmeticDefinitions.SlotLabels[slot] or slot, { name = "Slot_" .. slot, bold = true, size = UDim2.new(1, 0, 0, 26), maxSize = 18, layoutOrder = order })
		for _, item in ipairs(CosmeticDefinitions.itemsForSlot(slot)) do
			order += 1
			buildCosmeticRow(list, item, order, profile)
		end
	end
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

function ShopMenu.Mount(parent: Instance, context: any): Frame
	ctx = context
	modal = UIKit.modal(parent, "Shop", {
		name = "ShopMenu",
		onClose = function()
			local controller = ctx.controllers and ctx.controllers.UIController
			if controller and type(controller.CloseScreen) == "function" then
				controller.CloseScreen(ShopMenu.Name)
			end
		end,
	})
	tabs = UIKit.tabs(modal.body, { "Vehicles", "Looks" }, function(name)
		currentTab = name
		for pageName, page in pairs(pages) do
			page.frame.Visible = pageName == name
		end
		ShopMenu.Update()
		UIKit.focus(pages[name].frame)
	end, { name = "Tabs" })
	for _, name in ipairs({ "Vehicles", "Looks" }) do
		local frame = UIKit.panel(modal.body, { name = "Page_" .. name, transparency = 1, corner = false, size = UDim2.new(1, 0, 1, -(UIKit.MIN_HIT + 8)), position = UDim2.new(0, 0, 0, UIKit.MIN_HIT + 8), visible = name == "Vehicles" })
		local balance = UIKit.label(frame, "", { name = "Balance", bold = true, size = UDim2.new(1, 0, 0, 22), maxSize = 16 })
		local list = UIKit.scrollList(frame, { name = "List", size = UDim2.new(1, 0, 1, -26), position = UDim2.new(0, 0, 0, 26) })
		pages[name] = { frame = frame, list = list, balance = balance }
	end
	return modal.frame
end

function ShopMenu.Update()
	if not modal then
		return
	end
	if currentTab == "Vehicles" then
		renderVehicles()
	else
		renderLooks()
	end
end

function ShopMenu.OnShow()
	ShopMenu.Update()
end

function ShopMenu.SelectTab(name: string)
	if tabs then
		tabs.select(name)
	end
end

function ShopMenu.GetFrame(): Frame?
	return modal and modal.frame
end

function ShopMenu.GetList(tab: string?): ScrollingFrame?
	local page = pages[tab or currentTab]
	return page and page.list
end

return ShopMenu
