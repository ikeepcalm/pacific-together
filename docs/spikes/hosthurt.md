# hosthurt: the host's health after a guest death (2026-11-18)

Report from `20261118-114030-pair1-anomtable`: after a guest death and revive the host's health fell 100 -> 28 -> dead in
the next cloud row, every later row failed.

## Observations
- Guest dies from leech bites (11:01:39), `health.lua` revives it at 11:01:42 and the host's `g.health.respawn` puts it
  beside `BP_PlayerCarNew_C` ("health respawn guest next to BP_PlayerCarNew_C"). The scenario checked "host far from guest"
  once, at the start, so every later row was spawned at the guest's feet next to the host.
- hosthurt run `20261118-120750` (guest left beside the car, cloud at its feet): host 100 -> 1, guest forwarded 56 hits "for host"
  (client log, `owner=PDP_MainCharacter_C`, the host's body in the guest's world), each right after the guest applied the
  host's `g.anom.msg` (1-12 ms later); host log "anom damage applied ... hit you" for each.
- Same death, guest taken 7000 uu away again before the cloud (`20261118-115921`, `20261118-120535`): host stays at 100, no
  forwards. Death alone does not drain the host.
- Host loss with the forwards (mutation `hostdrain`, `20261118-122621`): 60 in 6 s; without them (`20261118-122114`): 62.
  The forwarded copies did not measurably add to the host's health loss (the host hook counted 0 forwarded acid hits at the
  receiver); the loss is the host's own cloud damage.

## Derived
- The drain in the anomtable run was mostly legitimate: the host stood in the same cloud as the respawned guest.
- There was also a real echo: with both players in a cloud the guest's copy of the hit lands on the host's body in its world
  and was forwarded ("for host"), 25-56 messages per cloud. Hazard damage on the host's body is dealt by the host's own game;
  only player-caused hits (guest melee) belong in the forward.

## Fix
- `anomalies.lua` `pre` (guest branch): Acid, Radiation, Electrical and FallDamage hits on the host's body are not forwarded
  (Physical_Impact already was). Mutation `hostdrain` forwards them again.
- `anomtable`: the guest is taken back to its far spot before every row; `t.heal` uses `Adjust` (Fill did not refill).
- New scenario `hosthurt` (check `host_not_drained_after_guest_death`: both in one cloud, the host's log shows no forwarded
  acid hit; read from the UE4SS log after a mark because the test mod cannot see the main mod's counters).

## Guesses
- Spillover on the cloud's message (Spillover=1) sends the hit on to the neighbouring body; not confirmed.

## Unknowns
- Why the forwarded acid hits did not register at the host's receiver hook, and whether other hazard classes (Impact clouds,
  explosions) echo the same way. `Damage_Physical` (melee) stays forwarded, so a Devil Grinder style cloud (Physical_Impact) is
  unchanged.
- `health.lua` death detection took up to 80 s in one hosthurt run (`20261118-122348`) with the guest held at its minimum;
  not investigated (scenario timeout raised to 150 s).
