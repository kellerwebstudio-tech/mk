--!nonstrict
-- ResultsToast: delivery results card (base, tip, total, rep, timeliness, new record) shown in the
-- top-centre stack and auto-dismissed after 6 seconds.

local UIKit = require(script.Parent:WaitForChild("UIKit"))

local ResultsToast = {}

ResultsToast.DURATION = 6

local frame: any = nil
local lines: { [string]: any } = {}
local showToken = 0

function ResultsToast.Mount(parent: Instance, ctx: any): Frame
	frame = UIKit.panel(parent, {
		name = "ResultsToast",
		color = UIKit.Theme.panel,
		transparency = 0.06,
		size = UDim2.new(0.9, 0, 0, 230),
		corner = 12,
		stroke = UIKit.Theme.success,
		visible = false,
		layoutOrder = 2,
	})
	UIKit.padding(frame, 10)
	UIKit.listLayout(frame, "Vertical", 3)

	lines.title = UIKit.label(frame, "Delivered!", { name = "Title", bold = true, color = UIKit.Theme.success, size = UDim2.new(1, 0, 0, 28), maxSize = 24, layoutOrder = 1 })
	lines.subtitle = UIKit.label(frame, "", { name = "Subtitle", color = UIKit.Theme.textDim, size = UDim2.new(1, 0, 0, 20), maxSize = 16, layoutOrder = 2 })
	lines.base = UIKit.statLine(frame, "Base pay", "$0", { name = "Base", layoutOrder = 3 })
	lines.tip = UIKit.statLine(frame, "Tip", "$0", { name = "Tip", layoutOrder = 4 })
	lines.total = UIKit.statLine(frame, "Total", "$0", { name = "Total", layoutOrder = 5, bold = true, valueColor = UIKit.Theme.accent, height = 26, maxSize = 20 })
	lines.rep = UIKit.statLine(frame, "Reputation", "+0", { name = "Rep", layoutOrder = 6 })
	lines.timeliness = UIKit.statLine(frame, "Timeliness", "", { name = "Timeliness", layoutOrder = 7 })
	lines.record = UIKit.label(frame, "", { name = "Record", bold = true, color = UIKit.Theme.warning, size = UDim2.new(1, 0, 0, 22), maxSize = 16, align = "Center", layoutOrder = 8 })
	return frame
end

local function timelinessText(payout: any): (string, Color3)
	local factor = tonumber(payout.timelinessFactor) or 1
	local late = tonumber(payout.lateSeconds) or 0
	if late > 0 then
		return string.format("Late by %s (tip x%.0f%%)", UIKit.formatSeconds(late), factor * 100), UIKit.Theme.warning
	end
	if factor >= 1 then
		return "On time (full tip)", UIKit.Theme.success
	end
	return string.format("Tip x%.0f%%", factor * 100), UIKit.Theme.textDim
end

function ResultsToast.Show(payout: any, order: any)
	if not frame or type(payout) ~= "table" then
		return
	end
	local orderLabel = ""
	if type(order) == "table" then
		orderLabel = string.format("%s -> %s", UIKit.businessShortName(order.businessId or ""), tostring(order.itemLabel or order.destinationId or ""))
	end
	lines.subtitle.Text = orderLabel
	lines.base.value.Text = UIKit.formatCash(payout.base)
	lines.tip.value.Text = UIKit.formatCash(payout.tip)
	lines.total.value.Text = UIKit.formatCash(payout.total)
	local rep = tonumber(payout.rep) or 0
	local milestone = tonumber(payout.milestoneRep) or 0
	lines.rep.value.Text = string.format("+%d Rep%s", rep, if milestone > 0 then string.format(" (+%d milestone)", milestone) else "")
	local text, color = timelinessText(payout)
	lines.timeliness.value.Text = text
	lines.timeliness.value.TextColor3 = color
	if payout.newRecord then
		lines.record.Text = "New record time on this route!"
		lines.record.Visible = true
	else
		lines.record.Visible = false
	end
	frame.Visible = true

	showToken += 1
	local token = showToken
	task.delay(ResultsToast.DURATION, function()
		if token == showToken and frame then
			frame.Visible = false
		end
	end)
end

function ResultsToast.Hide()
	showToken += 1
	if frame then
		frame.Visible = false
	end
end

function ResultsToast.GetFrame(): Frame?
	return frame
end

return ResultsToast
