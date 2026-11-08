# Proposed Flutter / Android / iOS architecture

**Status:** Shared Flutter UI source, widget tests, `pubspec.lock`, and an Android host are checked in under `mobile/app`. A fresh G2-A Android BLE diagnostic foundation now reports local prerequisites and handles the required permission flow; it performs no radio operation and has not been validated on Local PC. No iOS host or messaging/transport adapter is present. Nothing in this document is evidence of a working handset feature or a completed build. The existing simulator remains a separate product and regression baseline.

## 1. Design goals and boundaries

1. Deliver one Flutter client for Android and iOS, with native Kotlin and Swift ownership of OS-specific radio and lifecycle behavior.
2. Keep deterministic simulation separate from production. `sim/mesh_sim/` remains the authoritative simulator package; `src/` remains the browser simulator and Node reference implementation. Neither simulator transport nor simulation clock is the real app transport.
3. Start with a deliberately narrow, measurable real-device slice: installable shell, explicit permissions, discover one peer over a reviewed BLE service, establish an authenticated contact/session, and exchange a bounded text frame. Do not imply multi-hop, always-on background delivery, media transfer, or secure messaging before their independent acceptance tests pass.
4. Keep cryptographic primitives in a maintained, reviewed provider. Do not port `node:crypto`, hand-roll primitives, or expose raw long-term private keys to ordinary Dart/UI state.
5. Make every transport operation asynchronous, cancellable, capability-aware, and explicit about the difference between accepted-by-OS, link-delivered, peer-acknowledged, and application-accepted data.
6. Treat current architecture/skill documents as design inputs, not proof that named plugins, APIs, target versions, radio behavior, or battery budgets were tested.

## 2. Suggested workspace boundaries

Suggested full workspace (the current Flutter shell source/tests and Android host are present; production packages remain proposed):

```text
mobile/
  app/                         Flutter shell, tests, lockfile, Android host present
    lib/                       onboarding, empty conversations, diagnostics, settings, BLE status bridge
    android/                   checked-in Kotlin host; G2-A capability/permission diagnostics only
    ios/                        not generated yet; future Swift host / adapter
  packages/
    mesh_core/                 pure-Dart domain types and orchestration
    mesh_transport/            production transport contract and frame codec
    mesh_crypto/               reviewed provider interface and protocol integration
    mesh_store/                transactional message/session persistence
sim/mesh_sim/                  existing authoritative discrete-event simulator
src/                           existing browser simulator + Node-only references
 test-fixtures/                shared deterministic fixtures; changes gated separately
```

The initial app may keep small Dart packages inside `mobile/app` until the dependency boundaries are proven; avoid a broad package split before there is a buildable shell. Do not make `mobile/packages/mesh_core` depend on the simulator's clock, `MeshSimulation`, or `SimulatedMeshTransport`. Share algorithms only after a line-by-line boundary review and cross-engine tests show behavior is preserved.

### Runtime layers

- **Flutter presentation:** onboarding, contacts, verification/SAS, conversations, delivery state, settings, and permission explanations. Widgets render state; they do not own keys, packet parsing, retries, or native lifecycle.
- **Application/domain:** one serialized per-peer/session actor, message send/receive use cases, connection state, bounded queues, idempotency, and explicit delivery/trust statuses. No UI-triggered parallel mutation of a ratchet or native link.
- **Pure-Dart core:** validated immutable message/routing types, clock abstraction, limits, versioned framing, and deterministic unit-testable orchestration. Keep the simulation engine separate unless an approved extraction demonstrates identical simulation results.
- **Crypto provider boundary:** operations, not exported private-key bytes, for identity creation, signing, key agreement, authenticated encryption, and secure deletion. Select the implementation only after algorithm/platform compatibility, maintenance, license, FFI, and independent security review. Publish cross-language vectors before interoperability work.
- **Storage boundary:** encrypted local store with schema/version handling; one atomic transaction for accepting a message, advancing receive/replay state, and recording the message. Commit send sequence/ciphertext before it can be retried. Define backup, rollback, corruption, panic-clear, and data-retention behavior before promising recovery or deletion.
- **Transport boundary:** Dart facade plus a typed Flutter/native bridge (Pigeon or an equivalently reviewed API is a candidate, not a selected dependency). Native code reports capabilities, permission/lifecycle state, scan events, link events, byte frames, and typed failures. Platform events are untrusted input; every frame is bounded and validated before parsing.
- **Android host (Kotlin):** future approved adapters may own BLE advertising/scanning/GATT roles, runtime permission mapping, connection cancellation, and any foreground-service behavior required by the approved use case. Native code must report OS restrictions; it must not claim a scan or send succeeded merely because a request was queued. The current G2-A host only reports local capability/permission/adapter state; it performs none of those radio operations.
- **iOS host (Swift):** owns CoreBluetooth state, permission mapping, supported central/peripheral operations, restoration behavior if approved, and app lifecycle. Background modes are restricted and must be measured; foreground success does not imply screen-off or terminated-app delivery.

