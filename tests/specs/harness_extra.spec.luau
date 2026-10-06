--!nonstrict
-- tests/specs/harness_extra.spec.luau — adversarial probes of the offline harness against
-- hand-computed values and engine semantics that game code relies on.

local function v3(x, y, z) return Vector3.new(x, y, z) end
local HALF_PI = math.pi / 2

describe("Harness extra: CFrame numerics", function()
	it("lookAt matches hand-computed axes and ToWorldSpace composes correctly", function()
		-- looking along -Z is the identity rotation
		local cf = CFrame.lookAt(v3(10, 5, 10), v3(10, 5, 0))
		expect(cf.Position).toEqual(v3(10, 5, 10))
		expect(cf.Rotation).toBeCloseTo(CFrame.identity)
		expect(cf:ToWorldSpace(CFrame.new(1, 2, 3)).Position).toBeCloseTo(v3(11, 7, 13))

		-- looking along +X: Right = +Z, Up = +Y, Look = +X
		local px = CFrame.lookAt(v3(0, 0, 0), v3(10, 0, 0))
		expect(px.RightVector).toBeCloseTo(v3(0, 0, 1))
		expect(px.UpVector).toBeCloseTo(v3(0, 1, 0))
		expect(px.LookVector).toBeCloseTo(v3(1, 0, 0))
		local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = px:GetComponents()
		expect({ x, y, z }).toEqual({ 0, 0, 0 })
		expect(r00).toBeCloseTo(0) expect(r01).toBeCloseTo(0) expect(r02).toBeCloseTo(-1)
		expect(r10).toBeCloseTo(0) expect(r11).toBeCloseTo(1) expect(r12).toBeCloseTo(0)
		expect(r20).toBeCloseTo(1) expect(r21).toBeCloseTo(0) expect(r22).toBeCloseTo(0)
		-- 5 studs "forward" in object space (local -Z) lands at +X in world space
		expect(px:PointToWorldSpace(v3(0, 0, -5))).toBeCloseTo(v3(5, 0, 0))
		expect((px * CFrame.new(2, 0, 0)).Position).toBeCloseTo(v3(0, 0, 2))
		expect(px:VectorToWorldSpace(v3(1, 0, 0))).toBeCloseTo(v3(0, 0, 1))
		-- lookAt +X equals a -90 degree yaw; composing with a +90 degree yaw restores identity
		expect(px).toBeCloseTo(CFrame.Angles(0, -HALF_PI, 0))
		expect(px:ToWorldSpace(CFrame.Angles(0, HALF_PI, 0)).LookVector).toBeCloseTo(v3(0, 0, -1))
		-- object-space of a world point: the world +X point is "ahead" (local -Z)
		expect(px:PointToObjectSpace(v3(7, 0, 0))).toBeCloseTo(v3(0, 0, -7))

		-- pitch up 90 degrees: Look = +Y, Up = +Z
		local up = CFrame.Angles(HALF_PI, 0, 0)
		expect(up.LookVector).toBeCloseTo(v3(0, 1, 0))
		expect(up.UpVector).toBeCloseTo(v3(0, 0, 1))
		expect(up.RightVector).toBeCloseTo(v3(1, 0, 0))

		-- translation then yaw then local forward: (1,2,3) + 4 studs along yaw(90).LookVector (-1,0,0)
		local chain = CFrame.new(1, 2, 3) * CFrame.Angles(0, HALF_PI, 0) * CFrame.new(0, 0, -4)
		expect(chain.Position).toBeCloseTo(v3(-3, 2, 3))

		-- ToObjectSpace is the inverse of ToWorldSpace; Inverse() * cf is identity
		local a = CFrame.new(3, -2, 8) * CFrame.fromOrientation(0.3, 1.2, -0.4)
		local b = CFrame.new(-1, 4, 2) * CFrame.Angles(0.7, -0.2, 2.1)
		expect(a:ToObjectSpace(a:ToWorldSpace(b))).toBeCloseTo(b, 1e-6)
		expect(a:Inverse() * a).toBeCloseTo(CFrame.identity, 1e-6)
		expect(a:PointToObjectSpace(a:PointToWorldSpace(v3(1, 2, 3)))).toBeCloseTo(v3(1, 2, 3), 1e-6)
		local rx, ry, rz = a:ToOrientation()
		expect(rx).toBeCloseTo(0.3, 1e-6) expect(ry).toBeCloseTo(1.2, 1e-6) expect(rz).toBeCloseTo(-0.4, 1e-6)
		-- a rotation matrix stays orthonormal through composition
		local r = a.Rotation * b.Rotation
		expect(r.RightVector:Dot(r.UpVector)).toBeCloseTo(0, 1e-9)
		expect(r.RightVector:Cross(r.UpVector)).toBeCloseTo(-r.LookVector, 1e-9)
		-- lookAt with a custom up vector
		local custom = CFrame.lookAt(v3(0, 0, 0), v3(0, 0, -1), v3(1, 0, 0))
		expect(custom.UpVector).toBeCloseTo(v3(1, 0, 0))
		expect(custom.RightVector).toBeCloseTo(v3(0, -1, 0))
		-- CFrame + Vector3 translates without rotating
		expect((px + v3(1, 1, 1)).Position).toEqual(v3(1, 1, 1))
		expect((px + v3(1, 1, 1)).LookVector).toBeCloseTo(v3(1, 0, 0))
	end)
end)

