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
- [x] Transport abstraction `MeshTransport {advertise(), scan(), connect(), send()}`
> **Implementation note (Oct 2026 — `sim/mesh_sim/lib/src/transport.dart`, `test/transport_test.dart`):** built. This note used to say the interface was app
  work; it is not, and the distinction matters for sequencing. The four verbs are the part of Phase 1 that does not need a phone: what `selectTransport` picks
  and at what size, how big a discovery beacon is, whether a payload is refused or handed to the mesh, and what a scan is allowed to report are *decisions* and
  are testable. The GATT server (item 20) and the CoreBluetooth peripheral (item 21) that implement `advertise()` on hardware are bridges, not decisions. So
  the interface is pure Dart with no dependency beyond the SDK, it lifts into `core/` unchanged when item 13 creates the mono-repo, and the app layer can be
  written and tested against `SimulatedMeshTransport` before either bridge exists.
> Two of its rules are load-bearing rather than plumbing. `connect()` returns null for a peer the local scan has not reported instead of reaching anything in
  the world, and `scan()` reports `node.peerIds` — the device's own scan cycle, refreshed on the beacon interval and stale while a NORMAL node sleeps (item 118's
  duty cycle) — never `peersInRange`, which is the geometry. An implementation that reaches an unheard peer hands the app an oracle, and an app built on an
  oracle passes every test in this repo and then fails on a phone in a pocket. A test polls both for a minute and asserts they disagree at least once, so that
  invariant cannot pass vacuously.
> The size decisions it inherits are measured in both engines — `selectTransport(size)` picks Wi-Fi Direct above a 1024 B packet and BLE below it, and `docs/07`
  §4 and `docs/08` §5.3 pin the two thresholds that matter (a text body crosses at 930 characters once padding is counted; a 500 ms voice frame crosses at
  14.9 kbit/s). The seam sizes on the *packet*, not the payload, and per *chunk*, not per file — the heuristic it replaced crossed at 241 characters, about four
  times too early, which matters because transport is what sets per-hop latency in this model.
> **What is not built:** the platform implementations (items 20, 21, 215, 220), and the opt-in consent and local-first store that item 350's analytics needs.
  `SimulatedMeshTransport` is a reference and a test double, not a radio.
- [ ] **BLE GATT hello:** Android GATT server + scanner + 12-byte beacon (DB hash + id)
- [ ] **iOS beacon:** CoreBluetooth peripheral + central scan
- [ ] Simple UI: peer list + 1:1 chat (plaintext first)
- [ ] Permissions flows (Android 12+ new BT perms, location, WiFi)
- [ ] CI + F-Droid/Play internal track + TestFlight

**Exit criteria:** 2 Android phones exchange “hello” over BLE, no internet.

---

### PHASE 1 — Mesh MVP: Text + Broadcast (Weeks 5-10)
**Goal:** Multi-hop text in a room.

- [x] Seen-cache dedup + TTL (5) + hopCount + flood relay
> **Implementation note (Oct 2026 — `sim/mesh_sim` + `src/`, evidence in `docs/06-simulator-findings.md` §6, §12`):** implemented in both engines exactly as specified — a seen-cache keyed on message id with a 5-minute TTL and a
  5,000-entry cap, data TTL 5, `hopCount` incremented per radio hop, and flood relay by peers — and measured: 20 nodes
  deliver **99.7%** at **9.3%** of naive flood-all's relay budget. One correction the measurement forced (§12): a node
  must treat a copy of *its own* message as a duplicate, which the first engine did not; fixing it cut relay
  transmissions **18.3%** in a warm campus and moved the golden vectors, which were regenerated rather than patched.
- [x] BATMAN-lite nextHop table (best-next-hop only)
> **Implementation note (Oct 2026 — `sim/mesh_sim` + `src/`, evidence in `docs/06-simulator-findings.md` §6-§7`):** implemented in both engines: an OGM table with the best next-hop neighbour per destination, and a **tq window of 32
  samples per (originator, via) pair** rather than per originator — tq is a *link* metric (docs/03 §7), and tracking it
  per destination made every route look as good as the best neighbour that advertised it. The defect and its fix are the
  largest single movement in this repository's numbers: direct-neighbour tq **0.107 → 0.935**, usable routes
  **29.7% → 86.8%**, and delivery from single digits to 99.7% on the campus world.
