# G0 baseline — simulator and mobile application

**Snapshot date:** 2026-11-05
**Scope:** This report treats G0 as the requested source, environment, and feasible-test assessment. G0 evidence is recorded, but the baseline is **not a pass**: the current TypeScript suite has ten strict-timeout failures, the Dart suite could not run, and there is no mobile project or platform toolchain. G1 has not been reached.

## Source and evidence provenance

| Item | Recorded value |
|---|---|
| Repository | `eTarikhi/DumanMessenger`, checkout `/home/user/DumanMessenger` |
| Branch | `arena/be8aa6c3-dumanmessenger` (active) |
| Source commit tested | `a1f1916981c2244a2f8664573b66afbd5a2659b4` |
| Parent | `bdf719cf88205f944187cb79b8288264a56c13bd` |
| Commit meaning | Empty branch checkpoint; its tree is the same as its parent. It is not a new simulator implementation. |
| Working tree at test start | Clean; source files were not modified by the test run. |
| Historical evidence | Historical `527/532` and five-second-timeout observations are not results for this source snapshot. See [current test results](TEST-RESULTS.md). |

The original Windows checkout is not accessible from this environment and was not searched. The previously discussed Phase D archive reconstruction was declined and is not part of this work.

## Repository implementation boundary

| Area | What exists | What it does **not** establish |
|---|---|---|
| Browser simulator | React 18 / TypeScript / Vite UI in `src/`; deterministic simulation and synthetic chat/metrics. UI state is in memory. | Not a Flutter app, not a handset messenger, and not a real radio or secure storage implementation. Component tests are rendered/test-harness evidence, not a manual browser or device launch. |
| Authoritative simulator | Pure-Dart package `sim/mesh_sim/`, including the discrete-event engine, routing/election, radio model, simulator scenarios, `MeshTransport` contract, and `SimulatedMeshTransport`. The package documents shared fixtures at `test-fixtures/golden-vectors.json`. | Not a Flutter app. `SimulatedMeshTransport` drives `MeshSimulation`; it is not a Bluetooth implementation, and its simulated clock/delivery behavior is not evidence of OS radio behavior. Dart analysis/tests were not executable here. |
| TypeScript transport helpers | `src/transport.ts` defines beacon encoding/decoding and related byte-format helpers. | No scanner, advertiser, GATT connection, operating-system lifecycle, retransmission over a real link, or native adapter. |
| Crypto/protocol reference | `src/crypto/` contains an implemented reference protocol layer (identity/QR, Noise XX, a symmetric ratchet, packet framing) on `node:crypto` / OpenSSL. `src/crypto/primitives.ts` imports `node:crypto`; browser-import tests protect that boundary. | Not a mobile crypto provider or production key store. Key material is held in ordinary JS buffers; zeroization is best-effort. No Android Keystore/Secure Enclave integration or verified Dart/native port exists. |
| Deployment tooling | `tool/deploy/` packages and serves the browser simulator; local deployment tests exercise package integrity and an HTTP server. | Does not package, sign, install, or publish an Android or iOS app. |
| Flutter/mobile projects | None found: no Flutter app `pubspec.yaml`, `android/` project, `ios/` project, Gradle wrapper, or Xcode project. The only tracked `pubspec.yaml` is `sim/mesh_sim/pubspec.yaml`. | No mobile functionality can be claimed. |

## Reuse assessment

Reuse is conditional on parity, threat-model, and production-boundary review; code that models a radio is not a radio implementation.

| Candidate | Decision for the mobile workstream |
|---|---|
| Routing, deterministic event rules, radio assumptions, and golden vectors in `sim/mesh_sim/`, `src/`, and `test-fixtures/` | Reuse as **specification, test oracle, and research evidence**. Extract production-safe pure-Dart domain logic only after documenting the exact boundary and preserving simulator behavior/goldens. Do not make the production app depend on the simulator clock or simulated delivery. |
| Dart `MeshTransport` API in `sim/mesh_sim/lib/src/transport.dart` | Useful as a **starting contract**, not yet a production interface. It is adjacent to simulator types and describes simulated send/ACK behavior. A production contract must define capabilities, asynchronous discovery, MTU/framing, fragmentation, partial writes, acknowledgements, cancellation, link loss, permissions, and lifecycle explicitly. |
| 12-byte beacon layout in Dart and TypeScript | A candidate interoperability vector after choosing a real, fixed BLE service UUID and validating platform advertisement limits. Its database digest and 32-bit node alias are public, unauthenticated discovery data, not identity proof, privacy protection, or a cryptographic primitive. `DUMAN_MESH_SVC` is a simulator label, not a verified production UUID. |
| `src/crypto/` protocol code and tests | Reference material for a separately reviewed implementation and cross-language vectors only. Do not import it into Flutter or treat it as deployable crypto. Resolve the identity/key binding and routing-header questions in [architecture](../../docs/mobile/ARCHITECTURE.md) before freezing a wire protocol. |
| React components and simulator UI in `src/` | Keep as the simulator product. Reuse UX ideas only; do not wrap or relabel the browser simulator as the mobile messenger. |

