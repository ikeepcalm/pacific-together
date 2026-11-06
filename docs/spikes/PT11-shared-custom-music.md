# PT11: shared custom radio files

2026-11-03. Owner request: custom songs should be available to both players; the owner will check playback by hand.
Based on `2c7b1d3` (author protocol **6**). No change to PT1/PT1A or the existing radio messages.

## Behavior

`radio.lua` keeps the existing host-authoritative song selection and media-player path. Peers with the optional
`music-files` capability transfer only the currently selected host song. This does not merge music libraries or upload
the guest's own collection. A matching local SHA-256 avoids a download; cached songs are reused. A missing or different
file downloads to `ue4ss/pt_music` in that process's game binary directory, outside the player's custom music folder.
After verification the host reopens its song and sends the existing restart state, so both start near the same time.
While waiting, the guest pauses its previous song rather than playing different music over the host's selection.

The capability is advertised only with the matching native file functions. An older peer keeps the existing behavior:
the guest must already have the song, and missing songs are skipped. Both players need updated Lua plus native DLL
to use automatic file sharing. Protocol remains **6**; only the repository author changes it.

## Files and transport

- `radiomusic.lua`: offers, requests, cumulative acknowledgements, duplicate handling, readiness and cancellation.
- `music.cpp`: UTF-8/Windows wide paths, incremental SHA-256, chunk reads and a private verified cache.
- `net.lua`: optional capability and per-direction gating of the new `g.radio.file.*` messages.
- Native registration: `dllmain.cpp` and the native CMake target. Packaging already copies all shipping Lua and the DLL.

Only the selected local `file://<drive>:/...` audio file is registered for reading. The receiver accepts MP3/WAV/OGG
metadata, positive integer sizes up to 64 MB, a lowercase SHA-256 and a bounded display key. No remote filename or path
is used for writing. Files use hash-derived names, an exclusive `.part`, exact offsets and a final SHA-256 check before
atomic replacement. Corrupt transfers never become playback URLs. The managed cache is limited to 256 MB / 64 songs, evicting
old cache files and cleaning stale parts without touching unrelated files or following cache-directory reparse points.

Hashes advance at most 1 MB per call; entire songs are not hashed in one game-thread call. Transfer uses the established
reliable channel, 8 KB raw chunks encoded as hex and at most two chunks awaiting application acknowledgement. It waits
for the applied gameplay baseline. A controller lease, world epoch, request ticket and content hash fence the transfer.
Travel, leaving multiplayer, an idle timeout or a disk/integrity failure discard the partial file. The existing native
and Lua control queues retain their priority over bulk traffic. No extra service, socket or account is used.

## Validation actually run

`powershell -NoProfile -File tools/test-radio-music.ps1` builds a native self-test and a local interpreter from the pinned
Lua source using the installed compiler. It starts no games and uses only `local/music-tests` for test files.

- Native checks: binary round trip, Unicode source path, incremental hashing, SHA-256, invalid paths/extensions/sizes/
  offsets/hex, corrupt transfer rejection, cancellation, an unrelated working directory, and quota eviction while preserving unrelated cache files.
- 18 Lua protocol checks: missing/local/cached files, same-name collisions, incremental preparation, duplicate data,
  old peers, baseline admission, invalid metadata/ACKs, stale world/ticket/hash/offset, integrity/disk failures,
  same-name content changes, timeout, travel and leaving multiplayer.
- Shipping `radio.lua`, `radiomusic.lua`, `net.lua` and `common.lua` compile in that interpreter.
- Matching native DLL rebuilt with `tools/build-mod-fast.ps1 -MainBuild C:/Dev/pacific-together/native/build`.

Built native SHA-256: `21361028442f528fc0d053d00f85bd3eee79570c03219270d51895387475e9ef`.

Logs: `local/music-tests.log`, `local/music-native-build.log`. No real installation, real saves or user music were modified.
No live two-client transfer, Steam relay, rendered playback, audible output or full regression suite is claimed here.
The owner explicitly reserved the hand check; the working change is not release-certified.

## Hand check

1. Update Lua and DLL on both players. Put a supported song only in the host's usual custom-radio folder.
2. Join and select that song. The guest should see download/ready status, then both should hear the host's song.
3. Rejoin or replay it: the cache should avoid another transfer. Try different files with an identical filename.
4. Change tracks or travel during a transfer, and verify radio on/off, volume and station controls afterward.

The first download takes time, and songs above 64 MB cannot be shared this way. Coordinated restarts do not establish
sample-accurate playback or eliminate drift; media decoding and real Steam throughput still need the hand check.
