# Delivery Dash City — Architecture Contract

This document is the binding contract between modules. Every module must match the names, signatures, data shapes and conventions below. If you need to deviate, update this document in the same change.

## 0. Conventions

- Language: Luau, `--!strict` where practical, otherwise `--!nonstrict`. Files use the `.luau` extension. Rojo maps `src/` to the DataModel (see `default.project.json`).
- Server code lives in `ServerScriptService.DeliveryDash` (ModuleScripts + `ServerBootstrap.server.luau`).
- Client code lives in `StarterPlayer.StarterPlayerScripts.DeliveryDashClient` (ModuleScripts + `ClientBootstrap.client.luau`).
- Shared code lives in `ReplicatedStorage.Shared`.
- Modules are required by instance path (`require(ReplicatedStorage.Shared.Types)`), **never** by string. Capture all references at the top of the module (`local Shared = ReplicatedStorage:WaitForChild("Shared")`) so the offline harness can inject `script`.
- Services and controllers expose `Init(ctx)` (synchronous wiring, no yielding, no remote calls) and `Start()` (loops, connections). Bootstrap calls every `Init` first, then every `Start`, in the order listed in sections 6 and 7.
- **No service requires another service.** Cross-service access only via `ctx.services.<Name>` inside `Init`/`Start`/methods. This avoids require cycles and lets tests inject mocks.
- Numbers in world space are studs. Time uses `os.clock()` for durations and `os.time()` for persisted timestamps. Clients receive `serverTime = os.clock()` alongside payloads with absolute clock fields and compute offsets.
- Remote responses are tables: `{ ok = true, ... }` or `{ ok = false, error = "<ErrorCode>", message = "<human text>" }`. Error codes are PascalCase strings (`NotFound`, `WrongState`, `TooFar`, `NoCapacity`, `NotOwner`, `Insufficient`, `Locked`, `RateLimited`, `Invalid`, `Cooldown`, `AlreadyOwned`, `Requirements`, `PositionCheck`).
- All client input to the server is validated: type, size, ownership, state, distance, funds, cooldowns, duplicates. The client never sends payouts, positions used for rewards, or timestamps used for rewards.
- Attributes used across the client/server boundary are listed in section 9.
- CollectionService tags used: `DeliveryVehicle`, `Package`, `PickupZone`, `DeliveryZone`, `DepotPlot`, `CityNPC`, `DoorPart`, `VehiclePad`.

## 1. Explorer hierarchy (as built by Rojo + runtime builders)

```
ReplicatedStorage
  Shared
    Types                       (ModuleScript) exported types only
    InputActions                (ModuleScript) action names + default bindings per device
    Config
      EconomyConfig             (ModuleScript)
      MonetizationConfig        (ModuleScript) product IDs (nil = disabled)
      AudioConfig               (ModuleScript) sound ids ("" = silent)
      MeshAssets                (ModuleScript) imported vehicle mesh / texture asset ids (0 = not configured)
    Definitions
      VehicleDefinitions        (ModuleScript) handling + visual specs + masks
      BusinessDefinitions       (ModuleScript) 4 businesses, items, dialogue, delivery profiles
      OrderDefinitions          (ModuleScript) sizes, item categories, package keys, generation rules
      UpgradeDefinitions        (ModuleScript)
      ContractDefinitions       (ModuleScript) Lunch Rush
      DepotDefinitions          (ModuleScript) driver categories, costs
      CosmeticDefinitions       (ModuleScript)
    City
      CityLayout                (ModuleScript) authored city data (pure tables)
      RouteGraph                (ModuleScript) graph build + A* + projection helpers
    Util
      Signal                    (ModuleScript)
      Remotes                   (ModuleScript) names + accessors
      RateLimiter               (ModuleScript)
      TableUtil                 (ModuleScript) deepCopy, merge, reconcile, count
      Maid                      (ModuleScript)
      MathUtil                  (ModuleScript) lerp, damp, clamp, angle helpers
  Remotes                       (Folder) RemoteFunctions/RemoteEvents created by server at startup
  SharedAssets                  (Folder)
    VehicleDisplays             (Folder, server-created at VehicleService.Start) one cosmetic display Model per vehicle that uses a mesh (section 12)

ServerScriptService
  DeliveryDash
    ServerBootstrap             (Script)
    Services
      PlayerDataService, ProgressionService, CityService, VehicleService, OrderService,
      RewardService, ShopService, InteractionService, TutorialService, ContractService,
      DepotService, DriverService, AntiCheatService
    Builders
      CityBuilder, VehicleBuilder, PackageBuilder, NPCBuilder, DepotBuilder

ServerStorage
  VehicleTemplates, PackageTemplates, NPCTemplates, DepotTemplates   (Folders; builders fill them at startup)

StarterPlayer.StarterPlayerScripts
  DeliveryDashClient
    ClientBootstrap             (LocalScript)
    ClientState                 (ModuleScript) reactive store shared by controllers
    Controllers
      SettingsController, InputController, VehicleController, CameraController,
      NavigationController, InteractionController, UIController, AudioController,
      EffectsController, CityLifeController, TutorialController, CosmeticsController
    UI
      UIKit, HUD, OrderBoard, ActiveDeliveries, ShopMenu, UpgradeMenu, DepotMenu,
      ResultsToast, SettingsMenu, TutorialBanner, Notifications, Minimap

Workspace
  City                          (built by CityBuilder: Roads, Sidewalks, Buildings, Props, Landmarks, Water)
  PickupLocations               (one Model per business: Storefront, Counter, PickupPad, Sign, Attributes)
  DeliveryDestinations          (one Model per destination: Door, ArrivalPad, AddressSign)
  DepotPlots                    (one Model per plot: Ground, Sign, Parking, Attributes OwnerUserId)
  Runtime
    Vehicles                    (spawned vehicle models)
    Packages                    (unused when packages are welded; kept for pooling)
    NPCs                        (server-side NPCs: depot drivers)
```

Client-only runtime instances go under `workspace.CurrentCamera` (`ClientFX` folder) or `PlayerGui`.

## 2. Shared types (`Shared/Types.luau`)

See the file; the canonical shapes are reproduced here.

```lua
export type VehicleId = "Bicycle" | "Scooter" | "Van"
export type NeighborhoodId = "Downtown" | "Residential" | "Industrial"
export type ItemCategory = "Food" | "Pizza" | "Drinks" | "Grocery" | "Parcel"
export type SizeClass = "Small" | "Medium" | "Large"     -- 1 / 2 / 4 units
export type PackageKey = "FoodBag" | "PizzaBox" | "DrinkCarrier" | "GroceryBag" | "Parcel"
export type OrderState = "Available" | "Accepted" | "ReadyForPickup" | "Collected" | "Delivered" | "Cancelled" | "Expired"
export type VehicleState = "Parked" | "Mounting" | "Driving" | "Dismounting" | "Recovering" | "Despawning"
export type RoadKind = "Road" | "Street" | "Alley" | "BikePath" | "Bridge" | "BikeBridge" | "Industrial" | "Ramp"

export type Order = {
  id: string, userId: number,
  businessId: string, destinationId: string,
  itemCategory: ItemCategory, size: SizeClass, sizeUnits: number, packageKey: PackageKey,
  itemLabel: string,            -- e.g. "2x Margherita"
  basePay: number, tipMax: number, repReward: number,
  timeLimit: number?,           -- seconds after acceptance for full tip (nil = untimed)
  availableUntil: number,       -- os.clock(); when the order leaves the board (Available only)
  prepTime: number,             -- seconds after acceptance until ReadyForPickup
  routeDistance: number,        -- studs along the bicycle graph
  createdAt: number, acceptedAt: number?, readyAt: number?, collectedAt: number?, deliveredAt: number?,
  state: OrderState,
  contractId: string?, isTutorial: boolean?,
  rewardGranted: boolean?,      -- idempotency flag
}

export type Payout = { base: number, tip: number, total: number, rep: number, lateSeconds: number, timelinessFactor: number, newRecord: boolean? }

export type DriverAssignment = { id: string, category: string, startedAt: number, endsAt: number, revenue: number, cost: number, net: number, completed: boolean }
export type DriverSlot = { hired: boolean, name: string?, assignment: DriverAssignment?, pending: number }  -- pending = uncollected net cash

export type Profile = {
  schemaVersion: number,
  cash: number, reputation: number,
  ownedVehicles: {[string]: boolean}, equippedVehicle: VehicleId,
  upgrades: {[string]: number},
  depot: { owned: boolean, slotsUnlocked: number, drivers: {DriverSlot} },
  cosmetics: { owned: {[string]: boolean}, equipped: {[string]: string} },   -- equipped[slot] = cosmeticId
  tutorial: { completed: boolean, step: number },
  stats: { deliveries: number, totalEarned: number, bestTimes: {[string]: number}, distance: number, contractsCompleted: number, lateDeliveries: number },
  settings: { cameraSensitivity: number, reducedMotion: boolean, autoRecenter: boolean, musicVolume: number, sfxVolume: number, showMinimap: boolean, invertCameraY: boolean },
  lastSeen: number,
}
```

