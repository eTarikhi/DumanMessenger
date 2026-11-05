# Mobile toolchain readiness — Windows Android and macOS/iOS

**Status:** Setup and verification instructions are prepared; **the mobile toolchains are not installed/verified on this host and no mobile build has run.**
**Observed agent host:** Linux `6.1.158+` x86_64; `dart`, `flutter`, `java`, `gradle`, `adb`, `sdkmanager`, `xcodebuild`, `xcrun`, and `pod` are unavailable. There is no Flutter app or Android/iOS platform project.
**Source snapshot:** `a1f1916981c2244a2f8664573b66afbd5a2659b4`.

For the concise Windows 11 G1 sequence and read-only preflight, see [WINDOWS-G1-QUICKSTART.md](../../docs/mobile/WINDOWS-G1-QUICKSTART.md) and [`windows-g1-preflight.ps1`](../../tool/mobile/windows-g1-preflight.ps1). The preflight has not run on Windows in this workspace.

## 1. Version pins and owner choices

The only existing mobile-adjacent SDK constraint is `sim/mesh_sim/pubspec.yaml`: `sdk: ^3.4.0`, meaning Dart `>=3.4.0 <4.0.0`. This is a simulator constraint, not a Flutter app pin. Flutter bundles its own Dart SDK; the Flutter app must use the Dart version bundled by its owner-approved Flutter release.

No Flutter release, Flutter/Dart pair, Android API range, JDK/AGP/Gradle pair, Android build-tools version, iOS deployment target, Xcode/macOS pair, plugin set, or physical-device models are present or approved. Do not substitute arbitrary “latest stable” versions and call them reproducible. Select and record the exact matrix before creating the Flutter shell:

| Decision | Must be recorded before build |
|---|---|
| Flutter/Dart | Flutter exact stable tag and Git commit; bundled Dart version from `flutter --version --machine`; dependency lockfile. |
| Windows/Android | Windows edition/build; Android Studio or command-line tools release; JDK; AGP; Gradle wrapper; `minSdk`, `compileSdk`, `targetSdk`, build-tools, emulator image/API. Check current Google Play target-API policy again at release time. |
| macOS/iOS | macOS version/build; Xcode version/build; iOS SDK; app deployment target; simulator runtime; CocoaPods version if a selected plugin requires it. |
| Devices | Exact Android/iPhone models and OS builds, debug-signing/provisioning approach, and supported OS boundary. |
| Dependencies | Crypto provider, plugins, native dependencies, licenses, versions, and lockfiles. |

Android distribution target is **Google Play**. iOS implementation and testing are required. **App Store distribution is not authorized** and remains a separate owner decision.

## 2. Windows setup and verification (Android + Dart)

Windows can build and debug Android; it cannot produce an iOS/Xcode build. Run these steps on the owner's Windows 10/11 64-bit development host after approving the version matrix. `winget` package IDs should be confirmed in the owner's configured catalog.

### 2.1 Install Dart for the existing pure-Dart simulator

A standalone Dart 3.4.0 SDK satisfies the current simulator's declared lower bound and remains `<4.0.0`. This is an exact **simulator** SDK example, not the selected Flutter app SDK:

```powershell
$DartVersion = '3.4.0'
$DartArchive = Join-Path $env:TEMP "dartsdk-$DartVersion.zip"
$DartUrl = "https://storage.googleapis.com/dart-archive/channels/stable/release/$DartVersion/sdk/dartsdk-windows-x64-release.zip"
$DartRoot = Join-Path $env:USERPROFILE 'dev\dart-3.4.0'
Invoke-WebRequest -Uri $DartUrl -OutFile $DartArchive
New-Item -ItemType Directory -Force -Path $DartRoot | Out-Null
Expand-Archive -LiteralPath $DartArchive -DestinationPath $DartRoot -Force
$DartBin = Join-Path $DartRoot 'dart-sdk\bin'
$env:Path = "$DartBin;$env:Path"
dart --version
```

Expected output must identify Dart **3.4.0**. If the owner chooses a later Dart SDK for simulator work, it must remain in the declared `>=3.4.0 <4.0.0` range and be recorded. For Flutter app work, place the approved Flutter `bin` ahead of standalone Dart on `PATH` so Flutter and its bundled Dart are used together.

### 2.2 Install Flutter at an exact approved tag

```powershell
winget install --id Git.Git -e
$FlutterTag = '<OWNER-APPROVED-EXACT-FLUTTER-TAG>'
$FlutterHome = Join-Path $env:USERPROFILE 'dev\flutter'

# Do not run with the placeholder or use the moving stable branch for a reproducible build.
git clone --depth 1 --branch $FlutterTag https://github.com/flutter/flutter.git $FlutterHome
$env:Path = "$FlutterHome\bin;$env:Path"
flutter --version --machine
git -C $FlutterHome rev-parse HEAD
flutter doctor -v
```

