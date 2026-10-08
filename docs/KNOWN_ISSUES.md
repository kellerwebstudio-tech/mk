# Known issues and next priorities

Updated after the Phase 2 review. Severity: H = will affect players, M = edge case / quality, L = polish.

## Live findings (from the owner's first Studio run)
- **Everything looked half-sunk into the ground (fixed in `CityBuilder`)**: roads, pads and bases were placed flush with the smooth-terrain surface at y = 0, so the terrain (and its grass decoration) rendered through them. The ground is now a set of large anchored Grass parts whose top sits 0.1 stud under the road surface, terrain is pushed 2 studs below that with `Decoration` off, and it only shapes the canal basin. Not yet re-checked in Studio.

## Not verified live (needs Roblox Studio)
- **Embedded meshes (H)**: the owner reported every person as grey boxes in their first run with the embedded people; no Output line was available, so the failing stage is unknown. This build hardens the path (`MeshPart:ApplyMesh` instead of a plain `Clone()` for every attached copy, texture-only failures no longer box the entry, nil `EditableMesh` / `EditableImage` results are explained) and names the stage in every warning; the summary line in the Output window now pinpoints any remaining failure. Two engine rules are documented in `docs/MESHES.md`: a published experience needs **Enable Mesh / Image APIs** switched on (ID-verified owner), and live clients have an unpublished editable memory budget. Neither the decode nor the attach has been run in Roblox by the authors.
- **Vehicle feel (H)**: handling constants in `VehicleDefinitions` (acceleration, turn rates, ride height gain, camera offsets) were reasoned, never driven. Expect a tuning pass. The ground-follow model cannot flip, but ramp transitions and curb climbs need to be watched for visual pops.
- **Seat input (H)**: driving input relies on `VehicleSeat.ThrottleFloat/SteerFloat` being delivered to the occupant (seat enabled while riding). If a device reports zero, `InputController` falls back to keys / thumbstick / `Humanoid.MoveDirection`; confirm on touch and gamepad.
- **Touch layout (M)**: at 375×667 the UI scale floor (0.75) renders buttons at ~33 px; raise `UIKit` touch scale after a device check if layouts allow. On touch the minimap moves to the top-left under the mini-order list (140 px, translucent; `Minimap.SetTouchLayout`) and the vehicle readout is raised `HUD.VEHICLE_HUD_TOUCH_BOTTOM` (150 design px) above the jump button / action cluster; neither placement has been seen on a device.
- **DataStore behaviour (M)**: session lock, retries and BindToClose are exercised only against the in-memory mock.
- **Streaming (M)**: `StreamingEnabled` is on; client code tolerates missing instances, but marker/door visuals for far destinations were not observed in-engine.
- **Visuals (L)**: generated city geometry (sidewalk mitres, embankments under ramps, sign readability), vehicle proportions, package placement, NPC walk poses and lighting need an art pass.

## Design gaps accepted for the first release
- No package damage mechanic (by design until handling is stable).
- No moving traffic; parked vehicles only.
- NPC pedestrians are client-side cosmetic figures (not Humanoids); they do not react to vehicles.
- Rider posture uses the default seated pose (no custom animations).
- Cross-canal deliveries are long for a bicycle; the bike bridge and park paths are the intended shortcuts.
- Lunch Rush needs capacity ≥ 2 (a bicycle without Basket I cannot join; the UI explains the requirement).
- Monetization disabled (no product ids); store-only cosmetics are visible but not purchasable.
- Sounds are synthesized placeholders in `assets/audio`; engine loops are short synthetic loops.

## Next priorities
1. Studio playtest of `docs/PLAYTEST.md` sections A and B; tune handling, camera and ride height; record results in `docs/VERIFICATION.md`.
2. Device pass (phone + gamepad) for touch button placement, UI scale, minimap position and prompt readability.
3. Art pass: replace generated buildings' flat facades with modular meshes, add proper vehicle meshes (keep the collision box), real sounds.
4. Economy tuning from telemetry: time-to-first-upgrade, time-to-scooter, depot payback.
5. Optional: light cosmetic traffic on main roads once vehicles are proven stable; package condition mechanic.
