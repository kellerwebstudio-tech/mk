--!nonstrict
-- CityLifeController: client-only cosmetic NPCs. Up to 20 pedestrians walk the layout's
-- pedestrianPaths loops at 6-8 studs/s with a Motor6D walk pose, plus idle customers near four
-- destinations and workers at depot plots. Figures are built locally (server Builders are not
-- reachable from the client): with embedded people data a Shared.Util.FigureRig placeholder rig
-- (FigureRig.idForKind per kind/seed; the EmbeddedMeshController dresses the placeholders and the
-- hip Motor6Ds swing through FigureRig.setWalkPose), otherwise the generated part figure below.
-- Every part is non-colliding, the anchored Root is moved by CFrame. Updated at 20 Hz; figures
-- farther than 350 studs from the camera are paused and hidden.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Util = Shared:WaitForChild("Util")
local MathUtil = require(Util:WaitForChild("MathUtil"))
local FigureRig = require(Util:WaitForChild("FigureRig"))

local CityLifeController = {}

CityLifeController.MAX_PEDESTRIANS = 20
CityLifeController.MAX_CUSTOMERS = 4
CityLifeController.MAX_WORKERS = 4
CityLifeController.SPAWN_DELAY = 2
CityLifeController.UPDATE_INTERVAL = 0.05 -- 20 Hz
CityLifeController.ACTIVE_RANGE = 350
CityLifeController.MIN_SPEED = 6
CityLifeController.MAX_SPEED = 8
CityLifeController.ROOT_HEIGHT = 3 -- root (torso centre) height above the ground

local SHIRT_COLORS = {
	Color3.fromRGB(226, 76, 60), Color3.fromRGB(64, 160, 220), Color3.fromRGB(60, 160, 90),
	Color3.fromRGB(240, 200, 60), Color3.fromRGB(150, 90, 200), Color3.fromRGB(240, 140, 50),
	Color3.fromRGB(70, 70, 80), Color3.fromRGB(250, 250, 245),
}
local PANTS_COLORS = { Color3.fromRGB(45, 55, 90), Color3.fromRGB(40, 40, 45), Color3.fromRGB(110, 90, 70), Color3.fromRGB(80, 110, 140) }
local SKIN_COLORS = { Color3.fromRGB(245, 205, 170), Color3.fromRGB(200, 150, 110), Color3.fromRGB(140, 95, 65), Color3.fromRGB(230, 185, 150) }

local ctx = nil
local npcFolder: Instance? = nil
local walkers = {}
local idlers = {}
local accumulator = 0
local spawned = false
local rng = Random.new(7)

-------------------------------------------------------------------------------
-- Figure builder
-------------------------------------------------------------------------------

local function stylePart(part: BasePart)
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = true
	part.Massless = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
end