The recorded Flutter tag/commit determines the app's Dart version. Do not independently upgrade the bundled Dart SDK. If Git tag installation is not the owner's approved distribution method, use the matching official Flutter archive and record its version/checksum.

### 2.3 Install Android Studio/SDK/build tools

```powershell
winget install --id Google.AndroidStudio -e
```

Launch Android Studio once. In **SDK Manager**, install:

- Android SDK Command-line Tools (latest supported by the pinned project matrix).
- Android SDK Platform Tools (`adb`).
- Android Emulator.
- The pinned `platforms;android-<compileSdk>` and `build-tools;<version>`.
- The pinned emulator system image/API and an owner-selected device profile.

Set `ANDROID_HOME` to the actual SDK directory (the usual path below must be checked on the host):

```powershell
$SdkRoot = Join-Path $env:LOCALAPPDATA 'Android\Sdk'
$env:ANDROID_HOME = $SdkRoot
[Environment]::SetEnvironmentVariable('ANDROID_HOME', $SdkRoot, 'User')
$env:Path = "$SdkRoot\platform-tools;$SdkRoot\cmdline-tools\latest\bin;$FlutterHome\bin;$env:Path"
flutter config --android-sdk $SdkRoot
flutter doctor --android-licenses
winget list --id Google.AndroidStudio -e
git --version
java -version
flutter --version --machine
dart --version
```

For a pinned project, install exact SDK packages (replace placeholders only after the owner selects `compileSdk`/build-tools):

```powershell
$CompileSdk = '<PINNED-COMPILE-SDK>'
$BuildTools = '<PINNED-BUILD-TOOLS-VERSION>'
$SdkManager = Join-Path $SdkRoot 'cmdline-tools\latest\bin\sdkmanager.bat'
& $SdkManager "--sdk_root=$SdkRoot" "platform-tools" "emulator" "platforms;android-$CompileSdk" "build-tools;$BuildTools"
& $SdkManager --licenses
```

Use a JDK compatible with the exact AGP/Gradle pair. Do not assume Java 17/21 or an Android Studio bundled runtime until the project pins AGP/Gradle and `flutter doctor -v` confirms the runtime Flutter uses. Once the project exists, verify Gradle's selected runtime with its wrapper:

```powershell
java -version
.\gradlew.bat --version
```

The `gradlew.bat` command is run from the future app's `android` directory; it does not exist in the current repository.

### 2.4 Android emulator verification

Create an emulator from Android Studio **Device Manager** using an approved system image. Then verify:

```powershell
flutter doctor -v
adb version
adb devices -l
flutter devices
& (Join-Path $SdkRoot 'cmdline-tools\latest\bin\sdkmanager.bat') --list
```

The emulator should appear as an `emulator-...` device in `adb devices -l` and in `flutter devices`. Record image/API and emulator version. A working emulator verifies a host toolchain; it does not prove Bluetooth LE behavior or physical-device background behavior.

### 2.5 Physical Android debugging

On each owner-approved Android handset: enable Developer options and USB debugging; connect USB; accept that computer's RSA prompt; confirm the device is unlocked and authorized. Verify without exposing personal data:

```powershell
adb devices -l
adb shell getprop ro.product.model
adb shell getprop ro.build.version.sdk
adb shell pm list features | findstr /i bluetooth
flutter devices
```

Expected: one authorized device in `adb devices -l`; record model, API, build, and Bluetooth feature result. After a Flutter app exists, install/launch only its debug build using `flutter run -d <adb-device-id>` and record permission prompts, disconnect/reconnect, and process restart. Do not include device serials, accounts, message content, or secrets in public reports.

### 2.6 Simulator package checks on Windows

From the repository root, run Dart checks separately from Flutter app tests:

```powershell
Set-Location .\sim\mesh_sim
dart pub get
dart --version
dart analyze
dart test
```

These commands have **not** been run in this Linux environment. They verify the existing Dart simulator only, not a Flutter mobile app.

## 3. macOS/Xcode/iOS setup and verification

An owner-controlled macOS host is required for Xcode, the iOS SDK, Simulator, code signing, and iPhone installation. Windows/Linux cannot replace it. Pin a macOS release supported by the selected Xcode and Flutter release; the exact pair cannot be supplied before the target/dependency matrix is selected.

### 3.1 Install and select Xcode

Install the approved Xcode release through Apple's authorized channel, open it once, and install the selected Simulator runtime. Then run:

```bash
sw_vers
xcode-select --install
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
sudo xcodebuild -runFirstLaunch
xcodebuild -version
xcodebuild -showsdks
xcrun --version
xcrun simctl list devices available
```

