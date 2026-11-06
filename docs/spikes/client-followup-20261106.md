# Client follow-up, 2026-11-06

## Observed causes

- Open-container protection deferred even the first fill of an empty container. Empty fills now add items without removing slots; nonempty structural changes retain the existing menu guard.
- The replicated garage GovCar had the correct SelectedPaintPalette but zero DynamicMaterialInstances and a static material. The host had six dynamic instances. SetupMaterials must precede SetupTintOnVehicleAndParts on the new replica.
- Bio lantern's native spotlight uses unitless intensity 100, inverse-square falloff disabled, exponent 2, radius 2000, outer angle 75 and FColor 255,113,242. The mirror previously used inverse-square falloff, which made matching intensity insufficient.
- Passenger hood actions require a server-side rejection in addition to filtering both hood-interaction owners and panel owners.

## Checks

- motionparts: 32/32 before this follow-up; restored windshield filtering and locker transfer.
- garageparts 20261106-105611: 42/43; dynamic materials, first fill of an open empty trunk, health/identity preservation and passenger hood filter passed. Installed health check failed: observed 38.22388 then 42.82014 versus fixed expected 37.5. Cause remains unproven; do not count this run as a full pass.
- Bio lantern fixture test is extended to verify falloff as well as color/intensity. State tests are not proof of rendered illumination.

## Still open

Rendered illumination comparison; cabinet-specific late baseline with existing saves; passenger hood action rejection scenario; cosmetic physics while driving; foliage break animation; dumpster lid state. No release certification.
## Wreck panel material correction
The Blueprint material utility uses an out/ref Material parameter. UE4SS received an invalid Material when passed a Lua output table, so the prior call silently did nothing. Direct parameter updates now use the palette material layers. Live probes confirmed RGB 0.092694/0.122375/0.130208 in both painted panel slots. The visible_panel_paint_and_decal_match check passed after restart in 20261106-115533-vehicle-proxy-garageparts. Overall 43/44; installed health remains a separate failing check. No crash or PT error. Rendered visual comparison remains unverified.

## Lucky Junk Heap lid
Observed host lid pitch -90, guest 0 while all three timelines were stopped at position 1. DeniedTimeline and PopFx both write lid rotation; forcing stopped timeline positions let the last writer overwrite the host pose. Added negotiated heap-lid pose fields; legacy heap messages remain unchanged. heaplid passed 23/23 (20261106-130530); noheaplid control fails idle/open/closed angle checks. heapv2 broad interaction scenario was 18/23 (20261106-130841); initial hold did not complete and its dependent checks failed, so no full heap gameplay pass is claimed. No commit, per owner request.

## Cosmetic rigid bodies during guest driving
Rebind bobble/hanging constraints to the live replicated chassis and carry their simulated component transforms through the guest car pose delta. Physics stays enabled. Rebinding alone failed (hanging body 389.12 uu from actor). With carry: hanging max 0.06 uu, bobble max 7.29 uu over 727 samples. Control nocosmeticcarry: hanging 1191.44 uu and bobble 1194.01 uu, attachment check fails. Positive result 20261106-140034-vehicle-proxy-carsync: 40/41, existing guest_car_follows check fails (maxJump 807.4 uu); same check already failed before carry (368.5 uu). Camera/cabin checks passed with carry. Control 20261106-140518: 38/41, attachment/follower/camera checks failed. Headless evidence; rendered wobble remains to be reviewed. Owner will commit.

## Host-driven cosmetic motion (replaces static carry for updated peers)
Negotiated cosmetic-motion sends independent newest-wins streams for BobbleTop, HangingMesh and SM_Wagon_01_KeyPhysics. Client interpolation uses host poses relative to each cosmetic actor; the local cosmetic rigid-body solver yields to those poses, retaining host wobble rather than freezing the parts. No ignition command changes. Existing carry is retained only until data arrives / for older peers. 20261106-143225-vehicle-proxy-carsync passed attachment and local-angle-variation checks for all three; max distances 10.89, 0.11 and 104.10 uu respectively (key measured from car origin). Total 41/42, guest_car_follows still fails; all camera/cabin checks passed, no crash/PT error. This remains headless evidence; full regression and rendered validation not completed.
