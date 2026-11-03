# PT10: author 0.8.8 and local MultiVoid integration

2026-11-03. Base: `38fbaa0`, including all seven commits after local `18e3f07`.
The owner confirmed that the repository author alone changes the protocol. The current author protocol is **6**.
PT9 records the earlier protocol-5 checkpoint; its historical runs do not certify this candidate.

## Integration

- Keep the cloud fixes for transition health, gateways, live blueprint unlocks, radio acoustics, storage refill,
  predictive passenger entry, persistent guest drops, keypads, anchor effects and the embedded single-exe launcher.
- Keep the local weak-object leases, replay/world/pawn fencing, applied baselines, priority queues, motion datagrams,
  wheel clock, radio actions, junk heap and part-locker synchronization.
- Combine drop formats explicitly: author `N` with seven fields and keyed `K` adoption remains the baseline.
  Negotiated throws append velocity/rotation before the adoption key (15 fields). Six/14-field replacement paths remain
  accepted. A pitch value cannot be mistaken for a key. Adoption records use weak leases and replica tombstones.
- Drop reporting waits until applied-baseline admission; an early local drop cannot be permanently marked sent while the host rejects gameplay. The regression drops before admission and checks host delivery plus one surviving guest actor.
- Predictive seating uses the same world and pawn guards as local glide callbacks. Keypad requests use the intent
  envelope only when the host negotiates it; the author baseline still sends the original request.
- Keep the private `player_id.txt` out of Git and package payloads. The original local work is backed up under
  `local/sync-backup-20261103-084611/`, with its pre-sync stash retained.

## Validation

Both test-pair executables match the supported
SHA-256 `568bb63476c6de5fc2b1878572a655dd631dd25bb44fe304e3d96a51f6b98f7e`.
Pairs: `D:/PTLanes/passenger` (7823) and `D:/PTLanes/a` (7811), always `-NotInstalled`.
Native rebuilt with `tools/build-mod-fast.ps1 -MainBuild C:/Dev/pacific-together/native/build`.
Launcher compiled with the installed .NET Framework compiler. Native DLL SHA-256:
`aa3d4626acda54b8d02eec53e9bd8d8f8ab534ced5375d3e2db5732af381c462`.

The old local garage fixtures report `SAVEFILE CONTAINS MISSING ENTITLEMENTS` and cannot load on the current installed
content set. Those attempts were stopped and archived. Fresh garage/zone fixtures were created through the game's own
SaveGame in the isolated pair, under `local/sync-fixtures`; original fixtures, the real install and real saves were preserved.

This task is integration validation, not release certification: no full configured suite, human full run, two-account
Steam relay check, soak or crash-upload proof is claimed.

## Selected results

Archives are under `local/test-results/`.

| Check | Result | Archive |
|---|---|---|
| Production Lua compile, author protocol, weak identities and network parser sandbox | 25/25 | `20261103-085616-passenger-multivoid` |
| Predictive driver-door entry and passenger exit | 29/29 | `20261103-085944-passenger-carseat` |
| Drop created after loot purge but before full baseline; host delivery and one surviving guest actor | 24/24 | `20261103-091141-passenger-dropfall` |
| Throw velocity, landing, original actor adoption, lockers and windshield; 150 ms / 2% loss | 34/34 | `20261103-091322-passenger-tunnel-motionparts` |
| Guest keypad presses the host keypad | 20/20 | `20261103-091537-passenger-keypad` |
| Rendered radio controls, wheels, junk heap, datagrams; 150 ms / 2% loss | 41/41 | `20261103-092242-passenger-tunnel-drivev3` |
| Guest and host anchor pulls, including effect state | 23/23 | `20261103-091742-passenger-anchordup` |
| Original cloud protocol-6 guest with integrated host | 22/22 | `20261103-091613-a-legacy5` |
| Original cloud protocol-6 host with integrated guest | 22/22 | `20261103-091816-a-legacy5` |
| Keypad hook disabled: intended host press assertion fails | 19/20, expected failure | `20261103-092447-a-keypad-nokeypad` |
| Baseline wait disabled: intended host drop assertion fails | 23/24, expected failure | `20261103-092121-a-dropfall-nobaselinewait` |
| Session | 40/40 | `20261103-085852-a-session` |
| Save protection | 30/30 | `20261103-090404-a-safety` |
| Repeated reconnects | 36/36 | `20261103-090634-a-sessionrejoin` |
| Zone join | 14/14 | `20261103-090910-a-zonejoin` |
| Travel | 23/23 | `20261103-091106-a-travel` |
| Player bodies | 20/20 | `20261103-091401-a-body` |

The mixed-peer helper uses `-PeerProtocol 6` and the exact `38fbaa0` cloud Lua snapshot. Its native sources are
unchanged from `18e3f07`; the recorded historical DLL is used. The scenario retains its historical `legacy5` filename,
but these two runs boot **0.8.8 / protocol 6** on both peers. They do not claim protocol-5 interoperability.

The first drop regression exposed a real one-shot request loss before host baseline admission. Its corrected check
waits for the loot purge, creates the guest's drop during visual loading, then requires host delivery and a single guest
actor. Disabling only the new wait reproduces `guest_drop_on_host_ground` failure. A preliminary attempt dropped before
the initial loot purge and was not a valid setup for that regression; its archive is retained without a pass claim.

A headless `drivev3` run passed 39/41, failing station change/follow checks. That scenario needs its documented rendered
audio-engine mode; the headless run is not used as radio validation. The rendered rerun passed 41/41, including both radio assertions. Audible song identity/position still requires listening; this run verifies the engine state and gameplay assertions.

All selected positive runs passed: six integration smoke scenarios, seven focused scenarios, and both author-6 mixed-peer directions. Both negative controls failed only their intended assertion. No game processes remain; the mixed-peer junctions were restored.
