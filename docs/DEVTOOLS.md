# Studio dev panel (DEVTOOLS)

A developer panel for playtesting and tuning Delivery Dash City inside Roblox Studio: grant cash
and reputation, unlock everything, skip or restart the tutorial, spawn any vehicle, teleport,
trigger events, tune vehicle handling **while driving** and dump a state report to the Output.

## Studio-only, by construction

The panel cannot be reached in a published game:

- **Server.** `src/server/Services/DevService.luau` is loaded like every other service, but
  `DevService.Init(ctx)` returns at once (creating nothing) unless `ctx.isStudio` **and**
  `RunService:IsStudio()` are both true. Only then does it create the RemoteFunction
  `ReplicatedStorage.Remotes.DevCommand`. That remote is created directly, outside the lists in
  `Shared/Util/Remotes.luau`, so `Remotes.createAll()` never makes it and the client's
  `Remotes.getFunction` cannot find it on a live server.
- **Client.** `src/client/Controllers/DevPanelController.luau` does nothing unless
  `RunService:IsStudio()` is true **and** `ReplicatedStorage.Remotes.DevCommand` appears within
  10 s. With no remote it stays dormant: no ScreenGui, no key binding.
- Every command is validated like a normal remote (strings <= 64 chars, finite numbers, small
  tables), rate limited to 10 calls/s per player and logged with
  `warn("[DevService] <command> by <player> {args} -> ok|failed: ...")` so it shows in the Output.
- `tests/specs/devtools.spec.luau` covers the gating (no remote outside Studio, dormant client).

## Opening it

Press Play (or Play Here) in Studio. A small orange **DEV** button sits in the top-right of the
screen; click it or press **F6** to toggle the panel. It is a right-side scrollable column
(~360 px) and is **not** a modal: `UIController.IsModalOpen()` stays false, the HUD, prompts and
driving input keep working, and input outside the panel passes through. Close it with **X**, the
DEV button or F6.

## Buttons

### Economy
| Button | Command | Effect |
|---|---|---|
| +$1k / +$10k | `GrantCash {amount}` | `PlayerDataService.AddCash` (1..1,000,000) |
| +100 Rep / +1000 Rep | `GrantRep {amount}` | `PlayerDataService.AddReputation` (1..100,000) |
| Unlock all | `UnlockAll` | every vehicle owned, every upgrade at its (single) max level, every non-`paidOnly` cosmetic owned, reputation raised to at least 2000, cash to at least 50,000; the spawned vehicle's `Capacity` attribute is refreshed |
| Skip tutorial | `SkipTutorial` | `TutorialService.Complete(player)`: the normal step-9 path (completion bonus, generator on, `TutorialUpdated`), then outstanding tutorial orders are cancelled silently |
| Reset profile (tap twice) | `ResetProfile` | in-session reset to `PlayerDataService.DEFAULT_PROFILE` (schemaVersion kept): all orders cancelled silently without penalty, vehicle despawned, depot plot released, uniform re-applied, `TutorialService.Restart(player)` re-runs the profile-load path (step 0); `ProfileUpdated` / `OrdersUpdated` / `TutorialUpdated` / `DepotUpdated` are pushed. The DataStore is only touched by the normal autosave of the reset profile. |

### Vehicles
| Button | Command | Effect |
|---|---|---|
| Bicycle / Scooter / Van (Own + spawn) | `OwnVehicle {vehicleId}` | grants ownership and equips at no cost, then `VehicleService.Spawn` |
| Despawn | `Despawn` | `VehicleService.Despawn` |
| Recover | `Recover` | `VehicleService.Recover` (its 3 s cooldown still applies) |

### Teleport
The list is filled from `ListTargets` (hub, the 4 businesses by name, the 18 destinations by
address, depot plots) and can be refreshed. Each button sends `Teleport {target}` where `target`
is `hub`, `business:<id>`, `destination:<id>`, `plot:<id>` or `node:<index>` (graph node; not
listed, usable from a script). Positions come from `ctx.world` (arrival positions, plot origin,
hub spawn) or `ctx.graph`.

- **Driving:** the vehicle moves with you through `VehicleService.TeleportTo(player, cframe)`
  (same placement as Recover: chassis at `rideHeight` on the nearest road the vehicle may use,
  velocity zeroed, `Align` synced, `lastSafePosition` updated) and
  `AntiCheatService.NotePlausibleTeleport(player, 3, position)` is called so the jump is never a
  strike.
- **On foot:** the character is pivoted 3 studs above the point facing the door / counter, with
  the same anti-cheat note. A parked vehicle stays where it was.

