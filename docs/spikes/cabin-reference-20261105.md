# Stable passenger cabin reference

The owner identified the visible defect as the right-hand cabin pillar shifting relative to the guest's view, while the
host's cabin stayed steady. Matching only the final car position was insufficient.

## Changes

- With negotiated `car-motion`, mute only `OnRep_ReplicatedMovement` on the followed guest car, after a custom sample arrives.
  Other actors, attachments and car interactions retain their callbacks. Legacy peers retain native movement handling.
  Unmute when replacing/removing the follower or returning to the experimental physical proxy; map cleanup also clears mutes.
- Disable synthetic passenger head sway by default. This spring derived acceleration from the delayed guest presentation
  and deliberately moved its camera against the cabin. The old effect remains only under mutation `oldpassengersway`.
- Test native callback suppression and a fixed cabin reference separately from position, tilt and camera update timing.
  The former `guest_head_sways` assertion required precisely the movement the owner wants removed; the replacement requires
  less than 0.25 uu of camera component offset. Other movement/camera thresholds are unchanged.

## Observations and executed checks

- Controller tick dependency candidate: `20261105-204348-vehicle-proxy-tunnel-carsync`, 43/45; rejected and removed.
- Scoped movement notification suppression: `20261105-204703-vehicle-proxy-tunnel-carsync`, rendered 150 ms / 2% loss,
  45/45; maximum sampled step 65.2 uu, zero stalls, camera deviation 18.7 uu.
- Disable suppression (`nativecarpose`): `20261105-215117-vehicle-proxy-tunnel-carsync-nativecarpose`, 45/46. Exactly the
  suppression assertion failed; suppressed callback count was zero. This drive itself was smooth, so suppression alone
  is not established as the sole cause of visible cabin jitter.
- Suppression with synthetic sway retained: `20261105-215419-vehicle-proxy-tunnel-carsync`, 44/46. Suppressed calls 229,
  but follow/camera failed with a 9.298-second sampling gap. Do not treat callback suppression as a cure for rendering stalls.
- **Owner-approved rendered run**: `20261105-220803-vehicle-proxy-tunnel-carsync-nosway`, 150 ms / 2% loss. 496 guest samples,
  maximum sampled step 86.9 uu, zero stalls, camera deviation 10.2 uu, synthetic offset 0.00 uu, 484 suppressed native calls.
  Its old summary is 45/46 because `guest_head_sways` failed as expected with sway disabled. The owner reported no visual
  complaints after this run. This exact behavior is now the default; no movement constants were changed after approval.
- Default-settings rendered repeat `20261105-221702-vehicle-proxy-tunnel-carsync`: **45/46**. Follow, native-write
  suppression, fixed cabin reference and per-frame view alignment passed: 478 samples, 114.5 uu maximum step, zero stalls,
  471 suppressed writes, 0.00 uu synthetic offset. `guest_camera_rides` still caught a maximum 80.5 uu deviation
  (87.8 uu against the previous frame) with a 227 ms sampling gap. That failure is retained, not waived; the source of
  that occasional deviation remains unproven. It does not justify changing the owner's approved behavior silently.
- The earlier sway-enabled control recorded 10.22 uu of synthetic offset; it would fail the new fixed-reference limit.
  The renamed `oldpassengersway` mutation has not been rerun with the renamed assertion. No full-suite pass is claimed.

## Original-author comparison

Fetched `upstream` (`ikeepcalm/pacific-together`). Tip `b401fab` is already an ancestor of the experimental checkout; there
are eight author commits after `38fbaa0` (0.8.8), and zero additional upstream commits missing locally.

Clean branch `compare/upstream-original`, worktree `C:/Dev/pacific-together-upstream`, is exactly `b401fab`. Its native DLL
was built from that worktree using the existing UE4SS build; author Lua/native sources are unchanged. Both isolated clients
under `D:/PTLanes/upstream-original` use that worktree's Lua, test mod and native DLL, port 7843. A garage fixture was copied
only into this isolated host as slot 5. No real install or real saves were changed.

An initial setup copied an old UE4SS directory without its loader; that failed launch is archived as
`20261105-220125-upstream-original-repl`. Recreated the isolated runtime from the SHA-256-pinned UE4SS archive and verified
all mod junctions. Original launch/join smoke: `20261105-220554-upstream-original-repl`, 15/15, plus a successful guest-seat
probe. A default-map drive probe did not move the car and failed its assertion; it does not certify original driving.
The original author's code also contains synthetic passenger sway; it is intentionally preserved for comparison.

Launch original (load the copied slot 5 on the host, or start a game):

```powershell
cd C:\Dev\pacific-together-upstream
.\tools\play-local.ps1 -Root D:\PTLanes\upstream-original -Port 7843
```

This is local rendered/manual evidence and focused regression coverage. Full-run, two-PC Steam, long-drive and release
certification remain separate; a stalled renderer cannot be made seamless by network interpolation.
