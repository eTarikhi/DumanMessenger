# 08 — Media transport and push-to-talk: what a byte costs on this mesh

> Evidence for roadmap Phase 3 ("Media transport: WiFi Direct P2P for files, BLE
> chunked streaming for voice") and for the three acceptance boxes in
> `skills/05-voice-media.skill.md`. Every number below is measured by the simulator
> in both engines — `npm run media` (TypeScript reference, `tool/media-probe.ts`) and
> `dart run bin/mesh_sim.dart --media` (authoritative). Nothing is extrapolated from
> a datasheet, and where a measurement is noise it says so.
>
> Companion to `docs/06-simulator-findings.md` (routing, election, power, SOS,
> groups, scale) and `docs/07-e2ee-noise-xx.md` (handshakes, packet sizing).

---

## 1. What was missing

Before this work the engine charged every payload the same hop latency: an ACK and a
64 KB image slice both cost `hopLatencyBleMs` (120 ms) or `hopLatencyWifiMs` (40 ms)
plus jitter. A "10 MB image transfer" was therefore 160 messages that each behaved
like a text message, and the roadmap's Phase 3 exit criterion — *"2 phones exchange
image <10 MB over WiFi Direct mesh"* — could be marked as passing without a single
byte of radio time being accounted for.

That is not a modelling nicety. It is the difference between a 10 MB image crossing
three hops in 33 s and crossing them instantly, and it decides whether push-to-talk
is usable at all: a voice frame is 750 B, and 750 B is inside one BLE packet, so
whether a note rides the 120 ms radio or the 40 ms one is a payload-size question
(§5.3).

---

## 2. Air time: charging a payload for the radio it occupies

### 2.1 Only the excess over one packet

```
serializationMs(bytes, transport) = max(0, bytes − 1024) × 8 / kbps
bleKbps = 80        wifiDirectKbps = 20000
```

`hopLatencyBleMs = 120` was calibrated as *one* BLE round trip through the stack, so
it already pays for one full-sized packet (`BLE_MAX_BYTES = 1024`). Charging the whole
payload again would double-count that packet; charging nothing above it is what made
a 10 MB file free.

The consequence is the reason this could be added at all: **every packet that exists
in the engine today is ≤ 1024 B on the wire** (text bodies, OGMs, ACKs, SOS floods,
group copies — see the padding model in `docs/07` §4), so `serializationMs` returns 0
for all of them. The golden vectors in `test-fixtures/golden-vectors.json` are
byte-identical before and after this change, in both languages, and every latency
figure reported in `docs/06` still stands. Media is additive, not a recalibration.

### 2.2 Measured cost per hop

| payload | BLE 80 kbit/s | Wi-Fi Direct 20 Mbit/s | ratio |
|---|---|---|---|
| 1 KB | 0 ms | 0 ms | both under one packet |
| 4 KB | 307 ms | 1 ms | 250 |
| 7 KB (a 3 s note as one blob) | 648 ms | 3 ms | 250 |
| 44 KB | 4.40 s | 18 ms | 250 |
| 64 KB (one slice) | **6.45 s** | **26 ms** | 250 |
| 10 MB (one blob) | 17.47 min | 4.19 s | 250 |

### 2.3 The 250× claim, and what it does not say

`docs/05` §3.2 puts Wi-Fi Direct at *"250× faster than BLE"* for images. 80 kbit/s
against 20 Mbit/s reproduces exactly that ratio, so the two rates are not independent
guesses — one is pinned to the other by the spec.

What the claim does not say is that the ratio is a *serialization* ratio. The RF
budget in `rf.ts` is unchanged: range, RSSI, wall penalty and loss are identical on
both radios, which is why an SOS flood rides Wi-Fi Direct for latency and not for
reach (`docs/06` §11). A 64 KB slice is 26 ms of air time on Wi-Fi Direct and 6.45 s
on BLE — over a minute of difference *per hop*, which is the whole argument for
chunking rather than for hoping.

---

## 3. Chunked file transport

`sendFile(from, to, bytes)` slices into `transferChunkBytes` (64 KB, skills/05: *"64 KB
slices, sliding window ACK"*) and pushes them through a window of `transferWindow`
(default 4) unacknowledged chunks. Each chunk is an **ordinary unicast**: it goes
through `decideForward`, gets an ACK, gets retransmitted up to `maxRetries` times,
travels the OppQueue as a last resort, and appears in the hop trace like anything
else. Nothing media-specific was added to the data plane.

What that buys, for free:

* **Retransmission and DTN** — a chunk that meets a node walking out of range is
  carried until a contact appears (`docs/03` §8), which is the mechanism skills/05's
  *"resume on reconnect"* needs (§6).
* **Deduplication** — the receiver keys on the chunk index, so a retry that arrives
  after the original costs radio time and nothing else.
* **Hop traces** — a chunk that took four hops says so in the capture log.

A 10 MB image, measured on the 20-node campus (`campusQuad`, seed 42, settled 90 s,
cleanest pair at each hop distance):

| hops | chunks | retransmitted | transport | time | throughput |
|---|---|---|---|---|---|
| 1 | 160 | 0 | wifiDirect | 7.60 s | 11.0 Mbit/s |
| 2 | 160 | 10 | wifiDirect | 16.88 s | 4.97 Mbit/s |
| 3 | 160 | 0 | wifiDirect | 33.00 s | 2.54 Mbit/s |

The roadmap's exit criterion is met with margin: three hops, 33 s, well inside a
minute. The 2-hop run is not between the other two by accident — that pair has the
lossiest legs in the settled world and paid 10 retransmissions for it.

### 3.1 Accounting: media stays out of `deliveryRatio`

One file is 160 radio messages. Folded into `sentUnicast`/`deliveryRatio`, a single
image transfer would dominate the mesh's headline metric and make it a statement
about the file rather than about the routing. Chunks are therefore counted in their
own counters — `sentChunks`, `transfersStarted`, `transfersCompleted`,
`transferStalls`, `bytesDelivered` — and excluded from the unicast ratio, exactly as
group traffic is excluded (`docs/06` §14). Both engines assert this
(`keeps media out of the 1:1 delivery metrics`).

The UI follows the same rule: chunks render as one progress row per transfer, not as
160 empty chat bubbles, and the dashboard's *Media transport* section appears only
once a transfer exists.

---

## 4. The sliding window is the lever

skills/05 says "sliding-window ACK" but not how deep. Measured on the same 10 MB
image:

| window | 1 hop | 3 hops | retransmits (3 hops) |
|---|---|---|---|
| 1 | 31.98 s | 1.47 min | 4 |
| 2 | 15.31 s | 50.30 s | 0 |
| **4 (default)** | **7.60 s** | **33.00 s** | **0** |
| 8 | 3.82 s | 14.38 s | 4 |
| 16 | 2.06 s | 8.63 s | 0 |

Depth scales almost perfectly linearly: window 16 is 15.5× faster than window 1 at
one hop and 10.2× faster at three. So the interesting question is why not 16.

Two reasons, and one of them is a limit of this model rather than a finding:

1. **Memory and exposure.** 16 chunks in flight is 1 MB of unacknowledged payload per
   transfer on a handset, and every one of them is a candidate for retransmission when
   a link goes marginal. The retransmit column above is *not* evidence for this — it
   moves with the pair and the seed, not with the depth (0 at depth 16, 4 at depth 8).
2. **The simulator has no channel-access model.** There is no CSMA, no collision and
   no shared-medium contention (§11), so a deep window is charged nothing for filling
   the air. The linear scaling above is therefore an **upper bound** on what depth
   buys, not a prediction.

Window 4 ships as the default: it is the depth at which a 10 MB image crosses three
hops in 33 s — inside the roadmap's criterion — while holding 256 KB in flight, and
it is the deepest value whose benefit does not depend on a contention model this
simulator does not have.

---

## 5. Push-to-talk: streamed against sent-as-one-blob

### 5.1 Frame timing, honestly

skills/05's pipeline is *"Opus 12 kbps, 16 kHz mono, 20 ms frames batched into 500 ms
chunks"*, so a note of `seconds` is `ceil(seconds × 1000 / voiceFrameMs)` frames of
`voiceFrameMs × voiceKbps / 8` bytes (750 B at 12 kbps).

The first version of this model let frame *i* leave at `i × 500 ms`, which made a 3 s
note fully received 400 ms *before* the user let go of the button — a negative play
delay. That is wrong in the optimistic direction: frame *i* covers the capture window
`[i, i+1) × 500 ms`, so it cannot leave before the end of that window. The shipped
model schedules frame *i* at `min((i+1) × frameMs, seconds × 1000)`, which puts the
last frame on air exactly at release. Every PTT number below is measured against that
honest worst case, and `releasedAt = now + seconds × 1000` for both modes — a blob
cannot be sent before it has been recorded either.

Three quantities are reported, because they answer different questions:

* **first audio** — button press → first frame playable (`firstChunkAt +
  jitterBufferMs − startedAt`). This is what a walkie-talkie user feels.
* **play delay** — button release → whole note playable (`completedAt +
  jitterBufferMs − releasedAt`). This is what the roadmap's `<3 s 1-hop / <8 s 3-hop`
  criterion and skills/05's `<1 s round-trip` box are written against.
* **underruns** — arrival gaps longer than `voiceFrameMs + jitterBufferMs`, i.e. holes
  the playout buffer cannot cover. This is the only available proxy for "intelligible":
  no codec runs here (§11).

### 5.2 Measured

Streamed, BLE (a 750 B frame stays inside one packet), on the cleanest pair at each
distance; blob, one message at release:

| note | mode | hops | transport | first audio | play delay | max gap | underruns |
|---|---|---|---|---|---|---|---|
| 3 s | streamed | 1 | ble | 989 ms | 407 ms | 518 ms | 0 |
| 3 s | streamed | 2 | ble | 1.27 s | 585 ms | 1.11 s | 1 |
| 3 s | streamed | 3 | ble | 1.74 s | 1.10 s | 576 ms | 0 |
| 3 s | blob | 1 | wifiDirect | 3.43 s | 427 ms | — | 0 |
| 3 s | blob | 3 | wifiDirect | 3.99 s | 991 ms | — | 0 |
| 30 s | streamed | 1 | ble | 989 ms | 488 ms | 615 ms | 0 |
| 30 s | streamed | 3 | ble | 1.74 s | 1.17 s | 739 ms | 2 |
| 30 s | blob | 1 | wifiDirect | **30.32 s** | 318 ms | — | 0 |
| 30 s | blob | 3 | wifiDirect | **30.66 s** | 659 ms | — | 0 |

Read off that table:

* **The roadmap's PTT criterion passes with ~7× margin** at both ends: 407 ms against
  a 3 s budget at one hop, 1.10-1.17 s against 8 s at three.
* **Streaming's advantage is first audio, not play delay.** For a 30 s note the first
  frame is playable at 989 ms streamed against 30.32 s as a blob — 31× sooner — while
  the blob's play delay from release is *slightly better* (318-659 ms against
  488-1170 ms) because it rides the 40 ms radio instead of the 120 ms one. A blob
  gives you nothing until it gives you everything.
* **skills/05's own mode table is consistent with this.** It prescribes streaming PTT
  at one hop (150-300 ms) and a *voice note* — "press → send → peer plays once fully
  received", 2-8 s — at 2-5 hops. Measured: the blob arrives 578 ms and 991 ms after
  release at 2 and 3 hops, inside its 2-8 s band, and streaming is inside it too. The
  spec's split is a UX choice about liveness, not a latency necessity.
* Against `festivalCrowd`, where paths are longer and lossier, streamed play delay is
  429 ms / 1.29 s / 1.19 s at 1/2/3 hops — the same story.

### 5.3 The ceiling behind "6-12 kbps"

`docs/05` §3.3 specifies 6-12 kbps for Opus, and skills/05 says *"DON'T attempt BLE
Mesh audio streaming"*. Neither states why those rates, but the packet model derives
the ceiling exactly:

```
frameBytes = voiceFrameMs × voiceKbps / 8  ≤  1024   ⟺   voiceKbps ≤ 8192 / 500 = 16.4
```

| rate | frame | transport chosen | padded wire size |
|---|---|---|---|
| 6 kbit/s | 375 B | ble | 512 B |
| 12 kbit/s | 750 B | ble | **1024 B — exactly one packet, no slack** |
| 16 kbit/s | 1000 B | ble | 1280 B → would be Wi-Fi Direct |
| 24 kbit/s | 1500 B | **wifiDirect** | 1792 B |

The padded column applies the packet model from `docs/07` §4 —
`ceil((95 + payload) / 256) × 256` — and it tightens the ceiling: a payload stays in
one BLE packet up to **929 B**, i.e. up to **14.9 kbit/s** at 500 ms frames, not 16.4.
At 12 kbps the padded frame is *exactly* 1024 B, so the documented rate is not merely
under the ceiling, it is flush against it: any header growth (a per-frame nonce, a
longer transfer id) pushes a voice frame onto the Wi-Fi radio.

So 12 kbps is the fastest documented rate that keeps push-to-talk on the radio that is
guaranteed to be up. At 24 kbps a note silently starts requiring a Wi-Fi Direct group
owner — available in a car park, not available in a pocket-to-pocket BLE mesh — and
the failure mode is a note that never sends rather than one that sounds worse. Both
engines assert the 750 B / 1500 B pair and the 16.384 kbit/s raw ceiling.

The engine picks a chunk's transport from its **payload** size, not its padded size
(§8), which is the convention that keeps a 512 B BLE slice on BLE. The cost is that a
16 kbit/s frame reads as BLE here and would be Wi-Fi Direct on the wire; the padding
column above is the correction, and it is why the shipped default is 12 kbps.

---

## 6. The defect the measurement found: a transfer that never finishes

Sweeping the retry timer (§7) produced a run that did not complete: a 30 s note, two
hops, 1200 ms timer, budget 150 s — every frame put on air, and the transfer still
`active` at the end.

The mechanism is a hole in the "chunks are ordinary unicasts" design:

1. A chunk's retries run out (`maxRetries = 2`).
2. `onAckTimeout` does what it does for any message — parks it in the originator's
   OppQueue to be carried until a contact appears (`docs/03` §8).
3. But a bundled message is only re-sent on a peer discovery, and when it is, its
   logical id is already in every receiver's seen cache. It never arrives again.
4. The sliding window waits for that chunk forever. `received < chunks` for the rest of
   the run.

For text this is correct behaviour: a message in an OppQueue is a message that will
eventually be delivered. For a windowed transfer it is a hang, and it is exactly the
case skills/05's third acceptance box is about (*"resume after mid-transfer
disconnect"*).

**The fix is a stall watchdog.** While a transfer is active, a `transferstall` event
re-arms every `max(transferStallMs, timeout × (maxRetries+1) × 1.25)` ms — the
threshold follows the retry timer it backstops, so a transfer three hops away is not
kicked for being legitimately far — and re-sends the chunks that are in `onAir` but not
in `receivedChunks`. Two details matter:

* **Only chunks that went on air.** A voice note is captured in real time, so frames
  that have not been recorded yet are missing without being lost. Re-sending those
  would put the whole note on air at once and defeat the streaming design.
* **The receiver dedupes by index**, so a kick that was not needed costs radio time
  and nothing else.

Measured against skills/05's box 3, verbatim: a 10 MB image over Wi-Fi Direct, three
hops, receiver taken offline at chunk 49 of 160 for 20 s.

```
160/160 chunks arrived, 6 window stalls (all 6 while the receiver was away),
0 retransmitted chunks → resumed and completed in 45.02 s
```

Both engines assert this (`resumes a 10 MB Wi-Fi Direct image after a mid-transfer
disconnect`), including the intermediate state: nothing arrives while the peer is away,
and the watchdog notices.

---

## 7. The retry timer: 4 s is eight voice frames

The data plane's `ackTimeoutMs` is 4000 ms, tuned for text (§`docs/06`). For a voice
note that is eight frames long: one lost frame leaves a four-second hole in the audio,
and a 200 ms jitter buffer cannot cover it. Media therefore retries on its own timer,
`mediaAckTimeoutMs = 600`.

30 s note, streamed, two hops, **mean of three seeds** (one pair is not a sample):

| timer | play delay | worst gap | underruns | retransmits | stalls |
|---|---|---|---|---|---|
| 4000 ms (text plane) | 1.32 s | **8.53 s** | **16** | 11 | 0 |
| 1200 ms | 9.97 s | 26.24 s | 15 | 13 | 4 |
| **600 ms (ships)** | **1.06 s** | **1.21 s** | **7** | 5 | 0 |
| 300 ms | 1.03 s | 1.19 s | 12 | 9 | 0 |

Same note at three hops:

| timer | play delay | worst gap | underruns | retransmits |
|---|---|---|---|---|
| 4000 ms | 2.19 s | 4.97 s | 8 | 1 |
| 2500 ms | 1.03 s | 3.29 s | **6** | 2 |
| 1200 ms | 1.09 s | 1.67 s | 13 | 2 |
| 600 ms | 994 ms | 1.13 s | 21 | 7 |
| 300 ms | 1.11 s | 1.49 s | 13 | 11 |

And the same timer's effect on a file, 10 MB at two hops:

| timer | time | throughput | retransmits | stalls |
|---|---|---|---|---|
| 4000 ms | 44.71 s | 1.88 Mbit/s | 42 | 1 |
| 1200 ms | 30.15 s | 2.78 Mbit/s | 47 | 1 |
| **600 ms** | **24.09 s** | **3.48 Mbit/s** | 32 | 0 |
| 300 ms | 45.01 s | 1.86 Mbit/s | 27 | 5 |

What this supports, and what it does not:

* **A media timer well under one second is clearly right.** Against the text plane's
  4 s it cuts the worst audio gap from 8.53 s to 1.21 s, underruns from 16 to 7, and
  the same file's transfer time by 46% (44.71 s → 24.09 s).
* **"600 ms is optimal" is not supported.** The ordering is not monotonic — 1200 ms is
  worse than both its neighbours at two hops, and at three hops 600 ms has the best
  mean play delay but the most underruns. Retransmit and stall counts move with the
  pair and the seed as much as with the timer. The honest claim is *well under one
  second*, and 600 ms is the value that is best-or-tied on the two-hop voice sweep and
  best on the file sweep.
* **A too-eager timer costs more than it saves.** At 300 ms a file at two hops takes
  45.01 s — worse than waiting 4 s — with five window stalls: the timer is shorter
  than a round trip, so chunks still in flight are re-sent, and the duplicates crowd
  out the originals.

### 7.1 An adaptive timer, measured and rejected

The obvious refinement is to size the timer from the path: measure round trips from the
transfer's own ACKs and derive the timeout. Two rules were implemented and measured.

* **RFC 6298 RTO** (`srtt + 4·rttvar`, clamped to [300 ms, 4 s]): for a file it drifted
  to the 4 s ceiling, because with a window of chunks in flight the smoothed average
  measures the queue the transfer is creating for itself. 31.96 s for the 10 MB image
  against 24.09 s for fixed 600 ms.
* **Minimum RTT** (`2 × minRtt + 200`, same clamp) fixes the drift — it converged on
  1371 ms at two hops and 2049 ms at three — and still loses: 1.43 s play delay and 14
  underruns at two hops against 1.06 s and 7; 28.38 s for the file against 24.09 s.

The mechanism is worth keeping, because it is counter-intuitive: for a
**deadline-driven** stream, an early duplicate beats a correctly-sized timeout. Loss is
per-packet and independent, and the receiver dedupes by index, so re-sending before the
round trip has even elapsed is scheduled redundancy wearing a retry's clothes. The
proper version of that is FEC or frame interleaving, which needs a codec this simulator
does not model (§11).

`adaptiveMediaAck` therefore **defaults to false**. The code and both rules stay, so
the measurement can be repeated against a real RTT distribution, and the sweep above is
one flag away.

---

## 8. What a BLE-only mesh can actually carry

skills/05 slices to a *"chunked BLE 512B MTU"* when no Wi-Fi Direct group owner is
available, and `docs/05` §3.2 has the app *"auto-reject files >5 MB on BLE-only"* with
a "move closer to SUPER" hint. Measured at that MTU:

| size | chunks | time at 1 hop |
|---|---|---|
| 256 KB | 512 | 32.14 s |
| 1 MB | 2048 | 2.10 min |
| 2 MB | 4096 | 4.19 min |
| 5 MB | 10240 | **>5 min** (4896 arrived) |
| 10 MB | 20480 | **did not finish in 15 simulated minutes**, at one hop *and* at two |

Two conclusions:

1. **The auto-reject rule is directionally right and numerically generous.** 5 MB is
   allowed by the spec but cannot complete in 5 minutes on a one-hop BLE link. If the
   product criterion is "under a couple of minutes", the ceiling belongs near **1 MB**;
   at 5 MB the honest UI is a progress bar with a minutes-scale estimate, not a hint
   about moving closer.
2. **The engine enforces the ceiling that *is* specified.** skills/05's "Max 10 MB" is
   a hard limit: an 11 MB `sendFile` returns null and logs
   `refused 11.0 MB to node-12 — over the 10 MB ceiling (skills/05)`, asserted in both
   engines.

A note on the size convention: a chunk declares its **payload** size, not its wire
size, so a 512 B slice is charged 512 B and stays on BLE. Charging `wireSizeOf`
instead would add the 95 B header and 256 B padding block — ≤0.2% on a 64 KB slice —
but would push a 1024 B slice to 1280 B on the wire and escalate it to Wi-Fi Direct,
which is not where skills/05 puts it. The payload convention is the one that matches
the spec, and the omission is stated here rather than buried.

---

## 9. Contention: what one file does to everybody else — and a correction

The first version of this section reported that a 10 MB transfer in flight cost the mesh
1.8 points of delivery, pushed 35 messages into store-carry-forward, and moved p95 latency.
**That measurement was wrong, and the reason is worth more than the numbers.**

Each arm had drawn its own traffic from the simulation's RNG. So the "quiet" arm and the
"busy" arm did not send the same messages, and — because a media run consumes randomness
for every chunk's jitter and loss — every later draw in the busy arm was different. It was
two experiments wearing one table, which is exactly the confound `docs/06` §7 warns about
and §16.4 measures the size of.

Re-run properly — one fixed traffic plan of 60 messages replayed identically in both arms,
mean of three seeds, the file started before the first message:

| | quiet | with a 10 MB file in flight |
|---|---|---|
| messages sent | 59.0 | 59.0 |
| delivery ratio | **0.9944** | **0.9944** |
| within 5 hops | 0.9944 | 0.9944 |
| p95 latency | 4,472 ms | 3,275 ms |
| relay transmissions | 1,728 | **5,311** |
| retries sent | 11 | **59** |
| messages parked | 1.0 | 1.0 |
| retries exhausted | 1.0 | 1.0 |
| the transfer itself | — | 10.71 s |

Per seed, delivery is `0.983, 1.000, 1.000` in **both** arms. The only differences are the
media's own work — relay transmissions triple and retries go from 11 to 59, which is the
file's 160 chunks and their retransmissions — and a p95 that moves because the sample's
loss draws moved, not because anything got slower.

### 9.1 Why the answer is null, and why that is not luck

A 10 MB file does not harm text traffic in this model, and it cannot:

* **Loss is per packet and independent of volume.** `effectiveLossProbability` is a function
  of the link's margin and the retry count. Nothing about how busy the radio is enters it.
* **There is no shared medium.** Two transmissions at the same instant both succeed. A chunk
  occupies the radio in *time* — the serialization charge of §2 — but time is not contested,
  so occupying it does not displace anybody.

So the honest statement is not "media is polite on this mesh" but **"this model has no
mechanism by which media could be impolite"**. The 11.7× relay-transmission figure from the
confounded run survives as a fact about *cost* (a file is a lot of radio work) while the
claim about *harm* is withdrawn.

### 9.2 The consequence for the obvious next feature

The natural response to §9's first version was a load gate: refuse or shrink a transfer's
window while the mesh is busy. **On this model's evidence it should not be built** — there is
nothing for it to protect. A gate here would slow transfers in exchange for a benefit the
model cannot express, which is how a plausible-sounding feature ends up costing users time
for nothing.

The gate becomes a real question only once the missing mechanism exists: a channel-access
model where concurrent transmissions compete for one radio. That model was then built,
behind a flag that defaults to the behaviour measured here, and it reverses this
recommendation — §12.5 finds the gate is worth 2.8 points of everybody else's delivery at no
cost in file time, and that the right knob is the window rather than the chunk size. Both
results are reported because they are both true, of different networks: §9 describes the
model the roadmap's acceptance gates were written against, §12 describes the radio a phone
carries.

## 10. Acceptance mapping

skills/05:

| box | measured | verdict |
|---|---|---|
| 1-hop WiFi: PTT round-trip <1 s, intelligible (MOS proxy test) | 292 ms round trip; 92 ms excluding the 200 ms buffer, against the modes table's 150-300 ms band | **PASS** on latency (3.4× margin). *"Intelligible" is not simulatable* — no codec runs here; the underrun count (0 on this path) is the only proxy |
| 3-hop BLE: voice note arrives intact, Opus decode clean | 6/6 frames arrived over BLE at three hops, play delay 1.10 s, 0 arrival gaps longer than frame+buffer | **PASS** on "intact". "Decode clean" is a codec property; the gap count is the proxy and it is 0 |
| 10 MB image: delivered over WiFi Direct with resume after mid-transfer disconnect | 160/160 chunks, receiver offline at chunk 49 for 20 s, 6 window stalls, resumed, 45.02 s total | **PASS** — and it only passes because of the watchdog in §6 |

Also from skills/05: `VOICE_CHUNK` at `prio=high, ttl=3` (asserted per frame, and file
slices keep the data plane's ttl 5), the 512 B BLE MTU, and "Max 10 MB" enforced.

roadmap Phase 3:

| item | verdict |
|---|---|
| Media transport: WiFi Direct P2P for files, BLE chunked streaming for voice | implemented in both engines; §3, §5 |
| *Exit:* 2 phones exchange image <10 MB over WiFi Direct mesh | 10 MB, 3 hops, 33.00 s (§3) |
| *Exit:* PTT Opus note plays in <3 s 1-hop / <8 s 3-hop | 407 ms / 1.10 s (§5.2) |

Not implemented, and not claimed: **broadcast voice** (skills/05's "flood voice clip to
all listeners, ttl=5"). Media is 1:1 in both engines; the UI disables the file and PTT
buttons while the destination is a group or everybody, because a scoped flood cannot
carry 160 chunks and a group has no single receiver to slide a window against. Flooding
a blob to `BROADCAST` would work through the existing broadcast path and is unmeasured.

---

## 11. What this model does not represent

Stated so no number above is read as more than it is:

* **Wi-Fi Direct group-owner formation.** `docs/05` §3.2 puts it at 1-3 s. It is
  modelled as a *setup latency* only when the caller forces the transport (skills/05's
  "GO connected" case assumes it is already negotiated); it is **not** a second RF
  budget. `rf.ts` is deliberately untouched, which is why every measurement in
  `docs/06` and `docs/07` still stands and why the SOS flood can be said to ride "all
  transports" (`docs/06` §11).
* **Channel access — the largest limitation here, and now a flag (§12).** Everything above
  §12 was measured with no CSMA, no collisions and no shared medium, all of it in the
  optimistic direction: a deep window (§4) and duplicate retransmissions (§7) are charged
  nothing for filling the air, so both results are upper bounds, and media cannot harm text
  traffic at all (§9). `channelAccess: "halfDuplex"` supplies the missing mechanism and
  re-measures; it ships off, because the acceptance gates in skills/02 and skills/08 were
  written against a radio with no channel. Even on, two things stay unmodelled and both are
  optimistic: a busy receiver can still take a packet, and queued packets do not collide.
* **A codec.** Opus is represented by frame *size* only. MOS, intelligibility, packet
  loss concealment and the 20 ms-frame batching are out of scope; underruns are inferred
  from arrival gaps against a `frameMs + jitterBufferMs` threshold, not from a playout
  clock.
* **Battery.** A transfer draws the normal radio drain. There is no separate Wi-Fi
  Direct power figure, so skills/07's %/h numbers are unchanged by this work — and a
  33 s Wi-Fi Direct burst is exactly the kind of thing that deserves one.
* **RNG.** The per-chunk jitter draw is new randomness consumption, but only on media
  runs; no golden vector exercises a transfer, which is why the fixtures did not move.

---

## 12. Channel access: what one radio changes

§9's null result is a property of the model, and §11 named it as the largest limitation
here: with no shared medium, a transmission occupies no exclusive resource, so media has
no mechanism by which it could compete with text. This section closes that gap behind a
flag — `channelAccess` — and re-measures the same questions on the radio a phone actually
has.

`"free"` ships and is the default: an infinitely wide radio, exactly what every number in
this document so far was measured under, byte-identical golden vectors included.
`"halfDuplex"` gives each device one transmitter doing one thing at a time. Packets join a
bounded FIFO (`channelQueueDepth`, 8) and go on air when the radio comes free; when the
FIFO is full the newest packet is dropped, because a real radio sheds load rather than
promising air time it does not have. Air time is what §2 already computes: hop latency plus
serialization plus jitter — and a packet that is *lost* still occupied the radio for all of
it. Two things remain unmodelled, both in the optimistic direction: a busy **receiver** can
still take a packet (no capture effect), and packets waiting their turn do not collide.

### 12.1 Two wrong implementations, kept on the record

The flag took three attempts, and the first two failures are more instructive than the
result.

**Committing air time instead of queueing it.** The first implementation let `transmit()`
schedule a delivery at `max(now, radioFreeAt)` and push `radioFreeAt` forward, for both
endpoints. Nothing bounded how far ahead a radio could be committed, so a busy node's
horizon ran away: delivery fell to **0.37 on a 20-node campus with no media in flight at
all**, with 957 minutes of "deferred" air time over 1,202 transmissions — an average wait
of 47 s per packet. The packets were not late, they were scheduled past the end of the run.
It was an open-loop queue with no shedding: every retry added air time to a horizon that
was already unreachable, which produced more retries. Bounding the queue and dropping at
the tail is what makes the model a radio rather than an arithmetic accident.

**A radio that never woke up.** The second implementation queued correctly but only
scheduled a drain event when it left packets behind. So a radio that finished its queue
while still busy had nothing pending to wake it, and the next packet handed to it waited
for some *other* transmission to come along — in a quiet mesh, forever. Same symptom,
different cause: 0.37 delivery, no media. Both are pinned by tests now
(`wakes a radio that went busy with an empty queue`, `sheds load when the queue is full`).

### 12.2 One file, alone: the window's parallelism was imaginary

10 MB, one transfer, nothing else in the world, mean of the probe's pair selection:

| hops | `free` | `halfDuplex` | throughput | dropped |
|---|---|---|---|---|
| 1 | **7.60 s** | **1.45 min** | 11,039 → 962 kbit/s | 0 → 239 |
| 2 | 17.99 s | 2.21 min | 4,663 → 632 kbit/s | 0 → 449 |
| 3 | 33.00 s | 3.97 min | 2,542 → 352 kbit/s | 0 → 6,235 |

§4 measured the sliding window as the lever that turns 31.98 s into 2.06 s — 15.5×. That
was four transmissions happening *at once*, which one radio cannot do:

| window | `free`, 1 hop | `halfDuplex`, 1 hop | dropped |
|---|---|---|---|
| 1 | 31.98 s | 1.78 min | 20 |
| 2 | 15.31 s | 1.84 min | 36 |
| 4 | 7.60 s | 1.45 min | 239 |
| 8 | 3.82 s | 1.32 min | 270 |
| 16 | 2.06 s | 1.11 min | 368 |

On a real radio the same sweep is worth **1.6× instead of 15.5×**, and what it is worth is
only ACK-latency hiding — the radio was always going to spend the same air time. Note the
drop column: depth does not merely stop paying, it starts costing, because a deeper window
commits more chunks than the queue can hold and the transfer retransmits them. On the
2-node pair the tests pin, window 1 → 4 is 3.8× under `free` and 1.1× under `halfDuplex`,
while the whole transfer is 10× slower.

### 12.3 Voice: the capture clock is the limit, not the codec

A 500 ms frame is 750 B (§5), which fits in one BLE packet, so its air time is hop latency
plus jitter: about **245 ms per hop**. Streaming over N hops therefore needs ≈245N ms of
radio for every 500 ms of recording. That is arithmetic, and it predicts the result before
any measurement: sustainable at one hop, no slack at two (490 ms against a 500 ms clock, so
one retransmission starts a queue that never drains), and impossible at three.

| hops | `free` play delay | `halfDuplex` play delay | underruns |
|---|---|---|---|
| 1 | 488 ms | **449 ms** | 0 → 0 |
| 2 | 1.22 s | **51.56 s** | 3 → 29 |
| 3 | 1.17 s | unfinished in 150 s | 2 → 27 |

The 30 s note at three hops on the campus world did not finish inside the probe's 150 s
budget. On the quiet 4-node line the tests use, a 10 s note finishes — 17.8 s after the
user let go, against 757 ms under `free`, a 23× difference — and a 30 s note finishes 60.6 s
after release, i.e. it takes three times the length of the note to deliver the note.
Nothing is lost; every frame arrives. It arrives long after it was worth hearing, which is
a different failure and a worse one for push-to-talk.

### 12.4 The §9 A/B again, on a real radio

Same fixed plan, same three seeds, text metrics snapshotted at the end of the plan in every
arm so a transfer that takes minutes cannot dilute its own damage across a tail where
nothing competes:

| | `free` quiet | `free` + 10 MB | `halfDuplex` quiet | `halfDuplex` + 10 MB |
|---|---|---|---|---|
| delivery ratio | 0.9944 | 0.9944 | **0.9831** | **0.9548** |
| within 5 hops | 0.9944 | 0.9944 | 0.9774 | 0.9435 |
| p95 latency | 4,472 ms | 3,275 ms | 5,077 ms | 7,954 ms |
| retries sent | 11 | 59 | 17 | 272 |
| messages parked | 1.0 | 1.0 | 4.0 | 12.3 |
| queue drops | 0 | 0 | 248 | 2,409 |
| deferred air time | 0 | 0 | 17.3 min | 46.8 min |

Two things to read carefully. Text alone is barely hurt by having a real radio (0.9944 →
0.9831): 250-byte packets are short, and a 20-node campus at one message per two seconds is
nowhere near the air-time budget. **A 10 MB file costs 2.8 points of delivery, 3.4 points of
within-5, and 2.9 s of p95** — so §9's conclusion holds exactly as far as its model does,
and no further.

### 12.5 So is a load gate motivated? Yes — and it is the window, not the chunk size

With the transfer allowed to finish, so both sides of the trade are one experiment:

| | delivery | within 5 | p95 | parked | file time | dropped |
|---|---|---|---|---|---|---|
| no file | 0.9831 | 0.9774 | 5,077 ms | 4.0 | — | 248 |
| file, window 4 (ships) | **0.9548** | 0.9435 | 7,954 ms | 12.3 | 3.33 min | 2,409 |
| file, window 1 | **0.9887** | 0.9831 | 7,047 ms | 7.0 | **3.30 min** | 2,191 |

Committing one chunk at a time instead of four recovers **all** of the lost delivery — it
lands slightly *above* the no-file arm, which is within one message of noise and should be
read as "back to baseline" — and costs **nothing** in file time, because the air time was
serial anyway. That is the whole gate: no load sensor, no policy engine, one integer.

The intuitive alternative is wrong, and worth recording because it is the first thing an
engineer reaches for. Slicing the file smaller interleaves text *between* chunks instead of
*behind* them:

| chunk | delivery | p95 | file time | dropped |
|---|---|---|---|---|
| 64 KB (ships) | 0.9548 | 7,954 ms | 3.33 min | 2,409 |
| 16 KB | 0.9774 | 8,867 ms | **10.74 min** | 3,447 |
| 4 KB | 0.9718 | **16,839 ms** | unfinished in 15 min | 2,609 |

Adaptive fragmentation buys ~2 points of delivery and pays 3.2× in file time and 2.1× in
p95, and at 4 KB the transfer never finishes. The reason is §2's own arithmetic: air time is
`base + serialization + jitter`, and at 64 KB on Wi-Fi the fixed part (40 ms hop latency +
~125 ms jitter) is six times the serialization part (26 ms). Slicing 16× finer barely
reduces the air time of a byte and multiplies the fixed cost 16×: 10 MB is 30.6 s of air as
160 chunks and 427 s as 2,560. **Being polite in smaller pieces is not cheaper; it is much
more expensive.** The unit of politeness is how far ahead you commit, not how big you
commit.

### 12.6 The acceptance gates under a real radio

Same 20-node campus, same three seeds, no media:

| gate | `free` | `halfDuplex` | skills/02 and /08 want |
|---|---|---|---|
| delivery ratio | 0.9889 | **0.9556** | ≥ 0.90 ✓ |
| within 5 hops | 0.9889 | 0.9556 | ≥ 0.90 ✓ |
| overhead vs flood-all | 9.3 % | **38.6 %** | ≤ 70 % ✓ |
| SUPER ratio | 21.7 % | 25.0 % | 15–25 % ✓ (at the edge) |

The gates still pass, but the numbers are not the same network: overhead quadruples because
flood-all — which the ratio is measured against — is *also* slowed by the radio, and MPR's
advantage shrinks when air time rather than packet count is the scarce resource. That is
the honest reading, and it is why `halfDuplex` is a flag rather than a default: skills/02
and skills/08 were written against a model with no channel, and changing the shipped model
would silently redefine every acceptance number in the roadmap.

### 12.7 What ships, and what would change it

* `channelAccess: "free"` and `channelQueueDepth: 8` are in `DEFAULT_CONFIG`, and `free` is
  inert by construction: no counters move, no random draw changes order, golden vectors are
  byte-identical.
* If the team decides the real radio is the model to plan against, the one change with
  evidence behind it is **`transferWindow: 1`** (§12.5) — free in file time, worth 2.8
  points of everybody else's delivery.
* Push-to-talk beyond two hops needs a decision, not a parameter: at three hops a streamed
  note cannot keep up with its own capture clock on one radio (§12.3). Either the path is
  capped at two hops for streaming and longer notes are sent as blobs, or voice gets
  priority in the transmit queue — which this model does not implement, and which would be
  the next thing to measure.
* Voice priority in the transmit queue **is** implemented and measured (§12.8), and it does
  not do what it was for: it cannot rescue push-to-talk beyond two hops. It ships off.
* The receiver is modelled separately, by `channelCapture` (§12.9), and it is where most of
  the contention turns out to live. Two things remain unmodelled there as well: a capture
  effect that compares signal strengths rather than arrival order, and any carrier sense —
  a real radio defers before transmitting instead of transmitting blind.

### 12.8 Which packet a busy radio takes next

Once packets wait, the order they wait in is a design decision, and the obvious one is
wrong. `channelPriority` has three settings: `"fifo"` (arrival order, ships), `"ackFirst"`
(acknowledgements jump the queue), and `"class"` (a WMM-like ranking: an SOS and a voice
frame first, then acknowledgements, then everything else in arrival order — so a text
message overtakes the 64 KB chunk queued ahead of it). Mean of three seeds on the campus
world, all under `halfDuplex`:

**Text traffic with a 10 MB file in flight**

| priority | delivery | p95 | file time | queue drops |
|---|---|---|---|---|
| `fifo` | 0.9548 | 7,954 ms | 3.33 min | 2,409 |
| `ackFirst` | **0.9605** | **7,193 ms** | **3.15 min** | 2,545 |
| `class` | 0.9605 | 7,193 ms | 3.15 min | 2,545 |

`class` and `ackFirst` are identical here because nothing but text and chunks is in flight,
so the two settings make the same choice — a useful check that the ranking is doing what the
code says.

**A 30 s note with a 10 MB file in flight**

| priority | note delay after release | underruns | file time |
|---|---|---|---|
| `fifo` | 33.29 s | 21.7 | 3.74 min |
| `ackFirst` | **40.76 s** | 23.3 | 3.09 min |
| `class` | 33.45 s | 22.0 | **2.40 min** |

**Text with a 30 s note in flight, and an SOS with a file in flight**

| priority | text delivery | SOS mean latency |
|---|---|---|
| `fifo` | **0.9658** | 8.33 s |
| `ackFirst` | 0.9573 | 8.32 s |
| `class` | 0.9573 | 8.33 s |

Three things follow, and only the first is what the feature was for.

**Promoting acknowledgements is what pays.** An ACK is about 100 bytes and it is what
releases the next chunk of somebody's transfer, so letting it overtake a 64 KB slice takes
5% off a file that has text to compete with and 17% off one that has a note, and text
delivery and p95 move the same way. The tests pin the mechanism on one radio: with a 2 MB
transfer already committed, an ACK arrives after 8 chunks under `fifo` and after 5 under
`ackFirst`, and the transfer finishes in 15.0 s instead of 18.1 s.

**Promoting voice buys the file more and the voice nothing.** `class` cuts the same
note-competed transfer by a further 22% (3.09 → 2.40 min, 36% below `fifo`) because bulk
chunks are now the lowest class of all — and the note's own delay is unchanged at 33.4 s
with the same underruns. `ackFirst` alone actually *hurts* the note (33.3 → 40.8 s) because
voice frames now wait behind acknowledgements. On one radio the tests pin it: a 5 s note
started while a 2 MB file is in flight finishes at 24.3 s under `fifo`, with 9 of its 10
frames arriving before the file does, and at **15.4 s** under `class`, with all 10 first.

**Nothing rescues push-to-talk at three hops.** §12.3's limit is the note's own air time —
735 ms of radio per 500 ms of capture — and no queue discipline creates air time. Priority
changes who waits, not how much waiting there is; a note that is over-subscribed on its own
path stays over-subscribed while everybody else pays for the attempt, which is the 0.9 point
of text delivery `class` costs when a note is in flight. An SOS is untouched in every arm:
four floods of a 100-byte packet are not what a busy radio is waiting on.

So `"fifo"` ships. If the real radio is the model to plan against, the evidence-backed order
is: window 1 (§12.5), then `"ackFirst"`, and only then `"class"` — and `"class"` should be
chosen for bulk-transfer speed, not for voice.

### 12.9 Receiver contention, and why the acceptance gates lose their margin

§12 gave the device one transmitter and left the receiver infinitely attentive: a node on air
could still hear, and two packets arriving together both landed. `channelCapture` closes both.
`"first"` — the only setting besides the shipped `"none"` — makes the receiver lock onto
whichever packet arrived first, and makes a transmitting node deaf. Both are modelled as losses
rather than deferrals, because that is what a collision is, and neither compares signal
strengths, so the earlier packet always wins. The flag is independent of `channelAccess`, which
is what makes the two mechanisms separable:

**60 text messages at 2 s, nothing else** (3 seeds, 20-node campus)

| transmitter | receiver | delivery | within 5 | p95 | retries | parked | captured | deaf |
|---|---|---|---|---|---|---|---|---|
| `free` | `none` | **0.9944** | 0.9944 | 4,472 ms | 11 | 1.0 | 0 | 0 |
| `free` | `first` | 0.9831 | 0.9774 | **7,534 ms** | 32 | 8.7 | 661 | 180 |
| `halfDuplex` | `none` | 0.9831 | 0.9774 | 5,077 ms | 17 | 4.0 | 0 | 0 |
| `halfDuplex` | `first` | **0.9040** | 0.9040 | 10,550 ms | 52 | 15.3 | 291 | 267 |

**The same traffic with a 10 MB file in flight**

| transmitter | receiver | delivery | p95 | retries | parked | captured | deaf | queue drops | file time |
|---|---|---|---|---|---|---|---|---|---|
| `free` | `none` | **0.9944** | 3,275 ms | 59 | 1.0 | 0 | 0 | 0 | 10.71 s |
| `free` | `first` | **0.8588** | 10,314 ms | 379 | 37.3 | 3,625 | 1,256 | 0 | 1.98 min |
| `halfDuplex` | `none` | 0.9548 | 7,954 ms | 272 | 12.3 | 0 | 0 | 2,409 | 3.33 min |
| `halfDuplex` | `first` | 0.8927 | 11,681 ms | 310 | 21.0 | 603 | 808 | 1,744 | 3.75 min |

Four things follow.

**The receiver is where contention lives.** With a file in flight, a transmitter queue alone
costs text 4.0 points of delivery (0.9944 → 0.9548) and receiver collisions alone cost **13.6**
(0.9944 → 0.8588). §9's null result was not wrong about the transmitter; it was missing the
larger half of the mechanism. A single radio that can still hear everything is a much friendlier
network than a radio that cannot.

**Once collisions exist, the queue earns its keep.** Under `"none"` adding a transmitter queue
costs 4.0 points; under `"first"` adding one *recovers* 3.4 (0.8588 → 0.8927), because
serialising a node's own transmissions removes the overlaps it was causing everybody else. That
is the closest thing to a CSMA result in this repository: the discipline is worth having only
once there is something to collide with, and §12.5's window-1 recommendation still holds on top
of it.

**Collisions are paid in latency before delivery.** In a quiet mesh, receiver contention moves
p95 by +68% (4,472 → 7,534 ms) to cost 1.1 points of delivery, because a collided packet is not
lost — the sender's ACK timeout re-sends it into an idle radio four seconds later. The unit
tests pin exactly that: two packets sent to one receiver at the same instant produce one
collision and *two* deliveries.

**Most of the collisions are a node not hearing itself.** With a file in flight under
`halfDuplex` + `first`, 808 losses are deaf-receiver against 603 first-capture. A real CSMA/CA
radio defers rather than transmitting blind, so this arm overstates that half of the harm —
while the missing capture effect (a strong packet surviving a weak one) understates the other.
The two omissions do not cancel and are not claimed to.

**And the acceptance gates lose their margin.** The same 20-node campus, three seeds, gates
measured against a naive flood-all run under the same radio:

| transmitter | receiver | delivery | within 5 | overhead vs flood-all | SUPER ratio | queue drops |
|---|---|---|---|---|---|---|
| `free` | `none` (ships) | 0.9889 | 0.9889 | 9.3 % | 21.7 % | 0 |
| `free` | `first` | **0.9056** | 0.9056 | 15.8 % | 25.0 % | 0 |
| `halfDuplex` | `none` | 0.9556 | 0.9556 | 38.6 % | 25.0 % | 538 |
| `halfDuplex` | `first` | **0.9000** | 0.9000 | 27.1 % | 21.7 % | 185 |

skills/02 and skills/08 both ask for delivery ≥ 0.90. Under the two radios that have a receiver
in them, the campus measures **0.9056** and **0.9000** — the gate is met with nothing to spare.
Overhead stays comfortably inside 70% in every arm and the SUPER ratio stays inside its band, so
delivery is the binding criterion and contention is what binds it. That is the most consequential
number in this document: the roadmap's acceptance gates were calibrated against a radio with no
contention, and the moment a receiver is added the margin is zero. It is also an argument about
ordering — `docs/09`'s field test should measure delivery ratio on a real floor before anybody
tunes anything else, because the simulator can no longer claim headroom it does not have.

Neither flag ships: `channelCapture: "none"` is inert by construction (no counter moves, no
random draw changes order, golden vectors byte-identical), and the four-arm comparison above is
what the two flags are for — a decomposition, not a setting to leave on without deciding which
radio you are claiming to have.

## 13. Reproducing

```bash
npm run media                                            # TypeScript probe, every table above (§7-§9 for the radio)
dart run bin/mesh_sim.dart --scenario campus_quad --seed 42 --media --no-check
npm test                                                 # 243 TS tests, incl. 18 media + 6 channel cases
cd sim/mesh_sim && dart test                             # 18 Dart media cases + test/channel_test.dart
```

Engine surface: `sendFile(from, to, bytes, {chunkBytes, window, transport})`,
`sendVoice(from, to, seconds, {stream, transport})`, `serializationMs(bytes, transport)`,
`mediaTimeoutMs(transfer)`, `sim.transfers`, and the config keys `bleKbps`,
`wifiDirectKbps`, `transferChunkBytes`, `transferWindow`, `transferStallMs`,
`mediaAckTimeoutMs`, `adaptiveMediaAck`, `voiceKbps`, `voiceFrameMs`, `jitterBufferMs`,
`voiceTtl`, `maxTransferBytes`, `channelAccess`, `channelQueueDepth`, `channelPriority`,
`channelCapture`.

Tests that pin this document's claims: `media transport (docs/05 §3.2-3.3, roadmap
Phase 3)`, `media against skills/05 (Voice PTT & Media)`, `media under load, measured
without confounding the A/B (docs/08 §9)` and `channel access: one radio, half-duplex
(docs/08 §12)` and `which packet a busy radio takes next (docs/08 §12.8)` and
`receiver contention: what a busy receiver does (docs/08 §12.9)` in
`src/__tests__/simulation.test.ts`, `media transport in the UI` in
`src/__tests__/components.test.tsx`, and `test/media_test.dart` plus `test/channel_test.dart`
in the Dart engine.