### Events
| Button | Command | Effect |
|---|---|---|
| Open Lunch Rush: Downtown / Residential / Industrial | `OpenLunchRush {neighborhood}` | `ContractService.ForceOpen(neighborhood)`; any running rush is ended first |
| Finish driver assignments | `FinishDrivers` | every active assignment's `endsAt` is set to `os.time() - 1`, then `DriverService.Tick()` completes them (pending cash, van back, `DepotUpdated`) |
| Fill order board | `FillBoard` | `OrderService.RunGeneration(player)`; during the tutorial the generator is disabled and the toast says so |
| Ready my orders | `ReadyOrders` | every Accepted order gets `readyAt = now`, then `OrderService.RunTick()` flips them to ReadyForPickup |

`ExpireContract` exists as a command but `ContractService` exposes no end-now API, so it returns
`Unavailable` and the panel does not show a button for it (open a new rush instead, which ends the
current one).

### Handling (live tuning)
Tabs pick the vehicle (the spawned vehicle's tab is selected automatically; default Bicycle).
Each row is `[-] key value [+]` with a text box for direct entry. Steps: maxSpeed 2, reverseSpeed
1, acceleration 2, brakeDeceleration 2, coastDeceleration 1, turnRate 0.1, turnFullSpeed 1,
minTurnFactor 0.05, highSpeedTurnFactor 0.05, steerResponse 1, rideHeight 0.1, verticalGain 1,
maxClimbRate 5, leanAngle 1, wheelSteerAngle 2, cameraDistance 1, cameraHeight 0.5,
cameraLookAhead 1, fovSpeedBoost 1, maxSlopeDegrees 2. Overridden keys are marked with `*`.

Values go through `src/client/HandlingOverrides.luau` (`set(vehicleId, key, value)`), a
client-side, session-only layer: `HandlingOverrides.get(vehicleId)` returns the definition's own
handling table when nothing is overridden (identical behaviour to the shipped game) and a merged
copy otherwise. `VehicleController` reads its handling through it and swaps the table on
`HandlingOverrides.Changed` while active, so acceleration, turn rates, ride height, lean etc.
change on the next frame; `CameraController` reads `cameraDistance` / `cameraHeight` /
`cameraLookAhead` / `fovSpeedBoost` the same way.

- **Reset to defaults** drops the vehicle's overrides (and clears the server speed cap).
- **Print snippet** prints `HandlingOverrides.snippet(vehicleId)` to the Output: the FULL merged
  `handling = { ... },` block (overridden keys carry `-- was <old>`), ready to paste over the
  `handling` table of that vehicle in `src/shared/Definitions/VehicleDefinitions.luau`. A toast
  confirms "Snippet printed to Output".

**SetSpeedCap note.** The server's anti-cheat allows
`(maxSpeed * speedTolerance + speedSlack) * elapsed` studs per sample using the *definition's*
`maxSpeed`. Raising `maxSpeed` in the panel therefore also sends
`SetSpeedCap {vehicleId, maxSpeed}`, which calls the additive
`AntiCheatService.SetSpeedOverride(player, vehicleId, maxSpeed)`: the allowance then uses
`math.max(definition maxSpeed, override)` for that player and vehicle, so tuning above the shipped
top speed is not flagged. Lowering `maxSpeed` back to or below the definition clears the override
(`maxSpeed = 0`), as does Reset. Overrides are session state and vanish on `PlayerRemoving`.

### Report
**Print report to Output** invokes `Report` and prints a readable summary (cash, reputation,
deliveries, tutorial step, vehicle state/id, active orders with business and destination,
contract status/neighbourhood, depot owned/plot/pending, anti-cheat strikes) plus a short toast.

## The tuning loop

1. Press Play, open the panel (F6), **Own + spawn** the vehicle you want to tune and mount it.
2. Drive. Step `acceleration`, `turnRate`, `rideHeight`, `cameraDistance`... while driving; every
   change applies on the next frame. For a higher `maxSpeed` the speed cap is raised for you.
3. When it feels right, press **Print snippet**, open the Output window, copy the
   `handling = { ... },` block and paste it over the vehicle's `handling` table in
   `src/shared/Definitions/VehicleDefinitions.luau` (Rojo syncs it on save).
4. `bash tests/run.sh` still passes (the handling specs read the definitions), then commit.

## Scripting it

From the command bar on the client side (Play mode, "Current: Client"):

```lua
local r = game.ReplicatedStorage.Remotes.DevCommand
print(r:InvokeServer("Teleport", { target = "destination:D01" }))
print(r:InvokeServer("Report"))
```

Every command returns the usual `{ ok = true, ... }` / `{ ok = false, error = Code, message = text }`
table. Commands: `GrantCash`, `GrantRep`, `UnlockAll`, `SkipTutorial`, `ResetProfile`,
`OwnVehicle`, `Despawn`, `Recover`, `ListTargets`, `Teleport`, `OpenLunchRush`, `ExpireContract`,
`FinishDrivers`, `FillBoard`, `ReadyOrders`, `SetSpeedCap`, `Report`.