`PublicProfile` sent to the client = the whole Profile (nothing secret) minus `lastSeen`.

### Vehicle masks (`VehicleDefinitions.Mask`)
`Bicycle = 1`, `Scooter = 2`, `Van = 4`, `Foot = 7` (on foot may use any edge for guidance). Road kinds map to allowed masks: Road/Street/Bridge/Industrial/Ramp = 7; Street = 3 (bike + scooter); Alley/BikePath/BikeBridge = 1.

## 3. Remote contract (`Shared/Util/Remotes.luau`)

The server calls `Remotes.createAll()` at startup; clients call `Remotes.getFunction(name)` / `Remotes.getEvent(name)` which `WaitForChild`. All RemoteFunctions are invoked **client → server**. All RemoteEvents below are fired **server → client** unless noted.

| RemoteFunction | Args | Returns (`ok=true` fields) |
|---|---|---|
| `GetSnapshot` | – | `profile`, `orders = {available, active}`, `vehicle = {state, vehicleId}`, `contract`, `depot`, `tutorial = {completed, step}`, `serverTime` |
| `AcceptOrder` | `orderId: string` | `order` |
| `CancelOrder` | `orderId: string` | – |
| `RequestPickup` | `orderId: string` | `order` (state ReadyForPickup→Collected) or error `NotReady` with `secondsLeft` |
| `RequestDelivery` | `orderId: string` | `payout: Payout`, `order` |
| `SpawnVehicle` | `vehicleId: string` | `vehicleId` |
| `DespawnVehicle` | – | – |
| `MountVehicle` | – | – |
| `DismountVehicle` | – | – |
| `RecoverVehicle` | – | – |
| `PurchaseVehicle` | `vehicleId` | `profile` |
| `EquipVehicle` | `vehicleId` | `profile` |
| `PurchaseUpgrade` | `upgradeId` | `profile` |
| `PurchaseCosmetic` | `cosmeticId` | `profile` |
| `EquipCosmetic` | `cosmeticId` | `profile` |
| `PurchaseDepot` | – | `depot` |
| `UnlockDriverSlot` | – | `depot` |
| `HireDriver` | `slot: number` | `depot` |
| `AssignDriver` | `slot: number, category: string` | `depot` |
| `CollectDepotEarnings` | – | `collected: number`, `depot` |
| `JoinContract` | `contractId: string, orderIds: {string}` | `orders` |
| `AdvanceTutorial` | `step: number` (the step the client finished showing) | `step` |
| `SaveSettings` | `settings: table` (validated field by field) | `settings` |

| RemoteEvent (server→client) | Payload |
|---|---|
| `ProfileUpdated` | `profile: PublicProfile` (full snapshot; small enough) |
| `OrdersUpdated` | `{ available: {Order}, active: {Order}, serverTime: number, capacity: {current: number, max: number, load: number, committed: number} }` |
| `OrderEvent` | `{ kind: "Accepted"|"Ready"|"Collected"|"Delivered"|"Cancelled"|"Expired"|"Late", orderId: string, order: Order?, payout: Payout? }` |
| `VehicleStateChanged` | `{ state: VehicleState, vehicleId: string?, model: Model? }` |
| `ContractUpdated` | `ContractPublicState` (section 5.6) |
| `DepotUpdated` | `DepotPublicState` (section 5.7) |
| `Notify` | `{ text: string, kind: "info"|"success"|"warning"|"error", duration: number? }` |
| `TutorialUpdated` | `{ step: number, completed: boolean }` |
| `WorldEvent` | `{ kind: "DoorReaction", destinationId, line } | { kind: "PickupReaction", businessId, line } | { kind: "DriverDepart"|"DriverReturn", plotId, slot }` |

Client→server RemoteEvent: `ClientHeartbeat` `{ vehicleSpeed: number }` at most 1/s (telemetry only; never used for rewards).

Rate limits (InteractionService): 8 calls/s per player per function burst 12; `RequestPickup`/`RequestDelivery` additionally 1 per 0.3 s per order.

## 4. Data schema and persistence rules

- DataStore name `DDC_Profiles_v1`, key `u_<UserId>`. `schemaVersion = 1`. Default profile in `PlayerDataService.DEFAULT_PROFILE` (deep-copied, reconciled on load so new fields get defaults).
- Load: up to 4 attempts with backoff 1, 2, 4 s. On total failure: profile = defaults, `profile.__loadFailed = true` (transient, not saved), player is told "Progress will not save this session", **nothing is ever written** for that session.
- Session lock: `UpdateAsync` writes `lock = { jobId, t = os.time() }`. If a lock from another jobId younger than 120 s exists, retry 3× over 6 s, then load read-only (`__loadFailed = true`). Lock released (set nil) on save-on-leave.
- Save: `UpdateAsync` only (never SetAsync), only when `dirty`, autosave every 120 s, on leave, and in `BindToClose` (waits for all pending saves up to 25 s, including leave-saves and lock releases already in flight for players who left). Retries 3× with backoff. A save never writes a profile whose `schemaVersion` is less than the stored one.
- Active orders are **not** persisted. On disconnect they are cancelled without penalty. On respawn they survive (packages re-attach).
- Driver assignments persist with `os.time()` stamps. On load, assignments whose `endsAt` has passed complete into `pending` once (idempotent by `assignment.completed`). No new assignments start offline.

## 5. Service APIs (server)

Every service: `Service.Init(ctx: ServerContext)` and `Service.Start()`.

```lua
export type ServerContext = {
  services: { [string]: any },          -- all services by name, e.g. ctx.services.OrderService
  remotes: typeof(Remotes),             -- Shared.Util.Remotes
  layout: typeof(CityLayout),           -- Shared.City.CityLayout
  graph: RouteGraph.Graph,              -- built once by CityService.Init
  world: {                              -- filled by CityService.Init (CityBuilder output)
    cityFolder: Folder, pickupFolder: Folder, destinationFolder: Folder, depotFolder: Folder, runtime: Folder,
    businesses: { [string]: BusinessWorld },        -- { model, pickupPosition: Vector3, arrivalPosition: Vector3, doorPart: BasePart? }
    destinations: { [string]: DestinationWorld },   -- { model, doorPosition: Vector3, arrivalPosition: Vector3, doorPart: BasePart, facing: Vector3 }
    depotPlots: { [string]: DepotPlotWorld },       -- { model, origin: CFrame, parking: {CFrame}, signPart: BasePart }
    hubSpawn: CFrame, vehiclePads: {CFrame},
  },
  isStudio: boolean,
}
```

### 5.1 PlayerDataService
- `GetProfile(player): Profile?` — nil until loaded.
- `WaitForProfile(player, timeout: number?): Profile?`
- `IsSaveable(player): boolean`
- `Update(player, mutator: (Profile) -> ()): boolean` — runs mutator, marks dirty, replicates `ProfileUpdated`. Returns false if no profile.
- `AddCash(player, amount: number, reason: string): boolean` (amount ≥ 0, rounded to integer)
- `TrySpendCash(player, amount: number, reason: string): boolean` (atomic check-and-deduct)
- `AddReputation(player, amount: number, reason: string): boolean`
- `GetPublicProfile(player): table?`
- Signals: `ProfileLoaded: Signal<Player, Profile>`, `ProfileUnloading: Signal<Player, Profile>`.
- Leaderstats: `Cash`, `Deliveries`, `Rep` (IntValues) mirrored on `Update`.

