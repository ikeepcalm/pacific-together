# anomhit: a guest's kick on a Tourist (W6)

2026-11-18, lane anomhit. Module `mod/PacificTogether/Scripts/anomhit.lua`, scenario `anomhit` (fixture zone), mutation `noanomhit`.

## Observations

- Tourist = `BP_Hazard_Landmine_C`. `StartExplode` is reached by: body tilt >= `AntennaTriggerAngle` (25) in the host's tick (tick only
  awake), `Body` hit events, the tool path `OnTargetHitByAnyTool` and `OnHarvestComplete` (atlas `bp/BP_Hazard_Landmine.txt`).
  The tool path hangs off `AC_HazardInteractionVerbs`, which has `SelfBind=false`/no `TargetActor` on a Tourist: a raw
  `MSG_Damage_Physical_Prybar` dispatched to a Tourist on the host did nothing (probe, live), so tools are not the player-hit path.
- The player's kick is `BP_MainCharacterManager:PlayerKick`: sphere trace 200 uu from the camera, `AddImpulseAtLocation(mass * C_PlayerKickMassMultiplier(mass)
  * forward(camera pitch + 45))` on the hit component, then the Kickable interface's `ObjectKicked(component, impact point, that vector)`.
- On the guest `PlayerKick` runs normally (own manager and pawn) and hits the replicated copy (Role 1): `ObjectKicked` fires there, the impulse
  moves only the guest's copy. Nothing reaches the host.
- Host probe: impulse 14 kg * 248.7 * (0.7,0,0.7) at `TipScene` plus `ObjectKicked` exploded a Tourist (StartExplode, actor destroyed,
  the guest's copy disappears by replication). The same impulse at the body centre only rocked it.
- Names differ between processes (host level-placed: GUID names, guest copies `BP_Hazard_Landmine_C_2147477175`), so the key is class + actor position.
- Run `20261118-091016-anomhit-anomhit`: 21/21; log shows `PT|anomhit kick sent` then `kick applied`, 31 StartExplode calls, copies left 0.
  Mutation `20261118-091536-anomhit-anomhit-noanomhit`: 18/21, fails `host_tourist_exploded`, `guest_copy_gone`, `no_duplicate_after`.

## Derived

- Hook `ObjectKicked` on the guest's Role 1 copy, send `g.anomhit` (class, copy position, kick point, kick vector; protected kind, so held until the
  zone baseline), host checks the guest pawn is within 450 uu of the kick point, finds its Tourist within 250 uu, applies the same impulse and
  `ObjectKicked`. Authority stays on the host; the guest simulates nothing.
- The Shocked Tourist (`BP_Hazard_Landmine_Electric_C`) shares the function, so it is covered but not run.

## Guesses

- A real kick aims where the player looks, usually at the antenna, so tilt past 25 degrees is likely as with the host's own kick; a low or soft kick
  rocks the Tourist without exploding, as it does for the host.

## Unknowns

- Tour Bus (`BP_Hazard_BigBoyLandmine`) and Tourist Trap (`BP_Hazard_Bollard_Explosive`) have no `ObjectKicked`: kicks on them are the generic
  `AddImpulseAtLocation` on the guest's copy only, not forwarded. Thrown items on a Tourist were not tested (the item's physics run on the
  guest's side for its own copy). The rendered key press was not driven: the scenario calls `PlayerKick` itself, aimed at the tip.
- A kick made within the first ~40 s of a zone is held until the baseline and applied late.

## Owner hand-check line

Rendered guest: kick a Tourist with the kick key (and throw an item at one); the host's Tourist must explode and vanish on both screens.
