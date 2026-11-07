# Day clock and removable-part appearance, 2026-11-06

## Observations and source facts

The owner reported different dashboard minutes after loading, stock-looking remote held panels and paint/decal loss after dropping and installing a part. `world.lua` previously sent a four-decimal day fraction each second and corrected only beyond 0.002 day (172.8 game seconds). `ids.lua` explicitly omitted tints; installed paint used a separate `visual.lua` message, while remote hands rebuilt static meshes with default materials.

Live reflection of the supported executable confirmed the ToD manager's day fraction, day count, `Get Time of Day Speed` and the native tint component's item-instance getters/setters. A scratch component bound to a duplicated instance preserved palette classes and the enabled flag. The configured percentage-per-second speed does not capture frame-time stalls during heavy loading, so the final sender measures actual normalized-day advancement against elapsed time.

## Implementation

`world-clock` negotiates clock calibration probes and a 10 Hz newest-wins snapshot stream on the existing optional motion channel. The sender measures actual day advancement over a short history. Server timestamps and the lowest-RTT calibration in the latest 32 probes map snapshots to the client clock without treating arrival jitter as time progression. The client advances the latest sample every 50 ms and stops its independent ToD multiplier. Host pause, day rollover and the host's changing day/night speed are reflected. World tokens reject previous-map replies, request IDs and source timestamps reject stale replies, and travel/disconnect restore the prior local multiplier. Clock traffic is excluded from the reliable gameplay-window acknowledgement count. A clock-specific acknowledgement gates the transition's normal and timeout release; the existing bounded fallback remains for a missing peer.

`item-tint` adds paint palette, tint-enabled flag and decal palette to the existing shared item spec. The native component setters modify the instance, so recreation in containers, loose actors and swaps preserves it. Existing manifestations use their own component to refresh the visible material immediately; items without a manifestation use one registered scratch component on the local controller. Remote hand mirrors reuse the established wreck material-layer parameter application. Legacy peers receive their previous item spec without the optional fields. The checked-out author's protocol 7 remains unchanged.

## Validation

- `parttint`, rendered two-instance run: 31/31, no crash or PT error. Entire guest-remove -> remote held material -> guest drop -> host pickup/install -> host drop -> guest pickup/install chain. Palette state AND actual dynamic material paint vector/decal texture are asserted. `local/test-results/20261106-231451-vehicle-proxy-parttint`.
- `dayclock`: 23/23, no crash or PT error. Forced seven-day/local-time/speed corruption corrected, then real garage-to-run travel, guest rejoin, clock acknowledgement before fade release and matching day clocks. `local/test-results/20261106-231140-vehicle-proxy-dayclock`.
- `parttint -Mutate noitemtint`: expected failure, 20/31; specifically catches remote held material and dropped instance/material loss. `local/test-results/20261106-232204-vehicle-proxy-parttint-noitemtint`.
- `dayclock -Mutate noworldclock`: expected failure, 14/15; fails `initial_clock_lock`. `local/test-results/20261106-232458-vehicle-proxy-dayclock-noworldclock`.
- `netflow`: 17/17 for the 400-message reliable burst with clock replies bypassing its gameplay window. `local/test-results/20261106-233922-vehicle-proxy-netflow`.
- Final `dayclock -Tunnel "udp lag=150 loss=2"`: 29/29, including carried/lag checks, the independent simultaneous-state oracle and the real loading transition. After the loading release, 95 samples had median 0.443, p95 1.492 and maximum 3.604 game seconds of error. Large intentional host time jumps during the hidden loading phase are excluded from these displayed-world statistics. `local/test-results/20261107-000648-vehicle-proxy-tunnel-dayclock`.
- Final `pausehost`: 27/27, host menu pause/resume and guest movement/overlay remain intact. `local/test-results/20261107-001046-vehicle-proxy-pausehost`.
- Final `netflow` with the snapshot stream and rebuilt native DLL: 17/17. `local/test-results/20261107-001459-vehicle-proxy-netflow`.
- `tools/test-item-tint-wire.lua`: ten standalone validation/legacy-stripping assertions passed.

Earlier scenario failures exposed test issues: missing AutoJoin registration, acting before baseline admission, reading pending-kill manifestation components, and testing inventory-container contents before the active hand manifestation existed. The final scenario uses admission readiness, live component filtering and the actual active hand item. These failures are retained in local/test-results and are not counted as passes. Early clock candidates also failed under 150 ms / 2% loss: latest-RTT compensation and configured-speed extrapolation were replaced. The final independent oracle samples both test processes on the same machine-wide QPC clock and interpolates their recorded states at the same instant; a tiny PT_SCENARIO-only native clock registration avoids UE4SS DateTime/Timespan marshalling and float precision limits. It is not used by the shipping estimator.

## Limits

Half-RTT assumes roughly symmetric transit; arbitrary network stalls cannot guarantee zero instantaneous skew. Extrapolation stops after three seconds without a usable sample. The transition retains its bounded missing-peer fallback. Material assertions in a rendered run do not replace manual side-by-side visual acceptance. This pass does not certify every part variant, long-term backpack persistence, the full regression suite or two-account Steam transport.
