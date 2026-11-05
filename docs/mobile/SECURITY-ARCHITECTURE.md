# Proposed mobile security architecture

**Status:** Design proposal for owner/security review. It is not an approved protocol, wire specification, security claim, or implementation. **No protocol or packet-format code has been changed.**

**Evidence snapshot:** `a1f1916981c2244a2f8664573b66afbd5a2659b4` (empty checkpoint over `bdf719cf88205f944187cb79b8288264a56c13bd`), reviewed 2026-11-05. The full TypeScript baseline is 517/527; ten tests time out at the unchanged 5,000 ms limit. There is no Flutter/native application or device evidence. See [security review](../../reports/mobile/SECURITY-REVIEW.md), [threat model](THREAT-MODEL.md), and [implementation status](../../reports/mobile/IMPLEMENTATION-STATUS.md).

## 1. Security goals and limits

The first production messaging slice should provide:

1. A device signing identity cryptographically bound to the X25519 static key actually used by the authenticated handshake.
2. Explicit distinction among a syntactically valid key binding, a cryptographically established session, and a human-verified contact.
3. End-to-end confidentiality and peer/session authentication supplied by a maintained, reviewed protocol implementation—not by the simulator or this Node reference.
4. Opaque end-to-end ciphertext that a relay can forward without learning message plaintext or being able to alter it undetectably.
5. Bounded, replay-resistant, per-neighbor transport frames and bounded forwarding/reassembly work.
6. Crash-safe key, ratchet, replay, outbox, and inbox state, with honest recovery/rollback behavior.

This design does **not** claim anonymity, truthful path/hop counts, delivery against a malicious relay, offline revocation freshness, protection after endpoint compromise, OS-level secure-hardware support for every algorithm, or verified BLE/background behavior. Encryption alone does not authenticate a human identity. A relay can still observe timing, packet size class, traffic volume, and routing tokens, and can drop, delay, or selectively forward traffic.

## 2. Proposed identity and trust model

### 2.1 Device identity versus person/account

For the initial one-to-one slice, treat each installation/device as an independently verified device identity:

- An Ed25519 public key is the device's long-lived signing identity key. Its fingerprint is a device-key identifier, not a global account, username, or proof of a person's legal identity.
- A separate X25519 static public key is used by the Noise handshake. A signature made by the Ed25519 key binds the exact X25519 public key, protocol version, generation, and validity interval.
- A display name or handle is local presentation data. A signed handle claim may establish that a device key made a claim; it does not establish a unique real-world name, account, or exchange key.
- Until a reviewed multi-device/account-root design exists, two devices owned by one person are two contacts. Do not silently equate them or copy one device's private keys to another.
- Do not use the stable identity fingerprint as a public routing address by default. Routing identifiers and destination-token privacy are separate, unresolved protocol decisions.

See [IDENTITY-AND-KEYS.md](IDENTITY-AND-KEYS.md) for the proposed binding schema, verification, lifecycle, and migration rules.

### 2.2 First contact and later sessions

1. **Invite:** a QR/contact invite contains a versioned, signed device binding and the public signing key needed to verify it. The human-readable QR fingerprint is a comparison aid, not a substitute for signature verification. The exact encoding and QR-size budget remain to be tested.
2. **Validate:** parse strictly; reject unsupported versions/suites, malformed or non-canonical encodings, invalid signatures, expired bindings, and unacceptable generations before opening a session.
3. **Handshake:** use a maintained Noise implementation with a pinned protocol suite. Bind the protocol context, ordered peer device fingerprints, and signed-binding digests into the Noise prologue. After the handshake, verify that the remote static X25519 key is byte-for-byte the key in the verified binding. Reject a mismatch; never fall back to an unbound key.
4. **Human verification:** show a fresh transcript-derived short authentication string (SAS) and compare it over an independent channel for first contact or sensitive re-verification. A QR fingerprint SAS and a handshake SAS answer different questions. A valid signature proves possession of a signing key; it does not prove who controls that key.
5. **Trust state:** record `unknown`, `binding-valid/unverified`, `verified`, `rotation-pending`, `expired`, `revoked`, or `blocked` per device. Only the explicit verification action promotes the contact to `verified`; a successful handshake or a matching display name alone does not.
6. **Messaging policy:** default to withholding sensitive content until the user has verified first contact. If the product elects to permit explicit unverified/TOFU messaging, label it persistently and never report it as identity-authenticated. This UX/policy is an owner decision.

