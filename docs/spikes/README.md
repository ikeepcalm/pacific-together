# Experiment reports

These are dated experiments, implementation notes and test evidence, not the current backlog. A pass proves only the
checks and revision recorded. Preserve failures, mutations and unknowns when condensing a report.
Current behavior: [../../README.md](../../README.md). Current evidence/gaps: [../../NOTES.md](../../NOTES.md).

Latest bounded anomaly continuation: [W8-boons](W8-boons.md) (Healer/Charging visibility and resource state, November 1).

Client feedback, passenger controls and loose-item physics: [PT4-client-interactions](PT4-client-interactions.md).

## Reading order

| Area | Earlier evidence | Later implementation/fixes |
|---|---|---|
| Session/saves | [M2-session](M2-session.md), [M2-safety](M2-safety.md) | October 24 travel, ready gate and key-thread fixes in NOTES |
| Steam | [X5](X5.md), [X6](X6.md) | [PT2-steam](PT2-steam.md); October 23 two-account play in NOTES |
| Car/seat | [X7](X7.md), [X8](X8.md), [M3-car](M3-car.md) | [PT1-car](PT1-car.md), [PT1-pt3-spawn](PT1-pt3-spawn.md), [PT3-seat](PT3-seat.md); latest collision/re-entry fixes in NOTES |
| Guest car actions | [M3-guestact](M3-guestact.md) | [PT1-parts](PT1-parts.md), [PT1-swap](PT1-swap.md), [PT1-feel](PT1-feel.md), [PT2-upgrades](PT2-upgrades.md) |
| Loot/backpack | [X2](X2.md), [X4](X4.md), [X12](X12.md), [M4-loot](M4-loot.md) | [M4-loot2](M4-loot2.md), [M4-backpack](M4-backpack.md), [PT1-loot](PT1-loot.md) |
| Health/hazards | [M4-player](M4-player.md), [M5-anomalies](M5-anomalies.md), [M5-anomalies2](M5-anomalies2.md) | [PT1-anom3](PT1-anom3.md), [PT3-anom](PT3-anom.md), [PT3-hazard](PT3-hazard.md) |
| Run/world | [M5-world](M5-world.md), [PT1-runloop](PT1-runloop.md) | [PT1-portal](PT1-portal.md), [PT2-visual](PT2-visual.md), [PT3-world](PT3-world.md) |
| Progression/story/garage | [M5-progression](M5-progression.md), [M5-story](M5-story.md), [PT1-garage](PT1-garage.md) | [PT2-story](PT2-story.md), [PT2-stations](PT2-stations.md); player upgrades/door propagation in NOTES |
| UI/appearance | [M6-overlay](M6-overlay.md), [PT2-hands](PT2-hands.md), [PT2-map](PT2-map.md), [PT2-ping](PT2-ping.md) | [PT3-look](PT3-look.md), [PT3-ui](PT3-ui.md), [PT3-pause](PT3-pause.md) |
| Performance/input proof | [M6-playpath](M6-playpath.md), [PT1-pt1-crash](PT1-pt1-crash.md) | [PT3-perf](PT3-perf.md); current input/thread fixes in NOTES |

Important supersessions: zone props are enabled; flat tyres and guest radiation are synchronized; Steam traffic is
verified between two accounts; the ARC is behind the seats; host Esc is the shared pause; body rendering uses the
survivor model. Earlier reports describing these as absent or future work remain historical evidence.
