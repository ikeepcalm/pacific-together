# anomrest: Minuteman and Meteorite Squall (W6, 0.9.6-dev)

Lane `anomrest`, module `mod/PacificTogether/Scripts/anomrest.lua`, scenario `anomtable` (rows `minuteman`, `meteor`).

## Observations
- Minuteman (`BP_Hazard_Movement_Prong`), hand-spawned by the scenario on the host, logged on both sides every 200 ms
  (`20261118-122551-anomrest-anomtable`, probe build): the HOST actor rises (Cylinder z -200 to 5 in 1 s, RiseTimeline), stands, retracts
  (`Retracting` true, RetractTimeline, z back to -200) and is destroyed, 4.2 s after its own first sight. TimeActive is 0.0 and
  DelayBeforeRetract 2.0 on a spawned one. The guest's copy appeared about 1 s after the host's spawn (the 1 s sweep) and was gone
  3.2 s after ITS first sight: the same moment. The earlier note "host actor stays ~23 s" was a mistake of the scenario (it only looked
  again later and printed "gone").
- The guest's copy never ran the rise: Cylinder z stayed -200 for its whole life, RiseTimeline never played (tick off, `Retracting` false,
  nothing in the BP chain started on the copy). So the Minuteman was under the ground, invisible, for the guest.
- Setting TimeActive and DelayBeforeRetract to 1e6, `Retracting` true, destroying the Conductive component or ConductiveDistance 0 on
  the copy changed nothing (`20261118-120853`, `-121050`): the copy's death is the host's destroy, replicated.
- Meteorite Squall: `GEV_Asteroid` spawns `BP_AsteroidEventLogic` (host), which spawns `BP_Hazard_FallingPillar` (the pillars, row
  `fallenfirmament`) and `BP_Hazard_FallingPillarChunk` (the meteors; also `BP_ModifierActor_RandomAsteroid` and
  `BP_HazardProerty_Asteroids` spawn chunks). A chunk is a `BP_Base_Hazard` child: spawned at the ground spot (property `HitGroundLoc`), its
  `Chunk` component falls 22000 uu in about 1 s (CrashTimeline), the actor lies about 7 s (radiation volume), then destroys itself.
  `world.lua`'s sweep replicates it; the guest copy plays its own whole fall from ITS first sight (`20261118-121745`, both sides logged), so
  with the 1 s sweep the guest saw the meteor land about a second after the host.
- A chunk destroyed early (the scenario's old end-of-row destroy) leaves its radiation influence on, hurting the host for the rest of the
  run; a chunk left to end by itself still lowered the host by about 35 hp with the guest 6000+ uu away (`20261118-122005`).

## Derived
- Minuteman: nothing destroys the copy but the host's own cycle. The fixes are visibility (put the Cylinder up on the copy) and timing.
- Both: replicating from `ReceiveBeginPlay` (as the lightning strike and the acid glob) puts the copy within a frame or two of the host's.
  Meteor: first copy seen at age 0.00 s with the module, 1.05 s without.

## Changes
- `anomrest.lua`: host replicates `BP_Hazard_FallingPillarChunk` and `BP_Hazard_Movement_Prong` as they begin play; the guest sets the prong's
  Cylinder to `RandomHeight` (5) 0.3 s after the copy begins play (Role 1 only). Mutation `noanomrest` switches it off.
- `anomtable.lua`: rows `minuteman` (now checked) and `meteor`; row fields 7 (a function setting properties before the spawn finishes:
  `HitGroundLoc`), 8 (first copy seen within N s of the spawn) and 9 (the prong must be up, Cylinder z above N); the guest reports
  the age and the highest Cylinder z of its first sighting. A meteor row is not destroyed by the scenario (see above) and the host
  is refilled after it.
- `main.lua`: `anomrest` added to FEATURES.

## Guesses
- The guest copy's own BP chain (Delay, Rise) does not start on a replicated Prong; the cause was not found (the copy's `ReceiveBeginPlay` runs).
  The copy shows a prong standing up from the start instead of the 1 s rise animation, and it vanishes at the end of the host's retract
  instead of sinking (no retract signal reaches the guest).
- A real squall's meteors fall around the host's car; the host hurt by a meteor far from it is the radiation volume being measured at the
  wrong player, not checked further.

## Unknowns
- Whether level-placed Minutemen (TimeActive longer, cycling) behave like the spawned one; the visuals (the standing prong) need a rendered look.
- The radiation of a meteor next to the guest hurts the host (35 hp in the test): does the guest take it too (radiation.lua mirrors volumes)?

## Results (worktree C:\PTLanes\wt-anomrest, pair C:\PTLanes\anomrest)
- Row `minuteman`: pass with the module (`20261118-122759-anomrest-anomtable`, age 0.00, maxz 5), fails with `noanomrest`
  (`20261118-122947-anomrest-anomtable-noanomrest`, age 1.01, maxz -200).
- Row `meteor`: pass (`20261118-122348-anomrest-anomtable`, with the host refill), fails with `noanomrest` (age 1.05,
  `20261118-122200-anomrest-anomtable-noanomrest`; that run also failed the host-health check, before the refill was added).
- Final: full anomtable 65/65 (`20261118-124155-anomrest-anomtable`), session 40/40 (`20261118-124501-anomrest-session`).