describe("Harness extra: Model pivots", function()
	it("PivotTo moves every part rigidly and preserves relative transforms", function()
		local model = Instance.new("Model")
		local a = Instance.new("Part") a.Name = "A" a.Size = v3(2, 2, 2) a.CFrame = CFrame.new(0, 0, 0) a.Parent = model
		local b = Instance.new("Part") b.Name = "B" b.Size = v3(1, 1, 1) b.CFrame = CFrame.new(4, 0, 0) * CFrame.Angles(0, 0, math.pi / 4) b.Parent = model
		local folder = Instance.new("Folder") folder.Parent = model
		local c = Instance.new("Part") c.Name = "C" c.CFrame = CFrame.new(0, 3, 0) c.Parent = folder
		model.PrimaryPart = a
		local relB = a.CFrame:ToObjectSpace(b.CFrame)
		local relC = a.CFrame:ToObjectSpace(c.CFrame)

		local target = CFrame.new(10, 0, 0) * CFrame.Angles(0, HALF_PI, 0)
		model:PivotTo(target)
		expect(model:GetPivot()).toBeCloseTo(target, 1e-6)
		expect(a.CFrame).toBeCloseTo(target, 1e-6)
		-- local +X of a yaw(90) frame is world -Z
		expect(b.Position).toBeCloseTo(v3(10, 0, -4), 1e-6)
		expect(c.Position).toBeCloseTo(v3(10, 3, 0), 1e-6)
		expect(a.CFrame:ToObjectSpace(b.CFrame)).toBeCloseTo(relB, 1e-6)
		expect(a.CFrame:ToObjectSpace(c.CFrame)).toBeCloseTo(relC, 1e-6)
		expect((b.Position - a.Position).Magnitude).toBeCloseTo(4, 1e-6)

		-- a second pivot is relative to the current pivot, not the original
		model:PivotTo(CFrame.new(0, 0, 0))
		expect(a.CFrame).toBeCloseTo(CFrame.identity, 1e-6)
		expect(b.CFrame).toBeCloseTo(CFrame.new(4, 0, 0) * CFrame.Angles(0, 0, math.pi / 4), 1e-6)

		-- MoveTo keeps orientation, TranslateBy shifts
		model:PivotTo(target)
		model:MoveTo(v3(1, 2, 3))
		expect(a.Position).toBeCloseTo(v3(1, 2, 3), 1e-6)
		expect(a.CFrame.LookVector).toBeCloseTo(target.LookVector, 1e-6)
		model:TranslateBy(v3(0, 5, 0))
		expect(a.Position).toBeCloseTo(v3(1, 7, 3), 1e-6)

		-- without a PrimaryPart the pivot is the bounding box centre; parts still move rigidly
		local m2 = Instance.new("Model")
		local p1 = Instance.new("Part") p1.Size = v3(2, 2, 2) p1.CFrame = CFrame.new(0, 0, 0) p1.Parent = m2
		local p2 = Instance.new("Part") p2.Size = v3(2, 2, 2) p2.CFrame = CFrame.new(10, 0, 0) p2.Parent = m2
		expect(m2:GetPivot().Position).toBeCloseTo(v3(5, 0, 0), 1e-6)
		m2:PivotTo(CFrame.new(100, 0, 0))
		expect(p1.Position).toBeCloseTo(v3(95, 0, 0), 1e-6)
		expect(p2.Position).toBeCloseTo(v3(105, 0, 0), 1e-6)
		expect(m2:GetPivot().Position).toBeCloseTo(v3(100, 0, 0), 1e-6)
		local _, size = m2:GetBoundingBox()
		expect(size).toBeCloseTo(v3(12, 2, 2), 1e-6)
		-- PivotTo on a BasePart honours PivotOffset
		local lone = Instance.new("Part")
		lone.PivotOffset = CFrame.new(0, 0, -2)
		lone:PivotTo(CFrame.new(10, 10, 10))
		expect(lone.Position).toBeCloseTo(v3(10, 10, 12), 1e-6)
		expect(lone:GetPivot().Position).toBeCloseTo(v3(10, 10, 10), 1e-6)
	end)
end)

