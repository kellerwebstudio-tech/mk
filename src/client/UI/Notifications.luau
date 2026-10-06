--!nonstrict
-- Notifications: stacked toast messages (top-right column). Each toast shows a text prefix for its
-- kind ("OK", "!", "X", "i") so the meaning never depends on colour alone, and expires on its own.


local UIKit = require(script.Parent:WaitForChild("UIKit"))

local Notifications = {}

Notifications.DEFAULT_DURATION = 4
Notifications.MAX_VISIBLE = 5
Notifications.WIDTH = 340
Notifications.MIN_WIDTH = 200

local container: any = nil
local toasts: { Frame } = {}
local serial = 0

function Notifications.Mount(parent: Instance, ctx: any): Frame
	container = UIKit.panel(parent, {
		name = "Notifications",
		transparency = 1,
		corner = false,
		size = UDim2.new(0, Notifications.WIDTH, 0, 320),
		position = UDim2.new(1, -8, 0, 128),
		anchor = Vector2.new(1, 0),
		zindex = 5,
	})
	UIKit.listLayout(container, "Vertical", 6, { halign = "Right" })
	return container
end

-- Column width in design units (toasts are full-width children). UIController narrows it on phone
-- viewports so the column never crosses the top-centre results / tutorial stack.
function Notifications.SetWidth(width: number)
	if not container then
		return
	end
	local clamped = math.clamp(math.floor(tonumber(width) or Notifications.WIDTH), Notifications.MIN_WIDTH, Notifications.WIDTH)
	container.Size = UDim2.new(0, clamped, 0, 320)
end

function Notifications.GetContainer(): Frame?
	return container
end

local function removeToast(frame: Frame)
	for index, candidate in ipairs(toasts) do
		if candidate == frame then
			table.remove(toasts, index)
			break
		end
	end
	if frame.Parent then
		frame:Destroy()
	end
end

-- Adds a toast; returns the frame.
function Notifications.Push(text: string, kind: string?, duration: number?): Frame?
	if not container then
		return nil
	end
	kind = kind or "info"
	serial += 1
	local color = UIKit.kindColor(kind)
	local frame = UIKit.panel(container, {
		name = "Toast_" .. serial,
		color = UIKit.Theme.panel,
		transparency = 0.08,
		size = UDim2.new(1, 0, 0, 52),
		corner = 10,
		layoutOrder = serial,
		stroke = color,
	})
	frame:SetAttribute("Kind", kind)
	UIKit.label(frame, UIKit.KindPrefix[kind] or "i", {
		name = "Prefix",
		bg = color,
		color = UIKit.Theme.textOnAccent,
		bold = true,
		align = "Center",
		size = UDim2.new(0, 36, 0, 36),
		position = UDim2.new(0, 8, 0.5, 0),
		anchor = Vector2.new(0, 0.5),
		maxSize = 18,
		corner = 8,
	})
	UIKit.label(frame, text, {
		name = "Text",
		size = UDim2.new(1, -56, 1, -8),
		position = UDim2.new(0, 50, 0, 4),
		maxSize = 18,
	})
	table.insert(toasts, frame)

	-- Oldest toasts leave first when the stack overflows.
	while #toasts > Notifications.MAX_VISIBLE do
		removeToast(toasts[1])
	end

	local lifetime = tonumber(duration) or Notifications.DEFAULT_DURATION
	task.delay(lifetime, function()
		if frame.Parent then
			removeToast(frame)
		end
	end)
	return frame
end

function Notifications.Count(): number
	return #toasts
end

function Notifications.Clear()
	for index = #toasts, 1, -1 do
		removeToast(toasts[index])
	end
end

return Notifications