### 5.2 ProgressionService (pure functions over Profile)
- `GetUnlockedBusinesses(profile): {string}`; `IsBusinessUnlocked(profile, businessId): boolean`
- `IsMultiOrderUnlocked(profile): boolean` (tutorial complete and `stats.deliveries >= EconomyConfig.multiOrderUnlockDeliveries`)
- `GetUpgradeLevel(profile, upgradeId): number`
- `GetCapacityForVehicle(profile, vehicleId: string?): number` — nil vehicle = on foot (1)
- `GetMaxCapacity(profile): number` — best over owned vehicles
- `GetSpeedMultiplier(profile, vehicleId): number`
- `GetTipMultiplier(profile): number`
- `CanPurchaseVehicle(profile, vehicleId): (boolean, string?)`; `CanPurchaseUpgrade(profile, upgradeId): (boolean, string?)`; `CanPurchaseCosmetic`
- `IsContractUnlocked(profile, contractId): (boolean, string?)`; `GetUnlockedDriverCategories(profile): {string}`; `CanPurchaseDepot(profile): (boolean, string?)`
- `ApplyMilestones(profile): number` returns rep granted for newly reached delivery milestones.

### 5.3 CityService
- `Init`: builds the city via `CityBuilder.build(layout)` into the Workspace folders, builds `ctx.graph = RouteGraph.build(layout)`, fills `ctx.world`.
- `GetNearestRoadPoint(position: Vector3, mask: number): (Vector3, number)` — point on nearest allowed edge and distance.
- `GetSafeRespawnCFrame(position: Vector3, mask: number, raise: number?): CFrame` — nearest road point raised by `raise` studs (default `CityService.RESPAWN_HEIGHT` = 3), facing along the edge. VehicleService passes `handling.rideHeight` so a parked chassis sits on the asphalt.
- `GetHubSpawn(): CFrame`; `GetFreeVehiclePad(): CFrame`.

### 5.4 VehicleService
- `Spawn(player, vehicleId): Result` — requires ownership; despawns the current vehicle first; spawns near the player's nearest road point (within 80 studs) else at a hub pad. Sets model attributes, `ModelStreamingMode = PersistentPerPlayer` + `AddPersistentPlayer`, collision groups, network owner nil, chassis anchored, state `Parked`.
- `Despawn(player): Result`
- `Mount(player): Result` — requires own vehicle, state `Parked`, character alive, distance ≤ `EconomyConfig.mountDistance` (14). Sequence: state `Mounting` → unanchor → `seat:Sit(humanoid)` (verified; retries once by toggling `Disabled`) → `SetNetworkOwner(player)` → state `Driving`. Re-attaches package visuals to the vehicle.
- `Dismount(player): Result` — state `Driving` → `Dismounting` → unseat (`humanoid.Sit=false`, `Jump=true`, seat weld destroyed if still present) → character moved to `DismountAttachment` world position → vehicle snapped to ground/upright, `VectorVelocity = 0`, anchored, network owner nil → state `Parked`. Re-attaches package visuals to the character.
- `Recover(player): Result` — allowed in `Driving` or `Parked`; cooldown 3 s; moves vehicle (and rider if driving) to `CityService.GetSafeRespawnCFrame(lastSafePosition, mask, rideHeight)`. Calls `AntiCheatService.NotePlausibleTeleport(player, 3, position)` only when the rider was moved (Driving); a Parked recover moves the vehicle alone. `Spawn` never notes a teleport (the character does not move).
- `GetVehicle(player): VehicleRecord?`; `GetState(player): VehicleState?`; `IsDriving(player): boolean`
- `GetCurrentVehicleId(player): string?` — the spawned vehicle, regardless of mounted.
- `GetPlayerPosition(player): Vector3?` — chassis position if driving else HumanoidRootPart.
- `GetVehicleMask(player): number` — mask of the spawned vehicle if driving, else `Mask.Foot`.
- Signals: `StateChanged(player, state, record?)`, `Mounted(player, record)`, `Dismounted(player, record)`, `Despawned(player)`.
- Handles: `CharacterAdded` (re-spawn vehicle Parked at hub if it was lost; character placed at hub), `Humanoid.Died` (dismount + park at place), `PlayerRemoving` (despawn), server watchdog every 2 s: unauthorized occupant ejected; vehicle below `layout.killY` auto-recovered; `lastSafePosition` updated while inside bounds and above ground.

`VehicleRecord = { model: Model, chassis: BasePart, seat: VehicleSeat, bodyRoot: BasePart, vehicleId: string, state: VehicleState, ownerUserId: number, lastSafePosition: Vector3, cargoAttachment: Attachment, spawnedAt: number, lastRecoverAt: number }`

### 5.5 OrderService
- `GetAvailable(player): {Order}`; `GetActive(player): {Order}` (Accepted/ReadyForPickup/Collected); `GetOrder(orderId): Order?`
- `GetCapacityInfo(player): { current: number, max: number, load: number, committed: number }` — `load` = units of Collected orders; `committed` = units of all active orders; `current` = capacity of the spawned vehicle (or 1 on foot); `max` = `ProgressionService.GetMaxCapacity`.
- `Accept(player, orderId, opts?): Result` — order must be Available and belong to the player; if multi-order is locked, no other active order may exist; `committed + sizeUnits <= max`. An order with `contractId` is refused with `Locked` unless `opts = { viaContract = true }` (only `ContractService.Join` passes it; the `AcceptOrder` remote never does).
- `Cancel(player, orderId): Result` — any active state; Collected orders lose −2 rep (floored 0); package visuals removed; markers cleared via `OrdersUpdated`.
- `RequestPickup(player, orderId): Result` — state must be `ReadyForPickup` (if `Accepted` and `os.clock() < readyAt`, error `NotReady` with `secondsLeft`); distance from `VehicleService.GetPlayerPosition` to `world.businesses[id].pickupPosition` ≤ `EconomyConfig.pickupDistance` (18); `load + sizeUnits <= current capacity`; `AntiCheatService.CheckPosition(player)` ok. Transition → `Collected`, spawn package visual (`PackageBuilder.attach`).
- `RequestDelivery(player, orderId): Result` — state `Collected`; distance to `world.destinations[id].doorPosition` ≤ `EconomyConfig.deliveryDistance` (16) **or** to `arrivalPosition` ≤ 20; position check ok. Transition → `Delivered` and `RewardService.GrantDeliveryPayout` inside the same function before yielding; `rewardGranted` guards duplicates. Fires `OrderEvent Delivered` with payout and `WorldEvent DoorReaction`.
- `InjectOrders(player, orders: {Order})` — contract/tutorial orders appended to the player's Available list.
- `CreateOrder(player, spec: OrderSpec): Order` where `OrderSpec = { businessId, destinationId, size: SizeClass?, itemCategory?, contractId?, isTutorial?, timeLimit?, basePayOverride?, prepTimeOverride? }`. Uses `RouteGraph` distance (bicycle mask) and `EconomyConfig` to price.
- Generation loop (every 5 s per player): keep `EconomyConfig.boardMin` (3) to `boardMax` (6) Available orders drawn from unlocked businesses, only sizes the player's `max` capacity can take, destinations filtered by the business delivery profile; tutorial players get only the scripted tutorial orders. Available orders expire `EconomyConfig.boardLifetime` (150 s) after creation → state `Expired`, removed. **Accepted orders never expire**; a late delivery still pays base pay. Contract orders left uncollected when the contract window closes are `Cancelled` (no penalty).
- `Accepted → ReadyForPickup` at `readyAt = acceptedAt + prepTime` (tick loop 1 s; also checked lazily in `RequestPickup`).
- Signals: `OrderAccepted(player, order)`, `OrderReady(player, order)`, `OrderCollected(player, order)`, `OrderDelivered(player, order, payout)`, `OrderRemoved(player, order, reason)`.
- On `PlayerRemoving`: all orders cancelled silently. On character respawn: nothing changes; `PackageBuilder` re-attaches visuals for Collected orders.

