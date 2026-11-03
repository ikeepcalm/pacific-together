# Client feedback, passenger controls and loose items

November 2, 2026. Development candidate based on upstream `ce717a3` (0.8.7); protocol 5, as requested. No release package.

The November 1 results below predate integration of the twelve upstream commits and are historical evidence.

## Observations and changes

- Logbook restoration called `AddEntry` for historical entries. The native notification widget queues a toast per entry,
  with increasingly long delays. `progression.lua` marks baseline chunks with their total count and mutes only
  `UMG_LogBook_NotifMain_C.OnLogbookEntryAdded` while applying that baseline. Fresh discoveries retain notifications.
- Remote characters use `AC_PlayerHealthReceiverHelper_C`, which changes the process-wide player resource manager
  and starts local feedback. Refunding health afterward leaves the red damage frame. `damage.cpp` blocks the remote
  receiver's damage/heal binds before their Blueprint bodies and queues the payload for the existing owner-directed
  message channel. Weak object identities and temporary payload roots protect deferred delivery. Local receivers keep
  the game's normal health, resistance and feedback logic.
- Upstream 0.8.7 supplies the shared E edge dispatch and radio control. Passenger key/shifter selection was subsequently
  restored to native highlights at the owner's request; see the November 2 passenger follow-up below.
  The extra cutscene check requires an actual boolean `CanSkip`.
- Passenger entry/exit glides use the front right door. Exit opens that door and closes it after the transition.
  The game's grounded driver exit is mirrored to the passenger side when ground exists there; the existing driver-side
  fallback remains when the passenger side has no ground. Wall clearance at the mirrored spot remains unverified.
- Loose items previously received yaw at creation; movement updates ignored rotation at a fixed position. `loot.lua`
  now sends full initial poses and rotation-only updates using the existing movement record. Guest copies disable
  independent physics while retaining collision and pickup. Host physics remains authoritative.
- A prior `zonejoin` failure reached the game's 60-second `InitialConnectTimeout` while the host loaded the map
  (`20261101-140459-a-zonejoin`). Raising `ResolutionConnectionTimeout` alone did not cover that phase.
  `session.lua` now configures both initial and address-resolution waiting to 120 seconds on both sides before
  connecting/listening. Established-connection timeout is unchanged. `zonejoin` waits 75 seconds before loading the host
  map; mutation `shortconnect` leaves the original limit in place.

Cooked Blueprint listings and live probes are private under `local/client-controls/`, `local/probe-*.txt` and
`local/item-physics-{host,client}.txt`. The tested tire's simulating mesh is its actor root, so actor pose carries its
physical orientation. Extracted game files are not included in the repository.

## Validation

Test pair: `D:\PTLanes\a`, port 7811, supported executable hash, isolated `garage` fixture. Native build:
`tools\build-native.cmd`, final log `local/build-client-fixes-final.log`.

| Check | Result folder under `local/test-results/` | Result |
|---|---|---|
| Loose tire initial pose, rotation-only changes, kinematic guest copy, pickup on both sides | `20261101-185044-a-itemphysics` | 20/20 |
| Quiet logbook baseline, fresh discovery notification | `20261101-185438-a-progressquiet` | 17/17 |
| Remote hit has no intermediate host health change; local host damage remains | `20261101-191539-a-damagefeedback` | 20/20 |
| Key subscribers, held/repeated presses, callback errors | `20261101-194537-a-keyedges` | 6/6 |
| Native key/shifter highlights, selection priority, passenger ignition/gear intents | `20261101-200504-a-guestctl` | 38/38 |
| Passenger-door interaction, right-side exit, restored walking and matching views | `20261101-200638-a-carexit` | 30/30 |
| One connection through a delayed host forest load | `20261101-200918-a-zonejoin` | 14/14 |
| Session lifecycle and cleanup | `20261101-201326-a-session` | 40/40 |
| Map transition and host exit | `20261101-201546-a-travel` | 23/23 |
| Both player bodies and placement timeline | `20261101-201847-a-body` | 20/20 |
| Guest leaves and rejoins the session | `20261101-202120-a-sessionrejoin` | 36/36 |

The first damage test read local health before the game's deferred hit completed (`20261101-185222-a-damagefeedback`,
19/20). The corrected check waits for the real local loss and verifies it remains afterward.

The first extended native-guard run (`20261101-200218-a-damagefeedback`, 21/22) passed health isolation and the remote
receiver feedback check. Its extra repeated-payload fixture dispatched the same object twice in one frame; the game's
message queue merged that pair before the receiver. The revised fixture retains the object and dispatches again 200 ms
later, exercising separate ticks.

| Disabled fix | Result folder | Relevant failure |
|---|---|---|
| Item pose/physics | `20261101-192354-a-itemphysics-norotationsync` | Initial pose, kinematic copy, rotation-only update; 17/20 |
| Quiet catch-up | `20261101-192811-a-progressquiet-noprogressquiet` | History notification queue returns; 16/17 |
| Dashboard priority | `20261101-193015-a-guestctl-nopasshighlight` | Competing selection wins; 37/38 |
| Passenger-side exit | `20261101-193218-a-carexit-driverexit` | Driver-side position; 29/30 |