The current TypeScript reference allows encrypted messages while a session is `unverified`. That is a reference behavior, not an approved mobile policy.

## 3. Cryptographic implementation boundary

### Candidate composition—not yet selected

- Ed25519 signatures: [RFC 8032](https://www.rfc-editor.org/rfc/rfc8032).
- X25519 key agreement: [RFC 7748](https://www.rfc-editor.org/rfc/rfc7748).
- Noise handshake pattern and suite: [Noise Protocol Framework](https://noiseprotocol.org/noise.html); `Noise_XX_25519_ChaChaPoly_SHA256` is the current TypeScript reference suite, not yet approved for mobile.
- Candidate signed-binding container: COSE_Sign1 structures ([RFC 9052](https://www.rfc-editor.org/rfc/rfc9052)) with EdDSA algorithm support ([RFC 9053](https://www.rfc-editor.org/rfc/rfc9053)), over a deterministic-CBOR payload ([RFC 8949, §4.2](https://www.rfc-editor.org/rfc/rfc8949#section-4.2)). The binding fields and COSE content type are application-specific and require review; they are not a standard Duman identity schema.

These specifications do not select or endorse a Dart/Kotlin/Swift package. Before implementation, evaluate maintained providers and bindings for algorithm support, strict key validation, platform compatibility, security history, license, update cadence, reproducible builds, and independent review. Do not hand-roll signature, DH, KDF, AEAD, ratchet, COSE, or Noise code, and do not ship `src/crypto/` as the mobile provider.

Android Keystore/StrongBox and Apple Keychain/Secure Enclave capabilities must be tested for the chosen algorithms on the supported OS/device matrix. Do not assume both platforms expose Ed25519 and X25519 private-key operations in secure hardware. The design must document whether keys are hardware-backed, software-protected, or unavailable on a device; no key export or “secure enclave” claim until verified.

## 4. Two-layer packet and forwarding model

```text
Sender device
  plaintext + authenticated conversation context
        |
        v
  reviewed end-to-end messaging provider
  [ratchet state, replay state, E2E ciphertext]
        |             immutable opaque bytes
        +----------------------------------------------+
                                                       v
  route token + packet ID + bounded TTL/hop + fragment metadata
  [mutable forwarding envelope; no plaintext or stable user handle]
        |
        v
  per-neighbor authenticated record/frame (fresh link counter/tag)
        |
   BLE / other approved transport
        |
   Relay A -- checks neighbor record, bounds and dedupe;
        |      may update forwarding envelope, not E2E bytes
        v
   Relay B -- creates a new per-neighbor authenticated frame
        |
        v
   Recipient -- bounded reassembly -> E2E verification/decryption
              -> atomic replay/ratchet/inbox commit -> authenticated ACK
```

The outer envelope is not end-to-end authenticated as an immutable whole because honest relays must update it. A per-hop authenticator proves only that a frame came from the immediate authenticated neighbor and was not altered in transit on that link. It does **not** make a relay honest, authenticate the whole route, or prevent a relay from dropping, replaying, delaying, or rewriting fields when it creates the next hop's frame. The E2E provider must authenticate the original ciphertext and its relevant inner context independently.

### Forwarding fields and limitations

- A stable random packet ID supports duplicate suppression; it is visible and correlates copies of that packet across relays. Do not use a sender counter, contact name, or raw identity key as the public ID.
- A destination token is visible to relays. The current eight-byte `SHA-256(signingPublicKey)` prefix is also a prefix of the advertised node ID; it is not identity hiding. A rotating/opaque token may reduce linkability, but its derivation, advertisement, lookup, and privacy properties are unresolved. Do not label a placeholder token “anonymous.”
- TTL and hop count are bounded routing hints, not trustworthy path evidence. Honest nodes must enforce a configured hard cap, reject out-of-range encodings, never increase a received remaining budget, and deduplicate independently. Because an authorized relay can rewrite mutable metadata, a recipient cannot infer a truthful end-to-end hop count from a mutable field. If a cryptographically enforceable global hop budget is required, design and review a verifiable forwarding-budget mechanism separately; do not imply that a per-hop MAC provides it.
- Control traffic that must be readable by relays must be explicitly specified as such. Do not label routing/control fields “end-to-end encrypted.”

The candidate field-level design, ACK meanings, fragmentation rules, and size-limit decisions are in [PACKET-FORMAT.md](PACKET-FORMAT.md). That document is a proposal, not a frozen frame layout.

## 5. Persistence, replay, and interruption requirements

- Keep a serialized actor per peer/session so concurrent UI, radio, and background events cannot race one ratchet.
- Persist an outgoing ciphertext and its reserved protocol sequence/nonce before transmission or retry. Retries resend the same logical ciphertext and packet ID; they must not reuse a nonce for different plaintext or advance state twice.
- In one durable transaction, authenticate/decrypt a received message, advance receive/replay state, deduplicate, and commit the inbox item. An unauthenticated packet must not consume a ratchet key.
- Bound out-of-order/skipped-key caches, replay tables, pending frames, fragment count/bytes, queue depth, and expiry. Reject before attacker-controlled lengths cause large allocations.
- Define what happens on process death, disk-full, corrupt state, app reinstall, backup restore, and rollback. If the selected platform storage cannot guarantee monotonic state, surface re-verification/recovery rather than silently resuming an old ratchet.
- Do not log private key bytes, plaintext, contact identifiers, full routing tokens, or reusable session secrets. Test logs use synthetic identities and payloads.

## 6. Rotation and revocation summary

A device may rotate its X25519 static key under the same Ed25519 identity by issuing a new signed binding with a strictly higher generation and a digest of the previous binding. Peers reject a lower generation, same-generation conflict, invalid predecessor, expired binding, or unsupported suite. A root-signing-key change needs an explicit old-root cross-signature and/or new out-of-band verification; a signature from a compromised old root cannot restore trust. Signed revocation can propagate when devices meet, but offline peers cannot know about a revocation they have not received. Expiry is also limited by untrusted/offline wall clocks and storage rollback. Policy durations and recovery UX remain owner decisions.

## 7. Review gates and open decisions

No packet format, algorithm/provider, time validity, or UX policy is approved by this document. Before protocol implementation, the owner/security reviewer must decide:

1. Per-device identity versus a separate user/account root; contact and multi-device semantics.
2. Whether COSE_Sign1 plus deterministic CBOR is the binding format, and the exact schema/version/suite policy.
3. Provider/library choices for Noise, E2E messaging/ratchet, COSE, and platform key storage; validate actual Android/iOS secure-hardware support.
4. First-contact verification UX and whether any unverified sending is permitted.
5. Identity fingerprint exposure, destination-token construction, routing metadata, and the residual traffic-analysis threat.
6. Mutable TTL/hop semantics, maximum values, whether truthful global path limits are required, ACK guarantees, and fragmentation/size bounds.
7. Rotation/revocation, clock rollback, backup/restore, account recovery, and data deletion policy.
8. Independent protocol review and the simulator-versus-device acceptance evidence in [PROTOCOL-TEST-PLAN.md](PROTOCOL-TEST-PLAN.md).

**Stop condition:** no production crypto, handshake, QR, packet, forwarding, ratchet, or fixture/vector changes until these decisions are reviewed and explicitly authorized. Existing simulator tests, routing defaults, 5,000 ms timeout, and golden-vector semantics remain unchanged.

## 8. Source evidence and references

Repository findings are from `src/crypto/identity.ts`, `session.ts`, `noise-xx.ts`, `packet.ts`, `ratchet.ts`, `sas.ts`, and `src/simulation.ts` on the snapshot above. See [SECURITY-REVIEW.md](../../reports/mobile/SECURITY-REVIEW.md) for detailed findings and provenance. Simulator and device/toolchain evidence are separated in [PERFORMANCE-INVESTIGATION.md](../../reports/mobile/PERFORMANCE-INVESTIGATION.md) and [TOOLCHAIN-REQUIREMENTS.md](../../reports/mobile/TOOLCHAIN-REQUIREMENTS.md).
