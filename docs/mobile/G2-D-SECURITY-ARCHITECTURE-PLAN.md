# G2-D — Security architecture and implementation plan

**Status: DESIGN PROPOSAL. Nothing in this document is implemented, approved, or claimed to be secure. No protocol, key, storage, or trust code exists in the app. Protocol and library selection remain BLOCKED pending the evidence and review gates in §10.**

- **Date:** 2026-11-09
- **Predecessor:** [G2-C acceptance record](G2-C-ACCEPTANCE-CHECKLIST.md) — owner-validated TEST-ONLY BLE transport, no security properties.
- **Extends, does not replace:** [SECURITY-ARCHITECTURE.md](SECURITY-ARCHITECTURE.md), [THREAT-MODEL.md](THREAT-MODEL.md), [IDENTITY-AND-KEYS.md](IDENTITY-AND-KEYS.md), [PROTOCOL-IMPLEMENTATION-SPEC.md](PROTOCOL-IMPLEMENTATION-SPEC.md), [PROTOCOL-TEST-PLAN.md](PROTOCOL-TEST-PLAN.md), and the mesh-specific Noise cost analysis in [07-e2ee-noise-xx.md](../07-e2ee-noise-xx.md).
- **Evidence classes used here:** *verified source fact* (a link or a file in this repository), *external specification* (cited), *design decision proposed* (not approved), *open question* (owner or reviewer decision).

## 0. Why a security milestone exists at all

G2-C works. The owner has validated the transport on two physical phones, and the toolchain is green. That success is exactly the point at which a transport is easiest to over-trust: `service_ready` reads like a security state, but it only means the expected GATT service and characteristics were found and the notification descriptor was written. Five things are absent, and each is a stated G2-C limitation:

1. No authenticated peer handshake — nothing proves the peer holds a key.
2. No persistent peer identity or trust lifecycle — nothing survives a restart, nothing can be revoked.
3. No end-to-end encryption — test payloads are plaintext application bytes.
4. No replay or downgrade protection — no counter, epoch, or version binding.
5. No independent review — no external party has examined any of it.

G2-D is the milestone that closes 1–4 and produces the evidence demanded by 5. It is a security milestone, not a feature milestone: its output is a reviewed design, a pinned provider, a tested key lifecycle, and negative-test evidence. Usable messaging is a later, separately authorized consequence.

## 1. Objectives and non-goals

### Objectives (ordered; each is a gate, not a preference)

1. **Device identity** that is persistent, canonical, and bound to the exact key used by the key exchange.
2. **Authenticated key exchange** over the existing G2-C transport, using an established protocol and a pinned implementation.
3. **Peer trust** as an explicit human act with pins, revocation, and rotation — never automatic.
4. **Replay and downgrade resistance** with durable state that survives crash and restore, failing closed.
5. **End-to-end confidentiality and integrity** of message content that holds *across relays*, not just on the radio hop.
6. **Forward secrecy and post-compromise recovery** with honest, tested limits.
7. **Reviewable evidence**: vectors, negative tests, fuzz results, device matrix, and an independent review report.

### Non-goals

- Group messaging, multi-device accounts, and account recovery (MLS territory; see §3.1 and the open decisions in §12).
- Anonymity, traffic-analysis resistance, or metadata privacy. BLE advertisement and routing metadata remain visible and linkable; no claim will be made otherwise.
- Background reachability, iOS support, and store release.
- Any migration of existing simulator/browser crypto (`src/crypto/`) into the mobile app. It is TypeScript reference code, not a native provider.

## 2. Trust and state model

Keep six state axes strictly separate. Only the last two require cryptography, and only the fifth requires a human.

| Axis | Meaning | Producer | G2-C today | G2-D target |
|---|---|---|---|---|
| **Discovered** | A temporary radio candidate matched the service UUID | Scanner | Present (opaque token) | Unchanged |
| **Connected** | A GATT link exists | Android | Present | Unchanged |
| **Service ready** | Expected service/characteristics discovered **and** notifications configured | Android | Present | Unchanged |
| **Session established** | A protocol handshake completed and keys are bound to this exact peer key and transcript | Crypto provider | Absent | **G2-D** |
| **Verified** | A human compared an out-of-band value for this pinned key | User | Absent | **G2-D** |
| **Disconnected** | No link | Android | Present | Unchanged |

A peer progresses `discovered → connected → service ready → session established` automatically only up to *service ready*. Promotion to *session established* requires the handshake to succeed cryptographically. Promotion to *verified* requires an explicit user action and nothing else — no first-use auto-trust, no "trust this device" checkbox that defaults on, no silent pin on reconnect.

