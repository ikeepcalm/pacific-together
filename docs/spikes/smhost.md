# smhost: hazard state machines frozen on a listen host (W6, 2026-11-18)

Question: which Logic Driver machines are frozen on a listen host, and is there one generic fix instead of a driver per hazard?

## Observations (live probes, zone fixture, game MCP, headless, 2026-11-18)

- Every hazard machine is an `SMStateMachineComponent`; its instance (`R_Instance`, a `USMInstance`) carries three bits:
  `bCanEvaluateTransitionsLocally`, `bCanTakeTransitionsLocally`, `bCanExecuteStateLogic` (all default true, `SMInstance.cpp` dump).
- Standalone: all three true, `NetworkInterface` invalid. Listen host (same classes, same spot, mod's smhost off): `bCanEvaluateTransitionsLocally`
  is **false**, `NetworkInterface` is set, `component:IsConfiguredForNetworking()` is true, `HasAuthority()` true. The instance still ticks
  (`SMInstance:Tick` every frame, `WorldSeconds` advances) but takes no transition.
- Forcing the bit to true on the running instance does not make the machine move (saw stayed IDLE); only the instance's network state
  matters, not the bit alone.
- Not the configuration: the saw's component has `NetworkTickConfiguration` / `NetworkTransitionConfiguration` 0 (Client). Setting both to 2
  (or 1) in the class template before spawning, or on the component and `Restart()` (which re-uses the instance, so the bits are stale), left
  the bit false.
- Not the BP: `c:SetIsReplicated(false)` makes `IsConfiguredForNetworking()` false. With the template's `bReplicates = false` the next spawned
  saw had the bit true from the start and ran its cycle (IDLE, PreMove, Move) on the listen host. On a live instance the same needs a fresh
  instance: `bReuseInstanceAfterShutdown = false`, `Shutdown()`, `Initialize(owner)`, then `Start()` + `SetCanEverTick` / `SetTickInterval` copied
  from the old instance (the saw's BP calls those once when a player comes in range).
- Level-placed hazards are the same (6 `BP_Hazard_Bollard` in the zone: states followed after the fix).

### Active state names, 30 s, player within 1500 uu, one of each class spawned next to the pawn

(`!ev` = `bCanEvaluateTransitionsLocally` false; `@n` = first sampled n seconds after spawn)

| Class (logbook name) | Listen, no fix | Standalone | Listen, smhost fix |
|---|---|---|---|
| Blacksmith `BP_Hazard_RockPounder` | Pre-Rise!ev | Pre-Rise > Rise@4 | Pre-Rise > Rise@4 |
| Sick Mickey `BP_Hazard_LargeGeyser` | Dorment!ev | Dorment | Dorment |
| Titan's Bone `BP_Hazard_ImpactSpear` | Pre-Rise!ev | Rise > Pre-Retract@2 > Retract@4 | Rise > Pre-Retract@2 > Retract@4 |
| Wriggling Wreck `BP_Hazard_MovementHazard` | Idle!ev | CheckForFire | CheckForFire |
| Bubblegum Buddy `BP_Hazard_Spore` | Inactive!ev | Inactive > Investigate@2 > Idle@4 | Inactive > Idle@2 > Investigate@3 |
| Ticking Tumbler `BP_Hazard_BombRock` | INACTIVE!ev | INACTIVE > Rolling@4 | INACTIVE > Rolling@3 |
| Bollard `BP_Hazard_Bollard` | RangeCheck!ev (state entered by the BP, then stuck) | RangeCheck@4 > Underground@5 | RangeCheck@4 > Underground@5 |
| Pufferfish `BP_Boon_LootCreature` | INACTIVE!ev | Alert | Alert |
| Can Opener `BP_Hazard_SawBlade` | IDLE!ev (never PreMove) | PreMove@2 > Move@5 | PreMove@2 > Move@5 |

Sick Mickey and Wriggling Wreck sit in their first state in all three columns within 30 s (they wait for their own timers or a car);
only "same as standalone" is claimed for them, not that they erupt.

## Derived

- All listen-host machines of these classes are frozen in the same way, so a generic fix exists: take the component out of the
  engine's networked mode on the host. It is not a per-hazard driver.
- It is host-only by construction (the poll runs where `netMode == "listen"`). The guest's components are untouched (its copies keep their
  own configuration, W2).
- The states are not replicated to the guest any more (the component no longer replicates). Before, they did not move anyway.

## Implementation: `mod/PacificTogether/Scripts/smhost.lua` (FEATURES "smhost")

- Every 500 ms on a listening host: each `SMStateMachineComponent` not seen yet whose owner class starts with `BP_Hazard_` / `BP_Boon_`
  and that reports `IsConfiguredForNetworking()` gets the fix above. `BP_Hazard_PhysicsGrabber` is skipped (it ticks by itself and
  `anommove.lua` drives its calls; a second tick would double them).
- A host listening alone gets it too: vanilla single player ran these machines (Q7 is about what the mod adds).
- Mutation `nosmhost` switches the module off.

## Guesses

- The garage door machines (PT1-garage.md) probably have the same cause (the config fix "did not hold"; the replication bit was never tried).
  Not touched here: `garage.lua` drives the doors itself.
- With the generic fix the saw driver in `anommove.lua` (the 2.5 s stall push) should never fire. The lead decides whether to remove it.

## Unknowns

- `NetworkInterface` after the fix was not read directly (the property read through Lua returns a wrapper).
- Other machines (Swarmers, RockFlinger, Surge Tower, Crawling, ElectricFence, Leech) were not measured; the poll fixes them if their owner
  class starts with `BP_Hazard_` (Surge Tower and ElectricFence may not).
- Reinitialising a machine that was already mid-cycle restarts it; the poll sees most components before a player is in range.

## Results

Pair C:\PTLanes\smhost, port 7887, headless, zone fixture.
- `smhost` 24/24 (first run 23/24: the Pufferfish check wanted a second state; it only reaches Alert, fixed to "Alert seen"):
  `20261118-113840-smhost-smhost`. Per class `sm_<class>_runs` passes for Blacksmith, Titan's Bone, Bubblegum Buddy, Ticking Tumbler,
  Bollard, Pufferfish, Can Opener (saw: IDLE, PreMove, Move, EndMove all seen); the guest's saw copy follows (anommove sync).
- Mutation `nosmhost` 17/24: all 7 `sm_*_runs` fail, `guest_saw_copy_follows` still passes (the saw driver in `anommove.lua` pushes
  the blade by hand when the machine stands still): `20261118-114646-smhost-smhost-nosmhost`.
- Blacksmith on the guest: the copy's `Cylinder` stayed at z 0 with no machine state on the guest (info line only); the effect of
  the Blacksmith/Titan's Bone/etc. on the guest is not synced by this lane (their damage reaches the guest through the existing paths).
- With smhost on: `session` 40/40 `20261118-115000-smhost-session`, `anommove` 22/22 `20261118-115125-smhost-anommove`, `anomcarry` 20/20 `20261118-115233-smhost-anomcarry`.
