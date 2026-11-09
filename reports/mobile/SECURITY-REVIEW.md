# Mobile security design review

**Review date:** 2026-11-05
**Source snapshot:** `a1f1916981c2244a2f8664573b66afbd5a2659b4` (empty checkpoint over `bdf719cf88205f944187cb79b8288264a56c13bd`)
**Disposition:** **NOT READY FOR IMPLEMENTATION OR SECURITY CLAIMS. Owner/security review required before protocol or packet changes.**
**Review type:** Repository/source inspection and proposed-design review for this documentation milestone. No independent cryptographer, platform security engineer, or external audit has reviewed this work. No production or simulator code, packet formats, fixtures, tests, timeout, or routing defaults changed.
**Current note (2026-11-08):** A source-only Flutter UI shell and widget tests were added after this review snapshot. They add no identity, crypto, key storage, transport, or messaging behavior; this report does not audit the new widgets.

## 1. Executive summary

The repository contains a Node.js cryptographic protocol reference, two simulators, and a source-only Flutter UI shell, but no native transport, mobile key-storage integration, or device tests. The source exposes two protocol-design blockers that must be resolved before the reference can be treated as a mobile security design:

1. **Identity and session key are not signed together.** `generateIdentity` creates an Ed25519 signing key and an independent X25519 Noise static key. The QR carries the Ed25519 key/fingerprint, while Noise XX uses the X25519 static. The handshake prologue commits to Ed-derived identity hashes but does not prove that the remote X25519 static belongs to that Ed identity. The sender Ed key is placed inside encrypted content but is not signed or checked against a binding by `receive`.
2. **The packet header is immutable under its current AEAD.** `sealPacket` authenticates the entire visible header—including TTL and hop—as AEAD associated data. The simulator forwarding path decrements TTL and increments hop on `MeshMessage` objects. The simulator does not serialize, mutate, and re-authenticate this crypto packet, so the reference packet and modeled forwarding behavior are not one validated wire protocol.

In addition, the Node reference uses ordinary memory buffers and a custom symmetric ratchet, there is no durable mobile ratchet/replay store, key rotation/revocation/backup policy is not approved, and the radio/native boundary is absent. These are design gaps, not evidence of an exploit in a deployed app. The current TypeScript tests do not prove mobile security or handset interoperability.

A proposal for signed device-key binding and an immutable end-to-end ciphertext inside a bounded mutable forwarding envelope is documented in [SECURITY-ARCHITECTURE.md](../../docs/mobile/SECURITY-ARCHITECTURE.md), [IDENTITY-AND-KEYS.md](../../docs/mobile/IDENTITY-AND-KEYS.md), and [PACKET-FORMAT.md](../../docs/mobile/PACKET-FORMAT.md). Those documents are **not approved wire formats**.

## 2. Findings

