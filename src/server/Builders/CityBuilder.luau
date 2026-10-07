--!nonstrict
-- CityBuilder: builds the whole city from CityLayout data at server start and returns the
-- ctx.world table (docs/ARCHITECTURE.md section 5). Everything is plain anchored parts built
-- in batches; no templates are cloned.
--
-- Workspace.City (Folder)
--   Terrain is filled directly (grass slab + water basins)
--   Roads, Sidewalks, Markings, Buildings, Landmarks, Props, ParkedVehicles (Folders)
-- Workspace.PickupLocations/<businessId>      (Model: Storefront, Counter, PickupPad, Door, Staff)
-- Workspace.DeliveryDestinations/<destId>     (Model: Door, Doorbell, AddressSign, ArrivalPad, Building?)
-- Workspace.DepotPlots/<plotId>               (Model: Ground, Fence, Sign, Parking, Built)
--
-- CityBuilder.positionsFor(layout) is a pure helper (no instances) that computes every world
-- position the builder uses, so tests and other modules get identical numbers.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Definitions = Shared:WaitForChild("Definitions")
local CityFolder = Shared:WaitForChild("City")
local BusinessDefinitions = require(Definitions:WaitForChild("BusinessDefinitions"))
local RouteGraph = require(CityFolder:WaitForChild("RouteGraph"))
local NPCBuilder = require(script.Parent:WaitForChild("NPCBuilder"))

local CityBuilder = {}

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------

CityBuilder.PART_BUDGET = 4500 -- hard budget from ARCHITECTURE.md section 11
CityBuilder.DECOR_BUDGET = 4100 -- above this count, optional decoration is skipped
CityBuilder.YIELD_EVERY = 400 -- parts between yield checks
CityBuilder.YIELD_MIN_ELAPSED = 0.008 -- seconds of real work before a batch actually yields

local ROAD_THICKNESS = 1
local SIDEWALK_WIDTH = 6
local SIDEWALK_HEIGHT = 0.5
local SIDEWALK_GAP = 0 -- sidewalk starts right at the road edge
local MARKING_THICKNESS = 0.05
local DASH_SPACING = 16
local DASH_LENGTH = 5
local ROAD_SEARCH_DISTANCE = 40 -- max distance a road influences elevation lookups
local SLOPE_EPSILON = 0.2

local GROUND_GRASS = Enum.Material.Grass
-- The walkable ground is made of large anchored Parts (crisp, no terrain smoothing or grass
-- blades poking through roads). Terrain sits GROUND_THICKNESS below it and only shapes the canal.
local GROUND_THICKNESS = 2
local GROUND_TOP_OFFSET = -0.1 -- ground top sits just under road tops so coplanar faces never z-fight
local GROUND_COLOR = Color3.fromRGB(104, 158, 70)
local GROUND_MARGIN = 64
local CONCRETE_COLOR = Color3.fromRGB(200, 200, 196)
local CURB_COLOR = Color3.fromRGB(180, 180, 176)

local ROAD_STYLE = {
	Road = { color = Color3.fromRGB(70, 70, 74), material = Enum.Material.Asphalt },
	Street = { color = Color3.fromRGB(82, 82, 86), material = Enum.Material.Asphalt },
	Industrial = { color = Color3.fromRGB(110, 110, 112), material = Enum.Material.Concrete },
	Alley = { color = Color3.fromRGB(74, 72, 70), material = Enum.Material.Concrete },
	BikePath = { color = Color3.fromRGB(150, 86, 74), material = Enum.Material.Concrete },
	Bridge = { color = Color3.fromRGB(120, 120, 124), material = Enum.Material.Concrete },
	BikeBridge = { color = Color3.fromRGB(150, 86, 74), material = Enum.Material.Concrete },
	Ramp = { color = Color3.fromRGB(76, 76, 80), material = Enum.Material.Asphalt },
}

local SIDEWALK_KINDS = { Road = true, Street = true, Industrial = true }
local MARKING_KINDS = { Road = true, Industrial = true }
local BRIDGE_KINDS = { Bridge = true, BikeBridge = true }

-- Building styles: base colour/material and which details they get.
local BUILDING_STYLES = {
	Shop = { color = { 196, 120, 90 }, material = "Brick", awning = true, door = true, accent = { 230, 80, 60 } },
	Cafe = { color = { 236, 214, 180 }, material = "SmoothPlastic", awning = true, door = true, accent = { 150, 95, 60 } },
	Pizza = { color = { 170, 60, 50 }, material = "Brick", awning = true, door = true, accent = { 240, 230, 200 } },
	Market = { color = { 120, 160, 110 }, material = "Concrete", awning = true, door = true, accent = { 250, 240, 200 } },
	Apartment = { color = { 190, 150, 120 }, material = "Brick", windows = true, door = true },
	House = { color = { 236, 226, 200 }, material = "WoodPlanks", roof = true, door = true },
	Warehouse = { color = { 140, 145, 150 }, material = "Metal", roller = true },
	Tower = { color = { 90, 110, 140 }, material = "Metal", windows = true, door = true },
	Hub = { color = { 250, 150, 50 }, material = "SmoothPlastic", door = true },
	Office = { color = { 200, 205, 210 }, material = "Concrete", windows = true, door = true },
}

local WINDOW_COLOR = Color3.fromRGB(40, 55, 70)
local DOOR_COLOR = Color3.fromRGB(70, 45, 30)
local ROOF_COLOR = Color3.fromRGB(110, 70, 60)
local TRUNK_COLOR = Color3.fromRGB(100, 70, 45)
local LEAF_COLORS = { Color3.fromRGB(70, 140, 60), Color3.fromRGB(90, 160, 70), Color3.fromRGB(200, 120, 50), Color3.fromRGB(60, 120, 70) }
local CONTAINER_COLORS = { Color3.fromRGB(180, 60, 50), Color3.fromRGB(50, 90, 160), Color3.fromRGB(70, 130, 80), Color3.fromRGB(220, 150, 50), Color3.fromRGB(120, 120, 125) }

-------------------------------------------------------------------------------
-- Build state (part counting + batching)
-------------------------------------------------------------------------------

local state = nil

local function beginBuild()
	state = { count = 0, sinceYield = 0, lastYield = os.clock(), skippedDecor = 0 }
end

-- Counts a part; every YIELD_EVERY parts the builder yields one frame if real time was spent
-- (os.clock does not advance inside the offline harness, so tests never yield).
local function countPart()
	state.count += 1
	state.sinceYield += 1
	if state.sinceYield >= CityBuilder.YIELD_EVERY then
		state.sinceYield = 0
		if os.clock() - state.lastYield >= CityBuilder.YIELD_MIN_ELAPSED then
			task.wait()
			state.lastYield = os.clock()
		end
	end
end

local function decorOk(): boolean
	if state.count < CityBuilder.DECOR_BUDGET then
		return true
	end
	state.skippedDecor += 1
	return false
end

-------------------------------------------------------------------------------
-- Small helpers
-------------------------------------------------------------------------------

-- Accepts a Color3, a {r, g, b} array (0-255, as in Definitions) or a keyed { r =, g =, b = } table
-- (0-1 floats, as authored in CityLayout; values above 1 are treated as 0-255).
local function rgb(c): Color3
	if typeof(c) == "Color3" then
		return c
	end
	if type(c) ~= "table" then
		return Color3.fromRGB(200, 200, 200)
	end
	local r, g, b
	if c.r ~= nil then
		r, g, b = c.r or 0, c.g or 0, c.b or 0
		if math.max(r, g, b) > 1 then
			return Color3.fromRGB(r, g, b)
		end
		return Color3.new(r, g, b)
	end
	r, g, b = c[1] or 0, c[2] or 0, c[3] or 0
	if r % 1 ~= 0 or g % 1 ~= 0 or b % 1 ~= 0 then
		return Color3.new(math.clamp(r, 0, 1), math.clamp(g, 0, 1), math.clamp(b, 0, 1))
	end
	return Color3.fromRGB(r, g, b)
end

local function materialFrom(name: string?, fallback: Enum.Material?): Enum.Material
	if name then
		local ok, material = pcall(function()
			return Enum.Material[name]
		end)
		if ok and material then
			return material
		end
	end
	return fallback or Enum.Material.SmoothPlastic
end

-- Shifts a colour toward white (t > 0) or black (t < 0) for per-building variation.
local function tint(color: Color3, t: number): Color3
	if t >= 0 then
		return color:Lerp(Color3.new(1, 1, 1), t)
	end
	return color:Lerp(Color3.new(0, 0, 0), -t)
end

local function flatUnit(v: Vector3, fallback: Vector3?): Vector3
	local flat = Vector3.new(v.X, 0, v.Z)
	if flat.Magnitude < 1e-4 then
		return fallback or Vector3.new(0, 0, -1)
	end
	return flat.Unit
end

local function facingVector(f): Vector3
	if type(f) == "table" and f.x ~= nil and f.z ~= nil then
		return flatUnit(Vector3.new(f.x, 0, f.z))
	end
	return Vector3.new(0, 0, -1)
end

-- CFrame at `position` whose -Z axis points along the flat direction `dir`.
local function lookFlat(position: Vector3, dir: Vector3): CFrame
	local d = flatUnit(dir)
	return CFrame.lookAt(position, position + d)
end

-- Upright cylinder (Roblox cylinders have their axis along X).
local function uprightCylinderCFrame(position: Vector3): CFrame
	return CFrame.new(position) * CFrame.Angles(0, 0, math.pi / 2)
end

-- One helper creates every part with consistent defaults.
-- props: class?, shape?, name, size, cframe, color?, material?, transparency?, reflectance?,
--        parent, detail? (non-colliding/non-query/non-touch), collide?, query?, touch?, castShadow?
local function mk(props): BasePart
	local part = Instance.new(props.class or "Part")
	part.Name = props.name or "Part"
	if props.shape and part:IsA("Part") then
		part.Shape = props.shape
	end
	part.Size = props.size
	part.CFrame = props.cframe
	part.Color = props.color or CONCRETE_COLOR
	part.Material = props.material or Enum.Material.SmoothPlastic
	part.Anchored = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	if props.transparency then
		part.Transparency = props.transparency
	end
	if props.reflectance then
		part.Reflectance = props.reflectance
	end
	local detail = props.detail == true
	local collide = if props.collide ~= nil then props.collide else not detail
	part.CanCollide = collide
	part.CanQuery = if props.query ~= nil then props.query else collide
	part.CanTouch = if props.touch ~= nil then props.touch else collide
	local size = props.size
	local small = math.max(size.X, size.Y, size.Z) < 3
	if props.castShadow ~= nil then
		part.CastShadow = props.castShadow
	else
		part.CastShadow = not (detail and small)
	end
	part.Parent = props.parent
	countPart()
	return part