No app state-management package, database, crypto plugin, audio package, or radio plugin is selected by this assessment. Re-evaluate candidates against supported OS versions, licensing, maintenance, FFI/build constraints, and an actual integration test before adding a dependency.

## 3. First transport slice and wire contract

### BLE-first, capability-gated

A BLE-first vertical slice is the smallest cross-platform hypothesis to test. It is not a commitment that BLE alone meets the product's range, throughput, background, or mesh goals. Before native implementation, agree and freeze:

- Supported Android API levels, iOS versions, and the actual test-device set.
- A valid fixed BLE service UUID. `DUMAN_MESH_SVC` in the simulator is a label, not a verified production UUID.
- Advertisement payload feasibility on both OSes, including iOS background behavior, service-data/manufacturer-data restrictions, payload length, and privacy consequences. The existing 12-byte beacon is only a candidate vector.
- Frame version, maximum encoded length, fragmentation/reassembly bounds, duplicate handling, integrity/authentication, MTU negotiation, backpressure, timeout/cancellation, and reconnect semantics.
- Whether a transport completion means native queue acceptance, GATT write completion, link-layer delivery, protocol ACK, or recipient persistence. The current simulator cannot establish these meanings for a phone.
- How device roles and simultaneous connections work when both peers scan and advertise; maximum links and memory/radio work must be bounded.

Keep Wi-Fi Direct, Google Nearby, Multipeer Connectivity, Wi-Fi Aware, and larger media transfers behind capability-negotiated adapters and separate acceptance gates. Existing design prose's cross-platform or performance claims are unverified. Do not treat Android-only Wi-Fi Direct and Apple-only peer APIs as a cross-platform path without physical Android↔iOS tests.

### Identity, trust, and packet format: wire-freeze blockers

Resolve these before implementing an authenticated contact/session or freezing production vectors:

1. **Bind the identity key to the exchange key.** `src/crypto/identity.ts` derives the reference `nodeId` from the Ed25519 signing key; `DumanSession.peerExchangeNodeId` hashes the X25519 static key. The QR identifies one key while Noise XX authenticates another. The authenticated transcript, QR/SAS, and peer record need a reviewed cryptographic binding; a matching display name or unauthenticated mapping is insufficient.
2. **Separate mutable forwarding metadata from authenticated content.** The reference packet uses the header as AEAD associated data and includes hop/TTL, while a router needs to update forwarding state. Define which outer fields are mutable and bounded, which immutable inner fields are authenticated end-to-end, and how replay/downgrade/tampering are detected. Do not change the current simulator protocol, routing defaults, or golden vectors as a shortcut.
3. **Set honest discovery privacy.** The reference's literal eight-byte destination hint is a prefix of the advertised node ID; it does not hide a destination from a relay that has the OGM. `destHintBytesOpaque` is a reference option, not a deployed or validated format. The beacon's 32-bit alias/database digest is observable and unauthenticated. Do not market either as identity secrecy.
4. **Bound the reference crypto claim.** The TypeScript primitives use OpenSSL through `node:crypto`; key buffers and zeroization are not suitable as a mobile security boundary. The reference symmetric ratchet also does not provide a DH ratchet's post-compromise recovery. Select a maintained implementation and independently review protocol composition, key binding, session lifecycle, rollback, and erasure before exposing “end-to-end encrypted” or forward-secrecy claims.
5. **Use crash-safe state.** Persist sequence/ratchet/replay state atomically with message acceptance. A crash, disk-full error, process death, restore, or retry must not reuse a key/nonce or consume a valid receive key on an unauthenticated frame.

