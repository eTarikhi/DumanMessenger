# G1 implementation — smallest Flutter foundation

**Status (2026-11-08):** Shared Flutter app source and widget tests have been added in `mobile/app`. The generated Android/iOS hosts and `pubspec.lock` are still pending owner-side Flutter commands. The Linux agent has no Flutter/Dart/Java/Android tooling, so no Flutter analyze/test/build, Android emulator/device, or iOS validation has been run. The owner reports Flutter 3.47.8 / Dart 3.13.7 and a successful standalone APK smoke build; that is not evidence for this repository. G1 implementation is not fully validated or accepted.
**Base source snapshot:** `11d4a0f654b3fd71e7872065a0ac0dd90d1616f2` (before G1 source).
**Template basis:** Flutter 3.47.8 tag, framework commit `737ba8f885dc774b53b442759999a312c9461e4e`; use its bundled Dart 3.13.7. No workflow or platform-specific source has been changed.
**Distribution scope:** Android target is Google Play; iOS implementation/testing are required; App Store publishing is not authorized.

## 1. Goal and boundary

Implement the smallest Flutter application that can be independently built, installed, launched, and tested on an Android emulator and an iOS Simulator. Shared source and widget tests are now present; generated platform hosts, lockfile, and runtime evidence remain pending. This first milestone is an app-shell gate only. It must not imply that secure messaging, contacts, key management, radio transport, persistent chat, background delivery, or mobile protocol interoperability works.

Keep the app separate from `src/` and `sim/mesh_sim/`. Do not import the browser simulator, Node crypto, simulator clock, `MeshSimulation`, `SimulatedMeshTransport`, or protected golden vectors into the Flutter app. Do not add production cryptography, Bluetooth permissions, analytics, remote crash reporting, user tracking, or network access in the shell.

## 2. Smallest buildable project shape

The shared source below is implemented. Do not wait for macOS to work on shared Dart or Android. Generate the Android host and lockfile from the owner-reported Flutter 3.47.8 SDK on Windows; review/commit those generated project files. Add the iOS host on an authorized macOS host only when iOS build acceptance is possible.

```text
mobile/app/
  pubspec.yaml                 # Flutter SDK plus flutter_test / flutter_lints dev deps
  pubspec.lock                 # pending flutter pub get; commit after generation
  analysis_options.yaml
  lib/
    main.dart                  # entry point
    app.dart                   # MaterialApp, session theme and route composition
    app_routes.dart
    widgets/
      app_page_body.dart
      foundation_notice.dart
    screens/
      onboarding_screen.dart
      conversation_list_screen.dart # honest empty state
      diagnostics_screen.dart  # Flutter platform/build mode only
      settings_screen.dart     # session-only theme, diagnostics link
  test/
    test_helpers.dart
    app_navigation_test.dart
    onboarding_screen_test.dart
    conversation_list_screen_test.dart
    diagnostics_screen_test.dart
    settings_screen_test.dart
  android/                     # not present; generate from Flutter 3.47.8 on Windows
  ios/                         # not present; generate on macOS before iOS acceptance
```

The source uses Flutter SDK navigation (`Navigator`/named routes), Material widgets, and no runtime plugin. The only non-SDK dependency is the template-standard `flutter_lints` dev dependency; `flutter_test` is an SDK dev dependency. No conversations, contacts, sessions, identity, keys, network client, message store, permission request, or hidden analytics call are created.

## 3. Foundation screens and behavior

### Application entry/navigation

- `main.dart` calls `runApp` with a small `MaterialApp` and a single app theme.
- Start at onboarding on a fresh app launch; the “Continue” action navigates to an empty conversation list. Persisting onboarding completion is not required in the shell and can remain session-local.
- A visible app-bar/menu action opens a local diagnostics page; Android system back and iOS navigation back work.
- Routes use stable identifiers/constants and are covered by widget tests. Avoid deep-link/contact scheme registration in G1.

### Onboarding placeholder

- State clearly that the app is a foundation and secure messaging/radio is not available yet.
- State that no accounts, contacts, or conversations are loaded. The app source makes no network calls or location/Bluetooth/camera/microphone/file access and requests no runtime permissions.
- Continue is local navigation only. No key generation, QR scan, notification, account, permission prompt, or credential entry.

### Conversation-list placeholder

- Show an empty state such as “No conversations yet” and “Messaging is not enabled in this foundation build.”
- Do not display fabricated delivery, encryption, verified-peer, or offline status.
- No conversation detail, send button, fake ACK, or simulated transport.

### Diagnostics

- The implemented screen shows only Flutter target-platform and build-mode labels; it does not claim app version, commit, or OS version.
- No device serials, stable hardware IDs, account identifiers, IP addresses, contact names, cryptographic fingerprints, keys, message text, environment variables, or file paths are read or displayed.
- Data is local and read-only; there is no upload, crash-reporting, clipboard, or log export. The widget test supplies only the two supported fields and checks the visible labels.

### Basic settings placeholder

- A local Settings page is reachable from the conversation-list app bar/menu.
- Include only a session-local theme selection (`system`, `light`, `dark`) and a link to Diagnostics. Theme selection resets on process restart in G1; no preferences plugin or persistence is added.
- Make no claims about privacy controls, messaging behavior, or stored settings.

