# G2-C Reconstruction Execution Checkpoint

**Status: Phase 3 UI/permission source implemented; Phase 4 source audit and Windows handover guide prepared; authenticated protocol selection BLOCKED; uncompiled/unvalidated and G2-C NOT ACCEPTED.** No Flutter analysis/tests/build, Kotlin/Gradle compilation, APK, device/two-device checks, remote operations, or CI were run.

## Baseline and workspace

- Repository: `eTarikhi/DumanMessenger`
- Authoritative `main`: `83606d58ca106496f2da56f5a5676efa0868c0d4` (`origin/main` agrees; no newer main commit observed locally).
- Required baseline: exact match.
- Initial and current `HEAD`: `83606d58ca106496f2da56f5a5676efa0868c0d4`; all phase changes remain uncommitted in the working tree.
- Working tree before implementation: clean.
- Session branch: `arena/94329f0d-dumanmessenger` (fixed by the Arena session; the requested `agent/g2c-fresh-reconstruction` branch cannot be used here).
- Isolated linked worktree: `/home/user/DumanMessenger-g2c`, checked out on the same session branch. The primary checkout remains untouched. Do not create remote writes.
- `stash@{0}` was not inspected or modified.

## Baseline inspection completed (source inspection only)

- Android Flutter project: `mobile/app/android`; Kotlin package and namespace are `com.example.duman_messenger`.
- Android project uses Flutter-provided `compileSdk`, `targetSdk`, and `minSdk`; no explicit minimum API pin in app Gradle config. Java/Kotlin target 17; Gradle wrapper 9.3.1, AGP 9.1.0, Kotlin plugin 2.4.0.
- Manifest already has optional Bluetooth/BLE hardware declarations, legacy permissions capped at API 30, and Android 12+ `BLUETOOTH_SCAN` (`neverForLocation`), `BLUETOOTH_ADVERTISE`, and `BLUETOOTH_CONNECT` declarations.
- Existing native Kotlin: `MainActivity.kt`, `BleDiagnosticManager.kt` (G2-A diagnostics), and `BleDiscoveryManager.kt` (G2-B foreground discovery/advertising). MainActivity owns distinct diagnostic and discovery MethodChannel/EventChannel managers and forwards lifecycle/permission callbacks.
- Existing Flutter BLE source: `lib/ble/ble_diagnostic_{bridge,status}.dart`, `lib/ble/ble_discovery_{bridge,status}.dart`; UI: corresponding diagnostic and discovery screens; app routes are diagnostics-only. Existing `BleDiscoveryResult` is a temporary scan-session id, not an authenticated peer identity.
- Existing Flutter tests include bridge/status/screen tests for G2-A/G2-B. They were recorded but not run.
- `pubspec.yaml` has Flutter and lint dependencies only; no crypto/BLE plugin is currently declared. Native Android BLE operations exist in G2-B, but there is no G2-C connection/GATT or secure-session boundary identified.
- Existing crypto directory `src/crypto/` is the web/simulator TypeScript implementation; it is not a Dart or Android production identity/session API. No production mobile identity key store or protocol integration is identified. Reuse is not justified.
- Existing production messaging and routing boundaries are outside the mobile test-only BLE discovery flow. G2-C must remain isolated and must not enter production messaging.
- `.github/workflows/ci.yml` exists and is a push workflow. Authorization to execute GitHub Actions was not provided; no workflow was run and no push/PR/merge will be performed.

## Relevant baseline files and tests

- Android configuration: `mobile/app/android/settings.gradle.kts`, `build.gradle.kts`, `app/build.gradle.kts`, `gradle/wrapper/gradle-wrapper.properties`, `app/src/main/AndroidManifest.xml`.
- Native BLE: `mobile/app/android/app/src/main/kotlin/com/example/duman_messenger/{MainActivity,BleDiagnosticManager,BleDiscoveryManager}.kt`.
- Flutter BLE: `mobile/app/lib/ble/ble_diagnostic_bridge.dart`, `ble_diagnostic_status.dart`, `ble_discovery_bridge.dart`, `ble_discovery_status.dart`; `mobile/app/lib/screens/ble_diagnostic_screen.dart`, `ble_discovery_screen.dart`, and `mobile/app/lib/app.dart`.
- BLE tests (not run): `mobile/app/test/ble_diagnostic_bridge_test.dart`, `ble_diagnostic_screen_test.dart`, `ble_diagnostic_status_test.dart`, `ble_discovery_bridge_test.dart`, `ble_discovery_screen_test.dart`, `ble_discovery_status_test.dart`.
- Security and toolchain references: `reports/mobile/BASELINE.md`, `SECURITY-REVIEW.md`, `SECURITY-REVIEW-RESULTS.md`, `TOOLCHAIN-REQUIREMENTS.md`, `DEVICE-TEST-MATRIX.md`, `IMPLEMENTATION-STATUS.md`.

