# Pacific Together lab notes

Evidence ledger, updated through **0.0.7 / protocol 3, 2026-10-24**. Older observations describe the tested revision;
later fixes supersede their status, not the observation. Full subsystem experiments live in [docs/spikes](docs/spikes)
and [docs/research](docs/research). `local/` result folders are git-ignored and may exist only on the testing machine.

## Current evidence and open questions

- Shared gameplay is implemented; [README.md](README.md) describes the preview and [CHANGELOG.md](CHANGELOG.md) its changes.
- October 23 proved Steam UE traffic between two accounts. It also exposed gameplay failures; it was not a clean
  full-run acceptance pass. Cold-start invites, Steam host-disappearance behavior and mixed DLC still need validation.
- October 24 targeted regression after the travel/collision changes passed 13/13 scenarios. This is not a full-suite,
  lag/loss or two-hour-soak pass. The later key-polling commit records ping 25/25, guestui 40/40 and zoneexit 36/36.
- Known current player issues: guest anchor duplication; guest-only tutorial progress; one driver-pose re-entry report.
- Retest older evidence gaps before calling them current bugs: tacklebox capacity/item loss, full-trunk stack drift,
  death-crate item details, quirk cure on alternate fixtures, tool/prop interactions, sound and visual polish.
- Other open checks: route-menu car movement, transmuter/ARDA-container overlap, guest-crafted upgrades reaching the
  host, cutscenes, remaining hazards/DLC/Expeditions, and the firewalled crash-upload proof.
- `PTNative_NetStats` and the tunnel both patch socket imports. Their coexistence was flagged by code review, not
  established by a combined runtime test. Check before using counter readings as tunnel evidence.

## 2026-10-19: foundations and early spikes

### Observations

- Game exe matches the supported Steam build/hash in [CLAUDE.md](CLAUDE.md). The game initializes Steam under appid
  1458140 and exports the flat Messages/lobby API; no second Steam initialization is needed.
- Harness results (`local/test-results/20261019-*`): boot 11/11, listen 14/14, skipconnect 12/14, dump 19/19.
  `-NotInstalled` isolates saves; warm startup is much faster than the first shader-cache load.
- X1: Lua LoadMap hooks fire, but FURL is opaque and copied, so Lua cannot add `listen`. Native travel stopped hosting.
  `20261019-164906-travel` 22/23; fallback servertravel added a second map load.
- X1b: native LoadMap vtable patch appends `listen` without a second load. `20261019-180355-travel` 23/23;
  nokeep 22/23; ClientTravel experiment 21/23. Non-seamless travel still closes the guest connection.
- X11: the 20 s pending-connect limit is `IpNetDriver.ResolutionConnectionTimeout`, not InitialConnectTimeout.
  Setting its CDO to 120 before `open` allowed a 41 s wait: zonejoin 14/14 (`171617`); noconfig 12/14 (`171355`).
- X10: forced autosave wrote the host world into the guest's scratch slot. A native SaveGame pre-hook setting slot -1
  blocked it: guestsave 23/23 (`173646`), noblock 20/23 (`174119`). GameUserSettings rewrites retained the same hash.
  Other writers needed the later safety guards. A host AV at 0x178 in `172056` was not reproduced in four repeats.
- X13: remote ALS characters already animate; `M_PlayerCharacter_Invist` made them invisible. A visible material
  revealed walk/crouch/sprint on both sides. Observed speeds: 375/150/625 uu/s. Survivor geometry now replaces this
  early material-only presentation; see `survivor.lua` and [PT3-look](docs/spikes/PT3-look.md).
- Djecka's Blender source is `assets/player_model/SK_CoopSurvivor.blend`; generation/export scripts are in
  `tools/blender`. Original model: 1,500 vertices, 23 UE mannequin-named bones, five 30 fps loops, 1.78 m tall.
  The initial Blender re-import passed; it was not a cooked-UE asset validation.

### Derived

Validate the current world when counting actors/controllers. `net=client` alone may mean a pending connection;
require the expected map and pawn too. Gameplay state needs explicit synchronization even when an actor replicates.

### Detailed experiment sources

| Area | Evidence |
|---|---|
| Actor identity, replication and duplicate survey | [X2](docs/spikes/X2.md), [client actor survey](docs/research/client-actor-survey.md) |
| Guest interaction/backpack serialization | [X4](docs/spikes/X4.md), [X12](docs/spikes/X12.md) |
| UDP/Steam groundwork | [X5](docs/spikes/X5.md), [X6](docs/spikes/X6.md) |
| Car interpolation, passenger seat | [X7](docs/spikes/X7.md), [X8](docs/spikes/X8.md) |
| Session and save/crash guards | [M2-session](docs/spikes/M2-session.md), [M2-safety](docs/spikes/M2-safety.md) |
| Tourist, station, ARC and crash research | [E](docs/spikes/E.md), [research index](docs/research/README.md) |

## 2026-10-20: session, reload and message channel

### Observations

- Merge regression (`20261020-1533*` through `170232*`): session, travel, safety, body, loot/interaction probes,
  car-seat/ride, Tourist and ARC scenarios passed. No mutations or two-account Steam test in that batch.
- Abrupt guest death in garage/zone removed its host-side controller/pawn; relaunch rejoined. `sessiontravel` 55/55;
  nokeep 29/52. `TravelToGarage` states 2/3 bypass SaveAndQuit; the pause menu saves then calls `QuitToMenu(context)`.
- Host entering the car attached every character through shared manager delegates. `mute.cpp` suppresses those
  calls for the remote character: carenter 21/21; nomute fails. Native Browse rejoin avoids the main-menu detour:
  sessiontravel 54/54, session 40/40, sessionrejoin 36/36.
- Moving the native DLL into its own UE4SS mod prevents Lua RestartMod from unloading it. Lua-only reload still
  raced hooks: crash `20261020-232445-reload`. A test-only game-thread wait passed 3/3 runs, but plain reload also
  passed 3/4; this did not prove safety. Later repeated reloads crashed again. Restart for validation.
- Setup once copied an installed preview through a junction over the repo mod. Fixed: setup excludes `ue4ss/` and
  `dwmapi.dll` from the source copy and expands the pinned archive itself.
- `msg.cpp` uses reliable ServerExecRPC/ClientMessage, 1,000-byte chunks, a 32 KB message cap and per-controller/kind
  reassembly. Channel test `20261020-234822-channel` 21/21: ordered messages and 20 KB byte payload both ways;
  40 KB refused; nocapture 16/21. The per-message cap did not prevent later aggregate reliable-buffer overflow.

### Unknowns

Moving-car disconnect coverage, story/station save-writer coverage and the elevated firewalled crash proof were not
completed by this batch. Later session fixes do not automatically establish every one of those paths.

## 2026-10-21 to 22: shared gameplay and first playtests

Subsystem implementation details/results are in `M3-*`, `M4-*`, `M5-*`, `M6-*`, `PT1-*` and `PT2-*` under
[docs/spikes](docs/spikes). This section retains cross-system findings and failures rather than repeating each report.

### Observations

- The guest pawn's damage receiver originally changed the host's singleton PlayerHealth. Forwarded damage now
  applies on the guest. A blast affecting both players still needs careful combined-damage checks.
- The native SAVC serializer and LoadGame map travel rule out using a save-memory round trip for progression sync;
  whiteboard, research, route and journal state are copied explicitly.
- Garage storage is `Inventories_Garage`, keyed by station tag. Singular `Inventory_Garage*` fields were nil.
- Car-camera assertions must account for a one-frame view delay: comparing the prior frame reduced measured error
  to 6.7 uu (`20261021-134010-carsync`). Blueprint hooks run after the Blueprint body.
- Full suite `suite-20261022-010350.txt`: 28/31. sessiontravel needed its garage fixture; a loot rerun passed without
  a code change. A full-trunk transfer drifted by one item in PT1-swap.
- Hand play (`local/playtest-0.0.6-local/`): guest container loot/drop, host pickup/trunk transfer and riding worked;
  car exit worked twice out of three. Zone stutters reached hundreds of milliseconds; buildings were missing then.
- Tacklebox mismatch `20261022-190420-lootsync`: host 6 items, guest 5 for 90 s, missing Plastic with no host change.
  Suspected per-process mesh/capacity difference, not a proven snapshot race. Guest state could overwrite the sixth item.
- Run-failure rejoin crashed in 5/8 overnight runs (`20261022-03*-pt1-travel-sessiontravel`), even with several new
  modules disabled. Later fixes address stale ride-loop objects and cross-thread Lua; no current flake rate established.
- Bunny velocity assertions missed short impulses. Test movement alone reached 639 uu/s, so peak speed was not a
  valid mutation discriminator; damage was the reliable assertion.

## 2026-10-22 to 23: frame time and live fixes

### Observations and derived fixes

- Rendered measurements refuted the earlier guess that every FindAllOf costs ~35 ms. Per-class hash lookup was
  ~0.2 ms, Actor enumeration ~3 ms; repeated world/controller/item-function lookups dominated loot serialization.
- Missing-path StaticFindObject/RegisterHook fell back to a 25-45 ms full scan. Hash-only `PTNative_Find`, cached
  managers, bounded wreck reads, per-frame loot budgets and indexed claim candidates removed the repeated stalls.
  Host loot tick fell from ~250 ms to 50-70 ms in the first pass, then a few milliseconds in later passes.
- Guest full-list application initially took 470-590 ms. Budgeting spread ~300 entities over ~3 s, under 30 ms/frame
  in that session. Zone prop mirroring was enabled after pacing it; older reports saying it is off are superseded.
- `IsValid` rejects freed objects but cannot distinguish a new object at a reused address. Clear world caches on travel
  and retain class identity in long-lived cache entries. `pcall` does not catch native invalid-pointer faults.
- Reliable overflow `20261022-225808-lootsync`, NumOutRec 254: loot sent before the guest requested its list. The first
  fix gated loot on its hello; the October 24 protocol/readiness fix below covers aggregate host traffic.
- `stations` cure failed on `C:\PTLanes\main2` before and after perf edits, but passed on the main pair; fixture dependence
  remained unexplained. playpath p2/p6 also failed on baseline e47ef32, before the perf changes.
- Frame-time suite shards: 11/14, 13/14, 12/14. Targeted reruns passed session, lootsync2, lootcar, visual, zonejoin,
  sessiontravel, mapmark and stations. This was not a fully green suite; other old failures are not silently closed.
- Claiming wreck parts before purging locally rolled wreck bodies removed the claimed parts; stop claiming those
  bodies/parts. Caching prop verdicts by address alone broke removal checks; retaining class identity restored 3/3 runs.
- October 23 live fixes: detach/exit handling, correct walk state and camera, streamed prop copies and host-authoritative
  door interactions. See PT1 car/parts/garage reports and the later October 24 exit corrections.
- Do not read pooled item `.Instance` after its alive check fails. Queue RPC handlers for game-thread dispatch;
  loading assets inside an RPC hook hung a guest. Keep Lua input callbacks on the game thread.

### Remaining evidence limits

Rendered hand play remains necessary for sound, seat appearance and input focus. Tool-driven direct calls can pass
without proving the real highlight/hold path. Performance numbers are measurements of those runs, not guarantees.

## 2026-10-23 evening: first real Steam play (owner's PC = guest, real install, 0.0.6-dev-e56651f; logs local/playtest-20261023-steam/)

Observations
- Four sessions 18:52-19:30 local, all joined over Steam between two real accounts: each engine log has `Welcomed by server`
  (garage once, zone Rural_Forest_Radio_Scylla_02 in all four; 15:57 and 16:29 UTC end with "Host closed the connection.").
- Last session's UE4SS.log (the only one kept; UE4SS overwrites it per launch): the invite / Join Game callback arrived while the
  game ran (`PT|steam event join_lobby`, callback 333 path), lobby entered, tunnel peer 10.77.0.1 -> host SteamID, warm-up echo
  reliable and unreliable after 2.0 s, then the ordinary join and hello. So the Steam tunnel carries UE traffic between two
  accounts: the main X6/PT2-steam unknown.
