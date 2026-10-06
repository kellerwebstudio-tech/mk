--!strict
-- RouteGraph: builds a routing graph from CityLayout road polylines, runs bounded A*,
-- projects positions onto the graph and validates authored layouts.
-- Pure Luau: the only Roblox type used is Vector3, so the module also runs under the
-- plain `luau` CLI with a tiny Vector3 stub (see tools/validate_layout.py).

export type RoadKind = "Road" | "Street" | "Alley" | "BikePath" | "Bridge" | "BikeBridge" | "Industrial" | "Ramp"

export type Node = { index: number, position: Vector3, roadIds: { string } }
export type Edge = {
	index: number,
	a: number,
	b: number,
	length: number,
	mask: number,
	kind: RoadKind,
	roadId: string,
	width: number,
}
export type Graph = { nodes: { Node }, edges: { Edge }, adjacency: { [number]: { number } } }

export type TurnKind = "Left" | "Right" | "Straight" | "SlightLeft" | "SlightRight" | "UTurn"
export type TurnInstruction = { position: Vector3, kind: TurnKind, distanceFromStart: number }

local RouteGraph = {}

RouteGraph.MASK_BICYCLE = 1
RouteGraph.MASK_SCOOTER = 2
RouteGraph.MASK_VAN = 4
RouteGraph.MASK_FOOT = 7

RouteGraph.KIND_MASK = {
	Road = 7,
	Bridge = 7,
	Industrial = 7,
	Ramp = 7,
	Street = 3,
	Alley = 1,
	BikePath = 1,
	BikeBridge = 1,
} :: { [string]: number }

RouteGraph.MERGE_DISTANCE = 1 -- studs: road points closer than this become one node
RouteGraph.SPLIT_DISTANCE = 1 -- studs: a node this close to another road's segment interior splits it
RouteGraph.MAX_EXPANSIONS = 4000
RouteGraph.ARRIVAL_MAX_DISTANCE = 14
RouteGraph.DOOR_MAX_DISTANCE = 20

local VAN_BUSINESSES = { FreshLaneMarket = true, CrateAndCoSupply = true }

-------------------------------------------------------------------------------
-- Small helpers
-------------------------------------------------------------------------------

local function toVec(p: any, defaultY: number): Vector3
	local y = p.y
	if y == nil then
		y = defaultY
	end
	return Vector3.new(p.x, y, p.z)
end

local function maskFor(kind: string): number
	local m = RouteGraph.KIND_MASK[kind]
	if m == nil then
		return 0
	end
	return m
end

-- Projects `pos` onto the segment ab. Returns the point, parameter t in [0,1] and distance.
local function projectOnSegment(a: Vector3, b: Vector3, pos: Vector3, ignoreY: boolean): (Vector3, number, number)
	local ab = b - a
	local ap = pos - a
	if ignoreY then
		ab = Vector3.new(ab.X, 0, ab.Z)
		ap = Vector3.new(ap.X, 0, ap.Z)
	end
	local len2 = ab:Dot(ab)
	local t = 0
	if len2 > 1e-9 then
		t = math.clamp(ap:Dot(ab) / len2, 0, 1)
	end
	local point = a + (b - a) * t
	local diff = pos - point
	if ignoreY then
		diff = Vector3.new(diff.X, 0, diff.Z)
	end
	return point, t, diff.Magnitude
end

-- 2D (XZ) helpers used by validation ----------------------------------------

local function dist2D(ax: number, az: number, bx: number, bz: number): number
	local dx, dz = ax - bx, az - bz
	return math.sqrt(dx * dx + dz * dz)
end

local function pointSegDist2D(px: number, pz: number, ax: number, az: number, bx: number, bz: number): number
	local abx, abz = bx - ax, bz - az
	local len2 = abx * abx + abz * abz
	local t = 0
	if len2 > 1e-9 then
		t = math.clamp(((px - ax) * abx + (pz - az) * abz) / len2, 0, 1)
	end
	return dist2D(px, pz, ax + abx * t, az + abz * t)
end

local function orient(ax: number, az: number, bx: number, bz: number, cx: number, cz: number): number
	return (bx - ax) * (cz - az) - (bz - az) * (cx - ax)
end

