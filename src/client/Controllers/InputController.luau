--!nonstrict
-- InputController: binds every InputActions binding through ContextActionService (keyboard,
-- gamepad and touch buttons), exposes Pressed/Released signals, IsDown, drive input from the
-- VehicleSeat (ThrottleFloat / SteerFloat) plus gamepad R2 throttle override and the Brake action,
-- device detection (ClientState.device) and menu gating (no drive input while a modal is open).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContextActionService = game:GetService("ContextActionService")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Util = Shared:WaitForChild("Util")
local Signal = require(Util:WaitForChild("Signal"))
local InputActions = require(Shared:WaitForChild("InputActions"))

local InputController = {}

InputController.RECOVER_HOLD_TIME = 1 -- seconds the Recover action must be held
-- Brake shares Space with the PlayerModule jump action, which is bound at ContextActionPriority
-- Default (2000, the same value InputActions uses). Equal priorities resolve by binding order, and a
-- jump while seated ejects the rider, so Brake is bound above it.
InputController.BRAKE_PRIORITY = 3000 -- Enum.ContextActionPriority.High.Value
-- Gamepad jump (ButtonA) would likewise eject the rider; it is swallowed while Driving only.
InputController.JUMP_GUARD_ACTION = "DDC_JumpGuard"
InputController.JUMP_GUARD_KEYS = { Enum.KeyCode.ButtonA }
InputController.KEY_THROTTLE_FORWARD = { Enum.KeyCode.W, Enum.KeyCode.Up }
InputController.KEY_THROTTLE_BACK = { Enum.KeyCode.S, Enum.KeyCode.Down }
InputController.KEY_STEER_LEFT = { Enum.KeyCode.A, Enum.KeyCode.Left }
InputController.KEY_STEER_RIGHT = { Enum.KeyCode.D, Enum.KeyCode.Right }
InputController.Pressed = Signal.new() -- (actionName)
InputController.Released = Signal.new() -- (actionName)
InputController.DeviceChanged = Signal.new() -- (device)

-- Touch button positions inside ContextActionService's lower-right button area. The default
-- jump button sits in the bottom-right corner and the thumbstick on the left, so the cluster
-- stays above/left of the jump button.
local TOUCH_POSITIONS = {
	[InputActions.Names.Brake] = UDim2.new(0.52, 0, 0.52, 0),
	[InputActions.Names.Interact] = UDim2.new(0.12, 0, 0.3, 0),
	[InputActions.Names.MountDismount] = UDim2.new(0.52, 0, 0.1, 0),
	[InputActions.Names.Recover] = UDim2.new(0.12, 0, 0.72, 0),
	[InputActions.Names.NextStop] = UDim2.new(0.3, 0, 0.72, 0),
	[InputActions.Names.Horn] = UDim2.new(0.3, 0, 0.1, 0),
}

local ctx = nil
local down: { [string]: boolean } = {}
local visibleActions: { [string]: boolean } = {}
local bound: { [string]: boolean } = {}
local recoverHoldToken = 0
local device = "Keyboard"

local function uiController()
	return ctx and ctx.controllers and ctx.controllers.UIController or nil
end

local function isDriving(): boolean
	local vehicle = ctx and ctx.state.get("vehicle")
	return vehicle ~= nil and vehicle.state == "Driving"
end

-------------------------------------------------------------------------------
-- Device detection
-------------------------------------------------------------------------------

local function deviceForInputType(inputType: Enum.UserInputType): string?
	local name = inputType.Name
	if name == "Touch" then
		return "Touch"
	elseif string.sub(name, 1, 7) == "Gamepad" then
		return "Gamepad"
	elseif name == "Keyboard" or string.sub(name, 1, 5) == "Mouse" or name == "TextInput" then
		return "Keyboard"
	end
	return nil
end

local function setDevice(newDevice: string)
	if newDevice == device then
		return
	end
	device = newDevice
	if ctx then
		ctx.state.set("device", newDevice)
	end
	InputController.DeviceChanged:Fire(newDevice)
end

local function detectInitialDevice(): string
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		return "Touch"
	elseif UserInputService.GamepadEnabled and not UserInputService.KeyboardEnabled then
		return "Gamepad"
	end
	local lastOk, last = pcall(function()
		return UserInputService:GetLastInputType()
	end)
	if lastOk and last then
		return deviceForInputType(last) or "Keyboard"
	end
	return "Keyboard"
end

function InputController.IsTouch(): boolean
	return device == "Touch"
end

function InputController.IsGamepad(): boolean
	return device == "Gamepad"
end

function InputController.GetDevice(): string
	return device
end

-------------------------------------------------------------------------------
-- Action bindings
-------------------------------------------------------------------------------

