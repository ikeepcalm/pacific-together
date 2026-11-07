# PT7: thrown items, garage part lockers, wheels and passenger windshield

2026-11-02; supported Steam v1.15 executable SHA-256
`568bb63476c6de5fc2b1878572a655dd631dd25bb44fe304e3d96a51f6b98f7e`.
Isolated pair `D:/PTLanes/passenger`, port 7823. No real install or saves changed.

## Observed causes and changes

- Loose-item discovery previously waited up to one second on the guest and two seconds on the host; movement snapshots
  ran every 500 ms and snapped the guest actor. A guest throw only sent location/yaw, losing linear/angular velocity.
  Native InventorySystem spawn hooks now mark discovery dirty; the next 50 ms tick discovers the new item. A one-second
  fallback remains, and host discovery keeps the existing 8 ms work budget. Host movement runs at 20 Hz for hot items;
  the guest interpolates positions and quaternion rotations over 50 ms with its own item physics disabled. Drop requests
  include full rotation plus linear/angular velocity; finite numeric bounds are checked before spawning.
- `GetInstallTag(out)` did not populate `out.Station` in the live binding. All four part-storage spawners share
  `IA_Garage_InventoryParts`, but have distinct `StationInstallTag` values. Read that property directly in garage.lua
  and its existing garagesync/stations test callers. BackYard and Fence then spawned on both sides.
- The guest intentionally disables VehicleController. Native wheel meshes therefore never receive rolling/steering/
  suspension updates. Sample the four actual `*_Wheel_Mesh` component transforms in car space, send changes at up to
  20 Hz (one-second idle refresh), and interpolate on the guest. Chassis physics remains disabled there.
  The components' RelativeRotation properties stayed zero even while their native world transforms rolled: testing
  only those properties would miss the actual visual state.
- Native BaseHighlightManager:PassesFilter rejects `SLOT_Windshield` interactive highlights only while the local guest
  is riding. Driver/on-foot policy and the passenger ignition/shifter selection paths remain in use.

## Checks

Final tightened negative control (`-Mutate nofall -Headless`): **24/28**, expected failures for airborne movement and
landing agreement for BOTH host and guest throws; unrelated checks still pass. Archive:
`local/test-results/20261102-163017-passenger-motionparts-nofall`.

`tools/run-test.ps1 -Root D:/PTLanes/passenger -Port 7823 -Scenario motionparts -Seconds 360`

- Rendered two-client run: **27/27**, archive `local/test-results/20261102-162450-passenger-motionparts`.
- Final code, including discovery budget/numeric validation and pickup regression, headless: **28/28**,
  archive `local/test-results/20261102-162707-passenger-motionparts`.
- Earlier negative control (`-Mutate nofall -Headless`): **23/25**, expected failures for host airborne movement and
  landing agreement; archive `local/test-results/20261102-162107-passenger-motionparts-nofall`.
  The scenario was subsequently tightened to ignore the guest's original locally simulated throw when observing flight.

The scenario covers both lockers, visible wheel rolling/steering, host and guest airborne motion, preserved guest throw
velocity, landing position within 3 uu and pitch/roll within 2 degrees on both throw paths, kinematic guest item copies,
pickup removing the host item, native ignition/shifter highlight selection, windshield rejection while seated and restored
on-foot filtering. Live stopped-car wheel transforms also matched within their 0.1-unit/degree wire rounding.

These are short garage checks, not a release gate. High-speed wheel aliasing, large loose-item piles, tunnel lag/loss,
world travel/rejoin and a human full run have not been validated for this change. Guest views follow the same host physics
with network/interpolation delay; this does not establish identical pixels on the same wall-clock frame.
