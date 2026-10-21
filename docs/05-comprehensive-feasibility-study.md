# 05 — Comprehensive Technical Feasibility Study & Development Strategy
## Duman Messenger — Offline P2P Mesh Communication

---

> **Purpose:** This document consolidates and extends the prior research (docs 01–04) into a single formal feasibility study addressing three pillars: (1) Technical Feasibility & Constraint Analysis, (2) Comparative Methodology Research, and (3) Strategic Implementation Roadmap. It is intended as the authoritative reference for build/don't-build decisions and team formation.

---

## Pillar 1 — Technical Feasibility & Constraint Analysis

### 1.1 Signal Propagation & Effective Range

Phones carry three radios relevant to Duman: BLE, Bluetooth Classic, and Wi-Fi (in Direct/Aware/P2P modes). Each has fundamentally different propagation characteristics.

| Transport | Indoor Range | Open-Air Range | Throughput | Path Loss Model |
|-----------|-------------|----------------|------------|-----------------|
| BLE (advertising + GATT) | 10–30 m | ~100 m | ~6 kbit/s (10-node mesh), few KB/s max | Free-space: −20 log₁₀(d) + wall penalty 8–15 dB per interior wall |
| Bluetooth Classic (RFCOMM/SPP) | ~10 m | ~30 m | ~2 Mbps | Same model; shorter due to lower TX power class |
| Wi-Fi Direct (2.4 GHz P2P) | 100–200 m | ~200 m | 50–250 Mbps | −20 to −24 log₁₀(d); 5 GHz variant shorter range, higher throughput |
| Wi-Fi Aware (NAN, Android 26+) | ~100–150 m | ~150 m | Medium (data-path dependent) | Similar to Wi-Fi Direct; no group-owner negotiation overhead |

> **Implementation note (Oct 2026 — `sim/mesh_sim`, evidence in `docs/06-simulator-findings.md`):** the simulator calibrates the BLE row as
> `rssi = txPower − 20·log₁₀(d) − wallCrossings·wallPenalty` with `txPower = −55 dBm`
> at 1 m, `rxSensitivity = −85 dBm` and `wallPenalty = 12 dB` (inside the 8-15 dB
> range above). That yields a **31.6 m** line-of-sight hop — the top of the
> documented 10-30 m indoor band — and ~18 m through one interior wall.
> Do not pair `txPower = −30 dBm` with `−85 dBm` sensitivity: it implies a 562 m
> radio, which is what made the first prototype's 100×100 m world come up
> disconnected. Packet loss is margin-driven and raised to `p^(linkRetries+1)`,
> because BLE GATT and Wi-Fi Direct are reliable bearers that retransmit at the
> link layer before reporting a failure upwards.

**Key constraints:**