function InputController.IsDown(name: string): boolean
	return down[name] == true
end

local function fireRecoverIfHeld()
	recoverHoldToken += 1
	local token = recoverHoldToken
	task.delay(InputController.RECOVER_HOLD_TIME, function()
		if token == recoverHoldToken and down[InputActions.Names.Recover] then
			InputController.Pressed:Fire(InputActions.Names.Recover)
		end
	end)
end

local function handleAction(actionName: string, state: Enum.UserInputState, _input: InputObject)
	if state == Enum.UserInputState.Begin then
		if down[actionName] then
			return Enum.ContextActionResult.Sink
		end
		down[actionName] = true
		if actionName == InputActions.Names.Recover then
			fireRecoverIfHeld()
		else
			InputController.Pressed:Fire(actionName)
		end
	elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
		if not down[actionName] then
			return Enum.ContextActionResult.Pass
		end
		down[actionName] = nil
		InputController.Released:Fire(actionName)
	else
		return Enum.ContextActionResult.Pass
	end
	-- Brake shares Space with jump: only swallow it while driving so jumping on foot still works.
	if actionName == InputActions.Names.Brake and not isDriving() then
		return Enum.ContextActionResult.Pass
	end
	return Enum.ContextActionResult.Sink
end

local function applyTouchVisibility(name: string)
	local okButton, button = pcall(function()
		return ContextActionService:GetButton(name)
	end)
	if okButton and button then
		local visible = visibleActions[name]
		if visible == nil then
			visible = true
		end
		button.Visible = visible
	end
end

local function bindAll()
	for _, binding in ipairs(InputActions.Bindings) do
		local keys = {}
		for _, key in ipairs(binding.keyboard) do
			table.insert(keys, key)
		end
		for _, key in ipairs(binding.gamepad) do
			table.insert(keys, key)
		end
		local priority = binding.priority
		if binding.name == InputActions.Names.Brake then
			priority = math.max(priority, InputController.BRAKE_PRIORITY)
		end
		local okBind, err = pcall(function()
			ContextActionService:BindActionAtPriority(binding.name, handleAction, binding.touchButton, priority, table.unpack(keys))
		end)
		if not okBind then
			warn("[InputController] failed to bind " .. binding.name .. ": " .. tostring(err))
		else
			bound[binding.name] = true
			if binding.touchButton then
				pcall(function()
					ContextActionService:SetTitle(binding.name, binding.title)
					ContextActionService:SetDescription(binding.name, binding.description)
					local position = TOUCH_POSITIONS[binding.name]
					if position then
						ContextActionService:SetPosition(binding.name, position)
					end
				end)
				applyTouchVisibility(binding.name)
			end
		end
	end
end

-- Sinks the gamepad jump button while driving so pressing it does not unseat the rider.
local function bindJumpGuard()
	local okBind, err = pcall(function()
		ContextActionService:BindActionAtPriority(InputController.JUMP_GUARD_ACTION, function(_, _state, _input)
			if isDriving() then
				return Enum.ContextActionResult.Sink
			end
			return Enum.ContextActionResult.Pass
		end, false, InputController.BRAKE_PRIORITY, table.unpack(InputController.JUMP_GUARD_KEYS))
	end)
	if not okBind then
		warn("[InputController] failed to bind the jump guard: " .. tostring(err))
	end
end

-- Shows or hides the touch button of an action (no-op on devices without touch buttons).
function InputController.SetActionVisible(name: string, visible: boolean)
	visibleActions[name] = visible == true
	if bound[name] then
		applyTouchVisibility(name)
	end
end

function InputController.IsActionVisible(name: string): boolean
	local visible = visibleActions[name]
	if visible == nil then
		return true
	end
	return visible
end

-------------------------------------------------------------------------------
-- Drive input
-------------------------------------------------------------------------------

local function localSeat(): VehicleSeat?
	local player = Players.LocalPlayer
	local character = player and player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local seat = humanoid and humanoid.SeatPart
	if seat and seat:IsA("VehicleSeat") then
		return seat
	end
	return nil
end

local function anyKeyDown(keys: { Enum.KeyCode }): boolean
	for _, key in ipairs(keys) do
		local ok, isDown = pcall(function()
			return UserInputService:IsKeyDown(key)
		end)
		if ok and isDown then
			return true
		end
	end
	return false
end

