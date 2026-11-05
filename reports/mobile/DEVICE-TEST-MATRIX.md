# Device and environment test matrix

**Snapshot date:** 2026-11-05
**Current mobile evidence:** none. This matrix separates modeled simulation, Android emulator, iOS Simulator, and physical-device evidence. Passing a row in one category must never be reported as a pass in another.

## Evidence labels

- **SIMULATION:** deterministic model or protocol-reference tests in `src/` or `sim/mesh_sim/`.
- **ANDROID EMULATOR:** compiled app installed in Android Emulator. This can validate Android build/UI/integration paths available to that emulator; it does not prove physical BLE behavior, vendor interoperability, background delivery, or battery use.
- **IOS SIMULATOR:** compiled app installed in iOS Simulator. This can validate iOS build/UI and selected lifecycle paths; it does not prove physical CoreBluetooth behavior or sustained background operation.
- **PHYSICAL ANDROID / PHYSICAL IOS:** named devices and OS versions with documented procedure and observed output. Needed for radio, vendor, permission, lifecycle, and power conclusions.
- **CROSS-PLATFORM PHYSICAL:** real Android↔iOS peers. Required for interoperability claims.

## Current evidence ledger

| Surface | Evidence class | Current result | Evidence / limitation |
|---|---|---|---|
| TypeScript browser simulator and reference protocol | **SIMULATION** | **517/527 pass; 10 strict-timeout failures** | `npm test -- --reporter=verbose`; see [TEST-RESULTS.md](TEST-RESULTS.md). The existing 5,000 ms limit was retained. |
| TypeScript static check and production browser bundle | **SIMULATION / web build** | **Pass** | `npm run typecheck` and `npm run build`; no mobile code is built. |
| Local simulator deployment checks | **SIMULATION / local Node server** | **5/5 pass** | `npm run test:deployment`; not a phone or radio test. |
| Pure-Dart authoritative simulator | **SIMULATION** | **Not run** | 13 Dart test files exist; Dart SDK unavailable. |
| Flutter widget/integration tests | **APP TESTS** | **Not run / no project** | No Flutter app or Flutter SDK. |
| Android Emulator | **ANDROID EMULATOR** | **Not run / blocked** | No Flutter, JDK, Gradle, Android SDK, `adb`, emulator runtime, or Android app project in this host. |
| iOS Simulator | **IOS SIMULATOR** | **Not run / blocked** | Linux host; no Xcode/iOS SDK/Simulator or iOS app project. |
| Physical Android | **PHYSICAL ANDROID** | **Not run** | No device/build artifacts or native adapter. |
| Physical iPhone | **PHYSICAL IOS** | **Not run** | No device/build artifacts or native adapter. |
| Android↔iOS real-peer exchange | **CROSS-PLATFORM PHYSICAL** | **Not run** | No native transports, installable app, or physical-device evidence. |

## Planned test matrix after a buildable app exists

Device models, minimum/current OS versions, and coverage count must be selected before acceptance; they are **TBD**, not inferred here.

| Platform / class | Planned test | Evidence to record | Current status |
|---|---|---|---|
| Android Emulator | Clean debug install, first launch, navigation, process recreation, no-network behavior, permission prompts/denial/revocation, app upgrade and local reset. | Emulator image/API, host/tool versions, APK hash, logs with synthetic data, pass/fail by case. | Blocked: toolchain and app absent. |
| Android Emulator | Native bridge lifecycle and malformed/oversized frame handling, bounded queue behavior, cancellation/disconnect UI. | Emulator-only integration test results; clearly label any radio behavior as simulated by the emulator. | Blocked. |
| iOS Simulator | Clean build/install/launch, onboarding, permission denial, UI state restoration, process restart, data-reset behavior. | Xcode/iOS Simulator versions, simulator model/runtime, app build ID, case results. | Blocked: macOS/Xcode and app absent. |
| iOS Simulator | Bridge error paths and malformed frame bounds using controlled test input. | Simulator-only integration results; no CoreBluetooth/physical radio claim. | Blocked. |
| Physical Android pair | Advertise/scan, peer identity separately from discovery, connect/disconnect, text-frame exchange, MTU/fragment boundaries, loss/retry, screen off, process death, permission revocation, reconnect. | Exact device models, OEM, OS/API, app SHA, permissions, distance/topology, repetitions, event timestamps, observed delivery state, battery/thermal context. | Blocked: no native adapter or devices. |
| Physical iOS pair | CoreBluetooth discovery/connection/send/receive; foreground/background transitions, screen lock, app suspension/termination, restoration/reconnect limits, permission denial/revocation. | Exact device models and iOS version, Xcode/app build SHA, lifecycle case outcomes, connection and delivery records. | Blocked. |
| Cross-platform physical pair | Android↔iOS exchange in both initiation directions; scan/connect role combinations, loss, duplicate, retry, simultaneous open, permission changes, reconnect, app background/foreground. | Pairing matrix (Android device/OS × iPhone/iOS), app SHA on each, test script, packets/frame versions, outcomes; synthetic identities and bodies only. | Blocked. |
| Persistence/security (physical and automated fault tests) | SAS mismatch, unverified peer, forged/duplicate/replay frames, process kill between receive/auth/store steps, disk full, backup/rollback, corrupted database, key rotation/clear, reinstall. | Test-provider version and vector set, fault injection point, before/after ratchet/message state, logs proven free of keys/plaintext. | Blocked: no production crypto or store. |
| Later feature gates | Group key rotation/leave/history, files, voice/audio permissions, larger radio paths, background duty cycle, power/thermal measurement. | Separate feature-specific protocol/security review and physical-device matrix; no inheritance from simulator pass. | Not started. |

## Reporting rules

1. Keep simulator results, emulator/simulator results, and physical-device results in separate sections and label each with exact source/app SHA.
2. An emulator build or UI test is not a physical BLE test. A simulator radio model is not an emulator and is not a device.
3. Record no result as “pass” without the device/runtime, version, procedure, and observed output. A missing tool/device is **BLOCKED / NOT RUN**, not passed.
4. Do not claim reliable background or always-on mesh based on a foreground demo. Do not claim five-hop `>90%` delivery from this matrix without separately validated, current evidence.
5. iOS implementation/testing is required. **App Store submission/publication is not authorized** and remains a separate owner decision; device testing is still required regardless of that decision.
