# G2-C Android BLE link — validation record and acceptance checklist

**Status (2026-11-09): owner-validated at transport scope. G2-C is accepted for TEST-ONLY BLE transport use on the owner's own devices, on the basis of owner-reported evidence. It is NOT security-accepted, NOT production-ready, and NOT authorized for real messaging.**

This record separates four kinds of evidence that must never be merged: owner-run automated Flutter checks, an Android debug build, owner-reported physical two-device BLE behaviour, and independent security review. Only the first three exist. The fourth does not, and nothing here substitutes for it.

- **Branch:** `arena/94329f0d-dumanmessenger`
- **HEAD when this record was written:** `93dc6cef811a8deac3944d8d58f4747034a75b29`
- **G2-C commit range:** `17f5fe2..93dc6ce` (13 commits, listed in §9)
- **Scope document:** [ADR-G2-C-ANDROID-SECURE-BLE-LINK.md](ADR-G2-C-ANDROID-SECURE-BLE-LINK.md)
- **Reproduction guide:** [G2-C-WINDOWS-VALIDATION.md](G2-C-WINDOWS-VALIDATION.md)
- **Forward plan:** [G2-D-SECURITY-ARCHITECTURE-PLAN.md](G2-D-SECURITY-ARCHITECTURE-PLAN.md)

## 1. What G2-C is, and what it is not

G2-C is a foreground-only, Android-only, TEST-ONLY BLE transport: explicit discovery of one service UUID, an explicit GATT client or GATT server role, bounded fragmentation and a validated frame header, a typed Flutter status/diagnostics surface, and an optional unauthenticated test payload.

It is not an identity system, an authenticated session, an encrypted channel, a trust store, or a messaging path. A GATT connection, a discovered service, a written CCCD descriptor, or an OS-level BLE link encryption all describe radio transport state only.

## 2. Evidence classes

| Class | What was recorded | Who produced it | What it establishes | What it does not establish |
|---|---|---|---|---|
| **A. Automated Flutter validation** | `flutter analyze` passed; `flutter test` **67/67 passed** | Owner, on Windows local PC, reported 2026-11-09 | The Dart source type-checks, lints clean, and the declared widget/unit tests pass in the owner's Flutter 3.47.8 / Dart 3.13.7 environment | Nothing about Kotlin correctness or runtime behaviour; no Android/BLE path is executed by these tests; the tests use fakes, not devices |
| **B. Android APK build** | `flutter build apk --debug` built successfully | Owner, on the same machine | The Kotlin, manifest, Gradle and Dart sources compile and package into an installable debug APK | Nothing about runtime behaviour, permissions at runtime, radio interoperability, or release signing; a debug APK is not a release artifact |
| **C. Physical BLE** | Owner reports the current BLE workflow **works on both physical phones** | Owner, two physical Android devices, reported 2026-11-09 | At least one real client↔server G2-C interaction functioned between two handsets at the transport level | Not reproduced or independently observed. Device models, API levels, roles exercised, which states were reached, whether test frames crossed, timings, and logcat were not supplied (§4) |
| **D. Independent security review** | **Not performed** | — | Nothing | Everything security-related. No external cryptographer, protocol auditor, or mobile platform security reviewer has examined G2-C or any proposal in this repository |

Rules that follow from this table:

- Class A and B are toolchain evidence. They cannot be upgraded into device or security evidence by repetition.
- Class C is owner-reported. It is recorded as such and is not restated as an agent observation, a measurement, or a test result.
- No claim in this repository may say G2-C "passed security review", "is secure", "is encrypted", or "is production-ready". It has not, it is not, and it is not.

## 3. Recorded results

Owner-reported, 2026-11-09:

```text
flutter analyze                  -> passed
flutter test                     -> 67 / 67 passed
flutter build apk --debug        -> succeeded
physical two-device BLE workflow -> works on both phones
```

Static cross-check available in this repository (agent side, **not** a test run): the 13 files in `mobile/app/test/` declare exactly **67** `test(` / `testWidgets(` cases, which is consistent with the reported total. This only confirms the arithmetic of the declared suite; it is not evidence that any test executed.

### Provenance limits of the recorded results

- The owner did not attach the commit SHA, console output, `flutter --version`, or APK hash to the report, so these results are recorded at **branch level** (`arena/94329f0d-dumanmessenger`, G2-C range `17f5fe2..93dc6ce`), not pinned to a single tree state. If stricter provenance is needed later, re-run on the exact SHA and record it.
- The two-device result specifies neither handset, OS version, nor which operations were exercised.

## 4. Evidence the owner can still supply cheaply

None of these block the transport-scope acceptance recorded above; each one strengthens it.

