--!nonstrict
-- DevService: STUDIO-ONLY developer commands for playtesting and tuning (docs/DEVTOOLS.md).
-- Init returns at once (creating nothing) unless both ctx.isStudio and RunService:IsStudio() are
-- true, so a published server never owns the "DevCommand" RemoteFunction and a client can never
-- reach any of this. The remote is created directly under ReplicatedStorage.Remotes and is NOT
-- part of Shared/Util/Remotes (createAll never makes it). Every command is logged with warn so
-- it shows in the Studio Output.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Util.Remotes)
local RateLimiter = require(Shared.Util.RateLimiter)
local TableUtil = require(Shared.Util.TableUtil)
local VehicleDefinitions = require(Shared.Definitions.VehicleDefinitions)
local UpgradeDefinitions = require(Shared.Definitions.UpgradeDefinitions)
local CosmeticDefinitions = require(Shared.Definitions.CosmeticDefinitions)
local BusinessDefinitions = require(Shared.Definitions.BusinessDefinitions)
local ContractDefinitions = require(Shared.Definitions.ContractDefinitions)

local DevService = {}

DevService.REMOTE_NAME = "DevCommand"
DevService.RATE_PER_SECOND = 10
DevService.RATE_BURST = 10
DevService.MAX_STRING = 64
DevService.MAX_ARGS = 16
DevService.MAX_CASH = 1e6
DevService.MAX_REP = 1e5
DevService.MAX_SPEED_CAP = 1000
DevService.UNLOCK_REPUTATION = 2000
DevService.UNLOCK_CASH = 50000
DevService.TELEPORT_RAISE = 3

local ctx: any = nil
local remote: RemoteFunction? = nil
local limiter = RateLimiter.new(DevService.RATE_PER_SECOND, DevService.RATE_BURST)
local handlers: { [string]: (Player, any) -> any } = {}

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local function ok(extra)
	return Remotes.ok(extra)
end

local function fail(code: string, message: string?, extra)
	return Remotes.fail(code, message, extra)
end

local function service(name: string)
	return ctx and ctx.services and ctx.services[name]
end

local function getProfile(player: Player)
	local playerData = service("PlayerDataService")
	return playerData and playerData.GetProfile(player) or nil
end

local function isValidString(value: any): boolean
	return type(value) == "string" and #value > 0 and #value <= DevService.MAX_STRING
end

local function isInteger(value: any, min: number, max: number): boolean
	return TableUtil.isFiniteNumber(value) and value == math.floor(value) and value >= min and value <= max
end

-- args: nil or a small table of string keys to string / finite number / boolean values.
local function validateArgs(args: any): (boolean, string?)
	if args == nil then
		return true, nil
	end
	if type(args) ~= "table" then
		return false, "args must be a table"
	end
	local count = 0
	for key, value in pairs(args) do
		count += 1
		if count > DevService.MAX_ARGS then
			return false, "too many arguments"
		end
		if not isValidString(key) then
			return false, "argument keys must be short strings"
		end
		local kind = type(value)
		if kind == "string" then
			if #value > DevService.MAX_STRING then
				return false, "argument '" .. key .. "' is too long"
			end
		elseif kind == "number" then
			if not TableUtil.isFiniteNumber(value) then
				return false, "argument '" .. key .. "' is not finite"
			end
		elseif kind ~= "boolean" then
			return false, "argument '" .. key .. "' has an unsupported type"
		end
	end
	return true, nil
end

local function describeArgs(args: any): string
	if type(args) ~= "table" or next(args) == nil then
		return ""
	end
	local parts = {}
	for key, value in pairs(args) do
		table.insert(parts, tostring(key) .. "=" .. tostring(value))
	end
	table.sort(parts)
	return " {" .. table.concat(parts, ", ") .. "}"
end

local function log(player: Player, command: string, args: any, result: any)
	local status = if type(result) == "table" and result.ok then "ok" else ("failed: " .. tostring(type(result) == "table" and (result.message or result.error) or result))
	warn(string.format("[DevService] %s by %s%s -> %s", command, player.Name, describeArgs(args), status))
end

