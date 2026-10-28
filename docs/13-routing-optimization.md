# 13 — Five-hop routing optimization laboratory

Date: 2026-10-28. **Research implementation, not deployment approval.**

## 1. Decision and scope

The owner's new mission explicitly selects **five-hop delivery as primary** and three-hop delivery as diagnostic. This resolves F2 in the historical remediation report; no acceptance threshold, denominator, hop definition, or engine default changes. `skills/02` now states that decision rather than continuing to ask for it.

This iteration implements a bounded offline strategy library, reproducible paired experiments, conservative rejection analysis, and cross-language regression fixtures. It does **not** claim a global optimum, establish that improvement is impossible, or authorize online learning. An unsuccessful bounded search is useful evidence, not proof that all routing algorithms fail.

## 2. Architecture and metric audit

| Responsibility | TypeScript | Authoritative Dart counterpart |
|---|---|---|
| Coverage scoring, eligibility, role hysteresis | `src/election.ts`: `computeScore`, `electRole` | `lib/src/election.dart` |
| OGM route learning and next-hop lookup | `receiveOGM`, `getNextHop` in election module | same functions in Dart election module |
| Initial/relay forwarding decision | `src/routing.ts`: `decideForward` | `lib/src/routing.dart`: `decideForward` |
| Two-hop coverage suppression, bounded dense fanout | `resolveMprWait`, `selectMprSet`, `relaysCoverPeers` | routing/election modules |
| Scheduling, RF reception, radio queues, forwarding | `src/simulation.ts`: `applyDecision`, `transmit`, `onMsgReceive` | `lib/src/simulation.dart` |
| Retry and delivery bookkeeping | `onAckTimeout`, `recordDelivery`, `deliverToInbox` | simulation/routing modules |
| DTN handoff and custody | `scanOppQueue`, `enqueueOpp`, `pruneAcked` | routing module |
| Gate population | `src/__tests__/acceptance.test.ts`: `measure` | `bin/mesh_sim.dart`: unicast/withinFive report and gate |

Routing first uses direct delivery, then a usable advertised next hop (TQ threshold); unavailable routes fall back to coverage-aware MPR, not arbitrary shortest paths through a global graph. SUPERs relay immediately, NORMALs wait for coverage evidence. Dense fallback uses angular sectors and a bounded fanout. Carried bundles with no route park instead of flooding. Carrier selection and source ACK timing are already configurable primitives: experimenting with them need not fork the routing engine.

### Exact population (unchanged)

* Traffic is 150 planned text unicasts, 1,500 ms apart. Initial warmup is the scenario's existing 8,000 ms; the constructor clears warmup records. The last interval advances time; **there is no additional final drain**.
* Denominator: successfully submitted messages when both endpoints are online and `sendMessage` accepts. Not attempted radio packets, ACKs, relays, or a denominator conditional on delivery. The harness asserts this equals `stats.sentUnicast`.
* Numerator: `deliveries` entries excluding `ack` and `broadcast`, with `hops <= 5`. The gate's literal filter does not explicitly exclude group or transfer records, but this workload generates neither. It would be incorrect to reuse the filter for mixed traffic without auditing that population separately.
* Delivery is recorded on the addressed receiver after inbox deduplication by logical message ID. Retries use the same logical ID and a new attempt, allowing intermediate forwarding (`seenKey` includes the attempt) without counting destination duplicates. The harness explicitly rejects duplicate delivery IDs. The 150-message window stays below the 200-entry inbox and 5,000-entry delivery retention limits; unbounded runs would require a different audit.
* `recordDelivery` defines hops as `msg.hopCount + 1`: direct delivery is one; each forwarding step increments the carried counter and decrements TTL. **Retries reset hopCount to zero at the source.** Five hops describes the copy that first delivered, not the sum of radio work across failed attempts. DTN retains the stored copy's hop counter; spray attempts increment attempt IDs without pretending the original failed radio work was on the final path. No change is made to these semantics.
* DTN and retry deliveries count. A message arriving beyond five hops improves overall delivery but not the primary metric. Expiration/remaining queue statistics are not interchangeable: a seven-day DTN TTL cannot expire naturally in this 225-second measurement window. We report undelivered-at-horizon, exhausted retries, and queued copies, **not a fabricated expired-message count**.
* `latencyByHop` is restricted to first-attempt, non-DTN deliveries and must not supply either delivery numerator. This benchmark reports all-unicast latency separately, including retries and waiting.

