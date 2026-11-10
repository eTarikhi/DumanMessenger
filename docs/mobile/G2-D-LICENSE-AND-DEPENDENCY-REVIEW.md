# G2-D license and dependency review

**Status: no dependency was added in this milestone.** The app still depends only on the
Flutter SDK and `flutter_lints`. This document records what AGPL-3.0 obliges Duman to do
once `libsignal-android` is integrated, the inventory that integration brings, and the
questions that require legal review rather than an engineering answer.

- **Date:** 2026-11-09
- **Context:** [G2-D-ARCHITECTURE-DECISION.md](G2-D-ARCHITECTURE-DECISION.md)

**This is an engineering reading of the license, not legal advice.** Items marked
*needs counsel* must be confirmed by someone qualified to answer them before distribution.

## 1. Current dependency inventory (this milestone)

| Dependency | Version | License | Added by |
|---|---|---|---|
| Flutter SDK (framework) | owner-reported Flutter 3.47.8 / Dart 3.13.7 | BSD-3-Clause | pre-existing |
| `flutter_lints` | ^6.0.0 (dev only) | BSD-3-Clause | pre-existing |

Nothing else was added. The identity foundation uses `dart:math` and the core libraries
only. There is no new package in `pubspec.yaml`, no new Gradle dependency, and no vendored
source.

## 2. AGPL-3.0: what it actually requires

`org.signal:libsignal-android` is licensed **AGPL-3.0** (`LICENSE` in the upstream
repository; the published POM declares `AGPLv3`). The owner has accepted AGPL-3.0 for this
project. Acceptance is not the same as compliance, so here is what compliance means.

| Obligation | Plain meaning for Duman | Applies when |
|---|---|---|
| **§3 — Corresponding Source** | Whoever receives the app binary must be able to obtain the complete corresponding source of the work, including the library and the Duman code it is combined with, under the same license | Every distribution (store, APK, sideload, preview channel) |
| **§4 — Notices** | Keep copyright notices and the license text; the app must display/offer them (an in-app "Licenses" screen satisfies this if it includes libsignal and the AGPL text) | Every distribution |
| **§5 — Acceptance / conveyance** | Distributing the APK is "conveying"; you may not add terms that restrict recipients' AGPL rights | Every distribution |
| **§13 — Remote network interaction** | If a modified version is offered as a network service, users interacting with it must be offered its source | Today Duman is serverless, so no §13 surface exists; **any future relay/registration/push service is a §13 surface** |
| **§2 / §6 — No additional restrictions** | Terms of service, DRM, or a store agreement may not forbid what AGPL permits. Anti-tivoization (§6 Installation Information) applies to "User Products" | Store distribution; *needs counsel* for §6 applicability to Play-distributed apps |
| **Derivative work** | Linking the AAR into the app makes the app a combined work; the Duman application source becomes subject to AGPL | As soon as the dependency is in the shipped APK |

### 2.1 Consequences Duman must plan for

1. **The application will be AGPL-3.0**, not only the library. This includes the Dart code,
   which is currently unlicensed for distribution purposes. A `LICENSE` change and a
   copyright header policy are prerequisites for shipping.
2. **Source must be published** at the version that was built, with build instructions good
   enough to rebuild the same work. The repository already exists; the obligation is to keep
   a matching tag per release and to state the exact commit in the app's about screen.
3. **A licenses screen** must list libsignal, AGPL-3.0, every transitive dependency and the
   Duman license text.
4. **No additional restrictions** may be imposed via terms of use, telemetry consent
   bundling, or store-specific copy that narrows AGPL rights.
5. **Private use is unaffected**: developing, testing, and installing on the owner's own
   devices is not distribution. Publishing an APK to anyone else is.

## 3. Distribution channels

