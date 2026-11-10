# G2-D architecture decision — protocol and provider selection

**Status: RECOMMENDATION, NOT AN APPROVED DECISION.** Option A (Signal protocol via
`libsignal-android`) is recommended. It is **not integrated, not compiled, and not
validated on any device**, and the two conditions in §8 must be met before integration
starts. Option B (Noise) is not selectable on current evidence. Nothing in this document
establishes a security property of the running app.

- **Date:** 2026-11-09
- **Supersedes on protocol choice:** the "candidate evidence matrix" in
  [ADR-G2-C-ANDROID-SECURE-BLE-LINK.md](ADR-G2-C-ANDROID-SECURE-BLE-LINK.md) — that matrix
  was written before the owner accepted AGPL-3.0 and before the artifact evidence below.
- **Companions:** [G2-D-SECURITY-ARCHITECTURE-PLAN.md](G2-D-SECURITY-ARCHITECTURE-PLAN.md)
  (threat model, gates), [G2-D-IDENTITY-KEY-MANAGEMENT.md](G2-D-IDENTITY-KEY-MANAGEMENT.md),
  [G2-D-TRUST-AND-VERIFICATION.md](G2-D-TRUST-AND-VERIFICATION.md),
  [G2-D-LICENSE-AND-DEPENDENCY-REVIEW.md](G2-D-LICENSE-AND-DEPENDENCY-REVIEW.md).

## 1. Decision summary

| Question | Answer in this milestone |
|---|---|
| Which protocol family? | **Signal protocol (X3DH/PQXDH initial agreement + Double Ratchet), via `org.signal:libsignal-android`.** |
| Is it integrated? | **No.** No dependency was added. No code compiles against it. |
| Why not integrate now? | Two gates are open: a Java 21 + core-library-desugaring build change that has never been built on the owner's Windows toolchain, and an API 27 device probe of the JNI libraries (§8). Integrating blind would risk the working G2-C build for no security gain yet. |
| What can proceed regardless? | The protocol-agnostic identity foundation (§9), which is implemented and tested in this milestone. |
| Is Noise rejected? | **Not as a protocol — as an implementation choice for this app, yes, on current evidence** (§5). |
| Remaining owner decisions | §10. |

## 2. Constraints that drive the choice

1. **No central server.** This is the constraint that breaks the textbook Signal deployment
   model, and it is addressed in §7 rather than assumed away.
2. **Android API 27 floor.** The owner's test device is a Samsung SM-G610F on Android 8.1.
3. **Both devices are present at first contact.** Two phones in BLE range: an interactive
   handshake is affordable, asynchronous prekey publication is not needed.
4. **Multiple hops eventually.** Content must survive relays, so a per-link protocol alone
   is insufficient.
5. **Small frames.** G2-C caps a reassembled message at 2,048 bytes and a test frame payload
   at 512 bytes; at the mandatory ATT MTU of 23 a fragment carries 11 bytes.
6. **AGPL-3.0 accepted by the owner** for the project — with obligations documented in
   [G2-D-LICENSE-AND-DEPENDENCY-REVIEW.md](G2-D-LICENSE-AND-DEPENDENCY-REVIEW.md).
7. **Windows-only development, no Mac.** Nothing in this milestone may require Xcode.
8. **iOS remains a target.** The choice must be portable later, or the cost of switching must
   be explicit now.

## 3. Comparison matrix

Ratings are this review's judgement against **this app's** constraints, with the evidence
column stating what was actually inspected.

