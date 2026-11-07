# Mobile messaging threat model

**Status:** Proposed threat model for owner/security review; not a certification or implementation report. No protocol, packet, or application code changed. Evidence reviewed at `a1f1916981c2244a2f8664573b66afbd5a2659b4` on 2026-11-05. Related documents: [security architecture](SECURITY-ARCHITECTURE.md), [identity and keys](IDENTITY-AND-KEYS.md), [packet format](PACKET-FORMAT.md), [protocol test plan](PROTOCOL-TEST-PLAN.md), [security review](../../reports/mobile/SECURITY-REVIEW.md).

## 1. System under consideration

A future Flutter messenger for Android and iOS, operating over an intermittent, offline-capable mesh. The first useful slice is one-to-one text messaging with a verified device contact, maintained cryptographic provider, durable ratchet/replay state, and a platform transport. The repository now has a source-only Flutter UI shell; it has no native transport, mobile key store, messaging/identity implementation, or real-device protocol evidence. `src/` is a browser simulator/Node reference; `sim/mesh_sim/` is a pure-Dart simulator. Neither the simulators nor the UI shell represent a production handset.

Proposed security boundary:

```text
Flutter UI / app state / local database
                  |
       reviewed crypto-provider API
      [device identity, session, ratchet]
                  |
       typed native transport boundary
                  |
   untrusted BLE/radio / other relay links
                  |
       potentially malicious relays
                  |
   reviewed crypto-provider API on recipient
```

End-to-end content is to remain opaque to relays. Forwarding metadata is mutable and only locally/link authenticated. A relay's ability to receive a valid frame is not evidence that the relay is trusted.

## 2. Assets and security objectives

| Asset | Objective |
|---|---|
| Ed25519 device signing private key and X25519 exchange private key | Prevent extraction, misuse, substitution, and accidental reuse; bind the exchange key to the identity with a signed, versioned binding. |
| Contact pin, binding generation, and verification state | Prevent identity downgrade, silent key replacement, rollback, and misleading “verified” UI. |
| E2E session/ratchet keys, counters, skipped-key cache | Prevent nonce/key reuse, unauthorized decryption, replay, and state desynchronization; erase or invalidate state on supported events. |
| Message plaintext, attachment content, and authenticated context | Confidentiality/integrity from relays and unauthorized contacts; deliver at most once at the application layer under retries. |
| Inbox/outbox, replay/dedup cache, fragment buffers | Atomicity, bounded storage/memory, crash safety, and idempotency. |
| Device/user labels and contact graph | Avoid false claims about real-world identity; minimize public exposure and contact misbinding. |
| Routing tokens, packet IDs, sizes, timing, neighbor graph | Minimize metadata exposure; document that relays can observe and correlate some traffic. |
| Battery, CPU, radio time, memory, storage | Bound unauthenticated and malicious-relay resource consumption. |
| Protocol versions, provider dependencies, build artifacts | Prevent downgrade, supply-chain compromise, and incompatible cross-platform behavior. |

## 3. Principals and attacker capabilities

### Principals

- **Sender/recipient device:** runs the app and selected crypto provider; may be honest, offline, outdated, or compromised.
- **Contact owner:** human who scans a QR and may or may not compare a fresh SAS out of band.
- **Relay/neighbor:** can forward opaque packets but is not assumed honest. It may be an unknown device, a previous contact, or an attacker-controlled node.
- **Radio observer:** can listen, record, inject, replay, delay, or jam traffic within reach.
- **Local attacker:** may access a locked/unlocked phone, backups, logs, crash reports, or app files depending on permissions and OS state.
- **Build/dependency adversary:** may compromise package release, transitive dependency, build machine, or signing pipeline.

### Attacker capabilities considered

An attacker may control one or more relays; observe and replay packets; alter visible routing/fragment fields; send malformed, oversized, duplicate, reordered, or high-rate input; suppress or delay messages/ACKs; advertise a substituted QR/contact; run a man-in-the-middle handshake; induce disconnects/retries; exploit clock rollback or stale backup; and exploit parsing/provider/platform inconsistencies. A compromised endpoint may reveal its current plaintext, keys, or future messages accessible to that endpoint.

No assumption is made that an offline peer has fresh revocation information, a trusted wall clock, a stable route, or continuous background execution. Users may compare a short SAS incorrectly; a valid key signature does not prove a person's civil identity.

## 4. Trust boundaries

