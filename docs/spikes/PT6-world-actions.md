# World-scoped deferred actions

November 2, 2026. Second bounded step from the [MultiVoid comparison](../research/multivoid-applicability.md).
Wire format and protocol 5 are unchanged; this step is Lua-only, on top of the matching native message-lifetime build.

## Scope

`common.defer` captures the current world generation and invokes its callback only if that generation still matches.
The generation advances in the pre-map hook, before the old world's handles can become unsafe. It retains the existing
timer API's delay and cancellation identity. It does not suppress callback errors or introduce another timer loop.

All delayed car callbacks now use this boundary: door close/reset, entry recovery, and both stages of exit-control
restoration. The delayed session handshake timeout and late body refresh do too. Connection retries, post-menu join
and startup bootstrap deliberately keep their existing scheduling: they are meant to lead into another world.

Exit-control restoration also checks that the controller still possesses the captured character before either stage.
Valid old objects alone are insufficient after a replacement pawn is assigned. This prevents the old 150 ms exit
callback from unpossessing a replacement and possessing the old pawn again, or enabling walking on that obsolete pawn.

This is not an object-generation retrofit for every feature. It covers world boundaries and the passenger exit's pawn
identity. Same-world item ownership, unreliable pose streams and network packet generation tags remain later work.

## Checks

`worldactions` loads the actual common.lua in an isolated environment with a deterministic timer queue and map hooks.
It checks current-world execution, timer identity, old-world suppression, a new-world callback and a nested callback
that spans another map change. Normal run: 6/6 (`20261102-150055-passenger-worldactions`). With `nostaleactions`, the
old-world callback executes and the check fails: 5/6 (`20261102-150133-passenger-worldactions-nostaleactions`).

The first two-client `seatepoch` attempt (`20261102-150310-passenger-seatepoch`, 18/21) tried immediate exit/re-entry.
Inspection showed that existing exit-glide gating correctly refuses that re-entry, so the test's reseating assumption
was invalid. No entry gating was removed or bypassed. The corrected test replaces the guest pawn after exit detaches
it, before the delayed restoration runs, then checks that possession remains on the replacement. This is a controlled
replacement test, not a claim of a full natural death/respawn playthrough.

Tests use `D:/PTLanes/passenger`, port 7823, raw garage map without fixture saves. No real-install/save changes.

| Check | Result | Folder under local/test-results |
|---|---|---|
| Replacement pawn survives old exit timer | 20/20 | 20261102-151055-passenger-seatepoch |
| Ownership/world guards disabled | Expected failure, 19/20; old timer repossesses the previous pawn | 20261102-151145-passenger-seatepoch-nostaleactions |
| Six disconnect/rejoin cycles | 36/36 | 20261102-151411-passenger-sessionrejoin |
| Extended replacement and ordinary entry/exit | 24/24 | 20261102-151617-passenger-seatepoch |

The subsequent extended seatepoch scenario also checks an ordinary entry/exit by the replacement, so valid control
restoration passed separately from stale-action rejection. These completed runs had no PT errors or new crash folders.
Full natural respawn, rendered hand play, lag/loss and
the full release suite remain outside these results. No package or protocol change in this step.
