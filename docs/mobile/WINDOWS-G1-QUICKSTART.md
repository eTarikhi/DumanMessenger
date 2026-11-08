# Windows 11 quickstart for DumanMessenger G1 and G2-A

**Purpose:** Validate the checked-in G1 Flutter shell and fresh G2-A Android BLE diagnostic source on the owner’s Windows 11 x64 machine. The Flutter app, widget tests, `pubspec.lock`, and Android host/Gradle files are present under `mobile/app`; G2-A reports prerequisites only and performs no BLE radio operation. Flutter analysis/tests, Android builds, and device validation remain pending. These instructions are not evidence that this repository has built. The owner reports Flutter 3.47.8/Dart 3.13.7 and a successful standalone debug APK smoke build; that is not a DumanMessenger build. The Agent could not run Flutter/Dart/Java/Android tooling or tests. Use `tool/mobile/windows-g1-preflight.ps1` after setup; it is read-only.

## 1. Install free tools

Open PowerShell. `winget` is included with current Windows 11 App Installer; check it first. Install Git and Android Studio from their package IDs, and reopen PowerShell after installation:

```powershell
winget --version
winget install --id Git.Git -e
winget install --id Google.AndroidStudio -e
git --version
```

In Android Studio’s first-run wizard, choose the standard installation. In **Tools → SDK Manager**, install Android SDK Command-line Tools, Platform-Tools, and Android Emulator. The checked-in Android host selects `compileSdk` and NDK versions through the pinned Flutter Gradle plugin; inspect the generated values after Flutter setup rather than regenerating the host or guessing a build-tools version.

The G1 source uses the owner-reported matrix Flutter 3.47.8 / bundled Dart 3.13.7. Flutter tag `3.47.8` resolves to framework commit `737ba8f885dc774b53b442759999a312c9461e4e`; keep that SDK fixed during G1 verification and do not run `flutter upgrade` mid-cycle. The owner’s existing matching SDK can be used; only install it if needed, outside the repository.

```powershell
$FlutterRoot = 'C:\src\flutter'
New-Item -ItemType Directory -Force -Path 'C:\src' | Out-Null
if (-not (Test-Path -LiteralPath $FlutterRoot)) {
    git clone --depth 1 --branch 3.47.8 https://github.com/flutter/flutter.git $FlutterRoot
}
$env:FLUTTER_ROOT = $FlutterRoot
$FlutterBin = Join-Path $FlutterRoot 'bin'
$UserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$UserPathEntries = @($UserPath -split ';' | ForEach-Object { $_.Trim().TrimEnd('\') })
if ($UserPathEntries -notcontains $FlutterBin.TrimEnd('\')) {
    $UserPath = "$FlutterBin;$UserPath"
    [Environment]::SetEnvironmentVariable('Path', $UserPath, 'User')
}
[Environment]::SetEnvironmentVariable('FLUTTER_ROOT', $FlutterRoot, 'User')
$env:Path = "$FlutterBin;$env:Path"
flutter --version --machine
git -C $FlutterRoot rev-parse HEAD
& (Join-Path $FlutterRoot 'bin\cache\dart-sdk\bin\dart.exe') --version
```

Confirm Flutter 3.47.8, Dart 3.13.7, and (for a full clone) the recorded framework commit before building. Flutter supplies the Dart SDK for the app; do not install a separate Dart SDK into the Flutter app’s PATH. The repository’s existing `sim/mesh_sim` package has its own `^3.4.0` constraint; that does not select the Flutter app version.

## 2. Android SDK, PATH, Java, and licenses

In Android Studio, open **SDK Manager** and confirm its actual SDK location (normally `%LOCALAPPDATA%\Android\Sdk`). Install **Android SDK Command-line Tools**, **Platform-Tools**, and **Android Emulator**. The Android host is checked in; install the SDK platform/build-tools versions required by the Flutter Gradle configuration after the pinned Flutter SDK is available.

Set the user Android SDK path and update the current PowerShell session. If Android Studio shows another SDK path, use that path instead of the default below:

```powershell
$SdkRoot = Join-Path $env:LOCALAPPDATA 'Android\Sdk'
[Environment]::SetEnvironmentVariable('ANDROID_HOME', $SdkRoot, 'User')
$env:ANDROID_HOME = $SdkRoot
$SdkPathAdditions = @("$SdkRoot\platform-tools", "$SdkRoot\cmdline-tools\latest\bin")
$UserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$UserPathEntries = @($UserPath -split ';' | ForEach-Object { $_.Trim().TrimEnd('\') })
foreach ($Entry in $SdkPathAdditions) {
    if ($UserPathEntries -notcontains $Entry.TrimEnd('\')) {
        $UserPath = "$Entry;$UserPath"
        $UserPathEntries += $Entry.TrimEnd('\')
    }
}
[Environment]::SetEnvironmentVariable('Path', $UserPath, 'User')
$env:Path = "$FlutterRoot\bin;$SdkRoot\platform-tools;$SdkRoot\cmdline-tools\latest\bin;$env:Path"
flutter config --android-sdk $SdkRoot
flutter doctor -v
flutter doctor --android-licenses
```

