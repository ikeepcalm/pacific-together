# Marks: one marker per player, and the heal hint (lane marks, pt18, 2026-11-12)

## Owner requests (playtest 2026-11-12)

1. Two players, two different markers on the map, "one blue, one green for example", not the same one.
2. "That prompt of healing the friend appears [only] if you hover him, and it's not on cooldown."

## Observations (code read before building)

- Marker: the only marker a player places is the ARC screen's waypoint (`UMG_GobblerScreen.PlaceWaypoint` spawns or moves
  one `BP_WaypointActor`: a map pin `MapIcon` plus an in-world `SC_GenericObjective`). `FindExistingWaypoint` takes
  `GetActorOfClass(BP_WaypointActor_C)`, i.e. the first actor of the class. No HUD marker is placed by hand.
- Before this lane (mapmark.lua, 2026-10-30) each side kept one `BP_WaypointActor` and sent its state as `g.map.wp`; the receiver
  moved, spawned or destroyed ITS actor to match. So in co-op both players shared a single marker: when the guest placed a
  pin the host's pin jumped there, and clearing on one side cleared it on the other. Same colour (the game's own).
- Partner position icons (mapmark.lua): a `MapIconComponent` on the other's character copying the car icon (texture/materials),
  cyan `{0.2,0.8,1.0}`; plus an `SC_GenericObjective` HUD marker (blue quest type 3) past 30 m. Both players got the same cyan.

## Interpretation

Each player keeps their own pin (the game's own actor, never moved by the partner), sees the partner's pin as a second
pin, host blue and guest green. Partner-position map icons use the same two colours (host blue, guest green). The in-world
beacon and the HUD distance marker of the partner's waypoint are not built (see Unknowns).

## Derived (what is built)

- The partner's pin is a `MapIconComponent` (texture `Map-Pin`, found once by name) added to the `BP_GobblerMapBounds_C`
  actor with manual attachment, placed in world space, size/z from the car icon, not a second `BP_WaypointActor` (the ARC screen
  would pick it up through `GetActorOfClass` and move it as if it were the player's own). Registered in `proxyOf` so the guest's
  host-icon copy does not hide or resend it. A message that arrives before the bounds actor / car icon exists is retried every 0.5 s.
- Own pin recoloured every 0.5 s (`MapIcon:SetIconDrawColor`): host blue `{0.1,0.4,1}`, guest green `{0.1,1,0.2}`.
- Sync is unchanged on the wire (`g.map.wp`, "x y z" / "none"); only the receiver changed. Mutation `onemark` restores the old
  overwrite behaviour; `nowaypoint` still turns the sync off.
- Heal hint: no persistent hint existed. The only prompts were the toasts "You patched up X" / "You can heal X again in N s" after
  pressing H. A hint line "[H] Patch up <name>" now shows under the crosshair (overlay.lua `PTHint`, `ov.hint(text)`),
  driven every 150 ms from heal.lua: shown only while `partnerInReach` (REACH 300, AIM_DEG 25) and `readyAt` has passed.
  Mutation `healhintalways`: always shown. Test hook: under `PT_SCENARIO=healhint` heal.lua answers `g.heal.testpress` like H.

## Guesses

- The game never recolours the pin by itself after spawn (the 0.5 s tick would otherwise flicker); not seen in a screenshot yet.
- `Map-Pin` tint multiplies the texture (the cyan car icon did).

## Unknowns

- Not built: the in-world beacon (`SC_GenericObjective` of the game's own waypoint) for the partner's pin; the partner gets the map
  pin only. Its own pin's beacon keeps the game's colour (the game's `SetMarkerVisuals` types are not mapped to colours).
- No key injection exists for the real H key; the scenario uses the test hook above.
