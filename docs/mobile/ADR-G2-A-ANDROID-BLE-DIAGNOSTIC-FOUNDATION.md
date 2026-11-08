# ADR — G2-A Android BLE Diagnostic Foundation

- **Status:** Decision documented; fresh source implementation is awaiting Local PC validation.
- **Baseline:** G1 commit `58126a9fa0a7628ae04610c1394b7ecfc678d848`.
- **Scope:** Android-only BLE capability and permission diagnostics. This ADR does not authorize a BLE transport or any radio operation.

## Context

G2-A is being implemented fresh from the G1 baseline. Historical G2-A source was not recovered, so this work is not described as restoration or reconstruction. The app needs a small native foundation to report whether Android exposes BLE prerequisites, with explicit runtime-permission handling and a Flutter diagnostics screen. This milestone must not imply discovery, connectivity, messaging, or device interoperability.

## Decision

1. Declare both `android.hardware.bluetooth` and `android.hardware.bluetooth_le` with `android:required="false"`; neither Bluetooth nor BLE hardware is an installation requirement.
2. Declare legacy `BLUETOOTH` and `BLUETOOTH_ADMIN` permissions through API 30, and declare `ACCESS_FINE_LOCATION` with `android:maxSdkVersion="30"` for legacy Android BLE compatibility. Declare `BLUETOOTH_CONNECT`, `BLUETOOTH_SCAN`, and `BLUETOOTH_ADVERTISE` for Android 12 and later; mark scan `neverForLocation`. G2-A reports `ACCESS_FINE_LOCATION` on API 30 and earlier but does not request it or access location; no background-location permission is declared.
3. On API 31+, request only `BLUETOOTH_CONNECT`, and only when needed to inspect local adapter state. Report whether a required permission can be requested again or needs user action in system settings. A single app-private denial boolean is persisted to distinguish a retryable denial from a system-settings case; it contains no device or user identity. Do not launch settings or programmatically change Bluetooth state. On API 30 and earlier, legacy Bluetooth permissions are normal manifest permissions; the capped `ACCESS_FINE_LOCATION` permission is reported but does not gate this no-scan diagnostic or get requested by G2-A (it is a runtime permission from API 23).
4. The Kotlin diagnostic service reports API level, BLE feature availability, Bluetooth-manager/adapter availability, Bluetooth enabled state when permission allows, per-permission status/rationale/re-requestability, and the platform's local advertising-capability flag. It does not report device identifiers or enumerate peers.
5. Expose the snapshot and permission request through a `MethodChannel`; expose status changes through an `EventChannel`. The adapter-state receiver is registered only while the Flutter stream is listened to and the Activity is resumed, and is removed on pause, cancellation, and destruction. Permission completion is returned to the pending method call and reflected in the event stream.
6. Flutter uses a typed status model and bridge. Diagnostics navigation presents Android capability, permission, and Bluetooth-state results; non-Android platforms and native-channel failures produce safe diagnostic states. Stream subscriptions are cancelled when the screen is disposed.
7. Keep all existing simulator, routing, transport, fixture, threshold, and acceptance behavior unchanged. No external Flutter runtime dependency is added.

## Explicit non-goals

G2-A performs no BLE scan or advertising operation, discovery, pairing, GATT use, connection, peer enumeration, message/hello exchange, background BLE/location work, or transport/routing behavior. It does not create stable identities or keys, read adapter name/MAC or bonded-device data, open Android settings automatically, or enable Bluetooth. The future-reserved UUID `5d1796d0-d8f8-406a-8b3d-1a8684447470` is not present in radio-operation code and is not used for radio operations.

## Consequences

- The Flutter app can explain hardware, permission, adapter, and Bluetooth-state prerequisites without pretending that the radio path works.
- Optional BLE hardware allows installation on devices without BLE.
- Scan and advertise permissions may appear in Android's manifest metadata, but G2-A neither requests nor uses them. The required `ACCESS_FINE_LOCATION` manifest entry is capped at API 30 and reported without gating local-adapter status; G2-A does not request it or access location data. No background-location permission is declared.
- Android build, widget/model/bridge tests, permission prompts, lifecycle behavior, and device behavior remain unverified until the owner runs the validation plan on Local PC. Tests are authored but were not run by the Agent. No G2-A acceptance claim follows from this ADR or source review.

## Validation evidence required outside this implementation

Run the repository's Flutter analysis and tests, build and launch the Android app, then inspect permission behavior on supported Android API levels with BLE-capable and BLE-incapable devices or appropriate owner-approved test devices. Confirm the screen accurately handles permission granted/denied/permanently denied, Bluetooth disabled, missing BLE hardware/service, Activity pause/resume, and event-stream cancellation. Report emulator and physical-device evidence separately. No scan, advertisement, connection, or message interoperability test is part of G2-A.