Review and accept the Android SDK license prompts interactively. The preflight script does not accept licenses or change environment variables.

**JDK/AGP compatibility:** The checked-in Android host currently pins Android Gradle Plugin 9.1.0, Gradle wrapper 9.3.1, Kotlin Android plugin 2.4.0, and Java/Kotlin target 17. Do not regenerate or casually upgrade these settings. Android Studio includes a JBR/JDK; `flutter doctor -v` reports the Java binary Flutter selects. Verify that runtime against the official AGP compatibility requirements before building. If a compatible JDK is needed, use Android Studio’s bundled JBR or a free JDK distribution selected for this AGP; do not set a persistent `JAVA_HOME` until the selected runtime is confirmed. For the default Android Studio install, set the chosen compatible JDK in this PowerShell session only (change the path if the installation differs):

```powershell
$JdkHome = Join-Path $env:ProgramFiles 'Android\Android Studio\jbr'
$env:JAVA_HOME = $JdkHome
$env:Path = "$JdkHome\bin;$env:Path"
java -version
javac -version
```

From the checked-in `mobile\app\android` directory (starting at the repository root), verify the actual Gradle runtime with:

```powershell
Set-Location .\mobile\app\android
Get-ChildItem . -Recurse -File -Include *.gradle,*.gradle.kts | Select-String -Pattern 'com\.android\.application|com\.android\.tools\.build:gradle|compileSdk|buildToolsVersion'
Get-Content .\gradle\wrapper\gradle-wrapper.properties
.\gradlew.bat --version
```

## 3. Read-only preflight

From the repository root, run:

```powershell
$Preflight = & .\tool\mobile\windows-g1-preflight.ps1 -ProjectRoot .\mobile\app
$Preflight
$Preflight.ExitCode
```

`ExitCode` 0 means the script found no missing required components; warnings can still require action. `ExitCode` 1 lists missing components. The script only inspects commands, paths, and local version/license metadata. It does not install, write settings, invoke `sdkmanager`, accept licenses, start an emulator, or enumerate devices. It cannot certify AGP/JDK compatibility; use `flutter doctor -v` and the checked-in Gradle wrapper for that.

## 4. Create/select an emulator and debug a phone

In Android Studio open **Tools → Device Manager → Create Device**, choose an owner-approved Pixel profile, and install a current stable x64 system image compatible with the SDK/template. Do not pin an API level until the project’s supported Android range is selected. Then:

```powershell
flutter emulators
# Copy an emulator ID from the command above:
$AvdId = '<ID-FROM-flutter-emulators>'
flutter emulators --launch $AvdId
flutter devices
adb version
adb devices -l
```

For a physical Android phone, enable Developer Options and USB debugging, connect USB, unlock the phone, and accept its RSA authorization prompt. Verify it without publishing the device serial:

```powershell
adb devices -l
flutter devices
```

An emulator verifies UI/build and some lifecycle behavior; it does not prove physical BLE, background delivery, or interoperability.

## 5. Validate the checked-in Flutter app and Android host

The Flutter source, widget tests, `pubspec.lock`, and Android host are already checked in. G2-A adds Android BLE prerequisite diagnostics only: it requests `BLUETOOTH_CONNECT` when required to read local adapter state and performs no scan, advertising, connection, or message operation. Do **not** run `flutter create`, use `--overwrite`, regenerate Gradle files, or upgrade the pinned Android toolchain as part of this validation. The provisional application ID is `com.example.duman_messenger`; release identity is a separate owner decision.

From the repository root in PowerShell, after the Flutter/Android setup above:

```powershell
$RepoRoot = (Get-Location).Path
$AppRoot = Join-Path $RepoRoot 'mobile\app'
if (-not (Test-Path -LiteralPath $AppRoot)) { throw 'mobile\app source is missing' }
Push-Location $AppRoot
try {
    flutter pub get
    flutter analyze
    flutter test
    flutter build apk --debug
} finally {
    Pop-Location
}
```

The checked-in Android configuration pins AGP 9.1.0, Gradle wrapper 9.3.1, Kotlin Android plugin 2.4.0, and Java/Kotlin target 17. Confirm the JDK and SDK compatibility from `flutter doctor -v` and the checked-in wrapper before building; do not change these versions just to match a generic tutorial. Inspect `git status --short` and any `pubspec.lock` diff after `flutter pub get`. Keep `android/local.properties`, SDK paths, `.dart_tool`, caches, build outputs, and signing credentials out of Git. The app uses Flutter SDK widgets, `flutter_test`, and `flutter_lints`; there are no runtime plugins.

For an emulator/device smoke check after the build:

```powershell
flutter devices
# Copy an approved emulator/device ID from the output:
$DeviceId = '<DEVICE-ID-FROM-flutter-devices>'
flutter run -d $DeviceId
```