### 2.1 Two cryptographic layers, not one

```text
  application message (plaintext, local)
        |
        v
  [ L2  end-to-end session ]   ratcheted, per-peer, survives relays
        |   opaque ciphertext
        v
  [ G2-C frame + fragmentation ]   routing and bounds only
        |
        v
  [ L1  link session ]   per-neighbor authenticated channel over GATT
        |
        v
  BLE radio (possibly an OS-encrypted link, which counts for nothing here)
```

Reason for two layers: a mesh relay terminates the radio link but must not be able to read or alter message content. L1 protects a hop; only L2 protects the message. L1 alone would recreate the classic "encrypted to the relay" mistake. L2 alone would leave each hop's metadata and framing open to trivial injection and replay.

The existing mesh analysis in [07-e2ee-noise-xx.md](../07-e2ee-noise-xx.md) already prices a Noise handshake per link in this network; that cost analysis is an input to L1, not a substitute for L2.

## 3. Cryptographic protocol research

Constraints that shape the choice, before any library is named:

- **No server.** The mesh has no always-reachable directory or prekey service. Protocols whose first contact depends on a server-hosted prekey bundle (X3DH, PQXDH) do not map cleanly onto two phones that are simultaneously 30 cm apart.
- **Synchronous first contact.** Both devices are online at the same moment by construction — they are in radio range. A 3-message interactive handshake is affordable; asynchronous prekey publication is not needed.
- **Multiple hops.** Message content must be protected end to end across relays, so a per-link protocol alone is insufficient.
- **Tiny MTU, fragment-bound framing.** One G2-C application frame is capped at 512 bytes, one reassembled message at 2,048 bytes, and at the mandatory ATT MTU of 23 a fragment carries 11 payload bytes. Handshake messages must be sized for that (§8.2).
- **API 27 floor.** The oldest supported device has an Android Keystore that does not offer every modern algorithm as a hardware key (§7.2).

### 3.1 Specification evidence

