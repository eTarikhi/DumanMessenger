# Mobile toolchain and physical-device requirements

**Status:** Owner setup guide and version-pin blocker list. No Flutter app or mobile toolchain was installed or built in this milestone. This document does not claim Android/iOS tests passed.
**Observed host:** Linux `6.1.158+`, x86_64; Node `v22.22.3`, npm `10.9.8`; Dart/Flutter/Java/Gradle/Android SDK/Xcode unavailable.
**Evidence snapshot:** `a1f1916981c2244a2f8664573b66afbd5a2659b4`, reviewed 2026-11-05.

## 1. Version facts and unresolved pins

There is no Flutter application, Flutter `pubspec.yaml`, mobile `pubspec.lock`, Android Gradle project/wrapper, iOS project/Podfile, deployment target, or mobile CI in this checkout. Therefore an exact *mobile* Flutter/Dart/AGP/Gradle/JDK/Android SDK/Xcode/macOS/iOS matrix cannot be truthfully inferred or tested. The owner must approve and pin one compatible matrix before creating the mobile shell. Do not describe “latest stable” as reproducible evidence.

| Component | Exact evidence/requirement now | Pin required before mobile build |
|---|---|---|
| Flutter | No Flutter SDK or app project exists. Use an owner-approved stable release compatible with Android/iOS targets and selected dependencies. | Exact Flutter release tag **and Git commit**; record in project setup docs/CI. |
| Dart | Flutter bundles its Dart SDK; do not install an unrelated standalone Dart for the Flutter app. The existing pure-Dart simulator declares `sdk: ^3.4.0` in `sim/mesh_sim/pubspec.yaml` (Dart `>=3.4.0 <4.0.0` constraint). | Exact bundled Dart version shown by the chosen Flutter release; ensure simulator package compatibility and run its tests on a host with Dart. |
| Windows Android host | Supported 64-bit Windows version per the chosen Flutter and Android Studio releases; Android Studio stable, Android SDK command-line tools, platform-tools/`adb`, platform/build-tools, JDK compatible with the pinned Android Gradle Plugin, and Gradle wrapper. | Windows edition/build; exact Android Studio, JDK, AGP, Gradle, `compileSdk`, `targetSdk`, `minSdk`, build-tools, emulator system image, and Flutter/Dart pairing. Check Google Play target API policy again at release time. |
| Android emulator | Android Emulator and a system image for the approved API levels. | Exact image/API and device profile. Emulator evidence is not physical BLE evidence. |
| macOS/iOS host | A macOS version supported by the selected Xcode; Xcode and iOS SDK compatible with the chosen Flutter release; Xcode command-line tools and an iOS Simulator runtime. CocoaPods is needed only if chosen Flutter plugins require it. | Exact macOS version/build, Xcode version/build, iOS SDK/deployment target, Simulator runtime, CocoaPods version if applicable, and Flutter/Dart pairing. Xcode and deployment targets must be selected together. |
| iOS device signing | Owner-controlled development signing/provisioning is needed to install on physical iPhones; keep certificates/private signing keys out of the repository/chat. | Named test devices, supported iOS versions, Apple development team access, signing procedure. App Store distribution is not authorized. |
| Physical-device matrix | Real radio needs physical phones, not emulators alone. BLE capability, vendor/OS restrictions, permissions, and background behavior must be verified. | For Android↔Android, iOS↔iOS, and Android↔iOS claims, budget at least two supported Android phones and two supported iPhones, with exact models/OS builds recorded. At minimum, one Android and one iPhone are needed for cross-platform smoke testing. |

**Release scope:** Android distribution target is Google Play. iOS implementation and testing are required. **App Store publication remains unauthorized** and requires a separate owner decision.

## 2. Windows owner setup for Android/Dart

These commands are a setup procedure, not commands run by this agent. First approve exact Flutter/Dart and Android/Java/Gradle/SDK pins. Do not run the placeholder Flutter tag. Windows can build/test Android, but it cannot build or sign an iOS app.

### 2.1 Install baseline tools

