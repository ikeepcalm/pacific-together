# guestcar lane (2026-11-16): guest at the wheel, from the 2026-11-15 friend session

## Observations
- Junction with a guest driving (scenario guestjunction, before the fix): the car entered the junction's volumes, its gear went to park
  (MyCarGearBox 0 -> 1) and it stopped 226 uu short of Collision_Exit; PlayerCarState stayed 0. BP_LevelTransition_EnterExit's ReceiveTick parks and
  honks an "empty" car (state != 1) in its volumes, and its exit-volume overlap counts CarChassis only when state == 1.
- DoLevelTransition is jumped to inside the ubergraph: a hook on the function never fires, the map load is the observable.
- Exit at speed (scenario guestexitmove, mutation noexitrel): the glide ends car-relative, the old placement snapped to the exit-time world spot.
- With the placement car-relative the host's copy of the guest stayed at the exit-time spot: desync.lua turned move correction on and pulled the guest
  back (steps of 800+ uu 0.5 s after the placement). Fixed by `g.car.placed` (guest -> host), the host moves its copy and repeats the exit's
  UnPossess/Possess reset.
- A guest placed beside a car rolling at 5+ m/s is pushed by it (desync 500-900 uu off). The host now refuses `g.car.exit` above 500 uu/s
  ("force", from the unstick, always leaves).
- The E press on the driver's door while seated: door hook sends the exit, the game's EnterCar then sent `g.car.enter D` ~0.1 s later, after
  `g.car.out` had already cleared `riding`: guarded by a 3 s window from the exit intent.

## Derived
- PlayerCarState is held at 1 (raw property write, no change event) while a guest drives and the car is within 4000 uu of an active
  (ExitActive) junction; car.lua reads it through M.hs(), which hides the lift. It goes back to 0 when the guest stops driving or the car leaves.
- Ignition: 0 off, 1 starting, 2 running (SetCarIgnitionState, BP_PlayerCarNew switch on 0/1/2). A press while it is 1 now finishes the start.

## Guesses / Unknowns
- Other readers of PlayerCarState (HUD, audio, AC_PlayerHealthReceiverHelper...) see 1 near a junction while the host is on foot or a passenger.
  Not observed to matter in the scenario; not tried with the host riding as passenger (hostRiding).
- The lift is not undone by the game if the host takes the wheel inside the 4000 uu window (M.hs would still say 0). Edge case, not handled.
- guestauth.lua still reads PlayerCarState directly (guest-auth is off).
- "Starting engine" stuck: the ignition fix follows from reading the states, not from a reproduction.
- The 233 m move + death of the friend session is not reproduced; the placement snap and the rolling car are the candidates.
- Guest-side hood/door hooks: BP_Panel_Base hooks failed with "not loaded" when the guest entered the garage after a junction (PT|error in the
  scenario); registration is now retried per hook name.
