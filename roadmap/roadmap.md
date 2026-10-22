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
- [x] SQLite + CRDT for group/broadcast history (hash beacon anti-entropy)
> **Implementation note (Oct 2026 — `sim/mesh_sim` + `src/`, evidence in `docs/06-simulator-findings.md` §17):** the protocol half is implemented in both
  engines and measured; SQLite is storage and stays app-side. Each member holds its group messages as a
  grow-only set keyed by message id — a G-Set CRDT, so merging is a union and beacons may be lost,
  duplicated or reordered without the protocol caring — and every 10 s offers each co-member it can hear a
  digest: 16 XOR-folded bucket hashes, **156 characters whether the group has said nothing or 400
  messages**, i.e. one 256 B BLE packet. A peer whose buckets differ asks for those buckets *and lists the
  ids it already holds*; the reply is capped at 32 entries. That list is load-bearing: the first version
  replied with the head of the same sorted list every round and a 20-message absence converged to 8 and
  stopped. None of it is acknowledged — the next beacon is the retry.
  Measured: with a five-member group and one member out of range for a whole 20-message conversation,
  repair recovers **20/20** and converges in **8.8 s** when the membership can hear itself, and **0/20**
  with beacons switched off. Idle cost is 31 beacons/min and 81 B/s. The boundary is worth knowing before
  building on it: beacons are peer-to-peer, so what converges is the membership's *peer graph* — a spread
  membership (6 of 20 directed links, disconnected) recovers the returning member and still never
  converges, because reach is the scoped flood's job, not repair's. And a key rotation resets what is
  repairable: history older than the last membership change is unreadable to everybody, so it is never
  offered (§17.5). `dart run bin/mesh_sim.dart --history` and `npm run history` print both arms.
> **Prediction note (Oct 2026 — evidence in `docs/06-simulator-findings.md` §18):** the *atrium* half of this criterion has been answered in
  simulation, with a condition the criterion does not mention. The most open node in a world — most peers,
  strongest average RSSI — becomes SUPER within two election cycles in **all four worlds** when it is also
  healthy, and stays NORMAL in three of four when it is not: a drained phone at **199 peers** scores 0.688
  against a healthy phone at **nine** scoring 0.708, because the peer term is normalised logarithmically
  against 50 and so saturates, while battery, uptime and packet-loss rate carry an uncompressed 0.45 of the
  score. So the walk has to record battery, uptime and loss next to placement (`docs/09` §4's `sample`
  records exist for this), and the criterion to check is that the elected set is the top 20% by score — not
  that a particular spot wins. If the atrium phone loses while healthy, §18.2 names the lever: normalise the
  peer count against the observed maximum in the world rather than a fixed 50.
- [ ] E2EE round 1: Noise_XX 1:1, SAS verify, padding
  > **Implementation note (Oct 2026 — evidence in `docs/07-e2ee-noise-xx.md` §2-§4):** specified and costed against this mesh, not implemented — `skills/03` says
  *"never custom crypto"*, so the handshake is libsodium work. What is measured here and settles real
  decisions: a handshake is **three** mesh messages, so its budget is three times the per-message one
  (675 ms at 1 hop, 6.7 s at 3, and a 4-hop leg in the crowd was lost outright); retries must be
  per-leg, not per-handshake, or a 5% leg loss becomes ~14% handshake failure; and handshakes must be
  **on demand, never on discovery** — a crowd produces ~70 new in-range peers per node per hour, which
  as eager XX exchanges is ~210 radio messages per node per hour of pure key agreement. The padding
  half is implemented: both engines now size a packet as `ceil((95 + body)/256) × 256` from the
  documented layout instead of a per-character guess, which had been flipping 241-character texts onto
  Wi-Fi Direct when the real packet fits BLE until 930 characters.
- [x] Broadcast pager channel (public) + private 1:1 + group (3-10 members)
  > **Implementation note (Oct 2026 — `sim/mesh_sim` + `src/`, evidence in `docs/06-simulator-findings.md` §14):** all three traffic classes now exist in both engines with their own
  accounting, so a 10-member group can neither flatter `deliveryRatio` nor deflate `broadcastReach`.
  Group delivery ships in two measured modes — a scoped flood the whole network relays and only members
  accept (default, and the only mode that does not reveal membership to every node on the path), or one
  routed unicast per member (up to 130× cheaper when every member is a direct peer, up to 5.8× dearer
  when they are spread). `dart run bin/mesh_sim.dart --group 10` reports both on any world. The app-side
  work — sender-key agreement, the channel list UI, persistence — is Phase 1's remaining crypto and
  storage items.
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
> **Instrumentation note (Oct 2026 — `tool/capture-json.ts` + `tool/field-report.ts`, plan in `docs/09-field-test-plan.md`):** still blocked on
  hardware, and deliberately not ticked — its subject is a building. Everything except the walk is built
  and tested: a JSONL capture schema the phones will emit (tx/deliver/loss/duplicate/decision/queue/
  election/sample/calibration), an analyzer that turns a capture into this item's three numbers — delivery
  ratio against a flood-all baseline, the SUPER ratio the election settles on, battery %/h per role with
  the duty cycle on — plus the RF calibration fit that decides whether the simulator's radio model is this
  building's model. It is validated against a synthetic capture whose ground truth is known
  (`npm run field:capture`): the least-squares fit recovers the model's own parameters exactly
  (**−55.0 dBm at 1 m, 20.0 dB/decade, 31.6 m line of sight, 0.00 dB residual**), delivery reads 0.9867
  against the engine's 0.9833, and the A/B overhead reads 14.8% against a flood-all baseline that reaches
  100% delivery for 6.7× the relays. §5 of the plan tabulates the prediction for every criterion with the
  evidence section behind it, and §6 lists where a real building will diverge (no channel-access model, so
  real delivery will be lower and real overhead higher).
