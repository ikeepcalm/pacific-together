# Contributor tasks

Reviewed against 0.0.7 on 2026-10-24. This list tracks remaining work, not release readiness;
[PLAN.md](PLAN.md) defines scope and [RELEASING.md](RELEASING.md) defines the gates.

## Taking a task

1. Read [../CLAUDE.md](../CLAUDE.md), then use [DEVELOPING.md](DEVELOPING.md) for setup.
2. Check current code and open PRs. Claim a bounded task with a draft PR named `<id>: <title>`.
3. Keep changes on a topic branch. Coordinate edits to shared session, transport and module-registration files.
4. For gameplay changes, provide a focused two-instance scenario and a mutation that fails the relevant check.
   Follow [TESTING.md](TESTING.md); include actual result folders and remaining limits in the PR.
5. Use [LANES.md](LANES.md) when work is split across lanes. The owner reviews and merges.

## Current priorities

Automatic host-song file sharing: [PT11](spikes/PT11-shared-custom-music.md).
the owner has reserved the live two-client playback check.

November 1 continuation: Healer/Charging visibility and host resource state are covered by the focused `boons`
scenario. Current evidence and remaining anomaly limits: [W8-boons](spikes/W8-boons.md).

Historical protocol-5 evidence and the MultiVoid architecture steps: [PT9](spikes/PT9-multivoid-protocol5.md).

Wheel motion, passenger radio and Lucky Junk Heap follow-up: [PT8](spikes/PT8-wheel-radio-heap.md).

Thrown items, garage part lockers, wheel visuals and passenger windshield: [PT7-motion-parts](spikes/PT7-motion-parts.md).

Client notifications, damage feedback, passenger controls and item physics: [PT4-client-interactions](spikes/PT4-client-interactions.md).

| Work | Starting points | Completion evidence |
|---|---|---|
| Guest anchor duplication | 2026-11-17: no repro (`anchordup` 23/23); a guest-fed anchor is banked once (`exitdeposit`, mutation `noanchorbank`) | Close after a hand run confirms |
| Guest tutorial progress | 2026-11-17: route planner / mechanic mode steps done by the guest reach the host (`storytask`, [spike](spikes/tutorial.md)); CraftedItem, scanning, PlayerInCar unchecked | Rendered guest opens the planner; remaining step kinds |
| Passenger re-entry pose | 2026-11-17: headless `zoneexit` keeps the guest on the passenger seat after re-entry (37/37) | Rendered pose check |
| T06: full-run playtest | Packaged `PacificTogether.exe`, `tools/play-local.ps1` | Garage, junctions, gateway, death/failure, leave/rejoin; both logs and observed defects |
| T10 / R10: DLC handshake and compatibility | `session.lua`, game files from an authorized copy | Report ownership; establish which base/DLC combinations actually load, without assuming support |
| F1: current lag/loss regression | 2026-11-17 at 150 ms / 2%: session 46/46, runloop 55/55, lootsync 40/40, playpath 45/45, carsync 51/53 (fixture cosmetics, fixed since); NOTES "2026-11-17 unattended" | Repeat on the release candidate |
| L9: two-hour soak | 2026-11-17: 39 runs, 2 crashes (same AV class, hardened in d29730e, unproven), 3 bot flakes (fixed); NOTES "2026-11-17 unattended" | A clean 2 h soak on the candidate |
| Q9: firewalled crash proof | `tools/q9-firewall.ps1`, `crashfw`, [spike](spikes/M2-safety.md) | Owner's elevated test-copy run verifies the upload block |
| T01: reproducible atlas build | `tools/kdis`, `tools/pak`, `local/atlas/tools` | A fresh clone builds its atlas from its own game copy; no game data committed |

These are work candidates, not claims that every suspected issue remains reproducible. In particular, rerun old flaky
checks on current code before assigning a fix. Open evidence gaps are collected in [../NOTES.md](../NOTES.md).

## Earlier task IDs

The original October 20 backlog is superseded. Keep these IDs for old branches and reports:

| IDs | Current disposition |
|---|---|
| T02 | Changelog exists: [../CHANGELOG.md](../CHANGELOG.md) |
| T03 | Suite runner exists: `tools/run-suite.ps1` |
| T04 | Launcher has version display, uninstall and log collection |
| T05 | Animated survivor body implemented in `survivor.lua` |
| T07 / L8 | Steam lobby/tunnel/join implemented; two-account traffic verified October 23; repeat for release validation |
| F3 / F4 / F5 | Tourist observation, map markers, guest health/death implemented |
| L1 / L2 / L4 / L5 / L6 | Car, intent channel, car resources, backpack persistence and run loop implemented |
| L3 / L7 | Loot and anomalies implemented with gaps; focus on reproducible defects and uncovered hazards |
| R1-R9 / R11 | Initial research incorporated into [spike reports](spikes) and gameplay modules; investigate missing behavior rather than repeat the initial survey |
| F2 | Socket-counter/tunnel coexistence remains an investigation; verify current hooks before changing transport |

Guest driving, guest route planning, remaining DLC/anomaly coverage and Expeditions are later scope. Do not treat the
old cost estimates or milestone version numbers as scheduling commitments.
