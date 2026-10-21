# 04 — Security, Privacy & Threat Model
## E2EE Without Servers, Without Internet

---

### 1. Threats Duman Must Survive

- **Passive eavesdropper** nearby with BLE sniffer.
- **Active relay attacker** who forwards/modifies msgs.
- **Impersonation:** “I am Alice” without proof.
- **Denial of mesh** (jamming, battery drain attack).
- **State actor** who seizes phone or compels App Store takedown (India 2026 case [1](https://cyberpeace.org/resources/blogs/when-bluetooth-became-a-battleground-inside-indias-bid-to-block-bitchat-briar-and-bridgefy)).
- **No CA available offline** — cannot phone home to verify.

---

### 2. Identity Without Server

| Concept | Duman Choice |
|---------|--------------|
| Long-term identity | Ed25519 + X25519 keypair generated on first launch, stored in secure enclave/keystore |
| Human name | User-chosen handle (no phone number). Uniqueness not guaranteed globally — uniqueness is per-contact. |
| Trust on first use | **QR exchange** (Briar model [2](https://briarproject.org/index.html)): scan QR → exchange 32-byte pubkeys out-of-band. QR contains `pubKey + shortAuthString (8 chars)` |
| Optional link | If not in person, share `duman://add?pub=...&sas=...` over any side channel (then verify SAS verbally) |
| No central registry | Identity = keypair, not username. |

---

### 3. Encryption

- **1:1 DM:** **Noise_XX** (or X3DH + Double Ratchet light) with forward secrecy. Initiated via BLE handshake when peers first meet; session keys ratchet per message. Libsodium / Dart `cryptography`.
- **Group chat:** **MLS-style** or simple sender-key distribution over 1:1 channels: each group has `groupKey` rotated on member leave; stored encrypted.
- **Broadcast/pager channel:** **Not private** by design (like walkie channel). Option to create encrypted broadcast group with shared key.
- **At rest:** Encrypted SQLite (SQLCipher) + OS keystore; panic wipe = overwrite key.

**Why not TLS/PKI:** No internet to reach CA. Must be **trust-on-first-use + SAS verification**.

---

### 4. Message Format (encrypted payload)

```
header (plaintext for routing): {msgId, ttl, hopCount, destHint (hashed), type, priority}
ciphertext (Noise sealed): {fromPubKey, timestamp, body, padding}
auth tag: HMAC or AEAD tag (AES-GCM / ChaChaPoly)
```
- `destHint` = truncated hash of dest pubKey (8 bytes) so relays can route without learning full identity; only intended dest can fully verify.
- Padding to 256-byte blocks to hide length.

---

### 5. Relay Privacy

- SUPER nodes **cannot read** E2EE DMs — they see only header.
- No IP metadata — Briar advantage (no metadata to subpoena [3](https://yolah.fr/vpn-security/briar-offline-messaging-resilient/)).
- Mitigate traffic analysis: random jitter 50-200 ms before forwarding, dummy beacons at low rate.

---

### 6. Abuse & Safety (No Moderation Server)

- **Block/mute peer** locally (ignore msgs from pubKey).
- **Rate limit:** Max 5 broadcasts / minute per node; SUPERs drop excess.
- **Battery drain attack:** Cap relay to 30 msgs/min per source; ignore floods.
- **SOS misuse:** SOS channel is opt-in; user must toggle to listen (avoid spam).

---

### 7. Compliance Notes

- Comply with **GDPR by design**: No data leaves device to server; all PII is local.
- Export crypto note: Use standard libsodium (no custom crypto).
- Store listing: Prepare for takedown resilience — publish **APK + F-Droid + GitHub Releases** alongside Play/App Store.

---
**Audit plan:** Cure53-style review at end of Phase 3 (after E2EE implemented, before PTT). Budget for external audit.
