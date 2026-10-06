# Order, upgrade and economy tables (initial model — requires playtesting)

All values are read from `src/shared` at runtime; this page mirrors them for review. Change the source files, not this page.

## Order pricing (`EconomyConfig`, `BusinessDefinitions`, `OrderService.CreateOrder`)

```
basePay   = round((business.basePay + business.perStud × routeDistance) × (1 + sizeBonus[size]))
tipMax    = round(basePay × business.tipFraction)
tip paid  = tipMax × tipMultiplier(upgrades) × timeliness      (timeliness 1 inside timeLimit → 0 at 2× timeLimit)
timeLimit = max(90 s, routeDistance / 24 studs/s × 2.2)         (tutorial orders untimed)
rep       = business.repPerDelivery (+1 per size step above Small)
```
Size bonus: Small +0 %, Medium +25 %, Large +60 %. Units: Small 1, Medium 2, Large 4.

| Business | Neighbourhood | Unlock | Base | Per stud | Tip cap | Rep | Prep time | Distance band (bike graph) | Items (size) |
|---|---|---|---|---|---|---|---|---|---|
| Bean & Bun Café | Downtown | 0 Rep | $22 | $0.10 | 30 % | 5 | 4–9 s | 100–280 | 2 flat whites (S), Breakfast bun box (S), Iced latte tray (S), Office pastry platter (M) |
| Slice Street Pizza | Downtown | 0 Rep | $28 | $0.09 | 30 % | 6 | 6–12 s | 130–640 | Margherita (S), Pepperoni (S), 2 large pizzas (M), Party order (L) |
| Fresh Lane Market | Residential | 120 Rep | $35 | $0.10 | 25 % | 9 | 8–14 s | 160–640 | Weekly groceries (M), Fruit & veg box (S), Family shop (L) |
| Crate & Co. Supply | Industrial | 500 Rep | $60 | $0.12 | 20 % | 14 | 10–18 s | 220–650 | Spare parts crate (M), Pallet of supplies (L), Shop restock boxes (M) |

Worked examples (bicycle route distances from the validator):
| Route | Distance | Size | Base pay | Tip cap | Time limit |
|---|---|---|---|---|---|
| Slice Street → D02 (tutorial) | 74 | S | $45 fixed | — | none |
| Café → downtown apartment | 180 | S | $40 | $12 | 90 s |
| Pizza → Maple Hill house | 560 | M | $98 | $29 | 113 s |
| Crate & Co. → loading bay | 420 | L | $177 | $35 | 90 s |

## Order board rules
| Rule | Value |
|---|---|
| Orders kept on the board | 3–6 (generator every 5 s) |
| Board lifetime (Available → Expired) | 150 s |
| Accepted orders | never expire; late = reduced tip, full base pay |
| Multiple orders unlock | tutorial complete + 3 deliveries |
| Pickup / delivery distance | 18 / 16 studs (door) or 20 (arrival pad) |
| Cancel collected order | −2 Rep (floor 0) |

## Capacity (`VehicleDefinitions`, `UpgradeDefinitions`)
| Vehicle | Base | With upgrades | Mask (routes) |
|---|---|---|---|
| Bicycle | 1 | 3 (Basket I, II) | everything incl. alleys, bike paths, bike bridge |
| Scooter | 3 | 5 (Top Box I, II) | roads + streets |
| Van | 8 | 12 (Shelving I, II) | roads + industrial + bridge only |
On foot: 1.

## Upgrades
| Id | Name | Effect | Price | Requires |
|---|---|---|---|---|
| BasketI | Basket I | Bicycle +1 | $75 | — |
| BasketII | Basket II | Bicycle +1 | $350 | Basket I, 60 Rep |
| ThermalBagI | Thermal Bag I | tips +15 % | $200 | — |
| ThermalBagII | Thermal Bag II | tips +15 % | $900 | Thermal I, 100 Rep |
| TunedGears | Tuned Gears | bicycle speed +5 % | $250 | 40 Rep |
| ScooterTopBoxI | Scooter Top Box I | Scooter +1 | $900 | Scooter, 150 Rep |
| ScooterTopBoxII | Scooter Top Box II | Scooter +1 | $1,800 | Top Box I, 250 Rep |
| VanShelvingI | Van Shelving I | Van +2 | $3,000 | Van, 600 Rep |
| VanShelvingII | Van Shelving II | Van +2 | $5,000 | Shelving I, 800 Rep |

## Vehicles
| Vehicle | Price | Rep | Max speed | Accel | Brake | Turn rate |
|---|---|---|---|---|---|---|
| Bicycle | free | 0 | 38 | 22 | 40 | 2.6 rad/s |
| Scooter | $1,500 | 150 | 55 | 26 | 46 | 2.1 rad/s |
| Van | $8,000 | 600 | 62 | 18 | 36 | 1.35 rad/s |

## Reputation
| Source | Rep |
|---|---|
| Delivery | 5–14 (+1 per size step) |
| Tutorial completion | +25 |
| Lunch Rush batch | +50 |
| Milestones 10 / 50 / 100 / 250 deliveries | +25 / +75 / +150 / +300 |
| Unlocks | Grocery 120, Scooter 150, Lunch Rush 50 (+5 deliveries), Warehouse 500, Van 600, Depot 1,000, driver categories 1,000 / 1,200 / 1,500 |

## Lunch Rush (`ContractDefinitions`)
| Parameter | Value |
|---|---|
| First opening | 120 s after server start, then every 480 s after the previous rush ends |
| Window / grace | 240 s / 180 s |
| Offers per player | 5 (Small/Medium) |
| Batch | 2–4 orders within max capacity |
| Bonus | 40 % of the batch base pay + $60 + 50 Rep |
| Requirements | 50 Rep, 5 deliveries, tutorial complete |

## Depot and NPC drivers (`DepotDefinitions`)
| Item | Cost |
|---|---|
| Depot | $12,000, 1,000 Rep |
| Driver slot 2 | $6,000 |
| Hire driver | $2,500 |

| Category | Unlock | Duration | Revenue | Upfront cost | Net |
|---|---|---|---|---|---|
| Downtown Food Run | depot | 10 min | $900 | $300 | $600 |
| Maple Hill Groceries | 1,200 Rep | 12 min | $1,300 | $450 | $850 |
| Dockside Parcels | 1,500 Rep | 15 min | $1,900 | $700 | $1,200 |

Offline: an assignment that was paid for completes once when its end time has passed; no new assignments start offline.

## Cosmetics (Cash) — see `CosmeticDefinitions`
Bicycle colours $150–$450, scooter skins $600–$900, van paint $1,500–$1,800, van decals $500–$2,500, bag styles $300–$600, uniforms $250–$400, depot sign $1,200, depot decoration $1,500. "Neon"/"Elite"/"Deluxe"/"Lights" variants are store-only and disabled until product ids exist.