- **Range is density-dependent, not guaranteed.** A single hop covers 10–100 m depending on walls, bodies, and RF interference. In a sparse village (<1 device per 50 m), messages stop. Duman is a *crowd network*, not a cellular replacement.
- **Multi-hop extends range linearly** but with compounding latency: each hop adds 100–200 ms. After 4–5 hops, round-trip exceeds 1 s — acceptable for text, unacceptable for real-time full-duplex voice.
- **2.4 GHz congestion:** BLE and Wi-Fi Direct share the 2.4 GHz band. Dense mesh deployments (festivals, stadiums) experience mutual interference. Wi-Fi Aware's 5 GHz data-path mode mitigates this where hardware supports it.
- **Body absorption:** At 2.4 GHz, the human body attenuates signal by 3–5 dB. A phone in a pocket has measurably worse range than one held in hand. This affects super-node election (a stationary phone on a table is a better router than one in someone's pocket).

**Verdict:** Range is sufficient for campus/festival/disaster-relief scenarios (10–500 m with 5 hops). It is **not** sufficient for rural or sparse-suburban use without dedicated relay hardware (e.g., a plugged tablet at a community center).

---

### 1.2 Power Consumption & Battery Drain Mitigation

Continuous BLE scanning and Wi-Fi Direct group ownership are the two dominant power drains.

**Measured baselines from comparable apps:**

- **Briar** (Android, continuous BLE scan): drains battery ~4× faster than a server-based messenger. A phone that lasts 18 h on standby with Briar's mesh active lasts ~4.5 h.
- **Wi-Fi Direct group owner (GO):** the GO role consumes significantly more power than a client because it maintains the AP beacon and manages all connections. This is why super-node election must be voluntary and battery-aware.

**Duman's mitigation strategy (multi-layered):**

| Layer | Strategy | Expected Impact |
|-------|----------|----------------|
| Role-based duty cycling | NORMAL: scan 3 s / sleep 7 s (30% duty); SUPER: continuous scan (user-opt-in) | NORMAL drains ~15%/8h target; SUPER warned in UI |
| Transport selection | BLE for discovery + text (µW range); Wi-Fi Direct activated only for media/voice, then torn down | Avoids continuous Wi-Fi GO power cost |
| Adaptive scan intervals | Scan interval scales with peer density: dense = shorter interval (peers stable), sparse = longer (fewer discoveries expected) | Reduces redundant wake-ups |
| Charging bonus | Plugged devices get +0.1 coverage score → more likely to become SUPER | Encourages café/tablet community relays |
| Battery floor | Battery <25% → forced demotion from SUPER; <15% → minimal beacon only | Prevents dead-phone scenarios |
| OS-level integration | Android ForegroundService (connectedDevice type) + battery-optimization exemption request; iOS bluetooth-central background mode with state restoration | Prevents silent OS kills; documents tradeoff to user |

**Verification target:** NORMAL-mode overhead <15% per 8 h (validated via Android Battery Historian and iOS Energy Log). This is aggressive but achievable with 30% duty cycling and no continuous Wi-Fi GO.

**Residual risk:** Users who manually force SUPER mode on a low-battery phone will drain fast. The UI must make this tradeoff explicit and offer auto-demotion.

---

### 1.3 Device Discovery Latency & Handshake Efficiency

Discovery is the first user-visible metric — "how fast do I see nearby people?"

**BLE discovery mechanics:**

- Advertising interval directly trades off discovery speed vs. power. At 100 ms interval (SUPER), a scanner detects a peer in ~200–500 ms. At 500 ms (NORMAL), detection takes 1–3 s. At 1 s (power-save), 3–6 s.
- Android 7+ imposes scan throttling: max 5 scan start/stop cycles per 30 s, and a 30-minute cumulative scan cap unless using a Foreground Service. Duman must coalesce scan windows and use the foreground-service exemption.
- iOS throttles background BLE scans aggressively. In background, iOS only delivers advertisements for *known* service UUIDs and reduces scan frequency to ~15-min intervals. Discovery in background is unreliable; the app must communicate "open Duman to find people."

**Handshake efficiency:**

- BLE GATT connection setup: 100–500 ms depending on device and Android vendor stack. Samsung and Xiaomi behave differently; Huawei (no GMS) may lack Nearby Connections but raw BLE works.
- Noise_XX handshake (3 messages: `-> e, <- e,ee,s,es -> s,se`): adds 2 round-trips over BLE GATT. At ~50 ms per BLE write, that's ~200–300 ms on top of connection setup. Total time from discovery to first encrypted message: 500–1000 ms for a fresh peer, near-instant for a cached session (resumption within 7 days).
- 12-byte beacon (8-byte DB hash + 4-byte node prefix, Meshenger pattern): allows instant detection of whether two peers are out of sync without any GATT connection — pure advertising. This is the single most important discovery optimization.

**Target:** discovery latency <3 s (BLE beacon interval 500 ms for NORMAL, 100 ms for SUPER). First encrypted message <1 s after GATT connect for cached sessions.

---

### 1.4 Mesh Stability — Topology Changes & Node Churn

Phones are not fixed infrastructure. They move, sleep, die, and reboot. A mesh built on phones must handle constant churn.

**Churn scenarios:**

| Scenario | Frequency | Impact | Duman's Response |
|----------|-----------|--------|------------------|
| User walks away (peer lost) | Continuous | Route breaks; in-flight messages may be lost | BATMAN-lite nextHop table expires entries after 30 s of no OGM; OppQueue stores undeliverable DMs for retry |
| User kills app | Common | Node vanishes from mesh silently | No cleanup needed — OGM expiry handles it; WorkManager restarts service within 15 min (Android) |
| User reboots phone | Occasional | Same as kill + brief radio unavailability | BOOT_COMPLETED receiver re-launches foreground service |
| SUPER node dies | Critical if it was sole relay | Partition; messages between sides stop | SUPER election re-runs every 30 s; nearest runner-up self-promotes within 60 s; OppQueue preserves undelivered messages across the partition |
| Dense crowd movement (festival) | Continuous mass churn | Topology changes every few seconds | 30 s election cycle with hysteresis (±10% margin) prevents flapping; MPR-style lazy relay (NORMAL waits 300 ms for SUPER) reduces redundant retransmissions during churn |
| Network partition / merge | Occasional (group splits & rejoins) | Two sub-meshes form independently | CRDT merge on reconnection (group/broadcast history converges by union); OppQueue sprays queued DMs across new link |

**Stability mechanisms in detail:**

1. **Hysteresis (anti-flapping):** A node promotes to SUPER only if score >0.60 *and* top-20% rank. It demotes only if score <0.50 *for 2 consecutive 30 s cycles*. This 0.10 margin prevents oscillation when scores hover near the threshold.
2. **SUPER proximity guard:** If two SUPERs are within ~30 m (RSSI > −60 dBm) and within 0.10 score of each other, the lower scorer backs off for 60 s. Prevents 5 SUPERs in one classroom all creating Wi-Fi Direct groups.
3. **Soft-state routing:** No hard route commitments. The nextHop table is rebuilt continuously from OGM receipts. If a nextHop goes silent, the entry expires and routing falls back to flood. No partition-healing protocol needed — it emerges from gossip.
4. **Store-carry-forward (DTN):** The OppQueue (max 500 messages, 7-day expiry) acts as a buffer across partitions. When a new peer appears, the queue is scanned for messages destined for that peer or routable via that peer. Spray-and-wait limits copies to 3 to prevent queue flooding.

**Known limitation:** During rapid mass movement (e.g., a crowd dispersing from a stadium), the 30 s election cycle may lag topology changes by 1–2 cycles. Messages in flight during this window rely on flood + OppQueue for delivery, which adds latency but does not lose messages (within TTL).

---

### 1.5 Security — E2EE & Identity in a Decentralized, Trustless Environment

Duman operates with no server, no certificate authority, no phone number, and no central identity registry. This is both a security advantage (no metadata to subpoena, no chokepoint to compromise) and a significant engineering challenge.

**Threat model:**

| Threat | Actor | Severity | Mitigation |
|--------|-------|----------|------------|
| Passive eavesdropping | Nearby attacker with BLE sniffer | High | Noise_XX E2EE on all DMs; relay nodes see only routing headers, not plaintext |
| Active relay/modification | Attacker who forwards or alters packets | High | AEAD (ChaCha20-Poly1305) auth tag detects any modification; Noise_XX authenticates both parties |
| Impersonation ("I am Alice") | Attacker claiming another's identity | Critical | Trust-on-first-use via QR exchange (Briar model): QR contains pubkey + 8-char SAS for verbal verification. No identity without out-of-band key exchange. |
| Denial of mesh (jamming) | Attacker with RF jammer | Medium | Cannot prevent RF jamming; document as out-of-scope. Rate-limiting and SUPER rotation reduce impact of protocol-level floods. |
| Device seizure | State actor confiscates phone | Critical | Panic wipe (one-tap key zeroization + DB overwrite); encrypted SQLite at rest (SQLCipher); no cloud backup by design (lose phone = lose history, Briar's tradeoff) |
| Traffic analysis | Passive observer correlating timing/size | Medium | Random 50–200 ms forwarding jitter; 256-byte block padding; low-rate dummy beacons |
| Battery drain attack | Attacker flooding messages to drain peers | Medium | Rate limit: max 5 broadcasts/min per node; SUPERs drop excess; relay cap 30 msgs/min per source |

**Cryptographic design:**

- **Identity:** Ed25519 (signing) + X25519 (key exchange), generated on first launch, stored in Android Keystore/StrongBox or iOS Secure Enclave. 32-byte nodeId = SHA-256(pubKey). No phone number, no username — identity *is* the keypair.
- **1:1 DM:** Noise_XX handshake over BLE GATT (no internet round-trip needed). Session keys ratchet per message (Double Ratchet light) for forward secrecy. Session resumption cached for 7 days.
- **Group chat:** GroupKey distributed over pairwise Noise channels on creation/member-add. Key rotated on member removal. Group messages encrypted with GroupKey + signed with Ed25519.
- **Broadcast/pager:** Public channel is plaintext by design (like a walkie-talkie channel). Encrypted broadcast variant = group with shared key.
- **Packet format:** Header (plaintext, for routing): `{msgId16, ttl, type, destHint8, hopCount}`. Body (AEAD-sealed): `{fromPubKey, timestamp, body, padding}`. The `destHint` is a truncated hash of the destination pubkey (8 bytes) — relays can route without learning full identity; only the intended recipient can fully verify.

**Why not TLS/PKI:** No internet to reach a CA. Trust-on-first-use + SAS verification is the proven offline pattern (Briar, PGP in person, Signal safety numbers). It requires physical proximity for initial key exchange, which fits Duman's use case (you're already near the person you want to talk to).

**Audit plan:** External Cure53-style review at end of Phase 3 (after E2EE implemented, before PTT). Budget $15–30k. No custom crypto — libsodium via FFI only.

---

## Pillar 2 — Comparative Methodology Research

### 2.1 Mesh Networking Protocol Evaluation

Duman needs a routing protocol that works on phones: low memory, low CPU, tolerant of frequent topology changes, and able to operate over BLE GATT (not IP-based). This rules out most standard MANET protocols directly, but their *algorithms* can be adapted.

| Protocol | Origin | Topology Knowledge | Memory (50 nodes) | Overhead (49 nodes) | Phone Suitability | Duman Adaptation |
|----------|--------|-------------------|-------------------|---------------------|-------------------|------------------|
| **OLSR** (Optimized Link State Routing) | IETF RFC 3626, IP MANET | Full topology (link-state) | High: O(n²) for full link-state, MPR reduces to O(n·k) | ~6375 B/s control traffic (49 nodes) | **Poor** — full topology too heavy for phones; IP-based (needs IP connectivity, not BLE GATT) | Borrow MPR concept (minimal relay set covering 2-hop neighbors) for data-plane flood suppression |
| **BATMAN** (Better Approach To Mobile Ad-hoc Networking) | Freifunk community, layer 2 | None — only best-next-hop per originator | Low: O(n) — one entry per known originator | ~675 B/s (49 nodes, ~10× less than OLSR) | **Good** — decentralized, no global topology, survives churn, low overhead | **Primary inspiration.** Adapt OGM (Originator Message) beacon pattern for BLE: 2 s beacon carrying `{nodeId, seq, score, isSuper, peerCount, batteryBucket}`. Store only best-next-hop + transmit quality. |
| **AODV** (Ad hoc On-Demand Distance Vector) | IETF RFC 3561 | On-demand route discovery | Medium — routes built reactively; route repair on break | Bursty (RREQ floods on new destination) | **Moderate** — reactive routing avoids periodic overhead but RREQ floods are expensive over BLE | Not directly used; OppQueue provides similar "try later" semantics without explicit route discovery |
| **B.A.T.M.A.N. Advanced** (batman-adv) | Linux kernel, layer 2 | Distributed hash table of originators | Low | Kernel-level, very efficient | **N/A** — kernel module, not available on Android/iOS without root | Algorithm only, not implementation |
| **Bluetooth Mesh (802.15)** | Bluetooth SIG | Managed-flood with relay nodes | Low (relay is boolean) | Proven at scale (lighting networks) | **Poor for phones** — phones are proxy-only, not full mesh nodes; cannot relay while in background on iOS | **Do not use.** Build phone-native GATT mesh instead (Bridgefy/Briar approach). |
| **Spray-and-Wait (DTN)** | Epidemiological routing | None — bundle replication | Low (queue bounded) | Bounded by spray limit (L=3) | **Good** — complements BATMAN for partition scenarios | **Adopted as OppQueue** for store-carry-forward when no route exists |

**Duman's hybrid selection: BATMAN-lite (control plane) + MPR-inspired flood (data plane) + Spray-and-Wait DTN (partition tolerance).**

Rationale:
- BATMAN-lite gives the lowest memory footprint (O(n), capped at 200 nodes) and proven resilience to churn without requiring global topology.
- MPR flood suppression (SUPER nodes relay; NORMAL nodes wait 300 ms and only relay if no SUPER retransmission heard) reduces redundant transmissions by ~30% vs naive flood.
  - **Measured: 91-93% reduction on the 20-node case** (7-9% of the naive-flood relay budget), so the ~30% target is met with wide margin. But the rule *as phrased* is unsafe — "no SUPER retransmission heard" does not imply this node's neighbours are covered. On a 60-node crowd it cost 16-29 points of delivery. Gating suppression on **coverage** (the neighbours heard from, plus their advertised neighbour lists, must cover all of this node's 1-hop neighbours) reaches delivery **parity with the same engine without suppression** — and within 0-3 points of naive epidemic flooding on the 20-node case, 5-9 points in the 60-node crowd, where naive flooding buys that margin with 7-9× the relays. See `docs/03` §6.
  - *Composition of that saving, because the headline number flatters MPR:* most of it is the routing layer, not suppression. Holding routing fixed and switching suppression off (`route-flood`) costs 22-41% more relays in the 20-node quad and 50-58% more in the 60-node crowd. Both arms are reported in `docs/06-simulator-findings.md` §2 and §7. Neither was measurable until the per-link tq fix (`docs/06` §6) — with tq collapsing to 0 on every duplicate beacon, routes were rejected and both arms flooded blindly.