-- Returns kind ("none" | "point" | "overlap"), point (x,z) for "point", or the overlap interval
-- endpoints for "overlap" (x1,z1,x2,z2).
local function segIntersect2D(
	ax: number, az: number, bx: number, bz: number,
	cx: number, cz: number, dx: number, dz: number
): (string, number, number, number, number)
	local EPS = 1e-6
	local o1 = orient(ax, az, bx, bz, cx, cz)
	local o2 = orient(ax, az, bx, bz, dx, dz)
	local o3 = orient(cx, cz, dx, dz, ax, az)
	local o4 = orient(cx, cz, dx, dz, bx, bz)
	local collinear = math.abs(o1) < EPS and math.abs(o2) < EPS
	if collinear then
		-- project onto ab's direction
		local ux, uz = bx - ax, bz - az
		local len2 = ux * ux + uz * uz
		if len2 < EPS then
			return "none", 0, 0, 0, 0
		end
		local tc = ((cx - ax) * ux + (cz - az) * uz) / len2
		local td = ((dx - ax) * ux + (dz - az) * uz) / len2
		local lo, hi = math.min(tc, td), math.max(tc, td)
		local s0, s1 = math.max(0, lo), math.min(1, hi)
		if s1 < s0 - EPS then
			return "none", 0, 0, 0, 0
		end
		local x1, z1 = ax + ux * s0, az + uz * s0
		local x2, z2 = ax + ux * s1, az + uz * s1
		if dist2D(x1, z1, x2, z2) < 1e-3 then
			return "point", x1, z1, 0, 0
		end
		return "overlap", x1, z1, x2, z2
	end
	local function sgn(v: number): number
		if v > EPS then
			return 1
		elseif v < -EPS then
			return -1
		end
		return 0
	end
	local s1, s2, s3, s4 = sgn(o1), sgn(o2), sgn(o3), sgn(o4)
	if s1 * s2 <= 0 and s3 * s4 <= 0 then
		-- proper or touching intersection; compute the point via parametric form
		local rx, rz = bx - ax, bz - az
		local sx, sz = dx - cx, dz - cz
		local denom = rx * sz - rz * sx
		if math.abs(denom) < EPS then
			-- parallel but one endpoint touches (degenerate); choose that endpoint
			local candidates = { { ax, az }, { bx, bz }, { cx, cz }, { dx, dz } }
			for _, c in ipairs(candidates) do
				if pointSegDist2D(c[1], c[2], ax, az, bx, bz) < 1e-3 and pointSegDist2D(c[1], c[2], cx, cz, dx, dz) < 1e-3 then
					return "point", c[1], c[2], 0, 0
				end
			end
			return "none", 0, 0, 0, 0
		end
		local t = ((cx - ax) * sz - (cz - az) * sx) / denom
		return "point", ax + rx * t, az + rz * t, 0, 0
	end
	return "none", 0, 0, 0, 0
end

-- Distance from a 2D segment to an axis-aligned rectangle [x0,x1]x[z0,z1] (0 when they intersect).
local function segRectDist2D(ax: number, az: number, bx: number, bz: number, x0: number, z0: number, x1: number, z1: number): number
	local function inside(px: number, pz: number): boolean
		return px >= x0 and px <= x1 and pz >= z0 and pz <= z1
	end
	if inside(ax, az) or inside(bx, bz) then
		return 0
	end
	local corners = { { x0, z0 }, { x1, z0 }, { x1, z1 }, { x0, z1 } }
	local best = math.huge
	for i = 1, 4 do
		local c1 = corners[i]
		local c2 = corners[(i % 4) + 1]
		local kind = segIntersect2D(ax, az, bx, bz, c1[1], c1[2], c2[1], c2[2])
		if kind ~= "none" then
			return 0
		end
		best = math.min(best, pointSegDist2D(c1[1], c1[2], ax, az, bx, bz))
		best = math.min(best, pointSegDist2D(ax, az, c1[1], c1[2], c2[1], c2[2]))
		best = math.min(best, pointSegDist2D(bx, bz, c1[1], c1[2], c2[1], c2[2]))
	end
	return best
end

type Rect = { x0: number, z0: number, x1: number, z1: number }

local function rectOf(x: number, z: number, w: number, d: number, rot: number?): Rect
	local r = rot or 0
	local hw, hd = w / 2, d / 2
	if r % 180 == 0 then
		return { x0 = x - hw, z0 = z - hd, x1 = x + hw, z1 = z + hd }
	elseif r % 180 == 90 then
		return { x0 = x - hd, z0 = z - hw, x1 = x + hd, z1 = z + hw }
	end
	local rad = math.rad(r)
	local c, s = math.abs(math.cos(rad)), math.abs(math.sin(rad))
	local ex = hw * c + hd * s
	local ez = hw * s + hd * c
	return { x0 = x - ex, z0 = z - ez, x1 = x + ex, z1 = z + ez }
end

local function rectsOverlap(a: Rect, b: Rect, tolerance: number): boolean
	return a.x0 < b.x1 - tolerance and b.x0 < a.x1 - tolerance and a.z0 < b.z1 - tolerance and b.z0 < a.z1 - tolerance
end

-------------------------------------------------------------------------------
-- Binary min-heap keyed by f
-------------------------------------------------------------------------------

type Heap = { keys: { number }, values: { number }, size: number }

