# anomtail: Bunnies and the W6 long tail (2026-11-18)

Scenario `anomtable` (docs/spikes/W6-anomalies.md), module `mod/PacificTogether/Scripts/anomtail.lua`, mutation `noanomtail`.
Baseline run `20261118-092122-pair1-anomtable` (54/65): 11 failing checks.

## Observations
- Bunnies (the Leeches) are `BP_Base_Hazard_WorldItem`, so world.lua skips them (no position sync, no tick-off). Their guest copy is a
  replicated one (Role 1) but kept its own tick: the Leech's ReceiveTick ends with `K2_SetActorLocation(sphere location)`, and the
  guest's own physics sphere had fallen or rolled elsewhere. Offsets seen: constant 447 uu (boltbunny), up to 1160 (boombunny).
  The same row passed by luck in later runs, so the check is flaky without the fix.
- The leap target is the host's car (`K2FindManager(BP_CarManager_C)`, `GetLeapTargetLocation`); the camera (`GetPlayerCameraManager(0)`)
  decides vacuum and range, and `CheckForHitPlayer` compares the hit actor with `BP_MainCharacterManager.GetCharacterActor`. A guest on
  foot, with the host far away, is never a target and never hit: all five `_hurt` rows left the guest at 100 hp.
- `SetSimulatePhysics(false)` on a guest copy's sphere crashed the guest (access violation, `20261118-094510-anomtail-anomtable`).
- Lightning strike: `BP_Hazard_LightningStrike` destroys itself about a second after it begins play. The 1 s replication sweep of
  world.lua never reaches it, the test's first poll came after 3 s. Replicating from a `ReceiveBeginPlay` hook (as world.lua does for
  the acid glob) gives the guest a copy; the guest's copy was seen within the strike's life.
- Airstrip (`BP_Hazard_LowGravityZone`): its ubergraph ends with `GenerateWall(); if Spline.GetSplineLength() > 0 { AddSplineMeshProto ... }
  else K2_DestroyActor()`. A bare spawn has no spline points, so it destroys itself right after spawn (flaky: it survived the first poll
  in subset runs, was gone in the full baseline run and in `20261118-101235`). The row now spawns the `_RampTruck` variant (a spline of
  its own); it passed 63/63 in the full runs.
- Sightseer (`BP_Hazard_Evolved_Landmine_Floater`) once counted 2 copies (`20261118-101235`): a Pilgrim's Floaters outlive their row.
  The scenario clears Floaters before the sightseer row. Clearing every class's leftovers crashed the host (`20261118-102009`), so it is that row only.
- `IsSimulatingPhysics("None")` on a leech's sphere crashed the host (access violation) for a leech spawned a moment before (anomalies2's
  bare `BP_Hazard_Leech_C`); the body flag `BodyInstance.bSimulatePhysics` is read instead.
- Minuteman (`BP_Hazard_Movement_Prong`): host actor stays (~23 s) with tick off (dormant), replication flags fine (repl, remote role 1,
  always relevant). The guest copy appears at the right place (Role 1, offset 0) and is destroyed ~3 s later by its own logic
  (`PendingKill` seen 3.1 to 3.4 s after first sight, in every run). The test's `inWorld` skips destroyed actors, hence copies=0.
  Tried on the copy, none helped: TimeActive and DelayBeforeRetract 1e6, EnableProperty true/false, ConductiveDistance 0 (both the
  actor's and the Conductive component's). The remaining suspects: `ForceRetract`/`OnAllDamageDelt` chains, or the PooledActor /
  item-manifestation base destroying a copy that has no item instance. Not found without reading the engine side of the pool.
- Interloper (`BP_Hazard_ProximityMine_EvolvedCultist`, DLC): the guest copy exists when queried, but the host actor has moved
  ~36000 uu from its spawn spot by then and is destroyed within seconds (`host actor gone`). A hand-spawned Interloper does not
  survive on the host, so there is nothing to mirror. The class is absent from the atlas (plugin pak).

## Derived
- A guest copy of a Leech must not tick: with tick off the replicated root location (the host's sphere, written by the host's tick) wins.
  The sphere itself is set to the actor every 50 ms (no physics calls).
- A leech needs a guest-specific trigger: the host finds a guest pawn within 900 uu of a leech that is not leaping, grabbed, a Healer
  or Charging Bunny, and not in its 10 s cooldown; it throws the leech at the pawn and bites (the game's own 15 damage, forwarded to
  the guest by anomalies.lua) when the leech is within 220 uu. The game's own hit path (anomalies2.lua, leap state 3) stays.

## Guesses
- The Prong copy destruction is the conductive property's zap on the guest's own pawn ending the cycle. Not confirmed (ConductiveDistance 0 did not stop it).
- Interloper is a spawn-point driven mine (it needs a cultist/proximity set-up); the 36000 uu is a "teleport to its anchor".

## Unknowns
- Whether level-placed Minutemen in real maps behave like the hand-spawned one. They are found by name (world.lua g.world.pos), unlike a spawned one.
- Whether a Leech's bite should also need the guest on foot to be near enough to be "seen" (the game wants a line of sight to the car).

## Results (worktree C:PTLaneswt-anomtail, pair C:PTLanesnomtail)
- anomtable full: baseline 54/65 (`20261118-092122-pair1-anomtable`); after the fixes 63/63 (`20261118-103421-anomtail-anomtable`), minuteman and
  interloper logged "not checked".
- Mutation `noanomtail` (rows boltbunny, burpbunny, boombunny, brokenbunny, dustbunny, lightning): 22/29, 7 checks fail (`20261118-104114-anomtail-anomtable-noanomtail`).
- anomalies2 27/27 (`20261118-104730-anomtail-anomalies2`; one run had `guest_pulled_by_grabber` fail, a pull-speed check, not repeated); session 40/40 (`20261118-102557-anomtail-session`).

## Rows left open in anomtable
minuteman, interloper (logged as "not checked", with the reason).
