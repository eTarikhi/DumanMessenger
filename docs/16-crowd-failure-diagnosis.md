# Crowd delivery: diagnosis-first continuation

**Outcome: >90% five-hop delivery remains unverified. No promotion or default change.**

Dated evidence: [protocol](../reports/routing/2026-10-29-diagnosis/PROTOCOL.md),
[failure analysis](../reports/routing/2026-10-29-diagnosis/FAILURE-ANALYSIS.md),
[experiment and promotion decision](../reports/routing/2026-10-29-diagnosis/EXPERIMENT-AND-PROMOTION.md),
[reproduction/inventory](../reports/routing/2026-10-29-diagnosis/README.md).

## What was verified

- Recovered persisted65fdd27 tree/index metadata without a worktree reset, after fetching
and comparing against origin. Stayed on arena/ff85cb12-dumanmessenger; no main merge.
- Replayed12 baseline worlds covering all four scenarios and both power modes: **every
stats field and five-hop count matched** the prior study. Earlier different seeds were
not pooled. All exact configs, source hashes, motion seeds and commands retained.
- Added explicitly bounded, opt-in diagnostic observations. ON/OFF regression compares
full nodes/stats/deliveries/logs and RNG draw, not just the primary score. Overflow zero.
- Ran64 targeted worlds (32 pairs), one deterministic route-epoch hypothesis, no broad
parameter search/learning. Protocol and splits committed before new outcomes. Preserved
150-send denominator, first-delivery hop semantics, fixed horizon, TTL/MPR/DTN defaults.

## Diagnosis

In the old exposed crowd population (450 sends per mode), always had91 five-hop misses,
duty94. Of these,33/32 first arrived beyond five hops;58/62 never arrived by the fixed
horizon. Ideal lossless/unlimited-hop temporal contact could not reach11 messages in
each mode; that is an upper-bound explanation for those pairs, not a five-hop result.

Across the two separately reported modes,129 misses encountered advertised routes beyond
the remaining hop budget,53 an immediate reverse-to-sender route, and32 a suppressed
branch with a geometric coverage gap. These overlapping observations are **not a causal
partition**. Per-message strongest-evidence labels explicitly preserve unknown causality.
Independent RF loss, stale advertised coverage, retries and right censoring remain joint
mechanisms. Baseline free/none radios do not simulate MAC collisions. Sleeping scanners
do not imply reception disabled. No metric bug was demonstrated.

A unit test demonstrates a specific route-table mechanism: an old minimum-hop next hop
can remain selected while newer longer OGMs keep refreshing lastSeen. This justified one
candidate that starts route selection afresh per newer originator sequence, without
flooding more or disabling MPR. It is not proof that all failed messages share this cause.

## Unseen-at-declaration final result

| Six crowd seeds/mode | Always | Duty |
|---|---:|---:|
| Baseline five-hop |82.89%|82.78%|
| Candidate five-hop |83.11%|83.67%|
| Paired delta95% t CI,pp |+0.22 [−2.02,+2.46]|+0.89 [−0.97,+2.75]|
| Candidate seeds strictly >90% |0/6|0/6|
| Candidate worst seed |76.00%|78.67%|
| Max per-seed p95 latency ratio |1.612|2.634|

Fewer reverse-route observations and data transmissions did not yield reliable delivery
benefit. Three-hop/overall, queue/retry/expiry, latency, role stability, modeled energy,
control load and paired uncertainty are retained, not hidden behind the mean. Counter
semantics are explicit: existing totalTx excludes OGM control broadcasts, and OGM
controlOverhead counts per-link attempts. Reduced dataTX is not measured phone savings.

Protected sparse/partitioned profiles had identical full stats. Campus duty mean delivery
was unchanged but one seed lost a delivery; campus p95/resource gates also failed.
Predeclared aggregate, all-seed, benefit and provisional resource/regression screens
therefore fail. Six seeds/mode is a bounded feasibility screen, not production statistical
power; no packet-independence or robustness guarantee is claimed.

## Safety, parity and next steps

`ogm-epoch-v1` is a finite, validated, immutable-per-run **TS-only offline constructor
option**, default `baseline`. No live selector model can activate it. Default TS/Dart
routing and existing approval/power/fault latches remain unchanged. Authoritative Dart
candidate implementation/shared candidate goldens, device adapter/cohort and real-device
battery validation are absent, explicitly blocked—not inferred from the existing suite.

Next bounded hypotheses: age-aware coverage proof/repair, realistic constrained temporal
five-hop feasibility, and separately labeled right-censoring/retry analysis. Never reuse
5301–5306 as untouched final seeds. Any future candidate must survive offline→shadow→
explicit opt-in→owner-approved promotion, with authoritative parity and agreed resource/
non-inferiority budgets. No new cloud/online learning/user-content collection is required.

## Verification

Final engine/test executable810cab6: GitHub Actions
[40847018098](https://github.com/eTarikhi/DumanMessenger/actions/runs/40847018098),
**9/9 jobs successful; TypeScript513 tests/24 files; Dart344 passed,0 failed,0 skipped**.
Existing golden freshness/default parity passed; this does NOT validate the new TS-only
candidate in Dart. Local focused4 tests, typecheck/tool compilation/build, offline analyzer
and4 evidence contract tests passed. Local Dart SDK and devices unavailable. CI uses
stable Dart (exact resolved SDK version not extracted), Node22; local Node22.22.3,
TypeScript5.9.3, Python3.11.2. See verification.json for exits, known setup/hook failures,
artifact hashes and the distinction between tested engine SHA and later evidence/docs.
