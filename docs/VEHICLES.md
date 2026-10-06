# Vehicle framework specification

Priority #1 technical feature. One shared controller, three handling tables (`VehicleDefinitions`).
The design goal is control and reliability over simulation. No live Studio test has been run on this
model yet; the parameters are a reasoned starting point and must be tuned in Studio (see VERIFICATION.md).

## Model: constraint-driven ground-follow ("hover on rays")

The physical body is a single invisible box (`Chassis`). Two constraints drive it:

- `LinearVelocity` (`Velocity`, world-relative, full 3-axis `VectorVelocity`) sets the chassis velocity every frame.
- `AlignOrientation` (`Align`, one-attachment mode) drives the chassis to a target orientation every frame.

Because the velocity is fully commanded (including Y), gravity is emulated by the controller when
airborne and ride height is held by a proportional controller when grounded. The vehicle therefore
**cannot flip**, never launches, never wobbles, and climbs curbs/ramps smoothly. Wheels, body lean and
steering are cosmetic (`Motor6D.Transform`, local only).

The chassis stays `CanCollide = true` in collision group `Vehicles` (collides with the world only), so walls stop
the vehicle; `MaxForce` is finite (`AssemblyMass * 1200`) so anchored geometry always wins.

## Per-frame algorithm (owner client, Heartbeat, `dt` clamped to [1/240, 1/20])

Inputs: `throttle ∈ [-1,1]` (VehicleSeat.ThrottleFloat), `steerInput ∈ [-1,1]` (SteerFloat, +1 = right), `brake` (InputController).
State: `heading` (radians, 0 = facing -Z, increases turning left), `speed` (signed studs/s), `steer` (smoothed), `vy` (vertical velocity while airborne), `blockedTimer`, `groundNormal` (smoothed, starts +Y).

1. **Probe the ground.** Raycast down from three points `P_front`, `P_centre`, `P_rear` at chassis position + forward·(±length/2·0.8), from 2 studs above the chassis centre, length `rideHeight + probeExtra + 2`, `RaycastParams` filtering `Runtime.Vehicles`, all characters and packages, `IgnoreWater = false`. `grounded = centre hit exists and hitDistanceBelowChassis <= rideHeight + 1.25`. Ground height `gy = max(hit.Y of the hits)`, `normal = average of hit normals` (unit, fallback +Y). If the normal's angle to +Y exceeds `maxSlopeDegrees`, treat as not grounded for drive purposes (vehicle slides back under emulated gravity along the slope: apply `speed -= g·sin(slope)·dt`).
2. **Speed.**
   - brake: `speed = moveToward(speed, 0, brakeDeceleration·dt)`
   - throttle > 0: if `speed < 0` brake, else `speed = min(speed + acceleration·throttle·dt, maxSpeedEffective)` where `maxSpeedEffective = maxSpeed · speedMultiplier(upgrades)`.
   - throttle < 0: if `speed > 1` then brake (`brakeDeceleration`), else reverse: `speed = max(speed + throttle·acceleration·0.6·dt, -reverseSpeed)`.
   - no input: `speed = moveToward(speed, 0, coastDeceleration·dt)`.
   - not grounded: no acceleration changes (keep speed), no steering.