### 5.6 ContractService (Neighborhood Lunch Rush)
- Global cycle: every `ContractDefinitions.LunchRush.cooldown` (480 s) a rush opens for a rotating neighbourhood for `window` (240 s) + `grace` (180 s) for joined batches. `ContractPublicState = { id: string?, neighborhood: NeighborhoodId?, opensAt, closesAt, graceEndsAt, status: "Idle"|"Open"|"Grace", nextAt: number, offers: {Order}?, joined: {orderIds: {string}, deadline: number, required: number, done: number}? }` (offers/joined are per-player; the service sends personalised `ContractUpdated`).
- When Open, each eligible player (`ProgressionService.IsContractUnlocked`) gets `offerCount` (5) compatible Small/Medium orders from businesses in that neighbourhood (created with `OrderService.CreateOrder` with `contractId`, `timeLimit = closesAt + grace - now`), shown in the board's Contract tab, **not** in the normal list, and not auto-accepted.
- `Join(player, contractId, orderIds): Result` — 2–4 of the offered ids, total units ≤ `max` capacity, not already joined; the orders become Accepted at once. Failure to meet capacity returns `NoCapacity`.
- Completion: when all joined orders are Delivered before `deadline`, `RewardService.GrantContractBonus` (40% of batch base + flat bonus + 50 rep), `stats.contractsCompleted += 1`. If the deadline passes: remaining uncollected orders Cancelled, collected ones stay deliverable (base pay only).

### 5.7 DepotService + DriverService
- `DepotPublicState = { owned: boolean, plotId: string?, slotsUnlocked: number, drivers: {DriverSlot}, pendingTotal: number, categories: { {id, name, unlocked: boolean, duration, revenue, cost, net, requirement: string?} }, serverTime: number }`
- Plot assignment is per session: on profile load, if `depot.owned`, claim the first free plot (`DepotPlots` models, attribute `OwnerUserId`), build the depot visuals via `DepotBuilder.apply(plot, profile)`. On leave, release the plot.
- `Purchase(player)`: requirements via `ProgressionService.CanPurchaseDepot`, spend, `depot.owned = true`, slots 1, drivers `{ {hired=false, pending=0}, {hired=false, pending=0} }`, claim plot.
- `UnlockSlot(player)`: slotsUnlocked 1 → 2 for `DepotDefinitions.slot2Cost`.
- `HireDriver(player, slot)`: slot ≤ slotsUnlocked, not hired, spend `hireCost`, assign a name from `DepotDefinitions.driverNames`.
- `AssignDriver(player, slot, category)`: driver hired, idle (no assignment or completed-and-collected), category unlocked, spend `cost` up front, create assignment `{ id = GUID, startedAt = os.time(), endsAt = startedAt + duration, revenue, cost, net = revenue - cost, completed = false }`. Fires `WorldEvent DriverDepart`.
- `DriverService.Tick()` every 5 s: for each online owner, each assignment with `endsAt <= os.time()` and not completed → `completed = true`, `slot.pending += revenue` (cost already paid), `WorldEvent DriverReturn`, `DepotUpdated`.
- `Collect(player)`: player within `EconomyConfig.depotInteractDistance` (30) of own plot sign; sums `pending` over slots, sets each to 0 **before** `AddCash` (exactly-once), clears completed assignments.
- Reassignment: assigning a driver whose assignment is completed but uncollected moves its `pending` into `pending` (nothing lost), clears the assignment, starts the new one.

### 5.8 ShopService
- `PurchaseVehicle`, `EquipVehicle` (respawns the vehicle Parked beside the player if one was spawned), `PurchaseUpgrade`, `PurchaseCosmetic`, `EquipCosmetic` (re-applies cosmetics to the spawned vehicle / character via `VehicleBuilder.applyCosmetics` and `CosmeticDefinitions`; `DepotSign`/`DepotDecor` slots call `DepotService.RefreshVisuals(player)` so the plot rebuilds at once).

### 5.9 InteractionService
- Creates all remotes, binds every RemoteFunction to the right service with: rate limiting (`RateLimiter`), argument type checks (string ids ≤ 64 chars, numbers finite, tables ≤ 32 entries), profile-loaded check, `pcall` wrapping with generic `Internal` error on failure (logged with `warn`).
- Sends `Notify` for user-facing results where the client would not otherwise know.

### 5.10 AntiCheatService
- Samples each player's position (via `VehicleService.GetPlayerPosition`) every 1 s. Allowed distance since the last sample = `(maxSpeedOfCurrentVehicle * EconomyConfig.speedTolerance (1.8) + 24) * elapsed`. On violation: `strikes += 1`, `flaggedUntil = os.clock() + 4`; sample updated.
- `NotePlausibleTeleport(player, seconds, newPosition: Vector3?)` — called only when the **server** moves the character (dismount, recover while driving, respawn), never for vehicle spawn or client-reported movement; suppresses checks for that window and records `newPosition` (default: the current server-side position) as the reference point, so the first sample after the window still compares against where the server put the player.
- `CheckPosition(player): boolean` — false while `flaggedUntil > os.clock()`.

### 5.11 TutorialService
- Steps (numbers are the contract): 0 Welcome, 1 AcceptFirstOrder, 2 MountBike, 3 RideToPickup, 4 CollectOrder, 5 DeliverOrder, 6 Paid, 7 SecondOrder (route choice), 8 BuyUpgrade, 9 Done (`completed = true`).
- The service listens to Order/Vehicle signals to advance server-side steps 1–7; the client calls `AdvanceTutorial(step)` only for dismissable steps (0, 6, 8, 9). Walking the first order is allowed: the pickup-proximity poll runs at steps 2 and 3 (→ 4) and `OrderCollected` advances from steps 2–4 (→ 5), so a player who never mounts is not stuck on "Get on your bike". Tutorial orders are created with `isTutorial = true`, `basePayOverride` (45, 50), `prepTimeOverride = 0`, `timeLimit = nil`. While `tutorial.completed == false` the normal generator produces nothing; after step 8 the generator runs normally.
- Rewards: step 9 grants `EconomyConfig.tutorialCompletionBonus` (25 rep).

### 5.12 RewardService
- `ComputePayout(order, profile, now): Payout` — `tip = tipMax * tipMultiplier(profile) * timeliness`, timeliness = 1 inside `timeLimit`, linear to 0 at 2× (untimed = 1). Rounds to integers.
- `GrantDeliveryPayout(player, order): Payout?` — returns nil if `order.rewardGranted`; sets the flag first, then `AddCash`, `AddReputation`, stats (deliveries, totalEarned, bestTimes by `businessId .. ">" .. destinationId`, lateDeliveries), `ApplyMilestones`.
- `GrantContractBonus(player, contractId, orders): number`.

## 6. Server bootstrap order
`PlayerDataService, ProgressionService, CityService, AntiCheatService, VehicleService, RewardService, OrderService, TutorialService, ShopService, ContractService, DriverService, DepotService, InteractionService` — Init all in this order, then Start all in this order.

## 7. Client architecture

`ClientState` (`Controllers` require it): fields `profile`, `orders` (`{available, active, capacity}`), `vehicle` (`{state, vehicleId, model}`), `contract`, `depot`, `tutorial`, `serverTimeOffset`, `stopOrder: {string}` (client-side preferred order of active order ids), `settings`. `ClientState.Changed: Signal<key, value>`; `ClientState.set(key, value)`; `ClientState.get(key)`; `ClientState.serverNow(): number`.

Controllers (`Init(ctx)` / `Start()`, `ctx = { state = ClientState, remotes = Remotes, layout = CityLayout, graph = RouteGraph.Graph, controllers = {...} }`), started in order: `SettingsController, UIController, InputController, CameraController, VehicleController, NavigationController, InteractionController, AudioController, EffectsController, CityLifeController, CosmeticsController, TutorialController`.

### 7.1 InputController
Actions (`Shared/InputActions.luau`): `Brake`, `Interact`, `MountDismount`, `Recover`, `RecenterCamera`, `ToggleOrders`, `ToggleMenu`, `NextStop`. Bound through `ContextActionService` with touch buttons (`SetTitle`, positioned in the safe area) and gamepad buttons: Brake = Space / ButtonL2 / touch; Interact = E / ButtonX / touch; MountDismount = F / ButtonY / touch; Recover = R (hold 1 s) / ButtonSelect / touch (in menu); RecenterCamera = V / ButtonR3; ToggleOrders = Tab / ButtonStart... Throttle/steer come from `VehicleSeat.ThrottleFloat / SteerFloat` (Roblox applies WASD, thumbstick and gamepad left stick automatically). `InputController.GetDriveInput(): (throttle, steer, brake)`; `InputController.Pressed: Signal<actionName>`; `InputController.IsTouch(): boolean`; `InputController.IsGamepad(): boolean`.

