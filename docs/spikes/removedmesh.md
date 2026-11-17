# removedmesh lane (2026-11-17): visual `guest_removed_mesh_gone` flake

## Observations
- Removal path (visual.lua): the host's 5 s sweep builds the current line set, `sent` minus `cur` becomes a "D" message, the guest
  disposes `mine[key]`. Traced in 20261117-114842-removedmesh-visual: removal at 11:48:22.9, host `gone=2` at :27.7, guest disposed the
  copy at :27.74, check passed 4.1 s after the message. 9 normal visual runs today (11:46 to 12:42) all passed, 0 failures.
- The earlier failures (20261117-092102, -101356, -101648) show the copy still there for 30+ s, so not latency; those folders did not log
  which mesh was removed. In -101648 the host sent `gone=2` and the guest lost exactly one copy.
- The host picked `sma[1]` (smallest name, hex, random per run). The guest check is "a StaticMeshActor with this mesh within 30 uu".
  Measured in 20261117-122338: 180 of 980 plain static meshes (18 %) have a second actor with the same mesh within 30 uu.

## Derived
- A removed mesh that has such a twin keeps the check false after the right copy is gone: check flaw, not sync (visual.lua's D path
  disposed the copy in every traced run). Now the scenario removes a mesh with no twin, logs the twin ratio and the removed mesh.
- Worst-case removal latency is sweep (5.3 s) + rest (5 s) + sweep (5.3 s) + 0.5 s queue, about 10.5 s: the old 10 s window could fail by
  timing alone. Window now 15 s.
- Mutation `noremovesync` (guest ignores "D"): fails only `guest_removed_mesh_gone` (28/29, 20261117-123524-removedmesh-visual-noremovesync).

## Guesses / Unknowns
- 3 failures in 4 runs is more than an 18 % twin rate predicts (about 4 % by chance); not proven that twins caused those runs. If the
  check ever fails again the new log line `PT|info host removes <name> <mesh> twins=N` and the guest line
  `PT|visual host removed <key>: copy disposed|none` show which case it is.
