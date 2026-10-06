--!nonstrict
-- Minimap: 180x180 rounded frame (bottom-left). Draws the road graph once as thin rotated Frames
-- inside a container scaled MAP_SCALE px/stud, keeps the player centred (north-up: world -Z is up),
-- shows a player triangle, stop dots lettered "P"/"D" and a brighter polyline for the current path.

local UIKit = require(script.Parent:WaitForChild("UIKit"))

local Minimap = {}

Minimap.SIZE = 180
Minimap.MAP_SCALE = 0.35 -- pixels per stud
Minimap.MAX_PATH_SEGMENTS = 30
Minimap.MAX_STOPS = 12

local ROAD_COLOR = Color3.fromRGB(96, 102, 118)
local ROAD_RESTRICTED_COLOR = Color3.fromRGB(70, 90, 110)
local PATH_COLOR = Color3.fromRGB(250, 200, 90)

local frame: any = nil
local world: any = nil
local playerMarker: any = nil
local pathSegments: { Frame } = {}
local stopDots: { TextLabel } = {}
local edgeCount = 0
local visibleSetting = true

local function half(): number
	return Minimap.SIZE / 2
end

-- Places a segment frame between two world positions (x/z) inside the world container.
local function placeSegment(segment: Frame, ax: number, az: number, bx: number, bz: number, thickness: number)
	local s = Minimap.MAP_SCALE
	local dx = (bx - ax) * s
	local dz = (bz - az) * s
	local length = math.sqrt(dx * dx + dz * dz)
	segment.Size = UDim2.fromOffset(math.max(1, length), thickness)
	segment.Position = UDim2.fromOffset((ax + bx) * 0.5 * s, (az + bz) * 0.5 * s)
	segment.Rotation = math.deg(math.atan2(dz, dx))
	segment.Visible = length > 0.5
end

local function newSegment(parent: Instance, name: string, color: Color3, zindex: number): Frame
	local segment = Instance.new("Frame")
	segment.Name = name
	segment.BackgroundColor3 = color
	segment.BorderSizePixel = 0
	segment.AnchorPoint = Vector2.new(0.5, 0.5)
	segment.ZIndex = zindex
	segment.Visible = false
	segment.Parent = parent
	return segment
end

-- Draws every graph edge once (called from Mount when ctx.graph exists).
function Minimap.DrawGraph(graph: any)
	if not world or type(graph) ~= "table" or type(graph.edges) ~= "table" or type(graph.nodes) ~= "table" then
		return
	end
	local roads = world:FindFirstChild("Roads")
	if roads then
		roads:Destroy()
	end
	roads = Instance.new("Frame")
	roads.Name = "Roads"
	roads.BackgroundTransparency = 1
	roads.Size = UDim2.fromOffset(0, 0)
	roads.ZIndex = 1
	roads.Parent = world
	edgeCount = 0
	for _, edge in ipairs(graph.edges) do
		local a = graph.nodes[edge.a]
		local b = graph.nodes[edge.b]
		if a and b and typeof(a.position) == "Vector3" and typeof(b.position) == "Vector3" then
			local mask = tonumber(edge.mask) or 7
			local width = tonumber(edge.width) or 10
			local segment = newSegment(roads, "Edge" .. tostring(edge.index or edgeCount + 1), if mask == 7 then ROAD_COLOR else ROAD_RESTRICTED_COLOR, 1)
			placeSegment(segment, a.position.X, a.position.Z, b.position.X, b.position.Z, math.clamp(width * Minimap.MAP_SCALE * 0.6, 1.5, 5))
			edgeCount += 1
		end
	end
end

function Minimap.GetEdgeCount(): number
	return edgeCount
end