## 4. Backlog in dependency order

Mobile work proceeds in parallel with a simulator-preservation track; neither substitutes for the other.

| Order | Work item | Depends on / exit evidence |
|---|---|---|
| **S0 — preserve simulator baseline** | Keep the 5,000 ms Vitest timeout, routing defaults, semantics, thresholds, and goldens unchanged. Reproduce/profile the ten current timeout failures on a supported host before proposing a behavior-preserving optimization. Continue recording simulator evidence separately from phone evidence. | Current run is 517/527 with ten timeouts; see [TEST-RESULTS.md](../../reports/mobile/TEST-RESULTS.md). No fix or performance claim in this milestone. |
| **M0 — G0 evidence and architecture** | Record repository/toolchain/test boundary, risks, device matrix, and release gate. | Completed as documentation in this milestone; does not add mobile functionality. |
| **M1 — owner decisions and protocol/transport contract** | Decide supported OS/device range, app identity/trust flow, background expectations, data/backup/panic-clear policy, service UUID, frame/MTU limits, and crypto provider evaluation. Review identity binding and mutable header design. | Signed-off ADRs, frozen test vectors, threat model, dependency/license review. No radio implementation before this. |
| **M2 — buildable Flutter shell** | Create app project and pin Flutter/Dart/toolchain; set up lint/unit/widget tests and CI configuration only when separately authorized. Keep credentials out of source. | Clean Android debug build/install/launch and iOS simulator build/launch on their respective hosts; still no claim of radio or messaging. |
| **M3 — production core and fixture parity** | Extract/implement only reviewed deterministic domain logic, with explicit clock and simulator-independent APIs. | Shared tests against approved vectors; simulator tests/goldens unchanged unless separately authorized and validated. |
| **M4 — identity, crypto, trust, and storage** | Choose reviewed provider; bind identity/exchange keys; implement QR/SAS; encrypted persistence and transactional monotonic ratchet state. | Independent protocol review plus tamper/replay/downgrade, force-stop/reboot, disk-full, rollback, corruption, and recovery tests. No plaintext/secret diagnostic logs. |
| **M5 — Android/iOS BLE adapters** | Implement the agreed typed bridge, permissions/capabilities, scanner/advertiser/connection, bounded frames, fragmentation, cancellation, and cleanup in Kotlin and Swift. | Host unit/instrumentation tests, emulators/simulators for UI/lifecycle, then physical-device interoperability and permission/background tests. Simulator transport is not acceptable evidence. |
| **M6 — minimal real messaging** | Connect identity/trust, contacts, transport, crypto, durable queue, and Flutter conversation UI for one-to-one text. | Android↔Android, iOS↔iOS, and Android↔iOS physical-device tests with loss, duplicate, disconnect, restart, unverified peer, and explicit delivery states. |
| **M7 — groups, media, background, optimization** | Design group key distribution/history, media framing/storage, audio permissions, larger radio paths, lifecycle/background, and power controls independently. | Separate security, interoperability, battery/thermal, upgrade, and data-retention gates. Do not inherit simulated group/file/voice success as mobile acceptance. |
| **M8 — store/release readiness** | Google Play compliance, package metadata, privacy/data-safety materials, signing, upgrade/rollback, SBOM/license review, support/incident ownership. | Owner-approved release evidence and device matrix. App Store distribution remains a separate explicit owner decision; iOS implementation and testing remain required either way. |

## 5. Platform build and validation prerequisites

| Platform | Required environment before implementation/build evidence |
|---|---|
| Android | Supported Flutter/Dart SDK pinned to the project lock; compatible JDK and Android Gradle tooling; Android SDK platform/build-tools; `adb`; emulator runtime or owner-approved physical phones; permission/service testing. Google Play target API, signing, package identity, privacy declarations, and developer account must be checked against current Play requirements at release time. |
| iOS | macOS with compatible Xcode/iOS SDK, Flutter toolchain, and iOS Simulator runtime; CocoaPods only if selected dependencies require it; a physical iPhone and owner-controlled development signing for device tests. No iOS build can be produced from this Linux host. App Store publication is not authorized. |
| Shared | Pinned dependency lockfiles; lint/unit/widget/integration tests; deterministic test fixtures; no production credentials in repo/chat; a physical Android+iOS pair for cross-platform BLE; synthetic test identities/messages only. Emulator/simulator evidence and physical-device evidence must be reported in separate columns. |

