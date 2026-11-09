# Mobile release readiness

**Historical status as of 2026-11-05: NOT READY — mobile app not started.** This is a gate checklist, not a store submission or release authorization.

**Current update (2026-11-08):** Flutter UI source and widget tests now exist, but no Android/iOS host, lockfile, Flutter test/build, emulator/simulator, or physical-device evidence exists. There is still no native transport, production key store, or handset build. The owner’s standalone Flutter APK smoke test is not a DumanMessenger build. See [implementation status](../../reports/mobile/IMPLEMENTATION-STATUS.md) and [device matrix](../../reports/mobile/DEVICE-TEST-MATRIX.md).

## Current gate ledger

| Gate | Minimum evidence | Status |
|---|---|---|
| G0 — source, environment, architecture, baseline evidence | Record current source boundary, local tests, blocked tools, reuse limits, and architecture/security risks. | **Evidence recorded; not a clean pass.** The TypeScript suite has 10 failures at the unchanged 5,000 ms test timeout; Dart tests and mobile tools are unavailable. See [TEST-RESULTS.md](../../reports/mobile/TEST-RESULTS.md). |
| G1 — platform build and launch | Build, install, and launch Android and iOS apps independently, with source/app SHA and exact environment. | **NOT ACHIEVED.** Shared source/tests exist, but generated platform hosts, lockfile, and build/install/launch evidence are pending. Do not infer G1 from the browser simulator or standalone APK. |
| G2 — minimum real messaging and security | Reviewed identity/exchange-key binding, trust/SAS, maintained crypto provider, encrypted durable store, crash/replay safety, native BLE path, end-to-end text acceptance. | **NOT STARTED.** No real-device messaging or production security claim. |
| G3 — device/interoperability readiness | Android and iOS emulator/simulator paths plus physical-device Android, physical-device iOS, and cross-platform Android↔iOS tests, reported separately. | **NOT STARTED.** See [DEVICE-TEST-MATRIX.md](../../reports/mobile/DEVICE-TEST-MATRIX.md). |
| G4 — store and operational readiness | Owner-approved signing, privacy/data-safety material, support/incident ownership, SBOM/license review, upgrade/rollback, release checklist, and store-specific validation. | **NOT STARTED.** No signing/account state or release pipeline was assessed. No credentials were requested or stored. |
| Simulator release baseline | Preserve simulator semantics and satisfy its existing tests before calling the simulator baseline green. | **NOT READY.** Current local TypeScript suite has 10 strict-timeout failures; Dart suite unavailable. The historical five-hop `>90%` objective is not established by this run. |

## Distribution decisions and constraints

### Android

- **Target:** Google Play, as specified by the owner.
- Google Play upload, production track rollout, signing, or publication has **not** been authorized by this milestone.
- Before release, select and validate package ID, versioning, current required target API, permissions, signing-key ownership, privacy/data-safety declarations, store materials, upgrade/rollback path, and support owner. Check current Play requirements at release time; this assessment does not freeze a target API or generate signing material.

### iOS

- **Implementation and testing are required.** A missing App Store release decision does not waive iOS builds, simulator tests, physical-device tests, or Android↔iOS interoperability testing.
- **App Store distribution is not authorized.** Do not prepare or submit an App Store release, create a distribution profile, or represent an App Store decision as approved. The owner must make a separate explicit decision.
- iOS development and device signing require an owner-controlled macOS/Xcode environment and credentials. No such secrets or account details were sought or recorded here.

## Release blocker checklist

### Build and provenance

- [ ] Create and review a buildable Flutter project with pinned, compatible Flutter/Dart/Android/iOS toolchains and lockfiles.
- [ ] Verify Android debug build, install, and launch on a recorded Android environment.
- [ ] Verify iOS build, install, and launch on a recorded iOS Simulator environment; verify physical-device signing/launch on an approved iPhone.
- [ ] Record reproducible build commands, source/app SHA, dependency versions, artifact hashes, and clean/dirty state.
- [ ] Keep emulator/simulator, physical-device, and simulation evidence distinct.

### Security, privacy, and data integrity

- [ ] Resolve Ed25519 identity to X25519 exchange-key binding and authenticate the mapping in the protocol/transcript.
- [ ] Define immutable authenticated payload versus mutable bounded forwarding metadata; review replay, downgrade, routing-field tampering, and framing.
- [ ] Select and review a maintained crypto provider; test shared vectors and cross-platform interoperability. No production use of Node `node:crypto` reference code.
- [ ] Define OS key protection, identity recovery/rotation, encrypted store, transactional ratchet state, crash/rollback behavior, deletion limits, backup, and retention.
- [ ] Perform independent protocol/security review and dependency/SBOM/license review; verify no keys or plaintext in diagnostics.
- [ ] Complete privacy notice/data-safety review with a responsible controller/support owner; do not claim compliance from a draft policy.

### Radio, lifecycle, and user-visible functionality

- [ ] Approve BLE service UUID, supported device/API range, advertisement feasibility, frame version, MTU/fragmentation, flow control, cancellation, and retry semantics.
- [ ] Verify Android and iOS native discovery/connection/send/receive, permission denial/revocation, disconnect/reconnect, foreground/background behavior, and screen-off behavior on physical devices.
- [ ] Verify real Android↔Android, iOS↔iOS, and Android↔iOS text exchange with synthetic identities, loss, duplicate/replay, process restart, and SAS mismatch cases.
- [ ] Demonstrate truthful delivery states; discovery alone must not authenticate a peer, and OS queue acceptance must not be shown as peer receipt.
- [ ] Gate groups, voice, files, Wi-Fi paths, background operation, and battery claims on their own protocol, security, physical-device, and lifecycle tests.

### Store and operations

- [ ] Confirm Android Google Play target requirements and listing materials at release time.
- [ ] Obtain owner-approved Android signing and release pipeline; keep credentials outside this repository and chat.
- [ ] Obtain a separate explicit owner decision before any App Store distribution work or submission.
- [ ] Define privacy/support/incident ownership, version policy, upgrade/rollback, crash-reporting privacy, and release approvals.

## Evidence policy

A browser build, simulator pass, Dart unit test, source-code audit, or emulator/simulator launch cannot be represented as a real-device secure-messaging pass. No mobile functionality may be marked complete until the relevant Android and iOS builds/launches and the separate device matrix are verified. Nothing in this checklist authorizes GitHub Actions, external publication, deployment, store upload, or release.
