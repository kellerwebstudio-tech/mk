--!strict
-- MeshPack: decodes the "DDCM" v1 geometry blob written by tools/mesh_embed.py.
--
-- Layout (little-endian):
--   magic "DDCM" | u16 version = 1 | u16 flags = 0 | u32 vertexCount | u32 triangleCount
--   f32 bboxMin[3] | f32 bboxMax[3]
--   positions f32[3] * vertexCount
--   normals   i8[3]  * vertexCount     (unit normal * 127)
--   uvs       u16[2] * vertexCount     ((u, 1 - v) * 65535; Roblox UV origin is top-left)
--   triangles u16[3] * triangleCount   (0-based vertex ids; decoded to 1-based)
--
--   MeshPack.decode(blob) -> Mesh (errors on a bad magic / version / truncated blob)

local MeshPack = {}

export type Mesh = {
	vertexCount: number,
	triangleCount: number,
	bboxMin: Vector3,
	bboxMax: Vector3,
	positions: { Vector3 },
	normals: { Vector3 },
	uvs: { Vector2 },
	triangles: { number }, -- flat, 1-based vertex indices, 3 per face
}

MeshPack.MAGIC = "DDCM"
MeshPack.VERSION = 1
MeshPack.HEADER_SIZE = 4 + 2 + 2 + 4 + 4 + 12 + 12 -- 40 bytes

function MeshPack.decode(blob: buffer): Mesh
	if type(blob) ~= "buffer" then
		error("MeshPack.decode expects a buffer, got " .. typeof(blob), 2)
	end
	local n = buffer.len(blob)
	if n < MeshPack.HEADER_SIZE then
		error("MeshPack: blob too short for a DDCM header", 2)
	end
	if buffer.readstring(blob, 0, 4) ~= MeshPack.MAGIC then
		error("MeshPack: bad magic (expected \"DDCM\")", 2)
	end
	local version = buffer.readu16(blob, 4)
	if version ~= MeshPack.VERSION then
		error(string.format("MeshPack: unsupported DDCM version %d (expected %d)", version, MeshPack.VERSION), 2)
	end
	local vertexCount = buffer.readu32(blob, 8)
	local triangleCount = buffer.readu32(blob, 12)
	local bboxMin = Vector3.new(buffer.readf32(blob, 16), buffer.readf32(blob, 20), buffer.readf32(blob, 24))
	local bboxMax = Vector3.new(buffer.readf32(blob, 28), buffer.readf32(blob, 32), buffer.readf32(blob, 36))

	local posOffset = MeshPack.HEADER_SIZE
	local normalOffset = posOffset + vertexCount * 12
	local uvOffset = normalOffset + vertexCount * 3
	local triOffset = uvOffset + vertexCount * 4
	local total = triOffset + triangleCount * 6
	if total > n then
		error(string.format("MeshPack: blob truncated (%d bytes, header declares %d)", n, total), 2)
	end

	local positions: { Vector3 } = table.create(vertexCount)
	local p = posOffset
	for i = 1, vertexCount do
		positions[i] = Vector3.new(buffer.readf32(blob, p), buffer.readf32(blob, p + 4), buffer.readf32(blob, p + 8))
		p += 12
	end

	local normals: { Vector3 } = table.create(vertexCount)
	p = normalOffset
	for i = 1, vertexCount do
		normals[i] = Vector3.new(buffer.readi8(blob, p) / 127, buffer.readi8(blob, p + 1) / 127, buffer.readi8(blob, p + 2) / 127)
		p += 3
	end

	local uvs: { Vector2 } = table.create(vertexCount)
	p = uvOffset
	for i = 1, vertexCount do
		uvs[i] = Vector2.new(buffer.readu16(blob, p) / 65535, buffer.readu16(blob, p + 2) / 65535)
		p += 4
	end

	local triangles: { number } = table.create(triangleCount * 3)
	p = triOffset
	local k = 0
	for _ = 1, triangleCount do
		local a = buffer.readu16(blob, p) + 1
		local b = buffer.readu16(blob, p + 2) + 1
		local c = buffer.readu16(blob, p + 4) + 1
		if a > vertexCount or b > vertexCount or c > vertexCount then
			error("MeshPack: triangle references a vertex out of range", 2)
		end
		triangles[k + 1] = a
		triangles[k + 2] = b
		triangles[k + 3] = c
		k += 3
		p += 6
	end

	return {
		vertexCount = vertexCount,
		triangleCount = triangleCount,
		bboxMin = bboxMin,
		bboxMax = bboxMax,
		positions = positions,
		normals = normals,
		uvs = uvs,
		triangles = triangles,
	}
end

return MeshPack
