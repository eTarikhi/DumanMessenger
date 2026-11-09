# Milestone 3 — security review results

**Review date:** 2026-11-05
**Source snapshot:** `a1f1916981c2244a2f8664573b66afbd5a2659b4` (empty checkpoint over `bdf719cf88205f944187cb79b8288264a56c13bd`)
**Disposition:** **Design review identifies blockers; no new protocol or packet format is approved.**
**Reviewer independence:** This is an additional source/design review by the same task agent, not an independent cryptographic review. No separate cryptographer, protocol auditor, or mobile platform security engineer reviewed the construction. Independent review is still required before implementation or security claims.

This report reviews the five Milestone 2 security design documents and the current reference source. It distinguishes what exists in the repository from proposed controls. Using Ed25519, X25519, Noise, COSE, or AEAD does not by itself prove that their composition, state machine, storage, or relay behavior is secure.

## 1. Findings

### SR-01 — Ed25519 identity / X25519 session-key binding

- **Severity:** Critical design blocker.
- **Attack scenario:** A contact scans an Ed25519 QR identity, but an attacker substitutes or controls the independent X25519 static used by Noise. The QR and session can be represented as one peer even though no signed object proves the Ed key authorized that X key. A malicious peer can also place an unrelated Ed public key inside encrypted message content.
- **Existing protection:** The QR fingerprint is computed from the Ed25519 key. Noise XX authenticates possession of its X25519 static within the handshake. `sessionPrologueFromQr` commits Ed-derived identifiers to the transcript; a human may compare a fresh handshake SAS.
- **Missing protection:** No Ed25519-signed binding of the exact X25519 static; no verifier requiring the Noise remote static to equal a signed key; `receive` does not check the encrypted sender Ed key against a binding. A prologue is context, not a cross-key signature.
- **Recommended mitigation:** Define a versioned signed device binding; validate its signature and identity fingerprint before the handshake; include its digest and protocol context in the handshake; compare the authenticated remote X static byte-for-byte with the binding. Never silently fall back to an unbound key.
- **Required tests:** Valid/invalid signature; swapped Ed/X keys; valid QR with mismatched binding; handshake remote-static mismatch; transcript/SAS substitution; migration and legacy-unbound rejection.
- **Independent cryptographic reviewer:** **Required.** Review certificate construction, domain separation, key validation, handshake composition, and platform key operations.

### SR-02 — Canonical encoding and signature verification

- **Severity:** High.
- **Attack scenario:** Different parsers accept different byte encodings, duplicate map keys, trailing data, malformed key encodings, unknown critical fields, or a modified signed payload; parser disagreement can cause key substitution or downgrade.
- **Existing protection:** Current `decodeQr` checks payload length and SAS alphabet. Current packet parsing checks header length/type, AEAD result, body length, and zero padding. These are separate Node-reference checks, not a signed canonical binding parser.
- **Missing protection:** No binding object or COSE/CBOR parser exists. Current QR decode is not a signature-verification flow; no cross-runtime canonical-encoding contract or fuzz corpus exists.
- **Recommended mitigation:** If the owner accepts a COSE/CBOR candidate, use a maintained implementation; pin allowed COSE structure/algorithm/content type; deterministic CBOR; bounded lengths; reject duplicate keys, unsupported critical fields, trailing bytes, noncanonical forms, invalid key encodings, and unknown versions. Do not implement custom signature framing or curve validation.
- **Required tests:** Valid canonical vector; altered protected header/payload/signature; duplicate keys; indefinite/non-shortest encodings; wrong field type/size; trailing bytes; unknown critical fields; fuzz and Dart/Android/iOS differential parsing.
- **Independent cryptographic reviewer:** **Required** for parser/signature profile and its composition; independent parser/security review also needed.

### SR-03 — Device identity versus user identity

- **Severity:** High privacy/trust-model decision.
- **Attack scenario:** A UI or protocol labels a device key as a verified person/account, treats a handle as globally unique, or merges two unrelated device identities because they share a display name.
- **Existing protection:** The reference has a local handle-claim signature and an Ed-derived `nodeId`; QR fingerprints are key-specific.
- **Missing protection:** No account root, username authority, uniqueness service, verified profile, or reviewed multi-device model. `Identity.nodeId` is derived from Ed25519 while `peerExchangeNodeId` is derived from X25519. A signed handle claim is not an account credential or exchange-key binding.
- **Recommended mitigation:** Specify per-device identity separately from local display name, account/user identity, and route token. For a first release, keep devices independently verified unless an account-root/device-certificate design is reviewed. Do not advertise stable identity fingerprints as route addresses by default.
- **Required tests:** Same display name/different keys; same person/two devices; handle change; key replacement; device removal; UI labels for unverified/changed contacts; route-ID/identity-ID non-confusion.
- **Independent cryptographic reviewer:** **Yes** for any account-root or multi-device signature hierarchy; product/privacy owner review is also required.

