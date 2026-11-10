# G2-D device evidence and acceptance audit

**Status: audit of the runtime evidence available at `2eabbc8`. Recommendation — CONDITIONAL PASS.**
The owner's Windows/device run passed; this environment holds neither their Gradle reports nor
the device, so every runtime result below is labelled with what it actually rests on.

- **Date:** 2026-11-09
- **Branch:** `arena/94329f0d-dumanmessenger`
- **Reviewed head:** `2eabbc87306fe82f1a8b410c53c7c296ae252000` (the fix the owner validated is
  `d154c3d`; `2eabbc8` adds test isolation and the capability report — see §5)
- **Implementation under review:** [G2-D-ANDROID-KEYSTORE-AND-STORAGE.md](G2-D-ANDROID-KEYSTORE-AND-STORAGE.md)
- **Owner-reported validation (their machine, SM-G610F):** `flutter pub get` pass,
  `flutter analyze` no issues, `flutter test` 294/294, `flutter build apk --debug` pass,
  `connectedDebugAndroidTest` 16 tests successful

## 0. What this audit could and could not inspect

| Input | Available to this audit? |
|---|---|
| Source at the reviewed commit | yes — read directly |
| Git history, branch, remote state | yes |
| Owner's `flutter analyze` / `flutter test` / APK / instrumentation results | **only as the owner reported them** |
| Gradle instrumentation XML (`androidTest-results/connected/debug/*.xml`) | **no** — build outputs are not in this workspace |
| Gradle HTML report (`reports/androidTests/connected/debug/index.html`) | **no** |
| The device, its Keystore, its measurements | **no** — no device and no Android toolchain here |

Consequently: no test outcome in this document is an observation made by this audit. Device
measurements are listed as **UNKNOWN** wherever no report exists, and §3 gives the exact command
that produces them.

## 1. Repository state

| | |
|---|---|
| Branch | `arena/94329f0d-dumanmessenger` |
| HEAD | `2eabbc87306fe82f1a8b410c53c7c296ae252000` |
| Remote tracking | `origin/arena/94329f0d-dumanmessenger` == HEAD, worktree clean |
| Fix commit after `341083c` | `d154c3d52fe4eed21612d596cd75e5e0c9e4af75` — "cast the Keystore key description to KeyInfo and clear two lints" |
| Commits since the owner's validation | `2eabbc8` (test isolation + capability report; no production behaviour change) |

**Does the owner's tested source correspond to the pushed commit?** Partially evidenced. The
sequence is consistent — the owner's run fixed exactly the three findings `d154c3d` addresses, and
`analyze`/`test`/APK all pass at a commit where those were the only open items — but this audit
cannot prove which SHA their working copy had. The check that settles it, on their machine:

```powershell
cd DumanMessenger
git rev-parse HEAD          # expect 2eabbc8 after pulling; d154c3d was what they validated
git status --porcelain      # expect empty
```

Their previous run predates `2eabbc8`, so the instrumentation suite must be re-run to include the
isolation fix and the capability report (§5).

## 2. Instrumentation evidence

**16 tests at the commit the owner ran; 17 at `2eabbc8`.** Names and security meaning below are
read from the source at that commit, not inferred from the count. Outcome column: **PASS
(owner-reported)** means the owner's run reported the class passing; it is not an observation made
here.

