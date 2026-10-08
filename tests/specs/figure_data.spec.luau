--!nonstrict
-- Hip Motor6D maths checked against every real embedded figure index (Shared.MeshData, kind
-- "figure"): rest centres, the hip axis fixed under a swing, feet on the ground, placement.
local function requireShared(path)
	return shim.requirePath("ReplicatedStorage/Shared/" .. path)
end
local function v3(t) return Vector3.new(t[1], t[2], t[3]) end

describe("FigureRig on the real figure data", function()
	local FigureRig, MeshData
	beforeEach(function()
		FigureRig = requireShared("Util/FigureRig")
		FigureRig._setMeshData(nil)
		MeshData = requireShared("MeshData")
	end)

	it("every real figure: rest centres, fixed hip axis under a swing, feet on the ground, placement", function()
		local figures = 0
		for _, id in ipairs(MeshData.list()) do
			if MeshData.kind(id) == "figure" then
				figures += 1
				local index = MeshData.index(id)
				local model = FigureRig.build(id, { anchored = true })
				local root = model.PrimaryPart
				expect(root.Name).toBe("Root")
				expect(root.Position).toBeCloseTo(Vector3.new(0, 3, 0), 1e-6)
				expect(model:GetAttribute("FigureId")).toBe(id)
				local legs = 0
				for _, entry in ipairs(index.parts) do
					local part = model[entry.name]
					local bboxCentre = (v3(entry.bboxMin) + v3(entry.bboxMax)) / 2
					-- (a) rest: placeholder centre == index bboxCentre relative to the feet
					expect(part.Position).toBeCloseTo(bboxCentre, 1e-5)
					expect(part.Size).toBeCloseTo(v3(entry.bboxMax) - v3(entry.bboxMin), 1e-5)
					expect(part:GetAttribute("EmbeddedMesh")).toBe(id)
					expect(part:GetAttribute("EmbeddedPart")).toBe(entry.name)
					expect(game:GetService("CollectionService"):HasTag(part, "EmbeddedMeshBody")).toBe(true)
					if entry.pivot then
						legs += 1
						local pivot = v3(entry.pivot)
						local motor = part:FindFirstChildWhichIsA("Motor6D")
						expect(motor.Name).toBe(if entry.name == "LegL" then "LeftHip" else "RightHip")
						expect(motor.Part0).toBe(root)
						expect(motor.Part1).toBe(part)
						local rest = root.CFrame * motor.C0 * CFrame.identity * motor.C1:Inverse()
						expect(rest).toBeCloseTo(part.CFrame, 1e-6)
						-- the foot reaches the ground, the top is just under the hip line
						expect(part.Position.Y - part.Size.Y / 2).toBeCloseTo(0, 0.05)
						expect(part.Position.Y + part.Size.Y / 2).toBeLessThanOrEqual(pivot.Y + 1e-6)
						expect(part.Position.Y + part.Size.Y / 2).toBeGreaterThan(pivot.Y - 0.3)
						-- (b) swing: every point on the hip axis (pivot + t * X) stays fixed; the centre rotates
						for _, swing in ipairs({ 0.55, -0.55, 1.2 }) do
							local T = CFrame.Angles(swing, 0, 0)
							local swung = root.CFrame * motor.C0 * T * motor.C1:Inverse()
							for _, t in ipairs({ -1, 0, 0.5, 2 }) do
								local localPoint = motor.C1 * CFrame.new(t, 0, 0)
								expect((swung * localPoint).Position).toBeCloseTo(pivot + Vector3.new(t, 0, 0), 1e-6)
							end
							local off = bboxCentre - pivot
							expect(swung.Position).toBeCloseTo(pivot + T:VectorToWorldSpace(off), 1e-6)
							expect((swung.Position - pivot).Magnitude).toBeCloseTo(off.Magnitude, 1e-6)
							-- forward swing moves the leg centre forward (-Z) when swing > 0
							if swing > 0 then
								expect(swung.Position.Z).toBeLessThan(bboxCentre.Z)
							end
						end
					end
				end
				expect(legs).toBe(2)
				-- (c) placement: feet at a world point, facing +X; the leg centre follows the rotation
				local feet, facing = Vector3.new(12, 4, -7), Vector3.new(1, 0, 0)
				FigureRig.place(model, feet, facing)
				expect(root.CFrame.LookVector).toBeCloseTo(facing, 1e-6)
				expect(root.Position).toBeCloseTo(feet + Vector3.new(0, 3, 0), 1e-6)
				local feetFrame = CFrame.lookAt(feet, feet + facing)
				for _, entry in ipairs(index.parts) do
					local part = model[entry.name]
					local bboxCentre = (v3(entry.bboxMin) + v3(entry.bboxMax)) / 2
					expect(part.Position).toBeCloseTo(feetFrame:PointToWorldSpace(bboxCentre), 1e-4)
					if entry.pivot then
						local motor = part:FindFirstChildWhichIsA("Motor6D")
						expect((root.CFrame * motor.C0).Position).toBeCloseTo(feetFrame:PointToWorldSpace(v3(entry.pivot)), 1e-4)
					end
				end
				FigureRig.setWalkPose(model, math.pi / 2)
				expect(model.LegL.LeftHip.Transform).toBeCloseTo(CFrame.Angles(0.55, 0, 0), 1e-6)
				expect(model.LegR.RightHip.Transform).toBeCloseTo(CFrame.Angles(-0.55, 0, 0), 1e-6)
				FigureRig.setIdlePose(model)
				expect(model.LegL.LeftHip.Transform).toBeCloseTo(CFrame.identity, 1e-6)
			end
		end
		expect(figures).toBe(8)
		print("[figure_data.spec] checked " .. figures .. " real figures")
	end)
end)