The agent’s Linux environment has Node/npm for the runnable baseline but lacks Dart, Flutter, Java, Gradle, Android SDK tools, Xcode tools, and CocoaPods. The owner reports a separate Windows Flutter/Android setup; it has not been used to build this repository in this session. See [BASELINE.md](../../reports/mobile/BASELINE.md) and [WINDOWS-G1-QUICKSTART.md](WINDOWS-G1-QUICKSTART.md).

## 6. Acceptance terminology

- **Simulation evidence:** results from `src/` or `sim/mesh_sim/`. It tests modeled routing or protocol assumptions only.
- **Emulator/simulator evidence:** a compiled app installed in Android Emulator or iOS Simulator. It can validate builds, UI, and some lifecycle behavior; it cannot prove real BLE, vendor interoperability, sustained background operation, or physical power use.
- **Physical-device evidence:** named devices/OS versions with test procedure and observed results. Required for radio interoperability, background restrictions, and battery/thermal claims.
- **G1:** not achieved until independently recorded Android and iOS app builds **and launches** are verified. A browser build, Dart simulator test, source scaffold, or single-platform build is not G1.

## 7. Historical first reviewable milestone (2026-11-05)

The earlier G0/M3 milestone was documentation-only because its Linux agent had no Flutter/Dart or native build toolchains. Exact files and historical verification are listed in `reports/mobile/IMPLEMENTATION-STATUS.md` and `reports/mobile/TEST-RESULTS.md`. No simulator, protocol, timeout, or routing behavior was changed.

## 8. G1 shared-source baseline

The G1 baseline established Flutter onboarding with explicit limitations, a genuine empty conversations state, local platform/build-mode diagnostics, session-only theme settings, named navigation, and widget tests. It did not contain a BLE permission flow, identity, keys, cryptography, transport, or mesh behavior. The checked-in Android host and `pubspec.lock` are now part of the source tree; no iOS host is present.

The Agent cannot run Flutter/Dart/Java/Android commands. The owner-reported Flutter 3.47.8/Dart 3.13.7 environment and standalone APK do not verify this repository. Use [WINDOWS-G1-QUICKSTART.md](WINDOWS-G1-QUICKSTART.md) for owner-side setup and validation. G1 device/build acceptance remains separate from G2-A source completion.

## 9. G2-A fresh Android BLE diagnostic foundation

G2-A was implemented fresh from G1 commit `58126a9fa0a7628ae04610c1394b7ecfc678d848`; historical G2-A source was not recovered. The optional BLE hardware feature and API-aware permission declarations support installation on devices without BLE. Android 12+ `BLUETOOTH_CONNECT` is requested only when needed to inspect local adapter state. Scan/advertise permissions are declared for API-aware permission reporting but are not requested; legacy Bluetooth permissions are reported on API 30 and earlier. No location permission is declared or requested.

The Kotlin host reports API level, BLE feature, Bluetooth service/adapter availability, adapter enabled state where permission allows, permission status/rationale/re-requestability, and the adapter's advertising-capability flag. A lifecycle-bound event stream reports status changes while the diagnostic screen is subscribed and the Activity is resumed. Flutter presents typed states and permission guidance in Diagnostics navigation and cancels its event subscription on disposal. See [ADR-G2-A-ANDROID-BLE-DIAGNOSTIC-FOUNDATION.md](ADR-G2-A-ANDROID-BLE-DIAGNOSTIC-FOUNDATION.md) for the decision and validation boundary.

This foundation does not scan, advertise, discover, pair, use GATT, connect, enumerate peers or bonded devices, exchange messages/hello, run background BLE/location work, create identity/keys, read adapter name/MAC, or enable Bluetooth/open settings automatically. The future-reserved UUID `5d1796d0-d8f8-406a-8b3d-1a8684447470` is not used. Simulator, routing, transport, golden-vector, thresholds, and acceptance criteria are unchanged. Model, bridge, UI, and navigation tests are authored but were not run by the Agent. Source-level review is not build/device evidence; the owner must validate on Local PC, and G2-A is not accepted until those gates pass.
