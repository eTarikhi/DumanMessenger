# Implementation status — simulator, security, and Flutter workstreams

**As of:** 2026-11-05
**Branch:** `arena/be8aa6c3-dumanmessenger` (active)
**Source snapshot tested/reviewed:** `a1f1916981c2244a2f8664573b66afbd5a2659b4` (empty checkpoint over `bdf719cf88205f944187cb79b8288264a56c13bd`)

## Executive status

- **G0 baseline:** **NOT PASSED.** Full TypeScript suite is 517/527 with ten failures at the unchanged 5,000 ms timeout. Dart tests did not run on this host.
- **Milestone 2:** the documentation-only baseline and security design proposal remain complete. No production code changed.
- **Milestone 3 Tracks A–E:** the review results, draft implementation specification, ten-case timeout diagnosis, toolchain setup guide, and G1 foundation plan are documented below. These are documentation/review deliverables only.
- **Security status:** the security findings are recorded, but the review is not independent. No external cryptographer, protocol auditor, or platform security reviewer has examined the design. Candidate DMP 0.1 / wire version 2 is **not approved and not implemented**. **Owner/security approval is required before protocol, packet, or production crypto changes.**
- **Timeout status:** all ten failures were measured individually in focused default-worker and single-worker runs. All remained over budget. Synchronous simulation work explains the timeout trigger; representative source-equivalent profiles show repeated OGM/TQ-history, RF geometry, MPR/pruning, and GC work. This does not establish one identical hot function for every failure. No safe equivalent optimization was found; source/tests/configuration remain unchanged.
- **Mobile status:** no Flutter app or platform projects exist; no mobile toolchain or device is available on this Linux host. No Android/iOS build, launch, emulator, Simulator, or physical-device test was run.
- **G1:** **NOT ACHIEVED.** The minimum buildable-shell plan is ready, but it is not a scaffold or build result.
- **Release:** Android target is Google Play. iOS implementation/testing remain required. **App Store distribution is not authorized.** No GitHub Actions, push, merge, deployment, or publication was performed.

## Gate and workstream ledger

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

## Toolchain and G1 boundary

The existing simulator's Dart constraint is `sdk: ^3.4.0`; it does not pin Flutter or the mobile app. The owner guide includes an exact Dart 3.4.0 standalone SDK example for the current simulator and version-tag-based Flutter setup, but Flutter/Dart pairing, Android JDK/AGP/Gradle/SDK, macOS/Xcode/iOS, OS ranges, and devices still need approval. No Flutter scaffold was created because this host has no mobile toolchains and no macOS/Xcode host.

The proposed G1 is a local-only placeholder shell: onboarding, empty conversation list, privacy-safe diagnostics, navigation, widget/unit tests, Android debug build/install/launch on an approved emulator, and iOS Simulator build/install/launch on an approved macOS/Xcode host. It contains no messaging, keys, crypto, transport, permission prompts, or network behavior. G1 remains **not achieved** until both platform gates actually pass with recorded versions and evidence.

## Verification and operating restrictions

- The complete 517/527 baseline is carried forward from the prior full run; no full-suite result is claimed for M3.
- M3 focused timeout diagnostics failed as reported; no assertions were weakened and the 5,000 ms timeout was not changed.
- New code was not added. No protocol, packet, crypto, routing, fixture, golden-vector, workflow, or Flutter source change was made.
- `python3 tool/ci/check-docs.py`: **12/12 passed**. A custom check of all 19 mobile Markdown files passed local links, whitespace, control-character, and conflict-marker checks. `git diff --name-only` is empty; the workspace changes are untracked documentation under `docs/mobile/` and `reports/mobile/` only.
- No GitHub Actions/remote CI, push, merge, deployment, or publication was run. No credentials or private keys were added.

## Stop condition and next owner decisions

1. Obtain independent cryptographic and platform-security review of [SECURITY-REVIEW-RESULTS.md](SECURITY-REVIEW-RESULTS.md) and the DMP 0.1 draft. The current self-review does not satisfy that independent-review gate.
2. Approve or replace the device/user identity model, exact key-binding schema/encoding, session suite/provider, verified-contact UX, key lifecycle/revocation/recovery, and v1 compatibility policy.
3. Approve or replace the outer packet/relay design, AEAD authenticated-field contract, route token/privacy, TTL/hop guarantees, ACK state meanings, hard size/fragment/queue limits, and native link provider.
4. Select the mobile toolchain/device matrix and provide the supported Windows/Android and macOS/Xcode build hosts.
5. Only then authorize protocol or packet implementation; separately authorize the G1 shell after its toolchains are available.

**No protocol, packet-format, or production cryptography implementation is authorized by this status report.**
