# Playtester guide

Developer/friend preview **0.9.2**, development protocol **7**. Both players need the same download and the supported Pacific Drive build,
v1.15.0 (build 21896301). The host owns the world and saves. Mixed DLC ownership is not yet verified.

## Install and connect

Close the game, extract `PacificTogether-<version>.zip` to a folder, open `PacificTogether.exe` inside it and
check the game folder. **Install & play** starts the selected copy directly. Enable **Launch through Steam** to use the Steam library instead.

**Steam:** both players select **Host** to install without a saved IP, enable **Launch through Steam**, then **Install & play**. The actual host loads
a save; the guest starts the game and uses Steam's **Join game** or accepts an invite. This path was verified between
two accounts on October 23. A cold-start invite is a separate path and still needs validation.

**Direct IP:** the host selects **Host**, the guest selects **Join** and enters the host's address. After installation,
leave **Launch through Steam** off to start the selected copy directly. The host loads a save and the guest waits at the main menu. Use a reachable LAN/VPN address or forward UDP 7777 on the
host's router. Allow the game through Windows Firewall on the network used for the session. A saved join address takes
precedence over Steam joining; reinstall in Host mode to clear it.

Without the launcher (in the extracted folder): `install.cmd` for host/Steam, `install.cmd -Join <host IP>` for direct IP, then start `PenDriverPro\Binaries\Win64\PenDriverPro-Win64-Shipping.exe` (or through Steam).
A game or mod version mismatch refuses the join; a different build number is only logged, and such a pair is untested. See `README.txt` for features and known issues.

## Custom music

Both players need the updated Lua mod and native DLL for automatic music sharing. Select custom music on the host as
usual: its currently selected MP3, WAV or OGG is sent to the guest when needed. Wait for **Shared music ready** on the
first download; then the song restarts for both players. The host chooses the music for the session.

Identical local files are reused. Different files with the same name stay separate; the guest's own music is preserved.
The received-song cache keeps at most 256 MB / 64 songs and accepts individual files up to 64 MB. Older peers need the song in
their own music folder, as before. Song timing is approximate; this is file sharing and coordinated playback, not live
audio streaming.

## Controls and playtest

- Host drives; the guest opens the **passenger** door with **E** and gets in, and rides in the passenger seat. Open the passenger door from the seat to get out. From the seat, look at the ignition key, the shifter or the radio and press **E** to start/stop the engine, switch P/D or turn the radio on/off; the radio's panel works as the driver's does.
- New game: **E** skips the opening for both players.
- **Middle mouse** pings; **End** or **F8** resets stuck guest controls.
- **F9** opens the rescue menu when something breaks: **1** teleport to the other player, **2** resync with the host,
  **3** reset controls, **4** story tasks (press a stuck task's number twice to complete it for both; when a quest is done but
  the next one never starts, the list offers to start it). **0** goes back, **F9** closes.
- Host **Esc** pauses both games; guest **Esc** opens their menu.
- Check garage interactions, a junction transition, scavenging, gateway return, death/failure and leave/rejoin.
  Record what you actually saw; automated checks do not cover every interaction.

## Report a problem

Include roles, mod version, time, steps, expected/actual behavior and whether it repeats. A short recording helps.
Use **Copy logs** on each PC to create one Desktop zip with everything: the game's log now and of earlier runs, the mod's own
log of each of the last 10 runs (however the game was started), engine logs and crashes of the last week, your saves, game
settings, performance check results and a system summary (`list.txt` in the zip lists it all). Restarting first is fine.

- Main log: `PenDriverPro\Binaries\Win64\ue4ss\UE4SS.log` (**Open log folder**); per-run copies: `ue4ss\Mods\PacificTogether\run-NN.log`.
- Crash marker: `%LOCALAPPDATA%\PenDriverPro\Saved\Crashes\<crash folder>\PacificTogether-crash.txt`.
- Report modded-game crashes to this project; the mod disables the game's uploader.

## Backups and uninstall

The first install of each build saves a backup at `Documents\PacificDrive-saves-backup-<date>.zip`.
To restore, close the game and extract it over `%LOCALAPPDATA%\PenDriverPro\`.
Uninstall keeps saves but removes the entire `ue4ss` folder, including other UE4SS mods.
