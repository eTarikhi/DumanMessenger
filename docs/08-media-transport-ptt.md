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
no mechanism by which it could compete with text. This section closes that gap behind
flags — `channelAccess` and `channelCapture` — and re-measures the same questions on the
radio a phone actually has.

> **Every number in this section was measured twice.** The first pass was taken with a
> retry timer that started when a packet was handed to the radio instead of when it went
> on air, which under a queued radio retransmitted packets that had not been transmitted
> yet and made queueing look substantially worse than it is. §12.11 documents the defect
> and what each table said before it was fixed; the tables below are the corrected ones.

> **Every number in this section is also a property of one occupancy model** (`docs/06`
> §24.6). A packet here holds a radio for the calibrated hop latency — 120 ms on BLE —
> whatever its size, because `hopLatencyBleMs` was calibrated to include one full-sized GATT
> write. That is right at 1 024 B and over-charges everything below it: a 256 B padded text
> is 25.6 ms of airtime at the modelled bit rate, and a beacon (which §24.6 derives at 630 B
> typically) is 63 ms. Charging each packet its own size instead, behind
> `radioOccupancy: "airtime"`, moves this section's magnitudes considerably and **not always
> the same way**: under `csma` in `festival_crowd` delivery goes 68.5 % → 74.1 % and
> deferrals halve (12 649 → 6 707) over eight seeds, and `campus_quad` reaches 100 % on all
> eight with broadcast reach 57.8 % → 81.6 %; under `half-duplex` in the same crowd delivery
> goes the other way by about two points, on a three-seed measurement that `docs/06` §24.8
> says is too thin to quote a magnitude from.
> The *directions* below survive — a queue still earns back what collisions cost, capture
> still takes over as the margin rises, a media load gate still costs what it says it costs —
> but the drop and deferral counts are the flat-charge world's, and are quoted here as such.

`channelAccess: "free"` ships and is the default: an infinitely wide radio, exactly what
every number in this document before §12 was measured under, golden vectors byte-identical
included. `"halfDuplex"` gives each device one transmitter doing one thing at a time —
packets join a bounded FIFO (`channelQueueDepth`, 8), go on air when the radio comes free,
and are dropped at the tail when it is full, because a real radio sheds load rather than
promising air time it does not have. `"csma"` adds carrier sense on top of that (§12.10).
Air time is what §2 already computes — hop latency plus serialization plus jitter — and a
packet that is *lost* still occupied the radio for all of it.

`channelCapture` is the receiver. `"none"` ships: a busy receiver takes everything.
`"first"` locks the receiver onto whichever packet arrived first and makes a transmitting
node deaf (§12.9). Both are modelled as losses, not deferrals, because that is what a
collision is.

### 12.1 Two wrong implementations, kept on the record

The transmitter flag took three attempts, and the first two failures are more instructive
than the result.

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

10 MB, one transfer, nothing else in the world:

| hops | `free` | `halfDuplex` | throughput | dropped |
|---|---|---|---|---|
| 1 | **7.60 s** | **1.50 min** | 11,039 → 930 kbit/s | 0 → 198 |
| 2 | 17.99 s | 2.31 min | 4,663 → 606 kbit/s | 0 → 388 |
| 3 | 33.00 s | 4.44 min | 2,542 → 315 kbit/s | 0 → 6,698 |

§4 measured the sliding window as the lever that turns 31.98 s into 2.06 s — 15.5×. That
was four transmissions happening *at once*, which one radio cannot do:

| window | `free`, 1 hop | `halfDuplex`, 1 hop | dropped |
|---|---|---|---|
| 1 | 31.98 s | 1.53 min | 72 |
| 2 | 15.31 s | 1.64 min | 67 |
| 4 | 7.60 s | 1.50 min | 198 |
| 8 | 3.82 s | 1.27 min | 299 |
| 16 | 2.06 s | 1.22 min | 323 |

On a real radio the same sweep is worth **1.25× instead of 15.5×**, and what it is worth is
only ACK-latency hiding — the radio was always going to spend the same air time. Note the
drop column: depth does not merely stop paying, it starts costing, because a deeper window
commits more chunks than the queue can hold and the transfer retransmits them. On the 2-node
pair the tests pin, window 1 → 4 is 3.8× under `free` (35.0 s → 9.2 s) and **1.02×** under
`halfDuplex` (92.3 s → 90.2 s), while the whole transfer is 9.8× slower.

### 12.3 Voice: the capture clock is the limit, not the codec

A 500 ms frame is 750 B (§5), which fits in one BLE packet, so its air time is hop latency
plus jitter: about **245 ms per hop**. Streaming over N hops therefore needs ≈245N ms of
radio for every 500 ms of recording. That is arithmetic, and it predicts the result before
any measurement: sustainable at one hop, no slack at two (490 ms against a 500 ms clock, so
one retransmission starts a queue that never drains), and impossible at three.

| hops | `free` play delay | `halfDuplex` play delay | underruns |
|---|---|---|---|
| 1 | 488 ms | **449 ms** | 0 → 0 |
| 2 | 1.22 s | **54.59 s** | 3 → 29 |
| 3 | 1.17 s | unfinished in 150 s | 2 → 27 |

The 30 s note at three hops on the campus world did not finish inside the probe's 150 s
budget. On the quiet 4-node line the tests use, a 10 s note finishes — **26.8 s after the
user let go**, against 0.76 s under `free`, a 35× difference — and at one hop both models
are identical at 0.20 s. Nothing is lost; every frame arrives. It arrives long after it was
worth hearing, which is a different failure and a worse one for push-to-talk.

### 12.4 The §9 A/B again, on a real radio

Same fixed plan, same three seeds, text metrics snapshotted at the end of the plan in every
arm so a transfer that takes minutes cannot dilute its own damage across a tail where
nothing competes:

| | `free` quiet | `free` + 10 MB | `halfDuplex` quiet | `halfDuplex` + 10 MB |
|---|---|---|---|---|
| delivery ratio | 0.9944 | 0.9944 | **0.9831** | **0.9661** |
| within 5 hops | 0.9944 | 0.9944 | 0.9774 | 0.9605 |
| p95 latency | 4,472 ms | 3,275 ms | 4,669 ms | 9,079 ms |
| relay transmissions | 1,728 | 5,311 | 1,400 | 2,981 |
| retries sent | 11 | 59 | 13 | 309 |
| messages parked | 1.0 | 1.0 | 1.3 | 5.0 |
| queue drops | 0 | 0 | 209 | 2,672 |
| deferred air time | 0 | 0 | 14.8 min | 42.5 min |

