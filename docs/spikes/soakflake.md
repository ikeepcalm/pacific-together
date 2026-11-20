# soakflake: soak flakes of 2026-11-20 (lane, base 81c99fa)

## Observations
- Soak 20261120-142816: playpath failed twice (`guest_menu_open_after_interact` client + `p2_host_container_lost_item` host),
  lootsync once (`guest_lootables_match_host`, guest 39 vs host 40 for 90 s).
- playpath failure signature (every failing run, 20261120-151604, 163029, 175213, 180211, 180805, 181158, 184xxx):
  interact tool report `approach: teleported 2 time(s)` and `fired: InteractReleased(BP_Spawn_GasBarrel_PlacedOnly...)` before the
  crate's Pressed/Released; crate target change only `RolledOnOpenItems` (no `DataBlock_WasOpened`). Passing: 1 teleport, no barrel.
  The first standing spot highlights a gas barrel beside the crate, the tool moves on, and the crate is pressed but never opens.
- Rate on this lane: 5 of 14 playpath runs (soak: about 1 in 4 over all stored results, 41 of ~170).
- In the failing runs `IsPlayerMenuOpen` is false for 90 s, but an inventory widget with a TransferContainer exists from second 1.
  That widget is stale: the next steps grab from the **car trunk** (`PT|loot send S I:Inventory_Trunk`, no second `send S L1`),
  and the host's crate keeps its 4 items (`p2_host_container_lost_item`). Retrying the interact from 4 other sides at 80 uu in one
  run did not open the crate either (the retry did not get logged results then).
- lootsync failing run 20261120-160948: host always lists 40 lootables (29 of 29 runs); the guest log has `purged 54 own
  actors, 364 host actors (claimed 6, spawned 318)` where the other runs show 378/331 at the F line. 14 entities of the host's
  378 had no entry on the guest when F was handled, and no `loot could not make` line. The missing container's class and position
  were not logged.
- visual.lua error in playpath 20261120-170227 (client): `PT|error in visual.lua:930 ... visual.lua:376: attempt to call a
  TrivialObject value (method 'K2_DestroyActor')`, in `dropAll` (runs when the guest loads a new map/zone or the host resets the
  visual list): a copy the game already freed reads as live but has no methods. Player impact: the pcall of the tick caught it
  (it is an error log, not a crash), but the rest of dropAll (clearing `mine`, `todo`, `specs`) did not run, so the guest could keep
  stale entries across the load. Rare (1 of 25 runs here).

## Derived
- playpath: the bot's interact step is flaky, not the mod's container UI: a press that never opens the crate leaves a stale widget
  that fooled `IsPlayerMenuOpen`/widget based detection. Whether the barrel highlight really blocks the crate in the game is
  unproven (Guess).
- Fix in the scenario: the menu check now requires a widget whose TransferContainer is the crate's own container and
  `IsPlayerMenuOpen`; if it is not up 4 s after the interact the guest is placed 80 uu from the crate on another side (180, 90,
  -90, 0 deg) and the interact repeated (approach=false), up to 4 times.
- visual.lua dropAll: the destroy is in a pcall now.

## Guesses
- playpath: the barrel's highlight keeps the press (Released arrives for the barrel after the crate's) so the crate's press does not
  complete; a second spot fixes it.
- lootsync: 14 of 378 A lines yielded no entity at F (replica.adopt refused because a D arrived first, or a silent early return in
  onAdd). One of them was a lootable.

## Unknowns
- Which container was missing in lootsync 160948; no reproduction in 21 lootsync runs here. lootsync.lua now logs `hostonly <row>` /
  `guestonly <row>` in the `PT|info lootable match` line, so the next occurrence names class and position. No mod change for it
  (a fix without the cause is a guess). Next step if it recurs: log, in loot.lua handle("F"), the ids of the host's list that
  have no `ents` entry.
