# Delivery Dash City

A Roblox delivery simulator: start as a bicycle courier, learn the city, upgrade, unlock a scooter and a van, and open a depot with NPC drivers while driving deliveries yourself stays fun.

This repository is a complete **Rojo** project (Luau source + authored city data). The city, vehicles, packages and NPCs are built procedurally from data at server start, so the whole game lives in source control; no binary assets are required.

| Document | What it covers |
|---|---|
| `docs/DESIGN.md` | Design summary, first-release scope, plan, initial economy model |
| `docs/ARCHITECTURE.md` | Explorer hierarchy, module/remote/data contract, service APIs |
| `docs/VEHICLES.md` | Vehicle framework specification and tuning parameters |
| `docs/CITY.md` | City layout, roads, shortcuts, businesses, destinations, how to edit |
| `docs/TESTING.md` | Offline test harness, static analysis, build |
| `docs/VERIFICATION.md` | Verification report: passed, failed, untested, manual playtest script |
| `docs/PROGRESS.md` | Progress record |
| `docs/KNOWN_ISSUES.md` | Known issues and next priorities |

## Honest status

- Built and verified **offline only**: Luau syntax/type analysis (`luau-lsp`), unit/integration specs executed with the standalone `luau` CLI against a Roblox API mock, and a `rojo build` of the place file.
- **No live Roblox Studio playtest has been run** by the authors of this repository. Physics tuning values, UI layout on real devices and DataStore behaviour are reasoned, not measured. Follow the manual playtest script in `docs/VERIFICATION.md` before publishing.
- Monetization is disabled (no product IDs). Sound ids are placeholders (see "Audio").

## Installation (Rojo, recommended)

1. Install Roblox Studio and the [Rojo](https://rojo.space) Studio plugin.
2. Install the Rojo CLI (7.4+). Either use [Rokit](https://github.com/rojo-rbx/rokit)/[Aftman](https://github.com/LPGhatguy/aftman) or download a release binary.
3. Clone this repository and, from its root, build a place file:
   ```bash
   rojo build default.project.json -o build/DeliveryDashCity.rbxl
   ```
4. Open `build/DeliveryDashCity.rbxl` in Roblox Studio.
5. For live sync while editing source: run `rojo serve default.project.json`, then in Studio open the Rojo plugin and click **Connect**.
6. Press **Play** (or **Start** a local server with 2+ players under *Test → Clients and Servers*). The server builds the city in the first seconds; the console prints `Delivery Dash City server ready`.

Studio settings that must be enabled for the game to work when published:
- *Game Settings → Security → Enable Studio Access to API Services* (for DataStores in Studio tests).
- *Game Settings → Options → Max players: 8* (server size).
- HTTP requests are not used.

### Installing without Rojo (manual)

Open an empty place and recreate the tree in `default.project.json`:
- Copy each file under `src/shared` into `ReplicatedStorage/Shared` as ModuleScripts with the same folder structure and names (drop the `.luau` extension; `Util`, `Config`, `Definitions`, `City` become Folders).
- Copy `src/server` into `ServerScriptService/DeliveryDash` (`ServerBootstrap.server.luau` becomes a **Script** named `ServerBootstrap`; everything under `Services`/`Builders` becomes ModuleScripts).
- Copy `src/client` into `StarterPlayer/StarterPlayerScripts/DeliveryDashClient` (`ClientBootstrap.client.luau` becomes a **LocalScript**; the rest ModuleScripts).
- Create the folders listed under `ReplicatedStorage`, `ServerStorage` and `Workspace` in `default.project.json` and apply the `$properties` (Workspace streaming, Lighting, StarterGui).
This is tedious; Rojo is strongly recommended.

## Playing

- You spawn at the delivery hub on the central plaza beside the vehicle pads. Press **F** (gamepad **Y**, touch **Ride**) near a pad to spawn and mount your bicycle.
- Open the order board with **Tab** (gamepad **D-pad up**, touch **Orders**), accept an order, follow the route markers to the business, press **E** (**X** / **Interact**) at the counter to collect, ride to the address and press **E** at the door.
- **Space** brakes (gamepad **LT**, touch **Brake**), **R** (hold) recovers a stuck vehicle, **V** recenters the camera, **M** opens the menu (shop, upgrades, depot, settings).

## Audio

`src/shared/Config/AudioConfig.luau` lists every sound by key. Entries with `rbxasset://` ids use sounds that ship with the Roblox client as placeholders; entries with `""` are silent. Upload your own sounds through the Creator Dashboard and replace ids with `rbxassetid://<id>`. The game never breaks when a sound is missing.

## Monetization

`src/shared/Config/MonetizationConfig.luau` has every paid item with `assetId = nil`. Purchases are disabled until you create the products/passes in the Creator Dashboard and paste the ids. Only cosmetics and private servers are intended for sale; nothing here gates progression.

## Development

- `tests/run.sh` runs the offline spec suite (`DDC_TOOLS=<dir with luau binaries>`), `tools/analyze.sh` runs type analysis, `tools/build.sh` builds the place file. See `docs/TESTING.md`.
- The city is data: edit `src/shared/City/CityLayout.luau`, run `python3 tools/validate_layout.py` and `python3 tools/render_map.py` to validate connectivity and preview the map (`docs/map.png`).
