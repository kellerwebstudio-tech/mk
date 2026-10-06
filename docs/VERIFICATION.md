# Verification report

**Honesty statement.** Everything below was verified **offline** in a Linux container: Luau syntax and type analysis, an offline spec suite executed by the standalone `luau` CLI against a Roblox API mock (`tests/shim.luau`), a `rojo build` of the place file, the city layout validator, and an adversarial multi-lens code review. **No Roblox Studio or live server test has been run.** Physics feel, DataStore behaviour in production, device layouts and rendering are unverified until someone runs `docs/PLAYTEST.md`.

## Automated checks (final run — see "Final numbers" below)

| Check | Command | Result |
|---|---|---|
| Syntax | `luau-compile --binary` over every `src/**/*.luau` | pass |
| Types | `luau-lsp analyze --definitions=globalTypes.d.luau --sourcemap=sourcemap.json src` | 0 diagnostics |
| Spec suite | `DDC_TOOLS=… bash tests/run.sh` | 295 passed, 0 failed, 0 skipped |
| Place build | `rojo build default.project.json -o build/DeliveryDashCity.rbxl` | built (324,508 bytes) |
| City layout | `python3 tools/validate_layout.py` | 0 problems; bicycle/scooter/van graphs each one component; tutorial distances 123 / 74 studs |
| Map render | `python3 tools/render_map.py` → `docs/map.png` | inspected |

Spec files: `harness` (67) and `harness_extra` (14) prove the mock; `builders` (23), `server_bootstrap` (1), `server_core` (65), `contract_depot` (21), `client` (61), `client_verify` (12), `ui` (31) cover the game — 295 specs in total.

## Testing requirements → status

| Requirement | Status | Evidence |
|---|---|---|
| A new player can complete the tutorial delivery | PASSED (offline) | `server_core`: "runs steps 0-9 on a scripted first session"; "drives the full vehicle + delivery flow through remotes"; `client`: ClientBootstrap seeding, InteractionController prompts; review lens "first five minutes" walked the chain (findings fixed, see below) |
| All vehicles mount and dismount reliably | PASSED (offline) / UNTESTED (live) | `server_core`: Spawn/Mount/Dismount/Recover/Despawn transitions with the mock seat semantics; live seat timing unverified |
| Braking works consistently | PASSED (offline) | `client`: `_stepModel` brake stops within expected time, coast, reverse |
| Vehicles recover from flipping and falling | PASSED (offline) | `server_core`: watchdog recovers below killY; `client`: recovery request rate limit; the ground-follow model cannot flip by design |
| Respawning restores valid state | PASSED (offline) | `server_core`: "dismounts on death and keeps the vehicle parked", package re-attach on CharacterAdded |
| Pickup requires the correct order and location | PASSED (offline) | `server_core`: "checks pickup distance and capacity", Accept/pickup state validation |
| Delivery pays exactly once | PASSED (offline) | `server_core`: "pays exactly once even when RequestDelivery is called twice"; RewardService `rewardGranted` guard |
| Capacity limits cannot be bypassed | PASSED (offline) | `server_core`: Accept/pickup NoCapacity; `contract_depot`: Join capacity; client mirrors the rule only for UX |
| Route guidance respects vehicle restrictions | PASSED (offline) | `tools/test_routegraph.py` (mask filtering; van never uses alley/bike edges); `client`: NavigationController uses the vehicle mask |
| Missed turns trigger a valid route update | PASSED (offline) | `client`/`client_verify`: off-route recompute (> 24 studs, rate-limited to 1 s) |
| Cancelling removes relevant markers and items | PASSED (offline) | `server_core`: cancel removes package, −2 Rep floored; `client`: markers cleared with no stops |
| Visitors cannot claim another player's orders | PASSED (offline) | orders are per-player pools; `server_core` Accept NotFound for foreign ids; `contract_depot` Join ownership |
| NPC driver income calculated and collected exactly once | PASSED (offline) | `contract_depot`: tick completes once; Collect exactly once with rollback on AddCash failure |
| Depot reassignment clears stale state | PASSED (offline) | `contract_depot`: reassigning a returned driver keeps pending cash and starts a new assignment |
| Saving preserves progression | PASSED (offline) | `server_core`: save on leave, autosave only when dirty, BindToClose |
| Failed loads do not overwrite data | PASSED (offline) | `server_core`: "never saves after a failed load", session lock respected |
| Every required action works on mobile and controller | PARTIAL | bindings for keyboard/gamepad/touch exist and are spec'd (`client`: InputController); touch button placement, UI scale on phones, gamepad focus flow are UNTESTED live |
| Eight active players remain within performance targets | UNTESTED | budgets reasoned (ARCHITECTURE §11), no measurement possible offline |

## Adversarial review (Phase 2)

Eight reviewers (contract conformance, security, reliability, vehicle/input, Roblox API misuse, first five minutes, performance, UX) produced 62 findings; each was judged by two independent skeptics. 33 were confirmed and 31 refuted. Confirmed findings and their resolution are listed in the "Review findings" section below.

