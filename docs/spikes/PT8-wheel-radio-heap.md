# PT8: wheel motion clock, driver-style passenger radio and Lucky Junk Heap

2026-11-02; supported v1.15 executable/build unchanged.

## MultiVoid base and wheel fix

Adapted the fixed-delay snapshot clock from MultiVoid `coop/props/active_drive.h`, pinned revision
`4fbf1acf0e0ec7d14350132cd3de01d6a86aa552`, into `wheelmotion.lua`. Preserve its MIT notice in
`mod/PacificTogether/MULTIVOID-LICENSE.txt`; the package script includes it. Newest snapshots replace pending motion
instead of accumulating a FIFO, and rendering advances independently from packet arrivals.

The previous wheel implementation restarted interpolation from the displayed transform on every message and interpolated
spin together with steering as one shortest-path quaternion. This can mix steering/spin axes and alias complete turns.
The host now samples native angular position/velocity, removes rolling from the native mesh transform, and sends steering /
suspension separately. The guest unwraps scalar phase using angular velocity and composes rotation about the native local
pitch axis with interpolated steering. A 100 ms render buffer matches the car body's approximate delay; gaps extrapolate
rotation for at most 100 ms. Old timestamped snapshots are rejected. The reliable car baseline advertises the host's car
identity; a motion packet for another car is discarded.

Native `g.motion.*` / test `t.latest.*` messages must fit one chunk (1000 bytes). Each controller's weak-identity Link holds
one unsent packet per motion kind, drained before bulk chunks. Receive queues also keep only the newest pending motion per
sender/kind. These messages bypass Lua's gameplay-message window and its ACK count; native chunk ACKs and their bounds
still apply. The matching native DLL is needed for the new motion semantics.

At this PT8 checkpoint the substrate was still the game's reliable RPC connection; [PT9](PT9-multivoid-protocol5.md) adds negotiated datagrams on the existing tunnel. This is NOT a separate unreliable network channel: packets
already accepted by UE can still wait for retransmission under loss. Changing the game's UFunction flags or replacing the
Steam transport was not necessary for this fix and was not attempted.

## Radio

Passenger radio ExtraData.IsInside is temporarily false, the same adaptation as ignition/shifter, restored on leaving.
Native highlight selection and rendering run through the existing HighlightManager. Host-authoritative commands call the
attached radio's TogglePlayback / ChangeChannel / VolUp / VolDown; ordinary radio.lua state/music sync brings results back.
Passenger keys are taken from the game's InputSettings ActionMappings at mod startup. X changes station while aiming at the
radio, and otherwise remains passenger exit. Disabled highlights/menu context suppress radio hotkeys.

## Lucky Junk Heap

The host arbitrates a single guest claim: actor/world identity token, increasing request serial, character identity,
proximity, availability and native K2_ShouldHighlight. A hold uses the stock highlight duration. Cancellation, disconnect,
pawn replacement, map change and an eight-second safety bound release the claim; a repeated serial cannot grant again.

Bound delegates were verified against the cooked Blueprint with tools/pak + tools/kdis, research files only in local/:
`0 = OnInteractStart` (search sound), `1 = OnInteractEnd` (stop sound), `2 = OnInteractLong` (prize calculation). The host
runs these exact actor entry points without taking over the host player's camera/HighlightManager. Rewards and random rolls
stay in the native host graph. Guest actor/dispenser ticks and gameplay entry points are suppressed; loot.lua supplies the
host's spawned items. Timelines mirror playback position, direction/rate and length, running update callbacks without event
or finished callbacks. Idle positions are dirty-gated. Search/lid sound callbacks are presentation-only; charge sound is
replicated on the first charge edge, without invoking the guest's economy graph.

## Evidence

- Final rendered integration through the UDP chaos tunnel (`lag=150 loss=2`): **39/39**,
  `local/test-results/20261102-195029-passenger-tunnel-drivev2`. Both tunnel_carried and tunnel_lag_seen passed;
  observed RTT was about 350-375 ms with actual dropped packets. This final run includes the delegate guard,
  audio presentation replay and every wheel/radio/heap check. It is a functional network run, not a visual FPS benchmark.

- Native-callback guard follow-up `heapv2 -Headless`: **23/23**, `local/test-results/20261102-194605-passenger-heapv2`.
  In addition to prize/animation checks, the test directly invokes the guest's real OnInteractLong delegate and verifies
  that the native mute guard blocks it. Blueprint calls to native component functions can bypass ProcessEvent, so muting
  only InteractPressed/Released was insufficient. Presentation-only search sounds briefly unmute the actor on the game
  thread, call the verified audio-only delegate, and restore the complete gameplay mask even on a Lua error.
- Negative timing control `wheelclock -Mutate oldwheelclock -Headless`: **8/18**, expected failures in all nine
  constant/jitter/reverse spin checks and bounded-gap behavior; `local/test-results/20261102-193927-passenger-wheelclock-oldwheelclock`.

- Reliable-channel regression `channel -Headless`: **21/21**, `local/test-results/20261102-193728-passenger-channel`; ordered delivery, sender identity, 20 KB binary payload and oversize rejection.

- `wheelclock -Headless`: **18/18**, `local/test-results/20261102-172036-passenger-wheelclock`.
  Constant/reverse angular motion and jitter at 15/30/60/144 FPS; complete-turn unwrapping, bounded extrapolation,
  old-snapshot rejection, native steering axle invariant. These are deterministic timing/math checks, not FPS benchmarks.
- `heapv2 -Headless`: **22/22**, `local/test-results/20261102-192638-passenger-heapv2`.
  Native interaction/prizes, matching items with guest dispenser disabled, animation, duplicate request, early cancel and
  previous-world token rejection. The raw-map fixture opens the tutorial highlight gate on both peers and uses the native
  ResetConsolationPrize; it does not replace reward calculation with a fake result.
- Final rendered/audio integration `drivev2`: **32/32**,
  `local/test-results/20261102-193336-passenger-drivev2`. Burst of 100 native motion updates delivered only value 100;
  actual rolling wheel axle stayed horizontal while front steering matched the native 24-degree input; native passenger
  radio selection, on/off, volume both ways, station change and matching track; all heap checks above. No PT errors/crash.

An earlier rendered iteration stalled on passenger entry during an inspection that read visual-array state; the final
scenario resolves the radio attached to the actual car and checks the native highlight state instead. The cause of that
single earlier stall was not established, so the final pass does not establish absence of every hang.

No human full run, sustained frame-rate benchmark or full release suite was performed for this change.
Real keyboard/controller presses were not automated; mapping lookup and the resulting host commands were checked.
