# G2-C Owner Windows Validation Guide

**Owner-run handover only.** The commands below were not run in the agent workspace. Keep this guide as the reproducible procedure.

**Validation outcome (2026-11-09, owner-reported):** `flutter analyze` passed, `flutter test` reported 67/67 passed, `flutter build apk --debug` succeeded, and the BLE workflow works on the owner's two physical phones. Those results are recorded with their provenance limits in [G2-C-ACCEPTANCE-CHECKLIST.md](G2-C-ACCEPTANCE-CHECKLIST.md#3-recorded-results). Transport-scope acceptance is recorded there; **security acceptance is not** — no independent review has occurred, and nothing in this guide establishes authentication, confidentiality, or production readiness.

The steps below remain the way to re-run the evidence on a new SHA or a new machine. Record the commit SHA, toolchain versions and full command output with every run; the 2026-11-09 report did not include them.

## Target and prerequisites

- Windows 11 64-bit.
- Flutter 3.47.8 stable (record the output of `flutter --version`).
- Android SDK and platform tools already installed; Android Studio/SDK tools configured.
- One physical Android 8.1 / API 27 phone. A second BLE-capable phone is needed for peer/client-server tests; two-device acceptance remains separate.
- The handover archive is a source snapshot of repository baseline `83606d58ca106496f2da56f5a5676efa0868c0d4` plus uncommitted G2-C changes. It excludes `.git`; it is not a patch or commit.

## 1. Extract safely and preserve existing work

Do not extract over the owner's existing clone. First record and preserve any local changes. In PowerShell:

```powershell
$OwnerRepo = 'C:\src\DumanMessenger'   # change to the existing clone
$Archive = 'C:\handover\DumanMessenger-G2C-Phase3-Handover.zip'
$Stage = 'C:\handover\DumanMessenger-G2C-Phase3-Handover'

 git -C $OwnerRepo status --short --branch
 git -C $OwnerRepo diff --binary > "$env:USERPROFILE\Desktop\DumanMessenger-before-G2C.patch"
 Copy-Item -LiteralPath $OwnerRepo -Destination "$env:USERPROFILE\Desktop\DumanMessenger-backup" -Recurse
 New-Item -ItemType Directory -Force -Path $Stage | Out-Null
 Expand-Archive -LiteralPath $Archive -DestinationPath $Stage -Force
 Get-Content (Join-Path $Stage 'HANDOVER-README.txt')
 Get-Content (Join-Path $Stage 'CHANGED-PATHS.txt')
```

The copy/patch are precautionary; do not reset, clean, stash, or overwrite the existing clone. Keep the extracted tree separate. If local work exists, validate in a new clone/copy and reconcile deliberately after validation.

## 2. Verify baseline and compare source

The archive contains a full source snapshot without `.git`. Verify the owner clone has the expected commit before creating a disposable validation clone:

```powershell
$Base = '83606d58ca106496f2da56f5a5676efa0868c0d4'
 git -C $OwnerRepo rev-parse HEAD
 git -C $OwnerRepo cat-file -e "$Base^{commit}"
 git -C $OwnerRepo status --short
```

If the clone is not at that baseline, do not change it in place. Create a separate temporary clone from the same local/remote repository, then check out the exact baseline there. For a clean clone from the owner's configured remote:

```powershell
$ValidationRepo = 'C:\src\DumanMessenger-G2C-validation'
$Remote = (git -C $OwnerRepo remote get-url origin).Trim()
 git clone $Remote $ValidationRepo
 git -C $ValidationRepo checkout --detach $Base
 git -C $ValidationRepo rev-parse HEAD
```

Overlay the extracted snapshot into this disposable baseline clone. It is safe to overwrite only because this is a new validation copy. Preserve its `.git` directory; the handover archive has none.

```powershell
$HandoverTree = $Stage
robocopy $HandoverTree $ValidationRepo /E /XD .git .dart_tool build .gradle .idea .vscode /XF HANDOVER-README.txt CHANGED-PATHS.txt INCLUDED-FILES.txt
if ($LASTEXITCODE -ge 8) { throw "Robocopy failed with exit code $LASTEXITCODE" }
 git -C $ValidationRepo status --short
 git -C $ValidationRepo diff --stat
 git -C $ValidationRepo diff --check
```

The baseline commit is a comparison point, not an approved release. The ZIP's `CHANGED-PATHS.txt` enumerates the handover's modified/untracked paths; `INCLUDED-FILES.txt` enumerates archive content. Check the working tree against that list before proceeding. Do not commit or push validation results.

