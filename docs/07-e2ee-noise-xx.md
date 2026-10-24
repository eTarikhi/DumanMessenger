# 07 — E2EE over the mesh: Noise_XX specification, and what it costs here

> Companion to `skills/03-crypto.skill.md` and `docs/04-security-privacy.md` §3.
> `skills/03` states the primitives and the packet; this document states the
> **handshake as a mesh protocol** — what it costs in hops, milliseconds, radio
> time and battery on the network described in `docs/03` and measured in
> `docs/06-simulator-findings.md` — and what the simulator can and cannot validate.
>
> **No cryptographic *primitive* is implemented in this repository, and none should
> be.** `skills/03`: *"DO use libsodium via FFI; never custom crypto."* Everything
> numeric in §2–§4 comes from running the *mesh* model with messages the size and
> shape the crypto produces, which is the part a protocol simulator can honestly
> answer.
>
> **Amended (Oct 2026).** This document used to say "no cryptography is implemented
> here, and none should be", which conflated two different things. The *primitives*
> — X25519, ChaCha20-Poly1305, SHA-256 — are still not implemented and still must
> not be. The *protocol layer* above them now is, in `src/crypto/`: the Noise_XX
> state machine, the per-message ratchet, both SAS values, identity and the QR
> flow, and the packet serialised for real. It delegates every primitive to OpenSSL
> through `node:crypto`, so `skills/03`'s rule is respected rather than argued with.
> It is a **reference implementation, not a production one** — no constant-time
> guarantees of its own, key material in garbage-collected buffers — and the shipped
> build should still be libsodium via FFI and Dart's `cryptography`. What it buys is
> that §4, §6 and §7 below stopped being arithmetic and prose and became
> measurements: `npm run e2ee crypto`.

**Status:** design and cost model, plus a runnable protocol layer. Handshake latency, session-churn
rate, packet sizing and — since the amendment above — leg sizes, handshake CPU cost and the capture
test are all measured. Everything numeric in §2–§4 and §7 is re-runnable with **`npm run e2ee`**
(`tool/e2ee-probe.ts`, sections `latency`, `churn`, `packet`, `crypto`), which did not exist when
this document was written — the harness that produced the original figures was never committed, so
they were citations rather than results.
**Date:** Oct 2026

---

## 1. Why Noise_XX, and what the mesh changes about it

`skills/03` fixes the pattern: **Noise_XX** (`-> e`, `<- e, ee, s, es`, `-> s, se`),
no internet round trip, trust-on-first-use plus SAS verification. XX is the right
choice for this network and the reasons are mesh-specific:

- **No CA, no server, no phone number** (`docs/04`: "Why not TLS/PKI: no internet to
  reach CA"). XX authenticates by *possession of a static key*, so the only thing the
  two devices need is each other's key — which is what the QR add-contact flow
  carries.
- **Both sides are ephemeral peers.** Unlike a client/server handshake there is no
  asymmetry to exploit, and either device may initiate. XX handles simultaneous open,
  which matters when two people tap "add" at the same moment.
- **Three messages, and each one is a mesh message.** This is the part a TLS-shaped
  intuition gets wrong. On the internet a round trip is 30 ms; here it is 232 ms at
  one hop and 634-4 954 ms at three (§2), and any leg can be lost entirely (§2.2).

The mesh does not change the cryptography. It changes the **state machine around
it**: how long a handshake may take, what happens when a leg is lost, when to start
one at all, and what it costs to keep one alive.

## 2. Measured: what a handshake costs on this network

### 2.1 Establishment latency

Noise_XX needs three authenticated legs before the first plaintext can flow. Each leg
was sent as a unicast through the real engine (routing, MPR wait, link loss, ACKs and
retries all active) and the latency is the engine's own end-to-end figure for that
message:

| world | shortest path | leg 1 (`-> e`) | leg 2 (`<- e, ee, s, es`) | leg 3 (`-> s, se`) | **total** |
| --- | --- | --- | --- | --- | --- |
| campus_quad (20) | 1 hop | 232 ms | 230 ms | 213 ms | **675 ms** |
| campus_quad | 2 hops | 720 ms | 721 ms | 779 ms | **2 219 ms** |
| campus_quad | 3 hops | 634 ms | 1 082 ms | 4 954 ms | **6 671 ms** |
| campus_quad | 4 hops | 1 306 ms | 953 ms | 1 232 ms | **3 491 ms** |
| festival_crowd (60) | 1 hop | 181 ms | 184 ms | 185 ms | **550 ms** |
| festival_crowd | 2 hops | 397 ms | 415 ms | 566 ms | **1 378 ms** |
| festival_crowd | 3 hops | 992 ms | 944 ms | 874 ms | **2 810 ms** |
| festival_crowd | 4 hops | 1 691 ms | **lost** | 5 555 ms | **never established** |

`docs/02` §6 *Key Metrics to Hit* budgets **< 2 s for one hop and < 5 s for three**, per
message, and the roadmap's Phase 1 exit criteria say the same. (This paragraph used to cite
`docs/04` §5, which is *Relay Privacy* and contains no latency figure.)

