# guestdeath: slow guest death detection (2026-11-20)

## Observations
- `20261118-130123-playerhealth` (playerhealth 25/27): the guest was hit to the minimum 2.7 s after the arrival release; no
  `PT|health guest died` line ever; the guest's health read 1% for 8 s, then 2, 3 ... 11% (the game regenerates it and
  plateaus at ~11%).
- Same trace with a trace log in a 2026-11-20 run: after a hit to the minimum the value is 1.0, 1.1 (+4.7 s), ... : it leaves
  the old `cur <= 1.01` window within seconds, while the 8 s grace after the release is still running.
- Release does not drop health in the traced run (100 before and after), so the grace is only needed for the load drop.
- Baseline reruns on pre-fix code: playerhealth 27/27 (20261120-090517-guestdeath-playerhealth), 27/27
  (20261120-092358-guestdeath-playerhealth), 25/27 (20261120-092612-guestdeath-playerhealth, same failure as 11-18).
- worldzone on current code, 3 runs: 26/26 x3 (20261120-092827, -092959, -093131, all `-guestdeath-worldzone`). The 11-18
  `guest_generator_present` failure did not reproduce (under 3 parallel pairs then); not investigated.

## Derived
- Root cause: death was tested as `cur <= 1.01` only after the grace. A guest hit inside the grace regenerates above 1.01 before the
  grace ends and is never seen as dead (the "80 s" in hosthurt: it only dies when something pushes it to the minimum again).
- The check `guest_arrival_settled` read `package.loaded["transition"]` in the test mod, which is a different Lua state (always nil):
  it passed at once. Removed; the scenario now waits for the mod's log line `PT|trans guest load -> nil` instead.

## Fix
- health.lua latches the hit: `lethal` is set when health is exactly at the minimum while the guest was seen alive, cleared by a
  heal above 5% and by the load/transition. After the grace, `lethal and cur <= 5` is a death. A living guest at 2-3% that never
  touched the minimum is not dead (check `guest_low_health_not_dead`, health set to 2.5%, held 12 s).
- Mutation `slowdeath`: the old rule. playerhealth 26/28 (20261120-094038-guestdeath-playerhealth-slowdeath): guest_respawned and
  host_guest_respawned_near fail. Fix: 28/28 (20261120-094240-guestdeath-playerhealth).

## Guesses / Unknowns
- A guest healed from the minimum to 2-5% by an item (never above 5%) before the grace ends is still treated as dead.
- Hand check: a guest killed just after arriving in a zone (hazard at the spawn) gets the black screen within ~8 s of the arrival.