### 7.2 VehicleController (owner only, runs on `RunService.Heartbeat` while `vehicle.state == "Driving"`)
Ground-follow arcade model (full description in `docs/VEHICLES.md`): three downward raycasts (front/centre/rear, `RaycastParams` excluding vehicles/characters/packages), ride height from `VehicleDefinitions[id].handling.rideHeight`, `LinearVelocity.VectorVelocity = forward * speed + up * verticalCorrection`, `AlignOrientation.CFrame` from heading and smoothed ground normal, blocked detection, speed-scaled steering, emulated gravity when airborne, `MaxForce = AssemblyMass * 1200`. Cosmetic: wheel `Motor6D.Transform` spin/steer, body lean for two-wheelers, speed FOV via CameraController. Exposes `GetSpeed(): number`, `GetSteer(): number`, `IsGrounded(): boolean`.

### 7.3 CameraController
Scriptable follow camera while driving: pivot behind/above the vehicle (per-vehicle offsets), exponential smoothing (`MathUtil.damp`), look-ahead toward heading + steer, limited FOV 70→78 by speed (disabled by `reducedMotion`), orbit by mouse drag / right stick / touch drag, auto-recenter after 2.5 s idle (setting), recenter action. Default Roblox camera when not driving.

### 7.4 NavigationController
Chooses the current target (next stop from `stopOrder` else nearest active stop: pickup for Accepted/Ready, door for Collected). `RouteGraph.findPath(graph, fromPos, toPos, mask)` where mask = current vehicle mask or Foot. Recomputes when the player is > 24 studs from the path polyline or every 4 s (cheap, bounded A*). Draws pooled neon marker parts along the next 240 studs, a destination billboard (text "PICKUP" / "DELIVER" plus distance, icon shape differs), next-turn text (`← Turn left in 40`), and the Minimap (2D frames). Clears on cancellation.

### 7.5 InteractionController
Every 0.15 s checks the distance from the player's position to the current stop's interaction point (business `pickupPoint` or destination `door`), shows the prompt and on `Interact` calls `RequestPickup` / `RequestDelivery`; also shows mount prompt near own Parked vehicle and depot prompts. All prompts are the same `UIKit` prompt frame with the device-appropriate glyph.

### 7.6 UIController + UI modules
Programmatic UI via `UIKit` (ScreenGui with `IgnoreGuiInset=false`, `ScreenInsets = CoreUISafeInsets`, `UIScale` from viewport, controller selection via `GuiService.SelectedObject`, theme tokens). Screens are modules with `Mount(parent, ctx)` and `Update(state)`.

## 8. World builders (server)

### 8.1 CityLayout schema (`Shared/City/CityLayout.luau`) — pure data, positions as `{x=, y=?, z=}` (never Vector3)
```lua
{
  name, bounds = {minX, maxX, minZ, maxZ}, groundY = 0, killY = -60,
  neighborhoods = { {id, name, center={x,z}, bounds={minX,maxX,minZ,maxZ}, accent = {r,g,b}} },
  roads = { {id, name, kind: RoadKind, width, points = {{x,y?,z}...}, sidewalk: boolean?, oneWay: false} },
  water = { {x, z, w, d, surfaceY, depth} },           -- canal rectangles (terrain water)
  bridges = { {roadId, fromIndex, toIndex} },          -- segments that get railings and deck
  buildings = { {x, z, w, d, h, rot?, style, name?, color?, baseY?} },  -- style: Shop|Apartment|House|Warehouse|Tower|Hub|Office|Cafe|Market|Pizza
  businesses = { {id, buildingIndex?, building = {...}, door={x,z}, facing={x,z}, pickupPoint={x,z}, arrivalPoint={x,z}, neighborhood} },
  destinations = { {id, address, neighborhood, kind, door={x,z}, facing={x,z}, arrivalPoint={x,z}, accepts={Small=,Medium=,Large=}, building = {...}?} },
  landmarks = { plaza={x,z,r}, tower={x,z}, park={x,z,w,d}, waterTower={x,z}, hub={x,z} },
  hub = { spawn={x,z,facing={x,z}}, vehiclePads={{x,z,facing={x,z}}}, kiosk={x,z} },
  depotPlots = { {id, x, z, w, d, facing={x,z}, parking={{x,z,facing={x,z}}}} },
  pedestrianPaths = { {id, points={{x,z}...}, loop=true} },
  parkedVehicles = { {x, z, rot, color={r,g,b}, kind="Car"|"Truck"} },
  props = { {type="Tree"|"Lamp"|"Bench"|"Hydrant"|"Planter"|"Crate"|"Container"|"Dumpster"|"Sign"|"Cone", x, z, rot?} },
  bikeShortcuts = { {roadId, hint} },                  -- used by tutorial/nav hints
}
```
Every business and destination must satisfy `RouteGraph.validate(layout)`: arrival point within 14 studs of an allowed edge, door within 20 studs of the arrival point, ids unique, roads connected (single component for mask Bicycle **and** for mask Van over Road/Industrial/Bridge/Ramp kinds).

### 8.2 RouteGraph (`Shared/City/RouteGraph.luau`)
- `build(layout): Graph` — nodes from road points merged within 1 stud; T-junctions split; `Graph = { nodes: {Node}, edges: {Edge}, adjacency: {[nodeIndex]: {edgeIndex}} }`, `Node = { index, position: Vector3, roadIds: {string} }`, `Edge = { index, a, b, length, mask, kind, roadId, width }`.
- `findPath(graph, from: Vector3, to: Vector3, mask): (path: {Vector3}?, length: number)` — projects both endpoints onto the nearest allowed edge, A* on nodes, returns polyline including the projected endpoints. Bounded (max 4000 expansions).
- `nearestPointOnGraph(graph, pos, mask): (point: Vector3, edge: Edge, t: number, distance: number)`
- `distanceAlongPath(path): number`, `distanceToPolyline(path, pos): (distance, segmentIndex)`
- `turnInstructions(path): {{position, kind: "Left"|"Right"|"Straight"|"SlightLeft"|"SlightRight"|"UTurn", distanceFromStart}}`
- `validate(layout): {string}` — list of problems (empty = valid). Pure Luau, no Instances required beyond `Vector3`.

### 8.3 VehicleBuilder
`VehicleBuilder.build(vehicleId, ownerUserId, cosmetics): Model` with the structure:
```
Model "Vehicle" (Attributes: OwnerUserId, VehicleId, State, Capacity)
  Chassis (PrimaryPart, Part box, Transparency 1, CanCollide true, CollisionGroup "Vehicles", CustomPhysicalProperties(density 0.7, friction 0.3, elasticity 0))
    RootAttachment (Attachment, centre)
    Align (AlignOrientation, Mode OneAttachment, Attachment0=RootAttachment, RigidityEnabled=false, MaxTorque 1e7, Responsiveness 30, MaxAngularVelocity 12)
    Velocity (LinearVelocity, Attachment0=RootAttachment, RelativeTo World, VelocityConstraintMode Vector, VectorVelocity 0, MaxForce 1e6 initially)
    CargoAttachment (Attachment; first package slot; stacking along +Y)
    DismountAttachment (Attachment, left side at ground height)
    EngineSound (Sound, optional per AudioConfig)
  BodyRoot (Part, invisible, Massless, CanCollide false) joined via Motor6D "BodyMotor" (Part0=Chassis, Part1=BodyRoot)
  Seat (VehicleSeat, Disabled=true, MaxSpeed 0, Torque 0, HeadsUpDisplay false, WeldConstraint→BodyRoot)
  Body (Folder) cosmetic Parts, Massless, CanCollide/CanQuery/CanTouch false, WeldConstraint→BodyRoot; Attribute `PaintSlot` ("Primary"|"Accent"|"Decal") where recolourable
  Wheels (Folder) Parts (Cylinder) each with Motor6D "WheelMotor" (Part0=BodyRoot, Part1=Wheel) and Attributes `Steerable: boolean`, `Radius: number`
  Cargo (Folder) packages get parented here
```
`VehicleBuilder.applyCosmetics(model, cosmetics)` recolours `PaintSlot` parts. Visual specs live in `VehicleDefinitions[id].visual` (list of parts `{name, shape, size={x,y,z}, offset={x,y,z}, rot={x,y,z}?, color={r,g,b}|slot, material, transparency?}` and wheels `{name, radius, width, offset, steerable}`), so the builder is generic. When an imported mesh is configured for the vehicle (`Config/MeshAssets`), the `Body` folder holds a single `MeshBody` MeshPart instead and `Wheels` holds only configured wheel meshes; see section 12, "Custom meshes".

