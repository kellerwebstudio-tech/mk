--!nonstrict
-- CityService: builds the route graph and the city at server start (Init may yield; bootstrap
-- calls it before the other services' Init) and answers road/spawn queries for other services.
-- docs/ARCHITECTURE.md section 5.3.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CityFolder = Shared:WaitForChild("City")
local RouteGraph = require(CityFolder:WaitForChild("RouteGraph"))

local DeliveryDash = script.Parent.Parent
local Builders = DeliveryDash:WaitForChild("Builders")
local CityBuilder = require(Builders:WaitForChild("CityBuilder"))

local CityService = {}

CityService.RESPAWN_HEIGHT = 3 -- studs above the road surface for a safe respawn

local ctx = nil
local world = nil
local graph = nil
local padCursor = 0

local function ensureFolder(name: string): Folder
	local existing = Workspace:FindFirstChild(name)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = Workspace
	return folder
end

-- Builds ctx.graph and ctx.world. Yields while the city is built in batches.
function CityService.Init(context)
	ctx = context
	local layout = ctx.layout
	assert(type(layout) == "table", "CityService.Init: ctx.layout (CityLayout) is missing")

	graph = RouteGraph.build(layout)
	ctx.graph = graph

	local folders = {
		city = ensureFolder("City"),
		pickup = ensureFolder("PickupLocations"),
		destinations = ensureFolder("DeliveryDestinations"),
		depots = ensureFolder("DepotPlots"),
	}
	world = CityBuilder.build(layout, folders, graph)
	ctx.world = world
	padCursor = 0
end

function CityService.Start()
	-- Nothing heavy: the city is static after Init.
end

-- Point on the nearest allowed edge and its distance from `position`.
function CityService.GetNearestRoadPoint(position: Vector3, mask: number): (Vector3, number)
	local point, _, _, distance = RouteGraph.nearestPointOnGraph(graph, position, mask or RouteGraph.MASK_FOOT)
	if point == nil then
		return position, math.huge
	end
	return point, distance
end

-- Nearest allowed road point raised by `raise` studs (default RESPAWN_HEIGHT; VehicleService passes
-- the vehicle's handling.rideHeight so a parked chassis sits on the asphalt), facing along the
-- edge direction. Falls back to the hub spawn (itself RESPAWN_HEIGHT above the pad) re-based to
-- the same raise.
function CityService.GetSafeRespawnCFrame(position: Vector3, mask: number, raise: number?): CFrame
	local height = if type(raise) == "number" then raise else CityService.RESPAWN_HEIGHT
	local point, edge = RouteGraph.nearestPointOnGraph(graph, position, mask or RouteGraph.MASK_FOOT)
	if point == nil or edge == nil then
		local hub = world.hubSpawn
		return hub + Vector3.new(0, height - CityService.RESPAWN_HEIGHT, 0)
	end
	local a = graph.nodes[edge.a].position
	local b = graph.nodes[edge.b].position
	local direction = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
	if direction.Magnitude < 1e-3 then
		direction = Vector3.new(0, 0, -1)
	end
	local origin = Vector3.new(point.X, point.Y + height, point.Z)
	return CFrame.lookAt(origin, origin + direction.Unit)
end

function CityService.GetHubSpawn(): CFrame
	return world.hubSpawn
end

-- Round-robin over the hub vehicle pads (falls back to the hub spawn when none exist).
function CityService.GetFreeVehiclePad(): CFrame
	local pads = world.vehiclePads
	if #pads == 0 then
		return world.hubSpawn
	end
	padCursor = (padCursor % #pads) + 1
	return pads[padCursor]
end

function CityService.GetWorld()
	return world
end

function CityService.GetGraph()
	return graph
end

return CityService