## Security decisions / boundaries

- Implemented a bounded version-1 frame validator only; it provides no cryptographic protection. No G2-C authenticated crypto/session protocol has been implemented; do not represent the connection or framing as secure transport.
- Do not silently treat a discovered device or Bluetooth link as trusted/authenticated. BLE link encryption alone is not end-to-end security.
- Production identities, keys, packet format, encryption behavior, routing, golden vectors, and simulator are out of scope and must remain unchanged.
- Native platform crypto may be considered only with a written protocol/key lifecycle design and vetted Android primitives; do not invent cryptographic algorithms.
- `G2-C` must be clearly TEST-ONLY and separate from production messaging.

## Phase 2 implementation completed (source only)

- `G2cGattProtocol.kt`: shared G2-C service/characteristic/CCCD identifiers, versioned frame header, strict 512-byte payload maximum and decoder validation.
- `G2cFragmentation.kt`: MTU-derived ATT value capacity (`MTU - 3`, bounded to 20..514 bytes), 9-byte fragment header, 2,048-byte max message, 192-fragment cap, one in-flight reassembly, strict ordered sequence/declared-length validation, and 15-second cleanup timeout. Fragment success is not authentication.
- `G2cBleDiscovery.kt`: explicit foreground scan filtered to G2-C service UUID, 20-second timeout, max 32 temporary random candidate tokens; device address/name are not emitted; selection consumes the token.
- `G2cGattLink.kt`: API-27-compatible central/client lifecycle, connection and service/CCCD deadlines, MTU request with default-MTU fallback, notifications, serialized write-with-response fragment transmission, inbound reassembly/frame validation, stale callback checks, cancellation and cleanup.
- `G2cGattServer.kt`: explicit server lifecycle, service registration, CCCD handling, UUID advertising, single-peer enforcement, bounded write/notify transport and fragment reassembly, permission checks, timeouts, and resource cleanup.
- `G2cBleManager.kt`/`MainActivity.kt`: distinct TEST-ONLY channels, explicit start/stop discovery/server/connect/disconnect/send-test-frame operations, no simultaneous role, foreground pause cleanup.
- Flutter `g2c_ble_status.dart`/`g2c_ble_bridge.dart`: typed link/discovery/error states, candidate tokens, permission summaries, server state and test-frame methods; parser rejects authenticated=true.
- G2-C-specific ADR and execution documents updated. Primary checkout and G1/G2-A/G2-B modules were not intentionally modified.

## State, limits, and API compatibility

- Discovery is reported separately (`idle`, `scanning`, `results`, `permission_denied`, `timed_out`, `unsupported`, `failed`); a random candidate token is consumed for a selected connect attempt and is not identity.
- Link states distinguish `disconnected`, `connecting`, `connected_unauthenticated`, `service_ready`, `disconnecting`, `connection_failed`, `permission_denied`, `timed_out`, `protocol_error`, and `unsupported`. `authenticated` exists only as a forbidden/unreachable placeholder and Dart rejects a native authenticated claim.
- Both endpoint transports start at ATT MTU 23, request/record MTU where supported, derive value budget as `MTU - 3`, and cap to 514 bytes. G2-C logical frame payload is 512 bytes. Fragment header is 9 bytes; message max 2,048 bytes; fragment max 192; one in-flight receive; strict order/length and 15-second assembly timeout. Write/notification operations have deadlines.
- API 27-compatible GATT client/server/scanner/advertiser APIs are used; runtime permission checks vary by API 23 and 31. Compilation was deliberately not performed, so compatibility is a source-level intention, not verified fact.
- These limits provide transport validation only, not authentication, integrity, confidentiality, or replay defense.

## Phase 3 completed (source and read-only evidence)

