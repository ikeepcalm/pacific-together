# W6 anomalies: every wiki anomaly, host vs guest (2026-11-18)

Requirement W6/W2 (docs/PLAN.md): anomalies run on the host and look and act the same for the guest; no guest-side
duplicates; guest actions reach the host as intents. One row per entry on
[pacificdrive.wiki/view/Anomalies](https://pacificdrive.wiki/view/Anomalies) (revision oldid=6893, 63 entries).

## Sources and name mapping

- Wiki list: read 2026-11-18. The cross-check sources were not readable: the Fandom page returned HTTP 402 and the Steam guide
  3168433093 returned HTTP 429. So the cross-check is the **game's own logbook**. Each `LOG_*` asset's title is the in-game
  display name, extracted with `tools/pak/pak.py` from the test copy's paks into `local/research-extract/laneE`,
  `local/research-extract/w6` (LOG_Boon_*, LOG_GEV_*, LOG_Ambience_*) and `local/research-extract/w6fig` (the DLC plugin pak
  `PDFeature_Fig`, its titles resolved through `StringTables/ST_FIG`).
- Every wiki name matched a logbook title except two. Pothole and Pufferfish were matched from their wiki pages: Pothole is
  "floating rocks in the middle of roads", the road-obstruction prefab `PFX_Obstruct_RockFloating_01` (logbook
  `LOG_RoadObstruct_RockFloating_01`). Pufferfish "launches away on a plume, leaves a Glittering Boulder, drops a Burr" is
  `BP_Boon_LootCreature` (the "Chubby Bunny" folder). **The mod's earlier "bunny" code and scenarios (anomalies3, anomwake)
  are the Pufferfish. W6's "Bunnies" are the Leeches.**
- Correction: M5-anomalies2.md and PT1-anom3.md say Abductor, Pickpocket and Can Opener are "not in this build". That is
  wrong. They were looked up by display name. The logbook maps them: Abductor = `BP_Hazard_PhysicsGrabber`,
  Pickpocket = `BP_Hazard_PartStealer`, Can Opener = `BP_Hazard_SawBlade`.
- Logbook entries the wiki does not list (appendix, not rows): Surge Tower (`Tesla_Overloaded`), Warren (`LeechTree_Base`),
  Citric Swarm / Voltaic Ghost / Blasting Bishop (`Swarmers`), Forward-Backward and Locked Tight (`MalfunctionVolume_*`),
  Lightning Squall (`GEV_HeavyLightning`), Hot Dust Squall (`GEV_RadSpotSpawn`). The DLC also has Harvestman Hive and
  Glowgrabber Grove (`AnomalyConverter_*`). Both logbook files `LOG_Hazard_BouncePad` and `LOG_Hazard_NudgePad` are titled
  "Shaker".

## How the mod handles anomalies (shared mechanism)

- world.lua replicates every `BP_Base_Hazard` actor from the host (`common.replicateActor`). The guest destroys hazards it
  simulated itself, turns actor tick off on the replicated copies and smooths their positions. That covers W2 and the look.
- anomalies.lua: a hazard's damage message on the guest's pawn (on the host) is sent to the guest, and the guest applies it
  to itself. Tourist creep respects the guest's camera (W7).
- anomalies2.lua: leech leap and physics-grabber pull on a guest. anomalies3.lua: hazards wake near a guest, Pufferfish
  push, Spark Tower effects, Pickpocket taking from a guest.
- Status values: **synced** (passing check + failing mutation), **lane** (being fixed today), **out of scope** (reason).

## Table

Columns: host behaviour = what the game does (host). Guest sees / guest acts = state on main e06653c before this run.

TABLE_PENDING

## Results

RESULTS_PENDING
