# Pacific Together: plan

Updated 2026-10-24 for **0.0.7 / protocol 3**. Requirement and decision IDs are retained for code and research references.
P0 = required for 1.0; P1 = later scope; P2 = optional. Priority is not completion status.
Current player-facing behavior: [../README.md](../README.md). Results and remaining evidence gaps: [../NOTES.md](../NOTES.md).

## 1. Product decisions (made by the owner)

| # | Decision |
|---|---|
| D1 | **2-4 players**: host + up to three guests (owner 2026-11-14; was 2). Guests talk only to the host, which relays each guest's own state (`net.share`); no guest-to-guest links. Seats: driver, passenger, rear seat behind the driver (the ARC body keeps the other rear seat); a fourth player rides outside. |
| D2 | **Host's save only.** The guest plays in the host's world. Nothing the mod does may write to the guest's own saves. |
| D3 | **Steam invite / join** is the target way to connect. Direct IP stays for tests and VPN users. |
| D4 | **v1.0 = full run loop**: garage -> junctions -> gateway -> garage together, with shared car state and loot. Story plays as far as the host's save allows. |
| D5 | Name: **Pacific Together**. Mod folder `PacificTogether`. |
| D6 | **Guest death**: respawn at the car, backpack contents dropped as a recoverable bag. Host death or a wrecked car = run failure for both, with the host's failure penalty applied to both backpacks. |
| D7 | **Guest loot persists** in a side file per host save slot and guest SteamID; direct-IP joins fall back to a login name that can change between launches. |
| D8 | **DLC target**: only the host needs Whispers in the Woods; mixed-ownership compatibility is not verified. |
| D9 | Team: ikeepcalm (owner) and Djecka. Two Steam accounts, both with the game and the DLC. |
| D10 | Public repo https://github.com/ikeepcalm/pacific-together, MIT license. |
| D11 | **Only the host drives in v1.0.** Guest driving is v1.1 (C8). |
| D12 | **Passenger seat** for the guest; the ARC screen unit sits between the front seats and its body (anchor slot) on the rear seat behind the guest (C7). |
| D13 | **Shared ARC actions**: either player can summon a gateway and use ARC energy; route planning stays host-only (D22). |
| D14 | **Steam sessions** open a friends-only lobby while a save is loaded, unless a direct-IP join is configured (S1, S2). |
| D15 | **Host crash or disconnect**: the guest's backpack rolls back to the host's last save, same as the host's own progress. |
| D16 | **Crash reports**: the mod turns off the game's crash upload (Sentry, CrashReportClient) while installed and writes its own crash log for our GitHub issues (Q9). |
| D17 | **Finding each other**: a Steam name tag over the other player and a marker for them on the ARC map (P7, P8). |
| D18 | **No outside testers before 1.0**: only ikeepcalm and Djecka. GitHub releases stay draft (collaborators only). |
| D19 | **Tourists freeze if any player looks at them**; implemented after the original priority changes (W7, D24). |
| D20 | **No co-op difficulty scaling**: the host's difficulty preset rules; the mod changes no balance values. |
| D21 | **Guest can use the garage stations** (Fabrication, Tinker, Detailing) in v1.0, spending the host's shared resources (G2). |
| D22 | **ARC scope for the guest in v1.0: gateway summon and energy use only.** Route planning stays host-only until v1.1 (it runs through native `UBaseRouteState`; lane E research, 2026-10-20). Narrows D13 / W11. |
| D23 | **Prove the crash-upload block (D16/Q9) before 1.0** with one deliberate test-copy crash while a Windows Firewall rule blocks the test copy's CrashReportClient outbound (owner approved; needs a UAC prompt). Until then test copies have no CrashReportClient.exe at all (`setup-test.ps1` removes it). |
| D25 | **Passenger controls** (owner 2026-10-29): the seated guest can turn the ignition key and move the shifter between P and D (P holds the parking brake); the host applies both. Steering, throttle and route planning stay with the host (D11). |
| D24 | Earlier scope deferrals no longer describe delivery: supported garage stations, ARC map markers and Tourist observation are implemented. Guest driving and route planning remain later scope. |

## 2. Fixed constraints

- One game build: Steam buildid 21896301 (v1.15.0, last patch 23 Feb 2026), exe SHA-256 in `CLAUDE.md`. Steam only;
  Epic / Xbox / Game Pass builds are out of scope.