| # | Test | Security behaviour it validates | Outcome |
|---|---|---|---|
| 1 | `aesGcmRoundTripReturnsTheOriginalBytes` | AES-256-GCM with Keystore-chosen iv encrypts and decrypts to identical bytes under associated data | PASS (owner-reported) |
| 2 | `aDifferentKeyFailsAuthentication` | a ciphertext sealed under one Keystore key cannot be opened by another: GCM tag fails, `auth_failed` | PASS (owner-reported) |
| 3 | `corruptedCiphertextFailsAuthentication` | a single flipped ciphertext bit is rejected, not partially decrypted | PASS (owner-reported) |
| 4 | `associatedDataIsBoundToTheGeneration` | generation is bound into the AAD: a replayed generation does not authenticate | PASS (owner-reported) |
| 5 | `theStoredRecordIsNotPlaintext` | the persisted slot bytes do not contain the payload marker — encryption is real at rest | PASS (owner-reported) |
| 6 | `aStoredRecordSurvivesAReconstructedStorage` | a record written by one storage instance is readable by a fresh instance (process-restart shape) | PASS (owner-reported) |
| 7 | `noRecordMeansNullNotAnError` | absence is absence, not an error and not a fabricated record | PASS (owner-reported) |
| 8 | `aMissingWrappingKeyIsReportedAndNeverRecreated` | missing key with data present → `key_missing`, and **no replacement key is created** | PASS (owner-reported) |
| 9 | `anOlderGenerationIsRefusedAsStale` | a rolled-back slot is refused as `stale_record` instead of being accepted | PASS (owner-reported) |
| 10 | `anInterruptedWriteLeavesThePreviousRecordReadable` | a crash between temp-write and rename leaves the committed record readable; the stray file is ignored | PASS (owner-reported) |
| 11 | `deleteRemovesEverythingAndIsIdempotent` | explicit reset removes record, index and key; a second delete is a no-op | PASS (owner-reported) |
| 12 | `aRecordWrittenAfterAResetUsesAFreshKey` | a save over undecryptable data refuses (`key_missing`); only delete-then-save re-keys | PASS (owner-reported) |
| 13 | `theProbeReportsTheRealApiLevel` | reported API level is `Build.VERSION.SDK_INT`, provider is `AndroidKeyStore` | PASS (owner-reported) |
| 14 | `theProbeMeasuresARealRoundTrip` | the probe really generated a key, really round-tripped, is 256 bits, and leaves no key behind | PASS (owner-reported) |
| 15 | `hardwareBackingComesFromThePlatformAndNotFromTheApiLevel` | the hardware flag equals the platform's own `KeyInfo.isInsideSecureHardware` for a key created in the test | PASS (owner-reported) |
| 16 | `strongBoxIsReportedOnlyWhenThePlatformSupportsIt` | below API 28 StrongBox is not attempted; at/above it is attempted and only a created key counts | PASS (owner-reported) |

Test 16 on this device exercised the **API 27 branch**: `strongBoxRequested == false`, which is the
correct result for Android 8.1 and is not a capability failure.

### What to look at in the reports

```text
mobile\app\build\outputs\androidTest-results\connected\debug\          XML, one file per device
mobile\app\build\reports\androidTests\connected\debug\index.html       HTML summary
```

In the XML: `tests="17"`, `failures="0"`, `errors="0"`, `skipped="0"`, and one `<testcase>` per
name above plus `reportMeasuredCapabilitiesForTheAcceptanceRecord`; `<system-out>` should contain
the `G2D-CAPABILITY` block. A run that reports 16 tests is the pre-`2eabbc8` suite.

## 3. Physical-device capability evidence

**Not obtained. Every value below is UNKNOWN to this audit** — there is no device here, and the app
itself has no UI or Dart caller for the probe (`G2dAndroidIdentityRuntime` is never instantiated by
the shipping UI), so before `2eabbc8` there was no way to read these numbers at all.

| Measurement | Value | Source |
|---|---|---|
| API level | UNKNOWN (device is reported as Android 8.1; the probe asserts equality with `Build.VERSION.SDK_INT`, not with a literal) | not measured here |
| AES-GCM availability | UNKNOWN | not measured here |
| Probe key generation | UNKNOWN | not measured here |
| Encrypt/decrypt round trip | UNKNOWN | not measured here |
| Probe key hardware-backed | UNKNOWN | not measured here |
| Wrapping key present | UNKNOWN | not measured here |
| Wrapping key hardware-backed | UNKNOWN | not measured here |
| StrongBox requested / created | UNKNOWN (expected `false/false` at API 27; "expected" is not evidence) | not measured here |
| Key size / block modes / paddings | UNKNOWN | not measured here |

