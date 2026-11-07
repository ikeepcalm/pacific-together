# Loose-item host clock, 2026-11-06

The renderer previously assigned snapshots their receipt time and discarded its buffer whenever it reached the last pose. Uneven packet delivery therefore changed apparent velocity and brief gaps repeatedly restarted interpolation.

The negotiated item-clock extension appends host sample time to existing ordered poses. Updated clients interpolate in that timeline, with a minimum observed clock offset and the existing 120 ms presentation buffer. Create/delete/final edges retain reliable delivery and replica ordering. Motion state survives short gaps, retiring after one second without updates. Legacy peers retain eight-field poses. Shared cosmetic motion keeps its previous clock behavior.

Validation:
- Eight standalone itemclock checks passed, including exact constant-speed sampling under delivery jitter at 30/60/144 FPS and final pose/long gap checks.
- Replacing the host clock with receipt time fails all three new jitter checks.
- Rendered two-instance motionparts passed 32/32, no crash/PT error: host and guest throws, airborne motion, resting pose, velocity preservation, pickup and measured movement cadence. Results: local/test-results/20261106-211506-vehicle-proxy-motionparts.
- Updated the scenario's locker helper to use the now-authoritative NamedPartsContainer; the old proxy helper could not drive the current shipping storage code.

This is a developer preview. No full-suite, Steam two-account, lag/loss or manual side-by-side visual acceptance is claimed for this candidate. High jitter exceeding the presentation buffer can still cause visible holds; no speculative client collisions are introduced.