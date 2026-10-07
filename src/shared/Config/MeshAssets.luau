--!strict
-- MeshAssets: Roblox asset ids of the imported vehicle meshes (assets/meshes/<VehicleId>/).
--
-- How to fill this in (one time, in Roblox Studio):
--   1. Import assets/meshes/<VehicleId>/<VehicleId>_Body.obj with the 3D Importer (one MeshPart per
--      OBJ, texture included). Studio uploads the mesh and its texture and gives you a MeshPart.
--   2. Select the MeshPart. In Properties, MeshId reads "rbxassetid://123456789" and TextureID
--      reads "rbxassetid://987654321". Paste the NUMBERS (not the whole string) below:
--        Van = { body = { meshId = 123456789, textureId = 987654321 }, wheels = {} }
--   3. A meshId of 0 means "not configured": the builder keeps the generated block parts for that
--      vehicle. textureId 0 leaves the mesh untextured (vertex colours / default grey).
--   4. Wheels are optional and may be added later without code changes. The key is the wheel name
--      from VehicleDefinitions[id].mesh.wheels (e.g. "FrontWheel"):
--        wheels = { FrontWheel = { meshId = 111, textureId = 222 }, RearWheel = { ... } }
--      Until a wheel is configured, no wheel part is created for it (the wheels are baked into the
--      body mesh).
--
-- The server creates the MeshParts from these ids (AssetService:CreateMeshPartAsync); the client
-- only ever clones the display copies the server publishes under
-- ReplicatedStorage.SharedAssets.VehicleDisplays. Geometry (size, offsets) lives in
-- VehicleDefinitions[id].mesh and comes from assets/meshes/<VehicleId>/meta.json.

local MeshAssets = {}

export type AssetIds = { meshId: number, textureId: number }
export type VehicleMeshAssets = { body: AssetIds, wheels: { [string]: AssetIds } }

MeshAssets.ASSET_PREFIX = "rbxassetid://"

MeshAssets.Vehicles = {
	Bicycle = { body = { meshId = 0, textureId = 0 }, wheels = {} },
	Scooter = { body = { meshId = 0, textureId = 0 }, wheels = {} },
	Van = { body = { meshId = 0, textureId = 0 }, wheels = {} },
} :: { [string]: VehicleMeshAssets }

local function validId(value: any): number
	if type(value) == "number" and value == value and value ~= math.huge and value > 0 then
		return math.floor(value)
	end
	return 0
end

-- True when a body mesh id is configured for the vehicle (the builder then uses the mesh path).
function MeshAssets.hasBody(vehicleId: string): boolean
	local entry = MeshAssets.Vehicles[vehicleId]
	return entry ~= nil and entry.body ~= nil and validId(entry.body.meshId) > 0
end

-- (meshId, textureId) of the body, or nil when not configured. textureId is 0 when untextured.
function MeshAssets.bodyIds(vehicleId: string): (number?, number?)
	local entry = MeshAssets.Vehicles[vehicleId]
	if not entry or not entry.body then
		return nil, nil
	end
	local meshId = validId(entry.body.meshId)
	if meshId <= 0 then
		return nil, nil
	end
	return meshId, validId(entry.body.textureId)
end

-- (meshId, textureId) of a named wheel, or nil when that wheel has no mesh configured.
function MeshAssets.wheelIds(vehicleId: string, wheelName: string): (number?, number?)
	local entry = MeshAssets.Vehicles[vehicleId]
	local wheel = entry and entry.wheels and entry.wheels[wheelName]
	if not wheel then
		return nil, nil
	end
	local meshId = validId(wheel.meshId)
	if meshId <= 0 then
		return nil, nil
	end
	return meshId, validId(wheel.textureId)
end

-- "rbxassetid://<id>" for a positive id, "" otherwise.
function MeshAssets.assetUrl(id: number?): string
	local n = validId(id)
	if n <= 0 then
		return ""
	end
	return MeshAssets.ASSET_PREFIX .. tostring(n)
end

return MeshAssets
