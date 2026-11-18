# anomcarry: the Abductor carries the car, a thrown item hits a Tourist (W6, 2026-11-18)

Lane `anomcarry`. Files: `mod/PacificTogether/Scripts/anommove.lua` (changed), scenarios `anomcarry` and `anomthrow`.

## Observations (live probe, zone fixture, game MCP, headless pair)
- Abductor (`BP_Hazard_PhysicsGrabber`) hunt, from atlas `bp/BP_Hazard_PhysicsGrabber.txt` and `bp/SM_Hazard_PhysicsGrabber.txt`:
  the Cone's `ComponentBeginOverlap` with the car's chassis (`GetCarActor():K2_GetRootComponent()`, `CanGrabOn` true) sets
  `CurrentPatStealerState` 1. The rest is the Logic Driver machine's calls: 1 `StartMoveToGrabCar` + `TICK_MoveToGrabCar` (flies to the car, sets 2),
  2 `StartStartAttack` (hook on, `OnHazardGrab`, sets 3), 3 `StartAttacking` + `AttackingStateTick` (pulls the car until `EndPull`'s timer sets 0).
  An item (cone overlap with a simulating static mesh) sets state 5 (`StartMoveToOBJ` / `MoveToOBJ_TICK`).
- The machine does not run in a listen session (`NetworkTickConfiguration` 0, like the saw and the garage doors): after the cone event the
  grabber stays in state 1 and drifts over the car for minutes (also a level-placed one: `PhysicsGrabber2` stayed in state 1 for 10 min).
  With the calls made by hand the grabber flew to the car, hooked it and dragged it several thousand uu over ~10 s (car moved 6000 uu in the probe).
- The grabber's actor root is not static while it hunts or patrols: the host's root equals the core position and travels thousands of uu
  (`PhysicsGrabber2` host Y -13001 vs guest copy Y -8101). The guest copy's root does not replicate. anommove matched copies by the root XY
  the host sent, so any grabber that had moved was never matched: no core, magnet or arm updates on the guest. That is the owner's report
  ("stays on the ground"); the earlier scenario only lifted a grabber whose root stayed at its spawn point.
- Item hunt (state 5) driven by hand: `MoveToOBJ_TICK` at 20 Hz did not home in (the core drifted away from the item); not solved.
- Thrown item: `loot.lua` reports a guest drop (an unknown `BP_WorldItem_C` within 500 uu of the guest pawn) with position and linear/angular
  velocity (`drop-velocity`), the host spawns its copy and sets the physics velocity; the guest's copy is then adopted by the host's. The flight
  therefore happens in the host's physics. The Tourist's own hit event only records `KickImpulse` from the angular velocity; the explosion is
  the antenna tilt (25 degrees) in its tick.

## Derived
- Host (`anommove.lua`): grabbers send a stable key (their root at first sight) and the live root; a host driver makes the machine's calls per state
  (car hunts only). Guest: copies are keyed by their root at first sight, the copy's root follows the host's, core and magnet are placed as before.
- Mutations: `noanommove` (driver and sync off), `anomrootkey` (guest matches by the live root again, the old behaviour).

## Unknowns
- Item hunts (state 5) are not driven; a grabber that grabs a loose item or the player does not complete on the host.
- Lift: in the probe the car was dragged along the ground toward the grabber and carried over slopes; not checked whether it leaves the ground.
- The grabber's end state (0 after EndPull) has no driven patrol afterwards.
- The driver would tick twice for a grabber whose machine does run; none was seen to.
- The guest sees the car and the core about 250-450 uu behind the host's while dragged at ~1500 uu/s (10 Hz rows, 0.1 s glide, network).

## Results
See the end of this file.