- Added a focused G2-C TEST-ONLY screen with explicit scan/stop, opaque candidate selection/connect, server start/stop, disconnect, truthful state/errors, capability/permission display, permanent-denial settings link, and optional unauthenticated test-frame send. Warnings explicitly say no auth/trust/E2E/prod messaging; no fake peers/trust/authentication are created.
- Added operation-scoped Android runtime requests: API 31+ SCAN for scan, CONNECT for connection, CONNECT+ADVERTISE for server; API 23–30 foreground ACCESS_FINE_LOCATION only for scan; no runtime request below API 23. Permission denial/permanent denial are distinct from transport state, and denial never continues the operation. Permission result handling is wired through MainActivity; settings return refreshes actual grants without radio auto-restart.
- Lifecycle is foreground gated: pending prompt does not start radio; client/server actions stop active scanning before requesting; Activity pause stops operations unless permission UI is pending; screen disposal disconnects and cancels EventChannel.
- Follow-up source inspection found permission-state staleness after revocation: native status now re-reads the last operation's grants on refresh/resume and reports requestable/permanently-denied state rather than retaining a stale granted state. Status now includes Bluetooth radio enabled as true/false only when inspectable; API 31+ reports unknown without CONNECT rather than requesting an unrelated permission. A missing LE scanner is surfaced as Bluetooth unavailable, not unsupported hardware.
- Inspected candidate source/metadata via allowed GitHub API. Noise protocol Java candidates lack sufficient API-27/release/audit evidence; Tink is active and has an Android example minSdk 23 but is primitives, not a mutual authenticated session protocol; TLS profile unverified. No dependency added, protocol selection blocked.
- ADR records evidence URLs/dates, identity/trust lifecycle, Keystore/API-27 limitations, owner/security gates, and a candidate evidence matrix covering exact observed identities/versions, license/maintenance evidence, API-27/JVM status, protocol properties, independent-review evidence and unresolved requirements. It explicitly leaves versions/coordinates unverified where source evidence did not establish them.

## Phase 4 source-only audit and handover

- Re-inspected all G2-C Kotlin/Dart source and integration points, manifest, app routing, bridge lifecycle, permission map, framing and ADR. No compile/runtime correctness is claimed.
- Corrected source-verifiable duplicate server notification callback advancement with a pending fragment index; duplicate accepted-peer connected and service-added callbacks are ignored. Corrected error classification so Bluetooth radio unavailable is not mislabeled as unsupported hardware.
- Residual source risk: server callbacks share a callback instance across server lifecycles; late callbacks during rapid stop/restart cannot be ruled out without lifecycle-generation isolation or device evidence. Record and assess on owner devices; do not claim validated.
- Added `docs/mobile/G2-C-WINDOWS-VALIDATION.md`, an owner-run Windows 11/Flutter 3.47.8/API 27 handover guide. It separates static Flutter checks, APK build, API 27 permission checks, radio/discovery/GATT diagnostics and the later two-device/security gates.
- Handover archive packaging is performed after documentation is frozen. It is a source snapshot, not a commit; excludes `.git`, caches/builds and credentials. Exact archive path/size and inventory verification are reported at turn end.

## Remaining work / limitations

- Protocol selection remains blocked pending independent owner/security review, artifact provenance, API-27 key/provider behavior, vectors, release/license/advisory review and explicit approval. No handshake/session/replay defense/data-plane security exists.
- Identity/trust lifecycle is design only: current fingerprint helper/pin store is raw-byte/process-local and unused by sessions. Persistent Keystore-backed local identity, protected trust store, first-contact comparison, revocation/rotation and session binding are not implemented.
- Source-level GATT callback/lifecycle review was performed; runtime/compile correctness and API 27 interoperability remain unverified. No UI trust/auth affordance is shown because neither exists.
- Received test frames remain discarded. Add negative/parser/lifecycle tests later under owner validation policy; complete Windows validation, physical/two-device acceptance, independent security review.
- Android Gradle delegates min/target SDK to Flutter defaults; no resolved numeric target was available in source. Verify and record on owner machine.

- Current `HEAD`: `83606d58ca106496f2da56f5a5676efa0868c0d4`; modifications are uncommitted.
- Exact changed-file inventory: see `G2-C-RECONSTRUCTION-REPORT.md` and `G2-C-EXECUTION-STATE.json`.

## Validation evidence

- Current status/worktree/HEAD/source documents were inspected only.
- Flutter analysis/tests/builds, Kotlin compilation, Gradle, APK generation, emulator/device/two-device checks and all CI/Actions were deliberately not run, as instructed.
- No build, security, device, interoperability or acceptance result is claimed.
- No push, PR, merge, or remote write occurred.

## Next concrete action

Phase 3 control UI and operation-scoped permissions are present. Source-only review identified and fixed client-side duplicate connection/service/descriptor callback handling and guarded write-callback advancement with a pending-fragment index. Further review of the server, fragmentation, callback ordering and lifecycle is documented as source inspection only; no runtime correctness is established. Reconcile this checkpoint, JSON state, and reconstruction report against the final working-tree inventory. Protocol selection remains blocked pending owner/independent security review and API-27 evidence. Do not add authentication/trust claims or production messaging integration. Acceptance remains NOT ACCEPTED pending prohibited validations being performed later by authorized owners, independent security review, and explicit owner approval.
