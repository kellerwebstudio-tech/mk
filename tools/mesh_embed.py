#!/usr/bin/env python3
"""Pack meshes into Luau data modules under src/shared/MeshData/<Id>/ so the game rebuilds them at
runtime with EditableMesh / EditableImage (no Roblox upload needed).

Usage: python3 -I tools/mesh_embed.py            (re-emits every entry of MANIFEST)
       python3 -I tools/mesh_embed.py Bicycle NPCStaff   (only those ids)

Index module format v2 (src/shared/MeshData/<Id>/init.luau):
  { id, version = 2, kind = "vehicle"|"figure"|"accessory",
    texture = { chunks = n, bytes, width, height } | nil      (T1..Tn chunk ModuleScripts, PNG bytes)
    parts = { { name, chunks = {"Body_G1", ...}, bytes, vertexCount, triangleCount, bboxMin, bboxMax, pivot? } ... } }
Geometry blob per part: "DDCM" v1 (see pack_geometry). Coordinates are in the entry's own frame:
  vehicles: origin = chassis centre (rideHeight above ground), -Z forward
  figures:  origin = between the feet on the ground, -Z forward, height HEIGHT_FIGURE studs
  accessory (vest): origin = mesh centre, -Z forward
Leg parts of figures are written RELATIVE to their hip pivot so a MeshPart made from them is centred on
its own bounds; `pivot` is the hip point in figure coordinates (Motor6D C0), and bboxMin/bboxMax are in
figure coordinates too, so C1 = pivot - bboxCentre.
"""
import sys, os, io, json, math, struct, base64, glob
import numpy as np
from PIL import Image

CHUNK = 150_000
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
ASSETS = os.path.join(ROOT, "assets", "meshes")
OUT = os.path.join(ROOT, "src", "shared", "MeshData")
HEIGHT_FIGURE = 5.2  # studs (R15 is about 5)
UPLOADS = "/root/.claude/uploads/3419e611-d3a8-57fd-a159-26d72f1bea4b"  # original Meshy zips (dev machine only)

# Source OBJ for figures/accessory: a converted copy is kept under assets/meshes/<Id>/<Id>_Source.obj so the
# repository is self-contained; the first run copies it from `source` when present.
MANIFEST = [
    # vehicles: already converted (assets/meshes/<Id>/<Id>_Body.obj is in game coordinates)
    {"id": "Bicycle", "kind": "vehicle", "texture": 1024},
    {"id": "Scooter", "kind": "vehicle", "texture": 1024},
    {"id": "Van", "kind": "vehicle", "texture": 1024},
    # people: Meshy figures facing +Z -> rotate 180; origin at the feet; legs split at the hip
    {"id": "NPCCustomerA", "kind": "figure", "texture": 512, "source": "customerA"},
    {"id": "NPCCustomerB", "kind": "figure", "texture": 512, "source": "customerB"},
    {"id": "NPCStaff", "kind": "figure", "texture": 512, "source": "staff"},
    {"id": "NPCWorker", "kind": "figure", "texture": 512, "source": "worker"},
    {"id": "NPCDriver", "kind": "figure", "texture": 512, "source": "driver"},
    {"id": "NPCPedestrianA", "kind": "figure", "texture": 512, "source": "pedA"},
    {"id": "NPCPedestrianB", "kind": "figure", "texture": 512, "source": "pedB"},
    {"id": "NPCPedestrianC", "kind": "figure", "texture": 512, "source": "pedC"},
    # courier vest: untextured, tinted at runtime; fitted to an R15 UpperTorso (2 x 1.6 x 1 studs)
    {"id": "CourierVest", "kind": "accessory", "texture": None, "source": "vest", "fit": (2.3, 1.9, 1.3)},
]
HIP_FRACTION = 0.46     # legs = everything below this fraction of the height, split left/right
SOURCE_SCRATCH = os.path.join(os.environ.get("DDC_SCRATCH", "/tmp/claude-0/-home-user-mk/3419e611-d3a8-57fd-a159-26d72f1bea4b/scratchpad"), "npcmeshes")

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
            for k in range(1, len(face) - 1):
                F.append((face[0], face[k], face[k + 1]))
    return np.array(V, dtype=np.float64), np.array(VT, dtype=np.float64), np.array(VN, dtype=np.float64), F

