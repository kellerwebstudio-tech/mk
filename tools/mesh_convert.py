"""Convert Meshy OBJ vehicles to Delivery Dash City conventions and split wheels.
Usage: convert.py <obj> <vehicleId> <targetLength> <rideHeight> <outdir> [wheelBandFraction]
Output: <outdir>/<Vehicle>_Body.obj, <Vehicle>_<Wheel>.obj, mtl, 1024px texture, meta.json, views png.
Conventions: +X right, +Y up, -Z forward; origin = chassis centre (rideHeight above ground).
"""
import sys, os, json, math
import numpy as np
from PIL import Image, ImageDraw
sys.path.insert(0, os.path.dirname(__file__))
from mesh_analyze import load_obj, render

obj, vid, target_len, ride_h, outdir = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4]), sys.argv[5]
wheel_frac = float(sys.argv[6]) if len(sys.argv) > 6 else 0.0
yaw_fix_deg = float(sys.argv[7]) if len(sys.argv) > 7 else 0.0  # extra rotation about Y applied after the forward fix
os.makedirs(outdir, exist_ok=True)
V, VT, VN, F = load_obj(obj)

# 1. rotate: old -X forward -> new -Z forward (rotation -90deg about Y): x' = -z, y' = y, z' = x
R = np.array([[0, 0, -1], [0, 1, 0], [1, 0, 0]], dtype=float)  # row i gives new coord i from old (x,y,z)
Vn = V @ R.T
VNn = VN @ R.T if len(VN) else VN
if yaw_fix_deg:
    a = math.radians(yaw_fix_deg)
    Ry = np.array([[math.cos(a), 0, math.sin(a)], [0, 1, 0], [-math.sin(a), 0, math.cos(a)]])
    Vn = Vn @ Ry.T
    VNn = VNn @ Ry.T if len(VNn) else VNn
# 2. scale to target length along Z
mn, mx = Vn.min(0), Vn.max(0)
scale = target_len / (mx[2] - mn[2])
Vn = Vn * scale
mn, mx = Vn.min(0), Vn.max(0)
# 3. translate: centre x and z on the bbox centre, wheels (min y) at -rideHeight
offset = np.array([-(mn[0] + mx[0]) / 2, -ride_h - mn[1], -(mn[2] + mx[2]) / 2])
Vn = Vn + offset
# centre x on the wheel contact patches (lowest vertices) rather than the bounding box, so an
# asymmetric handlebar or mirror does not shift the vehicle off its centreline
_L = Vn[:, 2].max() - Vn[:, 2].min()
_front = Vn[Vn[:, 2] < Vn[:, 2].min() + 0.25 * _L]
_rear = Vn[Vn[:, 2] > Vn[:, 2].max() - 0.25 * _L]
_centreline = ((_front[:, 0].min() + _front[:, 0].max()) / 2 + (_rear[:, 0].min() + _rear[:, 0].max()) / 2) / 2
xshift = -float(_centreline)
Vn[:, 0] += xshift
offset[0] += xshift
mn, mx = Vn.min(0), Vn.max(0)
size = mx - mn
print(f"{vid}: scale {scale:.4f}, size (w,h,l) = {np.round(size,3)}, bbox y [{mn[1]:.3f},{mx[1]:.3f}] (ground at {-ride_h})")

# 4. wheel detection (optional): robust circle fit in the YZ plane per wheel position
wheels = []
face_owner = np.zeros(len(F), dtype=int)  # 0 body, k = wheel k
r_range = {"Bicycle": (0.9, 1.45), "Scooter": (0.5, 1.0), "Van": (1.2, 1.8)}.get(vid, (0.5, 2.0))

