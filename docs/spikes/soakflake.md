# soakflake: soak flakes of 2026-11-20 (lane, base 81c99fa)

## Observations
- Soak 20261120-142816: playpath failed twice (`guest_menu_open_after_interact` client + `p2_host_container_lost_item` host),
  lootsync once (`guest_lootables_match_host`, guest 39 vs host 40 for 90 s).
- playpath failure signature (every failing run, 20261120-151604, 163029, 175213, 180211, 180805, 181158, 184xxx):
  interact tool report `approach: teleported 2 time(s)` and `fired: InteractReleased(BP_Spawn_GasBarrel_PlacedOnly...)` before the
  crate's Pressed/Released; crate target change only `RolledOnOpenItems` (no `DataBlock_WasOpened`). Passing: 1 teleport, no barrel.
  The first standing spot highlights a gas barrel beside the crate, the tool moves on, and the crate is pressed but never opens.
- Rate on this lane before the final fix: 8 of 22 playpath runs (soak: about 1 in 4 over all stored results, 41 of ~170).
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
- playpath is the bot, not the mod's container UI: at that spot the interact tool's trace picks a gas barrel / a trailer door beside
  the crate; the crate gets its loot rolled but never opens. A stale inventory widget (car trunk) then made the old check
  misleading and the grab took from the trunk. A direct press-release of the crate's highlight does NOT open it either (the crate
  needs its hold of ~1 s of game time: tried 20261120-191114, 3 failed retries); press, wait 3 s, release does.
- Fix in the scenario: the check requires the crate's own container in an inventory widget plus `IsPlayerMenuOpen`; 4 s without it,
  the retry presses the crate's `Highlight` (InteractPressed), 3 s later releases it, up to 3 times. Result: playpath 8/8 passed on
  the final scenario (20261120-1917xx .. 1933xx), the retry fired in 1 of 8 (the two-teleport signature appeared once, fixed by 1 retry).
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
