# Packet and forwarding format — proposal

**Status:** Conceptual design; **no wire format is frozen or implemented.** The current TypeScript packet and simulator routing behavior were inspected on source snapshot `a1f1916981c2244a2f8664573b66afbd5a2659b4`. This proposal does not change source, test fixtures, or golden vectors. See [security architecture](SECURITY-ARCHITECTURE.md), [threat model](THREAT-MODEL.md), and [security review](../../reports/mobile/SECURITY-REVIEW.md).

## 1. Current reference packet and forwarding mismatch

`src/crypto/packet.ts` currently serializes this 27-byte plaintext header:

| Field | Current size | Current meaning |
|---|---:|---|
| `msgIdDigest` | 16 B | `SHA-256(msgId)[0..16]`; visible dedup/correlation token |
| `ttl` | 1 B | Visible remaining TTL value |
| `type` | 1 B | Visible message-type code |
| `destHint` | 8 B | Visible destination hint; current default is the first 8 bytes of `SHA-256(signingPublicKey)`, which is also a prefix of the identity-derived node ID |
| `hop` | 1 B | Visible hop count |

A 12-byte nonce, encrypted payload, and 16-byte AEAD tag follow. The sender public key, timestamp, body length, body, and padding are inside the encrypted payload. The **entire 27-byte header is AEAD associated data**, so modifying `ttl`, `hop`, type, ID digest, or destination hint without the content key makes authentication fail. That is good tamper detection for an immutable header, but it conflicts with a relay that is expected to decrement TTL or increment hop count.

Separately, `src/simulation.ts` receives `MeshMessage` objects, checks expiration, then forwards a cloned object with `ttl: msg.ttl - 1` and `hopCount: msg.hopCount + 1`. The simulator does not route the serialized bytes through `openPacket`/`sealPacket`. The object-level forwarding behavior therefore does not validate that the authenticated packet format supports those mutations and does not demonstrate native relay behavior.

## 2. Design objective: immutable end-to-end content inside mutable forwarding envelope

An **opaque end-to-end ciphertext inside a separately bounded forwarding envelope** is the recommended direction for review. It separates message authenticity from routing. It is not sufficient on its own: the cryptographic provider, outer-field trust rules, link authentication, replay state, and size/fragmentation limits must also be specified.

```text
Plaintext + authenticated E2E context
                 |
                 v
  Reviewed E2E protocol/provider
  [versioned ciphertext / ratchet sequence / authenticated context]
                 |       immutable across every relay
                 v
  +-------------------------------------------------------------+
  | Mutable forwarding envelope                                 |
  | packet_id, destination token, route class, TTL/hop, fragment |
  +-------------------------------------------------------------+
                 |
                 v
  [neighbor-A secure record: link counter + integrity/auth tag]
                 |
              Relay A -- validate A-link; bound/deduplicate;
                 |        change only allowed outer metadata
                 v
  [neighbor-B secure record: fresh B-link counter + auth tag]
                 |
              Relay B
                 |
              Recipient -- bounded reassembly, E2E verify/decrypt,
                            replay check and durable commit
```

The E2E provider must authenticate all inner fields whose semantics matter (such as message ID, recipient/conversation binding, content type, and protocol version), either as ciphertext/plaintext protected by its standard protocol or as authenticated context supported by that provider. Do not bolt on an ad hoc signature/AEAD format. The application message ID should be random and stable for retries; the provider owns message sequencing, nonces, and ratchet semantics. A source signature on every message is not assumed; whether the selected protocol provides peer authentication is a provider/security-review decision.

## 3. Candidate field inventory (not wire widths or a final schema)

### Immutable end-to-end content

| Data | Visibility | Proposed handling |
|---|---|---|
| Protocol/provider version, cryptographic session context, ratchet number | Recipient/provider only where supported | Encoded and authenticated by the maintained E2E protocol; reject unsupported versions without downgrade. Do not expose a custom ratchet counter in the clear. |
| Random application message ID | Prefer inside E2E content; an opaque packet ID may also be visible outside for forwarding dedupe | Generated once, collision-resistant, retained for retries and inbox idempotency. Do not use a user name, phone number, identity key, or sequential sender counter. |
| Sender/device identity | Encrypted or represented by the provider's authenticated peer state | Bind to the verified device key/session; do not trust an unauthenticated `from` string in an envelope. |
| Message type and payload | Recipient; minimize public type detail | Text/media/control semantics are encrypted unless routing absolutely requires a public class. Public control traffic is explicitly documented as public. |
| Recipient/conversation context | Recipient/provider | Authenticate in the E2E context so ciphertext cannot be transplanted to another conversation/peer unnoticed. |
| Expiry/creation time | Prefer authenticated E2E context; optional bounded outer expiry may be used for resource cleanup | Check clock limitations; a relayed timestamp is not proof of when a message was created. |