Every leg at one hop and every leg at three is inside the budget for its distance, including the
4 954 ms leg at three hops in the campus, which sits right on the 5 s line. The four-hop legs are
**not judged**, because no budget is published for that distance — the crowd's 5 555 ms leg is over
the three-hop figure and that is a gap in the budget, not a failure against it. And that is the
*point*: the budget was written for a message, but a session is three of them in series.

Three consequences for the app, each of which is a decision rather than a detail:

1. **Budget the handshake at three times the per-message budget.** A "verifying…"
   spinner that times out at 2 s will fail on a perfectly healthy 3-hop link. The
   measured worst case inside budget is 6.7 s; a 15 s establishment timeout with
   per-leg retry is the shape the data supports.
2. **Retry per leg, not per handshake.** Legs 1 and 2 carry the ephemeral keys; if
   leg 3 is lost the initiator can resend it without restarting, because XX's
   transcript is already fixed by then. Restarting on any loss turns a 5 % per-leg
   loss rate into a ~14 % handshake failure rate at three legs.
3. **SAS verification is not the slow part, and neither is the cryptography.** The
   emoji/8-character comparison is instant; the 0.5-6.7 s is the radio. The UX should
   show progress per leg so a user does not abandon a handshake that is one
   retransmission from finishing.
   > **Measured (Oct 2026 — `npm run e2ee crypto`).** This was an intuition when it was
   > written. A full XX handshake — two X25519 key generations, three DH operations and
   > four AEADs — costs **1 062 µs** on a laptop, which is **0.157 %** of the 675 ms the
   > one-hop row of the table above spends on radio. Sealing one 160-byte message
   > (ratchet step plus ChaCha20-Poly1305) is **14 µs**, about **70 000 messages/s** and
   > **10.8 MiB/s** on one core. So the split is 99.8 % mesh and 0.2 % crypto, and the
   > conclusion is stronger than the one drawn: there is no battery or latency argument
   > for weakening the cipher, because the cipher is not where the time goes. These are
   > OpenSSL numbers on a development machine, not an ARM handset in a battery saver
   > state — `skills/07`'s budget still has to be measured on hardware — but they are off
   > by a factor of 640 before crypto would matter as much as the radio does.

### 2.2 A leg can be lost, and at four hops in a crowd it was

The `festival_crowd` 4-hop row never established: leg 2 did not arrive inside 8 s.
`npm run e2ee latency` reproduces this and finds it is not seed-luck — at four hops in the crowd a
leg was lost on *both* seeds it runs, leg 1 at seed 42 and leg 2 at seed 7.
That is not a cryptographic failure and it is not rare enough to ignore — the crowd's
overall delivery is 91-95 % (§2 of `docs/06`), so a three-leg handshake inherits
roughly `1 − 0.95³ ≈ 14 %` failure before any retry. Session establishment therefore
needs the same treatment the data plane already has: a retry budget, a timeout, and a
user-visible state for "could not verify — move closer or try again".

`skills/03`'s session resumption ("cached `sessionId` if the peer is met again within
7 days") is what makes this tolerable: a handshake is a once-per-relationship cost,
not a once-per-contact cost — **provided the app does not handshake on discovery**,
which §3 shows it must not.

## 3. When to handshake: on demand, never on discovery

Measured over 10 simulated minutes, sampling the in-range graph every 5 s and counting
distinct pairs that came into range:

| world | nodes | distinct pairs met in 10 min | of all possible pairs | new peers per node per hour |
| --- | --- | --- | --- | --- |
| campus_quad | 20 | 102 | 54 % of 190 | **61.2** |
| festival_crowd | 60 | 702 | 40 % of 1 770 | **140.4** |
| sparse_village | 12 | 18 | 27 % of 66 | **18.0** |