- Spray-and-Wait DTN handles the partition case that pure MANET protocols don't address — messages survive across disconnections.

**Why not OLSR directly:** OLSR's full link-state database is too memory-heavy for phones (49 nodes = ~6.4 KB/s of control traffic over BLE's ~6 kbit/s budget — the control plane alone would saturate the link). BATMAN's ~675 B/s leaves headroom for data.

**Why not Bluetooth Mesh spec:** Phones cannot be full BLE Mesh relay nodes — Android and iOS Core Bluetooth APIs expose only proxy/client functionality, not the full mesh bearer. Building on the BLE Mesh spec would require external hardware gateways, violating the "phone-only" requirement.

---

### 2.2 Development Framework Comparison — Low-Level Radio Control & Background Processes

The framework choice determines how much control Duman has over BLE GATT servers, Wi-Fi Direct group ownership, foreground services, and background execution — all of which are make-or-break for a mesh app.

| Criterion | Native (Kotlin + Swift) | React Native | Flutter |
|-----------|------------------------|--------------|---------|
| **BLE GATT server (peripheral mode)** | Full control via `BluetoothGattServer` (Android) / `CBPeripheralManager` (iOS) | Requires native modules; existing plugins (`react-native-ble-plx`) are client-oriented, server/peripheral mode less mature | `flutter_blue_plus` / `flutter_reactive_ble` — considered most stable Flutter BLE plugins; peripheral mode requires MethodChannel bridge to native |
| **Wi-Fi Direct / P2P** | Full control via `WifiP2pManager` (Android); iOS uses MultipeerConnectivity (different API, no cross-interop) | No off-the-shelf plugin; requires custom native module | No off-the-shelf plugin; requires MethodChannel to native `WifiP2pManager` (Kotlin) and `MCSession` (Swift) |
| **Background execution** | Android: ForegroundService (full control, persistent notification); iOS: background modes + state restoration — both fully native | RN background execution limited; requires native modules for long-running BLE tasks | Same as RN — background BLE requires native bridge; Dart isolate limitations for long-running native callbacks |
| **Foreground service (Android)** | Native — straightforward | Requires third-party libs (`@notifee`, `react-native-background-actions`) — works but adds fragility | Requires MethodChannel to Kotlin ForegroundService — well-trodden pattern |
| **Code sharing (protocol/crypto/state)** | None — 2 separate implementations of routing, crypto, CRDT | Shared JS/TS for logic; native for radio only | Shared Dart for logic, crypto, CRDT, routing; native for radio only. Single codebase for 90%+ of app. |
| **BLE throughput** | Native — lowest latency, highest throughput | Bridge overhead adds latency; throughput lower per reports | Bridge overhead exists but MethodChannel/EventChannel is efficient for event streams; comparable to native for most payloads |
| **Existing mesh libraries** | `offlinemesh` (Kotlin/Swift GATT+WiFi Direct), Bridgefy SDK (native) | `react-native-ble-mesh` (exists, less mature) | `flutter_mesh_network` (BLE+WiFi Direct+WiFi Aware), `bridgefy` SDK on pub.dev, `cross_p2p_network` |
| **Team velocity** | Slow — 2 codebases, 2 radio stacks | Medium — 1 JS codebase + native bridges | **Fast** — 1 Dart codebase + thin native bridges; shared protocol layer |
| **Maturity for BLE-heavy apps** | Gold standard (Briar, Bridgefy are native) | Reports of BLE plugin instability vs Flutter | Best-in-class BLE plugin stability among cross-platform options per comparative reviews |
| **iOS background BLE** | Full control of `bluetooth-central` mode, state restoration | Limited — must bridge to native anyway | Must bridge to native anyway; no disadvantage vs RN, advantage of shared logic |

