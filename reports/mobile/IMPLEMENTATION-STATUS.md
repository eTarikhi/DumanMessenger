# Implementation status — simulator, security, and Flutter workstreams

**Current update:** 2026-11-09 (G2-D security hardening and trust remediation)
**Previous updates:** 2026-11-09 (G2-D architecture + identity/trust foundation), 2026-11-09 (G2-C validation), 2026-11-09 (G2-D security plan)
**Superseded sections below:** 2026-11-08 (G1 shared source) and 2026-11-05 (no-source baseline). Where an older section says that no Flutter app, Android host, or device evidence exists, the 2026-11-09 update governs.
**Branch:** `arena/94329f0d-dumanmessenger` (active)
**Historical G0 snapshot tested/reviewed:** `a1f1916981c2244a2f8664573b66afbd5a2659b4` (empty checkpoint over `bdf719cf88205f944187cb79b8288264a56c13bd`)

## Current update (2026-11-09, latest) — G2-D security hardening and trust remediation

Scope: remediate the read-only audit's findings F1–F17 and keep the seven owner-observed
trust failures fixed. **No dependency, Gradle, Android, G2-C or UI change. No gate passed.**

- **Trust regression root cause (already fixed in `590f67a`).** `authenticateIdentity`
  validated and compared the observed fingerprint but never bound it, so the pin stayed null:
  every later observation looked like first contact, a change could never be detected, and
  verification facts never counted. The fix stands; this milestone re-expresses the
  changed-identity semantics under the approved design instead of weakening them.
- **F4 (approved).** The record now separates the **pin** (`identityFingerprint`), the
  **observation** (`observedIdentityFingerprint`) and **history**
  (`previousIdentityFingerprint`). An observation never moves the pin; only a completed
  ceremony promotes it, records the displaced pin as history and clears the change marker.
- **F1.** `resetCorruptIdentity()` deletes only a positively-corrupt record, refuses a
  readable one, never treats unavailable storage as corruption, and recreates nothing.
- **F2.** `_commit` round-trips the record through the wire format before `store.save`, so
  clock rollback, contradictory lifecycle or unverified protection returns `invalidRecord`
  and writes nothing. Pending rotations are held to the active protection requirement.
- **F3.** `G2dPlatformKeyCapabilities` is injected; creation, rotation and every load are
  checked against the platform. A hardware-bound Ed25519 claim below API 33, or any
  hardware-bound Curve25519/X25519 claim, is refused; a platform limit is worded differently
  from missing probe evidence.
- **F5.** Construction over a store that reports `isSecureAtRest == false` throws unless the
  caller passes `allowInsecureStore: true`. Storage abstraction is not secure persistence and
  no UI may imply otherwise.
- **F6–F8.** Peer revocation is terminal and idempotent (original time, reason and evidence
  preserved); verified labels derive from `isUserVerified`; `G2dPeerTrustRecord.fromMap` is a
  strict decoder that rejects contradictory records.
- **F9–F17.** Adapter exceptions become typed storage failures; `hasVerifiedProtection`
  requires the probe flag; resets return a record-less success; mutations are serialized;
  retired identity ids cannot be reused; a rotated generation must name its predecessor;
  aliases/providers are validated and may not carry the fingerprint.
- **Tests declared:** 224 total (157 identity, 67 pre-existing) versus 167 before this
  milestone. **None executed here** — no Dart/Flutter toolchain. The owner's baseline remains
  the only executed evidence (`flutter analyze` clean, `flutter build apk --debug` clean,
  `160 passed / 7 failed`), and the post-remediation numbers are **not** claimed.

State file: [G2-D-EXECUTION-STATE.json](G2-D-EXECUTION-STATE.json).

## Current update (2026-11-09, later) — G2-D architecture recommendation and identity foundation

Scope: recommendation plus a protocol-agnostic foundation. **No dependency was added, no
key material is generated, no session exists, and no security gate is met.**