end

local function newFolder(name: string, parent: Instance): Folder
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

local function newModel(name: string, parent: Instance): Model
	local model = Instance.new("Model")
	model.Name = name
	model.Parent = parent
	return model
end

-- SurfaceGui with a single scaled text label on the given face.
local function surfaceText(part: BasePart, face: Enum.NormalId, text: string, textColor: Color3, name: string?): TextLabel
	local gui = Instance.new("SurfaceGui")
	gui.Name = name or "SignGui"
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.LightInfluence = 0.5
	gui.Parent = part
	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.Size = UDim2.fromScale(0.94, 0.8)
	label.Position = UDim2.fromScale(0.03, 0.1)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = textColor
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.Parent = gui
	return label
end

-- BillboardGui title floating above a part.
local function billboard(part: BasePart, text: string, height: number, color: Color3, maxDistance: number?): TextLabel
	local gui = Instance.new("BillboardGui")
	gui.Name = "Title"
	gui.Size = UDim2.new(0, 220, 0, 60)
	gui.StudsOffset = Vector3.new(0, height, 0)
	gui.MaxDistance = maxDistance or 140
	gui.LightInfluence = 0
	gui.AlwaysOnTop = false
	gui.Parent = part
	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = color
	label.TextStrokeTransparency = 0.3
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.Parent = gui
	return label
end

-------------------------------------------------------------------------------
-- Pure layout geometry (no instances) — shared by positionsFor and build
-------------------------------------------------------------------------------

local function pointY(p, groundY: number): number
	if p.y ~= nil then
		return p.y
	end
	return groundY
end

-- Nearest road segment (2D) to (x, z). Returns distance, interpolated y, road, segment index.
local function roadSample(layout, x: number, z: number)
	local groundY = layout.groundY or 0
	local bestDist = math.huge
	local bestY = groundY
	local bestRoad = nil
	local bestIndex = 0
	for _, road in ipairs(layout.roads or {}) do
		local points = road.points or {}
		for i = 1, #points - 1 do
			local a, b = points[i], points[i + 1]
			local abx, abz = b.x - a.x, b.z - a.z
			local len2 = abx * abx + abz * abz
			local t = 0
			if len2 > 1e-9 then
				t = math.clamp(((x - a.x) * abx + (z - a.z) * abz) / len2, 0, 1)
			end
			local px, pz = a.x + abx * t, a.z + abz * t
			local dx, dz = x - px, z - pz
			local d = math.sqrt(dx * dx + dz * dz)
			if d < bestDist then
				bestDist = d
				bestY = pointY(a, groundY) + (pointY(b, groundY) - pointY(a, groundY)) * t
				bestRoad = road
				bestIndex = i
			end
		end
	end
	return bestDist, bestY, bestRoad, bestIndex
end

local function roadHasSidewalk(road): boolean
	return road ~= nil and SIDEWALK_KINDS[road.kind] == true and road.sidewalk ~= false
end

-- Ground elevation at (x, z): the nearest road's elevation when close enough, else groundY.
local function elevationAt(layout, x: number, z: number): number
	local groundY = layout.groundY or 0
	local dist, y = roadSample(layout, x, z)
	if dist <= ROAD_SEARCH_DISTANCE then
		return math.max(groundY, y)
	end
	return groundY
end

-- Walkable surface height at (x, z): road top, sidewalk top or ground.
local function surfaceYAt(layout, x: number, z: number): number
	local groundY = layout.groundY or 0
	local dist, y, road = roadSample(layout, x, z)
	if road then
		local half = (road.width or 10) / 2
		if dist <= half then
			return y
		elseif dist <= half + SIDEWALK_WIDTH and roadHasSidewalk(road) then
			return y + SIDEWALK_HEIGHT
		elseif dist <= ROAD_SEARCH_DISTANCE then
			return math.max(groundY, y)
		end
	end
	return groundY
end

CityBuilder.elevationAt = elevationAt
CityBuilder.surfaceYAt = surfaceYAt

--[[
	Pure data helper: every world position the builder uses, computed without creating instances.
	{
	  businesses = { [id] = { pickup: Vector3, arrival: Vector3, door: Vector3, facing: Vector3 } },
	  destinations = { [id] = { door: Vector3, arrival: Vector3, facing: Vector3 } },
	  hubSpawn: CFrame (3 studs above the spawn pad, facing hub.spawn.facing),
	  vehiclePads = { CFrame } (pad top centre, facing),
	  depotPlots = { [id] = { origin: CFrame, parking: { CFrame } } },
	  kiosk: Vector3?
	}
]]
function CityBuilder.positionsFor(layout)
	assert(type(layout) == "table", "positionsFor requires a layout table")
	local result = { businesses = {}, destinations = {}, depotPlots = {}, vehiclePads = {} }

	for _, business in ipairs(layout.businesses or {}) do
		local door = business.door or business.pickupPoint
		local pickup = business.pickupPoint or door
		local arrival = business.arrivalPoint or pickup
		result.businesses[business.id] = {
			pickup = Vector3.new(pickup.x, surfaceYAt(layout, pickup.x, pickup.z), pickup.z),
			arrival = Vector3.new(arrival.x, surfaceYAt(layout, arrival.x, arrival.z), arrival.z),
			door = Vector3.new(door.x, surfaceYAt(layout, door.x, door.z), door.z),
			facing = facingVector(business.facing),
		}
	end

	for _, destination in ipairs(layout.destinations or {}) do
		local door = destination.door
		local arrival = destination.arrivalPoint or door
		result.destinations[destination.id] = {
			door = Vector3.new(door.x, surfaceYAt(layout, door.x, door.z), door.z),
			arrival = Vector3.new(arrival.x, surfaceYAt(layout, arrival.x, arrival.z), arrival.z),
			facing = facingVector(destination.facing),
		}
	end

	local hub = layout.hub or {}
	local spawn = hub.spawn or { x = 0, z = 0 }
	local spawnY = surfaceYAt(layout, spawn.x, spawn.z)
	local spawnPos = Vector3.new(spawn.x, spawnY + 3, spawn.z)
	result.hubSpawn = lookFlat(spawnPos, facingVector(spawn.facing))
	result.spawnSurfaceY = spawnY
	for _, pad in ipairs(hub.vehiclePads or {}) do
		local y = surfaceYAt(layout, pad.x, pad.z)
		table.insert(result.vehiclePads, lookFlat(Vector3.new(pad.x, y + 0.3, pad.z), facingVector(pad.facing)))
	end
	if hub.kiosk then
		result.kiosk = Vector3.new(hub.kiosk.x, surfaceYAt(layout, hub.kiosk.x, hub.kiosk.z), hub.kiosk.z)
	end

	for _, plot in ipairs(layout.depotPlots or {}) do
		local y = elevationAt(layout, plot.x, plot.z)
		local slabTop = y + 0.4
		local parking = {}
		for _, spot in ipairs(plot.parking or {}) do
			table.insert(parking, lookFlat(Vector3.new(spot.x, slabTop, spot.z), facingVector(spot.facing or plot.facing)))
		end
		result.depotPlots[plot.id] = {
			origin = lookFlat(Vector3.new(plot.x, slabTop, plot.z), facingVector(plot.facing)),
			parking = parking,
			groundY = y,
		}
	end

	return result
end

-------------------------------------------------------------------------------
-- Terrain
-------------------------------------------------------------------------------

local function buildTerrain(layout)
	local terrain = Workspace:FindFirstChildOfClass("Terrain")
	if not terrain then
		warn("[CityBuilder] No Terrain instance; skipping terrain fill")
		return
	end
	local groundY = layout.groundY or 0
	local bounds = layout.bounds or { minX = -512, maxX = 512, minZ = -512, maxZ = 512 }
	local width = (bounds.maxX - bounds.minX) + GROUND_MARGIN * 2
	local depth = (bounds.maxZ - bounds.minZ) + GROUND_MARGIN * 2
	local cx = (bounds.minX + bounds.maxX) / 2
	local cz = (bounds.minZ + bounds.maxZ) / 2
	-- Terrain top sits under the part-based ground layer (see buildGround).
	local terrainTop = groundY + GROUND_TOP_OFFSET - GROUND_THICKNESS
	local function fillY(x, z, w, d, fromY, toY, material)
		local height = toY - fromY
		if height <= 0 then
			return
		end
		terrain:FillBlock(CFrame.new(x, fromY + height / 2, z), Vector3.new(w, height, d), material)
	end
	local ok, err = pcall(function()
		pcall(function()
			terrain.Decoration = false -- no grass blades through roads and pads
		end)
		fillY(cx, cz, width, depth, terrainTop - 8, terrainTop, GROUND_GRASS)
		for _, water in ipairs(layout.water or {}) do
			local surfaceY = water.surfaceY or (groundY - 1)
			local waterDepth = water.depth or 6
			local floorY = surfaceY - waterDepth
			-- Basin: slate walls/floor 2 studs thick around the water volume, up to the ground underside,
			-- then carve the inside and fill the water.
			fillY(water.x, water.z, water.w + 4, water.d + 4, floorY - 2, terrainTop, Enum.Material.Slate)
			fillY(water.x, water.z, water.w, water.d, floorY, terrainTop + 4, Enum.Material.Air)
			fillY(water.x, water.z, water.w, water.d, floorY, surfaceY, Enum.Material.Water)
		end
	end)
	if not ok then
		warn("[CityBuilder] Terrain fill failed: " .. tostring(err))
	end
end

-------------------------------------------------------------------------------
-- Ground layer (parts)
-------------------------------------------------------------------------------

-- Axis-aligned rectangle subtraction: returns the pieces of `rect` outside `hole`.
local function subtractRect(rect, hole)
	local overlaps = hole.minX < rect.maxX and hole.maxX > rect.minX and hole.minZ < rect.maxZ and hole.maxZ > rect.minZ
	if not overlaps then
		return { rect }
	end
	local pieces = {}
	if hole.minX > rect.minX then
		table.insert(pieces, { minX = rect.minX, maxX = hole.minX, minZ = rect.minZ, maxZ = rect.maxZ })
	end
	if hole.maxX < rect.maxX then
		table.insert(pieces, { minX = hole.maxX, maxX = rect.maxX, minZ = rect.minZ, maxZ = rect.maxZ })
	end
	local midMinX = math.max(rect.minX, hole.minX)
	local midMaxX = math.min(rect.maxX, hole.maxX)
	if hole.minZ > rect.minZ then
		table.insert(pieces, { minX = midMinX, maxX = midMaxX, minZ = rect.minZ, maxZ = hole.minZ })
	end
	if hole.maxZ < rect.maxZ then
		table.insert(pieces, { minX = midMinX, maxX = midMaxX, minZ = hole.maxZ, maxZ = rect.maxZ })
	end
	return pieces
