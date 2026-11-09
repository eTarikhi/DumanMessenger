# G2-B Foreground BLE Discovery — Acceptance Checklist

**Status: READY FOR USER ACCEPTANCE — NOT ACCEPTED.** Agent source stabilization and synchronization are complete. The user reports successful physical-device testing on two Android phones; that evidence is recorded below and was not independently reproduced by the Agent. Local PC tests, analysis, and the final build still require user execution on the exact pushed SHA. Do not treat source review or the reported device results alone as complete G2-B acceptance.

See [ADR-G2-B-FOREGROUND-BLE-DISCOVERY.md](ADR-G2-B-FOREGROUND-BLE-DISCOVERY.md) for the exact scope and privacy decisions. G2-B explicitly permits only the foreground discovery operations listed there; it does not begin G2-C.

## A. Source-scope review (authored; not runtime-verified)

- [x] Use only service UUID `5d1796d0-d8f8-406a-8b3d-1a8684447470` for advertisements and OS-level scan filtering.
- [x] Require user actions to start and stop advertising/scanning; no automatic radio start and no programmatic Bluetooth enable.
- [x] Make advertisements non-connectable and omit device name and extra payloads.
- [x] Keep only a temporary in-memory match set, expose generated session-local result tokens and count, and avoid reading, displaying, persisting, or logging device names, MAC addresses, or stable peer IDs.
- [x] Handle unsupported BLE hardware, missing adapter/scanner/advertiser, permission denial/recovery, operation errors, Bluetooth-off notifications, event cancellation, and Activity/screen lifecycle stops in source.
- [x] Keep G2-B channels and Dart types separate from G2-A; retain the existing G2-A diagnostic.
- [x] Add model, bridge, screen, and navigation tests, plus this checklist and an ADR. Tests have not been executed.
- [x] No GATT, connection, pairing, messaging, identity/key exchange, background BLE, location tracking, simulator/transport/protocol changes, or dependency/SDK/Gradle/Kotlin version changes were added.

These are source-scope observations only. They do not establish that the app compiles or that Android behaves as intended.

## Agent source-level stabilization record

- **Lifecycle test diagnosis:** The displayed `0` is the discovery result count. The screen renders it in the keyed `ble-discovery-results-count` Text, while the lifecycle handler starts an asynchronous `stopAll` and updates widget state only after its response. The previous test checked the fake API's immediately-mutated state, then relied on generic `pumpAndSettle` and an unkeyed `find.text('0')` rather than awaiting the fake stop response and reading the keyed count. Source inspection also found a production race: a delayed initial/resume refresh could overwrite the cleared snapshot, and a lifecycle stop arriving during initial loading did not clear the loading state.
- **Correction:** Lifecycle loss now invalidates in-flight status/action responses; status updates are revision-checked so stale snapshots cannot restore active state or results. A lifecycle stop marks loading complete as it applies the cleared status. The focused widget regression now awaits fake stop completion, pumps the UI, reads the count through its stable key, delivers a deliberately stale refresh, and verifies the count stays at zero after resume without starting either operation. This is a source-level diagnosis; the test was not run by the Agent.
- **Analyzer correction:** The unused `StackTrace __` parameter in `ble_discovery_bridge.dart` now follows the Dart unused-parameter convention with `_`.
- **Files reviewed:** `BleDiscoveryManager.kt`, `MainActivity.kt`, the unchanged `BleDiagnosticManager.kt`, `AndroidManifest.xml`, the discovery Dart bridge/model/screen, discovery and navigation tests, app routing/diagnostics, the G2-B ADR/checklist, and the simulator/transport diff against the baseline.
- **Boundary review:** Advertising, scanning, permission gating, in-memory result handling, G2-A separation, and non-goals were reviewed by source inspection. No GATT/pairing/identity/messaging/background discovery or simulator/transport changes were introduced.

## B. Local PC automated validation — required, not run here

Use the owner's Windows 11 Local PC checkout and PowerShell. Do not use an unrelated standalone APK as evidence for this source tree. These commands are for the user only; they are **not** instructions for the Agent environment.

