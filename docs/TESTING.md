# Testing, analysis and build (offline)

Everything runs without Roblox Studio. Three scripts, all honouring `DDC_TOOLS` (a directory holding
`luau`, `luau-lsp`, `rojo` and optionally `globalTypes.d.luau`; otherwise the tools must be on `PATH`):

| Command | What it does |
|---|---|
| `bash tests/run.sh [pattern]` | `python3 tools/bundle.py` → `tests/build/all.luau`, then runs it with `luau`. Exit code is non-zero if any spec fails. `pattern` is a Lua pattern matched against `describe > it` names. |
| `bash tools/analyze.sh` | `rojo sourcemap` + `luau-lsp analyze` over `src/` with the Roblox API types (`tools/.cache/globalTypes.d.luau`, copied from `DDC_TOOLS` or downloaded). `tests/**` is ignored. |
| `bash tools/build.sh` | `rojo build` → `build/DeliveryDashCity.rbxl`. |

Example: `DDC_TOOLS=/path/to/tools bash tests/run.sh "OrderService"`.

## How the harness works

`tools/bundle.py` reads `default.project.json`, walks every `$path` with Rojo's mapping rules
(`Foo.luau` → ModuleScript, `Foo.server.luau` → Script, `Foo.client.luau` → LocalScript, `init.luau`
makes the folder itself the module, `Foo.json` → ModuleScript returning the table, `Foo.txt` →
StringValue, `*.meta.json` → class/properties, `$className`/`$properties` nodes, `globIgnorePaths`)
and writes one self-contained file, `tests/build/all.luau`:

1. `tests/shim.luau` — the Roblox API mock, exposed as the global `shim` and installed as the global
   environment (so specs can use `game`, `workspace`, `Vector3`, `task`, ... directly).
2. The virtual DataModel: every module's source as a long string plus its path. `tests/fixtures/` is
   mapped to `ReplicatedStorage.TestFixtures`.
3. `tests/runner.luau`, then every `tests/specs/*.spec.luau`, then `__ddc_runner.run(args)`.

Each embedded file is compiled with its real path as chunkname, so errors read
`tests/specs/Foo.spec.luau:12: ...` or `src/shared/Util/Maid.luau:40: ...`, never `all.luau`.

Modules are compiled lazily: `require(instance)` runs `loadstring` on first use with
`script` injected (`env = { script = instance }` falling back to the mocked globals), caches the
result by instance identity, errors on cycles (`... was required recursively`) and reports the
module path on compile/runtime errors. A module with a syntax error only fails when required.
Scripts (`.server`/`.client`) never auto-run; call `shim.runScript(instanceOrPath)`.

## Writing a spec

Create `tests/specs/<Name>.spec.luau`:

```lua
--!nonstrict
describe("OrderService", function()
	local OrderService
	beforeEach(function()
		shim.setContext("server")                   -- "server" (default) or "client"
		OrderService = shim.requirePath("ServerScriptService/DeliveryDash/Services/OrderService")
	end)

	it("accepts an available order", function()
		local player = shim.addPlayer("Alice", 1)   -- Player under Players; PlayerAdded fires
		shim.spawnCharacter(player)                  -- R15-like Model, CharacterAdded fires
		-- ... Init/Start the service with a ctx table, then:
		local result = OrderService.Accept(player, "order-1")
		expect(result.ok).toBe(true)
		task.wait(5)                                 -- allowed inside it(): the runner drives the clock
		expect(#shim.warnings).toBe(0)
	end)
end)
```

API: `describe`, `it`, `xit`/`xdescribe` (skip), `fit`/`fdescribe` (focus), `beforeEach`,
`afterEach`, `beforeAll`, `afterAll`, `expect(v)` with `.toBe`, `.toEqual` (deep), `.toBeTruthy`,
`.toBeFalsy`, `.toBeNil`, `.toBeDefined`, `.toBeCloseTo(x, eps)` (numbers, Vector3/2, CFrame,
Color3), `.toBeGreaterThan/LessThan[OrEqual]`, `.toContain`, `.toHaveLength`, `.toBeA(type)`,
`.toMatch(pattern)`, `.toThrow(substring?)` and `.never` for negation. `it(name, fn, { timeout = s })`
caps the virtual time a yielding test may consume (default 120 s).

Every `it` starts from a fresh DataModel (`shim.reset()` runs before each test: clock back to
`os.clock() == 1000`, `os.time() == 1700000000`, empty DataStores, modules re-executed on next
require). Background thread errors during a test fail the test.