| ID / severity | Finding and evidence | Required disposition |
|---|---|---|
| **SEC-01 — Critical blocker** | **Ed25519 identity is not cryptographically bound to the X25519 Noise static.** `src/crypto/identity.ts` independently generates both. QR encodes the Ed key plus identity SAS. `sessionPrologueFromQr` hashes Ed keys into the prologue; `src/crypto/noise-xx.ts` authenticates X statics. A prologue commits to context but is not a signed key certificate. | Approve a versioned signed binding, lifecycle, strict verifier, and remote-static equality check; include binding digests and protocol context in the handshake. Never silently accept an unbound fallback. |
| **SEC-02 — High** | **Two `nodeId` derivations and message sender ambiguity.** `Identity.nodeId` hashes Ed25519; `DumanSession.peerExchangeNodeId` hashes X25519. The sender Ed key is encrypted in the packet but is not signed there or validated against a binding by `receive`. `signHandleClaim` is a handle-to-Ed-derived-ID claim, not a key binding. | Give device identity, user/account identity, and route address separate names/types. Validate the E2E peer against the signed binding and selected provider. Do not trust `from`/handle fields alone. |
| **SEC-03 — High** | **QR fingerprint SAS is not handshake SAS.** `identitySas` fingerprints an Ed key; `handshakeSas` derives from a Noise transcript and X statics. The current QR does not carry an exchange-key binding. A one-time human comparison of handshake SAS can authenticate a particular transcript, but does not replace a signed persistent Ed-to-X binding or automatic rotation/recovery policy. | Document separate meanings; require explicit first-contact and key-change UX. Decide unverified messaging behavior. Keep the SAS as a human aid, not the only authentication for high-risk actions. |
| **SEC-04 — Critical blocker** | **Current authenticated packet header conflicts with relay mutation.** `src/crypto/packet.ts` includes the 27-byte `{msgIdDigest, ttl, type, destHint, hop}` header as AEAD AAD. Changing TTL/hop invalidates the tag. | Preserve existing v1 semantics/vectors. Design a new version where E2E content remains immutable and mutable routing metadata is separately bounded and authenticated per neighbor. Do not change bytes or semantics silently. |
| **SEC-05 — High** | **Simulator and crypto wire packet are not integrated.** `src/simulation.ts` forwards a cloned `MeshMessage`, decrementing TTL and incrementing hop. It does not pass `packet.ts` serialized bytes through relays. | Keep simulator claims and device/wire claims separate. Add versioned codec/forwarding integration tests only after owner approval; preserve current simulator tests and goldens. |
| **SEC-06 — High** | **No production mobile crypto/key-storage boundary.** `src/crypto/primitives.ts` uses Node crypto; private keys live in ordinary JS buffers with best-effort zeroization. No Flutter provider, Android Keystore/StrongBox, Secure Enclave/Keychain integration, or cross-runtime crypto implementation exists. Hardware support for Ed25519/X25519 is not established. | Select maintained, reviewed implementations and test actual supported OS/device APIs. Do not port the reference wholesale or claim hardware-backed keys without evidence. |
| **SEC-07 — High** | **Ratchet and persistence guarantees are not a mobile design.** The reference has a custom symmetric ratchet, but no durable atomic mobile outbox/inbox/replay state. A symmetric ratchet does not establish DH-ratchet post-compromise recovery. Crash, restore, rollback, and disk-full semantics are not implemented. | Select a maintained E2E protocol/provider; define per-peer serialization and atomic send/receive commits, backup/rollback policy, and interruption tests before messaging. |
| **SEC-08 — High** | **Key rotation, root recovery, expiry, and revocation are unresolved.** Offline peers may not receive updates; local wall clocks and restored state may be stale. | Define monotonically versioned signed bindings, root-change confirmation, revocation propagation, clock handling, and safe recovery. State the offline revocation limit explicitly. |
| **SEC-09 — High** | **Mutable TTL/hop and per-hop authentication do not prove a path.** A link MAC/AEAD covers one immediate link, but a relay can produce a new authenticated frame with rewritten outer fields, lie, fork, or drop. The current `destHint` is a prefix of identity-derived node ID. | Treat path fields as advisory; enforce local bounds; do not promise globally truthful hop count or anonymity. If a global cryptographic hop budget is required, review it as a separate design. |
| **SEC-10 — Medium** | **Metadata exposure is material.** Current header exposes type, packet digest, TTL/hop, and destination hint; relays already observe routing traffic. The current hint matches a prefix of an OGM node ID. | Minimize stable identity and message-type exposure; review rotating destination-token design; document traffic-analysis limits. Do not call a short hash anonymous. |
| **SEC-11 — High** | **No real transport, fragmentation, or platform evidence.** The Flutter source-only UI shell has no native BLE adapter, Android/iOS host, or physical device setup. `BLE_MAX_BYTES` and simulator success are not proof of Android/iOS MTU or background behavior. | Choose provider/frame/MTU/fragment bounds after platform/physical tests. Report simulator, emulator, and physical results separately. |
| **SEC-12 — High** | **Independent security review is absent.** The current review is source-based and design-level only. No external audit, dependency audit, SBOM/license review, or cross-platform cryptographic provider selection has run. | Require owner approval and independent protocol/provider/platform review before production implementation or security claims. |

Severity describes the implementation/design gate, not quantified exploitability. “Critical blocker” does not mean a deployed application is known to be vulnerable; no production mobile messaging app exists in this checkout.

## 3. Protocol direction for review

The proposed direction is:

1. Per-device Ed25519 signing identity, distinct from any human/account label and route token.
2. Versioned signed binding of that Ed key to the exact X25519 static used by the handshake; candidate COSE_Sign1/EdDSA over deterministic CBOR using maintained implementations.
3. Noise handshake context bound to ordered identity/binding digests and protocol suite; verify remote Noise static equals the signed binding; display/compare a fresh handshake SAS for the defined contact policy.
4. Use a maintained E2E messaging protocol/provider for content, ratchet, replay, and authenticated context; do not ship the custom Node reference as a production provider.
5. Keep the E2E ciphertext unchanged across forwarding. Put destination token, stable random packet ID, bounded TTL/hop, and optional bounded fragment metadata in a separate mutable envelope. Protect each link frame with a reviewed per-neighbor record/session. Treat per-hop authentication as neighbor authentication only.
6. Commit send ciphertext/state and receive replay/ratchet/inbox state atomically; define recovery, rotation, revocation, and user-facing trust states.
7. Complete the threat-driven verification matrix in [PROTOCOL-TEST-PLAN.md](../../docs/mobile/PROTOCOL-TEST-PLAN.md), including Android/iOS and physical Android↔iOS tests.

Candidate standard references are Ed25519 [RFC 8032](https://www.rfc-editor.org/rfc/rfc8032), X25519 [RFC 7748](https://www.rfc-editor.org/rfc/rfc7748), COSE_Sign1 [RFC 9052](https://www.rfc-editor.org/rfc/rfc9052), COSE algorithms [RFC 9053](https://www.rfc-editor.org/rfc/rfc9053), deterministic CBOR [RFC 8949 §4.2](https://www.rfc-editor.org/rfc/rfc8949#section-4.2), and the [Noise Protocol Framework](https://noiseprotocol.org/noise.html). These are standards/specifications, not a chosen dependency or a standard Duman identity schema.

## 4. Internal review and limitations

- Reviewed source paths: `src/crypto/identity.ts`, `session.ts`, `sas.ts`, `noise-xx.ts`, `packet.ts`, `ratchet.ts`, relevant session/recovery tests, `src/transport.ts`, and simulator receive/forward logic in `src/simulation.ts`.
- Reviewed proposed documents: [SECURITY-ARCHITECTURE.md](../../docs/mobile/SECURITY-ARCHITECTURE.md), [IDENTITY-AND-KEYS.md](../../docs/mobile/IDENTITY-AND-KEYS.md), [PACKET-FORMAT.md](../../docs/mobile/PACKET-FORMAT.md), [THREAT-MODEL.md](../../docs/mobile/THREAT-MODEL.md), and [PROTOCOL-TEST-PLAN.md](../../docs/mobile/PROTOCOL-TEST-PLAN.md).
- This is not code audit, formal verification, cryptographic proof, implementation review, penetration test, dependency audit, or approval by a separate security reviewer.
- No source or test was changed. No crypto was integrated, no protocol golden vector was edited, and no test was represented as passing.
- G0 test status remains 517/527 pass with ten timeouts at the unchanged 5,000 ms limit; Dart/Flutter/native/device checks were not available. See [TEST-RESULTS.md](TEST-RESULTS.md) and [PERFORMANCE-INVESTIGATION.md](PERFORMANCE-INVESTIGATION.md).

## 5. Owner decisions required before implementation

1. Approve/correct the two-layer packet direction and state whether a truthful global forwarding budget is required.
2. Approve/correct device versus user/account identity model, binding container/schema/version/suite, QR content, and rotation/revocation rules.
3. Select and independently review maintained E2E, Noise/link, COSE, and platform key-storage implementations.
4. Decide verified-contact UX, fresh SAS requirements, and whether any unverified message transmission is allowed.
5. Approve destination-token/packet-ID metadata policy, maximum frame/message/fragment sizes, TTL/hop semantics, ACK definitions, and durability expectations.
6. Decide supported Flutter/Dart, Android/Java/Gradle/SDK, Xcode/macOS/iOS targets and physical devices; see [TOOLCHAIN-REQUIREMENTS.md](TOOLCHAIN-REQUIREMENTS.md).
7. Authorize implementation only after the above and an independent security review. No protocol or packet change has been made pending this review.

## Milestone 3 follow-up

The detailed 12-item review matrix, including attack scenarios, current/missing controls, mitigations, required tests, severity, and the need for independent cryptographic review, is in [SECURITY-REVIEW-RESULTS.md](SECURITY-REVIEW-RESULTS.md). The field-level candidate is in [PROTOCOL-IMPLEMENTATION-SPEC.md](../../docs/mobile/PROTOCOL-IMPLEMENTATION-SPEC.md). This follow-up remains a review by the same task agent; it is **not** the independent reviewer required for implementation approval. No protocol/packet implementation was made.
