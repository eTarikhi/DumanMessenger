# Skill 05 — Voice PTT & Media

**Goal:** Walkie-talkie that feels alive, without promising fake cellular quality.

### Audio Pipeline
- Record: Opus 12 kbps, 16 kHz mono, 20 ms frames batched into 500 ms chunks
- Encrypt each chunk with session key (per-chunk nonce)
- Send: `VOICE_CHUNK` packets `prio=high, ttl=3` via best transport (WiFi Direct if GO connected, else chunked BLE 512B MTU)
- Receive: jitter buffer 200 ms → sequential Opus decode → play; reassemble if out-of-order

### Modes
| Scenario | UX | Latency |
|----------|----|---------|
| 1-hop WiFi Direct | Streaming PTT (push-to-talk, release plays) | 150-300 ms |
| Multi-hop (2-5) | Voice note (press → send → peer plays once fully received) | 2-8 s |
| Broadcast channel | Flood voice clip to all listeners | ttl=5 |

### Media Files
- Chunked transfer: 64 KB slices, sliding window ACK, resume on reconnect
- Max 10 MB; WiFi Direct only for >1 MB (auto-reject over BLE-only link with “move closer to SUPER” hint)
- Images: compress to 720p max before send

### Do / Don't
- DO set expectations: label button “Hold to Talk” not “Call”
- DON'T attempt BLE Mesh audio streaming (BLE mesh spec has no media support [1](https://developex.com/blog/limitations-of-ble-in-smart-home/))
- DO fallback gracefully: large file over BLE-only → queue until WiFi available

### Acceptance
- [x] 1-hop WiFi: PTT round-trip <1s, intelligible (MOS proxy test)
- [x] 3-hop BLE: voice note arrives intact, Opus decode clean
- [x] 10 MB image: delivered over WiFi Direct with resume after mid-transfer disconnect

> **Implementation note (Oct 2026 — `sim/mesh_sim` + `src/`, evidence in `docs/08-media-transport-ptt.md` §10):** all three are measured in
> simulation on a 20-node campus, and the latency halves pass with margin: **[1]** a streamed 3 s note
> over a negotiated Wi-Fi Direct link plays **292 ms** after release (92 ms excluding the 200 ms jitter
> buffer, against the modes table's 150-300 ms band); **[2]** at three hops over BLE all 6 frames arrive,
> play delay 1.10 s; **[3]** a 10 MB image with its receiver offline for 20 s at chunk 49 of 160 resumes
> and completes in 45.02 s. The codec halves — "intelligible", "MOS proxy", "Opus decode clean" — are
> **not** simulatable: no encoder runs here, so the proxy reported instead is arrival gaps longer than
> `frame + buffer`, i.e. holes a decoder would have to conceal (0 on the paths above).
>
> Three details from this skill are implemented as written and asserted in both engines: `VOICE_CHUNK`
> at `prio=high, ttl=3` (file slices keep ttl 5), the **512 B BLE MTU** for the no-GO case, and **Max 10
> MB** (an 11 MB send is refused with a log line). The "WiFi Direct if GO connected" rule is a transport
> *override* rather than a size decision, because a 750 B frame is under the BLE ceiling and would
> otherwise never use the faster radio. Two measurements worth feeding back into this skill: streaming
> beats a blob on **first audio** by 31× for a 30 s note (989 ms vs 30.32 s) but *not* on play delay, so
> the modes table's 1-hop-stream / multi-hop-note split is a UX choice rather than a latency necessity;
> and over BLE at the 512 B MTU even 2 MB takes 4.2 min, which makes the ">5 MB auto-reject" threshold
> in docs/05 §3.2 generous by about 5×. Broadcast voice ("flood voice clip to all listeners") is **not**
> implemented — media is 1:1 in both engines and the UI says why.
>
> One caveat applies to every media number above, and it is about the radio rather than the
> protocol: they were measured with `channelAccess: "free"`, a model in which two
> transmissions can occupy the air at once. On the one radio a phone has (`"halfDuplex"`,
> shipped off behind that flag) the sliding window's 15.5× becomes **1.6×**, a 10 MB image at
> three hops takes **4.44 min** instead of 33.00 s, and streamed PTT cannot keep up with its
> own capture clock beyond two hops — one 500 ms frame needs ≈245 ms of air per hop, so three
> hops need 735 ms per 500 ms recorded and a 10 s note finishes 26.8 s after the user let go.
> Window 1 instead of 4 recovers 1.1 of the 1.7 points of text delivery a transfer costs, and a
> third of the p95, for 46% more transfer time; slicing chunks smaller buys no delivery at all
> and costs 4.4x the transfer time, because the fixed part of air time (hop latency plus
> jitter) is six times the serialization part at 64 KB. `docs/08-media-transport-ptt.md` §12.
>
> One narrow exception to all of the above is a win rather than a trade, and it is this skill's
> own acceptance box: for a transfer between two devices with nothing else on the radio — "2
> phones exchange image <10 MB over WiFi Direct mesh" — letting the sender fill only the queue
> slots its radio has (`mediaBackpressure`) cuts a 1 MB transfer's dropped chunks from 25 to 5,
> its retransmissions from 6 to **0** and its window stalls from 1 to 0, and the file arrives in
> **6.04 s instead of 9.37 s**, because a chunk that was never dropped never had to be sent twice.
> For this to work the window has to be allowed to close completely: floored at one slot the sender
> still hands a packet to a full queue and has it shed at the tail, which is not backpressure but a
> slower way of dropping, and it leaves a retransmission behind. In a mesh the same flag is a trade
> rather than a win — it buys 1.7 points of delivery under carrier sense and loses 2.8 under plain
> half-duplex, because a transfer window can ration a transfer's *share* of a radio but cannot create
> slots (`docs/08` §12.12, and §12.14 for who is actually shedding).