def write_obj(path, V, VT, VN, F, name, mtl=None, tex=None):
    with open(path, "w") as w:
        w.write(f"# Delivery Dash City mesh ({name}); units = studs; +X right, +Y up, -Z forward\n")
        if mtl:
            w.write(f"mtllib {mtl}\n")
        w.write(f"o {name}\n")
        for p in V:
            w.write(f"v {p[0]:.5f} {p[1]:.5f} {p[2]:.5f}\n")
        for t in VT:
            w.write(f"vt {t[0]:.6f} {t[1]:.6f}\n")
        for n in VN:
            w.write(f"vn {n[0]:.5f} {n[1]:.5f} {n[2]:.5f}\n")
        if mtl:
            w.write("usemtl Material\n")
        for face in F:
            w.write("f " + " ".join(f"{vi+1}/{ti+1 if ti>=0 else ''}/{ni+1 if ni>=0 else ''}" for (vi, ti, ni) in face) + "\n")

def pack_geometry(V, VT, VN, F, origin_shift=None):
    """DDCM v1 blob from split vertices. origin_shift (np.array) is subtracted from positions."""
    keymap, positions, normals, uvs, tris = {}, [], [], [], []
    shift = origin_shift if origin_shift is not None else np.zeros(3)
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
                positions.append(V[vi] - shift)
                n = VN[ni] if ni >= 0 and len(VN) else fn
                nn = np.linalg.norm(n)
                normals.append(n / nn if nn > 1e-12 else fn)
                uv = VT[ti] if ti >= 0 and len(VT) else np.array([0.0, 0.0])
                uvs.append([float(np.clip(uv[0], 0, 1)), float(np.clip(1.0 - uv[1], 0, 1))])
            ids.append(idx)
        tris.append(ids)
    assert len(positions) < 65535, "too many split vertices for u16 indices"
    P = np.array(positions, dtype=np.float32)
    bmin, bmax = P.min(0), P.max(0)
    out = io.BytesIO()
    out.write(b"DDCM"); out.write(struct.pack("<HHII", 1, 0, len(positions), len(tris)))
    out.write(struct.pack("<3f", *bmin)); out.write(struct.pack("<3f", *bmax))
    out.write(P.astype("<f4").tobytes())
    out.write(np.clip(np.round(np.array(normals) * 127), -127, 127).astype(np.int8).tobytes())
    out.write(np.clip(np.round(np.array(uvs) * 65535), 0, 65535).astype("<u2").tobytes())
    out.write(np.array(tris, dtype="<u2").tobytes())
    return out.getvalue(), {"vertexCount": len(positions), "triangleCount": len(tris), "bboxMin": (bmin + shift).tolist(), "bboxMax": (bmax + shift).tolist()}

def pack_texture(png_path, max_size):
    im = Image.open(png_path).convert("RGB")
    if max(im.size) > max_size:
        im = im.resize((max_size, max_size), Image.LANCZOS)
    buf = io.BytesIO()
    im.save(buf, format="PNG", optimize=True, compress_level=9)
    return buf.getvalue(), im.size

def find_source(entry):
    """Returns (obj path, png path or None) for a figure/accessory: assets copy first, else the scratch unzip."""
    d = os.path.join(ASSETS, entry["id"])
    kept = os.path.join(d, f"{entry['id']}_Source.obj")
    if os.path.exists(kept):
        pngs = glob.glob(os.path.join(d, f"{entry['id']}_Source.png"))
        return kept, (pngs[0] if pngs else None)
    scratch = os.path.join(SOURCE_SCRATCH, entry["source"])
    objs = glob.glob(os.path.join(scratch, "*", "*.obj"))
    if not objs:
        raise SystemExit(f"no source OBJ for {entry['id']} (expected {kept} or an unzip under {scratch})")
    pngs = glob.glob(os.path.join(scratch, "*", "*.png"))
    os.makedirs(d, exist_ok=True)
    # keep a copy of the raw source in the repo so re-runs do not need the zips
    V, VT, VN, F = load_obj(objs[0])
    write_obj(kept, V, VT, VN, F, f"{entry['id']}_Source", mtl=f"{entry['id']}_Source.mtl" if pngs else None)
    if pngs:
        Image.open(pngs[0]).convert("RGB").resize((1024, 1024), Image.LANCZOS).save(os.path.join(d, f"{entry['id']}_Source.png"), optimize=True)
        with open(os.path.join(d, f"{entry['id']}_Source.mtl"), "w") as w:
            w.write(f"newmtl Material\nKd 1 1 1\nmap_Kd {entry['id']}_Source.png\n")
        return kept, os.path.join(d, f"{entry['id']}_Source.png")
    return kept, None