| Criterion | **A — libsignal-android** | **B — Noise (`XX`/`KK`) + own ratchet** | **C — another established stack** |
|---|---|---|---|
| Security properties | Initial agreement with mutual authentication, forward secrecy, post-compromise recovery (Double Ratchet); identity binding part of the protocol | Handshake gives mutual authentication and forward secrecy **for the session**; no ratchet, so no break-in recovery and no per-message FS unless one is built | MLS (RFC 9420) gives group FS/PCS but is aimed at groups; Tink gives primitives only |
| Implementation maturity | Deployed at very large scale; Rust core with JNI; actively released (tag `v0.106.2`, 2026-11-05) | No maintained JVM implementation with a published artifact (see §5) | MLS JVM implementations not assessed as production-ready here; Tink is mature but is not a session protocol |
| Android API 27 compatibility | `minSdkVersion 23` in the library's own build file → within floor; AAR ships `armeabi-v7a`, so the 32-bit test device is covered | Depends entirely on the implementation chosen | Unknown / unassessed |
| Flutter integration effort | Moderate–high: Java 21 + core-library desugaring in the app build, Kotlin/Java bridge behind a MethodChannel, six provider stores to implement | Moderate: needs a Noise implementation first, then a bridge | High: group protocol machinery with no use for it yet |
| P2P without a server | Yes, with a designed in-band bundle exchange (§7) | Yes, naturally | MLS needs a delivery service; not suitable here |
| Relay compatibility | Ciphertext is opaque; relays forward bytes | Opaque after handshake; handshake messages must be relayed only if the session spans hops | Opaque but larger |
| License / distribution | **AGPL-3.0** — obligations in the license review; store distribution requires source availability | MIT metadata on the candidate projects | Apache-2.0 (Tink) / varies |
| Maintenance risk | **Elevated but quantified:** upstream states third-party use is unsupported and APIs change without notice; Maven Central publication lags releases | **Severe:** no artifact, one candidate self-declares as unaudited | Varies; unassessed |
| iOS portability | libsignal ships a Swift package for the same Rust core → same protocol on both platforms later | Would need a second Noise stack on iOS, likely a different implementation → cross-platform divergence risk | Varies |
| Testing / independent review feasibility | Published vectors, an active security process (`SECURITY.md`), and a well-studied protocol family; app-level composition still needs its own review | Pattern-level analysis exists (Noise Explorer); the *implementation* has no review | Unassessed |

**Recommendation:** Option A. The decisive arguments are (i) it is the only candidate that
delivers forward secrecy *and* post-compromise recovery without Duman writing a ratchet,
(ii) it is the only candidate with a published Android artifact that declares API 23
support, and (iii) it keeps the iOS path open through the same Rust core. The cost is
AGPL-3.0 plus a real build-configuration change plus a library whose upstream does not
support outside use — all three are documented rather than hidden.

## 4. Option A — evidence inspected

Every claim below was read from the upstream repository or a package index during this
milestone; nothing was taken from a blog post.

| Fact | Value | Source |
|---|---|---|
| License | AGPL-3.0 (repo `LICENSE`; library POM declares `AGPLv3`) | `signalapp/libsignal` |
| Repository activity | Latest release tag `v0.106.2`, published 2026-11-05 | GitHub releases API |
| Android artifact | `org.signal:libsignal-android` (AAR) on Maven Central; `packaging = 'aar'` | `java/android/build.gradle`, Central |
| Version surfaced by Central | `0.86.5`, published ~11 months before this review — **lagging the repository tags** | Central artifact page |
| Transitive deps (declared) | `org.signal:libsignal-client` (same version), `org.jetbrains.kotlin:kotlin-stdlib:2.1.0`, `org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2` | AAR POM on Central |
| `minSdkVersion` | **23** → API 27 is inside the supported range | `java/android/build.gradle` |
| `compileSdk` / `targetSdk` | 34 / 33 | same |
| Java level | `sourceCompatibility`/`targetCompatibility` = **Java 21**, `coreLibraryDesugaringEnabled = true`, `desugar_jdk_libs:1.1.6` | same |
| Native ABIs built | `arm64-v8a`, `armeabi-v7a`, `x86_64`, `x86` | `java/build_jni.sh` |
| Native build needed by consumers? | No — prebuilt `.so` are packaged in the AAR; NDK is only needed to build libsignal itself (`doNotStrip` defers stripping to the app) | `java/android/build.gradle` |
| API stability | *"Use outside of Signal is unsupported… All APIs and implementations are subject to change without notice"* | upstream `README.md` |
| Security process | RFC-9116-style `SECURITY.md` pointing at `security@signal.org` | upstream `SECURITY.md` |
| Protocol surface | "Implements the Signal protocol, including the Double Ratchet algorithm" | upstream `README.md` |

### 4.1 What the app must change to consume it

The app today compiles at Java 17 with no desugaring:

```kotlin
// mobile/app/android/app/build.gradle.kts (current)
compileOptions {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}
kotlin { compilerOptions { jvmTarget = JvmTarget.JVM_17 } }
```

