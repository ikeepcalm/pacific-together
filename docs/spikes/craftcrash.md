# craftcrash: guest AV 0x100 in the backpack crafting tab after a death respawn (2026-11-17, not reproduced)

## Observations
- Crash marker (friend session 2026-11-15, mod 0.9.3.2, guest): game-thread stack CraftButton OnButtonClicked -> RecipeInfo TimerFinished
  -> RecipeList OnCraftButtonFinished; last finished calls are ~10 pairs of CR_NoSpecialItems K2_AllowTransferOutOf / AllowTransferInto.
  Source: local/playtest-20261115-friend/b/crashes/UE4CC-Windows-8417ECA343CFFE776869FFAB79D8005A_0000/PacificTogether-crash.txt. No minidump.
- Headless widgets exist (UMG_PlayerMenu_Main, RecipeList x2, RecipeInfo x4, CraftButton x3), so the real UI path can be driven:
  RecipeInfo:SetRecipe(asset) then CraftButton:Craft() -> TimerFinished -> RecipeList -> manager "Craft Recipe Asset".
- scenario `craftcrash` (zone fixture, headless, guest): craft through that UI path, die (PlayerHealth:Adjust, backpack emptied by the
  death handling), respawn, wait 30 s, craft again with (garage,car) = (false,false) as the backpack menu sets it, then with (true,true),
  then once more. All succeed, no crash, 21/21 (20261117-110213-craftcrash-craftcrash). Manager containers (Inventory_Player, PlayerHand,
  OverflowContainer, ActiveStations) keep the same objects across the respawn (same ItemContainer ids before/after).

## Derived
- The backpack menu crafts with IncludeGarage=false IncludeCar=false (BP_MainCharacterManager builds ST_PlayerMenuParams with false), so
  inputs are the hand, the player inventory, ActiveStations and the overflow container; the CR_NoSpecialItems loop is the native transfer.
- A null deref at +0x100 inside the native CraftRecipe means one container/slot in that list was null or freed at that moment.

## Guesses
- Something in 0.9.3.2 that no longer exists (death crate / backpack sync code of that version) left a freed container or item in the
  transfer list; main now (0.9.4.1) does not show it in a same-conditions headless run.
- Rendered-only state: the menu was open (real Slate focus, hold-to-craft timer over frames) and the real death had the death bag/crate
  near; headless fires Craft() directly.

## Unknowns
- Whether the crash still happens on 0.9.4.1 in a rendered session. Next hand test: die in a zone, respawn, open backpack, craft, repeat
  within 30 s, with and without a car nearby; keep the crash folder if it recurs (a minidump would show the null owner).