Open **Local diagnostics → Android BLE diagnostic**. On Android 12+, verify the Connect-permission prompt and the granted, denied, retryable, and manually recoverable guidance; turn Bluetooth off/on through Android itself and refresh. Verify lifecycle refresh when leaving/returning to the screen. On API 30 and earlier, confirm the legacy Bluetooth report without a prompt and verify that the required, capped `ACCESS_FINE_LOCATION` manifest entry is reported but not requested; its granted/denied status must not block local-adapter diagnostics. Record emulator and physical-device evidence separately; an emulator does not establish BLE interoperability. Do not test or claim scanning, advertising, pairing, GATT, connections, or messaging in G2-A.

The debug APK uses debug signing; do not create or commit a release keystore. None of these repository-specific commands or tests has been run by the Agent. The owner’s reported standalone Flutter APK is not a DumanMessenger build.

## 6. G1 shell and G2-A source boundary

The checked-in Android host and relevant G2-A source/tests include:

```text
mobile/app/pubspec.lock
mobile/app/android/app/src/main/AndroidManifest.xml
mobile/app/android/app/src/main/kotlin/com/example/duman_messenger/MainActivity.kt
mobile/app/android/app/src/main/kotlin/com/example/duman_messenger/BleDiagnosticManager.kt
mobile/app/lib/ble/ble_diagnostic_status.dart
mobile/app/lib/ble/ble_diagnostic_bridge.dart
mobile/app/lib/screens/ble_diagnostic_screen.dart
mobile/app/lib/app.dart
mobile/app/lib/app_routes.dart
mobile/app/lib/screens/diagnostics_screen.dart
mobile/app/test/ble_diagnostic_status_test.dart
mobile/app/test/ble_diagnostic_bridge_test.dart
mobile/app/test/ble_diagnostic_screen_test.dart
mobile/app/test/app_navigation_test.dart
```

The G1 onboarding/conversations/settings shell remains local and has no mock contacts or messages. Local diagnostics still display only target-platform and build-mode labels; a separate BLE screen reports local Android hardware, permission, adapter, Bluetooth-enabled, and advertising-capability status. G2-A has no runtime plugin, network client, message storage, identity/key/cryptography feature, or BLE radio operation. `ACCESS_FINE_LOCATION` is required in the manifest only through API 30 and is reported without gating the no-scan diagnostic, but it is not requested or used to access location; there is no location tracking or background-location permission. The only runtime permission request is Android 12+ `BLUETOOTH_CONNECT` for local adapter status; scan/advertise permissions are not requested. The screen has loading/error states for the native bridge and cancels its status subscription when disposed. Model, bridge, screen, and navigation tests are authored but have not been executed by the Agent.

## 7. iOS build strategy without a personal Mac

The repository is public, but GitHub reports its current `CI` workflow as **disabled manually**; its existing jobs all use `ubuntu-latest`, with no macOS job. No workflow was enabled or changed. GitHub’s `actions/runner-images` table currently lists macOS 26 Arm64 under labels including `macos-latest`/`macos-26`, and macOS 15 Arm64 under `macos-15`; it also records macOS 14 retirement on 2026-11-02. Labels, installed Xcode versions, and pricing/eligibility change, so select a runner only after checking the live image README and compatibility with the chosen Flutter release. `macos-latest` is a moving label.

Preferred first option, if owner-authorized: a GitHub-hosted macOS runner for `flutter test` and an iOS Simulator build. It needs Actions to be re-enabled by an authorized repository owner; no cost/quota assumptions are made here. Alternative hosted Macs (for example, a MacStadium service or an AWS EC2 Mac host) require owner-controlled accounts and may incur charges; neither is authorized or used. Do not enable workflows, store signing secrets, or start paid services without explicit approval.

On an authorized Mac with Flutter 3.47.8 and Xcode installed, add only the missing iOS host from the app directory (do not use `--overwrite`):

```bash
cd mobile/app
flutter create --empty --project-name duman_messenger --org com.example --platforms ios .
flutter pub get
flutter analyze
flutter test
flutter build ios --simulator
flutter devices
```

An iOS Simulator build does not require App Store distribution signing. A physical iPhone debug install requires an owner-controlled Apple development team/signing and provisioning setup. App Store publication remains unauthorized and is not part of G1. No iOS build or simulator test has passed; no Mac/Xcode execution was available to the agent.

## References

- [Flutter Windows install](https://docs.flutter.dev/get-started/install/windows/mobile)
- [Official Flutter 3.47.8 app templates](https://github.com/flutter/flutter/tree/3.47.8/packages/flutter_tools/templates/app)
- [Android Studio](https://developer.android.com/studio/install) and [SDK Manager](https://developer.android.com/tools/sdkmanager)
- [Android Gradle Plugin release/compatibility notes](https://developer.android.com/build/releases/gradle-plugin)
- [GitHub-hosted runner images and labels](https://github.com/actions/runner-images)
- [GitHub-hosted runners](https://docs.github.com/en/actions/using-github-hosted-runners/about-github-hosted-runners)
- [AWS EC2 Mac](https://aws.amazon.com/ec2/instance-types/mac/) and [MacStadium](https://www.macstadium.com/) (paid-service candidates; not authorized or price-checked)