## 3. Record toolchain and retrieve Flutter dependencies

Open PowerShell in the disposable validation clone:

```powershell
Set-Location $ValidationRepo
Set-Location mobile\app
flutter --version
flutter doctor -v
flutter pub get
```

Record the exact toolchain output and any dependency-resolution warnings. Do not increase Gradle heap aggressively; the owner machine previously experienced memory pressure with a large Gradle heap. Use its existing conservative settings and address memory problems as a separate environment issue.

## 4. Flutter source checks

```powershell
flutter analyze
flutter test
```

These cover Dart/static and available Flutter tests only. Passing them does **not** establish Android compilation, BLE behavior, interoperability, authentication, or security. Record test count, failures, and full console output.

Reference point: the 2026-11-09 owner run reported `flutter test` 67/67 passed. The suite in `mobile/app/test/` declares 67 `test(`/`testWidgets(` cases, so a divergent count means the tree is not the one that was validated.

## 5. Debug APK build

```powershell
flutter build apk --debug
```

Record the exit code and complete build output. This is a local debug artifact, not a release or security approval.

## 6. Inspect manifest and permissions

Inspect source declarations and the merged APK manifest:

```powershell
Get-Content android\app\src\main\AndroidManifest.xml
$Apk = 'build\app\outputs\flutter-apk\app-debug.apk'
$ApkAnalyzer = Join-Path $env:ANDROID_HOME 'cmdline-tools\latest\bin\apkanalyzer.bat'
if (Test-Path $ApkAnalyzer) { & $ApkAnalyzer manifest permissions $Apk }
```

If `apkanalyzer` is not installed at that path, use the Android SDK `aapt.exe` from the installed build-tools version:

```powershell
$Aapt = Get-ChildItem (Join-Path $env:ANDROID_HOME 'build-tools') -Filter aapt.exe -Recurse |
  Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
& $Aapt dump permissions $Apk
```

Expected source policy: API 23–30 scanning requests foreground `ACCESS_FINE_LOCATION`; API 27 does not have Android 12's runtime SCAN/CONNECT/ADVERTISE permissions. Legacy Bluetooth permissions are declared through API 30. API 31+ requests `BLUETOOTH_SCAN` for scanning, `BLUETOOTH_CONNECT` for connecting, and CONNECT+ADVERTISE for the server. Never infer API behavior solely from manifest inspection.

## 7. Identify the API 27 device, install and launch

Enable USB debugging and authorize the Windows computer on the phone. Record model/build and Android API:

```powershell
adb devices -l
adb -s <SERIAL> shell getprop ro.product.manufacturer
adb -s <SERIAL> shell getprop ro.product.model
adb -s <SERIAL> shell getprop ro.build.version.release
adb -s <SERIAL> shell getprop ro.build.version.sdk
```

Install and launch:

```powershell
adb -s <SERIAL> install -r $Apk
adb -s <SERIAL> shell am start -n com.example.duman_messenger/.MainActivity
```

Confirm the app opens and Diagnostics contains **G2-C BLE link (TEST ONLY)**. The UI must not show a trusted/authenticated success state.

## 8. API 27 runtime permission checks

On Android 8.1/API 27, verify in Android Settings → Apps → Duman Messenger → Permissions that Location is denied before the first scan. Start discovery in the G2-C screen and confirm Android asks for foreground Location. Deny once: discovery must not continue, and the UI should show denial/error. Retry and grant Location; the scan may proceed. Revoke Location in Settings while the app is backgrounded, return to the app, and verify status refresh reflects the missing permission and no scan/server/connection silently restarts.

The app does not use location for location features; the legacy permission is required by the Android BLE scan API on this OS. Do not expect API 31 permission prompts on API 27. Bluetooth radio disabled and BLE hardware unsupported should be reported distinctly where Android exposes the state; unknown radio status is not proof that the radio is enabled.

## 9. Discovery and candidate checks

With Bluetooth enabled and Location permission granted:

1. Tap **Start discovery**. Verify scanning status, then use the receiver's separate BLE GATT server in a later peer test to advertise the G2-C UUID.
2. Confirm only actual scan results appear as numbered temporary candidates; no fabricated peers, names, or addresses should be displayed.
3. Tap **Stop discovery** and verify scan ends and candidates are cleared/invalidated as appropriate.
4. Start again, let the 20-second scan timeout, and record the timed-out state.
5. Tap a candidate only while it is present. A stale/consumed token must not connect.