Useful `shim` helpers:

| Helper | Purpose |
|---|---|
| `shim.advance(seconds, dt?)` / `shim.step(dt)` | Drive the virtual scheduler: `task.wait/delay/defer`, `WaitForChild`, Heartbeat/Stepped/RenderStepped, tweens, Debris. `advance` steps in `shim.stepDt` (1/30 s) increments, clipped to due times so resumptions happen at exact times. |
| `shim.requirePath("ReplicatedStorage/Shared/Types")`, `shim.getInstance(path)`, `shim.runScript(path)`, `shim.listModules()` | Module access. Paths use `/` or `.`. |
| `shim.setContext("client" \| "server")` | Flips `RunService:IsServer/IsClient`; client context creates `Players.LocalPlayer` (`TestLocalPlayer`, UserId 1) if none exists. `shim.setLocalPlayer(p)` sets it explicitly. |
| `shim.addPlayer(name, userId)`, `shim.spawnCharacter(player, cframe?)`, `shim.removePlayer(player)` | Players and R15-like characters (HumanoidRootPart, Humanoid+Animator, Head, Upper/LowerTorso, limbs, PrimaryPart set). |
| `shim.datastore.data[name][key]`, `.failNextCalls = n`, `.latency = s`, `.calls` | In-memory DataStores. The next `n` calls raise `DataStore request failed (simulated)`; latency advances the clock. |
| `shim.setRaycast(fn)` | Replace `workspace:Raycast` (default: hit the y=0 plane going down, `Instance = Terrain`, Grass). |
| `shim.assetService.calls`, `.failNextCalls = n` | `AssetService:CreateMeshPartAsync(content, options)` returns a `MeshPart` (`MeshId` from the `Content`, `Size (1,1,1)`, requested fidelities) and records each call (`{method, content, options, meshId}`); the next `n` calls raise `CreateMeshPartAsync failed (simulated)`. The `Content` global (`fromAssetId`, `fromUri`, `fromObject`, `none`) is typed `Content`. |
| `shim.input.press/release/tap(keyCode, inputType?)`, `shim.triggerAction(name, state?)` | Fire `UserInputService` events and `ContextActionService` bindings. |
| `shim.marketplace.ownedPasses[userId][passId] = true`, `shim.marketplace.simulatePurchase(player, productId)` | Monetisation stubs; `simulatePurchase` invokes `MarketplaceService.ProcessReceipt`. |
| `shim.prints`, `shim.warnings`, `shim.threadErrors`, `shim.remoteLog`, `shim.boundToClose`, `shim.unknownClasses` | Recorded output and bookkeeping. `shim.quiet = true` silences stdout. |
| `shim.tweensInstant = true` | `Tween:Play()` applies final values immediately (Completed fires on the next step). |
| `shim.Signal.new()` | The Signal implementation used for every instance event. Instance events also expose `:Fire(...)` so tests can simulate engine events (`button.Activated:Fire()`, `prompt.Triggered:Fire(player)`). |
| `shim.remoteCopy` (default true) | Remote/Bindable arguments are deep-copied like real replication. |

## What is mocked faithfully vs. approximated

Real (numerically correct, engine-like semantics):

- `Vector3`, `Vector2`, `CFrame` (true 3x3 rotation matrix: `lookAt`, `Angles`/`fromOrientation`
  and their `ToEulerAngles*` inverses, `fromAxisAngle`, `fromMatrix`, quaternion `Lerp`, `Inverse`,
  object/world space conversions, `Orthonormalize`), `Color3`, `UDim/UDim2`, `NumberRange`,
  `NumberSequence`, `ColorSequence`, `Rect`, `TweenInfo`, `Random` (deterministic per seed), `DateTime`
  (virtual clock), `Enum` (common enums have real values; unknown enums/items are created lazily —
  set `shim.strictEnums = true` to make unknown items error).
- Instance tree: parenting + `ChildAdded/ChildRemoved/DescendantAdded/DescendantRemoving/
  AncestryChanged/Destroying`, `Find*`, `WaitForChild` (yields on the virtual scheduler, returns nil on
  timeout, no warnings), `IsA` hierarchy, `Destroy` (locks `Parent`), `Clone` (deep copy; `Archivable =
  false` descendants are skipped and Instance-valued properties such as `PrimaryPart`, `Part0/Part1`
  and `ObjectValue.Value` that point inside the cloned subtree are remapped to the copies), attributes,
  tags (`CollectionService` signals fire when a tagged instance enters/leaves the DataModel),
  `GetPropertyChangedSignal` (fires only when the value actually changes; a rotation-only `CFrame`
  write fires `CFrame` but not `Position`), `Changed` (ValueBase objects receive the value).