- [x] Store-and-forward OppQueue (7-day expiry, 500 msgs cap)
> **Implementation note (Oct 2026 — `sim/mesh_sim` + `src/`, evidence in `docs/06-simulator-findings.md` §8, §17, `docs/08-media-transport-ptt.md` §6`):** implemented in both engines at the specified constants — `OPP_QUEUE_MAX = 500`, `OPP_TTL_MS = 7 days`, Spray-and-Wait
  with `SPRAY_LIMIT = 3` copies — and exercised by the partitioned worlds, where it is the only thing that delivers at
  all. Opportunistic deliveries are marked `carried` so they stay out of the latency budget that docs/04 §5 writes for
  routed traffic. Two interactions were measured rather than assumed: a media chunk whose retries run out lands here and
  stalls its sliding window forever unless a watchdog re-sends it (`docs/08` §6), and a heavy file transfer pushed 35
  ordinary messages into store-carry-forward in 300 s (`docs/08` §9).
> **Correction note (Oct 2026 — evidence in `docs/06-simulator-findings.md` §20):** the layer was implemented as specified and still could not pass
  `skills/04`'s own carry test, for two reasons only a test would find: sprayed copies reused the source retries'
  `attempt` numbers, so relays deduped the first two of three copies and the spray budget was spent on copies nobody
  forwarded; and a carried bundle with no reachable route fell through to the flood branch, where a NORMAL node
  **MPR-suppressed it** — suppression exists to delete duplicate copies of a flood, and a bundle with nowhere to go is
  not a duplicate. Fixing both took the 60-node crowd from **0.867 to 0.947** delivery over six seeds, with five
  messages in a hundred arriving by store-carry-forward that previously did not arrive at all, and left the golden
  vectors untouched (the fixture parks no bundles). Two of `skills/04`'s rules were then measured and did not survive:
  preferring SUPER as a bundle carrier is implemented and **off by default** (−3.5 delivery points once the defects were
  fixed, because it duplicates work into the busiest queues), and "gossip ACK so relays can prune" pruned **zero**
  bundles across four worlds and six seeds, because the ACK is a unicast along the reverse path. §20.4 records the
  general lesson: the carrier preference measured as a *win* before the fixes and a *loss* after them.
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
> **Implementation note (Oct 2026 — `sim/mesh_sim` + `src/`, evidence in `docs/07-e2ee-noise-xx.md` §2-§4`):** the *cost* of this item is measured and the padding model is implemented in both engines (`wireSizeOf` =
  `ceil((95 + body)/256) × 256`, which moved the BLE ceiling from an assumed 241 characters to **930**). An XX handshake
  is three mesh legs: **675 ms** at one hop on the campus world, **2,219 ms** at two, **6,671 ms** at three, and it never
  completes at four hops in a 60-node crowd — so it must be negotiated on demand, never on discovery, and budgeted at
  three times a message. No cryptography is implemented here, deliberately: `skills/03` says never to write custom
  crypto.
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

