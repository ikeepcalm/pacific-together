# Changelog

What changed in Pacific Together, in plain words. Newest first. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Builds before 1.0 are previews for the developers and friends.

## [Unreleased]

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
