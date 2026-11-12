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

- First runs (`20261112-173322-guestauth-guestauth`, `20261112-173820-guestauth-guestauth`, 35/37): authority switched both
  ways and handback was clean, but the guest's car did not move. Its chassis simulated, the throttle built 1500 uu/s of
  physics velocity, and the car moved 5 uu in 12 s. The host's car followed it exactly (p50 2 uu).
- Live (game MCP, coop-zone): an impulse or set velocity on the guest's chassis was cancelled within a frame. The client's
  physics worked on a spawned cube. `OnRep_ReplicatedMovement` was muted (PTNative_MuteCount rose about 30/s) and no
  ProcessEvent call moved the car. VehicleController `Wake()` alone changed nothing. With
  `SM_Wagon_01_KeyPhysics:SetSimulatePhysics(true)` the chassis moved right away: car.lua's cosmetic follower
  (renderCosmetics) makes the key body kinematic, and `PhysicsConstraint_Key` ties it to the chassis.
- With the cosmetic bodies back on physics at the switch (`car.lua` `M.unfollow`), run `20261112-175842-guestauth-guestauth`
  passed 37/37:
  - The guest's key reached its own throttle in 3 frames (176 ms) and its car moved after 8 frames (498 ms). The test bot's key
    reaches guestauth.lua through the test intent, which takes one or two of those frames.
  - The host's car was kinematic in 399 of the samples.
  - Host-to-guest car distance while moving: p50 124 uu, p95 204 uu (follow delay at up to ~900 uu/s). Once stopped it was 0.0 uu.
  - Handback on exit: max step per frame 0.2 uu, 0.1 uu moved, min vz -7 over 210 frames. The guest followed the host again.
- Mutation `noguestauth` (`20261112-180418-guestauth-guestauth-noguestauth`) scored 32/37. guest_input_local failed: the
  guest's own throttle never rose, physics false. host_follows_guest and host_car_tracks_guest failed too.
- guestdrive with guestauth on (`20261112-180645-guestauth-guestdrive`, 31/34): the car moved about 2 m, then stood still at
  full throttle. The door the host shut after entry is posed on the guest from the door stream (kinematic MainMesh) and kept
  its `PhysicsConstraint` hinge to the chassis. Fix: while the guest simulates, the hinges of kinematic doors and panels are
  broken, as the door's own shut path does (`BreakConstraint`, mesh kinematic). The mutation `guestauthhinge` turns this off.
  After the fix guestdrive passed 34/34 (`20261112-181211-guestauth-guestdrive`). guestdrive now measures the host car's speed
  from its movement, because a guest-driven host car is kinematic.
- guestauth after the hinge fix (`20261112-181423-guestauth-guestauth`): every functional check passed. Throttle answered in
  3 frames (67 ms) and the car moved after 12 frames (376 ms). Distance while moving was p50 107 / p95 205 uu, 0.0 uu once
  stopped. Handback: max step 0.0 uu. The run scored 36/37 because the client logged car.lua's existing
  `RegisterHook ... BP_Panel_Base_C:AttemptOpen is not loaded` (hookAll ran before the panel class loaded). Earlier runs of the
  same code did not log it. The same error appears in older and other-lane results (`20261108-224623-lootcar`,
  `20261112-172509-breakables-carbreak`), so it predates this lane.

- Garage (carsync, `20261112-182137-guestauth-carsync`, `20261112-183409-guestauth-carsync`): carsync's guest enters by the
  driver's door, so since 0.9.2 it sits at the wheel. carsync expects the passenger seat, so host_guest_seated fails. No
  carsync run exists after 156bfaa to compare. Live (game MCP), the guest's car once flipped onto its side (roll 93-125) the
  moment its physics came on, with no input. In the second carsync run the car stayed steady at first, then the host took it
  back with a 4800 uu/s sample velocity, after the host scenario had removed a wheel and a door under it.
  Decision: no guest authority in the garage, where the host simulates as before. A start probe was added: the car must stay
  within 50 uu and 10 deg for its first second, else the host keeps simulating until the guest leaves the wheel. Authority
  starts only after the guest has sat at the wheel for 0.5 s, because the predicted seat and the host's seat toggled it at entry.
  Handback velocity is capped at 4500 uu/s.
- `session` 40/40 (`20261112-183810-guestauth-session`). An earlier session run (`20261112-182304`) crashed the client; game
  MCP evals were moving that client's car at the time (operator error, the MCP session attached to the running scenario).

## Derived

- The guest can simulate the replicated car copy (Role 1). Two conditions: the host's replicated pose stays muted, and every
  body constrained to the chassis must simulate too (key, bobble, hanging). A kinematic constrained body pins the chassis in place.
- The host follows with the existing `follow()` (its motion source is the guest's g.guestauth.car samples in the same
  carMotion slot), so the host sees the guest's car about one follow delay (0.1-0.25 s) late, as the guest saw the host's.

## Guesses / Unknowns

- Not run on a real network (ping/loss). The guest's stream is a reliable RPC at 20 Hz, about 130 B per sample.
- Crash damage and anomaly pushes while the guest drives are not forwarded (see the table above). The host's wheels stand still
  while it follows.
- The guest's driving camera is still the character camera (unchanged).
- Why the guest's car was thrown in the garage is unknown. Candidates: depenetration from a body that only the guest has
  overlapping the chassis, or part removal under a simulating copy. The zone may hit the same thing rarely; the start probe
  and the velocity cap limit the damage.
- Handback was tested only with the car stopped. A moving handback carries the last sample's velocity but is untested.

## carsync control (2026-11-12 evening)

- Main 883d892 checked out on this lane's pair (`20261112-190255-guestauth-carsync`): 34/46, the same failures as the lane's
  `20261112-184933` (host_guest_seated at t=240 and the drive/follow checks after it). With main's code the carsync guest's
  driver-door intent seats it at the wheel too (`car enter from 8675 uu`, seat 46.9,-46.6; seat error 92.4).
- The lead's passing main run `20261112-185446-carsync` took another path: the game attached the joining guest to the car
  (`car guest attached by the game, moved to the passenger seat`) before its enter intent, so the later D intent was ignored.
  Whether carsync passes depends on which of the two happens first, not on this lane.
- After merging main (8b4f905): guestauth 37/37 (`20261112-190515`), guestdrive 33/34 (`20261112-190654`). The only failure
  is the existing `BP_Panel_Base_C:AttemptShut is not loaded` error gate.