- Both players run the same game build and the same mod version. The mod checks game/mod/protocol versions on join and refuses mismatches. DLC reporting and mixed ownership remain open (W10).
- No game files or extracted assets ship or get committed. The release is our code plus a pinned UE4SS.
- Keep the mod client-side without separate online services; official game support is outside this project.

## 3. Current architecture

The host runs the authoritative game. UE 4.27 replication carries characters and actor movement; Lua modules send
intents and state for gameplay systems that have no native replication.

| Layer | Implementation |
|---|---|
| Hook layer | Pinned UE4SS, Lua gameplay modules, one native C++ mod |
| Game-state channel | `net.lua` + `msg.cpp`: guest `ServerExecRPC`, host `ClientMessage`; reliable messages on the game connection |
| Flow control | Protocol 3 acknowledges host traffic, caps in-flight bunches and delays bulky state until the guest character is ready |
| Transport | Direct UDP or in-process socket tunnel over the game's Steam Networking Messages, appid 1458140 |
| Joining | Friends-only lobby, rich presence/invite callbacks, or direct IP |
| Travel | Native keep-listen patch plus guest rejoin on non-seamless map changes |
| Persistence | Host save plus guest-backpack side files; guest save writers blocked |

Steam traffic between two real accounts was verified October 23. That does not prove all invite, disconnect or DLC paths.

## 4. Requirements and priorities

The rows below define scope; the delivery summary follows them.

### Session

| Id | Requirement | P |
|---|---|---|
| S1 | Loading any save opens a friends-only session automatically (D14), in the garage or mid-run | P0 |
| S2 | Guest joins via Steam invite/friends list; names and backpack identity come from Steam | P0 |
| S3 | Guest joins via direct IP (tests, VPN) | P0 |
| S4 | Handshake checks game/mod/protocol versions; DLC ownership reporting remains to be added | P0 |
| S5 | Guest can leave and rejoin at any time, also mid-run and while the car is moving; host never crashes from it | P0 |
| S6 | The session survives every map change the game makes (garage <-> junctions <-> garage, run failure, quit to menu) without a second map load | P0 |
| S7 | Guest's own saves and settings are never written while in a session (the game's client-side autosave must be blocked) | P0 |
| S8 | In-game menu entries (session status, kick, close the session) | P1 |
| S9 | 3-4 players | P2 |

### Players

| Id | Requirement | P |
|---|---|---|
| P1 | Each player has their own character, sees the other move and animate (walk, crouch, carry, tool use) | P0 |
| P2 | Guest uses the game's own interaction (doors, containers, pickups, anchors, tools) with host authority | P0 |
| P3 | Guest has a working backpack and quick slots | P0 |
| P4 | Damage, radiation and death for the guest (D6) | P0 |
| P5 | Guest backpack persists between sessions, stored next to the host's save slot per guest SteamID, saved whenever the host saves and when the guest leaves; a new guest starts empty (D7). Must not change the game's own save format | P0 |
| P6 | Voice/text chat | Won't (Steam has it) |
| P7 | Steam name tag over the other player, fading with distance (D17) | P0 |
| P8 | The other player shown on the ARC map and as a HUD marker with distance past 30 m (D17; built in `mapmark.lua`, scenario `mapmark`, rendered proof tracked in the experiment report) | P1 |

### Car

| Id | Requirement | P |
|---|---|---|
| C1 | Host drives; guest rides as passenger; both enter and exit through the game's own door interaction | P0 |
| C2 | Car moves smoothly on the guest's screen (interpolation), also at 100 ms ping | P0 |
| C3 | Visible car state matches: doors, trunk, lights, wipers, ignition, gear, handbrake, horn | P0 |
| C4 | Car health, part damage and status effects, fuel, battery, tyres: one truth on the host, shown on the guest's dashboard | P0 |
| C5 | Guest can repair, refuel and swap parts on the car during a run (intents) | P0 |
| C6 | Trunk and car storage shared | P0 |
| C7 | Guest sits in the passenger seat; the ARC device is moved so both can reach it (D12, spike X8) | P0 |
| C8 | Either player can drive (swap driver) | P1 |
| C9 | Car sounds and radio on the guest's side | P1 |
| C10 | Rear seats for players 3-4 | P2 |

### World and run

