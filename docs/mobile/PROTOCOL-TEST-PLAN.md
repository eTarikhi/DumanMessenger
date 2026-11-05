# Protocol verification and test plan

**Status:** Proposed tests for an owner-approved protocol; these tests are not implemented or passed. No source, packet format, fixture, golden vector, routing default, or test timeout changed. Evidence baseline is `a1f1916981c2244a2f8664573b66afbd5a2659b4` (2026-11-05). See [security architecture](SECURITY-ARCHITECTURE.md), [identity and keys](IDENTITY-AND-KEYS.md), [packet format](PACKET-FORMAT.md), and [security review](../../reports/mobile/SECURITY-REVIEW.md).

## 1. Test layers and evidence boundaries

| Layer | What it should test | What it cannot prove |
|---|---|---|
| **Existing simulator regression** (`src/`, `sim/mesh_sim/`) | Preserve modeled routing, radio, queues, TTL/hop object semantics, and shared vectors. Existing simulator tests remain unchanged unless separately approved. | Does not parse/forward the serialized crypto packet, prove mobile crypto, BLE, OS storage, or handset delivery. |
| **Reference/provider and codec tests** | Fixed standard/provider vectors; identity binding parser/signature; pure codec bounds; Noise/provider handshakes; E2E replay/ratchet state. Node reference tests are not production-mobile evidence. | Does not prove Dart/native/provider parity or OS key storage. |
| **Mobile core/persistence tests** | Flutter/Dart orchestration, transactional state, retry, reassembly, lifecycle/corruption behavior with fakes and deterministic clocks. | Does not prove native radio, Android Keystore/Secure Enclave, real BLE, or cross-device interoperability. |
| **Android/iOS host tests** | Kotlin/Swift bridge, permission mapping, capability reporting, cancellation, platform key API, native framing, process/background transitions. | Emulator/simulator results do not prove physical radio, vendor behavior, or battery/thermal characteristics. |
| **Physical-device tests** | Android↔Android, iOS↔iOS, and Android↔iOS radio/protocol interoperability, loss/retry/restart, key verification and supported lifecycle states. | A finite device set is not a universal guarantee; record exact model, OS, app build, test procedure, and result. |

Do not merge these evidence categories in summaries. No device/toolchain is available in the current Linux checkout, and no mobile test has run.

## 2. Existing baseline to preserve

The full TypeScript baseline is **517/527 passing; ten tests time out at the unchanged 5,000 ms limit**. Typecheck, browser build, deployment suite, and static documentation/Dart-source checks are separately recorded in [TEST-RESULTS.md](../../reports/mobile/TEST-RESULTS.md). The Dart test suite, Flutter tests, native builds, and device tests are unavailable here.

The simulator routes mutable `MeshMessage` objects; the crypto packet codec is not integrated into that route path. Existing simulator tests may validate modeled TTL/hop and forwarding behavior, but must not be described as packet-codec or mobile relay verification. Do not change tests, goldens, timeout, routing defaults, or semantics to make this plan pass.

## 3. Identity, binding, and contact trust tests

| ID | Layer | Scenario | Required result |
|---|---|---|---|
| ID-01 | Provider/codec | Valid signed binding with matching Ed25519 key, X25519 static, generation, suite, and validity | Parse and verify using selected standard/provider vectors; contact remains unverified until the required human step. |
| ID-02 | Provider/codec | Substitute a different Ed25519 public key, X25519 public key, binding payload, signature, or subject fingerprint independently | Reject; never associate the changed exchange key with the pinned identity. |
| ID-03 | Provider/codec | Truncated/oversized keys, bad Ed25519 encoding/signature, low-order/invalid X25519 input, all-zero DH result | Reject before session creation; no crash, state update, or secret diagnostic. |
| ID-04 | Provider/codec | Invalid COSE structure, duplicate CBOR map keys, non-deterministic encoding (if canonical form is required), trailing bytes, missing/wrong-type field, unknown critical field | Reject consistently across runtimes; bound allocation and parsing work. |
| ID-05 | Provider/codec | Unknown schema version, altered algorithm, weaker suite, missing binding, v1/unbound fallback attempt | Reject with explicit unsupported/unbound state; no silent downgrade. |
| ID-06 | Provider + mobile | QR payload has valid identity fingerprint but a different signed binding/static key | Show identity mismatch; do not proceed as verified. |
| ID-07 | Provider | Signed binding expired, not-yet-valid, implausible clock, malformed/overflow timestamp | Follow documented clock policy; fail closed or require an explicit recovery path, never silently ignore validity. |
| ID-08 | Mobile persistence | Lower generation after a newer pinned generation; same-generation conflicting key; invalid previous digest or fork | Reject and preserve high-water state; show contact-change warning. |
| ID-09 | Mobile persistence | Valid X-key rotation under same Ed root with generation increment and predecessor digest | Accept only under reviewed rotation policy; update pin atomically and notify user/peer. |
| ID-10 | Mobile/pairwise | Ed-root rotation with valid old-root cross-signature; root compromised/unavailable; stale revocation | Require explicit reviewed recovery or out-of-band re-verification; never treat compromised-root signature as sufficient. |
| ID-11 | Mobile persistence | Clock rollback, stale encrypted backup, app reinstall, missing generation/replay state | Detect where possible; refuse unsafe session resume or require re-verification; no silent trust downgrade. |
| ID-12 | Handshake | Noise remote static differs from X25519 key in the validated signed binding | Abort terminally, erase ephemeral/session material, and do not deliver or ACK application content. |
| ID-13 | Handshake | Prologue changes protocol version, role/order, identity fingerprint, binding digest, or suite | Handshake/SAS differs or fails; both peers must use the same explicitly versioned context. |
| ID-14 | Handshake/mobile | QR fingerprint SAS matches but fresh handshake SAS does not; or handshake SAS mismatch | Keep contact unverified/failed; show actionable mismatch warning; do not retry as a verified peer. |
| ID-15 | Handshake/mobile | Correct independent handshake SAS comparison; repeated session and key rotation | Promote only the intended contact/device; persist verification state; do not confuse QR and transcript SAS. |
| ID-16 | Mobile/pairwise | QR swapped/replayed, wrong contact selected, misleading display name/handle | Cryptographic contact key remains distinct from local label; require explicit comparison and confirmation. |