> **Corrected (Oct 2026).** The last column originally read 30.6 / 70.2 / 9.0 — exactly half these
> figures. It was computed as `pairs ÷ nodes × 6`, which counts each meeting once for the pair; but
> a pair coming into range is a new peer for *both* of its members, so the per-node rate is
> `2 × pairs ÷ nodes × 6`. `npm run e2ee churn` now measures it directly, by counting the distinct
> peers each node came into range with, which needs no formula to get wrong: it reports 61.8 /
> 142.2 / 18.0 per hour from 103 / 711 / 18 pairs, agreeing with the pair counts above to within
> 1 %. The conclusion this section draws was not weakened by the error — it argues against
> handshaking on discovery, and twice the churn argues harder.

A handshake on every first contact would therefore put, in a festival crowd,
**~140 XX exchanges per node per hour** on the radio — about 420 mesh messages per node
per hour of pure key agreement, each needing an ACK and eligible for two retries,
before a single user message is sent. In the campus it is ~61/hour (~184 messages).
Against `skills/07`'s battery budget (NORMAL under 15 % per 8 h, met only with the
duty cycle on — `docs/06` §10) that is not a rounding error, and 99 % of those peers
are strangers the user will never message.

So: **discovery is not consent to a handshake.** The 12-byte advertising beacon
(`docs/05` §3.2) shows who is nearby; a Noise session starts when the user adds a
contact or sends a first message. This is also the privacy-correct order — an
eager XX handshake announces to every passing stranger that this device is willing to
negotiate with them, which is a tracking surface `docs/04` §6 is trying to close.

The corollary for resumption: with handshakes on demand, the 7-day session cache is
what makes a mesh feel instant. In a campus, 54 % of all possible pairs meet within 10
minutes, so a cached session with a colleague survives a day of movement; the cache
should be keyed on the peer's static key and evicted on panic wipe (`docs/04`), not on
radio contact.

## 4. Packet size, padding, and a model bug this exposed

`skills/03` specifies the packet:

```
header {msgId16, ttl, type, destHint8, hop}          = 27 B
aead   {nonce12, ciphertext, tag16}                  = 28 B + ciphertext
ciphertext = from(32) + ts(6) + len(2) + body + pad-to-256-blocks
```

so the wire size is `ceil((95 + body) / 256) × 256`.

> **Corrected (Oct 2026 — `src/crypto/packet.ts`).** `ts` is 6 bytes, not 8, and the 2
> that frees up hold the body length. Serialising the packet showed why the 8-byte
> version cannot be built: the padding is zeros, and zero padding is ambiguous for a
> binary body — a media chunk can legitimately end in `0x00`, so a reader cannot tell
> body from padding without a length. The alternative, a mandatory `0x80` pad marker
> (ISO 9797-1 method 2), needs no length field but costs a whole extra 256 B block
> whenever `95 + body` is already a multiple of 256 — and **929 is exactly such a
> body**, the size §5.3 of `docs/08` uses to derive the 14.9 kbit/s push-to-talk
> ceiling. A 929-byte payload would have become a 1 280 B Wi-Fi Direct packet and the
> ceiling would have dropped. Six-byte milliseconds run to the year 10889, and the
> total stays 95 bytes, so every number in the table below is unchanged.
>
> `msgId16` is a **digest**, not the id: `SHA-256(msgId)[0:16]`. The engine's ids are
> short and sequential (`m000042`), so putting one in a plaintext header leaks the
> sender's counter and its send rate to every relay. Dedup compares digests, and 128
> bits is collision-safe for a mesh that will never approach 2^64 messages.
>
> Both changes are asserted against the engine rather than against this document:
> `packetLayoutIsConsistent()` in `src/crypto/packet.ts` fails if the field widths stop
> summing to `PACKET_OVERHEAD_BYTES`, and `npm run e2ee crypto` seals a real packet at
> body sizes 0/241/700/900/929/930 and requires each to measure exactly what
> `wireSizeOf` predicts.

