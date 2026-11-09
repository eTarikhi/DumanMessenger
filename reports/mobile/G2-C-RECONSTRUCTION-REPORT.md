# G2-C Fresh Android Reconstruction Report

**Status: Phase 3 Flutter controls and operation-scoped Android permission source implemented; Phase 4 source audit and Windows handover guide prepared; protocol selection BLOCKED; IN PROGRESS — NOT ACCEPTED.** Source changes are uncompiled and runtime-unvalidated; no authenticated session or secure two-device communication is claimed.

## Baseline verification

- Repository: `eTarikhi/DumanMessenger`.
- Required baseline SHA: `83606d58ca106496f2da56f5a5676efa0868c0d4`.
- `main`, `origin/main`, and initial `HEAD` all point to the required baseline; no newer main descendant is present in the available local refs.
- Initial working tree was clean.
- Initial commit is PR #4 merge (`G1/G2-A/G2-B Android foundation`).
- Final implementation SHA: **not yet available**. Current `HEAD` remains `83606d58ca106496f2da56f5a5676efa0868c0d4`; the source/documentation changes are uncommitted working-tree modifications (HEAD is not a content hash of those modifications).
- The session branch is fixed by Arena as `arena/94329f0d-dumanmessenger`; the requested `agent/g2c-fresh-reconstruction` name cannot be used in this session. Work is isolated in `/home/user/DumanMessenger-g2c` on the session branch. Primary checkout was not changed.

## Existing implementation inspected

The Flutter app under `mobile/app` already includes Android BLE diagnostics (G2-A) and foreground scanning/advertising (G2-B). Native entry points are `BleDiagnosticManager.kt` and `BleDiscoveryManager.kt`; `MainActivity.kt` registers separate method/event channels and forwards Android lifecycle and permission callbacks. The manifest has optional BLE hardware declarations, legacy Bluetooth/location permissions capped to API 30, and Android 12+ scan/advertise/connect permissions. Discovery is foreground-scoped and exposes temporary scan result identifiers, not authenticated peer identities.

Flutter boundaries are in `lib/ble/ble_diagnostic_{bridge,status}.dart` and `lib/ble/ble_discovery_{bridge,status}.dart`, with diagnostic/discovery screens and routes. Existing tests cover these G1/G2-A/G2-B UI, bridge and model behaviors. Tests were inventoried but not run.

Android configuration uses Flutter SDK compile/target/min SDK defaults, Java/Kotlin target 17, AGP 9.1.0, Kotlin 2.4.0, and Gradle wrapper 9.3.1. The Flutter pubspec has no BLE or crypto package dependency. The web/simulator TypeScript crypto under `src/crypto` is not a mobile identity/session API and will not be assumed reusable. No G2-C GATT connection, trusted-peer identity store, or authenticated mobile protocol boundary was found.

## Implemented source (Phases 1–3)

