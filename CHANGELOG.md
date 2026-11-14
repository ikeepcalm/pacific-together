# Changelog

What changed in Pacific Together, in plain words. Newest first. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Builds before 1.0 are previews for the developers and friends.

## [0.9.3.1] - 2026-11-14

Preview for 3-4 player testing. Network protocol **8**: everyone needs 0.9.3.1; a 0.9.3 player cannot join.

### Added

- 3-4 players: the Steam lobby takes a host and up to three guests. Every guest sees every other player, their held tool,
  their health under the name tag and their map marker (the host passes each guest's own state on to the others). Heal
  (H) patches up the player you look at. The third player rides on the rear seat behind the driver (next to the ARC body);
  a fourth stays outside and gets "The car is full". The host's loading screen waits for every guest. Feed lines name the
  player who did it.

### Changed

- The mod's text matches the game's HUD: the same cream as the health box and key prompts, no teal or green, a lighter shadow.
  Name tags too. The heal hint is a key box like the game's own prompts ("H" in an outlined box, then "Patch up <name>").
- The "Pacific Together <version>" label only shows in the main menu, for 10 s after a load and with the F9 menu open; the
  session status line stays.
- A guest who joins later sees the other players' map markers at once.

### Fixed

- The loading screen's "WAITING FOR HOST..." ran off the right edge of the screen; the box now grows to the left.
- Loot with more than one guest: a dropped item could be taken over by the wrong guest, a guest joining while another got
  the full item list only got its tail, and loot stopped flowing to the others when the first guest left.

## [0.9.3] - 2026-11-12

Convenience build for the evening session. Network protocol **7**, as in 0.9.2. Both players need 0.9.3; a different
mod version refuses the join.

### Added

- Guest driving, guest-side (experimental, **off by default**): the guest turns it on with F9, then 7. When the guest
  sits at the wheel in a zone, the guest's own game then runs the car's physics, so the car answers the keys at once with
  no ping delay, and the host's car follows. Leaving the wheel, the host taking it, or a dropped connection hands the car
  back to the host. In the garage the host still runs the car. **While it is on, the host must not sit in the passenger
  seat: the car gets launched** (not fixed yet). Crash damage and anomaly pushes do not reach the car while the guest drives
  this way. Doors open and shut normally (an early build tore them off).
- Own map marker for each player: both of you can place a waypoint and see both. Host blue, guest green, on the map pins
  and the partner-position icons.
- Heal hint: "[H] Patch up <name>" under the crosshair, only while you look at your partner within reach and the heal is ready.
- FPS in the log: `PT|perf fps` once a minute with the number of players, to track slowdowns while hosting.

### Changed

- Middle-click ping: the game's own objective marker (stays on screen at the edge, name, item and distance) and a tall
  beam of light at the spot, blue for the host's ping and green for the guest's.

### Fixed

- Breakables the host's car hits now break for the guest at once: signs, barrels, cones, fences, barricades, benches and
  floating rocks (they used to break 5-11 s late without flying). Trees and shrubs fall over on the guest instead of vanishing.

## [0.9.2] - 2026-11-11

Guest driving test build. Network protocol **7**, as in 0.9.1. Both players should use 0.9.2.

### Added

- Guest driving: whoever sits at the wheel drives. The guest gets in by the driver's door (when the host is not driving)
  and drives with W/S/A/D, Space for the handbrake; E on the key and the shifter as before. The host can ride as passenger
  with E on the passenger door, and E on that door again (or E at nothing) gets out. If the host gets in by the driver's
  door, they take the wheel and the guest moves to the passenger seat. The host's game still runs the car, so the guest
  driver feels their ping. Keyboard only for now.

- A seated guest can use the headlights, wipers and horn with their usual keys.
- A second download without the launcher, for Nexus Mods: install it with `install.cmd`. Antivirus scanners on
  VirusTotal flagged the launcher as `MSILHeracles` (10 of 61, a heuristic guess); the mod without it scans clean.
- ARC Doc (the Doctor ARC's car ability) now heals a guest sitting in the car too, at the ability's own rate (10 HP/s),
  and the car battery pays the ability's own price for it (0.4 battery per HP the guest gains).

### Fixed

- Guest driving: the car now speeds up, steers smoothly and reverses on S as when the host drives (the host's own idle
  controls cancelled the guest's throttle every frame, and the steering skipped the game's smoothing). The steering wheel
  turns for the guest, keys react sooner, and the driver's door shuts behind a guest who gets in by it.
- The guest's headlights and dashboard no longer flicker as if the car could not start: they follow the host's car.
- A sealed car now shields a seated guest from radiation as it does the host (the game only counted the host as inside).
- The guest now sees Salamander nest eggs and the other grab clusters the zone spawns (they existed on the host only).
  Each player can harvest a cluster once for now.
- Less stutter on the host near many wrecks (wreck paint and trunk state were re-read every half second), and on the
  guest when radiation zones update.
- Buildings such as the science trailers look the same for the guest as for the host: the guest's copy rolled its own
  foundation, so the stairs could be missing or different, and walking into the trailer pulled the guest back.
- A crash report now names the part of the mod that was running, to find the rare crash after returning to the garage.
- The ARC no longer sits inside the guest in the passenger seat: its screen unit is between the front seats and its body
  (where anchors go) on the rear seat behind the guest. The game puts both on the passenger seat.
- In the garage the guest can now use attachments the host installed on racks (side tanks, roof and seat storage): they had
  no outline for the guest until the next zone.

## [0.9.1] - 2026-11-08

Quick fix. Network protocol **7**, as in 0.9.0. Both players should use 0.9.1.

### Changed

- The download is now a zip: extract it and open `PacificTogether.exe` inside. The 0.9.0 single exe carried the whole mod
  inside itself, and Microsoft Defender flagged it as `Trojan:Win32/Wacatac.C!ml` (a machine-learning guess, not a real
  trojan). The new launcher is a small program without anything packed inside it.
- A joining guest's loading screen waits at most 30 s for the host's world props (it waited 55-80 s); the remaining props
  appear during play, nearest first.

### Fixed

- The launcher no longer fails to open when its unpacked files were left incomplete.
- A guest who dies while sitting in the car is revived in their own seat instead of the driver's seat.

## [0.9.0] - 2026-11-07

Network protocol **7**; the Everelsu fork's additions are negotiated between the two games. Both players should use 0.9.0.

### Added

- Automatic sharing of the host's custom MP3, WAV and OGG radio tracks; guests no longer need to copy matching files manually.

### Changed

- Smoother car movement, wheel rotation, steering and suspension on the guest, with a steady passenger view.
- The bobblehead, hanging ornament and ignition key follow the host's motion.
- Smoother thrown-item movement, preserving throw velocity and rotation.
- The guest's day clock follows the host through loading; time synchronization is confirmed before the loading screen clears.

### Fixed

- Removed car parts keep their paint and decals in hands, on the ground, after pickup and when installed again. Other players see the same appearance.
- Dropped items and car parts retain health, durability, fuel and battery charge instead of returning to full condition.
- Part lockers and shared containers load their contents on joining and synchronize item placement and changes.
- Abandoned cars match the host's paint, decals, part condition, trunk state and stored-item layout.
- Car doors, hood and trunk follow the host's opening and closing actions. Passengers cannot select the hood or windshield from inside.
- Bushes and small trees cleared by the host no longer remain standing on the guest.
- Lucky Junk Heap interactions, rewards, animations, sounds and lid position follow the host.
- Corrected the other player's bio-lantern light color, intensity and range.
- Prevented repeated custom-song restarts and overlapping radio playback.
- The installer restores missing files. The launcher supports direct launch of the selected copy or launch through Steam.
- Less stutter: the guest's game froze for about a tenth of a second every 2 s for the whole session (wreck parts looking for
  their car body); a few other per-frame and twice-a-second costs on both sides are smaller.
- What the guest does in the first ~40 s of a zone join (taking from a car trunk, scrapping a part, picking things up) is no
  longer lost: it is sent once the guest's world has loaded.
- A new guest sees what is inside abandoned cars' trunks and storage soon after loading instead of up to a minute later.
- F9 > 3 (Reset controls) also clears a stuck ARC screen: interaction prompts, hands and HUD come back.

## [0.8.9] - 2026-11-04

Network protocol **7**: both players need 0.8.9.

### Changed

- The guest's map is the host's: closed junctions, buildings, the gateway and quest markers look the same on both screens,
  and the map is turned the same way (each side used to pick its own north).
- The guest leaves the car through the passenger door; the X key and the "X Exit car" / "E Radio on/off" text are gone.
  **End**/**F8** in the seat also gets the guest out (for a car without its passenger door).
- The guest gets the radio's own outline and panel from the passenger seat (station, track, volume, power).
- The intro movies are skipped while the mod is installed (they come back on uninstall).

### Fixed

- "Wake the main story" (F9) now also starts the next mission, with its task and map marker.
- An old mission's green marker no longer stays on the guest's map.
- The car radio no longer sounds muffled to the guest in the seat.
- The research machine's screen no longer stays white the first time it is opened (a short flash remains).
- The guest sees the host's anchor energy and mechanic XP, so it can research; the energy board beside the machine shows it too.
- A car without a radio no longer causes errors on the guest.
- The guest finds the zone's gateway by its place instead of its name, which differs between the two games (not yet seen in
  a real zone).
- After joining, the guest clears its own lootables a few at a time instead of all at once (aimed at the join stutter; not yet
  checked by hand).

### Known issues

- An upgrade kit printed by the research machine loses its upgrade when the other player picks it up: that copy shows no place
  to install it. Let the player at the machine take and install the kit.
- After "Wake the main story" Oppy does not say the next mission's lines.

## [0.8.8] - 2026-11-02

Network protocol **6** in this integration; optional extensions negotiate support. Both players need 0.8.8. Includes the Everelsu fork's three commits (garage systems, passenger sway
and controls, message lifetimes; native layer rebuilt).

### Changed

- The release is one exe: the launcher carries the whole package and unpacks it by itself. **Install & play** starts the
  game through Steam when Steam is installed.
- **Copy logs** (was Collect logs) packs everything into one Desktop zip: the game log now and of earlier runs, the mod's own
  log of each of the last 10 runs (kept however the game was started; the game's log only ever held the last run), engine
  logs and crashes of the last week, saves, game settings, performance check results and a system summary.

### Fixed

- From the 2026-11-01 friend session (owner as guest; see NOTES "2026-11-02"):
  - The guest no longer "dies" a moment after every junction arrival and gets put next to the car. A likely cause of
    items vanishing from the guest's hands at junctions; not yet confirmed in play.
  - A gateway summoned by the host now shows on the guest's side (beam, lights, sound, map icon).
  - Blueprints the host unlocks mid-session reach the guest's benches and crafting lists without a rejoin.
  - The car radio no longer sounds muffled ("behind a wall") to a seated guest.
  - Guest crash while the host's garage storage changed (expansion install, shredder output): the guest's sliced refill
    stops when the storage it was filling is gone.
  - The launcher's "collect logs" also saves the engine's crash context (native call stack) next to each crash marker.
- Guest responsiveness (owner request 2026-11-02, "playing as a guest is not immersive"):
  - Getting into the car: the guest's walk to the seat starts the moment the door is pressed (driver's door too) and it sits
    down on its own; the host confirms. Before, every entry waited 2.1-2.3 s for the host's walk-in. Without the host's
    confirmation the guest stands up by the door again after 4 s.
  - Scrapping as the guest: the resources that drop stay put. They used to vanish within a second and come back as the host's
    copies a few seconds later.
  - Door keypads (the red lights by locked doors) exist for the guest too, and its press works the host's keypad.
  - The host pulling an ARC anchor: the guest's copy plays the take (sound, fade) at once and stays as a pulled anchor, instead
    of disappearing silently seconds later.
- Delayed car actions and handshake/body-refresh callbacks stop at a world change. A previous passenger exit cannot
  repossess an old character after that controller has received a replacement pawn.
- Message buffers are cleared before map loads; incomplete messages follow controller identities instead of reused addresses,
  and queued messages from expired controllers are discarded.
- Passenger camera sway settles at low FPS instead of amplifying tiny parked-car movements into sustained shaking.
- Passenger ignition and P/D interaction again use the game's native highlight and dashboard selection.
- Passenger look follows car turns while preserving free look, and returns to world-space control after leaving.
- Joining guests restore logbook history quietly; new discoveries still show notifications.
- Remote damage is intercepted before local health and HUD feedback run, preventing the host's red damage frame for a guest hit.
- A seated passenger can interact with the front passenger door to open it and leave on that side.
- Research uses the inventory manager's saved unlock graph instead of transient chart graphs; the guest UI cannot print a second reward.
- Pneumatic-mail inbox, outbox and return queue follow the host; guest tubes do not launch duplicate pickups.
- Loose items receive pitch, yaw and roll, including rotation without translation; guest copies follow host physics.
- Initial connection waiting covers long host loads; increasing address-resolution waiting alone left the game's 60-second cutoff active.
- Healer and Charging boons reach the guest, including remaining power and depletion; guest-local duplicates and resource simulation are suppressed.
- Already replicated anomalies also receive movement and distance-relevance settings. The three replication passes share idempotent setup.
- Lag/loss tests route auto-joining guests through the tunnel; previously only delayed probes used it while gameplay could bypass it.

## [0.8.7] - 2026-11-01

Fixes from the owner's live two-client test of 0.8.6 (each checked by hand on a test pair; zone travel, the Ida trader and
fuel barrels not yet).

### Added

- Performance check (F9 menu, item 6): 10 s of FPS as set and at half resolution tell whether the GPU or the CPU holds the
  game back, with the settings that matter (resolution, DLSS, FPS cap, mirrors), on screen and in the log.

### Changed

- Performance mode is aimed at a CPU-limited PC: the car mirror and the two rain cameras redraw the scene 10 times a second
  instead of every frame, and the render resolution is no longer lowered (it does not help such a PC and looked worse). The gain
  could not be measured on the developer's PC (too fast); the performance check on the slow PC will tell.

### Fixed

- Custom music: both players now hear the same custom song (checked by hand on a test pair, 2026-11-01). The guest plays the
  host's file from its own music folder and checks twice a second that it still does; before, songs kept changing, two
  played at once, or the guest drifted to its own. Songs with accented names play too. A song only the host has is skipped.
- Performance mode moved from F10 (it opened the console) to the F9 menu, item 5.
- Partner heal (H): the message now shows on screen, and healing a partner at full health tells you so instead of using up
  the cooldown.
- The garage status monitor stayed black for the guest.
- The seated guest's key, shifter and car radio did nothing: E reached only the first of two features listening for it. Fixed,
  and the control the guest looks at now gets the game's outline. The ARC screen in front of the shifter no longer takes the E
  meant for the shifter; looking straight at the ARC still opens it.
- E in the garage no longer fills the log with cutscene-skip errors.
- A Scrapper appeared on the host's screen for good once the guest scrapped something on the car.
- The garage battery charger: either player's pull now shows and charges on both sides.
- Radiation areas glowed brightly on the guest's ground while the host saw almost nothing: the guest's copies now match.
- FPS: in a zone the mod's steady work fell from about 2.1 s to 0.9 s a minute on the host and from 1.1 s to 0.55 s on the
  guest (distant wreck parts and resources are checked a few at a time, the host's prop sweep rests 5 s between passes).

### Checked by hand (0.8.6 fixes)

- No crash with both players in the trunk; no Hot Dust trail behind a carried ARC anchor; the guest's Settings, crafting and
  fuel nozzle work; partner heal and performance mode work.

## [0.8.6] - 2026-11-01

Fixes from the second two-hour friend session (friend hosting). Not yet tested by hand; see "Not checked" below.

### Added

- Patch up your friend: look at them up close and press H to give them 40% of their health back, once every 3 minutes
  each. A stopgap while the remaining causes of the host's health drain are tracked down.
- Performance mode (F10): lower render scale, shorter view and shadow distance, thinner foliage, no volumetric fog,
  reflections, ambient occlusion or motion blur. It can run faster than the unmodded game, at a visual cost. It is
  remembered for the next start; turning it off applies your own graphics settings again.
- The guest can turn the car radio on and off from the passenger seat (E while looking at it), and the key and shifter
  are easier to aim at.
- Ida's trader now appears for the guest too (each player's copy has its own stock).

### Changed

- The mod's text uses the game's own HUD fonts, and the F9 rescue menu is a framed card on the left like the game's.

### Fixed

- FPS dropped further the longer you played: the guest smoothed every hazard of the Zone each frame (6 ms a frame after
  two hours), and the host re-read every container and item twice a second (30-40 ms hitches). Now only nearby hazards
  are smoothed, and containers are read when they change.
- Custom music was skipped: the guest's game only knows a custom file once it is about to play it, so the host thought
  the guest lacked nearly all of them. The guest now looks in its own music folder.
- The guest crashed when both players had the trunk open and the other one moved items: the other player's changes to a
  container you have open now wait until you close it (your own changes still go through). If you both move items in
  the same container at the same moment, one of you may see an item come back.
- An unbreakable PC (and radio) appeared in the middle of the garage for the guest: copies of the game's hidden templates.
- The garage fuel nozzle vanished for the guest (and the pump got three nozzles): each player now keeps their own nozzle.
- A trail of Hot Dust behind a host carrying an ARC anchor: the guest's copy of the anchor's radiation now moves with it
  instead of leaving a new field every few metres.
- The host took a 60-point hit out of nowhere: bumps of the host's body in the guest's game are no longer passed on.
- The guest's held Scrapper could stick on the host's screen over the hotbar.
- Items in the car's storage racks and crates are now shared, so they no longer vanish when the next Zone loads.

### Not checked

- Custom music with real files, the trunk crash, the Scrapper on the host's screen and the car rack items were not
  reproduced in tests; they follow the logs. Still open: the guest's Settings crash, crafting disappearing for the guest,
  the charging station not showing "Connected" for the guest, fuel barrels missing for the guest, the guest stuck in the driver's seat after the Sierra mission.


## [0.8.5] - 2026-10-31

### Added

- A new look for the other player: a hooded rogue instead of the crude survivor, with a glowing face on a black mask.
  The host and the guest look different (an amber grin for the host, green round eyes and a zigzag mouth for the guest,
  and different jacket colours), so you always know who is who.
- The other player sits properly in the car: their legs fold into a seated pose when they get in and stretch out again
  when they get out, in both seats. Before, the driver stood in the seat with the legs through the floor.

### Changed

- New README for players: what the mod does, how to install and join, controls, known issues.

## [0.8.4] - 2026-10-30

### Added

- Rescue menu (F9) for glitches and softlocks: teleport to the other player, resync with the host, reset stuck controls,
  and complete a story task the game will not tick by itself (for example Q01's "Take the Anchor"), for both players.
  When a quest is finished but the next one never starts (Q01 to Q015), the menu offers to start it.

### Fixed

- The guest sees the rain again: falling drops and splashes now follow the guest's character, as they do for the host.
- Tools in the other player's hand (Scrapper, Impact Hammer, blowtorch and the rest) are held level at their real size,
  instead of pointing up over the shoulder or jumping around while the other player moved.

## [0.8.3] - 2026-10-30

### Added

- You hear the same scares: whispers, the static ghost, drones, startled birds and the rest now happen for both players at
  the same spot (the host's game picks them).
- One ARC waypoint for both: a waypoint either player places, moves or clears on the ARC map shows for the other too, on
  the map and in the world (the passenger can mark the next turn for the driver).

### Changed

- The other player's name tag stays out of the way: no tag when they stand in plain sight nearby, it shows when they are
  far off or behind something, and their health shows only when they are hurt.
- The overlay no longer narrates what you can see (entered the car, picked up an item, repaired, anomaly hits); it keeps
  what matters to you (the other player loading, your backpack, lost items, connection).

## [0.8.2] - 2026-10-30

### Added

- Co-op weather is spookier: while you play together the host's game keeps the sky overcast (fog, wind, light rain and
  darkness never drop below a floor, the game's own storms still come through), nights last longer and days pass faster,
  a map that loads in daylight starts late in the afternoon, and a storm, heavy rain, darkness or fog rolls in every 5-9
  minutes. Back to normal when the guest leaves.
- Riding as the guest feels like a car: the guest's head sways with the car (back on throttle, forward on braking, out in
  turns, down over bumps).

### Fixed

- The guest sees the rain: falling rain, splashes and the radiation haze were never set up for the guest.
- The car interior no longer shakes against the guest's view at speed (the car was placed a frame after the camera).
- Tools in the other player's hand look like the tools (Impact Hammer, Scrapper and the rest): their real model, size
  and textures instead of a jumble of first-person parts.

## [0.8.1] - 2026-10-30

### Added

- The guest in the passenger seat can turn the ignition key and move the shifter between P and D (P holds the parking
  brake): look at the key or the shifter and press **E** (the hint above the hotbar says which). The host applies it;
  the key turns without its animation and never fails to start.

### Fixed

- The antenna quest (Q01) no longer restarts after every run when the guest takes the anchor: what the guest does
  for a quest step (holding the anchor, carrying an item) now counts for the host's story.
- Radiation around an anchor (Hot Dust) no longer stays on the guest after the anchor is pulled: the guest's radiation
  now follows the host's, including clouds that disappear.
- Direct IP no longer depends on Steam: a different Steam build id (or none) no longer refuses the join, only a
  different game version, mod version or protocol does; the host logs the difference. A guest without Steam keeps their backpack on the host across launches
  through `player_id.txt` in the mod folder, like PDCoopNet. Steam invites work as before.
- The launcher's Install & play starts the game's exe directly instead of through Steam; the installer adds
  `steam_appid.txt` next to the exe (removed on uninstall) so it does not restart itself through Steam.

## [0.0.8] - 2026-10-25

Network protocol **4**: both players need 0.0.8.

### Added

- Map transitions look like a co-op game's: the guest fades out with the host and sees the game's own loading screen from the
  host's map load until both are in; the host's loading screen waits for the guest (60 s at most) so neither sees the world alone.
  Notices: "Host is choosing a route", "Host is travelling", "Waiting for <name> to load".
- "ARC <collected> / <required>" on the overlay in run maps: the device sits behind the seats in co-op, out of view.
- The guest can use the car radio and the garage stereo through the host, and both hear the same track, started together
  on every track change, join and map load. A custom track the other player does not have (matched by file name) is skipped.

### Fixed

- Weather and lighting follow the host on the guest: the guest's sky simulation never took the host's weather changes.
- An anchor the guest pulls is taken on the host too (and one the host pulls disappears for the guest), so it can be
  deposited only once.
- The host no longer takes a 20-60 point hit each time the guest rejoins after a junction (the game seating the guest jolted
  the car on the guest's side and that hit was forwarded to the host). Not reproduced in tests yet.

### Known issues

- Some anomalies are invisible to the guest: the noisy one that repairs the car, and the "tictac" (owner hand play 2026-10-24).
- Radio position can drift within a track (the game has no seek); real custom-music files are untested.
- Tutorial steps done by the guest alone do not advance the host.

## [0.0.7] - 2026-10-24

Network protocol **3**: both players need 0.0.7.

### Added

- Animated survivor bodies; seated legs hidden; Cyrillic name tags.
- Guest Esc menu, loading/seat prompts and fades, and End/F8 control reset.
- Only host Esc pauses both games; the guest sees "Paused by host".
- Host player upgrades, garage-door locks/state, zone buildings/props, radiation, flat tyres, ARC structures,
  broken plasma generators, portals and story pickups reach the guest.
- Spark Towers, landmines, bollards and grabbers respond to guests far from the host.

### Fixed

- Join-buffer overflow: host traffic is paced and bulky messages wait for the guest's character.
  A measured post-junction character delay fell from 48 s to about 1 s.
- Guest seating, safe exit placement and restored walking/collision after junction travel; immediate seat correction
  prevents a respawned guest from colliding with and tearing apart the car.
- Car replication stays relevant when the host drives away, preventing a frozen guest car and unloaded exit area.
- Key handling now runs on the game thread, avoiding concurrent Lua-state corruption and join-time crashes.
- Cached/budgeted synchronization removes repeated zone stalls. Car state is sent at most twice a second;
  measured host car-tick cost fell from 3.9 to 1.0 ms.
- Corrected doubled guest garage-upgrade counts, repeated story lines, oversized Impact Hammer, persistent scrape
  sound and a stale-object crash when a seated guest rejoins.

### Known issues

- Guest-picked anchors can remain on the host and be deposited twice.
- Tutorial steps done by the guest alone do not advance the host.
- Driver-door re-entry showed the driver's pose once in hand play; tests have not reproduced it.

## [0.0.6] - 2026-10-22

### Added
- You see where the other player is: a marker on the ARC map in the car, and a blue marker with their name and distance on the HUD once they are more than 30 m away (closer, the name tag shows).
- Car upgrades show for the guest: when the host fires nitro, the jump rack, the shields or the juke, the guest sees and hears
  them on the car; bigger batteries and fuel tanks grow the guest's gauges too; the interior light follows the host. The
  Chrono Dilator still does nothing in co-op. The guest's car no longer rolls its own quirks.
- The guest's tools work on car parts and abandoned cars: Scrapper and Electric Scrapper, Hammer and Magnetic Hammer,
  Prybar, Explosive Cutter, Blowtorch and putty. The part breaks or heals for both players and its scrap drops once.
- The guest can take parts off the car, install parts, refuel and use the car's storage; the host's car takes the change.
- The garage stereo and the car radio are shared: either player switches them, changes the volume or skips a track.
- Riding along feels alive: the guest hears the engine follow the host's driving and sees the speedometer, horn,
  headlights and wipers.
- Part Stealers go for the guest too: one near the guest on foot takes a random item from their backpack. A Loot
  Creature's push hurts and shoves the guest.
- The guest sees the host's garage stations (fax machine, Part Shredder, Destabilizer and the rest), and the garage
  doors open and close for both players, from either player's button press.
- You see what the other player holds: their tool or item in their hand, their flashlight's beam, a car part they
  carry, and a swing when they use a tool.
- The guest can use the garage stations: the Part Shredder, research, garage upgrades, fabrication and curing car
  quirks. The host's shared materials are spent once and the result shows for both players. Both see the same car quirks.
- Join through Steam: the host's game opens a friends-only lobby, the guest uses "Join game" in the friends list or
  an invite, and names come from Steam (not tested between two PCs yet; joining by IP works as before).
- The guest's journal lists the host's finished missions, and a quest item the guest picks up counts for the host.
- Ping: look at something and press the middle mouse button. Both players see a marker there for about 8 seconds with
  your name, the distance and, for an item or container, its name, and hear a short HUD sound. One ping per player.
- The guest sees the garage's Fig decorations and the paint and decals of the car's parts as the host does. (Copying
  the zone's buildings and props to the guest is built but switched off: it slowed the guest's loot sync too much.)

### Fixed
- The host's game crashed when the host pressed Esc with a guest connected (with "Pause game while in menus" on or off).
  The real cause was the guest's controller on the host having no input object; fixed. The host's pause menu pauses
  the game for both players.
- The garage doors never opened in co-op, so the car couldn't leave the garage.
- A guest who was stuck "dead" after a car door or the game's own kill lost their materials and got no death crate.
  Every guest death now ends in the death crate with crafted items intact, and the guest comes back.
- An item the guest dropped existed twice (one for each player to pick up).
- Loot in abandoned cars' trunks and truck beds wasn't shared.
- Dropped items floated in the air on the guest's screen.
- The guest's repairs and scrapping on car parts snapped back and left ghost items on the guest's side.
- Pressing X to leave the car left the guest stuck inside on their own screen.
- The ARC device between the seats blocked the starter key and some panels; it now sits behind the front seats.
- The overlay moved higher; it overlapped the game's HUD at the bottom right.

## [0.0.5] - 2026-10-21

### Added
- A proper launcher app (PacificTogether.exe) replaces the small window: pick Host or Join, install, uninstall, open the
  log folder, collect your logs into one zip on the Desktop, and read what's new, what is not done yet and how to connect.
- An in-game overlay: "Pacific Together" and its version at the bottom right, the session status with ping, and a short
  feed of what the other player does.
- The launcher shows the build in this download and the build installed in your game.
- The guest's game shows the host's progress while joined: garage upgrades, research, the route on the map and the
  logbook. A failed run costs the guest items too, as it does the host.
- More anomalies act on the guest: Leech leaps, BombRock blasts and Physics Grabbers. Tourists stop while either player
  looks at them.
- The story is shared: the guest sees the host's mission and objectives on the HUD and in the journal, and hears the
  host's radio transmissions and voice lines with subtitles.
- The guest can repair the car with putty, charge its battery, refuel from a fuel can, deposit anchors and pick the
  gateway at the ARC.
- Abandoned cars and their parts are shared; scrapping and siphoning fuel happen once for both. Handed-over items keep
  their durability, fuel and battery. Opened and emptied containers look that way for both players, and garage storage
  is really shared now.
- The guest's backpack is kept by the host and comes back when the guest rejoins. A guest who dies drops their items in a
  crate that either player can loot.

### Fixed
- The host's game crashed when the host opened the pause menu with a guest connected, and the guest couldn't open the
  pause menu at all. Pausing now works: the host's pause menu pauses the game for both players.
- The guest "died" a few seconds after every map change, dropping their backpack as a crate. Fixed.
- A failed run's item loss for the guest could be undone when they rejoined. Fixed.
- An anomaly hitting the guest took the host's health instead of the guest's. It now hurts the guest.

## [0.0.4] - 2026-10-21

### Added
- The guest rides in the host's car: in through the passenger door, smooth movement, out with the X key. Car parts, their
  health, fuel and battery are the same for both players, and the guest's dashboard shows the host's fuel and battery.
- Loot is shared: the guest sees the host's containers and items with the same contents. Taking or putting items in a
  container, the car trunk or garage storage changes it for both. An item picked up from the ground is gone for both.
- The run is shared: the same time of day, weather, instability, storm, gateway and anomalies for both players.
- Each player sees the other's health under their name tag. A guest who dies comes back at the car; the host's run goes on.
- The guest stays out of the story: missions, radio and cutscenes play for the host.

### Changed
- Under the hood: a message channel between host and guest carries all of the above.

## [0.0.3] - 2026-10-20

### Fixed
- The guest's field of view could be squeezed to a narrow slit after joining the host. It stays normal now.
- When the game crashes, the mod now writes down what it was doing at that moment, so a crash report says more.

## [0.0.2] - 2026-10-20

### Fixed
- The host getting into the car no longer drags the guest along with them.
- When the host changes map, the guest follows straight into it without a trip through the main menu.

## [0.0.1] - 2026-10-19

First preview.

### Added
- The guest joins the host by IP address from the main menu (UDP port 7777).
- You see each other's bodies and name tags, in the garage and out on a run.
- The guest follows the host through every map change: starting a run, the gateway home, death, run failure and the host's
  save and quit. If the guest's game drops or crashes, the host keeps going and the guest can join again.
- The host can get in and out of the car.
- Only the host's save is used. The guest's own saves are never written while joined.
- Pausing and the Chrono Dilator no longer freeze the game while a guest is connected.
- The game's crash upload to the developer is switched off while the mod is installed.
- The installer checks your game build, backs up your saves before the first install and can remove the mod again.
