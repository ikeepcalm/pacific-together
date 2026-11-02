# W8: Healer and Charging boons

2026-11-01. Shipping code: `world.lua`, shared replication setup in `common.lua` / `anomalies2.lua` / `anomalies3.lua`.
Scenario: `boons`, fixture `garage`, mutation `noboons`. Current development protocol 5.
November 1 evidence below was collected before upstream 0.8.7 integration, then using protocol 6.

## Observations

- The installed game and isolated pair matched build 21896301 and the executable SHA-256 in `AGENTS.md`.
  The cached UE4SS archive matched the pinned SHA-256 in `setup-test.ps1`.
- Runtime class inspection showed `BP_Boon_Healer_C` and `BP_Boon_Charging_C` inherit `BP_Base_Boon_C`, then Actor;
  neither inherits `BP_Base_Hazard_C`. Before the change, host-spawned instances had `bReplicates=false`,
  `RemoteRole=0`, `bAlwaysRelevant=false`; neither class had an instance on the guest.
  Local probe: `local/probe-boons.lua`; class/property readings: `local/BP_Boon_Healer_C.txt`,
  `local/BP_Boon_Charging_C.txt`.
- Both classes expose `Sphere1`, `OutOfJuice` and a remaining-power field. `EndHeal(false)` / `EndCharge()` stop
  their local timer-driven work; depletion events are `OnRunOutOfJuice()` / `PowerDrainedCompletely()`.
- The first scenario attempt crashed because its test-only `PTNative_MsgToHost` calls omitted the controller address.
  The existing native binding requires `(address, kind, data)`. The scenario was corrected before the passing run.
  Failure evidence: `local/test-results/20261101-133439-a-boons`.

## Implementation

- Reuse native actor replication for these two boon classes. The guest removes its independently spawned copies
  after the existing world-state grace period. Replicated copies disable overlap events and stop their heal/charge
  timer and actor tick; the host owns resource changes.
- The existing world snapshot carries class, location, remaining power and depletion. Guest copies match by class
  and location, since runtime replication can assign a different actor name. No additional transport or frame loop.
- The common replication setup checks movement, relevance and update frequency even for actors that already have
  a remote role. It avoids reconfiguring an actor once those settings match. The three existing passes reuse it.
  Guest boon-state application skips class enumeration when the snapshot contains no boons.

## Verification before repository update

The following results were collected on base `0a1fa70` (0.0.8). They do not certify the later 0.8.5 base.

Commands use the isolated pair with `-Root D:\PTLanes\a -Port 7811 -Headless`.

| Command additions | Actual result | Evidence under `local/test-results/` |
|---|---|---|
| `-Scenario boons -Fixture garage` | 26/26 PASS | `20261101-133823-a-boons` |
| `-Scenario boons -Fixture garage -Mutate noboons` | Expected failure: 18/26; exit 1, no crash or mod errors | `20261101-134242-a-boons-noboons` |
| `-Scenario boons -Fixture garage -Tunnel "udp lag=150 loss=2"` before runner fix | 30/32; both `tunnel_carried` checks FAIL | `20261101-134434-a-tunnel-boons` |
| `-Scenario boons -Fixture garage -Tunnel "udp lag=150 loss=2"` after runner fix | 32/32 PASS | `20261101-134713-a-tunnel-boons` |
| Same tunnel options plus `-Mutate tunnelbypass` | Expected failure: 30/32; only both `tunnel_carried` checks fail | `20261101-134904-a-tunnel-boons-tunnelbypass` |
| `-Scenario session` | 40/40 PASS | `20261101-135223-a-session` |

The mutation fails configuration, visibility, local-copy cleanup, passive simulation, remaining power, depletion,
depleted power and removal checks. It disables only the new boon coverage rather than forcing a generic failure.

The first lag/loss attempt exposed a runner defect: `PT_JOIN` still pointed to `127.0.0.1`, while only the test bot's
join helper was changed to `10.77.0.1`. The mod autojoins independently of that helper. Gameplay counters stayed
`in=0 out=0` although the tunnel probes reported delayed pongs. The runner now chooses the tunnel address for
auto-joining scenarios too, retaining the direct address only for the existing `tunnelbypass` mutation.
The rerun recorded gameplay packets in both directions (host final `out=1432 in=491`, delayed packets and drops),
and both `tunnel_lag_seen` and `tunnel_carried` passed.

The focused scenario creates two Healers with different remaining power plus a Charging boon, more than 15000 uu
from the players. The charger starts replicated with incomplete movement/relevance settings. The guest also creates
three independent copies. Checks cover mesh presence, exactly one copy per location, disabled local tick/overlaps,
distinct host resource values, depletion, host-side removal and preservation of the other Healer.

## Local tooling

The existing Python, PyYAML, native DLL, isolated pair and pinned UE4SS cache were reused. The read-only
`coop-anything` and `pacific-game` MCP servers were registered for Codex; stdio initialize/list-tools checks returned
9 and 40 tools respectively. Co-op Anything's MCP unit suite passed 13/13. Twelve local `coop-*` skills were linked
into the user's skill directory; no software download or account login was needed.

## Limits and remaining work

- This does not identify the owner's informal "tictac" report or cover every `BP_Base_Boon` subclass, DLC or Expeditions.
- Matching assumes stationary instances of the same class do not overlap within 100 uu. Moving/overlapping boons
  need replicated identity. Resource refill/revival after depletion is unverified.
- Mesh presence and property checks are headless evidence; rendered effects, healing/charging sounds, real car
  contact, and the charger's inventory conversion need separate checks. No frame-rate improvement is claimed.
- Full release certification still requires the gates in `RELEASING.md`; this work does not constitute a release.

## Repository synchronization

The checkout was updated by fast-forward to `3348579` (0.8.5), matching both origin/main and upstream/main, on November 1.
The local changes were preserved in a backup stash and reconciled with the newer weather/ambience code and player documentation.
The pinned Co-op Anything submodule is `b494a3f3dfd1cee76fcd869ebe217760be2d0e18`.
Before the update, additional smoke results were body 20/20, sessionrejoin 36/36, and zonejoin 12/14 (host/client zone connection failed); safety was not reached.
These older smoke results do not validate the updated source.

After synchronization, `tools/build-native.cmd` rebuilt the native DLL successfully (runtime version 0.8.1, as in upstream).
The copied DLL matches the build output SHA-256 `0eeb0f425a652a5b9f3acff469e8a6b16228fcd982f8addf0b4c70acd4b88914`.
`boons -Fixture garage -Headless` passed 26/26 on 0.8.5 / development protocol 6:
`local/test-results/20261101-142350-a-boons`. No crashes or mod errors. The pinned playbook MCP unit suite passed 13/13 again.
The complete smoke set, lag/loss and mutation runs have not been repeated on the updated base; no release certification is claimed.
