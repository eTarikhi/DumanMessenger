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
- `docs/07-e2ee-noise-xx.md` — Noise_XX as a *mesh* protocol: measured handshake cost, when to negotiate, packet/padding sizes
- `docs/08-media-transport-ptt.md` — What a byte costs on this mesh: chunked files, streamed push-to-talk, the retry timer, and skills/05's acceptance boxes
- `docs/09-field-test-plan.md` — The one criterion that needs a building: capture schema, analyzer, protocol, and what the simulator predicts
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
dart run bin/mesh_sim.dart --sos          # SOS reach probe: component-relative and raw
dart run bin/mesh_sim.dart --media        # 10 MB image at 1/2/3 hops, BLE-only ladder, PTT budgets
dart run bin/mesh_sim.dart --history      # group history repair, against the same world with it off
dart run bin/mesh_sim.dart --trace        # per-delivery route: dBm, action and reason per hop
dart run bin/mesh_sim.dart --capture      # pcap-like mesh log tail (--capture-ogm adds beacons)
```

**TypeScript (reference engine + browser visualiser):**

```bash
npm ci
npm test          # 166 tests: RF, election, routing, DTN, power, SOS, hop traces, acceptance, UI renders
npm run dev       # canvas: watch SUPERs get elected, MPR suppress floods, bundles wait for a contact
                  # click a node to decline its router role or turn on battery saver
npm run golden    # regenerate test-fixtures/golden-vectors.json after an engine change
npm run media     # the media transport probe behind docs/08 (files, PTT, retry timer, contention)
npm run history   # group-history anti-entropy, with and without repair (docs/06 §17)
npm run field:capture -- campus_quad 42 /tmp/cap.jsonl [flood-all]   # a field-test capture, from a run
npm run field:report  -- /tmp/cap.jsonl /tmp/base.jsonl              # the roadmap's field numbers (docs/09)
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
[`docs/06-simulator-findings.md`](docs/06-simulator-findings.md). E2EE is specified and costed —
handshake latency per leg, when to negotiate at all, and the packet/padding size model both engines
now use — in [`docs/07-e2ee-noise-xx.md`](docs/07-e2ee-noise-xx.md); no cryptography is implemented
here, because `skills/03` says never to write custom crypto.

**SOS mode** (`docs/05` §3.2-3.3, roadmap Phase 3): the originator floods, then re-floods three
times at 5 s intervals, each flood a *fresh message id* (the seen-cache would swallow a repeat that
reused one) carrying a fresh GPS fix, with receivers collapsing on `sosId` so four floods raise one
alert. SOS bypasses MPR at every hop — suppression exists to delete duplicate copies, and an emergency
broadcast is made of them. Measured: reach over the sender's radio-connected component is **100% in
all four worlds**; in the 60-node crowd four floods take raw reach from 89.4% to 100%, and with
link-layer retries disabled repeats take a degraded world from 40.8% to 64.5% — while six floods buy
nothing over four when the gap is *radius* rather than loss. TTL is the radius knob and stays at the
documented 5, except in `festival_crowd`, which is 6+ hops across from an edge sender
(`docs/06-simulator-findings.md` §11).

**Scale** (`skills/08`: nodeCount 10-200): measured end to end, and the top of the
range had a cliff — at 200 nodes in a 100×100 m area every node hears ~179 of the
other 199, so a beacon that advertises at most 30 neighbours cannot answer the MPR
coverage question, and every relay fell back to flooding all of its peers (one 3-hop
delivery: 7,038 transmissions). Bounding that fallback to six **direction-spread**
peers cuts the worst case 76% and 100 nodes by 86%, costs one message in 60 at 200
nodes, and is inert below 30 peers — so the 20- and 60-node evidence, and the golden
vectors, are unchanged (`docs/06-simulator-findings.md` §15).

