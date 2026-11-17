# anomwake: hazards near the guest act on the guest while the host is far (W6/W8)

2026-11-17, lane `anomwake`. Code: `anomalies3.lua` (bunny range hook added), scenario `anomwake` (fixture `zone`), mutation `noanomtesla` (switches the wake + range hooks off).

## Observations

- Most of the lane was already built by `pt3-anom` (see [PT3-anom.md](PT3-anom.md)): the generic wake of every `ManagedTickComponent` hazard within its own `MaxTickDistance` of a guest pawn, and the post-hook on `BP_HazardProperty_PlayerRange:DistanceToPlayer` (Landmine, Bollard, Grabber, Part Stealer's PlayerRange).
- Atlas: the Part Stealer's `IsPlayerInRange` is an empty delegate stub; it uses the `BP_HazardProperty_PlayerRange` component, so it was covered. The Pickpocket's actual theft on the guest is host-side proximity (anomalies3.lua, 1200 uu).
- Still host-only before this lane: `BP_Boon_LootCreature:IsPlayerInRange` (flat distance from `GetPlayerCameraManager(0)` and the car), also `BP_Hazard_Blackhole` and `BP_Hazard_BulletHell` (`IsPlayerInRange`, VSize to the host's player), and `GetPlayerPawn(0)` users: Landmine creep, BouncePad, NudgePad, SpikeBush, SpikeStrip.
- Run `20261117-103308-anomwake-anomwake` (22/22): guest teleported next to a map Tesla, host 44110 uu away and awake. Guest hp drops (Tesla), host hp stays; bunny and Part Stealer spawned next to the guest: the stealer takes a backpack item; the bunny's `IsPlayerInRange(1500)` called from Lua reports `in=true dist=500` with the hook (and `in=false dist=43907` before the hook registered in the same run).
- Mutation `noanomtesla`: `20261117-103906-anomwake-anomwake-noanomtesla` 20/22, fails `guest_hurt_by_tesla` and `bunny_notices_guest`.

## Derived

- `anomalies3.lua`: post-hook on `BP_Boon_LootCreature:IsPlayerInRange` (host): if a guest's flat distance to the creature is within `Distance` and the game's own result was false, set `PlayerInRange` true and `playerDistance` to it.

## Guesses

- The first run of the scenario (before the hook existed) failed host hp once (97 vs 100): the known transient from anomalies.lua's put-back sampling; not reproduced in the next runs (22/22).

## Unknowns

- The bunny hook is proven on a Lua call of `IsPlayerInRange`. Whether the game's own Blueprint-internal call inside the tick goes through the hook (hooks on `Discharge` never fired for BP-internal calls) is not shown: the bunny stayed in `Current State` 1 in the headless run, with or without the hook, so there is no behaviour check on the push or jump. The push damage/impulse path (`PushFx` hook) is unchanged and proven separately by `anomalies3`.
- Blackhole, BulletHell, BouncePad, NudgePad, SpikeBush/Strip and Landmine creep still act on the host only (not common in a normal run; the Tesla/landmine/grabber/stealer/bunny set covers the usual encounters).
- Hand test: split the players by more than ~5000 uu, walk the guest into a Spark Tower, a Part Stealer and a bunny.
