# Model list (custom asset pipeline)

Everything in the game is currently generated from parts by the builders. This is the full list of models that would replace that generated geometry, with the dimensions the game expects. Once models exist, the builders will clone a template from `ServerStorage` when one is present and fall back to generated parts otherwise (template-override support is the next engineering step; the names below are the names it will look for).

## Conventions (apply to every model)

| Rule | Value |
|---|---|
| Scale | 1 Blender unit = 1 stud. An R15 character is 5 studs tall, a door 7 studs, a road lane 10 studs. |
| Origin | Bottom-centre at ground level (y = 0 at the base) for buildings, props, packages, NPCs. Vehicles: origin at the chassis centre, `rideHeight` above the ground (bicycle 1.5, scooter 1.5, van 2.4). |
| Orientation | Front faces **-Z** (Roblox LookVector). +Y up, +X right. Wheels spin about their local X axis. |
| Collision | One invisible box per model named `Collider` (CanCollide true); every visible mesh non-colliding (`CanCollide/CanQuery/CanTouch = false`). Vehicles keep the game's own invisible chassis box as the only collider, so vehicle meshes are purely visual. |
| Triangle budgets | Vehicle ≤ 3,000 tris; building ≤ 2,500; prop ≤ 400; package ≤ 300; NPC ≤ 1,500; landmark ≤ 6,000. |
| Materials | Flat colours or one 512 px texture per model. Parts that the game recolours carry the attribute `PaintSlot` = `Primary`, `Accent` or `Decal` (vehicles), or `Primary` (bag styles, depot sign). |
| Naming | Model names exactly as listed; part names inside vehicles/packages exactly as listed because scripts find them by name. |
| Delivery format | FBX (or OBJ) per model, imported with Studio's 3D Importer into the `ServerStorage` folder named per section. |

## 1. Vehicles (`ServerStorage/VehicleTemplates`)

Visual-only meshes; the game adds the chassis, seat, constraints and cargo slots. Sizes are overall footprints.

| Model | Size (w × h × l, studs) | Parts the scripts need | Notes |
|---|---|---|---|
| `Bicycle` | 1.4 × 3.2 × 5.6 | `Body` (frame, fork, handlebar, saddle, basket, rear rack), `FrontWheel`, `RearWheel` (radius 1.1, width 0.3), optional `Crank`, `PedalLeft`, `PedalRight` | Frame = `Primary`, basket/fork = `Accent`. Saddle top at y 1.55 (seat), rear rack top at y 1.35 behind the saddle (package slot). |
| `Scooter` | 2.0 × 3.3 × 6.0 | `Body`, `FrontWheel`, `RearWheel` (radius 0.9, width 0.5), `TopBox`, `Headlight`, `Taillight` | Body = `Primary`, top box/fender = `Accent`. Saddle at y 1.45; top box lid at y 2.3 (package slot). |
| `Van` | 6.0 × 7.9 × 13.5 | `Body` (cargo box, cab, hood, bumpers, mirrors, roof rack), `FrontWheelL/R`, `RearWheelL/R` (radius 1.3, width 0.9), `Windshield`, `SideWindowL/R`, `HeadlightL/R`, `TaillightL/R`, `DecalL/R`, `StripeL/R` | Body = `Primary`, stripes = `Accent`, side panels = `Decal`. Driver seat at (-1.5, 0.4, -4.3) from the origin; rear cargo area open behind the cab for visible packages. |
| `VanDisplay` | same as Van | — | Optional: parked/depot version without openable rear (can be the Van mesh). |

Wheel meshes must have their axle along local X and be centred on the axle.

## 2. Delivery packages (`ServerStorage/PackageTemplates`)

Origin at the bottom centre; a flat top so they stack.

| Model | Size | Label face | Recolour |
|---|---|---|---|
| `FoodBag` | 1.1 × 0.9 × 0.8 | "FOOD" tag | bag = `Primary` (bag styles), strap = accent |
| `PizzaBox` | 1.5 × 0.25 × 1.5 | "PIZZA" lid print | — |
| `DrinkCarrier` | 1.2 × 0.7 × 0.7 | "DRINKS" | — |
| `GroceryBag` | 1.2 × 1.3 × 0.9 | "MARKET" | bag = `Primary` (bag styles) |
| `Parcel` | 1.6 × 1.2 × 1.3 | "FRAGILE" tape | — |

## 3. NPCs (`ServerStorage/NPCTemplates`)