Consuming the AAR is expected to require Java 21 plus core library desugaring, i.e. a
change to `compileOptions`, a `coreLibraryDesugaring` dependency, and a JDK-21 toolchain on
the owner's machine. **None of that was attempted here**, because it cannot be compiled or
built in this environment and a broken Gradle change would take the working G2-C build down
with it. This is gate **D2-a** (§8).

### 4.2 What is *not* verified

- That the published `0.86.5` AAR actually contains the four ABIs (inferred from the build
  script, not inspected inside the AAR).
- That the JNI libraries load on the SM-G610F or any API 27 device.
- That the Java API surface of `0.86.5` matches the repository's current documentation.
- That desugaring at the app's current `compileSdk` is sufficient (compileSdk is delegated
  to Flutter and not pinned in this repository).

Each of these is a spike step, not an assumption.

## 5. Option B — why Noise is not selectable here

Noise is a good framework and the right shape for a 3-message mutual handshake between two
phones that are both present. Revision 34 of the specification (2018-07-11) documents `XX`
as the most generally useful pattern precisely because it transmits both static keys under
mutual authentication, and pattern-level symbolic analysis exists (Noise Explorer).

The blocker is not the framework, it is the code:

| Candidate | Evidence | Verdict |
|---|---|---|
| `rweather/noise-java` | MIT metadata; **no published release artifact**; POM `1.0-SNAPSHOT`; Java 8 source/target | Cannot be pinned or resolved as a dependency |
| `jchambers/java-noise` | MIT metadata; README states **not published to artifact repositories** and **not independently audited**; Java 17 | Cannot be consumed without vendoring unaudited code |
| Any third implementation | **None identified in this review** that publishes an artifact, documents maintenance and has been reviewed | Not available |

Vendoring one of these would mean: (i) shipping unaudited cryptographic code, (ii) writing
our own session/ratchet layer on top because Noise stops at the handshake, and (iii) owning
all of that forever. That is precisely the "custom protocol" outcome the milestone forbids —
arrived at by accident rather than by design.

Noise remains a candidate **only** if a maintained, published, reviewed JVM implementation
appears, or if the project later decides to vendor one and fund its review.

## 6. Option C — other established stacks

- **MLS (RFC 9420, Standards Track, July 2023):** designed for groups with an asynchronous
  delivery service. Two phones on a BLE link need none of it, and the operational cost
  (KeyPackages, epochs, delivery service) is large. Revisit when group messaging is real.
- **Tink (`tink-android` 1.24.0, Apache-2.0):** a well-maintained primitives library with
  key management and wire formats. It cannot supply the mutually authenticated session
  protocol by itself; using it as the *composition* layer would reproduce Option B's problem
  with a better-maintained primitive set. It remains a strong candidate for **storage**
  encryption and record encryption under a reviewed design.
- **Platform TLS/mTLS:** certificate lifecycle, identity pinning and record mapping onto
  GATT would all have to be designed by us; not evaluated as a smaller total cost.

No Option C candidate was found that improves on A for a 1:1 serverless BLE messenger.

## 7. Session establishment without a server

The part of Signal's design that assumes a server is **prekey distribution**, not the
protocol. `libsignal` needs, on the responder side, a public bundle and, on the initiator
side, that bundle plus a one-time prekey. In Duman these are exchanged **in band, over the
same G2-C link, immediately after `service_ready`, before any message is accepted**.

### 7.1 Flow

```text
1. user starts discovery/connection on both phones         (existing G2-C, unchanged)
2. service_ready on both sides                             (existing G2-C, unchanged)
3. responder sends its public bundle:
      identity key (curve25519, 33 B) + signed prekey (33 B) + signature (64 B)
      + optional one-time prekey (33 B)                    ≈ 163 B + framing
   request/response, one reassembled G2-C message (≤ 2,048 B)
4. initiator builds PreKeySignalMessage, sends it          (fits the message budget)
5. both sides derive the session; the identity key is compared against the
   locally pinned fingerprint from step 3
6. only then may the UI move past "session established" — and it still says
   "identity authenticated, not verified by you"
```

### 7.2 Why in-band exchange is acceptable — and what it is not

