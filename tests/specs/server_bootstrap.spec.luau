--!nonstrict
-- tests/specs/server_bootstrap.spec.luau
-- Runs the real ServerBootstrap script through the harness so a regression in how it finds its
-- sibling folders (Rojo maps src/server to the Folder ServerScriptService.DeliveryDash, with the
-- Script BESIDE Services/Builders) is caught offline instead of hanging a live server.

describe("ServerBootstrap", function()
	beforeEach(function()
		shim.setContext("server")
		shim.isStudio = false -- a published server: DevService must create nothing
	end)

	it("finds the Services folder beside the script, initialises every service and builds the city", function()
		local bootstrap = shim.getInstance("ServerScriptService/DeliveryDash/ServerBootstrap")
		expect(bootstrap).toBeTruthy()
		expect(bootstrap.Parent.Name).toBe("DeliveryDash")
		expect(bootstrap.Parent:FindFirstChild("Services")).toBeTruthy()
		expect(bootstrap:FindFirstChild("Services")).toBeNil() -- the folder is a sibling, never a child

		local thread = shim.runScript(bootstrap)
		shim.advance(1)
		expect(coroutine.status(thread)).toBe("dead")

		local ready = nil
		for _, line in ipairs(shim.prints) do
			if string.find(line, "server ready", 1, true) then
				ready = line
			end
		end
		expect(ready).toBeTruthy()
		-- 13 documented services plus DevService (Studio-only; its Init is a no-op outside Studio).
		expect(ready).toMatch("14 services")
		expect(game:GetService("ReplicatedStorage").Remotes:FindFirstChild("DevCommand")).toBeNil()
		for _, line in ipairs(shim.warnings) do
			expect(line).never.toMatch("%[ServerBootstrap%]")
		end

		local remotes = game:GetService("ReplicatedStorage"):FindFirstChild("Remotes")
		expect(remotes).toBeTruthy()
		expect(remotes:FindFirstChild("GetSnapshot")).toBeTruthy()
		local city = game:GetService("Workspace"):FindFirstChild("City")
		expect(city).toBeTruthy()
		expect(#city:GetChildren()).toBeGreaterThan(0)
		expect(#shim.threadErrors).toBe(0)
	end, { timeout = 60 })
end)