- Parts: `CFrame`/`Position`/`Orientation`/`Rotation` coupling, `Mass` (volume x density),
  `Model:PivotTo/GetPivot/SetPrimaryPartCFrame/MoveTo/GetBoundingBox/GetExtentsSize` (rigid moves of
  all descendant parts; `BasePart:GetPivot/PivotTo` honour `PivotOffset`), attachments
  (`WorldCFrame/WorldPosition` from the parent part).
- `Humanoid` (`Health` → `Died`, `ChangeState`/`StateChanged`, `Sit`/`Jump`, `RootPart`;
  `Enum.HumanoidStateType` carries the engine's numeric values), `Seat/VehicleSeat:Sit` (Occupant,
  `SeatWeld` with Part0/Part1, `humanoid.SeatPart`, `Seated(true, seat)` / `Seated(false, nil)`; unseat
  via `Sit = false`, `Jump = true`, `ChangeState(Jumping)`, destroying the weld, or death).
- Scheduler: `task.*`, `wait/spawn/delay`, `os.clock/os.time/tick/time`, Heartbeat ordering,
  `Signal:Wait`, `TweenService` (real easing + interpolation on the clock, `Completed`, `Cancel`,
  `Pause`), `Debris`, `DataStoreService` (`Get/Set/Update/Increment/RemoveAsync`, OrderedDataStore
  sorting, key info), `HttpService` JSON (pure Luau, unicode escapes) and deterministic GUIDs,
  `PhysicsService` collision groups, Remote/Bindable events and functions (single process:
  `FireServer` calls `OnServerEvent` with `Players.LocalPlayer`).

Approximated or inert:

- No physics: velocities/forces/constraints/welds are property bags; `ApplyImpulse` is a no-op; parts
  only move when code sets `CFrame` or pivots a model. `AssemblyMass` is the part's own mass.
- `workspace:Raycast` hits only the y=0 plane (override with `shim.setRaycast`); `GetPartBoundsIn*`
  use axis-aligned approximations; `Touched` never fires on its own.
- GUI: `AbsoluteSize/AbsolutePosition` follow `Size/Position/AnchorPoint` only (no `UIListLayout`
  placement, no `AutomaticSize`); `TextBounds`/`TextService:GetTextSize` are rough estimates;
  `ScreenGui` viewport is 1280x720 with a 36 px inset.
- `Humanoid:MoveTo` fires `MoveToFinished(true)` on the next step without moving (set
  `shim.humanoidMoveToTeleports = true` to teleport the root). Animations load but do nothing.
- Streaming, network ownership (`SetNetworkOwner` only records; errors on anchored parts),
  `ModelStreamingMode`, `AddPersistentPlayer` are recorded, not enforced.
- Sounds, particles, lights, beams, highlights, terrain fills are property bags with recording
  methods. `MarketplaceService`, `TeleportService`, `BadgeService`, `LocalizationService`, `Chat`,
  `TextChatService`, `GroupService`, `LogService`, `VRService`, `HapticService`, `PolicyService`,
  `MessagingService` (works in-process), `PathfindingService` (straight-line waypoints), `TextService`
  filtering (pass-through) are stubs.
- `Instance.new` accepts unknown class names (they become plain Instances; see
  `shim.unknownClasses`). Unknown properties read as `nil` and are stored on assignment. Calling a
  method that exists on another class raises `X is not a valid member of Class "Path"`.
- `HttpService:GetAsync/PostAsync/RequestAsync`, `InsertService:LoadAsset`, `require(assetId)` and
  `require("string")` raise.
- Signals fire handlers synchronously in connection order (Roblox fires newest-first); each handler
  runs in its own coroutine so it may yield.
- `typeof` is replaced to report `Vector3`, `CFrame`, `Instance`, `EnumItem`, ... for the mocks.

Specs and modules share `_G` (`shim.G`, cleared on reset). `loadstring`/`getfenv`/`setfenv` from the
CLI remain reachable through the global fallback; game code must not rely on them.