3. **Steering.** `steer = damp(steer, steerInput, steerResponse, dt)`. Turn-rate factor by speed: `f = clamp(|speed| / turnFullSpeed, minTurnFactor, 1)`, then scaled down toward `highSpeedTurnFactor` at max speed: `f *= lerp(1, highSpeedTurnFactor, clamp((|speed| - turnFullSpeed) / (maxSpeed - turnFullSpeed), 0, 1))`. `heading -= steer · turnRate · f · dt · sign(speed)` (reversing mirrors steering like a real vehicle). When |speed| < 0.5 the heading does not change.
4. **Target orientation.** `forwardFlat = (-sin heading, 0, -cos heading)`; `forwardOnGround = (forwardFlat - normal·dot(forwardFlat, normal)).Unit`; `targetCF = CFrame.lookAlong(pos, forwardOnGround, normal)`; `Align.CFrame = targetCF.Rotation`.
5. **Velocity.** `horizontal = forwardOnGround · speed`. Vertical: if a ground hit exists within `rideHeight + probeExtra`: `targetY = gy + rideHeight`, `vyCmd = clamp((targetY - pos.Y) · verticalGain, -maxClimbRate, maxClimbRate)`; `vy = vyCmd`. Else (airborne): `vy = max(vy - gravity·dt, -maxFallSpeed)`. `Velocity.VectorVelocity = horizontal + (0, vy, 0)`. `Velocity.MaxForce = AssemblyMass · 1200` (recomputed when the occupant changes).
6. **Blocked detection.** `actual = chassis.AssemblyLinearVelocity` projected on `forwardOnGround`. If `|speed| > 6` and `|actual| < |speed| · blockedSpeedFraction` for more than `blockedTime` seconds: `speed *= bumpSlowdown`, play the bump sound, reset timer.
7. **Cosmetics.** `wheelSpin -= speed·dt / wheel.radius` (negative around +X spins the top forward); steerable wheels: `Transform = Angles(0, -steer·wheelSteerAngle, 0) · Angles(spin, 0, 0)` (negative Y = turn right in Roblox's right-handed frame); body lean (two-wheelers): `BodyMotor.Transform = Angles(0, 0, steer · leanAngle · clamp(|speed|/maxSpeed,0,1))` sign such that a right turn leans right (test: `CFrame.Angles(0,0,-θ)` rolls the top toward +X, i.e. to the right). Speed FOV: `CameraController.SetSpeedFraction(|speed|/maxSpeed)`.
8. **Safety.** If `pos.Y < layout.killY` or the chassis is more than 60 studs below the nearest road point for 2 s: request `RecoverVehicle` (rate-limited to once per 3 s). If `upVector.Y < 0.2` for 1.5 s (can only happen through external forces): request recovery. The server runs the same checks as a watchdog.

## States (server authoritative, attribute `State` on the model)

```
Parked ──Mount──▶ Mounting ──seated+owner set──▶ Driving ──Dismount──▶ Dismounting ──▶ Parked
                     │ fail ▶ Parked                 │ Recover ▶ Recovering ▶ Driving
Parked ──Recover──▶ Recovering ──▶ Parked           │ Despawn/leave/switch ▶ Despawning ▶ (gone)
```
- Parked: chassis anchored, velocity zero, network owner server, seat `Disabled = true` (manual `Sit` only).
- Mounting: validation passed; unanchor; `seat:Sit(humanoid)`; verify `seat.Occupant == humanoid` within 0.3 s (retry once toggling `Disabled`), set network owner to the player, state Driving. On failure revert to Parked and tell the player.
- Driving: owner client controller active. Server watchdog: unauthorized occupant → eject (`humanoid.Sit = false; Jump = true`) and keep state; owner no longer seated (fell out, died, reset) → run Dismount logic automatically.
- Dismounting: unseat, teleport character to `DismountAttachment.WorldPosition` (+ raise 3), snap chassis upright at ground + rideHeight, zero velocity, anchor, owner nil, state Parked.
- Recovering: compute `CityService.GetSafeRespawnCFrame(lastSafePosition, mask)`; `model:PivotTo(cf)`; if driving, the rider moves with the model (seated); `AntiCheatService.NotePlausibleTeleport(player, 3)`; return to the previous state.
- Despawning: dismount if needed, remove persistence for the owner, destroy the model.

Handled events: player respawn (dismount logic runs on `Humanoid.Died`; vehicle stays parked where it was; character spawns at the hub; a parked vehicle more than 300 studs from the hub is **not** moved so the player can walk back or despawn/respawn it from the menu), player leaving (despawn), vehicle destroyed externally (state cleared, player notified, can spawn again), losing the seat (watchdog dismount), falling outside the map (auto recover), switching vehicles (despawn then spawn), opening menus (client ignores drive input while a modal menu is open; brake applied), attempting to mount someone else's vehicle (server `NotOwner`; client never shows the prompt).

## Camera (CameraController)
- `CameraType.Scriptable` while Driving. Pivot = chassis position + up·cameraHeight. Desired position = pivot − forwardFlat·cameraDistance (+ orbit offsets). Smoothed with `damp` (position speed 8, orientation speed 10). Look target = chassis position + forwardFlat·cameraLookAhead + right·steer·4.
- FOV = 70 + fovSpeedBoost·speedFraction² (0 when reducedMotion).
- Orbit: mouse right-drag / touch drag / right stick rotate yaw (±180°) and pitch (−10..45°) scaled by `cameraSensitivity`; `autoRecenter` returns to behind after 2.5 s idle (disabled → stays); `RecenterCamera` action snaps smoothly.
- Reduced motion: no FOV change, no lean, slower smoothing is NOT used (keeps responsiveness); instead the camera follows rigidly with damp speed 20.
- Not driving: `CameraType.Custom` (default Roblox camera).

## Inputs
Throttle/steer: `VehicleSeat.ThrottleFloat/SteerFloat` (W/S/A/D, arrows, touch thumbstick, gamepad left stick) — provided by the Roblox PlayerModule when seated in a VehicleSeat. Brake/Interact/Mount/Recover/Recenter via `ContextActionService` (keyboard, gamepad, touch buttons). Gamepad: R2 can additionally act as throttle override (if `ButtonR2` pressed, throttle = max(throttle, 1)); L2 brakes.

## Collision groups
`Vehicles` vs `Vehicles`: off. `Vehicles` vs `Players`: off. `Vehicles` vs `NPCs`: off. `Packages` vs all: off. Characters are put in `Players` on spawn by VehicleService.

## Cosmetic sync for other clients
Non-owner clients spin the wheels of nearby vehicles (≤ 200 studs) from `chassis.AssemblyLinearVelocity` projected on the chassis look vector and steer them from the lateral velocity sign; no remotes are used.
