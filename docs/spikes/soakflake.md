# soakflake: soak flakes of 2026-11-20 (lane, base 81c99fa)

## Observations
- Soak 20261120-142816: playpath failed twice (`guest_menu_open_after_interact` client + `p2_host_container_lost_item` host),
  lootsync once (`guest_lootables_match_host`, guest 39 vs host 40 for 90 s).
- playpath failing runs (20261120-151604, 163029): the interact tool report says `approach: teleported 2 time(s)` and `fired:
  InteractReleased(BP_Spawn_GasBarrel...)` before the crate's Pressed/Released; `after: menu_open=false`, crate target change
  only `RolledOnOpenItems` (no `DataBlock_WasOpened`). Passing runs: 1 teleport, Pressed/Released on the crate only, menu_open=true.
  So the first standing spot did not highlight the crate (a gas barrel next to it did), the tool moved on, and the press that
  did reach the crate did not open the menu within the 10 s check. The inventory menu did exist ~10 s later (the following
  transfer step passed), i.e. the guest's container UI was not broken, only late or the press ineffective.
- Across all stored results: guest_menu_open_after_interact FAIL 41 of ~170 runs (about 1 in 4), always the same signature.
- New runs on this lane (soak-time load absent, one pair): lootsync 16/16 pass; playpath 9 runs, 8 clean, 1 failed on another flake
  (below); the new interact retry never fired (`PT|info act2 retry` absent) and the original menu failure did not recur.
- lootsync failing run 20261120-160948: host full list 378 entities, guest `purged ... 364 host actors (claimed 6, spawned 318)`
  (other runs: 378/331 at the same point); no `could not make` line. The missing container's class/position was not logged.
- Separate flake seen in playpath 20261120-170227 (client): `PT|error in visual.lua:930 ... visual.lua:376: attempt to call a
  TrivialObject value (method 'K2_DestroyActor')` in `dropAll` (a copy the game already freed reads as live).

## Derived
- playpath failure is the bot (interact tool/approach), not the mod: the menu code path works when the press reaches the crate.
- Fix: playpath now waits up to 40 s for the menu and presses the interact again once after 8 s without a menu.
- visual.lua dropAll: the destroy is in a pcall now (1 line).

## Guesses
- lootsync: the host's test `lootables()` counts a lootable that the host scan did not register (scan needs `ids.settled`
  and `alive(InventoryContainer)`), or the guest lost one copy after the list; the guest log shows neither.

## Unknowns
- Which container was missing; the failure did not reproduce in 16 runs here (it was 1 of 46 on the soak, once on 2026-11-17).
  lootsync.lua now logs `hostonly <row>` / `guestonly <row>` in the `PT|info lootable match` line, so the next occurrence names
  the class and position. No mod change was made for it: a fix without the cause would be a guess.
