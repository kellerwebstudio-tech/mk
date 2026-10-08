--!nonstrict
-- EffectsController: subtle client-side effects. Door reaction (door swings open 90 degrees
-- around its hinge edge, speech bubble, small confetti burst and, with embedded people data, a
-- customer figure standing in the doorway for DOOR_CUSTOMER_TIME seconds), pickup reaction (speech
-- bubble over the counter / staff), a floating "+$X" payment popup and a short screen flash on a
-- new record. No speed lines, no camera shake.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Util = Shared:WaitForChild("Util")
local MathUtil = require(Util:WaitForChild("MathUtil"))
local FigureRig = require(Util:WaitForChild("FigureRig"))

local EffectsController = {}

EffectsController.DOOR_OPEN_TIME = 0.45
EffectsController.DOOR_HOLD_TIME = 2
EffectsController.BUBBLE_TIME = 3
EffectsController.CONFETTI_COUNT = 20
EffectsController.POPUP_TIME = 1.6
EffectsController.FLASH_TIME = 0.9
EffectsController.DOOR_CUSTOMER_TIME = 3.5
EffectsController.DOOR_CUSTOMER_OFFSET = 1.2
EffectsController.DOOR_CUSTOMER_NAME = "DoorCustomer"

local ctx = nil
local fxFolder: Instance? = nil
local screenGui: Instance? = nil
local openDoors: { [Instance]: boolean } = {}
local doorCustomers: { [string]: Model } = {}

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
	if not fxFolder or fxFolder.Parent ~= camera then
		fxFolder = getOrCreateFolder(camera, "ClientFX")
	end
	return fxFolder
end

local function ensureScreenGui(): Instance?
	local player = Players.LocalPlayer
	local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return nil
	end
	if screenGui and screenGui.Parent == playerGui then
		return screenGui
	end
	local existing = playerGui:FindFirstChild("DDC_Effects")
	if not existing then
		local created = Instance.new("ScreenGui")
		created.Name = "DDC_Effects"
		created.ResetOnSpawn = false
		created.IgnoreGuiInset = true
		created.DisplayOrder = 50
		created.Parent = playerGui
		existing = created
	end
	screenGui = existing
	return existing
end

local function anchorPart(position: Vector3, name: string): BasePart?
	local folder = ensureFolder()
	if not folder then
		return nil
	end
	local part = Instance.new("Part")
	part.Name = name
	part.Size = Vector3.new(0.2, 0.2, 0.2)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.CastShadow = false
	part.CFrame = CFrame.new(position)
	part.Parent = folder
	return part
end

-- Speech bubble BillboardGui above a world position for `duration` seconds.
function EffectsController.ShowBubble(position: Vector3, text: string, duration: number?)
	local part = anchorPart(position, "SpeechBubble")
	if not part then
		return nil
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = "Bubble"
	gui.Size = UDim2.fromOffset(220, 60)
	gui.StudsOffset = Vector3.new(0, 1, 0)
	gui.AlwaysOnTop = true
	gui.MaxDistance = 120
	gui.LightInfluence = 0
	gui.Parent = part

	local frame = Instance.new("Frame")
	frame.Name = "Panel"
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	frame.BackgroundTransparency = 0.05
	frame.BorderSizePixel = 0
	frame.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 14)
	corner.Parent = frame

	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.Size = UDim2.new(1, -16, 1, -12)
	label.Position = UDim2.fromOffset(8, 6)
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.fromRGB(35, 35, 40)
	label.Font = Enum.Font.Gotham
	label.TextScaled = true
	label.TextWrapped = true
	label.Text = text
	label.Parent = frame

	Debris:AddItem(part, duration or EffectsController.BUBBLE_TIME)
	return part
end

-- Small confetti burst (ParticleEmitter, Emit(count) once).
function EffectsController.Confetti(position: Vector3, count: number?)
	local part = anchorPart(position, "Confetti")
	if not part then
		return nil
	end
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "Emitter"
	emitter.Rate = 0
	emitter.Lifetime = NumberRange.new(0.8, 1.4)
	emitter.Speed = NumberRange.new(8, 14)
	emitter.SpreadAngle = Vector2.new(50, 50)
	emitter.Size = NumberSequence.new(0.35, 0.15)
	emitter.Transparency = NumberSequence.new(0, 1)
	emitter.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 200, 60)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(90, 220, 140)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(80, 160, 255)),
	})
	emitter.Acceleration = Vector3.new(0, -30, 0)
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-180, 180)
	emitter.Parent = part
	pcall(function()
		emitter:Emit(math.min(count or EffectsController.CONFETTI_COUNT, EffectsController.CONFETTI_COUNT))
	end)
	Debris:AddItem(part, 3)
	return part
end