- [x] CoverageScore scorer (peerCount, RSSI, battery, stability)
> **Implementation note (Oct 2026 — `sim/mesh_sim` + `src/`, evidence in `docs/06-simulator-findings.md` §5, §18`):** implemented in both engines at docs/03 §3's weights — 0.30 peer count, 0.25 average RSSI, 0.20 battery, 0.15 stability,
  0.10 packet-delivery rate, +0.10 when charging, score 0 below a 25% battery floor — with peer count normalised
  logarithmically against 50. §18 measures the consequence the weights imply and the field test will have to record:
  position carries 0.55 of the score but is *compressed*, health carries an uncompressed 0.45, so a drained phone at
  **199 peers** (0.6879) still loses to a healthy one at **nine** (0.7083).
- [x] OGM (2s) with score + isSuper; neighborScores table; top-20% election + hysteresis
> **Implementation note (Oct 2026 — `sim/mesh_sim` + `src/`, evidence in `docs/06-simulator-findings.md` §5, §15`):** implemented in both engines: beacons every 2 s ± 200 ms of jitter at TTL 5 carrying score and role, a 30 s
  neighbour-score TTL, promotion above 0.60 *and* inside the top 20%, demotion below 0.50 for two consecutive cycles.
  Measured on the campus world: SUPER ratio **20-25%** against skills/02's 15-25% band, **0.06-0.22** role changes per
  node per minute, ≤1 election per minute. §15 records the scale limit: at 200 nodes a beacon can advertise at most 30
  of ~179 heard peers, so the coverage question becomes unanswerable and the MPR fallback went quadratic until it was
  bounded to one peer per angular sector.
- [x] SUPER behavior: aggressive scan, relay all, WiFi Direct GO auto-create; NORMAL: MPR-style lazy relay (300 ms wait)
> **Implementation note (Oct 2026 — `sim/mesh_sim` + `src/`, evidence in `docs/06-simulator-findings.md` §6-§7, §10, `docs/08-media-transport-ptt.md` §2`):** the radio half is implemented in both engines and measured: SUPER scans every 250 ms and relays everything, NORMAL
  scans every 1 s (or 3 s awake / 7 s asleep under skills/07's duty cycle) and waits `MPR_WAIT_MS = 300` before a lazy
  relay. `skills/02`'s two power rules are asserted — SUPER opt-out is honoured immediately with the declination
  advertised in the OGM, and battery saver vetoes promotion outright. The **Wi-Fi Direct GO auto-create** half is
  platform work and is modelled only as a transport a caller can select (`docs/08` §5): formation cost is a setup
  latency, not a second RF budget, so `rf.ts` is deliberately untouched and every earlier measurement stands.
- [x] MPR-like coverage: SUPERs suppress redundant NORMAL relays
> **Implementation note (Oct 2026 — `sim/mesh_sim` + `src/`, evidence in `docs/06-simulator-findings.md` §6, §15`):** implemented in both engines: a node computes an MPR set that covers its two-hop neighbourhood, a NORMAL relay waits
  300 ms and stands down when it hears the copy relayed by a member of that set, and the wait is coverage-gated rather
  than unconditional. Measured against both baselines the criteria demand — **9.3%** of naive flood-all's relays and a
  mean **0.736** of `route-flood` (suppression off, routing on) across six seeds, at equal-or-better delivery. §15
  bounds it at scale: the fallback that fires when coverage cannot be answered is capped at six sector-spread peers,
  which cut transmissions **67%/86%/76%** at 50/100/200 nodes and left the 20- and 60-node evidence untouched.
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