local function cancelOrders(player: Player, predicate: ((any) -> boolean)?): number
	local orders = service("OrderService")
	if not orders then
		return 0
	end
	local cancelled = 0
	local lists = { orders.GetActive(player), orders.GetAvailable(player) }
	for _, list in ipairs(lists) do
		for _, order in ipairs(table.clone(list)) do
			if predicate == nil or predicate(order) then
				local result = orders.Cancel(player, order.id, { silent = true, noPenalty = true, reason = "DevCommand" })
				if type(result) == "table" and result.ok then
					cancelled += 1
				end
			end
		end
	end
	return cancelled
end

local function businessName(businessId: string): string
	local def = BusinessDefinitions.get(businessId)
	return def and def.name or businessId
end

local function layoutEntries(key: string): { [string]: any }
	local byId = {}
	local layout = ctx and ctx.layout
	local list = type(layout) == "table" and layout[key]
	if type(list) == "table" then
		for _, entry in ipairs(list) do
			if type(entry) == "table" and entry.id then
				byId[entry.id] = entry
			end
		end
	end
	return byId
end

local function sortedKeys(map: { [string]: any }): { string }
	local keys = {}
	for key in pairs(map) do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

local function flatDirection(from: Vector3, to: Vector3): Vector3
	local delta = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
	if delta.Magnitude < 1e-3 then
		return Vector3.new(0, 0, -1)
	end
	return delta.Unit
end

-- Resolves a teleport target string to a ground-level position and a flat facing direction.
local function resolveTarget(target: string): (Vector3?, Vector3?, string?)
	local world = ctx and ctx.world
	if type(world) ~= "table" then
		return nil, nil, "World not built"
	end
	if target == "hub" then
		local hub = world.hubSpawn
		if typeof(hub) ~= "CFrame" then
			return nil, nil, "No hub spawn"
		end
		local look = hub.LookVector
		-- hubSpawn is authored RESPAWN_HEIGHT (3) above the pad; re-base to the ground.
		return hub.Position - Vector3.new(0, DevService.TELEPORT_RAISE, 0), flatDirection(Vector3.zero, Vector3.new(look.X, 0, look.Z)), nil
	end
	local kind, id = string.match(target, "^(%a+):(.+)$")
	if not kind or not id then
		return nil, nil, "Unknown target"
	end
	if kind == "business" then
		local business = world.businesses and world.businesses[id]
		if not business then
			return nil, nil, "Unknown business"
		end
		return business.arrivalPosition, flatDirection(business.arrivalPosition, business.pickupPosition), nil
	elseif kind == "destination" then
		local destination = world.destinations and world.destinations[id]
		if not destination then
			return nil, nil, "Unknown destination"
		end
		return destination.arrivalPosition, flatDirection(destination.arrivalPosition, destination.doorPosition), nil
	elseif kind == "plot" then
		local plot = world.depotPlots and world.depotPlots[id]
		if not plot or typeof(plot.origin) ~= "CFrame" then
			return nil, nil, "Unknown plot"
		end
		local look = plot.origin.LookVector
		return plot.origin.Position, flatDirection(Vector3.zero, Vector3.new(look.X, 0, look.Z)), nil
	elseif kind == "node" then
		local graph = ctx.graph
		local index = tonumber(id)
		local node = graph and graph.nodes and index and graph.nodes[index]
		if not node then
			return nil, nil, "Unknown node"
		end
		local facing = Vector3.new(0, 0, -1)
		local edges = graph.adjacency and graph.adjacency[index]
		local edge = edges and edges[1] and graph.edges[edges[1]]
		if edge then
			local other = if edge.a == index then edge.b else edge.a
			local otherNode = graph.nodes[other]
			if otherNode then
				facing = flatDirection(node.position, otherNode.position)
			end
		end
		return node.position, facing, nil
	end
	return nil, nil, "Unknown target"
end

-------------------------------------------------------------------------------
-- Commands
-------------------------------------------------------------------------------

handlers.GrantCash = function(player, args)
	local amount = args and args.amount
	if not isInteger(amount, 1, DevService.MAX_CASH) then
		return fail("Invalid", "amount must be an integer 1..1000000")
	end
	local playerData = service("PlayerDataService")
	if not playerData or not playerData.AddCash(player, amount, "DevGrant") then
		return fail("Locked", "Profile not loaded")
	end
	local profile = getProfile(player)
	return ok({ cash = profile and profile.cash or nil })
end