**Decision: Flutter + thin native transport bridges (Kotlin for Android, Swift for iOS).**

Rationale:
1. **90%+ code sharing:** The protocol layer (routing, crypto, CRDT, DTN queue, super-node scoring) is pure Dart and shared across platforms. Only the radio-specific transport implementations (BLE GATT server, Wi-Fi Direct, MultipeerConnectivity) require native code.
2. **BLE plugin stability:** Flutter BLE plugins are reported as more stable than React Native equivalents for the GATT peripheral (server) mode that Duman requires.
3. **Existing mesh ecosystem:** `flutter_mesh_network`, `bridgefy` on pub.dev, and `offlinemesh` patterns provide reference implementations to study.
4. **Team velocity:** A 3–5 person team can ship faster with one shared codebase than two native codebases. The native bridge work is concentrated in 2 engineers (1 Android, 1 iOS) who own the transport layer.
5. **Acceptable tradeoff:** The MethodChannel bridge adds minor latency to BLE event delivery, but this is dwarfed by BLE's own 50–100 ms per-write latency. For voice/media over Wi-Fi Direct, the socket layer is entirely native and bypasses the bridge.

**When to reconsider native:** If Phase 4 field testing reveals bridge throughput as a bottleneck for voice PTT latency (>300 ms bridge overhead), the Wi-Fi Direct voice path can be moved entirely to native Kotlin/Swift with a thin callback to Dart for UI state. This is a surgical escalation, not a rewrite.