-- Fallback drive input when the seat floats stay at zero (the seat is kept Disabled by the server
-- while Driving; whether the engine still feeds ThrottleFloat/SteerFloat then is unverified).
-- Keyboard keys first, then the gamepad left stick, then the humanoid's camera-relative
-- MoveDirection projected on the chassis axes.
local function fallbackDriveInput(seat: VehicleSeat?): (number, number)
	local throttle, steer = 0, 0
	local okFocus, focused = pcall(function()
		return UserInputService:GetFocusedTextBox()
	end)
	if okFocus and focused ~= nil then
		return 0, 0 -- typing in chat must not drive the vehicle
	end
	if anyKeyDown(InputController.KEY_THROTTLE_FORWARD) then
		throttle += 1
	end
	if anyKeyDown(InputController.KEY_THROTTLE_BACK) then
		throttle -= 1
	end
	if anyKeyDown(InputController.KEY_STEER_RIGHT) then
		steer += 1
	end
	if anyKeyDown(InputController.KEY_STEER_LEFT) then
		steer -= 1
	end
	if throttle ~= 0 or steer ~= 0 then
		return throttle, steer
	end
	if UserInputService.GamepadEnabled then
		local okState, states = pcall(function()
			return UserInputService:GetGamepadState(Enum.UserInputType.Gamepad1)
		end)
		if okState and type(states) == "table" then
			for _, input in ipairs(states) do
				if input.KeyCode == Enum.KeyCode.Thumbstick1 and input.Position then
					local x, y = input.Position.X, input.Position.Y
					if math.abs(x) > 0.15 then
						steer = x
					end
					if math.abs(y) > 0.15 then
						throttle = y
					end
				end
			end
		end
		if throttle ~= 0 or steer ~= 0 then
			return throttle, steer
		end
	end
	local player = Players.LocalPlayer
	local character = player and player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local move = humanoid and humanoid.MoveDirection or nil
	if seat and typeof(move) == "Vector3" and move.Magnitude > 0.05 then
		local cf = seat.CFrame
		local forward = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
		if forward.Magnitude > 1e-3 then
			forward = forward.Unit
			local right = Vector3.new(-forward.Z, 0, forward.X)
			throttle = move:Dot(forward)
			steer = move:Dot(right)
		end
	end
	return throttle, steer
end

-- Returns throttle, steer in [-1, 1] and brake. Everything is zero + brake while a modal is open.
function InputController.GetDriveInput(): (number, number, boolean)
	local ui = uiController()
	if ui and type(ui.IsModalOpen) == "function" then
		local okModal, modal = pcall(ui.IsModalOpen)
		if okModal and modal then
			return 0, 0, true
		end
	end

	local throttle, steer = 0, 0
	local seat = localSeat()
	if seat then
		throttle = tonumber(seat.ThrottleFloat) or 0
		steer = tonumber(seat.SteerFloat) or 0
	end
	if throttle == 0 and steer == 0 then
		throttle, steer = fallbackDriveInput(seat)
	end

	-- Gamepad R2 acts as an analogue throttle override.
	if device == "Gamepad" or UserInputService.GamepadEnabled then
		local okState, states = pcall(function()
			return UserInputService:GetGamepadState(Enum.UserInputType.Gamepad1)
		end)
		if okState and type(states) == "table" then
			for _, input in ipairs(states) do
				if input.KeyCode == Enum.KeyCode.ButtonR2 then
					local amount = input.Position and input.Position.Z or 0
					if amount > 0.05 then
						throttle = math.max(throttle, math.min(amount, 1))
					end
				end
			end
		end
	end

	throttle = math.clamp(throttle, -1, 1)
	steer = math.clamp(steer, -1, 1)
	return throttle, steer, down[InputActions.Names.Brake] == true
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

function InputController.Init(context)
	ctx = context
	device = detectInitialDevice()
	ctx.state.set("device", device)
end

function InputController.Start()
	bindAll()
	bindJumpGuard()

	UserInputService.LastInputTypeChanged:Connect(function(inputType)
		local detected = deviceForInputType(inputType)
		if detected then
			setDevice(detected)
		end
	end)
	UserInputService.GamepadConnected:Connect(function()
		if not UserInputService.KeyboardEnabled then
			setDevice("Gamepad")
		end
	end)

	-- Release everything when the window loses focus so no action sticks.
	UserInputService.WindowFocusReleased:Connect(function()
		for name in pairs(down) do
			down[name] = nil
			InputController.Released:Fire(name)
		end
	end)

	-- Touch prompts: the on-screen prompt re-fires the action it represents.
	local ui = uiController()
	if ui and ui.PromptActivated and type(ui.PromptActivated.Connect) == "function" then
		ui.PromptActivated:Connect(function(actionName)
			if type(actionName) == "string" then
				InputController.Pressed:Fire(actionName)
			end
		end)
	end

	-- Brake button only matters while driving.
	ctx.state.onChange("vehicle", function(vehicle)
		local driving = vehicle ~= nil and vehicle.state == "Driving"
		InputController.SetActionVisible(InputActions.Names.Brake, driving)
	end)
end

return InputController
