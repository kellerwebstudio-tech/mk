# Manual playtest script (Roblox Studio)

No live Studio test has been run by the authors. Run these steps before publishing. Each step lists the expected result; record pass/fail in `docs/VERIFICATION.md`.

Setup: build with `rojo build -o build/DeliveryDashCity.rbxl`, open in Studio, enable *Studio Access to API Services*, use *Test → Clients and Servers → 2 players* for multiplayer steps. Watch the Output window; the server prints `Delivery Dash City server ready` and the part count.

## A. First five minutes (new profile)
1. Spawn: you appear at the delivery hub on the plaza's south edge facing the plaza, within sight of the vehicle pads. HUD shows $0 and 0 Rep; a welcome banner appears. Expected: no empty area; the pads are < 30 studs away.
2. Press Continue on the welcome. Expected: tutorial step 1 asks you to open Orders; the board shows exactly one tutorial order (Slice Street Pizza → nearby apartment, $45, no timer).
3. Accept it. Expected: step 2 "Ride your bicycle"; a PICKUP marker/route appears; HUD mini list shows the order.
4. Walk to a vehicle pad, press F (gamepad Y / touch Ride). Expected: a bicycle spawns on the pad with your colours, you are seated within 0.5 s, the camera switches to the follow camera, Brake touch button appears on mobile.
5. Ride with W/A/S/D (thumbstick/left stick). Expected: responsive acceleration to top speed in ~2 s, predictable stops with Space, no wobble, no flipping over kerbs, climbs the plaza ring kerb smoothly, wheels spin, slight lean in turns, FOV widens slightly at speed.
6. Follow the markers to Slice Street Pizza (~120 studs). Expected: next-turn text and distance update; markers follow the alley/street network, never through buildings; the business sign reads SLICE STREET.
7. Stop on the PICKUP pad, press E. Expected: "Collect order" prompt within ~16 studs; after pressing, a pizza box appears on the rear rack, a speech bubble shows the handoff line, the pickup sound plays, step 4 → 5.
8. Follow the DELIVER marker to the address (~75 studs). Expected: door and address sign visible; the prompt appears at the arrival pad or door.
9. Press E at the door. Expected: the door swings open, a customer line appears, the package disappears, a results card shows $45 base + tip, Rep +, and the HUD cash updates once (not twice). Press E again: nothing happens (no duplicate pay).
10. Second tutorial order with the alley hint. Expected: route uses the bike-only alley; delivering completes step 7 and unlocks step 8 (buy Basket I in Upgrades for $75). Buy it. Expected: capacity shows 2/2 max; step 9 completion bonus (+25 Rep); the board now fills with 3–6 orders.
Timing target: first delivery complete within ~3 minutes of spawning.

## B. Vehicles
11. Mount/dismount 10 times in a row (F). Expected: always seated/unseated; character placed beside the vehicle on dismount; vehicle parks upright.
12. Drive into a wall at full speed. Expected: the vehicle stops at the wall, speed bumps down, a thud plays; reversing works (S).
13. Drive off the canal edge into water. Expected: within ~2 s the vehicle is recovered to the nearest road, you remain seated, no payout/order change.
14. Hold R for 1 s while stuck. Expected: recovery to the nearest road point; cooldown 3 s.
15. Reset character (Esc → Reset) while driving. Expected: you respawn at the hub; the vehicle stays parked where it was; packages stay with your orders (re-attached on your back); you can walk back or open Menu → Spawn vehicle to bring it to you.
16. Scooter and van (grant cash/rep via the command bar for testing: see `docs/TESTING.md` "Studio cheats"). Expected: scooter is faster with wider turns; van is heavier with a visibly larger turning circle; the van cannot be routed through alleys (markers use roads only); each vehicle's camera distance differs.
17. Second player tries to sit on your vehicle (walk into the seat / press F near it). Expected: no prompt for them; the server ejects them if they somehow sit; your controls are unaffected.

## C. Orders and capacity
18. With capacity 2, accept two Small orders; the third Accept is disabled with the reason "Not enough capacity". Expected: server also rejects (`NoCapacity`) if forced.
19. Collect both, reorder stops in Deliveries (Up/Down, Set as next). Expected: navigation follows the chosen order; "Suggested order" sorts by proximity.
20. Cancel a collected order. Expected: confirm dialog mentions −2 Rep; package removed; markers cleared; Rep decreases by 2 but never below 0.
21. Let an available order expire (wait 150 s). Expected: it leaves the board with an "Expired" notice; accepted orders never expire; a late delivery still pays base pay with a smaller tip.
22. Leave the server with active orders and rejoin. Expected: orders gone, no penalty, Cash/Rep/upgrades intact.

## D. Lunch Rush, depot, drivers
23. Wait for the Lunch Rush banner (first opens ~2 min after server start, requires 50 Rep and 5 deliveries). Expected: Orders → Lunch Rush tab shows 5 offers; select 2–4 within capacity; Join accepts them all; progress "x/y" and deadline shown; completing all before the deadline pays the bonus once; missing the deadline cancels uncollected ones silently.
24. Depot: with 1,000 Rep and $12,000 open Menu → Depot → Buy. Expected: a free plot becomes yours (sign shows your name), prompt to Collect when near; hire a driver ($2,500), assign Downtown Food ($300 upfront), see the van depart; after 10 minutes the van returns and the slot shows "$900 to collect"; Collect near the plot adds exactly $900 once (press again: nothing).
25. Reassign a returned-but-uncollected driver. Expected: pending cash kept and collectable; new assignment starts.
26. Leave mid-assignment and rejoin after it would have finished. Expected: exactly that assignment completes into pending; nothing else accrues offline.

## E. Persistence
27. Play, leave, rejoin. Expected: Cash, Rep, vehicles, upgrades, cosmetics, tutorial completion, stats and settings restored.
28. Simulate a load failure (disable API access, or temporarily rename the DataStore in `PlayerDataService.DATASTORE_NAME`). Expected: "Progress will not save this session" notice; play works; nothing is written (check the Output for the warning and confirm old data survives after re-enabling).
29. Shut down the server with players online (Studio Stop). Expected: BindToClose saves; rejoin shows the latest state.

## F. Devices
30. Touch emulator (Device → phone). Expected: thumbstick drives, Brake/Interact/Ride buttons in the lower right, all menus usable with taps, HUD within safe areas, minimap bottom-left, text readable at 375×667.
31. Gamepad. Expected: left stick drives, LT brakes, X interacts, Y mounts, D-pad up opens Orders, Start opens Menu, B/Escape closes menus, focus visible on buttons, R3 recenters the camera.

## G. Performance (8 players)
32. Local server with 8 clients, everyone driving. Expected (targets, unmeasured): server frame time < 8 ms, client 60 fps on desktop, memory stable over 15 minutes, ≤ 4,500 city parts, no per-frame remotes in the Network tab.