**Smallest test-only mechanism, now implemented:** `reportMeasuredCapabilitiesForTheAcceptanceRecord`
in `G2dIdentityKeystoreInstrumentedTest`, one extra instrumented test that prints a
`G2D-CAPABILITY key=value` block and asserts only what was measured. It exposes no secret — API
level, booleans, key size, mode names, notes — and never prints a key, iv, ciphertext or plaintext.
No production UI, route or startup path was touched, and no Dart-side surface was added.

```powershell
cd mobile\app\android
.\gradlew connectedDebugAndroidTest --tests "*G2dIdentityKeystoreInstrumentedTest.reportMeasuredCapabilitiesForTheAcceptanceRecord"
# or read the G2D-CAPABILITY block from the full run:
#   mobile\app\build\outputs\androidTest-results\connected\debug\*.xml  ->  <system-out>
adb logcat -s System.out | Select-String "G2D-CAPABILITY"
```

Until that output is pasted into a report, the answer to "is the SM-G610F's wrapping key inside the
TEE?" is *unknown*, and no document in this repository may say otherwise.

## 4. Persistence and recovery evidence

Evidence class per behaviour. "Device" = exercised on the SM-G610F by the instrumented suite;
"Dart" = exercised by the 294 Dart cases against a platform double; "Inspection" = read from the
code, not executed anywhere.

| Behaviour | Device | Dart | Inspection |
|---|---|---|---|
| Save then load returns the same payload | PASS (owner-reported, test 6) | yes | yes |
| Process termination and restart | PASS (owner-reported, test 6 — new instance, no shared state) | yes (`service reconstruction`) | yes |
| Correct generation selection (highest authenticating) | PASS (owner-reported, tests 9, 10) | partial | yes |
| Interrupted write recovery | PASS (owner-reported, test 10) | yes (simulated) | yes |
| Corrupted ciphertext handling | PASS (owner-reported, tests 3, 4) | yes (`store corrupt`, reset path) | yes |
| Missing Keystore key handling | PASS (owner-reported, test 8) | yes (`key_missing` → corrupt → reset) | yes |
| Invalidated key handling | **not exercised end to end** — the `KeyPermanentlyInvalidatedException` branch is only reachable by an OS invalidation, which no test forces | yes (mapped code) | yes |
| No automatic replacement of a missing key | PASS (owner-reported, test 8) | yes | yes |
| Explicit deletion | PASS (owner-reported, tests 11, 12) | yes | yes |
| Rollback detection | PASS (owner-reported, test 9) | no | yes |
| Real power loss / `fsync` | not testable in-process | no | reasoning only |

Two honest gaps: **key invalidation** is the one recovery path with no executed test (it needs an
OS-driven invalidation, e.g. a lock-screen change on an auth-bound key, and this key is not
auth-bound — so it is also unlikely to occur in practice), and **power-loss durability** cannot be
proven by any test; the `fsync` + `rename` protocol is an argument, not a measurement.

The instrumented suite runs against `identity_test/` and `g2d.identity.wrap.test[2].v1` as of
`2eabbc8`, so re-running it cannot touch a real identity or the production alias.

## 5. Changes made by this audit

| Commit | Change | Why |
|---|---|---|
| `2eabbc8` | `G2dIdentityStorage(directoryName, wrappingKeyAlias)` with production defaults; instrumentation moved to test-only directory and aliases | the suite's `@Before` deleted `files/identity/` and `g2d.identity.wrap.v1`. Harmless today (no identity exists), a defect the day one does |
| `2eabbc8` | probe also reports `probeKeyBlockModes` and `probeKeyEncryptionPaddings` from `KeyInfo` | §3 asks for the measured parameters; the probe already read them and threw them away |
| `2eabbc8` | new test `reportMeasuredCapabilitiesForTheAcceptanceRecord` | the missing retrieval path for §3 |
| this document | audit record | — |

No production behaviour changed: the defaults are the previous constants, and the extra probe keys
are ignored by `G2dAndroidCapabilityEvidence.fromMap`.

## 6. Security assessment

### Proven (given the owner's run)

- AES-256-GCM in the Android Keystore encrypts and authenticates the stored record; a wrong key or
  a modified ciphertext is rejected, not tolerated.
