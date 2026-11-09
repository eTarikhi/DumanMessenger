# Candidate protocol implementation specification

**Draft identifier:** Duman Mobile Protocol Design (DMP) **0.1**, proposing wire/profile version **2**
**Status:** For owner and independent security review only. **Not approved, not implemented, not a cryptographic security claim, and not a frozen packet format.** No production behavior or existing vector changed.
**Evidence base:** `a1f1916981c2244a2f8664573b66afbd5a2659b4` (reviewed 2026-11-05).

This draft makes field layouts and candidate processing rules concrete enough to review, while explicitly leaving provider selection, platform validation, and some operational limits as blockers. Its use of standardized algorithms or containers would not by itself prove the composition safe. The design must be reviewed independently before implementation.

## 1. Scope and terminology

DMP 0.1 covers a per-device Ed25519-to-X25519 signed binding, a first-contact Noise handshake context, an E2E message envelope, a mutable mesh-forwarding envelope, relay processing, acknowledgements, and migration from the current reference. It does not specify or implement a new AEAD, ratchet, MAC, signature algorithm, or BLE service. The E2E and per-neighbor secure-channel providers remain **unselected**.

- **Device ID:** 32-byte fingerprint derived from the Ed25519 device identity key. It is not a person/account ID or route address.
- **Binding:** a COSE_Sign1 signed statement that binds one X25519 static key and suite to one device ID and generation.
- **E2E ciphertext:** opaque bytes produced by a selected maintained secure-messaging provider; relays do not decrypt or rewrite these bytes.
- **Packet ID:** a random 16-byte message identifier, repeated in the encrypted E2E message and visible envelope for deduplication. Its visibility allows copies of one message to be correlated.
- **Destination token:** a relay-visible 16-byte routing hint. Its derivation/advertisement is unresolved; it is not an identity proof or anonymity mechanism.
- **Link record:** one message carried over an authenticated per-neighbor secure-channel session. The provider, not a custom Duman MAC/nonce implementation, owns its record protection and replay state.

The words **MUST**, **MUST NOT**, and **SHOULD** below describe this unapproved draft only. They do not authorize implementation.

## 2. Common encoding rules