## 4. E2E packet, forwarding, and parser tests

The exact new wire format and bounds are owner decisions. These cases become executable only after a versioned schema is approved.

| ID | Layer | Scenario | Required result |
|---|---|---|---|
| PK-01 | Provider | Flip, truncate, splice, or replace a byte in the immutable E2E ciphertext or authenticated inner context | Provider rejects; no plaintext, ratchet advancement, inbox commit, or recipient ACK. |
| PK-02 | Link + forwarding | Alter a frame in transit on one authenticated neighbor link | Per-hop record verification/replay check rejects; no forwarding side effect. |
| PK-03 | Forwarding | Honest relay decrements bounded TTL and updates hop metadata, then creates a new next-hop link record | E2E ciphertext and stable packet ID are byte-identical; next hop validates its own record. |
| PK-04 | Forwarding | Relay changes outer TTL/hop and produces a valid outgoing link record | Documented behavior: outer claim may change; receiving node enforces local limits and never treats claimed path/hop count as proof. E2E authentication still succeeds only for unchanged content. |
| PK-05 | Forwarding | Attempt to increase TTL above hard maximum, use negative/overflow/out-of-range values, or forward at exhausted budget | Reject/suppress according to exact reviewed TTL semantics; no policy bypass through integer wrap. |
| PK-06 | Forwarding | Malicious relay resets/decrements hop count incorrectly, forks packet, or replays it with a fresh outer frame | Duplicate/replay controls remain idempotent; path/hop claim is not trusted; no duplicate app delivery. Record residual DoS/availability risk. |
| PK-07 | Codec | Truncated header/frame, impossible length, unknown type/version, invalid encoding, trailing bytes | Reject before large allocation or state mutation; error is bounded and does not crash the app. |
| PK-08 | Codec/fuzz | Random and structured fuzzing of envelope, COSE/CBOR, packet, and fragment parsers | No crash, unbounded allocation, secret log, ratchet advance, or differential acceptance across supported runtimes. |
| PK-09 | Dedup | Same packet over two routes; duplicate at same relay; retry after lost link ACK; duplicate after app restart | One logical inbox item/ACK; cache bounded and expiration documented; retries reuse stable packet ID/ciphertext. |
| PK-10 | Replay | Replay old valid E2E ciphertext with fresh outer envelope/link record | E2E protocol/replay state rejects or identifies duplicate; no second delivery or key reuse. |
| PK-11 | Routing privacy | Observe destination token, packet ID, message type, sizes, timing, and repeated traffic | Verify only approved fields are visible; document correlation; do not assert anonymity or identity hiding. |
| PK-12 | Size limits | Just-below/at/above every approved frame, packet, message, and queue limit | Accept only within reviewed bounds; oversize is rejected before expensive decode/allocation. |

## 5. Fragmentation and resource-exhaustion tests

| ID | Layer | Scenario | Required result |
|---|---|---|---|
| FR-01 | Mobile core | Fragmented ciphertext arrives in order, out of order, with duplicate identical fragments | Reassemble once under configured bounds; final ciphertext is byte-identical; E2E provider verifies it. |
| FR-02 | Mobile core | Missing fragment, disconnect, process death, reconnect, retry, assembly expiry | Bounded cleanup/recovery; retry is idempotent; incomplete data is never delivered. |
| FR-03 | Mobile core | Same packet ID with inconsistent count/total length or conflicting bytes for one index | Reject assembly; no ambiguous selection or plaintext delivery. |
| FR-04 | Parser/resource | Attacker-supplied huge total length/count, zero count, index out of range, integer overflow | Reject before allocation; memory remains within hard limits. |
| FR-05 | Mobile/core | Many incomplete assemblies, many peers, queue flooding, repeated malformed frames | Per-peer and global limits/rate policy cap memory, CPU, disk, and radio work; app remains responsive. |
| FR-06 | Physical device | MTU negotiation, one-byte boundary, disconnect between fragments, Android↔iOS different link sizes | Actual limits and failures recorded by device/OS; no simulator-only assumption about BLE payload. |