The mission does not alter encrypted packet layout, Noise_XX, reverse ACK compatibility, media chunking, transfer backpressure, or user battery-saver eligibility. `docs/07` and `docs/08` remain applicable. Text-only experiments are not media or handshake validation.

## 3. Research: evidence versus hypotheses

Published algorithms motivate hypotheses, not delivery guarantees for Duman's workloads.

* **Q-routing:** Boyan and Littman's distributed reinforcement-learning routing learns local estimates of downstream delay and reports improvements on their simulated network workloads. Its objective is not Duman's five-hop gate. [1](https://proceedings.neurips.cc/paper_files/paper/1993/file/4ea06fbc83cdd0a06020c35d50e1e89a-Paper.pdf)
* **Contextual bandits:** LinUCB models context-dependent arm rewards with confidence bounds; the paper also discusses offline evaluation assumptions. Sequential, mutually interacting mesh nodes do not automatically satisfy an independent-interaction model. [8](https://arxiv.org/pdf/1003.0146)
* **Bounded replication:** Spray and Wait separates bounded spraying from waiting for destination contact, addressing the transmission cost of flooding in intermittently connected networks. The existing Duman queue is related but also permits advertised-route forwarding, so it is not an exact implementation of the paper's model. [2](https://dl.acm.org/doi/10.1145/1080139.1080143)
* **Bayesian search:** Snoek, Larochelle and Adams model hyperparameter performance using Gaussian processes to economize expensive evaluations. That motivates a later search over a larger bounded configuration space; it is unnecessary machinery for six enumerated arms. [1](https://proceedings.neurips.cc/paper/2012/file/05311655a15b75fab86956663e1819cd-Paper.pdf)
* **Multi-objective evolution:** NSGA-II supplies a nondominated-sorting evolutionary search approach. This motivates retaining a Pareto set rather than hiding transmission costs in an arbitrary reward weight. [1](https://dl.acm.org/doi/10.1109/4235.996017)
* **Deep Q-learning:** Mnih et al. demonstrate deep reinforcement learning in their control setting, not evidence of a gain in this mobile protocol. [10](https://www.nature.com/articles/nature14236)

### Candidate assessment (engineering estimates, not measured model timings)

Let A be approved strategies, F local features, N neighbors, D route destinations, and W neural-network weights.

| Approach | Five-hop mechanism / required observations | Cost, training and principal risks | Decision this iteration |
|---|---|---|---|
| Tuned heuristic | Change ACK timing or bounded carrier preference; uses existing timers, routes, role/charging advertisements | Constant incremental routing work, no training, easy deterministic replay; may trade waiting against redundant attempts | Implement and evaluate bounded arms |
| Transparent rules | Choose a tested arm from local peer count, recent failures, queue age and power mode | O(F+A), small state; thresholds overfit, neighbor count cannot prove end-to-end partition | Do not enable without validated arm/context advantage |
| Non-contextual bandit | Track delivered-within-five reward per arm | O(A) memory; delayed and missing ACK feedback confounds loss with partition; exploration spends scarce transmissions | Research only |
| LinUCB / contextual bandit | Density/mobility/queue context predicts an arm's constrained reward | Roughly O(AF²) state and inference/update work with maintained inverse matrices; delayed credit, coupled policies, exploration safety | Requires logged local decision features and randomized offline coverage first |
| Tabular Q-routing | Per-destination/neighbor estimate and hop budget in state, optimize bounded delivery return | O(DN) before adding hop/queue states; neighbor feedback protocol and cold-start traffic; topology nonstationarity | Not a drop-in compatible improvement |
| DQN | Approximate larger state/action value function using link/queue histories | O(W) inference/storage plus replay and training; variable neighbor actions, reward hacking, simulator overfit, floating-point reproducibility | No deployment evidence; no dependency added |
| Policy gradients / actor-critic | Direct next-hop or strategy policy with constrained reward | Rollouts and typically high-variance delayed rewards; training/inference and cross-language deployment burden | Not justified before simpler candidates win |
| Genetic / evolutionary multi-objective search | Mutate bounded timing/replication settings and retain nondominated results | Simulator cost dominates; no on-device training; finite validation may still overfit | Enumeration is the minimal Level-1 optimizer for this small space |
| Bayesian optimization | Surrogate proposes expensive configurations under delivery/energy constraints | Small training data but surrogate overhead and conditional parameter complexity; OOD uncertainty | Reserve for a larger search space |
| Supervised classifier | Label preferred arm using offline simulations, predict from actual local features | O(F × depth) for a small tree; labels can encode scenario identity or oracle knowledge; cannot infer labels from average results alone | No leakage-prone classifier trained |
| Model-based/hybrid | Simulated candidate evaluation plus hard protocol/power guards | No internet at inference; quality bounded by RF/mobility model fidelity | Implement offline safety boundary; retain known-good baseline |

A local controller could observe cached neighbor count (scan already pays collection cost), route availability/TQ (existing OGM table), queue length/age (bounded queue scan), ACK timeout counters, and user power mode. It cannot observe a true global partition, remote destination delivery before an ACK, oracle RF range, scenario name, or future mobility. Battery estimates in simulation are not measured phone joules.

If a controller is justified later: retain current strategy through missing observations, enforce minimum dwell and hysteresis, charge switching cost, and apply battery saver/opt-out *before* selection. Test counters reset and alternating contexts. No such untested controller is wired into the forwarding loop here. Offline policy selection from scenario names would be an oracle, not an automatic mobile routing solution.

## 4. Implemented strategy library and safety boundary

`tool/routing/strategies.ts` and `sim/mesh_sim/tool/routing_strategies.dart` define matching, versioned, existing-protocol parameter variants:

| ID | Patch relative to current scenario | Intended hypothesis | Status |
|---|---|---|---|
| `baseline-v1` | None | Known-good MPR/DTN behavior | Only approved default |
| `ack-2000-v1` | Text ACK timeout 2,000 ms | Recover losses earlier | Offline candidate |
| `ack-6000-v1` | Text ACK timeout 6,000 ms | Avoid premature retry amplification | Offline candidate |
| `super-carrier-v1` | Prefer SUPER carrier when no route | Higher contact opportunity | Offline candidate |
| `community-carrier-v1` | Prefer charging stationary carrier when no route | Stable custody | Offline candidate |
| `route-flood-v1` | Routing retained, MPR suppression disabled | Diagnostic reliability/relay trade-off | Diagnostic, never automatically promoted |

Unknown or unapproved IDs fall back to the original config unless the caller explicitly requests **offline** evaluation. No JSON model loader, arbitrary code generation, network dependency, new runtime package, or default routing change is introduced. Topology, TTL, retry limit, transmit power, duty cycling, rate limits and security controls are not search variables. DTN variants do nothing when DTN is disabled, and park if prerequisites/carriers are unavailable; existing spray limits continue to apply. The library reuses engine primitives instead of maintaining six engines.

**Level 1:** exhaustive finite configuration search implemented. **Level 2:** composition not promoted; an interaction sweep must precede combining individually promising patches. **Level 3:** no model-generated executable policy. Offline development-machine learning is preferable initially: it avoids private traffic collection, battery training costs, inconsistent per-device exploration, and any cloud requirement.

The analyzer emits `not-promoted` decisions and concrete rejection reasons. It screens held-out per-seed regressions, relay increases, energy estimates, p95 and stability; confidence bounds cannot auto-approve anything. Full authoritative evaluation, OOD, release acceptance, media and device evidence remain separate requirements. These conservative research screens are not new release thresholds and do not weaken existing ones.

## 5. Reproduction and experiment design

```sh
npm ci --no-audit --no-fund
npm run routing:benchmark -- artifacts/routing/benchmark.json
npm run routing:benchmark -- artifacts/routing/ood.json --ood
python3 tool/routing/analyze.py artifacts/routing/benchmark.json > artifacts/routing/summary.json
python3 tool/routing/analyze.py artifacts/routing/ood.json > artifacts/routing/ood-summary.json
python3 -m unittest discover -s tool/routing -p 'test_*.py'
npx vitest run src/__tests__/routing-strategies.test.ts
# SDK/network prerequisite applies:
(cd sim/mesh_sim && dart pub get --enforce-lockfile && dart test)
```

For a smaller parity workload: `npm run routing:benchmark -- artifacts/routing/smoke.json --smoke` (one seed, all four scenarios, both power modes, all arms). A smoke run is never held-out validation.

* Training seeds: **42, 7, 1234**. Validation seeds: **31415, 27182, 16180**. Separate OOD seeds: **424242, 8675309, 65537**.
* All four existing named scenarios are preserved: `campus_quad`, `sparse_village`, `festival_crowd`, `partitioned_pair`; always-on and duty-cycle separately. No sparse/partitioned scenario is relabelled a release acceptance pass.
* OOD combinations: static `festival_crowd` (mobility disabled), and `campus_quad` with CSMA, strongest-signal capture and binary backoff. Both power modes. These are model-shift stress tests, not hardware results.
* Six arms × four scenarios × two power modes × six seeds = **288** main runs; six arms × two OOD combinations × two power modes × three seeds = **72** adverse runs.
* Traffic pairs come from the existing acceptance-plan PRNG seed salt, independent of simulation event ordering. Full effective config and engine stats are captured per row, not just a strategy nickname. The baseline's seed-42 campus five-hop count must reproduce **148/150**, not the 140 first-attempt latency-table count.
* **Important limitation:** the engine shares one PRNG between mobility, packet loss and event jitter. Changing routing can consume random numbers differently; initial topology and mobility *rules* match, but mobile trajectories need not remain identical across policies. Paired comparisons estimate the complete seeded simulator effect, not an isolated effect under a fixed movement trace. Static-crowd OOD removes the movement confound, not all RNG coupling. Split independent exogenous mobility/link streams or replay recorded traces before stronger causal claims.
* Summary latency/hop p95 columns are means of per-seed percentiles, not percentiles pooled across runs.
* The analyzer reports per-context means and paired five-hop differences with Student-t 95% intervals over **seeds** (three per split; df=2), not falsely independent packet-level binomial intervals. They are unadjusted, low-power and exploratory across multiple comparisons. No confidence interval establishes a global optimum or device-level generalization.
* All-delivery mean/p95 latency and mean/p95 hops are separate from the engine's first-attempt transport budget. Each row retains relay counts, node transmission counts, retries, exhausted retries, remaining queue, role changes, NORMAL/SUPER battery estimates and the rest of `SimulationStats`. Wall time is whole-run timing, **not inference latency**. Model memory and inference costs are not measured because no model is deployed.

## 6. Results and recommendation

**Outcome: no candidate earns promotion.** The finite search found small average gains but no statistically resolved, regression-free improvement. Keep the current MPR default. This does **not** establish impossibility under the existing constraints.

Retained evidence: [main comparison](../reports/routing/2026-10-28/summary.md), [OOD comparison](../reports/routing/2026-10-28/ood-summary.md), [all 360 per-seed rows](../reports/routing/2026-10-28/per-seed.csv), [full main configurations/stats](../reports/routing/2026-10-28/benchmark.json), [full OOD configurations/stats](../reports/routing/2026-10-28/ood.json), [provenance/reproduction](../reports/routing/2026-10-28/README.md).

### Held-out aggregate (equal weight to eight scenario/power contexts)

The low pooled percentage is not failure of the campus release gate: sparse and partitioned scenarios include unreachable pairs. Conversely, a high campus ratio must not hide those contexts.

| Strategy | Train ≤5 % | Validation ≤5 % | Validation Δ pp [95% seed-block CI] | Validation relay change | Worst held-out seed/context Δ pp |
|---|---:|---:|---|---:|---:|
| baseline-v1 | 64.14 | 61.31 | +0.00 [+0.00, +0.00] | +0.00% | +0.00 |
| ack-2000-v1 | 63.69 | 62.25 | +0.94 [-1.18, +3.07] | +28.58% | -1.33 |
| ack-6000-v1 | 64.53 | 61.61 | +0.31 [-2.20, +2.81] | -0.90% | -8.67 |
| super-carrier-v1 | 63.69 | 60.61 | -0.69 [-6.82, +5.43] | +8.77% | -23.33 |
| community-carrier-v1 | 64.17 | 60.69 | -0.61 [-2.73, +1.50] | +2.99% | -12.67 |
| route-flood-v1 | 64.39 | 61.08 | -0.22 [-6.38, +5.93] | +151.00% | -21.33 |


Training's strongest mean candidate is `ack-6000-v1` (+0.39 percentage points). Selecting `ack-2000-v1` just because it has the highest held-out average would reuse validation as tuning. The latter's +0.94-point held-out mean has a CI spanning zero and uses more relay transmissions. Neither earns deployment.

### Baseline versus training-selected ACK-6000 on unseen seeds

| Scenario | Power | Baseline ≤5 % | ACK-6000 ≤5 % | Paired Δ pp [95% CI] | Candidate/baseline relays (mean paired ratio) |
|---|---|---:|---:|---|---:|
| campus_quad | always | 99.33 | 99.78 | +0.44 [-2.09, +2.97] | 0.869 |
| campus_quad | duty | 100.00 | 99.33 | -0.67 [-3.54, +2.20] | 1.050 |
| sparse_village | always | 25.11 | 25.11 | +0.00 [+0.00, +0.00] | 0.993 |
| sparse_village | duty | 25.11 | 25.11 | +0.00 [+0.00, +0.00] | 0.993 |
| festival_crowd | always | 81.33 | 84.89 | +3.56 [-8.98, +16.10] | 1.033 |
| festival_crowd | duty | 75.11 | 74.22 | -0.89 [-21.73, +19.95] | 0.977 |
| partitioned_pair | always | 42.22 | 42.22 | +0.00 [+0.00, +0.00] | 0.991 |
| partitioned_pair | duty | 42.22 | 42.22 | +0.00 [+0.00, +0.00] | 0.991 |


Important findings:

* Baseline seed-42 campus reproduces **148/150 within five hops**, confirming the audited gate rather than the latency-table population. Baseline campus validation is **99.33% always-on, 100% duty-cycle**. Dense mobile crowd is the more informative optimization target.
* ACK-6000 improves the always-on crowd mean from **81.33% to 84.89%** on unseen seeds, but loses **8.67 points on one duty-cycle crowd seed**. Its always-on crowd confidence interval still spans zero. It is a targeted hypothesis, not a justified automatic switching rule.
* Sparse and partitioned delivery remains unchanged across these parameter arms: carrier preference is no substitute for a physical meeting. End-of-window queues are not seven-day expiration evidence.
* SUPER-biased custody has a **23.33-point worst held-out regression**. This intuitive heuristic is unsafe as a blanket default.
* Routing-without-MPR costs **151.00% more validation relay transmissions**, reduces mean five-hop delivery by **0.22 points**, and loses **21.33 points** in its worst held-out context. Turning off suppression is not a generic reliability fix.
* OOD ACK-6000 averages **+0.94 points**, with **95% CI [-2.05,+3.94] points**, and loses up to **2 points** on an adverse seed/context. Even this modest change is not a verified generalized improvement.
* Campus and crowd seed-42 five-hop counts reproduce the previous documentation. The lower **unseen** crowd results are new generalization evidence, not replacement estimates for the old nine-seed population. Full tables retain all latency, transmission, role and energy measurements for every arm.

### Deployment and learning decision

| Capability | Evidence this iteration | Decision |
|---|---|---|
| Current routing | Regenerated across training, held-out and adverse contexts | Retain default |
| Best train-tuned heuristic (ACK-6000) | Small gains; duty-cycle/adverse-seed regressions; wide intervals | Offline candidate only |
| Automatic strategy selector | No safe context-to-policy advantage established; no causal local-feature dataset | Not implemented in forwarding loop |
| Learned classifier/contextual bandit | No model trained/evaluated; delayed credit and decision-feature collection unresolved | Cannot claim superiority or inference timings |
| Policy generation | Bounded Level-1 enumeration, provenance and rejection implemented | Foundation only; no promoted candidate |
| Deep RL / policy gradients | No measured Duman advantage over simpler alternatives | No model/dependency by default |

This iteration does **not** meet the mission's positive generalized-improvement criterion. It supplies an executable negative result over the declared search space, not a proof of infeasibility. Next experiments: larger independent seed samples, replayed exogenous traces, focused bounded timing/route-cost search, and local decision-feature logging before training a selector. No model is presented as “best” without measurements.

## 7. Verification and owner decisions

### Executed verification

* Local full TypeScript regression: **19 files, 484 tests passed**, 806.80 seconds while experiments shared the machine. Focused strategy safety suite: **4 passed**. Analyzer regression tests: **3 passed**.
* Production web build, tool TypeScript compilation, documentation checks, cross-language constant/config parity, Dart declaration-site checks, Dart delimiter checks, and `git diff --check`: **passed**.
* Authoritative CI [40638583664](https://github.com/eTarikhi/DumanMessenger/actions/runs/40638583664) at `0082fd5`: **9/9 jobs passed**; Dart job **329 passed / 0 failed / 0 skipped**, including **48 new exact strategy/scenario/power comparisons** against the retained TypeScript fixture. No existing golden vector was changed.
* Local Dart execution: **not-run**, SDK unavailable. The full 360-run candidate matrix has **not** been rerun in Dart; the 48-case parity fixture and existing baseline acceptance runs are the verified subset. Device energy, model inference and online selector performance are **not measured**.
* Machine-readable evidence and CI IDs: [verification.json](../reports/routing/2026-10-28/verification.json). Baseline TypeScript engine source hashes are retained there. Earlier lab commits `6418cd8` and `9b90713` passed all nine CI jobs.

No merge to main. New behavior must remain off until validated in authoritative Dart, unseen seeds, adverse models, existing release gates and real devices. The cross-language fixture pins all six policies, four scenarios and both power modes on seed 42; it is parity evidence, not held-out evidence or automatic approval. Golden vectors for existing routing are not regenerated.

Owner decisions still required before deployment: any accepted increase in relay/energy budget; any release threshold change; enabling adaptation by default; permission for online device learning or user telemetry; additional training infrastructure costs. None is assumed. The five-hop primary-objective decision is already explicit and needs no further question.

Further work is to expand seed counts, decouple exogenous random streams, add OOD mobility/link traces and media workloads, then compare a transparent selector against a small offline-trained classifier or bandit **only if** validated arms have a genuine context-dependent Pareto advantage. Deep learning currently has no measured advantage here; that is insufficient evidence to deploy it, not proof that it cannot help.
