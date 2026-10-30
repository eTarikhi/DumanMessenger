# 02 — Technical Architecture & Stack Selection

> 2026-10-29 deployment clarification: Current implementation boundary: only simulator/CLI and Node reference crypto exist; native radios/app/secure persistent storage are not implemented. See [deployment baseline](18-deployment-baseline.md).
## Evaluated Paths → Selected Way

---

### 1. Requirements Recap

- P2P messaging (1:1 private, group, broadcast)
- PTT voice (walkie-talkie) + optional real-time 1-hop call
- Smart router relay to extend coverage
- Fully offline: no server, no internet, no SIM
- Android + iOS (graceful degradation)
- E2EE, forward secrecy, panic wipe
- Store-and-forward for intermittent partitions

---

### 2. Options Considered

#### Option A — Native Android (Kotlin) + Native iOS (Swift)
**Pros:** Max control over BLE/WiFi, background modes.
**Cons:** 2 codebases, 2x cost, slow iteration. WiFi Direct / Multipeer still need separate impl.
**Verdict:** Overkill for MVP; consider later for ultra-optimization.

#### Option B — React Native + Native Bridges
**Pros:** One JS codebase, mature BLE libs (`react-native-ble-plx`, `react-native-ble-mesh` [1](https://github.com/suhailtajshaik/react-native-ble-mesh)), Expo support.
**Cons:** RN BLE plugins less stable than Flutter per reports [2](https://novelbits.io/native-vs-cross-platform-bluetooth-low-energy-mobile-app-platforms/); bridge throughput lower.
**Verdict:** Viable alternative. Second choice.

#### Option C — Flutter + Native Transport Modules (SELECTED)
**Pros:**
- `flutter_blue_plus` / `flutter_reactive_ble` considered most stable Flutter BLE plugins [2](https://novelbits.io/native-vs-cross-platform-bluetooth-low-energy-mobile-app-platforms/)
- Existing open mesh plugins: `flutter_mesh_network` (BLE + WiFi Direct + WiFi Aware) [3](https://github.com/ozcode2009/flutter_mesh_network), `cross_p2p_network` (NSD/Bonjour), `bridgefy SDK` [4](https://pub.dev/packages/bridgefy), `offlinemesh` (Kotlin/Swift GATT+WiFi Direct) [5](https://github.com/HcDragon/offlinemesh)
- MethodChannel/EventChannel pattern for native BLE is well-trodden [6](https://uynguyen.github.io/2026/03/14/Best-practice-BLE-cross-platform-iOS-Flutter-ReactNative/)
- Single Dart codebase + shared CRDT/protocol layer
- KMP-ready if needed later
**Cons:** Still needs native Kotlin/Swift for GATT server, WiFi Direct, foreground service.
**Verdict:** ✅ **SELECTED — best balance of speed + control**

#### Option D — Use Bridgefy SDK / Offline Protocol SDK as engine
**Pros:** Off-the-shelf mesh (Bridgefy SDK gives 100% offline mesh over BT+WiFi Direct [7](https://bridgefy.me/sdk/)), MLS encryption, 8 hops. Quick.
**Cons:** Proprietary (Bridgefy) or heavy RN dependency (Offline Protocol). Vendor lock-in, pricing.
**Verdict:** Use as **reference/inspiration**, not core dependency. Build own `DumanTurbo` transport layer to stay open-source & auditable.

---

### 3. Selected Architecture: Duman Hybrid Mesh Stack

```
┌─────────────────────────────────────────────────┐
│  Flutter UI (Dart) : Chats, Groups, PTT, SOS    │
│  State: Riverpod/Bloc + SQLite + CRDT Sync      │
├─────────────────────────────────────────────────┤
│  Duman Core (Dart)                              │
│  • Identity (X25519 + Ed25519)                 │
│  • E2EE (Noise_XX + Double Ratchet)            │
│  • Packet Router (TTL, dedup, flood/MPR)       │
│  • Store-and-Forward Queue (Delay-Tolerant)    │
│  • Super-Node Scorer (coverage algorithm)      │
├─────────────────────────────────────────────────┤
│  Transport Abstraction: MeshTransport interface   │
│  ┌──────────┬──────────────┬─────────────────┐ │
│  │ BLE GATT │ WiFi Direct  │ WiFi Aware /   │ │
│  │ (Android │ (Android)    │ Multipeer      │ │
│  │  Kotlin  │  Kotlin)     │ (iOS Swift)    │ │
│  │  + iOS)  │              │  + And. Aware  │ │
│  └──────────┴──────────────┴─────────────────┘ │
│  Strategy: auto-select by payload size/battery  │
├─────────────────────────────────────────────────┤
│  Platform Services                              │
│  • Foreground Mesh Service (Android)            │
│  • bluetooth-central bg mode (iOS)              │
│  • Permissions: BT_SCAN/CONNECT, WiFi, Location│
└─────────────────────────────────────────────────┘
```

#### 3.1 Transport Strategy (Auto)

| Payload | Chosen Transport | Rationale |
|---------|------------------|-----------|
| Discovery (hash beacon 12 B) | BLE Advertising | Always-on, lowest power |
| Text  (<1 KB) | BLE GATT | Reliable, low power |
| Voice PTT 1-15s Opus (~10-40 KB) | WiFi Direct if peer supports, else chunked BLE | Speed vs power |
| Image/File (<10 MB) | WiFi Direct | 250× faster than BLE [1](https://github.com/suhailtajshaik/react-native-ble-mesh) |
| Broadcast SOS | All transports flooding | Maximize reach |

- **Dart side** holds a `TransportRegistry` that scores transports: `score = (availability * linkQuality / powerCost)`
- On Android, internally can use **Google Nearby Connections** as shortcut where GMS present, fallback to raw `WifiP2pManager` + `BluetoothLeScanner/GattServer` on de-Googled devices. On iOS, use **MultipeerConnectivity + CoreBluetooth**.

#### 3.2 Mesh Routing — Two-Plane Design

- **Control plane (BATMAN-lite):** Every node broadcasts an Originator Message (OGM) every 2s containing `nodeId, seq, battery, peerCount, isSuperNode, bestHopToOriginators`. Nodes only store **best-next-hop per destination** (not full topology) → memory efficient for phones [8](https://ar5iv.labs.arxiv.org/html/1804.02139).
- **Data plane (Flood + MPR):** Messages flood via MPR set, not all nodes. Each msg has `ttl=5-7`, `msgId (dedup cache 5 min)`, `hopCount`.
- **Delay-Tolerant extension:** If no route to destination, queue in `OppQueue` (SPF-inspired OLSR-OPP [9](https://link.springer.com/article/10.1007/s11277-016-3323-8)) and **store-carry-forward** when new peer appears.

#### 3.3 Super-Node (Smart Router) Election — Summary (full in 03-)

Each node computes locally:
```
coverageScore = w1*norm(peerCount) + w2*norm(avgRSSI) + w3*batteryLevel + w4*stabilityUptime - w5*mobilityPenalty
```
- If score in top 20% of 2-hop neighborhood → self-promote to `SUPER` via OGM flag.
- SUPER nodes: scan aggressively, relay for all, create WiFi Direct group (GO) if needed.
- NORMAL nodes: duty-cycle aggressively, prefer SUPER as next hop.
- Re-evaluated every 30s with hysteresis (need +10% margin to demote/promote → no flapping).

#### 3.4 Data sync: CRDT vs Packet-Relay

Two valid models exist:
- **Packet-relay (Bridgefy/bitchat):** hop-by-hop packet forwarding to destination.
- **CRDT merge (Meshenger/offlinemesh):** phones merge DB rows; multi-hop emerges via fingerprint gossip [10](https://github.com/ebregger/Meshenger).

**Duman uses BOTH:**
- **Direct messages/calls:** packet-relay (needs routing).
- **Group chat / broadcast channel history:** CRDT (eventual consistency via `hash + anti-entropy sync` over BLE). This handles partitions gracefully.

#### 3.5 Voice Architecture (Walkie-Talkie Realism)

- **Not full duplex cellular call.** UX = **Push-to-Talk** button (like Zello):
  1. Press → record Opus 8-16 kHz (very low bitrate, 6-12 kbps).
  2. Chunk into 500 ms frames, encrypt per-frame, send over WiFi Direct if connected else BLE chunked.
  3. Receiver plays sequentially; jitter buffer 200 ms.
- **1-hop “live call” bonus:** If two peers are WiFi Direct-connected and `ttl=1`, allow streaming PTT with 150-300 ms latency (acceptable). Multi-hop voice = store-and-play, not live.
- Future: add **WiFi Aware data path** for lower-latency streaming where hardware supports.

#### 3.6 Persistence

- **SQLite (drift)** for messages, peers, queue.
- **12-byte BLE beacon:** 8-byte DB hash + 4-byte node prefix (as Meshenger does) [10](https://github.com/ebregger/Meshenger) → neighbors instantly know if they’re out of sync.
- **Offline media cache:** encrypted at rest (SQLCipher optional).

#### 3.7 Background & Power

- Android: `ForegroundService (type: connectedDevice)` + persistent notification “Duman Mesh Active • X peers”. WorkManager to restart after kill. Battery optimization exemption request.
- iOS: `bluetooth-central` + `bluetooth-peripheral` + state restoration key; document that mesh works best foreground; background = beacon + re-connect on wake.
- Adaptive duty cycling: SUPER = continuous, NORMAL = scan 3s / sleep 7s.

#### 3.8 Cross-Platform Interop Matrix

| Pair | Path | Notes |
|------|------|-------|
| Android ↔ Android | BLE + WiFi Direct + Nearby if GMS | Full mesh, 5 hops, PTT. |
| iOS ↔ iOS | MultipeerConnectivity + BLE | Full mesh within Apple ecosystem. |
| Android ↔ iOS | **BLE GATT only** | Text + PTT fallback chunked; no WiFi Direct interop. Document honestly. |
| Future: WiFi Aware unified | Aware is shared spec | Once Android & iOS Aware interoperate → add as primary. |

---

### 4. Why Not Pure BLE Mesh Spec?

Because **phones cannot be full BLE Mesh nodes** — only proxy clients, requiring external mesh gateways [11](https://citrusdev.com.ua/bluetooth-mesh-in-mobile-devices-the-complete-guide-for-2025/). Duman therefore builds a **phone-native mesh over BLE GATT + WiFi**, not over the Nordic BLE Mesh library. More work initially, but works on stock phones without accessories.

---

### 5. Tech Stack Checklist

- **App Framework:** Flutter 3.22+ (Dart 3.4)
- **Native Bridges:** Kotlin (Android) • Swift (iOS)
- **BLE:** `flutter_blue_plus` + custom GATT server/peripheral (native)
- **WiFi Direct:** `WifiP2pManager` (Android) • MultipeerConnectivity (iOS)
- **DB:** drift (SQLite) + optional sqlcipher
- **Crypto:** `cryptography` (Dart) + libsodium via FFI for X25519/Ed25519/Noise
- **Audio:** `flutter_sound` / `opus_dart` + native Opus
- **State:** Riverpod
- **Build:** F-Droid + Play + APK sideload + TestFlight

---

### 6. Key Metrics to Hit

- Discovery latency < 3s (BLE beacon interval 500 ms)
- Text delivery < 2s (1 hop), < 5s (3 hops)
- PTT voice note < 3s end-to-end (1 hop WiFi Direct), < 8s (3 hops BLE)
- Battery overhead < 15% / 8h (NORMAL mode)
- Support 50+ nodes in dense area (like a campus quad)
