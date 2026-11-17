# Guest tutorial progress (lane tutorial, 2026-11-17)

Observations
- story.lua already reported guest-completed tasks of class HasItem_PlayerInventory / HasItem_HandSlot / InRangeOfTag (storyprog 26/26).
- Tutorial steps in Q00/Q01 missions (class names from the .uasset): RoutePlannerOpen (expedition tutorial), MechanicModeChanged / MechanicModeSlotsViewed (Q01_E2), CraftedItem, HasLogEntryBeenScanned, PlayerInCar, CarPartInstalled, TagIsSet.
- Guest RoutePlannerOpen: task needs RequireExpeditionOffersDisplayed (true) = BP_UIManager.RunOffersDisplayed, set by UMG_ExpeditionPlanner_Main. With the event fired and the flag set, K2_CheckCompletion is true on the guest but TaskStates.bCompleted stays false (guest does not tick it to done): results 20261117-103425.
Derived
- Fix: for the three UI-only classes the guest reports when its own K2_CheckCompletion is true; the host ForceCompleteTask. storytask 23/23 (20261117-103837), mutation nostorytask 22/23 (20261117-104121), storyprog 26/26, session 40/40.
Guesses / unknowns
- The scenario fires the task event and sets RunOffersDisplayed by hand; the real planner UI on a rendered guest was not tried.
- CraftedItem, PlayerInCar, scanned-entry tasks not examined (crafting is host-routed, logbook shared): not covered.
