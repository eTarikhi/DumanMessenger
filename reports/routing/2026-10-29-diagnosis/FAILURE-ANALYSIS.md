# Failure diagnosis (before candidate outcomes)

Baseline reproduction:12/12 worlds match **every field** of prior `runs.json` stats and
five-hop counts. Source65fdd27 baseline semantics, final research executable810cab6;
per-file SHA256 and exact complete configs/motion seeds retained in baseline.json.
A subsequent final-source replay confirmed the same results, not a new population.

## Crowd discovery: same three old seeds, kept separate by power

| Observation | Always (450 sends) | Duty (450 sends) |
|---|---:|---:|
| Five-hop first deliveries |359|356|
| First delivery over five |33|32|
| No delivery by fixed horizon |58|62|
| No ideal temporal contact before horizon |11|11|
| Misses with route estimate beyond remaining five hops |66|63|
| Misses with immediate reverse-to-sender route |31|22|
| Misses with route entry age>10s |55|55|
| Misses with a TTL-exhausted branch |36|38|
| Misses with a copy's link-loss event |81|87|
| Misses with MPR suppression |78|85|
| Misses with MPR suppression and actual geometric coverage gap |10|22|
| Misses with exhausted source retries |77|79|

All evidence-tag rows overlap; they are NOT causal attribution percentages and cannot
be summed. Successful messages also experience loss/suppression. No claim that removing
any tag rescues the entire message. `failure-evidence.json` gives every missed message's
first observed timestamps, bounded examples, copy queue occupancy and strongest available
evidence. The mutually exclusive strongest-evidence label is a reporting priority,
not an inferred root-cause classifier; unresolved labels say so explicitly.

### Strongest findings and controllability

1. **Path/route inefficiency is material:**65 actual first deliveries exceed five hops;
129 misses encountered a route whose advertised hops plus traveled hops exceeded five;
53 encountered a reverse route. Historic minimum-hop pinning is directly reproducible
with a unit test: newer longer OGMs refresh lastSeen while retaining old next hop.
This motivates exactly one epoch-freshness experiment. It does not prove pinning causes
all these failures or that newer routes are better. A reverse send wastes that branch
through normal duplicate suppression; alternate branches may still succeed.
2. **Contact limits explain a subset, dominate protected sparse/partitioned cases:**
ideal temporal reachability is143/147/149 of150 for crowd3301/3302/3303, identically both
modes, versus actual five122/125/112 and118/121/117. Sparse2201 ideal42/150 equals observed
42/150; partitioned2201 ideal62/150 equals observed62/150, both modes. No routing rule
can rescue the unreachable pairs within this fixed window under this graph. These are
lossless, zero-latency, unlimited-hop/copy carry bounds, NEVER five-hop scores or proof
that the remaining pairs admit a feasible <=5-hop stochastic schedule. Earlier1102/2203
bounds150/150 are DIFFERENT seed populations, not a contradiction.
3. **Loss, coverage age, retries and right censoring are unresolved joint mechanisms:**
168 crowd misses have copy link loss,156 exhausted source retries;32 have a suppression
with geometric coverage gap. Coverage advertisements have no per-neighbour-list age
check in relaysCoverPeers; stale coverage is a plausible additional targeted hypothesis,
not a reason to disable MPR wholesale. A suppressed branch with no geometric gap can
still fail on independent receiver link loss. Retries exhausted does not prove permanent
failure: copies remain carried for later contact. Messages injected late have little
observation time, but we preserve the acceptance horizon and do not secretly add a drain.

## Ruled out / not represented / unresolved

- Baseline channelAccess=free, channelCapture=none: stochastic RF link loss is represented;
MAC contention/collision/deafness is NOT represented by these worlds. Nonzero calculated
radio demand is not evidence of simulated collision. Channel drops and rate drops are
retained in stats; do not convert utilization into invented dropped packets.
- Duty cycle skips scanning, not all packet reception. Existing beacons/receive paths
continue. It changes peer refresh/DTN opportunities; it is not simply a receive-off mask.
- DTN queues use7-day TTL, so bundle expiry cannot occur in225 seconds of traffic.
Route expiry is a different statistic. Queue evictions are not fully traced by this
collector; no unknown eviction is assigned a root cause. Per-source/per-minute and
radio-drop counters remain available; no silent TTL/cap changes were made.
- Source retransmissions retain logical ID, increment attempt and reset copy hops;
duplicate suppression is per attempt, first destination receipt determines the metric.
Deliveries beyond five stay failed for primary metric even if a later shorter copy arrives.
Destination delivery precedes TTL relay handling. These existing semantics are unchanged.
- latencyByHop is NOT the delivery denominator. Explicit successful source-send count,
unique destination deliveries and primary five filtering agree with the prior study.
No metric implementation defect was demonstrated. The fixed horizon is an explicit
right-censoring limitation, not repaired by redefining the denominator.
- Existing fresh-node traces omit duplicate/lost branches and repeated visits; hence
bounded opt-in observations were needed. Diagnostic cap1000 message records,8 examples
per record,240 characters/detail,50000 incoming keys; overflow is reported, zero in runs.
ON/OFF test compares complete nodes, stats, deliveries, logs and next RNG draw exactly.
No real-user payload bodies are logged; only synthetic IDs, routing reasons and counters.

## Why timing alone is not a verified path

The prior timing-only study's exposed final results are reproducible, not robust >90%.
Changing ACK/beacon timing cannot make an unreachable temporal pair reachable and does
not remove the historic-minimum route-selection rule. It may still alter coverage/loss
opportunities; no impossibility theorem for every timing policy is claimed. Unlimited-hop
contact optimism likewise supplies neither a five-hop guarantee nor an implementation.