> **Calibration note (Oct 2026 — `sim/mesh_sim` + `src/`, evidence in `docs/08-media-transport-ptt.md` §12.9):** every simulated number behind this exit
  criterion was measured with a radio that has no contention: no shared medium, and a receiver that takes every
  packet however busy it is. Both halves now exist as flags (`channelAccess`, `channelCapture`), both ship off,
  and separating them says which one matters — with a 10 MB file in flight, a transmit queue costs text 2.8 points
  of delivery and receiver collisions cost **13.6**. On the 20-node campus the same flags put delivery at
  **0.9056** (collisions only) and **0.8556** (both) against the ≥90% this criterion inherits from skills/02 and
  skills/08, while overhead stays at 15.8% and 25.5% of flood-all and the SUPER ratio stays inside its band. So the
  overhead half of this exit criterion has margin and the delivery half has none, and the 10-phone test should
  measure delivery ratio before it measures anything else. A third arm adds what real link layers do —
  `channelAccess: "csma"`, listen before talking — and it is worse than either: delivery **0.7389-0.7944** and
  overhead **78-80%** of flood-all, failing both gates, because listening converts collisions into queueing and
  this engine's retry timers convert queueing into load (§12.10). The missing mechanism is backpressure: a real
  stack defers *and* stops generating work, while the simulator only defers. If a real floor delivers nine
  messages in ten, that is the finding to act on, and it is not in the radio model.
  The radio-layer answer has now been built and measured, and it does not change that conclusion — it sharpens
  it. `channelBackoff: "binary"` adds the contention window carrier sense was missing (every deferring node is
  otherwise released at the same instant the medium clears, so listening synchronises the herd instead of
  dispersing it). It moves delivery ±1.1 points and leaves both csma arms ~14 short of the gate, because under
  carrier sense the losses are **queue drops, 1994-3466 against 273-394 collisions**: a lever that makes nodes
  wait longer feeds the queue that is shedding them (§12.13). So the fix is not in front of the queue and has
  to be above the radio, which is why sender-side flow control was built too — and measuring it corrects the
  reason. `mediaBackpressure` had to be fixed in three places before it did what it claims (a window floored at
  one slot still hands a packet to a full queue; the stall path bypassed the window; nothing resumed a blocked
  transfer). Corrected, it is a clear win on one radio — 25 → 5 drops, 6 → 0 retransmissions, 6.04 s instead of
  9.37 s — and a trade in a mesh, +1.7 points under carrier sense against -2.8 under plain half-duplex, neither
  reaching the gate (§12.12). Attribution says why the first version's null result was mis-explained: with a file
  in flight **82-85% of the shedding is the source's own**, not a relay's, so a sender-side window is pointed at
  most of the problem — and what it cannot fix is that a window rations a transfer's *share* of a radio rather
  than creating slots. The cheap alternative, rerouting round a congested relay, is not available either: an
  equal-cost alternative next hop existed for only 3-9% of relay sheds (§12.14). What remains is a radio that can
  refuse a hand-over, with a layer above it that holds the packet instead of counting it lost.

---

### PHASE 3 — WiFi Direct Media + PTT Foundations (Weeks 17-24)
**Goal:** Photos/files + walkie-talkie voice notes.