### SR-04 — Key rotation, expiration, revocation, and recovery

- **Severity:** High.
- **Attack scenario:** An attacker replays an old signed key after rotation, suppresses a revocation, rolls local state back from backup, or exploits an incorrect/offline wall clock to restore a retired key. A stolen root key may sign its own misleading “recovery.”
- **Existing protection:** `SessionCache` has a seven-day session lifetime and wipes expired in-memory sessions. That is not device-binding expiry, key rotation, revocation, or rollback protection.
- **Missing protection:** No signed binding generations/predecessor chain, identity-key rotation policy, expiry policy, revocation record/distribution, trusted time, monotonic storage, backup/restore, or account recovery.
- **Recommended mitigation:** Version signed bindings; pin a durable generation high-water mark; authenticate predecessor changes; define clock-skew/validity policy; require out-of-band re-verification when root continuity cannot be established. State explicitly that offline peers cannot receive revocations they have not encountered and that a compromised root cannot self-authenticate recovery.
- **Required tests:** Expired/not-yet-valid binding; lower/same/forked generation; missing predecessor; stale backup/clock rollback; valid and invalid rotation; delayed/missing revocation; compromised/unavailable old root; app reinstall and lost-key recovery.
- **Independent cryptographic reviewer:** **Required** for chain/revocation/recovery protocol; storage and clock assumptions require platform security review.

### SR-05 — Peer authentication and session establishment

- **Severity:** Critical design blocker.
- **Attack scenario:** A relay establishes two separate Noise sessions and presents the same scanned Ed identity to both sides. If users skip or misread SAS, the endpoints may trust an X key unrelated to the scanned Ed key. Reusing a session after a contact-key change can hide the changed peer.
- **Existing protection:** Noise XX provides handshake key agreement/authentication of its static keys; the transcript-derived handshake SAS can support an out-of-band comparison; the session has an explicit `unverified` phase.
- **Missing protection:** The long-term Ed QR key is not bound to the Noise X static. The QR's identity SAS and handshake SAS are distinct. `DumanSession` permits encrypted data while `unverified`; no mobile policy governs it.
- **Recommended mitigation:** Validate binding first, authenticate the exact remote static, domain-separate the prologue with roles/identities/binding digests, keep human verification state explicit, and decide whether to block or visibly warn on pre-verification sends. Do not treat a successful handshake as proof of human identity.
- **Required tests:** MITM between two handshakes; wrong remote static; altered role/order/prologue; lost/replayed handshake legs; simultaneous open; SAS mismatch; contact change; verified state persistence and unverified send UX.
- **Independent cryptographic reviewer:** **Required** for handshake/profile composition; usability review required for SAS flow.

### SR-06 — Downgrade and replay protection

- **Severity:** High.
- **Attack scenario:** An attacker strips a binding/version, forces a legacy packet or weaker suite, replays an old valid binding/message/ACK, or reuses stale ratchet state after a crash or restore.
- **Existing protection:** The Noise reference has a fixed `Noise_XX_25519_ChaChaPoly_SHA256` name and transcript; the session uses a symmetric ratchet and message number; packet AEAD authenticates its current header. The source includes reference tests for retry/recovery/ratchet behavior.
- **Missing protection:** Current packet header does not include an explicit wire version. No signed capability negotiation or versioned migration exists. Mobile monotonic replay state and durable transaction behavior do not exist. Simulator object-level dedupe is not proof of wire-level replay behavior.
- **Recommended mitigation:** Pin exact version/suite in a signed binding and authenticated handshake context; reject unsupported versions with no silent fallback; use provider-owned replay/ratchet state, stable random message IDs, bounded dedupe, and atomic persistence. Treat legacy contacts as explicitly legacy/unbound, not “verified.”
- **Required tests:** Strip/change version/suite; unknown suite; cross-version transcript; duplicate/reordered/old message; replay after app restart; nonce/sequence boundary; stale backup; exact-byte retry.
- **Independent cryptographic reviewer:** **Required** for downgrade and replay-state protocol; implementation/provider reviewer required for persistent state.

### SR-07 — End-to-end AEAD and authenticated fields

