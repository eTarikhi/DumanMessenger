# Duman Messenger — Delivery Roadmap
## 12 Months: Idea → MVP → PTT → Scale

> **Stack:** Flutter + Native Transport (Kotlin/Swift) | BLE GATT + WiFi Direct + Multipeer | CRDT + BATMAN-lite + DTN
> **Team:** 3-5 engineers (1 Flutter, 1 Android native, 1 iOS native, 1 crypto/protocol, 1 QA/design)
> **Principles:** Android-first, prove mesh with 10 phones before adding features; no fake promises on voice.

---

### PHASE 0 — Foundations (Weeks 1-4)
**Goal:** Repo, beacons, 2-phone text hello.

- [ ] Mono-repo: `app/` Flutter + `transport/android` + `transport/ios` + `core/` Dart pure
- [ ] Identity: Ed25519/X25519 keygen + QR add-contact (Briar-style)
- [ ] Transport abstraction `MeshTransport {advertise(), scan(), connect(), send()}`
- [ ] **BLE GATT hello:** Android GATT server + scanner + 12-byte beacon (DB hash + id)
- [ ] **iOS beacon:** CoreBluetooth peripheral + central scan
- [ ] Simple UI: peer list + 1:1 chat (plaintext first)
- [ ] Permissions flows (Android 12+ new BT perms, location, WiFi)
- [ ] CI + F-Droid/Play internal track + TestFlight

**Exit criteria:** 2 Android phones exchange “hello” over BLE, no internet.

---

### PHASE 1 — Mesh MVP: Text + Broadcast (Weeks 5-10)
**Goal:** Multi-hop text in a room.

- [ ] Seen-cache dedup + TTL (5) + hopCount + flood relay
- [ ] BATMAN-lite nextHop table (best-next-hop only)
- [ ] Store-and-forward OppQueue (7-day expiry, 500 msgs cap)
- [ ] SQLite + CRDT for group/broadcast history (hash beacon anti-entropy)
- [ ] E2EE round 1: Noise_XX 1:1, SAS verify, padding
- [ ] Broadcast pager channel (public) + private 1:1 + group (3-10 members)
- [ ] Foreground service (Android) + bg mode (iOS) + duty cycling NORMAL vs continuous SUPER (manual toggle first)
- [ ] Battery/performance logging

**Exit criteria:** 5 Android phones in mesh: A can message C via B relay; broadcast reaches all; airplane mode throughout; <2s 1-hop, <5s 3-hop.

---

### PHASE 2 — Smart Router (Weeks 11-16)
**Goal:** The “Duman” magic — auto-super-nodes.

- [ ] CoverageScore scorer (peerCount, RSSI, battery, stability)
- [ ] OGM (2s) with score + isSuper; neighborScores table; top-20% election + hysteresis
- [ ] SUPER behavior: aggressive scan, relay all, WiFi Direct GO auto-create; NORMAL: MPR-style lazy relay (300 ms wait)
- [ ] MPR-like coverage: SUPERs suppress redundant NORMAL relays
- [x] Mesh simulator `mesh_sim.dart` (virtual nodes, walls, random walk) → tune weights w1..w5
  - Delivered at `sim/mesh_sim/` (+ TypeScript reference engine and visualiser in `src/`), wired into CI with cross-language golden vectors.
  - Weights w1..w5 verified as specified (0.30/0.25/0.20/0.15/0.10): `campus_quad` over six seeds gives SUPER 20-25%, delivery 97.3-100%, 97.3-100% within 5 hops, 7-9% of the naive flood-all relay budget, ≤0.22 elections/node/min.
  - Three spec defects found while tuning and corrected in `docs/03`: the proximity guard's hard-coded −60 dBm; MPR suppression gated on "heard a SUPER" instead of on coverage (cost 16-29 delivery points in a 60-node crowd); and tq kept per route entry instead of per link, which made the `tq > 0.6` gate reject nearly every route and silently disabled multi-hop unicast. Evidence: `docs/06-simulator-findings.md`.
- [ ] Field test 1: campus quad / office floor mapping: atrium should become SUPER, packet delivery ratio vs flood-all baseline
- [x] Metrics dashboard: delivery ratio, overhead ratio, latency by hop, battery %/h
  - Delivered in the React visualiser (`src/components/MetricsPanel.tsx`) and in the headless CLI (`--json` emits the same fields, plus a hop table in the text report). Delivery and overhead ratio were already in the stats bar; latency by hop (count/avg/p95 per bucket, first-attempt routed unicast only) and measured battery %/h per role are new — `docs/06-simulator-findings.md` §10.3-10.5 has the numbers.

