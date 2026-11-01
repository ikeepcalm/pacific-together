Pacific Together 0.8.6 - co-op for Pacific Drive
================================================

Play Pacific Drive with a friend: one drives, one rides shotgun, both scavenge.
Early access: fully playable, still being polished. If something breaks mid-run, press F9 for the rescue menu.

Both players need this same mod version (0.8.6, protocol 5) and Pacific Drive on Steam, v1.15.0 (build 21896301), on Windows.

Features
- One car, two players: the host drives, the guest rides in the passenger seat and can start the engine or shift gears.
  Fuel, battery, damage, parts and storage are shared; both can repair, refuel and swap parts.
- Scavenge together: containers, pickups, abandoned cars and garage storage are shared; items keep their condition.
- The same Zone for both: storms, instability, gateways and most anomalies.
- One run, start to finish: junctions and the way back to the garage together. Missions, radio, research, upgrades and
  the journal are shared; the guest can use garage stations.
- See each other: a hooded body with a glowing face (different for host and guest), held tools, a name tag with health,
  and middle-mouse pings.
- Your own health and backpack: the guest takes their own damage and radiation; on death their items wait in a crate
  and they respawn at the car. The host keeps the guest's backpack for next time.
- Join through Steam invites or by IP address. The host owns the world and save; the guest's own saves are protected.

Install
1. Close the game. Unpack this zip anywhere and open PacificTogether.exe. Check the game folder it found.
2. Choose Host and click Install & play. (Both players choose Host when joining through Steam: it just means "no IP".)
   Windows may warn about an unknown publisher: More info, Run anyway.

Play with a friend
- Steam: the host starts the game and loads a save. The guest starts the game too, then accepts the host's Steam invite
  or picks Join game on the host in the Steam friends list.
- IP address: in the launcher the host picks Host, the guest picks Join and types the host's IP. The host loads a save,
  the guest connects from the main menu. The host may need to forward UDP port 7777 (or use a LAN or VPN).
Command line instead of the launcher: install.cmd (Host/Steam), install.cmd -Join <host IP>, install.cmd -Uninstall.

Controls
- E on the passenger door: get in (guest). X: get out.
- E on the key, the shifter or the radio from the passenger seat: engine on/off, P/D, radio on/off.
- H while looking at your friend up close: patch them up (40% health, once every 3 minutes each).
- F10: performance mode on/off (lower render scale, view distance, foliage and shadows for more FPS; remembered).
- Middle mouse (or G): ping a spot for your friend.
- F9: rescue menu (teleport to your friend, resync, unstick controls, complete a stuck story task).
- End or F8: unstick the guest's controls. Host Esc pauses both games.

Known issues
- Only the host drives and plans the route. Detailing and quirk hints are host-only; the Chrono Dilator is off in co-op.
- An anchor picked up by the guest can sometimes be deposited twice.
- A few anomalies are not visible to the guest; weather or time of day can differ between the players.
- Tutorial steps done by the guest alone do not count for the host. Mixed DLC between players is untested.

When something breaks
Click Collect logs in the launcher on BOTH PCs before restarting the game (the log is overwritten) and send the zips
with what you were doing: https://github.com/ikeepcalm/pacific-together/issues
Log: PenDriverPro\Binaries\Win64\ue4ss\UE4SS.log. The mod blocks the game's crash uploader: report crashes here, not
to the game's developer. More help: GUIDE.md. Changes: CHANGELOG.md.

Uninstall
Uninstall in the launcher. Saves are not touched, but it removes the whole ue4ss folder, including other UE4SS mods.
Every first install of a build backs up your saves to Documents\PacificDrive-saves-backup-<date>.zip; to restore, close
the game and extract it over %LOCALAPPDATA%\PenDriverPro\.

Support the mod: https://www.patreon.com/cw/ikeepcalm
Built on UE4SS. A fan project, not affiliated with Ironwood Studios. Contains no game files.