handlers.GrantRep = function(player, args)
	local amount = args and args.amount
	if not isInteger(amount, 1, DevService.MAX_REP) then
		return fail("Invalid", "amount must be an integer 1..100000")
	end
	local playerData = service("PlayerDataService")
	if not playerData or not playerData.AddReputation(player, amount, "DevGrant") then
		return fail("Locked", "Profile not loaded")
	end
	local profile = getProfile(player)
	return ok({ reputation = profile and profile.reputation or nil })
end

handlers.UnlockAll = function(player)
	local playerData = service("PlayerDataService")
	if not playerData then
		return fail("Unavailable", "PlayerDataService missing")
	end
	local applied = playerData.Update(player, function(profile)
		for vehicleId in pairs(VehicleDefinitions.Vehicles) do
			profile.ownedVehicles[vehicleId] = true
		end
		for upgradeId in pairs(UpgradeDefinitions.Upgrades) do
			profile.upgrades[upgradeId] = 1 -- upgrades are single-level (ProgressionService.CanPurchaseUpgrade)
		end
		profile.cosmetics = profile.cosmetics or { owned = {}, equipped = {} }
		profile.cosmetics.owned = profile.cosmetics.owned or {}
		for _, item in ipairs(CosmeticDefinitions.Items) do
			if not item.paidOnly then
				profile.cosmetics.owned[item.id] = true
			end
		end
		profile.reputation = math.max(profile.reputation or 0, DevService.UNLOCK_REPUTATION)
		profile.cash = math.max(profile.cash or 0, DevService.UNLOCK_CASH)
	end)
	if not applied then
		return fail("Locked", "Profile not loaded")
	end
	local vehicles = service("VehicleService")
	if vehicles and vehicles.RefreshCapacity then
		pcall(vehicles.RefreshCapacity, player)
	end
	return ok({ profile = playerData.GetPublicProfile(player) })
end

handlers.SkipTutorial = function(player)
	local tutorial = service("TutorialService")
	local profile = getProfile(player)
	if not profile then
		return fail("Locked", "Profile not loaded")
	end
	local completed = false
	if tutorial and tutorial.Complete then
		completed = tutorial.Complete(player) == true
	else
		local playerData = service("PlayerDataService")
		completed = playerData and playerData.Update(player, function(p)
			p.tutorial = { completed = true, step = 9 }
		end) or false
		pcall(function()
			ctx.remotes.getEvent("TutorialUpdated"):FireClient(player, { step = 9, completed = true })
		end)
		local orders = service("OrderService")
		if orders and orders.SetGeneratorEnabled then
			orders.SetGeneratorEnabled(player, true)
		end
	end
	-- Outstanding tutorial orders go quietly (the step machine is already at 9, so nothing is re-issued).
	local cancelled = cancelOrders(player, function(order)
		return order.isTutorial == true
	end)
	return ok({ completed = completed, cancelled = cancelled, step = profile.tutorial and profile.tutorial.step or nil })
end

handlers.ResetProfile = function(player)
	local playerData = service("PlayerDataService")
	if not playerData then
		return fail("Unavailable", "PlayerDataService missing")
	end
	local profile = getProfile(player)
	if not profile then
		return fail("Locked", "Profile not loaded")
	end
	-- Orders and the vehicle first (their cancellation hooks read the old profile).
	local cancelled = cancelOrders(player, nil)
	local vehicles = service("VehicleService")
	if vehicles and vehicles.GetVehicle and vehicles.GetVehicle(player) then
		pcall(vehicles.Despawn, player)
	end
	local depot = service("DepotService")
	if depot and depot.ReleasePlot then
		pcall(depot.ReleasePlot, player)
	end
	local applied = playerData.Update(player, function(p)
		local schemaVersion = p.schemaVersion
		local loadFailed = p.__loadFailed
		for key in pairs(p) do
			p[key] = nil
		end
		for key, value in pairs(TableUtil.deepCopy(playerData.DEFAULT_PROFILE)) do
			p[key] = value
		end
		p.schemaVersion = schemaVersion
		if loadFailed ~= nil then
			p.__loadFailed = loadFailed
		end
	end)
	if not applied then
		return fail("Locked", "Profile not loaded")
	end
	local orders = service("OrderService")
	if orders and orders.SetGeneratorEnabled then
		orders.SetGeneratorEnabled(player, false)
	end
	local tutorial = service("TutorialService")
	if tutorial and tutorial.Restart then
		tutorial.Restart(player)
	end
	-- TutorialService re-issues a withdrawn tutorial order while its step is 1..7 (OrderRemoved
	-- hook), so the first pass above can leave a fresh tutorial order behind. The state is back at
	-- step 0 now (no tracked order ids), so a second pass clears it without another re-issue.
	cancelled += cancelOrders(player, nil)
	local shop = service("ShopService")
	if shop and shop.ApplyUniform then
		pcall(shop.ApplyUniform, player)
	end
	if depot and depot.PushState then
		pcall(depot.PushState, player)
	end
	return ok({ cancelled = cancelled, profile = playerData.GetPublicProfile(player) })
