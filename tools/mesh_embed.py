#!/usr/bin/env python3
"""Pack converted vehicle meshes (assets/meshes/<Vehicle>/<Vehicle>_Body.obj + texture) into
Luau data modules under src/shared/MeshData/<Vehicle>/ so the game can rebuild them at runtime
with EditableMesh / EditableImage (no Roblox upload needed).

Geometry binary format "DDCM" v1 (little-endian):
  magic "DDCM" | u16 version=1 | u16 flags=0 | u32 vertexCount | u32 triangleCount
  f32 bboxMin[3] | f32 bboxMax[3]
  positions f32[3] * vertexCount
  normals   i8[3]  * vertexCount   (unit normal * 127)
  uvs       u16[2] * vertexCount   (u, 1-v) * 65535  -> Roblox UV origin is top-left
  triangles u16[3] * triangleCount (0-based vertex ids)
Vertices are "split" per unique (position, uv, normal) combination so every vertex owns one UV/normal.
Texture: the PNG file bytes (8-bit RGB/RGBA, non-interlaced) decoded at runtime by PngDecoder.
Both blobs are base64 and split into chunk ModuleScripts of at most CHUNK characters.
"""
import sys, os, struct, base64, json, io
import numpy as np
from PIL import Image

CHUNK = 150_000  # characters per ModuleScript chunk (keeps every script well under Studio limits)
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")

def load_obj(path):
    V, VT, VN, F = [], [], [], []
    for line in open(path, encoding="utf-8", errors="ignore"):
        if line.startswith("v "):
            V.append([float(x) for x in line.split()[1:4]])
        elif line.startswith("vt "):
            VT.append([float(x) for x in line.split()[1:3]])
        elif line.startswith("vn "):
            VN.append([float(x) for x in line.split()[1:4]])
        elif line.startswith("f "):
            face = []
            for tok in line.split()[1:]:
                p = tok.split("/")
                face.append((int(p[0]) - 1, int(p[1]) - 1 if len(p) > 1 and p[1] else -1, int(p[2]) - 1 if len(p) > 2 and p[2] else -1))
            # triangulate fans
            for k in range(1, len(face) - 1):
                F.append((face[0], face[k], face[k + 1]))
    return np.array(V, dtype=np.float64), np.array(VT, dtype=np.float64), np.array(VN, dtype=np.float64), F

def pack_geometry(obj_path):
    V, VT, VN, F = load_obj(obj_path)
    # face normals fallback when a face has no vn
    keymap = {}
    positions, normals, uvs, tris = [], [], [], []
    for tri in F:
        ids = []
        p0, p1, p2 = V[tri[0][0]], V[tri[1][0]], V[tri[2][0]]
        fn = np.cross(p1 - p0, p2 - p0)
        nl = np.linalg.norm(fn)
        fn = fn / nl if nl > 1e-12 else np.array([0, 1, 0])
        for (vi, ti, ni) in tri:
            key = (vi, ti, ni)
            idx = keymap.get(key)
            if idx is None:
                idx = len(positions)
                keymap[key] = idx
                positions.append(V[vi])
                n = VN[ni] if ni >= 0 and len(VN) else fn
                nn = np.linalg.norm(n)
                normals.append(n / nn if nn > 1e-12 else fn)
                uv = VT[ti] if ti >= 0 and len(VT) else np.array([0.0, 0.0])
                uvs.append([float(np.clip(uv[0], 0, 1)), float(np.clip(1.0 - uv[1], 0, 1))])  # flip V for Roblox
            ids.append(idx)
        tris.append(ids)
    assert len(positions) < 65535, "too many split vertices for u16 indices"
    P = np.array(positions, dtype=np.float32)
    bmin, bmax = P.min(0), P.max(0)
    out = io.BytesIO()
    out.write(b"DDCM"); out.write(struct.pack("<HHII", 1, 0, len(positions), len(tris)))
    out.write(struct.pack("<3f", *bmin)); out.write(struct.pack("<3f", *bmax))
    out.write(P.astype("<f4").tobytes())
    N = np.clip(np.round(np.array(normals) * 127), -127, 127).astype(np.int8)
    out.write(N.tobytes())
    U = np.clip(np.round(np.array(uvs) * 65535), 0, 65535).astype("<u2")
    out.write(U.tobytes())
    T = np.array(tris, dtype="<u2")
    out.write(T.tobytes())
    return out.getvalue(), {"vertexCount": len(positions), "triangleCount": len(tris), "bboxMin": bmin.tolist(), "bboxMax": bmax.tolist()}

