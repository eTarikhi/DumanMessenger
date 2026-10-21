# Skill 08 — QA, Simulator & Field Testing

**Goal:** Prove mesh without needing 100 real phones every time.

### Simulator `mesh_sim.dart`
- Virtual nodes with: position (x,y), mobility (random walk + waypoint clusters), battery curve, RSSI model `rssi = txPower - 20log10(d) - wallPenalty`
- Configurable: nodeCount 10-200, area 100×100m, walls, 0-30% super ratio target
- Metrics per run: deliveryRatio, overhead (relays/delivered), latencyP50/P95, superStability (elections/min)

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
- [ ] CI simulator: 20-node seed → delivery ≥90% <5 hops, overhead ↓30% vs naive flood
- [ ] Lab: 5-phone 3-hop text <5s reproducible 10/10
- [ ] Field report template filled per phase with battery & delivery tables

