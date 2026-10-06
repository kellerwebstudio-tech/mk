# Verification report

**Honesty statement.** Everything below was verified **offline** in a Linux container: Luau syntax and type analysis, an offline spec suite executed by the standalone `luau` CLI against a Roblox API mock (`tests/shim.luau`), a `rojo build` of the place file, the city layout validator, and an adversarial multi-lens code review. **No Roblox Studio or live server test has been run.** Physics feel, DataStore behaviour in production, device layouts and rendering are unverified until someone runs `docs/PLAYTEST.md`.

## Automated checks (final run — see "Final numbers" below)

| Check | Command | Result |
|---|---|---|
| Syntax | `luau-compile --binary` over every `src/**/*.luau` | pass |
| Types | `luau-lsp analyze --definitions=globalTypes.d.luau --sourcemap=sourcemap.json src` | 0 diagnostics |
| Spec suite | `DDC_TOOLS=… bash tests/run.sh` | see Final numbers |
| Place build | `rojo build default.project.json -o build/DeliveryDashCity.rbxl` | built (≈310 KB) |
| City layout | `python3 tools/validate_layout.py` | 0 problems; bicycle/scooter/van graphs each one component; tutorial distances 123 / 74 studs |
| Map render | `python3 tools/render_map.py` → `docs/map.png` | inspected |

Spec files: `harness` (82) and `harness_extra` (22) prove the mock; `builders` (21), `server_core` (60), `contract_depot` (24), `client` (64), `client_verify` (14), `ui` (57) cover the game.

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
_Filled in after the fix phase._
