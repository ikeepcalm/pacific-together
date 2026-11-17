# PT1 anom3: Spark Tower, Pickpocket, Bunnies on the guest (W6)

> Historical research; see the [index](README.md) for current implementation and later evidence.

2026-10-22, lane `pt1-anom3`. Module `mod/PacificTogether/Scripts/anomalies3.lua` (+ "anomalies3" in FEATURES), scenario `anomalies3` (fixture `zone`, mutation `noanom3`).

## Observations

- Not in this build (atlas class list `Gameplay/Hazards`, `Gameplay/Boons`; confirms `M5-anomalies2.md`): **Abductor**, **Can Opener**. The wiki names map to
  classes: Pickpocket = `BP_Hazard_PartStealer` (flying), Spark Tower = `BP_Hazard_Tesla` (`TeslaAnomaly`), Bunnies = `BP_Boon_LootCreature` (ChubbyBunny boon).
- Pickpocket in the game's code (atlas `BP_Hazard_PartStealer`): it takes car parts (`GrabCarPart` -> `CarManager:PopOffPartFromCar`, already mirrored by car.lua) AND
  reaches for the player: `CanReachForPlayer` needs the host's player on foot (`PlayerCarState == 0`) within 1500 uu of `MainTendrilConstraint` and in LOS of the host's
  camera (`GetPlayerCameraManager(0)`); it then hits (`HitPlayerDamage`: MSG_Damage_Physical_Impact 3 on `BP_MainCharacterManager.CharacterActor`) and takes a random item of
  `BP_InventoryManager:GetPlayerInventory` (`Spawn Item In World` at the reach spot, `GrabCarPart(item, true)`). Everything uses the host's character and inventory:
  a guest is never reached and never loses an item.
- Spark Tower: `FindTarget` uses an `ActorTagQuery` for `ActorTags.Character.MainPlayer` / car chassis in its AoE, the discharge is `DispatchMessageInSphere(MSG_Damage_Electrical, End, 300)`,
  which anomalies.lua already forwards when it hits a guest's pawn. A Tesla spawned at run time on the host was NOT replicated to the guest (run 20261022-014946: nearest Tesla on the
  guest 44171 uu away, `RemoteRole 0`, `bReplicates false` right after spawn): it is not handled by world.lua's list in practice for run-time spawns.
- Bunny: `PushFx` (called when a player touches the creature) fires a radial force (`PlayerPusher`, `Radius`, `ImpulseStrength` from tuning) and MSG_Damage_Physical_Impact `PushDamage`
  at the host's character only. The guest's copy exists (Role 1) and a push of the host's character did not reach the guest. With the hook a guest within the radius takes the
  damage (forwarded by anomalies.lua, host not hurt) and `g.anom3.push` (`20261022-014946`: guest_hurt_by_bunny, host_not_hurt pass).
- A Part Stealer spawned at the car went to State 5 (car slot) and did not take a part in 120 s (headless zone fixture): not guest related, not investigated.

## Derived (what is built)

- Replication loop for spawned Tesla / Part Stealer / Loot Creature (host, 1 s, same as anomalies2 for item hazards).
- Pickpocket for the guest: every 250 ms the host checks each Part Stealer (not reaching/holding: State not 1/3/4, 25 s... 8 s retry) for a guest pawn within 1200 uu; it sends
  `g.anom3.steal`; the guest declines when in the car or with an empty backpack, otherwise hurts itself 3, removes one random backpack item (`RemoveItemsOfType`) and answers
  `g.anom3.stolen <stealer>\t<archetype>`; the host spawns the item at the guest (`InventorySystem:SpawnItemActor`) and has the stealer take it (`GrabCarPart(item, true)`)
  unless it already holds something.
- Bunny: hook on `PushFx` (host): a guest pawn inside `PlayerPusher.Radius` takes `PushDamage` (tuning read through `TuningFloatLibrary:Conv_TuningFloatToFloat`) and gets `g.anom3.push`;
  the guest applies a velocity impulse away from the creature.

## Checks (scenario `anomalies3`, fixture zone, mutation `noanom3`)