def fit_circle(P, ground, zlo, zhi):
    """Grid-search a circle tangent to the ground (cy = ground + r) maximising rim coverage."""
    best = None
    for r in np.linspace(r_range[0], r_range[1], 45):
        cy = ground + r
        for cz in np.linspace(zlo + r * 0.5, zhi - r * 0.5, 80):
            d = np.sqrt((P[:, 2] - cz) ** 2 + (P[:, 1] - cy) ** 2)
            inl = np.abs(d - r) < 0.05 * r
            n = int(inl.sum())
            if n < 12:
                continue
            ang = np.arctan2(P[inl, 1] - cy, P[inl, 2] - cz)
            bins = np.unique(((ang + math.pi) / (2 * math.pi) * 24).astype(int) % 24)
            score = len(bins) * math.sqrt(n)
            if best is None or score > best[0]:
                best = (score, cz, cy, r, n, len(bins))
    return best

if wheel_frac > 0:
    H = size[1]; L = size[2]
    ground = mn[1]
    positions = [("Front", mn[2], 0.0), ("Rear", 0.0, mx[2])]
    sides = [("", None)] if vid != "Van" else [("L", -1), ("R", 1)]
    k = 0
    for pname, zlo, zhi in positions:
        for sname, sgn in sides:
            mask = (Vn[:, 2] >= zlo) & (Vn[:, 2] <= zhi) & (Vn[:, 1] < ground + wheel_frac * H)
            if sgn is not None:
                mask &= (np.sign(Vn[:, 0]) == sgn) & (np.abs(Vn[:, 0]) > 0.25 * size[0])
            P = Vn[mask]
            if len(P) < 30:
                continue
            best = fit_circle(P, ground, zlo, zhi)
            if best is None:
                continue
            score, cz, cy, r, n, nb = best
            # tyre width from the contact patch directly under the fitted circle (ignores forks, racks, stands)
            patch = P[(np.abs(P[:, 2] - cz) < 0.35 * r) & (P[:, 1] < ground + 0.12 * r)]
            if len(patch) < 4:
                patch = P[np.abs(np.sqrt((P[:, 2] - cz) ** 2 + (P[:, 1] - cy) ** 2) - r) < 0.05 * r]
            cx = float(np.median(patch[:, 0]))
            halfwidth = float(np.percentile(np.abs(patch[:, 0] - cx), 90)) + 0.04 * r
            k += 1
            sel = []
            for fi, face in enumerate(F):
                ok = True
                for (vi, _, _) in face:
                    q = Vn[vi]
                    if abs(q[0] - cx) > halfwidth * 1.15 or (q[2] - cz) ** 2 + (q[1] - cy) ** 2 > (r * 1.03) ** 2:
                        ok = False; break
                if ok:
                    sel.append(fi)
            for fi in sel:
                if face_owner[fi] == 0:
                    face_owner[fi] = k
            name = pname + "Wheel" + sname
            wheels.append({"name": name, "center": [cx, float(cy), float(cz)], "radius": float(r), "halfwidth": halfwidth, "faces": len(sel)})
            print(f"  {name}: centre ({cx:.3f},{cy:.3f},{cz:.3f}) r={r:.3f} width={2*halfwidth:.3f} faces={len(sel)} rim pts={n} bins={nb}/24")

def write_obj(path, faces, name, mtl, texname):
    used = sorted({f[0] for face in faces for f in face})
    remap = {v: i + 1 for i, v in enumerate(used)}
    usedt = sorted({f[1] for face in faces for f in face if f[1] >= 0})
    remapt = {v: i + 1 for i, v in enumerate(usedt)}
    usedn = sorted({f[2] for face in faces for f in face if f[2] >= 0})
    remapn = {v: i + 1 for i, v in enumerate(usedn)}
    with open(path, "w") as w:
        w.write(f"# Delivery Dash City vehicle mesh ({name}); units = studs; +X right, +Y up, -Z forward; origin = chassis centre\n")
        w.write(f"mtllib {mtl}\no {name}\n")
        for v in used:
            p = Vn[v]; w.write(f"v {p[0]:.5f} {p[1]:.5f} {p[2]:.5f}\n")
        for t in usedt:
            w.write(f"vt {VT[t][0]:.6f} {VT[t][1]:.6f}\n")
        for n in usedn:
            p = VNn[n]; w.write(f"vn {p[0]:.5f} {p[1]:.5f} {p[2]:.5f}\n")
        w.write("usemtl Material\n")
        for face in faces:
            w.write("f " + " ".join(f"{remap[vi]}/{remapt[ti] if ti>=0 else ''}/{remapn[ni] if ni>=0 else ''}" for (vi, ti, ni) in face) + "\n")

