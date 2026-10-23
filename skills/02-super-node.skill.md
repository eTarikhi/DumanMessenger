# Skill 02 — Smart Router / Super-Node Engine (Duman Adaptive Routing)

**Goal:** Auto-select coverage-optimal routers to minimize overhead while maximizing reach.

### Inputs (per 30s tick)
- `peerCount`, `avgRssi`, `batteryLevel`, `uptimeMin`, `mobility` (accel variance), `pdr` (delivery ratio)
- `neighborScores` from OGMs (expires 30s)

### Output
- `Role {SUPER, NORMAL}` + `reasonTrace` for UI (“promoted: 12 peers, -45 dBm avg, 78% battery”)
- OGM packet broadcast via all transports

### Algorithm
- `coverageScore = 0.30*norm(peerCount) + 0.25*normRssi + 0.20*battery + 0.15*stability + 0.10*pdr + bonusCharging`
- Eligibility: battery ≥25%, ≥3 peers
- Election: self rank in top 20% of 2-hop neighborhood + score>0.60 → SUPER; demote if <0.50 ×2 cycles (hysteresis)
- Proximity guard: suppress SUPER within ~30m / RSSI>-60 if another SUPER 0.1 score higher
  - ⚠ derive the threshold from tx power (`tx − 20·log10(30)`), don't hard-code −60 dBm: at the calibrated −55 dBm that means 3 m and the guard never fires. See `docs/03` §5 note.

See `docs/03-smart-router-algorithm.md` for full pseudocode.

### Do / Don't
- DO re-evaluate every 30s, jitter OGM by ±200 ms to avoid sync
- DO log `electionEvents` for tuner
- DON'T elect leader or use Raft — fully decentralized
- DON'T force WiFi GO if already one nearby; sniff via `requestGroupInfo`

### Acceptance
- [x] Simulator 20 nodes: SUPER ratio 15-25%, delivery ≥90% at 3 hops, overhead ≤70% of flood-all
  - **Met** (`campus_quad`, 150 msgs, seeds 42/7/1234/99/2026/555): SUPER **20-25%**, delivery **97.3-100%**, **97.3-100%** of sent messages within 5 hops at 1.8-2.0 average hops, **7-9%** of the naive flood-all relay budget (59-78% of routing-without-suppression), ≤0.22 role changes/node/min. Enforced by `src/__tests__/acceptance.test.ts` and `sim/mesh_sim/test/acceptance_test.dart` in CI. Evidence and the three A/B arms: `docs/06-simulator-findings.md` §2.
  - Pitfalls that decide this metric: rank over `self + 1-hop` (§4, not §3's 2-hop); boot nodes with realistic `uptimeMin` or the stability term never saturates; spawn by waypoint cluster, not uniformly.
  - **The delivery margin is a property of the radio model, not of the election.** All three criteria were calibrated with `channelAccess: "free"` and `channelCapture: "none"` — no shared medium and a receiver that takes everything, however busy. Give the device one radio and a realistic receiver and the same campus measures delivery **0.9000** against this box's ≥90%, with overhead 27.1% of flood-all (≤70% ✓) and the SUPER ratio inside 15-25% ✓. Two of the three criteria keep their margin; delivery does not, and it is the one this skill's election work is usually blamed for (`docs/08-media-transport-ptt.md` §12.9). With carrier sense added as well — what BLE and Wi-Fi actually do — delivery measures 0.7222-0.7889 and overhead 77-81%, so both of this box's radio criteria fail and the SUPER ratio is the only one that holds (§12.10).
- [ ] 10-phone field: atrium node elects SUPER, classroom corners stay NORMAL; no flapping >1 change/min
- [x] Battery: SUPER opt-out respected; NORMAL never auto-promoted if battery saver on
  - **Met in simulation** (both engines): `electRole` gates on `superOptOut` and `batterySaver` before the peer/battery checks and demotes at once, clearing `demoteCounter` — the two-cycle hysteresis above damps *score* noise, and a user toggle is not noise. The declination is advertised as `declinedRouter` in the OGM so peers drop it from the top-20% candidacy ranking; without that, declining a third of a 20-node mesh left **2 SUPERs (ratio 0.10)** instead of **4 (0.20)**. Both switches are user-visible in the simulator's node inspector. Tests: `src/__tests__/engine.test.ts`, `src/__tests__/simulation.test.ts`, `sim/mesh_sim/test/engine_test.dart`. Evidence: `docs/06-simulator-findings.md` §10.1-10.2.
  - Still Phase 3 on device: reading the real OS state (`PowerManager.isPowerSaveMode`, iOS Low Power Mode) and persisting the opt-out across restarts.