Simple stylised figures, 5 studs tall, root at the feet, limbs as separate meshes named `Head`, `Torso`, `LeftArm`, `RightArm`, `LeftLeg`, `RightLeg` so the walk pose can swing them (or a proper R15 rig if you prefer animation).

| Model | Outfit |
|---|---|
| `Pedestrian` (3 colour variants) | casual clothes |
| `Customer` (2 variants) | casual, holds nothing |
| `Staff` | cap + apron (apron colour = business accent) |
| `Worker` | hi-vis vest + hard hat |
| `Driver` | courier cap + vest |
| `CourierVest` (accessory) | 1 vest mesh welded to the player's torso; colour = `Primary` (uniform cosmetic) |

## 4. Buildings (`ServerStorage/CityTemplates/Buildings`)

The layout has 166 buildings in ten styles. Rather than one model per building, make a fixed kit per style; the layout footprints will be snapped to these sizes. Each has a front face at -Z with a door opening at the centre, flat roof with a lip, windows every 10 studs of height for the tall styles, and a `Collider` box of the full footprint.

| Model | Footprint w × d | Height | Count in city | Details |
|---|---|---|---|---|
| `House_A` | 26 × 20 | 12 | 56 houses total | pitched or flat roof, front door, two windows, porch step |
| `House_B` | 26 × 20 | 14 | | variant facade |
| `House_C` | 26 × 20 | 16 | | two-storey variant |
| `Shop_A` | 36 × 24 | 12 | 29 shops | ground-floor shopfront glazing, awning, flat roof |
| `Shop_B` | 48 × 26 | 14 | | wider shopfront, two awnings |
| `Apartment_A` | 36 × 26 | 24 | 44 apartments | window grid, entrance canopy |
| `Apartment_B` | 48 × 28 | 32 | | taller variant |
| `Office_A` | 36 × 24 | 18 | 15 offices | glass bands |
| `Office_B` | 48 × 40 | 42 | | tall glass block |
| `Warehouse_A` | 60 × 30 | 12 | 17 warehouses | roller door on the front, corrugated walls |
| `Warehouse_B` | 80 × 40 | 18 | | two roller doors |
| `Warehouse_C` | 110 × 60 | 26 | | three roller doors, loading dock |
| `Business_SliceStreetPizza` | 36 × 26 | 14 | 1 | pizzeria facade, counter inside at the front, sign plate above the door reading SLICE STREET (text is drawn by the game on a flat face named `Sign`) |
| `Business_BeanAndBunCafe` | 22 × 24 | 10 | 1 | open pavilion on the plaza, counter, sign face |
| `Business_FreshLaneMarket` | 56 × 36 | 14 | 1 | market with produce awning, sign face, side parking apron |
| `Business_CrateAndCoSupply` | 60 × 60 | 18 | 1 | warehouse with a large loading bay opening and a counter window |
| `DeliveryHub` | 28 × 12 | 9 | 1 | hub office with a big sign face "DELIVERY HUB", open front |
| `BeaconTower` | 36 × 36 | 120 | 1 | the landmark tower: stepped block, spire 14 high, beacon sphere 5 at the top (Neon) |

Door opening for every residential/shop model: 4 wide × 7 tall, centred on the front face; the game places its own animated `Door` mesh (below) in that opening.

## 5. Street-level pieces used by every destination and business

| Model | Size | Notes |
|---|---|---|
| `Door` | 4 × 7 × 0.6 | hinged on the left edge; the game rotates it 90° on delivery |
| `Doorbell` | 0.4 × 0.6 × 0.2 | beside the door |
| `AddressSign` | 3 × 1.2 × 0.2 | flat face named `Screen` for the address text |
| `ArrivalPad` | 8 × 0.2 × 8 | painted ground marking (chevrons) |
| `PickupPad` | 10 × 0.2 × 10 | painted "PICKUP" ground marking |
| `Counter` | 8 × 3.2 × 2 | pickup counter with a serving top |
| `RollerDoor` | 12 × 10 × 0.4 | industrial loading-bay door |
| `Awning` | 10–40 × 0.3 × 3 (three widths: 10, 20, 40) | striped fabric |
| `LoadingBay` | 16 × 1.2 × 10 | raised dock with bumpers, for the 4 industrial destinations |

## 6. Street props (`ServerStorage/CityTemplates/Props`)

