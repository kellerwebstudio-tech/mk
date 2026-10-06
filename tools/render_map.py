#!/usr/bin/env python3
"""Render a top-down map of CityLayout to docs/map.png (1 px = 1 stud).

Runs tools/export_layout.py (luau bundle -> JSON) and draws water, park, greenbelt, roads by kind and width,
buildings by style, business/destination markers, depot plots, hub, landmarks, parked vehicles, props
and pedestrian loops, plus a legend.
"""
from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, str(Path(__file__).resolve().parent))
from export_layout import export  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
OUT = REPO / "docs" / "map.png"

SCALE = 1.0
MARGIN = 20
LEGEND_H = 150

ROAD_COLORS = {
    "Road": (70, 70, 78),
    "Street": (105, 105, 112),
    "Alley": (150, 120, 90),
    "BikePath": (120, 170, 90),
    "Bridge": (95, 85, 70),
    "BikeBridge": (170, 140, 70),
    "Industrial": (60, 62, 70),
    "Ramp": (120, 110, 95),
}
STYLE_COLORS = {
    "Shop": (235, 190, 120),
    "Apartment": (200, 160, 140),
    "House": (230, 215, 170),
    "Warehouse": (150, 160, 175),
    "Tower": (120, 100, 160),
    "Hub": (255, 120, 60),
    "Office": (170, 185, 205),
    "Cafe": (160, 110, 70),
    "Market": (120, 190, 120),
    "Pizza": (220, 80, 60),
}
PROP_COLORS = {
    "Tree": (40, 120, 50),
    "Lamp": (250, 220, 90),
    "Bench": (120, 80, 40),
    "Hydrant": (220, 40, 40),
    "Planter": (90, 160, 90),
    "Crate": (170, 120, 60),
    "Container": (60, 110, 170),
    "Dumpster": (70, 90, 70),
    "Sign": (240, 240, 240),
    "Cone": (255, 140, 0),
}


