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
aead {nonce12, ciphertext, tag16} // ciphertext = from, ts, body, pad256
```

### Do / Don't
- DO use libsodium via FFI; never custom crypto
- DO pad to 256B blocks
- DON'T rely on phone number or server-issued cert
- DO implement panic wipe: zero keys + overwrite DB + toast

### Acceptance

> **Implementation note (Oct 2026 — `sim/mesh_sim` + `src/`, evidence in `docs/06-simulator-findings.md` §14):** the group *membership and epoch* semantics this skill depends on are
> already implemented and pinned by tests in both engines — 3-10 members, admin-only rotation, rotation
> on every join and leave, and a copy whose epoch does not match the receiver's rejected rather than
> delivered. What is not implemented is any of the cryptography below: there is no handshake, no
> ratchet, no sender-key distribution and no SAS in the simulator, and its "cannot decrypt" is an epoch
> comparison, not a cipher. Treat the simulator as the specification of *when* a key must change and
> *who* may read what, and this skill as the specification of how.
- [ ] 2 peers: QR exchange → Noise handshake → E2EE DM that SUPER cannot decrypt (capture test)
- [ ] Forward secrecy: compromise after = cannot decrypt prior (ratchet verify)
- [ ] Audit checklist: no plaintext PII in logs, destHint leaks only 8B hash