- Android G2-C transport: `G2cProtocol.kt` defines unique service/characteristic/CCCD UUIDs and a strict v1 frame (512-byte payload, 516-byte whole frame); `G2cFragmentation.kt` bounds MTU-aware fragments/messages; `G2cBleDiscovery.kt` scans explicitly for up to 20 seconds and exposes max 32 opaque tokens; `G2cGattLink.kt` and `G2cGattServer.kt` implement central/peripheral, service/CCCD, advertising, notifications/write requests, deadlines, one-peer server, state, and cleanup. No address/name is sent to Flutter.
- `G2cBleManager.kt` and `MainActivity.kt` own a separate test-only channel, permissions and lifecycle. Phase 3 requests permissions per operation, handles denied/permanently denied states, opens app settings, and gates radio startup on the foreground Activity. API 31+ asks SCAN/CONNECT/ADVERTISE as needed; API 23–30 asks ACCESS_FINE_LOCATION only for foreground scanning; earlier APIs have no runtime request. Manifest already has modern SCAN with `neverForLocation` and declarations for CONNECT/ADVERTISE; only its explanatory comment was updated. Numeric min/target SDK remain Flutter defaults, not pinned here.
- Flutter adds `G2cBleScreen`, route and diagnostics entry; it supports start/stop discovery, selecting a real opaque candidate, client connection, server start/stop, disconnect, permission/capability/error states, and optional test-frame transmission. It clearly says connection/service readiness are unauthenticated/untrusted and no E2E/production messaging exists. Test frames are discarded by native code.
- `G2cBleStatus`/`G2cBleBridge` carry typed link/discovery/permission states and the parser fails closed if native says authenticated. The screen subscribes to native status, renders actual candidate tokens and errors, serializes button operations, cancels its subscription on disposal, and explicitly disconnects; native EventChannel cancellation/Activity pause also tear down operations. Test-frame send is available only at GATT service-ready and native discards received frames.
- Follow-up permission/capability source work re-evaluates the last requested grants on getStatus/resume, so revocation does not leave a stale “granted” summary. Bluetooth radio enabled is surfaced true/false only when Android permits inspection; it is null/unknown on API 31+ without CONNECT rather than requesting CONNECT merely for scanning. A missing scanner is reported as bluetooth unavailable, not as missing BLE hardware. None of these paths were runtime-validated.
- Source-level transport review corrected stale scan callback acceptance, Android 12 scanner adapter-state permission access, permission-prompt foreground radio behavior, fragment reassembly assumptions under MTU changes, and bounded write/notification wait timeouts. These are code-review observations, not executed results.
- G1/G2-A/G2-B algorithms/behavior, production messages/crypto, routing, simulator and golden vectors were not intentionally changed.

## Protocol investigation and decision

No protocol/library is selected and no dependency was added. Read-only GitHub API/repository source evidence inspected on 2026-11-09:

- Noise Framework spec repository: `https://github.com/noiseprotocol/noise_spec`, v34 dated 2018-07-11; mature framework spec, not an Android implementation.
- `rweather/noise-java` (`https://github.com/rweather/noise-java`): MIT, no releases/tags, last push 2024-03-28, POM `1.0-SNAPSHOT`, Java 8 source/target, README describes a plain-Java reference implementation. API-27 provider/key behavior and independent review/audit remain unverified.
- `jchambers/java-noise` (`https://github.com/jchambers/java-noise`): MIT, no releases/tags, last push 2025-04-02, Java 17 POM. README says unpublished to an artifact repo and not independently security-audited; X25519/ChaChaPoly require provider support. Not suitable on current API-27 evidence.
- `tink-crypto/tink-java` (`https://github.com/tink-crypto/tink-java`): Apache-2.0, v1.24.0 release 2026-10-16 and active repository; checked-in Android example uses minSdk 23. Tink is not the required mutual-authenticated session/record protocol, and composing a handshake/session here would be custom protocol design.
- Mutual TLS over a GATT stream: API-27 mutual-authentication/provider and record adaptation were not verified.

The ADR contains the per-candidate evidence matrix requested for exact identities/versions (or explicit unverified status), authoritative source/docs, license and maintenance evidence, API-27/Kotlin/JVM evidence, mutual authentication/identity/transcript/replay/session-key properties, independent-review evidence and remaining uncertainties. Repository timestamps/releases and README statements are not an independent security audit. No artifacts were resolved/downloaded, no builds run, and no compatibility or security claims are made. Protocol selection is **BLOCKED** pending owner/independent security review of a pinned implementation, API-27 key-provider support, provenance, licensing, maintenance/advisories, vectors/interoperability, identity binding, transcript/roles, replay/rekey and teardown.

## Identity/trust architecture (designed, not implemented)