- **Architecture:** [G2-D-ARCHITECTURE-DECISION.md](../../docs/mobile/G2-D-ARCHITECTURE-DECISION.md) recommends **Option A — `org.signal:libsignal-android`** (AGPL-3.0, accepted by the owner), with the decision recorded as *recommended, not approved, not integrated*. Evidence inspected from upstream: `minSdkVersion 23`, Java 21 + core-library desugaring required, ABIs `arm64-v8a`/`armeabi-v7a`/`x86_64`/`x86`, Maven Central lagging repository tags (0.86.5 vs `v0.106.2`), and an explicit upstream statement that use outside Signal is unsupported. Option B (Noise) is not selectable: no maintained JVM implementation publishes an artifact, and Noise stops at the handshake. Option C offers nothing better for a 1:1 serverless messenger.
- **Blocking gates before integration:** D2-a (build with Java 21 + desugaring on Windows), D2-b (JNI + key probe on the SM-G610F API 27 device and one API 31+ device), D2-c (pin version + SHA-256, enumerate transitives), D1 (X3DH vs PQXDH profile).
- **Identity foundation implemented** in `mobile/app/lib/identity/`: strict identity record codec, create/rotate/revoke/reset lifecycle, storage contract with a fail-closed default store, probe-gated key protection, and the seven-axis peer trust model with fail-closed identity-change handling. 100 new Dart test cases across five files (declared suite total 167).
- **Deliberately not implemented:** the Android Keystore adapter (designed in [G2-D-IDENTITY-KEY-MANAGEMENT.md](../../docs/mobile/G2-D-IDENTITY-KEY-MANAGEMENT.md) §7), key generation, libsignal integration, peer persistence, and any UI — a trust screen without a handshake would be a misleading placeholder.
- **License:** [G2-D-LICENSE-AND-DEPENDENCY-REVIEW.md](../../docs/mobile/G2-D-LICENSE-AND-DEPENDENCY-REVIEW.md) records that linking the AAR makes the application AGPL-3.0, requires source availability per distribution, and leaves the App Store question and AGPL §6 applicability to legal review.
- **Validation:** none executed here — no Dart/Flutter/JDK/Kotlin toolchain in the agent environment. Only tree-sitter parsing, link/JSON checks and `git diff --check` were run. Owner validation is required.
- **G2-C:** untouched. No G2-C file, test, assertion or timeout was modified; its 67 declared tests remain.

State file: [G2-D-EXECUTION-STATE.json](G2-D-EXECUTION-STATE.json).

## Current update (2026-11-09) — G2-C validated at transport scope, G2-D planned

Three workstreams are now complete in source: G1 (shared shell), G2-A/G2-B (diagnostics and discovery), and G2-C (`17f5fe2..93dc6ce`, 13 commits, TEST-ONLY BLE link with both GATT roles, bounded fragmentation, connection-state revalidation and privacy-safe diagnostics).

**Owner-reported validation of G2-C (2026-11-09):** `flutter analyze` passed; `flutter test` 67/67 passed; `flutter build apk --debug` succeeded; the BLE workflow works on two physical phones. These are owner-run results recorded in the [G2-C acceptance record](../../docs/mobile/G2-C-ACCEPTANCE-CHECKLIST.md), not agent observations. The owner did not attach the exact SHA, console output, device models/API levels, or role breakdown; those gaps are listed in that record.

| Evidence | Status | Establishes |
|---|---|---|
| Flutter analyze / 67-67 test run (owner) | **Recorded** | Dart source and declared widget/unit tests are green in the owner's environment |
| Debug APK build (owner) | **Recorded** | Kotlin/manifest/Gradle/Dart compile and package |
| Two-device physical BLE (owner-reported) | **Recorded** | Transport-level client/server workflow functions between two handsets |
| Independent security review | **Not performed** | — |

**Status of G2-C:** accepted for TEST-ONLY transport use on the strength of the above. It is **not** security-accepted and **not** production-ready. No authenticated handshake, persistent identity/trust, end-to-end encryption, replay protection, or independent review exists. See the acceptance record's gate ledger (T1–T6 met at transport scope, S1–S5 open).

**G2-D (new, design only):** [G2-D-SECURITY-ARCHITECTURE-PLAN.md](../../docs/mobile/G2-D-SECURITY-ARCHITECTURE-PLAN.md) sets out the security milestone — identity/key lifecycle, authenticated key exchange, peer trust and revocation, replay/downgrade protection, message encryption, forward secrecy and recovery, security test requirements, library research (Noise r34, X3DH, Double Ratchet, PQXDH, MLS RFC 9420, Tink 1.24.0, libsignal AGPL-3.0, Android Keystore constraints) and ten review gates. **Protocol and library selection remain BLOCKED**; nothing was implemented; no dependency was added.

**Unchanged:** no GitHub Actions, remote CI, release, or publication was run. The agent environment still cannot compile or run Flutter/Kotlin/Android.