---

## Pillar 3 — Strategic Implementation Roadmap

### 3.1 Technical Stack

| Layer | Technology | Rationale |
|-------|-----------|-----------|
| App framework | Flutter 3.22+ (Dart 3.4) | Single codebase, mature BLE plugins, fast iteration |
| Android native bridge | Kotlin | `BluetoothGattServer`, `BluetoothLeScanner`, `WifiP2pManager`, ForegroundService |
| iOS native bridge | Swift | `CBPeripheralManager`, `CBCentralManager`, `MCSession`, `MCNearbyServiceAdvertiser` |
| BLE | `flutter_blue_plus` + custom native GATT server/peripheral | Most stable Flutter BLE plugin; peripheral mode via native bridge |
| Wi-Fi Direct (Android) | `WifiP2pManager` (native Kotlin) | No cross-platform Wi-Fi Direct API exists; Android-only |
| iOS peer-to-peer | MultipeerConnectivity (native Swift) | Apple's mesh: BT + Wi-Fi combined; no Android interop |
| Wi-Fi Aware | Android 26+ `WifiAwareManager` (feature-flagged) | Future transport; iOS 26+ incompatible with Android yet — flag for later |
| Database | drift (SQLite ORM) + optional SQLCipher | Local persistence, encrypted at rest; CRDT merge semantics |
| Crypto | `cryptography` (Dart) + libsodium via FFI | X25519/Ed25519/Noise_XX/ChaCha20-Poly1305; no custom crypto |
| Audio (PTT) | `opus_dart` + native Opus codec + `flutter_sound` | Opus 6–12 kbps voice; 500 ms chunked frames |
| State management | Riverpod | Reactive state, testable, mature in Flutter ecosystem |
| Build/distribution | Play Store + APK sideload + F-Droid + GitHub Releases + TestFlight | Takedown resilience (India 2026 precedent); no single store dependency |

