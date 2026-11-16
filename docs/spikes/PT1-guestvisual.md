# PT1 guestvisual: scrap health, car door/hood and garage door visuals on the guest (2026-11-16)

Scenarios `guestvisual` (`-Fixture gateway`) and `guestgarage` (`-Fixture garage`); mutations `noguestscrapvis`, `nodoorvisual`, `nogaragedoorvisual`.
Results (local/test-results): `20261116-203407-guestvisual-guestvisual` 37/37, `20261116-203016-guestvisual-guestgarage` 24/24;
mutations `...-nodoorvisual` 33/37, `...-noguestscrapvis` 35/37 (one of the two a flaky tween check), `20261116-202811-...-nogaragedoorvisual` 22/24.
Pre-fix baseline (door code unchanged): `20261116-195946-guestvisual-guestvisual-noguestscrapvis`.

## Observations
- Scrap: `guestparts.lua` zeroed the damage and lifted the copy to full health, so the copy stayed at full HP until the host's break removed it.
- Car doors: the host's door-motion rows (20 Hz) already swing the guest's door open (20+ frames). The shut was a snap (3 frames, a 46 degree step) because the rows stop when
  the host's door latches and `applyState` reset the mesh to its rest pose at once. No door sound played on the guest at all (the sounds come from the host's door physics).
- Garage rear door: the guest's `MoveDoorPosition` drive already moves over many frames (the "snap" was not reproduced headless); its start/stop sounds
  (`OnOpeningStart/End`, `OnClosingStart/End` -> `pro_garageDoor_*`) are posted by the state machine that never runs, so it was silent.
- `LoadAsset` of a Wwise event from the door sound path crashed the client (0x18), as did a scenario hook that read the parameters of `BPFL_AudioFunctions:SpawnAndAttachOneShotAkComponent`.

## Derived (the fix)
- guestparts: the copy takes the hit itself, clamped to leave 1 HP; the 200 ms loop lifts it to 1 if a modifier killed it. The host's break still removes it.
- car.lua: a door whose host rows stopped tweens back to rest over 0.3 s; the game's `sfx_car_door_*` events play through `BPFL_AudioFunctions.SpawnAndAttachOneShotAkComponent` when a swing starts (opened thud, 0.4 s later) and when it returns (close thud). Hood uses the trunk event when it is loaded, else the side one.
- garage.lua: the drive calls the door's own start/stop events when the movement starts, reverses and ends (host too).

## Unknowns / gaps
- Sound is proven by the call (hook count in a recording window), not by hearing it. Hood open/shut sound checks do not fail under `nodoorvisual` reliably (other sounds in the window).
- The guest's own hand-opened door (local `AttemptOpen`) was not measured: it goes to the host and returns as rows, so it should look the same; a double thud is possible.
- Real scrapper pressing, MSG_BreakDestructible (hammer on map destructibles) and resource props (`R`) were not driven; resources use the same hook if their health component is a BP_HealthComponent.
- The owner's "garage door snaps" report is not reproduced; a low-FPS guest could still show coarse steps (the drive uses real elapsed time, capped 0.25 s per step).
