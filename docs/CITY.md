# Delivery Dash City — City Guide

Authored data lives in `src/shared/City/CityLayout.luau` (pure tables) and is consumed by `CityBuilder`
(world), `RouteGraph` (navigation) and the order/tutorial services. Coordinates are studs, **X east, Z south,
Y up**, ground at y = 0. The whole city sits inside x ∈ [-560, 660], z ∈ [-460, 600]. A rendered top-down map is
in `docs/map.png` (1 px = 1 stud).

## The city at a glance

```
            z -460 ─────────────── canal (x 150..220) ───────────────
   DOWNTOWN (x -480..120, z -380..160)   ║   MAPLE HILL (x 240..640, z -380..200)
   grid of 100-stud blocks, plaza ring   ║   looping streets, Maple Park, Hillcrest hill
   Beacon Tower NW of the plaza          ║   Fresh Lane Market, Canal Bank houses
   Canal Bridge  ══════ z = -60 ═════════╬══  (Road, deck y 8, 70-stud ramps)
   Quay Bike Bridge ──── z = 120 ────────╬──  (BikeBridge, deck y 6)
 ───────────── greenbelt / rail strip z 200..250, crossings at x = -300, 0, 440 ─────────────
   DOCKSIDE (x -480..640, z 260..580): Wharf Road (z 300), Container Way (z 460), eight Dock Roads,
   warehouses with loading bays, Crate & Co. Supply, water tower (100, 520), depot plots P1..P6
```

* **Central plaza** at (0, 0), radius 55, ringed by `PlazaRing` (a chamfered square 80 studs from the centre,
  width 20). The **delivery hub** sits on the plaza's south apron: kiosk at (0, 48) in front of the Hub building (body z 34..46), four vehicle pads at
  z = 54 (x = -30, -10, 10, 30) facing north, spawn at (0, 62). **Bean & Bun Café** is a pavilion on the
  plaza's west side (door at (-57, 10), arrival pad on the inner kerb of the ring).
* **Beacon Tower** (120 studs tall) stands north-west of the plaza at (-110, -112).
* **Slice Street Pizza** is at (-115, 36) on Slice Street, one block west of the plaza; the tutorial ride from
  the hub is 123 studs along the bicycle graph.
* **Fresh Lane Market** at (330, -245) faces Fresh Lane with its arrival (parking) pad at (330, -210).
* **Crate & Co. Supply** at (-205, 380) has a van-sized loading bay on Dock Road C (arrival (-163, 380)).
* **Maple Park** (140 × 140 around (450, 20)) is crossed by three bike-only paths that meet in the centre.
  **Hillcrest Road** (z = -200, x 370..530) rises to y = 6 in the middle; its six houses use `baseY`.

## Roads

Masks: `Road`, `Bridge`, `Industrial`, `Ramp` = 7 (all vehicles); `Street` = 3 (bicycle + scooter);
`Alley`, `BikePath`, `BikeBridge` = 1 (bicycle only). Every road is an axis-aligned polyline except the plaza ring
and the park paths; roads that meet share an exact point.

| Road id | Name | Kind | Width | Where |
|---|---|---|---|---|
| `PlazaRing` | Plaza Ring | Road | 20 | chamfered square around the plaza (±80) |
| `BeaconAvenue` | Beacon Avenue | Road | 20 | z = 0, x -460 → -80 (ring) |
| `NorthgateRoad` | Northgate Road | Road | 20 | z = -360, x -460 → 115 |
| `FoundryRoad` | Foundry Road | Road | 20 | z = -200, x -460 → 115 |
| `UnionStreet` | Union Street | Road | 20 | z = 160, x -460 → 115 |
| `WestgateRoad` | Westgate Road | Road | 20 | x = -460, z -360 → 160 |
| `StationRoad` | Station Road | Road | 20 | x = -300, z -360 → 160 |
| `TowerRoad` | Tower Road | Road | 20 | x = -150, z -360 → 160 |
| `PlazaNorthRoad` / `PlazaSouthRoad` | Plaza North / South Road | Road | 20 | x = 0, north and south of the ring |
| `MillStreet` | Mill Street | Street | 14 | z = -280 |
| `LanternStreet` | Lantern Street | Street | 14 | z = -120, x -460 → -150 |
| `SliceStreet` | Slice Street | Street | 14 | z = 60, x -460 → -80 (ring) |
| `BakerStreet` | Baker Street | Street | 14 | x = -380, z -360 → 60 |
| `PrintStreet` | Print Street | Street | 14 | x = -225, z -200 → 60 |
| `QuayStreetNorth` / `QuayStreet` | Quay Street | Street | 14 | x = 115 (north of the bridge / south from the ring) |
| `TowerAlley` | Tower Alley | Alley | 8 | z = -60, x -300 → -80 (ring NW corner) |
| `LanternAlley` | Lantern Alley | Alley | 8 | x = -225, z 60 → 160 |
| `FishmarketAlley` | Fishmarket Alley | Alley | 8 | z = -140, x 0 → 115 |
| `PrintersAlley` | Printers Alley | Alley | 8 | x = -380, z 60 → 160 |
| `QuayAlley` | Quay Alley | Alley | 8 | z = 60, x 80 → 115 |
| `CobblerAlley` | Cobbler Alley | Alley | 8 | z = 110, x -300 → -150 |
| `CanalRampWest` / `CanalBridge` / `CanalRampEast` | Canal Bridge | Ramp / Bridge / Ramp | 20 | z = -60, x 80 → 290, deck y 8 |
| `BikeBridge` | Quay Bike Bridge | BikeBridge | 6 | z = 120, x 115 → 290, deck y 6 |
| `CanalSideDrive`, `ParkWestRoad`, `ParkEastRoad`, `OrchardRoad` | — | Road | 18 | x = 290, 370, 530, 620 |
| `NorthMapleRoad`, `FreshLane` + `HillcrestRoad`, `BridgeRoad`, `ParkSouthRoad`, `MapleRow` | — | Road | 18 | z = -340, -200, -60, 100, 180 |
| `ParkCrossEW`, `ParkCrossNS`, `ParkDiagonal` | Maple Park walks | BikePath | 6 | inside the park, meeting at (450, 20) |
| `RailCrossingWest` / `Central` / `East` | greenbelt crossings | Road | 20 | x = -300, 0, 440 |
| `WharfRoad`, `ContainerWay` | — | Industrial | 28 | z = 300, 460 |
| `DockRoadA` … `DockRoadH` | Dock Roads | Industrial | 28 | x = -440, -300, -150, 0, 150, 300, 440, 600 |