function Minimap.Mount(parent: Instance, ctx: any): Frame
	-- CanvasGroup, not Frame: ClipsDescendants on a Frame ignores rotated descendants, and every
	-- road / path segment is a rotated Frame; a CanvasGroup rasterises its content and clips it.
	frame = UIKit.panel(parent, {
		name = "Minimap",
		class = "CanvasGroup",
		color = Color3.fromRGB(30, 33, 40),
		size = UDim2.fromOffset(Minimap.SIZE, Minimap.SIZE),
		position = UDim2.new(0, 8, 1, -8),
		anchor = Vector2.new(0, 1),
		corner = 16,
		stroke = true,
		clips = true,
	})
	world = Instance.new("Frame")
	world.Name = "World"
	world.BackgroundTransparency = 1
	world.Size = UDim2.fromOffset(0, 0)
	world.Position = UDim2.fromOffset(half(), half())
	world.Parent = frame

	for index = 1, Minimap.MAX_PATH_SEGMENTS do
		pathSegments[index] = newSegment(world, "Path" .. index, PATH_COLOR, 3)
	end
	for index = 1, Minimap.MAX_STOPS do
		local dot = UIKit.label(world, "P", {
			name = "Stop" .. index,
			bg = UIKit.Theme.pickup,
			color = UIKit.Theme.textOnAccent,
			bold = true,
			align = "Center",
			size = UDim2.fromOffset(16, 16),
			anchor = Vector2.new(0.5, 0.5),
			minSize = 10,
			maxSize = 12,
			corner = 8,
			zindex = 4,
			visible = false,
		})
		stopDots[index] = dot
	end

	playerMarker = UIKit.label(frame, "^", {
		name = "Player",
		bold = true,
		color = UIKit.Theme.text,
		align = "Center",
		size = UDim2.fromOffset(18, 18),
		position = UDim2.fromOffset(half(), half()),
		anchor = Vector2.new(0.5, 0.5),
		minSize = 14,
		maxSize = 18,
		zindex = 6,
	})
	UIKit.label(frame, "N", {
		name = "North",
		bold = true,
		color = UIKit.Theme.textDim,
		align = "Center",
		size = UDim2.fromOffset(18, 18),
		position = UDim2.new(0.5, 0, 0, 2),
		anchor = Vector2.new(0.5, 0),
		minSize = 12,
		maxSize = 14,
		zindex = 6,
	})

	if ctx and ctx.graph then
		Minimap.DrawGraph(ctx.graph)
	end
	Minimap.ApplyVisibility()
	return frame
end

function Minimap.ApplyVisibility()
	if frame then
		frame.Visible = visibleSetting
	end
end

-- settings.showMinimap toggle.
function Minimap.SetVisible(visible: boolean)
	visibleSetting = visible ~= false
	Minimap.ApplyVisibility()
end

function Minimap.IsVisible(): boolean
	return frame ~= nil and frame.Visible
end

-- data = { playerPosition: Vector3, heading: number, stops: {{position, kind, current}}, path: {Vector3}? }
function Minimap.Update(data: any)
	if not world or not frame or type(data) ~= "table" then
		return
	end
	local s = Minimap.MAP_SCALE
	local position = data.playerPosition
	if typeof(position) ~= "Vector3" then
		position = Vector3.zero
	end
	world.Position = UDim2.fromOffset(half() - position.X * s, half() - position.Z * s)
	-- Heading 0 faces -Z (north/up); positive heading turns toward -X (left) = counter-clockwise.
	playerMarker.Rotation = -math.deg(tonumber(data.heading) or 0)

	local stops = type(data.stops) == "table" and data.stops or {}
	for index, dot in ipairs(stopDots) do
		local stop = stops[index]
		if stop and typeof(stop.position) == "Vector3" then
			local isPickup = stop.kind == "pickup"
			dot.Text = if isPickup then "P" else "D"
			dot.BackgroundColor3 = if isPickup then UIKit.Theme.pickup else UIKit.Theme.deliver
			local size = if stop.current then 22 else 16
			dot.Size = UDim2.fromOffset(size, size)
			dot.Position = UDim2.fromOffset(stop.position.X * s, stop.position.Z * s)
			dot.ZIndex = if stop.current then 5 else 4
			dot.Visible = true
		else
			dot.Visible = false
		end
	end

	local path = data.path
	if type(path) == "table" and #path >= 2 then
		-- Subsample long paths so at most MAX_PATH_SEGMENTS segments are drawn.
		local pointCount = #path
		local segmentsWanted = math.min(Minimap.MAX_PATH_SEGMENTS, pointCount - 1)
		local used = 0
		for index = 1, segmentsWanted do
			local fromIndex = 1 + math.floor((index - 1) * (pointCount - 1) / segmentsWanted)
			local toIndex = 1 + math.floor(index * (pointCount - 1) / segmentsWanted)
			local a = path[fromIndex]
			local b = path[toIndex]
			if typeof(a) == "Vector3" and typeof(b) == "Vector3" and toIndex > fromIndex then
				used += 1
				placeSegment(pathSegments[used], a.X, a.Z, b.X, b.Z, 3)
			end
		end
		for index = used + 1, Minimap.MAX_PATH_SEGMENTS do
			pathSegments[index].Visible = false
		end
	else
		for _, segment in ipairs(pathSegments) do
			segment.Visible = false
		end
	end
end

function Minimap.GetFrame(): Frame?
	return frame
end

return Minimap