A candidate token and matching GATT UUID are not identity, trust, or authentication.

## 10. GATT client/server checks

This requires a second BLE-capable Android device to exercise a peer. Two-device acceptance remains a later, separately authorized gate; do not use production identities or messages.

- On the API 27 device, tap **Start server** and confirm server state. On API 27 this should not prompt for modern Bluetooth runtime permissions. Stop it and verify the state returns to stopped.
- For client testing, use the receiver device to run an explicitly started G2-C-compatible GATT server, then scan on the API 27 device, select the real candidate, and connect. Observe `connected_unauthenticated`, then `service_ready` only if service/CCCD setup completes.
- A service mismatch, unavailable radio, permission failure, connect failure, or deadline must be shown as an error/failed state, not success.
- Do not treat an encrypted/pairing BLE link as end-to-end security. Test frames are unauthenticated and not production messages.

## 11. Disconnect, cancellation and reconnection

- Stop discovery during scanning; verify it stops.
- Disconnect during connection setup and after service-ready; verify eventual disconnected state and no automatic reconnect.
- Stop the server while a client is connected; verify cleanup and client failure/disconnect reporting.
- Background the Activity and return; verify G2-C work is stopped and is not silently restarted.
- Navigate away/dispose the G2-C screen; verify GATT and event operations are cleaned up. Reopen and start an explicit new operation.
- Reconnect only by explicitly scanning/selecting a currently listed candidate. Record any stale state, duplicate callback symptom, delayed timeout, or resource leak.

These are owner diagnostics, not exhaustive lifecycle or security acceptance tests.

## 12. Logcat and evidence collection

Start a clean capture before a reproduction:

```powershell
adb -s <SERIAL> logcat -c
adb -s <SERIAL> logcat -v threadtime > "$env:USERPROFILE\Desktop\g2c-logcat.txt"
```

Reproduce, then press Ctrl+C. Also capture the device/build information, `flutter --version`, command outputs, app UI/error state, and a concise timestamped reproduction sequence. To inspect the saved log locally:

```powershell
Select-String -Path "$env:USERPROFILE\Desktop\g2c-logcat.txt" -Pattern 'G2c|Bluetooth|BluetoothGatt|AndroidRuntime|Flutter'
```

Review and redact device addresses, identifiers, account data, access tokens, and unrelated personal information before sharing logs. G2-C should not intentionally log peer addresses or secrets; report any such output as a defect.

## 13. Expected results and failure classification

- **Expected source-level behavior:** explicit test-only controls; real temporary candidates only; permission denial stops the operation; `connected_unauthenticated` and `service_ready` are distinct; timeout/errors remain visible; teardown requires a new user action.
- **Toolchain/build failure:** capture full output, Flutter/Dart versions, Java version, Gradle/AGP/Kotlin versions and available memory. Do not “fix” this by large Gradle heaps or broad dependency upgrades without review.
- **Permission/capability failure:** record Android version, grant state, Bluetooth state and exact UI/error code. Separate no BLE hardware, radio off, permission denial, and unsupported GATT peripheral role.
- **Transport failure:** record whether discovery found the receiver, its Android model/API, service readiness stage, operation sequence, timing and redacted logs. Do not infer protocol incompatibility or security failure from one radio failure.
- **Security/protocol gate:** no current result can establish authentication, trust, confidentiality, replay defense, API-27 key support, or production readiness. Protocol selection is still blocked pending owner and independent security approval.

## 14. Report results for troubleshooting

Send back:

1. Exact handover ZIP name/size and baseline SHA.
2. `git status --short`, diff stat, and diff-check result in the disposable clone.
3. Flutter/Java/Android SDK versions and available memory.
4. Analyze/test/build exit codes and relevant complete output.
5. Device manufacturer/model/build/API, BLE capability/radio state, and permission decisions.
6. Step-by-step reproduction with timestamps and observed G2-C states/error codes.
7. Redacted logcat and whether the issue reproduces after a fresh app launch.

Do not send secrets or unredacted device identifiers. Preserve the validation clone and logs until troubleshooting is complete. Do not commit or push. Passing Flutter/build checks does not establish BLE runtime or security correctness; independent security review and two-device acceptance remain separate gates. **G2-C remains NOT ACCEPTED.**
