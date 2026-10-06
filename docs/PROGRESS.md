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
| Builders (City, Vehicle, Package, NPC, Depot) | DONE | builders.spec (21); city = 3557 parts |
| Server services | DONE | server_core.spec (57), contract_depot.spec (18) |
| Client controllers + UI | DONE | client.spec (58), client_verify.spec (10), ui.spec (24) |
| Contract / Depot / Drivers | DONE | Lunch Rush, depot plots, two driver slots |
| Verification report | TODO | docs/VERIFICATION.md |
| README / install | DONE | README.md, docs/ECONOMY.md, docs/PLAYTEST.md, docs/KNOWN_ISSUES.md |
