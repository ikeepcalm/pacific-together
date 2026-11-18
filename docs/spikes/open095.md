# open095: four items left open from 0.9.5 (lane open095, 2026-11-18)

## 1. Guest loot-tick crash (soak 2 runs 5 and 9)

Observations
- Both crashes are in the `runloop` scenario (zone -> garage cycles), not lootsync/sessiontravel: `local/test-results/20261117-154638-soak-runloop`
  (AV reading 0x40, 144 s after start) and `20261117-155909-soak-runloop` (AV reading 0x200000040, 106 s).
- Crash marker in both: `Last Lua started: loot.lua:1293` (the 500 ms tick), guest side. Same PCallStackHash in both.
- Last finished calls in both: `ItemContainer:GetSlot`, `ItemSlot:GetNumItems`, `ItemSlot:GetItems` on a slot, i.e. `ids.slotKey` inside `ids.layout`
  (scanChanges container branch). Crash 1: guest's own inventory container (trunk) after a trunk refill; crash 2: a crate in the streamed
  Rural_Forest_Radio_Scylla_02 level. The crash comes right after `GetItems` returns and before the next game call (`inst.Archetype` / `it:get()`).
- The soak ran before the tick breadcrumb (b2c7766), so the phase is not in the marker.

Derived
- The pointer in the slot's item array was garbage (0x200000000 + 0x40), so a slot or item was being torn down or still streaming in while Lua read it.
  `slot:IsValid()` does not exclude that.

Guesses
- Slots/items of a container in a level that is async-loading or being destroyed (trunk rebuild, zone teardown).

Change: `ids.layout(c, true)` (strict, state scan only) returns nil if the container or any slot is AsyncLoading/Unreachable/PendingKill;
`loot.stateOf` then returns nil and the container is read again at its next scan. Apply paths unchanged.
This is a hardening from the evidence above, NOT a proven root cause: the crash did not reproduce before the change either (runloop 1/1
pass on the old code, 20261118-090442). With the guard: runloop 4/4 (-0908, -0912, -0916, -1013), lootsync 34/34 x2 and 32/34 once
(39 of 40 lootables on the guest, the known under-load miss: actors, not container state), sessiontravel 54/54 x3, session 40/40.
Soak 2 saw 2 crashes in 9 runloops under 4-pair load; a clean soak on merged main is still the real proof. No mutation (cannot be made to fail
on demand). Repro to try if it returns: runloop under load, read the crash marker for `loot tick <phase>`.

## 2. mapmark

Observations
- Failing runs (20261117-171014, -173117): host_two_marks and three client checks fail; both ended in RB_Garage. In the failing client log
  `client_marks_host_near` needed 12-13 s instead of 1 s, and `own pos` z fell from 8000 to -25000 (guest teleported 50 m by the host onto terrain
  it has no collision for), then the game respawned it next to the host.
- Passing run (172817): the near check passed within ~2 s of `fly`.

Derived
- Cause is in the scenario: host and guest start their waits at different moments (join detection, load). The host moved the guest 50 m
  before the guest's own near check ran; the guest then fell, respawned beside the host, so the "far" HUD-shown checks (needs > 30 m) fail.
  The garage travel is the game's own return after the falls/time, not the mod.
- The nudge pad hook is not involved (be44283's guard is harmless).

Change: host waits for the guest's `t.near` message before moving it.

## 3. guestact charge-port jumper

Observation: in failing runs (20261117-172700, -155242, -142536) the guest log has no `PT|act send bat Internal.ChargePort` line (the first
`act send bat Attachments.BackSeatRight` is there). A debug line at batHook entry showed it ran once only (the first charge).
Derived: the scenario's `tool()` returned the first valid FindAllOf instance, the replaced charger that hold() removed but the GC had not
freed; a call on it never reaches the hook. The mod (hook, host g.act.bat) is right: the real held tool is hooked.
Change: `tool()` takes the last instance that is not pending kill. guestact 36/36 x3 (20261118-0937, -0939, -0943).

## 4. damagefeedback reused_payload

Observation: host logs two `anom damage for guest` 0.2 s apart in the failing step, the guest applies both: the native damage queue (damage.cpp)
counts every dispatch as its own hit ("Reused DOT payloads are separate hits"). The check accepted only one hit's loss (12 < loss < 23) and passed
only when polled between the two deliveries.
Change: the check expects two hits (25 < loss < 40) and holds it.