| Id | Requirement | P |
|---|---|---|
| W1 | Loot is taken once: containers, pickups, scrap from wrecks, siphoned fuel, anchors | P0 |
| W2 | No client-side duplicates of anything the host spawns (cars, loot, props, anomalies) | P0 |
| W3 | Same junction for both: route choice, conditions, weather, radiation | P0 |
| W4 | Instability, storm walls, gateway summon and the exit warp happen for both at the same time | P0 |
| W5 | Run failure (emergency protocol) returns both players to the garage with the host's failure penalty | P0 |
| W6 | Anomalies run on the host and look and act the same for the guest; the run-shaping ones first: Abductor, Bunnies, Pickpocket, Tourists, Spark Tower, Can Opener | P0 |
| W7 | Tourists count as observed if either player looks at them (implemented) | P1 |
| W8 | Remaining anomalies and Whispers in the Woods content | P1 |
| W9 | Expeditions mode | P1 |
| W11 | Either player can summon the gateway and use ARC energy (D13, D22); guest route planning is P1 | P0 |
| W10 | A guest without the DLC can play the base-game zones with a DLC-owning host. Whether DLC content is installed for non-owners is unknown; until checked, the host is warned before travelling into DLC content | P1 |

### Garage, story, progression

| Id | Requirement | P |
|---|---|---|
| G1 | Guest can walk the garage and hand items to the host or the locker | P0 |
| G2 | Guest uses the garage stations (Part Shredder, research/blueprints, fabrication, garage upgrades, Tinker, Detailing) with the host performing each action on the shared resources (D21; owner 2026-10-22: in v1.0) | P0 |
| G3 | Story missions, radio transmissions, cutscenes play on the host; guest is a bystander and nothing breaks | P0 |
| G4 | Story audio and cutscenes for the guest | P1 |
| G5 | Co-op disables the Chrono Dilator. Only host Esc pauses both games; inventories/map/logbook do not pause the shared world | P0 |
| G6 | Saving, Suspend and manual saves: host only | P0 |

### Quality, install, ops

| Id | Requirement | P |
|---|---|---|
| Q1 | Every P0 feature has an automated two-instance test scenario that passes, plus a mutation check showing the test can fail | P0 |
| Q2 | Core scenarios pass at 150 ms lag / 2% loss through tunnel emulation (`-Tunnel "udp lag=150 loss=2"`) | P0 |
| Q3 | 2-hour soak (host + guest bots doing runs) without crash or desync | P0 |
| Q4 | One human playtest of a full run before each minor release (the owner and a friend) | P0 |
| Q5 | Preview zip with launcher/installer and pinned UE4SS; uninstall removes the entire UE4SS folder | P0 |
| Q6 | The mod logs to its own file; a "copy logs" step for bug reports | P0 |
| Q7 | The mod is inert unless a session is active (single-player stays vanilla with the mod installed) | P0 |
| Q8 | Nexus Mods release | P2 |
| Q9 | Game crash upload (Sentry, CrashReportClient) off while the mod is installed; the mod writes its own crash log (D16) | P0 |

### Won't do

Dedicated servers, cross-platform, other game builds, anti-cheat or online services, shipping game assets,
split screen, achievements sync.

## 5. Delivery and remaining work

| Area | Current state |
|---|---|
| M0-M2: foundations/session | Build, isolated copies, harness, join/rejoin, travel, mismatch rejection, save guards and crash marker implemented |
| M3: car | Passenger, interpolation, resources, repairs, parts, storage and audio implemented; driver-door entry remains the guest path |
| M4: loot/players | Shared loot, backpack persistence, death crate, health/radiation and survivor body implemented; guest anchors can duplicate |
| M5: run/world | Travel/failure, storm, gateways, progression, story audio, props and many hazards implemented; tutorials and remaining content need work |
| M6: Steam | Lobby, tunnel and running-game join implemented; two-account traffic verified; cold-start/recovery paths need validation |
| M7: hardening | In progress: human full runs, current lag/loss coverage, soak, crash proof, public-build hygiene |

Implemented does not mean all acceptance criteria passed. In particular, Detailing/quirk hints remain host-only,
cutscene coverage is incomplete, and DLC/Expeditions are not established. The milestone names are subsystem labels;
the original 0.1-0.5 schedule and duration estimates are retired.

Next work: [TASKS.md](TASKS.md). Release evidence: [RELEASING.md](RELEASING.md). Gameplay changes need focused scenario
results and mutations; collaboration follows [LANES.md](LANES.md), testing follows [TESTING.md](TESTING.md).