ADR specifies a G2-C-only local identity (no production key reuse), canonical algorithm-tagged fingerprint, proof-of-key-possession before explicit first-contact out-of-band fingerprint comparison, durable peer public identity/trust record, explicit revoke/rotation, and peer-fingerprint/transcript-bound sessions. Android Keystore exists on API 27 and `KeyGenParameterSpec` begins at API 23, but exact static-DH key-purpose/provider support must be tested per API/device. No private key may fall back to plaintext disk; unsupported algorithms must fail closed or use an explicitly reviewed Keystore-wrapped-at-rest approach with in-memory exposure documented. Current identity helper is raw-byte fingerprinting and current pin store is volatile; neither authenticates transport.

## Remaining / blocked

1. Select a vetted protocol implementation only after owner/security approval; implement authenticated handshake, mutual identity binding, transcript/KDF/session, replay defense, expiry/rekey and teardown.
2. Implement Keystore-backed local identity, protected persistent trust, trust/revoke/rotation UI, and authenticated-session state; current UI correctly shows none.
3. Verify/repair source under owner Windows builds and permission/device matrix; two-device BLE and API 27 behavior remain unknown.
4. Add protocol/transport negative tests and independent security review; then owner acceptance. No secure data plane currently exists.

## Phase 3 source criteria

The protocol investigation has a documented, evidence-qualified blocker rather than a guessed dependency. Identity/trust lifecycle is specified. The focused Flutter control screen and operation-scoped Android permission source are present. Phase 2 source has been reviewed and source-level issues addressed. These criteria are met **at source/documentation level only**; compilation/runtime correctness remains unverified. No authenticated session is implemented. G2-C remains NOT ACCEPTED.

## Security constraints

- Discovery is not authentication or consent. Unknown peers must be rejected unless an explicit trust ceremony completes.
- BLE link encryption is transport protection, not end-to-end security.
- No production identity keys, encryption state, packet compatibility, routing logic/defaults/thresholds, five-hop semantics, golden vectors, or simulator behavior may be modified.
- No secret, private key, or sensitive plaintext logging.
- G2-C features must be prominently labeled TEST-ONLY and be architecturally separate from production messaging.
- Security design and independent review remain prerequisites; no custom crypto algorithm is permitted.

## Phase 4 source audit and Windows handover

Source-only inspection covered all G2-C Kotlin/Dart files, manifest, route/screen integration, bridge/event lifecycle, Activity callbacks, protocol/fragment bounds, permission state mapping, and security boundaries. The server now ignores duplicate `onServiceAdded` and duplicate connected callbacks for its current peer, and permits only the matching pending `onNotificationSent` to advance the notification fragment index. Generic `unavailable` errors no longer classify a disabled Bluetooth radio as unsupported hardware. These corrections are source-level only.

Residual: the server callback object is shared across server instances; a callback arriving late after stop/restart cannot be conclusively associated with its originating server from the current callback signature/state. Rapid stop/restart should be observed during owner diagnostics. API 27 behavior, callback ordering and radio behavior remain unverified. No production messaging or identity/security code was added.

`docs/mobile/G2-C-WINDOWS-VALIDATION.md` provides safe extraction/clone guidance, baseline comparison, Flutter dependency/analyze/test/build steps, manifest and ADB inspection, API 27 permission checks, discovery/GATT/lifecycle diagnostics, logcat guidance, failure classification and owner result reporting. All validation commands are for the owner and were not executed here. A full source handover ZIP is prepared outside the repository; it excludes `.git`, build/cache output and credentials and includes a file manifest and changed-path inventory.

## Validation, delivery, and acceptance

No validation command was run for the current Phase 2/3 source. Only source/status inspection and documentation/archive packaging were performed. Flutter analysis/tests/build, Kotlin/Gradle compile, APK build, device test, and two-device BLE acceptance have not been run. GitHub Actions/CI was not run. No push, PR, merge, or other remote write was performed. The repository has a push workflow at `.github/workflows/ci.yml`; Actions remain unauthorized until an authorized maintainer confirms they are disabled at repository or organization scope.

Windows validation commands for the owner after implementation (run from PowerShell in the repository root):