Open PowerShell. Install Git and Android Studio from the approved channels; `winget` IDs below are common stable packages and should be confirmed on the owner's Windows catalog before installation:

```powershell
winget install --id Git.Git -e
winget install --id Google.AndroidStudio -e
```

Open Android Studio once and install the Android SDK command-line tools, platform-tools, emulator, and the exact approved SDK platform/build-tools/system image. Do not select arbitrary `latest` versions for a release build; use the versions pinned for the app.

Install the approved Flutter release outside the repository. Flutter's GitHub tags are used here so the exact tag/commit can be recorded:

```powershell
$FlutterTag = '<OWNER-APPROVED-EXACT-FLUTTER-TAG>'
$FlutterHome = Join-Path $env:USERPROFILE 'dev\flutter'

# Replace the placeholder only after owner approval; do not check out the moving `stable` branch for a reproducible build.
git clone --depth 1 --branch $FlutterTag https://github.com/flutter/flutter.git $FlutterHome
$env:Path = "$FlutterHome\bin;$env:Path"
```

Flutter supplies the Dart SDK used by the app. Do not separately install a mismatched Dart SDK. For the Java runtime, use the exact JDK supported by the selected AGP/Gradle pair; Android Studio's bundled runtime may be suitable, but verify what Gradle/Flutter actually select. Do not assume one JDK version before the Android project pins AGP/Gradle.

### 2.2 Configure the Android SDK

After installing Android command-line tools, set `ANDROID_HOME` to the actual SDK location (the default below is typical, not guaranteed):

```powershell
$SdkRoot = Join-Path $env:LOCALAPPDATA 'Android\Sdk'
$env:ANDROID_HOME = $SdkRoot
[Environment]::SetEnvironmentVariable('ANDROID_HOME', $SdkRoot, 'User')
$env:Path = "$SdkRoot\platform-tools;$SdkRoot\cmdline-tools\latest\bin;$env:Path"

flutter config --android-sdk $SdkRoot
flutter doctor --android-licenses
```

If an approved project later pins `compileSdk`/build-tools explicitly, install those exact packages through SDK Manager or `sdkmanager.bat`, for example:

```powershell
$CompileSdk = '<PINNED-COMPILE-SDK>'
$BuildTools = '<PINNED-BUILD-TOOLS-VERSION>'
$SdkManager = Join-Path $SdkRoot 'cmdline-tools\latest\bin\sdkmanager.bat'
& $SdkManager "--sdk_root=$SdkRoot" "platform-tools" "platforms;android-$CompileSdk" "build-tools;$BuildTools" "emulator"
```

Do not run the placeholders as written. The chosen Flutter/Android Studio release may use a different SDK command-line-tools directory; verify the actual executable path in Android Studio SDK Manager.

### 2.3 Windows verification checklist

Run in a fresh PowerShell after setup and record full output/version values (do not include credentials or signing material):

```powershell
flutter --version --machine
flutter doctor -v
dart --version
java -version
adb version
adb devices -l
```

Also record the selected SDK packages and Android Studio/AGP/Gradle versions:

```powershell
$env:ANDROID_HOME
& (Join-Path $env:ANDROID_HOME 'cmdline-tools\latest\bin\sdkmanager.bat') --list
```

After a Flutter project exists and the owner-approved lockfiles are committed, the project-specific verification sequence should include:

```powershell
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
flutter devices
```

Install/launch the debug build on an approved emulator and physical phone; record the app commit, device, Android build, permissions, and result. `flutter doctor` and an APK build do not prove BLE interoperability. Run Dart simulator commands separately from the repo root:

```powershell
Set-Location .\sim\mesh_sim
dart pub get
dart analyze
dart test
```

The Dart simulator test commands have **not** been run in the current environment.

## 3. macOS/Xcode/iOS owner prerequisites and verification

