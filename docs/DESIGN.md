# Delivery Dash City — Design Summary

**Working title:** Delivery Dash City
**Genre:** Delivery simulator / arcade driving / business progression
**Server size:** 8 players. **Devices:** PC, mobile, controller.
**Fantasy:** "I started delivering on a bicycle, and now I run a delivery company, but driving deliveries myself is still fun."

## 1. Design summary

The player is an independent courier. Orders arrive on an in-game "Dash" app (HUD order board) that works anywhere in the city, so nobody has to walk back to a hub between jobs. A delivery is: accept an order, ride to the business, collect a visible bag/box, choose a route, reach the customer's door, hand it over, get paid and rated. The interesting decisions are **route choice** (alleys and bike paths are bicycle-only; main roads are faster for scooters and vans), **batching** (carry several compatible orders once capacity allows and reorder your stops), and **investment** (capacity, tips, vehicles, then a depot with NPC drivers that earn supporting income while you keep driving).

Three neighbourhoods give three delivery feels:

| Neighbourhood | Feel | Routes | Typical orders |
|---|---|---|---|
| Downtown | Dense, short hops, many turns | Alleys (bike-only), narrow streets (bike + scooter), plaza ring (all) | Café drinks and food, pizza |
| Residential (Maple Hill) | Longer smooth streets, moderate hill, park with bike paths | Bridge over the canal (all vehicles), bike bridge (bike-only shortcut), park paths (bike-only) | Pizza, groceries |
| Industrial (Dockside) | Wide roads, warehouses, loading bays | Wide roads suited to vans | Parcels, bulk grocery |

Landmarks that make the city legible: the **central plaza** (spawn + delivery hub), the **Beacon Tower** north-west of the plaza, the **Canal Bridge** to the east, **Maple Park** on the hill, and the **Dockside water tower** to the south.

### Core loop
Accept → reach the business → collect → choose a route → deliver → Cash + Reputation → upgrade / unlock → repeat with more orders, larger loads, more neighbourhoods, better vehicles, special contracts, a depot and NPC drivers.

### Vehicles
A shared arcade "ground-follow" controller (raycast ride height + constraint-driven velocity and orientation) with per-vehicle handling tables. Vehicles cannot flip under normal driving, wheels are cosmetic, braking is predictable, and a stuck/fallen vehicle can be recovered with one button. Only the owner can mount a personal vehicle. Vehicles do not collide with characters or other vehicles (anti-griefing), only with the world.

| Vehicle | Max speed | Capacity (base) | Access |
|---|---|---|---|
| Bicycle | 38 studs/s | 1 unit (+2 via upgrades) | Everything incl. alleys, bike paths, park paths, bike bridge |
| Scooter | 55 studs/s | 3 units (+2) | Roads and narrow streets; no alleys/bike paths |
| Van | 62 studs/s | 8 units (+4) | Roads and industrial roads only |

Order sizes: Small = 1 unit, Medium = 2 units, Large = 4 units.

### Progression beats
1. First delivery within ~3 minutes (tutorial order from Slice Street Pizza to a plaza-side apartment).
2. Second delivery with a route choice (alley shortcut is highlighted).
3. First upgrade (Basket I, $75, +1 capacity) after two deliveries.
4. Multiple orders unlock after 3 deliveries.
5. Grocery market unlocks at 120 Reputation; Scooter purchasable at 150 Reputation / $1,500.
6. Lunch Rush contract unlocks at 50 Reputation and 5 deliveries.
7. Warehouse unlocks at 500 Reputation; Van at 600 Reputation / $8,000.
8. Depot at 1,000 Reputation / $12,000; two NPC driver slots; drivers run bounded 10-minute assignments.

## 2. First-release scope (what this repository implements)

- One cohesive city built procedurally from authored data (`CityLayout`), three neighbourhoods, landmarks, sidewalks, pedestrian routes, parked cosmetic vehicles, props.
- Four original pickup businesses: Slice Street Pizza, Bean & Bun Café, Fresh Lane Market, Crate & Co. Supply.
- 18 delivery destinations with unique IDs, readable addresses, arrival pads and door interaction zones.
- Bicycle, scooter and small van on one shared vehicle framework with separate handling configs.
- Server-authoritative order system (Available → Accepted → ReadyForPickup → Collected → Delivered; Cancelled/Expired), capacity, batching, stop reordering.
- Route guidance on an authored road graph with vehicle restrictions, missed-turn recalculation, markers, next-turn text, minimap.
- Cash, Reputation, vehicle shop, upgrades, cosmetics (bike colours, scooter skins, van paint + decal, bag styles, uniforms, depot sign + decoration).
- One special contract: Neighbourhood Lunch Rush.
- Depot plots with two NPC driver slots, assignments, exactly-once collection.
- Persistence with session locking, bounded retries, autosave, shutdown save, and no-overwrite-on-failed-load.
- Tutorial, HUD, order board, active delivery list, shop, upgrades, depot, results, settings.
- PC / touch / controller input, custom follow camera with reduced-motion option.
- Cosmetic client-side city life (pedestrians, staff, customers, depot workers).