Two things to read carefully. Text alone is barely hurt by having a real radio (0.9944 →
0.9831): 250-byte packets are short, and a 20-node campus at one message per two seconds is
nowhere near the air-time budget. **A 10 MB file costs 1.7 points of delivery, 1.7 points of
within-5, and 4.4 s of p95** — so §9's conclusion holds exactly as far as its model does,
and no further.

### 12.5 So is a load gate motivated? Yes, and it costs something

With the transfer allowed to finish, so both sides of the trade are one experiment:

| | delivery | within 5 | p95 | parked | file time | dropped |
|---|---|---|---|---|---|---|
| no file | 0.9831 | 0.9774 | 4,669 ms | 1.3 | — | 209 |
| file, window 4 (ships) | **0.9661** | 0.9605 | 9,079 ms | 5.0 | **2.12 min** | 2,672 |
| file, window 1 | **0.9774** | 0.9774 | 6,123 ms | 3.0 | 3.10 min | 1,810 |

Committing one chunk at a time instead of four recovers most of the lost delivery (0.9661 →
0.9774, against a no-file baseline of 0.9831) and a third of the p95 — and it charges the
sender **46% more transfer time** for it, 2.12 → 3.10 min. That is the whole gate: no load
sensor, no policy engine, one integer, and a trade rather than a free win. Before §12.11's
fix this looked free (3.33 → 3.30 min), which is worth remembering the next time a knob
appears to cost nothing.

The intuitive alternative is still wrong, and more clearly now:

| chunk | delivery | p95 | file time | dropped |
|---|---|---|---|---|
| 64 KB (ships) | 0.9661 | 9,079 ms | **2.12 min** | 2,672 |
| 16 KB | 0.9605 | 7,514 ms | 9.25 min | 2,949 |
| 4 KB | 0.9605 | 7,560 ms | unfinished in 15 min | 2,817 |

Adaptive fragmentation buys p95 and nothing else: 4.4× the transfer time at 16 KB, an
unfinished transfer at 4 KB, and delivery that does not improve. The reason is §2's own
arithmetic — air time is `base + serialization + jitter`, and at 64 KB on Wi-Fi the fixed
part (40 ms hop latency + ~125 ms jitter) is six times the serialization part (26 ms).
Slicing 16× finer barely reduces the air time of a byte and multiplies the fixed cost 16×:
10 MB is 30.6 s of air as 160 chunks and 427 s as 2,560. **Being polite in smaller pieces is
not cheaper; it is much more expensive.** The unit of politeness is how far ahead you commit,
not how big you commit.

### 12.6 The acceptance gates under a real radio

Same 20-node campus, same three seeds, no media:

| gate | `free` | `halfDuplex` | skills/02 and /08 want |
|---|---|---|---|
| delivery ratio | 0.9889 | **0.9444** | ≥ 0.90 ✓ |
| within 5 hops | 0.9889 | 0.9389 | ≥ 0.90 ✓ |
| overhead vs flood-all | 9.3 % | **35.5 %** | ≤ 70 % ✓ |
| SUPER ratio | 21.7 % | 25.0 % | 15–25 % ✓ (at the edge) |

The gates still pass, but the numbers are not the same network: overhead nearly quadruples
because flood-all — which the ratio is measured against — is *also* slowed by the radio, and
MPR's advantage shrinks when air time rather than packet count is the scarce resource. That
is the honest reading, and it is why `halfDuplex` is a flag rather than a default: skills/02
and skills/08 were written against a model with no channel, and changing the shipped model
would silently redefine every acceptance number in the roadmap.

### 12.7 What ships, and what would change it

* `channelAccess: "free"`, `channelQueueDepth: 8`, `channelPriority: "fifo"` and
  `channelCapture: "none"` are in `DEFAULT_CONFIG`, and the shipped combination is inert by
  construction: no counters move, no random draw changes order, golden vectors are
  byte-identical.
* If the team decides the real radio is the model to plan against, the changes with evidence
  behind them are **`transferWindow: 1`** (§12.5) — worth 1.1 points of everybody else's
  delivery and a third of the p95, for 46% more transfer time — and nothing else. The queue
  discipline (§12.8) and carrier sense (§12.10) are both trades or losses.
* Push-to-talk beyond two hops needs a decision, not a parameter: at three hops a streamed
  note cannot keep up with its own capture clock on one radio (§12.3). Either the path is
  capped at two hops for streaming and longer notes are sent as blobs, or voice gets
  priority in the transmit queue — which §12.8 measures, and which does not rescue it.
* The receiver is modelled by `channelCapture`, and it is where most of the contention lives.
  §12.9 gave it two arms — `none`, which takes everything however busy it is, and `first`, which
  locks onto whichever packet arrived first and is the pessimistic bound that produced the
  13.6-point figure every later section quotes. §12.15 added the third, `strongest`, which lets a
  newcomer that is enough stronger take the receiver over. Carrier sense is modelled too (§12.10)
  and is the pessimistic arm on the transmitter side.
* Backpressure is modelled at the sender only (§12.12), where it halves a one-peer
  transfer's drops and its time, and does nothing for a mesh — because the queue that
  overflows in a mesh belongs to a relay.
* Modelled after this list was first written, each with a measurement behind it and neither of
  them a rescue: the capture effect that compares signal strengths rather than arrival order
  (`channelCapture: "strongest"` with `channelCaptureRatioDb`, §12.15 — it moves the loss from the
  newcomer to the incumbent instead of removing it, and one packet is lost either way); and the
  contention window with random backoff (`channelBackoff: "binary"`, §12.13 — queue drops run
  1 994–3 466 against 273–394 receiver collisions, roughly eight packets shed at the buffer for
  every one the window prevents, so the binding loss is buffering and not collision).
* Still unmodelled, with the direction of each error named: RTS/CTS for the hidden terminal
  (optimistic, and a test pins that carrier sense cannot fix it), and backpressure from a *relay's*
  radio up to the layers above it — the half of §12.10's verdict that §12.12 deliberately did not
  build, because a sender can throttle itself and a relay has no way to tell the sender to.

### 12.8 Which packet a busy radio takes next

Once packets wait, the order they wait in is a design decision. `channelPriority` has three
settings: `"fifo"` (arrival order, ships), `"ackFirst"` (acknowledgements jump the queue),
and `"class"` (a WMM-like ranking: an SOS and a voice frame first, then acknowledgements,
then everything else in arrival order — so a text message overtakes the 64 KB chunk queued
ahead of it). Mean of three seeds on the campus world, all under `halfDuplex`:

**Text traffic with a 10 MB file in flight**

| priority | delivery | p95 | file time | queue drops |
|---|---|---|---|---|
| `fifo` | 0.9661 | 9,079 ms | **2.12 min** | 2,672 |
| `ackFirst` | **0.9774** | **8,921 ms** | 2.42 min | 2,769 |
| `class` | 0.9774 | 8,921 ms | 2.42 min | 2,769 |

`class` and `ackFirst` are identical here because nothing but text and chunks is in flight,
so the two settings make the same choice — a useful check that the ranking is doing what the
code says.

**A 30 s note with a 10 MB file in flight**

| priority | note delay after release | underruns | file time |
|---|---|---|---|
| `fifo` | 40.36 s | 25.3 | 2.86 min |
| `ackFirst` | **1.33 min** | 29.0 | 2.64 min |
| `class` | **49.26 s** | **22.7** | **2.47 min** |

**Text with a 30 s note in flight, and an SOS with a file in flight**

| priority | text delivery | SOS mean latency |
|---|---|---|
| `fifo` | **0.9487** | 8.39 s |
| `ackFirst` | 0.9487 | 8.37 s |
| `class` | 0.9316 | 8.32 s |

No ordering is free; each one trades a flow against another, and which trade is right depends
on what the product is doing at the time.

**Promoting acknowledgements** buys text 1.1 points of delivery and 158 ms of p95, and
charges the file 14% for it — every slice an ACK overtakes is a slice the transfer waits
for. The tests pin the mechanism on one radio: with a 2 MB transfer already committed, an ACK
handed to the radio goes on air after 5 chunks instead of 8, and the transfer takes 21.2 s
instead of 13.4 s.

**Promoting voice and SOS on top** is the best arm when a note is competing with a file —
49.26 s of play delay against `ackFirst`'s 1.33 min, and the fastest file of the three,
because bulk chunks are the lowest class of all — and it costs 1.7 points of text delivery
when a note is in flight instead. On one radio the tests pin the same trade: a 5 s note
started while a 2 MB file is committed finishes in 6.1 s under `class` against 13.6 s under
`fifo`.

**Nothing rescues push-to-talk at three hops.** §12.3's limit is the note's own air time —
735 ms of radio per 500 ms of capture — and no queue discipline creates air time. Priority
changes who waits, not how much waiting there is. An SOS is untouched in every arm: four
floods of a 100-byte packet are not what a busy radio is waiting on.

So `"fifo"` ships, and the honest summary is that the queue discipline is a product decision
rather than an optimisation: `ackFirst` for a mesh carrying text while somebody transfers a
file, `class` for a mesh where a note is in flight and the file can wait.

### 12.9 Receiver contention, and why the acceptance gates lose their margin

`channelCapture: "first"` makes the receiver lock onto whichever packet arrived first, and
makes a transmitting node deaf. It is independent of `channelAccess`, which is what makes the
two mechanisms separable:

**60 text messages at 2 s, nothing else** (3 seeds, 20-node campus)

| transmitter | receiver | delivery | within 5 | p95 | retries | parked | captured | deaf |
|---|---|---|---|---|---|---|---|---|
| `free` | `none` | **0.9944** | 0.9944 | 4,472 ms | 11 | 1.0 | 0 | 0 |
| `free` | `first` | 0.9831 | 0.9774 | **7,534 ms** | 32 | 8.7 | 661 | 180 |
| `halfDuplex` | `none` | 0.9831 | 0.9774 | 4,669 ms | 13 | 1.3 | 0 | 0 |
| `halfDuplex` | `first` | 0.9718 | 0.9718 | 13,587 ms | 39 | 13.0 | 253 | 233 |
| `csma` | `none` | 0.9661 | 0.9661 | 11,002 ms | 35 | 5.3 | 0 | 0 |
| `csma` | `first` | 0.9266 | 0.9266 | 13,294 ms | 49 | 8.0 | 231 | **2** |

**The same traffic with a 10 MB file in flight**

| transmitter | receiver | delivery | p95 | retries | parked | captured | deaf | queue drops | file time |
|---|---|---|---|---|---|---|---|---|---|
| `free` | `none` | **0.9944** | 3,275 ms | 59 | 1.0 | 0 | 0 | 0 | 10.71 s |
| `free` | `first` | **0.8588** | 10,314 ms | 379 | 37.3 | 3,625 | 1,256 | 0 | 1.98 min |
| `halfDuplex` | `none` | 0.9661 | 9,079 ms | 309 | 5.0 | 0 | 0 | 2,672 | 2.12 min |
| `halfDuplex` | `first` | 0.9096 | 11,399 ms | 293 | 19.7 | 511 | 693 | 1,441 | 3.28 min |
| `csma` | `none` | 0.9096 | 28,740 ms | 285 | 16.3 | 0 | 0 | 2,488 | 3.80 min |
| `csma` | `first` | 0.8757 | 16,212 ms | 296 | 27.7 | 330 | **7** | 2,995 | 3.64 min |

Four things follow.

**The receiver is where contention lives.** With a file in flight, a transmitter queue alone
costs text 2.8 points of delivery (0.9944 → 0.9661) and receiver collisions alone cost
**13.6** (0.9944 → 0.8588). §9's null result was not wrong about the transmitter; it was
missing the larger half of the mechanism.

**Once collisions exist, the queue earns its keep.** Adding a transmitter queue to a network
that already has collisions is worth **4.9 points** (0.8588 → 0.9096), because serialising a
node's own transmissions removes the overlaps it was causing everybody else. That is the
closest thing to a CSMA result in this repository: the discipline is worth having only once
there is something to collide with.

**Collisions are paid in latency before delivery.** In a quiet mesh, receiver contention
moves p95 by +68% (4,472 → 7,534 ms) to cost 1.1 points of delivery, because a collided
packet is not lost — the sender's ACK timeout re-sends it into an idle radio. The unit tests
pin exactly that: two packets sent to one receiver at the same instant produce one collision
and *two* deliveries.

**Most of the collisions are a node not hearing itself.** With a file in flight under
`halfDuplex` + `first`, 693 losses are deaf-receiver against 511 first-capture. A real
CSMA/CA radio defers rather than transmitting blind, which is §12.10 — and there the deaf
count falls to 7.

**And the acceptance gates lose their margin.** The same 20-node campus, three seeds, gates
measured against a naive flood-all run under the same radio:

| transmitter | receiver | delivery | within 5 | overhead vs flood-all | SUPER ratio | queue drops |
|---|---|---|---|---|---|---|
| `free` | `none` (ships) | 0.9889 | 0.9889 | 9.3 % | 21.7 % | 0 |
| `free` | `first` | **0.9056** | 0.9056 | 15.8 % | 25.0 % | 0 |
| `halfDuplex` | `none` | 0.9444 | 0.9389 | 35.5 % | 25.0 % | 443 |
| `halfDuplex` | `first` | **0.8556** | 0.8500 | 25.5 % | 23.3 % | 180 |
| `csma` | `none` | **0.7944** | 0.7944 | **80.2 %** | 25.0 % | 699 |
| `csma` | `first` | **0.7389** | 0.7389 | **78.0 %** | 23.3 % | 562 |

skills/02 and skills/08 both ask for delivery ≥ 0.90 and overhead ≤ 70%. Only two of these six
radios meet the delivery gate — the shipped one, and `free` + `first` with nothing to spare —
and the two carrier-sense arms fail both gates. So the margin the roadmap's acceptance numbers
were calibrated on was contention that did not exist. One caveat on the overhead column, which
is a metric artefact rather than a routing result: the ratio's denominator is flood-all's
transmissions, and under heavy queue shedding flood-all's packets are dropped at the tail
before they are ever counted, so the denominator shrinks and the ratio rises.
Overhead-vs-flood-all stops meaning what it meant in a model where every attempted
transmission happens.

### 12.10 Carrier sense: the mechanism real radios have, and why it is the pessimistic arm

`channelAccess: "csma"` is `halfDuplex` plus listen-before-talk over peers in range, which is
what BLE and Wi-Fi both do at the link layer. There is no contention window, no random backoff
and no RTS/CTS.

| | quiet mesh | with a 10 MB file | deaf losses | first-capture losses | p95 with the file | queue drops |
|---|---|---|---|---|---|---|
| `halfDuplex` (transmits blind) | 0.9718 | **0.9096** | 693 | 511 | 11,399 ms | 1,441 |
| `csma` (listens first) | **0.9266** | 0.8757 | **7** | 330 | 16,212 ms | 2,995 |

**It does exactly what it was invented to do.** Self-deafness all but disappears — 693 losses
become 7 — and first-capture falls 35%, because a node that can hear the medium does not
transmit into it. The unit test pins the mechanism at its smallest: two nodes sending to each
other at the same instant produce one deaf loss and one retransmission under `halfDuplex`, and
zero of each under `csma`, paid for with 573 ms of waiting. A second test pins what it cannot
do: in a three-node line the two end nodes are 40 m apart and out of each other's range but
both in range of the middle one, and the collision survives `csma` exactly as it survives
`halfDuplex`. That is the hidden terminal, and RTS/CTS is what exists for it.

**And it is still the pessimistic arm.** Under load, listening costs delivery (0.9096 →
0.8757 with a file, 0.9718 → 0.9266 quiet) and p95 grows 42%, because waiting is not free:
deferring holds packets in a bounded queue while the layers above keep generating them, so the
queue overflows harder (1,441 → 2,995 drops). On the gates it is the worst of the six radios
(0.7389-0.7944 delivery, 78-80% overhead).

**Depth is not the fix.** The obvious response to "the queue overflows" is a bigger queue.
Same arms, same file in flight, three seeds:

| transmitter | depth | delivery | p95 | parked | queue drops | deferred air time | file time |
|---|---|---|---|---|---|---|---|
| `halfDuplex` | 8 | **0.9096** | 11,399 ms | 19.7 | 1,441 | 26.1 min | 3.28 min |
| `halfDuplex` | 32 | 0.8588 | 14,432 ms | 27.0 | 1,434 | 78.6 min | 3.87 min |
| `halfDuplex` | 128 | 0.8588 | 19,533 ms | 23.3 | 1,334 | 208.7 min | 8.18 min |
| `csma` | 8 | **0.8757** | 16,212 ms | 27.7 | 2,995 | 67.4 min | 3.64 min |
| `csma` | 32 | 0.7966 | 38,597 ms | 48.7 | 2,969 | 227.4 min | 7.12 min |
| `csma` | 128 | 0.7062 | 55,055 ms | 65.7 | 2,799 | **429.4 min** | 16.96 min |

Monotonic in both arms, and at depth 128 the deferred air time totals seven hours across three
60-node runs — the mesh spends its whole life waiting for a radio horizon that keeps moving.
This is bufferbloat with a discrete-event clock, and it is the same runaway §12.1 hit by
accident, now reachable on purpose through a config knob. Since §12.11 the retry timers start
when a packet goes on air, so what depth buys is no longer duplicate load — it is plain delay,
and plain delay is still worse than a dropped packet, because a dropped packet is retried and a
delayed one is waited for.

**What would change the verdict**, in order of how much it matters here:

1. **Backpressure.** A real stack tells the layer above to stop generating work when the radio
   is saturated. This engine has none — the MPR fan-out, the retry timers and the transfer
   window all keep producing packets regardless of what the queue is doing — which is why
   listening makes the queue worse instead of better. Everything else on this list is a
   refinement; this is the missing half.
2. **A contention window with random backoff**, which is 802.11's answer to two nodes that
   defer for each other. Without it, symmetry is broken only by event ordering.
3. **RTS/CTS**, for the hidden terminal that carrier sense provably cannot fix.

**Verdict:** implemented, measured, not shipped. The number to carry into the platform work is
the pair: carrier sense removes self-deafness completely (693 → 7) and still costs delivery
under load, and the reason it costs is a queueing question that a simulator without
backpressure cannot answer honestly. If the field test shows a real floor behaving like the
loaded arm, the fix is not in the radio model — it is in the layers above it.

### 12.11 The defect the channel model found in the retry timer

Every table above was measured twice, and the difference is a defect in the engine rather than
a modelling choice.

`sendMessage` scheduled the ACK timeout at the moment a message was handed over, and the
retransmission fired from that instant. Under `channelAccess: "free"` the two instants are the
same — a packet goes on air the moment it is handed to the radio — so nothing in §1-§11 was
affected, and the golden vectors do not move. Under a queued radio they are not the same: a
packet can sit in the transmit FIFO for hundreds of milliseconds or, with a file in flight, for
minutes. A timer that starts at hand-over then expires *before the packet has been
transmitted*, retransmits it, and puts a duplicate into the same saturated queue behind the
original. The retry timer measured the queue instead of measuring the silence.