### Bicycle shortcuts (`bikeShortcuts`, used by the tutorial and navigation hints)

| Road | Saves | Hint |
|---|---|---|
| `TowerAlley` | 220 vs 340 studs from the ring's NW corner to Station Road | "Tower Alley cuts straight from the plaza to Station Road, skipping the Beacon Avenue loop." |
| `LanternAlley` | 100 vs 250 studs from Slice Street to Union Street | "Lantern Alley links Slice Street straight down to Union Street." |
| `BikeBridge` | 176 vs 794 studs across the canal at the quay | "The Quay bike bridge is the short way over the canal; vans and scooters must use the Canal Bridge." |

## Businesses

| id | Name | Neighbourhood | Door | Pickup point | Arrival pad |
|---|---|---|---|---|---|
| `SliceStreetPizza` | Slice Street Pizza | Downtown | (-115, 49) | (-115, 51) | (-115, 52) on Slice Street |
| `BeanAndBunCafe` | Bean & Bun Café | Downtown | (-57, 10) | (-62, 10) | (-68, 10) on the Plaza Ring |
| `FreshLaneMarket` | Fresh Lane Market | Residential | (330, -227) | (330, -220) | (330, -210) on Fresh Lane (van OK) |
| `CrateAndCoSupply` | Crate & Co. Supply | Industrial | (-175, 380) | (-168, 380) | (-163, 380) on Dock Road C (van OK) |

Bicycle-graph distances from each business to the destinations in its first-release band (see
`tools/validate_layout.py` output): café 6 destinations in 120–260, pizza 5 in 150–420, market 4 in 200–450,
warehouse 8 in 250–600. Residential houses are 550+ studs from the downtown businesses (the canal separates
them), so pizza and café orders are effectively downtown orders.

## Destinations

| id | Address | Neighbourhood | Kind | Accepts | Door | Arrival pad |
|---|---|---|---|---|---|---|
| D01 | Beacon Shops, 28 Beacon Avenue | Downtown | Shop | Small, Medium | (-189, -14) | (-189, -10) |
| D02 | Slice Street Flats, 9 Slice Street | Downtown | Apartment | Small, Medium | (-189, 49) | (-189, 53) |
| D03 | Cobbler Court, 21 Slice Street | Downtown | Apartment | Small, Medium | (-261, 71) | (-261, 67) |
| D04 | Fishmarket Lofts, 3 Fishmarket Alley | Downtown | Apartment | Small, Medium | (34, -130) | (34, -136) |
| D05 | Beacon Heights, 40 Beacon Avenue | Downtown | Apartment | Small, Medium | (-261, -14) | (-261, -10) |
| D06 | Union Parade, 4 Union Street | Downtown | Shop | Small, Medium | (-31, 146) | (-31, 150) |
| D07 | Lantern Mews, 15 Lantern Street | Downtown | Shop | Small, Medium | (-189, -109) | (-189, -113) |
| D08 | 14 Maple Row | Residential | House | Small, Medium, Large | (405, 163) | (405, 171) |
| D09 | 3 Hillcrest Road (baseY 6) | Residential | House | Small, Medium, Large | (450, -217) | (450, -209) |
| D10 | 6 Hillcrest Road (baseY 3.5) | Residential | House | Small, Medium, Large | (495, -183) | (495, -191) |
| D11 | 12 Canal Bank | Residential | House | Small, Medium, Large | (276, 30) | (284, 30) |
| D12 | 41 Orchard Road | Residential | House | Small, Medium, Large | (606, -100) | (614, -100) |
| D13 | 15 Park West Road | Residential | House | Small, Medium, Large | (356, 15) | (364, 15) |
| D14 | 17 Bridge Road | Residential | House | Small, Medium, Large | (405, -77) | (405, -69) |
| D15 | Canal Logistics, Bay 3 Wharf Road | Industrial | LoadingBay | Small, Medium, Large | (75, 320) | (75, 313) |
| D16 | Pier Six Distribution, Bay 5 Container Way | Industrial | LoadingBay | Small, Medium, Large | (225, 440) | (225, 447) |
| D17 | Dockside Freight, Bay 1 Wharf Road | Industrial | LoadingBay | Small, Medium, Large | (-370, 320) | (-370, 313) |
| D18 | Canal Logistics, Bay 4 Container Way | Industrial | LoadingBay | Small, Medium, Large | (75, 440) | (75, 447) |

