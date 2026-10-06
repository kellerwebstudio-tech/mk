# Progress record

Updated as work lands. Status words: DONE (implemented + offline-verified), BUILT (implemented, static checks only), PARTIAL, TODO.

| Area | Status | Notes |
|---|---|---|
| Design summary, scope, plan | DONE | docs/DESIGN.md |
| Architecture contract | DONE | docs/ARCHITECTURE.md |
| Vehicle spec | DONE | docs/VEHICLES.md |
| Shared spine (Types, Util, Config, Definitions) | BUILT | luau-lsp analyze clean |
| Offline test harness | DONE | tools/bundle.py, tests/shim.luau, 81 harness specs pass (luau CLI) |
| CityLayout + RouteGraph | DONE | validator 0 problems; 115 nodes/179 edges; bike/scooter/van graphs connected; docs/map.png |
| Builders (City, Vehicle, Package, NPC, Depot) | TODO | |
| Server services | TODO | |
| Client controllers + UI | TODO | |
| Contract / Depot / Drivers | TODO | |
| Verification report | TODO | docs/VERIFICATION.md |
| README / install | TODO | |
