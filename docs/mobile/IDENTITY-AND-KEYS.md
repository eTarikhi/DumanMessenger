# Identity and key binding — proposal

**Status:** Proposed design for owner/security review; not an approved wire format. No identity, QR, handshake, key-storage, or cryptographic code was changed. Evidence is for source snapshot `a1f1916981c2244a2f8664573b66afbd5a2659b4` (2026-11-05). See [security architecture](SECURITY-ARCHITECTURE.md) and [security review](../../reports/mobile/SECURITY-REVIEW.md).

## 1. Current reference flow and gap

Source inspected: `src/crypto/identity.ts`, `src/crypto/session.ts`, `src/crypto/noise-xx.ts`, `src/crypto/sas.ts`, and the related session/recovery tests.

| Step | Current TypeScript reference behavior | Security consequence |
|---|---|---|
| Key generation | `generateIdentity` independently generates Ed25519 signing and X25519 exchange keypairs. `nodeId = SHA-256(Ed25519 public key)`. | The identity and Noise static keys are different keys with no signed binding. Ordinary JS buffers are not a mobile key store. |
| Contact QR | Encodes Ed25519 public key and an eight-character `identitySas`; it carries no signed X25519 binding. | The QR authenticates/identifies a signing-key fingerprint only; it does not itself authenticate the Noise static key. Eight characters from a 32-symbol alphabet are a 40-bit comparison aid, not a public-key certificate. |
| Handshake | Noise XX uses the separate X25519 static key. `sessionPrologueFromQr` hashes the Ed25519 keys into context, but a prologue is not a signature binding those keys to the Noise statics. | Noise authenticates the participating X25519 statics at the handshake layer, not their ownership by the scanned Ed25519 identity. The handshake SAS is distinct from the QR fingerprint. Manual comparison can authenticate a particular transcript, but it is not a persistent signed key binding. |
| Peer identifier | `DumanSession.peerExchangeNodeId` hashes the peer X25519 key; `Identity.nodeId` hashes the Ed25519 key. | “Node ID” has two meanings; callers must not treat them as interchangeable. Use an explicit device identity ID versus routing ID. |
| Message sender | `DumanSession.send` puts the Ed25519 public key in encrypted packet content. It does not sign the content with that key; `receive` does not validate it against a signed binding. | Presence of a public key inside an encrypted payload is not a proof that it is the session peer's identity key. Session encryption and contact identity are separate claims. |
| Handle claim | `signHandleClaim`/`verifyHandleClaim` sign a handle, Ed-derived node ID, and timestamp. | This claim is not an Ed-to-X binding, account certificate, uniqueness proof, or identity lifecycle. It is not used to verify the Noise static. |
| Trust state | The session has `handshaking`, `unverified`, `verified`, `failed`, and `wiped` phases. Messages can flow while `unverified`; `confirmSas` promotes the session after a human compares the handshake SAS. | The mobile product must explicitly decide whether to permit unverified messaging and must not label encryption alone as verified identity. |

## 2. Proposed initial identity model

### Device, not account

For the first one-to-one release, use one independently generated Ed25519 identity root per device/install and one bound X25519 static key for its Noise identity. The display name is local and user-editable. A `device_id` may be a domain-separated fingerprint such as `SHA-256("DumanDevice/v1" || ed25519_public_key)`; the precise encoding is an application decision. Do not use this stable ID as an advertised route address by default.

There is no account service, central CA, global username registry, or approved user-root/multi-device scheme in this repository. If one person has two installations, contacts verify them separately until an account-root design is reviewed. Do not copy private keys between phones as a shortcut.

### Signed binding object (illustrative, not frozen)

Candidate envelope: QR carries the 32-byte Ed25519 public key plus a COSE_Sign1 object. The COSE payload is deterministic CBOR and could contain a structure like:

```text
DeviceBindingV1 = {
  version: 1,
  device_id: SHA-256("DumanDevice/v1" || Ed25519_public_key),
  exchange_static_key: X25519_public_key,  // exactly 32 bytes
  generation: unsigned integer,
  issued_at: timestamp,
  not_before: timestamp,
  not_after: timestamp,
  previous_binding_digest: 32-byte digest or null,
  protocol_suite: "Noise_XX_25519_ChaChaPoly_SHA256"
}
```