```powershell
cd mobile/app
flutter --version
flutter analyze
flutter test
flutter build apk --debug
adb devices -l
adb install -r build\app\outputs\flutter-apk\app-debug.apk
adb shell am start -n com.example.duman_messenger/.MainActivity
```

The Windows owner must additionally run the documented two-device test matrix with synthetic identities/payloads, record Android model/build and runtime permission decisions, verify discovery cancellation, connection loss, timeout, untrusted/revoked peer rejection, malformed/replayed message rejection, and safe teardown. Commands above have not been run here. Adapt the package launch component if the implementation intentionally changes applicationId, documenting that change.

G2-C remains **NOT ACCEPTED** until owner-run Windows Flutter validation succeeds, Android physical-device validation and two-device BLE acceptance succeed, independent security review completes, and the owner explicitly approves acceptance. Implementation completion alone is not production readiness.

## Complete changed-file inventory at this checkpoint

The current working tree contains 19 changed or untracked paths (all uncommitted):

1. `docs/mobile/ADR-G2-C-ANDROID-SECURE-BLE-LINK.md` — protocol candidates, identity/trust design and explicit approval gates.
2. `mobile/app/android/app/src/main/AndroidManifest.xml` — G2-C permission declarations.
3. `mobile/app/android/app/src/main/kotlin/com/example/duman_messenger/G2cProtocol.kt` — frame schema/codec and identity/trust abstractions.
4. `mobile/app/android/app/src/main/kotlin/com/example/duman_messenger/G2cFragmentation.kt` — bounded MTU-aware segmentation/reassembly.
5. `mobile/app/android/app/src/main/kotlin/com/example/duman_messenger/G2cBleDiscovery.kt` — foreground UUID scan and opaque candidate tokens.
6. `mobile/app/android/app/src/main/kotlin/com/example/duman_messenger/G2cGattLink.kt` — central/client GATT lifecycle, notifications, serialized writes and callback guards.
7. `mobile/app/android/app/src/main/kotlin/com/example/duman_messenger/G2cGattServer.kt` — peripheral/server lifecycle and bounded transport.
8. `mobile/app/android/app/src/main/kotlin/com/example/duman_messenger/G2cBleManager.kt` — TEST-ONLY channel command/status and permission orchestration.
9. `mobile/app/android/app/src/main/kotlin/com/example/duman_messenger/MainActivity.kt` — channel registration, permission callbacks and lifecycle gating.
10. `mobile/app/lib/ble/g2c_ble_status.dart` — typed status and fail-closed auth parsing.
11. `mobile/app/lib/ble/g2c_ble_bridge.dart` — G2-C discovery/client/server/test-frame API.
12. `mobile/app/lib/screens/g2c_ble_screen.dart` — test-only diagnostic controls and explicit security caveats.
13. `mobile/app/lib/app.dart` — screen integration.
14. `mobile/app/lib/app_routes.dart` — route registration.
15. `mobile/app/lib/screens/diagnostics_screen.dart` — entry point to G2-C controls.
16. `reports/mobile/G2-C-EXECUTION-CHECKPOINT.md` — milestone state and next steps.
17. `reports/mobile/G2-C-EXECUTION-STATE.json` — machine-readable implementation state.
18. `reports/mobile/G2-C-RECONSTRUCTION-REPORT.md` — this report.
19. `docs/mobile/G2-C-WINDOWS-VALIDATION.md` — owner-run Windows validation and evidence handover guide.

The client source review added idempotence guards for duplicate connected/service/descriptor callbacks and requires a matching pending fragment write before advancing the outbound index. Phase 4 added server duplicate service/peer callback guards and pending-notification callback advancement checks, and corrected Bluetooth-disabled versus unsupported error classification. Server callback, notification pacing, fragmentation bounds, timeout and teardown paths were inspected; source review does not verify platform callback behavior, compile correctness, or runtime safety. No G1/G2-A/G2-B behavior, routing, existing crypto, simulator, golden vector, or production messaging source was intentionally modified.
