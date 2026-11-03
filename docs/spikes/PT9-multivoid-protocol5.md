# PT9: MultiVoid architecture at the historical protocol-5 checkpoint

Historical evidence below predates the author's protocol-6 release. On 2026-11-03 the owner confirmed that only the repository author changes the protocol; current integrations use 6. See [PT10](PT10-cloud-local-integration.md) for the merged candidate.

2026-11-03. Continuation after PT5 (message lifetimes) and PT6 (world-scoped callbacks).
Pinned MultiVoid source remains `4fbf1acf0e0ec7d14350132cd3de01d6a86aa552`; MIT notice ships with the mod.
Only isolated `D:/PTLanes/passenger`, port 7823, and supplied test fixtures are used.

## Compatibility contract

D26 fixes `PROTOCOL_VERSION = 5`. PT1 chunks, PT1A acknowledgements and old feature payloads remain supported.
The guest appends optional `caps=mv` to the existing hello, which historical peers ignore. Only an admitted guest
with that field receives `g.net.cap`. The response confirms capabilities, world nonce and a host-issued pawn ticket.
Original peers receive neither new motion nor heap event kinds. An updated guest uses the old six-field drop request
unless its host advertises rotation/velocity support; the host accepts both six and fourteen fields.

Historical comparison source: git HEAD `18e3f07` (full revision recorded in `local/legacy5/revision.txt`),
with native SHA-256 `FCFBC4ED3E356BBA94D819498131B96883085B0296EC8B95924FAA52C39C0B54`.
`tools/test-legacy5.ps1` swaps only test-pair junctions and restores them in finally. It never edits the historical source,
current source, real install or saves. Core mixed-version checks cover joining, enter, ignition, P/D, exit and dropping.
New features require both updated peers; mixed compatibility does not imply feature equivalence or arbitrary game-build support.

## Implementation sequence after stage two

1. **Object identity and transform ownership.** Native `PTNative_ObjectIdentity` returns UE weak object index/serial.
   `common.lease/resolve` additionally bind references to the world generation. Native `PTNative_ObjectMatches` resolves the captured weak key directly, without reading through a freed actor address. Controller/world/singleton caches,
   session identities, car component caches and shared-item entities use these leases. Loot discovery distinguishes a
   new actor at a recycled address. Delayed gameplay in anomalies, UI, health, visual mirrors and session spawn uses
   `common.defer`; connection retries/bootstrap intentionally survive travel.
2. **Authority and idempotence.** Negotiated requests carry world nonce, monotonically increasing serial and the host's
   pawn ticket. Admission, current pawn identity and applied baseline are checked before dispatch. Consume the serial
   before the handler so a partial exception cannot replay a cost. A replacement pawn needs a new ticket. Local UE names
   cannot identify a pawn across processes: live inspection confirmed their names differ. Legacy requests retain original
   behavior; modern raw requests cannot bypass the envelope. Existing host feature handlers still validate actions/prices.
3. **Create-or-adopt IDs.** Existing host-issued monotonic world IDs are retained. Guest tombstones prevent an old add/pose
   from reviving a removed ID. Actors and candidate claims validate weak identity; a reused address gets a new ID.
   Pending poses wait for creation, with a bounded pre-creation buffer. A world change clears the registry and fences
   packets with the old nonce. These are world IDs, not new persistent save identifiers.
4. **Moving items.** Hot items emit newest-wins snapshots at 20 Hz, tagged with world/ID/serial. A reliable final edge fixes
   the settled position/rotation after 300 ms without a meaningful change. Older/reordered snapshots cannot replace it.
   The guest freezes local physics and interpolates the authoritative poses. Drop requests preserve linear/angular velocity
   when negotiated; pickup/destruction stays reliable and retires the ID. Overflow poses use the ordered reliable stream.
5. **Control/bulk/motion.** Lua and native control queues prioritize admission/loading/seat messages. Object creates, state
   and final edges retain FIFO dependency order. Optional motion datagrams use reserved port-zero frames on the already
   established Steam/UDP tunnel; no new socket, game RPC flags or PT1/PT1A version changes. Native queues replace unsent
   and pending motion per kind; the receiver rejects previous-world/reordered datagrams. Lag/loss emulation covers them too.
   Ordinary direct IP without that tunnel retains the tested reliable newest-wins fallback.
6. **Readiness.** Existing character-ready means bulk may start. Active additionally requires the guest to apply car state,
   loot including deferred container fill, and the first complete visual-prop baseline. The visual marker follows its
   definitions/adds on their reliable stream and waits for the guest's work queue to empty. Only then is the host's loading
   hold released and modern gameplay requests accepted. Legacy hosts keep their original readiness; timeout UI recovery
   does not manufacture baseline completion. World changes clear phases/tickets; dead controller leases drop peer state.

## Transform writers

