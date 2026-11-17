# anomwake2: spike strip, spike bush and bounce pad act on a guest far from the host

2026-11-17, lane `anomwake2` (follow-up of [anomwake](anomwake.md)). Code: `anomalies3.lua` (bounce pad hook, mutation switch), scenario `anomwake2` (fixture `zone`), mutation `noanomwake2` (switches the wake, range and bounce hooks off).

## Observations

- Atlas (`BP_Hazard_SpikeStrip`, `BP_Hazard_SpikeBush`): both are `BP_HazardProperty_PlayerRange` hazards. `OnPlayerInRange` starts a 0.2 s timer (`DamagePlayer`) that dispatches `MSG_Damage_Physical_Piercing` with `DispatchMessageInSphere` (tag filter [2], radius of the hazard's sphere): any pawn with that tag in the sphere is hit, not only `GetPlayerPawn(0)`. `GetPlayerPawn(0)` appears only in the wheel-damage branch (it is the ignore list there).
- So the spikes needed nothing new: the earlier lanes' wake (ManagedTick) plus the `PlayerRange:DistanceToPlayer` hook already arm them for a lone guest, and anomalies.lua forwards the damage. Measured: a strip and a bush spawned at the guest's feet with the host 44000 uu away both hurt the guest (strip 100 to under 99, bush 52 to 40 in the first baseline run) and not the host (`guest_hurt_by_spikestrip`, `guest_hurt_by_spikebush`, `host_not_hurt_*`). First seconds show the wake delay (hp unchanged for 3-4 polls).
- `BP_Hazard_BouncePad`: the box's begin-overlap sets `OverlappingCmp`; the owner is compared with `BP_MainCharacterManager:GetCharacterActor()` (the host's own character). Only that one gets `Impulse Player` (zero vertical velocity, `AddImpulse(up * LaunchPlayerImpulseAmount, true)` on its CharacterMovement); any other overlapper must be physics-simulating (`ImpulseOther`). A guest pawn is neither, so a guest standing on a pad was never launched (baseline: max height over rest = 0). `GetPlayerPawn(0)` there is only the fade distance of the geyser column visual.
- A hook on `Impulse Player` would never fire for a guest. Hook that fires: `BndEvt__Box_K2Node_ComponentBoundEvent_0_ComponentBeginOverlapSignature__DelegateSignature` (host).
- Launching only on the guest (`g.anom3.bounce`) lifted it about 35-100 uu and the host then set it back (server replay of the guest's moves has no impulse, the host's correction wins). Applying the same zero-Z-velocity plus `AddImpulse` to the host's copy of the guest's CharacterMovement as well made the launch stick (scenario: the guest's peak rises well above its rest height; an earlier run with the guest-only launch showed +34 uu, which the test now rejects at +60).
- Mutation `noanomwake2`: only `guest_launched_by_bouncepad` fails (21/22). The strip and bush checks still pass with the wake and range hooks off, so they are regression checks, not proof of those hooks (the zone fixture's guest apparently arms them through its own copy of the hazard or the pad range already; not isolated).
- Pad impulse value in the zone fixture: `LaunchPlayerImpulseAmount` 1000, movement mode of the guest before the launch: walking (1).

## Derived

- `anomalies3.lua`: host hook on the pad's begin-overlap; if the overlapping actor is a guest pawn (and the pad's per-guest 1.5 s cooldown has run), the host applies the pad's impulse to its copy of the pawn and sends `g.anom3.bounce` (`ux uy uz amount`); the guest zeroes its vertical velocity and adds the impulse. The cooldown replaces the pad's own re-arm delay (`ReArmTimerOnPlayerLaunch`, not read).
- `M.fix` is now also off for `PT_MUTATE=noanomwake2` (wake, range, bounce).

## Guesses

- Landmine: the hazard's creep and anything else using `GetPlayerPawn(0)` keep targeting the host, as in anomwake. Not touched.
- The hook is registered when the class is loaded (retry every 2 s); the zone fixture's map loads it with the level, so a pad that a guest touches in the first 2 s after its class loads is missed. A scenario that spawns the class itself must `LoadAsset` it first (it does).

## Unknowns

- NudgePad (`GetPlayerPawn(0)` at the nudge direction, `ImpulseHelper` smart launch to `ActorTags.Hazard.Anomaly`), Blackhole and BulletHell (their own `IsPlayerInRange`, VSize to the host's player) not done: no pad of those in the zone fixture, and the actor counts of those maps were not queried (no `find` over the other zones in this lane).
- Visual of the geyser column on the guest (its own copy of the pad animates, the fade distance uses the guest's own pawn there) not looked at: headless.
- Hand test: split the players by more than ~5000 uu and walk the guest over a bounce pad, a spike strip and a spike bush.

## Runs (local/test-results)

- `20261117-114342-anomwake2-anomwake2` 22/22; mutation `noanomwake2` `20261117-114806-anomwake2-anomwake2-noanomwake2` 21/22 (fails `guest_launched_by_bouncepad`).
- Before the hook (`20261117-111106-anomwake2-anomwake2`): bounce pad did nothing for the guest; strip and bush already hurt it.
- Regression: session 40/40 `20261117-115406-anomwake2-session`; anomwake 22/22 `20261117-115525-anomwake2-anomwake`; anomalies3 25/26 `20261117-121859-anomwake2-anomalies3` (`guest_pushed_by_bunny` fails the same way on main: 25/26 in the anomwake lane run `20261117-104335` and since 2026-10-25).
