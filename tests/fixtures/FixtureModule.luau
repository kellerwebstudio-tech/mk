--!strict
-- Fixture used by harness.spec.luau: proves `script` injection, service lookup and sibling requires.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fixtures = ReplicatedStorage:WaitForChild("TestFixtures")
local Helper = require(script.Parent.FixtureHelper)

local Module = {}
Module.scriptName = script.Name
Module.parentName = script.Parent.Name
Module.fullName = script:GetFullName()
Module.fixturesFolder = Fixtures
Module.helperValue = Helper.value
Module.loadCount = (_G.fixtureLoadCount or 0) + 1
_G.fixtureLoadCount = Module.loadCount
function Module.double(x: number): number
	return Helper.double(x)
end
return Module