Every destination's arrival pad is on the kerb of a bicycle-legal edge (≤ 14 studs from the centre line);
loading bays sit on Industrial roads so vans can reach them. Doors are at most 8 studs from their pad.

## Depot plots

| Plot | Centre | Size | Faces | Where |
|---|---|---|---|---|
| P1 | (-370, 503) | 60 × 50 | north | Container Way, west end |
| P2 | (-225, 503) | 60 × 50 | north | Container Way, by Crate & Co. |
| P6 | (-75, 503) | 60 × 50 | north | Container Way, west of the water tower |
| P3 | (225, 503) | 60 × 50 | north | Container Way, east of the water tower |
| P4 | (370, 503) | 60 × 50 | north | Container Way |
| P5 | (520, 503) | 60 × 50 | north | Container Way, east end |
| P7 | (36, 124) | 44 × 48 | south | south-east of the plaza, between Plaza South Road and Quay Street |
| P8 | (84, 124) | 44 × 48 | south | same block, next to Quay Street |

Each plot has two parking spots (`parking`) 15 studs either side of its centre, 8 studs toward the road.

## Other authored content

* **Water:** one canal rectangle, x 150..220, z -460..240, `surfaceY = -3`, `depth = 8`.
* **Bridges:** `CanalBridge` points 1→2 and `BikeBridge` points 2→3 get decks and railings.
* **Landmarks:** plaza (0, 0, r 55), tower (-110, -112), park (450, 20, 140 × 140), water tower (100, 520), hub (0, 50).
* **Buildings:** 166 (downtown shops/apartments/offices, 56 houses, 18 warehouses/sheds, tower, café, pizza,
  market, hub kiosk). Styles: `Shop | Apartment | House | Warehouse | Tower | Hub | Office | Cafe | Market | Pizza`.
* **Pedestrian loops:** 8 (`PlazaWalk`, `SliceStreetWalk`, `TowerBlockWalk`, `QuayWalk`, `ParkWalk`,
  `MarketWalk`, `CanalSideWalk`, `CrateYardWalk`), all closed loops along sidewalks or park edges.
* **Parked vehicles:** 23 (17 cars, 6 trucks) in the kerb-side strip of a road, never on an arrival pad and never
  within 4 studs of a route centre line. `rot` 0 faces north (-Z), 90 faces east.
* **Props:** ~390 (lamps every 60 studs on main roads, trees in the park, residential streets and the greenbelt,
  planters and benches on the plaza, hydrants at downtown corners, crates/containers/dumpsters in alleys and
  industrial yards, cones at the bridge ramps).

## Editing the layout

1. Edit `src/shared/City/CityLayout.luau`. Keep positions as `{x=, z=}` / `{x=, y=, z=}` tables; the helper
   locals (`road`, `building`, `rowX`, `rowZ`, `house`, `destination`, `plot`, `lampsAlong`, …) only build
   plain tables.
2. **Roads** must share an exact point wherever they meet or cross (add the point to both polylines).
   Buildings must stay ≥ (road width / 2 + 1) studs from every road centre line and must not overlap each other.
3. **Arrival pads** must be ≤ 14 studs from the centre line of a bicycle-legal edge (and of a van-legal edge for
   the market, Crate & Co. and loading bays); doors ≤ 20 studs from their pad.
4. Validate: `DDC_TOOLS=<dir with luau> python3 tools/validate_layout.py` — prints every problem, graph
   statistics, business→destination distances for masks 1/2/4 and the tutorial distance checks; exits non-zero
   on any problem. `python3 tools/test_routegraph.py` runs the RouteGraph behaviour tests.
5. Render: `python3 tools/render_map.py` writes `docs/map.png` (uses `tools/export_layout.py`, which dumps
   `tests/build/layout.json`). Look at the map after every change.
6. Tutorial constraints: hub → Slice Street Pizza ≤ 180 studs and pizza → nearest destination ≤ 220 studs on the
   bicycle graph (currently 123 and 74).
