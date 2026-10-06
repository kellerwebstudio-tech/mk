--!nonstrict
-- TutorialController: watches ClientState.tutorial and feeds the tutorial banner
-- (UIController.SetTutorial). The server sends title/body/hint with TutorialUpdated; a local table
-- (matching docs/ARCHITECTURE.md 5.11) fills in missing texts. Dismissable steps (0, 6, 8, 9)
-- advance through AdvanceTutorial when the player presses Continue.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")

local TutorialController = {}

TutorialController.DISMISSABLE = { [0] = true, [6] = true, [8] = true, [9] = true }

TutorialController.TEXTS = {
	[0] = { title = "Welcome to Delivery Dash City", body = "You're a courier. Orders appear on your Dash app; pick them up at the business and ride them to the customer.", hint = "Tap Continue" },
	[1] = { title = "Your first order", body = "Slice Street Pizza has a pizza waiting. Open the order board and accept it.", hint = "Open Orders and press Accept" },
	[2] = { title = "Get on your bike", body = "Your courier bicycle is parked nearby. Walk up to it and hop on.", hint = "Press Ride next to the bike" },
	[3] = { title = "Ride to Slice Street", body = "Follow the route markers to the pizzeria. Alleys and bike paths are bicycle-only shortcuts.", hint = "Follow the glowing markers" },
	[4] = { title = "Collect the order", body = "Stop at the counter and grab the pizza.", hint = "Press Interact at the counter" },
	[5] = { title = "Deliver it", body = "Ride to the customer's door and hand it over before it gets cold.", hint = "Press Interact at the door" },
	[6] = { title = "You got paid!", body = "Base pay plus a tip for being quick. Cash buys upgrades; reputation unlocks new businesses and vehicles.", hint = "Tap Continue" },
	[7] = { title = "Second delivery", body = "Another order is up. Try a different route this time: the alley shortcut is bicycle-only.", hint = "Accept and deliver the order" },
	[8] = { title = "First upgrade", body = "Open the shop and buy Basket I to carry an extra order at once.", hint = "Open the Menu, then Upgrades" },
	[9] = { title = "You're ready", body = "The city is yours. Deliver more to unlock new businesses, the scooter, contracts and your own depot.", hint = "Tap Continue to finish" },
}

local ctx = nil
local currentStep: number? = nil
local advancing = false
local shownSpec = nil

local function ui()
	return ctx and ctx.controllers and ctx.controllers.UIController or nil
end

-- Builds the banner spec for a tutorial state (nil when completed or absent).
function TutorialController.SpecFor(tutorial: any)
	if type(tutorial) ~= "table" or tutorial.completed then
		return nil
	end
	local step = tonumber(tutorial.step) or 0
	local fallback = TutorialController.TEXTS[step] or TutorialController.TEXTS[0]
	local hint = tutorial.hint
	if type(hint) ~= "string" or hint == "" then
		hint = fallback.hint
	end
	return {
		step = step,
		title = (type(tutorial.title) == "string" and tutorial.title ~= "") and tutorial.title or fallback.title,
		body = (type(tutorial.body) == "string" and tutorial.body ~= "") and tutorial.body or fallback.body,
		hint = hint,
		dismissable = TutorialController.DISMISSABLE[step] == true,
	}
end

function TutorialController.GetCurrentSpec()
	return shownSpec
end

function TutorialController.IsDismissable(step: number): boolean
	return TutorialController.DISMISSABLE[step] == true
end

local function show(spec)
	shownSpec = spec
	local controller = ui()
	if controller and type(controller.SetTutorial) == "function" then
		local ok, err = pcall(controller.SetTutorial, spec)
		if not ok then
			warn("[TutorialController] SetTutorial failed: " .. tostring(err))
		end
	end
end

-- Continue pressed: only dismissable steps are advanced by the client.
function TutorialController.Continue()
	local step = currentStep
	if step == nil or advancing or not TutorialController.DISMISSABLE[step] then
		return
	end
	advancing = true
	task.spawn(function()
		local ok, result = pcall(function()
			return ctx.remotes.getFunction("AdvanceTutorial"):InvokeServer(step)
		end)
		advancing = false
		if not ok then
			warn("[TutorialController] AdvanceTutorial failed: " .. tostring(result))
		elseif type(result) == "table" and result.ok == false then
			warn("[TutorialController] AdvanceTutorial rejected: " .. tostring(result.message or result.error))
		end
	end)
end

function TutorialController.Init(context)
	ctx = context
end

function TutorialController.Start()
	ctx.state.onChange("tutorial", function(tutorial)
		local spec = TutorialController.SpecFor(tutorial)
		currentStep = spec and spec.step or nil
		show(spec)
	end)

	local controller = ui()
	if controller and controller.TutorialContinue and type(controller.TutorialContinue.Connect) == "function" then
		controller.TutorialContinue:Connect(function()
			TutorialController.Continue()
		end)
	end
end

return TutorialController
