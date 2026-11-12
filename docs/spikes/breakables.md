# Breakables (lane breakables, 2026-11-12)

Owner report: driving the host car through small trees or flying rocks breaks them for the host only.

## Observations
- Atlas (`local/atlas/bp/BP_Crash_*.txt`): every destructible derives from `BP_Crash_Base`. `BP_Crash_Simple_Base` (signs, barrels,
  cones, trash bags, `BP_Destruct_Part_FloatingRock`) breaks through `SimpleBreak(Impulse)`; `BP_Crash_Complex_Base` (fences,
  barricades, benches, box piles, foliage `BP_IF_*`) through `ComplexBreak(Impulse, Component)`. Both end in `PostBreakLogic()`.
  Car contact reaches these through `BaseMesh` OnComponentHit (impulse over `DestroyImpactTollerance`).
- Before this lane foliage.lua published only `BP_Crash_Complex_Foliage_Base` (trees/shrubs); every other class was host-only.
- These actors are swapped in from mesh instances near a player (`InstanceSwappableData`): on a guest the actor either does not
  exist or has another name, so path/name identity (first attempt) found nothing: guest saw `StaticFindObject` false for both.
- Road-obstruction rocks (`BP_RoadObstruct_Rock_*`) are `BP_RoadObstructPart_Base`, not breakables: out of scope.
- Calling `GetPhysicsLinearVelocity` 150 ms after a SimpleBreak crashed the host (null body, access violation 0x70, not catchable by
  pcall). `GetComponentVelocity` is safe.

## Derived
- Same identity as foliage works: swappable-instance mesh + position. Host hook `PostBreakLogic` now covers all `BP_Crash_Base`.
- Simple props are sent as `g.foliage.crash` (row + kind + host velocity 150 ms after break); the guest runs the existing foliage
  apply path (matching swapped actor -> `SimpleBreak`/`ComplexBreak`, else remove the mesh instance), then sets the host's
  velocity on a simple prop so a knocked/flying rock or sign travels roughly like on the host.
- Cheapest approach for flying props: replay the break locally with the host's velocity, no per-frame transform sync. The guest's
  physics after that is its own (a prop can land elsewhere); rare and cosmetic.
- Reuses capability "foliage"; older guests ignore the new kind.

## Guesses / Unknowns
- Not driven with a real car: the scenario calls SimpleBreak/ComplexBreak on host actors (same `PostBreakLogic` path the hit takes).
  The owner should drive through a sign, a fence and a floating rock on a host+guest pair.
- Break impulse is not sent for complex props (debris falls in place on the guest).
- Pending jobs retry for up to five minutes (shared with foliage); streamed-out props are matched when they swap in.

## Results
- carbreak 19/19: `local/test-results/20261112-173414-breakables-carbreak`.
- visual.lua already mirrors `BP_Destruct_*` breaks (br=1) but from its 5 s sweep, about 5-11 s late and without velocity; carbreak
  asserts a break within 4 s / 6 s, and the `nocarbreak` mutation fails both checks (18/20, `...-breakables-carbreak-nocarbreak`).
- Reruns: foliage 20/20 (`20261112-174544-breakables-foliage`), session 40/40 (`20261112-174924-breakables-session`), visual -Fixture zone
  27/29 (`20261112-180134-breakables-visual`): guest_door_follows_host also failed in 20261108 runs before this lane; the other
  failure is "RegisterHook BP_Panel_Base:AttemptShut is not loaded" (car.lua, not touched here).