| Model | Size | Count | Notes |
|---|---|---|---|
| `Lamp` | 1.4 × 12.8 × 1.4 | 153 | pole + head; head emits light |
| `Tree_A` / `Tree_B` / `Tree_C` | 6–9 wide, 10–14 tall | 112 total | round, tall, and park variants |
| `Container` | 8 × 8.5 × 20 | 26 | shipping container, 4 colour variants |
| `Bench` | 5 × 1.8 × 1.6 | 22 | |
| `Hydrant` | 0.8 × 2.7 × 0.8 | 19 | |
| `Crate` | 3 × 3 × 3 | 16 | wooden |
| `Dumpster` | 6.2 × 4.4 × 3.7 | 15 | with lid |
| `Cone` | 1.6 × 2.2 × 1.6 | 9 | traffic cone |
| `Planter` | 4 × 2.4 × 2 and 5 × 2.4 × 2.5 (plaza) | 7 + plaza ring | concrete planter with plants |
| `StreetSign` | 1 × 8 × 0.2 | 3 | post with sign plate (face named `Screen`) |
| `Railing` | 4 × 3 × 0.3 (tiling segment) | bridges | bridge railing segment |
| `VehiclePad` | 6 × 0.3 × 12 | 4 | hub pad with a bicycle icon |
| `Kiosk` | 4 × 7 × 2 | 1 | order-board kiosk at the hub with a screen face |

## 7. Parked vehicles (cosmetic obstacles)

| Model | Size | Count | Notes |
|---|---|---|---|
| `ParkedCar` (3 colour variants) | 4.5 × 3.6 × 9 | 17 | sedan/hatchback, no interior needed |
| `ParkedTruck` (2 variants) | 6.2 × 9.6 × 16 | 6 | box truck |

## 8. Landmarks

| Model | Size | Notes |
|---|---|---|
| `PlazaFountain` | 12 wide × 5.6 tall | basin, pedestal, bowl, water disc |
| `PlazaPaving` | ring radius 55 | can stay as generated parts |
| `WaterTower` | 14 wide × 44 tall | tank on four legs with a ladder and cap |
| `CanalBridgeDeck` | 20 × 1 × 70 (one span) + railings | can stay as generated parts |
| `BikeBridge` | 6 × 1 × 70 + railings | can stay as generated parts |
| `ParkGazebo` (optional) | 12 × 8 × 12 | Maple Park centrepiece |

## 9. Depot (`ServerStorage/DepotTemplates`)

Plots are 60 × 50 studs.

| Model | Size | Notes |
|---|---|---|
| `DepotOffice` | 20 × 9 × 14 | small office with a door and window |
| `DepotSign` | 10 × 3 × 0.6 on a 2-post frame | face named `Screen` for the owner's name; frame colour = `Primary` (sign cosmetic) |
| `DepotFence` | 4 × 3 × 0.3 tiling segment + `DepotGate` 8 × 3 × 0.3 | low fence around the plot |
| `DepotParkingLine` | 6 × 0.1 × 14 | painted bay markings |
| `DepotPlanter` | 4 × 2.4 × 2 | "Planters & flags" decoration |
| `DepotFlag` | 0.3 × 10 × 0.3 pole + 4 × 2.5 flag | same decoration |
| `DepotLights` | string of small lamps, 20 long | "String lights" decoration |
| `ForkliftStatic` (optional) | 4 × 6 × 8 | yard dressing |

## 10. Navigation and UI props (client-side)

| Model | Size | Notes |
|---|---|---|
| `NavMarkerPickup` | 1.5 sphere | orange, glowing |
| `NavMarkerDeliver` | 1.5 cube | green, glowing |
| `NavArrow` (optional) | 3 × 0.5 × 3 | floor chevron used instead of spheres on the road |

## 11. Not models (made in-engine)

Roads, sidewalks, lane markings, ramps, embankments, the ground, the canal (terrain water), lighting, UI icons (text glyphs), sounds (`assets/audio`).

## Totals

Vehicles 3 (+1 optional), packages 5, NPC figures 6 (+ variants), buildings 18 kit models, street pieces 9, props 13 (+ variants), parked vehicles 2 (+ variants), landmarks 3 required (+ 3 optional), depot 7 (+1 optional), nav markers 2. **About 70 models**, roughly 85 with colour variants.

## Suggested order

1. Bicycle, Scooter, Van, the five packages (the player stares at these the whole game).
2. Door, AddressSign, PickupPad/ArrivalPad, Counter, the four business buildings, DeliveryHub.
3. House/Shop/Apartment kits, Lamp, Tree, Bench, ParkedCar.
4. Warehouse/Office kits, Container, Dumpster, Crate, ParkedTruck, LoadingBay, RollerDoor.
5. BeaconTower, WaterTower, PlazaFountain, depot set, NPCs, nav markers.
