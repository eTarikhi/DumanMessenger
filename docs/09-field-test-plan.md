# 09 — Field test 1: instrumentation, protocol, and what the simulator predicts

> Roadmap Phase 2 asks for *"Field test 1: campus quad / office floor mapping: atrium
> should become SUPER, packet delivery ratio vs flood-all baseline"*. It is the one
> acceptance item in this repository that cannot be closed by simulation, because its
> subject is a building.
>
> What **can** be done without hardware is everything except the walk: the capture
> schema, the analyzer that turns a capture into the roadmap's numbers, and the
> predictions the walk is meant to falsify. All three are implemented and tested here —
> `npm run field:capture` writes a capture from a simulated run, and
> `npm run field:report` reads it back, so the analysis pipeline is debugged against a
> log whose ground truth is known instead of being written on the day against one whose
> ground truth is not.
>
> Evidence for the predictions: `docs/06-simulator-findings.md` §1-§17. Criteria:
> `skills/02`, `skills/07`, `skills/08`, `roadmap/roadmap.md` Phase 2.

---

## 1. What the walk is for

Three numbers, in order of importance:

1. **Delivery ratio against a flood-all baseline.** Not "does it work" but "does MPR
   flood suppression buy what the simulator says it buys on this floor plan". Criterion:
   overhead ≤70% of flood-all at equal-or-better delivery (`skills/02`), ↓30% (`skills/08`).
2. **The SUPER ratio the election actually settles on**, and whether the node in the
   atrium is one of them. Criterion: 15-25% (`skills/02`), no flapping.
3. **Battery %/h per role with the duty cycle on.** Criterion: NORMAL <15% per 8 h
   (`skills/07`), i.e. <1.875%/h.

Everything else in the report exists to explain those three: hop distribution and
latency percentiles say *how* delivery happened, loss and duplicate counts say what the
radio did, and the RF calibration fit says whether the simulator's radio model is the one
this building has.

---

## 2. Equipment and roles

| | |
|---|---|
| 10-15 Android handsets | `skills/08` specifies a 10-200 node range; 10 is the minimum that can show a ratio, 15 gives the 20-node campus an analogue |
| 1 laptop | runs the analyzer, holds the floor plan, is the clock reference |
| Floor plan with measured distances | the calibration walk is worthless without them |
| Tape/laser measure, chalk | placement and wall counting |
| 1 charger | the `chargingRatio` arm: a charging node must not be elected SUPER |

Roles on the day:

* **Two walkers** — the calibration pair. One holds the reference phone, one walks the
  distances and counts walls between them.
* **One static "atrium" phone** — placed in the most open spot on the floor (the roadmap
  predicts this one becomes SUPER).
* **The rest scattered** in three clusters, mirroring `campusQuad`'s spawn clusters, with
  ~half of them stationary and ~half walking a slow loop (the simulator's
  `stationaryRatio 0.5`).
* **One operator** who does not move, runs the traffic script and watches the capture grow.

---

## 3. Procedure

### 3.1 Calibration walk (do this first, and do not skip it)

Readings of RSSI against measured distance, at **0, 1 and 2 interior walls**, at 2, 5,
10, 20 and 30 m. Each reading is one `calibration` record (§4). Twenty readings is the
minimum the fit will accept; the simulator's own run produces ~780.

The report fits `rssi = txPower − 10·n·log₁₀(d) − walls·penalty` for all three
unknowns, and the decision rule is:

* **slope n ≈ 2 (18-25 dB/decade) and RMS residual < 6 dB** → the simulator's radio model
  is this building's radio model; its predictions can be compared directly.
* **slope well off 2, or RMS ≥ 6 dB** → recalibrate before believing anything else. A
  concrete case: an open-plan floor with a metal ceiling will read n < 2 at long range and
  the delivery predictions will be optimistic, because the simulator will think nodes hear
  each other from further away than they do.
* **no through-wall readings** → the fit falls back to two parameters and reports the wall
  penalty as unknown. That is why the walk asks for walls explicitly.

### 3.2 Placement and traffic

