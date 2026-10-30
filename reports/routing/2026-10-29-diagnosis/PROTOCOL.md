# Diagnosis-first continuation

Starting branch arena/ff85cb12-dumanmessenger; fetched origin65fdd27. Sandbox worktree
matched origin but Git metadata reverted to82d967a; repaired index/ref only after comparing
engine, without a reset/worktree edits. No unrelated changes remained. Node22.22.3,
local Dart unavailable. Existing evolution report, raw rows, metrics, trace/retry/routing,
Dart copyWith and existing shared parity tests inspected before instrumenting.

Phase0/1: reproduce exact evolution baseline counts/relays/retries with identical config,
150 acceptance-plan text unicasts at1500ms, no drain, independent motion seed XOR0x1347.
Crowd3301/3302/3303 both modes and protected2201 all other scenarios/both modes:12 worlds.
These OLD final seeds are now discovery data, never new holdout data. Compare diagnostics
ON/OFF on one case for exact full stats/deliveries invariance. Bounded optional diagnostics
capture existing event observations; distinguish overlapping evidence tags from proven root
causes. Sleeping scanners do not imply sleeping data receivers: inspect actual implementation.
No parameter/algorithm search before failure evidence is examined.

After diagnosis select at most one narrowly justified candidate, predeclare its hypothesis,
resource constraints and test splits in an addendum before new outcome runs. Fix existing
metric population, inbox deduplication, retry hop reset, DTN, expiry, 225-second window and
all existing acceptance thresholds. No unrestricted flooding, RF-range/TTL increase or
production activation. Owner-approved resource/non-inferiority tolerances still absent.

## Frozen targeted experiment, before new-seed outcomes

First replay (12 worlds) reproduced prior five counts, relays and retries. In crowd discovery
there were185 five-hop misses:65 delivered over five,120 not delivered by horizon. Observed
route estimates exceeded remaining five-hop budget on129 misses; reverse-to-sender route
on53, route entry age>10s on110. These overlap and are NOT proven message root causes.
Original receiveOGM keeps the historically shortest hop/neighbour even after a newer
originator sequence arrives via a different neighbour; every receipt refreshes lastSeen.
This is a concrete stale-minimum mechanism, testable independently of parameter search.

Single candidate `ogm-epoch-v1`: newest originator sequence starts a new route-selection
competition; only equal-sequence shorter/better-TQ copies can replace it; old sequence
cannot replace route. Baseline remains the default; no change to MPR/fanout/TTL/RF/retries.
Hypothesis: replacing obsolete shortest routes reduces loops and long detours enough to
improve five-hop crowd delivery. Alternative: earliest arrival of a new sequence is a
poor route and hurts delivery; reject rather than tune further. TS-only research arm;
not live-compatible, no Dart outcome or device validation claimed.

Discovery development4301/4302, validation4303/4304, final untouched5301–5306 crowd,
protected6301/6302 three other scenarios. Every seed both modes, both arms, identical
traffic, topology, config and independent motion stream. Loss/jitter share endogenous
RNG calls, so changed transmissions break packet-level common-random pairing. Pair at
world seed level; do not treat packets as independent. No final-seed policy feedback.

Provisional research-screen gates (NOT owner-approved release tolerances): both modes
separately >90% aggregate, all6 final seeds >90%, paired95% t interval lower bound>0;
protected every paired seed has no five-hop loss; max totalTX and modeled energy ratio
<=1.05; p95 latency ratio<=1.10. Report every failure, distributions, seed-pass fraction,
three-hop/overall, retries/queues/expiry and diagnostics; no pooling contexts/modes.
Six final worlds/mode is a bounded feasibility screen, not a production sample-size claim:
prior baseline final range74.67–83.33%; improvements needed exceed10pp, but no reliable
fresh-route paired variance exists. At6/6 successes a one-sided95% seed-pass lower bound
is only60.7%; robust >90% across-world reliability would require a larger untouched
prepowered study even on a positive screen. Owner budgets and promotion remain blocked.
Do not expand sample adaptively or try another candidate after observing final results.