end

handlers.OwnVehicle = function(player, args)
	local vehicleId = args and args.vehicleId
	if not isValidString(vehicleId) or not VehicleDefinitions.get(vehicleId) then
		return fail("Invalid", "Unknown vehicle")
	end
	local playerData = service("PlayerDataService")
	local vehicles = service("VehicleService")
	if not playerData or not vehicles then
		return fail("Unavailable", "Services missing")
	end
	local applied = playerData.Update(player, function(profile)
		profile.ownedVehicles[vehicleId] = true
		profile.equippedVehicle = vehicleId
	end)
	if not applied then
		return fail("Locked", "Profile not loaded")
	end
	return vehicles.Spawn(player, vehicleId)
end

handlers.Despawn = function(player)
	local vehicles = service("VehicleService")
	if not vehicles then
		return fail("Unavailable", "VehicleService missing")
	end
	return vehicles.Despawn(player)
end

handlers.Recover = function(player)
	local vehicles = service("VehicleService")
	if not vehicles then
		return fail("Unavailable", "VehicleService missing")
	end
	return vehicles.Recover(player)
end

handlers.ListTargets = function()
	local world = ctx and ctx.world
	local targets = {}
	if type(world) ~= "table" then
		return ok({ targets = targets })
	end
	if typeof(world.hubSpawn) == "CFrame" then
		table.insert(targets, { id = "hub", label = "Dash Hub", kind = "hub" })
	end
	for _, businessId in ipairs(sortedKeys(world.businesses or {})) do
		table.insert(targets, { id = "business:" .. businessId, label = businessName(businessId), kind = "business" })
	end
	local destinationInfo = layoutEntries("destinations")
	for _, destinationId in ipairs(sortedKeys(world.destinations or {})) do
		local info = destinationInfo[destinationId]
		local label = info and info.address or destinationId
		table.insert(targets, { id = "destination:" .. destinationId, label = label, kind = "destination" })
	end
	for _, plotId in ipairs(sortedKeys(world.depotPlots or {})) do
		table.insert(targets, { id = "plot:" .. plotId, label = "Plot " .. plotId, kind = "plot" })
	end
	return ok({ targets = targets })
end

handlers.Teleport = function(player, args)
	local target = args and args.target
	if not isValidString(target) then
		return fail("Invalid", "target must be hub | business:<id> | destination:<id> | plot:<id> | node:<index>")
	end
	local position, facing, reason = resolveTarget(target)
	if not position then
		return fail("NotFound", reason or "Unknown target")
	end
	local vehicles = service("VehicleService")
	local anti = service("AntiCheatService")
	if vehicles and vehicles.IsDriving and vehicles.IsDriving(player) and vehicles.TeleportTo then
		-- Land on the nearest road the vehicle may use, through the recovery placement path.
		local ground = CFrame.lookAlong(position, facing)
		local city = service("CityService")
		if city and city.GetSafeRespawnCFrame then
			local mask = vehicles.GetVehicleMask and vehicles.GetVehicleMask(player) or VehicleDefinitions.Mask.Foot
			local okCf, cf = pcall(city.GetSafeRespawnCFrame, position, mask, 0)
			if okCf and typeof(cf) == "CFrame" then
				ground = CFrame.lookAlong(cf.Position, facing)
			end
		end
		local result = vehicles.TeleportTo(player, ground)
		if type(result) == "table" and result.ok then
			result.mode = "vehicle"
			result.target = target
		end
		return result
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not character or not root then
		return fail("Invalid", "No character")
	end
	local destination = position + Vector3.new(0, DevService.TELEPORT_RAISE, 0)
	local okPivot, err = pcall(function()
		character:PivotTo(CFrame.lookAlong(destination, facing))
	end)
	if not okPivot then
		return fail("Internal", tostring(err))
	end
	if anti and anti.NotePlausibleTeleport then
		pcall(anti.NotePlausibleTeleport, player, 3, destination)
	end
	return ok({ mode = "character", target = target, position = destination })