- [ ] WiFi Direct transport (Android `WifiP2pManager`): createGroup/join, socket relay, auto-select for payloads >1 KB
> **Implementation note (Oct 2026 — `sim/mesh_sim` + `src/`, evidence in `docs/08-media-transport-ptt.md` §2-§3`):** the **auto-select for payloads >1 KB** half is implemented in both engines and measured: `BLE_MAX_BYTES = 1024`, with
  the air-time model behind it reproducing docs/05 §3.2's "250× faster than BLE" exactly (a 64 KB slice is 26 ms on
  Wi-Fi Direct against **6.45 s** on BLE), and a 10 MB image crossing three hops in **33.00 s**. `createGroup`/`join`
  and the socket relay are platform work; the model treats formation as a setup latency, not as a second RF budget.
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
> **Implementation note (Oct 2026 — `sim/mesh_sim` + `src/`, evidence in `docs/08-media-transport-ptt.md` §5`):** the framing and transport half is implemented in both engines and measured, and the simulator's chat panel has the
  push-to-talk control (streamed against one blob, which is the A/B `docs/08` §5 reports). The codec half is not
  simulated, so intelligibility and MOS stay unmeasured. What the framing half settled: **12 kbps is the fastest
  documented rate that keeps a frame on BLE** — 750 B raw, and exactly 1024 B once `docs/07`'s padding is counted, so
  there is no slack at all — and a streamed note plays **407 ms** after release at one hop and **1.10 s** at three.
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
> **Implementation note (Oct 2026 — `sim/mesh_sim` + `src/`, evidence in `docs/08-media-transport-ptt.md` §5.3, §8, `docs/07-e2ee-noise-xx.md` §4`):** costed rather than built, and the costing produced a constraint worth knowing before the crypto is written: a 750 B
  voice frame pads to **exactly 1024 B**, flush against the BLE packet ceiling, so a per-frame nonce has no slack to
  grow into. Either it fits inside the 95 B of overhead the padding model already budgets, or the frame escalates to
  Wi-Fi Direct and push-to-talk stops working on the radio that is guaranteed to be up. A 64 KB file slice pays
  ≤0.2% for the same overhead, which is why chunks declare their payload size rather than their wire size.
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

> **Correction note (Oct 2026 — `sim/mesh_sim` + `src/`, evidence in `docs/08-media-transport-ptt.md` §12):** every number in the note above was
  measured with a radio that has no channel: `channelAccess: "free"` lets two transmissions occupy the air at
  once, so a transfer costs nothing but its own time. Giving the device the one radio it actually has —
  `channelAccess: "halfDuplex"`, a bounded transmit queue that drops at the tail, shipped **off** because this
  exit criterion and skills/02's and skills/08's gates were written against the channel-free model — moves the
  same three clauses: the 10 MB image takes **4.44 min** at three hops instead of 33.00 s, and a streamed note
  at three hops arrives **26.8 s after the user let go** for a 10 s recording (0.76 s under `free`), because one
  frame needs ≈245 ms of air per hop against a 500 ms capture clock. At one hop both still pass, and at two the
  note is already marginal. Two consequences worth carrying into the platform work: the sliding window's 15.5×
  is **1.25×** on a real radio, since there is one transmitter to fill; and a load gate on transfers *is*
  motivated there — window 1 instead of 4 recovers 1.1 of the 1.7 points of text delivery a file costs, and a
  third of the p95, for 46% more transfer time; slicing chunks smaller (the intuitive alternative) costs 4.4× the
  transfer time and buys no delivery at all.

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
> **Implementation note (Oct 2026 — `sim/mesh_sim` + `src/`, evidence in `docs/06-simulator-findings.md` §14, §17`):** two of the three are implemented and measured in both engines: **admin rotate key** (`rotateGroupKey`, admin-only,
  epoch bumped, stale-epoch copies rejected network-wide) and **leave/rejoin sync** — hash-beacon anti-entropy recovers
  what a member missed, 20/20 messages in 8.8 s when the membership can hear itself. The caveat that belongs in the UX:
  a rotation makes older history unreadable to everybody, so what rejoin can sync is only what was sent since the last
  membership change. Inviting by QR is app work.
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
> **Implementation note (Oct 2026 — `sim/mesh_sim` + `src/`, evidence in `docs/06-simulator-findings.md` §15, §7`):** the simulator half is done and it found something: a 10-200 node sweep exposed a **quadratic cliff** in the MPR
  fallback at high density, where a beacon advertising at most 30 of ~179 heard peers makes coverage unanswerable; one
  3-hop delivery cost 7,038 transmissions and a whole run 15,933. Bounding the fallback to six sector-spread peers cut
  transmissions **67% at 50 nodes, 86% at 100, 76% at 200**, at a delivery cost only at 200 (100% → 98.3%) and inert at
  20 and 150. Battery: NORMAL measures **10.0%/8 h** on the campus world with the duty cycle on (15.0% stationary
  always-on, 19.4% mobile always-on) — inside skills/07's 15% with the sleep slot, outside it without. A 200-node run
  takes 24.6 s of wall time for 38 s of simulation.
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
> **Implementation note (Oct 2026 — `sim/mesh_sim` + `src/`, evidence in `docs/09-field-test-plan.md` §4, §7`):** the format this would ship in is written down and has a working analyzer: `docs/09` §4's JSONL capture carries
  per-message `hop`, per-device `sample` records and calibration readings, and `tool/field-report.ts` derives hop
  distribution, latency percentiles, relay counts and an RF-model fit from it. Validated against a synthetic capture
  whose ground truth is known, where the fit recovers the model's own parameters exactly (−55.0 dBm at 1 m,
  20.0 dB/decade, 31.6 m line of sight, 0.00 dB residual). What is not built is the opt-in consent and the
  local-first store — and note that the capture deliberately carries no identities, only stable per-device labels.
