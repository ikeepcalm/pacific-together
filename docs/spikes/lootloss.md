# lootloss: the guest misses whole lootables under lag (lane, base 1fc7442)

## Observations
- lootsync under `-Tunnel "udp lag=150 loss=2"` (local/test-results/20261120-211236-pair1-tunnel-lootsync): guest 36 vs host 40, the
  same four backpacks missing for 90 s, no `loot A refused`, no `could not make`, no `PT|error`.
- Diagnostics added on this lane (`PT|loot F: got A for N ids, M without entity`, plus temporary per-message in/out lines):
  20261120-212056-lootloss-tunnel-lootsync (failed): the guest's F line said it had A lines for only 240 of the host's ~350
  entities, 0 of them without an entity: the lines never reached `handle`.
  20261120-212255-lootloss-tunnel-lootsync (passed): the host sent 24 loot messages of the full list; all 24 arrived (same byte sizes) in
  `net.on("g.loot.b")` at 22:00.5-22:02.0; the guest handled lines until 22:01.9, then nothing; its `F` line never ran; the guest
  asked `H` again three times and got a second and third full list, and only the third completed.
- So: transport (reliable, ordered, chunked, windowed: msg.cpp, net.lua flow) was fine; lines were lost inside loot.lua's inbox.

## Derived
- Cause: the guest's inbox is a Lua table used as a queue. The worker did `inbox[head] = nil` per consumed line and tested
  `head > #inbox`. `#` on a table whose front is nil is not a border guarantee (binary search over the array part can land on a nil
  hole and return a small number). With lines arriving staggered (lag) while earlier ones are consumed, `#inbox` came out below
  `head`, the loop then believed the inbox was empty and ran `inbox, head = {}, 1`, discarding every queued line (typically
  the tail of a list, including F). Without lag a full list arrives in one burst before consumption, so it is rare
  (1 in 45 runs on the soak).
- Fix: explicit `tail` counter (push at tail, test `head > tail`). progression.lua's work queue had the same pattern: it no longer nils consumed slots.
- Recovery that already existed: the guest asks `H` again while no F came (the full list is re-sent); that is why runs eventually passed. It
  cannot help when F did arrive and the purge ran with a partial list (the guest then asks nothing more).
- Wire: unchanged (protocol 10 stays as is).

## Proof
See the end of this file (filled in after the runs).

## Guesses
- Other `# of a queue with nil front` sites may exist (grep `, head = nil` style: only loot.lua and progression.lua matched).

## Unknowns
- A host-side periodic checksum/resend was not added: with the inbox fixed no lost line was observed.

## Proof (pair C:\PTLanes\lootloss, port 7861, results in local/test-results)
- Before the fix: tunnel lootsync 1 of 2 runs failed on this pair (20261120-212056 failed, 212255 passed; the first soak: 1 in 45 without a tunnel).
  The mutation `inboxholes` restores the old `#inbox`: 4 of 5 tunnel runs failed (214126 38/40, 214656 31/40, 214933 38/40, 215314 33/40; 214254 passed).
- After the fix: tunnel lootsync 5 of 5 pass (212606, 212728, 212850, 213012, 213144), plain lootsync 3 of 3 (213302, 213434, 213559),
  session 1 of 1 (213851, 40/40).
- Mutation run 6 was stopped, not needed.
