# guestauth: the guest at the wheel simulates the car (lane guestauth, 2026-11-12)

Owner request (2026-11-12): "when guest is in the driver's seat, HIS game decides the physics, and the host gets the same
treatment with movement the guest gets when host is driving." Before: the guest's keys went to the host (g.car.drive), the
host simulated, the guest saw the result through the follower (100-250 ms follow delay + ping; NOTES "2026-11-09 afternoon").

## Decisions (written before building)

Only the car's physics/transform changes hands. Everything else stays where it was:

| What | Who | While the guest drives |
|------|-----|------------------------|
| Chassis physics, VehicleController tick, transform, velocity | guest's car copy | simulated from the guest's own keys, no round trip |
| Host's car | host | kinematic follower of the guest's stream: the same `follow()` the guest uses when the host drives |
| Input events on the host's car (g.car.drive) | host | still applied (throttle/steering state, engine sound, steering wheel), but the car's VehicleController is off so they move nothing |
| Ignition, gear, parking brake, lights, doors, horn, radio | host | unchanged (g.car.ctl / H line) |
| Part health, fuel, battery, part installs (g.car.s) | host | unchanged: the host's car state overwrites the guest's copy |
| Collisions with anomalies, crash damage | host's world | **gap**: the host's follower is moved with teleport (no sweeps, no hits) and the guest's crash damage is overwritten by the host's state. Anomalies that push the car push only the host's kinematic copy (nothing). Acceptable for a first version; forwarding the guest's hits is the follow-up. |
| Items in the trunk | host | unchanged (attached to the car, carried by its transform) |
| Wheel meshes | each side's own copy | guest: its own physics; host: wheels stand still while it follows (gap, cosmetic) |

Authority rules:
- Guest takes it when it sits at the wheel (car-local Y < 0, riding), both peers offer `guest-auth`, and not mutation
  `noguestauth`. It stops following (keeps the host's ReplicatedMovement muted), turns its chassis physics and controller on
  with the follower's last velocity and streams `g.guestauth.car` (same fields as g.motion.car) at 20 Hz.
- The host follows only the stream of the guest it has at the wheel (`driverGuest`) while the host itself is not driving.
- Back to the host when the guest leaves the wheel (exit, reseat, host takes the wheel), disconnects, or no sample came for 1 s:
  the host's follower stops where the car is, physics and controller go back on with the last sample's velocity (no teleport).
  The guest's copy goes back to following the host's g.motion.car.

## Observations

(filled after runs)

## Derived / Guesses / Unknowns

(filled after runs)
