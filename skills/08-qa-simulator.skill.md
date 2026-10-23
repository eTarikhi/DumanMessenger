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
dart run bin/mesh_sim.dart --sos                # SOS reach probe: component-relative and raw
dart run bin/mesh_sim.dart --trace              # per-delivery route: dBm, action, reason per hop
dart run bin/mesh_sim.dart --capture            # pcap-like mesh log tail (--capture-ogm adds beacons)
```

Scenarios: `campus_quad` (20 nodes — the acceptance case), `sparse_village` + `partitioned_pair` (store-carry-forward), `festival_crowd` (60 nodes, the W36 density target).

- **Mobility must be waypoint-based.** A pure random walk at 1.4 m/s moves a node ~250 m in a 225 s run: people leave their cluster and isolate themselves. Waypoints took `campus_quad` from 19/20 to 20/20 connected on every seed.
- **The A/B against naive flooding must replay an identical traffic plan.** Drawing pairs from the simulation's own RNG does not work — the 300 ms MPR wait changes event interleaving, so the two arms diverge into different experiments and report "overhead" of 119-155% (MPR apparently *worse* than flooding). Both engines pre-generate the pair list from a separate seeded generator.
- **A baseline must not share the mechanism under test.** `flood-all` used to consult the route table. That was invisible while routing was broken and misleading the moment it worked: the campus overhead ratio jumped to 71-78% because the *baseline* had improved, not because the engine regressed. Three arms now run per configuration — `mpr` (ships), `route-flood` (routing, suppression off) and `flood-all` (naive epidemic: no routes, no suppression) — selectable with `--policy`, so "vs naive flood" and "what suppression is still worth" are separate numbers.
- **Judge suppression against the arm that differs by suppression only.** Naive epidemic flooding does reach 100% delivery in the 60-node crowd — by spending 7-9× the relays — so "within 5 points of flood-all" demands epidemic redundancy instead of testing MPR. Compare on the **mean across seeds**: 150 messages through a chaotic 60-node world carries several points of run-to-run variance that a per-seed bound mistakes for a regression.
- **tq is a link metric: keep its window per (originator, neighbour) pair.** Keyed on the route entry, a duplicate beacon arriving over a longer path resets the window and tq collapses to 0. Measured 0.107 for direct neighbours whose real receipt rate was ~0.8, so the `tq > 0.6` route gate rejected nearly everything and the network flooded blindly. Per-pair windows took usable routes from 29.7% → **86.8%** (quad) and 46.6% → **91.8%** (crowd). See `docs/06-simulator-findings.md` §6.
- **Run the whole documented node range, not just the acceptance size.** `nodeCount 10-200` is in this file's own spec, and the first 200-node run found a cliff that no 20- or 60-node run could: at 200 nodes in a 100×100 m area every node hears ~179 of the other 199, a beacon advertises at most 30 of them, so the MPR coverage test can only answer "no" and every relay fell back to flooding *all* peers — one 3-hop delivery cost 7 038 transmissions. Bounding that fallback to six direction-spread peers cut the range's worst case 76% (531 → 125 tx/message) and 86% at 100 nodes, at a cost of one message in 60 at the very top of the range. Inert below 30 peers, so the 20- and 60-node evidence is untouched and the golden vectors are byte-identical. `docs/06-simulator-findings.md` §15.
- **A density result needs its caveats printed next to it.** The simulator has no collision model, and its `ogmTx` counter records one entry per *receiving* peer, so control traffic reads as O(N²) when a real advertising beacon is one transmission heard by many. Neither invalidates the protocol comparison — both arms share the model — but both mean the 200-node figures bound the protocol, not a deployment.
- **Cross-language golden vectors** (`test-fixtures/golden-vectors.json`, `npm run golden`) pin the Dart engine to the TypeScript reference: RNG stream, spawn geometry and protocol counters must match exactly; float aggregates carry a tolerance for libm last-ULP differences.
- **A behaviour change that alters the transmission count invalidates the goldens, and that is correct.** Every transmission draws from the RNG for its loss roll, so removing one rearranges the whole run. Regenerate and check the run is deterministic; do not hand-patch the fixture. Adding a *field*, a log entry or a hop record consumes no RNG and must leave the fixture byte-identical — assert that, it is the cheapest possible proof that instrumentation is inert.
- **Instrument the reach of a broadcast against the sender's radio-connected component.** Raw reach in `sparse_village` is 27% and in `partitioned_pair` 44%, and no protocol choice moves either: 8 of 11 and 5 of 9 online nodes have no chain of links to the sender. Report both numbers or the criterion is untestable. See `docs/06-simulator-findings.md` §11.3.
- **A render test on the UI finds engine defects.** Rendering the SOS card with `react-dom/server` against real simulation state reported "20 of 19 online nodes heard" — an impossible denominator that traced to every node accepting and re-flooding copies of its *own* message returned by peers. No engine test would have caught it, because every engine assertion was consistent with the bug. Fixing it cut relay transmissions 18.3% in the warm 20-node world (§12).
- **When a ratio test breaks after a correctness fix, ask which arm the defect was inflating.** `mpr / route-flood ≤ 0.85` measured 0.947 once the originator stopped re-flooding: `route-flood` floods most, so it was the arm most inflated by the amplifier (−37% transmissions on that seed vs MPR's −4%). Part of the measured advantage was the defect. Re-pin such ratios on the **mean across seeds** and keep a hard per-seed invariant that cannot be gamed ("never worse than the arm without the mechanism").

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
  - **Met on all six seeds** (42/7/1234/99/2026/555): delivery **97.3-100%**, **97.3-100%** of sent messages within 5 hops, overhead **7-9%** of naive flood (a 91-93% reduction against the required 30%), p95 latency 1.1-4.5 s, ≤0.22 elections/node/min.
  - Read `delivery ≥90% <5 hops` as: ≥90% of *sent* messages arrive within five radio hops. Exclude ACKs and broadcasts, or control traffic inflates the ratio.
  - Excluded from the latency budget: retries (they add a whole ACK timeout) and DTN bundles (a store-carry-forward delivery measures a *meeting* time, not transport time). Assert the budget on first-attempt routed traffic.
  - **These gates assume a radio with no channel.** The simulator's default `channelAccess: "free"` lets two transmissions occupy the air at once, so nothing competes for the medium — which is what makes the overhead figure as low as 7-9%. With one real radio per device (`channelAccess: "halfDuplex"`, a bounded transmit queue that drops at the tail) the same 20-node campus measures delivery **95.6%** and overhead **38.6%** of flood-all: both gates still pass, but the margin is not the same network's, because flood-all is slowed by the radio too and MPR's advantage shrinks when air time rather than packet count is scarce. It ships off so the gates keep measuring what they were written against; `docs/08-media-transport-ptt.md` §12 has the A/B and the two defects an unbounded or unwoken queue produces.
  - **And the margin disappears once a receiver is modelled too.** `channelCapture: "first"` makes a busy receiver lose the second of two packets and a transmitting node hear nothing — the two things a real radio does that an infinitely attentive one does not. On the same 20-node campus over three seeds, delivery measures **0.9056** with collisions and no transmit queue, and **0.9000** with both: the ≥90% gate is met with nothing to spare, while overhead (15.8% and 27.1%) and the SUPER ratio stay comfortably inside their bands. So delivery is the binding criterion and contention is what binds it, which makes delivery ratio the first thing a field test should measure and the last thing to claim headroom on (`docs/08` §12.9). Adding what real link layers actually do — carrier sense, `channelAccess: "csma"` — makes both gates *fail* rather than pass: delivery **0.7222-0.7889** and overhead **77-81%** of flood-all, because listening converts collisions into queueing and this engine's retry timers convert queueing into load. The overhead figure also stops meaning what it meant: flood-all's packets are shed at the queue tail before they are counted, so the ratio's denominator shrinks. Read §12.10 before quoting any of these numbers; the shipped model is the one the box was met under.
- [ ] Lab: 5-phone 3-hop text <5s reproducible 10/10
- [ ] Field report template filled per phase with battery & delivery tables