- **Severity:** Critical for any packet-format change.
- **Attack scenario:** A relay changes the current header or transplants ciphertext to a different peer/conversation. Alternatively, the protocol authenticates plaintext but leaves a security-relevant message ID, recipient, or type outside the authenticated context.
- **Existing protection:** `src/crypto/packet.ts` passes the 27-byte header—including message-ID digest, TTL, type, destination hint, and hop—as AEAD associated data. Sender key, timestamp, body length, and body are encrypted; `openPacket` rejects invalid tags and lengths.
- **Missing protection:** The header's integrity conflicts with forwarding mutation. No approved E2E provider/API, message-context profile, packet-to-message-ID binding, or mobile serialization exists. Current `openPacket` is a Node reference, not an independently audited mobile record layer.
- **Recommended mitigation:** Do not mutate the existing format. For a reviewed new version, keep E2E ciphertext immutable; have the selected maintained messaging provider authenticate sender/recipient/session/message context; place only permitted forwarding metadata outside. Specify exact authenticated fields and provider boundary before code.
- **Required tests:** Flip ciphertext and each authenticated field; wrong recipient/conversation; packet ID versus protected message ID mismatch; nonce/replay tests; malformed lengths; provider vectors across supported runtimes.
- **Independent cryptographic reviewer:** **Required.** Do not infer security from the primitive name or AEAD call alone.

### SR-08 — Mutable forwarding metadata

- **Severity:** Critical design blocker for relaying.
- **Attack scenario:** An honest relay cannot decrement TTL/increment hop while preserving the current AEAD tag; if the tag is removed or ignored, an attacker can alter routing, packet ID, destination, or resource limits.
- **Existing protection:** Current packet AEAD detects header tampering. The simulator clones `MeshMessage` and decrements TTL/increments hop; current simulator semantics are modeled and tested separately.
- **Missing protection:** No serialized v2 envelope, immutable/mutable field classification, versioned forwarding behavior, or codec-to-router integration. The simulator does not forward the serialized crypto packet.
- **Recommended mitigation:** Keep current bytes unchanged; design a versioned outer envelope where inner E2E ciphertext stays byte-identical and every relay preserves specified immutable fields. Give each hop a fresh authenticated link record. Treat mutable fields as untrusted claims.
- **Required tests:** Exact E2E ciphertext equality over multiple forwards; allowed TTL/hop update; forbidden field mutation; packet-ID/fragment mismatch; codec+router round trips; golden v1 unchanged; malformed v2 frame.
- **Independent cryptographic reviewer:** **Required** for end-to-end/outer-layer composition; routing owner review for semantics.

### SR-09 — Per-hop authentication and relay trust

- **Severity:** High.
- **Attack scenario:** An unauthenticated nearby node injects or replays frames, or an implementation mistakes a link-level integrity tag for end-to-end authentication or an honest route proof.
- **Existing protection:** Noise XX exists in the Node reference for a peer session; simulator transport models links/events. There is no deployed per-hop native channel in the repository.
- **Missing protection:** No Android/iOS link/session implementation, link key lifecycle, anti-replay record, per-neighbor authorization, or physical radio test. A tag from one relay would not authenticate prior relays or prevent dropping/rewriting on the next hop.
- **Recommended mitigation:** Use a maintained authenticated secure-channel/record implementation for each immediate neighbor; provider owns nonce/replay handling; treat all relays as malicious for content and availability. Re-authenticate a new outgoing record per next hop without altering E2E bytes.
- **Required tests:** In-link tamper/replay; neighbor key mismatch; reconnect/counter reset; relay modification of allowed/forbidden fields; malicious relay drop/fork/delay; Android↔iOS physical link tests.
- **Independent cryptographic reviewer:** **Required** for channel composition and keying; platform specialist required for BLE/link behavior.

### SR-10 — TTL and hop-count enforcement limits

- **Severity:** High resource/control limitation.
- **Attack scenario:** A malicious relay increments TTL, resets hop count, forks a packet, or lies about the number of traversed hops to extend flood/resource use or mislead metrics.
- **Existing protection:** The simulator checks TTL exhaustion and changes object TTL/hop on forwarding. Current packet AEAD would reject unauthorized changes to TTL/hop, but also prevents honest relays from changing them.
- **Missing protection:** No production hard cap, mutable-field protocol, signed forwarding budget, or proof of path. A per-hop MAC cannot establish what happened before the immediate neighbor.
- **Recommended mitigation:** Clamp/reject an implementation-defined local maximum, never increase a received budget in an honest forward, bound queues and deduplicate independently, and treat hop count as diagnostic. If a globally enforceable path/hop bound is a requirement, commission a separate reviewed proof design; do not claim the simple envelope provides one.
- **Required tests:** Zero/maximum/overflow TTL; expiration edge semantics; attempted TTL inflation/reset; hop overflow; duplicate/fork; load bounds under malicious relays; verify no trusted UI/path metric consumes an unverified count.
- **Independent cryptographic reviewer:** **Required** if a cryptographic global budget is proposed; routing/security owner review otherwise.