- [x] Metrics dashboard: delivery ratio, overhead ratio, latency by hop, battery %/h
  - Delivered in the React visualiser (`src/components/MetricsPanel.tsx`) and in the headless CLI (`--json` emits the same fields, plus a hop table in the text report). Delivery and overhead ratio were already in the stats bar; latency by hop (count/avg/p95 per bucket, first-attempt routed unicast only) and measured battery %/h per role are new — `docs/06-simulator-findings.md` §10.3-10.5 has the numbers.

**Exit criteria:** In 10-phone test, SUPERs auto-elect, overhead drops ≥30% vs flood-all with same delivery; no flapping.

---

### PHASE 3 — WiFi Direct Media + PTT Foundations (Weeks 17-24)
**Goal:** Photos/files + walkie-talkie voice notes.

- [ ] WiFi Direct transport (Android `WifiP2pManager`): createGroup/join, socket relay, auto-select for payloads >1 KB
- [ ] MultipeerConnectivity parity on iOS (Apple-to-Apple files via MPC)
- [x] Chunked large-file protocol (64 KB chunks, ACK, resume)
> **Implementation note (Oct 2026 — `sim/mesh_sim` + `src/`, evidence in `docs/08-media-transport-ptt.md` §3, §4, §6):** implemented in both
  engines and measured. 64 KB slices behind a sliding window of 4 unacknowledged chunks, each slice an
  ordinary unicast so it inherits ACKs, retransmission, the OppQueue and the hop trace. A 10 MB image
  crosses 1/2/3 hops in **7.60 s / 16.88 s / 33.00 s** over Wi-Fi Direct; over BLE at skills/05's 512 B
  MTU the same file does not finish in 15 simulated minutes even at one hop. Window depth is the lever
  (16-deep is 15.5× faster than 1-deep at one hop) and 4 ships because the deeper wins are an upper
  bound: this simulator has no channel-access model to charge a deep window for filling the air.
  **"Resume" needed a mechanism, not just a queue**: a slice whose retries run out is carried in an
  OppQueue and its logical id is never seen again, so the window hung forever. A stall watchdog now
  re-sends the slices a stopped window is missing, and the skills/05 acceptance case — receiver offline
  for 20 s at chunk 49 of 160 — resumes and completes in 45.02 s. Chunks are counted apart from 1:1
  traffic so one file cannot flatter `deliveryRatio`.