`xcode-select --install` may report that command-line tools are already installed; verify the selected developer directory with `xcode-select --print-path`. Record the macOS, Xcode, SDK, and simulator-runtime versions. Do not update Xcode/macOS outside the approved matrix during a verification run.

### 3.2 Install the approved Flutter release on macOS

Use the same owner-approved Flutter tag/commit as Windows (unless an explicit cross-platform exception is documented):

```bash
FLUTTER_TAG='<OWNER-APPROVED-EXACT-FLUTTER-TAG>'
FLUTTER_HOME="$HOME/development/flutter"
# Replace the placeholder only after approval; do not clone the moving stable branch as a release pin.
git clone --depth 1 --branch "$FLUTTER_TAG" https://github.com/flutter/flutter.git "$FLUTTER_HOME"
export PATH="$FLUTTER_HOME/bin:$PATH"
flutter --version --machine
git -C "$FLUTTER_HOME" rev-parse HEAD
flutter doctor -v
flutter devices
```

Flutter bundles Dart. Record the exact Dart version from `flutter --version --machine`. CocoaPods is required only if an approved Flutter plugin/native dependency requires it. If so, install the owner-pinned CocoaPods version using the selected Ruby/package-management method, then verify `pod --version`; do not install an unpinned global latest by default.

### 3.3 Simulator verification

With the approved runtime installed:

```bash
xcrun simctl list devices available
flutter devices
```

After the app project exists, run its unit/widget tests and build/launch a debug iOS Simulator app. Record the simulator model/runtime, Xcode, Flutter/Dart, app commit, and output. A Simulator result is not physical BLE or battery evidence.

### 3.4 Physical iPhone signing and debugging

Physical installation requires an owner-controlled Apple development team/signing setup and device provisioning. Use Xcode's Accounts/Signing facilities and the owner's approved profile; do not commit certificates, private keys, provisioning secrets, or personal identifiers. Pair/trust each phone with the Mac, enable Developer Mode where required by its iOS version, and verify:

```bash
xcrun xcdevice list
xcrun devicectl list devices
flutter devices
```

Some Xcode versions may not provide `devicectl`; in that case use the Xcode Devices and Simulators window and `xcrun xcdevice list`. Record the phone model, iOS build, Xcode build, signing mode, and app commit. After the app exists, launch its debug build using `flutter run -d <device-id>`; test install, permissions, disconnect/reconnect, process termination/relaunch, and only the explicitly supported background states. Do not report an iOS build until a real build and launch has been performed on this Mac.

**No macOS, Xcode, iOS Simulator, iPhone, Apple signing setup, or iOS command above was available or used here.**

## 4. Physical-device coverage needed

For full protocol/interoperability claims, plan for at least two supported Android phones and two supported iPhones so same-platform and cross-platform paths can all be exercised:

- Android↔Android on real BLE/radio.
- iOS↔iOS on real BLE/radio.
- Android↔iOS on real BLE/radio.
- Minimum supported OS and a current/reference OS per platform, after the owner selects support boundaries.
- Verified and unverified contact flows; key change; permission denial; loss, duplicate, retry, reconnect; app force-stop/reboot; foreground/background constraints; fragmentation/MTU limits.

An Android emulator and iOS Simulator are still required for their respective build/install/launch checks, but they do not replace physical radio evidence. Tests use synthetic identities/messages only.

## 5. Readiness result and non-claims

- Windows Dart/Flutter/Android setup instructions and commands are documented, but none were run here.
- iOS/macOS/Xcode prerequisites and commands are documented, but none were run here.
- Exact mobile versions remain **blocked on owner approval**; the Dart simulator constraint `^3.4.0` is not a Flutter pin.
- No Flutter scaffold, Android project, iOS project, install, build, simulator launch, or physical-device test exists or passed.
- The current browser build and TypeScript simulator tests are not mobile evidence. Current full TypeScript status remains 517/527 with ten timeouts; see [TIMEOUT-ROOT-CAUSE.md](TIMEOUT-ROOT-CAUSE.md).

For the earlier toolchain assessment, see [TOOLCHAIN-REQUIREMENTS.md](TOOLCHAIN-REQUIREMENTS.md). For the proposed minimum app foundation and build gates, see [G1-IMPLEMENTATION-PLAN.md](G1-IMPLEMENTATION-PLAN.md).

## 6. Reference setup pages

- [Flutter install — Windows](https://docs.flutter.dev/get-started/install/windows/mobile)
- [Flutter install — macOS/iOS](https://docs.flutter.dev/get-started/install/macos/mobile-ios)
- [Android Studio installation](https://developer.android.com/studio/install)
- [Android SDK command-line tools](https://developer.android.com/tools/sdkmanager)
- [Apple Xcode](https://developer.apple.com/xcode/)

Recheck compatibility/policy pages when selecting toolchain versions and again before Google Play release; no live compatibility or store-policy check was performed as part of this documentation task.