**Exit criteria:** In 10-phone test, SUPERs auto-elect, overhead drops ≥30% vs flood-all with same delivery; no flapping.

---

### PHASE 3 — WiFi Direct Media + PTT Foundations (Weeks 17-24)
**Goal:** Photos/files + walkie-talkie voice notes.

- [ ] WiFi Direct transport (Android `WifiP2pManager`): createGroup/join, socket relay, auto-select for payloads >1 KB
- [ ] MultipeerConnectivity parity on iOS (Apple-to-Apple files via MPC)
- [ ] Chunked large-file protocol (64 KB chunks, ACK, resume)
- [ ] Audio pipeline: Opus encoder/decoder, 500 ms frames, 6-12 kbps, push-to-talk UI (hold to record)
- [ ] PTT flow: record → chunk → encrypt → send via WiFi Direct preferred / BLE fallback → receiver jitter buffer → sequential play
- [ ] E2EE for media/voice frames (same Noise session, per-frame nonce)
- [ ] SOS mode: repeated flood of GPS + text over all transports (like LinkMesh SOS [1](https://github.com/litu173/LinkMesh))
- [ ] External audit prep + panic wipe (one-tap key zeroization)

**Exit criteria:** 2 phones exchange image <10 MB over WiFi Direct mesh; PTT Opus note plays in <3s 1-hop / <8s 3-hop; SOS reaches all within ttl.

---

### PHASE 4 — Polish, iOS, & Scale (Weeks 25-36)
**Goal:** Shippable to real users.

- [ ] iOS harden: background scan throttling UX (“keep in foreground for mesh”), MPC fallbacks, BLE-only Android↔iOS interop
- [ ] WiFi Aware experiment (Android 26+ & iOS 26 compat probe) — feature-flagged
- [ ] Group UX: invite via QR, admin rotate key, leave/rejoin sync
- [ ] Hop visualization: “via 2 nodes • SUPER Amir” hop trace for transparency
- [ ] Performance pass: 50-node density test (emulator + 15 real phones crowded), battery <15%/8h NORMAL
- [ ] Onboarding: 3-slide explainer (no internet needed, keep Bluetooth on, this is short-range not replacement)
- [ ] Distribution: Play + APK direct + F-Droid + GitHub Releases + TestFlight; handle GMS-less Huawei via fallback
- [ ] Legal: privacy policy, crypto export note, takedown resilience docs

**Exit criteria:** Closed beta 50-100 users at university/festival; Android delivery ratio >90% at 3 hops; iOS companion usable.

---

### PHASE 5 — Launch & Beyond (Weeks 37-52)
**Goal:** Public launch + community.

- [ ] Public launch v1.0 (Android) + v0.9 (iOS)
- [ ] Offline maps integration (optional, like OSHI [2](https://oshi-messenger.com/best-offline-messenger))
- [ ] Plugin API: `offline-protocol`-like SDK for other apps to join Duman mesh [3](https://www.offlineprotocol.com/guides/quickstart)
- [ ] Mesh analytics (opt-in only, local-first): anonymous hop counts to improve scoring
- [ ] Community relay program: “Keep Duman on a plugged tablet at your café/campus → community SUPER”

---

### Risk Mitigations Across Roadmap

| Risk | Mitigation |
|------|------------|
| iOS can’t match Android | Document degradation early; ship iOS as companion, not parity promise |
| Huawei / no-GMS | Test on de-Googled device by Week 6; raw BLE+WiFi Direct must pass |
| Battery complaints | Duty-cycle NORMAL aggressively; let user toggle mesh off; SUPER opt-in |
| Voice disappointment | Market as **push-to-talk**, never “cellular call”; stream only 1-hop |
| Sparse network death | DTN OppQueue + clear UX “No relay nearby — message will send when someone passes” |

---

### Milestone Table

| When | Milestone | Demo |
|------|-----------|------|
| W4 | 2-phone hello | Airplane mode chat |
| W10 | 5-phone mesh flood | Broadcast in room |
| W16 | Auto-super election | Overhead chart ↓30% |
| W24 | Image + PTT | “Walkie” demo across building |
| W36 | 50-person beta | Festival field test |
| W52 | v1 public | Stores + APK |

---

### Cost & Team Hint

- **Core team 4 FTE × 12 mo** ≈ lean startup budget; biggest cost is test devices (15-20 mixed Android) + audit ($15-30k).
- Keep scope ruthless: **cut video/live-call, cut >10 MB, cut iOS parity** in v1. Add after PMF.

---
*See `roadmap/index.html` for visual interactive version.*