local function heapNew(): Heap
	return { keys = {}, values = {}, size = 0 }
end

local function heapPush(h: Heap, key: number, value: number)
	local n = h.size + 1
	h.size = n
	h.keys[n] = key
	h.values[n] = value
	local keys, values = h.keys, h.values
	while n > 1 do
		local parent = n // 2
		if keys[parent] <= keys[n] then
			break
		end
		keys[parent], keys[n] = keys[n], keys[parent]
		values[parent], values[n] = values[n], values[parent]
		n = parent
	end
end

local function heapPop(h: Heap): (number, number)
	local keys, values = h.keys, h.values
	local key, value = keys[1], values[1]
	local n = h.size
	keys[1], values[1] = keys[n], values[n]
	keys[n], values[n] = nil, nil
	n -= 1
	h.size = n
	local i = 1
	while true do
		local l, r = i * 2, i * 2 + 1
		local smallest = i
		if l <= n and keys[l] < keys[smallest] then
			smallest = l
		end
		if r <= n and keys[r] < keys[smallest] then
			smallest = r
		end
		if smallest == i then
			break
		end
		keys[i], keys[smallest] = keys[smallest], keys[i]
		values[i], values[smallest] = values[smallest], values[i]
		i = smallest
	end
	return key, value
end

-------------------------------------------------------------------------------
-- Graph build
-------------------------------------------------------------------------------

type NodeIndex = { grid: { [string]: { number } }, nodes: { Node }, cell: number }

local function cellKey(cx: number, cz: number, cy: number): string
	return cx .. "," .. cy .. "," .. cz
end

