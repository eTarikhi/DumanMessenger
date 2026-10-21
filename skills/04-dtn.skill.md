# Skill 04 — Store-Carry-Forward (DTN) Layer

**Goal:** Survive partitions — deliver when path reappears, not only when connected now.

### Queue
```dart
class OppMessage {
  MsgId id; NodeId dest; Uint8List encrypted; int ttlDays; int copyCount; DateTime created;
}
OppQueue {max=500, expiry=7days}
```

### Rules
- If `nextHop(dest) == unknown` and msg is unicast DM (not broadcast), enqueue.
- On `peerDiscovered`:
  - if peer == dest OR peer.knowsRouteTo(dest): forward 1 copy (spray limit 3) [1](https://link.springer.com/article/10.1007/s11277-016-3323-8)
  - increment copyCount; lower priority after 3 (**keep** the bundle — dropping it at the limit loses the copy that could still be handed to the destination; `docs/03` §8)
- On `ackReceived` from dest: remove + gossip ACK (so relays can prune)
- Periodic sweeper: drop expired; keep newest 500 (LRU by priority)

### Transport agnostic
- DTN sits above MeshTransport; unaware if BLE or WiFi carried it.

### Do / Don't
- DO bound memory strictly; DTN is not infinite storage
- DO prefer SUPER as bundle carrier (more storage/battery)
- DON'T flood DTN queue on every scan — spray limited copies only

### Acceptance
- [ ] A→C: A enqueues for C (C offline); B meets A then later C → C receives (carry test)
- [ ] Spray limit: same msg not duplicated >3× in network capture
- [ ] Expiry: 7-day old queued msg dropped after offline week