| Specification | Version / date observed | What it gives | What it does not give |
|---|---|---|---|
| [Noise Protocol Framework](https://noiseprotocol.org/noise.html) | Revision 34, 2018-07-11, marked "official/unstable" | A framework for 2-party authenticated key exchange with fixed patterns (`XX`, `KK`, `IK`); `XX` is described in the spec as the most generically useful pattern because both static public keys are transmitted under mutual authentication | No message ratchet beyond the handshake, no identity semantics, no trust model, no wire framing. A pattern choice is a protocol decision that still needs review |
| [Noise Explorer](https://noiseexplorer.com/) | Public symbolic-verification tool for Noise patterns | Machine-checked analysis of individual patterns (secrecy, authentication), supplying third-party validation of the *pattern*, not of any Java implementation | Nothing about a specific library's correctness, side channels, or Android packaging |
| [X3DH](https://signal.org/docs/specifications/x3dh/) | Revision 1, 2016-11-20 | Asynchronous initial key agreement from a prekey bundle, with identity binding | Assumes a server-published bundle; not obviously applicable to a serverless BLE first contact |
| [Double Ratchet](https://signal.org/docs/specifications/doubleratchet/) | Revision 1, 2016-11-20 | Forward secrecy plus break-in recovery through DH + symmetric ratcheting, message keys, out-of-order handling | Requires durable, crash-safe ratchet state; the state machine is where implementations actually fail |
| [PQXDH](https://signal.org/docs/specifications/pqxdh/) | Revision 3, 2023-05-24 (updated 2024-01-23) | Post-quantum-secure initial agreement (X25519 + ML-KEM), still relying on discrete log for authentication | Adds KEM key sizes and a second key type to the identity story; a later migration, not a G2-D v1 requirement |
| [MLS (RFC 9420)](https://www.rfc-editor.org/rfc/rfc9420) | Standards Track, July 2023 | Asynchronous group key agreement with forward secrecy and post-compromise security for large groups | Complexity and group semantics far beyond a two-party BLE link; relevant only when groups are a real product requirement |
| [RFC 7748](https://www.rfc-editor.org/rfc/rfc7748) / [RFC 8032](https://www.rfc-editor.org/rfc/rfc8032) | — | X25519 key agreement / Ed25519 signatures, with test vectors | Vectors, not an implementation |
| [RFC 5869](https://www.rfc-editor.org/rfc/rfc5869) / [RFC 8439](https://www.rfc-editor.org/rfc/rfc8439) | — | HKDF / ChaCha20-Poly1305 AEAD with vectors | — |

**No primitive in this plan is invented.** Every construction named here comes from one of the specifications above, and the composition of two of them (a Noise handshake feeding a ratchet) is itself a review item, not a settled fact.

### 3.2 Library evidence

| Candidate | Exact identity observed | License | Evidence observed | Assessment for G2-D |
|---|---|---|---|---|
| **Tink (Android)** | `com.google.crypto.tink:tink-android` **1.24.0**, published 2026-10-17 on Maven Central | Apache-2.0 | Actively released; Google-maintained; AEAD/HKDF/keyset primitives with wire formats and test vectors | **Primitives and storage crypto only.** Tink is a primitive library, not a mutually authenticated session protocol; composing a handshake from primitives would be exactly the custom-protocol work this milestone forbids. Strong candidate for the store's AEAD and for record encryption under a reviewed design |
| **libsignal** | `org.signal:libsignal-client` on Maven Central; repository `signalapp/libsignal`, latest tag `v0.106.2` (2026-11-05), AGPL-3.0 | **AGPL-3.0** | The reference implementation of X3DH/PQXDH + Double Ratchet, deployed at very large scale; Rust core with JNI/Java bindings | **Strongest protocol maturity, hardest licensing decision.** AGPL-3.0 is a copyleft obligation the owner must accept explicitly, and the artifact is published primarily for Signal's own apps — Android packaging on API 27 and stability of the Java API are unverified here. Not selectable without a written licensing decision |
| **Noise implementation (Java/Kotlin)** | `rweather/noise-java` and `jchambers/java-noise` — assessed in the [ADR](ADR-G2-C-ANDROID-SECURE-BLE-LINK.md#candidate-evidence-matrix-review-status-not-approval) | MIT (metadata only) | Neither has a published immutable release artifact; one is explicitly self-described as unaudited; Java 8 vs Java 17 targets differ | **Not selectable on current evidence.** Would need a pinned commit, provenance, advisories, API 27 provider tests, and vectors |
| **libsodium (via JNI wrapper)** | `jedisct1/libsodium`, ISC licence, active 2026-11-08 | ISC | Mature, widely deployed; Android requires a JNI wrapper whose own maintenance and provenance must be reviewed | Candidate primitive provider at OS level; a wrapper is a dependency to audit like any other |
| **Platform (Conscrypt / Android Keystore)** | Android platform docs: key material never enters the app process, optional hardware binding, encrypted key import from API 28 | Platform | [Android Keystore system](https://developer.android.com/privacy-and-security/keystore) | Correct home for *wrapping* keys and for hardware-backed signing where available; **not** a source of an authenticated messaging protocol |

**Consequence:** no candidate in this table can be adopted today without either a licensing decision (libsignal), a provenance/audit decision (Noise Java), or a protocol-composition decision that this milestone forbids. That is the honest state of the selection, and it is why protocol selection is marked BLOCKED rather than "in progress".

## 4. Candidate architectures

Three coherent end states, each with what must be true before it is chosen. **No option is approved.**

### Option A — libsignal session end to end

`G2-C transport → libsignal session (X3DH or PQXDH + Double Ratchet)`.

- **Pro:** the protocol is the most heavily deployed and studied messaging construction available; the ratchet, prekey handling, and state machine are somebody else's reviewed code; least new cryptographic surface in Duman.
- **Con / gates:** AGPL-3.0 must be accepted in writing by the owner; the Android artifact and its Java API must be pinned, SBOM'd, and exercised on API 27; first contact must be adapted to an in-person exchange instead of a server-hosted prekey bundle, which is a protocol-usage decision requiring review.
- **Verdict:** strongest security posture; licensing is a product decision, not a technical one.

### Option B — Noise for the link, ratchet for the message

`Noise_XX (or KK once pinned) over GATT for L1 → Double Ratchet keyed from the handshake for L2`.

- **Pro:** maps naturally onto "both devices are here right now"; XX gives mutual authentication and identity binding in 3 messages; the L1 handshake and L2 ratchet are separable for audit.
- **Con / gates:** this is a **composition**, and composition is where protocols go wrong. It requires a Noise implementation with provenance (none currently qualifies) *and* a ratchet implementation, *plus* a review of the KDF hand-off between them. It also needs a defined identity binding inside the prologue and a defined rekey policy.
- **Verdict:** the architecture most likely to fit the mesh long-term, and the most review-dependent.

### Option C — primitives only (Tink + hand-built session)

- **Verdict: rejected.** It is the custom-handshake path this milestone explicitly forbids. Tink remains useful for storage and record encryption under one of the other options, never as the session protocol's composer.

**Recommendation to the owner (not a decision made here):** run the review on **Option A vs Option B** and treat the AGPL question as the deciding input. If AGPL is unacceptable, Option B becomes the path, and the ratchet implementation's provenance becomes the top dependency risk. In both cases §6.1 (identity and keys) and §6.4 (replay and downgrade) are shared work and can start first.

## 5. Threat model for G2-D

This extends the existing [THREAT-MODEL.md](THREAT-MODEL.md) register (T1–T18) with the threats specific to moving from a working unauthenticated transport to an authenticated one.

| ID | Threat | G2-D mitigation | Residual risk |
|---|---|---|---|
| **D1** | **MITM at first contact**: an attacker relays GATT traffic and terminates two separate handshakes | Handshake transcript bound to both static keys and roles; short authentication string compared out of band; mismatch is terminal | A user who skips the comparison gets an unverified session; the UI must never report that as authenticated |
| **D2** | **Substituted static key**: attacker presents its own key for a known peer | Pinned peer record; any key change is a rotation ceremony requiring explicit re-verification | Offline peers cannot learn of a rotation immediately |
| **D3** | **Downgrade to G2-C plaintext test frames** | Version and suite negotiated *inside* the authenticated transcript; a peer offering anything weaker fails the handshake; no plaintext data path exists once the session layer is enabled | A deliberately reverted build can still speak plaintext; that is a build-provenance risk (T17) |
| **D4** | **Replay across sessions or across devices** | Per-direction counters bound into AEAD nonces; random 128-bit session identifiers; epoch binding; durable high-water marks; refuse a reset without a fresh authenticated handshake | Restored backups can present stale state; the store must detect and refuse it (§6.4, §7.1) |
| **D5** | **GATT injection / malformed frames** | Authenticate before parsing expensive structures; strict length/version checks; bounded fuzz-tested parsers; drop, never "best effort" | A nearby attacker can still burn airtime (DoS is not preventable at this layer) |
| **D6** | **Key extraction from a rooted or compromised device** | Keystore-wrapped private keys, non-exportable wrapping key, no plaintext key on disk, no keys in logs or crash reports | A compromised process can use keys even if it cannot extract them; hardware support varies by device |
| **D7** | **Rollback of persisted trust or ratchet state** | AEAD associated data includes record type, version, and peer identity; monotonic generation counter checked on load; mismatch ⇒ fail closed and require re-pairing | An attacker with full storage control can always cause denial of service |
| **D8** | **Silent trust on reconnect** ("it worked last time") | Trust is a stored, explicit record with a timestamp and a verification method; reconnect never re-derives it from traffic | Users habituate to prompts; UX must make unverified peers visibly different |
| **D9** | **Provider/library compromise or abandonment** | Pin exact artifact versions; SBOM; advisory monitoring; no auto-upgrade; documented replacement path | Supply chain risk is reduced, not eliminated (T17) |

Out of scope, stated plainly: protection after endpoint compromise, resistance to a malicious OS, anonymity, and guaranteed delivery.

## 6. G2-D workstreams

Each workstream is separately reviewable and separately gated. None may begin implementation before its design review entry in §10 passes.

### 6.1 Identity and key lifecycle

**Two keys, one identity, one canonical encoding.**

- **Signing identity:** Ed25519 ([RFC 8032](https://www.rfc-editor.org/rfc/rfc8032)). Signs the binding object that contains the exchange key. Its public key is the identity.
- **Exchange static:** X25519 ([RFC 7748](https://www.rfc-editor.org/rfc/rfc7748)). Used by the handshake; must be byte-identical to the key named in the signed binding.
- **Binding object:** version, algorithm identifiers, the exchange public key, a generation counter, an optional validity interval, and the signature. Encoding must be canonical and unambiguous before it is hashed. The candidate container in [IDENTITY-AND-KEYS.md](IDENTITY-AND-KEYS.md) is COSE_Sign1 over deterministic CBOR; that proposal is **not frozen** and must be reviewed for size (§8.2) as well as correctness.
- **Fingerprint:** `SHA-256(domain_separator || version || algorithm_id || canonical_public_key)`, displayed as a grouping-formatted hex string. A fingerprint is an **identifier**, never proof of possession or of a person.
- **No key reuse:** the G2-D identity is scoped to Duman messenger transport. Nothing in `src/crypto/`, the simulator, or the Node reference may share it. Production and test identities never mix.

**Lifecycle states:** `absent → generated (unverified) → in use → rotation-pending → rotated` and, orthogonally, `revoked`. Deletion of the identity is destructive and requires an explicit user action that names the consequence (all trusted peers must re-verify).

**Open questions for the owner:** whether the identity is per-installation or per-device-account; whether a second key type (PQ hybrid, §12 item 5) is designed in now or added by version bump; whether key attestation is ever surfaced in the UI.

### 6.2 Authenticated key exchange

Whatever protocol is selected, these rules are non-negotiable and must appear in the reviewed design:

1. **Transcript binding.** The handshake hash must cover: protocol name and version, suite identifiers, both roles, both static public keys, both binding-object digests, and the G2-C service UUID. Nothing that a relay can rewrite may be *outside* the authenticated transcript and *inside* the message that gets delivered.
2. **Exact key equality.** The peer exchange key used in the handshake must equal, byte for byte, the key named in the peer's verified binding. Mismatch aborts the session; there is no fallback to an unbound key.
3. **No unauthenticated fallback.** If the handshake fails, the connection is not "connected with reduced security" — it is failed, and the UI says so.
4. **Freshness.** Both sides contribute ephemeral material; a handshake replayed from a previous session must not produce a usable session (D4).
5. **Human-verifiable value.** The design must define a short authentication string derived from the transcript, plus the exact UX for comparing it (e.g. a 6–8 digit value or a word list) and for recording the outcome. Signal's safety-number practice is the reference model; the specific derivation must be specified, not improvised.
6. **Bounded work.** Handshake parsing, DH operations, and retransmission are bounded; a malicious peer must not be able to make the phone compute indefinitely.

### 6.3 Peer trust and revocation

- Trust record = pinned identity public key + fingerprint + verification method + timestamp(s) + format version + (optional) local label. Stored encrypted and integrity-protected (§7.1).
- **No TOFU.** A peer with no trust record is *unverified*; content policy for unverified peers is a product decision, but no unverified peer may ever be described as authenticated.
- **Revocation** deletes the record, tears down any bound session, and refuses future sessions until a new ceremony completes.
- **Rotation** is a ceremony: the new key is presented, compared, and confirmed; the old key's revocation is recorded. A silent key change is an attack signal, not an update.
- **Backup/restore** must not silently resurrect revoked trust. Restoring an older store must be detected (§6.4).

### 6.4 Replay and downgrade protection

- **Version negotiation is authenticated.** The version and suite are inputs to the transcript hash; a peer proposing another version fails authentication rather than triggering a fallback path.
- **Counters, not timestamps.** Per-direction 64-bit counters starting at zero for each session, bound into the AEAD nonce. Counters are durable state, not memory state.
- **Session identity.** A random 128-bit session identifier is included in every record's associated data, so records cannot be transplanted between sessions or peers.
- **Bounded reordering.** A sliding window (fixed size, e.g. 64) permits legitimate BLE reordering while rejecting repeats and ancient records. Window size and behaviour at exhaustion must be specified and tested.
- **Fail closed on ambiguity.** An unverifiable counter, a duplicate nonce, or a window underflow is a protocol error that tears down the session — never a warning.

### 6.5 Message encryption and authentication

- **AEAD per record.** ChaCha20-Poly1305 ([RFC 8439](https://www.rfc-editor.org/rfc/rfc8439)) is the candidate; AES-256-GCM is the alternative if hardware acceleration on the target matrix proves decisive. Associated data covers: protocol version, suite, session id, direction, counter, record type, and payload length.
- **Two layers of AEAD are expected:** an inner end-to-end record and an outer per-link record. Keys are derived independently and never reused across layers.
- **Content opacity.** The E2E ciphertext is opaque to relays; only forwarding metadata is visible and mutable, and the design must not pretend otherwise.
- **Padding and size class.** Record sizes leak some information; if padding is added, the padding policy is part of the reviewed design. No claim of traffic-analysis resistance.
- **No plaintext anywhere else:** no plaintext in logs, crash reports, notifications, analytics, or the diagnostics ring that G2-C introduced.

### 6.6 Forward secrecy and session recovery

- **Forward secrecy** comes from per-session ephemeral DH; the design must state which keys are ratcheted and how old message keys are destroyed.
- **Post-compromise security** requires a DH ratchet on reply (Double Ratchet behaviour). If the selected protocol does not provide it, that limitation must be stated in the UI/security documentation rather than glossed.
- **Rekey policy:** rekey after a specified message or byte count, and on a time bound; the thresholds are design parameters requiring review, not implementation details.
- **Session teardown** on: disconnect, activity pause, role change, key rotation, revocation, protocol error, and rekey failure. Teardown zeroizes session keys and ratchet state.
- **Recovery.** If ratchet state and stored counters disagree after a crash, the session is abandoned and a new authenticated handshake is required. There is no "resume anyway" path, and no silent re-derivation from a cached shared secret.

## 7. Storage, key protection, and process boundaries

### 7.1 Where keys live

- Private keys are **generated in the app process** and immediately wrapped, or generated in the Keystore where the algorithm is supported. They are never written unencrypted.
- At rest: AES-256-GCM under a non-exportable Android Keystore key, with the record's associated data binding type, version, and owner. The [Keystore documentation](https://developer.android.com/privacy-and-security/keystore) describes the extraction-prevention property this relies on ("key material never enters the application process"), plus optional hardware binding (TEE/StrongBox) and encrypted key import from API 28.
- If the Keystore key is invalidated or lost, the app **fails closed**: identity reset and re-verification, no plaintext fallback, no silent regeneration.

### 7.2 The API 27 reality check

The G2-C minimum device runs Android 8.1 (API 27). Two facts constrain the design and must be verified on hardware, not assumed:

- **Ed25519 is not a Keystore key algorithm before Android 13 (API 33).** Keystore historically offers RSA, EC and DSA; Ed25519 appears only with newer KeyMint versions. On API 27 an Ed25519 identity must therefore be a software key wrapped by a Keystore AES key — with the honest consequence that the Ed25519 private key is exposed in memory while in use.
- **X25519 is not offered as a Keystore key algorithm** across the supported range, so the exchange key is a wrapped software key regardless of Android version.

Both statements must be confirmed against the device matrix (`KeyProperties` constants, provider behaviour on the specific handsets) and written into the security documentation as *"software-protected, Keystore-wrapped"* rather than *"hardware-backed"*. Claiming hardware backing the platform does not provide is a documentation defect of the same severity as a protocol bug.

### 7.3 Process boundary

Cryptography runs in the Kotlin layer; Dart receives typed results only. The Flutter side must never see private keys, raw shared secrets, or ratchet state — it sees `verified/unverified`, fingerprint strings, and delivery states. This mirrors the G2-C rule that the Dart parser rejects an `authenticated` claim the native layer cannot justify; that rule stays and is extended to the new states.

## 8. BLE-specific engineering constraints

These are the places where a correct protocol meets an unforgiving radio.

### 8.1 Fragmentation budget

G2-C limits, from the [ADR](ADR-G2-C-ANDROID-SECURE-BLE-LINK.md): one application frame ≤ 512 bytes, one reassembled message ≤ 2,048 bytes, ≤ 192 fragments, one in-flight message per direction, 15-second reassembly deadline, ATT default MTU 23 (11 payload bytes per fragment), MTU request to 247 attempted but not required.

### 8.2 Handshake message sizing (worked example, not a commitment)

For a Noise `XX` handshake with X25519 / ChaCha20-Poly1305 / SHA-256:

| Message | Content | Size |
|---|---|---|
| 1 | `e` (32) | 32 bytes |
| 2 | `e` (32) + encrypted static (32+16) + payload tag (16) | 96 bytes + payload |
| 3 | encrypted static (32+16) + payload tag (16) | 64 bytes + payload |

So a 512-byte frame leaves roughly **416 bytes** of authenticated payload in message 2 and **448 bytes** in message 3. A compact binding (32-byte Ed25519 key + 32-byte X25519 key + 64-byte signature + version/generation fields) fits; a certificate chain, QR blob, or verbose encoding does not. Anything larger must be exchanged *after* the handshake, inside the encrypted channel, in separate bounded frames.

At MTU 23, a 512-byte frame is 47 fragments — 47 serialized write-with-response round trips per handshake message. This is the cost the mesh analysis in [07-e2ee-noise-xx.md](../07-e2ee-noise-xx.md) measures; the design must not assume a 247-byte MTU is granted, and must expose handshake progress so a slow link is legible rather than a hang.

### 8.3 Interaction with G2-C lifecycle

- A session is bound to one GATT link and dies with it. There is no session resumption across a disconnect without a fresh handshake in v1.
- The existing foreground-only rule stays: no background session, no silent re-establishment.
- The single-peer server rule stays; a second peer is rejected before it can reach a handshake.

### 8.4 What BLE link security is worth here

LE Secure Connections with **Just Works** provides no MITM protection at all; Numeric Comparison, Passkey Entry and OOB do, because the user authenticates the pairing. This is worth exactly what it says: it authenticates *radios*, once, at the OS level, with a bond that any app on the phone can reuse. It does not bind a Duman peer identity, does not survive a relay, and does not authenticate a message. The correct posture is: allow the OS to encrypt the link if it wants to, and design as if it does not.

## 9. Security test requirements

Test *categories* that must exist before any security claim. Each is a gate input, not a nice-to-have.

1. **Known-answer vectors.** X25519 and Ed25519 from [RFC 7748](https://www.rfc-editor.org/rfc/rfc7748) / [RFC 8032](https://www.rfc-editor.org/rfc/rfc8032), HKDF from [RFC 5869](https://www.rfc-editor.org/rfc/rfc5869), ChaCha20-Poly1305 from [RFC 8439](https://www.rfc-editor.org/rfc/rfc8439), plus the selected protocol's own test vectors.
2. **Handshake negatives.** Wrong static key, tampered transcript, mismatched binding digest, replayed handshake from a previous session, truncated/oversized message, wrong role, and an offered downgrade — all must fail closed with a distinguishable error.
3. **Replay and window tests.** Duplicate record, reordered record inside and outside the window, counter reset attempt, foreign session id, transplanted record from another peer.
4. **State-machine tests.** Every legal transition, every illegal transition, and every teardown path; assertions that no state is reachable without the cryptographic step it depends on.
5. **Crash and restore tests.** Kill the process between state write and send; restore an older store; corrupt one field; lose the Keystore key. Each must fail closed, never resume silently.
6. **Fuzz and resource tests.** Frame parser, binding parser, handshake parser, and fragmentation reassembly under hostile input; CPU/memory/queue bounds under sustained garbage.
7. **Cross-implementation interoperability.** The same vectors and the same negative cases run against both the Dart-facing model and the Kotlin implementation, so the UI can never believe something the native layer did not establish.
8. **Device matrix.** API 27 floor, an API 31+ device, and an API 33+ device, with the Keystore capability probe result recorded per device. JVM-only tests are not device evidence.
9. **Hygiene tests.** No key material, shared secret, or plaintext payload in logs, exception messages, diagnostics, or crash output.
10. **Dependency and SBOM review.** Pinned versions, provenance, licence, advisory history, and transitive inventory for every added artifact.

## 10. Security review gates

No production-security claim may be made until every gate below has recorded evidence. The gates are ordered; skipping one invalidates the later ones.

| Gate | Name | Exit evidence | Blocking? |
|---|---|---|---|
| **D0** | Threat model and scope approval | Reviewed threat register (§5 + T1–T18), explicit non-goals, owner sign-off | Yes |
| **D1** | Protocol selection | Written comparison of Option A/B (or a reviewed alternative), pattern/profile chosen, transcript contents specified, downgrade and replay semantics specified | Yes |
| **D2** | Provider selection | Exact artifact coordinate + version or immutable commit; licence, provenance, transitive SBOM, advisory history; API 27 packaging evidence; published vectors reproduced | Yes |
| **D3** | Identity and key lifecycle | Canonical encoding frozen; fingerprint derivation specified; Keystore capability matrix measured per device; wrap/unwrap and fail-closed behaviour tested; rotation and revocation ceremonies specified and tested | Yes |
| **D4** | Independent security review of the design | External reviewer report on protocol, composition, identity binding, and state machine | **Yes — the hard gate** |
| **D5** | Implementation evidence | All §9 categories executed and recorded, including device matrix and crash/restore | Yes |
| **D6** | Independent review of the implementation | Reviewer examines the actual code and test evidence, not just the design | Yes |
| **D7** | Owner acceptance | Owner signs the evidence set, states the residual risk accepted, and only then may security language be used in the app or docs | Yes |

Until D4 completes, the correct description of any work in this milestone is *"an unreviewed design proposal"*. Until D6 completes, the correct description of any implementation is *"unreviewed code that must not carry real messages"*.

## 11. Phased implementation plan

Sequenced so that the least controversial work is also the work that must exist regardless of the Option A/B decision.

| Phase | Work | Depends on | Deliverable |
|---|---|---|---|
| **D-1** | Freeze the threat model, non-goals, and state vocabulary; record the six axes (§2) in code as a state machine with no crypto | — | Reviewed design note + state machine skeleton + tests |
| **D-2** | Identity and key storage: key generation, wrapping, canonical binding, fingerprint, fail-closed behaviour | D-1 | Keys that exist, are protected, and are testable on API 27 |
| **D-3** | Protocol/library decision: Option A vs B, with D1/D2 evidence | D-2, owner licensing decision | Written selection + pinned provider |
| **D-4** | Link session (L1) over the G2-C transport, plus transcript binding and SAS | D-3 | Mutual authentication proven on two devices, negative tests |
| **D-5** | End-to-end session (L2): ratchet, replay window, counters, rekey, teardown | D-4 | E2E confidentiality and integrity across a relay, crash/restore tests |
| **D-6** | Trust UX: verification ceremony, pinned records, revocation, rotation, unverified-peer labelling | D-4 | A UI that cannot claim more than the crypto established |
| **D-7** | Hardening and review: fuzz, device matrix, SBOM, independent review | D-5, D-6 | The D5–D7 evidence set |

No phase is authorized by this document. Each begins only when its gate evidence exists.

## 12. Risks and open decisions

| # | Open decision | Owner or reviewer | Why it matters |
|---|---|---|---|
| 1 | Accept AGPL-3.0 (libsignal) or not | Owner | Determines Option A vs B, and therefore the whole protocol path |
| 2 | Accept the Noise-Java provenance risk, or fund a pinned/audited implementation | Owner + reviewer | Option B has no shippable Noise implementation today |
| 3 | Frozen identity binding encoding (COSE/CBOR vs a minimal fixed layout) | Reviewer | Must satisfy §6.1 *and* the 448-byte handshake payload budget |
| 4 | Product policy for unverified peers (block, or warn-and-permit) | Owner | Security expectations must match the UI's claims |
| 5 | PQ hybrid in v1 or v2 (PQXDH-style) | Owner + reviewer | Design it in now, or version-bump later; adding it late is a breaking identity change |
| 6 | Group messaging timeline (MLS) | Owner | If groups are near, L2 should be chosen with that in mind |
| 7 | Session resumption across reconnects | Reviewer | v1 refuses it; convenience pressure will arrive quickly |

Standing risks, unchanged by this plan: the mesh cannot guarantee delivery; a relay can always drop traffic; endpoint compromise defeats message protection; radio metadata is observable; there is no independent review of anything yet.

## 13. What must never be claimed

- "G2-C is secure." It is a validated transport for test payloads.
- "The BLE link is encrypted, therefore messages are private." Link encryption protects a hop from a passive radio attacker at best, and Just Works pairing provides no MITM protection at all.
- "We use Noise/Ed25519/X25519, so it is secure." Naming primitives is not evidence; composition, state handling, and implementation review are.
- "The design was reviewed" before D4, or "the code was reviewed" before D6.
- "Production-ready", "end-to-end encrypted", or "verified peer" in any user-facing string until D7 is signed.

## 14. References

- Noise Protocol Framework, revision 34 — <https://noiseprotocol.org/noise.html>
- Noise Explorer (pattern verification) — <https://noiseexplorer.com/>
- X3DH — <https://signal.org/docs/specifications/x3dh/>
- Double Ratchet — <https://signal.org/docs/specifications/doubleratchet/>
- PQXDH, revision 3 — <https://signal.org/docs/specifications/pqxdh/>
- MLS, RFC 9420 — <https://www.rfc-editor.org/rfc/rfc9420>
- X25519, RFC 7748 — <https://www.rfc-editor.org/rfc/rfc7748>; Ed25519, RFC 8032 — <https://www.rfc-editor.org/rfc/rfc8032>
- HKDF, RFC 5869 — <https://www.rfc-editor.org/rfc/rfc5869>; ChaCha20-Poly1305, RFC 8439 — <https://www.rfc-editor.org/rfc/rfc8439>
- Android Keystore system — <https://developer.android.com/privacy-and-security/keystore>
- libsignal — <https://github.com/signalapp/libsignal> (AGPL-3.0); `org.signal:libsignal-client` on Maven Central
- Tink — <https://github.com/tink-crypto/tink-java> (Apache-2.0); `com.google.crypto.tink:tink-android` 1.24.0
- In-repository: [SECURITY-ARCHITECTURE.md](SECURITY-ARCHITECTURE.md), [THREAT-MODEL.md](THREAT-MODEL.md), [IDENTITY-AND-KEYS.md](IDENTITY-AND-KEYS.md), [PROTOCOL-IMPLEMENTATION-SPEC.md](PROTOCOL-IMPLEMENTATION-SPEC.md), [PROTOCOL-TEST-PLAN.md](PROTOCOL-TEST-PLAN.md), [PACKET-FORMAT.md](PACKET-FORMAT.md), [07-e2ee-noise-xx.md](../07-e2ee-noise-xx.md)