| Object | Host writer | Guest writer | Competing path held off |
|---|---|---|---|
| Car chassis | Native vehicle physics | Existing car.lua follow/Hermite loop | Guest chassis simulation/VehicleController |
| Passenger pawn | Host seat attachment, native movement on foot | Seat/glide path during seating; native movement on foot | Remote single-player enter/exit delegates |
| Passenger view | Local player input | Car-relative look plus bounded local sway | No second network writer of camera rotation |
| Wheel meshes | Native wheel components | wheelmotion clock; scalar roll composed with steering | Native guest wheel driver |
| Open door mesh | Host native door physics | Authoritative swing pose | Guest door physics while mirrored |
| Loose item | Host physics | loot.lua pose interpolation | Guest local simulation |
| Heap | Host native prize/dispenser graph | Timeline/audio presentation | Guest reward graph and dispenser ticks |

## Validation

Current native SHA-256: `B95A442C7E8AD479FFCC216B57A55B72E67544DB01DD2D62887F516498A48205`.

| Check | Result | Archive under local/test-results |
|---|---|---|
| Production parsers, weak-key resolution, replay/world/pawn tickets, readiness and datagram order | 24/24 | 20261103-082801-passenger-multivoid |
| Historical protocol-5 guest with full applied baseline | 22/22 | 20261102-213306-passenger-legacy5 |
| Historical protocol-5 host with full applied baseline | 22/22 | 20261102-213448-passenger-legacy5 |
| Rendered wheel/radio/heap integration, actual datagram send and receive, 150 ms / 2% loss | 41/41 | 20261102-214011-passenger-tunnel-drivev3 |
| Host and guest throws/landing/pickup, lockers, windshield, 150 ms / 2% loss | 34/34 | 20261102-212244-passenger-tunnel-motionparts |
| Native reliable wire/channel regression | 21/21 | 20261102-214143-passenger-channel |
| World-scoped callback regression | 6/6 | 20261102-214211-passenger-worldactions |
| Native message reset across real travel | 14/14 | 20261102-214319-passenger-messageepoch |
| Replacement passenger pawn and normal exit | 24/24 | 20261102-214444-passenger-seatepoch |
| Datagram arrives while 800 KB reliable bulk still pending | 21/21 | 20261102-210737-passenger-tunnel-datagrams |
| Control priority with dependent create/final FIFO | 18/18 | 20261102-205534-passenger-lanes |
| Control priority disabled, expected control/HOL failures | 16/18 | 20261102-205822-passenger-lanes-oldlanes |
| Datagram adapter disabled, exactly the two carrier assertions fail | 39/41 | 20261102-212103-passenger-tunnel-drivev3-nodgramlane |
| Pose sequencing removed, three ordering/retirement assertions fail | 19/22 | 20261102-211748-passenger-multivoid-oldreplica |
| Wheel render clock math at 12/15/30/60/144 FPS | 20/20 | 20261102-205414-passenger-wheelclock |

Earlier PT7/PT8 archives describe those exact checkpoints, not this candidate.
The selected scenarios and negative controls exercise real game clients and production parsers/queues.

The travel smoke additionally exposed a cache-reset bug: object references were cleared but their live leases remained.
Reset now clears both, GetWorld supplies an invalid object during the no-world gap, and netMode tolerates an absent context.
The production-code unit covers this exact reset before rerunning the affected session/safety/travel scenarios.

## Final integration smoke (latest reruns)

| Scenario | Result | Archive under local/test-results |
|---|---|---|
| Session/map changes | 40/40 | 20261103-083153-passenger-session |
| Guest save protection | 30/30 | 20261103-083710-passenger-safety |
| Native travel and reconnect | 23/23 | 20261103-083925-passenger-travel |
| Six repeated reconnects | 36/36 | 20261102-215620-passenger-sessionrejoin |
| Zone join | 14/14 | 20261102-215856-passenger-zonejoin |
| Player bodies | 20/20 | 20261102-222236-passenger-body |

The first suite exposed the nil-context/cache reset bug. The three affected scenarios were rerun after the fix;
all six selected scenarios pass using their latest runs. This is a selected smoke, not the full configured release suite.

## Limits

- Direct IP without the tunnel still has reliable head-of-line blocking after UE accepts a packet. Datagrams are optional
  on the existing two-player tunnel and fall back if its peer mapping is ambiguous; no new port-forwarding requirement.
- The Steam datagram adapter uses the same existing Steam message transport, but two distinct accounts must be checked
  separately. Loopback UDP chaos tests do not prove Steam relays or NAT behavior.
- The readiness barrier covers the car, shared items and initial prop copies. Ambient/audio/streaming refreshes continue
  afterward; this is not a global pause of all single-player streaming systems.
- Existing legacy inventory snapshots and client-reported tool amounts remain the co-op trust model. Replay fencing is
  not a complete anti-cheat or a transaction journal across a process crash.
- Shared-item state still has the existing tint/status-effect metadata limits. IDs here do not rewrite save formats.
- Timing/math tests at 12/15/30/60/144 FPS do not establish a complete rendered chassis/passenger FPS benchmark.