The fix is one rule: **a retry timer measures silence after a transmission, so it starts when
the packet goes on air.** `pendingAcks` records the instant the originator's own copy left, and
the timeout handler reschedules to that instant plus the timeout if the silence has not elapsed
yet. The reschedule is pushed as an absolute deadline rather than `now + remainder`, because
recomputing a remainder accumulates float error and a remainder of 1e-13 ms reschedules the
same event forever — the first version of the fix hung the test suite, which is its own kind of
evidence. A test pins the behaviour: three messages into one radio with a 600 ms timer wait
888 ms between them and produce **zero** retransmissions, while the same burst with a 300 ms
timer — shorter than one round trip on that radio — produces four, so the timer still fires when
there is genuine silence.

What it changed, because the direction matters more than the magnitude:

| claim | before the fix | after |
|---|---|---|
| a 10 MB file costs text (§12.4) | 2.8 points | **1.7 points** |
| window 1 instead of 4 (§12.5) | free: 3.33 → 3.30 min | **costs 46%**: 2.12 → 3.10 min |
| promoting acknowledgements (§12.8) | paid: file 3.33 → 3.15 min | **costs**: file 2.12 → 2.42 min |
| `halfDuplex` gates (§12.6) | 0.9556 delivery, 38.6% overhead | 0.9444, 35.5% |
| `halfDuplex` + `first` gates (§12.9) | 0.9000 delivery | **0.8556** |
| a voice note against a file (§12.8) | 33.3 s play delay | 40.4 s |
| 10 MB at three hops, alone (§12.2) | 3.97 min | 4.44 min |

Two of the day's conclusions reversed: the load gate stopped being free, and promoting
acknowledgements stopped paying for itself. Both had been measured correctly, of the wrong
engine — one whose retry timer was manufacturing the load that made queueing look expensive.
That is the same class of error as §9's confounded A/B, and the same lesson: a measurement is
only as good as the model's bookkeeping, and a model that gains a queue has to re-check
everything that assumed there wasn't one.

### 12.12 Backpressure: the mechanism §12.10 named, and why it is not the fix

`mediaBackpressure` makes a transfer fill only the queue slots its sender's radio actually
has, instead of committing a whole window to a queue that may be four deep. This is the
"missing half" §12.10 asked for — a layer above the radio that stops generating work when the
radio is saturated — in the smallest form that can be built: the sender throttles itself.

**On one radio with nobody else on it, it works exactly as intended.** Two nodes, one hop, a
1 MB file with a window of 8 into a queue 4 deep, so the transfer is committed twice as far
ahead as the radio can hold:

| queue depth | backpressure | queue drops | retransmitted | window stalls | waits on the radio | file time |
|---|---|---|---|---|---|---|
| 4 | off | 25 | 6 | 1 | 0 | 9.37 s |
| 4 | **on** | **5** | **0** | **0** | 4 | **6.04 s** |
| 2 | off | 29 | 7 | 1 | 0 | 6.63 s |
| 2 | **on** | **7** | **0** | **0** | 4 | **4.90 s** |

The file arrives *sooner* with the throttle on, because a chunk that was never dropped never
had to be sent twice and the window never stalled waiting for one. Under
`channelAccess: "free"` the flag is inert by construction — nothing queues, so there is
nothing to throttle — and a test pins both halves.

**This table was measured twice, and the first version of the flag was not backpressure.**
Its window was floored at one, so a throttled sender *still* handed a packet to a queue that
was already full and had it shed at the tail — a slower way of dropping, not a way of not
dropping. Its stall path bypassed the window entirely and re-sent up to a whole window into
the queue that had caused the stall. And nothing resumed a blocked transfer when a slot freed,
so a sender that was correctly refusing itself air waited for a timeout instead of for the
medium. Corrected — the window may reach zero, the stall path consults the same gate and does
not count waiting-on-your-own-radio as a stall, and the channel drain resumes the transfer —
the `on` rows above read 5 drops and **no** retransmissions where they read 3 and 1, at 6.04 s
rather than 5.2 s. The corrected version is 0.8 s slower and removes the retransmission
outright, which is the better trade: `transferBlocks` shows the sender waiting four times
rather than the queue shedding on its behalf. The `off` rows are unchanged to the digit, which
is the check that the correction touched only the throttled path.

**In a mesh it does not help, and slightly hurts.** Three seeds, 20-node campus, 60 messages
at 2 s with a 10 MB file in flight, receiver model on:

| transmitter | backpressure | delivery | p95 | parked | queue drops | waits | file time |
|---|---|---|---|---|---|---|---|
| `halfDuplex` | off | **0.9096** | 11,399 ms | 19.7 | 1,441 | 0 | 3.28 min |
| `halfDuplex` | on | 0.8814 | 13,029 ms | 21.7 | **1,401** | 5 | **3.10 min** |
| `csma` | off | 0.8757 | 16,212 ms | 27.7 | 2,995 | 0 | **3.64 min** |
| `csma` | on | **0.8927** | 28,488 ms | **16.0** | **2,113** | 14 | 4.41 min |

The corrected mechanism cuts drops in both arms (−3 % and −29 %) and cuts parked bundles and
file time under `halfDuplex`. It moves delivery in **opposite directions**: +1.7 points under
carrier sense, −2.8 under plain half-duplex, and neither arm reaches the ≥0.90 gate. Under
`halfDuplex` it buys a faster file with text delivery, which is the wrong way round for an
acceptance box about text; under `csma` it buys delivery with a p95 that nearly doubles and a
file 21 % slower. The `off` rows reproduce the table this section published before the
correction to the digit, so the two mechanisms are being compared on the same runs.

With no media in flight the gates are identical to the digit (0.9718 and 0.9266 delivery),
which is the inertness check: there is nothing to throttle when nobody is transferring.

**The reason this section gave for that verdict was wrong, and §12.14 measures it.** The
argument was topological: in a multi-hop mesh the queue that overflows belongs to a *relay*,
fed by several senders at once, so throttling one source leaves it exactly as full. Attributing
every shed packet to the node that shed it says otherwise — with a file in flight, **82-85 % of
the shedding is the source's own** and only 15-18 % is a relay's. The premise was never
measured, and it is false. Sender-side backpressure reaches the queue that is actually
overflowing; it just does not reach all of it, because a transfer window can only ration the
transfer's share of a radio that the node's own text traffic is also asking for.

**Verdict:** implemented, corrected, off by default, and the recommendation is *wider* than this
section first gave it — but still not a gate rescue. Where sender-side throttling is a strict
improvement is the one-peer case: a file to a neighbour over Wi-Fi Direct, which is exactly
skills/05's "2 phones exchange image <10 MB" acceptance box, and exactly the case where it cuts
drops 80 % and the transfer time 36 % together, with no retransmissions and no stalls at all.
That is worth building. In a mesh it is a trade rather than a win: it helps delivery under
carrier sense and hurts it under plain half-duplex, and the price is latency in both.

