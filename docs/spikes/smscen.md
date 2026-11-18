# smscen: old anomaly scenarios that assumed frozen hazards (W6, 2026-11-18)

## Observations
- After smhost (host Logic Driver machines run in a listen session) a Leech / Tumbler / Pufferfish placed next to the guest also acts on a HOST
  standing nearby (anomalies2: host hp 100 -> 50) and the Pufferfish runs its own AI.
- anomalies3 (`20261118-141434-smscen-anomalies3`): the spawned Pufferfish pushes the guest by itself 0.5 s after the spawn (`anom3 bunny pushed the guest
  dmg=1.0 radius=1500 strength=1500`, guest hp 97 -> 96, `bunny push applied` on the guest). The scenario's own `PushFx` call 3 s later
  did not run the hook again (no second push line); the old checks re-baselined hp/speed at that point, so they saw nothing. The old "1010 uu" reading
  is not the cause here (PushRadius is 1500, bunny re-placed 192 uu from the guest).
- anomhit fails (`20261118-140756-anomhit`): 29 kick attempts, `PlayerKick` never reached the Tourist (no ObjectKicked, no `anomhit kick sent`).
  Passing run (`20261118-141649-smscen-anomhit`): camera-to-tip distance was 174 uu, the kick traces about 200 uu, so the margin was 26 uu.

## Derived
- The scenarios must put the guest alone near the hazard (host > 6000 uu away, anomwake2 pattern) so "host not hurt" is a statement about the guest's hit.
- The guest-side mod code is fine: the vanilla push already reaches the guest through anomalies3.lua (hook on PushFx) and applies on the guest.
- anomhit flakiness is the bot's stand position (pawn drift/replacement, reach margin), not a merged module: anomvis lists only RockPounder, ImpactSpear,
  Bollard, Spore, BombRock, LootCreature; anomtail only touches the leech; smhost/hosthurt do not touch the Tourist's physics on the guest.

## Changes (test only, no mod change)
- anomalies2: after the guest joins, the zone's Tesla is destroyed and the guest teleported beside it (host far away, `host_far_from_guest`); guest client has a `t.tp` handler.
- anomalies3: same block after the Tesla check; bunny baselines (guest hp, peak speed) are taken at the spawn, not at the manual push, so the
  Pufferfish's own push or the manual one both count; host baseline stays at the push.
- anomhit: the guest stands 90 uu from the Tourist (was 130) and is re-placed before every kick; each kick logs distance and pawn position.

## Unknowns
- Why a direct `PushFx` call after the creature's own push does not re-fire the hook (the BP event runs a latent ubergraph; probably busy).