1. **Contact bootstrap:** QR/URI and local contact input are attacker-controlled until strict parse, signature verification, binding checks, and any required human comparison complete.
2. **Identity-to-session boundary:** the Ed25519 signing identity and X25519 Noise static must be cryptographically bound. Current reference code does not provide that signed binding.
3. **UI/application to crypto provider:** only typed operations and validated results cross this boundary. UI labels and `from` fields are not cryptographic proof.
4. **App to OS/key storage:** OS APIs and hardware support vary; private-key handling, backups, lifecycle, and erasure need platform-specific verification.
5. **Radio/native adapter:** native events and bytes are untrusted; length/version/capability checks happen before decoding/state changes.
6. **Relay to E2E message:** link authentication protects a hop only; relays can alter outer routing metadata and deny service. Only the selected E2E protocol protects content end to end.
7. **Persistent storage/restore:** encrypted storage alone does not prevent rollback or atomicity failures; replay/ratchet state and inbox/outbox need crash-safe transactions.
8. **Simulation versus device:** simulation evidence tests modeled behavior, not Android/iOS permission, background, radio, storage, or platform cryptography.

## 5. Threat register

| ID / severity | Threat | Proposed mitigation / required test | Residual risk |
|---|---|---|---|
| **T1 Critical** | Ed25519 identity substituted or associated with an attacker's X25519 static key | Signed, versioned Ed-to-X binding; include binding digest in handshake context; require exact equality between verified X key and Noise remote static. Negative key-swap tests. | A valid key binding does not establish a real-world person; QR/SAS channel can still be deceived. |
| **T2 High** | QR tampering, malformed key, unknown algorithm, duplicate/non-canonical CBOR, parser confusion | Strict bounded COSE/CBOR parser from maintained implementation; exact key lengths; allowlist versions/algorithms; reject unknown critical fields and invalid curve points. Fuzz parser. | Parser/provider bugs and QR scanner differences remain possible. |
| **T3 High** | Active MITM during first contact or contact re-pairing | Noise transcript bound to peer bindings and roles; compare fresh handshake SAS out of band; persist explicit verification state; mismatch is terminal. | Human comparison can fail; short SAS has limited entropy; no central CA is available. |
| **T4 High** | Session downgrade or legacy/unbound fallback | Strict protocol version/suite allowlist, pinned binding generation, no silent v1 fallback, versioned migration and negative tests. | A user may explicitly approve an unsafe legacy workflow unless UI policy blocks it. |
| **T5 High** | Replay of an old binding or rollback to a compromised/retired key | Signed generation and predecessor digest, local high-water state, persistent replay tracking, change warning/reverification. Test stale backup/restore and clock rollback. | Offline devices may miss rotation/revocation; storage rollback may defeat local high-water state. |
| **T6 High** | E2E packet forgery, ciphertext alteration, or cross-conversation transplant | Use a reviewed E2E protocol/provider with authenticated peer/session and context; do not trust clear `from`/route fields. Alteration and wrong-context tests. | Endpoint compromise or provider flaw can defeat protection. |
| **T7 High** | TTL/hop/header tampering, reset, or dishonest path claim | Outer envelope is mutable; authenticate each link frame, cap local TTL/hop, preserve E2E bytes, dedupe. Test attempted inflation/reset and document that claims are not proof. | A malicious relay can rewrite mutable fields, fork traffic, or lie about the path. No global hop bound is guaranteed without a separate proof design. |
| **T8 High** | Replay/duplicate delivery and ratchet desynchronization after loss/retry | Stable packet/message IDs, bounded replay windows, serialized per-peer actor, durable send/receive transactions, idempotent ACK handling. Test reorder, retry, crash, duplicate, and state divergence. | Long offline gaps or lost state may require safe re-establishment and human re-verification. |
| **T9 High** | Malicious relay drops, delays, selectively forwards, forges delivery reports | Separate link/relay/recipient ACK semantics; end-to-end authenticated ACK after defined commit; bounded retries and truthful UI states. Test unavailable/malicious relays. | Availability cannot be guaranteed over an adversarial/offline mesh. A relay can always drop traffic. |
| **T10 High** | Oversized/malformed frames or fragment exhaustion cause memory/CPU/storage denial of service | Authenticate link record before expensive work; strict parser bounds; pre-allocation caps; per-peer/global queue, fragment, rate, and time quotas; fuzz and soak tests. | A nearby radio attacker can still consume airtime or exploit a bug below the app layer. |
| **T11 High** | Private key or current ratchet state exposed by device compromise | Platform provider/key-storage review, least exposure, lock/biometric policy decision, crash/log hygiene, deletion; compromise/recovery tests. | A compromised or unlocked endpoint can read current messages; hardware support and erasure vary by device. |
| **T12 High** | Counter/nonce reused after crash, retry, backup restore, or concurrent send | Provider-owned nonce/ratchet rules; one serialized actor; persist state and ciphertext atomically before send; crash-point tests. | Storage/provider defects can still corrupt state; cannot promise recovery before tested. |
| **T13 Medium** | Metadata leakage: stable identity, destination, packet ID, size, timing, neighbor graph | Avoid stable identity in route advertisements; evaluate rotating tokens and padding; minimize clear type/priority fields; document limits. | Routing itself reveals some metadata; anonymity is not provided. |
| **T14 Medium** | Forged or misinterpreted ACKs / confusing OS send completion with delivery | Typed delivery states; E2E authenticated ACK bound to message ID; distinguish transport, relay, and app acceptance. | ACK can be lost; user may see pending despite recipient acceptance until retry/ACK. |
| **T15 High** | Key rotation/revocation is lost or attacker suppresses it | Signed chain/revocation, generation pinning, contact-change warnings, out-of-band recovery. | Offline mesh cannot offer instant revocation; root compromise needs new out-of-band trust. |
| **T16 High** | Cross-platform crypto/parser/provider disagreement | Shared versioned vectors; strict cross-runtime tests for Dart/Kotlin/Swift; differential fuzzing; verify Android↔iOS on physical devices. | Platform APIs, endianness, lifecycle, and provider updates can introduce incompatibility. |
| **T17 High** | Dependency, SDK, signing key, or build pipeline compromise | Dependency/license/SBOM review; pin versions; protected release keys; reproducible/reviewed builds; update policy. | Supply-chain controls reduce but do not eliminate compromise. No audit has been performed. |
| **T18 Medium** | False real-world identity from handle/name claim | Label names as user-supplied claims; no global uniqueness; bind the cryptographic device key separately; show verified device status. | Users can still be socially engineered or choose misleading names. |