## Previous G1 update (2026-11-08)

- Added Flutter shared source and widget tests in `mobile/app`: onboarding, true empty conversations, local platform/build-mode diagnostics, named navigation, and an in-memory system/light/dark theme selector. No runtime plugin, network client, contacts, messages, cryptography, keys, persistence, runtime permission flow, or mesh transport was added.
- The app uses the Flutter 3.47.8 template conventions and owner-reported bundled Dart 3.13.7. This version/environment is reported by the owner, not independently run on this agent.
- `android/`, `ios/`, and `pubspec.lock` are not generated/checked in yet. The Windows quickstart gives the safe `flutter create --empty --platforms android .` command (no `--overwrite`) plus exact analyze/test/debug-APK steps; iOS host generation/build must be done on macOS/Xcode.
- No Flutter analyze/test/build, Android emulator, physical Android, iOS Simulator, or physical iOS validation has run. The owner's standalone Flutter debug APK smoke test is not a DumanMessenger build.
- Shared source/test implementation is ready for owner-side generation and validation; G1 acceptance is **not passed** until generated project files, test/build checks, and separately documented Android/iOS acceptance gates are complete. No workflow was enabled or changed.

## Historical executive status (2026-11-05)

- **G0 baseline:** **NOT PASSED.** Full TypeScript suite is 517/527 with ten failures at the unchanged 5,000 ms timeout. Dart tests did not run on this host.
- **Milestone 2:** the documentation-only baseline and security design proposal remain complete. No production code changed.
- **Milestone 3 Tracks A–E:** the review results, draft implementation specification, ten-case timeout diagnosis, toolchain setup guide, and G1 foundation plan are documented below. These are documentation/review deliverables only.
- **Security status:** the security findings are recorded, but the review is not independent. No external cryptographer, protocol auditor, or platform security reviewer has examined the design. Candidate DMP 0.1 / wire version 2 is **not approved and not implemented**. **Owner/security approval is required before protocol, packet, or production crypto changes.**
- **Timeout status:** all ten failures were measured individually in focused default-worker and single-worker runs. All remained over budget. Synchronous simulation work explains the timeout trigger; representative source-equivalent profiles show repeated OGM/TQ-history, RF geometry, MPR/pruning, and GC work. This does not establish one identical hot function for every failure. No safe equivalent optimization was found; source/tests/configuration remain unchanged.
- **Mobile status:** no Flutter app or platform projects exist; no mobile toolchain or device is available on this Linux host. No Android/iOS build, launch, emulator, Simulator, or physical-device test was run.
- **G1:** **NOT ACHIEVED.** The minimum buildable-shell plan is ready, but it is not a scaffold or build result.
- **Release:** Android target is Google Play. iOS implementation/testing remain required. **App Store distribution is not authorized.** No GitHub Actions, push, merge, deployment, or publication was performed.

## Historical gate and workstream ledger (2026-11-05)

