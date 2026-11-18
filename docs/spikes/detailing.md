# Detailing station and tinker hints (PLAN G2 gaps, lane detailing, 2026-11-18)

Code: `guestswap.lua` (Detailing: `ItemSlot:SwapSlotContents` hook), `stations.lua` (hints: `g.st.hint` / `g.st.hints`). Scenario `detailing`
(`-Fixture garage`), mutations `nodetailing`, `nohints`. Earlier design: [PT2-stations.md](PT2-stations.md).

## Observations

- Cosmetics are ordinary car parts: items in the car's equipped container, slots `Car.Equip.Cosmetics.*` (LicensePlate, Shifter, SteeringWheel,
  Mirror, Bobblehead, Sticker.L/R, HoodOrnament, Antenna). The station widget's `EquipSlot` is `CarSlot.SwapSlotContents(StationSlot)`.
  car.lua already mirrors every equipped slot host -> guest (`P` lines, archetype path), so the guest's car shows a cosmetic once the host's slot has it.
- `ItemSlot:SwapSlotContents` is native: a hook with one callback runs BEFORE the swap (the first run sent "-" for the slot); register `(function() end, post)`.
- Swapping two slots whose item types do not fit (plate into the ornament slot) is refused by the game and changes nothing.
- The garage fixture has `BP_Garage_CosmeticsStation_C` with a one-slot `ItemListSlot` container; `SetItem` on that slot hung the game (probe), so the scenario
  swaps from a pack slot (same native call).
- Currencies: `CA_AnchorJuice_*` live under `/Game/Systems/Spawning/Anchors/`, table values are hundredths (`CurrencyAdjust(ca, -0.5)` = -50).
  Hint cost = `ConsecutiveHintsBought + 0.5` anchors (free if `GetFreeHints`). The first hint costs 50 table units.
- Hint reveal state is `PartKnownCategories` / `TypeKnownCategories` (enum -> bool maps) on the quirk's condition and behavior elements, plus `ConsecutiveHintsBought`
  on the status effect manager. `RevealHint` sets the known flags, then `CurrencyAdjust`, then `IncrementHintsBought`.

## Derived

- Before: a guest's diagnose changed only its local currency table (stations.lua's host table broadcast overwrote it within 10 s): the hint was free for the host
  and the reveal stayed on the guest.
- Now: the guest's `IncrementHintsBought` post-hook sends its known flags (`g.st.hint`); the host ORs them in, pays `GetHintCost` once from its own table and counts
  the hint; the host's flags and count come down (`g.st.hints`, every change and 6 s) and the guest ORs/takes them, so both quote the same cost.
- Detailing: the guest's swap hook sends the car slot's new content as the existing `g.swap.set`; the host installs it (`guestswap.lua`), car.lua shows it back.
  The displaced cosmetic stays in the guest's own station container/pack (cosmetics are per-player stock in the station, not shared storage).

## Guesses

- The real station UI (EquipSlot button) ends in the same native swap the scenario calls; not driven with rendered input.
- Other known flags (condition/behavior "part" categories) merge the same way as the type flag the scenario uses.

## Unknowns / not done

- Unique cosmetics deposited into the station (`DepositItem`) and paint/decal tools are not mirrored beyond the car slot swap.
- A cosmetic taken off the car by the guest goes into the guest's station container; the host's station is not told.
- The logbook/journal entry of a diagnosed quirk is not mirrored.
