# Skill 08 — QA, Simulator & Field Testing

**Goal:** Prove mesh without needing 100 real phones every time.

### Simulator `mesh_sim.dart` — **delivered** at `sim/mesh_sim/`
- Virtual nodes with: position (x,y), mobility (random walk + waypoint clusters), battery curve, RSSI model `rssi = txPower - 20log10(d) - wallPenalty`
- Configurable: nodeCount 10-200, area 100×100m, walls, 0-30% super ratio target
- Metrics per run: deliveryRatio, overhead (relays/delivered), latencyP50/P95, superStability (elections/min)

**Implementation:** pure `dart:core` + `dart:math`, no Flutter dependency, so it runs headless in CI. Deterministic discrete-event simulation on a virtual millisecond clock — same seed ⇒ same run, byte for byte.

```bash
cd sim/mesh_sim && dart pub get && dart test
dart run bin/mesh_sim.dart --scenario campus_quad --seed 42 --json   # exits non-zero if acceptance fails
```

Scenarios: `campus_quad` (20 nodes — the acceptance case), `sparse_village` + `partitioned_pair` (store-carry-forward), `festival_crowd` (60 nodes, the W36 density target).

- **Mobility must be waypoint-based.** A pure random walk at 1.4 m/s moves a node ~250 m in a 225 s run: people leave their cluster and isolate themselves. Waypoints took `campus_quad` from 19/20 to 20/20 connected on every seed.
- **The A/B against naive flooding must replay an identical traffic plan.** Drawing pairs from the simulation's own RNG does not work — the 300 ms MPR wait changes event interleaving, so the two arms diverge into different experiments and report "overhead" of 119-155% (MPR apparently *worse* than flooding). Both engines pre-generate the pair list from a separate seeded generator.
- **Cross-language golden vectors** (`test-fixtures/golden-vectors.json`, `npm run golden`) pin the Dart engine to the TypeScript reference: RNG stream, spawn geometry and protocol counters must match exactly; float aggregates carry a tolerance for libm last-ULP differences.

### Lab Harness
- 6-10 real phones + RF-attenuated boxes to fake distance
- Test matrix: Android-Ancroid, Android-iOS, iOS-iOS; GMS vs no-GMS; battery saver on/off; permission deny flows

### Field Tests (roadmap phase gates)
- **W10:** Office floor (5 phones, 1 floor) → flood mesh
- **W16:** Campus quad (10 phones, indoor/outdoor) → super election tuning
- **W24:** Building walkie test (PTT across 3 floors via SUPERs on stairs)
- **W36:** Festival beta (50 users, 2h crowd) → target 90% delivery at 3 hops

### Do / Don't
- DO run simulator in CI (detects regression in coverage weights)
- DO record pcap-like mesh logs (msgId trace per hop) for post-mortem visualization
- DON'T claim large-scale results without real-world crowd test

### Acceptance
- [x] CI simulator: 20-node seed → delivery ≥90% <5 hops, overhead ↓30% vs naive flood
  - **Met on all six seeds** (42/7/1234/99/2026/555): delivery **98.7-100%**, ≥98% of sent messages within 5 hops, overhead **54-68%** of flood-all (i.e. a 32-46% reduction against the required 30%), p95 latency 1.0-4.7 s, ≤0.14 elections/node/min.
  - Read `delivery ≥90% <5 hops` as: ≥90% of *sent* messages arrive within five radio hops. Exclude ACKs and broadcasts, or control traffic inflates the ratio.
  - Excluded from the latency budget: retries (they add a whole ACK timeout) and DTN bundles (a store-carry-forward delivery measures a *meeting* time, not transport time). Assert the budget on first-attempt routed traffic.
- [ ] Lab: 5-phone 3-hop text <5s reproducible 10/10
- [ ] Field report template filled per phase with battery & delivery tables