## Final numbers

Final integration run after the fix phase (offline, Linux container, 2026-10-06). Commands as in the table above with `DDC_TOOLS` pointing at the offline toolchain.

| Check | Exact result |
|---|---|
| Syntax | `luau-compile --binary` over `src/**/*.luau`: 65 files checked, 0 failed |
| Types | `luau-lsp analyze --definitions=globalTypes.d.luau --sourcemap=sourcemap.json --base-luaurc=.luaurc --ignore 'tests/**' src`: 0 diagnostics, exit 0 |
| Spec suite | `bash tests/run.sh`: `bundle.py: wrote tests/build/all.luau (73 modules, 9 spec files, 0 warnings)` → **295 passed, 0 failed, 0 skipped** |
| Place build | `rojo build default.project.json -o build/DeliveryDashCity.rbxl`: built, 324,508 bytes |
| City layout | `python3 tools/validate_layout.py`: `Validation: 0 problem(s)`; 115 nodes / 179 edges; Bicycle 179 edges (16,122 studs), Scooter 159 (14,680), Van 129 (12,320), each 1 component; tutorial hub → Slice Street Pizza 123 studs (max 180), pizza → D02 74 studs (max 220); `VALIDATION OK` |
| Debug leftovers | `src/` has no `DEBUG` or `print("` hits and no TODO/FIXME/XXX/HACK markers; the two remaining `print(` calls are the deliberate "server ready" / "client ready" startup lines in the bootstraps |

The CityBuilder spec builds the real layout at 3,550 parts (budget 4,500). No Roblox Studio or live server run has been performed; see the honesty statement at the top.

## Review findings (confirmed and resolved)

