# Skill 03 — E2EE & Identity

**Goal:** No server, no phone number, no CA — yet private, authenticated, forward-secret.

### Identity
- Keygen on first launch: `Ed25519 (sign) + X25519 (exchange) + 32B nodeId = hash(pubKey)`
- Storage: Android `StrongBox/Keystore`, iOS `SecureEnclave`/`Keychain`
- Add-contact: QR = `base64(pubKey || sas8)`; display SAS 3×3 emoji or 8-char string for verbal verify

### 1:1 Channel
- Handshake: **Noise_XX** (`-> e, <- e, ee, s, es -> s, se`) over BLE GATT; no internet RTT
- Transport: ChaCha20Poly1305 or AES-GCM; ratchet per message (Double Ratchet light) for FS
- Session resumption: cached `sessionId` if peer met again within 7 days

### Group
- GroupKey distributed over pairwise Noise channels on create/add member; rotate on member removal
- Group messages: sender encrypts with GroupKey + signs with Ed25519

### Broadcast pager
- Public channel = plaintext (intentional). Encrypted broadcast variant = group with shared key.

### Packet

> **Implementation note (Oct 2026 — evidence in `docs/07-e2ee-noise-xx.md` §4):** the packet is now the simulator's size model too, in both engines:
> `wireSizeOf(body) = ceil((95 + body) / 256) × 256` with `PACKET_OVERHEAD_BYTES` 95 and
> `PAD_BLOCK_BYTES` 256 exported and the BLE/Wi-Fi boundary pinned by tests at 900 characters
> (1 024 B, still BLE) and 930 (1 280 B, Wi-Fi Direct). The previous `64 + 4 bytes per character`
> heuristic crossed the 1 KB ceiling at 241 characters, which put ordinary long texts on the fast
> transport and made their latency look three times better than a BLE deployment would deliver.
```
header {msgId16, ttl, type, destHint8, hop}
aead {nonce12, ciphertext, tag16} // ciphertext = from(32), ts(6), len(2), body, pad256
```

> **Implementation note (Oct 2026 — `src/crypto/packet.ts`, evidence in `docs/07-e2ee-noise-xx.md` §4):** this layout is now serialised for
  real, and building it corrected two things. `ts` is **6** bytes and the 2 that frees up hold the body **length**: the padding is zeros, and
  zero padding is ambiguous for a binary body — a media chunk can legitimately end in `0x00` — so a reader needs the length. The alternative
  (a mandatory `0x80` marker) needs no length field but costs a whole extra 256 B block whenever `95 + body` is already a multiple of 256,
  and **929 is exactly such a body**, the size `docs/08` §5.3 uses to derive the 14.9 kbit/s PTT ceiling. Six-byte milliseconds run to the
  year 10889 and the total stays 95 B, so every published size survives. `msgId16` is `SHA-256(msgId)[0:16]`, not the id: the engine's ids
  are short and sequential, and putting one in a plaintext header leaks the sender's counter and send rate to every relay.

### Do / Don't
- DO use libsodium via FFI; never custom crypto
> **Implementation note (Oct 2026 — `src/crypto/primitives.ts`):** this rule is about *primitives*, and `src/crypto/` keeps it: X25519,
  ChaCha20-Poly1305, Ed25519, SHA-256 and HMAC all delegate to OpenSSL through `node:crypto`, behind one `CryptoPrimitives` interface so the
  app can put libsodium or Dart's `cryptography` behind the same seam without the protocol layer being rewritten. What `src/crypto/` does
  implement is the protocol *above* them — the XX state machine, the ratchet, the SAS, the packet — which no library supplies and which is
  what the acceptance criteria below are about. It is a reference implementation and says so at the top of every file: no constant-time
  guarantees of its own, key material in garbage-collected buffers. Ship the libsodium build.
- DO pad to 256B blocks
- DON'T rely on phone number or server-issued cert
- DO implement panic wipe: zero keys + overwrite DB + toast

### Acceptance

> **Implementation note (Oct 2026 — `sim/mesh_sim` + `src/`, evidence in `docs/06-simulator-findings.md` §14):** the group *membership and epoch* semantics this skill depends on are
> already implemented and pinned by tests in both engines — 3-10 members, admin-only rotation, rotation
> on every join and leave, and a copy whose epoch does not match the receiver's rejected rather than
> delivered. What the simulator does not implement is any of the cryptography below: its "cannot decrypt" is an epoch
> comparison, not a cipher. Treat the simulator as the specification of *when* a key must change and
> *who* may read what, and this skill as the specification of how.
>
> **Amended (Oct 2026 — `src/crypto/`, 87 tests, `npm run e2ee crypto`).** This note said there is no handshake, no ratchet and no SAS in
> the repository. There now is, as a **reference protocol layer over OpenSSL** — Noise_XX, a per-message ratchet, both SAS values, the QR
> flow and the packet serialised for real. Still true and unchanged: the *simulator* has no cipher in it, sender-key distribution is not
> built, and nothing here is production cryptography.

**Scope of the ticks below:** they mean the protocol layer is implemented and tested in `src/crypto/`. They do **not** mean a phone can do
this — there is no app, no BLE GATT transport for the legs to travel on, and no keystore behind the keys.

- [x] 2 peers: QR exchange → Noise handshake → E2EE DM that SUPER cannot decrypt (capture test)
> Met by `src/crypto/session.ts` + `src/crypto/__tests__/session.test.ts` and reported by `npm run e2ee crypto`. The capture test is written
  so that it means something: the relay is a **legitimate peer of the sender**, holding a real message key legitimately derived from its own
  XX session with her — same sender, same message number, different recipient, different chain. It reads the header and nothing else, and
  `openPacket` fails `auth-failed`. A relay holding a random key fails too and proves nothing.
- [x] Forward secrecy: compromise after = cannot decrypt prior (ratchet verify)
> Met by `src/crypto/ratchet.ts`. The test names the state an attacker actually gets (`compromise()` — both chain keys, both counters, the
  skip cache), rebuilds a ratchet from nothing but that, and shows messages already read are unreachable while the next one is not. The mesh
  forced one design decision the criterion does not mention: the ratchet must tolerate out-of-order arrival, so the receiver caches keys it
  derived ahead of itself, and that cache is **bounded at 64** because an unbounded one is a denial of service — a peer claiming message
  number 2^40 would otherwise force 2^40 derivations.
- [ ] Audit checklist: no plaintext PII in logs, destHint leaks only 8B hash
> Partly met, and the criterion needs rewording. `relayVisible()` in `src/crypto/packet.ts` returns exactly what a relay may read and is
  asserted to have no `to` and no `from` field; the capture log (`docs/06` §13) records ids, reasons and dBm and no body. But "leaks only an
  8 B hash" measures the wrong thing: implemented literally against `docs/05`'s `nodeId = SHA-256(pubKey)`, the hint **is** `nodeId[0:8]` — a
  prefix of a value `docs/02` §2 broadcasts every 2 seconds. A relay that can route the packet has already heard the destination's nodeId. The
  hint buys a shorter label (8 B instead of 32, 9 % of a padded block) and friction for a sniffer that never collected OGMs; it does not hide
  an identity. `docs/04` §4 and `docs/07` §6 carry the correction, and the engine's own `destHint` is neither field — it is a 32-bit string
  hash of the node id (`docs/06` §9). Left unchecked until the criterion says what it can actually require.