Exchanging public keys over an unauthenticated radio channel is **exactly** the situation
X3DH was designed for: an active attacker can substitute a bundle, but it cannot make the
substituted identity key equal the fingerprint the user later compares out of band. The
protection is therefore *not* the channel; it is the out-of-band comparison plus the
protocol's binding of the identity key into the session.

Consequences that must be implemented or accepted:

- A peer whose fingerprint has never been compared is **unverified**, and a substituted
  bundle produces exactly the "identity changed" state that
  [G2-D-TRUST-AND-VERIFICATION.md](G2-D-TRUST-AND-VERIFICATION.md) fails closed on.
- First contact therefore has a real, visible security step: the user compares 64 hex
  characters (or scans a QR code) on the two phones.
- Bundles must be validated strictly before use: exact lengths, curve-point validity, and
  signature verification of the signed prekey. `libsignal` performs these checks; the app
  must not pre-parse or normalise the bytes.

### 7.3 PQXDH sizing problem (flagged, not solved)

If PQXDH is adopted later, the Kyber prekey added to the bundle is roughly 1.5 KB. That
exceeds a single 512-byte G2-C frame payload and must travel as a multi-fragment message
(≤ 2,048 bytes reassembled), which is possible but tight once a one-time prekey is also
included. This is a design input for **D1** (protocol profile), not something to discover
during integration.

## 8. Conditions before integration (gates)

Integration may not start until these are evidenced. Both are cheap relative to the cost of
discovering them after the app depends on the library.

| Gate | Requirement | Why it blocks |
|---|---|---|
| **D2-a — build** | A throwaway branch that adds the AAR at a pinned version, moves the app to Java 21 + core library desugaring, and builds `flutter build apk --debug` **and** a release-variant build on the owner's Windows machine | A build-toolchain change that has never been compiled can break the working app; the owner is the only one who can build |
| **D2-b — device** | Install the resulting debug APK on the SM-G610F (API 27, 32-bit) and on one API 31+ device; run a minimal "load native library, generate an identity key, sign, verify" self-check; record the result per device | `minSdkVersion 23` and the ABI list are *declared* facts; loading JNI code on a 32-bit Android 8.1 device is an *observed* fact |
| **D2-c — provenance** | Pin the exact artifact version, record its SHA-256, enumerate transitive dependencies and licenses, and confirm the version chosen exists on Central (given the observed lag) | Unpinned dependencies are not reproducible |
| **D1 — profile** | Decide X3DH vs PQXDH for v1, the one-time-prekey policy, session message ordering, and the bundle framing on G2-C | Determines sizes, storage and the identity binding |

Only after D2-a/D2-b pass is the risk of "integration breaks the working build" retired.

## 9. What is decided now regardless of Option A

The identity foundation is deliberately **provider-agnostic** and is implemented in this
milestone:

- identity records and lifecycle (create, rotate, revoke, reset) over a storage contract;
- key protection that must be *probed* before it can be recorded;
- the seven-axis peer trust model with fail-closed identity-change handling.

It records *which* key an installation uses and how it is protected; it never generates key
material. When the provider lands, its key generation fills in the fingerprint and the
handle, and the record format does not change. See
[G2-D-IDENTITY-KEY-MANAGEMENT.md](G2-D-IDENTITY-KEY-MANAGEMENT.md).

## 10. Decisions still requiring owner approval

1. **Proceed with Option A** after D2-a/D2-b pass (this document recommends, the owner decides).
2. **Accept the Java 21 + desugaring build change** and its effect on the Flutter/AGP setup.
3. **Accept the AGPL distribution model** including source availability for a store release
   ([license review](G2-D-LICENSE-AND-DEPENDENCY-REVIEW.md)) and the App Store question.
4. **X3DH now, PQXDH later** — or design the PQ path into the bundle from the start.
5. **Pin policy** — which exact `libsignal-android` version, given that Central lags tags.
6. **Vendor-vs-resolve** — consume from Central or vendor a vetted AAR in the repository.

## 11. What must not be claimed

- That Duman is end-to-end encrypted. No session code exists.
- That Option A is "selected". It is recommended and gated.
- That a libsignal integration would be secure by virtue of the library: the *composition*
  (bundle exchange, trust ceremony, storage, replay handling) is Duman's responsibility and
  is unreviewed.
