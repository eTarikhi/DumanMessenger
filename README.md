# Duman Messenger — Serverless Offline Messenger
### Bluetooth + Wi-Fi Direct / Wi-Fi Aware Mesh | No Internet, No Cellular Required

> **Vision:** A pager & walkie-talkie for the disconnected world. People within short distance can message and call directly via Bluetooth/WiFi, and the network self-organizes to extend range through smart router nodes.

**Package contents:**
- `docs/01-feasibility-analysis.md` — Possibilities & problems (deep research)
- `docs/02-technical-architecture.md` — Evaluated stacks & selected approach
- `docs/03-smart-router-algorithm.md` — Coverage-based super-node election (Duman Adaptive Routing)
- `docs/04-security-privacy.md` — Threat model & E2EE without servers
- `docs/05-comprehensive-feasibility-study.md` — Full feasibility study: constraint analysis, protocol/framework comparison, architecture, phased roadmap & talent matrix
- `roadmap/roadmap.md` — Phase-by-phase delivery plan (12 months, MVP → Scale)
- `roadmap/index.html` — Interactive visual roadmap (open in browser)
- `skills/` — 8 development skill definitions for the build team
- `docs/06-simulator-findings.md` — Simulator calibration evidence, protocol corrections & the one documented limitation
- `sim/mesh_sim/` — **Dart mesh simulator** (authoritative headless engine + CLI)
- `src/` — **TypeScript mesh simulator** (reference engine + React visualiser)
- `test-fixtures/golden-vectors.json` — cross-language determinism contract asserted by both engines

**Status:** Research Complete | Stack Selected | Simulator Implemented (Dart + TS) | Ready for Development
**Date:** Oct 2026 | **Location:** Bucharest, RO
**Target platforms:** Android 8+ • iOS 13+ (with graceful degradation)

---

## Mesh simulator

Two engines, one set of golden vectors. Both are deterministic discrete-event
simulations on a virtual clock: same seed ⇒ same run, byte for byte.

**Dart (authoritative, headless — this is what the roadmap builds on):**

```bash
cd sim/mesh_sim
dart pub get
dart test                                                    # incl. golden parity with the TS engine
dart run bin/mesh_sim.dart --scenario campus_quad --seed 42  # exits non-zero if acceptance fails
dart run bin/mesh_sim.dart --scenario festival_crowd --nodes 80 --json
dart run bin/mesh_sim.dart --duty-cycle   # NORMAL scans 3 s / sleeps 7 s (skills/07)
```

**TypeScript (reference engine + browser visualiser):**

```bash
npm ci
npm test          # 132 tests: RF, election, routing, DTN, power, regressions, acceptance
npm run dev       # canvas: watch SUPERs get elected, MPR suppress floods, bundles wait for a contact
                  # click a node to decline its router role or turn on battery saver
npm run golden    # regenerate test-fixtures/golden-vectors.json after an engine change
```

Scenarios: `campus_quad` (20 nodes — the `skills/02` + `skills/08` acceptance
case), `sparse_village` and `partitioned_pair` (store-carry-forward DTN),
`festival_crowd` (60 nodes, the `docs/02` §6 density target).

Measured on `campus_quad` across six seeds: **SUPER ratio 20-25%, delivery
97.3-100%, 97.3-100% of messages within 5 hops, 7-9% of the naive flood-all
relay budget, ≤0.22 role changes per node per minute.** In the 60-node crowd the
engine delivers **91.3-95.3%** at 12-14% of naive flood's relays — naive flooding
does reach 100% there, for 7-9× the transmissions.
Criteria, calibration evidence and the protocol bugs found while measuring are in
[`docs/06-simulator-findings.md`](docs/06-simulator-findings.md).

**Power policy** (`skills/02`, `skills/07`): SUPER opt-out and battery saver are
respected immediately — no two-cycle hysteresis, because a user toggle is not
score noise — and the declination is advertised in the OGM so neighbours stop
counting it as a top-20% candidate. The duty cycle (`scan 3s/sleep 7s`, SUPER
continuous) throttles scanning only, and it is what brings NORMAL inside
`skills/07`'s battery budget: measured **19-25% per 8 h always-on** versus
**8.7-12.4% duty-cycled**, delivery-neutral on the seed mean. The visualiser's
metrics dashboard and `--json` report battery %/h per role, scans/s, relays/s and
latency by hop (`docs/06-simulator-findings.md` §10).

---
**Quick verdict:** Buildable — but NOT as a single “Bluetooth-call-everywhere” app. Feasible as a **hybrid mesh**: `BLE (discovery + text) + Wi-Fi Direct/Aware (media + voice) + store-and-forward + opportunistic routing`. Voice = push-to-talk walkie-talkie, not cellular-grade full duplex. See analysis inside.
