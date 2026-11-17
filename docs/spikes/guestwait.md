# guestwait (2026-11-17): car-seat intents do not wait for the zone-join baseline

Observations: a guest's protected intents were held until every baseline part (loot, car, visual) was done and the host had applied
g.net.baseline: 29.7-30 s after the first zone join, 65-88 s after a second join in zoneexit (321 messages queued, headless).
Run 20261117-103151: exit intent sent at seat-after-travel waited the whole time.
Derived/changed: net.lua `carSeat(kind)` (g.car.enter/exit/door) skips the guest hold once the car baseline part is done and the host
gate once the guest is `ready`. Exit now lands 1.0 s after sitting (20261117-111358-guestwait-zoneexit 37/37); mutation carintentwait
restores the old gating (20261117-110723-...-carintentwait: guest_exits_before_baseline FAIL).
Unknowns: the other baseline parts are not sped up (loot lists dominate); g.car.ctl/drive still wait. zoneexit re-entry through the DRIVER door
after a real passenger-door exit never pressed (allow=false candidates), also with the old gating; the scenario now re-enters via the passenger door.
visual guest_removed_mesh_gone: not looked at.