def rotate_y(V, VN, degrees):
    a = math.radians(degrees)
    R = np.array([[math.cos(a), 0, math.sin(a)], [0, 1, 0], [-math.sin(a), 0, math.cos(a)]])
    return V @ R.T, (VN @ R.T if len(VN) else VN)

def convert_figure(entry):
    obj, png = find_source(entry)
    V, VT, VN, F = load_obj(obj)
    V, VN = rotate_y(V, VN, 180)                      # Meshy figures face +Z; Roblox forward is -Z
    mn, mx = V.min(0), V.max(0)
    V = V * (HEIGHT_FIGURE / (mx[1] - mn[1]))
    mn, mx = V.min(0), V.max(0)
    V = V - np.array([(mn[0] + mx[0]) / 2, mn[1], (mn[2] + mx[2]) / 2])  # feet on the ground, centred
    mn, mx = V.min(0), V.max(0)
    hip_y = HIP_FRACTION * HEIGHT_FIGURE
    parts = {"Body": [], "LegL": [], "LegR": []}
    # Candidate leg faces: every vertex below the hip line. Hands hang below the hip too, so keep only
    # the connected pieces that reach the ground (legs) and return the rest (hand bottoms) to the body.
    below = [i for i, tri in enumerate(F) if (V[[t[0] for t in tri], 1] < hip_y).all()]
    parent = {}
    def find(a):
        while parent.setdefault(a, a) != a:
            parent[a] = parent[parent[a]]; a = parent[a]
        return a
    def union(a, b):
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[ra] = rb
    vert_face = {}
    for i in below:
        for t in F[i]:
            vert_face.setdefault(t[0], []).append(i)
    for faces in vert_face.values():
        for j in faces[1:]:
            union(faces[0], j)
    comp_faces = {}
    for i in below:
        comp_faces.setdefault(find(i), []).append(i)
    leg_faces = set()
    for faces in comp_faces.values():
        verts = {t[0] for i in faces for t in F[i]}
        if V[list(verts), 1].min() < 0.05 * HEIGHT_FIGURE:  # touches the ground -> a leg
            leg_faces.update(faces)
    for i, tri in enumerate(F):
        if i in leg_faces:
            P = V[[t[0] for t in tri]]
            parts["LegL" if P[:, 0].mean() < 0 else "LegR"].append(tri)
        else:
            parts["Body"].append(tri)
    out = []
    for name in ("Body", "LegL", "LegR"):
        faces = parts[name]
        if not faces:
            continue
        pivot = None
        shift = None
        if name != "Body":
            P = V[sorted({t[0] for face in faces for t in face})]
            pivot = np.array([(P[:, 0].min() + P[:, 0].max()) / 2, hip_y, (P[:, 2].min() + P[:, 2].max()) / 2])
            shift = pivot
        blob, meta = pack_geometry(V, VT, VN, faces, origin_shift=shift)
        meta["name"] = name
        if pivot is not None:
            meta["pivot"] = pivot.tolist()
        out.append((blob, meta))
    # converted reference OBJ (whole figure) for inspection
    d = os.path.join(ASSETS, entry["id"])
    write_obj(os.path.join(d, f"{entry['id']}_Body.obj"), V, VT, VN, F, f"{entry['id']}_Body", mtl=f"{entry['id']}_Source.mtl" if png else None)
    return out, png, (mn, mx)

def convert_accessory(entry):
    obj, png = find_source(entry)
    V, VT, VN, F = load_obj(obj)
    V, VN = rotate_y(V, VN, 180)
    mn, mx = V.min(0), V.max(0)
    fit = np.array(entry["fit"])
    V = (V - (mn + mx) / 2) * (fit / (mx - mn))        # non-uniform fit, centred on the origin
    if len(VN):
        VN = VN / np.maximum(np.linalg.norm(VN, axis=1, keepdims=True), 1e-9)
    blob, meta = pack_geometry(V, VT, VN, F)
    meta["name"] = "Body"
    d = os.path.join(ASSETS, entry["id"]); os.makedirs(d, exist_ok=True)
    write_obj(os.path.join(d, f"{entry['id']}_Body.obj"), V, VT, VN, F, f"{entry['id']}_Body")
    return [(blob, meta)], png, (V.min(0), V.max(0))