Out of scope for this release (deliberately): drones, aircraft, moving traffic, package damage, offline income beyond finishing an already-paid assignment, paid products (disabled until product IDs are configured).

## 3. Prioritised implementation plan

| Stage | Goal | Status |
|---|---|---|
| 1 | Complete first delivery: city block, bicycle, one restaurant + destination, accept/collect/deliver/pay, minimal nav + UI | see docs/PROGRESS.md |
| 2 | Reliable progression: upgrades, saving, scooter + van, capacity + multiple orders | see docs/PROGRESS.md |
| 3 | City expansion: three neighbourhoods, all businesses/destinations, vehicle-specific routes, Lunch Rush | see docs/PROGRESS.md |
| 4 | Business ownership: depot plots, two NPC driver slots, assignment/income, social visits | see docs/PROGRESS.md |
| 5 | Polish: visuals, animation, lighting, audio, UI, tuning, onboarding, performance | see docs/PROGRESS.md |
| 6 | Verification: offline tests, static analysis, build, manual playtest script, known issues | see docs/VERIFICATION.md |

## 4. Initial economy model (REQUIRES PLAYTESTING — all numbers are a starting model)

### Delivery payouts
Base pay = business base + per-stud rate × route distance (bicycle graph). Tip = up to `tipMax` (a share of base) scaled by timeliness.

| Business | Base | Per stud | Typical distance | Typical base pay | Tip cap | Rep per delivery | Expected duration |
|---|---|---|---|---|---|---|---|
| Bean & Bun Café (Downtown) | $22 | $0.10 | 120–260 | $34–$48 | 30% | 5 | 45–90 s |
| Slice Street Pizza (Downtown) | $28 | $0.09 | 150–420 | $42–$66 | 30% | 6 | 60–120 s |
| Fresh Lane Market (Residential) | $35 | $0.10 | 200–450 | $55–$80 (+size bonus) | 25% | 9 | 90–180 s |
| Crate & Co. Supply (Industrial) | $60 | $0.12 | 250–600 | $90–$132 (+size bonus) | 20% | 14 | 120–240 s |

Size bonus: Medium +25%, Large +60%. Tutorial deliveries: $45 and $50 fixed.
Lateness: full tip inside the time limit, linearly to zero at 2× the limit; base pay is always paid.

### Reputation
+ per delivery (table above), +50 for a completed Lunch Rush batch, milestones at 10/50/100/250 deliveries (+25/+75/+150/+300). No reputation loss in the first release except cancelling a collected order (−2, floored at 0).

### Prices
| Item | Price | Requirement |
|---|---|---|
| Basket I / II (bike +1 cap each) | $75 / $350 | – / Basket I + 60 Rep |
| Thermal Bag I / II (+15% tip cap each) | $200 / $900 | – / Thermal I |
| Tuned Gears (+5% bike speed) | $250 | 40 Rep |
| Scooter | $1,500 | 150 Rep |
| Scooter Top Box I / II (+1 cap each) | $900 / $1,800 | Scooter |
| Van | $8,000 | 600 Rep |
| Van Shelving I / II (+2 cap each) | $3,000 / $5,000 | Van |
| Depot | $12,000 | 1,000 Rep |
| Depot driver slot 2 | $6,000 | Depot |
| Hire NPC driver | $2,500 per slot | Depot |
| Cosmetics | $150–$2,500 | varies |

### NPC driver assignments (per driver, bounded, server-timed)
| Category | Unlock | Duration | Revenue | Operating cost | Net |
|---|---|---|---|---|---|
| Downtown Food | Depot | 10 min | $900 | $300 | $600 |
| Residential Grocery | 1,200 Rep | 12 min | $1,300 | $450 | $850 |
| Industrial Parcel | 1,500 Rep | 15 min | $1,900 | $700 | $1,200 |

Active play earns roughly $40–$70 per minute on a bicycle downtown and $90–$150 per minute in a van on industrial routes, so two drivers (~$120–$240 per 10 minutes) stay supporting income.

### Intended time to major unlocks (estimates)
| Milestone | Estimate |
|---|---|
| First delivery | ~3 min |
| First upgrade | ~5 min |
| Multiple orders | ~8 min |
| Lunch Rush eligible | ~12 min |
| Scooter | ~30–40 min |
| Grocery unlock (120 Rep) | ~25 min |
| Warehouse unlock (500 Rep) | ~1.5 h |
| Van | ~2 h |
| Depot | ~3.5–4.5 h |
