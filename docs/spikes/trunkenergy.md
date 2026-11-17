# trunkenergy lane (2026-11-17)

## Observations
- trunktravel unfixed (20261117-090935): after the host's Tier 2 upgrade the guest trunk ended 4 slots / 23 items vs host 9 / 47 (the
  guest's part swap rebuilt the container, `SetNewInventoryTrunk` via `OBJ_Trunk_Storage_Tier2_UpgradeLogic.OnInstall`, under a fill in
  flight: this is the old "Tier2 spill"); after TravelToNextLeg the guest's `Inventory_Trunk` was nil for the whole zone (the part sits in
  its slot, nothing runs OnInstall again). Matches finding 11.
- exitdeposit with the exit deposit mutated off (20261117-092556): an anchor item in the host's anchor inventory is banked by the game's own
  TravelToGarage(2) return (Unstable 10500 -> 10630); no mod call needed. Guest-fed anchors (g.act.anchor) only ran the Gobbler's charge
  logic, so no item existed to bank (20261117-093020 noanchorbank: anchors=0, energy unchanged).
- anchordup on 8efa25e: 23/23 (20261117-085914), host anchor removal still works.

## Derived
- Normal gateway return banks energy natively (probably in the native Rinse/save path; no Blueprint caller found in the atlas). Finding 5 is
  most likely the guest-fed anchors, not the setpiece exit itself.

## Guesses
- Friend's 0 energy could also be a host-side cause we did not exercise (host-fed anchors on a real setpiece exit were not run).

## Unknowns
- Tier 1 trunk on a fresh map for the guest (only Tier 2/3 handled; Tier 1 has no upgrade call).
- Setpiece `BP_LevelTransition_Custom` exit not run here (same TravelToGarage(2) call).
