# Experimental physical car proxy

This branch tests host-authoritative driving with guest-side vehicle physics and a smooth correction towards the host's replicated movement. The host sends throttle, brake and steering at up to 20 Hz over the existing motion channel only to peers that advertise `physical-car`. The guest switches to the existing kinematic follower when fresh control messages are unavailable. Protocol 6 and PT1/PT1A framing are unchanged. This is an experiment, not a release candidate.

## Initial evidence

The headless direct `carsync` run `20261104-010833-vehicle-proxy-carsync` reached the driving stage, confirmed guest physics and host controls, and failed camera and settled-position checks. After the stop, the guest's distance from the host oscillated from roughly 286 to 934 uu in the recorded samples; the scenario then failed its state check. The run was stopped after the prerequisites failed, with logs retained. The initial speed samples were taken after the new checks and do not cover the same interval as the control.

The control `20261104-011244-vehicle-proxy-carsync-nophysicalcar`, same pair and direct headless mode, completed 38/40: the two intentionally disabled physical-proxy checks failed; the original movement, camera, final position, state and exit checks passed. Its guest recorded zero stalls and a maximum per-sample displacement of 34.3 uu. This is a short artificial garage drive, not visual proof or a real-network test.

The corrected repeat `20261104-012130-vehicle-proxy-carsync` recorded guest physics and input delivery, but failed `guest_car_follows`, `guest_camera_rides`, `guest_car_settled`, and `guest_state_matches`. The guest's largest sampled displacement was 310.6 uu, and its measured speed-change p95 was 1628.1 uu/s versus 342.1 uu/s in the control. Sample rates differed, and neither result is a visual benchmark. The run was stopped after the prerequisite failures and logs were archived; the exit and remaining checks were not completed.

The experiment does not implement guest driving, input prediction/replay or a new unreliable RPC. Motion uses the existing negotiated transport, which falls back to the game's reliable channel when no tunnel is active. Local physics can visibly diverge and is not suitable for normal play on this evidence.