> **A second correction, in the engine (Oct 2026).** The table below counts *bytes* of
> body, and `createMessage` was counting UTF-16 **code units** — `wireSizeOf(body.length)`.
> For ASCII the two agree, which is why it survived: `NAMES` is 24 Latin names without
> a diacritic, the traffic generator sends `"hey " + name`, and
> `test-fixtures/golden-vectors.json` contains no byte above `0x7f`, so no golden vector
> moves and 276 tests stayed green. They disagree the moment a user types Turkish,
> Arabic, Devanagari, CJK or an emoji, and the disagreement is optimistic — the
> direction this section already calls dangerous, because the number picks the transport
> and the transport sets the per-hop latency every finding is reported against:
>
> | body | by `.length` | transport | by UTF-8 bytes | transport |
> | --- | --- | --- | --- | --- |
> | 300 emoji (600 code units) | 768 B | **BLE** | 1 536 B | Wi-Fi Direct |
> | a Turkish body of 930 bytes (810 code units) | 1 024 B | **BLE** | 1 280 B | Wi-Fi Direct |
>
> Both left-hand rows report a payload riding a radio that cannot carry it, at BLE's
> 120 ms per hop rather than Wi-Fi Direct's 40 ms. Fixed in both engines as
> `utf8ByteLength` / `wireSizeOfBody`, counted by hand rather than through `TextEncoder`
> and `utf8.encode` because those two disagree on a lone surrogate — one substitutes
> U+FFFD, the other throws — and the engines have to agree by construction, not by
> luck. The simulator's transport selector
was instead using a `64 + 4 bytes per character` heuristic, which crosses the 1 KB BLE
ceiling (`docs/02` §3.1, `docs/05` §3.2: "Text message (<1 KB) | BLE GATT") at **241
characters**. The documented packet crosses it at **930**:

| body | engine (old heuristic) | transport | skills/03 packet | transport |
| --- | --- | --- | --- | --- |
| 0 chars | 64 B | BLE | 256 B | BLE |
| 241 chars | 1 028 B | **Wi-Fi Direct** | 512 B | BLE |
| 700 chars | 2 864 B | **Wi-Fi Direct** | 1 024 B | BLE |
| 900 chars | 3 664 B | **Wi-Fi Direct** | 1 024 B | BLE |
| 930 chars | 3 784 B | Wi-Fi Direct | 1 280 B | Wi-Fi Direct |

This was not a cosmetic difference. Transport is what sets per-hop latency in this
model (`hopLatencyBleMs` 120 vs `hopLatencyWifiMs` 40), so the heuristic was silently
routing ordinary long texts onto the fast transport and reporting latencies that a BLE
deployment would not achieve — in the optimistic direction, which is the dangerous one.

Both engines now size a message as `wireSizeOf(bodyChars)` from the documented layout,
with the constants exported (`PACKET_OVERHEAD_BYTES` 95, `PAD_BLOCK_BYTES` 256) and the
BLE/Wi-Fi boundary pinned by tests at 900 characters (1 024 B, still BLE) and 930
(1 280 B, Wi-Fi Direct). Golden vectors are unchanged: the fixture's bodies are short
enough that both models select BLE.

Two things padding does and does not buy, since both get claimed:

- **It does** make message length uninformative below 161 characters of body, and
  coarse (256/512/1 024/1 280 B) above it — an observer cannot tell a "yes" from a
  160-character paragraph.
- **It does not** hide the conversation. Timing, direction and the ACK pattern are all
  still on the radio, and §3's churn numbers say an observer in a crowd sees ~140 new
  contacts per node per hour regardless (this paragraph said ~70 until §3's per-node
  column was corrected). Length padding is cheap hygiene, not traffic-analysis
  resistance; `docs/04` should not be read as claiming otherwise.

> **Cross-reference (Oct 2026 — `docs/08-media-transport-ptt.md` §5.3, §8):** the padding model above is what sets the
> ceiling on push-to-talk. A payload stays inside one BLE packet up to **929 B**, so a 500 ms Opus frame
> stays on BLE only up to **14.9 kbit/s** — and at the documented 12 kbps the padded frame is *exactly*
> 1024 B, flush against the ceiling with no room for a per-frame nonce to grow into. Media chunks declare
> their **payload** size rather than their padded size, which is the convention that keeps skills/05's
> 512 B BLE slice on BLE; the ≤0.2% air-time error on a 64 KB slice is stated in docs/08 §8 rather than
> buried.

## 5. Group keys: what §14 of `docs/06` already pins

`skills/03`: *"GroupKey distributed over pairwise Noise channels on create/add member;
rotate on member removal."* The membership and rotation half is implemented and tested
in both engines (`docs/06` §14) — 3-10 members, admin-only rotation, rotation on every
join and leave, and a copy whose epoch does not match the receiver's rejected rather
than delivered. Two properties worth restating here because they constrain the crypto:

- **Rotation is network-wide.** After a rotation, a message already in flight under the
  old epoch is unreadable to *every* member, not only to the node that left. The key
  distribution step therefore has to reach all N−1 members before the group can send
  again, and a member that is offline during a rotation is out of the group until it
  receives the new epoch over its pairwise channel. That is a mesh-delivery problem
  with the DTN machinery of `docs/03` §8 behind it, not a local one.
- **Cost of a membership change is N−1 pairwise encryptions.** Creating a 10-member
  group needs 9 pairwise channels to exist first — which at §2's latency is 9 ×
  (0.5-6.7 s) if they are cold, and why an "add member" action needs a progress state.
  A group with 5 membership changes an hour re-keys 45 times.

What is *not* modelled: the sender-key tree, the double ratchet, signature
verification, or any of `skills/03`'s acceptance criteria below. The simulator's
"cannot decrypt" is an integer epoch comparison. It specifies **when a key must change
and who may read what**; `skills/03` specifies how, and libsodium implements it.

## 6. Acceptance mapping

| `skills/03` acceptance | status | where |
| --- | --- | --- |
| 2 peers: QR exchange → Noise handshake → E2EE DM a SUPER cannot decrypt (capture test) | **met in the reference implementation** (Oct 2026) | `src/crypto/` end to end — QR encode/decode, XX over three legs, both SAS values, sealed packets. The capture test is `npm run e2ee crypto` and `src/crypto/__tests__/session.test.ts`; §2.1 gave it the timeout and per-leg retry budget it runs under and §4 the packet size it must produce |
| Forward secrecy: compromise after ≠ can decrypt prior (ratchet verify) | **met in the reference implementation** (Oct 2026) | `src/crypto/ratchet.ts`. §2's leg loss is what forced the design: the ratchet tolerates out-of-order and retransmitted messages through a bounded skip cache, and the bound (`MAX_SKIP` 64) is a security parameter, not a convenience — an unbounded cache is a denial of service |
| Audit checklist: no plaintext PII in logs, `destHint` leaks only an 8 B hash | **partly met, and the criterion needs rewording** | `relayVisible()` in `src/crypto/packet.ts` returns exactly what a relay may read and is asserted to have no `to` and no `from` field. The capture log (`docs/06` §13) is still the artifact an auditor should read: ids, reasons and dBm, never bodies. But see the note below — an 8 B `destHint` does not do what the criterion assumes |

**On the capture test, because the obvious version proves nothing.** A relay holding a
random key cannot open the packet, and neither can a rock. The test that matters gives
the relay a *legitimate* key: it is a real peer of the sender, with its own completed XX
session, and it derives the real message key for that message number from its own
receive chain — the strongest position a relay can be in short of holding the
recipient's private key. Same sender, same message number, different recipient, so a
different session and a different chain: the AEAD fails. That is what `npm run e2ee
crypto` runs.

**On the third row: `destHint` does not hide an identity, and cannot.**
`docs/04` §4 says the hint is a *"truncated hash of dest pubKey (8 bytes) so relays can
route without learning full identity"*. Implemented literally against `docs/05`'s
`nodeId = SHA-256(pubKey)`, the hint is

    destHint = SHA-256(pubKey)[0..8]  ==  nodeId[0..8]

— a **prefix of the nodeId**, which `docs/02` §2 puts in an OGM the destination itself
broadcasts every 2 seconds and `docs/03` §2 floods into the routing table of every node
in range. Any relay that can route the packet at all has already heard the destination's
nodeId and can match the prefix against it. So the audit criterion "leaks only an 8 B
hash" is measuring the wrong thing: the identity is not leaked *by the hint*, it is
announced by the protocol.

What the hint genuinely buys is a **shorter label** — 8 bytes per header instead of 32,
which is 9 % of a 256 B padded block — and a small amount of friction for a passive
sniffer that has *not* collected OGMs. Both are worth having; neither is identity
hiding. `src/crypto/identity.ts` implements the literal version as `destHintBytes` and a
domain-separated one as `destHintBytesOpaque`, which is not a prefix of anything, for a
deployment that would rather pay a lookup than publish the relationship. The engine's own
`destHint` is neither: it is a 32-bit string hash of the node id (`docs/06` §9), which is
fine for routing and is not the field `docs/04` §4 describes — see the correction to
`src/types.ts` alongside this one.

