# Client sync fixes and author sync, 2026-11-04

Worktree: `C:/Dev/pacific-together-vehicle-proxy`, retaining the experimental physical vehicle. Author upstream `b401fab` (0.8.9, protocol 7) is included by merge `1996a79`. No native source changed upstream; the existing native binary is retained. Local item-motion and optional transport extensions remain in place. Both peers must use the updated Lua.

## Fixes

- Hood: `SLOT_Hood` is a `BP_Panel_Base_C`, rather than a door. The existing guest door intents, host swing watcher and guest mesh presentation now include that panel. The live host probe confirmed hood opening sets manager door bit 4 and enables its mesh physics.
- Dropped items: host creation now includes the existing `ids.spec` item state. Guest drop requests carry that same state only when `item-state` and velocity support are negotiated. The receiver validates property names, numeric bounds, duplicates and matching archetype before spawning/applying. Durability, health, fuel and battery use the existing item-property serialization. Appearance, upgrades and kit metadata retain their previous limits.
- Radio: stopping the built-in carrier's Wwise event repeatedly caused song completion and file reopen. Pause preserves the carrier instead; guest `OnSongFinished` dispatch is held while following the host's custom selection, then restored on leaving that selection/session. A previous candidate that only held completion dispatch still failed the real playback check, so it was insufficient by itself.

## Executed checks

Archives under `C:/Dev/pacific-together/local/test-results/`:

- `20261104-211925-vehicle-proxy-itemhood`: 25/25 before author sync.
- `20261104-214328-vehicle-proxy-itemhood`: 25/25 on 0.8.9/protocol 7. Guest opens and closes host hood; damaged flare arrives with durability 123, is picked up into the guest backpack, dropped through `PlayerDropHandItem`, and arrives on the host with durability 123.
- `20261104-213346-vehicle-proxy-radioshared`: failed the guest playback check with repeated opens (negative candidate).
- `20261104-213732-vehicle-proxy-radioshared`: 20/20 with audio/rendering enabled; host-only generated WAV reaches the verified client cache, opens once, remains playing after 15 seconds, no new crash or PT error. This checks MediaPlayer state, not audible output or sample alignment.
- Existing file-transfer protocol checks: 18/18 using `local/music-tests/lua.exe tools/tests/radio-music.lua C:/Dev/pacific-together-vehicle-proxy`.
- `20261104-214744-vehicle-proxy-motionparts`: 29/29 after author sync, including both throws, landing, pickup, continuous-motion sampling, wheels and passenger highlight checks.

No full release suite, real Steam relay, long audio soak, track-end/off-on/travel playback matrix or human auditory validation is claimed. Earlier physical-car divergence findings remain open; the owner's hand-play report remains positive. Real installs and saves were not modified.