-- Swings a door part open 90 degrees around its hinge edge (-X edge in door space) and back.
function EffectsController.SwingDoor(door: BasePart)
	if openDoors[door] then
		return
	end
	openDoors[door] = true
	local closed = door.CFrame
	local halfWidth = door.Size.X / 2
	local hinge = closed * CFrame.new(-halfWidth, 0, 0)
	local open = hinge * CFrame.Angles(0, math.rad(90), 0) * CFrame.new(halfWidth, 0, 0)
	local info = TweenInfo.new(EffectsController.DOOR_OPEN_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local okOpen = pcall(function()
		TweenService:Create(door, info, { CFrame = open }):Play()
	end)
	if not okOpen then
		openDoors[door] = nil
		return
	end
	task.delay(EffectsController.DOOR_OPEN_TIME + EffectsController.DOOR_HOLD_TIME, function()
		if door.Parent then
			local okClose = pcall(function()
				local tween = TweenService:Create(door, info, { CFrame = closed })
				tween.Completed:Connect(function()
					openDoors[door] = nil
				end)
				tween:Play()
			end)
			if not okClose then
				door.CFrame = closed
				openDoors[door] = nil
			end
		else
			openDoors[door] = nil
		end
	end)
end

local function findDoor(model: Instance): BasePart?
	local door = model:FindFirstChild("Door")
	if door and door:IsA("BasePart") then
		return door
	end
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") and descendant.Name == "Door" then
			return descendant
		end
	end
	return nil
end

-------------------------------------------------------------------------------
-- Door customer (embedded people figure)
-------------------------------------------------------------------------------

local function hashString(text: string): number
	local h = 0
	for i = 1, #text do
		h = (h * 31 + string.byte(text, i)) % 1000003
	end
	return h
end

-- The destination's facing (out of the building): the layout's facing, else the Door part's
-- LookVector, else -Z.
local function destinationFacing(destinationId: string, door: BasePart?): Vector3
	local layout = ctx and (ctx.layout or (ctx.state and type(ctx.state.getLayout) == "function" and ctx.state.getLayout()))
	local destinations = layout and layout.destinations
	if type(destinations) == "table" then
		for _, destination in ipairs(destinations) do
			if type(destination) == "table" and destination.id == destinationId then
				local facing = destination.facing
				if type(facing) == "table" and type(facing.x) == "number" and type(facing.z) == "number" then
					local flat = Vector3.new(facing.x, 0, facing.z)
					if flat.Magnitude > 1e-4 then
						return flat.Unit
					end
				end
				break
			end
		end
	end
	if door then
		local flat = MathUtil.flatten(door.CFrame.LookVector)
		if flat.Magnitude > 1e-4 then
			return flat.Unit
		end
	end
	return Vector3.new(0, 0, -1)
end

-- Places an idle customer rig in the doorway (feet at `feet` + facing * DOOR_CUSTOMER_OFFSET,
-- looking outward) for DOOR_CUSTOMER_TIME seconds. Returns nil without embedded people data.
function EffectsController.ShowDoorCustomer(destinationId: string, feet: Vector3, facing: Vector3): Model?
	local figureId = FigureRig.idForKind("Customer", hashString(destinationId))
	if not FigureRig.has(figureId) then
		return nil
	end
	local folder = ensureFolder()
	if not folder then
		return nil
	end
	local existing = doorCustomers[destinationId]
	if existing and existing.Parent then
		return existing
	end
	local ok, model = pcall(function()
		local rig = FigureRig.build(figureId, { name = EffectsController.DOOR_CUSTOMER_NAME, anchored = true })
		rig:SetAttribute("DestinationId", destinationId)
		FigureRig.setIdlePose(rig)
		FigureRig.place(rig, feet + facing * EffectsController.DOOR_CUSTOMER_OFFSET, facing)
		rig.Parent = folder
		return rig
	end)
	if not ok then
		warn("[EffectsController] door customer failed: " .. tostring(model))
		return nil
	end
	doorCustomers[destinationId] = model
	task.delay(EffectsController.DOOR_CUSTOMER_TIME, function()
		if doorCustomers[destinationId] == model then
			doorCustomers[destinationId] = nil
		end
		model:Destroy()
	end)
	return model
end

-------------------------------------------------------------------------------
-- World events
-------------------------------------------------------------------------------

function EffectsController.DoorReaction(destinationId: string, line: string?)
	local folder = Workspace:FindFirstChild("DeliveryDestinations")
	local model = folder and folder:FindFirstChild(destinationId)
	local door = model and findDoor(model)
	local position: Vector3? = nil
	local feet: Vector3? = nil
	local facing = destinationFacing(destinationId, door)
	if door then
		position = door.Position
		feet = door.Position - Vector3.new(0, door.Size.Y / 2, 0)
		EffectsController.SwingDoor(door)
	else
		feet = ctx.state.getDestinationDoorPosition(destinationId)
		position = feet
		if position then
			position += Vector3.new(0, 3.5, 0)
		end
	end
	if not position then
		return
	end
	EffectsController.ShowBubble(position + Vector3.new(0, 4.5, 0), line or "Thank you!", EffectsController.BUBBLE_TIME)
	EffectsController.Confetti(position + Vector3.new(0, 2, 0), EffectsController.CONFETTI_COUNT)
	if feet then
		EffectsController.ShowDoorCustomer(destinationId, feet, facing)
	end
end

function EffectsController.PickupReaction(businessId: string, line: string?)
	local folder = Workspace:FindFirstChild("PickupLocations")
	local model = folder and folder:FindFirstChild(businessId)
	local position: Vector3? = nil
	if model then
		local staff = model:FindFirstChild("Staff")
		local staffRoot = staff and (staff:FindFirstChild("Head") or staff:FindFirstChild("Root"))
		local counter = model:FindFirstChild("Counter")
		if staffRoot and staffRoot:IsA("BasePart") then
			position = staffRoot.Position + Vector3.new(0, 2, 0)
		elseif counter and counter:IsA("BasePart") then
			position = counter.Position + Vector3.new(0, 4, 0)
		end
	end
	if not position then
		local pickup = ctx.state.getBusinessPickupPosition(businessId)
		if pickup then
			position = pickup + Vector3.new(0, 6, 0)
		end
	end
	if position then
		EffectsController.ShowBubble(position, line or "Order's ready!", EffectsController.BUBBLE_TIME)
	end
end

-- Floating "+$X" popup rising from the player's position.
function EffectsController.PaymentPopup(amount: number)
	local origin = ctx.state.getPlayerPosition()
	if not origin then
		return
	end
	local part = anchorPart(origin + Vector3.new(0, 4, 0), "PaymentPopup")
	if not part then
		return
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = "Popup"
	gui.Size = UDim2.fromOffset(140, 44)
	gui.StudsOffset = Vector3.new(0, 0, 0)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.Parent = part

	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.fromRGB(120, 240, 150)
	label.TextStrokeTransparency = 0.3
	label.TextStrokeColor3 = Color3.fromRGB(10, 40, 20)
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.Text = "+" .. MathUtil.formatCash(amount)
	label.Parent = gui

	local info = TweenInfo.new(EffectsController.POPUP_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	pcall(function()
		TweenService:Create(gui, info, { StudsOffset = Vector3.new(0, 5, 0) }):Play()
		TweenService:Create(label, info, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	end)
	Debris:AddItem(part, EffectsController.POPUP_TIME + 0.2)
end

-- Short full-screen text flash ("NEW RECORD!").
function EffectsController.ScreenFlash(text: string)
	local gui = ensureScreenGui()
	if not gui then
		return
	end
	local label = Instance.new("TextLabel")
	label.Name = "Flash"
	label.Size = UDim2.fromScale(1, 0.18)
	label.Position = UDim2.fromScale(0, 0.28)
	label.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	label.BackgroundTransparency = 0.75
	label.BorderSizePixel = 0
	label.TextColor3 = Color3.fromRGB(255, 210, 60)
	label.TextStrokeTransparency = 0.2
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.Text = text
	label.Parent = gui
	local info = TweenInfo.new(EffectsController.FLASH_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	pcall(function()
		TweenService:Create(label, info, { BackgroundTransparency = 1, TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	end)
	Debris:AddItem(label, EffectsController.FLASH_TIME + 0.1)
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

function EffectsController.Init(context)
	ctx = context
end

function EffectsController.Start()
	ctx.state.WorldEvent:Connect(function(payload)
		if type(payload) ~= "table" then
			return
		end
		local ok, err = pcall(function()
			if payload.kind == "DoorReaction" and type(payload.destinationId) == "string" then
				EffectsController.DoorReaction(payload.destinationId, payload.line)
			elseif payload.kind == "PickupReaction" and type(payload.businessId) == "string" then
				EffectsController.PickupReaction(payload.businessId, payload.line)
			end
		end)
		if not ok then
			warn("[EffectsController] world event failed: " .. tostring(err))
		end
	end)

	ctx.state.OrderEvent:Connect(function(payload)
		if type(payload) ~= "table" or payload.kind ~= "Delivered" then
			return
		end
		local payout = payload.payout
		if type(payout) ~= "table" then
			return
		end
		local ok, err = pcall(function()
			if type(payout.total) == "number" and payout.total > 0 then
				EffectsController.PaymentPopup(payout.total)
			end
			if payout.newRecord then
				EffectsController.ScreenFlash("NEW RECORD!")
			end
		end)
		if not ok then
			warn("[EffectsController] payment effect failed: " .. tostring(err))
		end
	end)
end

return EffectsController
