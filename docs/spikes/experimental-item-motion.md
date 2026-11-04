# Experimental item motion

2026-11-04. The vehicle-proxy worktree retains the physical car experiment; this change only alters loose-item presentation on the guest. The host remains authoritative. No protocol or wire payload changed.

## Method

The guest buffers received item poses and renders 120 ms behind their arrival clock, interpolating between snapshots instead of restarting a 50 ms lerp on every arrival. Rotation uses the existing shortest-path quaternion interpolation. A gap over 250 ms starts a new interpolation from the currently displayed pose; when the stream stops, the item reaches the last pose and stays there. Reliable final poses, world/sequence fencing, pickup and guest drop adoption remain in place. This follows the fixed-delay approach in MultiVoid `active_drive.h`, revision `4fbf1acf0e0ec7d14350132cd3de01d6a86aa552` (MIT).

## Checks

- Render-clock math and jitter at 30/60/144 FPS, stopping and long-gap resumption: 11/11, `C:/Dev/pacific-together/local/test-results/20261104-201649-passenger-itemclock`. The same test with interpolation disabled failed its movement and gap checks, `20261104-201546-passenger-itemclock-olditemclock`.
- Real game pair, direct headless, item changes on the main-worktree base: 29/29, `20261104-202741-passenger-motionparts`. The fresh test object moved in 141/193 samples between first and last movement; both real throw directions, final poses and pickup passed.
- Vehicle-proxy pair, headless, tunnel 150 ms / 2% loss: 35/35, `20261104-203403-vehicle-proxy-tunnel-motionparts`. The controlled-motion object moved in 168/237 samples between its first and last movement; both throw paths and pickup passed. Both sides reported that gameplay used the tunnel.
- Same tunnel with interpolation disabled: 34/35, `20261104-203607-vehicle-proxy-tunnel-motionparts-olditemclock`. Only `guest_item_smooth_during_motion` failed; 76/173 samples moved in its measured span.
- Vehicle-proxy pair, rendered direct: 29/29, `20261104-203849-vehicle-proxy-motionparts`; controlled motion moved in 125/174 samples in its measured span. The automated run did not inspect the rendered image.

The controlled movement is a test-driven trajectory, not a measurement of rendered pixels or frame pacing. The game-physics throw checks establish flight and landing agreement, not visual smoothness throughout flight. Direct-IP transport may still queue behind reliable traffic; long gaps freeze at the last received pose. A previously resting world item may take several seconds to be rediscovered as moving. A human playtest, real Steam relay, other item classes and a full release suite remain unverified.