### 8.4 PackageBuilder
`PackageBuilder.build(packageKey, styleId?): Model` (Root + cosmetic parts, all Massless non-colliding, tag `Package`, attributes `OrderId`, `PackageKey`). `PackageBuilder.attachToVehicle(model, record, slotIndex)`, `PackageBuilder.attachToCharacter(model, character, slotIndex)`, `PackageBuilder.detach(model)`. Server-side owner: OrderService keeps `packageModels[orderId]`.

### 8.5 NPCBuilder / DepotBuilder
`NPCBuilder.build(kind: "Pedestrian"|"Staff"|"Customer"|"Worker"|"Driver", seed): Model` — simple part-based figure with a `Root` PrimaryPart, no Humanoid (client-side use for pedestrians, server-side for depot drivers). `DepotBuilder.apply(plotWorld, profile, ownerName)` builds/refreshes the owner's depot (sign text, decoration cosmetic, driver NPC + van per hired slot), `DepotBuilder.clear(plotWorld)`.

## 9. Attributes and tags
| Instance | Attribute | Set by | Read by |
|---|---|---|---|
| Vehicle model | `OwnerUserId: number`, `VehicleId: string`, `State: string`, `Capacity: number` | server | client (prompts, controller gating, cosmetic spin on all clients) |
| Vehicle chassis | `Speed: number` (owner client, cosmetic only), | owner client | – (not replicated; local only) |
| Package model | `OrderId`, `PackageKey` | server | client effects |
| Destination model | `DestinationId`, `Address` | server | client |
| Business model | `BusinessId` | server | client |
| Depot plot model | `PlotId`, `OwnerUserId` (0 = free), `OwnerName` | server | client prompts |
| Player | `TutorialStep: number` | server | client |

## 10. Collision groups (PhysicsService, registered by VehicleService.Init)
`Players` (character parts), `Vehicles`, `NPCs`, `Packages`. Vehicles↔Vehicles false, Vehicles↔Players false, Vehicles↔NPCs false, Players↔NPCs false, Packages↔everything false. Default↔all true.

## 11. Performance budgets (provisional, unmeasured)
- City: ≤ 4,500 parts total, all anchored; decorative parts `CanCollide=false, CanQuery=false, CanTouch=false`.
- Vehicles: ≤ 36 parts each (the van is 33: 26 body parts, 4 wheels, chassis, body root, seat); one Heartbeat update on the owner, a cheap cosmetic update on other clients only for vehicles within 200 studs.
- NPCs: ≤ 24 client-side pedestrians, ≤ 8 static staff/customers, updated at 20 Hz; ≤ 16 server-side depot NPC parts in total.
- Navigation: ≤ 1 A* per 4 s per client, ≤ 4000 expansions, ≤ 40 marker parts.
- Remotes: ≤ 2 `OrdersUpdated` per second per player; no per-frame remotes.
- Server loops: order generation 5 s, order tick 1 s, driver tick 5 s, anti-cheat 1 s, autosave 120 s.


## 12. Implementation notes and accepted deviations (recorded after implementation)

These additions are part of the contract as built. Where they differ from the sections above, this section wins.

