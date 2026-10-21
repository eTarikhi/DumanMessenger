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

**Status:** Research Complete | Stack Selected | Ready for Development
**Date:** Oct 2026 | **Location:** Bucharest, RO
**Target platforms:** Android 8+ • iOS 13+ (with graceful degradation)

---
**Quick verdict:** Buildable — but NOT as a single “Bluetooth-call-everywhere” app. Feasible as a **hybrid mesh**: `BLE (discovery + text) + Wi-Fi Direct/Aware (media + voice) + store-and-forward + opportunistic routing`. Voice = push-to-talk walkie-talkie, not cellular-grade full duplex. See analysis inside.