### SR-11 — Acknowledgement authenticity and replay protection

- **Severity:** High for user-visible delivery state.
- **Attack scenario:** A relay fabricates an ACK, replays an old ACK for a reused ID, or the UI interprets OS/link queue acceptance as recipient delivery. A recipient accepts a message but its ACK is lost, causing duplicates.
- **Existing protection:** The simulator models `ACK:<messageId>` and delivery records. `packet.ts` defines `ack` as a control type; `isSealedType` classifies it separately from ordinary sealed types. These are not an authenticated mobile ACK contract.
- **Missing protection:** No message-ID cryptographic binding, recipient-authenticated ACK, durable-acceptance meaning, replay table, or distinction in a mobile UI among link/relay/recipient acceptance.
- **Recommended mitigation:** Define transport, relay-store, and E2E application ACKs as distinct types/states. Make the recipient ACK E2E-authenticated under the selected provider and bind it to the original message ID and recipient device; send “durably accepted” only after atomic inbox/ratchet commit; make duplicate ACK processing idempotent.
- **Required tests:** Forged/wrong-peer ACK; replay/duplicate ACK; ACK loss and resend; reused/unknown message ID; ACK before durable commit; relay ACK versus recipient ACK UI state.
- **Independent cryptographic reviewer:** **Required** for E2E ACK binding/provider behavior; product review for delivery terminology.

### SR-12 — Protocol versioning and backward compatibility

- **Severity:** High.
- **Attack scenario:** An attacker or stale peer strips version/suite information or triggers a permissive parser that interprets v2 data as legacy, weakening key binding or allowing header tampering.
- **Existing protection:** Noise prologue string includes `DumanMessenger-session-v1`; packet type codes and current golden vectors define existing reference behavior. These are not a complete versioned mobile handshake or forwarding negotiation.
- **Missing protection:** No explicit version field in the 27-byte packet header, no signed suite offer, no v2 migration code, and no approved legacy trust state. Existing test vectors are protected by owner instruction.
- **Recommended mitigation:** Introduce a distinct versioned invite/binding and outer frame; pin version/suite in the signed binding and handshake context; reject unknown versions and mismatched suites. Keep v1/reference decoding isolated and explicitly unverified; do not silently reinterpret or fallback. Only migrate after owner approval and reviewed vectors.
- **Required tests:** Unknown version; field stripping; version/suite mismatch; cross-version replay; v1 contact must not be labeled v2 verified; exact legacy golden vectors unchanged; explicit migration and rollback tests.
- **Independent cryptographic reviewer:** **Required** for downgrade/transition design; owner approval required for compatibility policy.

## 2. Cross-cutting review disposition

1. The Milestone 2 architecture/identity/packet/threat/test-plan documents correctly surfaced major conflicts, but they did not constitute an independent security review or an implementation specification.
2. Candidate standards—Ed25519 (RFC 8032), X25519 (RFC 7748), COSE_Sign1 (RFC 9052/9053), deterministic CBOR (RFC 8949), and Noise—define components, not the security of this application's schema, handshake composition, forwarding, ACKs, or state machine.
3. No test vectors have been independently generated or checked across Dart/Kotlin/Swift. Do not publish illustrative bytes as vectors.
4. No production cryptography provider, packet version, or routing-token scheme is selected. No source/golden changes were made.
5. The current design requires a separate independent cryptographic review before implementation. The same authoring agent cannot provide that independence.

## 3. Required approval gates

Before protocol/packet implementation, obtain owner/security approval for the identity model, signed-binding fields and encoding, exact cryptographic/provider profiles, key lifecycle, first-contact verification, downgrade/migration behavior, E2E authenticated context, outer-envelope semantics, relay-link provider, global TTL requirement, ACK state transitions, size/reassembly bounds, and mobile persistence/recovery. Then obtain independent cryptographic and platform review and publish provider-verified vectors. See [PROTOCOL-IMPLEMENTATION-SPEC.md](../../docs/mobile/PROTOCOL-IMPLEMENTATION-SPEC.md) for the unapproved candidate draft.