`guest_has_map_teslas`, `guest_has_items`, `guest_sees_stealer`, `guest_item_stolen`, `pickpocket_hurt_guest`, `stealer_holds_item`, `guest_sees_bunny`, `guest_hurt_by_bunny`,
`guest_pushed_by_bunny`, `host_not_hurt_by_bunny_on_guest`. Mutation `noanom3` switches the module off in both processes: it fails the pickpocket and bunny checks
(run `20261022-030909-pt1-anom3-anomalies3-noanom3`: 20/27 with the earlier scenario).

Runs (local/test-results): `20261022-014946` first run 20/24 (before the fixes), `20261022-025820` 20/27, `20261022-030440` 23/27, `20261022-031643` 25/27 (pickpocket and
bunny all pass), `20261022-032241` 26/27 (only the Tesla firing check failed), `20261022-032723` and `20261022-035511` crashed the host (Tesla experiments, see below).

## Guesses

- Level Teslas are dormant while the host is far away (a `ManagedTick` component, `OnTickChanged`): with the guest 44000 uu from the nearest Tesla and the host elsewhere nothing fired (90 s).
  Not verified.
- A discharge at the position of the guest would be forwarded by anomalies.lua like any `DispatchMessageInSphere` damage; the Tesla chose the host (`FindTarget` takes the first actor with the highest tag priority).

## Unknowns at the time

- **Spark Tower firing at the guest is not proven.** A map Tesla moved next to the players (`K2_SetActorLocation`) fired within seconds: host hp 100 -> 1 -> 20, the guest stayed at 100
  for the 5 s seen, then the headless host crashed (access violation, `crash-host-UE4CC...` in `20261022-035511`: most likely the host reaching 0 hp). Teleporting the host 44000 uu to a
  Tesla (`K2_TeleportTo` on the host character) also crashed it (`20261022-032723`). A clean proof needs the host out of the Tesla`s reach but awake (or `PlayerProtected`/health restore each second) and
  the guest in its AoE; run-time spawned Teslas destroy themselves at once, so use a map Tesla.
- Hazards are driven by the HOST character (`PlayerRange`, `ManagedTick`, `CanReachForPlayer`): a guest far from the host (> the hazard's range) gets no pickpocket or Tesla.
- Pickpocket for the guest is host-side proximity (1200 uu, no LOS, state not 1/3/4), not the game's own reach animation: the stealer does not reach out to the guest, the item
  just appears in its grab. The guest's held item is not taken (the game's own held-item branch is `Bool(0)`, i.e. off). Car-part theft: unchanged (car.lua mirrors PopOffPartFromCar).
- A Part Stealer spawned at the car stayed in State 5 for 120 s without taking a part (not guest related).
- Bunny push: velocity impulse is a guess (`strength / 100` clamped 300..1200, + 200 up), `PushDamage` read from the tuning (1.0 in the run) and `PlayerPusher.Radius` 1500, `ImpulseStrength` 1000 in the run.
  The bunny only wakes by the host's distance (`IsPlayerInRange`); the test calls `PushFx` directly on the host instead of walking the guest into the creature.
- Abductor and Can Opener do not exist in this build's classes.
- Final runs: normal 25/26 (20261022-040137, only guest_pushed_by_bunny failed: the guest's peak speed check is timing-flaky, it passed in 20261022-032241), noanom3 21/26 (20261022-040447: fails the 5 pickpocket and bunny checks).

## 2026-11-17 lane bunnypush: guest_pushed_by_bunny

- Observation: the push is real. Guest log after `g.anom3.push`: 1054 uu/s at once, 591 -> 116 uu/s over ~0.4 s (run `20261117-122729-bunnypush-anomalies3`).
- Derived: the check was wrong. The guest reports its 50 ms peak once per second; the report with the peak could arrive while the earlier `guest_hurt_by_bunny` check polled, and the old check only read the latest report. `maxSpd` is now updated in `poll()`.
- The scenario also called `PlayerPusher:FireImpulse()` itself; with `noanom3` that alone pushed the guest to 791 uu/s, so the mutation did not fail the check. Removed it (PushFx alone: guest peak 276 uu/s horizontal, 0 with `noanom3`).
- Runs: 3x 26/26 (`20261117-125636`, `-125808`, `-125936`), `noanom3` 21/26 incl. guest_pushed_by_bunny (`20261117-125513-...-noanom3`).
