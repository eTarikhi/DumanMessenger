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
> **Implementation note (Oct 2026 — `src/crypto/`, 87 tests, `npm run e2ee crypto`; evidence in `docs/07-e2ee-noise-xx.md` §6–§7):** the protocol layer this
  describes is built as a reference implementation over OpenSSL primitives — XX, a per-message ratchet for the forward secrecy, both SAS values, and the
  packet serialised for real. No primitive is hand-written, so "Libsodium / Dart `cryptography`" is still what ships; `src/crypto/primitives.ts` is the
  seam they go behind. Three numbers it produced: handshake legs are **32 / 96 / 64 B** and fit one unfragmented 247 B GATT write each, a full handshake
  is **1 062 µs of CPU against 675 ms of radio** at one hop, and a relay holding a legitimate key from its own session with the sender reads the header and
  nothing else.
> **Implementation note (Oct 2026 — evidence in `docs/07-e2ee-noise-xx.md` §2):** the handshake is three mesh messages, so the §5 budget below applies
> per *leg* and establishment needs roughly three times it — measured 675 ms at one hop, 6.7 s at three,
> and one leg lost outright at four hops in a 60-node crowd. Establishment also has to be **on demand**:
> §3 measures ~70 new in-range peers per node per hour in a crowd, so handshaking on discovery would
> cost ~210 radio messages per node per hour of key agreement with strangers.
- **Group chat:** **MLS-style** or simple sender-key distribution over 1:1 channels: each group has `groupKey` rotated on member leave; stored encrypted.
> **Implementation note (Oct 2026 — `sim/mesh_sim` + `src/`, evidence in `docs/06-simulator-findings.md` §14):** the *membership and epoch* half is implemented and measured in both
> engines: a group of 3-10 with an admin, a key epoch that rotates on every membership change and on
> admin command, and copies whose epoch does not match the receiver's counted as rejected rather than
> delivered. Two semantics worth fixing now, because they are easy to get wrong in the app: rotation
> discards the old key **network-wide**, so a message already in flight becomes unreadable to every
> member, not just to the node that left; and a departed member keeps **relaying** group traffic (the
> bytes are not secret to the network, only unreadable to it), which is why a scoped group flood needs
> no membership knowledge to work. Not modelled here: the key agreement itself — sender-key
> distribution over 1:1 channels is `skills/03` work.
>
> **Addendum (Oct 2026 — evidence in `docs/06-simulator-findings.md` §17.5):** rotation has a second
> consequence now that group history is repaired by hash-beacon anti-entropy. Because a rotated epoch makes
> older copies unreadable to *everybody*, the engine does not offer them for repair, so **the repairable
> history of a group is only ever as old as its last membership change**. A member that was out of range
> recovers everything sent since it last shared an epoch, and nothing from before. If readable history is a
> product feature, the key schedule has to change with it (per-message keys, or a rotation that re-wraps
> history) — anti-entropy cannot substitute for it.
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

> **Corrected (Oct 2026 — `src/crypto/packet.ts`, `src/crypto/identity.ts`; evidence in `docs/07-e2ee-noise-xx.md` §6).** Two things this
> section states do not survive being implemented.
>
> **`destHint` does not hide an identity, and cannot.** Against `docs/05`'s `nodeId = SHA-256(pubKey)`, a truncated hash of the destination
> public key is `nodeId[0:8]` — a *prefix of the nodeId*, which §2 of `docs/02` puts in an OGM the destination itself broadcasts every
> 2 seconds and `docs/03` §2 floods into the routing table of every node in range. A relay that can route the packet at all has already heard
> the destination's nodeId and can match the prefix against it. What the hint buys is a **shorter label** (8 bytes per header instead of 32,
> which is 9 % of a 256-byte padded block) and a little friction for a passive sniffer that never collected OGMs. Both are worth having. The
> sentence above should read: *"so the header carries an 8-byte routing label instead of a 32-byte one"* — and §5's claim that SUPER nodes
> "see only header" stays exactly true, because the header still has no `from`, no `to` and no body in it. `destHintBytesOpaque` in
> `src/crypto/identity.ts` is the variant for a deployment that would rather pay a lookup than publish the prefix relationship.
>
> Separately, the **simulator's** `destHint` is not this field at all: both engines compute a 32-bit string hash of the node id (`docs/06`
> §9), up to 8 hex characters, and `src/types.ts` documented it as a truncated hash of the destination pubkey. That comment is now corrected.
> The engine also carries a cleartext `to`, which the header above does not list — a routing simulator has to route, so the leak is inherent
> to the model and not to the design; `relayVisible()` returns the documented header and is asserted to have neither field.
>
> **The header is the AEAD's associated data.** `msgId16` is `SHA-256(msgId)[0:16]`, not the id: the engine's ids are short and sequential,
> and a plaintext id would leak the sender's counter and send rate to every relay. Because the header is authenticated rather than merely
> plaintext, a relay can read `ttl` and `hopCount` but cannot lower a ttl or advance a hop count without the tag failing — §1's "active relay
> attacker who forwards/modifies msgs" is answered by the AEAD, not by hoping.

