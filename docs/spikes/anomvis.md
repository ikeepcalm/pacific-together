# anomvis: newly un-frozen hazards move on the guest (W6, 2026-11-18)

Classes: Blacksmith `BP_Hazard_RockPounder`, Titan's Bone `BP_Hazard_ImpactSpear`, Bollard `BP_Hazard_Bollard`, Bubblegum Buddy `BP_Hazard_Spore`,
Ticking Tumbler `BP_Hazard_BombRock`, Pufferfish `BP_Boon_LootCreature`. Follows `smhost.md` (their machines run on a listen host now),
`anommove.md` (same idea for the saw and the Abductor).

## Observations (zone fixture, headless pair, scenario `anomvis`; host samples every 100 ms for 40 s)
- Their moving parts are components (and roots) the host's timelines move; the guest copy has tick off. Parts that moved > 20 uu on the host:
  Titan's Bone `sm_proto_ImpactSpear`, `sm_proto_ImpactSpear1`, `SM_VFX_Impact_Spear`, `PointLight`; Bollard `SM_Hazard_Bollard` + `SM_bollardPillar_M`
  (up to ~600 uu), base only ~35 uu; Tumbler root + `MainMesh` (rolls ~300-700 uu in 40 s); Bubblegum Buddy whole actor (`SM_Hazard_Spore_Body`,
  root) wanders > 1200 uu; Pufferfish root + `Cube`, crate and lights (blast-off, ~300-500 uu).
- Rolling and flying bodies (Tumbler `MainMesh`, Spore body, Pufferfish `Cube`) simulate physics and are detached from the root: their relative
  transform is meaningless (Spore body read 69680 uu), the world transform is the truth.
- A spawned Bollard picks a random yaw when it spawns and does not replicate it: the guest's copy stood rotated differently (parts 100 uu off).
- A spawned Titan's Bone's copy can sit at 0,0,0 for a while on the guest (root not replicated yet) and is gone again ~6 s later.
- Blacksmith: the host's machine reaches Pre-Rise > Rise > **Pre-Drop and stays there** (30+ s in the probe, `RockPounderState` 1,
  `PlayerInRange` true); `Cylinder` never leaves z 0, so there is nothing to mirror. Calling `OnDrop()` by hand only changed `RockPounderState`
  (1 to 3). Its slam effects are Niagara + spawned bollards/spears (other hazards).
- Damage: a fresh Titan's Bone under the guest, `Damage()` called on the host: the guest's health fell, the host's did not (the existing
  `anomalies.lua` forward of the pawn's `MSG_Damage_Physical_Explosive`, no new code). The Blacksmith's effect on players is
  `LaunchPhysics` (impulses on car and player bodies), no damage message: not checked.
- `IsSimulatingPhysics("None")` on a mesh component crashed the host (twice, as anomtail.lua found): the module reads `BodyInstance.bSimulatePhysics`.

## Implementation (`mod/PacificTogether/Scripts/anomvis.lua`, FEATURES "anomvis")
- Host, every 100 ms: for each hazard of the six classes within 15000 uu of any player: every SceneComponent except the root, only if its relative
  transform / scale / visibility changed (all parts every 5 s, staggered), plus the root position and rotation (`g.anomvis`). Simulating
  mesh parts are sent in world space with a flag.
- Guest: claims a copy per host hazard (first row: copy within 80 uu of the root, or after 1 s the nearest unclaimed copy within 3000 uu, or one
  at the origin), turns its root body's physics off, then applies root position/rotation and the parts (physics off for flagged parts).
- Bandwidth in the scenario (7 hazards + 6 level bollards in range): `g.anomvis` ~80 KB per 30 s (~2.7 KB/s) after the 5 s full refresh;
  1 s refresh was 160 KB.
- Mutation `noanomvis` switches the module off on both sides.

## Guesses / unknowns
- 10 Hz steps with no smoothing: a fast bollard or spear moves in visible steps. A per-frame glide like anommove's would fix it.
- Blacksmith: why the machine stops in Pre-Drop is not found (Timeline_2 finished event, tick?). It needs its own lane; the module mirrors
  `Cylinder` as soon as it moves.
- Bubblegum Buddy's tendrils, Niagara effects and sounds are not synced (components that are spawned at run time have no counterpart).
- Two spawned hazards of one class close together (or two copies at the origin) may swap copies.
- **Open: root rotation of a spawned Bollard does not reach the guest.** The last runs read host root yaw 130 / -151 and guest 0, so the base
  part (offset ~100 uu from the pivot) is off and `guest_bollard_follows` fails in about half the runs (passes when the random yaw is small).
  The module sends the root rotation and calls `K2_SetActorRotation` (also tried `RootComponent:K2_SetWorldRotation`, same result); why
  it does not stick on the guest was not found (something re-sets it, or the call does not reach the root). Level-placed bollards are not
  affected by the random yaw. Titan's Bone: the guest copy lives ~5 s and is often late, so the check also fails sometimes (5 of 9 runs passed).

## Results (pair C:\PTLanes\anomvis, port 7890, headless)
- `anomvis` 22/23 best runs (`20261118-130508-anomvis-anomvis`: all but `guest_bollard_follows`); the same state failed titansbone and/or bollard
  in other runs (`20261118-131739`, `-132046`, `-132442`): both are flaky, see above. Passing in every run: Tumbler, Bubblegum Buddy, Pufferfish
  follow checks, `guest_hurt_by_spear`, `host_not_hurt_by_spear_on_guest` (once failed because the host itself lost health to the spawned hazards).
  Blacksmith: info line only.
- Mutation `noanomvis` 20/23 `20261118-130944-anomvis-anomvis-noanomvis`: fails titansbone and bollard follow (and a host-hurt check by chance). Tumbler,
  Bubblegum Buddy and Pufferfish still pass without the module: their roots replicate by themselves and the check does not tell the parts apart,
  so those three checks are weak.
- `session` 40/40 `20261118-131246-anomvis-session`, `smhost` 24/24 `20261118-131350-anomvis-smhost`, `anommove` 22/22 `20261118-131519-anomvis-anommove`.