- Host engine log (friend's PC, saved as host-PenDriverPro.log): one launch 18:52-19:32, garage `?listen` 15:52, zone 15:57:20,
  garage again 16:30:01 (after both died), main menu 16:32. So the two "Host closed the connection" are the host's own travels,
  not drops. No mod lines in it (ours go to UE4SS.log). 12k+ each of `Divide by zero detected: 425/0`, `325/0`, `0/0` on the
  host only: source not looked up.
- Guest sessions vs owner's account: 18:58 quit after X in the zone launched the car (#3); 18:59-19:17 ended by the hard
  freeze after the arc anchor (#6/#16); 19:27 rejoin, long stall at the zone entry, car launched, both died (#17).

Owner + friend reports from play (guest = owner, host = friend; numbering is the owner's list)
1. Chained side doors in the garage (pried open): opened by the guest, the door swings, but an invisible wall blocks the guest.
   Opened by the host, it works for both.
2. Guest driving: scraping-metal sound sometimes, host never hears it (maybe while turning).
3. Zone load: guest spawns in the driver's seat (game default), stuck. X: guest falls through the ground, then is put back
   floating above the car with the camera stuck to it; once the X launched the car.
4. Story lines repeat for the guest until the "mission updated" log appears.
5. Transmuter (in place of an ARDA container, small building) shown to the host only.
6. Guest frozen and snapped back while the host is in pause, loot container, trunk or crafting grid ("pause game while in
   inventories" was on: likely the cause). Once a freeze never ended (restart): host in the car using the ARC anchor at the car's
   ARC machine (behind the guest's seat); guest still heard car sounds as if seated.
7. Host's crafted Impact Hammer, seen by the guest: huge, broken texture (screenshot from owner, green body lying on the road
   next to the car), from the moment it was crafted.
7b. Plasma generator broken by the host: its drops reach the guest, the generator stays whole on the guest.
8. Radiation never hurts the guest.
9. Wheel damage (broken, punctured) not shown on either client, but a scan reports it damaged. Owner: not vanilla behaviour.
10. Guest scrapping sometimes leaves its sound playing.
11. No "paused by host" label on the guest: pauses look like lag.
12. Guest's legs stick out under the car (body copy seated).
13. Cyrillic Steam name renders as squares on the floating nametag (fine in the UI hint): font lacks Cyrillic.
14. Guest car entry sometimes slow.
15. ARC anchor structures invisible to the guest; once the host picks one up it shows in their hands, dropped it shows on the floor.
16. After the host inserted the ARC anchor, the car froze for the guest (sounds kept playing): same event as #6's hard freeze.
17. After several rejoins, 40-60 s stuck at the zone entry crossing, unable to move; then the car was launched spinning into
   the air, its impact killed both, both sent to the garage, guest launched again there.
- Worked: car parts, driving, Grabber (per-frame jumpy on the guest), floor items, buildings, scrappables, crafting, inventories.
- Host felt lower FPS / more sluggish than solo; no other complaints.

- Host UE4SS.log (friend sent it, saved as host-UE4SS.log, 18:52-19:32): no PT|error, no Lua traceback. Hitches: 257
  `PT|slow` lines (>30 ms in one callback), nearly all car.lua:740 (host car tick, 250 ms loop) and car.lua:753 (door swing
  loop, 50 ms), plus visual.lua:552, loot.lua:721, progression.lua:118. Last perf window: car.lua:740 total 1098 ms
  (max 33, n=222), carfeel.lua:265 851 ms, visual.lua:552 516 ms, car.lua:753 474 ms; FindAllOf BP_CarManager_C 403 ms
  over n=1376 and PlayerController 347 ms. Fits the friend's "more sluggish than solo" (derived, not measured in FPS).
- Host log at the ARC freeze (19:14-19:18): only slow lines, nothing from car/session until the guest's rejoin at 19:18:15
  (seated 19:18:46). So the host saw nothing wrong; the freeze was on the guest's side.

- Guest-only engine warnings (lead, diff of guest vs host warning kinds):
  - `SerializeNewActor failed to find/spawn actor` for actors of `Rural_Forest_Radio_Scylla_02_Mission_Sub`:
    BP_Hazard_Tesla_C x8, BP_Hazard_PhysicsGrabber_C x6, BP_LevelTransition_ExitPortal_C x4,
    BP_Resource_Narrative_Q01_RadioBitsGrabbable_C x4 (each zone join). Fits "Spark Tower not working" on the guest; the
    exit portal (gateway) and the Q01 quest item may be missing or unsynced on the guest too (not checked).
  - `No owning connection for actor BP_Hazard_PhysicsGrabber_C / BP_Hazard_Bollard_C. Function SERVER_Start/Stop will not
    be processed`: the guest's own hazard copies call server RPCs.
  - `CreateSavedMove: Hit limit of N saved moves` 66+ times around 16:00-16:10 UTC: the guest's moves not acked while the
    host was paused in menus (#6).
  - `ClientAdjustPosition_Implementation could not resolve the new relative movement base actor` ~45x at the garage join
    (base SM_Metal_Sheet_2), once in the zone.
  - `Ability ARC Doc / Handbrake no longer "available" from provider`, `GetHotbarSlots index 2 of length 2` (guest hotbar),
    `GetGarageInventory` index warning, `GasPump GetUpgrades index -1`: guest-side UI/state mismatches, not looked into.
Unknowns
- The guest's UE4SS logs of the first three sessions are gone (the freeze after the ARC anchor was in the second).

## 2026-10-24 night: Steam playtest fixes (lead + 10 Sonnet lanes, owner asleep; spike docs docs/spikes/PT3-*.md, PT1-portal.md, PT1-pt3-spawn.md)

All proven headless two-client only (no rendered or hand check). Numbers refer to the Steam playtest list above.

Observations (scenario runs, folders in local/test-results)
- #3 guest put in the DRIVER seat on a zone join: the game attaches a character spawned while the host drives to the driver
  seat; the host now moves it to the passenger seat (car.lua). zonespawn 34/34, mutation nozonefix 32/34.
- #6 host menus froze the guest: everything goes through BP_UIManager_C:PauseGame; with a session only the Esc menu
  (instigator PauseMenu) keeps its pause (pause.lua). #11 "Paused by host" banner on the guest. pausehost 27/27, nopause 22/27.
- #1 chained garage doors: guest lock-open and E run on the host's map-placed door (g.vis.unlock, g.vis.door, full-path key).
  worlddoors 21/21. #15 ARC anchor structures and #7b broken plasma generators on the guest: worldzone 26/26.
- #8 radiation: the radiating volumes are spawned at runtime on the host only (host 8, guest 3); radiation.lua sends them and
  the guest spawns copies (damage only, no decal/VFX). radiation 20/20, norad 16/20.
- #9 flat tyres: SE_FlatTire on the host set GetPartFlat on the host only; wheelflat.lua mirrors the flat map. wheelflat
  17/17. On-screen look not checked.
- #4 story lines: the guest's 6 s dedupe window was just shorter than the replay interval in the real log; now 90 s, and the
  guest stops writing WB.Statistics.* tags. storysync 24/24, storyprog 26/26, progsync 30/30. Not proven against the real repeat.
- #7 Impact Hammer: the tool carries a visible /Engine/BasicShapes/Cylinder that hands.lua took as the base; engine meshes
  skipped. hands 64/64. #13 Cyrillic nametag: TextRender only draws offline fonts (256 Latin glyphs); names with letters above
  U+00FF use a UMG TextBlock at the head (nametag 23/23; lead fixed the byte test to the UTF-8 lead byte). #2 scrape sound:
  BP_CarScrapeFX_C destroyed on spawn on the guest (carfeel 42/42; cause read from bytecode, not heard).
- Spark Tower: SpatialTickController switches managed hazards off by distance (5000) from the HOST's player; hazards near a guest
  are kept ticking, player-range hazards (landmines, bollards, grabbers) arm for the guest, Tesla beam/discharge mirrored,
  replicated hazard copies glide (anomalies3.lua, world.lua). anomtesla 20/20.
- Exit portals and Q01 radio bits: the guest destroyed its own level-placed copy before the host's actor channel bound to it
  (SerializeNewActor failed); now the guest keeps copies the host has. portals 20/20 (portal half not reproduced in the fixture).
- Guest UI: Esc opens the pause menu (a client's SetGamePaused always fails), End/F8 + `ptunstick` with "Controls reset",
  "X  Exit car" hint, Joining/Loading/Waiting text, fade on seat changes (guestui.lua). guestui 40/40.
- Host frame time: car host tick 3.9 -> 1.0 ms/call, swing watcher gone from the top 8, carfeel ticks halved (carsync window,
  docs/spikes/PT3-perf.md). Hooks seen firing on the host: UpdatedCarEquip, Tintable SetPaint/SetDecal.
- Two code reviews of the merged code; 14 fixes by the lead (35a885d, d818b35, e080c60, 54d56ce).
- Full suite on main d818b35 (2 shards): 46/50. Reruns: lootcar 24/24 (flake). Fail twice: playpath p6 (guest ground pickup
  never reaches the host), guestparts (1-2 different checks per run), mapmark (guest crash after its death rejoin, same address
  0x1e31c0cc0 as 2026-10-23 16:36: pre-existing). Lanes pt3-regress (p6, guestparts) and pt3-crash (mapmark) started 03:00.
- pt3-regress: p6 and the cutter check were test flakes (two chemicals 73 uu apart, near() took the first; a panel's drop is a
  loot roll). pt3-crash: the guest's 1 ms ride loop (car.lua) read the old world's pawn after a rejoin while seated; now
  validity-checked and cancelled at map change (section below). Lead: guestparts "door stays repaired by blowtorch" broke after
  the perf merge (the host's part lines cached for 1 s sent the old health back); the cache is dropped after any guest
  g.parts/g.act/g.swap message (net.tap, 24b9568).
- Final on main 24b9568: playpath 39/39, carexit 29/29, mapmark 22/22 x2, zonespawn 34/34, sessionrejoin 36/36, guestparts
  73/73 x2, guestswap 33/33, carsync 36/36, session 40/40. Zip dist/PacificTogether-0.0.6-dev-24b9568.zip.
- pt3-seat: the game has no sitting pose for a character in the car (its driver is never drawn; ALS_MovementMode 5 changes no
  bone); the seated guest's thigh bones are hidden on both sides and shown again on exit (carsit 23/23, nosit 21/23). The torso
  floats at seat height: to be looked at by hand. #14 slow entry: no avoidable wait found (docs/spikes/PT3-seat.md).
  On main ec2c96b: carsit 23/23, carsync 36/36, guestdeath 30/30, lootcar 24/24, carfeel 42/42, mapmark 22/22.
  Zip for the next playtest: dist/PacificTogether-0.0.6-dev-ec2c96b.zip.

Unknowns / not fixed
- #16 freeze after the ARC anchor: the ARC machine code never pauses, dilates time or repossesses; host log clean; cause on the
  guest side, needs a live repro or the guest's UE4SS log.
- #5 transmuter vs ARDA container: not reproduced (the host's transmuter reaches the guest, ~1 min late).
- #10 scrapper sound still needed a hand check. #12/#14/#17 received later seat/readiness fixes below;
  this night pass alone did not establish their resolution.
- Landmines still creep toward the host only; the guest's radiation copies have no visuals; a host pause opened before the guest
  joined is not refused; host health read 97 once after a Tesla shot at the guest (anomtesla run, unverified).

## 2026-10-24 night: the guest's rejoin crash in mapmark (pt3-crash)

Observations: crash (EXCEPTION_ACCESS_VIOLATION, 0x1e31c0cc0 / 0xffffffffffffffff) in 3 of 3 mapmark runs on main, about 50% of runs with mutate and ~0 of 6 with the fix. CrashContext call stack symbolized with dbghelp + UE4SS.pdb: Lua `obj.Property` read -> UObjectBase::prepare_to_handle -> UStruct::FindProperty -> TFieldIterator (a freed object's class pointer). Tracing every loop for 6 s after the load map (run 20261024-032013-pt3-crash-mapmark-noridefree): the last loop entered was car.lua's seat-hold loop (`ride`, 1 ms).
Derived: that loop kept `char`/`car` of the old world through the guest's rejoin and called `char:GetAttachParentActor()` without a validity check (pcall cannot catch an access violation). Fix in car.lua: the loop checks valid(char) and valid(car) first and cancels itself; a LoadMapPre hook cancels it. Mutation PT_MUTATE=noridefree switches both off.
Results: mapmark 22/22 twice with the fix (20261024-032235, -032333), noridefree: 2 of 3 runs pass by luck, 1 crashes (-032625); sessionrejoin 36/36 (-032823), guestdeath (zone) 30/30 (-034615).

## 2026-10-24 day: hand play on the local pair (owner), test saves from the owner's own progress

Observations
- Guest car entry: the host seats the guest within 0.15 s of the door press, the guest noticed 4.6/13.9/4.8 s later (replicated
  attachment); with the host's g.car.seat message 0.07 s (garage play 11:43). One seat 18 uu high (head in the roof): offset now
  kept to the passenger seat when the game's transform is off by more than 8 uu. carsit 25/25; mutation noseatmsg also passes
  headless (the delay only shows with rendering).
- Guest crash on X (getting out): UE4SS dump (tools/dmpstack.py) -> luaH_next under luaL_traceback: a corrupted Lua state; the
  carfeel NotifyOnNewObject callback from review fix d818b35 ran Lua off the game thread. Reverted to the game-thread poll
  (bd71f8a). Zip ec2c96b has this crash; 10a86e0 does not.
- "Host cannot interact" on the garage fixture: not a mod bug. Garage stations check the global whiteboard for
  WB.Missions.QD_Q00_Mission_D.Completed (or Q00_Demo_Mission_B.ReplaceFlat.Completed) in K2_ShouldHighlight; the garage
  fixture is a fresh story save without them. The guest's own tutorial moved on alone (OpenedRoutePlanner, Oppy talks for the
  guest only): tutorial/objective progress done by the guest does not reach the host.
- Guest garage upgrade tags doubled (Inventory.InstallCount 8 vs 4, CraftingTable 2 vs 1).
  Fixed in the afternoon progression pass below.
- LoadBookmark and the quest manager's "Fake Complete Q00 & Q01" are blocked in the shipping build; forcing quest missions
  live crashed the host (twice, once from a bad console call of mine). Test saves now come from the owner's own saves
  (coop-garage/zone/gateway/return, docs/TESTING.md).

Unknowns
- Whether the doubled upgrade tags make the guest see extra stations/storage.
- coop-garage hand play (logs local/playtest-20261024-coop1): the host drove out to the junction and the guest's car stayed in the
  garage (lights still synced: our own message), the guest's exit put it at the real spot but the car was back in the garage;
  in the zone every guest exit fell through the ground (died 3x, twice). Cause: the player car was not bAlwaysRelevant; its net
  cull is 150 m and the garage exit trigger is 234 m from the car. Seen from the guest's camera (riding the guest's frozen copy)
  the car left relevance and stopped replicating, and the guest's world did not stream in around the real car. Fix: the host sets
  the car bAlwaysRelevant while a guest is connected. carrelevant (car moved 300 m, again after the 5 s relevance timeout) 17/17,
  mutation norelevant 16/17.
- Not looked into yet: while the host was in the junction's route menu, the guest's car kept moving (owner).

## 2026-10-24 afternoon: guest dropped on join (reliable buffer), doors, player upgrades, exit spot (lead, owner away)

Observations
- netflow (host bursts 400 x 1 KB at the guest in the garage), flow control off: host engine log `LogNetPartialBunch: Warning:
  SendBunch: Reliable partial bunch overflows reliable buffer! ... BP_PlayerController_MainCharacter_C ... NumOutRec: 254`, the
  channel closes, the guest times out 60 s later; no message of the burst arrives (16/17). The same overflow as the Steam play and
  the coop-garage/zone joins ("loot full list for the guest: 234 entities" just before).
- A 1000-byte chunk of ours is 2 reliable partial bunches (3 when a byte is >= 0x80: the FString goes out as UTF-16). The first
  flow-control try counted chunks against a window of 150, i.e. ~300 bunches: it overflowed the same way.
- Player upgrades (backpacks, armour, suits, gloves, boots: IA_PlayerEquipment_*) are archetypes in
  BP_MainCharacterManager.PlayerUpgradesUnlocked, from the save; "Add Player Upgrade" adds one and calls RebuildPlayerUpgrades
  (pack layout, hotbar count, zap immunity, radiation curve). The guest's list was empty.
- Garage side doors are map-placed BP_Door_Single with a chain lock (LockStrength, BP_LockedComponent, OnUnlockedTag added to
  the whiteboard; the lock state is decided at BeginPlay from the whiteboard). Only guest -> host was mirrored.
- Doubled WB.GarageUpgrades on the guest: progression writes the host's values, then garage.lua's InstallSpecificUpgrade on the
  guest counts its installs on top; the host only resends a section when it changes, so it stayed doubled.
- Highway_Forest_01 hand play (local/playtest-20261024-coop2): the guest was placed 2.5 m left of the car (fixed offset) and
  ended under the road; host log `ServerMove: TimeStamp expired: 0.024161, CurrentTimeStamp: 8.716180` right after the exit
  (before the 150 ms repossess).

Changes
- net.lua: host -> guest flow control counted in bunches (window 160 of 256), nothing sent before the guest's first ack on the
  connection (10 s at most), window reset after 20 s without an ack. Guest acks 10x/s while messages come, every 2 s anyway.
  PROTOCOL_VERSION 3 (host and guest must both have it). netflow 17/17, mutation noflow 16/17.
- progression.lua: player upgrades section (g.prog.pu), guest applies with "Add Player Upgrade"; the guest keeps the host's
  whiteboard and writes it again after each garage install (M.reapplyWb from garage.lua).
- visual.lua: host lists its placed garage doors' states (g.vis.pd, on change and every 10 s); the guest unlocks with
  ForceUnlockDoor (chain break sound and particles) or sets open/shut with "Set Door from State".
- car.lua: the guest's exit spot is the car's LocateSafeExitPoint (the game's driver exit trace) within 6 m, else the old offset.
  Mutation noexitspot.
- Results on main: netflow 17/17 (noflow 16/17), runloop 49/49 on the garage fixture and 49/49 on coop-garage (the owner's save;
  loot lists of 251 and 753 entities went out, no window reset), worlddoors 23/23, progsync 31/31, garagesync 35/35, carexit
  29/29 (exit spot "game", 1.7 m beside the driver's door), guestdeath 30/30, zonespawn 34/34, sessionrejoin 36/36, portals
  20/20, carsync 36/36. LocateSafeExitPoint from Lua takes one table per out parameter; a struct's table gets its fields.
- Scenarios: worlddoors + guest_door_unlocked_by_host, guest_door_follows_host_press; progsync + guest_got_host_player_upgrade;
  garagesync + guest_garage_upgrade_counts_equal; runloop takes -Fixture (coop-garage = the owner's save).

Unknowns
- Guest -> host has no flow control (few, small messages so far).
- Whether the guest's own crafted player upgrade should reach the host (only host -> guest is synced).
- Tutorial progress made by the guest alone (Oppy) and the route-menu car movement: not looked into.

## 2026-10-24 evening: hand play on the local pair, guest falling after a junction (coop3..coop12 logs in local/)

Observations
- Host at ~5 FPS while the owner played the guest window (high settings, two games on one GPU): the guest's pawn came late and its
  moves expired. The test copies now run on Low (GameUserSettings.ini sg.*=0, .ptbak-quality backups).
- Our traffic per kind (net.lua logs it every 30 s): g.car.s 1552 KB / 30 s (~52 KB/s of the guest's 100 KB/s), the whole car state
  (~5 KB: every part with its asset path) resent whenever a number drifted while driving.
- After a junction (TravelToNextLeg) the host pushed ~1 MB of loot lists (1774 entities), world positions and radiation volumes at a
  guest still loading: its pawn arrived 48 s after the host spawned it; the guest left the car 4 s later into a half-loaded world.
- After the exit's repossess the host had the guest's character at MOVE_None, collision off (the game's possession sees "the player
  is in the car": the host, driving). With that fixed the host's copy still fell: the capsule itself was NoCollision (profile
  Custom), set by the game when it put the joining guest in the car.
- A guest respawned into the car body tore off doors, a panel and a wheel within the 250 ms seat check.
- Guest crashes this session: my console probe (a trace hit's weak pointer read on the guest) and the test mod's watchers running on
  the guest (FindAllOf on a freed actor); a live Lua reload of the host in a zone crashed it. None of these run in normal play.

Changes
- car.lua: car state at most twice a second (the H line: ignition, gear, lights, handbrake, doors still at once); the game-attach seat
  check every frame; after the exit's repossess walking, actor collision and capsule collision go back on (mutation noexitwalk);
  ground diagnostics at the exit spot on both sides.
- net.lua: until the guest reports its character (g.net.ready) only g.car/pause/health/net/ping go out, the rest waits (90 s at most;
  mutation noready); bytes per kind logged every 30 s.
- guestui.lua: logs what the guest has while it has no character.
- Scenario zoneexit (fixture coop-zone): host in its car, guest seated, junction travel, the game seats the rejoined guest, it leaves,
  walks away from the car and jumps; neither side may see it more than 3 m below the exit spot. 33/33; mutation noexitwalk 32/32 fails
  host_guest_stays_on_ground. Pawn after travel: 1 s (was 48 s).
- Regression on this code: carsync, lootsync, progsync, garagesync, guestdeath, carexit, runloop 49/49, sessionrejoin, zonespawn,
  guestui, worlddoors, carsit, netflow: 13/13.

Unknowns
- Anchors picked up by the guest stay on the host (deposited twice): loot sync gap, not looked at.
- Parked, not needed now: local/wip-after-0f7fb78.patch (window 32, move-buffer watcher).

## 2026-10-24 night: owner hand play of 0.0.7 on an MCP live session (logs local/playtest-20261024-coop16, coop17)

Observations
- coop16: the guest went back to the main menu when the host travelled to the junction (Highway_Forest_01) and did not rejoin. Its
  shipping mod logged `role=host join=nil`: in MCP/repl sessions the test bot joined with its own `open`, so the shipping guest had
  no rejoin. The host closing the connection on the map load (`LoadMap ...?listen`, NetDriver shutdown) is the normal path.
- coop17, after the fix: the owner played garage -> Highway_Forest_03 -> Rural_Forest_Town_Sasquatch_82 -> Rural_Forest_Radio_Scylla_02
  -> garage with the guest rejoining at every map; owner: "come back with my guest in one piece". 0 PT|error on either side.

Changes
- run-test.ps1: `repl` is in $AutoJoin; repl.lua's guest only waits for the connection (the shipping mod joins and rejoins).

Log analysis of coop17 (19:08-19:27, 5 map loads; local/playtest-20261024-coop17)
- Rejoin: guest ready 2.3-3.4 s after each load (8.2 s on Sasquatch_82, a 352-entity loot list first); the game seated it
  every time; every exit restored walking and collision. No crash, no new dumps.
- Bug: each rejoin forwarded an anomaly hit to the host: MSG_Damage_Physical_Impact 60 (twice) and 19.8 (twice), in the same
  second as "car guest attached by the game". The seating jolts the car on the guest's side, the host's body there is hit,
  anomalies.lua sends it to the host. Headless zoneexit -Mutate noseatguard reproduced it (guest forwarded 60, host applied).
  The host's health read 100 0.5 s later, so whether it lands on health or the car (DistributeMode 2) is unknown.
- Fix (anomalies.lua): the guest forwards nothing for 20 s after a map load (mutation noseatguard turns this off).
  zoneexit got the check host_not_hurt_by_guest_seating (counts damage binds on the host's own character from the travel
  to 12 s after seating). NOT RUN: the owner stopped the tests; the check's first, health-based version passed under the
  mutation (sampled too late), the bind-counting version has not run with or without the fix.
- Traffic host -> guest 3-10 KB/s of 100 KB/s: g.car.s up to ~8 KB/s driving, g.world.pos ~4 KB/s on Sasquatch_82,
  g.garage.up ~2 KB/s and g.story.done ~0.8 KB/s are deliberate full resends. Worst hitches: guest's first join, net.lua:209
  272 ms, garage.lua:220 161 ms; later frames under 100 ms.
- Engine noise only: ServerMove timestamps expired (two games on one PC), 376 unresolved-guid warnings for a runtime-spawned
  garage crafting table the guest stood on, bollard SERVER_Start/Stop without an owning connection (known, anomalies3).

Owner-seen bugs, to fix later
- Some anomalies invisible to the guest: the noise-making one that repairs the car, and the "tictac".
- Weather and time of day were different for host and guest (README had claimed both synchronized).

## 2026-10-25 worldsync lane: weather/time of day and duplicated anchors (branch lane/worldsync)

Observations
- Weather: host and guest managers agree on time of day, target preset, overrides and fog (world.lua already sends them once a second).
  What differed was the guest's lighting simulation: in a live pair (`Wilderness_Forest_06`, then `Rural_Forest_Radio_Scylla_02`) the guest's
  `BP_ToDManager_C.ToDSimulationActor` was invalid while the level's `ToD_Simulation_C` existed, and after the host switched the preset
  (`Set New TOD Target` with ToD_Preset_AcidRain) the guest manager's target followed but the guest simulation's `CurrentPresetObject` stayed
  on ForestSullen: directional light 2.26 vs 0.87, skylight 1.47 vs 5.02, precipitation 0 vs 1, wetness and wind low. Calling
  `SetupToDSimulationActor` on the guest fixed the reference; calling `sim:WeatherChangeEvent(target)` fixed the preset, light and rain.
- The sim binds `TODPresetTargetChanged` in its own begin-play; on the guest that binding evidently never took effect (cause unknown, see below).
- Anchors: the zone's `BP_Spawn_Anchor_*` structures are host-spawned; the guest has non-replicated copies from visual.lua (named
  `..._C_2147...`, host names are GUIDs). Pulling a copy on the guest runs the game's own `Long Grab Complete` (item to the guest, mesh gone);
  nothing reached the host, so its structure stayed pullable. The host's own pull marks `SuccessfullyGrabbed` and leaves the actor.
- RegisterHook post callbacks never fire for the Blueprint function `BP_Spawn_Anchor_Base_01_C:Long Grab Complete` (the pre hook does).

Changes
- world.lua (guest, once a second): relink the manager to the sim when the reference is invalid; run `WeatherChangeEvent` when the sim's preset
  class differs from the manager's target. Mutation `nosimlink` turns it off.
- visual.lua: guest pre-hook on `Long Grab Complete` (checks `SuccessfullyGrabbed` 300 ms later) sends `g.vis.anchor <key>`; the host marks its
  structure taken the way the game does (flag, AddAnchorPulledTag, AnchorTaken, removeAnchorGoo, highlight off, grab mesh gone). Prop state
  gained `tk=1` (SuccessfullyGrabbed), applied on the guest by removing the copy: a host pull removes the guest's copy. The deposit path
  (g.act.anchor) is unchanged, so a pulled anchor is deposited once. Mutation `noanchorsync`. No wire-format change to existing messages
  (new message `g.vis.anchor`, extra state field): PROTOCOL_VERSION not bumped.
- New scenarios `weathersync` (fixture zone or garage) and `anchordup` (fixture zone), registered in run-test.ps1 and run-suite.ps1.

Unknowns
- Why the sim's delegate binding is missing on the guest (the manager is a game-instance object that outlives levels; the sim's begin-play
  may find another manager or none): not investigated, the guest relink is a once-a-second reconciliation, not a root fix.
- Rendered comparison (screenshots) of host and guest sky was not done; the evidence is simulation properties.
- Map transitions with the new code are covered only by the smoke set below, not by a weather-specific travel scenario.

Results (all runs headless, one pair, root C:\PTLanes\worldsync, port 7841)
- weathersync -Fixture zone 22/22, -Fixture garage 22/22; -Mutate nosimlink 19/22 (fails guest_sim_linked, guest_runs_host_preset, guest_precipitation_matches).
- anchordup -Fixture zone 22/22; -Mutate noanchorsync 21/22 (fails host_anchor_taken_by_guest).
- Smoke set on this branch: session 40/40, travel 23/23, body 20/20, sessionrejoin 36/36, zonejoin 14/14, safety 30/30.
- zoneexit -Fixture coop-zone 37/37 and with -Mutate noseatguard 37/37: host_not_hurt_by_guest_seating passes with the guard OFF too in this
  headless run, so the check does not yet discriminate (the seating jolt did not reproduce this time); the fix itself stays unproven by test.

## 2026-10-25 immersion lane: map transitions as a co-op game shows them, ARC energy on the overlay (docs/spikes/PT6-immersion.md)

Observations (headless MCP probes on coop-zone, hooks with timestamps; details and the full event order in the spike)
- Host travel: `TravelToNextLeg` -> `LoadMap` in the same frame; the game's `LoadingScreen_C` (on the game instance, kept across maps)
  gets `K2_OnBeginLoad` there, `HoldLoadingScreen` when the spawning manager starts, `K2_OnLevelLoaded`, 28-32 s of spawning, then
  `FinishLoadingScreen` -> `K2_OnLevelReady` (FadeGoal 0) -> `FinishAndSpawnPlayer`; the widget's own tick fades it out in 0.9 s.
  The engine adds/removes its Slate widget directly (`IsInViewport()` false); the world is not paused while it is up.
- Guest: the host's close takes the guest world's `NetDriver` away within 60 ms (GameState, world and `netMode()` "client" stay); the
  native rejoin browses back at once, then 15-25 s on the old map without a pawn and without a loading screen, its own load (the
  engine shows the screen there, `K2_OnBeginLoad` fires after our LoadMap pre-hook), then the world visible with no pawn until the
  host's own spawn is done. `K2_OnLevelLoaded`/`K2_OnLevelReady` never fire on a client.
- Setting `FadeGoal = 1`, `FadeDirection = true` after `K2_OnLevelReady` keeps the host's screen up (21 s tried); `FadeGoal = 0`,
  `FadeDirection = false` fades it out as the game does. `AddToViewport`/`RemoveFromParent` of the same widget on the guest shows
  and hides the game's screen (TRAVELING..., throbber, the state text can be set). No errors or crashes in any probe.
- A message sent in the host's LoadMap pre-hook reaches the guest before the close when it skips the flow-control queue (seen 2/2
  once g.trans bypassed it; queued behind other traffic it was lost 1/1).

Changes
- transition.lua (new): host tells the guest "route" (BP_ProgressionManager:Open Map UI), "fade" (first update of the EnterExit
  `Fadeout` / ExitPortal `Final Transition Fade In` timelines), "load" (LoadMap pre) and "go"; after its own load it holds the game's
  loading screen (state text "WAITING FOR <name>...") until the guest's g.net.ready, 60 s at most ("<name> did not load in time").
  Guest: camera fade to black on "fade" (undone after 15 s if no travel follows), the game's loading screen from "load" or the
  NetDriver drop through its own load until "go" (fallback: own character + 8 s; 150 s cap), then a 0.8 s fade-in; feed lines
  "Host is choosing a route", "Host is travelling", "Waiting for <name> to load".
- net.lua: `M.ready(pc)` callback on g.net.ready; g.trans skips the queue. overlay.lua: no "Paused by host" banner during a transition;
  new line "ARC <collected> / <required>" (TextBlock PTArc) under the status in run maps during a session, from the local
  GobblerScreen's GetAnchorCharge (the guest's values are the host's through guestact.lua's g.act.arc mirror). PROTOCOL_VERSION 4.
- Scenarios: transition (coop-zone; host hold seen and released, guest screen at the drop, before its character, removed after),
  arcui (gateway; both ARC lines equal); run-test/run-suite registration.

Results (lane pair C:\PTLanes\immersion, port 7851, headless unless said; folders in local/test-results)
- transition (coop-zone) 26/26 (20261025-113502): host held 2.5-2.8 s (the guest connected during the host's spawn and was ready at
  once), guest screen up at the host's "load" message, before its character, removed on "go". Mutation notransition 23/26
  (20261025-113737): host_held_loading_screen_for_guest, client_screen_shown_at_drop, client_screen_shown_until_placed fail.
- arcui (gateway) 18/18 (20261025-114149): both lines "ARC 7.0 / 1.0". Mutation nooverlay 15/18 (20261025-115116): the three
  ARC checks fail (no widget).
- Rendered pair (coop-zone, MCP session, TravelToNextLeg on the host 11:45:46; local/immersion/*.png, PrintWindow captures of both
  windows every 3 s): the guest's window showed the game's loading screen with "WAITING FOR HOST..." 1.5 s after the host's LoadMap
  (guest-loading-screen-at-host-load.png; the frame 5 s earlier is the zone, guest-before-host-load.png) and kept it for the whole
  107 s the host took to load and spawn (two rendered games on one GPU), the host held its own screen 4.5 s until the guest's
  character was there, both went to the world on the host's "go" (host-after-transition-arc-line.png: host in the new zone with
  "ARC 0.0 / 0.0" under the status; guest-arc-line-overlay.png: the guest's line). Owner observation on this rendered pair: the shared
  load worked and the guest showed "waiting for host" on the loading screen. Not captured: the host's held screen itself (the hold
  began 9 s after the capture loop ended) and the "fade"/"route" notices (the direct travel call has no junction fade).
- Smoke set on ca8e214+ (headless, one at a time, 11:51-12:09): session 40/40, travel 23/23, body 20/20, sessionrejoin 36/36,
  zonejoin 14/14, safety 30/30 (folders 20261025-1154.. to -120900-immersion-*).

Unknowns / not done
- Hand play at a real junction (route menu -> "Host is choosing a route", the junction's fade -> guest fade, the garage gate and
  the exit portal) has not happened: those hooks were registered but only the direct travel path ran. The route-menu car movement
  on the guest (NOTES 2026-10-24 day) is unchanged.
- The host's world runs (not paused) while it holds its loading screen; a stuck guest costs the host up to 60 s standing at the
  spawn with the screen up. The "<name> did not load in time" path was not exercised.
- The radio lane also moves PROTOCOL_VERSION to 4: one bump is enough after the merge.

## 2026-10-25 radio lane (worker, worktree C:\PTLanes\radio, branch lane/radio)

Details and probes: [docs/spikes/PT6-radio.md](docs/spikes/PT6-radio.md).

Observations
- RadioPlaylist is a queue; SkipTrack takes a random front entry and moves it to the end (the last entry is the playing track). Filling the
  front with one track makes SkipTrack play exactly it (about 0.3 s); the list shrinks to 2 and is restored from DefaultRadioPlaylist.
- Custom music folder is `<game>\PenDriverPro\Custom\Radio`; with `RadioSource=1` the library scans it at start (4 files found), but in every
  probe the scanned files did not enter RadioPlaylist. A synthetic custom MusicTrack forced through SkipTrack did become CurrentRadioTrack,
  WmfMedia then failed to open my generated wav and the game moved on.
- A loose BP_CarPart_Internal_Radio_C without a parent exists next to the car's; calling ChangeChannel on it does nothing.
- Rendered 2-client run `radio` (local/test-results/20261025-114756-radio-radio): 34/34. Earlier runs 28/34, 30/34, 32/34 x2 failed
  on test bugs and one real bug (guest's custom-file list sent without the key prefix, so the host skipped shared files).
- The coordinator then limited runs to headless; the radio scenario cannot run headless (CurrentRadioTrack is invalid with -nosound), so the
  noradio mutation was started rendered and stopped before finishing: NO mutation result.

Derived
- carfeel's radio half became radio.lua: guest changes are intents (g.radio.i), the host applies them and sends state (g.radio.s) to
  both players with the current track key; 5 s heartbeat; restart of the track on join and map load; protocol 3 -> 4.
- Custom files match by lower-case file name (cheap, the game itself names tracks by file); no hash.

Unknowns
- That anything is audible; the song position on the two sides (no seek from Lua); how the real library gets files into the playlist;
  a real custom mp3/ogg played on both sides. Needs a hand check with two players and real files.

Smoke set (headless, one run at a time, root C:\PTLanes\radio port 7861): session 40/40, travel 23/23, body 20/20, sessionrejoin 36/36,
safety 30/30, zonejoin 12/14 first (guest stayed at the main menu, host_two_pcs/client_connected_zone timed out; the machine was loaded by
three lanes) and 14/14 on the immediate rerun. carfeel was not rerun after losing its skip/playlist checks (lead's suite run).

## 2026-10-25 lead: full suite on 8488bcb and release 0.0.8

Observations (folders in local/test-results, 2026-10-25)
- Full suite (60 scenarios, 1-3 headless pairs in parallel): 55 passed first time. lootsync, guestcraft, worldzone failed under 2-3 pairs
  and passed on a single-pair rerun (load). stations and anomalies3 failed again on a single pair.
- anomalies3 fails `guest_pushed_by_bunny` (10 s window) on 2fe120d too (20261025-134026): not caused by today's lanes.
- stations: the guest's own CureCarQuirk returns Removed=false (`guest cured quirk: false`), then 8 checks fail (42/50), quirk-independent.
  Today with the weather relink on 4 of 7 runs failed, with it off/absent 1 of 7 (nosimlink 20261025-141046); the same failure is in
  3 runs of 2026-10-22. Derived: an intermittent failure in the guest cure path or its test, older than this release. Cause unknown.
- 0.0.8 (0195e6a) packaged and published as GitHub pre-release v0.0.8; native DLL unchanged (0.0.7).

## 2026-10-24: a guest dropped every ~70 s on a big save (msg.cpp flow control)

Hand playtest on a contributor's own long save (garage storage of 4165 items, a full trunk): the guest joined, got a body,
and 1-2 s later the host closed the connection; the guest rejoined every ~70 s and sat body-less in between.

Observations
- Host `PenDriverPro.log`: `Closing connection. Can't send function 'ClientMessage' ... Reliable buffer overflow`
  (later `Reliable partial bunch overflows reliable buffer`), right after the guest's hello: every module sent its full state
  in one frame. `Ch MaxPacket: 1024`, so a 1000-char chunk is 2-3 partial bunches against UE's 256.
- A fixed send rate (96 KB/s, 16 KB burst) still overflowed 2 s after the join: the joining guest confirms nothing while it
  loads (`20261024-165420-a-bigjoin`).
- Confirmed window: each side confirms received chunks once a frame (`PT1A|<count>`), a sender keeps at most 48 unconfirmed:
  `bigjoin` 17/17, guest kept the same controller and body for 150 s; host `chunks_out=1745 queued_max=308`
  (`20261024-171214-a-bigjoin`). Mutation `nopace` (every chunk at once, the old behaviour) dropped the guest after 2 s with the
  same overflow (`20261024-165842-a-bigjoin-nopace`, run with the rate build; its nopace path is the same old send).
- `PROTOCOL_VERSION` 2 -> 3: a version 2 peer never confirms and a version 3 sender would stall after 48 chunks.

Derived
- Any join with enough state (a long save) hits this; the owner's fixtures were small enough not to.

Unknowns
- Throughput over a real internet link (48 chunks per round trip, ~150 KB/s at 300 ms) is not measured.
- `bigjoin` needs a big garage save as its `garage` fixture; the owner's fixture may not overflow at all.

## 2026-10-24 evening: a guest on a big save (doors, spawn, freezes)

Hand playtest on a contributor's long save (two copies on one PC), then measured on a second test pair, rendered and headless.

Observations
- Map doors (BP_Door_* placed in the garage sublevels, same names on both sides) are not touched by visual.lua: the guest had its
  own fresh states, padlocks on where the host had broken them. New `leveldoors.lua`: the host sends state + locked, the guest
  swings to it (Set Door from State, then its meshes turned back and tweened over 0.35 s); the guest's E sends its own resulting
  state (a press passed to the host opened the host's door the other way: the side comes from the host's character). On a guest,
  `ForceUnlockDoor` hides the padlock but `BP_LockedComponent:IsLocked` stays true (highlight off); `SetLockStrength(0)` clears it.
  `leveldoors` 22/22, mutation `noleveldoors` 18/22 (`20261024-192249-a-leveldoors`, `-192545-...-noleveldoors`).
- Guest spawn: 150 uu to the host's right put the guest inside the pneumatic storage (BP_Garage_AutoStoreVacuum). session.lua
  now tries right/left/back/front at 150 and 250 uu, the first spot with a clear line from the host and no collision.
  `bigjoin` (host placed at -489,185 facing +X, the storage to its right) 18/18; mutation `oldspawn` fails guest_spawned_in_sight.
- Rendered guest profile (6 min, `PT|slow`): garage.lua's 500 ms loop held 60-70 ms every pass (~6 s a minute): the 30 picture
  frames (UP_Garage_Cosmetic_FramedMount_Install) never take on a guest and were installed again every pass. Retries now back off
  (2, 4, 8, 16, 32 s, then given up): 0.45 s a minute, worst ~10 ms. Storage stations take only after a few tries.
- Join-time hitches left (rendered): loot lines for big containers (Expansion 4165 items 1.6 s, Starter 1.5 s), g.prog.lb/wb
  0.3-0.5 s each, first g.car.s 0.4-1 s. net.lua now logs `PT|slow net <kind> <ms> <bytes>` over 50 ms, loot.lua `PT|slow loot
  line`, story.lua `PT|slow story load`.
- garagesync on this save 31/34: guest_has_no_parts_yet (the save already has fax/shredder/destabilizer) and the drive-out (the
  car is parked inside, the waypoints start in the yard) are fixture assumptions, not regressions.

Unknowns
- The door tween and the new spawn were not watched by a person yet. Picture frames stay empty on the guest.

## 2026-10-24 night: frame time on a big save, position desync watch

Observations (rendered pair on a long save, `PT|perf` / `PT|slow`, then fixes, headless suites)
- Guest join froze 22 s in one garage.lua pass: ~80 station installs at once. Now 2 installs a pass (500 ms); failed installs back
  off 2-32 s, then are given up (30 picture frames never "take" as upgrades, but the frame actors exist).
- Picture frames' contents live in garage containers `Stations.Install.Mount.NN`; loot.lua now shares them (both ways). An item put
  in a guest's frame container shows on the wall at once. `frames` 20/20, mutation `noframes` fails.
- Host loops that cost 1-2.6 s a minute each, and what they do now: progression (one section a pass, each every 4 s), carfeel
  (audio/speedometer lookups cached 3 s, the per-component-move hook only on the guest, playlist read every 2 s), visual paint
  (host 5 s, guest only on change), story history (read every 3 s, full resend every 60 s), garage upgrade read (6 s), car
  ARC slots (5 s) and door parts (2 s). Guest: the car follow loop skips frames while the host's car is parked; progression
  apply is queued, 4 ms a frame; the ARC map is captured once (30 s) instead of twice.
- Position desync (desync.lua): the guest reports its own spot and where it sees the host twice a second. A host copy that
  stands while its guest walks (repro: the copy's movement disabled and the engine's correction off) is found within ~1 s,
  repaired, and the guest put back at the host's spot if still off: `desync` 19/19, mutation `nodesync` 18/19 (stays 507 uu
  off). A movement tick off alone is no fault (the engine still runs the guest's moves).
- carsync/carfeel fail on the long save (the host starts seated: the seat check uses the host's seat) and pass on a fresh
  garage save (`local/fixtures-fresh`, slot 4): 36/36, 41/41. carexit 29/29, bigjoin 18/18, leveldoors 22/22, storysync 24/24.

Unknowns
- The stations/storyprog/upgrades/visualgarage failures on the long save are not sorted into fixture assumptions vs regressions.
- No rendered re-measure after the last round of loop changes.

## 2026-10-24 late: the host stood still on the guest's screen (saturated connection)

Observations (rendered lane D:\PTLanes\a, owner's long save, game MCP; engine log `log LogNetTraffic VeryVerbose` on the host)
- While the host walked, its character on the guest stopped for minutes: on the guest `ReplicatedMovement` and
  `ReplicatedBasedMovement` of the host's copy stayed old, the host's PlayerState `Score` set on the host never arrived, and the
  guest's log said `CreateSavedMove: Hit limit of 96 saved moves` every ~6 s (no move acks; the host logged `ServerMove:
  TimeStamp expired` for the guest). Our reliable messages kept arriving the whole time.
- On the host the guest's connection was fine (receives every frame, ViewTarget = the guest's character, actor channels open,
  CurrentNetSpeed 100000, driver MaxClientRate 100000) but the engine log said `Saturated. Mark PDP_MainCharacter_C_... NetUpdateTime
  to be checked for next tick` for every actor, while our ClientMessage traffic averaged ~4.7 KB/s in bursts of ~1 KB chunks.
- It shows from the join on (51 "Hit limit" lines before anyone moved) and after a 5 s guest hitch while the host sends; it did
  not show in headless runs (higher frame rate).
- A/B on the same running pair: a 300 KB burst at the game's 100000 -> the guest saw a changed score 15 s later still not;
  raising that connection's CurrentNetSpeed to 1000000 -> the score arrived within 4 s; a second 300 KB burst at 1000000 ->
  all 10 messages and the score within 3 s.

Derived
- A saturated connection gets no actor replication and no move acks; only reliable RPCs go. Our windows of chunks (and the
  join state) kept it saturated far longer than 100000 B/s explains, so the per-tick budget is smaller than CurrentNetSpeed at
  low frame rates.

Checked in the binary (Ghidra 12.1.4 headless, no auto-analysis: functions found from their log strings, decompiled alone)
- UNetConnection::Tick is at 0x142e61620 (references "UNetConnection::Tick: Removing from KeepProcessingActorChannelBunchesMap").
  Per tick: `rate = min(engine max tick rate, driver+0x5c)` (FLT_MAX when neither is set), `dt = clamp(time since the last
  tick, 0, 1/rate)`, `QueuedBits(+0x1F8) -= CurrentNetSpeed(+0x38) * dt * 8`, floored at `-2 * CurrentNetSpeed * dt * 8`
  (constants 1.0, 8.0, FLT_MAX read from the exe). So a frame longer than 1/rate earns no more budget: at low frame rates a
  connection gets less than CurrentNetSpeed per second, and a long hitch earns nothing extra.
- The "Saturated. Mark %s NetUpdateTime to be checked for next tick" log is in the function at 0x142e8b2a0 (server replicate
  actors): after the prioritized-actor pass stops early, every remaining actor is marked for the next tick.
- Ghidra on this PC: Felix (OSGi) would not start with its cache under %APPDATA% ("The data file must be inside the data dir");
  `VMARGS=-Dapplication.settingsdir=C:/Tools/ghidra-settings` in support/launch.properties fixed it. Script and how to run it:
  `local/ghidra/DecompileByString.java` (see its header).

Fix
- net.lua raises CurrentNetSpeed of every session connection (host: each guest; guest: its connection to the host) and the
  driver's MaxClientRate/MaxInternetClientRate to 1000000, checked twice a second. Test `netspeed` (1.5 MB burst, score within
  6 s), mutation `oldspeed`.

- msg.cpp also sends at most 8 chunks per frame and connection (a whole 48-chunk window in one frame still saturated at 1 MB/s:
  `netspeed` failed with the speed alone).
- Headless on D:\PTLanes\a after both: netspeed 18/18 (score in 2 s), mutation oldspeed 17/18; channel 21/21, session 40/40,
  bigjoin 18/18, leveldoors 22/22, frames 20/20, desync 19/19 (long save); carsync 36/36, playpath 27/28 (fresh save).
  lootsync/progsync not run: they need a `zone` fixture, none in local/fixtures.

Unknowns
- Whether 1 MB/s over the Steam relay on a slow uplink queues too much in the socket instead (bursts are up to ~48 KB).
- playpath `p3_host_trunk_has_guest_item` failed (the guest opened and closed the trunk menu, the host's trunk did not grow in
  90 s): not yet compared against a run without these changes.
- No rendered re-check of the host's movement on the guest's screen after the fix.

## 2026-10-28: upstream 0.0.8 merged into the owner's main (not committed yet)

What was kept where both sides had it
- World doors: upstream's (visual.lua); our leveldoors.lua and its scenario are removed (owner's choice).
- Host -> guest flow control: upstream's net.lua queue (window of 160 bunches, urgent kinds first, bulk held until g.net.ready)
  stays on top; under it msg.cpp keeps its 48-chunk window, at most 8 chunks a frame, and net.lua's 1 MB/s connection speed
  (the saturation fix, NOTES 2026-10-24 late). PROTOCOL_VERSION 5 (msg.cpp acks "PT1A|": a plain 0.0.8 peer never sends them).
- Car loop and car audio cache: upstream's (the same 1 Hz part lines, 2 s door cache, 5 s ARC slots, wider). Radio is radio.lua.
- progression.lua: upstream's file, with our guest-side apply queue (4 ms a frame, a chunk sent again is not queued twice).
- garage.lua: upstream's reapplyWb after an install that took; our 2^k s backoff and give-up after 6 tries for one that did not.

Results (headless, D:\PTLanes\a, 2026-10-28; long save = local/fixtures, fresh = local/fixtures-fresh)
- Long save: netspeed 18/18, netflow 17/17, bigjoin 18/18, frames 20/20, desync 19/19. No fixture: channel 21/21, session 40/40.
- Fresh save: worlddoors 23/23, carsit 25/25, survivor 29/29, pausehost 27/27, carsync 36/36, playpath 27/28.

Unknowns
- playpath `p3_host_trunk_has_guest_item` fails on the fresh garage save before and after the merge; upstream's suite runs
  playpath on a zone save, which this checkout does not have. Not compared against an unchanged tree.
- lootsync, progsync, zoneexit, transition and the other zone/gateway scenarios not run (no zone fixtures here).

## 2026-10-28: crash damage for a seated guest, opening skip for both (from PDCoopNet refactor, MIT)

Observations (headless, D:\PTLanes\a)
- Crash damage: the car's damage controller (`BP_CarDispatchController`, a plain object, not an actor or component: no GetOwner)
  works out the player's share in `LimitDamageToPlayerOverTime`; the hook's out parameter holds the share after the call. While a
  guest sits in the car whose `DamageDispatchController` it is, the host sends that share as `g.anom.msg` (tag "crash"); the guest's
  own receiver applies it. `carcrash` (fresh garage, guest seated by a real door press, the host calls the controller 10 times with
  2.0): 21/21, guest 100 -> 98, host untouched; mutation `nocrash` 20/21. The garage deals no player damage, so the module skips it
  unless PT_CRASH_GARAGE=1 (set by the runner for carcrash only). Not checked in a real crash in a zone.
- Opening skip: the intro level's `InpActEvt_Interact_K2Node_InputActionEvent_0` with CanSkip set moves the opening to its end
  (SEQ_OpeningCredits frame -3 -> 2039, stopped; CanSkip false). A host has a second, stale copy of that level script in
  /Engine/Transient with CanSkip true for good; pressing it does nothing, so it is ignored. E (or console `ptskip`) skips on the
  presser's side and goes to the other side as `g.cut.skip`; the host passes a guest's skip on. `cutscene` (new game in slot 6):
  22/22; mutation `nocutscene` 20/22.

Unknowns
- E also interacts in the world; during the opening nothing else answers E (not checked in a rendered game).

## 2026-10-28: passenger door in/out, storage layout (not committed yet)

Observations (headless, D:\PTLanes\a)
- The guest's E on the passenger door only fired its highlight events 2/0 and AttemptOpen (door opens, nobody gets in); the game
  enters only through the driver's door. car.lua: AttemptOpen on SLOT_FrontRightDoor from the guest (not riding) now sends the
  enter intent. The body glides (car-local points) from where it stands past the nearest front-door EntranceLogicPoint onto the
  seat (0.8 + 1.1 s) on both sides; out, the spot is the game's LocateSafeExitPoint mirrored to the passenger side (ground trace,
  driver's spot as fallback), the host moves only the mesh there, the guest its own pawn. `carseat` 28/28 (largest step 15 uu in,
  29 out); noglide 131/163 uu (fails), driverexit and nopassdoor fail their checks. carsit 25/25, carexit 29/29, carcrash 21/21,
  carsync 36/36 (one run 32/36: the guest's car never settled after the drive, not seen again).
- desync.lua's repair turned walking and collision back on mid-glide (carsync: the guest 87 m away glided through the car, hit by
  Physical_Impact, seated 106 uu off): desync now skips gliding bodies; a guest more than 6 m away is seated at once.
- Garage storage is an ItemTileLayout grid (CL_Garage_V1 8x11): each stack is an ItemTileSlot at Location X,Y (+bRotated), slots
  come and go with their items. SetNumSlots/AddSlot do nothing. The state was a bag, so each side placed items anywhere and a move
  inside a container sent nothing. Now "@x.y.r=spec*n+..." per stack; on a difference the receiver empties the container and
  places every stack with the layout's EmplaceSlot (ignoring collision; instances reused); ItemContainer HandleSlotItemAdded/Removed
  mark a container for the next scan. `storagelayout` (owner's long save, the Starter locker, slots swapped on each side) 21/21
  three times; mutation `nolayout` 18/21.
- Double doors (BP_Door_Double_*) are children of BP_Door_Single: the placed ones are in visual.lua's door list already.

Unknowns
- storagelayout failed once of four: right after the join both sides sent the locker without a move and kept overriding each
  other. Guess: the guest's own garage station installs (garage.lua, same seconds) touch its containers. Not reproduced since.
- On the guest, applying the host's Expansion container (4165 items, a bag) took 2.3 s in one frame.
- What exactly breaks double doors in play is not known yet (not looked at live).

## 2026-10-28 evening: double doors, door swings, filling big containers over frames (not committed yet)

Observations (headless, D:\PTLanes\a; live checks in game MCP sessions)
- BP_Door_Double (< BP_Door_Single) has a second leaf: component OtherDoor (relative yaw = currentRotOtherDoor), its own
  Highlight_OtherDoor and event BndEvt__Highlight_OtherDoor_K2Node_ComponentBoundEvent_0_OnHighlightInteract__DelegateSignature,
  closed angle AnimTargetClosedOther (180), timeline Timeline_0. Pressing it leaves CurrentState alone (90 -> 180 seen), so it never
  synced and the guest's E on it never reached the host. In the fresh save the back room's double door is chained (state 3).
- On the guest a press of that leaf turns it only sometimes (its timeline did not run in 2 of 3 tries) and sets AnimTargetOther to a
  value that is not where it ends; the host's press from a distance (no player) went to "15 -> 15" (its locked shake).
- The guest snapped every door with "Set Door from State". Pressing the guest's own main-leaf highlight plays the game's swing:
  69 different angles from -90 to -180 (was one jump).

Changes (visual.lua)
- Door state carries the second leaf (ot=, placed doors "path=state/angle"). The guest opens or shuts a main leaf by pressing its own
  highlight (a lock or anything else still snaps), turns a second leaf with its own 0.8 s tween, and leaves a door alone 2-3 s
  after a press (here or its own) so the host's state does not pull it back mid-swing. The guest's E on a second leaf sends the
  angle it ends at (its game's, or the toggle shut <-> 90 degrees done here); the host tweens its leaf there.
- doubledoor (long save, BP_Door_Double_Backroom_Exterior) 23/23; nodoorswing fails guest_main_leaf_swung; nodoubledoor fails
  host_second_leaf_follows_guest. worlddoors 23/23 (fresh).

Filling big containers (loot.lua, ids.lua)
- On the guest the host's Expansion storage (4165 items, a bag) held one frame 2.3 s. A coroutine cannot slice it: UE4SS refuses
  game calls from a coroutine's Lua state ("The lua state ... has no instance inside lua_instances"; every loot line failed).
  ids.apply/applyLayout now return their item operations as a list of steps when asked; loot.lua runs them in its 4 ms-a-frame
  budget before the next line, the container marked busy so the change scan does not send it half filled. bigjoin: Expansion
  filled in 4165 steps over 9.8 s, no single frame over 0.1 s for it; bigjoin 18/18, storagelayout 21/21, frames 20/20.

Unknowns
- Other join spikes on the long save's guest: first g.car.s 808 ms, progression.lua:238 372 ms, story.lua:323 359 ms.
- Zone door copies (visual props) take the same applyDoor path; not run (no zone fixture here). Rendered play not checked.

## 2026-10-29: Steam-free direct IP and passenger car controls (owner request)

Observations
- Owner's Radmin session (real install log): the guest connected and sent its hello three times; the host refused each with
  `build mismatch: host has 21896301, you have 911` (game=1.15.0, mod 0.0.8, protocol 5 equal). The build id now only logs.
- On the seated guest `BP_HighlightManager:Should Allow Highlight(Highlight_Key)` = false, "Must be inside car!"
  (`IsPlayerInCar` false, car manager `PlayerCarState` 0: the mod seats by attachment). The handbrake attachment passes.
  A UE4SS post-hook `allow:set(true)` did not change the out param (the call still returned false).
- Host setters: `ManualSetIgnition_NoAnim` takes 0 (off) and 2 (running); 1 does not stick. `ManualActivate_Gearbox` 1 = P with
  the parking brake on, 0 = D with it off; 2 did not stick in park. `VehicleController:SetParkingBrakeActive(false)` in P is
  put back. `ToggleIgnitionState(1)`, the Highlight_Key bound events and `HighlightPress` on the driving host changed nothing
  headless.
- Reading every property value of `AB_HandbrakeAbility_C` through the repl crashed the host twice (AV reading 0x10).

Derived
- The passenger aims with its camera (8 degrees, 200 uu: `UICollision_Key`, `Socket_GearBox`) and presses E; `g.car.ctl ign|gear`
  toggles on the host. guestctl 34/34 (`20261029-005331-a-guestctl`); noguestctl 29/34
  (`20261029-005813-a-guestctl-noguestctl`). sessionmismatch 21/21 after its host refusal wait was raised to 130 s.

Unknowns
- The E key and the aim test are not drivable headless (the scenario sends the intent E sends); rendered hint and real aim
  in hand play are unchecked. The game's own key animation and failed-start chance do not run for the guest's turn.
- `player_id.txt` backpack keying and a build-911 guest in a full session are not tested.

## 2026-10-25 owner hand play of 0.0.8 (logs local/playtests/20261025-pt7-008)

Observations
- Rendered pair, coop-garage, garage -> Highway_Forest_04 -> Wilderness_Forest_20: transitions worked; owner: "seems working".
- Owner: the ARC energy shows only the collected amount; required is 0.
- Headless coop-zone (Wilderness_Forest_06, 20261025-152241-repl): host GetAnchorCharge Max=0 and route whiteboard
  WB.ActiveRun.AnchorsRequired=0, guest Max=0 too (the mirror copies the host faithfully). Host current leg (rs.CurrentLeg):
  AnchorRequirement=1, CanReveal Reason=1 (ELegRevealFailure.Disabled), no WB.ActiveMap.IsEnd. Each map loaded once on the host.

Derived (atlas BP_LegStateBase K2_OnVisited 1426): required = AnchorRequirement only when CanReveal is Ok/AlreadyRevealed or IsEnd,
else 0; so 0 follows from the leg being Disabled (SetRevealable false: BP_RouteStateBase reveal pass, CPE_ScanSettings
CheckIfShouldBeScannable keys on WB.ActiveRun.GatewayRequirementAmount.* / CP_GatewayRequirements IsExitPoint).

Unknown: whether the same save in single player also gives 0 (vanilla for this progression) or co-op makes the leg Disabled.
No mod-free launch exists to compare.

## 2026-10-25 afternoon: owner + friend Steam play of 0.0.8, ~1 h (logs local/playtests/20261025-pt8-live)

Setup: real installs, friend = host (`host/UE4SS (2).log` from 15:32, his odsave1.sav + 4 backups 16:15..16:32, no engine log),
owner = guest (`guest/UE4SS.log` from 16:09, engine logs, crash dir). Guest clock reads ~4 s ahead of the host's.
Owner report: an hour without major problems; radiation out of sync; Q01 (antenna / ScannerParts) stuck after two runs.

Observations
- Q01 stuck. Run 1: host log 16:06:47 `act grab BP_Resource_Narrative_Q01_RadioBitsGrabbable_3 grabbed=true` (guest grab relayed,
  guestact.lua grab path); bits end in the trunk (`loot got S I:Inventory_Trunk ...Q01_RadioBi`, host 16:12:43). On garage
  return guest gets `WB.Missions.QD_Q01_Mission_C.SuccessfulRun.Completed nil -> 0.00` (16:12:00), objective restarts on
  QD_Q01_Mission_A then -> Mission_C within 4 s; host installs ZoneScanner (`WB.GarageUpgrades.ZoneScanner -> 1`, 16:14:53).
  Run 2 (16:20): `RP_CP_Q01_ScannerParts.LastAttempted -> 2`, dialogue `DS_Q01_Retry01_StillNeedThose`, host carries the bits
  (guest hands mirror 16:26:11), return at 16:30:45 again Mission_A -> Mission_C. All five saves name only QD_Q01_Mission_C.
- Guest crashed at 16:08 mid-run 1 (before its current log): `EXCEPTION_ACCESS_VIOLATION reading 0x280` while opening
  Pause > Settings and switching category (Graphics page construct; stack through UE4SS.dll). Rejoined in-zone at 16:09.
  Guest's run-1 UE4SS log was overwritten by the restart; its engine log survives (`guest/prev-run-crashed-1608-PenDriverPro.log`).
- Radiation: host log has only 2 guest-originated radiation hits (0.005 each, 16:27, right after the guest pulled a stable anchor)
  and 7 physical-impact hits (16:20). Host's own radiation damage is not logged by the mod. Guest rebuilds volumes from
  `g.rad.vols` (`radiation guest volume ... r= max=` lines at 16:09 and 16:20/16:21). No log line names Hot Dust on either side.
- Anchors: guest pulled S (16:27:45) and L (16:29:13) stable anchors, `taken on the host`, deposited via `act anchor`.

Derived / guesses (not checked)
- Q01 completion likely depends on something the host's game records at grab/extract time that the relayed
  ShortGrabComplete or the loot-synced trunk copy does not give (e.g. the bits must be in the host's own inventory/car through
  extraction, or a SuccessfulRun flag set by the vanilla grab path). The guest crash/rejoin mid-run 1 may also matter.
- "Save corrupted" is probably quest state, not a broken file: saves parse-look normal (SAVC header) and keep Mission_C.
- Hot Dust seen only by the guest while the host carried an anchor: the guest's local game may run anchor-carry hazard spawns
  on the host's mirrored carry, or the mirrored volumes differ from the host's. Host damage "for no reason" may be the reverse.

Unknown: what Q01 Mission_A/B/C each require; whether the friend's save completes Q01 in single player (fixture candidate:
`host/odsave1.sav`, test copy only). No offline SAVC decoder exists; strings show only partial names (compressed chunks).

## 2026-10-30: pt8 fixes (Q01 stuck, radiation around anchors), Settings crash not reproduced

Merged first: Everelsu fork main (0a1fa70, fast-forward; protocol 5) and coop-anything upstream b494a3f; native DLL rebuilt
(fork's msg.cpp). Fixture `pt8-q01` = the friend's host save after run 2 (slot 1, RB_Garage, Q01 on Mission_C), test copies only.

Observations
- Q01 Mission_C tasks (host, pt8-q01): CR_Q01_AntennaMats ingredients (done), FoundAnchor (WB tag), GrabbedAnchor =
  BPMT_HasItem_HandSlot IA_Resource_Anchor_Stable_L, DepositedAnchor (ARC +0.25), ChargeGobbler (done), ExitSelected (WB tag),
  SuccessfulRun = BPMT_ReturnToGarage. In pt8 the guest pulled both anchors; no `story guest reports task` line in either log.
- A guest holding Stable L completes its own task 3 (mask 1010100) but the host stays 1000100: reportTasks skipped it because
  `t.CheckCar or t.CheckZETI` on a class without those properties returns a truthy TrivialObject (UE4SS), read as "trunk check".
  Fixed (`== true`); q01anchor 21/21 (`20261030-124749`), unfixed 20/21 host_task_done_by_guest (`20261030-124940`).
- BP_Spawn_Anchor_Base_01 AnchorTaken (atlas, ubergraph 5114): destroys the anchor's RadActor and broadcasts
  CauseHazardDisturbance. visual.lua already calls it on the host for a guest's pull: one HazardDisturbance(nonAnchor=false)
  per guest pull (anchordup `20261030-130054`). The guest's game has no BP_HazardAnchorPull_C (zone fixture).
- radiation.lua only added volumes on the guest and sent nothing when the host had none: a removed host volume kept radiating on
  the guest. Fixed (unmatched guest volumes set to 0, empty list sent); radiation 22/22 (`20261030-125356`), unfixed 20/22
  (`20261030-125616`).
- Settings crash: stack starts at the pause menu's Settings press (default category selected while the menu builds), crash in
  native code after PageGraphics constructed. Not reproduced: headless and rendered guest on the zone fixture, same GPU/RHI/DLSS
  plugin, Accessibility -> Video and 6 open/close/tab cycles (`20261030-123952`, `20261030-124158`).

Derived / guesses
- Q01 stuck = GrabbedAnchor never done on the host when the guest takes the L anchor, so the run is not successful and the
  objective restarts. Not run end to end (zone run with the friend's save) yet.
- "Hot Dust around carried anchors" = the guest's copy of the anchor's RadActor volume outliving the host's.
- Settings crash may depend on the owner's real graphics settings (test copies run on Low) or zone state; no fix made.

Unknown: FoundAnchor/ExitSelected tags when only the guest is at the site; whether zeroed guest volumes pile up for moving clouds.

## 2026-10-30 afternoon: guest rain, co-op weather, guest ride feel, held tools (owner requests)

Observations
- Rain: host and guest weather values matched (rain 1.0 both), but the guest had no NS_Ambient_Environment_*, NS_RainSplashes_01 or
  NS_PlayerRadiation: BP_AmbienceManager's EnvironmentComponent/RainSplashSystem/PlayerRadiationNiagaraSystem were invalid (its setup
  ran before the guest's character existed). SetupEnvAmbientVFX/SetupSplashEffects/SetupRadiationVFX by hand made them. Headless games
  make no Niagara systems (the setup returns nothing). weathersync rendered 23/23, noambience 22/23; headless the check skips.
- Weather: overrides by priority, entry 0 drives the sky (FogMedium/FogLight p1 in the zone fixture); debug events work in shipping
  (Set ToD Midnight 0.000, Dawn 0.300, Noon 0.500, Sunset 0.680; Force Event: Storm/Rain Heavy/Dark Heavy replace each other async);
  AddTODWeatherOverride with an existing identifier replaces it; Set Time Of Day Speed Multiplier(New Speed) sets LocalTODSpeedMultiplier.
  Co-op weather (world.lua): weathersync 24/24, nospooky 23/24.
- Guest car: POV vs FP_Camera after the car's placement 5.95 uu p95 with the UE4SS loop (camera computed first), 0.00 from the car's
  ReceiveTick (fires every frame on the guest copy). Head sway max ~10 uu. carsync 38/38, nocartick and nosway each fail their check.
- Held tools: the mirror's base part was picked by unscaled bounds (Scrapper: canister fill r=137 at 0.1 scale) and placed at scale 1
  with no grip; first-person meshes carry runtime MIDs. Every tool tried has a world twin (`<FP mesh>_World`, same folder, true size).
  First-person arms skeleton: Root BaseArm Wrist Hand ... (no hand_r). Grip correction = Prybar's pose on the FP Hand bone.
  hands 64/64, noworldmesh 62/64 (hammer checks). Rendered: hammer, scrapper, prybar recognizable (screenshots in client2 Saved\Screenshots).

Unknowns
- Feel of the sway constants (gain 0.012, 2.5 Hz, clamp 10 uu) and the grip of tools other than the three looked at: owner hand play.
- The guest's own car "prediction": the follow delay (100-250 ms) is unchanged; the guest is not driving, so it is not felt as input lag.
- Whether forced weather events change gameplay (lightning on the car) beyond looks.

## 2026-10-30 evening: co-op mood (quiet tag, quiet feed, shared scares, shared waypoint)

Observations
- BP_AmbienceManager: every ambient event (PickAndStartNextEvent -> async load -> "Spawn Ambient Event Actor"(Event Class, Position))
  is local; AmbientEventsEnabled gates the random pick (ShouldAmbientEventPlay), the debug Force* events bypass it. The guest calling
  Spawn Ambient Event Actor with the host's class and spot works (ok=true; the host's own Birds_Circling also went through).
- ARC waypoint: UMG_GobblerScreen PlaceWaypoint spawns/moves one local BP_WaypointActor (self.Waypoint); the actor destroys itself
  every 1 s check when the local camera is within 1000 uu (2D). ClearWaypoints/RemoveWaypoint destroy it.
- Footsteps: no ProcessEvent call matched Footstep/AnimNotify/Ak*/Surface while the host walked (headless, -nosound). Unknown
  whether they are native anim notifies or skipped without audio; partner sounds need a rendered look.
Results: nametag 24/24 (loudtag 21/24), overlay 40/40 (loudfeed 37/40), sharedworld 25/25 (noambsync 23/25, nowaypoint 22/25).

## 2026-10-30 evening: rescue menu (owner request: a way out of glitches and softlocks like Q01)

Observations
- A guest's own K2_SetActorLocation moved it only on its screen: the host's copy stayed at the old spot (idle client sends no
  move). Teleport now goes through the host (moves its copy, sends the spot back). rescue run `20261030-145857` / `-150026` failed
  host_guest_teleported, after the change 21/21 (`20261030-150503`).
- ForceCompleteTask on the host's Q01 Mission_C GrabbedAnchor (task 3), asked from the guest by UniqueName, completes it on the host
  and the guest's mirror. norescue mutation 18/21 (teleport, host task, guest mirror fail).
- Rendered hand play (owner, test copies, logs local/playtests/20261030-rescue-live): a held F9 reads down/up on alternate 30 ms
  polls, so one press toggled the menu several times per tick (debounced, 0.4 s since the last down edge). The panel stayed
  empty: overlay.lua's render read `panelText` declared below it (a nil global). After both fixes all four actions worked by hand.
- Q01 forced done in the garage (all Mission_C tasks): Mission_C and QD_Q01_Objective completed, no objective active, and
  BP_QuestDirector's "Q01 complete" branch (AntennaSignalsReady line, delay, StartObjective QD_Q015_Objective, whiteboard tag
  WB.quests.objectives.QD_Q01_Objective.MissionEVODelay.Complete) never ran. StartObjective(QD_Q015_Objective, false, true) by hand
  started Q015 Mission_A; the menu now offers it (NEXT table, Q01 only).
- Guest rain: BP_AmbienceManager on the guest had VFXInitialized=false and AmbsReadyToPlay=false (initialised before its character),
  so K2_Tick never updated (PS_Ambience_Rain stood where first placed, Inside_* stayed 0). The guest also had no
  rainOcclusionCamera_Blueprint_C and no BP_GlobalHeightCapture_C (host-side spawn). RetryInitialize + InitializeAmbientVFX +
  SpawnRainOcclusionCamera + spawning the height capture: owner saw rain and splashes on the guest.
- Held tools: the grip read off the first-person arms changed with their animation (Scrapper 52 -> 17 uu in 0.3 s), rebuilding the
  mirror every report; world meshes (Scrapper's is SM_Tool_ItemHarvester_01_World, no "_Base") have other pivots than the
  first-person parts, so the grip put them up the arm. Now: grip read once 1 s after equip, world meshes held level, front forward,
  pivot in hand_r. Owner: Scrapper, Impact Hammer, blowtorch, Extractor, repair tool, prybar, Vacuum "all look nice".
Unknown: number keys with the menu open also reach the game's bindings; which of the occlusion camera and height capture the rain
needed (both are spawned); held-tool look while the other player walks or uses the tool.

## 2026-10-31: the Rogue as the partner's body (owner request: a real character model instead of the crude survivor)

Observations
- Candidates in the owner's files (moved to `local/player_model/`): Survival_Character (UE 5.1 content, 1.3 GB, 4K-8K textures)
  needs the UE editor to cook; Rogue_FREE (`rogue_free.ma`, Maya 2025 ASCII, 14 skinned meshes, 11.6k verts, 5 flat lambert
  colours, no textures) can be read as text. Both use the UE5 mannequin skeleton (spine_01..05, neck_02, corrective bones).
- `tools/model/maya_ascii.py` reads the .ma: Orig-shape meshes, skin weights, bindPreMatrix, joint hierarchy (self-check: the
  hierarchy rebuilds every stored bind matrix to 1e-3), per-face materials through groupParts/groupId.
- The car interior has no trace collision (Visibility and Camera traces from the passenger footwell hit only the garage floor,
  69 uu, car origin 147); the seated pelvis is at 139. Seat pose tuned by eye with the owner (thighs 95 deg up, shins 60 deg
  forward); host and guest both confirmed no legs under the car.
- The guest's game never ran a seated pose for the driving host (car.lua seats only the guest); survivor.lua now folds the legs
  of any body attached to the car on its 2 s refresh.
- Hand play (owner, rendered pair) rejected in turn: inside-out faces (converter reversed the winding), hollow belly and
  shoulders, a broken crotch, faceted shading, straps and the cloak torn between bones, and copies of triangles on a second bone
  sticking out. Root causes: the game's UE4 spine_03 is the chest (140 cm), the model's UE5 spine_03 the waist (113 cm); the
  game's shoulder joint sits 7 cm higher on the chest; each part turns onto the game's A-pose by its own angle.
- Accepted look: pads, shoulder pad and cloak dropped; belts and straps rigid; torso three blocks (hips, chest anchored at the
  model's spine_05, head with neck); one bone per triangle; every part placed where its parent puts the model's joint; no
  stretching; smooth normals; colours x2.5; black mask with a glowing face from the game's neon material
  (`MI_GasStation_Light_01`, Glow Color / Glow Intensity): host amber grin, guest green round eyes and zigzag mouth.

Results: survivor 31/31 (new other_variant check), carsit 26/26 (new host_sees_guest_legs_folded, knee-hip dz -3), carexit 29/29,
session 40/40. Not run: the full suite, lag/loss, mutations for the new checks.

## 2026-11-01 night: fixes from the friend-hosted 0.8.5 session (pt9)

Logs: `local/playtest-20261031/` (193135 = host, 18:34-19:29 only; 203059 = guest, 19:08-20:30). Plan and per-item status:
`local/resume/RESUME-pt9-night.md`.

Observations
- Guest `PT|perf world.lua:405` (16 ms hazard smoothing loop) 0.2 s/min at 19:38 -> 10.3 s/min at 20:24; `loot.lua` 500 ms tick
  held host frames 31-39 ms (1124 `PT|slow` lines in the host's first hour); `car.lua` localPC ran FindAllOf PlayerController per frame.
- Host log `radio host skips L:<file> (the guest lacks it)`; guest `radio guest has N custom file(s)` grew 1..9 one by one: the
  game makes a custom MusicTrack only when it plays it. Setting `MusicTrack.ExternalUrl` from Lua works (eval).
- Garage probe: host lists `/Engine/Transient` templates of BP_Spawn_Resource_ElectronicDevice_{Computer,Radio} at 0,0,0; the guest
  spawned real copies there (the "unbreakable PC"). Guest pump had 3 BP_WorldItem_Resource_GasPumpHandle attached, host 2.
- Guest log: 30 `radiation guest volume at` per minute at 19:59 and 20:16 (host carrying an anchor): a new volume per 4 s update.
- Host log: one guest-forwarded `MSG_Damage_Physical_Impact 60.000`.
- Trunk crash (crash F1919, guest 0.8.5): in `UMG_PlayerMenu_Inventory ContainerOnHoveredSlot`; ids.applyLayout RemoveAllItems frees
  the slots the open menu hovers.
- Zone fixture: host 19 runtime BP_Spawn_GasBarrel, guest 0 (only the map-placed one); BP_ZoneTrader is a zone-generated actor too.
- `GetSlot(i)` on the car equipped container crashed the host (AV 0xa, three scenario runs); `Slots`/`Items` iteration is safe.

Fixes (0.8.6) and results
- Closing the guest's menu from Lua (`Try Close Menu`) left the game unable to open any container menu again (lootcar 20/24,
  bisected to it). An unsliced refill plus the menu's `Reconstruct Inventory` passed lootcar 24/24 but lost the guest's take in
  playpath (p2_host_container_lost_item). Final: the partner's state for the container the open menu shows waits in e.pending
  and is applied when the menu closes (watchMenu: UMG_PlayerMenu_Main_C IsInViewport + Category_Inventory.TransferContainer;
  the inventory page keeps TransferContainer after closing, so reading it alone deferred the trunk forever, lootsync 32/34).
- loot.lua (open-container fill, throttled scans, template filter, pump nozzles local, car part containers `I:Car.<slot>`),
  world.lua (smooth hazards within 80 m), car.lua (cached controller, aim 14 deg / 260 uu, radio target), radio.lua (guest makes
  tracks from its music folder, misses expire after 60 s), radiation.lua (move own copies, destroy own leftovers, 1.5 s),
  anomalies.lua (no Physical_Impact forwarding from the guest), hands.lua (never mirror on own body), visual.lua (trader, barrels),
  heal.lua (H), perf.lua (F10), overlay.lua/rescue.lua/guestui.lua (game fonts, F9 card).
- lootsync 34/34, lootsync2 33/33, garagesync 35/35, guestctl 34/34, storagelayout 21/21, hands 64/64, radiation 22/22.
  radio: committed 0.8.5 fails the same 3 checks headless (host_skips_custom_the_guest_lacks, guest_same_track_after_own_skip,
  guest_follows_host_skip); one check changed to the new rate (`host_announced_missing_custom_once_a_minute`).

- Gas barrels mirrored to the guest (visual.lua ALLOW) arrived over the zone mirror's minute; playpath failed 2 of 4 runs with
  `move_to ... stuck` and "NOT interactable here" while copies were still being spawned. Taken out again; barrels stay host-only.

- Full suite on the candidate (`suite-20261101-002512`): 51/60. Failing the same way on committed 0.8.5 tonight (stash runs):
  playerhealth (host sees stale guest %), visual (guest_door_follows_host), pausehost (guest walks 9 uu vs 10), zoneexit
  (guest_reentered), playpath (1 of 2), anomalies3 (bunny, since 10-25). runloop and anomalies2 passed on rerun. lootcar was a real
  regression (menu close) and passes 24/24 now; guestcraft failed 2 of 4 (guest's dropped tool never came back; new
  `loot guest drop` / `guest's drop` log lines added) and passed the last run.

- Final code: rescue 22/22 (card title check), radio 31/34 (0.8.5 also 31/34 tonight; this run guest_plays_shared_custom
  failed instead of host_skips_custom: the host announced ptB before the test made the guest's tracks, the guest's miss then
  held it), lootcar 24/24, guestcraft 26/26, playpath 0.8.5 37/39 and 39/39.

Not checked: real custom files, the trunk crash, Scrapper on the host HUD, car rack contents (fixture car has none), trader copy,
heal and F10 in game. Open: guest Settings crash (only the old 0.0.8 stack), crafting button gone, charging "Connected", guest in
driver seat after Sierra.

## 2026-11-02: friend session 2026-11-01 (0.8.7 ce717a3), owner was the guest

Logs: `local/playtest-20261102-175321` (host "Medici", 16:11-17:52), `local/playtest-20261102-185310` (owner = guest, only its
last life 18:30-18:52 = host 17:30-17:52, plus 3 crash markers). Merged first: Everelsu fork main 18e3f07 (fast-forward, 3
commits; native DLL rebuilt for msg.cpp/damage.cpp).

Observations
- Owner reports: held items vanish at junctions; host-summoned gateway invisible to the guest; blueprints sometimes reach the
  guest only after a rejoin; car radio muffled for the guest; one crash opening Settings.
- Guest `PT|health guest died` 0.5 s before "host says go" on both zone arrivals in the guest log (18:36:49, 18:51:59), each
  followed by a respawn next to the car. The 8 s grace counted from LoadMapPost; the guest waited 29 s and 52 s for the go.
- The guest's newest local crash (owner PC, Saved/Crashes, 18:29) is `ItemTileLayout:EmplaceSlot` on CL_Garage_V1, access
  violation 0x1000001bc; on the host just before: shredder output and `loot got S I:Stations.Install.Inventory.Expansion` 0 -> 9.
- The Settings crash marker (0.8.7, guest) has the same Blueprint stack as the 0.0.8 one (Settings press -> Graphics page
  constructed -> native). No native stack: the log zip did not carry CrashContext.runtime-xml.
- Host summoned the gateway itself (exits 16:51, 17:20; no `act gate`). Guest code only called Select Exit Portal Actor; the
  portal's Activate (ubergraph 5167: Portal_AnimStart, SetExitPortalActive(true), ambient AkComponent, map icon, collision)
  ran on the host only.
- Guest unlocks used UnlockNode(node, bSuppressEvents=true) for every change, so OnNodeUnlocked listeners (ProgressionManager,
  benches) never heard of mid-session unlocks. Nodes not loaded were skipped silently.
- `radio_car_distance_exterior` is set only in BP_CarPart_Internal_Radio when the radio switches on: 0 if PlayerCarState==1,
  else distance/10000. The guest's PlayerCarState stays 0 (seated by car.lua).
- Host error once: `g.vis.unlock visual.lua:545 ForceUnlockDoor` is a TrivialObject (not looked into).

Changes (each a guess from the logs, not reproduced)
- health.lua: grace restarts while transition.lua has a phase; death lines carry the reason.
- world.lua: guest runs Portal_AnimStart + SetExitPortalActive(true) + ambient sound for the host's gateway (not Activate:
  it enables the portal collision).
- progression.lua: unlocks after the first 5 s of a map use the game's events; LoadAsset fallback; count of nodes not found.
- radio.lua: guest sets the RTPC itself every 1 s (0 when attached to the car).
- ids.lua: applyLayout re-reads container/Layout per sliced step and stops when either is gone.
- Launcher.cs: collect copies CrashContext.runtime-xml beside each crash marker.

Checks: progsync 31/31 (`20261102-171347-progsync`, guest "1 nodes set, 0 not found" for the later unlock); radio 31/34
(`20261102-171742-radio`, the same 3 custom-file checks as 0.8.5/0.8.7; guest logged exterior 0.87 standing in the garage). Gateway, radio
muffle, false death and the storage crash have no scenario run; they need the live loop.

## 2026-11-02 (later): guest responsiveness pass

Owner: as the guest (80-100 ms ping) actions feel 1-2 s late. Their examples: car entry; scrapped resources spawn, vanish and come back;
no ARC energy at the garage; the research machine does not research; the host's hood opening not seen; the host's anchor
pull has no effects and the anchor lingers.

Observations (friend-session logs above)
- The transport is not the delay: net.lua dispatches every frame and sends at once. The delays come from the guest waiting
  for the host's result, the host noticing state by scans, and the guest discarding its own result.
- Car entry: guest `enter intent` -> `riding` 2.1-2.3 s every time; host `enter from` -> `seated` 1.9 s (its walk-in glide, run
  before the seat message). The driver's door path did no local glide on the guest.
- Scrap: guest `loot guest drop ... told the host` per resource; the sweep destroyed the guest's drop at once and the host's
  copy came back as an "A" after the host's scan.
- Host anchor pull: only the prop sweep's `tk=1` (seconds), which destroyed the guest's copy without effects.
- Research: zero `st buy` lines in the guest log: the game's screen never called PurchaseNode (blocked before our hook).
- ARC energy: guestact mirrors only the car's ARC screen charge; nothing for the garage's display.
- Hood: car.lua sends door open bits (EOpenableDoors 0-5) and physics poses of swinging door meshes; which index (if any) is
  the hood, and how it animates, is not known.

Changes
- car.lua: predictEnter (both doors): the guest glides at once and seats itself (PASSENGER offset) at the glide's end;
  g.car.seat confirms. No confirmation in 4 s -> detach, stand at the passenger door. Mutations nopredict, nopredictseat.
- loot.lua: the guest keeps its drop; "N" carries a key, the host registers its spawned copy and answers "K|id|key" instead of
  an "A". Mutation nodropadopt.
- visual.lua: the host hooks Long Grab Complete too and sends g.vis.anchortaken; the guest's copy runs PlayPrySound,
  AddAnchorPulledTag, AnchorTaken, removeAnchorGoo (guessed from the function names) and stays; tk=1 no longer destroys a taken
  copy. Mutation noanchorfx.

- loot.lua: a drop is reported only once it rests (velocity <= 10 uu/s): reported mid-air, the host's copy hung there and the
  guest froze its own on the "K" (dropfall guest_drop_on_host_ground failed until then).

Checks (headless, default root): anchordup 23/23, with noanchorfx 21/23 (only guest_anchor_gone_when_host_pulls fails);
carsync 39/39; carseat 29/29, carseat PT_VARIANT=driver 29/29 (guest moved 95 uu 1.01 s after the press, "seated by
prediction"), with nopredict 28/29 (walk-in 2.02 s after the press); dropfall 21/21, with nodropadopt 20/21 (only
guest_drop_kept_single). Not run: lootsync and the rest of the suite; the real 80-100 ms ping (no udp-lag run); the rollback path
(host refusing a seat); anchor sound and fade by ear.

Red doors (owner, same session): "some doors were not opening for me as a guest, specifically red doors in the expedition".
- Observed: host 17:41:07-10 five `guest used door BP_Door_Single5_160: pressed on the host, state=3` (3 = locked: the garage's rear
  door read 3 before the guest's Unlocker and 2 after); 16:46:30-31 three presses of `BP_Door_Sliding_Single_Science_Trailer_Ext_T1`,
  state=3. The guest's Unlocker uses did reach the host (`unlocked on the host`, 17:41:37 and 17:46:10).
- Derived: a door keypad (BP_ExternalDoorLock_Keypad, matRed/matGreen, DoorActor) and the hand-dryer lock are their own actors;
  visual.lua's ALLOW list had no BP_ExternalDoorLock_, so the guest had no copy to press. Guess: the "red doors" are these keypads.
- Change: ALLOW + "BP_ExternalDoorLock_"; the guest's copy hooks the lock's highlight events 0-3 and sends g.vis.keypad; the host presses
  its own lock (1 s dedupe, one press fires two events). shortcut: the guest's copy keeps its red light. Map-placed keypads (not
  copies) are not covered. Mutation nokeypad.
- Check: new scenario keypad (host spawns a keypad by the guest, the guest presses its copy by the interact action) 20/20
  (`20261102-180918-keypad`), with nokeypad host_keypad_pressed FAILS. Not proven: that a real zone keypad then opens its door for both (needs a zone with one, live loop).

Open: hood, garage ARC energy, research need the live loop (look at them on the guest with the console).

Anomalies (owner, same session): the saw (left-right) showed its red line but no blade; the "wiggling wreck" that spawns electric
coils did not fire with both players next to it. Probe session `20261102-182743-repl` (zone fixture, MCP), nothing changed in code.
- Saw = BP_Hazard_SawBlade (host log `anom3 woke BP_Hazard_SawBlade_C_...` 16:32, 17:08). Atlas: the blade (StaticMesh) is shown only by
  BP_HazardProperty_PlayerRange's OnPlayerInRange (SetVisibility true) and hidden on OutOfRange; movement is timelines + SyncToPhase. The
  range check is the local player's: a guest copy (tick off, world.lua) never shows its blade. Guess for the guest side; whether the host saw
  the blade is not known. A standalone or layout-spawned saw in the probe never built its spline (pts=0): needs a real zone saw.
- Logic Driver SMs in the probe zone (4 PhysicsGrabber, 6 Bollard) all NetworkTick/TransitionConfiguration 0 (the garage-door listen bug).
  A grabber 5.4 m from the host stayed "Patrol" 10 s with 0 and 10 s with 2: inconclusive (it may not have had a reason to act).
- Wreck = probably BP_Template_CivCar_Mimic + BP_Hazard_MimicTrigger_ShockPoles (atlas). Trigger: sphere (r 750) overlap turns tick on;
  each tick fires only if BP_CarManager PlayerCarState == 0 (the host on foot). Then it spawns BP_Hazard_Movement_Prong on valid ground.
  Probe: trigger spawned on the host next to the guest, host on foot 294 m away: it fired (ToSpawn 15 -> 0), the host had 0 prongs after
  (ground checks far from the host's player failed?), the guest had 13 prongs at 0,0,0 with Role 3 (spawned by the guest's own game,
  origin not found). With both players next to it in the session, the cause is unknown; a host in the car would block it (state 1).
- Next: a zone fixture saved next to a saw and a mimic wreck, then the live loop (both sides: blade visibility, SM config, prongs).


## 2026-11-03: friend session (0.8.8 38fbaa0), friend hosted, owner was the guest

Logs: `local/playtest-20261103-215129` (friend/host: run-01 20:50-21:24 ends in a crash, run-02 21:26-21:51; its saves are from
21:51) and `local/playtest-20261103-225113` (owner/guest: run-02 21:52-22:51). The host's log for 21:52-22:51 is not in either zip.
Owner reports: gateway still invisible to the guest; car radio still muffled for the guest; story stuck on "Return to Sierra" and
F9 story tasks did not help; guest freezes "while the mod syncs"; 5k LIM gathered, 3.1k in the garage. Friend: one crash; the
research machine showed a white screen the first time it was opened. Fixed per the owner: seat-on-door-press, scrapped loot flicker.

Gateway
- Observed: no `PT|world guest gateway ... shown` line in the guest's whole hour. Atlas: exit portals are spawned at runtime
  (BFL_RuntimeSpawnHelpers.DynamicSpawnActor, class BP_LevelTransition_ExitPortal), so the guest's replicated copies have other
  object names than the host's. world.lua matched the host's `gate` by name; guestact.lua's g.act.gate (guest summons) did the same.
- Change: common.portalKey/findPortal: the portal is named by its location and found as the nearest portal within 5 m. A portal
  not found logs `PT|world guest gateway at <pos>: no portal there` once.

Radio muffle
- Observed: the guest set radio_car_distance_exterior to 0 in the seat (`PT|radio guest exterior 0.00`, the 2026-11-02 fix) and
  it still sounded muffled. Atlas AC_CarAudio: OnPlayerStartEnterCar sets RTPC veh_int 1, PlayerInsideCar, state veh_int_ext-veh_int
  and UpdateClosedness; while PlayerInsideCar is false its tick runs UpdateDoorOcclusion (veh_door_closedness_exterior). The guest is
  seated by car.lua, so its copy of the car's audio stayed "outside, doors shut". Guess: that occlusion is the muffle.
- Change: carfeel.lua guestCabin: the guest calls AC_CarAudio.OnPlayerStartEnterCar(false) / OnPlayerStartExitCar(false) when its
  pawn's attach parent becomes / stops being the car (`PT|feel cabin audio inside=...`). Not heard yet: needs the live loop.

Story ("Return to Sierra")
- Observed (fixture `local/fixtures/pt11-q03` = the host's odsave1.sav, MCP 20261103-2306..2310): QD_Q03_Mission_A2 task ReturnSierram
  (BPMT_TagIsSet, route WB, WB.Missions.QD_Q03_Mission_A2.ReturnSierram.ReachSierramAgain). The tag WAS set; the mission state had
  bInitTasks=false and ActiveTime 0 (UseLuckHeap's mission ticked). QD_Q03_Objective IsDormant=true: GSS_MainQuestsDormancy on
  (states Fig_Mission_Chapter01/03/05/06, the DLC's chapters) while QO_Fig_Mission_Chapter01 is in CompletedObjectives and no Fig
  objective is active. A dormant objective's mission never ticks, so ForceCompleteTask (F9) did nothing either.
- Check: SetGlobalSwitch(GSS_MainQuestsDormancy, each state, DONTCARE) -> switch false, A2 initialised and completed at once.
- Unknown: why the chapter's state stayed on (the host's log for the chapter's end is missing; guest saw Fig Chapter01 stop 22:06:42).
- Change: rescue.lua: F9 > Story tasks shows "Wake the main story" when the switch is on, no QO_Fig objective is active and a main
  objective is dormant; it releases every state of the switch on the host. Checked through the guest console (`ptrescue tasks`,
  `ptrescue do 1`) on the fixture: host `PT|rescue host wakes the main story: dormancy switch now false`, A2 completed.

Guest freezes
- Observed: guest `PT|slow loot.lua:961` 109-244 ms every ~2 s from 21:53:17 to 21:54:07 (scanGuest 3890 ms in that minute), the
  90 s after the join when the guest purges its own lootables (4 classes in one tick). Steady play: scanGuest ~320 ms/min, no other
  Lua stalls over 100 ms except one `radio.lua:490 1002 ms` (22:20:34). Freezes outside the join minute are not explained by the log.
- Change: loot.lua purges one class per 500 ms tick (each still every 2 s).

Other
- Host crash 21:24 (run-01, CrashContext 0D48E295...): access violation in TaskGraphThreadNP 8 (a worker thread, not the game
  thread), shipping exe frames without symbols. One second before: two `act heal Attachments.HeadLightRight` from the guest. Unknown.
- ARC energy: guest `WB.PrevRun.Currency.AnchorJuice.Stable 2.10 -> 5.60` on return; garage showed 3.1. Guess: the gateway's cost
  (5.6 - 3.1 = 2.5); the ARC mirror (guestact.lua g.act.arc) writes on the guest only. Not checked.
- Research machine white screen (host, first open): nothing in the logs. Unknown.
- Guest crash markers in the owner's zip are old (0.8.5/0.8.7).
- Checks on these changes (headless pairs): guestact 32/32 (`20261103-231404-guestact`; guest intent and host pick by position
  `-47832,6942,-1548`, guest `gateway ... shown`; this fixture's portal has the same name on both sides, so the renamed-portal case
  is not covered); carfeel 38/38 (`20261103-231630-carfeel`, guest `PT|feel cabin audio inside=true`); lootsync 34/34
  (`20261103-231733-lootsync`); rescue 22/22 (`20261103-232142-rescue`). Radio muffle and gateway visuals not heard/seen: live loop.

Fork commit 2c7b1d3 (Everelsu, "Protocol 6 motion and heap integration", 49 files, native msg/transport/find): not merged. Review
(read only): a new-build guest is "active" only after loot+car+visual baselines (net.lua baselineComplete); the car part comes only
from g.car.s, which the host sends only with a car, so with no car every protected guest action is dropped for the session.
Also: loot.lua `known()` address reuse can wipe the new byName entry (duplicates); MULTIVOID-LICENSE.txt referenced but missing;
needs a DLL rebuild; its validation runs are on the contributor's machine only.

## 2026-11-04: live loop on the 2026-11-03 fixes (902f0ae), fixture pt11-q03, two rendered clients

Logs: `local/playtest-20261104-live1` (first session; the second one is in the test copies).
- Cabin radio (carfeel guestCabin): owner heard it right as the guest in the seat. Confirmed by hand.
- Wake the main story: the switch went off, but QD_Q03_Mission_A2 stayed the active mission with IsCompleted()=true (its one task
  done, ActiveTime 0.0187, never advanced): no new task, no waypoint. A live `AdvanceObjective(QD_Q03_Objective, nil)` started
  Mission B ("Locate stabilizer records"). Change: rescue.lua, for 10 s after a wake the host advances each active objective whose
  mission is complete (`PT|rescue host moves ... on from the woken ...`). Owner, second session: F9 wake -> task and green marker
  appeared by themselves; still on B afterwards (no double advance).
- Oppy is silent after the wake. Atlas: BP_QuestDirector MissionBind_QD_Q03_Mission_A2_Finished waits for the player in the car
  (OnPlayerStartEnterCar), DelayBetweenMissions, then dialogue. Whether it ran: unknown (Lua probes on it and on AdvanceObjective
  printed nothing, not even for the rescue's own call, so the probe itself is suspect). Open.
- Extra green waypoint on the guest: BP_ScriptKit_GobblerMap_GenericObjective_C actors with Enabled=false destroy themselves at
  BeginPlay on the host; the guest kept 5 of them, one visible (QD_Q03_Mission_A.Broadcast). Change: world.lua lists them in "keep";
  the guest removes a marker the host has not listed in 10 states in a row. Seen: guest removed all 5 15 s after the join.
- Map turned 90 degrees on the guest: BP_ToDManager RandomizeNorth picks a north per side (host 270, guest 0); BP_GobblerMapBounds
  UpdateRotation turns the map by it. Change: world.lua sends `north`; the guest calls SetTrueNorth and the bounds' Capture Configure
  (Recapture) to render the map again. Owner: guest map wrong for 5-10 s after the join, then matches the host.
- Intro movies: install.ps1 moves Content\Movies\Intro_Segment_* (MoviePlayerSettings.StartupMovies) into
  Movies\PacificTogether-skipped, uninstall moves them back. Test copy client1 only: owner saw the left window start faster. Both logs
  still show 15 s from movie player start to the main menu. The install.ps1 code itself has not run yet (I ran the same lines by hand).
- Guest ARC map icons (owner, same session): the guest showed every junction open and doubled building icons. Observed: each
  junction has Icon_Entrance/Exit/Closed/DeadEndWarn at one spot and the host shows one (guest 15 visible, host 5); the host's
  building icons are mostly runtime components (MapIconComponent_<n>) on its own clump buildings, which the guest does not have;
  the gateway's PulseIcon/Range icons stay off on the guest's portal copies. Change: mapmark.lua, the host sends every visible
  icon (base + each layer: texture, materials, place, size, unit, zorder, color, rotation, fog), skipping players/car/pin and
  /Engine/Transient orphans (at 0,0, not drawn on the host); the guest hides all of its own and draws the list on components
  of its own on BP_GobblerMapBounds (`PT|mapmark guest map draws N host icons`). world.lua: the guest removes its own
  GenericObjective markers (a live one re-shows its icon every tick). Owner: "fully identical now".
  Crash on the way: host access violation in ActorComponent:GetOwner on map icons (some owners freed); the code no longer calls it.
  Layered icons: base and layer both draw (a junction: grey square + black glyph at 0.67); a copy without layers drew a house
  black on black until the layers were sent as their own copies.
- Guest radio in the seat (owner, same session): volume and track changes already reached the host (`PT|radio intent`,
  `skip 1@cr sent`), but the guest had no outline and no radio panel, and X (the radio's next track) also exited the car.
  Cause: car.lua sets ExtraData.IsInside=false on the seated guest's dashboard highlights (ignition, shifter) so a character
  passes the highlight filter; the radio was left out (fork commit cfc2b6b, no reason given). A live IsInside=false on the radio
  showed both. Change: the radio is included; the X exit key and the guestui seat hint are removed at the owner's request
  (the passenger door is the exit). Owner: works end to end. guestui scenario updated (hint checks dropped), not run.
- Research machine (fixture own1, garage): white screen on the first open on both sides. Cause: BP_Garage_InventingBench
  ActivateScreen calls Widget.SetWidget and at once ScreenMID.SetTextureParameterValue(SlateUI, Widget.GetRenderTarget()), but the
  widget component makes its render target only when it first draws: SlateUI stayed none (seen live; setting it by hand showed the
  screen). Change: stations.lua, after ActivateScreen the render target is put on ScreenMID once it exists (owner: a short flash).
- Guest research energy 0 0 0: amounts live in BaseInventoryManager.CurrencyTable (archetype -> hundredths; host 260/740/960 +
  MechXP 116850), the guest's was empty. Change: stations.lua g.st.cur, host table down on change / every 10 s, guest writes it
  (TMap Add, no CurrencyAdjust) and calls the bench's UpdateAnchorCounts (the energy board). Owner: guest researched a blueprint.
- Upgrade kit from a guest's research: host bench OnNodePurchased turns its highlight off and spawns the kit; the guest picked the
  kit up through the loot sync (host's actor destroyed, highlight back), but loot items travel as archetype + state only (ids.lua
  shortcut "upgrades do not travel"), so the guest's kit had no IP_ItemUpgrade UpgradeNode: ToolManifestation.GetUpgrade invalid,
  no install spots shown. The guest's drop spawned a kit on the host that lacks it too. Open: carry the node in the spec and
  rebuild kits with BFL_ItemPropertyUtilityFns.CreateUpgradeItem(node); reading the node from a real kit not tried yet.
  Kit follow-up (same session): a host kit's node is readable from Lua by calling GetUpgrade on the
  BP_BaseGarageUpgrade_ToolManifestation_C CDO with CDO.Instance set to the item instance for that call (then cleared): Upgrade
  Asset UP_Garage_InventoryExpansion_Install_4th_C, UpgradeNode /Game/Gameplay/Inventory/Items/RecipeResearchGraph.RecipeResearchGraph
  :GenericGraphUpgradeNode_27 (an asset path, same on both sides). InventoryBlueprintLibrary.GetItemProperties from Lua returns
  false (wildcard out); GetDataBlockDump shows IP_ItemUpgrade as {} even on a working kit. A guest probe
  BFL_ItemPropertyUtilityFns.CreateUpgradeItem(node, 0, pc, out) crashed the guest (access violation 0x10; the crash marker's last
  calls do not show it, so the cause is unproven). Next: try that build in a headless pair, not with the owner waiting.
- Code review of 38fbaa0..HEAD (high, unverified findings), fixed: F8/End seated also exits (door is the only other exit);
  the post-wake advance only touches objectives that were dormant at the wake and only once, and the wake re-checks
  storyAsleep (stale menu row); the guest shows a gateway once per position per map; cabin audio retries 10 s after an error
  instead of off for the run; a currency the host no longer lists is 0 on the guest; map icons: default materials not sent,
  sizes/colors rounded, missing assets cached, the guest's own icons come back and the copies go when the session ends;
  README controls. Not changed: the icon list's size beyond that (measure in a session first).