---

### 5. Relay Privacy

- SUPER nodes **cannot read** E2EE DMs — they see only header.
- No IP metadata — Briar advantage (no metadata to subpoena [3](https://yolah.fr/vpn-security/briar-offline-messaging-resilient/)).
- Mitigate traffic analysis: random jitter 50-200 ms before forwarding, dummy beacons at low rate.
  > **Implementation note (Oct 2026 — `src/simulation.ts` `onCover` + `sim/mesh_sim`; evidence in `docs/06-simulator-findings.md` §23):** both halves are built in both engines. The
  > jitter half has shipped unconditionally from the start (`jitterMinMs` 50 / `jitterMaxMs` 200, drawn per forward, and the reason `docs/02` §6's latency budget is a spread rather than a
  > point). The dummy beacons are `coverTraffic` + `coverIntervalMs` (`--cover-traffic`, `--cover-interval`), **off by default, because measuring them produced a null result**: one node's
  > 12-message burst is already invisible to an observer counting transmissions — it names the sender 0 times in 3 seeds with cover off, because in a dense mesh relaying dominates every
  > node's count — and tightening the interval to 5 s moves the sender's z-score from 0.844 to 0.866 with no direction while costing **66 %** more airtime. Three things this line does not
  > say, which the implementation had to decide: that a dummy beacon is never acknowledged (one that had to be would not be a dummy); that *"low rate"* is an adjective, so §23 sweeps
  > 60/30/10/5 s rather than picking a number; and that this engine gives beacons no length, so the modelled cover is timing and count only — an adversary doing length-based analysis is
  > not reachable here, and defending against it would need padded cover on the beacon side, of which `src/crypto/packet.ts`'s 256-byte block padding is the payload-side equivalent.

---

### 6. Abuse & Safety (No Moderation Server)

- **Block/mute peer** locally (ignore msgs from pubKey).
  > **Implementation note (Oct 2026 — `src/simulation.ts` `blockPeer`/`isBlocked` + `sim/mesh_sim`; evidence in `docs/06-simulator-findings.md` §22):** built in both engines as a
  > per-device list keyed on the sender's node id — which is what *"from pubKey"* means on air, since §4 of `docs/07` derives `destHint8 = SHA-256(pubKey)[0:8]` and a node id carries that
  > hint. It is inert while empty, so no shipped run and no golden vector changes. Three things this bullet does not say, which the implementation had to decide:
  >
  > - **Control plane is not blockable.** Blocking an ACK makes the blocked peer retransmit forever, because it never learns its message arrived — more airtime, the opposite of the point.
  >   Blocking an OGM removes the peer from the blocker's routing table, which changes MPR selection and can cost a third party a route through a node that merely dislikes one of its
  >   neighbours. A block filters what a user sees; it is not a routing change.
  > - **SOS is not blockable,** for the same reason it is exempt from the rate cap below: the asymmetry is not close. A blocked peer's SOS costs one notification the user opted into; a
  >   suppressed real one costs a life. Measured, a blocked sender's SOS reaches all 10 blockers in every arm, including under the aggressive scope.
  > - **"Locally" has two possible reaches, and both ship.** `blockScope: "delivery"` (the default, and the literal reading of *"ignore msgs"*) filters the blocker's inbox and leaves the
  >   mesh carrying the copy for everyone else. `blockScope: "relay"` also refuses to forward, which is what the battery-drain bullet below means by *"ignore floods"*: it saves **9.7 %** of
  >   the network's airtime in a world where half the nodes have blocked a spammer, and costs that sender 17 of its copies per seed at nodes that never blocked it, because a blocker that
  >   will not forward is a hole in its routes. `delivery` is the default because it cannot censor anybody; `relay` is a knob because §6's own two bullets point in different directions.
- **Rate limit:** Max 5 broadcasts / minute per node; SUPERs drop excess.
- **Battery drain attack:** Cap relay to 30 msgs/min per source; ignore floods.
> **Implementation note (Oct 2026 — `src/routing.ts` `admitByRate` + `sim/mesh_sim/lib/src/routing.dart`; evidence in `docs/06-simulator-findings.md` §21):** both limits above are
  built in both engines, off by default, as token buckets rather than per-minute tallies — a tally would admit 5 broadcasts in the last second of one minute and 5 in the first second of the
  next, which is ten in two milliseconds without breaking a per-minute count. Measured on `campus_quad` over three seeds: a compliant network loses **nothing** (zero drops, identical delivery
  and transmissions with the caps on and off), and one node flooding at 12× the cap loses **19 %** of the network's transmissions (6 084 → 4 929) and 18 points of its own broadcast reach.
>
> Three things the implementation had to decide that this section does not:
>
> - **The relay cap of 30/min cannot be applied to control-plane traffic.** `docs/03` §1 beacons an OGM every 2 s, which is exactly 30/min per source, so counting beacons leaves the routing
>   protocol holding the entire sustained budget: 29 data messages admitted in ten minutes instead of 300, a 90 % cut caused by the node's own beacons and with nobody abusing anything. `ogm`,
>   `ack` and `sync` are therefore exempt. This corrects the number as written rather than relaxing it — the cap still applies to everything a user sends.
> - **Only SUPERs enforce the broadcast cap, as this section says, and that bounds distance rather than neighbourhood.** A NORMAL node neither relays far nor filters, so a flooder still reaches
>   its own one-hop neighbours in full: the flood's reach with the caps on is **76.9 %**, not the 8.3 % that 5-of-60 admitted would imply. For the neighbour-spam case this section is about, one
>   hop is the whole attack. Making every node enforce it is a rule this document does not contain, so it is a **knob rather than a change**: `broadcastCapScope` (`--broadcast-cap-scope
>   super|all`) defaults to `super`, and `npm run rate flood` measures both. Every node enforcing cuts the flood's reach to **21.2 %** and its airtime to **2 304** of **6 084** transmissions
>   (−62 %) while costing an honest network nothing. On that evidence `all` is the better default, but switching it is a change to a specified security rule and so is left to whoever owns this
>   document; the measurement is in `docs/06` §21.5.
> - **SOS is exempt.** It travels to `BROADCAST` like everything else on the pager channel, so the obvious gate (`to == BROADCAST`) would cap an emergency channel at 5/min. This section already
>   gives SOS two other mechanisms — opt-in listening and §11's collapsing — and a real emergency is precisely where a rate limit does the most harm.
>
> The caps are a battery and airtime control, not a delivery control, and `docs/06` §21.4 reports the null result plainly: honest unicast delivery is **100 % in all four arms**, flooded or not,
> caps on or off. A 20-node campus mesh absorbs one 12× flooder without dropping a unicast, so there was nothing here for the caps to rescue.
- **SOS misuse:** SOS channel is opt-in; user must toggle to listen (avoid spam).
  > **Implementation note (Oct 2026 — `sim/mesh_sim` + `src/`, evidence in `docs/06-simulator-findings.md` §11):** the anti-spam half is implemented as *collapsing*: a repeated SOS flood is a
  new radio event but the same emergency, so it replaces the receiver's existing alert with its fresher
  GPS fix instead of raising a second notification. Copies arrive out of order across four floods, so
  the alert only ever moves forward in time — a late flood 1 cannot overwrite the fix from flood 3.
  Four floods over a 20-node world produce 76 radio receipts and **19** notifications, one per peer.

---

### 7. Compliance Notes

- Comply with **GDPR by design**: No data leaves device to server; all PII is local.
- Export crypto note: Use standard libsodium (no custom crypto).
- Store listing: Prepare for takedown resilience — publish **APK + F-Droid + GitHub Releases** alongside Play/App Store.

---
**Audit plan:** Cure53-style review at end of Phase 3 (after E2EE implemented, before PTT). Budget for external audit.
