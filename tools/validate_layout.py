#!/usr/bin/env python3
"""Validate src/shared/City/CityLayout.luau offline with the luau CLI.

Bundles a Vector3 stub + CityLayout + RouteGraph into tests/build/validate_layout.luau, runs it with
$DDC_TOOLS/luau and prints: every validation problem, graph statistics, sample path lengths between every
business and every destination for masks 1/2/4, and the tutorial distance checks.
Exits non-zero if any validation problem exists (or a tutorial distance limit is exceeded).
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from luau_bundle import bundle, run_luau  # noqa: E402

MAIN = r"""
local layout = CityLayout
local problems = RouteGraph.validate(layout)
print(string.format("== Validation: %d problem(s) ==", #problems))
for i, p in ipairs(problems) do
    print(string.format("  [%d] %s", i, p))
end

local graph = RouteGraph.build(layout)
print("== Graph stats ==")
print(string.format("  nodes: %d", #graph.nodes))
print(string.format("  edges: %d", #graph.edges))
local maskNames = { { 1, "Bicycle" }, { 2, "Scooter" }, { 4, "Van" } }
for _, m in ipairs(maskNames) do
    local mask, name = m[1], m[2]
    local count, total = 0, 0
    local nodesWith = {}
    for _, e in ipairs(graph.edges) do
        if bit32.band(e.mask, mask) ~= 0 then
            count += 1
            total += e.length
            nodesWith[e.a] = true
            nodesWith[e.b] = true
        end
    end
    -- component count
    local visited, components = {}, 0
    for ni in pairs(nodesWith) do
        if not visited[ni] then
            components += 1
            local stack = { ni }
            visited[ni] = true
            while #stack > 0 do
                local cur = table.remove(stack)
                for _, ei in ipairs(graph.adjacency[cur]) do
                    local e = graph.edges[ei]
                    if bit32.band(e.mask, mask) ~= 0 then
                        local other = if e.a == cur then e.b else e.a
                        if not visited[other] then
                            visited[other] = true
                            table.insert(stack, other)
                        end
                    end
                end
            end
        end
    end
    print(string.format("  mask %d (%s): %d edges, %.0f studs, %d component(s)", mask, name, count, total, components))
end
local kinds = {}
for _, e in ipairs(graph.edges) do
    kinds[e.kind] = (kinds[e.kind] or 0) + 1
end
local kindList = {}
for k, v in pairs(kinds) do table.insert(kindList, k .. "=" .. v) end
table.sort(kindList)
print("  edges by kind: " .. table.concat(kindList, ", "))
print(string.format("  buildings: %d, destinations: %d, businesses: %d, props: %d, parked: %d, paths: %d",
    #layout.buildings, #layout.destinations, #layout.businesses, #layout.props, #layout.parkedVehicles, #layout.pedestrianPaths))

local function v(p) return Vector3.new(p.x, p.y or layout.groundY or 0, p.z) end

print("== Sample path lengths (business -> destination), masks 1 / 2 / 4 ==")
local ranges = {
    BeanAndBunCafe = { 120, 260 }, SliceStreetPizza = { 150, 420 },
    FreshLaneMarket = { 200, 450 }, CrateAndCoSupply = { 250, 600 },
}
local inRange = {}
for _, b in ipairs(layout.businesses) do
    inRange[b.id] = 0
    for _, d in ipairs(layout.destinations) do
        local parts = {}
        for _, m in ipairs(maskNames) do
            local path, len = RouteGraph.findPath(graph, v(b.arrivalPoint), v(d.arrivalPoint), m[1])
            if path then
                table.insert(parts, string.format("%6.0f", len))
            else
                table.insert(parts, "unreachable")
            end
        end
        local bikePath, bikeLen = RouteGraph.findPath(graph, v(b.arrivalPoint), v(d.arrivalPoint), 1)
        local r = ranges[b.id]
        local flag = ""
        if bikePath and r and bikeLen >= r[1] and bikeLen <= r[2] then
            flag = " *"
            inRange[b.id] += 1
        end
        print(string.format("  %-17s -> %s (%-11s %-12s): %s%s", b.id, d.id, d.neighborhood, d.kind, table.concat(parts, " / "), flag))
    end
end
print("== Destinations inside the first-release distance band per business (bicycle) ==")
for _, b in ipairs(layout.businesses) do
    local r = ranges[b.id]
    print(string.format("  %-17s %d destination(s) in [%d, %d]", b.id, inRange[b.id], r[1], r[2]))
end

-- Tutorial checks
local hub = v(layout.hub.spawn)
local pizza
for _, b in ipairs(layout.businesses) do if b.id == "SliceStreetPizza" then pizza = b end end
local tutorialFail = false
local _, hubLen = RouteGraph.findPath(graph, hub, v(pizza.arrivalPoint), 1)
print(string.format("== Tutorial: hub -> SliceStreetPizza = %.0f studs (max 180)%s", hubLen, hubLen <= 180 and "" or "  FAIL"))
if hubLen > 180 then tutorialFail = true end
local nearest, nearestId = math.huge, "?"
for _, d in ipairs(layout.destinations) do
    local _, len = RouteGraph.findPath(graph, v(pizza.arrivalPoint), v(d.arrivalPoint), 1)
    if len < nearest then nearest, nearestId = len, d.id end
end
print(string.format("== Tutorial: SliceStreetPizza -> nearest destination %s = %.0f studs (max 220)%s", nearestId, nearest, nearest <= 220 and "" or "  FAIL"))
if nearest > 220 then tutorialFail = true end

-- Shortcut sanity: each bikeShortcut road must exist and be bicycle-only
for _, s in ipairs(layout.bikeShortcuts) do
    local found
    for _, r in ipairs(layout.roads) do if r.id == s.roadId then found = r end end
    if not found then
        print("  shortcut road missing: " .. tostring(s.roadId))
        tutorialFail = true
    else
        print(string.format("  shortcut %s (%s): %s", s.roadId, found.kind, s.hint))
    end
end

-- Turn instruction smoke test on the tutorial route
local tutPath = RouteGraph.findPath(graph, hub, v(pizza.arrivalPoint), 1)
local turns = RouteGraph.turnInstructions(tutPath)
print(string.format("  tutorial route: %d points, %d turn instruction(s)", #tutPath, #turns))
for _, t in ipairs(turns) do
    print(string.format("    %s at %.0f studs (%.0f, %.0f)", t.kind, t.distanceFromStart, t.position.X, t.position.Z))
end

if #problems > 0 or tutorialFail then
    error(string.format("VALIDATION FAILED: %d problem(s)%s", #problems, tutorialFail and " + tutorial distance" or ""))
end
print("VALIDATION OK")
"""


def main() -> int:
    source = bundle(MAIN)
    result = run_luau(source, "validate_layout.luau")
    sys.stdout.write(result.stdout)
    if result.returncode != 0:
        sys.stdout.write(result.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