| Severity | Id | Finding | Files | Resolution |
|---|---|---|---|---|
| blocker | api-1 | ServerBootstrap waits for `Services` as a child of the Script, but Rojo places it as a sibling: the server never initialises | ServerBootstrap.server.luau | fixed |
| high | seed-1 | Touch jump button unseats the rider while driving | VehicleController.luau, InputController.luau | fixed |
| high | contract-1 | Client treats VehicleStateChanged state="Despawning" as a live vehicle: pad spawn prompt dead after any despawn | InteractionController.luau, VehicleService.luau, ClientBootstrap.client.luau | fixed |
| high | contract-2 | ShopService.EquipCosmetic never calls DepotService.RefreshVisuals: DepotSign / DepotDecor purchases have no visible effect | ShopService.luau, DepotService.luau, DepotBuilder.luau | fixed |
| high | security-2 | SpawnVehicle/Dismount/Recover reset the anti-cheat sampler on demand, keeping it permanently blind | VehicleService.luau, AntiCheatService.luau | fixed |
| high | reliability-1 | BindToClose does not wait for leave-saves already in flight | PlayerDataService.luau | fixed |
| high | vehicle-1 | AlignOrientation target is never set before the chassis is unanchored, so every Mount yaws the vehicle toward world -Z (or the previous ride's heading) | VehicleService.luau, VehicleBuilder.luau, VehicleController.luau | fixed |
| medium | seed-2 | Minimap covers the dynamic thumbstick zone on touch devices | Minimap.luau, UIController.luau, HUD.luau | fixed |
| medium | seed-3 | Lunch Rush offers ignore the business delivery profile | ContractService.luau | fixed |
| medium | seed-4 | ShopMenu rebuilds ViewportFrame previews on every ProfileUpdated | ShopMenu.luau | fixed |
| medium | ux-3 | Horn and RecenterCamera share R3; Horn is bound last, has no consumer, and swallows the input so gamepad Recenter never fires | InputActions.luau, InputController.luau, CameraController.luau | fixed |
| medium | contract-3 | DepotPublicState.publicPlots[].drivers is a number on the server but DepotMenu reads it as a slot array (always shows '0 drivers') | DepotMenu.luau, DepotService.luau | fixed |
| medium | reliability-3 | Client vehicle state stays 'Despawning' forever, killing the pad 'Take vehicle' prompt and F-to-spawn | InteractionController.luau, ClientBootstrap.client.luau | fixed |
| medium | vehicle-5 | Horn and RecenterCamera are both bound to ButtonR3; Horn is bound last and sinks, so gamepad recenter never fires (and nothing consumes Horn) | InputActions.luau, InputController.luau | fixed |
| medium | firstfive-2 | AlignOrientation CFrame is never updated after PivotTo, so the first mount snaps the vehicle to face world -Z | VehicleBuilder.luau, VehicleService.luau, VehicleController.luau | fixed |
| medium | firstfive-3 | Tutorial stays on step 2 ('Get on your bike') for a player who walks: pickup does not advance it | TutorialService.luau | fixed |
| medium | firstfive-4 | Client treats the terminal 'Despawning' vehicle state as a live vehicle: the pad 'Take vehicle' prompt never comes back after a despawn | InteractionController.luau, ClientBootstrap.client.luau, VehicleService.luau | fixed |
| medium | performance-1 | Full-screen CanvasGroup HUD is re-rasterised every frame while driving | HUD.luau, VehicleController.luau | fixed |
| medium | ux-4 | Most purchase/depot/contract actions produce two toasts (server Notify + client UIKit.notify) | ShopService.luau, ShopMenu.luau, UpgradeMenu.luau | fixed |
| medium | ux-5 | Touch layout: minimap sits in the thumbstick zone and the vehicle readout under the jump button / button cluster (KNOWN_ISSUES claims the minimap was moved; code shows it was not) | Minimap.luau, HUD.luau, CameraController.luau | fixed |
| medium | ux-9 | Controls reference and touch glyph table advertise controls that do not exist on the device | InputActions.luau, SettingsMenu.luau, UIController.luau | fixed |
| low | contract-4 | CityService.GetSafeRespawnCFrame raises by a constant 3 but VehicleService parks the chassis there: spawned/recovered Parked vehicles float above the road | VehicleService.luau, CityService.luau | fixed |
| low | security-4 | Per-order rate-limiter buckets are never released: unbounded memory growth from RequestPickup/RequestDelivery with arbitrary ids | InteractionService.luau, RateLimiter.luau | fixed |
| low | reliability-5 | AcceptOrder accepts Lunch Rush offers directly, bypassing Join and desynchronising ContractService | OrderService.luau, ContractService.luau | fixed |
| low | performance-2 | orderLimiter buckets are keyed by user:action:orderId strings and never removed (unbounded growth, client-growable) | InteractionService.luau, RateLimiter.luau | fixed |
| low | ux-7 | Phone-width layout: results card + tutorial banner cover most of the centre column and overlap the toast column | UIController.luau, ResultsToast.luau, TutorialBanner.luau | fixed |
| low | ux-8 | Modal focus is not contained: HUD buttons stay selectable behind the scrim and Close has no gamepad hint | UIController.luau, HUD.luau, UIKit.luau | fixed |
| low | reliability-7 | Per-order RateLimiter buckets are never evicted (unbounded growth over server lifetime) | InteractionService.luau, RateLimiter.luau | fixed |
| low | vehicle-8 | Right-mouse orbit does not lock the cursor while the PlayerModule camera is disabled under CameraType.Scriptable | CameraController.luau | fixed |
| low | vehicle-9 | Van seat offset places the rider's head and upper torso through the cab roof | VehicleDefinitions.luau | fixed |
| low | firstfive-5 | Step 9 'You're ready' is never shown: the server sends it with completed=true and the client hides the banner | TutorialController.luau, TutorialService.luau | fixed |
| low | firstfive-6 | Welcome banner is driven by the default ClientState before the profile exists; Continue fails silently with Locked | ClientState.luau, TutorialController.luau | fixed |
| low | firstfive-7 | The order-board kiosk is built inside the solid 'Dash Hub Kiosk' building | CityLayout.luau, CityBuilder.luau | fixed |

Every confirmed finding above was fixed in place by the fix phase, each with a regression spec (suite grew from 273 to 295 specs). Interface changes made while fixing are recorded in `docs/ARCHITECTURE.md` section 12.

Refuted claims (31) are kept out of the code; the most instructive ones:

- security-1: Instant pickup/delivery by teleporting: CheckPosition never samples at check time, so the 1 Hz sampler is trivially raced
- vehicle-2: ThrottleFloat/SteerFloat are camera-relative, so orbiting the camera while driving turns throttle into steering (and reverses it at 180°)
- firstfive-1: 'Take vehicle' at a hub pad spawns the bike 26 studs away on the Plaza Ring, floating above its ride height
- ux-1: D-pad Up/Right are sunk globally, so gamepad menu navigation fights ToggleOrders/NextStop
- ux-2: Gamepad focus is destroyed on every screen re-render (Up/Down, checkbox, Cancel confirm, every server update)
- security-3: Capacity check is bypassed after pickup: EquipVehicle/DespawnVehicle moves a full Van load onto a Bicycle or on foot
- reliability-2: Quick rejoin to the same server loads stale data while the previous leave-save is still writing
- reliability-4: Switching/equipping a vehicle never re-validates the carried load against the new vehicle's capacity
- vehicle-3: Touch jump button (and any Humanoid.Jump path outside ContextActionService) ejects the rider mid-drive; the jump guard only covers Space/ButtonA
- vehicle-4: Watchdog teleports an owner who left the seat on their own back to the vehicle (moveCharacter = true for the occupant == nil case)
- vehicle-6: Seated rider's collidable character parts stay in the Players group, so riders physically collide with pedestrians, other players and other riders despite the anti-griefing collision matrix
- ux-6: Tutorial/first-five-minutes wording does not match the real controls and flow
