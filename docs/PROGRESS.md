# Progress record

Updated as work lands. Status words: DONE (implemented + offline-verified), BUILT (implemented, static checks only), PARTIAL, TODO.

| Area | Status | Notes |
|---|---|---|
| Design summary, scope, plan | DONE | docs/DESIGN.md |
| Architecture contract | DONE | docs/ARCHITECTURE.md |
| Vehicle spec | DONE | docs/VEHICLES.md |
| Shared spine (Types, Util, Config, Definitions) | BUILT | luau-lsp analyze clean |
| Offline test harness | DONE | tools/bundle.py, tests/shim.luau, 81 harness specs pass (harness 67 + harness_extra 14, luau CLI) |
| CityLayout + RouteGraph | DONE | validator 0 problems; 115 nodes/179 edges; bike/scooter/van graphs connected; docs/map.png |
| Builders (City, Vehicle, Package, NPC, Depot) | DONE | builders.spec (23); city = 3550 parts |
| Server services | DONE | server_core.spec (65), server_bootstrap.spec (1), contract_depot.spec (21) |
| Client controllers + UI | DONE | client.spec (61), client_verify.spec (12), ui.spec (31) |
| Contract / Depot / Drivers | DONE | Lunch Rush, depot plots, two driver slots |
| Verification report | DONE | docs/VERIFICATION.md — final run: 65 files compile, 0 type diagnostics, 295/295 specs, place built, layout 0 problems |
| README / install | DONE | README.md, docs/ECONOMY.md, docs/PLAYTEST.md, docs/KNOWN_ISSUES.md |
