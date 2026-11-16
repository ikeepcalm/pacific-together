# hudmap: HUD map and partner pins (2026-11-16)

## Observations
- BP_InteractCameraComponent (the ARC screen's "widget component") is a CameraComponent, not a WidgetComponent. It draws UMG_GobblerScreen_C
  into a SimpleWidgetRenderer render target (GetWidgetRenderTarget, 2048x2048) and ticks it only when `Widget Tick Mode`
  (property "Widget Tick Mode", byte) allows: 1 = only while the owner was rendered in the last 0.2 s, 2 = every `Frame Interval` frames.
  The screen was at 1 on both sides. UWidgetComponent calls (SetTickWhenOffscreen) do not exist on it.
- Headless (-nullrhi): the Minimap widget never ticks (Initialized=false, Icons=0, InitialMapSize 0), the render target object exists.
  Rendered, seated host: Initialized=true, 38+ icons, pins listed as widgets.
- The map is the top left InitialMapSize (1516x1324) of the 2048x2048 target; the rest is legend and text. A ClipToBounds canvas in a SizeBox shows only the map.
- Slate units are pixels / GetViewportScale (0.44 at 752x423): 22% of the height needs `vp.Y * 0.22 / scale`.
- Rendered 2-client run (local/test-results/20261116-195047-hudmap-hudmap): the partner pin (BP_GobblerMapBounds MapIconComponent, Map-Pin,
  colour per side) is a UMG_GobblerScreen_C.Minimap.Icons widget with visibility SelfHitTestInvisible on BOTH sides. showPartnerPin was right.
- HighResShot does not capture UMG; `Shot ShowUI` does.

## Derived
- "Pins invisible both ways" (NOTES 2026-11-15 item 10) is most likely the ARC screen not being drawn: behind the front seats the screen is
  never "recently rendered", so its Minimap does not tick and nothing, pins included, shows in the physical screen. The HUD map keeps the
  screen's tick mode at 2 while seated, so the Minimap initialises and lists the pins.

## Guesses / Unknowns
- Not reproduced: a pin missing from the Minimap while the Minimap ticks. If the owner still sees no pin in the HUD map, send the log line `PT|mapmark partner waypoint` and the guest's Map-Pin widget state.
- The map overlaps the bottom of overlay.lua's status text a little at 1080p (map 238 + 18 px, overlay line at 240 px).
- Tick mode 2 draws the 2048x2048 screen every 3rd frame while seated: not measured for FPS (rendered pair too small).
- Headless cannot see the Minimap widgets; the scenario checks the tracker side there and the widgets in rendered runs.
