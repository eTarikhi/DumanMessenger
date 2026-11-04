# Research-led routing reliability and diagnostic ML

**No production change: the unseen crowd >90% objective remains unmet.**

Full evidence in [dated report](../reports/routing/2026-10-29-reliability/README.md):
[reconciliation](../reports/routing/2026-10-29-reliability/BASELINE-RECONCILIATION.md),
[research matrix](../reports/routing/2026-10-29-reliability/RESEARCH.md),
[failure/ML schema](../reports/routing/2026-10-29-reliability/FAILURE-AND-ML.md),
[preregistered protocol](../reports/routing/2026-10-29-reliability/PROTOCOL.md),
[results](../reports/routing/2026-10-29-reliability/RESULTS.md),
[deployment/rollback and owner actions](../reports/routing/2026-10-29-reliability/DEPLOYMENT-AND-ROLLBACK.md).

## Trustworthy baseline

Actual startingHEADdbd6e83 was clean, on the requested branch, with two successful CI
runs on that exact HEAD—not merely810cab6. Replayed12 baseline worlds across four
scenarios/both modes, then audited all12 baseline530x crowd worlds. **Every statistics
field matched** the historical records. The79.78/79.11 percentages use3301–3303;
82.89/82.78 use5301–5306. Different seed populations, same denominator/metric semantics:
not evidence of progress or a contradiction. Experimental policies also differed.

## Research and ML actually executed

Verified bibliographic/status information for OLSRv2, PRoPHET, ETX/ETT, opportunistic
routing, bounded DTN, multipath/load scheduling, Trickle, adaptive retransmission,
ContikiMAC, Q-routing/LinUCB and multiobjective optimization. Matrix distinguishes
published findings, project inference and experiments; inspected pinned Contiki-NG
MRHOF implementation. External throughput gains are not Duman delivery claims.

Old outcome records lack pre-decision local state: context/time models were weak in
crowd despite apparently good all-context accuracy/AUC. Added source snapshots to the
experiment runner (no RNG/events): discovery/queue, battery/role, route presence/hops/TQ/
age, power/time. Frozen offline logistic vs constant on4301/4302 BEFORE740x evaluation.
Untouched crowd AUC0.854/0.861, precision0.526/0.527, recall0.556/0.513; calibration and
errors retained per context/mode. This is failure-risk prediction, **not action value
or causal attribution**. No learned routing selector or online learning activated.

## One bounded reliability alternative

`source-backup-v1`, TS-only experimental: on an initial source-routed text message, add
at most one different locally advertised/discovered suitable first hop. No relay-level
replication, MPR disable, TTL increase or changed retry/DTN caps. True distinct first
hops do not establish node-disjoint end-to-end paths; no correlated-failure independence
assumed. Compare baseline, latest resource-competitive epoch candidate, and backup.
Seventy predeclared worlds, including historical audit, plus12 exact baseline replays;
all per-message/source snapshots and negative outcomes retained with hashes.

| New final7401–7404 (each mode) | Always | Duty |
|---|---:|---:|
| Baseline five-hop |79.00%|80.83%|
| Epoch comparator |80.17%|80.33%|
| Bounded backup |80.33%|80.67%|
| Backup paired change95% CI,pp |+1.33 [−1.27,+3.93]|−0.17 [−0.70,+0.36]|
| Backup seeds strictly >90% |1/4|1/4|
| Backup worst seed |72.67%|70.00%|

Benefit/all-seed/target gates fail. Backup max p95 ratios1.187/1.147 exceed proposed1.10;
campus duty dataTX ratio1.063 exceeds proposed1.05. Sparse/partitioned remain separate
and unchanged by backup. CSMA+strongest diagnostic radio sensitivity decreases7401
five-hop91→87 and90→87; not acceptance or real-device validation. Mean Pareto points,
Jain fairness, control attempts, queues/retries/latency/energy proxies and all per-seed
values are retained. No favorable7403-only claim or pooled protected average.

No synthesis or complex learner is justified by inconclusive individual improvements.
Default baseline unchanged, independent rollback available. Unknown research profile
fails construction; live selector cannot activate it. Dart candidate parity/device
adapter/cohort are absent; existing Dart tests do not validate new TS-only profiles.
Owner cost/regression budgets still require approval before any future promotion.

## Verification scope

Core/test source3051774, model-freeze/report source55b74bf. CI40852877613 and40852870858
completed successfully on55b74bf: **9/9 jobs,516 TypeScript tests/25 files,344 Dart tests
(0 failed/0 skipped)**. Old3051774 runs were cancelled by newer pushes, not called passes.
Focused7 tests, typecheck/tool compile/build/static checks and8 Python evidence/metric
contract tests passed. Final evidence-only HEAD has its own CI status checked at handoff;
see verification.json and final handoff rather than substituting a prior green SHA.
Local Dart unavailable; real hardware/canary not run. No merge to main.