| Gate / stream | Status | Evidence / limitation |
|---|---|---|
| G0 — source and architecture inventory | **Recorded** | [BASELINE.md](BASELINE.md) and [ARCHITECTURE.md](../../docs/mobile/ARCHITECTURE.md). Browser simulator, authoritative pure-Dart simulator, and Node protocol reference exist; no Flutter app. |
| G0 — full local TypeScript baseline | **Partial / not passed** | Last complete suite: 517/527 pass, ten strict 5,000 ms timeouts, duration 315.66 s. The complete suite was not rerun in this milestone. See [TEST-RESULTS.md](TEST-RESULTS.md). |
| G0 — Dart/mobile baseline | **Not run** | Dart/Flutter/Android/Xcode/device tools unavailable on this host; static source checks are not Dart tests or mobile builds. |
| Track A — security findings | **Documented; independent review pending** | [SECURITY-REVIEW-RESULTS.md](SECURITY-REVIEW-RESULTS.md) records severity, attack, current/missing protections, mitigation, tests, and independent-review need for 12 findings. No independent cryptographer reviewed it. |
| Track B — implementation specification | **Drafted, not approved/implemented** | [PROTOCOL-IMPLEMENTATION-SPEC.md](../../docs/mobile/PROTOCOL-IMPLEMENTATION-SPEC.md) is candidate DMP 0.1 / wire version 2. Field-level encodings and processing rules are provided; provider, operational limits, revocation, and some privacy/UX choices remain approval blockers. No vectors are claimed. |
| Track C — ten timeout diagnoses | **Individually recorded; root cause characterized** | [TIMEOUT-ROOT-CAUSE.md](TIMEOUT-ROOT-CAUSE.md) gives source lines, exact failure, per-test default/single-worker durations, workloads, repeatability, representative direct profiles, and remaining limits. No test/source/timeout changed. |
| Simulator optimization | **No change; equivalence not established** | [PERFORMANCE-INVESTIGATION.md](PERFORMANCE-INVESTIGATION.md) and the new root-cause report. No optimization, routing change, or golden edit. |
| Track D — mobile environment | **Instructions prepared; setup not performed** | [MOBILE-TOOLCHAIN-READINESS.md](MOBILE-TOOLCHAIN-READINESS.md) documents Windows/Dart/Flutter/Android/emulator/physical setup and macOS/Xcode/iOS setup. Exact mobile pins remain owner decisions; no build is claimed. |
| Track E — G1 foundation | **Plan ready; no scaffold** | [G1-IMPLEMENTATION-PLAN.md](G1-IMPLEMENTATION-PLAN.md) defines a minimal local-only shell and Android Emulator/iOS Simulator acceptance. Toolchains/hosts are prerequisites. |
| Android build/install/launch | **Not run** | `java`, `gradle`, `adb`, and `sdkmanager` unavailable. No emulator/phone evidence. |
| iOS build/install/launch | **Not run** | Linux host; `xcodebuild`, `xcrun`, Xcode, and iPhone unavailable. No iOS Simulator/device evidence. |
| Real radio / secure messaging | **Not implemented or tested** | No native BLE adapter, mobile key store, durable message database, selected production crypto provider, or real-peer exchange. |
| Google Play / App Store release | **Not ready / not authorized** | Google Play is the Android target. iOS engineering/testing remain required; App Store distribution remains a separate unauthorized decision. |

## Milestone 3 deliverables

1. `reports/mobile/SECURITY-REVIEW-RESULTS.md` — 12 security findings, each with severity, attack, current/missing protections, mitigation, tests, and independent-review requirement.
2. `docs/mobile/PROTOCOL-IMPLEMENTATION-SPEC.md` — unapproved, versioned candidate identity-binding and packet/forwarding specification. It explicitly separates a signed binding, provider-owned E2E ciphertext, mutable forwarding metadata, and per-neighbor channel protection.
3. `reports/mobile/TIMEOUT-ROOT-CAUSE.md` — per-test duration/location/configuration, normal versus one-worker comparison, fixed-seed repeatability, direct-profiling coverage, bottlenecks, and unknowns.
4. `reports/mobile/MOBILE-TOOLCHAIN-READINESS.md` — Windows Dart/Flutter/Android and Android debugging setup; macOS/Xcode/iOS setup; commands and physical-device coverage. No commands were represented as having run.
5. `reports/mobile/G1-IMPLEMENTATION-PLAN.md` — smallest buildable Flutter shell scope, dependency boundaries, unit/widget tests, Android/iOS acceptance, and explicit non-goals.
6. Updated `reports/mobile/PERFORMANCE-INVESTIGATION.md` with the M3 comparison/profile addendum.
7. Updated `reports/mobile/IMPLEMENTATION-STATUS.md` — this status ledger.

The M2 documents remain in place: `docs/mobile/SECURITY-ARCHITECTURE.md`, `IDENTITY-AND-KEYS.md`, `PACKET-FORMAT.md`, `THREAT-MODEL.md`, `PROTOCOL-TEST-PLAN.md`, and `reports/mobile/SECURITY-REVIEW.md`. G0 files remain: [BASELINE.md](BASELINE.md), [TEST-RESULTS.md](TEST-RESULTS.md), [DEVICE-TEST-MATRIX.md](DEVICE-TEST-MATRIX.md), [ARCHITECTURE.md](../../docs/mobile/ARCHITECTURE.md), and [RELEASE-READINESS.md](../../docs/mobile/RELEASE-READINESS.md).

## Timeout evidence summary

The last complete suite remains **517/527**, ten timeouts, at `vitest.config.ts:7` (`testTimeout: 5000`). The ten selected cases were also run in focused JSON-reporter diagnostics under the default worker pool and `--maxWorkers=1`; all ten timed out in both. In the focused comparisons, body durations ranged from 6.37–57.41 s (default pool) and 5.79–59.65 s (one worker). The four-file diagnostic selected ten tests and marked 200 unrelated cases as not selected; this was not a complete-suite pass and did not edit/skip tests in the repository.

