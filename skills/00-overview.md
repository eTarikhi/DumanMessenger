# Skills Overview — Duman Messenger Build System

These “skills” are **modular capability contracts** — each file is a spec + acceptance checklist the team (or an AI agent) must fulfill. They map 1:1 to roadmap phases.

| # | Skill | File | Phases |
|---|-------|------|--------|
| 1 | Mesh Discovery & Transport | `01-mesh-transport.skill.md` | 0-1 |
| 2 | Smart Router Engine | `02-super-node.skill.md` | 2 |
| 3 | E2EE & Identity | `03-crypto.skill.md` | 1,3 |
| 4 | Store-Carry-Forward (DTN) | `04-dtn.skill.md` | 1 |
| 5 | Voice PTT & Media | `05-voice-media.skill.md` | 3 |
| 6 | Persistence & Sync (CRDT) | `06-persistence.skill.md` | 1,4 |
| 7 | Power & Background Resilience | `07-power-bg.skill.md` | 0-4 |
| 8 | QA & Field Simulator | `08-qa-simulator.skill.md` | 2-5 |

**How to use:** Each skill file contains: Goal, Interfaces, Inputs/Outputs, Algo, Dependencies, Acceptance Tests, and “Do/Don’t”. Treat as sprint definitions.

All skills assume stack: **Flutter + Kotlin/Swift bridges + BLE GATT + WiFi Direct/Multipeer + SQLite/drift + libsodium + Opus**.