- The persisted files do not contain the plaintext payload.
- A record survives a storage instance being rebuilt, which is the shape of a process restart.
- A missing wrapping key produces `key_missing` and **no replacement is generated**.
- A rolled-back slot is refused; an interrupted write leaves the previous record intact.
- Explicit deletion removes data, index and key, and is idempotent.
- The capability probe measures rather than infers, and leaves no key behind.

### Proven at the Dart level (not on the device)

Lifecycle invariants, the error-code → recovery mapping (including "unknown code is never corrupt"),
runtime refusal when the wrap did not verify, and record validation on both save and load. These
exercise the adapter's decisions with a fake platform; they say nothing about Android.

### Unverified

- Whether the SM-G610F's wrapping key is TEE-backed (the only input to any hardware claim).
- StrongBox on this device (expected absent at API 27; not measured).
- Real durability across power loss.
- The `KeyPermanentlyInvalidatedException` path end to end.
- Behaviour after an OS upgrade, a Keystore reset, or an OEM backup agent that ignores the
  exclusion rules.
- Anything on a second device or a modern Android version.

### API 27 limits that remain true regardless of the measurement

Ed25519 is not a Keystore algorithm before API 33, and X25519 never is; the identity key on this
device will be software material wrapped at rest. StrongBox requires API 28 and is not attempted.
The upgrade path that would make the identity key hardware-resident does not exist here.

### Backup, rollback and root

- **Backup:** the identity directory is excluded from cloud backup and device transfer; Keystore
  keys are never backed up. A restore therefore yields absence, not a broken record — and an OEM
  agent that ignores the rules yields `key_missing`, which is corruption and requires an explicit
  reset. Neither path recreates an identity.
- **Sandbox rollback:** the generation index lives in app-private storage. An attacker who can write
  there can delete it and defeat rollback detection. There is no monotonic counter outside the
  sandbox, and this document does not claim otherwise.
- **Root:** on a rooted device with the app running and unlocked, the wrapping key is usable by the
  app and therefore by anything that can act as the app. When a software-held identity key exists it
  will be in process memory while in use. The at-rest envelope does not protect against that.

### Is the storage protection claim justified?

Yes, in these words and no stronger: *the identity record is encrypted and authenticated at rest
under a non-exportable Android Keystore AES-256-GCM key; a missing or invalidated key makes the
data unrecoverable, and the only recovery is an explicit reset that discards it.* That claim is
supported by tests 1–12. It is **not** a hardware-backed claim (unmeasured), **not** a claim about
a hardware-resident identity key (impossible on API 27), and **not** end-to-end encryption: no
session, no message protection, no provider.

## 7. Acceptance recommendation

**CONDITIONAL PASS.**

What justifies the pass: the platform-dependent behaviours that the whole design rests on — real
AES-GCM, real tag failure, real key deletion, real crash-shape recovery, no silent re-keying — were
exercised on the target device and reported green by the owner, and the Dart-level suite (294)
covers the decisions above them.

Conditions, in order of weight:

1. **Attach the instrumentation XML** (or the HTML report) from the `2eabbc8` run so the 17 outcomes
   are confirmed rather than reported, and so the `G2D-CAPABILITY` block is on the record.
2. **Record the device measurements.** Until `probeKeyHardwareBacked` and
   `wrappingKeyHardwareBacked` are read off the device, no document may describe the wrapping key
   as hardware-backed and no UI may imply it.
3. **Independent design and code review** (gates D0–D7) remains open and is not satisfied by this
   audit; it is a self-review.
4. **A second device or a modern Android version** is still untested; the adapter is written to be
   indifferent to the API level above 28, but that is reasoning, not evidence.

What would make this **FAIL**: any instrumentation failure at `2eabbc8`; a device on which the probe
round trip does not verify (the runtime then refuses to assemble, which is correct but means no
identity can be stored); or evidence that the encrypted slots ever contain plaintext.

What would make it an unconditional **PASS**: conditions 1 and 2 satisfied, plus independent review
of the envelope and error matrix — with the hardware-backed question answered *by measurement*,
whichever way it falls.

## 8. Not claimed

Not device-verified by this audit. Not hardware-backed. Not E2EE. Not a security certification. No
gate D0–D7 is passed by this document.
