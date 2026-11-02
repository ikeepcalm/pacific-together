# Message lifetime: first MultiVoid architecture adoption

November 2, 2026. Scope: the existing native message channel and its Lua map boundary. Wire bytes and protocol 5 are
unchanged. Both the Lua script and the rebuilt native DLL are needed together.

The adopted principle is explicit lifetime ownership: buffered state belongs to its current controller and world.
Reference: the pinned [MultiVoid comparison](../research/multivoid-applicability.md), especially its session serial and
world-load lifecycle discussion. This implementation uses Pacific Together's existing weak-object support and map hook;
no MultiVoid source code was copied.

## Before and after

`msg.cpp` previously kept partial messages in a process-wide map keyed only by controller address and kind. An address
reused after a disconnect could inherit the previous controller's unfinished prefix. Complete inbox messages also
carried a raw sender address. Lua cleared its own flow-control state on map load, while native inboxes, fragments and
outbound chunk queues remained separate from that reset.

Partials now live in the existing per-controller Link. Its FWeakObjectPtr identity already includes the engine object's
serial and resets on replacement. Completed inbox messages also carry weak sender identities; polling excludes
expired senders. A live controller remains eligible until UE invalidates its identity.

The Lua pre-map hook now clears the native inbox, links and their queues/fragments, alongside its existing controller
cache, flow window and ACK/readiness state. Handler receive timestamps are also reset. An old local buffer cannot be
interpreted as the new world's current state.

This does not add generation numbers to network packets or arbitrary gameplay callbacks. Delayed packets on a retained
connection and all per-object gameplay lifecycles are separate adoption steps. Non-seamless travel/reconnect remains the
supported model. The regular interpolation, authority rules and Steam/direct-IP transport are unchanged.

## Validation contract

`messageepoch` injects real RPC envelopes into the native capture path and loads the actual net.lua reset callbacks in
an isolated Lua environment. Checks: normal fragment assembly, old complete inbox removal, old prefix removal,
timestamp reset, repeated resets, and pending-message removal across a real menu-to-garage map load. Mutation `nomessageepoch` skips
the native reset and must fail the inbox/prefix checks. This isolates the lifetime boundary without requiring a DLC save.

The initial test fixture tried to destroy a temporary PlayerController through K2_DestroyActor. Live inspection showed
that the controller remained valid and IsActorBeingDestroyed was false, so expecting its messages to disappear was
incorrect. Those runs were not passing results. That fixture was replaced with a real world change. An attempted
extra destruction-state check and unsupported generated getter were removed; the final implementation uses the
existing engine weak-identity semantics.

## Completed checks

Supported executable SHA-256 was verified when preparing `D:/PTLanes/passenger`; runs used port 7823 and headless
test copies, without fixture saves or real-install changes. Native build: `tools/build-mod-fast.ps1 -MainBuild
C:/Dev/pacific-together/native/build`. DLL SHA-256:
`FCFBC4ED3E356BBA94D819498131B96883085B0296EC8B95924FAA52C39C0B54`.

| Check | Result | Folder under local/test-results |
|---|---|---|
| Native reassembly, lifecycle reset and real menu-to-garage travel | 14/14 | 20261102-145139-passenger-messageepoch |
| Native reset disabled | Expected failure, 12/14; old inbox and old prefix checks fail | 20261102-145242-passenger-messageepoch-nomessageepoch |
| Two-client ordered RPC, large message/echo, sender identity and oversize rejection | 21/21 | 20261102-145355-passenger-channel |

No new crash folders or PT errors in these completed runs. The user-visible benefit demonstrated here is that buffered
data from the previous world no longer survives the reset; this is not evidence of an FPS or latency gain. Reconnect
stress, lag/loss, a full two-person run and the full release suite remain unverified. No preview package was built.
