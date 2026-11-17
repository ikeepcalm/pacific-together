# nudgepad: NudgePad launches a guest far from the host

2026-11-17, lane `nudgepad` (follow-up of [anomwake2](anomwake2.md)). Code: `anomalies3.lua` (`launch`, NUDGE hook; shares `g.anom3.bounce`), scenario `anomwake2` (nudge pad check added), mutation `noanomwake2`.

## Observations

- Atlas `BP_Hazard_NudgePad`: box begin-overlap and a repeating `Bounce` timer (started on PlayerRange in-range, `Box.SetGenerateOverlapEvents(true)`) both call `BounceCmp(PrimCmp)`. Owner == `BP_MainCharacterManager:GetCharacterActor()` runs `ImpulsePlayerCharacter` (host's character only); other physics bodies go to `Impulse Other`. A guest pawn is neither, so it was never nudged.
- `ImpulsePlayerCharacter`: `ImpulseHelper:ImpulseInDirection(up, 1000, ..., smart launch toward `ActorTags.Hazard.Anomaly` within 250-2500 uu, 45 deg of the host's last velocity, chance 1)`, ends in `CharacterMovement:AddImpulse` on the host's character; vertical velocity zeroed only when the launch is smart. Not applied while the player is in the car.
- Without the hook the spawned pad still lifts a guest ~100 uu (pad mesh rises); the scenario therefore needs +200 for the nudge pad (hooked run ~340, repeated launches every ~2 s). Mutation run fails it.
- Hook `BP_Hazard_NudgePad_C:BounceCmp` registered and fired for a guest standing on a spawned pad. The zone fixture's guest was lifted (scenario `guest_launched_by_nudgepad`, +60 uu over rest), the far host was not (`host_not_launched_by_nudgepad`).

## Derived

- `launch()` (shared with the bounce pad): host applies the impulse to its copy of the guest's movement and sends `g.anom3.bounce` (`ux uy uz amount`); amount 1000 for the nudge pad. Same 1.5 s per-pad cooldown.

## Guesses / shortcuts

- The smart launch toward a nearby anomaly (arc to a hazard) is dropped; the guest gets a plain up impulse of 1000 even when an anomaly is near. Nudge pads normally sit near anomalies, so by hand the guest may fly straight up where the host would be arced toward one.
- The vertical zeroing is applied always (the original does it only on a smart launch); harmless for a pad.

## Unknowns

- Whether NudgePads occur in normal maps (class exists with prefab `PFX_Layout_Hazard_NudgePads` and an `_AnchorSpawn` variant); the scenario spawns one. Not checked per zone.
- Hand test: split the players >5000 uu and walk the guest onto a nudge pad.

## Runs (local/test-results)

- 20261117-135554-nudgepad-anomwake2 25/25; mutation noanomwake2 20261117-140001-nudgepad-anomwake2-noanomwake2 23/25 (bouncepad + nudgepad launch checks fail); session 40/40 20261117-135057-nudgepad-session.