```powershell
Set-Location "C:\Users\Administrator\Desktop\Git-Clones\DumanMessenger"
git fetch origin
git status --short
git pull --ff-only origin arena/be8aa6c3-dumanmessenger

Set-Location .\mobile\app
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

Before this stabilization, the user reported that `flutter pub get` and `flutter build apk --debug` succeeded, one lifecycle widget test failed at its count assertion, and Flutter analyze reported `unnecessary_underscores`. The earlier build/dependency results were not reported against this stabilization SHA and do not validate it. Rerun the sequence above and record Flutter/Dart versions, exact commit SHA, full command outcomes, and any failures. The authored focused tests are:

```text
mobile/app/test/ble_discovery_status_test.dart
mobile/app/test/ble_discovery_bridge_test.dart
mobile/app/test/ble_discovery_screen_test.dart
mobile/app/test/app_navigation_test.dart
```

No Agent-side tests, analysis, build, CI/CD simulation, or GitHub Actions were run: **NOT RUN — PROHIBITED**.

## C. Android permission and recovery matrix — required

Use Android devices/emulators on representative API levels and record exact API/device information. Test with a fresh install or reset app permissions so prior G2-A permission grants do not hide G2-B prompts.

- [ ] On Android 12+ (API 31+), opening Diagnostics and refreshing status does not request `SCAN`, `ADVERTISE`, or `CONNECT`.
- [ ] On Android 12+, tapping Start scanning requests `BLUETOOTH_SCAN` only; tapping Start advertising requests `BLUETOOTH_ADVERTISE` only. G2-B never requests `BLUETOOTH_CONNECT`.
- [ ] On Android 6–11 (API 23–30), status inspection and advertising do not request location. Tapping Start scanning requests the manifest-capped `ACCESS_FINE_LOCATION` only then, and the UI explains the OS requirement and that no location data is read or stored.
- [ ] Confirm no background-location permission or request exists.
- [ ] Exercise permission grant, first denial/retry, and a non-repeatable denial followed by manual recovery in Android app settings. The app does not open Settings automatically.
- [ ] With Bluetooth turned off in Android settings, confirm discovery does not start, the user receives a clear state, and turning Bluetooth back on does not automatically restart it.
- [ ] Confirm missing/unsupported BLE hardware, adapter, scanner, and advertiser states are safe and understandable.

## D. Foreground, cancellation, and temporary-data checks — required

- [ ] Confirm both start operations require a button press and each can be explicitly stopped.
- [ ] Start advertising or scanning, then background the app / cause Activity pause. Confirm radio operations stop, results clear, and returning to the app does not restart either operation.
- [ ] Close the discovery screen or cancel its EventChannel subscription. Confirm native operations stop and temporary results are cleared.
- [ ] Repeatedly start and stop each operation; confirm there are no duplicate subscriptions, stale result counts, or unhandled platform errors.
- [ ] Confirm only a temporary matching-device count is displayed; there is no device name, MAC address, stable identifier, peer identity, or location value in the UI, app logs, or persistent storage.
- [ ] Confirm G2-A diagnostics still report local prerequisites independently and never start a radio operation.

## E. Physical-device discovery evidence — required for acceptance

Use at least two physical, BLE-capable Android devices. Emulators may supplement but do not replace this evidence. From a separate PowerShell session at the repository root, launch the app on a connected physical device with:

```powershell
Set-Location .\mobile\app
flutter devices
$DeviceId = Read-Host 'Enter the physical Android device ID shown above'
flutter run -d $DeviceId
```

Stop the foreground `flutter run` session with Ctrl+C after the manual checks. Repeat the launch on the second device as required.

- [ ] On device A, explicitly start advertising; confirm the app reports the operation active and the advertisement carries the reserved service UUID only, without a name or connectable payload.
- [ ] On device B, explicitly start scanning; confirm the Android scan is filtered for the reserved UUID and the matching count increments once per unique advertiser during that scan session.
- [ ] Stop advertising and scanning independently; confirm operation states stop. Repeat with device roles reversed.
- [ ] Verify that a nearby non-matching BLE advertiser does not increase the count.
- [ ] Capture date, Android version/API, device model, permission outcomes, steps, observed counts, stop/lifecycle results, and any limitations. Do not include real device names, addresses, or other stable identifiers in the report.
- [ ] Confirm no pairing, GATT connection, identity exchange, messaging, or background operation occurred.

## User-reported physical-device evidence (not Agent-reproduced)

The user reports successful physical BLE testing with these two devices:

| Device | User-provided platform detail |
| --- | --- |
| Samsung Galaxy S10e — SM-G970F | Android/API version not supplied |
| Samsung Galaxy J7 — SM-G610F | Android 8.1 / API 27 |

Across the two-device test, the user reports successful BLE advertising and scanning, discovery in both tested directions, stopping advertising/scanning, clearing temporary discovery results, and foreground/background lifecycle behavior. The report is recorded as user-reported evidence only; the Agent did not reproduce these tests. It does not establish authenticated identity, secure trust, pairing, GATT, messaging, or transport capability. The remaining permission, non-matching-advertiser, privacy/non-goal, and Local PC validation items above still need their own evidence.

## F. Final acceptance gate

- [ ] Local PC Flutter tests pass.
- [ ] Local PC Flutter analysis passes.
- [ ] Local PC Android debug build succeeds.
- [ ] Permission, unsupported-hardware, Bluetooth-off, lifecycle, and cleanup evidence is recorded.
- [ ] Physical-device service-UUID discovery succeeds in both directions and the privacy/non-goal checks above pass.
- [ ] Reviewer records exact baseline, parent, implementation, and fetched remote SHAs and confirms the worktree is clean after synchronization.

Only after every required unchecked gate in sections B–F has evidence may an owner/reviewer call G2-B accepted. A test result, build, or emulator demo alone is insufficient. No G2-C work is included in this checklist.