end

-- Returns the ground rectangles (bounds + margin minus water) without creating instances.
local function groundRects(layout)
	local bounds = layout.bounds or { minX = -512, maxX = 512, minZ = -512, maxZ = 512 }
	local rects = { {
		minX = bounds.minX - GROUND_MARGIN,
		maxX = bounds.maxX + GROUND_MARGIN,
		minZ = bounds.minZ - GROUND_MARGIN,
		maxZ = bounds.maxZ + GROUND_MARGIN,
	} }
	for _, water in ipairs(layout.water or {}) do
		local hole = {
			minX = water.x - water.w / 2,
			maxX = water.x + water.w / 2,
			minZ = water.z - water.d / 2,
			maxZ = water.z + water.d / 2,
		}
		local next = {}
		for _, rect in ipairs(rects) do
			for _, piece in ipairs(subtractRect(rect, hole)) do
				if piece.maxX - piece.minX > 0.5 and piece.maxZ - piece.minZ > 0.5 then
					table.insert(next, piece)
				end
			end
		end
		rects = next
	end
	return rects
end
CityBuilder.groundRects = groundRects

-- Large anchored Grass parts forming the walkable ground (top at groundY + GROUND_TOP_OFFSET).
local function buildGround(layout, parent: Instance)
	local groundY = layout.groundY or 0
	local folder = newFolder("Ground", parent)
	local top = groundY + GROUND_TOP_OFFSET
	local MAX_PART = 2000 -- Roblox parts cap at 2048 studs per axis
	for _, rect in ipairs(groundRects(layout)) do
		local w = rect.maxX - rect.minX
		local d = rect.maxZ - rect.minZ
		local nx = math.max(1, math.ceil(w / MAX_PART))
		local nz = math.max(1, math.ceil(d / MAX_PART))
		for ix = 0, nx - 1 do
			for iz = 0, nz - 1 do
				local x0 = rect.minX + w * ix / nx
				local x1 = rect.minX + w * (ix + 1) / nx
				local z0 = rect.minZ + d * iz / nz
				local z1 = rect.minZ + d * (iz + 1) / nz
				mk({
					name = "Ground",
					size = Vector3.new(x1 - x0, GROUND_THICKNESS, z1 - z0),
					cframe = CFrame.new((x0 + x1) / 2, top - GROUND_THICKNESS / 2, (z0 + z1) / 2),
					color = GROUND_COLOR,
					material = GROUND_GRASS,
					parent = folder,
					collide = true,
					query = true,
					castShadow = false,
				})
			end
		end
	end
	return folder
end

-- Roads, sidewalks, markings (built per RouteGraph edge so T-junctions are split)
-------------------------------------------------------------------------------

type EdgeInfo = {
	edge: any,
	a: Vector3,
	b: Vector3,
	dir: Vector3, -- unit 3D direction a -> b
	flat: Vector3, -- unit flat direction
	length: number,
	width: number,
	kind: string,
	road: any,
	sidewalk: boolean,
	bridge: boolean,
}

-- Incident edge entries at a node: direction away from the node, angle, width, sidewalk flag.
local function incidentEntries(graph, infos, nodeIndex: number)
	local entries = {}
	local node = graph.nodes[nodeIndex]
	for _, edgeIndex in ipairs(graph.adjacency[nodeIndex] or {}) do
		local info = infos[edgeIndex]
		if info then
			local edge = info.edge
			local other = if edge.a == nodeIndex then edge.b else edge.a
			local d = flatUnit(graph.nodes[other].position - node.position, nil)
			if (graph.nodes[other].position - node.position).Magnitude > 1e-3 then
				table.insert(entries, {
					edgeIndex = edgeIndex,
					dx = d.X,
					dz = d.Z,
					angle = math.atan2(d.Z, d.X),
					width = info.width,
					sidewalk = info.sidewalk,
				})
			end
		end
	end
	return entries
end

-- The angular neighbour of `entry` rotating counter-clockwise (ccw = true) or clockwise.
local function angularNeighbour(entries, entry, ccw: boolean)
	local best, bestDelta = nil, math.huge
	for _, other in ipairs(entries) do
		if other ~= entry then
			local delta = if ccw then (other.angle - entry.angle) else (entry.angle - other.angle)
			delta = delta % (2 * math.pi)
			if delta < 1e-6 then
				delta = 2 * math.pi
			end
			if delta < bestDelta then
				best, bestDelta = other, delta
			end
		end
	end
	return best, bestDelta
end

-- Distance along the edge (from the node, positive = into the edge) at which the sidewalk on the
-- side with flat normal (nx, nz) begins. Negative values extend the sidewalk past the node.
local function sidewalkTrim(entries, entry, nx: number, nz: number, edgeLength: number): number
	local ux, uz = entry.dx, entry.dz
	local ccw = (ux * nz - uz * nx) > 0
	local neighbour, phi = angularNeighbour(entries, entry, ccw)
	if not neighbour then
		-- dead end: run to the end of the road square; the cap part closes the end
		return -(entry.width / 2)
	end
	if math.abs(phi - math.pi) < 0.05 then
		return 0 -- straight continuation
	end
	local inner = phi < math.pi
	local fx, fz = neighbour.dx, neighbour.dz
	-- neighbour's normal pointing toward this edge
	local nfx, nfz = -fz, fx
	if ux * nfx + uz * nfz < 0 then
		nfx, nfz = fz, -fx
	end
	if not inner then
		nfx, nfz = -nfx, -nfz
	end
	local priority = entry.edgeIndex < neighbour.edgeIndex
	local offsetF
	if neighbour.sidewalk then
		offsetF = if priority then neighbour.width / 2 + SIDEWALK_WIDTH else neighbour.width / 2
	else
		offsetF = neighbour.width / 2
	end
	local offsetE = entry.width / 2 + SIDEWALK_GAP + SIDEWALK_WIDTH / 2
	local denom = ux * nfx + uz * nfz
	if math.abs(denom) < 0.05 then
		return 0
	end
	local t = (offsetF - offsetE * (nx * nfx + nz * nfz)) / denom
	local limit = entry.width / 2 + neighbour.width / 2 + SIDEWALK_WIDTH * 2
	return math.clamp(t, -limit, edgeLength * 0.5)
end