describe("Harness extra: seats", function()
	it("Sit then ChangeState(Jumping) unseats and fires the right signals", function()
		local player = shim.addPlayer("Rider", 10)
		local character = shim.spawnCharacter(player)
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		local seat = Instance.new("VehicleSeat")
		seat.CFrame = CFrame.new(20, 2, 0)
		seat.Parent = workspace
		local occupantChanges, seatedEvents, stateChanges = {}, {}, {}
		seat:GetPropertyChangedSignal("Occupant"):Connect(function() occupantChanges[#occupantChanges + 1] = { seat.Occupant } end)
		humanoid.Seated:Connect(function(active, part) table.insert(seatedEvents, { active, part }) end)
		humanoid.StateChanged:Connect(function(_, new) table.insert(stateChanges, new) end)

		seat:Sit(humanoid)
		expect(seat.Occupant).toBe(humanoid)
		expect(humanoid.SeatPart).toBe(seat)
		expect(humanoid.Sit).toBe(true)
		local weld = seat:FindFirstChild("SeatWeld")
		expect(weld).toBeDefined()
		expect(weld.Part0).toBe(seat)
		expect(weld.Part1).toBe(character.HumanoidRootPart)
		expect(humanoid:GetState()).toBe(Enum.HumanoidStateType.Seated)
		expect(#occupantChanges).toBe(1)
		expect(occupantChanges[1][1]).toBe(humanoid)
		expect(seatedEvents[1]).toEqual({ true, seat })
		-- the character was placed on the seat
		expect((character.HumanoidRootPart.Position - seat.Position).Magnitude).toBeLessThan(5)

		humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
		expect(seat.Occupant).toBeNil()
		expect(humanoid.SeatPart).toBeNil()
		expect(humanoid.Sit).toBe(false)
		expect(seat:FindFirstChild("SeatWeld")).toBeNil()
		expect(weld.Parent).toBeNil()
		expect(humanoid:GetState()).toBe(Enum.HumanoidStateType.Jumping)
		expect(#occupantChanges).toBe(2)
		expect(occupantChanges[2][1]).toBeNil()
		expect(stateChanges[#stateChanges]).toBe(Enum.HumanoidStateType.Jumping)
		-- the engine fires Seated(false, nil) when leaving a seat
		expect(#seatedEvents).toBe(2)
		expect(seatedEvents[2][1]).toBe(false)
		expect(seatedEvents[2][2]).toBeNil()

		-- sitting again creates a fresh weld; Sit = false unseats too
		seat:Sit(humanoid)
		expect(seat.Occupant).toBe(humanoid)
		expect(seat:FindFirstChild("SeatWeld")).never.toBe(weld)
		humanoid.Sit = false
		expect(seat.Occupant).toBeNil()
		expect(humanoid:GetState()).toBe(Enum.HumanoidStateType.Running)
		-- a seated humanoid moving to another seat vacates the first
		local seat2 = Instance.new("Seat") seat2.Parent = workspace
		seat:Sit(humanoid)
		seat2:Sit(humanoid)
		expect(seat.Occupant).toBeNil()
		expect(seat2.Occupant).toBe(humanoid)
		expect(humanoid.SeatPart).toBe(seat2)
		-- dead humanoids cannot sit
		humanoid.Health = 0
		expect(seat2.Occupant).toBeNil()
		seat:Sit(humanoid)
		expect(seat.Occupant).toBeNil()
		expect(#shim.warnings).toBe(0)
	end)
end)

describe("Harness extra: scheduler", function()
	it("WaitForChild times out to nil after the virtual clock advances and resumes when the child appears", function()
		local folder = Instance.new("Folder")
		folder.Parent = workspace
		local t0 = os.clock()
		local result = folder:WaitForChild("Missing", 2)
		expect(result).toBeNil()
		expect(os.clock() - t0).toBeCloseTo(2, 1e-6)
		expect(#shim.warnings).toBe(0)

		local got, finishedAt = "pending", nil
		task.spawn(function()
			got = folder:WaitForChild("Later", 10)
			finishedAt = os.clock()
		end)
		expect(got).toBe("pending")
		shim.advance(1)
		expect(got).toBe("pending")
		local child = Instance.new("Part")
		child.Name = "Later"
		child.Parent = folder
		shim.advance(0)
		expect(got).toBe(child)
		expect(finishedAt).toBeCloseTo(t0 + 3, 1e-6)
		-- the timeout for a satisfied wait must not fire later
		shim.advance(15)
		expect(got).toBe(child)
		expect(#shim.threadErrors).toBe(0)
		-- an existing child returns immediately without yielding
		local before = os.clock()
		expect(folder:WaitForChild("Later")).toBe(child)
		expect(os.clock()).toBe(before)
	end)

	it("task.delay/defer/spawn resume in due-time then FIFO order and honour cancel", function()
		local order = {}
		local function mark(tag) return function(...) table.insert(order, tag .. select("#", ...)) end end
		task.delay(0.2, mark("A"), 1, 2)
		task.delay(0.1, mark("B"))
		task.delay(0.1, mark("C"))
		task.defer(mark("D"))
		task.spawn(mark("E"))
		local cancelled = task.delay(0.05, mark("X"))
		task.cancel(cancelled)
		local zero = task.delay(0, mark("Z"))
		expect(order).toEqual({ "E0" })
		expect(typeof(zero)).toBe("thread")
		shim.advance(0)
		expect(order).toEqual({ "E0", "D0", "Z0" })
		shim.advance(0.09)
		expect(order).toEqual({ "E0", "D0", "Z0" })
		shim.advance(0.01)
		expect(order).toEqual({ "E0", "D0", "Z0", "B0", "C0" })
		shim.advance(0.1)
		expect(order).toEqual({ "E0", "D0", "Z0", "B0", "C0", "A2" })
		shim.advance(1)
		expect(#order).toBe(6)
		-- task.wait returns the elapsed virtual time and delayed closures see the advanced clock
		local t0 = os.clock()
		local seenAt
		task.delay(0.5, function() seenAt = os.clock() end)
		local elapsed = task.wait(1)
		expect(elapsed).toBeCloseTo(1, 1e-6)
		expect(os.clock() - t0).toBeCloseTo(1, 1e-6)
		expect(seenAt).toBeCloseTo(t0 + 0.5, 1e-6)
		-- a delayed thread that errors is recorded as a thread error (not raised here)
		expect(#shim.threadErrors).toBe(0)
	end)
end)

describe("Harness extra: DataStore and JSON", function()
	it("UpdateAsync returning nil cancels the write and transforms see copies", function()
		local store = game:GetService("DataStoreService"):GetDataStore("Probe")
		store:SetAsync("k", { cash = 10, list = { 1, 2 } })
		local callsBefore = #shim.datastore.calls
		local calls = 0
		local result = store:UpdateAsync("k", function(old)
			calls += 1
			expect(old.cash).toBe(10)
			old.cash = 999 -- mutating the passed-in copy must not leak
			return nil
		end)
		expect(calls).toBe(1)
		expect(result).toBeNil()
		expect(#shim.datastore.calls).toBe(callsBefore + 1)
		local stored = store:GetAsync("k")
		expect(stored).toEqual({ cash = 10, list = { 1, 2 } })
		expect(shim.datastore.data.Probe.k.cash).toBe(10)

		-- a real update stores a deep copy; later mutation of the returned table does not leak
		local returned = { cash = 42, list = { 3 } }
		local newValue, keyInfo = store:UpdateAsync("k", function(old) return returned end)
		returned.cash = -1
		expect(newValue.cash).toBe(42)
		expect(store:GetAsync("k").cash).toBe(42)
		expect(typeof(keyInfo)).toBe("DataStoreKeyInfo")
		-- GetAsync on a missing key is nil, and a failing call raises before touching data
		expect(store:GetAsync("nope")).toBeNil()
		shim.datastore.failNextCalls = 1
		expect(function() store:UpdateAsync("k", function() return { cash = 0 } end) end).toThrow("simulated")
		expect(store:GetAsync("k").cash).toBe(42)
		-- values that cannot be serialized are rejected
		expect(function() store:SetAsync("bad", { v = Vector3.new() }) end).toThrow()
		expect(function() store:SetAsync("bad", { f = function() end }) end).toThrow()
	end)

	it("JSON decodes nested arrays/objects and unicode escapes, and round-trips", function()
		local http = game:GetService("HttpService")
		local src = '{"a":[1,[2,3],{"b":null,"c":"\\u00e9\\ud83d\\ude00"}],"d":true,"e":-1.5e2,"f":"line\\nbreak\\"q\\\\","g":{},"h":[],"i":0.25}'
		local v = http:JSONDecode(src)
		expect(v.a[1]).toBe(1)
		expect(v.a[2]).toEqual({ 2, 3 })
		expect(v.a[3].b).toBeNil()
		expect(v.a[3].c).toBe("\195\169\240\159\152\128")
		expect(utf8.len(v.a[3].c)).toBe(2)
		expect(v.d).toBe(true)
		expect(v.e).toBe(-150)
		expect(v.f).toBe('line\nbreak"q\\')
		expect(v.g).toEqual({})
		expect(v.h).toEqual({})
		expect(v.i).toBe(0.25)
		expect(http:JSONDecode("  [ ]  ")).toEqual({})
		expect(http:JSONDecode('"\\u0041"')).toBe("A")
		expect(http:JSONDecode("[1,null,3]")[3]).toBe(3)
		expect(function() http:JSONDecode("{\"a\":1} x") end).toThrow()
		expect(function() http:JSONDecode("{a:1}") end).toThrow()
		expect(function() http:JSONDecode("[1,]") end).toThrow()
		-- round trip of a nested table with arrays, nested objects and special characters
		local data = { name = "Dash \"Delivery\"\n\t\\", nested = { list = { 1, 2.5, -3, { deep = true } }, empty = {} }, uni = "\195\169", flag = false, n = 1e-3 }
		local back = http:JSONDecode(http:JSONEncode(data))
		expect(back).toEqual(data)
		expect(http:JSONEncode({ 1, 2, 3 })).toBe("[1,2,3]")
		expect(http:JSONEncode({ b = 1, a = { 2 } })).toBe('{"a":[2],"b":1}')
		expect(http:JSONEncode({ 1, 2, 3 }):sub(1, 1)).toBe("[")
		-- a sparse table with a hole is encoded as an object, like the engine does
		local sparse = {}
		sparse[1] = "a"
		sparse[3] = "c"
		expect(http:JSONEncode(sparse):sub(1, 1)).toBe("{")
		-- control characters and non-ASCII survive encoding
		local weird = { s = "\1\2 tab\t \226\130\172" }
		expect(http:JSONDecode(http:JSONEncode(weird))).toEqual(weird)
	end)
end)

describe("Harness extra: Random and Clone", function()
	it("Random is deterministic per seed, in range, and Clone/Shuffle behave", function()
		local r1, r2 = Random.new(7), Random.new(7)
		local seqA, seqB = {}, {}
		for _ = 1, 50 do
			seqA[#seqA + 1] = r1:NextInteger(-5, 5)
			seqB[#seqB + 1] = r2:NextInteger(-5, 5)
		end
		expect(seqA).toEqual(seqB)
		local sawMin, sawMax = false, false
		for _, n in ipairs(seqA) do
			expect(n).toBeGreaterThanOrEqual(-5)
			expect(n).toBeLessThanOrEqual(5)
			expect(n).toBe(math.floor(n))
			if n == -5 then sawMin = true end
			if n == 5 then sawMax = true end
		end
		expect(sawMin and sawMax).toBe(true)
		for _ = 1, 50 do
			local f = r1:NextNumber()
			expect(f).toBeGreaterThanOrEqual(0)
			expect(f).toBeLessThan(1)
			local g = r2:NextNumber(2, 3)
			expect(g).toBeGreaterThanOrEqual(2)
			expect(g).toBeLessThan(3)
		end
		expect(r1:NextInteger(3, 3)).toBe(3)
		-- different seeds differ
		local r3 = Random.new(8)
		local same = true
		for i = 1, 20 do
			if r3:NextInteger(1, 1000) ~= Random.new(7):NextInteger(1, 1000) then same = false end
		end
		expect(same).toBe(false)
		-- Clone continues the identical sequence; the original is unaffected
		local base = Random.new(99)
		base:NextNumber()
		local copy = base:Clone()
		expect(copy:NextInteger(1, 1e6)).toBe(base:NextInteger(1, 1e6))
		-- Shuffle is a deterministic permutation
		local listA, listB = { 1, 2, 3, 4, 5, 6, 7, 8 }, { 1, 2, 3, 4, 5, 6, 7, 8 }
		Random.new(3):Shuffle(listA)
		Random.new(3):Shuffle(listB)
		expect(listA).toEqual(listB)
		table.sort(listA)
		expect(listA).toEqual({ 1, 2, 3, 4, 5, 6, 7, 8 })
		local unit = Random.new(1):NextUnitVector()
		expect(unit.Magnitude).toBeCloseTo(1, 1e-6)
		expect(typeof(base)).toBe("Random")
		expect(function() Random.new(1):NextInteger(5, 1) end).toThrow()
	end)

	it("Instance:Clone is a deep, independent copy that remaps internal references", function()
		local model = Instance.new("Model")
		model.Name = "Template"
		local root = Instance.new("Part") root.Name = "Root" root.Size = v3(2, 2, 2) root.CFrame = CFrame.new(1, 2, 3) root.Parent = model
		local wheel = Instance.new("Part") wheel.Name = "Wheel" wheel.Parent = model
		local weld = Instance.new("Weld") weld.Part0 = root weld.Part1 = wheel weld.Parent = root
		local link = Instance.new("ObjectValue") link.Name = "Link" link.Value = wheel link.Parent = model
		local att = Instance.new("Attachment") att.CFrame = CFrame.new(0, 1, 0) att.Parent = root
		local hidden = Instance.new("Part") hidden.Name = "Hidden" hidden.Archivable = false hidden.Parent = model
		model.PrimaryPart = root
		model:SetAttribute("Kind", "Van")
		model:AddTag("DeliveryVehicle")
		root:SetAttribute("Mass", 12.5)

		local copy = model:Clone()
		expect(copy).never.toBe(model)
		expect(copy.Parent).toBeNil()
		expect(copy.Name).toBe("Template")
		expect(copy:GetAttribute("Kind")).toBe("Van")
		expect(copy:HasTag("DeliveryVehicle")).toBe(true)
		local copyRoot = copy:FindFirstChild("Root")
		expect(copyRoot).toBeDefined()
		expect(copyRoot).never.toBe(root)
		expect(copyRoot.Parent).toBe(copy)
		expect(copyRoot.Size).toEqual(v3(2, 2, 2))
		expect(copyRoot.CFrame).toEqual(CFrame.new(1, 2, 3))
		expect(copyRoot:GetAttribute("Mass")).toBe(12.5)
		expect(copy:FindFirstChild("Hidden")).toBeNil()
		expect(#copy:GetChildren()).toBe(3)
		expect(copyRoot:FindFirstChildOfClass("Attachment").CFrame).toEqual(CFrame.new(0, 1, 0))
		-- references inside the cloned subtree point at the clones, not the originals
		expect(copy.PrimaryPart).toBe(copyRoot)
		local copyWeld = copyRoot:FindFirstChildOfClass("Weld")
		expect(copyWeld.Part0).toBe(copyRoot)
		expect(copyWeld.Part1).toBe(copy:FindFirstChild("Wheel"))
		expect(copy:FindFirstChild("Link").Value).toBe(copy:FindFirstChild("Wheel"))
		-- a reference to something outside the subtree is kept as-is
		local outside = Instance.new("Part") outside.Parent = workspace
		local ov = Instance.new("ObjectValue") ov.Name = "Outside" ov.Value = outside ov.Parent = model
		expect(model:Clone():FindFirstChild("Outside").Value).toBe(outside)

		-- mutations do not cross between the original and the copy
		copyRoot.Name = "Renamed"
		copyRoot.CFrame = CFrame.new(9, 9, 9)
		copy:SetAttribute("Kind", "Bike")
		copy:RemoveTag("DeliveryVehicle")
		copy.PrimaryPart = nil
		expect(root.Name).toBe("Root")
		expect(root.CFrame).toEqual(CFrame.new(1, 2, 3))
		expect(model:GetAttribute("Kind")).toBe("Van")
		expect(model:HasTag("DeliveryVehicle")).toBe(true)
		expect(model.PrimaryPart).toBe(root)
		expect(#model:GetChildren()).toBe(5)
		Instance.new("Part").Parent = copy
		expect(#model:GetChildren()).toBe(5)
		copy:Destroy()
		expect(root.Parent).toBe(model)
		expect(model:FindFirstChild("Root")).toBe(root)
		-- connections are not cloned
		local fired = 0
		root:GetPropertyChangedSignal("Transparency"):Connect(function() fired += 1 end)
		local again = model:Clone()
		again.Root.Transparency = 0.5
		expect(fired).toBe(0)
		root.Transparency = 0.5
		expect(fired).toBe(1)
	end)
end)

describe("Harness extra: signals and tags", function()
	it("GetPropertyChangedSignal fires once per real change only", function()
		local part = Instance.new("Part")
		part.Parent = workspace
		local counts = {}
		for _, prop in ipairs({ "Transparency", "Name", "CFrame", "Position", "Parent", "Anchored", "Size", "Color" }) do
			counts[prop] = 0
			part:GetPropertyChangedSignal(prop):Connect(function() counts[prop] += 1 end)
		end
		local changedProps = {}
		part.Changed:Connect(function(prop) table.insert(changedProps, prop) end)

		part.Transparency = 0.5
		part.Transparency = 0.5
		expect(counts.Transparency).toBe(1)
		part.Transparency = 0
		expect(counts.Transparency).toBe(2)
		part.Name = "Part"
		expect(counts.Name).toBe(0)
		part.Name = "Other"
		part.Name = "Other"
		expect(counts.Name).toBe(1)
		part.Anchored = false
		expect(counts.Anchored).toBe(0)
		part.Anchored = true
		expect(counts.Anchored).toBe(1)
		part.Size = Vector3.new(4, 1, 2) -- the default
		expect(counts.Size).toBe(0)
		part.Size = Vector3.new(1, 1, 1)
		expect(counts.Size).toBe(1)
		part.Color = Color3.fromRGB(163, 162, 165)
		expect(counts.Color).toBe(0)
		-- CFrame: same value is silent; a move fires CFrame and Position; a pure rotation fires only CFrame
		part.CFrame = CFrame.new()
		expect(counts.CFrame).toBe(0)
		expect(counts.Position).toBe(0)
		part.CFrame = CFrame.new(1, 0, 0)
		expect(counts.CFrame).toBe(1)
		expect(counts.Position).toBe(1)
		part.Position = Vector3.new(1, 0, 0)
		expect(counts.CFrame).toBe(1)
		expect(counts.Position).toBe(1)
		part.Position = Vector3.new(2, 0, 0)
		expect(counts.CFrame).toBe(2)
		expect(counts.Position).toBe(2)
		part.CFrame = CFrame.new(2, 0, 0) * CFrame.Angles(0, 1, 0)
		expect(counts.CFrame).toBe(3)
		expect(counts.Position).toBe(2)
		-- Parent
		local f = Instance.new("Folder") f.Parent = workspace
		part.Parent = workspace
		expect(counts.Parent).toBe(0)
		part.Parent = f
		expect(counts.Parent).toBe(1)
		expect(changedProps).toContain("Transparency")
		expect(changedProps).toContain("Parent")
		-- attributes have their own signal and AttributeChanged
		local attrFires, attrChanged = 0, {}
		part:GetAttributeChangedSignal("Score"):Connect(function() attrFires += 1 end)
		part.AttributeChanged:Connect(function(name) table.insert(attrChanged, name) end)
		part:SetAttribute("Score", 1)
		part:SetAttribute("Score", 1)
		part:SetAttribute("Score", 2)
		part:SetAttribute("Score", nil)
		expect(attrFires).toBe(3)
		expect(attrChanged).toEqual({ "Score", "Score", "Score" })
		expect(part:GetAttribute("Score")).toBeNil()
		-- ValueBase Changed passes the new value; same value is silent
		local iv = Instance.new("IntValue")
		local seen = {}
		iv.Changed:Connect(function(v) table.insert(seen, v) end)
		iv.Value = 3
		iv.Value = 3
		iv.Value = 4
		expect(seen).toEqual({ 3, 4 })
		-- disconnecting stops delivery
		local conn = part:GetPropertyChangedSignal("Transparency"):Connect(function() counts.Transparency += 100 end)
		conn:Disconnect()
		expect(conn.Connected).toBe(false)
		part.Transparency = 0.9
		expect(counts.Transparency).toBe(3)
	end)

	it("CollectionService instance added/removed signals follow DataModel membership", function()
		local CS = game:GetService("CollectionService")
		local added, removed = {}, {}
		CS:GetInstanceAddedSignal("Package"):Connect(function(inst) table.insert(added, inst) end)
		CS:GetInstanceRemovedSignal("Package"):Connect(function(inst) table.insert(removed, inst) end)
		expect(CS:GetInstanceAddedSignal("Package")).toBe(CS:GetInstanceAddedSignal("Package"))

		-- tagging something already in the DataModel fires immediately
		local a = Instance.new("Part") a.Name = "A" a.Parent = workspace
		CS:AddTag(a, "Package")
		expect(added).toEqual({ a })
		expect(CS:HasTag(a, "Package")).toBe(true)
		expect(a:HasTag("Package")).toBe(true)
		CS:AddTag(a, "Package") -- idempotent
		expect(#added).toBe(1)

		-- tagging a loose instance fires only once it enters the DataModel (via an ancestor)
		local holder = Instance.new("Model") holder.Name = "Holder"
		local b = Instance.new("Part") b.Name = "B" b.Parent = holder
		b:AddTag("Package")
		expect(#added).toBe(1)
		expect(CS:GetTagged("Package")).toEqual({ a })
		holder.Parent = workspace
		expect(#added).toBe(2)
		expect(added[2]).toBe(b)
		expect(#CS:GetTagged("Package")).toBe(2)

		-- leaving the DataModel fires removed; re-entering fires added again
		holder.Parent = nil
		expect(removed).toEqual({ b })
		expect(#CS:GetTagged("Package")).toBe(1)
		holder.Parent = workspace
		expect(#added).toBe(3)
		-- RemoveTag and Destroy both fire removed exactly once
		CS:RemoveTag(b, "Package")
		expect(#removed).toBe(2)
		expect(removed[2]).toBe(b)
		CS:RemoveTag(b, "Package")
		expect(#removed).toBe(2)
		a:Destroy()
		expect(#removed).toBe(3)
		expect(removed[3]).toBe(a)
		expect(CS:GetTagged("Package")).toEqual({})
		expect(a:HasTag("Package")).toBe(true) -- tags survive on the destroyed object itself
		-- a clone carries the tag and fires added when parented
		local c = Instance.new("Part") c:AddTag("Package")
		local cc = c:Clone()
		cc.Parent = workspace
		expect(added[#added]).toBe(cc)
		expect(CS:GetTags(cc)).toEqual({ "Package" })
		-- GetAllTags only lists tags that are in use
		expect(CS:GetAllTags()).toContain("Package")
		-- the signal from a handler that yields does not block the caller
		local resumed = false
		CS:GetInstanceAddedSignal("Slow"):Connect(function() task.wait(1) resumed = true end)
		local d = Instance.new("Part") d.Parent = workspace
		d:AddTag("Slow")
		expect(resumed).toBe(false)
		task.wait(1)
		expect(resumed).toBe(true)
	end)
end)

describe("Harness extra: typeof, Enum and Vector3 edge cases", function()
	it("typeof reports Roblox type names for every mocked datatype", function()
		local cases = {
			{ Vector3.new(), "Vector3" }, { Vector2.new(), "Vector2" }, { CFrame.new(), "CFrame" }, { Color3.new(), "Color3" },
			{ UDim.new(1, 2), "UDim" }, { UDim2.new(0, 1, 0, 2), "UDim2" }, { UDim2.fromScale(1, 1), "UDim2" },
			{ Enum, "Enums" }, { Enum.KeyCode, "Enum" }, { Enum.KeyCode.A, "EnumItem" },
			{ Instance.new("Part"), "Instance" }, { game, "Instance" }, { workspace, "Instance" }, { game:GetService("Players"), "Instance" },
			{ Instance.new("Part").Touched, "RBXScriptSignal" }, { Instance.new("Part").Touched:Connect(function() end), "RBXScriptConnection" },
			{ shim.Signal.new(), "RBXScriptSignal" },
			{ Random.new(1), "Random" }, { DateTime.now(), "DateTime" }, { TweenInfo.new(1), "TweenInfo" },
			{ NumberRange.new(1, 2), "NumberRange" }, { NumberSequence.new(1), "NumberSequence" }, { NumberSequenceKeypoint.new(0, 1), "NumberSequenceKeypoint" },
			{ ColorSequence.new(Color3.new()), "ColorSequence" }, { ColorSequenceKeypoint.new(0, Color3.new()), "ColorSequenceKeypoint" },
			{ Rect.new(0, 0, 1, 1), "Rect" }, { BrickColor.new("Bright red"), "BrickColor" }, { BrickColor.Red(), "BrickColor" },
			{ Ray.new(Vector3.zero, Vector3.xAxis), "Ray" }, { Region3.new(Vector3.zero, Vector3.one), "Region3" },
			{ Font.fromEnum(Enum.Font.Gotham), "Font" }, { PhysicalProperties.new(1, 0.3, 0.5), "PhysicalProperties" },
			{ RaycastParams.new(), "RaycastParams" }, { OverlapParams.new(), "OverlapParams" },
			{ 1, "number" }, { "s", "string" }, { true, "boolean" }, { nil, "nil" }, { {}, "table" }, { print, "function" }, { coroutine.create(function() end), "thread" },
			{ setmetatable({}, {}), "table" }, { setmetatable({}, { __index = {} }), "table" },
			{ os.clock(), "number" }, { task.spawn(function() end), "thread" },
		}
		for i, case in ipairs(cases) do
			local actual = typeof(case[1])
			if actual ~= case[2] then
				error(string.format("case %d: typeof(%s) = %s, expected %s", i, tostring(case[1]), actual, case[2]))
			end
		end
		expect(typeof(Enum.Material.Plastic)).toBe("EnumItem")
		expect(type(Vector3.new())).toBe("table")
		expect(typeof(Vector3)).toBe("table")
	end)

	it("Enum items are singletons with real values and usable as keys", function()
		expect(Enum.KeyCode.A).toBe(Enum.KeyCode.A)
		expect(rawequal(Enum.KeyCode.A, Enum.KeyCode.A)).toBe(true)
		expect(Enum.KeyCode.A).never.toBe(Enum.KeyCode.B)
		expect(Enum.KeyCode.A.Value).toBe(97)
		expect(Enum.KeyCode.Space.Value).toBe(32)
		expect(Enum.KeyCode.A.Name).toBe("A")
		expect(Enum.KeyCode.A.EnumType).toBe(Enum.KeyCode)
		expect(tostring(Enum.KeyCode.A)).toBe("Enum.KeyCode.A")
		expect(tostring(Enum.KeyCode)).toBe("Enum.KeyCode")
		expect(Enum.KeyCode:FromName("A")).toBe(Enum.KeyCode.A)
		expect(Enum.KeyCode:FromValue(97)).toBe(Enum.KeyCode.A)
		expect(Enum.Material.Plastic.Value).toBe(256)
		expect(Enum.Material.Neon.Value).toBe(288)
		expect(Enum.HumanoidStateType.Running.Value).toBe(8)
		expect(Enum.HumanoidStateType.Jumping.Value).toBe(3)
		expect(Enum.HumanoidStateType.Seated.Value).toBe(13)
		expect(Enum.HumanoidStateType.Dead.Value).toBe(15)
		expect(Enum.HumanoidStateType.Physics.Value).toBe(16)
		expect(Enum.HumanoidStateType.None.Value).toBe(18)
		expect(Enum.EasingStyle.Linear.Value).toBe(0)
		expect(Enum.EasingDirection.InOut.Value).toBe(2)
		expect(Enum.UserInputType.MouseButton1.Value).toBe(0)
		expect(Enum.UserInputType.Keyboard.Value).toBe(6)
		expect(Enum.UserInputType.Gamepad1.Value).toBe(10)
		expect(Enum.UserInputState.Begin.Value).toBe(0)
		expect(Enum.UserInputState.End.Value).toBe(2)
		expect(Enum.RaycastFilterType.Exclude.Value).toBe(0)
		expect(Enum.RaycastFilterType.Include.Value).toBe(1)
		expect(Enum.NormalId.Top.Value).toBe(1)
		expect(Enum.PartType.Ball.Value).toBe(0)
		expect(Enum.CameraType.Scriptable.Value).toBe(6)
		expect(Enum.ContextActionPriority.High.Value).toBe(3000)
		-- usable as table keys because they are the same object every time
		local t = {}
		t[Enum.KeyCode.W] = "forward"
		expect(t[Enum.KeyCode.W]).toBe("forward")
		expect(t[Enum.KeyCode:FromName("W")]).toBe("forward")
		-- GetEnumItems contains the singleton and is sorted by value
		local items = Enum.UserInputState:GetEnumItems()
		expect(items[1]).toBe(Enum.UserInputState.Begin)
		local found = false
		for _, item in ipairs(Enum.KeyCode:GetEnumItems()) do
			if item == Enum.KeyCode.A then found = true end
		end
		expect(found).toBe(true)
		expect(Enum.KeyCode.A < Enum.KeyCode.B).toBe(true)
		-- read-only
		expect(function() Enum.KeyCode.A.Value = 1 end).toThrow()
		expect(function() Enum.KeyCode = nil end).toThrow()
		-- comparing with other types never errors and is false
		expect(Enum.KeyCode.A == "A").toBe(false)
		expect(Enum.KeyCode.A == 97).toBe(false)
		expect(Enum.KeyCode.A == Enum.Material.Plastic).toBe(false)
		-- strict mode catches typos
		shim.strictEnums = true
		local okUnknown = pcall(function() return Enum.KeyCode.NotAKey end)
		shim.strictEnums = false
		expect(okUnknown).toBe(false)
		expect(Enum.KeyCode.A).toBe(Enum.KeyCode.A)
	end)

	it("Vector3 operators handle numbers on either side and edge cases like the engine", function()
		local v = v3(1, -2, 3)
		expect(2 * v).toEqual(v3(2, -4, 6))
		expect(v * 2).toEqual(v3(2, -4, 6))
		expect(v * 0.5).toEqual(v3(0.5, -1, 1.5))
		expect(v / 2).toEqual(v3(0.5, -1, 1.5))
		expect(v * v3(2, 3, 4)).toEqual(v3(2, -6, 12))
		expect(v / v3(1, 2, 3)).toEqual(v3(1, -1, 1))
		expect(-v).toEqual(v3(-1, 2, -3))
		expect(v // 2).toEqual(v3(0, -1, 1))
		expect(Vector3.one * 3).toEqual(v3(3, 3, 3))
		expect(v3(1, 2, 3) + v3(0, 0, 0)).toEqual(v3(1, 2, 3))
		expect(v3(1, 2, 3) - v3(1, 2, 3)).toEqual(Vector3.zero)
		expect(v3(1, 2, 3) == v3(1, 2, 3)).toBe(true)
		expect(v3(1, 2, 3) ~= v3(1, 2, 3.0001)).toBe(true)
		expect(Vector3.new() == Vector3.zero).toBe(true)
		expect(Vector3.new(0, 0, 0) == Vector3.zero).toBe(true)
		-- comparisons against other types are false, never errors
		expect(v3(1, 2, 3) == nil).toBe(false)
		expect(v3(1, 2, 3) == 5).toBe(false)
		expect(v3(1, 2, 3) == "1, 2, 3").toBe(false)
		expect(v3(1, 2, 3) == { X = 1, Y = 2, Z = 3 }).toBe(false)
		expect(v3(1, 2, 3) == Vector2.new(1, 2)).toBe(false)
		expect(v3(1, 2, 3) == CFrame.new(1, 2, 3)).toBe(false)
		-- invalid operations raise instead of producing garbage
		expect(function() return v + 1 end).toThrow()
		expect(function() return 1 + v end).toThrow()
		expect(function() return v - 1 end).toThrow()
		expect(function() return v * "2" end).toThrow()
		expect(function() return v * CFrame.new() end).toThrow()
		expect(function() return Vector3.new("1", 2, 3) end).toThrow()
		expect(function() return v.W end).toThrow()
		expect(function() v.X = 9 end).toThrow()
		-- division by zero yields inf/nan rather than erroring
		local inf = v3(1, 0, -1) / 0
		expect(inf.X).toBe(math.huge)
		expect(inf.Y ~= inf.Y).toBe(true)
		expect(inf.Z).toBe(-math.huge)
		expect(Vector3.zero.Unit.X ~= Vector3.zero.Unit.X).toBe(true)
		-- magnitude and dot/cross identities
		expect(v3(2, 3, 6).Magnitude).toBe(7)
		expect(v3(2, 3, 6).Unit.Magnitude).toBeCloseTo(1, 1e-9)
		expect(v3(1, 0, 0):Cross(v3(0, 1, 0))).toEqual(v3(0, 0, 1))
		expect(v3(0, 1, 0):Cross(v3(1, 0, 0))).toEqual(v3(0, 0, -1))
		expect(v3(1, 2, 3):Dot(v3(4, -5, 6))).toBe(12)
		expect(v3(1, 0, 0):Angle(v3(0, 1, 0))).toBeCloseTo(HALF_PI, 1e-9)
		expect(v3(1, 0, 0):Angle(v3(0, 1, 0), v3(0, 0, -1))).toBeCloseTo(-HALF_PI, 1e-9)
		expect(v3(1, 0, 0):Lerp(v3(3, 0, 0), 0.5)).toEqual(v3(2, 0, 0))
		expect(v3(1.4, -1.5, 2.6):Floor()).toEqual(v3(1, -2, 2))
		expect(v3(1.4, -1.5, 2.6):Ceil()).toEqual(v3(2, -1, 3))
		expect(v3(-3, 0, 4):Sign()).toEqual(v3(-1, 0, 1))
		expect(v3(1, 2, 3):Max(v3(3, 1, 2), v3(0, 5, 0))).toEqual(v3(3, 5, 3))
		expect(Vector3.FromNormalId(Enum.NormalId.Front)).toEqual(v3(0, 0, -1))
		expect(Vector3.FromAxis(Enum.Axis.Z)).toEqual(v3(0, 0, 1))
		expect(tostring(v3(0.5, 100, -0.25))).toBe("0.5, 100, -0.25")
		-- lower-case accessors still work
		expect(v.x).toBe(1) expect(v.magnitude).toBeCloseTo(v.Magnitude)
		-- Vector3 values can be table keys only by identity (not value); use tostring for maps
		local map = {}
		map[tostring(v3(1, 2, 3))] = true
		expect(map[tostring(Vector3.new(1, 2, 3))]).toBe(true)
		-- frozen: table.freeze semantics mean rawset also fails
		expect(table.isfrozen(v)).toBe(true)
		-- CFrame operators
		expect(function() return CFrame.new() * 2 end).toThrow()
		expect(function() return CFrame.new() + 1 end).toThrow()
		expect(CFrame.new(1, 2, 3) == CFrame.new(1, 2, 3)).toBe(true)
		expect(CFrame.new(1, 2, 3) == v3(1, 2, 3)).toBe(false)
		expect(CFrame.new(1, 2, 3) * v3(1, 1, 1)).toEqual(v3(2, 3, 4))
	end)
end)