All DMP application objects in this draft use deterministic CBOR as defined by [RFC 8949 §4.2](https://www.rfc-editor.org/rfc/rfc8949#section-4.2): definite-length items; shortest permitted integer/length encoding; deterministic map-key ordering; no duplicate map keys; no indefinite-length values. Map keys are unsigned integer labels. Parsers reject non-deterministic encodings, duplicate keys, trailing bytes, unknown fields, unknown versions, wrong value types, and lengths outside their hard caps before allocating large buffers.

For each object below, the field table is the complete version-2 schema. Additional keys are rejected. A future extension requires a new reviewed version or an explicitly specified extension mechanism; implementations must not ignore an unknown field that affects security.

Ed25519, X25519, COSE_Sign1, and CBOR references: [RFC 8032](https://www.rfc-editor.org/rfc/rfc8032), [RFC 7748](https://www.rfc-editor.org/rfc/rfc7748), [RFC 9052](https://www.rfc-editor.org/rfc/rfc9052), [RFC 9053](https://www.rfc-editor.org/rfc/rfc9053), and RFC 8949. They specify building blocks/containers, not this application's trust or forwarding model. Implementations must use maintained, reviewed libraries and providers.

## 3. Device binding V2

### 3.1 Invite object

The invite payload carried in a QR or equivalent side channel is one deterministic-CBOR map:

| Label | Type | Required value/meaning |
|---:|---|---|
| `0` | `uint` | `2` — invite encoding version |
| `1` | `bstr(32)` | Raw Ed25519 public key `ed_public_key` |
| `2` | `bstr` | Complete COSE_Sign1 binding object, including mandatory CBOR tag 18 |

No private key, secret recovery material, session key, or user-authentication claim is included. The maximum encoded invite size is a **candidate 2,048 bytes**; scanner/QR interoperability must be tested before adopting this ceiling.

### 3.2 COSE_Sign1 protected headers and signature coverage

The COSE_Sign1 object uses the RFC 9052 structure with mandatory tag 18:

- Protected header map: label `1` (`alg`) = `-8` (COSE EdDSA); label `3` (`content type`) = exact text `application/vnd.duman.device-binding+cbor;v=2`.
- Unprotected header map: empty.
- Payload: a byte string containing the deterministic-CBOR `DeviceBindingPayloadV2` below.
- External AAD: empty byte string `h''`.
- Signature: exactly 64 bytes, verified with the raw 32-byte Ed25519 public key in the invite.
- No `kid`, unprotected algorithm, unknown protected/unprotected header, or unrecognized critical extension is accepted in this draft.

Signature coverage is exactly the COSE_Sign1 `Sig_structure` (`"Signature1"`, encoded protected-header bytes, empty external AAD, and payload bytes) defined by RFC 9052. Implementations must call a maintained COSE/Ed25519 verifier; they must not reconstruct or sign a custom concatenation.

### 3.3 Signed payload field definitions

`DeviceBindingPayloadV2` is a deterministic-CBOR map:

| Label | Type | Required value/meaning |
|---:|---|---|
| `0` | `tstr` | Exact domain string `duman-device-binding` |
| `1` | `uint` | `2` — binding schema version |
| `2` | `bstr(32)` | `device_id` = `SHA-256(UTF8("DumanDeviceID/v2") || 0x00 || ed_public_key)` |
| `3` | `bstr(32)` | X25519 static public key used by the Noise handshake |
| `4` | `uint64` | `generation`; starts at 1 and strictly increases for static-key rotations under this Ed25519 root |
| `5` | `uint64` | `issued_at_ms`, Unix epoch milliseconds |
| `6` | `uint64` | `not_before_ms`, Unix epoch milliseconds |
| `7` | `uint64` | `not_after_ms`, Unix epoch milliseconds; must be greater than `not_before_ms` |
| `8` | `null` or `bstr(32)` | `previous_binding_digest`; null only at generation 1; otherwise digest of the exact previous COSE_Sign1 bytes |
| `9` | `uint` | `suite_id`; `1` is the sole draft value and names `Noise_XX_25519_ChaChaPoly_SHA256` |

`device_id` is a key fingerprint, not proof of a person. Hashes use the selected provider's standard SHA-256 implementation. The predecessor digest is exactly `SHA-256(UTF8("DumanBindingCOSE/v2") || 0x00 || previous_cose_sign1_bytes)`. This digest rule is an application-specific candidate requiring review.

Structural checks: `generation >= 1`; `issued_at_ms <= not_after_ms`; `not_before_ms <= not_after_ms`; generation 1 has `previous_binding_digest = null`; generation >1 has a 32-byte predecessor digest; the computed device ID equals label 2; the suite equals an explicitly supported value. For rotation under one root, a peer accepts only a strictly higher generation whose predecessor chain matches its pinned state. A peer that missed generations needs a complete verified chain or explicit recovery; it must not silently jump or accept rollback.

The lifetime limit, allowed clock skew, grace period, and offline expiry UX are **not selected**. They are security-policy blockers, not parser details. Expiry cannot be made reliable by an untrusted wall clock alone.

### 3.4 Root-key change and revocation

A new Ed25519 root creates a new `device_id`; it is not an ordinary X25519 rotation. If the old root is available and not suspected compromised, an old-root signature over the new device ID may demonstrate continuity, but it cannot repair a compromised old root. Otherwise require an out-of-band invite and re-verification; do not automatically merge contacts.

A signed revocation-record schema is **not frozen in DMP 0.1**. No root-signing or offline revocation protocol is approved. Any future record must identify the device and affected generation, be signed by an authorized key, have replay/idempotency rules, and state that offline peers cannot know a revocation before receiving it. This deliberate omission is an implementation blocker, not a claim that revocation is unnecessary.

## 4. Peer session establishment and version policy

### 4.1 Candidate suite and prologue

Suite ID 1 names the existing reference spelling `Noise_XX_25519_ChaChaPoly_SHA256`; use only through a maintained Noise implementation if the owner approves it. The repository's TypeScript Noise code is not selected as a mobile implementation.

After both binding signatures and validity/generation checks pass, the initiator and responder construct a deterministic-CBOR prologue array in this exact order:

```text
[
  "DumanMessenger/Noise-prologue/v2",
  2,                         // DMP profile version
  1,                         // suite_id
  initiator_device_id,       // bstr(32)
  responder_device_id,      // bstr(32)
  initiator_binding_digest,  // bstr(32), as defined in §3.3
  responder_binding_digest  // bstr(32)
]
```

The Noise role ordering is explicit, not lexicographically sorted. The selected library receives these exact encoded bytes as its prologue. After XX completes, the implementation MUST verify that the remote static X25519 public key equals the signed binding's label 3, byte for byte. Mismatch is terminal: wipe/abandon the session, do not deliver messages, and do not downgrade to a bare-key session.

A first successful machine-authenticated session means “this session peer controls the bound device key,” not “this is the intended human.” Human verification state remains explicit and separate. DMP 0.1 does not specify a new short-authentication-string derivation; the current reference's SAS is not automatically adopted. A reviewed provider/UX must define how users compare a fresh transcript and how a mismatch is handled before calling a contact human-verified.

### 4.2 Negotiation and downgrade

DMP 0.1 has one profile version and one suite ID; it does not perform opportunistic algorithm negotiation. Unknown version, suite, binding content type, or handshake context is rejected. There is no automatic fallback to the current unversioned packet, an unbound X key, or an older suite. A future multi-suite offer must be signed or authenticated, included in the transcript, and independently reviewed; it is outside this draft.

## 5. End-to-end message profile

### 5.1 Application plaintext (inside the selected provider)

Before encryption, the application encodes `E2EMessagePayloadV2` as deterministic CBOR:

| Label | Type | Required value/meaning |
|---:|---|---|
| `0` | `uint` | `2` — application-message schema version |
| `1` | `bstr(16)` | `message_id`, cryptographically random and unique per device; equals outer `packet_id` |
| `2` | `bstr(32)` | Sender `device_id`, checked against the established provider-authenticated peer |
| `3` | `bstr(32)` | Intended recipient `device_id`, checked against the local binding |
| `4` | `bstr(16)` | Random conversation identifier, interpreted only within the selected provider session |
| `5` | `uint` | `content_type`: `0` text; `1` ACK; other values rejected in this initial profile |
| `6` | `uint64` | `created_at_ms`, Unix epoch milliseconds; informational and subject to clock limits |
| `7` | `bstr` | Body; for type 0, UTF-8 text bytes; for type 1, canonical `AckPayloadV2` bytes |

The complete encoded payload is passed to a selected maintained E2E messaging provider. DMP does not define the provider's ciphertext, ratchet, nonce, key schedule, signature, or internal authenticated headers. Provider output is opaque and immutable at the mesh layer. The provider must expose/verify the bound peer identity and protect its own protocol headers as specified by its standard.

**Application-supplied E2E AEAD AAD in this draft is empty.** DMP semantic fields above are inside the E2E encrypted plaintext and therefore must be authenticated by the provider's ordinary authenticated-encryption/message-authentication operation. The receiver checks sender ID, recipient ID, conversation, version, and `message_id` against the authenticated session and outer envelope before commit. Provider-defined authenticated headers remain provider-owned. If the chosen provider cannot safely authenticate this payload/context and expose the authenticated peer, implementation stops for a specification review; do not add a custom wrapper AEAD.

No per-message Ed25519 signature or non-repudiation claim is made. Message origin authentication is the selected provider's authenticated session/ratchet property, tied to the signed device binding. This composition requires independent review.

## 6. Route envelope V2

### 6.1 Exact candidate fields

One `RouteEnvelopeV2` is a deterministic-CBOR map. It contains a fragment of the provider ciphertext, not plaintext:

| Label | Type/range | Meaning |
|---:|---|---|
| `0` | `uint`, exactly `2` | Forward-envelope version |
| `1` | `bstr(16)` | `packet_id`; random message ID, stable across retries, fragments, and hops; must match decrypted `E2EMessagePayloadV2.message_id` |
| `2` | `bstr(16)` | `destination_token`; relay-visible route lookup hint, not identity proof; exact discovery source remains unselected |
| `3` | `uint`, enum | `0` unicast; `1` public broadcast; `2` control/ACK; unknown value rejected |
| `4` | `uint8` | `ttl_remaining`; source initializes at an approved value no greater than `MAX_HOPS`; honest relay decrements before forwarding |
| `5` | `uint8` | `hop_count`; source initializes `0`; honest relay increments before forwarding; diagnostic/untrusted path claim |
| `6` | `uint16` | `fragment_index`, zero-based |
| `7` | `uint16` | `fragment_count`, at least 1; `fragment_index < fragment_count` |
| `8` | `uint32` | `total_ciphertext_length`, complete provider ciphertext length in bytes |
| `9` | `bstr` | `ciphertext_fragment`; fragment payload bytes |

CBOR uint encoding is shortest-form; the stated widths are semantic ranges, not permission to wrap. Fragment counts/lengths and complete envelope size are checked against hard configured caps before memory allocation. Draft policy constants—`MAX_HOPS`, maximum total ciphertext, maximum fragment count, maximum encoded envelope, incomplete assemblies per peer/global byte budget, queue quotas, and fragment expiry—are intentionally **not approved** until owner decisions and actual Android/iOS MTU tests. No implementation may leave these limits unbounded or select them silently.

### 6.2 Immutable versus mutable fields

Across an honest relay, fields `0,1,2,3,6,7,8,9` are immutable and copied exactly. Only `4` (`ttl_remaining`) and `5` (`hop_count`) may change, according to the forward rule below. `destination_token` and `route_class` are public routing hints and remain untrusted even if preserved; a malicious relay can rewrite them when producing another link record. E2E recipient/context checks prevent a different recipient from accepting the message but cannot prevent misrouting or denial of service.

The E2E ciphertext is never re-encrypted, resealed, or modified by a relay. It is fragmented only as a byte string; reassembly must reproduce the exact original provider ciphertext.

### 6.3 Per-hop protection and associated data

DMP does not define a custom link MAC, nonce, tag, or shared mesh-wide key. Each neighbor relationship uses a reviewed authenticated secure-channel/record implementation that authenticates the peer device using its validated binding. The complete encoded `RouteEnvelopeV2` is sent as one record's protected plaintext. The selected record provider owns its counter/nonce/replay behavior and its exact record-header AAD; it must authenticate its complete record metadata and plaintext. Relays terminate one link record and create a new record for the next hop.

### 6.4 Signature and AEAD coverage matrix

| Layer | DMP-controlled authenticated input | Protected data | What is deliberately not covered end-to-end |
|---|---|---|---|
| Device binding | COSE_Sign1 `Sig_structure`: protected headers (algorithm and binding content type), empty external AAD, and exact deterministic-CBOR binding payload | COSE signature uses the invite's Ed25519 public key; the payload's `device_id` is recomputed from that key | QR carrier/transport and display name; these are checked separately and do not become a real-world identity proof. |
| E2E message | DMP application-supplied AAD is the empty byte string `h''` | Entire deterministic-CBOR `E2EMessagePayloadV2` (labels 0–7) is provider-encrypted/authenticated; the provider's own standard message headers/ratchet state are authenticated as specified by that provider | No route token, TTL, hop count, or fragment index is E2E AAD. The outer packet ID is checked equal to the encrypted `message_id` after decryption. |
| Per-neighbor link record | No custom DMP AEAD/AAD encoding is defined. The selected secure-channel provider authenticates its standard record metadata/counter according to its profile. | The complete encoded `RouteEnvelopeV2` is protected as one secure-channel record payload by the selected provider. | A link record authenticates only the immediate neighbor/session, not the origin or preceding path. |

For the link layer, “exact authenticated coverage” in this draft means **all** RouteEnvelope bytes plus all metadata the selected provider uses to identify/order/authenticate a record. The provider's concrete record header/AAD encoding is intentionally not specified until a maintained provider is selected. Selecting a provider that leaves any DMP route field unauthenticated on its immediate link requires reopening this spec; do not create a custom tag or accept unauthenticated framing.

Consequences:

- On-link modification/replay is rejected by the immediate link session/provider.
- Per-hop authentication says only which immediate neighbor sent that record. It does not authenticate earlier relays, prevent a relay from dropping/forking/rewriting the next envelope, or prove a route.
- The outer envelope is not protected by one end-to-end AEAD AAD because TTL/hop legitimately change. Current v1's 27-byte AEAD-AAD header cannot be repurposed or mutated under its existing tag.
- The E2E provider authenticates the immutable inner payload. DMP's application-supplied E2E AAD is empty as defined in §5.1; no TTL/hop/destination token is E2E AAD.

If the selected provider cannot provide these link/session properties without custom cryptographic code, reopen the design rather than inventing a link scheme.

## 7. Relay processing and TTL/hop semantics

For each received per-hop record, an honest relay follows this order:

1. Let the secure-channel provider authenticate and replay-check the immediate link record before application parsing.
2. Bound encoded size; decode deterministic CBOR; require exact map keys/version/types; reject oversized or malformed values without state mutation.
3. Validate `fragment_count`, index, total ciphertext length, fragment bytes, `ttl_remaining <= MAX_HOPS`, and `hop_count <= MAX_HOPS`; reject wraparound/inconsistent metadata.
4. Check a bounded dedupe cache keyed by `(packet_id, fragment_index)`; an exact duplicate is idempotent. Conflicting duplicate metadata/bytes rejects the assembly. Cache lifetime and quotas are required build-time policy values.
5. If this node is the intended destination, reassemble under per-peer/global/time limits and pass only the complete ciphertext to the E2E provider. Decrypt/authenticate first, compare inner/outer message IDs and recipient, then atomically commit replay/ratchet/inbox state. A TTL of zero does not prevent delivery at the node that received it; it only prevents another forward.
6. If forwarding is allowed and `ttl_remaining > 0`, emit a new envelope with the same immutable fields and E2E fragment, `ttl_remaining - 1`, and `hop_count + 1`. Reject if hop count would exceed `MAX_HOPS`; never wrap. Re-encode deterministically and send in a fresh next-hop secure record.
7. If `ttl_remaining == 0`, do not forward. Queue/rate/resource limits apply regardless of authentication.

A candidate invariant for honest processing is `ttl_remaining + hop_count <= MAX_HOPS`; source initializes `ttl_remaining = H`, `hop_count = 0`. Each honest forwarding step preserves the sum. A malicious relay can reset these mutable fields and create a fresh link record; the receiver cannot prove actual path length from them. This envelope therefore **does not cryptographically enforce a global hop budget**. `MAX_HOPS` itself is an unapproved routing/resource policy value; select and review it without changing current simulator defaults.

## 8. ACK profile and replay handling

Transport completion, relay queue acceptance, and recipient acceptance are distinct states:

- **Link ACK/completion:** provider/OS says the immediate record was accepted/delivered at its documented boundary; not recipient delivery.
- **Relay-store ACK (optional):** explicitly identifies a relay and the declared queue durability; not proof the relay will forward.
- **Recipient ACK:** only this may mean recipient acceptance. It is an E2E encrypted `E2EMessagePayloadV2` with `content_type = 1`; its `body` is deterministic-CBOR `AckPayloadV2`:

| Label | Type | Meaning |
|---:|---|---|
| `0` | `uint`, `2` | ACK schema version |
| `1` | `bstr(16)` | Random `ack_id`, unique to the ACK message |
| `2` | `bstr(16)` | `acked_message_id` |
| `3` | `uint`, exactly `1` | Status `durably_accepted`; no “read/displayed” status in this profile |

The recipient emits this ACK only after the E2E message, receive/replay state, and inbox row are committed atomically. The E2E provider authenticates the ACK sender/device and protects it like any other message. Sender accepts an ACK only from the intended recipient for a known outstanding message ID; records ACK IDs idempotently. Replayed/duplicate valid ACKs do not alter state twice; a duplicate accepted message may cause the same durable ACK to be resent. ACK loss can leave sender pending even when the recipient committed; relay availability is not guaranteed.

## 9. Key lifecycle, error handling, and state mutation

- Generate private keys through the selected provider/platform boundary; never store raw private material in UI or ordinary application state. Hardware-backed support must be measured separately on each platform.
- Generation 1 binding starts with predecessor `null`. Static-key rotation uses a signed higher generation and exact previous-binding digest. Lower/same-conflicting generation, bad chain, expired/not-yet-valid binding, invalid signature, unsupported suite, or mismatched Noise static is rejected.
- Root-key change requires an old-root continuity mechanism only if old root is not suspected compromised; otherwise it requires an out-of-band new contact verification. Revocation/recovery formats are not yet defined.
- Before E2E authentication, do not advance ratchet/replay state, persist an inbox message, or send a recipient ACK. Before an outgoing encrypted message is persisted with its send state, do not transmit it. Retries reuse the same E2E ciphertext and `packet_id`; a different plaintext requires a fresh provider state/nonce as defined by the provider.
- Failure responses are local typed errors and do not echo secret/provider details to relays. Proposed codes: `unsupported_version`, `noncanonical_encoding`, `malformed_binding`, `bad_signature`, `binding_expired`, `generation_rollback`, `static_key_mismatch`, `handshake_auth_failed`, `link_replay`, `frame_too_large`, `bad_fragment`, `duplicate`, `ttl_exhausted`, `e2e_auth_failed`, `wrong_recipient`, `ack_invalid`, `storage_commit_failed`. Do not log keys, plaintext, contact names, or full route tokens.
- Malformed input, replay, or failed authentication must not crash, allocate attacker-selected memory, leak secret diagnostics, mutate trust state, consume a receive key, or report delivery.

## 10. Compatibility and migration

The current reference's 27-byte `{msgIdDigest, ttl, type, destHint, hop}` packet header is AEAD AAD. The simulator forwards mutable `MeshMessage` objects and does not serialize this packet. DMP v2 must remain a separate versioned format; do not reinterpret v1 bytes, alter existing tests/golden vectors, or claim that simulator routing proves DMP compatibility.

- A v2-only implementation rejects a v1/unversioned packet as unsupported for verified messaging.
- If a legacy reader is separately authorized, it must be isolated, visibly labeled legacy/unbound, and never auto-promoted to v2 verified trust.
- Migration requires fresh signed binding, re-verification, explicit contact/session reset rules, versioned vectors, and a rollback plan. No compatibility fallback may accept unbound keys while displaying “verified.”
- Version selection is fixed at v2/suite 1 in this draft. Future negotiation must bind exact offers into a signed binding and authenticated transcript; it is not implicit.

## 11. Test vectors and approval blockers

No cryptographic test vectors are included. There is no selected maintained mobile provider, no approved schema, no independent second implementation, and no independent vector verification. The tables above are schema examples, not key/signature/ciphertext vectors. Do not turn them into tests that bless this draft before review.

Before implementation, the owner/security reviewer must approve (or replace) the binding container, exact COSE/CBOR rules, lifetime/clock/revocation policy, suite/provider, human verification policy, E2E plaintext/associated-data profile, route-token source/privacy, hard packet/fragment/queue limits, ACK durability semantics, and any v1 migration. An independent cryptographic reviewer must assess binding, handshake, provider composition, authenticated fields, replay, and relay limits. Platform specialists must validate Android/iOS key storage and secure-record behavior. Only then may deterministic vectors be generated and independently checked.

**Implementation stop remains active.** This document does not authorize a new protocol, packet format, production crypto integration, fixture, or source change.