What it cannot reach is the part §12.14 isolates: the packets still being shed are the ones a
transfer window has no claim on, offered by a node whose radio is busy for minutes at a time.
The mechanism that would cover them is **hop-by-hop** flow control — a radio that can refuse a
hand-over rather than shed it, and a layer above that holds the packet instead of counting it
lost — which nothing in this stack has, and which DTN's store-carry-forward deliberately avoids,
since a bundle is parked rather than refused. §12.14 also closes the door on the cheap
alternative: rerouting round a congested relay, which needs an equal-cost alternative next hop
to exist, and one exists for 3-9 % of relay sheds.

### 12.13 The contention window: what carrier sense was missing, and why it still is not the fix

§12.10 measured carrier sense and found it made delivery *worse* than not listening, which is
not what listening is supposed to do. The diagnosis it offered was that waiting is not free.
There is a second thing wrong, and it is structural: **the wake-up is synchronous.** Every node
deferring on a busy medium is released at the instant the medium clears, because that instant is
what it was scheduled against. They all find it free together and they all transmit together, so
carrier sense synchronises the herd instead of dispersing it. A contention window is the standard
answer and §12.10 noted this engine did not have one.

`channelBackoff: "binary"` adds it: when the medium is free, draw a slot count uniformly from the
current window and wait it out; after a collision double the window up to `channelCwMax`; after a
clean transmission reset it to `channelCwMin`. It is consulted only under `channelAccess: "csma"`
— a radio with no shared medium has nobody to contend with, and its own FIFO already serialises
it — and it ships as `"none"`, so it consumes no random numbers and nothing above moves.

**The gates, with and without the random wait** (20-node campus, 3 seeds, 60 messages, no media):

| receiver | backoff | delivery | within 5 | overhead | SUPER | queue drops | deferred | draws |
|---|---|---|---|---|---|---|---|---|
| `none` | `none` | 0.7944 | 0.7944 | 80.2% | 25.0% | 699 | 3 042.0 s | 0 |
| `none` | `binary` | 0.7889 | 0.7889 | 76.4% | 25.0% | 825 | 2 963.0 s | 1 058 |
| `first` | `none` | 0.7389 | 0.7389 | 78.0% | 23.3% | 562 | 2 629.6 s | 0 |
| `first` | `binary` | **0.7500** | 0.7500 | 77.3% | 25.0% | 590 | 2 794.6 s | 1 052 |

The mechanism fires — 1 058 draws over the run — and it moves delivery by **+1.1 points with
collisions modelled and −0.6 without**. Neither arm is within 14 points of the ≥0.90 gate. Backoff
does not rescue carrier sense, and it helps only in the arm where there are collisions to prevent,
which is at least the right shape for the mechanism.

**How wide a window** (same world, 10 MB file in flight, collisions modelled, 3 seeds; the
`backoff: none` control from §12.10 is delivery 0.8757, p95 16 212 ms, file 3.64 min):

| `cwMin` | slot | delivery | p95 ms | captured | deaf | drops | deferred | draws | file |
|---|---|---|---|---|---|---|---|---|---|
| 2 | 1 ms | 0.8475 | 14 549 | 356 | 9 | 2 815 | 74.3 m | 2 067 | 4.20 min |
| 2 | 5 ms | **0.9322** | 24 931 | 370 | 7 | 2 762 | 82.0 m | 2 152 | 4.50 min |
| 4 | 1 ms | 0.8305 | 21 400 | 394 | 7 | 3 294 | 82.4 m | 2 147 | 4.21 min |
| 4 | 5 ms | 0.8701 | 25 689 | 380 | 6 | 3 311 | 84.7 m | 2 185 | 4.54 min |
| 16 | 1 ms | 0.8701 | 19 955 | 351 | 10 | 2 444 | 87.8 m | 2 158 | 4.27 min |
| 16 | 5 ms | 0.9096 | 19 696 | 319 | 6 | 2 666 | 82.6 m | 2 023 | 4.69 min |
| 64 | 1 ms | 0.8644 | 17 744 | 380 | 5 | 2 738 | 86.5 m | 2 154 | 5.11 min |
| 64 | 5 ms | 0.8588 | 24 463 | 273 | 6 | 3 466 | 91.1 m | 1 884 | 5.61 min |

Two arms clear the gate, which is more than any other radio lever managed. The sweep is also not
monotonic in either knob: `cwMin` 2 beats 16 at a 5 ms slot and loses to it at a 1 ms slot, and 64
beats 4 at one slot width and loses at the other. A lever whose effect reverses when a neighbouring
setting changes is a lever whose effect may be noise, and §6's faster-beacon idea was exactly that
— +2.6 points on three seeds, −1.1 on six. So the two arms that cleared the gate were re-run on the
acceptance suite's six seeds with every seed printed:

| arm | mean | per-seed delivery | drops | file |
|---|---|---|---|---|
| control (`none`) | 0.8672 | 0.898 0.831 0.898 0.847 0.831 0.898 | 2 215 | 3.77 min |
| `binary` `cwMin` 2, 5 ms | **0.9040** | 0.915 0.932 0.949 **0.847** 0.864 0.915 | 2 108 | 4.07 min |
| `binary` `cwMin` 16, 5 ms | 0.8955 | 0.915 0.847 0.966 0.932 **0.797** 0.915 | 1 994 | 4.37 min |

The mean rises 3.7 points and clears the gate. The spread widens at the same time: `cwMin` 2's
worst seed (0.847) is *below the control's mean*, and `cwMin` 16's worst (0.797) is below the
control's worst. A lever that raises the mean by making good seeds better and bad seeds worse has
not made the network more reliable — it has moved which seeds are unreliable, and an acceptance
gate that has to hold per-run does not get to average over that. It costs 8–16% of file time to
find out.

**The reason it cannot work is in the columns nobody reads first.** Across every arm above, queue
drops run **1 994–3 466** while receiver collisions run **273–394**: roughly eight packets shed at
a full transmit queue for every one lost to a collision. Under carrier sense the dominant loss is
*buffering*, not collision. Listening makes nodes wait; waiting fills an 8-deep transmit queue;
the queue sheds. A contention window makes nodes wait **longer**, so it feeds the mechanism that is
actually losing the packets, and it buys its few points by removing a loss that was never the
binding one. Widening the window from 2 to 64 slots does cut collisions (370 → 273) and cuts
delivery anyway.