local function limb(name: string, size: Vector3, color: Color3, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.Anchored = false
	stylePart(part)
	part.Parent = parent
	return part
end

local function joint(name: string, part0: BasePart, part1: BasePart, c0: CFrame, c1: CFrame): Motor6D
	local motor = Instance.new("Motor6D")
	motor.Name = name
	motor.Part0 = part0
	motor.Part1 = part1
	motor.C0 = c0
	motor.C1 = c1
	motor.Parent = part1
	return motor
end

export type Figure = {
	model: Model,
	root: BasePart,
	rig: boolean,
	figureId: string?,
	leftLeg: Motor6D?,
	rightLeg: Motor6D?,
	leftArm: Motor6D?,
	rightArm: Motor6D?,
}

-- Builds the figure for a kind/seed: an embedded FigureRig when its data is present (Root
-- anchored, placeholders unanchored and dressed by the EmbeddedMeshController), else the generated
-- part figure (BuildGeneratedFigure).
function CityLifeController.BuildFigure(seed: number, kind: string?): Figure
	local npcKind = kind or "Pedestrian"
	local figureId = FigureRig.idForKind(npcKind, seed)
	if FigureRig.has(figureId) then
		local ok, model = pcall(FigureRig.build, figureId, { name = npcKind, anchored = true })
		if ok and model and model.PrimaryPart then
			model:SetAttribute("NPCKind", npcKind)
			model:SetAttribute("Seed", seed)
			FigureRig.setIdlePose(model)
			return { model = model, root = model.PrimaryPart, rig = true, figureId = figureId }
		end
		warn("[CityLifeController] " .. figureId .. ": rig build failed, using the generated figure: " .. tostring(model))
	end
	return CityLifeController.BuildGeneratedFigure(seed, npcKind)
end

-- Builds a simple part figure. Root is anchored and invisible; limbs hang off the torso with
-- Motor6Ds whose Transform animates the pose. Colours vary with `seed`.
function CityLifeController.BuildGeneratedFigure(seed: number, kind: string?): Figure
	local model = Instance.new("Model")
	model.Name = kind or "Pedestrian"

	local shirt = SHIRT_COLORS[(seed % #SHIRT_COLORS) + 1]
	if kind == "Worker" then
		shirt = Color3.fromRGB(250, 150, 40)
	end
	local pants = PANTS_COLORS[(math.floor(seed / 3) % #PANTS_COLORS) + 1]
	local skin = SKIN_COLORS[(math.floor(seed / 2) % #SKIN_COLORS) + 1]

	local root = Instance.new("Part")
	root.Name = "Root"
	root.Size = Vector3.new(1.6, 2, 0.9)
	root.Transparency = 1
	root.Anchored = true
	stylePart(root)
	root.CastShadow = false
	root.Parent = model
	model.PrimaryPart = root

	local torso = limb("Torso", Vector3.new(1.6, 2, 0.9), shirt, model)
	joint("RootJoint", root, torso, CFrame.identity, CFrame.identity)
	local head = limb("Head", Vector3.new(1.1, 1.1, 1.1), skin, model)
	joint("Neck", torso, head, CFrame.new(0, 1.6, 0), CFrame.identity)
	if kind == "Worker" then
		local hat = limb("Hat", Vector3.new(1.3, 0.4, 1.3), Color3.fromRGB(250, 220, 60), model)
		joint("HatJoint", head, hat, CFrame.new(0, 0.7, 0), CFrame.identity)
	end

	local leftArm = limb("LeftArm", Vector3.new(0.7, 1.9, 0.7), shirt, model)
	local rightArm = limb("RightArm", Vector3.new(0.7, 1.9, 0.7), shirt, model)
	local leftLeg = limb("LeftLeg", Vector3.new(0.75, 2, 0.75), pants, model)
	local rightLeg = limb("RightLeg", Vector3.new(0.75, 2, 0.75), pants, model)

	-- Shoulder / hip pivots: C0 at the joint on the torso, C1 at the top of the limb.
	local leftArmMotor = joint("LeftShoulder", torso, leftArm, CFrame.new(-1.15, 0.9, 0), CFrame.new(0, 0.95, 0))
	local rightArmMotor = joint("RightShoulder", torso, rightArm, CFrame.new(1.15, 0.9, 0), CFrame.new(0, 0.95, 0))
	local leftLegMotor = joint("LeftHip", torso, leftLeg, CFrame.new(-0.42, -1, 0), CFrame.new(0, 1, 0))
	local rightLegMotor = joint("RightHip", torso, rightLeg, CFrame.new(0.42, -1, 0), CFrame.new(0, 1, 0))

	return {
		model = model,
		root = root,
		rig = false,
		figureId = nil,
		leftLeg = leftLegMotor,
		rightLeg = rightLegMotor,
		leftArm = leftArmMotor,
		rightArm = rightArmMotor,
	}
end

-- Walk pose: legs and arms swing in opposite phase (rigs: the hip Motor6Ds through FigureRig).
local function applyWalkPose(figure: Figure, phase: number)
	if figure.rig then
		FigureRig.setWalkPose(figure.model, phase)
		return
	end
	local swing = math.sin(phase) * 0.6
	local leftLeg, rightLeg, leftArm, rightArm = figure.leftLeg, figure.rightLeg, figure.leftArm, figure.rightArm
	if leftLeg and rightLeg and leftArm and rightArm then
		leftLeg.Transform = CFrame.Angles(swing, 0, 0)
		rightLeg.Transform = CFrame.Angles(-swing, 0, 0)
		leftArm.Transform = CFrame.Angles(-swing * 0.8, 0, 0)
		rightArm.Transform = CFrame.Angles(swing * 0.8, 0, 0)
	end
end

local function applyIdlePose(figure: Figure, time: number, seed: number)
	if figure.rig then
		-- Rigs have no arm joints; the idle pose was set once at build time.
		return
	end
	local sway = math.sin(time * 1.2 + seed) * 0.08
	local leftLeg, rightLeg, leftArm, rightArm = figure.leftLeg, figure.rightLeg, figure.leftArm, figure.rightArm
	if leftLeg and rightLeg and leftArm and rightArm then
		leftArm.Transform = CFrame.Angles(0, 0, sway)
		rightArm.Transform = CFrame.Angles(0, 0, -sway)
		leftLeg.Transform = CFrame.identity
		rightLeg.Transform = CFrame.identity
	end
end

-------------------------------------------------------------------------------
-- Paths
-------------------------------------------------------------------------------

local function groundY(): number
	local layout = ctx.layout
	return layout and type(layout.groundY) == "number" and layout.groundY or 0
end

-- Pre-computes cumulative lengths for a loop of {x, z} points.
local function buildLoop(points: { any }): any?
	if type(points) ~= "table" or #points < 2 then
		return nil
	end
	local y = groundY()
	local vectors = {}
	for _, p in ipairs(points) do
		if type(p.x) == "number" and type(p.z) == "number" then
			table.insert(vectors, Vector3.new(p.x, y, p.z))
		end
	end
	if #vectors < 2 then
		return nil
	end
	local cumulative = { 0 }
	local total = 0
	for index = 2, #vectors + 1 do
		local a = vectors[index - 1]
		local b = vectors[(index - 1) % #vectors + 1]
		total += (b - a).Magnitude
		cumulative[index] = total
	end
	if total < 1 then
		return nil
	end
	return { points = vectors, cumulative = cumulative, total = total }
end

-- Position and forward direction at `distance` along the loop.
local function sampleLoop(loop, distance: number): (Vector3, Vector3)
	local d = distance % loop.total
	local n = #loop.points
	for index = 1, n do
		local startDistance = loop.cumulative[index]
		local endDistance = loop.cumulative[index + 1]
		if d >= startDistance and d <= endDistance then
			local a = loop.points[index]
			local b = loop.points[index % n + 1]
			local segment = endDistance - startDistance
			local t = segment > 1e-6 and (d - startDistance) / segment or 0
			local direction = b - a
			if direction.Magnitude < 1e-6 then
				direction = Vector3.new(0, 0, -1)
			end
			return a:Lerp(b, t), direction.Unit
		end
	end
	return loop.points[1], Vector3.new(0, 0, -1)
end

-------------------------------------------------------------------------------
-- Spawning
-------------------------------------------------------------------------------

local function getOrCreateFolder(parent: Instance, name: string): Instance
	local existing = parent:FindFirstChild(name)
	if existing then
		return existing
	end
	local created = Instance.new("Folder")
	created.Name = name
	created.Parent = parent
	return created
end

local function ensureFolder(): Instance?
	local camera = Workspace.CurrentCamera
	if not camera then
		return nil
	end
	local fx = getOrCreateFolder(camera, "ClientFX")
	if not npcFolder or npcFolder.Parent ~= fx then
		npcFolder = getOrCreateFolder(fx, "NPCs")
	end
	return npcFolder
end

local function placeFigure(figure: Figure, position: Vector3, direction: Vector3)
	local flat = MathUtil.flatten(direction)
	if flat.Magnitude < 1e-4 then
		flat = Vector3.new(0, 0, -1)
	end
	local origin = position + Vector3.new(0, CityLifeController.ROOT_HEIGHT, 0)
	figure.root.CFrame = CFrame.lookAt(origin, origin + flat.Unit)
end

local function spawnPedestrians(folder: Instance)
	local layout = ctx.layout
	local paths = layout and layout.pedestrianPaths or {}
	local loops = {}
	for _, path in ipairs(paths) do
		local loop = buildLoop(path.points)
		if loop then
			table.insert(loops, loop)
		end
	end
	if #loops == 0 then
		return
	end
	local count = math.min(CityLifeController.MAX_PEDESTRIANS, #loops * 3)
	for index = 1, count do
		local loop = loops[(index - 1) % #loops + 1]
		local figure = CityLifeController.BuildFigure(index * 11 + 3, "Pedestrian")
		local walker = {
			figure = figure,
			loop = loop,
			distance = rng:NextNumber(0, loop.total),
			speed = rng:NextNumber(CityLifeController.MIN_SPEED, CityLifeController.MAX_SPEED),
			phase = rng:NextNumber(0, math.pi * 2),
			hidden = false,
			lastPosition = nil,
		}
		local position, direction = sampleLoop(loop, walker.distance)
		placeFigure(figure, position, direction)
		walker.lastPosition = position
		figure.model.Parent = folder
		table.insert(walkers, walker)
	end
end

local function spawnIdlers(folder: Instance)
	local layout = ctx.layout
	if not layout then
		return
	end
	local y = groundY()
	-- Customers near four destinations spread across the list.
	local destinations = layout.destinations or {}
	if #destinations > 0 then
		local step = math.max(1, math.floor(#destinations / CityLifeController.MAX_CUSTOMERS))
		local placed = 0
		local index = 1
		while placed < CityLifeController.MAX_CUSTOMERS and index <= #destinations do
			local destination = destinations[index]
			local arrival = destination.arrivalPoint
			local door = destination.door
			if arrival and door then
				local baseY = destination.building and destination.building.baseY or y
				local position = Vector3.new(arrival.x, baseY, arrival.z)
				local facing = Vector3.new(door.x - arrival.x, 0, door.z - arrival.z)
				local sideways = Vector3.new(-facing.Z, 0, facing.X)
				if sideways.Magnitude > 1e-4 then
					position += sideways.Unit * 3
				end
				local figure = CityLifeController.BuildFigure(placed * 5 + 1, "Customer")
				placeFigure(figure, position, facing)
				figure.model.Parent = folder
				table.insert(idlers, { figure = figure, seed = placed, hidden = false, position = position })
				placed += 1
			end
			index += step
		end
	end
	-- Workers at the first depot plots (near the sign post at the front-left corner).
	local plots = layout.depotPlots or {}
	for index = 1, math.min(CityLifeController.MAX_WORKERS, #plots) do
		local plot = plots[index]
		local facing = plot.facing or { x = 0, z = -1 }
		local forward = Vector3.new(facing.x, 0, facing.z)
		if forward.Magnitude < 1e-4 then
			forward = Vector3.new(0, 0, -1)
		end
		forward = forward.Unit
		local right = Vector3.new(-forward.Z, 0, forward.X)
		local position = Vector3.new(plot.x, y, plot.z) + forward * ((plot.d or 30) / 2 - 8) - right * ((plot.w or 40) / 2 - 10)
		local figure = CityLifeController.BuildFigure(index * 13, "Worker")
		placeFigure(figure, position, forward)
		figure.model.Parent = folder
		table.insert(idlers, { figure = figure, seed = index + 10, hidden = false, position = position })
	end
end

function CityLifeController.Spawn()
	if spawned then
		return
	end
	local folder = ensureFolder()
	if not folder then
		return
	end
	spawned = true
	spawnPedestrians(folder)
	spawnIdlers(folder)
end

function CityLifeController.GetCounts(): (number, number)
	return #walkers, #idlers
end

-------------------------------------------------------------------------------
-- Update
-------------------------------------------------------------------------------

local function setHidden(entry, hidden: boolean, folder: Instance)
	if entry.hidden == hidden then
		return
	end
	entry.hidden = hidden
	entry.figure.model.Parent = if hidden then nil else folder
end

local function update(dt: number)
	local folder = ensureFolder()
	if not folder then
		return
	end
	local camera = Workspace.CurrentCamera
	local viewpoint = camera and camera.CFrame.Position or Vector3.zero
	local range = CityLifeController.ACTIVE_RANGE
	local now = os.clock()

	for _, walker in ipairs(walkers) do
		local reference = walker.lastPosition or viewpoint
		local far = (reference - viewpoint).Magnitude > range
		setHidden(walker, far, folder)
		if not far then
			walker.distance = (walker.distance + walker.speed * dt) % walker.loop.total
			walker.phase += walker.speed * dt * 1.6
			local position, direction = sampleLoop(walker.loop, walker.distance)
			walker.lastPosition = position
			placeFigure(walker.figure, position, direction)
			applyWalkPose(walker.figure, walker.phase)
		end
	end

	for _, idler in ipairs(idlers) do
		local far = (idler.position - viewpoint).Magnitude > range
		setHidden(idler, far, folder)
		if not far then
			applyIdlePose(idler.figure, now, idler.seed)
		end
	end
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

function CityLifeController.Init(context)
	ctx = context
end

function CityLifeController.Start()
	task.delay(CityLifeController.SPAWN_DELAY, function()
		local ok, err = pcall(CityLifeController.Spawn)
		if not ok then
			warn("[CityLifeController] spawn failed: " .. tostring(err))
		end
	end)

	RunService.Heartbeat:Connect(function(dt)
		if not spawned then
			return
		end
		accumulator += dt
		if accumulator >= CityLifeController.UPDATE_INTERVAL then
			local elapsed = accumulator
			accumulator = 0
			local ok, err = pcall(update, elapsed)
			if not ok then
				warn("[CityLifeController] update failed: " .. tostring(err))
			end
		end
	end)
end

return CityLifeController
