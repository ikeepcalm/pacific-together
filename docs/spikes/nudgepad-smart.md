# nudgepad-smart: smart launch of a guest on the Nudge pad (Shaker)

2026-11-20, lane `nudgepad` (follows [anomfin.md](anomfin.md) 4 and [nudgepad.md](nudgepad.md)). Code: `anomalies3.lua` (`smartVector`, `launch`), scenario `anomwake2` (`guest_nudged_toward_anomaly`), mutation `nosmartlaunch`.

## Observations

- Real flow on the host's own character (live game, zone fixture): with `CharacterMovement.LastUpdateVelocity` = (600,0,0) and a landmine 1200 uu ahead, `pad:ImpulsePlayerCharacter()` gave velocity (709,3,681) one tick later. With
  LastUpdateVelocity zero it gave only (0,0,688). So the lead's hypothesis is right: the smart search needs a non-zero velocity pointing at an anomaly.
- The anomfin probe's (0,0,1000) was a second, separate failure: calling `ImpulseHelper:CalcualteImpulseFromPoint` from Lua with a `TagsToImpulseTo`/`IgnoreTags` container (any table, even an empty one) makes UE4SS drop the whole
  SmartLaunch struct (read back through a pre-hook on the same function: Chance 0, ranges 0, override 0). Scalars, the Vector2D and the override vector marshal fine (Chance 1, MaxRange 2500, Angle 45, override 1,0,0 read back).
  So the helper cannot be fed a tag container from Lua. Its out values also land in the last table argument, not the first.
- `ActorTags.Hazard.Anomaly` is carried by (zone map): Tesla (5), Landmine (10), floating rock (21), physics grabber (4), bollard (6), the nudge pad itself. A spawned landmine carries it too (the nudge pad is excluded by the game as the helper's owner).
  Tags are read with `BlueprintActorTagFunctionLibrary:GetActorTags(world, actor, outSet)` and `:GetActorsWithTag(world, {TagName=FName(..)}, outSet)` (out set arrives as a table of params, `v:get()` is the element). `ActorTagQuery` could not be called from Lua (out-param table error).
- `GameplayStatics:SuggestProjectileVelocity_CustomArc(world, outVec, start, end, 0, arc)` is callable; the game's arc 0.5 from 1200 uu away gave (767,0,767).
- Apply: smart => the game zeroes the whole velocity then `AddImpulse(arcVelocity, true)`; plain => only adds the up impulse. `ImpulseInDirection` is fed the pad's up vector, From = the character's centre, query origin = centre + up.

## Derived

- `launch()` (nudge pad only) now redoes the game's search on the host from the host's copy of the guest: velocity direction (up vector if standing), anomalies from `GetActorsWithTag`, 250-2500 uu, within 45 degrees, not the pad, not tagged `HazardProperty.Lob`,
  random pick, arc via the game's own solver (arc 0.5, 1 try per candidate until one succeeds). The vector goes in `g.anom3.bounce` as `ux uy uz 1 1` (fifth field = smart: the guest sets its velocity to the vector and enters falling mode, on the host's copy too).
  Setting the velocity directly matters: with the game's `AddImpulse(v, true)` the guest took the vector for one frame, then the host's replay of the guest's moves pulled it back to ~(88,-287) (the old Z-only plain launch survives that, a horizontal vector did not). No candidate => the plain up impulse, as in the game.
- Scenario: headless input does not walk a character (one Command Move call moves ~4 uu), so host and guest both force the guest's velocity to (306,257,0) (40 degrees off +X) for 0.5 s, a landmine is 1500 uu ahead along +X, and a nudge pad
  appears under the guest. Smart: the guest flies at (823,-65,738) and is 62 uu off the line when it has travelled 700 uu in +X; `nosmartlaunch` (plain up impulse) keeps the 257 uu/s sideways velocity (offset 500+ or never at 700 uu).
  Plain X travel or horizontal speed alone cannot tell them apart (the pad mesh push and the 2 s flight add hundreds of uu; a landmine blast fakes 1100+ speed).
- `LoopInGameThreadWithDelay` does not stop when the callback returns true in this runtime (a probe loop kept running); scenario loops must guard themselves.

## Guesses / shortcuts

- No line-of-sight check (the game's query uses channel 3 and ignores the pad), no `TargetForwardVelocityScale` lead (game adds 2x the velocity of a physics-simulating target), no `Accuracy` scatter (the pad uses Accuracy 1 = no scatter).
- The host's copy of the guest's velocity is used (derived from the guest's replicated moves); if it is zero the search falls back to the up vector and nearly never finds anything. Not checked with a really walking guest.

## Unknowns

- Whether a hand-walked guest's host-side velocity is non-zero when the pad fires (the scenario injects it). Hand test: two players far apart, guest walks onto a nudge pad toward an anomaly (landmine, floating rock) 1000-2500 uu away.
