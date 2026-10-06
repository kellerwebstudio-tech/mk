#!/usr/bin/env python3
"""Offline behaviour tests for RouteGraph (runs under the luau CLI via the bundler).

Covers node merging, T-junction splitting, mask filtering, A* optimality and bound, projection helpers,
turn instructions, and validate() catching deliberately broken layouts. Exits non-zero on any failure.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from luau_bundle import bundle, run_luau  # noqa: E402

MAIN = r"""
local failures = 0
local function check(cond, msg)
    if cond then
        print("  ok   " .. msg)
    else
        failures += 1
        print("  FAIL " .. msg)
    end
end
local function near(a, b, eps) return math.abs(a - b) <= (eps or 0.01) end
local function V(x, y, z) return Vector3.new(x, y or 0, z) end
local function xz(flat)
    local pts = {}
    for i = 1, #flat, 2 do pts[#pts + 1] = { x = flat[i], z = flat[i + 1] } end
    return pts
end

print("== build: merging + T-junction splitting ==")
local tiny = {
    bounds = { minX = -1000, maxX = 1000, minZ = -1000, maxZ = 1000 }, groundY = 0,
    roads = {
        { id = "A", kind = "Road", width = 20, points = xz({ 0, 0, 100, 0, 200, 0 }) },
        { id = "B", kind = "Street", width = 14, points = xz({ 100.5, 0, 100, 100 }) },       -- merges with (100,0)
        { id = "C", kind = "Alley", width = 8, points = xz({ 50, -50, 50, 0 }) },              -- T-junction: endpoint on A's interior -> split
        { id = "D", kind = "Road", width = 20, points = xz({ 200, 0, 200, 100, 100, 100 }) },
    },
}
local g = RouteGraph.build(tiny)
check(#g.nodes == 7, "node count after merge/split = 7 (got " .. #g.nodes .. ")")
local function nodeAt(x, z)
    for _, n in ipairs(g.nodes) do if near(n.position.X, x, 0.6) and near(n.position.Z, z, 0.6) then return n end end
end
check(nodeAt(100, 0) ~= nil and #nodeAt(100, 0).roadIds == 2, "(100,0) merged node has 2 road ids")
check(#g.edges == 7, "edge count after split = 7 (got " .. #g.edges .. ")")
local splitNode = nodeAt(50, 0)
check(splitNode ~= nil and #g.adjacency[splitNode.index] == 3, "T-junction at (50,0) became a 3-way node")

print("== findPath ==")
local path, len = RouteGraph.findPath(g, V(0, 0, -5), V(190, 0, -5), 7)
check(path ~= nil and near(len, 190, 0.5), "straight along A = 190 (got " .. tostring(len) .. ")")
check(path ~= nil and near(path[1].Z, 0) and near(path[#path].X, 190) and near(path[#path].Z, 0), "path starts/ends at projected points")
local p2, l2 = RouteGraph.findPath(g, V(50, 0, -50), V(100, 0, 0), 1)
check(p2 ~= nil and near(l2, 100, 0.5), "bicycle uses the alley then A (100)")
local p3, l3 = RouteGraph.findPath(g, V(50, 0, -50), V(100, 0, 0), 4)
check(p3 ~= nil and near(l3, 50, 0.5), "van projects onto A instead of the alley (50)")
local island = { bounds = tiny.bounds, groundY = 0, roads = { tiny.roads[1], { id = "F", kind = "Road", width = 20, points = xz({ 500, 500, 600, 500 }) } } }
local ig = RouteGraph.build(island)
local ip, il = RouteGraph.findPath(ig, V(0, 0, 0), V(550, 0, 500), 7)
check(ip == nil and il == math.huge, "disconnected target -> (nil, inf)")
local p4, l4 = RouteGraph.findPath(g, V(0, 0, 0), V(100, 0, 100), 2)
check(p4 ~= nil and near(l4, 200, 0.5), "scooter uses the street (200) not the long way round")
local p5, l5 = RouteGraph.findPath(g, V(0, 0, 0), V(100, 0, 100), 4)
check(p5 ~= nil and near(l5, 400, 0.5), "van avoids the street: 400 via D")
local same, sameLen = RouteGraph.findPath(g, V(10, 0, 3), V(40, 0, -3), 7)
check(same ~= nil and #same == 2 and near(sameLen, 30), "same-edge endpoints give a direct 2-point path")

print("== bounded A* ==")
-- a long chain of 6000 nodes: the far end must be unreachable within 4000 expansions
local chain = { x = 0, z = 0 }
local pts = {}
for i = 0, 6000 do pts[#pts + 1] = { x = i * 2, z = 0 } end
local big = { bounds = { minX = -1e9, maxX = 1e9, minZ = -1e9, maxZ = 1e9 }, groundY = 0, roads = { { id = "L", kind = "Road", width = 20, points = pts } } }
local bg = RouteGraph.build(big)
local t0 = os.clock()
local bp, bl = RouteGraph.findPath(bg, V(0, 0, 0), V(12000, 0, 0), 7)
local dt = os.clock() - t0
check(bp == nil, "far end of a 6000-node chain is cut off by the expansion bound")
check(dt < 1.0, string.format("bounded search returned quickly (%.3f s)", dt))
local np, nl = RouteGraph.findPath(bg, V(0, 0, 0), V(5000, 0, 0), 7)
check(np ~= nil and near(nl, 5000, 0.5), "2500-node route still found inside the bound")

print("== projection + polyline helpers ==")
local pt, edge, t, d = RouteGraph.nearestPointOnGraph(g, V(150, 0, 30), 7)
check(edge ~= nil and edge.roadId == "A" and near(pt.X, 150) and near(pt.Z, 0) and near(d, 30), "nearestPointOnGraph projects onto A")
check(near(t, 0.5), "t is 0.5 on the (100,0)-(200,0) edge")
local _, edge2 = RouteGraph.nearestPointOnGraph(g, V(50, 0, 30), 4)
check(edge2 ~= nil and edge2.roadId ~= "C", "van projection ignores the alley")
local poly = { V(0, 0, 0), V(100, 0, 0), V(100, 0, 100) }
check(near(RouteGraph.distanceAlongPath(poly), 200), "distanceAlongPath = 200")
local pd, seg = RouteGraph.distanceToPolyline(poly, V(107, 0, 50))
check(near(pd, 7) and seg == 2, "distanceToPolyline picks segment 2 at distance 7")
check(RouteGraph.distanceToPolyline({}, V(0, 0, 0)) == math.huge, "empty polyline -> inf")

print("== turnInstructions ==")
local turns = RouteGraph.turnInstructions({ V(0, 0, 0), V(0, 0, -100), V(100, 0, -100), V(100, 0, -200), V(100, 0, -300), V(50, 0, -350), V(100, 0, -300) })
check(#turns == 4, "4 instructions (straight vertex skipped), got " .. #turns)
check(turns[1] and turns[1].kind == "Right" and near(turns[1].distanceFromStart, 100), "heading north then east = Right at 100")
check(turns[2] and turns[2].kind == "Left" and near(turns[2].distanceFromStart, 200), "then north = Left at 200")
check(turns[3] and turns[3].kind == "SlightLeft", "45-degree bend = SlightLeft")
check(turns[4] and turns[4].kind == "UTurn", "reverse = UTurn")

print("== validate() catches broken layouts ==")
local function copyLayout(extraRoads, extraBuildings)
    local l = { bounds = tiny.bounds, groundY = 0, roads = {}, buildings = extraBuildings or {}, businesses = {}, destinations = {}, depotPlots = {},
        hub = { spawn = { x = 0, z = 0 }, vehiclePads = { { x = 0, z = 0 } } } }
    for _, r in ipairs(tiny.roads) do table.insert(l.roads, r) end
    for _, r in ipairs(extraRoads or {}) do table.insert(l.roads, r) end
    return l
end
local function has(problems, needle)
    for _, p in ipairs(problems) do if string.find(p, needle, 1, true) then return true end end
    return false
end
local probs = RouteGraph.validate(copyLayout({ { id = "X", kind = "Alley", width = 8, points = xz({ 60, -50, 60, 50 }) }, { id = "F", kind = "Road", width = 20, points = xz({ 500, 500, 600, 500 }) } }))
check(has(probs, "cross at (60.0, 0.0) without a shared point"), "unshared crossing reported")
check(has(probs, "Van graph has 2 components") and has(probs, "Bicycle graph has 3 components"), "disconnected graphs reported")
local tinyProbs = RouteGraph.validate(copyLayout())
check(#tinyProbs == 1 and has(tinyProbs, "roads A and C cross at (50.0, 0.0)"), "a T-junction without an explicit shared point is reported (builder splits it, validator insists on authored points)")
probs = RouteGraph.validate(copyLayout({ { id = "A", kind = "Road", width = 20, points = xz({ 0, 10, 10, 10 }) } }))
check(has(probs, 'duplicate road id "A"'), "duplicate id reported")
probs = RouteGraph.validate(copyLayout({ { id = "E", kind = "Road", width = 20, points = xz({ 0, 0, 150, 0 }) } }))
check(has(probs, "overlap collinearly"), "collinear overlap reported")
probs = RouteGraph.validate(copyLayout(nil, { { x = 100, z = 10, w = 20, d = 20, h = 10, style = "Shop" }, { x = 500, z = 500, w = 20, d = 20, h = 10, style = "Shop" }, { x = 505, z = 505, w = 20, d = 20, h = 10, style = "Shop" } }))
check(has(probs, "overlaps road A"), "building on a road reported")
check(has(probs, "overlaps building 3"), "building overlap reported")
probs = RouteGraph.validate(copyLayout({ { id = "Z", kind = "Road", width = 20, points = xz({ 0, 0, 5000, 0 }) } }))
check(has(probs, "outside bounds"), "out-of-bounds point reported")
local l = copyLayout()
l.destinations = { { id = "X", kind = "LoadingBay", accepts = { Large = false }, door = { x = 50, z = -61 }, arrivalPoint = { x = 50, z = -30 } } }
probs = RouteGraph.validate(l)
check(has(probs, "nearest van edge"), "loading bay next to alley only -> van edge problem")
check(has(probs, "door is 31.0 studs"), "door too far from arrival reported")
check(has(probs, "does not accept Large"), "LoadingBay without Large reported")
l.destinations = nil
l.parkedVehicles = { { x = 100, z = 2, rot = 0, kind = "Car" } }
probs = RouteGraph.validate(l)
check(has(probs, "centre line of road"), "parked car on a centre line reported")

print("== real layout ==")
local real = RouteGraph.validate(CityLayout)
check(#real == 0, "CityLayout validates with 0 problems (got " .. #real .. ")")
local rg = RouteGraph.build(CityLayout)
-- Tower Alley shortcut: ring NW corner to Station Road at z=-60, bike vs scooter
local _, bikeLen = RouteGraph.findPath(rg, V(-80, 0, -60), V(-300, 0, -60), 1)
local _, scooterLen = RouteGraph.findPath(rg, V(-80, 0, -60), V(-300, 0, -60), 2)
check(bikeLen < scooterLen - 100, string.format("Tower Alley saves >100 studs for bikes (%.0f vs %.0f)", bikeLen, scooterLen))
local _, bb = RouteGraph.findPath(rg, V(115, 0, 120), V(290, 0, 120), 1)
local _, vb = RouteGraph.findPath(rg, V(115, 0, 120), V(290, 0, 120), 4)
check(bb < vb - 100, string.format("Bike bridge saves >100 studs over the Canal Bridge (%.0f vs %.0f)", bb, vb))
local _, la = RouteGraph.findPath(rg, V(-225, 0, 60), V(-225, 0, 160), 1)
local _, ls = RouteGraph.findPath(rg, V(-225, 0, 60), V(-225, 0, 160), 2)
check(la < ls - 100, string.format("Lantern Alley saves >100 studs (%.0f vs %.0f)", la, ls))
-- every node reachable for bicycles from the hub
local reach = 0
local hub = V(0, 0, 62)
for _, n in ipairs(rg.nodes) do
    local p = RouteGraph.findPath(rg, hub, n.position, 1)
    if p then reach += 1 end
end
check(reach == #rg.nodes, string.format("all %d nodes reachable by bicycle from the hub (%d)", #rg.nodes, reach))

print(string.format("== %d failure(s) ==", failures))
if failures > 0 then error("RouteGraph tests failed") end
"""


def main() -> int:
    result = run_luau(bundle(MAIN), "test_routegraph.luau")
    sys.stdout.write(result.stdout)
    if result.returncode != 0:
        sys.stdout.write(result.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