## Environment and platform prerequisites

Observed in this checkout on Linux `6.1.158+`, `x86_64`:

| Tool / capability | Observed state | Consequence |
|---|---|---|
| Node.js / npm | Node `v22.22.3`; npm `10.9.8` | TypeScript baseline commands are locally runnable. |
| Dart / Flutter | `dart` and `flutter` not found | Cannot run `dart analyze`, `dart test`, `flutter test`, or Flutter builds. Do not infer a pass from static source inspection. |
| Android build tools | `java`, `gradle`, `adb`, and `sdkmanager` not found; `ANDROID_HOME`, `ANDROID_SDK_ROOT`, and `JAVA_HOME` unset | Cannot build, install, launch, or test an Android APK/AAB or emulator here. Android SDK/platform/build-tools, compatible JDK, Flutter SDK, and emulator or physical device are prerequisites on an enabled host. |
| Apple build tools | `xcodebuild`, `xcrun`, and `pod` not found; host is Linux | Cannot build or launch an iOS app or simulator. iOS work requires a macOS host with compatible Xcode/iOS SDK and Simulator runtime; device signing also requires owner-controlled signing setup. |
| Emulators / physical phones | Not available through the observed toolchain; no device test was run | No emulator or physical-device evidence exists. Android and iOS device/OS coverage remains TBD. |
| npm dependencies | Initially absent; installed from the committed lock with `npm ci --ignore-scripts --no-audit --no-fund` (100 packages). The `prepare` script was deliberately not run. | Local TypeScript tests/builds could run without changing the lockfile or invoking the package hook that changes local Git configuration. |

Android target: **Google Play**. iOS implementation and testing are required, but **App Store distribution is not authorized**; this is a separate release decision, not a reason to omit iOS engineering or tests.

## Current local test baseline

See [TEST-RESULTS.md](TEST-RESULTS.md) for commands, durations, the ten timed-out tests, and unrun checks.

- `npm run typecheck`: pass.
- `npm run build`: pass for the browser simulator only.
- `npm run test:deployment`: 5/5 pass for the simulator package/server only.
- `npm test -- --reporter=verbose`: 517/527 pass; 10 tests timed out at the existing 5,000 ms limit. The limit was not changed, and no tests were skipped or weakened.
- Dart, Flutter, Android, and iOS tests/builds: not run because their required toolchains/hosts are unavailable.
- GitHub Actions and remote CI: not run.

This run does **not** prove the five-hop `>90%` objective. Historical 527/532 results, historical five-second-timeout evidence, and any prior CI result must remain labelled with their own source hash and provenance; none substitutes for this run.

## Blocking risks to address before mobile implementation

1. **Identity binding is unresolved.** The reference `Identity` derives `nodeId` from the Ed25519 signing public key, while `DumanSession.peerExchangeNodeId` derives a value from the peer's X25519 static key. The QR and Noise static key therefore must be cryptographically bound in the authenticated transcript before a scanned identity can be treated as the session peer.
2. **The packet's mutable routing fields need a wire design.** `src/crypto/packet.ts` authenticates its header as AEAD associated data, including hop/TTL fields. A relay that must change those fields cannot be assumed to preserve that tag. Define an authenticated immutable inner packet and a separately bounded/mutable forwarding envelope—or another reviewed design—before implementing relays; do not silently alter vectors or routing semantics.
3. **The destination hint is not identity hiding.** The literal first-eight-byte hash is a prefix of the advertised node ID; an opaque variant exists in the reference but is not a verified deployed protocol. Discovery beacons are observable and unauthenticated.
4. **Reference crypto is not a mobile security boundary.** Ordinary-memory private keys, best-effort wipes, the absence of a production keystore provider, and the hand-written protocol state machine require a maintained provider, key lifecycle, independent review, and cross-language vectors.
5. **Durability and replay safety are absent.** Crash-safe monotonic send counters, atomic receive-ratchet/message commits, encrypted persistent storage, backup/rollback behavior, and migration/corruption handling are not implemented.
6. **Radio behavior is unverified.** BLE roles, service/advertisement limits, fragmentation and MTU, Android background service/permissions, iOS background restrictions, reconnect, and cross-vendor interoperability need real-device tests. Wi-Fi Direct, Nearby, Multipeer Connectivity, Wi-Fi Aware, plugins, and battery claims in older architecture prose are proposals, not repository capabilities.

## Next gate

The first reviewable milestone in this turn is the evidence and architecture documentation listed in [IMPLEMENTATION-STATUS.md](IMPLEMENTATION-STATUS.md). It does not add a mobile shell or claim functionality. Before the first code scaffold, use an SDK-enabled Android host and a macOS/Xcode host, agree the protocol/key-binding and transport contract, and preserve the current simulator baseline while separately investigating its ten timeouts.