## 6. Ratchet, reliability, and malicious-relay tests

| ID | Layer | Scenario | Required result |
|---|---|---|---|
| RR-01 | Provider | Replay same authenticated message number/nonce | Reject/idempotently classify duplicate; never decrypt/deliver twice or advance state twice. |
| RR-02 | Provider | Reorder within and beyond the reviewed out-of-order window; skipped-key cache exhaustion | Accept only permitted order/window; bounded cache; request safe resync or re-handshake when required. |
| RR-03 | Mobile persistence | Concurrent sends/receives from UI, radio, and lifecycle callbacks | Per-peer serialization prevents races and duplicate sequence/nonce. |
| RR-04 | Mobile persistence | Crash after sequence reservation, ciphertext creation, outbox commit, native send, receive-authentication, inbox commit, and ACK creation | Recovery is atomic at every boundary; no nonce reuse, lost ratchet advancement, duplicate message, or false delivery state. |
| RR-05 | Mobile persistence | Disk full, write failure, database corruption, interrupted migration | Fail closed; do not transmit uncommitted ciphertext or consume an unauthenticated receive key; report recoverable state. |
| RR-06 | Link + device | Retry a lost Noise handshake leg, simultaneous open, interruption at each leg | Retries are byte-for-byte as specified by selected provider; no ephemeral reuse across abandoned handshakes; UI progress is accurate. |
| RR-07 | Relay simulation/core | Relay unavailable, disappears mid-forward, queues then drops, selectively forwards, delays beyond expiry | Sender stays pending/failed with honest state; bounded retries; no claim of recipient delivery. |
| RR-08 | Relay simulation/core | Relay forges a link-level or store ACK, replays old ACK, drops end-to-end ACK | Only an authenticated recipient ACK reaches “recipient accepted” state; relay ACK has distinct weaker status. |
| RR-09 | Relay simulation/core | Malicious route advertisement, duplicate/fork, incorrect TTL/hop, repeated reconnect | No plaintext exposure or duplicate delivery; quotas and local forwarding limits hold; delivery may fail without false success. |
| RR-10 | Mobile/device | Force-stop, reboot, OS process eviction, permission revocation, radio off/on, app upgrade | State and user status remain consistent; no key/counter reuse; explicit behavior on every platform. |

## 7. Cross-runtime and platform verification

Before interoperability work, publish fixed, versioned synthetic vectors for:

- Ed25519 binding signature and validation (valid, modified payload, wrong key, invalid encoding).
- COSE/CBOR payload parsing and deterministic encoding (if approved).
- Noise handshake, prologue, remote-static comparison, SAS derivation, and all failure cases using the selected provider's test vectors.
- E2E provider ciphertext, authenticated context, replay, reordering, and retry semantics.
- Forwarding-envelope encoding, per-hop record validation, ID/TTL/fragment boundaries, and canonical failures.

Run the same vectors in provider/reference harnesses and mobile core; compare exact bytes only where the selected standard defines deterministic output. Do not silently update expected values. Changes to protocol version, test vectors, or golden fixtures require an explicit review and migration note.

Android and iOS host tests must separately exercise the actual key-storage/provider APIs, serialization/transactions, native bridge, permission denial, link cancellation, app lifecycle, and failure reporting. Physical tests must name the phones, OS versions, app build, transport state, test data (synthetic only), and evidence. Minimum required physical pair: one supported Android phone and one supported iPhone, plus same-platform pairs for Android↔Android and iOS↔iOS claims.

## 8. Pass criteria and reporting

A protocol test gate is not passed until:

1. Owner-approved versioned identity, handshake, packet, rotation, replay, ACK, and fragment specifications exist.
2. A maintained provider and platform key boundary are selected and independently reviewed.
3. All applicable negative, malformed, replay, crash, retry, downgrade, and resource-bound tests pass without weakening assertions or increasing/removing timeouts.
4. Shared vectors agree across all supported runtimes; regression tests preserve the simulator semantics and existing vectors.
5. Android and iOS builds/tests pass on their supported toolchains; emulator/simulator and physical-device evidence are reported separately.
6. Android↔Android, iOS↔iOS, and Android↔iOS physical tests exercise interruption, malicious/unavailable relays, duplicates, and verified/unverified contacts.
7. Logs and artifacts contain only synthetic identities/payloads and no secrets.

Current status: **not run / not passed**. The current TypeScript full-suite timeouts are recorded separately; they are not protocol test results. See [performance investigation](../../reports/mobile/PERFORMANCE-INVESTIGATION.md) and [toolchain requirements](../../reports/mobile/TOOLCHAIN-REQUIREMENTS.md).