The signing key is the Ed25519 public key supplied alongside the signed object. The COSE protected headers pin EdDSA and a versioned Duman binding content type; the payload uses deterministic CBOR. The exact fields, time units, hash domain, identifier, content type, digest, QR URI, and suite are unapproved application schema. Do not implement the pseudocode as a format without owner and independent security review.

Standards references: Ed25519 is specified in [RFC 8032](https://www.rfc-editor.org/rfc/rfc8032); X25519 in [RFC 7748](https://www.rfc-editor.org/rfc/rfc7748); COSE_Sign1 structures in [RFC 9052](https://www.rfc-editor.org/rfc/rfc9052), COSE EdDSA in [RFC 9053](https://www.rfc-editor.org/rfc/rfc9053), and deterministic CBOR in [RFC 8949 §4.2](https://www.rfc-editor.org/rfc/rfc8949#section-4.2). These standards define encodings/algorithms, not this application's device identity semantics. Select maintained implementations; do not write a custom signature format or key parser.

## 3. Verification rules

A mobile verifier should perform these checks in order, before associating a contact or starting a session:

1. **Bound input:** cap the QR/URI and CBOR/COSE byte sizes before allocation; reject trailing bytes, duplicate CBOR map keys, non-deterministic encodings if canonical form is required, missing fields, wrong types, and unknown critical fields.
2. **Version and algorithm:** accept only explicitly supported schema versions and pinned algorithms/suites. Reject unknown or weaker suites; no algorithm negotiation fallback to an unbound legacy mode.
3. **Key shape and validity:** require exact public-key lengths and use the selected crypto provider's strict key/signature validation. Reject invalid Ed25519 encodings/signatures and invalid/low-order X25519 input according to the chosen implementation; reject an all-zero DH result. Do not implement curve checks by hand.
4. **Signature and subject:** verify the COSE signature with the Ed25519 public key; recompute `device_id`; check that the signed subject and supplied key agree. A valid signature binds a key to another key, not a real-world person.
5. **Validity and generation:** validate time bounds according to the owner's clock policy; compare the signed generation and predecessor digest with pinned local state. Reject rollback, same-generation key conflict, forked chain, and unsupported predecessor gaps unless a reviewed recovery flow handles them.
6. **Noise handshake:** bind protocol version, ordered device IDs, exact signed-binding digests, roles, and suite into a domain-separated Noise prologue. When the handshake completes, require the remote Noise static X25519 key to equal the signed binding's exchange key. A mismatch is a terminal identity/session error.
7. **Human confirmation:** display a fresh handshake SAS for first contact or sensitive key changes. A valid Ed signature does not establish that the peer is the person the user intended to contact; use an independent comparison when that property matters.
8. **Pin atomically:** persist the binding chain, high-water generation, verification state, and peer mapping durably before trusting later sessions. Never silently convert `unverified` to `verified` after a successful handshake or after restoring an old backup.

A QR fingerprint and a handshake SAS are not interchangeable. The QR fingerprint identifies the invited Ed25519 public key. The handshake SAS is computed for one handshake transcript. The current implementation has both values; the current QR does not carry a signed exchange-key binding.

## 4. Lifecycle and recovery proposal

| Event | Proposed behavior (policy values remain TBD) |
|---|---|
| First install | Generate keys through the selected provider; keep private operations behind a platform/crypto-provider API. Create and sign generation 1 binding. Do not expose private bytes to Flutter widgets, logs, clipboard, or ordinary app state. |
| QR invite | Include the signed binding and public signing key; display a full/adequate fingerprint and fresh handshake SAS. A QR scanned from an untrusted channel creates an unverified contact until the appropriate human check. Verify QR size and scanner interoperability on actual devices. |
| Routine X25519 static rotation | Sign a new binding under the same Ed25519 root with generation `n+1` and previous binding digest; enforce monotonic generation and expiry. Notify contacts when they meet; require explicit approval or a predetermined safe policy. Never accept a lower generation merely because the old session still works. |
| Ed25519 root rotation | Require an old-root cross-signature to a new root plus an explicit user re-verification policy. If the old root may be compromised or is unavailable, a cross-signature cannot establish safety; require a new out-of-band QR/SAS and mark the contact changed. |
| Revocation | A signed revocation can be relayed and recorded; an offline peer cannot learn it until it receives the record. A root-key compromise can invalidate the authority used for its own revocation. Do not claim instant/global revocation in an offline mesh. |
| Expiry | Expired bindings block new authenticated sessions or require a reviewed refresh path. Offline wall clocks can be wrong or rolled back; store generation high-water state and explain clock uncertainty. Exact lifetimes and grace windows need owner approval. |
| Backup/restore | Encrypted backup, key export, device migration, and rollback semantics are not selected. Restoring stale ratchet or generation state must not reuse a send key/nonce or silently reduce the pinned generation. Re-verify if monotonic state cannot be trusted. |
| Lost/reinstalled device | Treat a new installation as a new device identity unless a reviewed recovery/account-root mechanism proves otherwise. Do not derive private keys from a display name, phone number, or weak recovery code. |
| Panic wipe/uninstall | Define exactly which keys, bindings, ratchets, queues, databases, OS backups, logs, and crash reports are erased. JavaScript/Dart memory overwrites are not proof of physical erasure. |

No universal validity period or revocation authority is prescribed here. The mesh has no central always-online authority or trusted clock in evidence.

## 5. Platform storage and key handling

The selected implementation must expose operations (`generate`, `sign`, `agree`, `delete`) rather than return long-lived private-key bytes to UI/application code wherever possible. Android Keystore/StrongBox and Apple Keychain/Secure Enclave support must be confirmed for the actual Ed25519/X25519 algorithms and OS/device versions. If a provider must keep a private key in software memory or an encrypted file, document that residual risk and obtain owner approval; do not describe it as hardware-backed.

Key requirements include:

- Separate signing identity, key-agreement, session/ratchet, and per-link keys; enforce protocol/domain separation through the selected standard/provider.
- Never reuse an X25519 private key as an Ed25519 key or use one public-key fingerprint as both the device identity and routing address without an approved reason.
- Reject nonce/counter reuse; persist required state transactionally with ciphertext before send.
- Avoid plaintext/private-key diagnostics and clipboard/export flows; keep synthetic fixtures in tests.
- Handle key loss, process death, restore, rollback, device clock change, and database corruption with explicit states and user-facing recovery—not silent fallback.

## 6. Migration from the current reference

The existing QR contains Ed25519 public key plus eight-character identity SAS only. Existing stored/in-flight contacts (if any in a future app) therefore cannot be assumed to have a verified signed X25519 binding. Do not backfill trust by hashing the old X25519 key, matching a display name, or accepting the old QR as a v2 certificate.

Safe migration proposal:

1. Keep v1/reference parsing separate from any v2 parser; do not alter existing golden vectors or reinterpret existing bytes.
2. Label legacy contacts `legacy/unbound`; do not claim that their X25519 static belongs to their Ed25519 key.
3. If both private keys are still safely controlled on the same device, create a signed binding only after explicit local continuity checks; require the peer to refresh its invite or re-verify before promoting trust.
4. If the old signing key is lost, create a new device identity and verify it out of band. Never silently recover with an unauthenticated fallback.
5. Add versioned vectors and negative tests for v2 only after owner approval; preserve old vectors as historical compatibility fixtures unless an explicit versioned migration is approved.

The source-only G1 Flutter shell has no identity or persistent contact database, so no actual migration has run.

## 7. Open owner decisions

- Device identity only, or introduce a user/account root and multi-device certificates now?
- Approve COSE_Sign1 plus deterministic CBOR as a candidate binding container? Approve the exact payload fields, context, key IDs, versioning, suites, expiry, and revocation semantics?
- What cryptographic provider can be maintained across Dart/Kotlin/Swift and validated on the minimum supported phones?
- What must first-contact verification prove, and may a user send unverified messages?
- How are stable device fingerprints hidden from routing metadata? What is the rotation and contact-update UX?
- What key backup/recovery/rollback/deletion guarantees are required?

These decisions are prerequisites, not implied answers. See [PROTOCOL-TEST-PLAN.md](PROTOCOL-TEST-PLAN.md) for the tests that must gate an implementation.
