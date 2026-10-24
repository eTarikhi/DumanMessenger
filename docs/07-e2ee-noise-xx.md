# 07 — E2EE over the mesh: Noise_XX specification, and what it costs here

> Companion to `skills/03-crypto.skill.md` and `docs/04-security-privacy.md` §3.
> `skills/03` states the primitives and the packet; this document states the
> **handshake as a mesh protocol** — what it costs in hops, milliseconds, radio
> time and battery on the network described in `docs/03` and measured in
> `docs/06-simulator-findings.md` — and what the simulator can and cannot validate.
>
> **No cryptography is implemented in this repository, and none should be.**
> `skills/03`: *"DO use libsodium via FFI; never custom crypto."* Everything numeric
> below comes from running the *mesh* model with messages the size and shape the
> crypto produces, which is the part a protocol simulator can honestly answer.

**Status:** design and cost model. Handshake latency, session-churn rate and packet
sizing are measured; the handshake itself is not implemented here. Everything numeric in §2–§4 is
re-runnable with **`npm run e2ee`** (`tool/e2ee-probe.ts`, sections `latency`, `churn`, `packet`),
which did not exist when this document was written — the harness that produced the original figures
was never committed, so they were citations rather than results.
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
3. **SAS verification is not the slow part.** The emoji/8-character comparison is
   instant; the 0.5-6.7 s is the radio. The UX should show progress per leg so a
   user does not abandon a handshake that is one retransmission from finishing.

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
ciphertext = from(32) + ts(8) + body + pad-to-256-blocks
```

so the wire size is `ceil((95 + body) / 256) × 256`. The simulator's transport selector
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
  still on the radio, and §3's churn numbers say an observer in a crowd sees ~70 new
  contacts per node per hour regardless. Length padding is cheap hygiene, not
  traffic-analysis resistance; `docs/04` should not be read as claiming otherwise.

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

| `skills/03` acceptance | status | what this document adds |
| --- | --- | --- |
| 2 peers: QR exchange → Noise handshake → E2EE DM a SUPER cannot decrypt (capture test) | not started — needs the crypto library | §2.1 gives the timeout and per-leg retry budget the capture test should run under, and §4 the packet size it must produce |
| Forward secrecy: compromise after ≠ can decrypt prior (ratchet verify) | not started | unchanged; the mesh adds nothing to the ratchet, but §2's leg loss means the ratchet must tolerate out-of-order and retransmitted messages |
| Audit checklist: no plaintext PII in logs, `destHint` leaks only an 8 B hash | partly testable here | `destHint` is already implemented as a truncated hash in both engines and covered by tests; the capture log (`docs/06` §13) is the artifact an auditor should read, and it logs ids, reasons and dBm — never bodies |

The third row is the one this repository can actually make progress on, and it is worth
noting that the capture log added for hop transparency is also the audit surface: it
records `msgId`, node ids, forwarding reasons and link budgets, and no message body.
That is deliberate, and it should stay that way.

## 7. Open questions for the crypto implementation

1. **Simultaneous open.** XX supports it, but two devices that both initiate will each
   hold a half-session. Which one wins, and does the loser's ephemeral key get
   discarded or reused? The mesh makes collisions likelier than the internet does,
   because there is no RTT asymmetry to break the tie.
2. **Handshake over which transport?** `skills/03` says BLE GATT. At 1 024 B a leg
   needs GATT MTU negotiation or fragmentation; the 256 B padded block fits a
   negotiated 247 B MTU only by luck. Either fix the handshake messages under one
   fragment (they are: `e` is 32 B + tag) or specify the fragmentation.
3. **Resumption identity.** A cached `sessionId` is a linkable identifier. Reusing it
   within 7 days (`skills/03`) trades privacy for latency; §3's churn numbers suggest
   the latency win is large in a stable campus and small in a crowd of strangers, so
   the policy may want to differ by context.
4. **Panic wipe ordering.** `docs/04` wants one-tap key zeroization. Sessions, group
   epochs and the at-rest database all have to die in one transaction, and a group
   rotation triggered by a wipe has to reach N−1 members who no longer have the key —
   which is §5's network-wide rotation, arriving from a node that has already
   forgotten why.