def convert_vehicle(entry):
    d = os.path.join(ASSETS, entry["id"])
    V, VT, VN, F = load_obj(os.path.join(d, f"{entry['id']}_Body.obj"))
    blob, meta = pack_geometry(V, VT, VN, F)
    meta["name"] = "Body"
    return [(blob, meta)], os.path.join(d, f"{entry['id']}_Texture.png"), (V.min(0), V.max(0))

def emit(entry):
    kind = entry["kind"]
    parts, png, bbox = {"vehicle": convert_vehicle, "figure": convert_figure, "accessory": convert_accessory}[kind](entry)
    out_dir = os.path.join(OUT, entry["id"])
    os.makedirs(out_dir, exist_ok=True)
    for f in os.listdir(out_dir):
        if f.endswith(".luau"):
            os.remove(os.path.join(out_dir, f))
    def chunks(b64):
        return [b64[i:i + CHUNK] for i in range(0, len(b64), CHUNK)]
    part_entries = []
    total_chars = 0
    for blob, meta in parts:
        b64 = base64.b64encode(blob).decode("ascii")
        names = []
        for i, c in enumerate(chunks(b64), 1):
            name = f"{meta['name']}_G{i}"
            names.append(name)
            with open(os.path.join(out_dir, f"{name}.luau"), "w") as w:
                w.write(f'--!nocheck\n-- generated by tools/mesh_embed.py: {entry["id"]} {meta["name"]} geometry chunk {i}\nreturn "{c}"\n')
        total_chars += len(b64)
        part_entries.append((meta, names, len(blob)))
    tex_entry = "nil"
    if png and entry.get("texture"):
        tex, (tw, th) = pack_texture(png, entry["texture"])
        t64 = base64.b64encode(tex).decode("ascii")
        tchunks = chunks(t64)
        for i, c in enumerate(tchunks, 1):
            with open(os.path.join(out_dir, f"T{i}.luau"), "w") as w:
                w.write(f'--!nocheck\n-- generated by tools/mesh_embed.py: {entry["id"]} texture chunk {i}/{len(tchunks)}\nreturn "{c}"\n')
        total_chars += len(t64)
        tex_entry = f"{{ chunks = {len(tchunks)}, bytes = {len(tex)}, width = {tw}, height = {th}, format = \"png\" }}"
    def v3(v):
        return f"{{ {v[0]:.4f}, {v[1]:.4f}, {v[2]:.4f} }}"
    lines = []
    for meta, names, nbytes in part_entries:
        pivot = f", pivot = {v3(meta['pivot'])}" if "pivot" in meta else ""
        chunk_list = ", ".join(f'"{n}"' for n in names)
        lines.append(f"\t\t{{ name = \"{meta['name']}\", chunks = {{ {chunk_list} }}, bytes = {nbytes}, vertexCount = {meta['vertexCount']}, triangleCount = {meta['triangleCount']}, bboxMin = {v3(meta['bboxMin'])}, bboxMax = {v3(meta['bboxMax'])}{pivot} }},")
    index = f'''--!strict
-- generated by tools/mesh_embed.py; do not edit by hand (re-run the tool instead)
-- Embedded mesh data for {entry["id"]} ({kind}); see the tool's docstring for the format.
return {{
	id = "{entry["id"]}",
	version = 2,
	kind = "{kind}",
	texture = {tex_entry},
	bboxMin = {v3(bbox[0])},
	bboxMax = {v3(bbox[1])},
	parts = {{
{chr(10).join(lines)}
	}},
}}
'''
    with open(os.path.join(out_dir, "init.luau"), "w") as w:
        w.write(index)
    print(f"{entry['id']:15s} {kind:9s} parts={len(part_entries)} tris={sum(m['triangleCount'] for m,_,_ in part_entries):5d} texture={'none' if tex_entry=='nil' else entry['texture']} base64={total_chars:,} chars; bbox {np.round(bbox[0],2)}..{np.round(bbox[1],2)}")

if __name__ == "__main__":
    wanted = set(sys.argv[1:])
    for entry in MANIFEST:
        if wanted and entry["id"] not in wanted:
            continue
        emit(entry)