local function findOrAddNode(idx: NodeIndex, pos: Vector3, roadId: string?): number
	local cell = idx.cell
	local cx, cy, cz = math.floor(pos.X / cell), math.floor(pos.Y / cell), math.floor(pos.Z / cell)
	local best, bestDist = 0, RouteGraph.MERGE_DISTANCE
	for dx = -1, 1 do
		for dy = -1, 1 do
			for dz = -1, 1 do
				local bucket = idx.grid[cellKey(cx + dx, cz + dz, cy + dy)]
				if bucket then
					for _, ni in ipairs(bucket) do
						local d = (idx.nodes[ni].position - pos).Magnitude
						if d <= bestDist then
							best, bestDist = ni, d
						end
					end
				end
			end
		end
	end
	if best ~= 0 then
		if roadId then
			local node = idx.nodes[best]
			if not table.find(node.roadIds, roadId) then
				table.insert(node.roadIds, roadId)
			end
		end
		return best
	end
	local node: Node = { index = #idx.nodes + 1, position = pos, roadIds = {} }
	if roadId then
		node.roadIds[1] = roadId
	end
	table.insert(idx.nodes, node)
	local key = cellKey(cx, cz, cy)
	local bucket = idx.grid[key]
	if not bucket then
		bucket = {}
		idx.grid[key] = bucket
	end
	table.insert(bucket, node.index)
	return node.index
end

type RawEdge = { a: number, b: number, mask: number, kind: RoadKind, roadId: string, width: number }

function RouteGraph.build(layout: any): Graph
	local groundY = layout.groundY or 0
	local idx: NodeIndex = { grid = {}, nodes = {}, cell = 4 }
	local raw: { RawEdge } = {}

	for _, road in ipairs(layout.roads or {}) do
		local points = road.points or {}
		local mask = maskFor(road.kind)
		local prev: number? = nil
		for _, p in ipairs(points) do
			local ni = findOrAddNode(idx, toVec(p, groundY), road.id)
			if prev ~= nil and prev ~= ni then
				table.insert(raw, { a = prev, b = ni, mask = mask, kind = road.kind, roadId = road.id, width = road.width or 10 })
			end
			prev = ni
		end
	end

	local nodes = idx.nodes

	-- T-junction splitting: any node lying within SPLIT_DISTANCE of a segment interior splits it.
	local edges: { Edge } = {}
	local adjacency: { [number]: { number } } = {}
	local function addEdge(a: number, b: number, re: RawEdge)
		if a == b then
			return
		end
		local pa, pb = nodes[a].position, nodes[b].position
		local edge: Edge = {
			index = #edges + 1,
			a = a,
			b = b,
			length = (pb - pa).Magnitude,
			mask = re.mask,
			kind = re.kind,
			roadId = re.roadId,
			width = re.width,
		}
		table.insert(edges, edge)
		adjacency[a] = adjacency[a] or {}
		adjacency[b] = adjacency[b] or {}
		table.insert(adjacency[a], edge.index)
		table.insert(adjacency[b], edge.index)
	end

	local splitDist = RouteGraph.SPLIT_DISTANCE
	for _, re in ipairs(raw) do
		local pa, pb = nodes[re.a].position, nodes[re.b].position
		local minX, maxX = math.min(pa.X, pb.X) - splitDist, math.max(pa.X, pb.X) + splitDist
		local minZ, maxZ = math.min(pa.Z, pb.Z) - splitDist, math.max(pa.Z, pb.Z) + splitDist
		local minY, maxY = math.min(pa.Y, pb.Y) - splitDist, math.max(pa.Y, pb.Y) + splitDist
		local splits: { { t: number, node: number } } = {}
		for ni, node in ipairs(nodes) do
			if ni ~= re.a and ni ~= re.b then
				local p = node.position
				if p.X >= minX and p.X <= maxX and p.Z >= minZ and p.Z <= maxZ and p.Y >= minY and p.Y <= maxY then
					local _, t, d = projectOnSegment(pa, pb, p, false)
					if d <= splitDist and t > 0 and t < 1 then
						local edgeLen = (pb - pa).Magnitude
						if t * edgeLen > splitDist and (1 - t) * edgeLen > splitDist then
							table.insert(splits, { t = t, node = ni })
							if not table.find(node.roadIds, re.roadId) then
								table.insert(node.roadIds, re.roadId)
							end
						end
					end
				end
			end
		end
		if #splits == 0 then
			addEdge(re.a, re.b, re)
		else
			table.sort(splits, function(x, y)
				return x.t < y.t
			end)
			local prev = re.a
			for _, s in ipairs(splits) do
				addEdge(prev, s.node, re)
				prev = s.node
			end
			addEdge(prev, re.b, re)
		end
	end

	for i = 1, #nodes do
		adjacency[i] = adjacency[i] or {}
	end

	return { nodes = nodes, edges = edges, adjacency = adjacency }
end

-------------------------------------------------------------------------------
-- Projection
-------------------------------------------------------------------------------

local function nearestEdge(graph: Graph, pos: Vector3, mask: number, ignoreY: boolean): (Vector3?, Edge?, number, number)
	local bestPoint: Vector3? = nil
	local bestEdge: Edge? = nil
	local bestT, bestDist = 0, math.huge
	local nodes = graph.nodes
	for _, edge in ipairs(graph.edges) do
		if bit32.band(edge.mask, mask) ~= 0 then
			local point, t, d = projectOnSegment(nodes[edge.a].position, nodes[edge.b].position, pos, ignoreY)
			if d < bestDist then
				bestPoint, bestEdge, bestT, bestDist = point, edge, t, d
			end
		end
	end
	return bestPoint, bestEdge, bestT, bestDist
end

function RouteGraph.nearestPointOnGraph(graph: Graph, pos: Vector3, mask: number): (Vector3, Edge, number, number)
	local point, edge, t, d = nearestEdge(graph, pos, mask, false)
	-- The contract promises a point and an edge; a graph without any allowed edge is a layout bug.
	return point :: any, edge :: any, t, d
end

-------------------------------------------------------------------------------
-- A*
-------------------------------------------------------------------------------

function RouteGraph.findPath(graph: Graph, from: Vector3, to: Vector3, mask: number): ({ Vector3 }?, number)
	local pFrom, eFrom = nearestEdge(graph, from, mask, false)
	local pTo, eTo = nearestEdge(graph, to, mask, false)
	if pFrom == nil or eFrom == nil or pTo == nil or eTo == nil then
		return nil, math.huge
	end
	if eFrom.index == eTo.index then
		return { pFrom, pTo }, (pTo - pFrom).Magnitude
	end

	local nodes, edges, adjacency = graph.nodes, graph.edges, graph.adjacency
	local g: { [number]: number } = {}
	local parent: { [number]: number } = {}
	local closed: { [number]: boolean } = {}
	local heap = heapNew()

	local function h(ni: number): number
		return (nodes[ni].position - pTo).Magnitude
	end

	local goalCost: { [number]: number } = {}
	goalCost[eTo.a] = (nodes[eTo.a].position - pTo).Magnitude
	goalCost[eTo.b] = (nodes[eTo.b].position - pTo).Magnitude

	for _, ni in ipairs({ eFrom.a, eFrom.b }) do
		local cost = (nodes[ni].position - pFrom).Magnitude
		if g[ni] == nil or cost < g[ni] then
			g[ni] = cost
			heapPush(heap, cost + h(ni), ni)
		end
	end

	local best, bestNode = math.huge, 0
	local expansions = 0
	while heap.size > 0 do
		local f, ni = heapPop(heap)
		if f >= best then
			break
		end
		if not closed[ni] then
			closed[ni] = true
			expansions += 1
			if expansions > RouteGraph.MAX_EXPANSIONS then
				break
			end
			local gi = g[ni]
			local gc = goalCost[ni]
			if gc ~= nil and gi + gc < best then
				best, bestNode = gi + gc, ni
			end
			for _, ei in ipairs(adjacency[ni]) do
				local edge = edges[ei]
				if bit32.band(edge.mask, mask) ~= 0 then
					local other = if edge.a == ni then edge.b else edge.a
					if not closed[other] then
						local ng = gi + edge.length
						if g[other] == nil or ng < g[other] then
							g[other] = ng
							parent[other] = ni
							heapPush(heap, ng + h(other), other)
						end
					end
				end
			end
		end
	end

	if bestNode == 0 then
		return nil, math.huge
	end

	local reversed: { Vector3 } = {}
	local cur: number? = bestNode
	while cur ~= nil do
		table.insert(reversed, nodes[cur].position)
		cur = parent[cur]
	end
	local path: { Vector3 } = { pFrom }
	for i = #reversed, 1, -1 do
		local p = reversed[i]
		if (p - path[#path]).Magnitude > 1e-3 then
			table.insert(path, p)
		end
	end
	if (pTo - path[#path]).Magnitude > 1e-3 then
		table.insert(path, pTo)
	end
	return path, best
end

-------------------------------------------------------------------------------
-- Path helpers
-------------------------------------------------------------------------------

function RouteGraph.distanceAlongPath(path: { Vector3 }): number
	local total = 0
	for i = 2, #path do
		total += (path[i] - path[i - 1]).Magnitude
	end
	return total
end

function RouteGraph.distanceToPolyline(path: { Vector3 }, pos: Vector3): (number, number)
	local n = #path
	if n == 0 then
		return math.huge, 0
	elseif n == 1 then
		return (pos - path[1]).Magnitude, 1
	end
	local bestDist, bestIndex = math.huge, 1
	for i = 1, n - 1 do
		local _, _, d = projectOnSegment(path[i], path[i + 1], pos, false)
		if d < bestDist then
			bestDist, bestIndex = d, i
		end
	end
	return bestDist, bestIndex
end

function RouteGraph.turnInstructions(path: { Vector3 }): { TurnInstruction }
	local result: { TurnInstruction } = {}
	local n = #path
	if n < 3 then
		return result
	end
	local distance = 0
	for i = 2, n - 1 do
		distance += (path[i] - path[i - 1]).Magnitude
		local inV = path[i] - path[i - 1]
		local outV = path[i + 1] - path[i]
		local ix, iz = inV.X, inV.Z
		local ox, oz = outV.X, outV.Z
		local inLen = math.sqrt(ix * ix + iz * iz)
		local outLen = math.sqrt(ox * ox + oz * oz)
		if inLen > 1e-3 and outLen > 1e-3 then
			local cross = ix * oz - iz * ox
			local dot = ix * ox + iz * oz
			local deg = math.deg(math.atan2(cross, dot)) -- positive = right turn (X east, Z south)
			local mag = math.abs(deg)
			local kind: TurnKind? = nil
			if mag >= 150 then
				kind = "UTurn"
			elseif mag >= 55 then
				kind = if deg > 0 then "Right" else "Left"
			elseif mag >= 20 then
				kind = if deg > 0 then "SlightRight" else "SlightLeft"
			end
			if kind ~= nil then
				table.insert(result, { position = path[i], kind = kind, distanceFromStart = distance })
			end
		end
	end
	return result
end

-------------------------------------------------------------------------------
-- Validation
-------------------------------------------------------------------------------

local function componentCount(graph: Graph, mask: number): (number, number)
	local visited: { [number]: boolean } = {}
	local components = 0
	local nodesWithEdges = 0
	local hasAllowed: { [number]: boolean } = {}
	for _, edge in ipairs(graph.edges) do
		if bit32.band(edge.mask, mask) ~= 0 then
			hasAllowed[edge.a] = true
			hasAllowed[edge.b] = true
		end
	end
	for ni in pairs(hasAllowed) do
		nodesWithEdges += 1
		if not visited[ni] then
			components += 1
			local stack = { ni }
			visited[ni] = true
			while #stack > 0 do
				local cur = table.remove(stack) :: number
				for _, ei in ipairs(graph.adjacency[cur]) do
					local edge = graph.edges[ei]
					if bit32.band(edge.mask, mask) ~= 0 then
						local other = if edge.a == cur then edge.b else edge.a
						if not visited[other] then
							visited[other] = true
							table.insert(stack, other)
						end
					end
				end
			end
		end
	end
	return components, nodesWithEdges
end

local MASK_NAMES = { [1] = "Bicycle", [2] = "Scooter", [4] = "Van" }

function RouteGraph.validate(layout: any): { string }
	local problems: { string } = {}
	local function report(fmt: string, ...: any)
		table.insert(problems, string.format(fmt, ...))
	end

	local bounds = layout.bounds or { minX = -math.huge, maxX = math.huge, minZ = -math.huge, maxZ = math.huge }
	local function checkBounds(label: string, x: number?, z: number?)
		if x == nil or z == nil then
			report("%s has a missing coordinate", label)
			return
		end
		if x < bounds.minX or x > bounds.maxX or z < bounds.minZ or z > bounds.maxZ then
			report("%s at (%.1f, %.1f) is outside bounds", label, x, z)
		end
	end

	local roads = layout.roads or {}
	local buildings = layout.buildings or {}
	local businesses = layout.businesses or {}
	local destinations = layout.destinations or {}
	local depotPlots = layout.depotPlots or {}

	-- 1. ids unique, roads shape
	local seen: { [string]: string } = {}
	local function uniqueId(kind: string, id: any)
		if type(id) ~= "string" or id == "" then
			report("%s with missing id", kind)
			return
		end
		local key = kind .. ":" .. id
		if seen[key] then
			report("duplicate %s id %q", kind, id)
		end
		seen[key] = kind
	end
	for _, road in ipairs(roads) do
		uniqueId("road", road.id)
		if type(road.points) ~= "table" or #road.points < 2 then
			report("road %q has fewer than 2 points", tostring(road.id))
		end
		if maskFor(road.kind) == 0 then
			report("road %q has unknown kind %q", tostring(road.id), tostring(road.kind))
		end
		if type(road.width) ~= "number" or road.width <= 0 then
			report("road %q has no width", tostring(road.id))
		end
		for i, p in ipairs(road.points or {}) do
			checkBounds(string.format("road %s point %d", tostring(road.id), i), p.x, p.z)
		end
	end
	for _, b in ipairs(businesses) do
		uniqueId("business", b.id)
	end
	for _, d in ipairs(destinations) do
		uniqueId("destination", d.id)
	end
	for _, p in ipairs(depotPlots) do
		uniqueId("depotPlot", p.id)
	end
	for _, n in ipairs(layout.neighborhoods or {}) do
		uniqueId("neighborhood", n.id)
	end
	for _, p in ipairs(layout.pedestrianPaths or {}) do
		uniqueId("pedestrianPath", p.id)
		for i, pt in ipairs(p.points or {}) do
			checkBounds(string.format("pedestrian path %s point %d", tostring(p.id), i), pt.x, pt.z)
		end
	end

	-- 2. road segment crossings without shared nodes
	type Seg = { road: any, i: number, ax: number, az: number, bx: number, bz: number }
	local segs: { Seg } = {}
	for _, road in ipairs(roads) do
		local pts = road.points or {}
		for i = 1, #pts - 1 do
			table.insert(segs, { road = road, i = i, ax = pts[i].x, az = pts[i].z, bx = pts[i + 1].x, bz = pts[i + 1].z })
		end
	end
	local function roadHasNodeNear(road: any, x: number, z: number): boolean
		for _, p in ipairs(road.points or {}) do
			if dist2D(p.x, p.z, x, z) <= RouteGraph.MERGE_DISTANCE then
				return true
			end
		end
		return false
	end
	local reportedPairs: { [string]: boolean } = {}
	for i = 1, #segs do
		local s = segs[i]
		local sMinX, sMaxX = math.min(s.ax, s.bx), math.max(s.ax, s.bx)
		local sMinZ, sMaxZ = math.min(s.az, s.bz), math.max(s.az, s.bz)
		for j = i + 1, #segs do
			local o = segs[j]
			local sameRoad = s.road == o.road
			if not (sameRoad and math.abs(s.i - o.i) == 1) then
				if math.max(s.ax, s.bx) < math.min(o.ax, o.bx) - 1 or math.max(o.ax, o.bx) < sMinX - 1
					or sMaxZ < math.min(o.az, o.bz) - 1 or math.max(o.az, o.bz) < sMinZ - 1 then
					-- bounding boxes apart
				else
					local kind, x1, z1, x2, z2 = segIntersect2D(s.ax, s.az, s.bx, s.bz, o.ax, o.az, o.bx, o.bz)
					if kind == "overlap" then
						report("roads %s (segment %d) and %s (segment %d) overlap collinearly from (%.1f, %.1f) to (%.1f, %.1f)",
							tostring(s.road.id), s.i, tostring(o.road.id), o.i, x1, z1, x2, z2)
					elseif kind == "point" then
						if not (roadHasNodeNear(s.road, x1, z1) and roadHasNodeNear(o.road, x1, z1)) then
							local key = tostring(s.road.id) .. "|" .. tostring(o.road.id) .. "|" .. string.format("%.0f,%.0f", x1, z1)
							if not reportedPairs[key] then
								reportedPairs[key] = true
								report("roads %s and %s cross at (%.1f, %.1f) without a shared point", tostring(s.road.id), tostring(o.road.id), x1, z1)
							end
						end
					end
					_ = sMaxX
				end
			end
		end
	end

	-- 3. water: only bridge kinds may cross water rectangles
	for _, w in ipairs(layout.water or {}) do
		checkBounds("water", w.x, w.z)
		local rect: Rect = { x0 = w.x - w.w / 2, z0 = w.z - w.d / 2, x1 = w.x + w.w / 2, z1 = w.z + w.d / 2 }
		for _, s in ipairs(segs) do
			local kind = s.road.kind
			if kind ~= "Bridge" and kind ~= "BikeBridge" then
				if segRectDist2D(s.ax, s.az, s.bx, s.bz, rect.x0, rect.z0, rect.x1, rect.z1) < 0.5 then
					report("road %s (segment %d, kind %s) crosses water at (%.0f, %.0f)", tostring(s.road.id), s.i, tostring(kind), w.x, w.z)
				end
			end
		end
	end

	-- 4. graph-based checks
	local graph = RouteGraph.build(layout)
	for _, mask in ipairs({ 1, 2, 4 }) do
		local components, nodeCount = componentCount(graph, mask)
		if nodeCount == 0 then
			report("%s graph has no edges", MASK_NAMES[mask])
		elseif components ~= 1 then
			report("%s graph has %d components (expected 1)", MASK_NAMES[mask], components)
		end
	end

	local groundY = layout.groundY or 0
	local function checkStop(label: string, arrival: any, door: any, requireVan: boolean)
		if type(arrival) ~= "table" or arrival.x == nil or arrival.z == nil then
			report("%s has no arrival point", label)
			return
		end
		if type(door) ~= "table" or door.x == nil or door.z == nil then
			report("%s has no door", label)
			return
		end
		checkBounds(label .. " arrival", arrival.x, arrival.z)
		checkBounds(label .. " door", door.x, door.z)
		local pos = Vector3.new(arrival.x, groundY, arrival.z)
		local _, edge, _, d = nearestEdge(graph, pos, RouteGraph.MASK_BICYCLE, true)
		if edge == nil or d > RouteGraph.ARRIVAL_MAX_DISTANCE then
			report("%s arrival point (%.0f, %.0f) is %.1f studs from the nearest bicycle edge (max %d)", label, arrival.x, arrival.z, d, RouteGraph.ARRIVAL_MAX_DISTANCE)
		end
		if requireVan then
			local _, vEdge, _, vd = nearestEdge(graph, pos, RouteGraph.MASK_VAN, true)
			if vEdge == nil or vd > RouteGraph.ARRIVAL_MAX_DISTANCE then
				report("%s arrival point (%.0f, %.0f) is %.1f studs from the nearest van edge (max %d)", label, arrival.x, arrival.z, vd, RouteGraph.ARRIVAL_MAX_DISTANCE)
			end
		end
		local doorDist = dist2D(arrival.x, arrival.z, door.x, door.z)
		if doorDist > RouteGraph.DOOR_MAX_DISTANCE then
			report("%s door is %.1f studs from its arrival point (max %d)", label, doorDist, RouteGraph.DOOR_MAX_DISTANCE)
		end
	end
	for _, b in ipairs(businesses) do
		local label = "business " .. tostring(b.id)
		checkStop(label, b.arrivalPoint, b.door, VAN_BUSINESSES[b.id] == true)
		if type(b.pickupPoint) ~= "table" then
			report("%s has no pickup point", label)
		else
			checkBounds(label .. " pickup", b.pickupPoint.x, b.pickupPoint.z)
			if b.door and b.door.x then
				local pd = dist2D(b.pickupPoint.x, b.pickupPoint.z, b.door.x, b.door.z)
				if pd > RouteGraph.DOOR_MAX_DISTANCE then
					report("%s pickup point is %.1f studs from its door (max %d)", label, pd, RouteGraph.DOOR_MAX_DISTANCE)
				end
			end
		end
	end
	for _, d in ipairs(destinations) do
		local label = "destination " .. tostring(d.id)
		checkStop(label, d.arrivalPoint, d.door, d.kind == "LoadingBay")
		if type(d.accepts) ~= "table" then
			report("%s has no accepts table", label)
		end
		if d.kind == "LoadingBay" and type(d.accepts) == "table" and not d.accepts.Large then
			report("%s is a LoadingBay but does not accept Large", label)
		end
	end

	-- 5. buildings vs roads, buildings vs buildings
	local rects: { Rect } = {}
	for bi, b in ipairs(buildings) do
		local label = string.format("building %d (%s)", bi, tostring(b.name or b.style))
		if type(b.x) ~= "number" or type(b.z) ~= "number" or type(b.w) ~= "number" or type(b.d) ~= "number" then
			report("%s has missing dimensions", label)
			rects[bi] = { x0 = 0, z0 = 0, x1 = 0, z1 = 0 }
		else
			local r = rectOf(b.x, b.z, b.w, b.d, b.rot)
			rects[bi] = r
			checkBounds(label .. " min corner", r.x0, r.z0)
			checkBounds(label .. " max corner", r.x1, r.z1)
			for _, s in ipairs(segs) do
				local limit = (s.road.width or 0) / 2 + 1
				if segRectDist2D(s.ax, s.az, s.bx, s.bz, r.x0, r.z0, r.x1, r.z1) < limit then
					report("%s at (%.0f, %.0f) overlaps road %s (segment %d)", label, b.x, b.z, tostring(s.road.id), s.i)
				end
			end
		end
	end
	for i = 1, #rects do
		for j = i + 1, #rects do
			if rectsOverlap(rects[i], rects[j], 0.01) then
				local a, b = buildings[i], buildings[j]
				report("building %d (%s at %.0f, %.0f) overlaps building %d (%s at %.0f, %.0f)", i, tostring(a.name or a.style), a.x, a.z, j, tostring(b.name or b.style), b.x, b.z)
			end
		end
	end

	-- 6. depot plots vs roads / buildings
	for _, plot in ipairs(depotPlots) do
		local label = "depot plot " .. tostring(plot.id)
		local r = rectOf(plot.x, plot.z, plot.w, plot.d, 0)
		checkBounds(label .. " min corner", r.x0, r.z0)
		checkBounds(label .. " max corner", r.x1, r.z1)
		for _, s in ipairs(segs) do
			local limit = (s.road.width or 0) / 2 + 1
			if segRectDist2D(s.ax, s.az, s.bx, s.bz, r.x0, r.z0, r.x1, r.z1) < limit then
				report("%s overlaps road %s (segment %d)", label, tostring(s.road.id), s.i)
			end
		end
		for bi, br in ipairs(rects) do
			if rectsOverlap(r, br, 0.01) then
				report("%s overlaps building %d (%s)", label, bi, tostring(buildings[bi].name or buildings[bi].style))
			end
		end
		for pi, spot in ipairs(plot.parking or {}) do
			if spot.x < r.x0 or spot.x > r.x1 or spot.z < r.z0 or spot.z > r.z1 then
				report("%s parking spot %d is outside the plot", label, pi)
			end
		end
	end

	-- 7. parked vehicles vs road centre lines and arrival pads
	local arrivals: { { x: number, z: number, label: string } } = {}
	for _, b in ipairs(businesses) do
		if b.arrivalPoint then
			table.insert(arrivals, { x = b.arrivalPoint.x, z = b.arrivalPoint.z, label = "business " .. tostring(b.id) })
		end
	end
	for _, d in ipairs(destinations) do
		if d.arrivalPoint then
			table.insert(arrivals, { x = d.arrivalPoint.x, z = d.arrivalPoint.z, label = "destination " .. tostring(d.id) })
		end
	end
	for vi, v in ipairs(layout.parkedVehicles or {}) do
		local label = string.format("parked vehicle %d", vi)
		checkBounds(label, v.x, v.z)
		local nearest = math.huge
		local nearestRoad = ""
		for _, s in ipairs(segs) do
			local d = pointSegDist2D(v.x, v.z, s.ax, s.az, s.bx, s.bz)
			if d < nearest then
				nearest, nearestRoad = d, tostring(s.road.id)
			end
		end
		if nearest < 4 then
			report("%s at (%.0f, %.0f) is %.1f studs from the centre line of road %s (min 4)", label, v.x, v.z, nearest, nearestRoad)
		end
		for _, a in ipairs(arrivals) do
			if dist2D(v.x, v.z, a.x, a.z) < 8 then
				report("%s at (%.0f, %.0f) sits on the arrival pad of %s", label, v.x, v.z, a.label)
			end
		end
	end

	-- 8. props and hub inside bounds
	for pi, p in ipairs(layout.props or {}) do
		checkBounds(string.format("prop %d (%s)", pi, tostring(p.type)), p.x, p.z)
	end
	local hub = layout.hub
	if type(hub) ~= "table" or type(hub.spawn) ~= "table" then
		report("hub.spawn is missing")
	else
		checkBounds("hub spawn", hub.spawn.x, hub.spawn.z)
		for i, pad in ipairs(hub.vehiclePads or {}) do
			checkBounds("hub vehicle pad " .. i, pad.x, pad.z)
		end
		if hub.kiosk then
			checkBounds("hub kiosk", hub.kiosk.x, hub.kiosk.z)
		end
		if #(hub.vehiclePads or {}) < 1 then
			report("hub has no vehicle pads")
		end
	end

	return problems
end

return RouteGraph