Severity is provisional and reflects design review, not a quantitative risk assessment.

## 6. Existing-source gaps (not claims about a deployed app)

- `generateIdentity` creates separate Ed25519 and X25519 keypairs; QR includes the Ed25519 key/fingerprint only.
- The Noise XX reference uses the X25519 static; the QR prologue commits to Ed-derived IDs but is not a signed cross-key binding.
- `peerExchangeNodeId` and `Identity.nodeId` hash different key types.
- Sender Ed25519 public key is inside the encrypted packet, but current `DumanSession.receive` does not verify it against a signed binding.
- Current packet header authenticates TTL/hop as AEAD associated data, while `src/simulation.ts` mutates the corresponding object fields during forwarding; serialized crypto packets are not passed through the simulator's route engine.
- Current Node reference keys are ordinary buffers with best-effort wipe; there is no mobile keystore, durable ratchet store, native BLE, or device integration.
- The symmetric reference ratchet is not evidence of a production ratchet or post-compromise recovery.

Source-level observations are not proof of an exploit, nor proof that a production app exists. The current repository has only a source-level Flutter UI shell; no production messaging, identity, crypto, key storage, native transport, or handset evidence is present.

## 7. Out of scope and explicit non-guarantees

- Protection when sender or recipient is compromised, malicious OS/root access, hostile screen capture, or a user voluntarily exports plaintext.
- Global traffic-analysis resistance, anonymity, source hiding, truthful routing path, guaranteed delivery, or instantaneous revocation.
- Voice/file/group messaging, multi-device/account recovery, always-on background reachability, secure deletion from flash/OS backups, or hardware-backed support before those receive separate designs and tests.
- Treating simulator, Node reference, browser build, or static Dart checks as Android/iOS cryptographic, radio, or device evidence.

## 8. Acceptance evidence

Use the [protocol test plan](PROTOCOL-TEST-PLAN.md). Before an implementation is called secure/verified, require: owner-approved versioned design; independent cryptographic review; provider and dependency review; fixed vectors; negative/fuzz/state-machine tests; crash/rollback tests; and separate Android, iOS, and physical cross-device evidence. This repository has not yet met those gates.
