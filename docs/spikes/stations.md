# Lane stations (0.9.5): world stations and the acid thrower (friend playtest 2026-11-15, NOTES item 8/13)

## Observations
- BP_WorldStation_FriendlyDumpster_C (atlas bp/BP_WorldStation_FriendlyDumpster.txt) is the world "Lucky Junk Heap": level-placed, not replicated,
  destroys itself in BeginPlay unless QD_Q01_Objective is complete or the world settings have bIsTestLevel. `Highlight` bound event 0
  (`BndEvt__Highlight_K2Node_ComponentBoundEvent_0_OnHighlightInteract__DelegateSignature`) is the prize action: Uses+1, loot table roll
  (DTR_LuckHeap_WorldStation_Table, per side RNG), ItemDispenser puts world items out. Live (zone fixture, bIsTestLevel on): host call -> Uses 1, 9+ world
  items, the guest's BP_WorldItem count followed (loot.lua).
- It consumes nothing from the player (no input items): "items consumed" in the finding was a guess. The message `%d item{s} put into dumpster 03` is
  loot.lua's container overlay for a BP_Lootable_Dumpster, and only its quiet-feed LOG line was unformatted (overlay.lua logged the raw template);
  the on-screen feed formats it.
- BP_Hazard_AcidLobb_C and BP_Hazard_AcidGlob_C both derive BP_Base_Hazard_C (world.lua REPLICATED covers them, 1 s sweep).
- BP_Boon_Frame_Shelter_Health_C > BP_Boon_Shelter_Base_C > BP_Base_Boon_Structure_C > BP_Base_Boon_C (Actor): HealingPowerRemaining, ActivateShelterOverlap box,
  no OutOfJuice. Battery shelters (_Battery, _T2, _T2_PitStop) not probed.

## Derived
- The glob was only ever replicated by the 1 s sweep: fixed by replicating it in its own ReceiveBeginPlay on the host (world.lua hookGlob).
- The shelter list is BOONS with a `sphere`/`nojuice` variant; the guest's placed copy is destroyed like the Healer's, the host's copy is passive on the guest.
- Heap: guest E on the heap highlight sends g.st.dump (x,y,z), host runs event 0 if allowed and within 600 uu; the guest's copy has event 0 muted (PTNative_Mute)
  and gets allow/uses from the host once a second.

## Guesses / Unknowns
- "Repair machine" being the Health shelter is a guess (it repairs the car); the coral reef class is still unknown (no live find at the spot).
- The Battery shelters are not covered. The heap has no lid/charge animation on the guest, and the 0.5 s hold is skipped (press = use).
- Not run by hand: E on the heap with a rendered guest.
