# Testing

Use isolated test copies, never the real install or saves. Setup and the pinned UE4SS build are in
[DEVELOPING.md](DEVELOPING.md). Steam must be running. Results are evidence for the code tested, not a claim that every
player interaction works.

## Running

```powershell
tools\run-test.ps1 -Scenario boot
tools\run-test.ps1 -Scenario carsync -Fixture garage -Headless
tools\run-test.ps1 -Scenario zoneexit -Fixture coop-zone -Headless
tools\run-test.ps1 -Scenario mail -Fixture garage -Headless

tools\run-test.ps1 -Scenario boons -Fixture garage -Headless
tools\run-test.ps1 -Scenario boons -Fixture garage -Mutate noboons -Headless
tools\run-test.ps1 -Scenario listen -Mutate skipconnect -Headless
tools\run-test.ps1 -Scenario listen -Tunnel "udp lag=150 loss=2" -Headless
```

The mutation should fail its intended check. Shipping UE has no usable `NetEmulation.*`; use the tunnel for lag/loss.
For auto-joining scenarios the runner sets `PT_JOIN` to the tunnel address too. Require `tunnel_carried` as well as
`tunnel_lag_seen`: successful delay probes alone do not prove that gameplay used the tunnel. Mutation `tunnelbypass`
keeps the direct join address and must fail `tunnel_carried` on both sides.
Steam-specific scenarios are separate: `steamsession` tests the join flow using loopback UDP, while two-account
Steam transport needs the human check in [spikes/PT2-steam.md](spikes/PT2-steam.md).

Options: `-Root` (default `C:\PacificTogetherTest`), `-Port`, `-Clients 1|2`, `-Seconds`, `-Headless`, `-Fixture`,
`-FixturesDir`, `-Mutate`, `-Tunnel`, `-ResultsDir`, `-KeepOpen`. Scenario defaults live in `tools/run-test.ps1`;
unknown scenarios default to two clients and 300 seconds. Headless uses `-nullrhi -nosound`; visuals/audio need a rendered run.

The runner refuses a busy root and stops only processes from its test copies. It archives logs, crash folders,
screenshots and `summary.txt` under `local/test-results/<timestamp>-<scenario>[-<mutation>]/`. Exit 0 means all checks passed.
Config edits and fixture saves are restored after the run.

**Watch every started run:** inspect new `PT|check` lines and both processes at least every five minutes. If no new check
appears, investigate and stop a stuck run. The runner also aborts a scenario that fails to load or produce a plan
within three minutes after boot. Do not leave an unobserved run waiting out its timeout.

## Suite

```powershell
tools\run-suite.ps1
tools\run-suite.ps1 -Only carsync,carexit,runloop
```

The suite runs its configured scenarios headless, with their fixtures, sequentially on one pair. It writes
`local/test-results/suite-<timestamp>.txt` and exits nonzero on failure. `-Shard 1/2` and `-Shard 2/2` split that list;
each shard needs its own `-Root` and `-Port`. Inspect the list in `tools/run-suite.ps1` before interpreting a suite pass:
it excludes some probes, mutations and human/Steam paths.

Run the focused scenario and mutation during a change; after integration run the smoke set from [LANES.md](LANES.md).
Run the full configured suite once before a preview/release, then rerun only affected failures after fixes.

## Scenario and log contract

New scenarios live in `test/PacificTogetherTest/Scripts/scenarios/<name>.lua`, returning
`function(T) return steps end`. `T` exposes helpers such as `onMap`, `join`, `console` and fixture loading.
Steps are `{check=id, timeout=s, cond=fn, tick=fn(t)}`, `{wait=s}` or `{run=fn}`; checks poll on the game thread.
The harness counts planned checks automatically. Legacy scenarios remain in the test mod's `main.lua`.

| Log marker | Meaning |
|---|---|
| `PT\|boot` | Mod version/protocol and successful load |
| `PT\|plan side=... checks=N` | Expected check count |
| `PT\|check side=... name=... result=PASS\|FAIL` | Assertion result and details |
| `PT\|done side=...` | Scenario finished |
| `PT\|error` | Fails the run |
| `PT\|snap` | Save/config file hash snapshot for write-protection checks |
| `PT\|actors` | Actor survey exported to CSV |
| `PT\|status`, `PT\|info`, `PT\|loadmap` | Diagnostic state, not proof of success |

A pass requires boot/plan/done on every side, all planned checks passing, no errors and no new crash folder.
`PT_ROLE`, `PT_SCENARIO`, `PT_HOST`, `PT_STATUS` and `PT_MUTATE` configure the test processes.
Assert player count, map and role before checking sync. Mutations must break the relevant behavior rather than merely
force a generic error. Report the failed assertion as well as the nonzero exit.

## Parallel lanes

- Create a pair from the lane worktree:
  `tools\setup-test.ps1 -Root C:\PTLanes\<lane> -LinkFrom C:\PacificTogetherTest\client1 -UE4SSZip <main>\local\cache\ue4ss\zDEV-UE4SS_v3.0.1-1181-g83330635.zip`.