### 3.2 High-Level System Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                     Flutter UI Layer (Dart)                   │
│  Chats · Groups · PTT Walkie · SOS · Peer List · Settings    │
│  State: Riverpod · Navigation · Theming                      │
├──────────────────────────────────────────────────────────────┤
│                    Duman Core (Pure Dart)                     │
│  ┌────────────┐ ┌──────────────┐ ┌────────────────────────┐ │
│  │ Identity    │ │ E2EE Engine  │ │ Packet Router          │ │
│  │ Ed25519     │ │ Noise_XX     │ │ TTL · Dedup · Flood    │ │
│  │ X25519      │ │ Double       │ │ BATMAN-lite nextHop    │ │
│  │ QR trust    │ │ Ratchet      │ │ MPR suppression        │ │
│  └────────────┘ └──────────────┘ └────────────────────────┘ │
│  ┌────────────┐ ┌──────────────┐ ┌────────────────────────┐ │
│  │ Super-Node  │ │ DTN Layer    │ │ Persistence & Sync     │ │
│  │ Election    │ │ OppQueue     │ │ drift SQLite + CRDT    │ │
│  │ Coverage    │ │ Spray-Wait   │ │ Hash beacon anti-      │ │
│  │ Score       │ │ 7-day expiry │ │ entropy merge          │ │
│  └────────────┘ └──────────────┘ └────────────────────────┘ │
├──────────────────────────────────────────────────────────────┤
│              Transport Abstraction (Dart interface)            │
│  MeshTransport { advertise() · scan() · connect() · send() }  │
│  TransportRegistry: auto-select by payload size / battery     │
├──────────────────────────────────────────────────────────────┤
│  ┌─────────────────┐  ┌──────────────────┐  ┌──────────────┐ │
│  │ BLE GATT        │  │ Wi-Fi Direct     │  │ Multipeer    │ │
│  │ (Android Kotlin │  │ (Android Kotlin) │  │ (iOS Swift)  │ │
│  │  + iOS Swift)   │  │                  │  │              │ │
│  │ Discovery+text  │  │ Media+voice+file │  │ iOS-iOS full │ │
│  └─────────────────┘  └──────────────────┘  └──────────────┘ │
├──────────────────────────────────────────────────────────────┤
│                   Platform Services                           │
│  Android: ForegroundService · WorkManager · BOOT_RECEIVER    │
│  iOS: bluetooth-central bg · state restoration · bg refresh  │
│  Permissions: BT_SCAN/CONNECT · NEARBY_WIFI_DEVICES · Location│
└──────────────────────────────────────────────────────────────┘
```

**Transport auto-selection logic:**

| Payload | Selected Transport | Rationale |
|---------|-------------------|-----------|
| Discovery beacon (12 B) | BLE Advertising | Always-on, lowest power, no connection needed |
| Text message (<1 KB) | BLE GATT | Reliable, low power, universal (Android + iOS) |
| Voice PTT (10–40 KB) | Wi-Fi Direct if connected, else chunked BLE | Wi-Fi Direct for speed; BLE fallback for universality |
| Image/file (<10 MB) | Wi-Fi Direct only | 250× faster than BLE; auto-reject over BLE-only with "move closer to SUPER" hint |
| Broadcast SOS | All transports, flood (TTL=5) | Maximize reach; no ACK needed |

> **Implementation note (Oct 2026 — `sim/mesh_sim` + `src/`, evidence in `docs/06-simulator-findings.md` §11):** TTL=5 is the engine default (`sosTtl`) and SOS floods to every peer at every
> hop, bypassing MPR and the route table. Two things the row does not say, both measured: *all
> transports* is one payload on one radio here (SOS uses Wi-Fi Direct, which in this model buys 40 ms
> per hop instead of 120, not extra reach), and TTL sets the **radius** an SOS can reach — a 60-node
> crowd is 6+ hops from an edge sender, so that scenario overrides `sosTtl` to 7. Repeating the flood
> recovers loss and movement, never radius.

### 3.3 Phased Development Roadmap

#### Phase 0 — Prototyping & Foundations (Weeks 1–4)

**Goal:** Two Android phones exchange "hello" over BLE in airplane mode.

| Workstream | Deliverables | Owner |
|------------|-------------|-------|
| Repo scaffold | Mono-repo: `app/` (Flutter) + `transport/android` (Kotlin) + `transport/ios` (Swift) + `core/` (pure Dart) | Flutter engineer |
| Identity | Ed25519/X25519 keygen, secure storage, QR add-contact (Briar pattern) | Crypto engineer |
| Transport abstraction | `MeshTransport` Dart interface; `BleGattTransportAndroid` (Kotlin): GATT server + scanner + 12-byte beacon | Android engineer |
| iOS beacon | `BleGattTransportIos` (Swift): `CBPeripheralManager` + `CBCentralManager` | iOS engineer |
| UI | Peer list + 1:1 chat (plaintext first) | Flutter engineer |
| Permissions | Android 12+ BT_SCAN/CONNECT, location, WiFi; iOS bluetooth-central | Android + iOS engineers |

**Exit criteria:** 2 Android phones discover each other in <3 s and exchange 1 KB over BLE GATT, no internet.

#### Phase 1 — Protocol Layer: Mesh MVP (Weeks 5–10)

**Goal:** 5 phones — A messages C via B relay; broadcast reaches all.

| Workstream | Deliverables | Owner |
|------------|-------------|-------|
| Routing | Flood relay: seen-cache dedup (LRU 5000, 5-min), TTL=5, hopCount; BATMAN-lite nextHop table (best-next-hop only, no global topology) | Flutter/protocol engineer |
| DTN | OppQueue: 7-day expiry, 500-msg cap, spray-and-wait (L=3) | Flutter/protocol engineer |
| Sync | SQLite (drift) + CRDT for group/broadcast history; hash-beacon anti-entropy sync | Flutter engineer |
| E2EE | Noise_XX 1:1 handshake, SAS verification, 256-byte padding; public pager vs private DM vs group | Crypto engineer |
| Background | Android ForegroundService + iOS bluetooth-central bg mode; duty cycling (NORMAL 3s/7s, SUPER continuous — manual toggle first) | Android + iOS engineers |
| Metrics | Delivery ratio, latency per hop, battery %/h logging | QA engineer |

**Exit criteria:** 5 Android phones in mesh: A→C via B relay; broadcast to all; airplane mode; <2 s 1-hop, <5 s 3-hop.

#### Phase 2 — Mesh Optimization: Smart Router (Weeks 11–16)

**Goal:** Auto-elected super-nodes cut overhead ≥30% vs flood-all, no flapping.

| Workstream | Deliverables | Owner |
|------------|-------------|-------|
| Coverage scorer | `coverageScore = 0.30·norm(peers) + 0.25·normRSSI + 0.20·battery + 0.15·stability + 0.10·PDR + chargingBonus` | Protocol engineer |
| Election | OGM beacons (2 s) with score + isSuper; neighborScores table; local top-20% election; hysteresis (±0.10); 30 m SUPER proximity guard | Protocol engineer |
| Role behavior | SUPER: continuous scan + relay-all + Wi-Fi Direct GO auto-create; NORMAL: MPR lazy relay (300 ms wait for SUPER) | Android engineer |
| Simulator | `mesh_sim.dart`: 20–100 virtual nodes, random-walk mobility, wall attenuation, RSSI model; tune weights w1–w5 | QA engineer |
| Field test | Campus quad / office floor: 10 phones; verify atrium → SUPER, corners → NORMAL; overhead chart vs flood-all baseline | All engineers |

**Exit criteria:** 10-phone test: SUPERs auto-elect, overhead drops ≥30% vs flood-all with same delivery; no flapping >1 change/min.

#### Phase 3 — UI/UX Integration & Media: WiFi Direct + PTT (Weeks 17–24)

**Goal:** Photos, files, and walkie-talkie voice notes.

| Workstream | Deliverables | Owner |
|------------|-------------|-------|
| Wi-Fi Direct transport | Android `WifiP2pManager`: createGroup/join, socket relay, auto-select for >1 KB payloads | Android engineer |
| iOS MPC | MultipeerConnectivity parity for iOS-to-iOS file transfer | iOS engineer |
| File protocol | Chunked transfer: 64 KB slices, sliding-window ACK, resume on reconnect, max 10 MB | Flutter engineer |
| Audio pipeline | Opus encoder/decoder, 500 ms frames, 6–12 kbps; PTT UI (hold to record); jitter buffer 200 ms | Flutter + Android engineers |
| E2EE media | Per-frame nonce encryption over existing Noise session | Crypto engineer |
| SOS mode | Repeated flood of GPS + text over all transports (TTL=5) | Protocol engineer |

> **Implementation note (Oct 2026 — `sim/mesh_sim` + `src/`, evidence in `docs/06-simulator-findings.md` §11.1–§11.2):** implemented and measured. Each flood is a *fresh message id* — the
> seen-cache is keyed on the id, so a repeat that reused one would be dropped by every node that
> already heard it — tied together by `sosId` and carrying the sender's position at that moment, so a
> moving sender stays trackable. At TTL 7 in the 60-node crowd, going from 1 flood to 4 takes reach
> **89.4% → 100.0%**; with link-layer retries disabled in a degraded world it takes it **40.8% → 55.3%
> → 64.5%** at 1/4/7 floods. Cost is real and tracked: four floods are 3.9× the transmissions of one.
| Security audit prep | External audit (Cure53-style); panic wipe (one-tap key zeroization) | Crypto engineer + external |

**Exit criteria:** 2 phones exchange image <10 MB over Wi-Fi Direct; PTT Opus note plays in <3 s 1-hop / <8 s 3-hop; SOS reaches all within TTL.

#### Phase 4 — Polish, iOS & Scale (Weeks 25–36)

**Goal:** Shippable to real beta users.

| Workstream | Deliverables | Owner |
|------------|-------------|-------|
| iOS harden | BLE-only Android↔iOS interop; background scan throttling UX ("keep in foreground for mesh"); MPC fallbacks | iOS engineer |
| Wi-Fi Aware probe | Android 26+ & iOS 26 compat test — feature-flagged experiment | Android + iOS engineers |
| Group UX | Invite via QR, admin key rotation, leave/rejoin sync | Flutter engineer |
| Hop visualization | "via 2 nodes • SUPER Amir" trace for transparency | Flutter engineer |
| Performance | 50-node density test (emulator + 15 real phones); battery <15%/8h NORMAL | QA engineer |
| Onboarding | 3-slide explainer (no internet needed, keep Bluetooth on, short-range not internet replacement) | Flutter engineer + designer |
| Distribution | Play + APK + F-Droid + GitHub Releases + TestFlight; GMS-less Huawei fallback | All engineers |

**Exit criteria:** Closed beta 50–100 users at university/festival; Android delivery ratio >90% at 3 hops; iOS companion usable.

#### Phase 5 — Launch & Beyond (Weeks 37–52)

**Goal:** Public launch + community ecosystem.

| Workstream | Deliverables | Owner |
|------------|-------------|-------|
| Launch | v1.0 (Android) + v0.9 (iOS) public release | All |
| Offline maps | Optional integration (OSHI pattern) | Flutter engineer |
| Plugin SDK | `offline-protocol`-like SDK for third-party apps to join Duman mesh | Protocol engineer |
| Community SUPERs | "Keep Duman on a plugged tablet at your café → community relay" program | — |
| Analytics | Opt-in only, local-first: anonymous hop counts to refine scoring | QA engineer |

### 3.4 Talent Requirements Matrix

Duman requires a lean team (4 FTE core + 1 part-time) with highly specialized skills. The dominant cost is test devices (15–20 mixed Android) + external security audit ($15–30k).

| Role | FTE | Key Competencies | Primary Deliverables | Phase(s) |
|------|-----|-------------------|----------------------|----------|
| **Flutter / Protocol Engineer** | 1.0 | Dart, Flutter, Riverpod, CRDT design, MANET routing algorithms, BATMAN/OLSR familiarity, state machine design | Core protocol layer (routing, DTN, CRDT sync), app UI, state management, mesh simulator | 0–5 |
| **Android Native Engineer** | 1.0 | Kotlin, Android BLE stack (`BluetoothGattServer`, `BluetoothLeScanner`), `WifiP2pManager`, ForegroundService, WorkManager, Android 12+ permission model, vendor BLE quirks (Samsung/Xiaomi/Huawei) | BLE GATT transport, Wi-Fi Direct transport, foreground service, battery optimization, no-GMS fallback | 0–4 |
| **iOS Native Engineer** | 1.0 | Swift, CoreBluetooth (`CBPeripheralManager`/`CBCentralManager`), MultipeerConnectivity, iOS background mode limitations, state restoration, Info.plist entitlements | iOS BLE transport, MPC transport, background BLE (degraded but functional), iOS companion app | 0–4 |
| **Cryptography / Security Engineer** | 1.0 | Noise protocol framework, X3DH, Double Ratchet, libsodium/FFI, Ed25519/X25519, AEAD (ChaCha20-Poly1305), secure enclave/keystore integration, threat modeling, audit liaison | Identity layer, E2EE engine, QR trust flow, panic wipe, external audit preparation | 0–3 (full-time), 4–5 (part-time) |
| **QA / Field Test Engineer** | 0.5–1.0 | Test automation, mesh simulation design, RF testing (attenuated boxes), field test methodology, Battery Historian, metrics dashboards, multi-device lab management | Mesh simulator (`mesh_sim.dart`), CI mesh regression tests, field test reports per phase, battery/performance validation | 1–5 |
| **Product Designer (part-time)** | 0.3 | Mobile UX, onboarding flows for unconventional apps, permission rationale design, accessibility, honest-messaging copy | Onboarding slides, permission dialogs, PTT UX ("Hold to Talk" not "Call"), SUPER-mode warnings | 3–4 |

**Competency gaps to watch:**

- **Low-level BLE GATT server experience** is rare. Most mobile BLE work is client-side (scanning, reading). Duman needs *peripheral/server* mode (advertising + GATT server characteristics), which is less commonly done. The Android and iOS engineers must have this specifically — not just general mobile experience.
- **MANET routing on non-IP transports** is unusual. Standard BATMAN/OLSR run over IP; Duman runs over BLE GATT (byte-stream, not packet-switched). The protocol engineer must understand how to adapt routing algorithms to a connection-oriented, low-MTU transport.
- **Audio/Opus on mobile** may require a short-term specialist during Phase 3 if the team lacks media codec experience. `opus_dart` handles encoding but the jitter buffer and sequential playback pipeline need audio engineering care.

**Team formation recommendation:** Hire the Flutter/protocol engineer and Android native engineer first (Phase 0–1 can progress with 2 people + part-time crypto). Add the iOS engineer by Phase 1 (for beacon parity). Add crypto full-time by Phase 1. QA joins at Phase 1 for the mesh MVP field test.

---

## Summary Verdict

| Question | Answer |
|----------|--------|
| Is a serverless BLE/Wi-Fi mesh messenger buildable? | **Yes**, as a hybrid mesh (BLE + Wi-Fi Direct), Android-first, with honest scoping. |
| Can it do real-time voice calling? | **No**, not across multi-hop. Push-to-talk voice notes only; streaming only 1-hop Wi-Fi Direct. |
| Can iOS match Android? | **No**. iOS = BLE-only companion (no Wi-Fi Direct interop with Android, background BLE throttled). |
| Is the smart router algorithm feasible? | **Yes**. BATMAN-lite + MPR flood suppression + coverage-score election is proven MANET theory adapted to phones. |
| Is the security model sound? | **Yes**, with audit. Noise_XX + QR trust-on-first-use + libsodium is the right offline pattern. No custom crypto. |
| What's the team and timeline? | **4 FTE × 12 months** (Flutter/protocol, Android, iOS, crypto) + 0.5 QA + 0.3 designer. External audit $15–30k. |
| What's the biggest risk? | **iOS parity expectation.** Must be communicated as "companion" from day one. Second: battery drain in SUPER mode. |

**Bottom line:** Duman is buildable and differentiated if scoped as an Android-first pager + mesh-text + push-to-talk walkie-talkie + smart relay network. It is not a cellular replacement, not a full-duplex call app, and not an iOS-parity app. Market it honestly, and it fills a real gap for campuses, festivals, disaster relief, and censored streets.
