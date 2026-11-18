# anommove: Abductor and Can Opener on the guest (W6, 2026-11-18)

Logbook names: Abductor = `BP_Hazard_PhysicsGrabber` (parent `BP_Hazard_Base_Flying`), Can Opener = `BP_Hazard_SawBlade`
(`/Game/Gameplay/Hazards/SawBladeAnomaly`). The older spikes ("not in this build") are wrong.

## Observations (live probe, zone fixture, game MCP, headless pair)
- Saw: the actor root never moves. The blade rides `Mount` (a `SceneComponent`, parent of `StaticMesh`) along a spline: PreMove / Moving /
  EndMove timelines set `Mount` relative location and `StaticMesh` relative rotation (spin). `Mount` was (0,0,0) on the guest while the
  host's was (800,0,-1461); nothing of it replicates. The guest's copy (Role 1) exists, tick off (`bCanEverTick` is false anyway).
- Saw, host: its Logic Driver state machine (`SMStateMachine`, `NetworkTickConfiguration`/`NetworkTransitionConfiguration` 0 = client only,
  same as the garage doors, PT1-garage.md) never leaves IDLE in a listen session, even with the host 7000 uu away and `DataBlock_PlayerInRange`
  true. Calling `StartPreMove` by hand runs the rise (state 0 -> 1); `OnMoveStart` runs the travel; the end (HitEndPoint, `OnEndMove`,
  state 0, `Direction` flipped) chains by itself. Setting both configs to 2 and `Restart()` did not make the machine run.
- Saw spawn: `GroundSplineGenerator:BuildSpline` fails and the saw destroys itself near the start (safety zone, `IsPointInSafetyZone` 500 uu
  buffer, radius > 6000 uu) and on bad ground; (65464,-31031) in the zone fixture is a spot where it survives. Spawning it with the class not
  loaded (no `LoadAsset`) crashed the host (access violation 0x18, three times).
- Abductor: `CoreFloatingMesh` and `SM_PG_Magnet` are physics bodies with no attach parent (root `DefaultSceneRoot` stays at the spawn
  point, so it is a stable key). Arm angle is `armAnim` (`AnimateArm`), the cable is `UpdateCableMesh` (look-at between magnet and cable
  mesh). On the guest both bodies simulate on their own: the copy's core sat at z 9147 under a root at 9818 (host core 9814): it fell
  ~650 uu to the ground. `world.lua` already placed the core by name 4 times a second, which a simulating body ignores between updates.
- Abductor logic is the host's tick (`PatrolTICK`, `MoveToCarTimers` ...) plus its own Logic Driver machine (config 0,0,2). A grabber
  spawned 1200 uu over the parked car did nothing for 60 s (target = the car within 10000 uu with a clear line, `HazardsNoGrab` off);
  level-placed grabbers patrol on the host as usual.

## Derived
- Guest copy needs: the host's `Mount` rel. location + blade rotation + visibility (saw), `CoreFloatingMesh` and `SM_PG_Magnet` world
  transforms + `armAnim` (grabber), physics off for the grabber bodies on the guest, and the game's own `UpdateCableMesh`.
- Match by root position (static, within 80 uu): spawned hazards have different names on host and guest.
- The saw's damage needs no guest code: its mesh overlap runs on the host with the guest's pawn there, the piercing message is dispatched to
  the pawn and `anomalies.lua` forwards it (`MessageBind_MSG_Damage_Physical`; scenario forces the overlap handler).

## Implementation (`mod/PacificTogether/Scripts/anommove.lua`, FEATURES "anommove")
- Host, every 100 ms: saws and grabbers within 15000 uu of any player send changed rows (all every 1 s) in `g.anom.move`.
- Host, every 500 ms: a saw that is armed (`DataBlock_PlayerInRange`) and has stood still in the same state for 2.5 s is pushed to its next
  step (`StartPreMove` / `OnMoveStart` / `OnEndMove`). A working machine (1 s tick) never waits that long, so the driver is harmless where the
  game's own machine runs (`M.drive = false` switches it off).
- Guest, every frame: smooths toward the newest row over ~0.1 s (jumps over 1500 / 3000 uu are not glided), turns the grabber's physics
  off once, applies `AnimateArm` and `UpdateCableMesh`.
- `world.lua`: the guest no longer places a grabber's core itself when anommove is on (one line).
- Mutation `noanommove`: module off in both processes (no sync, no host driver).

## Unknowns
- The grabber carrying the car or an item was not produced in a test (no hunt in the spawned case). By design the carried thing is moved by
  the host's physics and shown through `car.lua` / item replication; the magnet it hangs from is synced. Needs a hand check.
- Saw blade spin is applied at 10 Hz (steps, no extrapolation); the chargeup/dust VFX and sounds on the guest copy are not driven.
- A guest sitting in the car hit by a saw (car damage path) not checked.
- Grabber lift in the scenario is a component move with physics off on the host, not the grabber's own lift.

## Results (pair C:\PTLanes\anommove, port 7881, headless)
- `anommove` 22/22: `20261118-093048-anommove-anommove` (first run 21/22, the lift check failed because the host grabber's own stabiliser pulled the bodies back; physics off on the host for the scripted lift).
- Mutation `noanommove` 18/22, failing `guest_abductor_at_host_height`, `guest_abductor_lifts`, `host_saw_runs_its_cycle`, `guest_saw_follows_host`: `20261118-093853-anommove-anommove-noanommove` (the saw damage checks still pass: the hit is the host's own game).
- `session` 40/40 `20261118-094241-anommove-session`; `anomalies2` 27/27 `20261118-094401-anommove-anomalies2`.