def pack_texture(png_path, max_size):
    im = Image.open(png_path).convert("RGB")
    if max(im.size) > max_size:
        im = im.resize((max_size, max_size), Image.LANCZOS)
    buf = io.BytesIO()
    im.save(buf, format="PNG", optimize=True, compress_level=9)
    return buf.getvalue(), im.size

def write_module(path, text):
    with open(path, "w") as w:
        w.write(text)

def luau_string_chunks(b64):
    return [b64[i:i + CHUNK] for i in range(0, len(b64), CHUNK)]

def emit(vehicle_id, obj_path, png_path, out_dir, max_tex):
    geo, meta = pack_geometry(obj_path)
    tex, (tw, th) = pack_texture(png_path, max_tex)
    os.makedirs(out_dir, exist_ok=True)
    for f in os.listdir(out_dir):
        if f.endswith(".luau"):
            os.remove(os.path.join(out_dir, f))
    g64 = base64.b64encode(geo).decode("ascii")
    t64 = base64.b64encode(tex).decode("ascii")
    gchunks = luau_string_chunks(g64)
    tchunks = luau_string_chunks(t64)
    for i, c in enumerate(gchunks, 1):
        write_module(os.path.join(out_dir, f"G{i}.luau"), f'--!nocheck\n-- generated by tools/mesh_embed.py: {vehicle_id} geometry chunk {i}/{len(gchunks)}\nreturn "{c}"\n')
    for i, c in enumerate(tchunks, 1):
        write_module(os.path.join(out_dir, f"T{i}.luau"), f'--!nocheck\n-- generated by tools/mesh_embed.py: {vehicle_id} texture chunk {i}/{len(tchunks)}\nreturn "{c}"\n')
    index = f'''--!strict
-- generated by tools/mesh_embed.py; do not edit by hand (re-run the tool instead)
-- Embedded mesh data for {vehicle_id}: base64 chunks of a DDCM geometry blob and a PNG texture.
return {{
	vehicleId = "{vehicle_id}",
	version = 1,
	geometry = {{ chunks = {len(gchunks)}, bytes = {len(geo)}, vertexCount = {meta["vertexCount"]}, triangleCount = {meta["triangleCount"]}, bboxMin = {{ {meta["bboxMin"][0]:.4f}, {meta["bboxMin"][1]:.4f}, {meta["bboxMin"][2]:.4f} }}, bboxMax = {{ {meta["bboxMax"][0]:.4f}, {meta["bboxMax"][1]:.4f}, {meta["bboxMax"][2]:.4f} }} }},
	texture = {{ chunks = {len(tchunks)}, bytes = {len(tex)}, width = {tw}, height = {th}, format = "png" }},
}}
'''
    write_module(os.path.join(out_dir, "init.luau"), index)
    print(f"{vehicle_id}: geometry {len(geo):,} B ({meta['vertexCount']} verts, {meta['triangleCount']} tris) -> {len(gchunks)} chunk(s); texture {len(tex):,} B {tw}x{th} -> {len(tchunks)} chunk(s); base64 total {len(g64)+len(t64):,} chars")
    return meta

if __name__ == "__main__":
    max_tex = int(sys.argv[1]) if len(sys.argv) > 1 else 1024
    report = {}
    for vid in ("Bicycle", "Scooter", "Van"):
        d = os.path.join(ROOT, "assets", "meshes", vid)
        report[vid] = emit(vid, os.path.join(d, f"{vid}_Body.obj"), os.path.join(d, f"{vid}_Texture.png"), os.path.join(ROOT, "src", "shared", "MeshData", vid), max_tex)
    json.dump(report, open(os.path.join(ROOT, "src", "shared", "MeshData", "report.json"), "w"), indent=1)