That revises §12.10's own diagnosis. It said waiting is not free in an engine with no
backpressure, and reached for a contention window as the thing carrier sense was missing. The
decomposition says the thing missing is flow control: the queue that sheds is the loss, and the
mechanism that would stop it shedding is §12.12's **hop-by-hop** backpressure — a relay that can
tell its upstream to stop — not a wider window in front of it. Backoff is the right answer to a
question this network is not asking.

At three nodes in a triangle, where every pair is inside the line-of-sight budget and there is no
hidden terminal to excuse anything, the same result appears in miniature: the backoff fires (8
draws) and turns 1 250 ms of deferral into 2 054 ms, and the collision count does not move — one
either way, with all three messages arriving either way. `halfDuplex` + `binary` is inert by
construction and asserted so (0.9096 delivery, 0 draws, 3.28 min, identical to `none`).

**Verdict: rejected, and kept as a control.** Ships as `"none"`. It is the first radio lever to
move the carrier-sense arm's mean toward the gate at all, so it is worth recording what it costs
and why it does not hold — but the honest summary is that it optimises collisions in a network
whose losses are queue drops. If a hop-by-hop flow control is ever built, the contention window
should be re-measured against it, because the two address different halves of the same failure and
backoff alone cannot be judged fairly in an engine that sheds.

### 12.14 Who sheds the packets, and what that rules out

§12.12 explained a null result with an argument about topology and §12.13 explained a rejection
with a ratio read off two totals. Both deserve to be measured rather than reasoned, so the engine
now attributes every packet its radios shed: `channelDropsRelayed` counts the ones a node dropped
while forwarding somebody else's message (`hopCount > 0`), so the difference is shed by the node
that originated it; `channelDropsMedia` counts the shed packets that were file or voice chunks;
and `channelDropsWithAlternative` counts the relay sheds for which some peer in range was at least
as close to the destination as the next hop that was chosen — the packets that could have gone
*round* the congestion instead of into it. All three are derived from state the engine already
keeps, consume no random numbers, and leave the golden vectors byte-identical.

Three seeds, 20-node campus, 60 messages, receiver model on:

| transmitter | media in flight | queue drops | shed by a relay | file/voice chunks | alternative next hop existed | file |
|---|---|---|---|---|---|---|
| `halfDuplex` | no | 176 | **80 %** | 0 % | 9 % | — |
| `halfDuplex` | yes | 1,441 | **15 %** | **82 %** | 3 % | 3.28 min |
| `csma` | no | 563 | **83 %** | 0 % | 5 % | — |
| `csma` | yes | 2,995 | **18 %** | **79 %** | 9 % | 3.64 min |

Three things follow, and they point in different directions.

**With no media, the shedding really is a relay's** — 80-83 %, which is what §12.12 assumed. **With
a file in flight it inverts**: 82-85 % of the shed packets are dropped by the node that originated
them, and 79-82 % of what it sheds is transfer chunks. The premise behind rejecting sender-side
backpressure was measured on the wrong arm. A transfer window *is* the thing generating the
pressure, and the source *is* where it lands, which is why correcting that flag moved the mesh
numbers at all (§12.12).

**Congestion-aware forwarding is not on offer.** Rerouting round a saturated relay needs somewhere
to reroute to: a peer in range whose own route to the destination is no longer than the one already
chosen. One existed for **3-9 %** of relay sheds. This topology does not have the path diversity
the mechanism needs, so "prefer a next hop that is not busy" would have almost nothing to prefer —
and the 91-97 % with no alternative would be shed exactly as before. That closes the cheapest of the
hop-by-hop designs without building it.

**What is left after the corrected gate is not the transfer's to give up.** With `mediaBackpressure`
on under `csma`, drops fall 2,995 → 2,113 and delivery rises 0.8757 → 0.8927 — but 70 % of what is
still shed is shed at a source and 66 % of it is still chunks. A window can only ration the
transfer's *share* of a radio; it cannot create slots. The radio is busy for minutes at a time, the
node's own text traffic wants the same slots, and whichever packet arrives when the queue is full is
the one that dies. That is why no arm of this reaches the ≥0.90 gate, and why the remaining mechanism
is not a better policy at the queue but a refusal to accept the hand-over in the first place: a radio
that can say "not now" to the layer above it, and a layer above that holds the packet rather than
counting it lost. Nothing in this stack has that, and it is the one item §12.10, §12.12, §12.13 and
this section all independently arrive at.

### 12.15 The capture effect: does a realistic receiver lose less than a pessimistic one?

§12.9 gave the receiver two models and neither is a real radio. `none` takes everything however busy
it is, which is optimistic. `first` locks onto whichever packet arrived first and never lets a strong
one survive a weak one, which is pessimistic — and it is the arm that produced the 13.6-point figure
every later section quotes. Real receivers do a third thing: they demodulate the stronger signal
*through* the weaker one when the margin is enough, which is the capture effect. `channelCapture:
"strongest"` models it, with `channelCaptureRatioDb` as the margin (6 dB by default, the ratio usually
quoted for an angle-modulated receiver). A newcomer at least that much stronger than the packet the
receiver is holding takes the receiver over, and the incumbent is the packet that is lost.

The question is not whether the mechanism works — it does, and a unit test pins it exactly. Three nodes
in a lopsided line, 10 m and 25 m from a common receiver, 35 m from each other so neither sender hears
the other: twenty contested pairs, weak sender handed to the engine first each time, produce **exactly
twenty takeovers** at a 6 dB margin and **zero** at 12 dB, which the 8 dB of geometry cannot reach. All
forty messages still arrive, because the bookkeeping is per *transmission* rather than per message: the
incumbent that was overtaken is re-sent by its own retry timer and that retry is a fresh attempt. Keyed
by message id instead, an overtaken packet would have its retry dropped on arrival too, and modelling a
collision would have become modelling a blackhole.

The question is whether it recovers the loss. It does not.

**A correction made mid-measurement, because the first answer was an artefact.** The first run of this
section had `csma` + a 10 MB file at **0.9266** over three seeds — clearing the ≥0.90 gate that no other
receiver arm has ever cleared. It was wrong, and the reason is worth more than the number. A transmission
is booked against its link's quality estimate when it goes on air, so under `first` the loser of a
collision is booked as a *failure*. Under `strongest` the loser is the incumbent, which had already been
booked as a success before anything was wrong with it, and the first implementation left that success
standing. So the two arms differed in something other than capture: `strongest` was systematically
optimistic about link quality, and routing believed it. Booking the outcome at arrival instead — which is
when a transmission's fate is actually known, and which is more accurate under every mode — removed the
win outright: 0.8870 on three seeds, and **0.8672 on six, which is `first`'s six-seed mean to four
decimal places.**