end

handlers.OpenLunchRush = function(player, args)
	local neighborhood = args and args.neighborhood
	if neighborhood ~= nil then
		if not isValidString(neighborhood) or not TableUtil.contains(ContractDefinitions.LunchRush.neighborhoods, neighborhood) then
			return fail("Invalid", "neighborhood must be one of " .. table.concat(ContractDefinitions.LunchRush.neighborhoods, ", "))
		end
	end
	local contracts = service("ContractService")
	if not contracts or not contracts.ForceOpen then
		return fail("Unavailable", "ContractService missing")
	end
	contracts.ForceOpen(neighborhood)
	local state = contracts.GetStateFor and contracts.GetStateFor(player) or nil
	return ok({ contract = state })
end

handlers.ExpireContract = function(player)
	local contracts = service("ContractService")
	if not contracts then
		return fail("Unavailable", "ContractService missing")
	end
	if type(contracts.ForceEnd) == "function" then
		contracts.ForceEnd()
		return ok({ contract = contracts.GetStateFor and contracts.GetStateFor(player) or nil })
	end
	return fail("Unavailable", "ContractService exposes no end-now API; skipped (wait for the window, or open a new rush)")
end

handlers.FinishDrivers = function(player)
	local playerData = service("PlayerDataService")
	local drivers = service("DriverService")
	if not playerData or not drivers then
		return fail("Unavailable", "Services missing")
	end
	local profile = getProfile(player)
	if not profile then
		return fail("Locked", "Profile not loaded")
	end
	local forced = 0
	playerData.Update(player, function(p)
		local depot = p.depot
		for _, slot in ipairs(depot and depot.drivers or {}) do
			local assignment = slot.assignment
			if type(assignment) == "table" and not assignment.completed then
				assignment.endsAt = os.time() - 1
				forced += 1
			end
		end
	end)
	local completed = 0
	if drivers.Tick then
		completed = drivers.Tick() or 0
	elseif drivers.CompleteDue then
		completed = drivers.CompleteDue(profile, os.time())
	end
	return ok({ forced = forced, completed = completed })
end

handlers.FillBoard = function(player)
	local orders = service("OrderService")
	if not orders or not orders.RunGeneration then
		return fail("Unavailable", "OrderService missing")
	end
	local before = #orders.GetAvailable(player)
	orders.RunGeneration(player)
	local after = #orders.GetAvailable(player)
	local enabled = orders.IsGeneratorEnabled and orders.IsGeneratorEnabled(player) or false
	return ok({ added = after - before, available = after, generatorEnabled = enabled, message = if enabled then nil else "Generator disabled (tutorial in progress); nothing generated" })
end

handlers.ReadyOrders = function(player)
	local orders = service("OrderService")
	if not orders then
		return fail("Unavailable", "OrderService missing")
	end
	local now = os.clock()
	local readied = 0
	for _, order in ipairs(orders.GetActive(player)) do
		if order.state == "Accepted" then
			order.readyAt = now
			readied += 1
		end
	end
	if orders.RunTick then
		orders.RunTick()
	end
	return ok({ readied = readied })
end

handlers.SetSpeedCap = function(player, args)
	local vehicleId = args and args.vehicleId
	local maxSpeed = args and args.maxSpeed
	if not isValidString(vehicleId) or not VehicleDefinitions.get(vehicleId) then
		return fail("Invalid", "Unknown vehicle")
	end
	if maxSpeed ~= nil and not (TableUtil.isFiniteNumber(maxSpeed) and maxSpeed >= 0 and maxSpeed <= DevService.MAX_SPEED_CAP) then
		return fail("Invalid", "maxSpeed must be a number 0..1000 (0 clears)")
	end
	local anti = service("AntiCheatService")
	if not anti or not anti.SetSpeedOverride then
		return fail("Unavailable", "AntiCheatService missing")
	end
	anti.SetSpeedOverride(player, vehicleId, maxSpeed)
	return ok({ vehicleId = vehicleId, maxSpeed = anti.GetSpeedOverride and anti.GetSpeedOverride(player, vehicleId) or nil })