- [ ] The exact SHA validated, plus `flutter --version` and `flutter doctor -v` output.
- [ ] `flutter analyze` and `flutter test` console output (the `67/67` line and any warnings).
- [ ] Debug APK path and `sha256` of `build/app/outputs/flutter-apk/app-debug.apk`.
- [ ] Both devices: manufacturer, model, Android release and API level.
- [ ] Which role each phone took (GATT client / GATT server), and whether the pair reached `connected_unauthenticated`, then `service_ready`.
- [ ] Whether an unauthenticated test frame was sent and received in each direction, and whether the reception banner appeared.
- [ ] Permission prompts observed (API 31+ scan/connect/advertise, or foreground location on API 23–30) and the denial paths exercised.
- [ ] Redacted logcat for one full connect → service ready → test frame → disconnect cycle.
- [ ] Whether the workflow was repeated after a cold app restart, and after backgrounding and returning.

## 5. Acceptance gate ledger

Transport-scope gates (these are what the owner's validation now covers):

| Gate | Requirement | Status | Basis |
|---|---|---|---|
| **T1 — source scope** | Foreground-only, TEST-ONLY channels, no production messaging, no trust/authentication state exposed | **Met** | Source review + `flutter analyze` (class A) |
| **T2 — toolchain** | `flutter analyze` clean, `flutter test` green, debug APK builds | **Met** | Classes A + B (owner-run) |
| **T3 — runtime permissions** | Operation-scoped requests; denial never continues an operation; permanent denial routes to settings | **Met, owner-reported** | Class C, without a recorded per-API matrix |
| **T4 — two-device BLE** | Client and server roles interoperate on real handsets; `service_ready` only after real service/CCCD completion | **Met, owner-reported** | Class C, without device models or role breakdown |
| **T5 — lifecycle** | Pause, disposal, disconnect and stop-server tear down radio work; no silent restart | **Met, owner-reported** | Class C, partially exercised |
| **T6 — diagnostics** | Bounded, privacy-safe diagnostics (no addresses, names, keys or payload bytes) surfaced in the UI | **Met** | Source review; the Dart parser rejects out-of-contract values |

Security-scope gates (these are the ones the owner's validation does **not** cover):

| Gate | Requirement | Status |
|---|---|---|
| **S1 — identity** | Persistent device identity with canonical, algorithm-tagged encoding and a fingerprint that is an identifier, not proof | **Not started** |
| **S2 — authenticated key exchange** | Reviewed protocol establishing a session bound to the exact peer static key and transcript; no silent fallback | **Not started; protocol selection blocked** |
| **S3 — trust lifecycle** | Explicit out-of-band first contact, pinned peer records, revocation and rotation, no TOFU | **Design only** (ADR + [IDENTITY-AND-KEYS.md](IDENTITY-AND-KEYS.md)) |
| **S4 — end-to-end encryption** | Confidentiality and integrity of message content across relays, not just the radio link | **Not started** |
| **S5 — independent security review** | External review of protocol, provider, key lifecycle, storage and the G2-C to G2-D boundary | **Not started — the blocking gate** |

**Overall:** T1–T6 recorded as owner-validated (TEST-ONLY transport). S1–S5 open. G2-D may not produce a security claim until S5 is satisfied.

## 6. Known limitations (accepted for TEST-ONLY use)

1. **No authenticated peer handshake.** Nothing proves that the device on the other end of a GATT link possesses any particular key. A service UUID, a candidate token, a Bluetooth address and a successful CCCD write are routing facts, not authentication.
2. **No persistent peer identity or trust lifecycle.** The only key pin in the app is a process-local abstraction disconnected from the transport. Nothing survives a restart; nothing can be revoked, rotated, or audited.
3. **No end-to-end encryption.** Test payloads travel as plaintext bytes inside the frame. Any party that can observe or relay GATT traffic can read them, and any party that can write the characteristic can replace them.
4. **BLE transport success does not establish message authenticity or confidentiality.** `service_ready` means "expected GATT schema present and notifications configured". Even if the OS negotiates an encrypted BLE link, that is link encryption between two radios — it does not bind a Duman peer identity and does not survive a relay.
5. **No replay or downgrade protection.** There is no counter, nonce, session identifier, or version negotiation establishing that a frame is fresh or that both ends chose the same protocol generation.
6. **Unauthenticated fragmentation.** Reassembly is bounded (one in-flight message, ordered fragments, 2,048-byte cap, 15-second deadline) but a well-formed attacker-supplied message is indistinguishable from a peer's.
7. **Single-peer server, foreground only.** One peer at a time, and all radio work stops on pause/disposal. There is no background reachability.
8. **Android only, one API level observed.** The owner's physical evidence involves two handsets whose API levels were not recorded. API 27-specific provider and callback behaviour remains unverified in writing.
9. **Privacy of radio metadata is unresolved.** Advertisements carry the service UUID; scan results reveal nearby G2-C devices to anyone listening. There is no anonymity claim.
10. **No release engineering.** The build evidence is a debug APK. Signing, versioning, target API compliance, SBOM and store requirements are untouched.

## 7. What this acceptance does and does not authorize

Authorized:

- Continued TEST-ONLY development on this foundation, on the owner's devices.
- Using G2-C as the transport substrate that a future authenticated session would run over.
- Treating the transport diagnostics as a debugging surface.

Not authorized:

- Sending real user messages, contacts, or files over G2-C.
- Any statement that G2-C traffic is confidential, authenticated, tamper-proof, or secure.
- Exposing an `authenticated` or `trusted` state in the UI. The Dart parser actively rejects a native `authenticated=true` claim for this reason.
- Merging G2-C into a production messaging path, or shipping a release build.

## 8. Residual risk statement

For a TEST-ONLY transport between two devices the owner controls, the residual risk is accepted: the worst realistic outcome is that a nearby attacker reads, injects, or blocks unauthenticated test payloads, or that a radio/lifecycle defect surfaces as a stuck state. Nothing of value is protected by G2-C today, which is precisely why it must stay test-only until S1–S5 close.

## 9. G2-C commits in this branch

| Commit | Subject | Scope |
|---|---|---|
| `17f5fe2` | feat(android): add experimental G2-C BLE link foundation | Kotlin `G2cProtocol/Fragmentation/BleDiscovery/GattLink/GattServer/BleManager`, `MainActivity` wiring, Dart bridge/status/screen, routes, ADR, validation guide (14 files, +2,611) |
| `34df4bb` | build(android): make G2-C validation memory-safe | `android/gradle.properties` only (conservative heap) |
| `4f13d42` | fix(android): correct G2-C GATT state callback binding | Manager callback binding, bridge cleanup |
| `ff11c3d` | fix(android): resolve G2-C BLE screen layout | Screen layout overflow, screen test |
| `53d2ea5` | feat(android): add G2-C test-frame reception diagnostics | Native reception outcomes, diagnostics |
| `9aefced` | feat(android): surface G2-C test-frame reception and role capability | Dart status/screen/tests |
| `1385e7a` | test(android): assert the distinct G2-C reception banner | Screen test |
| `e4bf0bc` | fix(android): clear stale G2-C queue error on a new send | Manager |
| `e572915` | fix(android): revalidate G2-C link and server connection state | Link/server revalidation, stale peer clearing, advertising restart, session counters |
| `7095ddf` | feat(android): show G2-C connection diagnostics and role state | Bounded diagnostics ring, Dart parsing, UI, tests |
| `7733a37` | test(android): assert the failed G2-C discovery diagnostic | Screen test |
| `d6d01b2` | feat(android): add explicit G2-C status revalidation control | Screen control, screen test |
| `93dc6ce` | test(android): supply discovery state in G2-C status fixtures and make the refresh tap hit-testable | Test fixtures + interaction |

Diff for the whole mobile subtree across `83606d5..93dc6ce`: 17 files, +3,958 / −3.

Changed paths (G2-C scope):

```text
mobile/app/android/app/src/main/AndroidManifest.xml
mobile/app/android/app/src/main/kotlin/com/example/duman_messenger/MainActivity.kt
mobile/app/android/app/src/main/kotlin/com/example/duman_messenger/G2cProtocol.kt
mobile/app/android/app/src/main/kotlin/com/example/duman_messenger/G2cFragmentation.kt
mobile/app/android/app/src/main/kotlin/com/example/duman_messenger/G2cBleDiscovery.kt
mobile/app/android/app/src/main/kotlin/com/example/duman_messenger/G2cGattLink.kt
mobile/app/android/app/src/main/kotlin/com/example/duman_messenger/G2cGattServer.kt
mobile/app/android/app/src/main/kotlin/com/example/duman_messenger/G2cBleManager.kt
mobile/app/android/gradle.properties
mobile/app/lib/app.dart
mobile/app/lib/app_routes.dart
mobile/app/lib/ble/g2c_ble_bridge.dart
mobile/app/lib/ble/g2c_ble_status.dart
mobile/app/lib/screens/g2c_ble_screen.dart
mobile/app/lib/screens/diagnostics_screen.dart
mobile/app/test/g2c_ble_screen_test.dart
mobile/app/test/g2c_ble_status_test.dart
docs/mobile/ADR-G2-C-ANDROID-SECURE-BLE-LINK.md
docs/mobile/G2-C-WINDOWS-VALIDATION.md
docs/mobile/G2-C-ACCEPTANCE-CHECKLIST.md
```

## 10. Next step

G2-D. The security work is designed, gated and unstarted: see [G2-D-SECURITY-ARCHITECTURE-PLAN.md](G2-D-SECURITY-ARCHITECTURE-PLAN.md). Nothing in this acceptance record advances it, and no protocol, key, or trust code may be added until the gates in that plan are met.