The capture log remains the audit surface worth reading: it records `msgId`, node ids,
forwarding reasons and link budgets, and no message body. That is deliberate, and it
should stay that way.

## 7. Four questions this document asked, and what building it answered

These were open questions for a crypto implementation. `src/crypto/` is one, so each now
has an answer in code, a test, and a number where a number applies. Where the answer
changed the question, that is said too.

1. **Simultaneous open — answered: lexicographic order on the X25519 keys, and the loser
   destroys its ephemeral.**
   `resolveSimultaneousOpen` compares the two static keys, which both devices already
   hold from the QR exchange, so the rule is computable with no communication and is a
   total order: exactly one side wins, and the two sides cannot disagree. It compares the
   **X25519** keys, not the Ed25519 keys the QR carries, because those are what XX binds —
   comparing the other pair would be a different order and two devices could both think
   they lost.
   The loser discards rather than reuses its ephemeral key, and that is not a preference:
   a key that appears in two transcripts is not ephemeral, and the abandoned
   half-session's forward secrecy rests on it being dead. `abandon()` zeroizes it and
   returns whether one existed.
   The part the question did not anticipate is that **detection has to precede the state
   machine**. Both sides write leg 0, so what each receives is a bare 32-byte ephemeral
   where a 96-byte leg 1 was expected. Feeding that to Noise fails *both* sessions —
   including the winner's — and destroys the very state the tie-break needs. So a 32-byte
   frame arriving when leg 1 is due is recognised as a collision, neither session is
   harmed, and only the loser restarts. The winner re-sends the leg 0 it already put on
   air. A truncated leg 1 is indistinguishable from this by length alone; treating it as
   a collision is still right, because truncation is a link failure the mesh retries while
   two people tapping "add" together is common.
2. **Handshake over which transport — answered: BLE GATT, unfragmented, with 151 B to
   spare.** The legs measure **32 / 96 / 64 bytes** (`npm run e2ee crypto`). The question's
   arithmetic was off in one place worth recording: a leg's trailing payload is
   `EncryptAndHash`, so once a key exists even an *empty* payload costs a 16-byte tag —
   which is why leg 1 is a bare 32 and legs 2 and 3 are 96 and 64 rather than 80 and 48.
   None needs MTU negotiation. The fragmentation problem this worried about is real but
   belongs to the **data** plane, whose packets are padded to 256 B blocks and cross the
   1 024 B BLE ceiling at a 929-byte body (§4).
3. **Resumption identity — answered: there is no identifier, so there is nothing to
   link.** The worry was that a cached `sessionId` is a linkable identifier. As built, the
   cache (`SessionCache`) is keyed **locally** on the peer's static key, which the device
   already holds, and resumption puts **nothing on air**: both sides continue chains they
   already share. An observer sees traffic resume with no key agreement in front of it —
   which is strictly less observable than re-handshaking, and against §3's ~140 new peers
   per node per hour in a crowd that absence is the point. The policy consequence survives:
   eviction is on **time and on wipe**, never on radio contact, because §3 measures 54 % of
   campus pairs meeting within ten minutes and a contact-keyed eviction would discard a
   working session several times a day.
4. **Panic wipe ordering — answered: ratchets, handshake, transport keys, SAS, identity;
   and a wipe cannot revoke.** The order is forced by the derivations: each is keyed from
   the one after it, so wiping the identity first would leave a live chain key that can
   still decrypt. `panicWipe()` returns the order it actually took, because a wipe that
   throws halfway is worse than one that reports where it stopped, and `docs/04` asks for
   one tap — one chance to find out it missed something.
   The rotation half of the question has no good answer, and the honest one is that it is
   not an ordering problem but a physics problem: the group rotation needs the pairwise
   channels whose keys are the thing being destroyed. **A wipe cannot revoke.** Detection
   has to move to the receiver, which notices an epoch it cannot decrypt rather than being
   told — §5's network-wide rotation, arriving from a node that has already forgotten why,
   is a message that will never be sent. The second half is easy to miss and is tested:
   a wipe does not retroactively protect anything already on air, which is why `docs/04`'s
   at-rest encryption is not optional.
   What JavaScript cannot do at all is guarantee the bytes are gone: the collector may have
   copied them, and OpenSSL held them first. `zeroize()` overwrites what the object still
   references and says so. That is the real argument for `skills/03`'s StrongBox and Secure
   Enclave — not performance, but that a JS wipe is best-effort by construction.