end

handlers.Report = function(player)
	local profile = getProfile(player)
	if not profile then
		return fail("Locked", "Profile not loaded")
	end
	local vehicles = service("VehicleService")
	local orders = service("OrderService")
	local contracts = service("ContractService")
	local depot = service("DepotService")
	local anti = service("AntiCheatService")

	local activeOrders = {}
	if orders and orders.GetActive then
		for _, order in ipairs(orders.GetActive(player)) do
			table.insert(activeOrders, { id = order.id, state = order.state, business = order.businessId, destination = order.destinationId })
		end
	end
	local contractState = contracts and contracts.GetStateFor and contracts.GetStateFor(player) or nil
	local pending = 0
	for _, slot in ipairs(profile.depot and profile.depot.drivers or {}) do
		pending += tonumber(slot.pending) or 0
	end
	return ok({
		cash = profile.cash,
		reputation = profile.reputation,
		deliveries = profile.stats and profile.stats.deliveries or 0,
		tutorialStep = profile.tutorial and profile.tutorial.step or nil,
		tutorialCompleted = profile.tutorial and profile.tutorial.completed == true or false,
		vehicle = {
			state = vehicles and vehicles.GetState and vehicles.GetState(player) or nil,
			vehicleId = vehicles and vehicles.GetCurrentVehicleId and vehicles.GetCurrentVehicleId(player) or nil,
		},
		activeOrders = activeOrders,
		contract = {
			id = contractState and contractState.id or nil,
			status = contractState and contractState.status or nil,
			neighborhood = contractState and contractState.neighborhood or nil,
		},
		depot = {
			owned = profile.depot and profile.depot.owned == true or false,
			plot = depot and depot.GetPlotId and depot.GetPlotId(player) or nil,
			pending = pending,
		},
		antiCheatStrikes = anti and anti.GetStrikes and anti.GetStrikes(player) or 0,
	})
end

-------------------------------------------------------------------------------
-- Dispatch
-------------------------------------------------------------------------------

-- Validates and runs a command for a player. Public so the offline specs can call it directly.
function DevService.Invoke(player: Player, command: any, args: any)
	if not remote then
		return fail("Unavailable", "Dev commands are Studio-only")
	end
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return fail("Invalid", "Invalid caller")
	end
	if not isValidString(command) then
		return fail("Invalid", "Invalid command")
	end
	local handler = handlers[command]
	if not handler then
		return fail("NotFound", "Unknown command " .. command)
	end
	if not limiter:Allow(player) then
		return fail("RateLimited", "Slow down")
	end
	local argsOk, reason = validateArgs(args)
	if not argsOk then
		local result = fail("Invalid", reason)
		log(player, command, args, result)
		return result
	end
	local okRun, result = pcall(handler, player, args)
	if not okRun then
		warn("[DevService] " .. command .. " raised: " .. tostring(result))
		return fail("Internal", tostring(result))
	end
	if type(result) ~= "table" then
		result = ok()
	end
	log(player, command, args, result)
	return result
end

function DevService.IsEnabled(): boolean
	return remote ~= nil
end

function DevService.GetCommands(): { string }
	return sortedKeys(handlers)
end

function DevService.Init(context)
	ctx = context
	remote = nil
	if not ctx or ctx.isStudio ~= true or not RunService:IsStudio() then
		return
	end
	local folder = ReplicatedStorage:FindFirstChild(Remotes.FOLDER_NAME)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = Remotes.FOLDER_NAME
		folder.Parent = ReplicatedStorage
	end
	local existing = folder:FindFirstChild(DevService.REMOTE_NAME)
	if existing then
		existing:Destroy()
	end
	local created = Instance.new("RemoteFunction")
	created.Name = DevService.REMOTE_NAME
	created.Parent = folder
	created.OnServerInvoke = function(player, command, args)
		return DevService.Invoke(player, command, args)
	end
	remote = created
	warn("[DevService] Studio dev commands enabled (" .. #DevService.GetCommands() .. " commands)")
end

function DevService.Start()
	if not remote then
		return
	end
	Players.PlayerRemoving:Connect(function(player)
		limiter:Reset(player)
	end)
end

return DevService
