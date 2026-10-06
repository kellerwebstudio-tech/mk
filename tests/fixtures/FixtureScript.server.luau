--!nonstrict
-- Fixture Script: must NOT run automatically; shim.runScript runs it explicitly.
local Workspace = game:GetService("Workspace")
Workspace:SetAttribute("FixtureScriptRan", true)
Workspace:SetAttribute("FixtureScriptClass", script.ClassName)
task.wait(1)
Workspace:SetAttribute("FixtureScriptFinished", os.clock())