The exact E2E library, authenticated data, inner encoding, ID length, and message-size policy remain undecided. Do not infer them from `src/crypto/ratchet.ts`; it is a Node reference, not an approved mobile provider.

### Mutable forwarding envelope

| Candidate field | Relay use | Security/privacy rule |
|---|---|---|
| `format_version` | Select envelope parser | Strict allowlist; reject unsupported version and downgrade. Bound parser input before decoding. |
| `packet_id` | Duplicate suppression and fragment grouping | Random opaque value, stable across hops/retries for one E2E packet, visible correlation handle. Keep a bounded expiring cache. |
| `destination_token` | Route/next-hop lookup | Public to relays. The current 8-byte hash prefix is not identity hiding. Exact token construction, rotation, advertisement, and leakage are unresolved. |
| `route_class` | Select forwarding policy | Minimize and document visible classes; never put plaintext or a trusted sender identity here. |
| `ttl_remaining` | Limit honest forwarding work | Clamp to a hard local maximum; reject invalid/out-of-range values; on an honest forward decrement only. It is mutable and not proof of the actual path. |
| `hop_count` | Diagnostics or best-effort policy | Treat as a claim, not a cryptographic count. Do not use it for trust, billing, or security decisions unless a separately reviewed proof design exists. |
| `fragment_index`, `fragment_count`, `total_ciphertext_length` | Reassemble a large E2E ciphertext | Bounds checked before allocating; counts/total bytes capped by constants selected after device/MTU tests. Conflicting metadata for one packet ID rejects that packet. |
| `expiry_hint` (optional) | Drop stale queued frames | Bounded and advisory; a malicious relay can alter it. E2E expiration semantics require authenticated inner context and an explicit clock policy. |

Field widths, maximum values, CBOR/binary encoding, padding, and a fixed frame limit are deliberately **not** specified here. The simulator's `BLE_MAX_BYTES = 1024` and 256-byte padding are not verified BLE application limits and must not be copied into a mobile contract without measurements.

## 4. Per-hop authentication and relay trust

Each radio/link frame should be carried inside a maintained, authenticated per-neighbor record/session. The record protects the complete frame header and payload with a link-specific key and counter/replay window; after forwarding, a relay emits a fresh record for the next neighbor. Use a reviewed protocol/provider or platform-secure link, not a custom MAC/nonce scheme. Persistent counters and reconnect/reset behavior must prevent nonce reuse and replay.

Per-hop authentication guarantees only that the immediate peer established by that link/session sent those bytes, and that the bytes were not altered on that link. It does **not**:

- make that peer an honest relay or prove earlier hops;
- prevent packet suppression, delay, route manipulation, selective forwarding, or resource-exhaustion attempts;
- stop a relay from rewriting TTL/hop and producing a valid next-hop record;
- hide timing, size, packet ID, destination token, or repeated-route metadata from relays;
- prove that a visible hop count or expiry hint is truthful.

Relays are therefore untrusted for message content and availability. E2E authentication protects message contents; queue quotas, TTL hard caps, dedupe, parser limits, and admission control bound honest/accidental resource use. A malicious relay can still lie or drop.

### TTL/hop invariant and its limit

Proposed honest-node rule: initialize a bounded remaining budget, reject values above the configured maximum, deliver locally if addressed, and forward only when the budget is positive; each forward uses a new envelope with remaining budget decremented and diagnostic hop count incremented. Exact “is a TTL-0 frame deliverable at the receiving node?” and inclusive/exclusive hop semantics must be fixed in a reviewed versioned spec.

Because relays can rewrite mutable fields, a receiver cannot prove that every previous relay decremented a global budget. A hard local cap protects each implementation from obviously excessive values, but a malicious relay can reset claims or fork forwarding. If a cryptographically enforceable global hop bound is a requirement, it needs a separate proof/budget design and adversarial review. Do not claim that outer-field AEAD or per-hop MACs alone solve this.

## 5. Forwarding, deduplication, and acknowledgement flow

1. **Send transaction:** the E2E provider produces one authenticated ciphertext using its serialized session actor. Persist the ciphertext, provider state, stable random message/packet ID, destination token, and retry state atomically before attempting transmission.
2. **Frame:** place the immutable E2E bytes (or one bounded fragment of them) in a versioned forwarding envelope; wrap the complete frame in the current neighbor's authenticated link record.
3. **Receive at relay:** authenticate/replay-check the immediate link record before expensive parsing; enforce length/version/field limits; apply a bounded duplicate key such as `(packet_id, fragment_index)`; enqueue or reject by explicit policy. A relay does not open or rewrite the E2E ciphertext.
4. **Forward:** create a new outer envelope with only approved routing fields updated, preserve packet ID and E2E bytes exactly, and protect it using the next-hop link's fresh record counter/key.
5. **Receive at destination:** reassemble fragments under strict per-peer/per-message/time/memory quotas; reject conflicting fragment metadata; pass the complete ciphertext to the E2E provider. The provider verifies/decrypts and enforces its replay/ratchet state. Commit ratchet/replay state and the inbox row atomically; only then send a message-level acknowledgement.
6. **Retry/reconnect:** retry with the same E2E ciphertext and stable packet ID. Duplicate ciphertext is idempotently recognized; it must not be delivered twice or consume a receive key twice. Link counters are independent per-link state, never reused after a crash/reconnect.

