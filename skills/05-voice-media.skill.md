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
- [ ] 1-hop WiFi: PTT round-trip <1s, intelligible (MOS proxy test)
- [ ] 3-hop BLE: voice note arrives intact, Opus decode clean
- [ ] 10 MB image: delivered over WiFi Direct with resume after mid-transfer disconnect

