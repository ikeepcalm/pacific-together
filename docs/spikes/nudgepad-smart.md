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
  Launch call matters (2026-11-20 follow-up, lane nudgepad2): `AddImpulse` and a direct `Velocity` set + falling mode both lost the horizontal part two frames after the fire, on the guest and the host's copy alike, (817,-67,817) -> (88,-289,739),
  with the nudge pad present (removing the pad, or testing with the pad destroyed on fire, kept it). The game's own launch of the HOST's character on the same pad with the pad present kept (668,339,632) for 2 s, so the guest was launched differently from the game.
  `Character:LaunchCharacter(vec, true, true)` (pending launch velocity applied at the start of the next movement tick, before collision) on the guest and on the host's copy keeps the vector with the pad present (anomwake2 26/26, offset 62-65 uu at 700 uu of +X).
- Scenario (pad stays; the host forces its copy's velocity until a BounceCmp fire, the guest until it sees its own launch): headless input does not walk a character (one Command Move call moves ~4 uu), so host and guest both force the guest's velocity to (306,257,0) (40 degrees off +X) for 0.5 s, a landmine is 1500 uu ahead along +X, and a nudge pad
  appears under the guest. Smart: the guest flies at (823,-65,738) and is 62 uu off the line when it has travelled 700 uu in +X; `nosmartlaunch` (plain up impulse) keeps the 257 uu/s sideways velocity (offset 500+ or never at 700 uu).
  Plain X travel or horizontal speed alone cannot tell them apart (the pad mesh push and the 2 s flight add hundreds of uu; a landmine blast fakes 1100+ speed).
- `LoopInGameThreadWithDelay` does not stop when the callback returns true in this runtime (a probe loop kept running); scenario loops must guard themselves.

## Guesses / shortcuts

- No line-of-sight check (the game's query uses channel 3 and ignores the pad), no `TargetForwardVelocityScale` lead (game adds 2x the velocity of a physics-simulating target), no `Accuracy` scatter (the pad uses Accuracy 1 = no scatter).
- The host's copy of the guest's velocity is used (derived from the guest's replicated moves); if it is zero the search falls back to the up vector and nearly never finds anything. Not checked with a really walking guest.

## Unknowns

- Whether a hand-walked guest's host-side velocity is non-zero when the pad fires (the scenario injects it). Hand test: two players far apart, guest walks onto a nudge pad toward an anomaly (landmine, floating rock) 1000-2500 uu away.

## Follow-up 2026-11-20 (lane nudgepad2): the scenario check is flaky, cause not found

- Lead's pair failures (`velocity 0 ... 959/1000/1007, 0 in the cone`) came from the earlier padTest pads; the smart test's own pad does fire (`velocity 400, 1 in the cone`, `smart launch 820,-61,820`, guest applies it).
- What fails is what happens two frames later, on the guest and on the host's copy at the same moment: (820,-61,814) becomes (87,-285,783), so the guest never travels 700 uu in +X. Seen with: AddImpulse, direct Velocity set + falling, `LaunchCharacter(sv,true,true)`; pad present, pad collision off on host only, pad collision off on both sides from spawn (run 142116). Not the pad's collision, not the call used.
- The host's own character on the same kind of pad (pad present, forced velocity toward the anomaly) keeps its launch (668,339,632 constant for 2 s). So the difference is the guest's networked movement, most likely the test's forced `Velocity` writes (not real input) which the saved moves / host replay do not agree with; a really walking guest has not been tried.
- Passes seen: 140627 (26/26, LaunchCharacter) and 133028 (26/26, earlier code); failures: 140918, 141334, 141xxx, 142116. Treat the scenario check as unreliable until a walking guest (or a real input path) is used; the mod code path itself is unchanged in behaviour by the launch call.
- Hand check needed: two players, the guest walks onto a nudge pad toward an anomaly.

## Follow-up 2026-11-20 (lane nudge3): the "two frames later" loss, cause found; the scenario gate is back

Results: 20261120-165923..172045 (probes, anomwake2, folders `*-nudge3-anomwake2`), gating runs 20261120-172331, 172551, 172818 and 173633, 173847, 174107 (26/26 each), mutation `nosmartlaunch` 173102 and 174340 (25/26, only `guest_nudged_toward_anomaly` fails), session 20261120-173408 (40/40).

### Observations

- A per-tick trace on both sides (velocity, location, sphere sweeps around the capsule): the host's copy lost the horizontal part on its first movement tick after the launch and the guest followed at once. Z was untouched. The new XY velocity was always the launch velocity projected onto one fixed horizontal line (-73 degrees):
  (819,-64) -> (88,-290) and (792,163) -> (22,-71) both equal `(v . t) t` with t = (0.292,-0.956). No plane constraint was set (`bConstrainToPlane` false).
- At that spot (guest at about 69900,-35650,z 8213, Tesla +400 uu) object sweeps from the guest hit `BP_CarPart_Interactive_C ... .Box` 2-7 uu away with impact normal (-0.957,-0.289), a surface at -73 degrees, for headings 0-90 and 300-330. A Visibility-channel `LineTraceSingle` did not see it; the Pawn movement sweep does.
- The scenario picks its Tesla with `FindAllOf`, whose order differs between runs. Sites seen: guest at ~69900,-35650,z 8213 (the box, every failing run) and ~31420,-16300,z 3700 (no box; the runs that passed). This also explains "2 of 6 passes".
- Mutation `nosmartlaunch`: the check fails (the plain impulse keeps the sideways velocity); smart arc offset at 700 uu of +X is 235 uu on the open spot.

### Derived

- The guest was launched toward +X beside a car part's box and slid along its wall: ordinary game collision, not network correction. Neither `AddImpulse`, a direct `Velocity` set nor `LaunchCharacter` was at fault; the mod's launch code is unchanged.

### Fix (scenario only)

- The smart test first moves the guest to open ground (first of 8 offsets from the Tesla spot with ground within 400 uu of the Tesla height and 1300 uu of free object sweep along +X), the landmine sits 15 degrees off +X (stays in the 45 degree cone after the guest drifts), and the Tesla is chosen by largest X so the site is stable. `guest_nudged_toward_anomaly` gates again (offset < 330).

### Guesses / unknowns

- Guess: the older "pad removed or destroyed keeps the vector" runs happened at the open Tesla site; not checked, so it is not shown that the pad is irrelevant.
- Guess: the host-character comparison (668,339,632 held) was taken somewhere without the box.
- Not exercised: the new open-spot search at the box site (69900,-35650): after the largest-X Tesla choice that site did not come up in six runs (its Tesla was apparently not the largest X or not loaded). Without the open-spot step that site would still fail.
- Hand check still open: a really walking guest on a nudge pad (normal collision applies).
