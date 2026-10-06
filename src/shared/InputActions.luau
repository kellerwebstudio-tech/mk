--!strict
-- Named input actions with default bindings per device. Throttle/steer come from the VehicleSeat
-- (Roblox maps WASD / arrow keys, touch thumbstick and gamepad left stick automatically).

export type ActionBinding = {
	name: string,
	title: string,
	description: string,
	keyboard: { Enum.KeyCode },
	gamepad: { Enum.KeyCode },
	touchButton: boolean,
	priority: number,
}

local InputActions = {}

InputActions.Names = {
	Brake = "DDC_Brake",
	Interact = "DDC_Interact",
	MountDismount = "DDC_MountDismount",
	Recover = "DDC_Recover",
	RecenterCamera = "DDC_RecenterCamera",
	ToggleOrders = "DDC_ToggleOrders",
	ToggleMenu = "DDC_ToggleMenu",
	NextStop = "DDC_NextStop",
	Horn = "DDC_Horn",
}

InputActions.Bindings = {
	{
		name = InputActions.Names.Brake,
		title = "Brake",
		description = "Hold to brake",
		keyboard = { Enum.KeyCode.Space, Enum.KeyCode.LeftShift },
		gamepad = { Enum.KeyCode.ButtonL2, Enum.KeyCode.ButtonB },
		touchButton = true,
		priority = 2000,
	},
	{
		name = InputActions.Names.Interact,
		title = "Interact",
		description = "Collect or deliver an order",
		keyboard = { Enum.KeyCode.E },
		gamepad = { Enum.KeyCode.ButtonX },
		touchButton = true,
		priority = 2000,
	},
	{
		name = InputActions.Names.MountDismount,
		title = "Ride",
		description = "Mount or dismount your vehicle",
		keyboard = { Enum.KeyCode.F },
		gamepad = { Enum.KeyCode.ButtonY },
		touchButton = true,
		priority = 2000,
	},
	{
		name = InputActions.Names.Recover,
		title = "Recover",
		description = "Reset your vehicle to the road (hold)",
		keyboard = { Enum.KeyCode.R },
		gamepad = { Enum.KeyCode.ButtonSelect },
		touchButton = false,
		priority = 2000,
	},
	{
		name = InputActions.Names.RecenterCamera,
		title = "Recenter",
		description = "Recenter the camera behind the vehicle",
		keyboard = { Enum.KeyCode.V },
		gamepad = { Enum.KeyCode.ButtonR3 },
		touchButton = false,
		priority = 2000,
	},
	{
		name = InputActions.Names.ToggleOrders,
		title = "Orders",
		description = "Open the order board",
		keyboard = { Enum.KeyCode.Tab },
		gamepad = { Enum.KeyCode.DPadUp },
		touchButton = false,
		priority = 2000,
	},
	{
		name = InputActions.Names.ToggleMenu,
		title = "Menu",
		description = "Open the main menu",
		keyboard = { Enum.KeyCode.M },
		gamepad = { Enum.KeyCode.ButtonStart },
		touchButton = false,
		priority = 2000,
	},
	{
		name = InputActions.Names.NextStop,
		title = "Next stop",
		description = "Cycle navigation target",
		keyboard = { Enum.KeyCode.Q },
		gamepad = { Enum.KeyCode.DPadRight },
		touchButton = false,
		priority = 2000,
	},
	{
		name = InputActions.Names.Horn,
		title = "Bell",
		description = "Ring your bell / horn",
		keyboard = { Enum.KeyCode.H },
		gamepad = { Enum.KeyCode.ButtonR3 },
		touchButton = false,
		priority = 2000,
	},
} :: { ActionBinding }

-- Glyphs for prompts per device family.
InputActions.Glyphs = {
	Keyboard = {
		[InputActions.Names.Brake] = "Space",
		[InputActions.Names.Interact] = "E",
		[InputActions.Names.MountDismount] = "F",
		[InputActions.Names.Recover] = "R",
		[InputActions.Names.RecenterCamera] = "V",
		[InputActions.Names.ToggleOrders] = "Tab",
		[InputActions.Names.ToggleMenu] = "M",
		[InputActions.Names.NextStop] = "Q",
		[InputActions.Names.Horn] = "H",
	},
	Gamepad = {
		[InputActions.Names.Brake] = "LT",
		[InputActions.Names.Interact] = "X",
		[InputActions.Names.MountDismount] = "Y",
		[InputActions.Names.Recover] = "Back",
		[InputActions.Names.RecenterCamera] = "R3",
		[InputActions.Names.ToggleOrders] = "D-Up",
		[InputActions.Names.ToggleMenu] = "Start",
		[InputActions.Names.NextStop] = "D-Right",
		[InputActions.Names.Horn] = "R3",
	},
	Touch = {
		[InputActions.Names.Brake] = "Tap",
		[InputActions.Names.Interact] = "Tap",
		[InputActions.Names.MountDismount] = "Tap",
		[InputActions.Names.Recover] = "Menu",
		[InputActions.Names.RecenterCamera] = "Menu",
		[InputActions.Names.ToggleOrders] = "Tap",
		[InputActions.Names.ToggleMenu] = "Tap",
		[InputActions.Names.NextStop] = "Tap",
		[InputActions.Names.Horn] = "Tap",
	},
}

return InputActions