local function buildRoads(layout, graph, cityFolder)
	local roadsFolder = newFolder("Roads", cityFolder)
	local sidewalkFolder = newFolder("Sidewalks", cityFolder)
	local markingFolder = newFolder("Markings", cityFolder)
	local bridgeFolder = newFolder("Bridges", cityFolder)
	local groundY = layout.groundY or 0

	local roadsById = {}
	for _, road in ipairs(layout.roads or {}) do
		roadsById[road.id] = road
	end
	-- Explicit bridge segments: roadId -> { from, to } point indices
	local bridgeRanges = {}
	for _, bridge in ipairs(layout.bridges or {}) do
		bridgeRanges[bridge.roadId] = bridgeRanges[bridge.roadId] or {}
		table.insert(bridgeRanges[bridge.roadId], { from = bridge.fromIndex or 1, to = bridge.toIndex or 2 })
	end

	local function edgeIsBridge(edge, mid: Vector3): boolean
		if BRIDGE_KINDS[edge.kind] then
			return true
		end
		local ranges = bridgeRanges[edge.roadId]
		if not ranges then
			return false
		end
		local road = roadsById[edge.roadId]
		if not road then
			return false
		end
		-- find the authored segment containing the edge midpoint
		local points = road.points or {}
		local bestIndex, bestDist = 0, math.huge
		for i = 1, #points - 1 do
			local a, b = points[i], points[i + 1]
			local abx, abz = b.x - a.x, b.z - a.z
			local len2 = abx * abx + abz * abz
			local t = 0
			if len2 > 1e-9 then
				t = math.clamp(((mid.X - a.x) * abx + (mid.Z - a.z) * abz) / len2, 0, 1)
			end
			local dx, dz = mid.X - (a.x + abx * t), mid.Z - (a.z + abz * t)
			local d = dx * dx + dz * dz
			if d < bestDist then
				bestIndex, bestDist = i, d
			end
		end
		for _, range in ipairs(ranges) do
			if bestIndex >= range.from and bestIndex < range.to then
				return true
			end
		end
		return false
	end

	-- Edge infos
	local infos = {}
	for _, edge in ipairs(graph.edges) do
		local a = graph.nodes[edge.a].position
		local b = graph.nodes[edge.b].position
		local delta = b - a
		if delta.Magnitude > 0.05 and Vector3.new(delta.X, 0, delta.Z).Magnitude > 0.05 then
			local road = roadsById[edge.roadId]
			local info: EdgeInfo = {
				edge = edge,
				a = a,
				b = b,
				dir = delta.Unit,
				flat = flatUnit(delta),
				length = delta.Magnitude,
				width = edge.width or 10,
				kind = edge.kind,
				road = road,
				sidewalk = roadHasSidewalk(road),
				bridge = edgeIsBridge(edge, (a + b) / 2),
			}
			infos[edge.index] = info
		end
	end

	-- Segment parts
	for _, info in pairs(infos) do
		local style = ROAD_STYLE[info.kind] or ROAD_STYLE.Road
		local mid = (info.a + info.b) / 2
		local cf = CFrame.lookAt(mid, info.b) * CFrame.new(0, -ROAD_THICKNESS / 2, 0)
		mk({
			name = info.edge.roadId .. "_" .. info.edge.index,
			size = Vector3.new(info.width, ROAD_THICKNESS, info.length),
			cframe = cf,
			color = style.color,
			material = style.material,
			parent = roadsFolder,
		})
		local rise = info.b.Y - info.a.Y
		local sloped = math.abs(rise) > SLOPE_EPSILON
		local lowY = math.min(info.a.Y, info.b.Y)
		if info.bridge then
			-- Deck underside and railings along both sides.
			mk({
				name = "Deck",
				size = Vector3.new(info.width + 1, 1.5, info.length),
				cframe = cf * CFrame.new(0, -ROAD_THICKNESS / 2 - 0.75, 0),
				color = Color3.fromRGB(95, 95, 100),
				material = Enum.Material.Concrete,
				parent = bridgeFolder,
			})
			for side = -1, 1, 2 do
				mk({
					name = "Railing",
					size = Vector3.new(0.5, 2.4, info.length),
					cframe = cf * CFrame.new(side * (info.width / 2 - 0.25), ROAD_THICKNESS / 2 + 1.2, 0),
					color = Color3.fromRGB(190, 190, 195),
					material = Enum.Material.Metal,
					parent = bridgeFolder,
					collide = true,
				})
			end
		elseif sloped then
			-- Wedge embankment under the sloped deck, thin edge at the low end.
			local flatLen = Vector3.new(info.b.X - info.a.X, 0, info.b.Z - info.a.Z).Magnitude
			local lowEnd = if info.a.Y < info.b.Y then info.a else info.b
			local midFlat = Vector3.new(mid.X, lowY - ROAD_THICKNESS + math.abs(rise) / 2, mid.Z)
			local toLow = flatUnit(Vector3.new(lowEnd.X - mid.X, 0, lowEnd.Z - mid.Z))
			mk({
				class = "WedgePart",
				name = "Embankment",
				size = Vector3.new(info.width, math.abs(rise), flatLen),
				cframe = CFrame.lookAt(midFlat, midFlat + toLow),
				color = Color3.fromRGB(120, 110, 95),
				material = Enum.Material.Ground,
				parent = roadsFolder,
			})
			local supportH = lowY - ROAD_THICKNESS - groundY
			if supportH > 0.2 then
				mk({
					name = "Fill",
					size = Vector3.new(info.width, supportH, flatLen),
					cframe = CFrame.lookAt(Vector3.new(mid.X, groundY + supportH / 2, mid.Z), Vector3.new(info.b.X, groundY + supportH / 2, info.b.Z)),
					color = Color3.fromRGB(120, 110, 95),
					material = Enum.Material.Ground,
					parent = roadsFolder,
				})
			end
		elseif lowY - ROAD_THICKNESS > groundY + 0.3 then
			-- Elevated flat road: solid fill down to the terrain.
			local supportH = lowY - ROAD_THICKNESS - groundY
			mk({
				name = "Fill",
				size = Vector3.new(info.width + 2 * SIDEWALK_WIDTH, supportH, info.length),
				cframe = CFrame.lookAt(Vector3.new(mid.X, groundY + supportH / 2, mid.Z), Vector3.new(info.b.X, groundY + supportH / 2, info.b.Z)),
				color = Color3.fromRGB(120, 110, 95),
				material = Enum.Material.Ground,
				parent = roadsFolder,
			})
		end

		-- Lane markings
		if MARKING_KINDS[info.kind] and not info.bridge and decorOk() then
			local half = info.width / 2
			local markY = ROAD_THICKNESS / 2 + MARKING_THICKNESS / 2 + 0.01
			local edgeCf = CFrame.lookAt(mid, info.b)
			local inner = info.length - info.width - 2
			if inner > 4 then
				for side = -1, 1, 2 do
					mk({
						name = "EdgeLine",
						size = Vector3.new(0.3, MARKING_THICKNESS, inner),
						cframe = edgeCf * CFrame.new(side * (half - 0.6), markY, 0),
						color = Color3.fromRGB(235, 235, 230),
						material = Enum.Material.SmoothPlastic,
						parent = markingFolder,
						detail = true,
						castShadow = false,
					})
				end
				local start = -inner / 2 + DASH_LENGTH / 2
				local t = start
				while t + DASH_LENGTH / 2 <= inner / 2 and decorOk() do
					mk({
						name = "Dash",
						size = Vector3.new(0.35, MARKING_THICKNESS, DASH_LENGTH),
						cframe = edgeCf * CFrame.new(0, markY, -t),
						color = Color3.fromRGB(240, 200, 60),
						material = Enum.Material.SmoothPlastic,
						parent = markingFolder,
						detail = true,
						castShadow = false,
					})
					t += DASH_SPACING
				end
			end
		end
	end

	-- Node squares (corners/junctions/dead ends) so corners have no gaps.
	for nodeIndex, node in ipairs(graph.nodes) do
		local entries = incidentEntries(graph, infos, nodeIndex)
		local needSquare = true
		if #entries == 0 then
			needSquare = false
		elseif #entries == 2 then
			local e1, e2 = entries[1], entries[2]
			if e1.dx * e2.dx + e1.dz * e2.dz < -0.996 then
				needSquare = false -- straight continuation
			end
		end
		if needSquare then
			local widest = entries[1]
			for _, entry in ipairs(entries) do
				if entry.width > widest.width then
					widest = entry
				end
			end
			local kind = infos[widest.edgeIndex].kind
			local style = ROAD_STYLE[kind] or ROAD_STYLE.Road
			local pos = node.position
			local cf = lookFlat(Vector3.new(pos.X, pos.Y + 0.02 - ROAD_THICKNESS / 2, pos.Z), Vector3.new(widest.dx, 0, widest.dz))
			mk({
				name = "Node_" .. nodeIndex,
				size = Vector3.new(widest.width, ROAD_THICKNESS, widest.width),
				cframe = cf,
				color = style.color,
				material = style.material,
				parent = roadsFolder,
			})
		end
	end

	-- Sidewalks: two parallel strips per edge, trimmed at junctions so they never cross a road.
	local entriesByNode = {}
	local function entriesFor(nodeIndex: number)
		local cached = entriesByNode[nodeIndex]
		if not cached then
			cached = incidentEntries(graph, infos, nodeIndex)
			entriesByNode[nodeIndex] = cached
		end
		return cached
	end
	local function findEntry(entries, edgeIndex: number)
		for _, entry in ipairs(entries) do
			if entry.edgeIndex == edgeIndex then
				return entry
			end
		end
		return nil
	end

	for _, info in pairs(infos) do
		if info.sidewalk then
			local edge = info.edge
			local entriesA = entriesFor(edge.a)
			local entriesB = entriesFor(edge.b)
			local entryA = findEntry(entriesA, edge.index)
			local entryB = findEntry(entriesB, edge.index)
			if entryA and entryB then
				local offset = info.width / 2 + SIDEWALK_GAP + SIDEWALK_WIDTH / 2
				for side = -1, 1, 2 do
					-- world normal for this side (left of travel for side = -1 in Roblox's right-handed frame)
					local normal = Vector3.new(-info.flat.Z, 0, info.flat.X) * side
					local tA = sidewalkTrim(entriesA, entryA, normal.X, normal.Z, info.length)
					local tB = sidewalkTrim(entriesB, entryB, normal.X, normal.Z, info.length)
					local startT = tA
					local endT = info.length - tB
					local len = endT - startT
					if len > 0.5 then
						local startP = info.a + info.dir * startT + normal * offset
						local endP = info.a + info.dir * endT + normal * offset
						local mid = (startP + endP) / 2 + Vector3.new(0, SIDEWALK_HEIGHT / 2, 0)
						mk({
							name = "Sidewalk",
							size = Vector3.new(SIDEWALK_WIDTH, SIDEWALK_HEIGHT, len),
							cframe = CFrame.lookAt(mid, mid + (endP - startP).Unit),
							color = CONCRETE_COLOR,
							material = Enum.Material.Concrete,
							parent = sidewalkFolder,
						})
					end
				end
				-- Dead-end caps
				for _, pair in ipairs({ { entriesA, info.a, -info.flat }, { entriesB, info.b, info.flat } }) do
					local entries, pos, outward = pair[1], pair[2], pair[3]
					if #entries == 1 then
						local capCentre = pos + outward * (info.width / 2 + SIDEWALK_WIDTH / 2) + Vector3.new(0, SIDEWALK_HEIGHT / 2, 0)
						mk({
							name = "SidewalkCap",
							size = Vector3.new(info.width + SIDEWALK_WIDTH * 2, SIDEWALK_HEIGHT, SIDEWALK_WIDTH),
							cframe = CFrame.lookAt(capCentre, capCentre + outward),
							color = CONCRETE_COLOR,
							material = Enum.Material.Concrete,
							parent = sidewalkFolder,
						})
					end
				end
			end
		end
	end
end

-------------------------------------------------------------------------------
-- Buildings
-------------------------------------------------------------------------------

-- Builds one building from a spec {x, z, w, d, h, rot?, style, name?, color?, baseY?}.
-- opts.facing (Vector3) forces the front face; otherwise the face nearest a road is the front.
-- opts.noDoor skips the generic door (businesses/destinations place their own Door part).
-- Returns the body part and a table describing the front face { normal: Vector3, centre: Vector3 }.
local function buildBuilding(layout, spec, index: number, parent: Instance, opts)
	opts = opts or {}
	local style = BUILDING_STYLES[spec.style] or BUILDING_STYLES.Shop
	local groundY = layout.groundY or 0
	local baseY = spec.baseY
	if baseY == nil then
		baseY = elevationAt(layout, spec.x, spec.z)
		if baseY == nil then
			baseY = groundY
		end
	end
	local w, h, d = spec.w, spec.h, spec.d
	local rot = math.rad(spec.rot or 0)
	local centre = CFrame.new(spec.x, baseY + h / 2, spec.z) * CFrame.Angles(0, rot, 0)

	local rng = Random.new(index * 7919 + math.floor(spec.x) + math.floor(spec.z) * 31)
	local baseColor = if spec.color then rgb(spec.color) else tint(rgb(style.color), (rng:NextNumber() - 0.5) * 0.16)

	local body = mk({
		name = spec.name or spec.style or "Building",
		size = Vector3.new(w, h, d),
		cframe = centre,
		color = baseColor,
		material = materialFrom(style.material, Enum.Material.Concrete),
		parent = parent,
		collide = true,
	})
	body:SetAttribute("Style", spec.style or "Shop")

	-- Front face: forced facing or toward the nearest road.
	local facing: Vector3
	if opts.facing then
		facing = flatUnit(opts.facing)
	else
		local _, _, road, segIndex = roadSample(layout, spec.x, spec.z)
		if road then
			local a, b = road.points[segIndex], road.points[segIndex + 1]
			local abx, abz = b.x - a.x, b.z - a.z
			local len2 = abx * abx + abz * abz
			local t = if len2 > 1e-9 then math.clamp(((spec.x - a.x) * abx + (spec.z - a.z) * abz) / len2, 0, 1) else 0
			facing = flatUnit(Vector3.new(a.x + abx * t - spec.x, 0, a.z + abz * t - spec.z), centre.LookVector)
		else
			facing = flatUnit(centre.LookVector)
		end
	end
	local localFacing = centre:VectorToObjectSpace(facing)
	local candidates = {
		{ normal = Vector3.new(0, 0, -1), extent = d / 2, width = w },
		{ normal = Vector3.new(0, 0, 1), extent = d / 2, width = w },
		{ normal = Vector3.new(1, 0, 0), extent = w / 2, width = d },
		{ normal = Vector3.new(-1, 0, 0), extent = w / 2, width = d },
	}
	local front = candidates[1]
	local bestDot = -math.huge
	for _, candidate in ipairs(candidates) do
		local dot = candidate.normal:Dot(localFacing)
		if dot > bestDot then
			bestDot, front = dot, candidate
		end
	end
	-- Frame at the bottom centre of the front face, -Z pointing outward.
	local frontCentre = centre * CFrame.new(front.normal * front.extent) * CFrame.new(0, -h / 2, 0)
	local worldNormal = centre:VectorToWorldSpace(front.normal)
	local frontFrame = CFrame.lookAt(frontCentre.Position, frontCentre.Position + worldNormal)

	if style.windows and decorOk() then
		local floorY = 5
		while floorY + 2 < h and decorOk() do
			mk({
				name = "Windows",
				size = Vector3.new(w + 0.2, 1.6, d + 0.2),
				cframe = centre * CFrame.new(0, -h / 2 + floorY, 0),
				color = WINDOW_COLOR,
				material = Enum.Material.Glass,
				transparency = 0.15,
				reflectance = 0.1,
				parent = parent,
				detail = true,
			})
			floorY += 10
		end
	end

	if style.roof and decorOk() then
		-- Pitched roof from two wedges, ridge along the longer axis.
		local roofH = math.clamp(math.min(w, d) * 0.35, 2, 8)
		local ridgeAlongX = w >= d
		local span = if ridgeAlongX then d else w
		local run = if ridgeAlongX then w else d
		for side = -1, 1, 2 do
			local localCf
			if ridgeAlongX then
				localCf = CFrame.new(0, h / 2 + roofH / 2, side * (span / 4 + 0.25)) * CFrame.Angles(0, if side > 0 then math.pi else 0, 0)
			else
				localCf = CFrame.new(side * (span / 4 + 0.25), h / 2 + roofH / 2, 0) * CFrame.Angles(0, if side > 0 then -math.pi / 2 else math.pi / 2, 0)
			end
			mk({
				class = "WedgePart",
				name = "Roof",
				size = Vector3.new(run + 1, roofH, span / 2 + 0.5),
				cframe = centre * localCf,
				color = ROOF_COLOR,
				material = Enum.Material.Slate,
				parent = parent,
				detail = true,
			})
		end
	elseif decorOk() then
		mk({
			name = "RoofLip",
			size = Vector3.new(w + 1, 0.6, d + 1),
			cframe = centre * CFrame.new(0, h / 2 - 0.2, 0),
			color = tint(baseColor, -0.25),
			material = Enum.Material.Concrete,
			parent = parent,
			detail = true,
		})
	end

	if style.awning and decorOk() then
		local awningW = math.min(front.width * 0.6, 10)
		local awningY = math.min(7.5, h - 0.5)
		mk({
			name = "Awning",
			size = Vector3.new(awningW, 0.3, 3),
			cframe = frontFrame * CFrame.new(0, awningY, -1.5),
			color = rgb(style.accent or { 230, 80, 60 }),
			material = Enum.Material.Fabric,
			parent = parent,
			detail = true,
		})
	end

	if style.roller and decorOk() then
		mk({
			name = "RollerDoor",
			size = Vector3.new(math.min(front.width * 0.5, 10), math.min(h - 1, 8), 0.3),
			cframe = frontFrame * CFrame.new(0, math.min(h - 1, 8) / 2, -0.2),
			color = Color3.fromRGB(150, 155, 160),
			material = Enum.Material.DiamondPlate,
			parent = parent,
			detail = true,
		})
	elseif style.door and not opts.noDoor and decorOk() then
		mk({
			name = "Door",
			size = Vector3.new(3.2, 6, 0.3),
			cframe = frontFrame * CFrame.new(0, 3, -0.2),
			color = DOOR_COLOR,
			material = Enum.Material.Wood,
			parent = parent,
			detail = true,
		})
	end

	return body, { normal = worldNormal, frame = frontFrame, width = front.width }
end

local function buildBuildings(layout, cityFolder)
	local folder = newFolder("Buildings", cityFolder)
	local bodies = {}
	for index, spec in ipairs(layout.buildings or {}) do
		local body = buildBuilding(layout, spec, index, folder, nil)
		bodies[index] = body
	end
	return bodies
end

-------------------------------------------------------------------------------
-- Businesses and destinations
-------------------------------------------------------------------------------

local function buildDoor(parent: Instance, doorPos: Vector3, facing: Vector3, tag: string?): BasePart
	local frame = lookFlat(doorPos + Vector3.new(0, 3.5, 0), facing) * CFrame.new(0, 0, -0.35)
	local door = mk({
		name = "Door",
		size = Vector3.new(4, 7, 0.6),
		cframe = frame,
		color = DOOR_COLOR,
		material = Enum.Material.Wood,
		parent = parent,
		collide = false,
		query = true,
		touch = false,
	})
	if tag then
		CollectionService:AddTag(door, tag)
	end
	-- Door handle
	mk({
		name = "Handle",
		size = Vector3.new(0.25, 0.25, 0.5),
		cframe = frame * CFrame.new(1.4, -0.3, -0.4),
		color = Color3.fromRGB(220, 190, 90),
		material = Enum.Material.Metal,
		parent = parent,
		detail = true,
	})
	return door
end

local function buildBusinesses(layout, positions, pickupFolder, bodies)
	local result = {}
	for index, business in ipairs(layout.businesses or {}) do
		local def = BusinessDefinitions.get(business.id)
		local name = if def then def.name else business.id
		local signText = if def then def.signText else string.upper(business.id)
		local accent = if def then rgb(def.accent) else Color3.fromRGB(230, 80, 60)
		local staffName = if def then def.staffName else "Staff"
		local pos = positions.businesses[business.id]
		local facing = pos.facing

		local model = newModel(business.id, pickupFolder)
		model:SetAttribute("BusinessId", business.id)
		model:SetAttribute("Name", name)

		-- Storefront: own building spec or a reference to a layout building.
		local storefront = newModel("Storefront", model)
		if business.building then
			buildBuilding(layout, business.building, 1000 + index, storefront, { facing = facing, noDoor = true })
		elseif business.buildingIndex and bodies[business.buildingIndex] then
			storefront:SetAttribute("BuildingIndex", business.buildingIndex)
		end

		-- Sign above the door, readable from the street.
		local signPos = pos.door + Vector3.new(0, 9, 0)
		local sign = mk({
			name = "Sign",
			size = Vector3.new(12, 2.4, 0.5),
			cframe = lookFlat(signPos, facing) * CFrame.new(0, 0, -0.6),
			color = Color3.fromRGB(35, 35, 40),
			material = Enum.Material.SmoothPlastic,
			parent = storefront,
			detail = true,
		})
		surfaceText(sign, Enum.NormalId.Front, signText, accent)

		local door = buildDoor(storefront, pos.door, facing, nil)

		-- Counter just outside the door with the staff member behind it.
		local counterPos = pos.door + facing * 2.2 + Vector3.new(0, 1.5, 0)
		mk({
			name = "Counter",
			size = Vector3.new(6, 3, 1.4),
			cframe = lookFlat(counterPos, facing),
			color = Color3.fromRGB(120, 85, 60),
			material = Enum.Material.Wood,
			parent = model,
			collide = true,
		})

		-- Pickup pad
		local pad = mk({
			name = "PickupPad",
			size = Vector3.new(10, 0.2, 10),
			cframe = lookFlat(pos.pickup + Vector3.new(0, 0.1, 0), facing),
			color = accent,
			material = Enum.Material.SmoothPlastic,
			transparency = 0.35,
			parent = model,
			collide = false,
			query = true,
			touch = true,
		})
		CollectionService:AddTag(pad, "PickupZone")
		pad:SetAttribute("BusinessId", business.id)
		billboard(pad, name .. "\nPICKUP", 5, Color3.fromRGB(255, 255, 255))

		-- Staff NPC behind the counter (between door and counter), facing the street.
		local staff = NPCBuilder.build("Staff", index * 17, { name = staffName, shirt = if def then def.accent else nil })
		staff.Name = "Staff"
		NPCBuilder.place(staff, pos.door + facing * 1.0, facing, true)
		NPCBuilder.freeze(staff)
		staff.Parent = model
		for _, part in ipairs(staff:GetDescendants()) do
			if part:IsA("BasePart") then
				countPart()
			end
		end

		result[business.id] = {
			model = model,
			pickupPosition = pos.pickup,
			arrivalPosition = pos.arrival,
			doorPart = door,
		}
	end
	return result
end

local function buildDestinations(layout, positions, destinationFolder)
	local result = {}
	for index, destination in ipairs(layout.destinations or {}) do
		local pos = positions.destinations[destination.id]
		local facing = pos.facing
		local address = destination.address or destination.id

		local model = newModel(destination.id, destinationFolder)
		model:SetAttribute("DestinationId", destination.id)
		model:SetAttribute("Address", address)
		model:SetAttribute("Kind", destination.kind or "House")

		if destination.building then
			local buildingModel = newModel("Building", model)
			buildBuilding(layout, destination.building, 2000 + index, buildingModel, { facing = facing, noDoor = true })
		end

		local door = buildDoor(model, pos.door, facing, "DoorPart")
		door:SetAttribute("DestinationId", destination.id)

		-- Doorbell beside the door
		mk({
			name = "Doorbell",
			size = Vector3.new(0.5, 0.7, 0.25),
			cframe = lookFlat(pos.door + Vector3.new(0, 4.2, 0), facing) * CFrame.new(2.6, 0, -0.2),
			color = Color3.fromRGB(240, 220, 120),
			material = Enum.Material.Neon,
			parent = model,
			detail = true,
		})

		-- Address sign above the door
		local sign = mk({
			name = "AddressSign",
			size = Vector3.new(5, 1.2, 0.25),
			cframe = lookFlat(pos.door + Vector3.new(0, 7.9, 0), facing) * CFrame.new(0, 0, -0.4),
			color = Color3.fromRGB(245, 245, 240),
			material = Enum.Material.SmoothPlastic,
			parent = model,
			detail = true,
		})
		surfaceText(sign, Enum.NormalId.Front, address, Color3.fromRGB(30, 30, 35))

		-- Arrival pad
		local pad = mk({
			name = "ArrivalPad",
			size = Vector3.new(8, 0.2, 8),
			cframe = lookFlat(pos.arrival + Vector3.new(0, 0.1, 0), facing),
			color = Color3.fromRGB(70, 170, 230),
			material = Enum.Material.SmoothPlastic,
			transparency = 0.4,
			parent = model,
			collide = false,
			query = true,
			touch = true,
		})
		CollectionService:AddTag(pad, "DeliveryZone")
		pad:SetAttribute("DestinationId", destination.id)
		billboard(pad, address, 4, Color3.fromRGB(255, 255, 255), 100)

		result[destination.id] = {
			model = model,
			doorPosition = pos.door,
			arrivalPosition = pos.arrival,
			doorPart = door,
			facing = facing,
		}
	end
	return result
end

-------------------------------------------------------------------------------
-- Depot plots
-------------------------------------------------------------------------------

local function buildDepotPlots(layout, positions, depotFolder)
	local result = {}
	for _, plot in ipairs(layout.depotPlots or {}) do
		local pos = positions.depotPlots[plot.id]
		local origin = pos.origin
		local w, d = plot.w or 40, plot.d or 30
		local groundY = pos.groundY

		local model = newModel(plot.id, depotFolder)
		model:SetAttribute("PlotId", plot.id)
		model:SetAttribute("OwnerUserId", 0)
		model:SetAttribute("OwnerName", "")
		model:SetAttribute("PlotWidth", w)
		model:SetAttribute("PlotDepth", d)
		CollectionService:AddTag(model, "DepotPlot")

		-- Ground slab (top at origin y)
		mk({
			name = "Ground",
			size = Vector3.new(w, 0.4, d),
			cframe = origin * CFrame.new(0, -0.2, 0),
			color = Color3.fromRGB(165, 165, 160),
			material = Enum.Material.Concrete,
			parent = model,
			collide = true,
		})

		-- Low fence on the back and both sides (front stays open to the street)
		local fenceColor = Color3.fromRGB(120, 125, 130)
		mk({
			name = "FenceBack",
			size = Vector3.new(w, 2, 0.3),
			cframe = origin * CFrame.new(0, 1, d / 2 - 0.15),
			color = fenceColor,
			material = Enum.Material.Metal,
			parent = model,
			collide = true,
		})
		for side = -1, 1, 2 do
			mk({
				name = "FenceSide",
				size = Vector3.new(0.3, 2, d),
				cframe = origin * CFrame.new(side * (w / 2 - 0.15), 1, 0),
				color = fenceColor,
				material = Enum.Material.Metal,
				parent = model,
				collide = true,
			})
		end

		-- Sign on a post near the front edge
		local signFrame = origin * CFrame.new(-w / 2 + 6, 0, -d / 2 + 3)
		mk({
			name = "SignPost",
			size = Vector3.new(0.4, 5, 0.4),
			cframe = signFrame * CFrame.new(0, 2.5, 0),
			color = Color3.fromRGB(80, 80, 85),
			material = Enum.Material.Metal,
			parent = model,
			detail = true,
		})
		local sign = mk({
			name = "Sign",
			size = Vector3.new(8, 3, 0.4),
			cframe = signFrame * CFrame.new(0, 6.5, 0),
			color = Color3.fromRGB(240, 240, 240),
			material = Enum.Material.SmoothPlastic,
			parent = model,
			collide = false,
			query = true,
			touch = false,
		})
		sign:SetAttribute("PlotId", plot.id)
		surfaceText(sign, Enum.NormalId.Front, "FOR SALE - Depot", Color3.fromRGB(30, 30, 30))
		surfaceText(sign, Enum.NormalId.Back, "FOR SALE - Depot", Color3.fromRGB(30, 30, 30), "SignGuiBack")

		-- Parking spot markings
		local parkingFolder = newFolder("Parking", model)
		for i, spot in ipairs(pos.parking) do
			for side = -1, 1, 2 do
				mk({
					name = "SpotLine" .. i,
					size = Vector3.new(0.3, 0.06, 14),
					cframe = spot * CFrame.new(side * 3.6, 0.04, 0),
					color = Color3.fromRGB(240, 240, 235),
					material = Enum.Material.SmoothPlastic,
					parent = parkingFolder,
					detail = true,
					castShadow = false,
				})
			end
		end

		newFolder("Built", model)

		result[plot.id] = {
			model = model,
			origin = origin,
			parking = pos.parking,
			signPart = sign,
			plotId = plot.id,
			groundY = groundY,
		}
	end
	return result
end

-------------------------------------------------------------------------------
-- Props
-------------------------------------------------------------------------------

local function buildTree(parent: Instance, base: Vector3, rng: Random)
	local height = 7 + rng:NextNumber() * 3
	mk({
		name = "Trunk",
		shape = Enum.PartType.Cylinder,
		size = Vector3.new(height, 1.2, 1.2),
		cframe = uprightCylinderCFrame(base + Vector3.new(0, height / 2, 0)),
		color = TRUNK_COLOR,
		material = Enum.Material.Wood,
		parent = parent,
		detail = true,
		castShadow = true,
	})
	local leafColor = LEAF_COLORS[rng:NextInteger(1, #LEAF_COLORS)]
	local crown = 6 + rng:NextNumber() * 3
	mk({
		name = "Leaves",
		shape = Enum.PartType.Ball,
		size = Vector3.new(crown, crown, crown),
		cframe = CFrame.new(base + Vector3.new(0, height + crown * 0.3, 0)),
		color = leafColor,
		material = Enum.Material.Grass,
		parent = parent,
		detail = true,
		castShadow = true,
	})
	if rng:NextNumber() < 0.6 and decorOk() then
		local small = crown * 0.7
		mk({
			name = "Leaves2",
			shape = Enum.PartType.Ball,
			size = Vector3.new(small, small, small),
			cframe = CFrame.new(base + Vector3.new((rng:NextNumber() - 0.5) * 3, height + crown * 0.55, (rng:NextNumber() - 0.5) * 3)),
			color = tint(leafColor, 0.1),
			material = Enum.Material.Grass,
			parent = parent,
			detail = true,
			castShadow = true,
		})
	end
end

local function buildBench(parent: Instance, frame: CFrame)
	mk({ name = "Seat", size = Vector3.new(5, 0.4, 1.6), cframe = frame * CFrame.new(0, 1.6, 0), color = Color3.fromRGB(150, 105, 65), material = Enum.Material.Wood, parent = parent, detail = true })
	mk({ name = "Back", size = Vector3.new(5, 1.4, 0.3), cframe = frame * CFrame.new(0, 2.5, 0.75) * CFrame.Angles(math.rad(-8), 0, 0), color = Color3.fromRGB(150, 105, 65), material = Enum.Material.Wood, parent = parent, detail = true })
	mk({ name = "Legs", size = Vector3.new(4.4, 1.4, 1.2), cframe = frame * CFrame.new(0, 0.7, 0), color = Color3.fromRGB(60, 60, 65), material = Enum.Material.Metal, parent = parent, detail = true })
end

local function buildLamp(parent: Instance, frame: CFrame)
	mk({ name = "Pole", size = Vector3.new(0.4, 12, 0.4), cframe = frame * CFrame.new(0, 6, 0), color = Color3.fromRGB(50, 50, 55), material = Enum.Material.Metal, parent = parent, detail = true })
	local head = mk({ name = "Head", size = Vector3.new(1.4, 0.6, 1.4), cframe = frame * CFrame.new(0, 12.2, 0), color = Color3.fromRGB(255, 240, 200), material = Enum.Material.Neon, parent = parent, detail = true })
	local light = Instance.new("PointLight")
	light.Name = "Light"
	light.Brightness = 1.5
	light.Range = 26
	light.Color = Color3.fromRGB(255, 235, 190)
	light.Shadows = false
	light.Parent = head
end

local function buildProp(layout, folder: Instance, prop, index: number)
	local y = surfaceYAt(layout, prop.x, prop.z)
	local base = Vector3.new(prop.x, y, prop.z)
	local frame = CFrame.new(base) * CFrame.Angles(0, math.rad(prop.rot or 0), 0)
	local rng = Random.new(index * 131 + 7)
	local kind = prop.type
	if kind == "Tree" then
		buildTree(folder, base, rng)
	elseif kind == "Lamp" then
		buildLamp(folder, frame)
	elseif kind == "Bench" then
		buildBench(folder, frame)
	elseif kind == "Hydrant" then
		mk({ name = "Hydrant", size = Vector3.new(0.8, 2, 0.8), cframe = frame * CFrame.new(0, 1, 0), color = Color3.fromRGB(210, 50, 40), material = Enum.Material.Metal, parent = folder, detail = true })
		mk({ name = "HydrantCap", shape = Enum.PartType.Ball, size = Vector3.new(1, 1, 1), cframe = frame * CFrame.new(0, 2.2, 0), color = Color3.fromRGB(210, 50, 40), material = Enum.Material.Metal, parent = folder, detail = true })
	elseif kind == "Planter" then
		mk({ name = "Planter", size = Vector3.new(4, 1.6, 2), cframe = frame * CFrame.new(0, 0.8, 0), color = Color3.fromRGB(150, 150, 145), material = Enum.Material.Concrete, parent = folder, collide = true })
		mk({ name = "PlanterGreen", size = Vector3.new(3.6, 1, 1.6), cframe = frame * CFrame.new(0, 1.9, 0), color = Color3.fromRGB(80, 150, 70), material = Enum.Material.Grass, parent = folder, detail = true })
	elseif kind == "Crate" then
		mk({ name = "Crate", size = Vector3.new(3, 3, 3), cframe = frame * CFrame.new(0, 1.5, 0), color = Color3.fromRGB(170, 130, 80), material = Enum.Material.WoodPlanks, parent = folder, detail = true })
	elseif kind == "Container" then
		mk({ name = "Container", size = Vector3.new(8, 8.5, 20), cframe = frame * CFrame.new(0, 4.25, 0), color = CONTAINER_COLORS[rng:NextInteger(1, #CONTAINER_COLORS)], material = Enum.Material.Metal, parent = folder, collide = true })
	elseif kind == "Dumpster" then
		mk({ name = "Dumpster", size = Vector3.new(6, 4, 3.5), cframe = frame * CFrame.new(0, 2, 0), color = Color3.fromRGB(50, 110, 70), material = Enum.Material.Metal, parent = folder, collide = true })
		mk({ name = "DumpsterLid", size = Vector3.new(6.2, 0.4, 3.7), cframe = frame * CFrame.new(0, 4.2, 0), color = Color3.fromRGB(40, 90, 60), material = Enum.Material.Metal, parent = folder, detail = true })
	elseif kind == "Sign" then
		mk({ name = "SignPost", size = Vector3.new(0.3, 8, 0.3), cframe = frame * CFrame.new(0, 4, 0), color = Color3.fromRGB(90, 90, 95), material = Enum.Material.Metal, parent = folder, detail = true })
		mk({ name = "SignPlate", size = Vector3.new(3, 1.5, 0.2), cframe = frame * CFrame.new(0, 7.4, 0), color = Color3.fromRGB(40, 120, 70), material = Enum.Material.SmoothPlastic, parent = folder, detail = true })
	elseif kind == "Cone" then
		mk({ name = "ConeBase", size = Vector3.new(1.6, 0.2, 1.6), cframe = frame * CFrame.new(0, 0.1, 0), color = Color3.fromRGB(255, 120, 30), material = Enum.Material.SmoothPlastic, parent = folder, detail = true })
		mk({ name = "Cone", shape = Enum.PartType.Cylinder, size = Vector3.new(2.2, 0.8, 0.8), cframe = uprightCylinderCFrame(base + Vector3.new(0, 1.3, 0)), color = Color3.fromRGB(255, 120, 30), material = Enum.Material.SmoothPlastic, parent = folder, detail = true })
	else
		warn("[CityBuilder] Unknown prop type " .. tostring(kind))
	end
end

local function buildProps(layout, cityFolder)
	local folder = newFolder("Props", cityFolder)
	for index, prop in ipairs(layout.props or {}) do
		if prop.type == "Tree" or prop.type == "Lamp" or prop.type == "Planter" or prop.type == "Container" or prop.type == "Dumpster" or decorOk() then
			buildProp(layout, folder, prop, index)
		end
	end
end

-------------------------------------------------------------------------------
-- Parked vehicles (cosmetic obstacles)
-------------------------------------------------------------------------------

local function buildParkedVehicle(layout, folder: Instance, spec, index: number)
	local y = surfaceYAt(layout, spec.x, spec.z)
	local frame = CFrame.new(spec.x, y, spec.z) * CFrame.Angles(0, math.rad(spec.rot or 0), 0)
	local color = if spec.color then rgb(spec.color) else Color3.fromRGB(200, 200, 205)
	local model = newModel((spec.kind or "Car") .. index, folder)
	local wheelColor = Color3.fromRGB(30, 30, 32)
	local glass = Color3.fromRGB(150, 200, 230)
	if spec.kind == "Truck" then
		local wheelR = 1.4
		local function wheel(x: number, z: number)
			mk({ name = "Wheel", shape = Enum.PartType.Cylinder, size = Vector3.new(1, wheelR * 2, wheelR * 2), cframe = frame * CFrame.new(x, wheelR, z), color = wheelColor, material = Enum.Material.Rubber, parent = model, collide = true })
		end
		mk({ name = "Cab", size = Vector3.new(6, 3.6, 5), cframe = frame * CFrame.new(0, wheelR + 1.8, -6), color = color, material = Enum.Material.SmoothPlastic, parent = model, collide = true })
		mk({ name = "Windows", size = Vector3.new(6.1, 1.3, 5.1), cframe = frame * CFrame.new(0, wheelR + 2.6, -6), color = glass, material = Enum.Material.Glass, transparency = 0.35, parent = model, detail = true })
		mk({ name = "Box", size = Vector3.new(6.2, 6, 11), cframe = frame * CFrame.new(0, wheelR + 3.3, 2.5), color = tint(color, 0.3), material = Enum.Material.SmoothPlastic, parent = model, collide = true })
		for side = -1, 1, 2 do
			wheel(side * 3, -6)
			wheel(side * 3, 1)
			wheel(side * 3, 4.5)
		end
	else
		local wheelR = 1.1
		mk({ name = "Body", size = Vector3.new(4.5, 1.6, 9), cframe = frame * CFrame.new(0, wheelR + 0.7, 0), color = color, material = Enum.Material.SmoothPlastic, parent = model, collide = true })
		mk({ name = "Cabin", size = Vector3.new(4.2, 1.4, 4.8), cframe = frame * CFrame.new(0, wheelR + 2.2, 0.3), color = color, material = Enum.Material.SmoothPlastic, parent = model, collide = true })
		mk({ name = "Windows", size = Vector3.new(4.3, 0.9, 4.9), cframe = frame * CFrame.new(0, wheelR + 2.3, 0.3), color = glass, material = Enum.Material.Glass, transparency = 0.35, parent = model, detail = true })
		for side = -1, 1, 2 do
			for _, z in ipairs({ -3, 3 }) do
				mk({ name = "Wheel", shape = Enum.PartType.Cylinder, size = Vector3.new(0.8, wheelR * 2, wheelR * 2), cframe = frame * CFrame.new(side * 2.2, wheelR, z), color = wheelColor, material = Enum.Material.Rubber, parent = model, collide = true })
			end
		end
	end
	for _, part in ipairs(model:GetChildren()) do
		if part:IsA("BasePart") then
			part.CollisionGroup = "Default"
		end
	end
end

local function buildParkedVehicles(layout, cityFolder)
	local folder = newFolder("ParkedVehicles", cityFolder)
	for index, spec in ipairs(layout.parkedVehicles or {}) do
		buildParkedVehicle(layout, folder, spec, index)
	end
end

-------------------------------------------------------------------------------
-- Landmarks and the delivery hub
-------------------------------------------------------------------------------

local function buildPlaza(layout, folder: Instance, plaza, spawnPos: Vector3?)
	local y = elevationAt(layout, plaza.x, plaza.z)
	local r = plaza.r or 40
	local centre = Vector3.new(plaza.x, y, plaza.z)
	local model = newModel("Plaza", folder)
	mk({
		name = "Paving",
		shape = Enum.PartType.Cylinder,
		size = Vector3.new(0.3, r * 2, r * 2),
		cframe = uprightCylinderCFrame(centre + Vector3.new(0, 0.15, 0)),
		color = Color3.fromRGB(205, 195, 180),
		material = Enum.Material.Cobblestone,
		parent = model,
		collide = true,
	})
	-- Fountain at the centre (pushed aside if the spawn sits on the centre)
	local fountainPos = centre
	if spawnPos and (Vector3.new(spawnPos.X, 0, spawnPos.Z) - Vector3.new(centre.X, 0, centre.Z)).Magnitude < 12 then
		local away = flatUnit(centre - spawnPos, Vector3.new(1, 0, 0))
		fountainPos = centre + away * (r * 0.45)
	end
	local top = fountainPos.Y + 0.3
	mk({ name = "FountainBasin", shape = Enum.PartType.Cylinder, size = Vector3.new(1.4, 12, 12), cframe = uprightCylinderCFrame(Vector3.new(fountainPos.X, top + 0.7, fountainPos.Z)), color = Color3.fromRGB(175, 170, 165), material = Enum.Material.Concrete, parent = model, collide = true })
	mk({ name = "FountainWater", shape = Enum.PartType.Cylinder, size = Vector3.new(0.3, 11, 11), cframe = uprightCylinderCFrame(Vector3.new(fountainPos.X, top + 1.35, fountainPos.Z)), color = Color3.fromRGB(90, 170, 220), material = Enum.Material.Glass, transparency = 0.4, reflectance = 0.2, parent = model, detail = true })
	mk({ name = "FountainPedestal", shape = Enum.PartType.Cylinder, size = Vector3.new(3.5, 2, 2), cframe = uprightCylinderCFrame(Vector3.new(fountainPos.X, top + 1.4 + 1.75, fountainPos.Z)), color = Color3.fromRGB(175, 170, 165), material = Enum.Material.Concrete, parent = model, detail = true })
	mk({ name = "FountainBowl", shape = Enum.PartType.Cylinder, size = Vector3.new(0.7, 5, 5), cframe = uprightCylinderCFrame(Vector3.new(fountainPos.X, top + 1.4 + 3.5 + 0.35, fountainPos.Z)), color = Color3.fromRGB(175, 170, 165), material = Enum.Material.Concrete, parent = model, detail = true })
	-- Planters around the ring
	local ringR = r * 0.72
	for i = 0, 5 do
		if decorOk() then
			local angle = i * math.pi / 3 + math.pi / 6
			local p = centre + Vector3.new(math.cos(angle) * ringR, 0.3, math.sin(angle) * ringR)
			local frame = CFrame.new(p) * CFrame.Angles(0, -angle, 0)
			mk({ name = "Planter", size = Vector3.new(5, 1.6, 2.5), cframe = frame * CFrame.new(0, 0.8, 0), color = Color3.fromRGB(150, 150, 145), material = Enum.Material.Concrete, parent = model, collide = true })
			mk({ name = "PlanterGreen", size = Vector3.new(4.6, 1, 2.1), cframe = frame * CFrame.new(0, 1.9, 0), color = Color3.fromRGB(200, 90, 110), material = Enum.Material.Grass, parent = model, detail = true })
		end
	end
end

local function buildBeaconTower(layout, folder: Instance, tower)
	local y = elevationAt(layout, tower.x, tower.z)
	local base = Vector3.new(tower.x, y, tower.z)
	local model = newModel("BeaconTower", folder)
	local stone = Color3.fromRGB(150, 150, 158)
	mk({ name = "Base", size = Vector3.new(20, 8, 20), cframe = CFrame.new(base + Vector3.new(0, 4, 0)), color = stone, material = Enum.Material.Concrete, parent = model, collide = true })
	mk({ name = "Shaft", size = Vector3.new(12, 92, 12), cframe = CFrame.new(base + Vector3.new(0, 8 + 46, 0)), color = tint(stone, 0.1), material = Enum.Material.Concrete, parent = model, collide = true })
	mk({ name = "Cap", size = Vector3.new(16, 2, 16), cframe = CFrame.new(base + Vector3.new(0, 101, 0)), color = stone, material = Enum.Material.Metal, parent = model, detail = true })
	mk({ name = "Spire", size = Vector3.new(4, 14, 4), cframe = CFrame.new(base + Vector3.new(0, 102 + 7, 0)), color = Color3.fromRGB(90, 90, 100), material = Enum.Material.Metal, parent = model, detail = true })
	local beacon = mk({ name = "Beacon", shape = Enum.PartType.Ball, size = Vector3.new(5, 5, 5), cframe = CFrame.new(base + Vector3.new(0, 116 + 2.5, 0)), color = Color3.fromRGB(255, 80, 60), material = Enum.Material.Neon, parent = model, detail = true })
	local light = Instance.new("PointLight")
	light.Name = "BeaconLight"
	light.Brightness = 3
	light.Range = 60
	light.Color = Color3.fromRGB(255, 90, 70)
	light.Parent = beacon
	-- Window stripes on the shaft
	for floorY = 20, 90, 20 do
		if decorOk() then
			mk({ name = "Windows", size = Vector3.new(12.2, 2, 12.2), cframe = CFrame.new(base + Vector3.new(0, floorY, 0)), color = WINDOW_COLOR, material = Enum.Material.Glass, transparency = 0.15, parent = model, detail = true })
		end
	end
end

local function buildWaterTower(layout, folder: Instance, spec)
	local y = elevationAt(layout, spec.x, spec.z)
	local base = Vector3.new(spec.x, y, spec.z)
	local model = newModel("WaterTower", folder)
	local legColor = Color3.fromRGB(90, 90, 95)
	for _, offset in ipairs({ { -4, -4 }, { 4, -4 }, { -4, 4 }, { 4, 4 } }) do
		mk({ name = "Leg", size = Vector3.new(1.2, 24, 1.2), cframe = CFrame.new(base + Vector3.new(offset[1], 12, offset[2])), color = legColor, material = Enum.Material.Metal, parent = model, collide = true })
	end
	mk({ name = "Ring", shape = Enum.PartType.Cylinder, size = Vector3.new(0.6, 15, 15), cframe = uprightCylinderCFrame(base + Vector3.new(0, 24.3, 0)), color = legColor, material = Enum.Material.Metal, parent = model, detail = true })
	mk({ name = "Tank", shape = Enum.PartType.Cylinder, size = Vector3.new(12, 14, 14), cframe = uprightCylinderCFrame(base + Vector3.new(0, 30.5, 0)), color = Color3.fromRGB(210, 205, 195), material = Enum.Material.Metal, parent = model, collide = true })
	mk({ name = "Roof", shape = Enum.PartType.Cylinder, size = Vector3.new(3, 8, 8), cframe = uprightCylinderCFrame(base + Vector3.new(0, 38, 0)), color = Color3.fromRGB(150, 60, 50), material = Enum.Material.Metal, parent = model, detail = true })
	mk({ name = "Ladder", size = Vector3.new(1.2, 24, 0.3), cframe = CFrame.new(base + Vector3.new(0, 12, -5)), color = legColor, material = Enum.Material.Metal, parent = model, detail = true })
end

local function buildPark(layout, folder: Instance, park)
	local model = newModel("MaplePark", folder)
	local w, d = park.w or 80, park.d or 80
	local rng = Random.new(4242)
	-- Trees in a loose 3x2 grid
	local cols, rows = 3, 2
	for i = 0, cols - 1 do
		for j = 0, rows - 1 do
			if decorOk() then
				local x = park.x - w / 2 + w * (i + 0.5) / cols + (rng:NextNumber() - 0.5) * 6
				local z = park.z - d / 2 + d * (j + 0.5) / rows + (rng:NextNumber() - 0.5) * 6
				buildTree(model, Vector3.new(x, elevationAt(layout, x, z), z), rng)
			end
		end
	end
	-- Benches facing the centre from two sides
	for side = -1, 1, 2 do
		if decorOk() then
			local x = park.x + side * w * 0.3
			local z = park.z
			local p = Vector3.new(x, elevationAt(layout, x, z), z)
			buildBench(model, CFrame.lookAt(p, Vector3.new(park.x, p.Y, park.z)))
		end
	end
end

local function buildHub(layout, positions, folder: Instance, hubLandmark, bodies)
	local hub = layout.hub or {}
	local model = newModel("DeliveryHub", folder)
	local spawnCf = positions.hubSpawn
	local spawnSurface = positions.spawnSurfaceY
	local spawnPos = Vector3.new(spawnCf.Position.X, spawnSurface, spawnCf.Position.Z)

	-- Hub building: reuse a layout building of style Hub if authored, else build one.
	local hubBody = nil
	local hubFront = nil
	for index, spec in ipairs(layout.buildings or {}) do
		if spec.style == "Hub" and bodies[index] then
			hubBody = bodies[index]
			break
		end
	end
	if hubBody == nil and hubLandmark then
		local facing = flatUnit(spawnPos - Vector3.new(hubLandmark.x, 0, hubLandmark.z), Vector3.new(0, 0, -1))
		local body, front = buildBuilding(layout, { x = hubLandmark.x, z = hubLandmark.z, w = 26, h = 10, d = 18, style = "Hub", name = "HubBuilding" }, 3000, model, { facing = facing })
		hubBody, hubFront = body, front
	end
	if hubBody then
		-- Big sign on top of the front face
		local size = hubBody.Size
		local facing
		if hubFront then
			facing = hubFront.normal
		else
			facing = flatUnit(spawnPos - hubBody.Position, hubBody.CFrame.LookVector)
		end
		local localFacing = hubBody.CFrame:VectorToObjectSpace(facing)
		local extent = if math.abs(localFacing.X) > math.abs(localFacing.Z) then size.X / 2 else size.Z / 2
		local width = if math.abs(localFacing.X) > math.abs(localFacing.Z) then size.Z else size.X
		local signPos = hubBody.Position + facing * (extent + 0.4) + Vector3.new(0, size.Y / 2 - 2, 0)
		local sign = mk({
			name = "HubSign",
			size = Vector3.new(math.min(width * 0.9, 24), 3.2, 0.6),
			cframe = lookFlat(signPos, facing),
			color = Color3.fromRGB(35, 35, 40),
			material = Enum.Material.SmoothPlastic,
			parent = model,
			detail = true,
		})
		surfaceText(sign, Enum.NormalId.Front, "DELIVERY HUB", Color3.fromRGB(255, 170, 60))
	end

	-- Spawn pad
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "HubSpawn"
	spawn.Size = Vector3.new(8, 0.4, 8)
	spawn.CFrame = lookFlat(spawnPos + Vector3.new(0, 0.2, 0), spawnCf.LookVector)
	spawn.Color = Color3.fromRGB(250, 150, 50)
	spawn.Material = Enum.Material.Concrete
	spawn.Anchored = true
	spawn.CanCollide = true
	spawn.TopSurface = Enum.SurfaceType.Smooth
	spawn.BottomSurface = Enum.SurfaceType.Smooth
	spawn.Neutral = true
	spawn.Enabled = true
	spawn.Duration = 0
	spawn.AllowTeamChangeOnTouch = false
	spawn.Parent = model
	countPart()

	-- Order board kiosk
	local kioskPos = positions.kiosk or (spawnPos + spawnCf.LookVector * 10)
	local kioskFacing = flatUnit(spawnPos - kioskPos, -spawnCf.LookVector)
	local kiosk = mk({
		name = "Kiosk",
		size = Vector3.new(3.2, 5, 1.2),
		cframe = lookFlat(kioskPos + Vector3.new(0, 2.5, 0), kioskFacing),
		color = Color3.fromRGB(50, 50, 56),
		material = Enum.Material.Metal,
		parent = model,
		collide = true,
	})
	mk({
		name = "Screen",
		size = Vector3.new(2.6, 2.2, 0.1),
		cframe = kiosk.CFrame * CFrame.new(0, 0.8, -0.62),
		color = Color3.fromRGB(80, 220, 240),
		material = Enum.Material.Neon,
		parent = model,
		detail = true,
	})
	billboard(kiosk, "Order Board - open Orders (Tab)", 4, Color3.fromRGB(255, 255, 255), 90)

	-- Vehicle pads
	local pads = {}
	for i, padCf in ipairs(positions.vehiclePads) do
		local pad = mk({
			name = "VehiclePad" .. i,
			size = Vector3.new(6, 0.3, 12),
			cframe = padCf * CFrame.new(0, -0.15, 0),
			color = Color3.fromRGB(60, 160, 220),
			material = Enum.Material.SmoothPlastic,
			parent = model,
			collide = true,
		})
		CollectionService:AddTag(pad, "VehiclePad")
		pad:SetAttribute("PadIndex", i)
		surfaceText(pad, Enum.NormalId.Top, "🚲 VEHICLE PAD", Color3.fromRGB(255, 255, 255))
		table.insert(pads, padCf)
	end
	return pads
end

local function buildLandmarks(layout, positions, cityFolder, bodies)
	local folder = newFolder("Landmarks", cityFolder)
	local landmarks = layout.landmarks or {}
	local spawnPos = positions.hubSpawn.Position
	if landmarks.plaza then
		buildPlaza(layout, folder, landmarks.plaza, spawnPos)
	end
	if landmarks.tower then
		buildBeaconTower(layout, folder, landmarks.tower)
	end
	if landmarks.park then
		buildPark(layout, folder, landmarks.park)
	end
	if landmarks.waterTower then
		buildWaterTower(layout, folder, landmarks.waterTower)
	end
	return buildHub(layout, positions, folder, landmarks.hub, bodies)
end

-------------------------------------------------------------------------------
-- Public build
-------------------------------------------------------------------------------

--[[
	Builds the city. folders = { city: Folder, pickup: Folder, destinations: Folder, depots: Folder }.
	graph (optional) = RouteGraph.build(layout); built here when omitted.
	Returns the ctx.world table (Types.World). May yield (task.wait between batches).
]]
function CityBuilder.build(layout, folders, graph)
	assert(type(layout) == "table", "CityBuilder.build requires a layout table")
	assert(type(folders) == "table" and folders.city and folders.pickup and folders.destinations and folders.depots, "CityBuilder.build requires {city, pickup, destinations, depots} folders")
	beginBuild()
	local started = os.clock()
	local routeGraph = graph or RouteGraph.build(layout)
	local positions = CityBuilder.positionsFor(layout)

	local runtime = Workspace:FindFirstChild("Runtime")
	if not runtime then
		runtime = Instance.new("Folder")
		runtime.Name = "Runtime"
		runtime.Parent = Workspace
	end
	for _, name in ipairs({ "Vehicles", "Packages", "NPCs" }) do
		newFolder(name, runtime)
	end

	buildTerrain(layout)
	buildGround(layout, folders.city)
	buildRoads(layout, routeGraph, folders.city)
	local bodies = buildBuildings(layout, folders.city)
	local businesses = buildBusinesses(layout, positions, folders.pickup, bodies)
	local destinations = buildDestinations(layout, positions, folders.destinations)
	local depotPlots = buildDepotPlots(layout, positions, folders.depots)
	local vehiclePads = buildLandmarks(layout, positions, folders.city, bodies)
	buildParkedVehicles(layout, folders.city)
	buildProps(layout, folders.city)

	local total = state.count
	local elapsed = os.clock() - started
	warn(string.format("[CityBuilder] Built %d parts in %.2fs (%d decorative parts skipped by budget)", total, elapsed, state.skippedDecor))
	if total > CityBuilder.PART_BUDGET then
		warn(string.format("[CityBuilder] Part budget exceeded: %d > %d", total, CityBuilder.PART_BUDGET))
	end

	return {
		cityFolder = folders.city,
		pickupFolder = folders.pickup,
		destinationFolder = folders.destinations,
		depotFolder = folders.depots,
		runtime = runtime,
		businesses = businesses,
		destinations = destinations,
		depotPlots = depotPlots,
		hubSpawn = positions.hubSpawn,
		vehiclePads = vehiclePads,
		partCount = total,
	}
end

-- Part count of the most recent build (0 before any build).
function CityBuilder.getLastPartCount(): number
	return if state then state.count else 0
end

return CityBuilder
