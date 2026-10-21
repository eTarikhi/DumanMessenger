# 03 — Duman Adaptive Routing: Smart Router Algorithm
## Coverage-Based Super-Node Election & Mesh Routing

---

### 1. Goal

> Select a small set of **Super-Nodes** that maximize coverage and minimize redundant relays, extending the local network without flooding the spectrum.

Classic flood-everywhere causes broadcast storms. OLSR solved it with **MPRs** (each node picks minimal relays covering 2-hop neighbors) [1](https://www.mdpi.com/2079-9292/14/5/872). BATMAN solved it with **best-next-hop only** (no global topology) [2](https://ar5iv.labs.arxiv.org/html/1804.02139). Duman merges both, tuned for phones.

---

### 2. Intuition

In a crowd:
- Person on a **hill / balcony / center of quad** sees 15 peers with good RSSI and has 80% battery and hasn’t moved → **excellent router**.
- Person walking on edge with 8% battery, 2 peers, weak signal → **bad router**, should save power.

The algorithm lets devices **self-score** and **self-promote** without central coordinator.

---

### 3. Coverage Score (computed locally every 30s)

```
Let:
  N      = peerCount (discovered unique peers last 60s, max 50)
  R      = avgRSSI normalized: map -100..-30 dBm → 0..1
  B      = batteryLevel 0..1 (0.15 minimum to be eligible)
  S      = stability = min(uptimeMinutes/60, 1) * (1 - mobility)
  M      = mobility = avg accelerometer variance last 60s, 0 stationary ..1 sprinting
  Q      = linkQuality = packetDeliveryRatio last 20 msgs (0..1)

coverageScore = 0.30*norm(N) + 0.25*R + 0.20*B + 0.15*S + 0.10*Q

norm(N) = log(1+N) / log(1+50)   // diminishing returns after ~20 peers
```

**Eligibility gate to be Super:**
- B ≥ 0.25 (≥25%)
- Not in battery saver
- Has had ≥3 peers in last 2 minutes (isolated nodes don’t need to route)
- Charging → +0.1 bonus (encourages plugged phones at events)

**Hysteresis (prevents flapping):**
- Promote to SUPER if `score > 0.60` AND rank in top 20% of known 2-hop neighborhood.
- Demote if `score < 0.50` for 2 consecutive cycles.

---

### 4. Distributed Ranking Without Leader

No election; just gossip:

1. Each node’s OGM (2s beacon) carries: `{nodeId, seq, score, isSuper, peerCount, batteryBucket}`
2. Each node maintains table `neighborScores[nodeId] = score` (expires after 30s no OGM → remove).
3. To rank itself, node looks at `self + 1-hop neighbors` scores it has heard. If in top 20% → promotes. This is **2-hop-local**, not global — scales.
4. SUPER flag is **advisory**, not command. Peers that see SUPER prefer it as next hop but can still use NORMAL if SUPER congested.

**Why this works:** Inspired by OLSR MPR coverage + BATMAN OGM ranking; no Dijkstra on phones, just local sort (O(k log k), k ≤ 30).

---

### 5. Routing Behavior by Role

| Role | Scan | WiFi Direct GO? | Relay Policy | Power |
|------|------|------------------|--------------|-------|
| **SUPER** | Continuous BLE scan + advertise 100 ms interval | **Yes** if ≥4 peers & no GO nearby → create group, SSID `Duman-XXXX` | Relay **all** flood msgs + store-forward queue eagerly | High (warn user, offer opt-out) |
| **NORMAL** | Duty-cycled: scan 3s / sleep 7s, advertise 500 ms | No — join nearest SUPER’s GO if invited | Relay only if no SUPER covered the msg (MPR fallback) | Low |

**SUPER creation guard:** At most 1 SUPER per ~30m radius. If node sees another SUPER with score within 0.1 and RSSI > -60 (very close), lower scorer backs off for 60s → avoids 5 SUPERs in one classroom all being GO.

---

### 6. Message Forwarding Rules (Data Plane)

```
On receive msg:
  if msgId in seenCache: drop (dedup, 5-min LRU ~5000 entries)
  add msgId to seenCache
  if msg.dest == self: deliver to inbox, send ACK via reverse path
  else if msg.ttl <=0: drop
  else {
    msg.ttl--
    msg.hopCount++
    if self.isSuper:
       forward immediately via best transport (WiFi if large, BLE if small)
    else {
       // NORMAL: only forward if no SUPER ack heard within 300 ms (MPR optimization)
       wait 300 ms; if no retransmit from SUPER heard: forward
    }
    // Store-and-forward: if destination unknown and msg is DM (not broadcast), enqueue OppQueue
  }
```

- **Broadcast (pager):** ttl=5, no ACK, flood via SUPERs.
- **Unicast DM:** try routed flood; if dest known via nextHop table, unicast via that hop; else opportunistic flood.
- **Group DM:** CRDT merge → no routing; just anti-entropy gossip whenever peers meet (Meshenger model [3](https://github.com/ebregger/Meshenger)).

---

### 7. Next-Hop Table (BATMAN-lite, memory-light)

Per originator, store only:
```
nextHop[originatorId] = { bestNeighborId, tq, lastSeq, hopCount }
tq (transmit quality) = (OGMs received via that neighbor / OGMs expected) over window 32
```
- Update on each OGM: if seq newer → update; compute tq via sliding window.
- Forward unicast to originator via `bestNeighborId` if tq > 0.6; else flood.
- **No full graph** — O(n) memory, n = nodes known (capped 200).

---

### 8. Store-Carry-Forward (DTN Layer)

For sparse networks (village, trail):

```
OppQueue: holds DMs where no route known, max 7 days, max 500 msgs.
On peer discovered:
  for each msg in OppQueue:
    if peer == msg.dest or peer.nextHopToDestKnown:
       forward to peer (spray 3 copies max, spray-and-wait [4](https://link.springer.com/article/10.1007/s11277-016-3323-8))
       increment copyCount; if copyCount == 3: keep but lower priority
On peer lost:
  keep queued; no deletion.
Expiry: TTL days or ACK received.
```

This hybrid MANET-DTN (OLSR-OPP / SF-BATMAN [5](https://journals.indexcopernicus.com/api/file/viewByFileId/71428)) improves delivery ~20% in intermittent connectivity.

---

### 9. Walkie-Talkie on This Fabric

- **PTT Opus frame path:** Sender SUPERs prioritize voice frames (higher queue). Each frame `type=VOICE_CHUNK, ttl=3, priority=high`.
- **Jitter:** Receiver plays after 200 ms buffer; if hop>2, switch UX to “Voice Note” (play after full clip assembled) rather than fake real-time.
- **Push-to-Talk channel:** Group broadcast voice = flood, ttl=5, no ACK. All listeners in range get it like a walkie channel.

---

### 10. Pseudocode (Dart-like)

```dart
class SuperElection {
  double computeScore(Node self, List<Peer> peers) {
    final n = log(1 + peers.length) / log(51);
    final r = peers.map((p)=> (p.rssi+100)/70).clamp(0,1).average();
    final b = battery.level;
    final s = (self.uptimeMin/60).clamp(0,1) * (1 - motion.variance60s);
    final q = pdrWindow.ratio; // packet delivery
    if (b < 0.25) return 0;
    return 0.30*n + 0.25*r + 0.20*b + 0.15*s + 0.10*q + (charging?0.1:0);
  }

  Role elect(double myScore, Map<NodeId, double> neighborScores) {
    final sorted = [...neighborScores.values, myScore]..sort((a,b)=>b.compareTo(a));
    final rank = sorted.indexOf(myScore);
    final top20 = (sorted.length * 0.2).ceil();
    final shouldBeSuper = myScore > 0.60 && rank < top20;
    final shouldDemote = myScore < 0.50;
    return applyHysteresis(shouldBeSuper, shouldDemote);
  }
}
```

---

### 11. Testing the Algorithm

- **Simulator first:** Build `mesh_sim.dart` with 20-100 virtual nodes, random walk mobility, obstacles (walls attenuate RSSI by 15 dB). Measure: delivery ratio, overhead (msgs relayed / msgs delivered), latency by hop.
- **Real-world:** 6-10 phones in building: atrium (SUPER expected) + classrooms. Verify SUPER elects balcony/center nodes, battery drain on SUPER < 20%/8h with duty controls, and broadcast reaches 3 hops.

---
**Result:** Lightweight, phone-friendly, no central server, proven MANET primitives adapted for BLE/WiFi constraints.
