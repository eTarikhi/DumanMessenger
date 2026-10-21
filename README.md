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
```

**TypeScript (reference engine + browser visualiser):**

```bash
npm ci
npm test          # 106 tests: RF, election, routing, DTN, regressions, acceptance
npm run dev       # canvas: watch SUPERs get elected, MPR suppress floods, bundles wait for a contact
npm run golden    # regenerate test-fixtures/golden-vectors.json after an engine change
```

Scenarios: `campus_quad` (20 nodes — the `skills/02` + `skills/08` acceptance
case), `sparse_village` and `partitioned_pair` (store-carry-forward DTN),
`festival_crowd` (60 nodes, the `docs/02` §6 density target).

Measured on `campus_quad` across six seeds: **SUPER ratio 20-25%, delivery
98.7-100%, ≥98% of messages within 5 hops, 54-68% of the naive flood-all relay
budget, ≤0.14 role changes per node per minute.** In the 60-node crowd, MPR
reaches delivery **parity with naive flooding** at ~50% of the relay budget.
Criteria, calibration evidence and the protocol bugs found while measuring are in
[`docs/06-simulator-findings.md`](docs/06-simulator-findings.md).

---
**Quick verdict:** Buildable — but NOT as a single “Bluetooth-call-everywhere” app. Feasible as a **hybrid mesh**: `BLE (discovery + text) + Wi-Fi Direct/Aware (media + voice) + store-and-forward + opportunistic routing`. Voice = push-to-talk walkie-talkie, not cellular-grade full duplex. See analysis inside.