Place the phones, let the mesh settle for 90 s (the simulator's `warmupMs`, and the time
the election and OGM tables need), then send **150 messages at 1 s intervals** between
random pairs — the same volume the acceptance runs use (`skills/08`'s 20-node seed run),
so the simulator's numbers and the field numbers have the same denominator.

### 3.3 The A/B, and why it has to be the same traffic

Run the whole thing **twice**: once under the shipping relay policy (MPR suppression), and
once with suppression off so every node relays everything (`--policy flood-all` in the
simulator, a debug switch in the app). Use the **same message plan** — same pairs, same
order, same timings — because a flood-all arm that happens to send easier traffic will
flatter the shipping policy. The simulator learned this the hard way: an early A/B that
drew fresh random traffic per arm produced an overhead ratio that moved with the seed
rather than with the policy (`docs/06` §6).

### 3.4 Duty-cycle arm (battery)

A separate, longer run with the duty cycle **on** (NORMAL scans 3 s and sleeps 7 s, SUPER
continuous, per `skills/07`). Eight hours is the criterion's window; one hour with the
`awake` samples in the capture is enough to extrapolate, and the report says which it got.

**Do not gate the battery criterion on an always-on run.** An always-scanning NORMAL node
in a mobile population measures 18-25% per 8 h in simulation (`docs/06` §7) — the sleep
slot is load-bearing for that criterion, not a refinement — and the analyzer marks the row
"not gated: duty cycle off" rather than failing a run for being what it says it is.

### 3.5 Report

```bash
npm run field:report -- /sdcard/duman/mpr-run.jsonl /sdcard/duman/flood-all-run.jsonl
```

---

## 4. The capture schema

One JSON object per line (JSONL), appended as events happen, rotated to disk — **never
ring-buffered in memory**, which is the one way a capture silently loses its own
denominator. `v` is the schema version.

```jsonc
{"v":1,"kind":"meta","atMs":0,"device":"operator","scenario":"office-floor-2",
 "nodes":15,"policy":"mpr","dutyCycle":false,"engine":"android-1.4.0",
 "note":"atrium phone is device-07"}

// One radio transmission. hop 0 is the originator's own; hop > 0 is a relay.
{"v":1,"kind":"tx","atMs":18342.5,"device":"device-03","peerId":"device-07",
 "msgId":"m112","msgType":"text","hop":1,"rssi":-71.4,"detail":"mpr relay"}

// A copy handed to the application. One per recipient, so a broadcast has many.
{"v":1,"kind":"deliver","atMs":18510.0,"device":"device-07","peerId":"device-03",
 "msgId":"m112","msgType":"text","hop":1,"rssi":-71.4,"detail":"1 hop, 167 ms"}

{"v":1,"kind":"loss","atMs":18400.1,"device":"device-03","peerId":"device-11","msgId":"m112","rssi":-88.2}
{"v":1,"kind":"duplicate","atMs":18455.7,"device":"device-11","msgId":"m112","hop":2}
{"v":1,"kind":"decision","atMs":18402.0,"device":"device-11","msgId":"m112","detail":"suppressed: MPR set does not include me"}
{"v":1,"kind":"queue","atMs":19002.0,"device":"device-11","msgId":"m113","detail":"retries exhausted — carrying until a peer appears"}
{"v":1,"kind":"election","atMs":30000.0,"device":"device-07","detail":"NORMAL → SUPER — coverage 0.71, top 20%"}

// Periodic, every 30 s per device. This is the role timeline and the battery series.
{"v":1,"kind":"sample","atMs":30000,"device":"device-07","role":"SUPER","battery":0.8123,
 "charging":false,"online":true,"awake":true,"peers":6,"txCount":214}

// One reading of the calibration walk.
{"v":1,"kind":"calibration","atMs":1200,"device":"device-01","peerId":"device-02",
 "rssi":-73.5,"distanceM":10.0,"walls":1}
```

Field rules that matter to the analyzer:

* `device` ids must be **stable for the whole capture** — the role timeline and the
  battery series are per device.
* `msgId` must be **globally unique per message**, not per device, or delivery counting
  merges two messages into one.
* `hop` on a `deliver` record is the number of radio hops the copy took; the analyzer adds
  one for the final link, matching the engines' convention.
* `atMs` must come from one clock. If devices cannot share one, record a `meta` line per
  device with its offset and normalize before analysis.
* `msgType` values the analyzer skips for traffic metrics: `ack`, `ogm`, `sync`. They are
  control plane, and counting them would make the delivery ratio a statement about
  beacons.

`npm run field:capture -- <scenario> <seed> <out.jsonl> [policy]` produces exactly this
schema from a simulated run, including the `sample` and `calibration` records, so a new
app build's logger can be checked against a reference file before anybody travels.

---

## 5. What the simulator predicts

`campus_quad`, seed 42, 20 nodes, 100×100 m, 150 messages, from `docs/06`:

| criterion | prediction | source | if the field disagrees |
|---|---|---|---|
| delivery ratio | **99.7%** (97.3-100% over six seeds) | §6 | below 90% → look at the loss records first: the model's margin-based loss is the most likely thing to be wrong |
| overhead vs flood-all | **9.3%** of naive flood's relays (7-9% over six seeds); flood-all reaches 100% for 7-9× the transmissions | §6 | above 70% → suppression is not firing; check `decision` records for the MPR reason |
| within 5 hops | 99.7% of sent | §6 | — |
| SUPER ratio | **20-25%** of nodes, 0.06-0.22 role changes per node per minute | §5 | outside 15-25% → the coverage weights need this building's numbers |
| atrium node | SUPER within **2 election cycles** (60 s) **if it is also healthy** — full battery, long uptime, low packet loss. Verified in all four simulated worlds | §18.1 | it does not → read its battery and uptime before reading its position: a drained phone at 199 peers (0.688) still loses to a healthy one at nine (0.708), because the peer term saturates logarithmically (§18) |
| atrium node, drained | **NORMAL**, in three of four worlds — health carries 0.45 of the score and position only 0.55 of a compressed term | §18 | if a drained atrium phone *is* elected, something is inflating the position terms: check the RSSI normalization against the calibration fit |
| atrium node, **as spawned** | **NORMAL** in three of four worlds, and not because of its score: it clears the 0.60 promote gate on the campus world and still loses on **rank** — 7th of the 13 candidates it can hear, where the top-20% cap is 3 | §18.4 | record the *rank among heard candidates* next to the score. Normalising openness against the observed maximum was built for exactly this case and changes nothing: the score rises 0.05-0.19 and the rank does not move at all, because every open neighbour gains the same way |
| delivery, with a receiver in the model | **0.9056** with collisions and no transmit queue, **0.8556** with both — against 0.9889 in the shipped model | `docs/08` §12.9 | the shipped model has no contention at all, so the real number is below every row above. This is the criterion with no margin left: measure it first, on the first walk, before tuning anything else |
| delivery, with carrier sense as well | **0.7944** listening with no collisions modelled, **0.7389** with both; overhead 80.2% and 78.0% of flood-all | `docs/08` §12.10 | if the floor delivers nine in ten, the real radios are behaving like the §12.9 arms and *not* like the carrier-sense arm — which is the useful inference, because that arm is what a simulator with no backpressure produces when it is told to listen. A real stack defers *and* stops generating work; this engine only defers |
| media on a real radio (`channelAccess: "halfDuplex"`) | 10 MB at 3 hops in **3.97 min** instead of 33.0 s; a 10 s streamed note at 3 hops finishes **17.8 s after release** instead of 757 ms; text delivery with a file in flight 0.955 instead of 0.994 | `docs/08` §12 | the shipped model is `free`, so the field numbers will sit between the two rows above; which side they fall on is the single most useful thing a media field test can report |
| latency | p50 ~0.3 s, p95 ~1.3-4.8 s (traffic-dependent); 1 hop ≈ 0.16-0.5 s | §4, §8 | p95 over 5 s at 3 hops → the retry timer, not the routing |
| NORMAL battery, duty cycle on | **10.0%/8 h** campus, 10.9% crowd, 7.1% stationary | §7 | over 15% → the scan window is not being honoured by the OS |
| NORMAL battery, always on | 19.4%/8 h campus, 22.5% crowd — **fails the criterion by design** | §7 | this is the prediction, not a surprise |
| 60-node crowd analogue | 91.3-95.3% delivery at 12-14% of naive flood | §6, §16 | — |
| media: 10 MB image, 3 hops | 33.0 s over Wi-Fi Direct; **unfinished in 15 min** over BLE at a 512 B MTU | `docs/08` §2-§3 | Wi-Fi Direct GO formation is modelled as a setup latency, so expect the real number to carry 1-3 s the simulator does not |
| media: PTT play delay | 407 ms at 1 hop, 1.10 s at 3 hops, streamed | `docs/08` §5 | — |
| group history repair | 20/20 recovered, converged in 8.8 s when the membership can hear itself; **never converges** when it cannot | §17 | a spread membership that does not converge is the prediction, not a failure |

---

## 6. Where the real building will diverge

Listed so a disagreement is diagnosed rather than argued about:

* **Channel access and receiver contention are flags, and both ship off.** The default (`channelAccess: "free"`) has
  no CSMA, no collisions and no shared medium: two transmissions at once both succeed. A
  2.4 GHz floor with 15 phones and a dozen access points will not behave like that, and the
  direction is known — real delivery will be *lower* and real overhead *higher*, because a
  suppressed relay is free in the model and a collided one costs a retry. `"halfDuplex"`
  supplies the missing mechanism (one transmitter, a bounded queue, drop-tail) and predicts
  overhead 35.5% against 9.3%, and delivery 0.944 against 0.989 on the same campus world
  (`docs/08` §12.6); it still omits receiver capture and collisions, both optimistic. The
  field test should report which of the two it lands nearer, per criterion, because that
  decides whether the acceptance gates in `skills/02` and `skills/08` are calibrated against
  a radio anybody carries. `channelCapture: "first"` adds the receiver half — a busy receiver
  loses the second of two packets, a transmitting node hears nothing — and that is the larger
  mechanism: 13.6 points of delivery against a transmit queue's 2.8 with a 10 MB file in
  flight, and once collisions exist the queue is worth 4.9 points back. With both on, the campus
  measures **0.8556** against skills/02's and skills/08's ≥90% (`docs/08` §12.9), so the
  prediction to test first is not overhead or battery but whether a real floor delivers nine
  messages in ten.
* **Carrier sense is modelled, and it is the pessimistic arm.** `channelAccess: "csma"` adds
  what BLE and Wi-Fi both do at the link layer — listen, and wait if a peer within range is
  transmitting — with no contention window, no random backoff and no RTS/CTS. It removes almost
  every collision a node can hear (self-deafness 808 → 8 with a file in flight) and still
  measures **worse** than transmitting blind under load: delivery 0.7389-0.7944, overhead
  78-80% of flood-all, p95 up 42%. The reason is that waiting is not free in an engine whose
  layers above keep generating packets while the queue fills, and whose retry timers (4 s for
  text, 600 ms for media) retransmit anything that waits longer than they do. A real stack
  defers *and* applies backpressure; this one only defers. So the field result to compare
  against is a range: near the `free`+`none` end means contention is not binding in practice,
  and near the `csma` end means the radios are deferring into a saturated queue and the fix
  belongs above the radio (`docs/08` §12.10).
* **Wi-Fi Direct formation** is a setup latency in the model, not a negotiation that can
  fail, time out, or be refused by a phone in a pocket.
* **Human bodies are walls.** The model's obstacles are static rectangles; a crowd of
  people is a time-varying attenuator the calibration walk cannot capture.
* **BLE scanning is not continuous discovery.** `skills/07`'s duty cycle is modelled as a
  window; Android's scan throttling and iOS's background limits are not, and both are
  harsher than a 3 s/7 s window.
* **Battery chemistry and screen state** dominate real drain; the model's per-role drain
  rates are radio-only.
* **Clock skew** between devices, which is why §4 asks for one clock or a recorded offset.

---

## 7. Validating the analyzer against known ground truth

`npm run field:capture -- campus_quad 42 /tmp/cap.jsonl` and the same with `flood-all`,
then `npm run field:report -- /tmp/cap.jsonl /tmp/base.jsonl`:

| report line | analyzer, from the log | engine, from its own state |
|---|---|---|
| messages sent / delivered | 150 / 148 | 120 unicast sent, deliveryRatio 0.9833 |
| delivery ratio | 0.9867 | 0.9833 |
| relay transmissions | 3,131 | `totalForwarded` 5,078 |
| overhead vs flood-all | **14.8%** | ~9.3% (§6) |
| SUPER ratio (sampled) | 23.0% | 25.0% instantaneous |
| role changes / node / min | 0.025 | 0.06-0.22 (§5) |
| txPower at 1 m | **−55.0 dBm** | −55 dBm |
| path-loss slope | **20.0 dB/decade** | 20 dB (n = 2) |
| fit RMS residual | **0.00 dB** | exact by construction |
| implied LOS range | **31.6 m** | 31.6 m |

The RF fit recovering the model's own parameters to three significant figures from 776
synthetic readings is the check that the least-squares code is right; on real readings it
is the check that the building is.

The two ratios that differ are **definitional, not bugs**, and the difference is the point
of writing them down:

* The engine's `deliveryRatio` counts only 1:1 unicasts (group traffic has its own
  denominator, media chunks and sync packets are excluded — §14, §17, `docs/08` §3.1). The
  log-derived ratio counts every non-control message that was put on air, including
  broadcasts, so its denominator is larger and its value slightly different.
* The engine's `totalForwarded` counts every relayed transmission including OGM relays;
  the log-derived relay count excludes `ogm`, `ack` and `sync` records. The overhead ratio
  is therefore *conservative* in the log-derived form (14.8% rather than 9.3%) — it
  compares data relays to data relays. Both are far inside the ≤70% criterion, but a field
  report must say which one it is quoting.

On the day, quote the log-derived numbers, because they are the ones a phone can produce.

---

## 8. Reproducing

```bash
npm run field:capture -- campus_quad 42 /tmp/cap.jsonl              # shipping policy
npm run field:capture -- campus_quad 42 /tmp/base.jsonl flood-all   # the A/B baseline
npm run field:report  -- /tmp/cap.jsonl /tmp/base.jsonl             # the report above
dart run bin/mesh_sim.dart --scenario campus_quad --seed 42 --policy flood-all --json
```

The analyzer is one file, `tool/field-report.ts`, with no dependencies beyond Node's
`fs`: it can be copied onto the laptop that goes to the building.