texsrc = [p for p in os.listdir(os.path.dirname(obj)) if p.lower().endswith(".png")][0]
tex_out = f"{vid}_Texture.png"
im = Image.open(os.path.join(os.path.dirname(obj), texsrc)).convert("RGB").resize((1024, 1024), Image.LANCZOS)
im.save(os.path.join(outdir, tex_out), optimize=True)
mtl_out = f"{vid}.mtl"
with open(os.path.join(outdir, mtl_out), "w") as w:
    w.write(f"newmtl Material\nKa 1 1 1\nKd 1 1 1\nKs 0 0 0\nd 1\nillum 1\nmap_Kd {tex_out}\n")

meta = {"vehicleId": vid, "scale": scale, "size": size.tolist(), "bboxMin": mn.tolist(), "bboxMax": mx.tolist(), "rideHeight": ride_h, "parts": []}
if wheel_frac > 0 and wheels:
    body = [F[i] for i in range(len(F)) if face_owner[i] == 0]
    write_obj(os.path.join(outdir, f"{vid}_Body.obj"), body, f"{vid}_Body", mtl_out, tex_out)
    bb = Vn[sorted({f[0] for face in body for f in face})]
    meta["parts"].append({"name": "Body", "faces": len(body), "bboxMin": bb.min(0).tolist(), "bboxMax": bb.max(0).tolist()})
    for k, wh in enumerate(wheels, start=1):
        faces = [F[i] for i in range(len(F)) if face_owner[i] == k]
        if not faces:
            continue
        # wheel OBJ is written RELATIVE to its own centre so the MeshPart pivot = axle
        saved = Vn.copy()
        Vn = Vn - np.array(wh["center"])
        write_obj(os.path.join(outdir, f"{vid}_{wh['name']}.obj"), faces, f"{vid}_{wh['name']}", mtl_out, tex_out)
        Vn = saved
        wb = Vn[sorted({f[0] for face in faces for f in face})]
        meta["parts"].append({"name": wh["name"], "faces": len(faces), "center": wh["center"], "radius": wh["radius"], "bboxMin": wb.min(0).tolist(), "bboxMax": wb.max(0).tolist()})
else:
    write_obj(os.path.join(outdir, f"{vid}_Body.obj"), F, f"{vid}_Body", mtl_out, tex_out)
    meta["parts"].append({"name": "Body", "faces": len(F), "bboxMin": mn.tolist(), "bboxMax": mx.tolist()})
json.dump(meta, open(os.path.join(outdir, "meta.json"), "w"), indent=1)

# verification render of the body and wheels in new coordinates (side: z right? we show -Z to the left = forward left)
render(Vn, F, os.path.join(outdir, f"{vid}_converted.png"), [("side (z right, y up): forward is LEFT", 2, 1, 0, False), ("top (x right, z up)", 0, 2, 1, False), ("front (x right, y up)", 0, 1, 2, False)])
if wheel_frac > 0 and wheels:
    # colour-coded split render
    size_px = 700
    img = Image.new("RGB", (size_px, size_px), (240, 240, 240)); d = ImageDraw.Draw(img)
    ext = size.max()
    order = sorted(range(len(F)), key=lambda i: Vn[[f[0] for f in F[i]]][:, 0].mean())
    for i in order:
        P = Vn[[f[0] for f in F[i]]]
        poly = [(40 + (p[2] - mn[2]) / ext * (size_px - 80), size_px - 40 - (p[1] - mn[1]) / ext * (size_px - 80)) for p in P]
        col = [(190, 180, 170), (200, 60, 60), (60, 90, 220), (60, 170, 90), (200, 160, 40)][face_owner[i]]
        d.polygon(poly, fill=col)
    img.save(os.path.join(outdir, f"{vid}_wheelsplit.png"))
print(json.dumps(meta["parts"], indent=0)[:600])
