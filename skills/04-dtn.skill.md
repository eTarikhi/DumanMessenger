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
- [x] A→C: A enqueues for C (C offline); B meets A then later C → C receives (carry test)
- [x] Spray limit: same msg not duplicated >3× in network capture
- [x] Expiry: 7-day old queued msg dropped after offline week

> **Implementation note (Oct 2026 — `sim/mesh_sim` + `src/`, evidence in `docs/06-simulator-findings.md` §20):** all three are implemented and
> asserted in both engines, and the first one **did not pass until two defects were fixed**. (a) Sprayed
> copies were numbered from `attempt` 1, which the source retries had already used, so every relay that had
> heard the retries deduped the first two copies on `id#attempt` and the whole spray budget was spent on
> copies nobody forwarded. (b) A carried bundle whose destination had no reachable route fell through to the
> flood branch, where a NORMAL node **MPR-suppressed it** — suppression exists to delete duplicate copies of
> a flood, and a bundle with nowhere to go is not a duplicate. Carried messages are now parked, never flooded
> and never suppressed. Together the two fixes took the 60-node crowd's delivery from **0.867 to 0.947** over
> six seeds, with five messages in a hundred arriving by store-carry-forward that previously did not arrive
> at all; the two partitioned worlds do not move, because carrying cannot substitute for topology. The
> expiry box is verified on the sweeper's boundary rather than by running seven days of simulated time
> (2.4 M physics ticks), and that is stated rather than hidden.
>
> Two of this skill's rules did not survive measurement. **"DO prefer SUPER as bundle carrier"** is
> implemented (`dtnPreferSuper`) and **off by default**: it measured +4.5 delivery points *before* the two
> fixes above and **−3.5 points after them**, because spraying toward SUPERs duplicates work into the
> busiest nodes' queues. The intuition is about who should *hold* a bundle, not who should be handed extra
> copies — if the product wants community relays carrying bundles, the lever is a storage/battery-aware
> eviction preference. And **"gossip ACK (so relays can prune)"** is implemented exactly as written — the
> bundle is acknowledged to the carrier that handed it over, and any node that hears the ACK drops its copy —
> and it pruned **zero** bundles in six seeds across four worlds, because the ACK is a unicast along the
> reverse path and the other holders are not on it. The cap never binds in any world measured (97 of 500 at
> worst), so the recommendation is to keep the free unicast prune and not add a prune flood until a
> deployment shows cap pressure. "Keep newest 500 (LRU by priority)" now ranks priority before age; it used
> to evict the oldest bundle whatever its priority, which could throw away a fresh one to keep a sprayed-out
> one.