## 4. Tests and local commands

### Pure Dart/unit/widget coverage

- App starts on onboarding; continue reaches the conversation list; back/navigation behavior is stable.
- Empty-state UI explicitly says messaging is unavailable; no UI implies encryption or recipient delivery.
- Settings navigation works; theme selection updates the in-memory app theme and resets on app restart.
- Diagnostics render only the supported non-sensitive platform/build fields; no device-specific source or user-data field exists in the diagnostics model.
- No network, runtime permission, Bluetooth, key store, database, or crash-report SDK is instantiated by the shell.
- Widget tests for screens/navigation/theme are implemented with deterministic data and no wall-clock sleeps. `flutter analyze` and `flutter test` have not yet run on any host.

### Android acceptance

On the approved Windows/Android host, record Flutter/Dart, JDK, Gradle/AGP, Android SDK/build-tools, emulator image, OS build, and app commit. Run:

```powershell
# From mobile/app; no --overwrite. Add Android native host without replacing Dart sources.
flutter create --empty --project-name duman_messenger --org com.example --platforms android .
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
flutter devices
flutter run -d <approved-android-emulator-id>
```

Acceptance requires a successful debug APK build, install, launch, first-frame rendering, onboarding-to-empty-list navigation, diagnostics navigation, and Android system-back behavior on an approved emulator. Record exact device/API and observed result. Do not sign a release APK/AAB, upload to Google Play, or use production signing credentials.

### iOS acceptance

On the approved macOS/Xcode host, record macOS, Xcode/iOS SDK, Simulator runtime, Flutter/Dart, app commit, and selected build settings. Run:

```bash
flutter pub get
flutter analyze
flutter test
flutter build ios --simulator
flutter devices
flutter run -d <approved-ios-simulator-id>
```

Acceptance requires a successful iOS Simulator build, install, launch, first-frame rendering, onboarding-to-empty-list navigation, and diagnostics navigation. Record the exact simulator/runtime and result. Do not archive, sign for distribution, submit to App Store Connect, or claim App Store readiness.

Run the shell smoke test on each platform from a clean install and a second relaunch. Record screenshots/logs only if they contain no user/device secrets. Do not use GitHub Actions or remote CI for this milestone.

## 5. Exact G1 acceptance criteria

G1 Foundation is complete only when **all** criteria below have independent local evidence:

1. Owner-approved, checked-in Flutter/Dart and platform toolchain pins are reproducible on an authorized Windows/Android host and a macOS/Xcode host.
2. `flutter analyze` and `flutter test` pass on the pinned Flutter/Dart SDK without skipped/disabled/relaxed tests.
3. Android debug APK builds and installs/launches on the approved Android emulator; navigation and diagnostics smoke test pass.
4. iOS Simulator app builds and installs/launches with the approved Xcode/runtime; navigation and diagnostics smoke test pass.
5. No `node:crypto`, production crypto/provider, keys, contacts, storage, real message, route/packet format, BLE/permission, or analytics behavior is present.
6. No existing simulator test, golden vector, routing default, test timeout, or production simulator semantics was changed to make the shell pass.
7. Evidence names exact app commit, toolchain/device versions, commands, and outcomes. Emulator/Simulator evidence is clearly separated from later physical-device/radio evidence.

A G1 pass does **not** mean mobile secure messaging, BLE, a key store, or real device-to-device operation is implemented. Physical Android/iOS installation may be recorded as an additional smoke check but is not a substitute for the required emulator/Simulator build gates.

## 6. Dependency-ordered follow-up

1. Verify the owner-reported Flutter 3.47.8 / Dart 3.13.7 matrix and read-only Windows preflight; see [WINDOWS-G1-QUICKSTART.md](../../docs/mobile/WINDOWS-G1-QUICKSTART.md).
2. On Windows, run `flutter create --empty --project-name duman_messenger --org com.example --platforms android .` from `mobile/app` without `--overwrite`, then `flutter pub get`. Review/commit the generated Android host, `.metadata`, and `pubspec.lock`; inspect AGP/Gradle and confirm JDK compatibility.
3. Run `flutter analyze`, `flutter test`, and `flutter build apk --debug`; only report what actually runs. Continue to Android emulator smoke evidence when available.
4. On an authorized macOS/Xcode host, add the iOS host with `flutter create --empty --project-name duman_messenger --org com.example --platforms ios .` (no `--overwrite`), then complete the separate Simulator build/launch gate. Do not enable workflows or incur service cost without explicit approval.
5. Record separate Windows/Android and macOS/iOS results.
6. Separately obtain owner/security approval for identity, protocol, packet, provider, key storage, and persistence before any secure-messaging or transport implementation. G1 does not authorize those features.

Only the minimal G1 shell described here is in scope. Shared app source and tests now exist, but the generated platform hosts, dependency lockfile, and build/test/device evidence remain outstanding. This plan does not authorize production messaging, protocol/packet changes, cryptography, radio/mesh transport, workflow changes, deployment, or publication.