**Group channels** (`docs/04` §4, roadmap Phase 1): 3-10 members, an admin, and a key epoch that
rotates on every membership change — so a node that leaves keeps relaying group traffic but can no
longer read it, and a node that joins cannot read the history it missed. Delivery ships in two
measured modes: a **scoped flood** the whole network relays and only members accept (the default, and
the only mode that does not reveal the membership to every node on the path), or **one routed unicast
per member**, which is up to 130× cheaper when every member is a direct peer and up to 5.8× dearer
when they are spread across the world. `dart run bin/mesh_sim.dart --group 10` reports both on any
world and says which is cheaper and why; the visualiser manages membership from the node inspector and
flips the mode live from the chat header (`docs/06-simulator-findings.md` §14).

**Media transport** (`skills/05`, `docs/05` §3.2-3.3, roadmap Phase 3): a payload now costs what it
occupies the radio with — `max(0, bytes − 1024) × 8 / kbps` per hop, at 80 kbit/s on BLE against
20 Mbit/s on Wi-Fi Direct, the 250× ratio `docs/05` claims — and it is inert below one packet, which is
why every earlier measurement and both golden fixtures are unchanged. Files go out as 64 KB slices
behind a 4-deep sliding window, each slice an ordinary unicast so it inherits ACKs, retries, the
OppQueue and the hop trace: a 10 MB image crosses 1/2/3 hops in **7.6 s / 16.9 s / 33.0 s**, and when
its receiver disappears for 20 s mid-transfer a stall watchdog re-sends what is missing and it finishes
in 45.0 s (skills/05's "resume" acceptance box). Push-to-talk streams 500 ms Opus frames at 12 kbps —
750 B, exactly one padded BLE packet — leaving at the end of each capture window, and plays **407 ms**
after release at one hop and **1.10 s** at three against the roadmap's <3 s / <8 s; media retries on a
600 ms timer because the text plane's 4 s is eight voice frames and one lost frame left an 8.5 s hole in
the audio. Chunks are counted apart from 1:1 traffic so one file cannot flatter `deliveryRatio`, the
chat panel renders a transfer as one progress row instead of 160 empty bubbles, and
`dart run bin/mesh_sim.dart --media` / `npm run media` print every table in
[`docs/08-media-transport-ptt.md`](docs/08-media-transport-ptt.md).

**Field-test instrumentation** (roadmap Phase 2, `docs/09`): the one acceptance item that needs a
building is prepared for instead of guessed at. A JSONL capture schema, an analyzer that turns a capture
into delivery-vs-flood-all, the SUPER ratio and battery %/h, and an RF calibration fit that decides
whether the simulator's radio model is *this* building's model — all validated against a synthetic
capture whose ground truth is known, where the fit recovers −55.0 dBm / 20.0 dB per decade / 31.6 m to
three significant figures.

**Group history repair** (roadmap Phase 1's "CRDT for group/broadcast history (hash beacon
anti-entropy)"): every member holds its group's messages as a grow-only set keyed by message id, so
merging two members is a union and a beacon may be lost, duplicated or reordered without the protocol
caring. Each offers every co-member it can *hear* a digest — 16 XOR-folded bucket hashes, **156
characters whether the group has said nothing or 400 messages**, one 256 B BLE packet — and a peer whose
buckets differ asks for those buckets *and lists the ids it already holds*, which is what lets a reply be
capped at 32 entries and still converge (without the list, every round re-offers the same head and repair
stalls). Nothing is acknowledged; the next beacon is the retry. Measured on a five-member group with one
member out of range for a whole 20-message conversation: **20/20 recovered, converged in 8.8 s**, against
**0/20** with beacons off, for 31 beacons/min and 81 B/s when idle. The boundary is measured too — beacons
are peer-to-peer, so what converges is the membership's *peer graph*: a spread membership recovers the
returning member and still never converges, because reach is the scoped flood's job, not repair's
(`docs/06-simulator-findings.md` §17).

**Hop transparency** (roadmap Phase 4): every delivery carries a per-hop trace — arrival time, link
budget in dBm, who handed it over, the action and the router's own reason — and `deliveredChain()`
recovers the route from what turns out to be a fan-out *tree* (a 4-hop delivery lists 15 nodes), which
is what makes the roadmap's "via 2 nodes • SUPER Amir" computable instead of decorative. A bounded
pcap-like capture log sits behind `--capture` and is provably inert: with it on, every counter and
node position is identical and the golden vectors are byte-for-byte unchanged (§13).

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
