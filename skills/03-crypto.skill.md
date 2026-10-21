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
- [ ] 2 peers: QR exchange → Noise handshake → E2EE DM that SUPER cannot decrypt (capture test)
- [ ] Forward secrecy: compromise after = cannot decrypt prior (ratchet verify)
- [ ] Audit checklist: no plaintext PII in logs, destHint leaks only 8B hash