The installed Vitest wrapper checks elapsed time on return from a synchronous callback. `MeshSimulation.runFor` and the affected test bodies are synchronous, so CPU-bound work continues until the callback returns and is then rejected for exceeding 5,000 ms. Representative direct V8 profiles of source-equivalent workloads point to OGM/TQ history, RF geometry, MPR/pruning, and GC. They are not Vitest-worker profiles and do not attribute each test to one function. See [TIMEOUT-ROOT-CAUSE.md](TIMEOUT-ROOT-CAUSE.md) for all ten rows and exact evidence.

No safe optimization with regression proof was identified. No source/test/assertion, test timeout, route default, simulator semantics, threshold, or golden vector changed. The full suite was not rerun in this milestone.

## Security review and specification status

The review confirms key blockers in the reference: Ed25519 QR identity is not signed to the separate X25519 Noise static; `Identity.nodeId` and `peerExchangeNodeId` hash different keys; the current packet header authenticates TTL/hop as AEAD AAD even though simulated forwarding mutates those object fields; and the crypto packet is not integrated with simulator forwarding. The proposal does not claim the chosen primitives compose securely.

DMP 0.1 is an **unapproved draft for discussion**, not a selected library/protocol, test-vector set, or implementation. The candidate COSE/CBOR binding profile, Noise context, message schema, outer envelope, ACK semantics, and error rules need owner and independent-security review. Hard policy values/provider selection (including expiry/clock, revocation, route-token privacy, message/fragment limits, and link-record implementation) remain explicit blockers. No user/security approval is recorded yet.

## Historical toolchain and G1 boundary (2026-11-05)

The existing simulator's Dart constraint is `sdk: ^3.4.0`; it does not pin Flutter or the mobile app. The owner guide includes an exact Dart 3.4.0 standalone SDK example for the current simulator and version-tag-based Flutter setup, but Flutter/Dart pairing, Android JDK/AGP/Gradle/SDK, macOS/Xcode/iOS, OS ranges, and devices still need approval. No Flutter scaffold was created because this host has no mobile toolchains and no macOS/Xcode host.

The proposed G1 is a local-only placeholder shell: onboarding, empty conversation list, privacy-safe diagnostics, navigation, widget/unit tests, Android debug build/install/launch on an approved emulator, and iOS Simulator build/install/launch on an approved macOS/Xcode host. It contains no messaging, keys, crypto, transport, permission prompts, or network behavior. G1 remains **not achieved** until both platform gates actually pass with recorded versions and evidence.

## Historical verification and operating restrictions (2026-11-05)

- The complete 517/527 baseline is carried forward from the prior full run; no full-suite result is claimed for M3.
- M3 focused timeout diagnostics failed as reported; no assertions were weakened and the 5,000 ms timeout was not changed.
- New code was not added. No protocol, packet, crypto, routing, fixture, golden-vector, workflow, or Flutter source change was made.
- `python3 tool/ci/check-docs.py`: **12/12 passed**. A custom check of all 19 mobile Markdown files passed local links, whitespace, control-character, and conflict-marker checks. `git diff --name-only` is empty; the workspace changes are untracked documentation under `docs/mobile/` and `reports/mobile/` only.
- No GitHub Actions/remote CI, push, merge, deployment, or publication was run. No credentials or private keys were added.

## Historical stop condition and next owner decisions (2026-11-05)

1. Obtain independent cryptographic and platform-security review of [SECURITY-REVIEW-RESULTS.md](SECURITY-REVIEW-RESULTS.md) and the DMP 0.1 draft. The current self-review does not satisfy that independent-review gate.
2. Approve or replace the device/user identity model, exact key-binding schema/encoding, session suite/provider, verified-contact UX, key lifecycle/revocation/recovery, and v1 compatibility policy.
3. Approve or replace the outer packet/relay design, AEAD authenticated-field contract, route token/privacy, TTL/hop guarantees, ACK state meanings, hard size/fragment/queue limits, and native link provider.
4. Select the mobile toolchain/device matrix and provide the supported Windows/Android and macOS/Xcode build hosts.
5. Only then authorize protocol or packet implementation; separately authorize the G1 shell after its toolchains are available.

**No protocol, packet-format, or production cryptography implementation is authorized by this status report.**