| Channel | Status | Notes |
|---|---|---|
| Local debug builds on owner devices | Unaffected | No conveyance |
| Google Play (intended Android target) | **Permitted in principle**, obligations above apply | Source availability and notices must be reachable from the listing or the app |
| Direct APK / preview channel | Obligations apply per delivery | Ship a source offer with the artifact |
| **Apple App Store (iOS target)** | **Unresolved — needs counsel** | AGPL and the App Store terms have a well-known tension: store terms impose usage and redistribution restrictions that GPL-family licenses forbid. The FSF has publicly taken the position that GPL-family terms are incompatible with the App Store; whether that reasoning extends to AGPLv3 for this app is a legal question, not an engineering one |
| Enterprise/MDM or F-Droid | Obligations apply | F-Droid requires fully free builds; consistent with AGPL |

This matters for the owner's stated long-term iOS goal: **choosing libsignal may make
App Store distribution legally difficult while the same code is fine on Play.** The
alternatives if that becomes a blocker are (a) distribute iOS outside the App Store, (b) a
different provider for iOS (protocol divergence), or (c) renegotiate the protocol choice.
Recording it now is cheaper than discovering it after the integration.

*Needs counsel:* whether §6 Installation Information applies to Play-distributed apps; the
App Store question; whether the existing repository's lack of a `LICENSE` change conflicts
with any pre-existing license text in the tree (`LICENSE` exists at the repository root —
its terms must be reconciled before AGPL code is combined).

## 4. Inventory the integration will bring (not yet added)

| Artifact | Version to pin | License (as declared) | Verified how |
|---|---|---|---|
| `org.signal:libsignal-android` | 0.86.5 is what Maven Central surfaced at review; the repository tag is `v0.106.2` → **the version to pin must be chosen deliberately, not by "latest"** | AGPLv3 | AAR POM on Central, upstream `LICENSE` |
| `org.signal:libsignal-client` | same version | AGPLv3 | POM |
| `org.jetbrains.kotlin:kotlin-stdlib` | 2.1.0 | Apache-2.0 | POM |
| `org.jetbrains.kotlinx:kotlinx-coroutines-android` | 1.10.2 | Apache-2.0 | POM |
| `com.android.tools:desugar_jdk_libs` (added by Duman for desugaring) | 1.1.6 per libsignal's build | *to be confirmed from the artifact* | **not verified** |
| Transitive set | unknown until resolved | unknown | **not enumerated** |

Until `./gradlew :app:dependencies` has been run on the owner's machine, the transitive
inventory is unknown, and an unknown inventory cannot be reviewed. That is a gate, not a
footnote.

## 5. Provenance and binary integrity

- Pin an **exact version**; never use a dynamic version or `+`.
- Record the artifact SHA-256 in the repository and verify it in the build.
- Prefer Gradle dependency verification (`verification-metadata.xml`) so a swapped artifact
  fails the build rather than silently entering the APK.
- **Publication lag is a real risk**: Central showed `0.86.5` (~11 months old) while the
  repository had released `v0.106.2`. The chosen version may be older than the upstream
  code; either accept that and document it, or vendor a specifically built AAR with its
  build provenance recorded.
- Upstream states that use outside Signal is unsupported and that APIs change without
  notice, so an upgrade is a review event, not a routine bump.

## 6. What would change this analysis

- A maintained **Apache-2.0/MIT** implementation of the same protocol family with an Android
  artifact and an audit → removes the AGPL and iOS-store questions entirely. None was
  identified in the architecture review.
- A decision to ship iOS outside the App Store → the store conflict disappears.
- A decision to keep Duman strictly private (no distribution) → obligations do not trigger,
  but neither does the product.

## 7. Gates

| Gate | Requirement |
|---|---|
| L1 | `LICENSE` reconciled: the repository license and the app's distribution license are decided and consistent with AGPL |
| L2 | Transitive dependency inventory produced from a real Gradle resolve, with licenses |
| L3 | Artifact pinned by version **and** SHA-256, ideally with Gradle verification |
| L4 | Licenses screen content prepared (Duman, libsignal, AGPL text, transitives) |
| L5 | Source-availability process defined per release (tag + build instructions + offer) |
| L6 | Legal review of the App Store question and §6 applicability, **before** any iOS distribution work |
| L7 | SBOM generated per release |

None of L1–L7 is satisfied. None is claimed.