### Acknowledgements are different events

| ACK layer | What it proves | What it does not prove |
|---|---|---|
| Link/transport completion | The local adapter/neighbor accepted a frame according to that API's documented completion point | Not end-recipient delivery or durable recipient storage. |
| Relay/store acknowledgement (if added) | A relay says it accepted a packet into a queue with a defined durability level | Not that it will forward, that the recipient received it, or that the relay is honest. |
| End-to-end application ACK | The recipient's authenticated protocol response refers to the message ID and is sent after the defined recipient-side commit | Not global delivery guarantees; a route can still drop the ACK. The exact meaning—decrypted, displayed, or durably stored—must be explicit. |

An ACK exposed to untrusted relays should not identify plaintext or be forgeable as a recipient ACK. An authenticated end-to-end ACK can itself be relayed in an opaque envelope. Retries and ACKs require stable IDs and idempotent state transitions.

## 6. Fragmentation and size limits

The transport MTU and maximum accepted lengths are platform/device facts to measure, not simulator constants. Before implementation, select and test explicit limits for link frame bytes, full ciphertext bytes, fragment count, incomplete assemblies per peer, total incomplete bytes, queue depth, retry lifetime, and parsing work.

Proposed fragmentation rules:

- Fragment the already-created E2E ciphertext; never encrypt each fragment under an ad hoc independent key or alter the underlying ratchet semantics.
- Include packet ID, fragment index/count, total ciphertext length, and any needed version in bounded outer metadata. Repeated fragments for an ID must agree on count/length and be byte-identical at an already-seen index; conflicting duplicates reject the assembly.
- Accept out-of-order fragments if the selected delivery protocol requires it; handle duplicates idempotently. A missing fragment times out and releases memory.
- Do not allocate from an unauthenticated length/count before checking hard caps. Apply per-peer and global quotas to prevent a malicious neighbor pinning memory.
- Reassemble before E2E verification unless the selected E2E provider has a reviewed streaming-fragment API. An incomplete or unauthenticated ciphertext is never delivered to the application.
- Test interruption, process death, reconnect, retry, duplicate, reordering, truncation, and conflicting fragments. Relays may forward individual fragments, but this choice and any relay-side storage requirement remain to be measured.

No numeric mobile payload or BLE limit is approved here. `BLE_MAX_BYTES` in the simulator is not an OS guarantee.

## 7. Failure behavior and privacy

Reject unknown versions/types, bad lengths, truncated frames, invalid tags, unknown critical fields, inconsistent fragments, invalid counter/replay windows, impossible TTL/hop values, and oversized packets before expensive or state-changing work. Do not crash, log secrets, advance ratchet state, or allocate attacker-selected amounts of memory on failure. Rate-limit repeated malformed traffic per neighbor, with policy that does not block benign retries indefinitely.

Metadata remains observable: packet timing, visible packet ID across copies, destination token, route class, fragment count/size, link peers, and traffic volume. Padding may reduce some size leakage but costs airtime and does not hide timing/routing. Stable identity IDs should not be broadcast as route keys. No anonymity or traffic-analysis resistance claim is made.

## 8. Migration and compatibility

The current 27-byte AAD header cannot be silently repurposed as a mutable forwarding envelope: changing TTL/hop currently invalidates its authentication tag. A versioned new frame must keep the current format and golden vectors distinct, or explicitly migrate them under owner authorization. Never add a compatibility fallback that accepts unauthenticated or unbound fields while claiming the new protocol's trust level.

The simulator currently forwards typed `MeshMessage` objects, not this crypto packet. Future parity tests must separately verify that the simulation's routing semantics are unchanged and that the production codec's allowed mutations preserve the exact E2E ciphertext. No simulator result alone proves on-device framing or relay interoperability.

## 9. Owner review questions

- Approve or reject the two-layer opaque-E2E-content/mutable-envelope direction?
- Which routing token and packet ID are visible, stable, rotated, and privacy-reviewed?
- Are TTL/hop fields advisory only, or is cryptographically verifiable global budget required?
- What packet/message/frame/fragment limits match Android↔Android, iOS↔iOS, and Android↔iOS hardware?
- Which layer's ACK is exposed to the user, and what exactly does it mean?
- Which reviewed E2E/link protocol implementation owns AEAD, nonce/counter, ratchet, and replay handling?

No packet-format changes should be implemented before these decisions and the test plan are reviewed.
