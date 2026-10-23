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
  - **The delivery margin is a property of the radio model, not of the election.** All three criteria were calibrated with `channelAccess: "free"` and `channelCapture: "none"` — no shared medium and a receiver that takes everything, however busy. Give the device one radio and a realistic receiver and the same campus measures delivery **0.8556** against this box's ≥90% — the gate fails — with overhead 25.5% of flood-all (≤70% ✓) and the SUPER ratio inside 15-25% ✓. Two of the three criteria keep their margin; delivery does not, and it is the one this skill's election work is usually blamed for (`docs/08-media-transport-ptt.md` §12.9). With carrier sense added as well — what BLE and Wi-Fi actually do — delivery measures 0.7389-0.7944 and overhead 78-80%, so both of this box's radio criteria fail and the SUPER ratio is the only one that holds (§12.10). Adding the contention window carrier sense was missing (`channelBackoff: "binary"`: a random wait, doubled after each collision) does not recover them — ±1.1 points, still ~14 short — because under carrier sense the losses are **queue drops, not collisions**, roughly eight to one, and a wider window makes nodes wait longer into the queue that is shedding them (§12.13). Flow control *above* the radio was built for exactly that reason and is a trade rather than a rescue: `mediaBackpressure` buys **+1.7** points under carrier sense and loses **-2.8** under plain half-duplex, and neither arm reaches ≥0.90 (§12.12). What makes that interpretable is attribution rather than the A/B — with a file in flight **82-85% of the shed packets are dropped by the node that originated them**, and an equal-cost alternative next hop existed for only **3-9%** of the relays' sheds, so neither throttling a source nor rerouting round congestion closes the remaining gap (§12.14). No radio-layer lever in this engine has met the delivery box except the two that ship, and the first lever aimed above the radio does not either.
- [ ] 10-phone field: atrium node elects SUPER, classroom corners stay NORMAL; no flapping >1 change/min
- [x] Battery: SUPER opt-out respected; NORMAL never auto-promoted if battery saver on
  - **Met in simulation** (both engines): `electRole` gates on `superOptOut` and `batterySaver` before the peer/battery checks and demotes at once, clearing `demoteCounter` — the two-cycle hysteresis above damps *score* noise, and a user toggle is not noise. The declination is advertised as `declinedRouter` in the OGM so peers drop it from the top-20% candidacy ranking; without that, declining a third of a 20-node mesh left **2 SUPERs (ratio 0.10)** instead of **4 (0.20)**. Both switches are user-visible in the simulator's node inspector. Tests: `src/__tests__/engine.test.ts`, `src/__tests__/simulation.test.ts`, `sim/mesh_sim/test/engine_test.dart`. Evidence: `docs/06-simulator-findings.md` §10.1-10.2.
  - Still Phase 3 on device: reading the real OS state (`PowerManager.isPowerSaveMode`, iOS Low Power Mode) and persisting the opt-out across restarts.

