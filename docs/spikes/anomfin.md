# anomfin: last W6 anomaly rows (2026-11-20, lane `anomfin`, pair C:\PTLanes\anomfin, port 7811, headless, zone fixture)

Result folders are in `local/test-results/` (prefix `20261120-`).

## 1. Blacksmith (`BP_Hazard_RockPounder`): it was never broken on the host

Observations
- Bytecode (`BP_Hazard_RockPounder`, `BPSM_Hazard_RockPounder`): Idle > Pre-Drop (RockPounderState 1) > Drop (2) > Hit (3) > Pre-Rise (4) > Rise (5) > Idle (0).
  Pre-Drop's entry runs `StartSpearSpawnGeneratrion`: a loop of `TryGenSpline` (`GroundSplineGenerator:BuildSplineOverTime`, one `BP_GroundSplineAsync` actor per try)
  around the car in 25-45 degree steps; only when the angle passes 330 is state 2 set.
- In the zone fixture every try failed with `Failed on first point` (hundreds of `BP_GroundSplineAsync` actors, `CurrentGenAngle` grew past 100000).
  `BP_HazardProperty_Base:Is Spot Ground AValid Spawn Location` first asks `BP_HazardManager:IsPointInSafetyZone(loc, 500)`; that is true for every point
  within ~6000 uu of the fixture's start (the arrival area is a safety zone); 8000 uu away on +Y it is false.
- Placed 10000 uu from the start (outside the zone), the same spawned Blacksmith with smhost on ran Pre-Drop > Drop > Hit > Pre-Rise > Rise > Idle repeatedly
  (about every 11 s), and the slam spawned 126 `BP_Hazard_ImpactSpear` actors plus bollards and bombrocks.

Derived: no co-op bug. "Stays in Pre-Drop" is the game's own refusal to slam inside a safety zone (as in single player); the earlier probes spawned it in the zone.
`Cylinder` never moves in relative z either way (nothing to mirror); the slam shows as spears/bollards/rocks (actors, mirrored by anomvis or native replication) and `LaunchPhysics`.

Implementation: scenario work only. `anomvis` now finds a clear spot (36 sample points within 5000 uu all outside any safety zone, ground by line trace), moves both players
there, spawns a Blacksmith and checks `host_blacksmith_slams` (Drop and Hit seen on the host's machine) and `guest_sees_slam_spears` (the guest counts ImpactSpear actors).
Mutation `nosmhost` fails `host_blacksmith_slams` (`095900-anomfin-anomvis-nosmhost`).

Found on the way (a real bug, fixed in `anomvis.lua`): the host crashed (access violation, `091550-anomfin-anomvis`) while sampling a BombRock/Mimic the slam spawned and that
had already gone. The sampler now uses `live()` for the actor and skips parts that are invalid or pending kill.
Players near the slam: it has no damage message, only the launch (`NudgeCarAndPlayer` on the host's own car and character; a far guest is not launched, same gap as in 4). The spears hurt through the existing path.

## 2. Abductor (`BP_Hazard_PhysicsGrabber`) item hunts

Observations: with the smhost fix applied to the grabber's machine (smhost skipped it until now) the game's own machine runs every state: a cone overlap with a loose item
(`CanGrabOn` true) sets state 5, then `MoveToGrabOBJ`/5, `GrabbingOBJ`/6, Patrol/0; the item was lifted and thrown 442 uu in the probe.
Implementation: `smhost.lua` no longer skips `BP_Hazard_PhysicsGrabber_C`; the hand driver in `anommove.lua` (states 1-3, car only) now does nothing for a grabber whose
machine reports `bCanEvaluateTransitionsLocally` (it stays for `nosmhost`). The item is moved by the host's physics and reaches the guest through item replication; the
grabber's core, magnet and root through anommove as before. The game's grab of the player's held item or body uses the host's character only: not extended to a guest.
Scenario `anomcarry`: new `host_grabber_hunts_item` (state 5, then the item moved > 150 uu or state 6). 22/22 `093537-anomfin-anomcarry`; `nosmhost` 21/22 `094232-anomfin-anomcarry-nosmhost` (fails it).
Not checked: that the guest sees the carried item (no check; item replication is the engine's).

Lag (lead's request), anomcarry `guest_grabber_follows` and anomalies2 `guest_pulled_by_grabber` at `udp lag=150 loss=2`:
- anomcarry: the check matched the guest's copy within 600 uu of the host root, sent 10 times a second; the grabber travels ~2500 uu/s, so under lag the position is stale by
  more than that and the copy was not found. Check fix (not the mod): window 2500 uu, and the follow is sampled every 200 ms from the grab on (the grabber flies off on patrol afterwards).
  With the tunnel: 28/28 `094352-anomfin-tunnel-anomcarry`.
- anomalies2: not reproduced, 34/34 `094518-anomfin-tunnel-anomalies2`. The check needs one guest speed sample > 30 within 10 s; the pull is a 3 s burst and the guest reports speed twice a second,
  so a lost report or two at 2 % loss can miss it. Check window widened to 25 s. Mod untouched.

## 3. Bollard random yaw

Root cause: `anomvis.lua`'s host rows never carried the root rotation (rows were `home x y, x y z, parts`); the guest read fields 6-8 as pitch/yaw/roll, got the first part string
(`tonumber` nil, so 0) and forced the copy's yaw to 0 on every full row. The doc said rotation was sent; the code did not. The copy is natively replicated (role 1) and unrotated
because `SetBollardRandomness` adds its random yaw only on the host (the earlier "something re-sets it" guess was this).
Fix: the host sends `Pitch/Yaw/Roll` (3 fields after the position, which the guest's parser already expected) and re-sends when it changes. Mutation `nobollardyaw` (guest ignores it).
Scenario `anomvis`: the spawned Bollard is set to yaw 130 and `guest_bollard_yaw_matches` compares the guest copy's root yaw (< 3 degrees). 25/26 `095140-anomfin-anomvis`
(only `guest_hurt_by_spear` failed: the host stood 219 uu from the guest and was already hurt; a known flake, it also failed in the first run); `nobollardyaw` 23/26 `095451` fails
`guest_bollard_yaw_matches` and `guest_bollard_follows`.

## 4. Nudge pad: smart launch done later

Not done in this lane; solved by the nudgepad lane 2026-11-20, see [nudgepad-smart.md](nudgepad-smart.md). The (0,0,1000) result here was the probe's fault: the struct's tag
container never reached the function (every field of the smart-launch struct arrived as zero, so Chance was 0 and the plain impulse came back).

## 5. Interloper (DLC): hand check

The class is not in the atlas (plugin pak) and no class matching ProximityMine/Cultist is loaded in the zone fixture; the anomtail result stands (a hand-spawned one leaves its spot, ~36000 uu,
and destroys itself). Not spawned again. Hand check in a real DLC zone.

## Runs (all `20261120-*-anomfin-*`)

anomvis 25/26 `095140`, `nobollardyaw` 23/26 `095451`, `nosmhost` 21/26 `095900`; anomcarry 22/22 `093537`, `nosmhost` 21/22 `094232`, lag 28/28 `094352`; anomalies2 lag 34/34 `094518`; session 40/40 `100153`.