### Server
- `CityBuilder.build(layout, folders, graph?)` takes the Workspace folders table `{city, pickup, destinations, depots}` and an optional prebuilt `RouteGraph.Graph` (CityService passes `ctx.graph`). `ctx.world` carries an extra `partCount`; `DepotPlotWorld` entries carry `groundY`. `CityBuilder.positionsFor(layout)`, `surfaceYAt(layout, x, z)` and `elevationAt` are server-side pure helpers; the client takes world positions from streamed instances (`workspace.DeliveryDestinations.<id>.Door/ArrivalPad`, `workspace.PickupLocations.<id>.PickupPad`, which also carry `DestinationId`/`BusinessId` attributes) and falls back to layout x/z with y = 0.
- `ctx.world.vehiclePads` are CFrames at the pad surface; VehicleService adds `handling.rideHeight`. `GetSafeRespawnCFrame(position, mask, raise?)` raises by `raise` (default `RESPAWN_HEIGHT` = 3, used for characters); VehicleService passes `handling.rideHeight` so Spawn-near-road and Recover park the chassis at road y + rideHeight.
- `VehicleBuilder` extras: `buildDisplay`, `getSlotCFrame`, `getSlotsPerLayer`, `getRideHeight`. The LinearVelocity child is named `Velocity`; because `BasePart.Velocity` is a (deprecated) property, consumers must use `chassis:FindFirstChild("Velocity")`. `BodyMotor` lives inside `BodyRoot`; each `WheelMotor` lives inside its wheel. Builders register the collision groups idempotently because CityService.Init runs before VehicleService.Init; VehicleService owns the collidability matrix.
- `NPCBuilder.build(kind, seed?, options?)` with `options = {name, shirt, pants}`; extras `place`, `freeze`, `setIdlePose`; limbs are Motor6Ds `TorsoJoint/Neck/LeftShoulder/RightShoulder/LeftHip/RightHip`; `Root` centre is 3 studs above the feet.
- `PackageBuilder.build(packageKey, style?)` takes `{color, accent}` (BagStyle cosmetic data). `attachToVehicle` parents under the vehicle `Cargo` folder; `attachToCharacter` welds to `UpperTorso/Torso/HumanoidRootPart` at the back; `detach` keeps the model (Parent nil); the weld is named `AttachWeld`. OrderService sets the `OrderId` attribute.
- `DepotBuilder.apply(plotWorld, profile, ownerName, ownerUserId?)`; everything built lives under `<plot>/Built`; `setVanPresent/isVanPresent` toggle a slot's visuals; `clear` restores the FOR SALE sign.
- Depot plot models carry `PlotWidth/PlotDepth`; the plot `Sign` part also carries `PlotId`.
- `VehicleService.Mount(player, targetModel?)` — pointing at another player's model returns `NotOwner`. Extras: `RunWatchdog`, `RefreshCapacity(player)`. `ctx.builders` (optional) may inject builder modules for tests.
- `Profile.stats.milestonesGranted: {[string]: true}` (idempotent milestones). `Payout` carries extra `deliveryTime` and `milestoneRep`; `Payout.rep` is the order's repReward only.
- `OrderService.Cancel(player, orderId, opts?)` with `opts = {silent?, noPenalty?, reason?}`; Available orders of the player may also be cancelled (used by ContractService to withdraw offers). Extras: `SetGeneratorEnabled/IsGeneratorEnabled`, `RefreshPackages`, `RunGeneration(player)`, `RunTick()`. Tutorial orders stay on the board for 24 h (`availableFor`). The generator pre-filters destinations by straight-line distance and prices the chosen order with a real A* distance.
- `ShopService.PurchaseVehicle/PurchaseCosmetic` auto-equip the purchased item. `ShopService.ApplyUniform(player)` also runs on CharacterAdded.
- Error code `Unavailable` is returned when a target service is not loaded; `NotReady` (with `secondsLeft`) for early pickups.
- `TutorialUpdated` carries `{step, completed, title, body, hint}`; `TutorialService.GetHint(step, player?)` (with a player, step 2 says "take a bike at the hub pad" while no vehicle is spawned and is re-sent when one appears), `GetStep`, `StepChanged` exist. Tutorial steps 2/3 advance to 4 by server-side proximity polling (1 s). `TutorialStep` attribute is 9 for completed profiles. `InteractionService.GetSnapshot` waits up to 15 s for the profile.
- ContractService: offers pair each destination of the rush neighbourhood only with businesses whose `deliveryProfile` (neighbourhoods and, when set, `kinds`) serves it, on top of `businessesByNeighborhood` and size acceptance (e.g. groceries never go to loading bays; an Industrial rush needs CrateAndCoSupply unlocked); `Join` calls `OrderService.Accept(player, id, { viaContract = true })` and an offer accepted by any path is dropped from the offer list. Rush ids are `LunchRush-<n>` (orders carry that `contractId`; `Join` accepts the rush id or `LunchRush`); the first rush opens `INITIAL_DELAY` (120 s) after server start; `RewardService.GrantContractBonus` increments `stats.contractsCompleted`; `ContractPublicState.joined` carries extra `completed/failed`; cancellation reasons `ContractClosed`, `ContractExpired`, `ContractJoinFailed` (all silent, no penalty). Extras: `RunTick`, `GetCycle`, `ForceOpen(neighborhood?)`, `Stop`.
- DepotService: `DepotPublicState.publicPlots = { {plotId: string, ownerName: string, ownerUserId: number, drivers: number} }` (`drivers` = the owner's hired-slot count, `Types.DepotPublicPlot`) for social visits; `Collect` measures proximity to the plot origin and returns `WrongState` with nothing pending / `NotFound` without a claimed plot, and adds the collected amount to `stats.totalEarned`; `AssignDriver` codes: `Invalid` (bad slot), `Locked` (slot not unlocked / no depot), `NotFound`, `Requirements` ("Requires 1,200 Rep"), `WrongState` (driver out), `Insufficient`; `UnlockSlot` with both unlocked and `HireDriver` on a hired slot return `AlreadyOwned`. `WorldEvent DriverDepart/DriverReturn` go to all clients. Extras: `SetVanPresent`, `PushState`, `RefreshVisuals`, `GetPublicPlots`, `ClaimPlot/ReleasePlot/GetPlotId/GetPlot`.
- DriverService: `TICK_INTERVAL = 5`; `OnProfileLoaded` settles due assignments before DepotService claims the plot (bootstrap order), and DepotService re-syncs van presence after the claim.
- `PlayerDataService.ProfileLoaded` can fire synchronously during PlayerAdded; services also scan `Players:GetPlayers()` in Start.
- **Studio-only developer tooling** (`docs/DEVTOOLS.md`): `DevService` is a 14th service (picked up by the bootstrap's folder scan, after the documented order). `DevService.Init(ctx)` returns at once and creates nothing unless `ctx.isStudio` **and** `RunService:IsStudio()`; in Studio it creates the RemoteFunction `ReplicatedStorage.Remotes.DevCommand` directly (it is deliberately **not** in `Remotes.Functions`, so `createAll` never makes it) and serves `OnServerInvoke(player, command: string, args: table?)` with the usual validation (strings <= 64 chars, finite numbers, tables <= 16 string-keyed entries of string/number/boolean), a 10/s per-player `RateLimiter`, `warn("[DevService] ...")` logging and `Remotes.ok/fail` results. Commands: `GrantCash`, `GrantRep`, `UnlockAll`, `SkipTutorial`, `ResetProfile`, `OwnVehicle`, `Despawn`, `Recover`, `ListTargets`, `Teleport`, `OpenLunchRush`, `ExpireContract` (returns `Unavailable`: ContractService has no end-now API), `FinishDrivers`, `FillBoard`, `ReadyOrders`, `SetSpeedCap`, `Report`. Extras: `DevService.Invoke(player, command, args)` (the handler, public for specs), `IsEnabled()`, `GetCommands()`.
- Additive APIs for the tooling: `VehicleService.TeleportTo(player, groundCFrame): Result` (Driving or Parked; chassis placed `handling.rideHeight` above the pose through the same placement path as Recover: zero velocity, `Align` sync, `lastSafePosition`; a riding player moves with the model and `AntiCheatService.NotePlausibleTeleport(player, 3, position)` is called; a Parked vehicle moves alone and stays anchored; no cooldown). `AntiCheatService.SetSpeedOverride(player, vehicleId, maxSpeed?)` / `GetSpeedOverride(player, vehicleId)`: the allowed distance uses `math.max(definition maxSpeed, override) * upgradeMultiplier` for that player and vehicle; nil / <= 0 clears; cleared on `PlayerRemoving`. `TutorialService.Complete(player): boolean` (completes through the normal step-9 path; false when already complete) and `TutorialService.Restart(player): boolean` (forgets the session state and re-runs the profile-load path).

### Custom meshes (imported vehicle bodies)
- `Shared/Config/MeshAssets.luau` holds, per vehicle id, `{ body = { meshId, textureId }, wheels = { [wheelName] = { meshId, textureId } } }` (numbers pasted from the MeshPart's `MeshId`/`TextureID` `rbxassetid://` strings after importing `assets/meshes/<VehicleId>/<VehicleId>_Body.obj` with Studio's 3D Importer; `meshId = 0` = not configured). Helpers: `hasBody(vehicleId)`, `bodyIds(vehicleId) -> (meshId, textureId)?`, `wheelIds(vehicleId, wheelName) -> (meshId, textureId)?`, `assetUrl(id)`. Wheels are optional and may be configured later without code changes; until then they are baked into the body mesh.
- `VehicleDefinitions[id].mesh = { body = { size, offset }, seatOffset?, cargoOffset?, cargoLayout?, chassisSize?, dismountOffset?, wheels = { {name, radius, offset, steerable} } }` (`VehicleDefinitions.MeshSpec`; numbers from `assets/meshes/<id>/meta.json`: `size` is the OBJ bounding box, `offset` its centre relative to the chassis centre, which sits `handling.rideHeight` above the ground; the two-wheelers use `offset.x = 0` instead of their asymmetric box centre (0.15 / 0.32) so the tyre line sits on the chassis centreline under the seat). The generated-part numbers (`seatOffset`, `cargoOffset`, `cargoLayout`, `chassisSize`, `dismountOffset`, `visual`) are unchanged. **`VehicleDefinitions.getEffective(vehicleId, useMesh: boolean) -> { seatOffset, cargoOffset, cargoLayout, chassisSize, dismountOffset }`** (`EffectiveLayout`, a fresh table) is the single source of truth for every reader of those offsets: the generated values, or the `mesh` overrides merged over them when `useMesh`. Server readers pass `VehicleBuilder.usesMesh(id)` (VehicleBuilder chassis/seat/attachments/`getSlotCFrame`/`getSlotsPerLayer`, `PackageBuilder.attachToVehicle` through `getSlotCFrame`, `VehicleService` dismount fallback); the client passes `MeshAssets.hasBody(id)` (`VehicleController` chassis length, `CosmeticsController` previews).
- `VehicleBuilder.usesMesh(vehicleId)` is true when `MeshAssets.hasBody(id)`, the definition has a `mesh` block and the mesh has not failed to load this server session. `VehicleBuilder.build`/`buildDisplay` then create the body as one `MeshPart` named **`MeshBody`** under the `Body` folder: a clone of a template built once per `(meshId, textureId)` with `AssetService:CreateMeshPartAsync(Content.fromAssetId(meshId), { CollisionFidelity = Box, RenderFidelity = Automatic })` (yields on first use; concurrent callers for the same pair wait for the one in-flight call instead of requesting the asset again; `VehicleBuilder.warmMeshCache(id)` preloads, `resetMeshCache()` forgets), `TextureID = "rbxassetid://<textureId>"` when `textureId > 0`, `Size = mesh.body.size`, `CFrame = chassis * CFrame.new(mesh.body.offset)`, `Massless`, `CanCollide/CanQuery/CanTouch = false`, `CastShadow = true`, CollisionGroup `Vehicles`, `WeldConstraint` to `BodyRoot` (anchored, no weld, in `buildDisplay`), **no `PaintSlot`** (`applyCosmetics` and `CosmeticsController.ApplyColors` skip MeshParts). No `visual.parts` are generated. `Wheels` holds a MeshPart per wheel in `mesh.wheels` whose ids are configured (`Motor6D "WheelMotor"`, `C0 = offset`, attributes `Steerable`/`Radius`, size = the imported mesh's size) and is an **empty Folder** when none are configured; `VehicleController` (owner and non-owner cosmetic pass) tolerates the empty folder and two-wheeler lean still runs through `BodyMotor`. The model carries an extra attribute `UsesMesh: boolean`.
- Fallback: a `CreateMeshPartAsync` failure (or a non-MeshPart result) warns **once per asset pair** (`[VehicleBuilder] mesh <id> (<label>) failed to load, using generated parts: ...`), is remembered for the session (no retry on later spawns, so a bad id never stalls every spawn) and the vehicle is built from the generated parts **with the generated offsets** (`usesMesh` turns false for that vehicle, so cargo slots and dismount agree with the built geometry).
- Shop previews: clients cannot create MeshParts from ids, so `VehicleService.Start` runs `VehicleService.PublishDisplays()` (`task.spawn`; per vehicle `pcall`): for every vehicle with `usesMesh` it warms the cache, builds `VehicleBuilder.buildDisplay(id, defaultColors)` and parents it as **`ReplicatedStorage.SharedAssets.VehicleDisplays.<VehicleId>`** (the folder is created on first publish and absent when no vehicle uses a mesh; a vehicle whose mesh failed gets no entry). `CosmeticsController.BuildDisplayVehicle` clones that model when `MeshAssets.hasBody(id)` and it is present (`WaitForChild` up to `CosmeticsController.DISPLAY_WAIT` = 1 s for the folder and again for the entry), otherwise it builds the generated preview as before; `GetDisplayRadius` bounds the mesh body for mesh vehicles. `DepotBuilder` parked vans go through `buildDisplay` and therefore match. `ShopMenu` card text is unchanged (nothing about meshes).
- Harness: `tests/shim.luau` mocks `AssetService:CreateMeshPartAsync(content, options)` (returns a `MeshPart` with `MeshId` from the Content, `Size (1,1,1)`, the requested fidelities; calls recorded in `shim.assetService.calls`; `shim.assetService.failNextCalls = n` makes the next n calls raise, `shim.assetService.latency = s` makes each call yield that long) and the `Content` global (`fromAssetId/fromUri/fromObject/none`, `typeof == "Content"`). Specs: `tests/specs/meshes.spec.luau`.

### Client
- See section 7; `ClientState` additionally exposes `OrderEvent` and `WorldEvent` signals, `device`, and `getOrderedStops()`. `UIController` additionally exposes `TutorialContinue`, `PromptActivated` and `OpenDepotFor(plotId?)`.
- Review fixes (cross-module): `VehicleService` re-targets the chassis `AlignOrientation` (`Align.CFrame = chassis.CFrame.Rotation`) after every server pivot (spawn, ground snap, recover) and in `Mount` before the chassis is unanchored, and `VehicleController.activate` does the same on the owner before its first step, so a mount never yaws the vehicle toward the builder's identity rotation. Success toasts have one source: the server `Notify` (ShopService purchases, DepotService purchase/unlock/hire/assign/collect, ContractService join); the client screens toast only failures and local equips. `RateLimiter` sweeps idle buckets (older than `burst / rate`) every `SWEEP_EVERY` new keys (`Sweep(maxIdle?)`, `Count()`), and `InteractionService` sweeps the per-order limiter on `PlayerRemoving`, so client-chosen order ids cannot grow server memory. The HUD root is a plain `Frame` (a `CanvasGroup` re-rasterised the viewport every speed-bar write); `HUD.SetDimmed` only records the state (the `DDC_Menus` scrim dims the HUD) and `HUD.SetVehicleHud` skips frames whose values did not change (`HUD.SPEED_STEPS`). On touch the vehicle readout sits `HUD.VEHICLE_HUD_TOUCH_BOTTOM` above the bottom edge (jump button / CAS cluster) and the minimap moves top-left (`Minimap.SetTouchLayout`). `TutorialController` shows the step-9 "You're ready" card (sent with `completed = true`) only on the in-session transition from a lower step, closes it locally on Continue and sends `AdvanceTutorial(9)` as the ack; a returning completed player never sees it. The unimplemented `Horn` action was removed (it shared ButtonR3 with `RecenterCamera` and, bound last, sank it); `InputActions.Glyphs` has no entry for an action without an affordance on a device (`SettingsMenu.ControlsFor(device)` skips those), the touch glyphs point `NextStop` at the Deliveries screen and `RecenterCamera` at Settings, where a "Recenter camera" button calls `CameraController.Recenter`. `DepotPublicState.publicPlots[].drivers` is a number (`Types.DepotPublicPlot`). The hub kiosk is authored in front of the Hub building (`CityLayout.hub.kiosk = (0, 48)`) and `InteractionController.KIOSK_DISTANCE` is 6 so a player on a vehicle pad gets the pad's prompt.
- `ClientState.vehicle.state` is nil whenever the player has no vehicle: `ClientBootstrap.applyVehicle` maps the server's terminal `VehicleStateChanged {state = "Despawning"}` event (and a nil state) to `{state = nil, vehicleId = nil, model = nil}`, so client consumers only ever see the live states (`InteractionController` additionally treats a raw `"Despawning"` as no vehicle). `ClientState.tutorial` is seeded nil and only populated from the snapshot / `TutorialUpdated` / `ProfileUpdated`, so no banner shows before the profile is known; `TutorialController.Continue` surfaces a rejected `AdvanceTutorial` through `UIController.Notify` (`Locked` → "Still loading your profile..."). While `VehicleController` is active (Driving + seated) it disables the local humanoid's `Jumping` state (`SetStateEnabled`) and re-enables it on deactivation, because the PlayerModule touch jump button bypasses ContextActionService; `CameraController` locks and hides the cursor (`UserInputService.MouseBehavior = LockCurrentPosition`) for the duration of a right-mouse orbit drag while driving and restores `Default` on release, on leaving the driving camera and on `WindowFocusReleased`.
- **Studio-only developer panel** (`docs/DEVTOOLS.md`): `DevPanelController` is a 13th controller (picked up by the bootstrap's folder scan after the documented order). `Init`/`Start` return early unless `RunService:IsStudio()`; `Start` then waits up to 10 s for `ReplicatedStorage.Remotes.DevCommand` and stays dormant without it. In Studio it builds its own ScreenGui `DDC_Dev` (DisplayOrder 50, above `DDC_Menus`) with a top-right DEV button and a right-side ~360 px column (sections Economy, Vehicles, Teleport, Events, Handling, Report; `ContextActionService` F6 toggles it). It never touches `UIController`'s screens and is not a modal (`UIController.IsModalOpen()` stays false; only the panel frame is `Active`). Extras for specs: `IsEnabled`, `IsOpen`, `Toggle`, `SetOpen`, `GetGui`, `GetPanel`, `GetSection(name)`, `GetStepper(key)`, `GetTargetList`, `Invoke(command, args)`, `ApplyHandling(key, value)`, `StepHandling(key, direction)`, `SetHandlingVehicle(id)`, `RefreshTargets`.
- `src/client/HandlingOverrides.luau` (sibling of `ClientState`): session-only handling overrides for live tuning. `get(vehicleId)` returns the definition's own `handling` table when nothing is overridden (same identity, identical behaviour) and a cached merged copy otherwise; `set(vehicleId, key, value): boolean` (a value equal to the definition removes the override; unknown keys / non-finite values are ignored), `reset(vehicleId)`, `resetAll()`, `getOverrides(vehicleId)`, `hasOverrides`, `getDefault(vehicleId, key)`, `snippet(vehicleId)` (the full merged `handling = { ... },` block in definition order, overridden keys commented `-- was <old>`), `formatNumber`, `KEY_ORDER`, `Changed: Signal<vehicleId>`. `VehicleController` resolves `refs.handling` through `HandlingOverrides.get` and, on `Changed` for the active vehicle, swaps `refs.handling` and drops the cached `stepHandling`; `CameraController.handlingFor` falls back to `HandlingOverrides.get` (cache invalidated on `Changed`) when no VehicleController handling is available. With no overrides every existing spec runs unchanged.
- UI layout/device extras (additive): `Minimap.SetTouchLayout(isTouch)` (touch: top-left 140 px translucent map clear of the dynamic thumbstick zone; otherwise 180 px bottom-left), `Notifications.SetWidth(px)` driven by `UIController.Relayout()` so the toast column never crosses the top-centre stack on phone viewports, `UIKit.containSelection(frame)/releaseSelection()` (GuiService selection group `DDC_Modal` follows the open screen) and `UIKit.closeButtonText()` ("Close (B)" on gamepad). `ShopMenu` builds vehicle cards once and updates them in place; a preview is rebuilt only when its paint signature changes.
