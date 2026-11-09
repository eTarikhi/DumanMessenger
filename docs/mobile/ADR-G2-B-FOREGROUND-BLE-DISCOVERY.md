# ADR — G2-B Foreground BLE Discovery

- **Status:** Source stabilization is complete. User-reported physical-device results are recorded in the [acceptance checklist](G2-B-ACCEPTANCE-CHECKLIST.md); Local PC automated validation remains pending. G2-B is **not accepted**.
- **Baseline:** Verified G2-A commit `7d973933a5e51f7a8ca28d6c93b9611395767b77` on `arena/be8aa6c3-dumanmessenger`.
- **Scope:** Explicit, foreground-only Android BLE advertising and service-UUID-filtered scanning. This decision does not authorize a transport, peer connection, or messaging feature.
- **Relationship to G2-A:** This ADR explicitly authorizes the narrow G2-B radio operations below and supersedes G2-A's no-scan/no-advertise restriction only for this foreground discovery milestone. G2-A's separate prerequisite diagnostic remains unchanged and remains radio-operation-free.

## Context

The G2-A baseline established an Android-only local BLE prerequisite diagnostic without advertising or scanning. G2-B is a fresh implementation from that verified baseline; no historical G2-B source was recovered. The app needs a narrowly scoped discovery experiment to confirm that a phone can advertise and find the DumanMessenger service UUID without introducing an identity, connection, messaging, or background transport.

## Decision

1. **One reserved service UUID.** Use `5d1796d0-d8f8-406a-8b3d-1a8684447470`. Advertising includes that UUID only: no device name, address, stable identity, manufacturer payload, message data, or key material. Advertisements are non-connectable.
2. **OS-filtered scan.** Start scans with an Android `ScanFilter` for that UUID and retain a defensive in-process UUID check. Count unique matches only for the current scan session. The Flutter UI receives generated session-local result tokens and the count, never the `BluetoothDevice`, name, MAC address, or a stable peer identifier. No peer result is logged or persisted.
3. **Explicit foreground controls.** The user must press Start advertising or Start scanning. Each operation has a corresponding Stop action. There is no automatic start on app launch, resume, or screen navigation, and the app never enables Bluetooth programmatically. A native Activity-bound manager stops active operations and clears temporary results on Activity pause/destruction, event-stream cancellation, screen disposal/stop-all, and Bluetooth-off state changes. Resume refreshes status but does not restart radio operations. No background service or background BLE mode is introduced.
4. **Operation-specific Android permissions.** On Android 12+ (API 31+), request `BLUETOOTH_SCAN` only after the user starts scanning and `BLUETOOTH_ADVERTISE` only after the user starts advertising. G2-B does not request `BLUETOOTH_CONNECT`; that permission remains a separate G2-A adapter-status requirement only where Android requires it. On Android 6–11 (API 23–30), request capped `ACCESS_FINE_LOCATION` only when the user starts scanning, and explain that the OS requires it for foreground BLE scanning while DumanMessenger does not read or store location. Legacy normal Bluetooth permissions are declared for supported API levels. No background-location permission is declared.
5. **Denial and capability states.** Report BLE hardware, adapter, adapter enabled state where permission allows, scanner/advertiser availability, permission rationale/re-requestability, and operation errors with typed states. Allow retry when Android permits another request; otherwise explain that the user can change the permission in system settings. Do not open Settings automatically. Bluetooth-off, missing hardware/service/scanner/advertiser, start failures, permission denial, and foreground/lifecycle stops are surfaced without leaking exception text.
6. **Isolated Flutter/native bridge.** Keep G2-B on dedicated method/event channels (`com.dumanmessenger/ble_discovery/methods` and `com.dumanmessenger/ble_discovery/events`) with typed Dart status/results. The existing G2-A channel names and diagnostic flow remain unchanged. Non-Android platforms report unsupported; disposing or cancelling the discovery stream stops native operations.
7. **Strict non-goals.** No GATT, connection, pairing, peer authentication/trust, identity or key exchange, message exchange, routing/transport/simulator/protocol changes, background BLE, location tracking, or G2-C implementation. A matching advertisement is discovery only; it is not proof of a peer's identity or an authenticated contact.
8. **No toolchain expansion.** Do not change Flutter dependencies or Android SDK, Gradle, Kotlin, or Java versions for this milestone unless a separately documented necessity is approved.

## Privacy and retention

Native code keeps device objects only in memory for per-scan duplicate suppression. It does not read a device name or address, expose those values to Flutter, write scan results to preferences/files, or log results. The only discovery result token is generated locally and resets with the scan session. Permission retry metadata is app-private permission state, not peer data. The discovery screen shows the temporary match count and explicitly explains that discovery is not authentication, pairing, or a connection.

## Consequences

- G2-A remains a useful read-only prerequisite screen; the new G2-B feature is separately navigable and explicitly user initiated.
- Optional BLE hardware and a safe unsupported state remain supported; the app does not require BLE hardware to install.
- Android's actual permission prompt and radio behavior must be validated across relevant API levels. Source inspection cannot establish that a particular device advertises or discovers another phone.
- Flutter model, bridge, screen, and navigation tests are authored but not executed in the Agent environment: **NOT RUN — PROHIBITED**. The user-reported device results are recorded separately in the acceptance checklist and were not reproduced by the Agent. No automated-validation pass or final G2-B acceptance is claimed here.

## Validation evidence required

Follow [G2-B Acceptance Checklist](G2-B-ACCEPTANCE-CHECKLIST.md) on Local PC. At minimum, run the documented Flutter tests, analysis, and Android debug build there; exercise permission and lifecycle cases on Android; then verify matching service-UUID discovery between physical BLE-capable Android devices. Keep emulator results distinct from physical-device evidence. Until those gates are recorded, G2-B remains unaccepted.