- [ ] Audio pipeline: Opus encoder/decoder, 500 ms frames, 6-12 kbps, push-to-talk UI (hold to record)
- [x] PTT flow: record → chunk → encrypt → send via WiFi Direct preferred / BLE fallback → receiver jitter buffer → sequential play
> **Implementation note (Oct 2026 — `sim/mesh_sim` + `src/`, evidence in `docs/08-media-transport-ptt.md` §5, §7):** the transport half of the flow is
  implemented in both engines and measured; *record* (a microphone) and *encrypt* (per-frame nonces) are
  app-side and still to do, as with the SOS item above. Opus framing per skills/05 — 500 ms frames at
  12 kbps, 750 B each, `jitterBufferMs` 200 before playout — with frames leaving at the **end** of their
  capture window, so the last frame departs at release rather than a frame early. Measured play delay
  from release: **407 ms at one hop, 585 ms at two, 1.10 s at three**, against this phase's <3 s / <8 s.
  "WiFi Direct preferred" is a transport override (a negotiated group owner), not a size decision,
  because a 750 B frame is under the BLE ceiling and would otherwise never reach the faster radio; with
  it, the one-hop round trip is **292 ms** (skills/05's box is <1 s). Streaming beats sending the note as
  one blob on *first audio* by 31× for a 30 s note (989 ms vs 30.32 s) but not on play delay. The data
  plane's 4 s ACK timer turned out to be **eight voice frames** — one lost frame left an 8.53 s hole in
  the audio — so media retries on a 600 ms timer, which cut the worst gap to 1.21 s and underruns from
  16 to 7 across three seeds; an RTT-adaptive timer was implemented, measured, and left off by default.
- [ ] E2EE for media/voice frames (same Noise session, per-frame nonce)
- [x] SOS mode: repeated flood of GPS + text over all transports (like LinkMesh SOS [1](https://github.com/litu173/LinkMesh))
> **Implementation note (Oct 2026 — `sim/mesh_sim` + `src/`, evidence in `docs/06-simulator-findings.md` §11):** the protocol mechanism is implemented in both engines and measured — four floods
  5 s apart, each with a fresh GPS fix, receivers collapsing on `sosId` so one emergency raises one
  alert, and SOS bypassing MPR at every hop because suppression exists to delete the duplicate copies
  an emergency broadcast is made of. `TTL=5` is the default as specified; `festival_crowd` overrides it
  to 7 because from an edge sender that world is 6+ hops across and **repeating cannot fix a radius
  limit** (6 floods buy nothing over 4 at TTL 5). Reach over the sender's radio-connected component is
  **100% in all four worlds**; the app-side work (all-transports fan-out, the opt-in listen toggle) is
  still to do. `dart run bin/mesh_sim.dart --sos` prints the reach probe.
- [ ] External audit prep + panic wipe (one-tap key zeroization)

**Exit criteria:** 2 phones exchange image <10 MB over WiFi Direct mesh; PTT Opus note plays in <3s 1-hop / <8s 3-hop; SOS reaches all within ttl.

> **Implementation note (Oct 2026 — `sim/mesh_sim` + `src/`, evidence in `docs/08-media-transport-ptt.md` §10):** the image and PTT clauses are now met in
  simulation as well: a 10 MB image crosses three hops over Wi-Fi Direct in **33.00 s** (and resumes
  after a 20 s mid-transfer disconnect in 45.02 s total), and a streamed Opus note plays **407 ms** after
  release at one hop and **1.10 s** at three, against <3 s and <8 s. What simulation cannot answer is
  whether the note is *intelligible* — no codec runs in either engine — and whether two real phones
  negotiate a Wi-Fi Direct group in the 1-3 s docs/05 §3.2 budgets, since GO formation is modelled as a
  setup latency rather than as a second RF budget (`rf.ts` is deliberately untouched, so every earlier
  measurement stands).

> **Implementation note (Oct 2026 — `sim/mesh_sim` + `src/`, evidence in `docs/06-simulator-findings.md` §11.3):** the SOS clause is met in simulation and needs a denominator to be
  meaningful: over the sender's radio-connected component, reach is **100%** in all four worlds, while
  raw reach is 27% in `sparse_village` and 44% in `partitioned_pair` because 8 of 11 and 5 of 9 online
  nodes have no chain of links to the sender at all. The image and PTT clauses need hardware.

---

### PHASE 4 — Polish, iOS, & Scale (Weeks 25-36)
**Goal:** Shippable to real users.

- [ ] iOS harden: background scan throttling UX (“keep in foreground for mesh”), MPC fallbacks, BLE-only Android↔iOS interop
- [ ] WiFi Aware experiment (Android 26+ & iOS 26 compat probe) — feature-flagged
- [ ] Group UX: invite via QR, admin rotate key, leave/rejoin sync
  > **Implementation note (Oct 2026 — `sim/mesh_sim` + `src/`, evidence in `docs/06-simulator-findings.md` §14.3):** partly delivered in simulation: admin-only key rotation, invite and
  leave with rotation on both, and the 3-10 bound are implemented, tested and visible in the visualiser's
  node inspector (the engine's rules are in the DOM: Leave is disabled at three members, Rotate key for a
  non-admin). Still to do: QR invites and *rejoin sync*, which needs the CRDT history reconciliation from
  Phase 1 item 32 — a rejoining member cannot read the history it missed, by design, so syncing it is a
  separate mechanism from rotating the key.
- [x] Hop visualization: “via 2 nodes • SUPER Amir” hop trace for transparency
> **Implementation note (Oct 2026 — `sim/mesh_sim` + `src/`, evidence in `docs/06-simulator-findings.md` §13):** delivered in both engines plus the visualiser. `path` turned out to be a
  *fan-out tree* — a 4-hop delivery in the 20-node world lists 15 nodes — so `deliveredChain()` walks
  the per-hop `via` links backwards to recover the route the sentence describes, and the string is
  computed from data rather than asserted. Each hop carries arrival time, link budget in dBm, the
  action (`delivered`/`relayed`/`suppressed`/`queued`/`expired`) and the router's own reason, so the
  panel can show *why* two nodes stayed quiet. A pcap-like capture log (`--capture`, off by default,
  bounded, provably inert on the golden vectors) backs it.
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