The first extended `guestctl` test passed both native highlights and selection priority, but attempted to call the
shipping mod's Lua key callback from the test mod's separate Lua environment. That test was invalid; the replacement
keeps native selection assertions and uses the established intent channel. The interrupted run
`20261101-191945-a-guestctl` is a failure, including a client shutdown crash, and is not a passing regression result.

Rendered inspection confirmed the key outline (`HighresScreenshot00020.png` in the test client's screenshot directory).
Automated intent/pose checks do not establish physical keyboard capture, every rendered transition, audio or Steam
connectivity. Full regression and release certification remain separate gates.

## November 2 integration

All twelve upstream commits from `191fc63` through `ce717a3` are included. The upstream loot scan scheduling,
controller cache, radio, charger, radiation and performance changes remain in place.

The inventory manager's `UnlockState` is the authoritative research graph. The owner's garage save also has transient
chart graphs; selecting the first `BaseGenericGraphState` silently read and purchased against those unrelated states.
Progression snapshots, station purchases and their scenarios now use `UnlockState`.
The guest bench's `OnNodePurchased` is muted before it can print the UI's local duplicate reward.

`Inventory_Tubes_In`, `Inventory_Tubes_Out` and `Inventory_GarageTransfer` now use existing shared-container sync.
Live baseline: host inbox 0, guest inbox 7 before the fix; guest inbox 0 afterward. A host deposit reached the guest,
and removing that item on the guest reached the host. The guest's physical transfer tube has ticking disabled;
the host launches the physical output and normal loot replication displays it to the guest.

The first station run passed research purchase, exact host cost and matching resource checks, then hit an outdated
scenario assumption that an advanced garage save must have an unbuilt station. That run is not an overall pass.
The revised check uses an existing station when both candidates are already built and verifies no duplicate installation.

Passenger-door native interaction: `20261102-092841-a-carexit`, 31/31. This covers entry, interaction to exit,
passenger-side placement on both copies and restored walking. It does not exercise OS keyboard capture.

### Integrated candidate results

Isolated pair `D:\PTLanes\a`, port 7811, protocol 5. Executable SHA-256 was rechecked against `AGENTS.md`.
Native DLL SHA-256: `5E18F71804A05D1EF29CD901ADE9B1EE96F4A4A7B800AEDE5ACE929538037A34`.

| Scenario | Checks | Result folder under `local/test-results/` |
|---|---|---|
| `session` | 40/40 | `20261102-093342-a-session` |
| `stations` | 50/50 | `20261102-093722-a-stations` |
| `safety` | 30/30 | `20261102-094228-a-safety` |
| `sessionrejoin` | 36/36 | `20261102-094430-a-sessionrejoin` |
| `zonejoin` | 14/14 | `20261102-094733-a-zonejoin` |
| `itemphysics` | 20/20 | `20261102-094859-a-itemphysics` |
| `damagefeedback` | 22/22 | `20261102-094957-a-damagefeedback` |
| `progressquiet` | 17/17 | `20261102-095101-a-progressquiet` |
| `keyedges` | 6/6 | `20261102-095118-a-keyedges` |
| `mail` | 22/22 | `20261102-095225-a-mail` |
| `guestctl` | 38/38 | `20261102-095409-a-guestctl` |
| `travel` | 23/23 | `20261102-095605-a-travel` |
| `body` | 20/20 | `20261102-095856-a-body` |

All thirteen scenarios completed without test errors or new crash folders. The separate passenger-door scenario passed 31/31.
The runner SHA-256 snapshot function was checked against the standard `abc` digest under Windows PowerShell 5.1.
A second invocation with forward-slash root `D:/PTLanes/a` refused the busy pair before modifying it.

This is the focused integration and smoke set, not the full release suite or a two-account Steam playtest.
Rendered OS keyboard input, audio, wall clearance beside the passenger exit and a complete hand-played run remain unverified.

Additional current-base anomaly run: `20261102-100021-a-boons`, 26/26.

Sensitivity controls on the integrated candidate:

| Disabled fix | Result folder | Outcome |
|---|---|---|
| Mail containers and passive guest tube | `20261102-100400-a-mail-nomailsync` | Expected failure, 16/22; baseline, deposit, withdrawal and passive-tube assertions fail |
| Remote damage guard | `20261102-100559-a-damagefeedback-nodamageguard` | Expected failure, 19/22; receiver feedback, retained local damage and repeated-payload assertions fail |
| Passenger-door exit | `20261102-100933-a-carexit-nopassdoorexit` | Expected failure, 26/31; detachment, passenger-side placement and subsequent walking fail |

All three controls completed without new crash folders.

## November 2 passenger follow-up

At the owner's request, key and P/D selection again use the game's own highlight components and feedback, as in the
saved pre-integration implementation. The cosmetic shifter's highlight supplies its actual collision and visuals.
Radio control and the shared E dispatch remain available. The ARC screen keeps its normal collision; a 16 ms loop
sets native selection without calling `SetHighlight` from a Blueprint hook.
The original inside/outside flags and muted interaction functions are restored when the passenger leaves.

The guest's look previously stayed in world space while the interpolated car turned beneath it. The car-follow step
now adds its smoothed yaw delta to the seated guest's control rotation, before camera update. Mouse look and pitch are
preserved. On foot, no car rotation is applied; the existing head-sway calculation is unchanged.

`guestctl` now checks native selection and visuals, competing selection, ignition/P/D host authority, view direction
through a turn and the yaw wrap, manual look, and unchanged on-foot view after exit. Mutations are `nopasshighlight`,
`nocarlook` and the existing `noguestctl`. These checks use real game clients, not a mathematical mock.

The first follow-up run (`20261102-112806-a-guestctl`) was stopped after a direct reentrant highlight probe ceased
answering. It also exposed a stale test assumption that the key's highlighted mesh is always `SM_Wagon_01_KeyPhysics`;
the assertions now read the highlight component's actual `HighlightVisuals`. That interrupted run is not a pass.
The next attempt (`20261102-113146-a-guestctl`) passed native selection but also stopped answering with a Blueprint
tick hook installed. Both Blueprint hooks were removed; no such hook is installed by the final implementation.

The corrected headless `guestctl` run (`20261102-113414-a-guestctl`) passed 51/51. The camera kept relative yaw 30 degrees
and pitch -12 through the first turn, then yaw 50 and pitch -20 through the second turn after manual look. Leaving
stopped the car-relative yaw adjustment. A subsequent test-only addition also covers native radio selection.

The disabled-look control (`20261102-113644-a-guestctl-nocarlook`) failed the two turn checks and the dependent manual-look
check: 49/52, no crash. With native dashboard selection disabled (`20261102-114003-a-guestctl-nopasshighlight`), the key,
radio, shifter and competing-selection checks failed while all camera checks passed: 47/52, no crash.

The first `carsync` follow-up (`20261102-114235-a-carsync`) was stopped before driving: its host-side seat check used the
native driver's transient entry transform, 22.3 uu above the seated character. The test now uses X8's measured passenger
seat reference, as production seating already does. Production placement was not changed.

Final validation was resumed later on November 2. `carsync` (`20261102-135055-a-carsync`) could not load the fixture:
the game logged `Missing mounted DLC` and `SAVEFILE CONTAINS MISSING ENTITLEMENTS`. The rendered `guestctl` retry with
the existing `local/fixtures-fresh/garage` save was rejected by the same entitlement check. Both runs were stopped;
neither is a passing result. No entitlement, save or real-install changes were made. The completed evidence for the
gameplay change remains the 51/51 headless run and the two failing mutation controls above; the final rendered run,
driving regression and full release suite remain unverified. No release package was built.

## November 2 stationary passenger shaking

The owner reported shaking even with the car parked. A separate pair at `D:/PTLanes/passenger`, port 7823, opened
`/Game/Maps/RunProto/RB_Garage` directly without a fixture save. The supported executable hash was verified. The owner's
active pair was left running; its test console did not answer, so no runtime changes were applied there.

Reproduction: seated guest, `t.MaxFPS 12`, host chassis made kinematic, host car moved 1 uu and returned after 500 ms.
The guest's FP camera relative offset was sampled for eight seconds. Before the fix, its maximum and its maximum after
five seconds both reached 17.3205 uu (all three axes at their 10 uu clamp), across 91 samples. The isolated spring also
diverged with zero target at 12/15 FPS. This proves one cause of stationary shaking; it does not establish that every
possible movement-replication writer conflict is absent.

The semi-implicit spring used the whole frame as its integration step. With K=247 and damping=22, its stability limit
is about 66 ms. Frames longer than that amplify an initial displacement instead of damping it. Only spring integration
now uses steps no longer than 1/120 s. Its gain, damping, movement interpolation, camera yaw and seat positioning remain
as before.

After a full restart, the same 12 FPS perturbation peaked at 0.8597 uu and settled to zero in the five-to-eight-second
window (97 samples). `scenarios/passengersway_probe.lua` preserves the live assertion: start after seating, apply the
host perturbation, then call `check()` after eight seconds. It requires enough samples and tail displacement below 0.2 uu.
The before/after runs use real host and guest game processes with headless rendering, not a mathematical mock.

With FPS caps of 30 and 60, the probe also passed: peak offsets 0.6094 and 0.4651 uu, tail zero, 234 and 341 samples
respectively. The sample counts do not establish a sustained 60 FPS. Baseline session archive:
`20261102-140726-passenger-repl`; corrected session: `20261102-141113-passenger-repl`. Both sessions stopped cleanly,
15/15 lifecycle checks, no new crashes. Full driving, rendered hand play and the release suite were not run for this fix.

Thrown-item trajectory, garage part lockers, remote wheels and passenger windshield follow-up: [PT7](PT7-motion-parts.md).