A supported macOS host is mandatory for iOS builds, simulator runs, and signing. Windows/Linux cannot replace it. Select a macOS/Xcode pair supported by the owner-approved Flutter release; record exact macOS and Xcode builds, SDK, deployment target, and simulator runtime. Install Xcode from Apple's authorized channel, open it once, accept required terms, install the command-line components and approved Simulator runtime. Add CocoaPods only if an approved dependency requires it; pin its version rather than installing an unreviewed global latest.

On the Mac, verify and record:

```bash
sw_vers
xcode-select --print-path
xcodebuild -version
xcodebuild -showsdks
xcrun --version
xcrun simctl list devices available
flutter --version --machine
flutter doctor -v
flutter devices
pod --version   # only if CocoaPods is part of the approved dependency set
```

After the Flutter app/project exists, run the approved Flutter tests and an iOS simulator build/launch. For a physical iPhone, use owner-managed development signing/provisioning and verify installation, permission prompts, connect/disconnect, process termination/relaunch, and supported foreground/background states. Record device model, iOS build, Xcode build, signing mode, app commit, and result. Do not include private certificates/profiles or user messages in evidence.

**No macOS, Xcode, iOS Simulator, iPhone, or Apple signing setup was available or used here.** No iOS build, launch, or test passed in this milestone.

## 4. Physical-device acceptance matrix

| Claim | Minimum physical-device evidence | Additional evidence required |
|---|---|---|
| Android install/launch | One owner-approved Android phone; record model, API/build, install source, permissions, app version | Repeat on minimum supported Android API and a current/reference device before release readiness. |
| iOS install/launch | One owner-approved iPhone; record model, iOS build, Xcode/signing/app version | Repeat on minimum supported iOS deployment target and a current/reference device. This is engineering/testing, not App Store publication. |
| Android↔Android messaging | Two supported Android phones and real radio | Verified/unverified contact, loss, duplicate, disconnect, retry, process death/restart, permission denial, and ACK semantics. |
| iOS↔iOS messaging | Two supported iPhones and real radio | Same failure cases, plus app lifecycle/background behavior on approved iOS versions. |
| Android↔iOS messaging | One supported Android phone plus one supported iPhone | Interoperability vectors, permissions, frame limits/fragmentation, reconnect, and loss/retry with exact app/provider versions. |
| Battery/background claim | Named devices under repeatable workload and OS state | Battery/thermal measurement, background restrictions, screen-off/termination conditions, and repeat runs. No simulator result substitutes. |

Emulator/simulator runs are useful for UI, parser, state, and some lifecycle tests, but are not real BLE or physical-device evidence. Test only synthetic contacts, messages, and keys.

## 5. Version-pin decision required before creating the shell

Owner should approve a single checked-in toolchain matrix containing:

- Flutter release tag and SDK Git commit; bundled Dart version.
- Windows version for Android builds; Android Studio release; JDK; AGP; Gradle wrapper; Android `minSdk`, `compileSdk`, `targetSdk`, build-tools, emulator image.
- macOS version/build; Xcode version/build; iOS SDK/deployment target; Simulator runtime; CocoaPods version if used.
- Required physical device models, Android API/iOS versions, radio capability, and signing arrangements.
- Plugin/provider versions, lockfiles, licenses, and any native build prerequisites.

The minimum Android/iOS OS versions, Play target API, JDK/AGP pairing, Xcode/macOS pair, and device set are **not yet approved**. Select them against the current official Flutter, Android, Apple, and Google Play compatibility/policy pages at implementation/release time; do not infer them from the simulator or today's host.

## 6. Current result and non-claims

The current Linux host has Node/npm only for the runnable local baseline. `dart`, `flutter`, `java`, `gradle`, `adb`, `sdkmanager`, `xcodebuild`, `xcrun`, and `pod` were unavailable. There is no mobile project to build. The full TypeScript suite is 517/527 with ten strict timeouts; that is browser simulator/reference evidence only. The Dart suite, Flutter tests, Android/iOS builds, emulators, and physical-device tests are **not run**, not passed. See [BASELINE.md](BASELINE.md), [TEST-RESULTS.md](TEST-RESULTS.md), and [IMPLEMENTATION-STATUS.md](IMPLEMENTATION-STATUS.md).