- [ ] Community relay program: “Keep Duman on a plugged tablet at your café/campus → community SUPER”
> **Measurement note (Oct 2026 — `src/__tests__/simulation.test.ts` `community relays`, evidence in `docs/06-simulator-findings.md` §19):** simulated before
  being believed, in the world where it has the most to gain (`festival_crowd`, 60 nodes, 100 messages,
  identical traffic plan in every arm). The election half works: every plugged, stationary, well-placed
  tablet is elected SUPER within two cycles. The rest does not work the way the line reads. At **three**
  tablets, total relay traffic rises 24.6% and transmissions by *other* nodes rise **9.2%** — a SUPER relays
  everything by design (Phase 2 item 65), so adding always-on SUPERs adds relays everywhere. Only at **six**
  does the burden move off other people's phones (−4.6%), because the tablets start displacing
  battery-powered SUPERs instead of joining them, and the top-20% cap then elects only **four of the six**.
  Delivery drifts down the whole way (0.910 → 0.900 → 0.890), so this is not a coverage programme.
  What it can honestly claim: NORMAL battery drain falls **3.005 → 2.957 → 2.877 %/h** at 0/3/6 tablets.
  §19.2 says what to change before building it — promotion has to be cap-aware (reserve part of the top 20%
  for charging, stationary nodes, or score a tablet above a phone at equal position), and the benefit is a
  quota, not a single tablet.

> **Correction note (Oct 2026 — `sim/mesh_sim` + `src/`, evidence in `docs/06-simulator-findings.md` §19.4):** cap-aware promotion was then built in both
  proposed forms (`communityRelayQuota`: reserve a share of the top 20%, or exempt community relays from it) and
  measured on three seeds. It is aimed at a mechanism that is not operating. The tablets that fail to be elected
  are not losing to phones: with six plugged nodes in one crowd they all hear each other, so the five slots are
  already theirs and the weakest two lose to the strongest four (seed 42: six better-scoring tablets, **zero**
  better-scoring phones); at three tablets the one that sometimes loses is stopped by the 30 m proximity guard,
  which is docs/03 §5 working as written. Exemption does elect all six and lifts delivery 1.7 points, but it
  raises everybody else's transmissions **12%** — back to the no-tablet baseline — and puts the SUPER ratio at
  **25.0%**, the ceiling of skills/02's band, so it fails the programme's own claim of moving work off other
  people's batteries. Reserving half the cap reserves nothing for the same reason and instead hands a slot to a
  phone (13 → 14 SUPERs, tablets unchanged). Ships at 0, i.e. off. The useful question this leaves is not how to
  elect more tablets but whether a plugged node should be *preferred* as an MPR and as a bundle carrier.

> **Measurement note (Oct 2026 — `sim/mesh_sim` + `src/`, evidence in `docs/06-simulator-findings.md` §19.5):** that question was then asked of both
  places, and the answer is no twice. `communityRelayPreference` inserts "is a plugged, stationary node" into
  the MPR tie-break chain ahead of SUPER status: it wins the tie it was written for, never overrides a
  coverage gain, and in the crowd moves **0.6 of 100 MPR slots** while delivery, p95, relay transmissions,
  both burden counts and NORMAL drain stay identical to the digit across three seeds and three tablet
  counts — because who transmits is decided per packet from what a node actually heard, not from the MPR
  label. `dtnPreferCommunity` hands a routeless bundle to a reachable plugged carrier instead of a SUPER: it
  fires **40-51 times a run**, grows parked bundles **27-55%**, and buys at most **0.7** extra opportunistic
  deliveries a run, with delivery flat to 1.1 points worse. A stationary node is the best place to *leave* a
  bundle and the worst place to *carry* one, because carrying is movement — the same failure class as
  skills/04's "prefer SUPER as bundle carrier" (`docs/06` §20.4). Both flags ship off. What is left of the
  community-relay programme is the finding §19.2 already had: six plugged tablets take 18.6% of the radio
  work off everybody else because they are elected and plugged in, not because anything prefers them.

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