- Give each pair a unique port; otherwise guests can join another lane's host.
- Use `-ResultsDir <main>\local\test-results` to retain evidence after removing the worktree.
- `PT_SLOTS` defaults to four simultaneous runs. Waiting for a slot is not a completed test.
- Pass `-FixturesDir <main>\local\fixtures` to the runner in a worktree. Game MCP can locate the main checkout automatically.

## Live console

Start `tools/run-test.ps1 -Scenario repl -Seconds 3600 -Headless` (add your root, port and fixture).
Use `tools/repl.ps1 -Side host|client -Code "state()"` or `-File probe.lua`; expressions return values and blocks can
use `out(...)`. Stop with `tools/repl.ps1 -Stop`. Console exit codes: 0 success, 1 Lua error, 2 no answer.
The console is also available during automated scenarios. [GAME-MCP.md](GAME-MCP.md) exposes it as tools.

`-Reload` exists for Lua-only experiments, but repeated reloads have crashed live sessions. Save useful logs and restart
for normal bug-fix validation; native changes always require a restart. Exploratory reads can also crash on stale game
objects: `pcall` does not catch native access violations.

## Fixture saves

Fixtures are git-ignored `.sav` files plus `fixture.txt`/optional `fixture.json` under `local/fixtures/<name>/`.
The runner temporarily replaces the host copy's SaveGames directory, restores it afterward (or recovers a leftover
`.ptbak` next launch), and archives the run's saves as `fixture-saves-after`.

| Name | Slot | Map | State |
|---|---|---|---|
| `garage` | 7 | `RB_Garage` | story mode, car and character, stocked by the game's debug events (biggest container 457 items, anchor juice +5 each); no missions done |
| `zone` | 8 | `Rural_Forest_Radio_Scylla_02` | a real run map (started by the game's own `TravelToNextLeg`), car and character, ARC charge about 4 |
| `gateway` | 9 | `Rural_Forest_Radio_Scylla_02` | `zone` with the ARC `CurrentCharge` = 7.0 (`MaxCharge` 1.0, so the screen counts it charged); the game's own exit selection (`GobblerScreen:OnExitUseComplete(portal)`) sets the gateway (2026-10-24); the nearest portals are ~1.1 km from the car |
| `coop-garage` | 2 | `RB_Garage` | **for hand play**: the owner's own mid-story save (tutorial done, quests up to Q03; the owner copied it in), host backpack with the common tools, a guest tool kit in the car trunk (a guest's own backpack is not kept between local launches: its login name changes) |
| `coop-zone` | 3 | `Wilderness_Forest_06` | `coop-garage` sent out by the game's `TravelToNextLeg`: 32 hazards, 4 exit portals |
| `coop-gateway` | 5 | `Wilderness_Forest_06` | `coop-zone`; a selected gateway is not saved, so the test mod's repl scenario reopens it on load for any fixture named `*gateway*` (nearest portal, ~225 m; this car's ARC reads 0/0) |
| `coop-return` | 6 | `RB_Garage` | back from `coop-gateway` through the exit portal's own return, loot in the car |
| `garage-return` | 1 | `RB_Garage` | back from a run through the exit portal's own return (`TravelToGarage(2, ...)`), loot in the car (trunk 129 items on the guest); fixture.txt has the steps |


`T.loadFixture(name[, fromMenu])` waits for the map, character and car. `fixtureload -Fixture garage,zone,gateway -Clients 1`
checks the built-in fixtures; mutations are `nofixture` and `wrongfixture`.

Use MCP `fixture_save` or follow the fixture's own recipe in a test copy to remake it. Never read the real saves as an
automatic fallback; the `coop-*` fixtures were supplied by the owner. `UserNewGame(slot, CHALLENGE)` has hung/crashed
in experiments, so do not use it as an assumed working fixture path.

## Crash dumps

`python -I tools/dmpstack.py <ue4ss/crash_*.dmp> <folder-with-UE4SS.dll-and-UE4SS.pdb>` scans the crashing stack and
symbolizes UE4SS/game frames. It is a stack scan, not a full unwind. Keep both players' logs before restarting;
UE4SS overwrites them. Crash-upload research and outstanding proof: [spikes/M2-safety.md](spikes/M2-safety.md).

## Playing by hand

`tools/play-local.ps1` opens two windowed test copies side by side. With no fixture, load a save on the host and the
guest autojoins; `-Fixture coop-garage|coop-zone|coop-gateway` loads an owner-supplied test save. Options include `-Root`,
`-Port`, `-ResX` and `-ResY`. Close both games or press Ctrl+C to end the session and restore saves.
This helper does not give the guest a live console; use MCP for live debugging.

## Live bug-fix loop

1. Start MCP `session_start players=2 headless=false seconds=3600` with the required fixture.
2. Let the owner reproduce the issue and leave the broken state intact.
3. Compare the relevant live state on both sides. Prove the suspected cause with a bounded probe when possible.
4. Copy useful logs, patch, then `session_stop` and restart. Do not hot-reload this session.
5. Retest by hand and add focused regression coverage. Record observations separately from guesses in [../NOTES.md](../NOTES.md).