def main() -> int:
    layout = export()
    b = layout["bounds"]
    width = int((b["maxX"] - b["minX"]) * SCALE) + 2 * MARGIN
    height = int((b["maxZ"] - b["minZ"]) * SCALE) + 2 * MARGIN
    img = Image.new("RGB", (width, height + LEGEND_H), (214, 208, 190))
    draw = ImageDraw.Draw(img, "RGBA")
    try:
        font = ImageFont.load_default(size=11)
        font_big = ImageFont.load_default(size=14)
    except TypeError:  # very old Pillow
        font = ImageFont.load_default()
        font_big = font

    def P(x: float, z: float) -> tuple[float, float]:
        return (MARGIN + (x - b["minX"]) * SCALE, MARGIN + (z - b["minZ"]) * SCALE)

    def rect(x: float, z: float, w: float, d: float, fill, outline=None):
        x0, z0 = P(x - w / 2, z - d / 2)
        x1, z1 = P(x + w / 2, z + d / 2)
        draw.rectangle([x0, z0, x1, z1], fill=fill, outline=outline)

    # Neighbourhood tints
    for nb in layout["neighborhoods"]:
        nbb = nb["bounds"]
        a = nb["accent"]
        tint = (int(a["r"] * 255), int(a["g"] * 255), int(a["b"] * 255), 28)
        x0, z0 = P(nbb["minX"], nbb["minZ"])
        x1, z1 = P(nbb["maxX"], nbb["maxZ"])
        draw.rectangle([x0, z0, x1, z1], fill=tint, outline=(0, 0, 0, 40))
        draw.text((x0 + 6, z0 + 4), nb["name"], fill=(40, 40, 40), font=font_big)

    # Greenbelt / rail strip
    x0, z0 = P(b["minX"], 200)
    x1, z1 = P(b["maxX"], 250)
    draw.rectangle([x0, z0, x1, z1], fill=(150, 180, 120))
    x0, z0 = P(b["minX"], 224)
    x1, z1 = P(b["maxX"], 226)
    draw.rectangle([x0, z0, x1, z1], fill=(90, 80, 70))

    # Park
    park = layout["landmarks"]["park"]
    rect(park["x"], park["z"], park["w"], park["d"], (140, 195, 120))

    # Plaza
    plaza = layout["landmarks"]["plaza"]
    cx, cz = P(plaza["x"], plaza["z"])
    r = plaza["r"] * SCALE
    draw.ellipse([cx - r, cz - r, cx + r, cz + r], fill=(225, 215, 195), outline=(180, 170, 150))

    # Water
    for w in layout["water"]:
        rect(w["x"], w["z"], w["w"], w["d"], (90, 150, 210))

    # Depot plots
    for plot in layout["depotPlots"]:
        rect(plot["x"], plot["z"], plot["w"], plot["d"], (235, 225, 160), outline=(160, 140, 60))
        px, pz = P(plot["x"], plot["z"])
        draw.text((px - 8, pz - 6), plot["id"], fill=(80, 60, 0), font=font)

    # Roads (sort so thin bike paths draw on top of wide roads)
    order = {"Industrial": 0, "Road": 1, "Bridge": 2, "Ramp": 2, "Street": 3, "Alley": 4, "BikePath": 5, "BikeBridge": 5}
    roads = sorted(layout["roads"], key=lambda r: order.get(r["kind"], 9))
    for road in roads:
        pts = [P(p["x"], p["z"]) for p in road["points"]]
        color = ROAD_COLORS.get(road["kind"], (0, 0, 0))
        wpx = max(1, int(road["width"] * SCALE))
        draw.line(pts, fill=color, width=wpx, joint="curve")
        # round the ends so junctions look clean
        for (x, z) in (pts[0], pts[-1]):
            draw.ellipse([x - wpx / 2, z - wpx / 2, x + wpx / 2, z + wpx / 2], fill=color)
        if road["kind"] in ("Bridge", "BikeBridge"):
            draw.line(pts, fill=(240, 230, 200), width=1)
        if road["kind"] == "Alley":
            draw.line(pts, fill=(255, 230, 170), width=1)

    # Pedestrian loops
    for path in layout["pedestrianPaths"]:
        pts = [P(p["x"], p["z"]) for p in path["points"]]
        if path.get("loop"):
            pts.append(pts[0])
        draw.line(pts, fill=(255, 255, 255, 160), width=1)

    # Buildings
    for bd in layout["buildings"]:
        color = STYLE_COLORS.get(bd["style"], (200, 200, 200))
        if bd.get("baseY", 0) > 0:
            color = tuple(min(255, c + int(bd["baseY"] * 6)) for c in color)
        rect(bd["x"], bd["z"], bd["w"], bd["d"], color, outline=(60, 50, 40))

    # Landmarks
    lm = layout["landmarks"]
    tx, tz = P(lm["tower"]["x"], lm["tower"]["z"])
    draw.ellipse([tx - 6, tz - 6, tx + 6, tz + 6], fill=(90, 60, 150), outline=(255, 255, 255))
    draw.text((tx + 8, tz - 6), "Beacon Tower", fill=(40, 20, 80), font=font)
    wx, wz = P(lm["waterTower"]["x"], lm["waterTower"]["z"])
    draw.ellipse([wx - 9, wz - 9, wx + 9, wz + 9], fill=(90, 130, 190), outline=(255, 255, 255))
    draw.text((wx + 11, wz - 6), "Water tower", fill=(20, 40, 90), font=font)

    # Hub
    hub = layout["hub"]
    for pad in hub["vehiclePads"]:
        rect(pad["x"], pad["z"], 8, 6, (255, 200, 80), outline=(120, 80, 0))
    sx, sz = P(hub["spawn"]["x"], hub["spawn"]["z"])
    draw.ellipse([sx - 4, sz - 4, sx + 4, sz + 4], fill=(255, 60, 60), outline=(255, 255, 255))
    draw.text((sx + 6, sz - 6), "Hub spawn", fill=(120, 0, 0), font=font)

    # Parked vehicles
    for v in layout["parkedVehicles"]:
        size = (12, 6) if v["kind"] == "Car" else (18, 8)
        if v["rot"] % 180 == 0:
            size = (size[1], size[0])
        c = v["color"]
        rect(v["x"], v["z"], size[0], size[1], (int(c["r"] * 255), int(c["g"] * 255), int(c["b"] * 255)), outline=(0, 0, 0))

    # Props
    for p in layout["props"]:
        color = PROP_COLORS.get(p["type"], (0, 0, 0))
        x, z = P(p["x"], p["z"])
        rad = 3 if p["type"] in ("Tree", "Container") else 1.5
        draw.ellipse([x - rad, z - rad, x + rad, z + rad], fill=color)

    # Destinations
    for d in layout["destinations"]:
        ax, az = P(d["arrivalPoint"]["x"], d["arrivalPoint"]["z"])
        dx, dz = P(d["door"]["x"], d["door"]["z"])
        draw.line([(ax, az), (dx, dz)], fill=(0, 120, 200), width=1)
        draw.ellipse([ax - 4, az - 4, ax + 4, az + 4], fill=(0, 140, 230), outline=(255, 255, 255))
        draw.text((ax + 5, az - 12), d["id"], fill=(0, 50, 120), font=font)

    # Businesses
    for bz in layout["businesses"]:
        ax, az = P(bz["arrivalPoint"]["x"], bz["arrivalPoint"]["z"])
        dx, dz = P(bz["door"]["x"], bz["door"]["z"])
        draw.line([(ax, az), (dx, dz)], fill=(200, 0, 100), width=1)
        draw.polygon([(ax, az - 7), (ax - 6, az + 5), (ax + 6, az + 5)], fill=(230, 30, 110), outline=(255, 255, 255))
        draw.text((ax + 8, az - 14), bz["name"], fill=(120, 0, 60), font=font_big)

    # Legend
    ly = height + 8
    draw.rectangle([0, height, width, height + LEGEND_H], fill=(245, 242, 232))
    draw.text((8, ly), f"{layout['name']} - top-down map, 1 px = 1 stud, X east / Z south. "
              f"Bounds x[{b['minX']},{b['maxX']}] z[{b['minZ']},{b['maxZ']}]", fill=(30, 30, 30), font=font_big)
    col = 8
    row = ly + 24
    for kind, color in ROAD_COLORS.items():
        draw.line([(col, row + 6), (col + 28, row + 6)], fill=color, width=max(2, {"Alley": 4, "BikePath": 3, "BikeBridge": 3, "Street": 6, "Industrial": 10}.get(kind, 8)))
        draw.text((col + 34, row), kind, fill=(30, 30, 30), font=font)
        row += 14
        if row > ly + 24 + 14 * 4:
            row = ly + 24
            col += 120
    col += 120
    row = ly + 24
    for style, color in STYLE_COLORS.items():
        draw.rectangle([col, row + 1, col + 14, row + 11], fill=color, outline=(60, 50, 40))
        draw.text((col + 20, row), style, fill=(30, 30, 30), font=font)
        row += 14
        if row > ly + 24 + 14 * 4:
            row = ly + 24
            col += 110
    col += 110
    row = ly + 24
    for ptype, color in PROP_COLORS.items():
        draw.ellipse([col + 3, row + 3, col + 10, row + 10], fill=color)
        draw.text((col + 20, row), ptype, fill=(30, 30, 30), font=font)
        row += 14
        if row > ly + 24 + 14 * 4:
            row = ly + 24
            col += 100
    col += 100
    row = ly + 24
    draw.ellipse([col + 2, row + 2, col + 10, row + 10], fill=(0, 140, 230), outline=(255, 255, 255))
    draw.text((col + 16, row), "Destination (arrival pad -> door)", fill=(30, 30, 30), font=font)
    row += 14
    draw.polygon([(col + 6, row), (col, row + 12), (col + 12, row + 12)], fill=(230, 30, 110))
    draw.text((col + 16, row), "Business (arrival pad -> door)", fill=(30, 30, 30), font=font)
    row += 14
    draw.rectangle([col, row + 1, col + 12, row + 11], fill=(235, 225, 160), outline=(160, 140, 60))
    draw.text((col + 16, row), "Depot plot P1..P8", fill=(30, 30, 30), font=font)
    row += 14
    draw.rectangle([col, row + 1, col + 12, row + 11], fill=(90, 150, 210))
    draw.text((col + 16, row), "Canal (water)   green strip = greenbelt/rail   white loops = pedestrian paths", fill=(30, 30, 30), font=font)
    row += 14
    draw.rectangle([col, row + 1, col + 12, row + 11], fill=(200, 60, 60), outline=(0, 0, 0))
    draw.text((col + 16, row), "Parked vehicle (car/truck)", fill=(30, 30, 30), font=font)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    img.save(OUT)
    print(f"wrote {OUT} ({img.size[0]}x{img.size[1]})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
