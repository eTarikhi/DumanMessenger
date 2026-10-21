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

See `docs/03-smart-router-algorithm.md` for full pseudocode.

### Do / Don't
- DO re-evaluate every 30s, jitter OGM by ±200 ms to avoid sync
- DO log `electionEvents` for tuner
- DON'T elect leader or use Raft — fully decentralized
- DON'T force WiFi GO if already one nearby; sniff via `requestGroupInfo`

### Acceptance
- [ ] Simulator 20 nodes: SUPER ratio 15-25%, delivery ≥90% at 3 hops, overhead ≤70% of flood-all
- [ ] 10-phone field: atrium node elects SUPER, classroom corners stay NORMAL; no flapping >1 change/min
- [ ] Battery: SUPER opt-out respected; NORMAL never auto-promoted if battery saver on