Six seeds, 20-node campus, 10 MB in flight:

| transmitter | receiver | delivery mean | worst seed | takeovers | collisions | queue drops | file |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `halfDuplex` | `none` | **0.9689** | 0.9153 | 0 | 0 | 2258 | **1.95 min** |
| `halfDuplex` | `first` | 0.9209 | 0.8475 | 0 | 510 | **984** | 3.13 min |
| `halfDuplex` | `strongest` | 0.8983 | 0.8644 | 90 | 488 | 821 | 3.00 min |
| `csma` | `none` | 0.9181 | 0.8136 | 0 | 0 | 2075 | **3.52 min** |
| `csma` | `first` | 0.8672 | **0.8305** | 0 | 352 | 2215 | **3.77 min** |
| `csma` | `strongest` | 0.8672 | 0.7458 | 58 | 359 | 2075 | 4.41 min |

Under carrier sense the capture effect changes nothing at all: the same delivery to four decimals, a
worse worst seed, and a slower file. Under plain half-duplex it is **2.3 points worse** than the model it
was supposed to improve on. Nothing here reaches the gate, and the only arm that clears it remains the
one with no receiver in it at all.

How much margin the mechanism needs (`csma`, 10 MB in flight, six seeds):

| margin | takeovers | collisions | delivery mean | worst seed | p95 ms | queue drops | file |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 0 dB | **167** | 391 | 0.8757 | 0.7797 | 17859 | **1782** | 4.01 min |
| 3 dB | 100 | 392 | 0.8898 | 0.8305 | 17621 | 1807 | 4.06 min |
| 6 dB | 58 | 359 | 0.8672 | 0.7458 | 18526 | 2075 | 4.41 min |
| 12 dB | 16 | 373 | 0.8616 | 0.7966 | 18432 | 1981 | 4.23 min |
| 20 dB | **2** | 355 | 0.8701 | 0.7966 | 18692 | 2012 | **3.83 min** |

The takeover column is exactly monotone in the margin — 167, 100, 58, 16, 2 — so the knob does precisely
what it says, from loudest-wins at 0 dB to first-packet-wins at 20 dB. The delivery column does not move
with it: a flat, noisy band from 0.8616 to 0.8898 across an eighty-fold change in how often the mechanism
fires. On three seeds this table looked monotone in the *other* direction, improving steadily toward 0 dB
and reaching 0.9209; six seeds flattened it, which is the fourth time in this document that a three-seed
trend has not survived being given more seeds.

Why a takeover buys nothing is worth stating plainly, because it is not obvious. **A takeover is not a
rescue; it moves the loss from the newcomer to the incumbent.** One packet is lost either way, so the
collision count barely changes — and the incumbent's transmitter now has a retry to do, which is more
load on the same radio, in the same direction §12.10 found that retry timers convert queueing into load.
Under half-duplex there is a second effect: the takeover extends the period the receiver is locked, so
more of what arrives next finds it busy or deaf, which is why the `deaf` count rises with the mechanism
on. The one thing that does improve is the queue — drops fall from `first`'s 2215 to 1782–2075 — and
delivery does not follow it, which is the same dissociation §12.13 and §12.14 both ran into: relieving
the buffer is not the same as delivering the packet.

**What this settles.** §12.9's cost for modelling a receiver is *not* an artefact of the pessimistic
first-capture rule. A receiver with a realistic capture effect loses about the same amount, and under
half-duplex loses more. So the bracket `docs/09` §5 asks a field test to locate itself in is narrower on
this axis than §12.9 alone implied: the choice that matters is between modelling a receiver at all
(0.867 under carrier sense) and not modelling one (0.918), not between two receiver models. A field
capture that lands near 0.92 is telling you the radios are not contending; one that lands near 0.87 is
telling you they are, and no assumption about capture ratio will change that reading by more than noise.

Not shipped: `channelCapture` stays `"none"` and `channelCaptureRatioDb` is 6, so nothing above moves and
the golden vectors are byte-identical. `npm run media -- captureEffect` reproduces both tables and
`captureMargin` the sweep.


## 13. Reproducing

```bash
npm run media                                            # TypeScript probe, every table above (§7-§12 for the radio: channel, priority, capture, carrier sense, the contention window, who sheds, the capture effect)
npm run media -- backoff                                 # one section; also `shedding`, `captureEffect`, `captureMargin`. The whole probe is minutes of simulation
dart run bin/mesh_sim.dart --scenario campus_quad --seed 42 --media --no-check
npm test                                                 # 276 TS tests, incl. 18 media cases and the 29-case §12 radio block
cd sim/mesh_sim && dart test                             # 197 Dart cases, incl. 18 media and test/channel_test.dart
```

Engine surface: `sendFile(from, to, bytes, {chunkBytes, window, transport})`,
`sendVoice(from, to, seconds, {stream, transport})`, `serializationMs(bytes, transport)`,
`mediaTimeoutMs(transfer)`, `sim.transfers`, and the config keys `bleKbps`,
`wifiDirectKbps`, `transferChunkBytes`, `transferWindow`, `transferStallMs`,
`mediaAckTimeoutMs`, `adaptiveMediaAck`, `voiceKbps`, `voiceFrameMs`, `jitterBufferMs`,
`voiceTtl`, `maxTransferBytes`, and the five radio keys — `channelAccess`
(`free`/`halfDuplex`/`csma`), `channelQueueDepth`, `channelPriority`, `channelCapture` and
`mediaBackpressure` — every one of which defaults to the behaviour this document was measured
under before §12.

Tests that pin this document's claims, all in `src/__tests__/simulation.test.ts` unless noted:
`media transport (docs/05 §3.2-3.3, roadmap Phase 3)`, `media against skills/05 (Voice PTT &
Media)`, `media under load, measured without confounding the A/B (docs/08 §9)`, `channel access:
one radio, half-duplex (§12)`, `which packet a busy radio takes next (§12.8)`, `receiver
contention: what a busy receiver does (§12.9)`, `carrier sense, and the hidden terminal it
cannot fix (§12.10)`, `a retry timer cannot run out before the packet exists (§12.11)` and
`sender-side backpressure (§12.12)`; `media transport in the UI` and `the radio channel in the
UI` in `src/__tests__/components.test.tsx`; and `test/media_test.dart` plus
`test/channel_test.dart` in the Dart engine, which mirrors every one of the radio cases.
