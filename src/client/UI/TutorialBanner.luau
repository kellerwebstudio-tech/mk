--!nonstrict
-- TutorialBanner: top-centre card with the current tutorial step (title / body / hint) and a
-- Continue button for dismissable steps. Touch friendly (44 px button), controller selectable.

local Signal = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Util"):WaitForChild("Signal"))
local UIKit = require(script.Parent:WaitForChild("UIKit"))

local TutorialBanner = {}

TutorialBanner.Continue = Signal.new()

local frame: any = nil
local stepLabel: any = nil
local titleLabel: any = nil
local bodyLabel: any = nil
local hintLabel: any = nil
local continueButton: any = nil
local currentSpec = nil

function TutorialBanner.Mount(parent: Instance, ctx: any): Frame
	frame = UIKit.panel(parent, {
		name = "TutorialBanner",
		color = UIKit.Theme.panel,
		transparency = 0.06,
		size = UDim2.new(1, 0, 0, 150),
		corner = 12,
		stroke = UIKit.Theme.accent,
		visible = false,
		layoutOrder = 1,
	})
	UIKit.padding(frame, 10)
	UIKit.listLayout(frame, "Vertical", 4)

	local header = UIKit.row(frame, { name = "Header", size = UDim2.new(1, 0, 0, 26), layoutOrder = 1, gap = 8 })
	stepLabel = UIKit.pill(header, "Step 1", { name = "Step", color = UIKit.Theme.accent, textColor = UIKit.Theme.textOnAccent, width = 80, layoutOrder = 1 })
	titleLabel = UIKit.label(header, "", { name = "Title", bold = true, size = UDim2.new(1, -90, 1, 0), maxSize = 22, layoutOrder = 2 })
	bodyLabel = UIKit.label(frame, "", { name = "Body", size = UDim2.new(1, 0, 0, 52), maxSize = 17, valign = "Top", layoutOrder = 2 })
	hintLabel = UIKit.label(frame, "", { name = "Hint", color = UIKit.Theme.accent, size = UDim2.new(1, 0, 0, 22), maxSize = 16, layoutOrder = 3 })
	continueButton = UIKit.primaryButton(frame, "Continue", function()
		TutorialBanner.Continue:Fire()
	end, { name = "ContinueButton", size = UDim2.new(0, 160, 0, UIKit.MIN_HIT), layoutOrder = 4 })
	continueButton.Visible = false
	return frame
end

-- spec = { step, title, body, hint?, dismissable? } or nil to hide.
function TutorialBanner.Set(spec: any)
	currentSpec = spec
	if not frame then
		return
	end
	if type(spec) ~= "table" then
		frame.Visible = false
		return
	end
	stepLabel.Text = "Step " .. tostring((tonumber(spec.step) or 0) + 1)
	titleLabel.Text = tostring(spec.title or "")
	bodyLabel.Text = tostring(spec.body or "")
	hintLabel.Text = if spec.hint and spec.hint ~= "" then "Hint: " .. tostring(spec.hint) else ""
	local dismissable = spec.dismissable == true
	continueButton.Visible = dismissable
	frame.Size = UDim2.new(1, 0, 0, if dismissable then 190 else 140)
	frame.Visible = true
end

function TutorialBanner.GetSpec()
	return currentSpec
end

function TutorialBanner.GetFrame(): Frame?
	return frame
end

function TutorialBanner.GetContinueButton(): TextButton?
	return continueButton
end

return TutorialBanner
