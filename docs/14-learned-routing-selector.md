# 14 — Shadow-first learned routing selector

**Date:** 2026-10-28. **Status:** implemented in both simulators; experimental model rejected
for candidate activation. Default routing is unchanged. No Flutter app or platform transport
application exists in this checkout, so this is not a phone deployment.

## 1. What changed

`src/routing-selector.ts` and `sim/mesh_sim/lib/src/routing_selector.dart` implement the same
immutable decision-stump contract and safety controller. The simulator calls one controller
per local source in the existing text ACK-timer path. It observes local context and emits
bounded local diagnostics. It never changes packet identities, the inbox, relay rules, the
metric denominator, DTN, media ACK timing, user power mode, or actual ACK timers.

Three modes exist: `baseline`, `shadow`, and `canary`. **All applied actions are currently
`baseline-v1`.** Canary requests return `approval-required`: there is intentionally no flag
or model field that can approve itself. A later owner-approved actuator requires an explicit,
reviewed API/version change and offline gates, not changing a JSON boolean. Shadow decisions
are predictions, not evidence of improved delivery.

This is an integrated live observation/controller implementation, **not live learned actuation**.
The lack of an approved candidate is intentional; building a model did not change that gate.

## 2. Metric and experiment integrity

The audit in [the previous research report](13-routing-optimization.md) still applies:
150 planned text unicasts, independent traffic PRNG, 1,500 ms intervals, constructor warmup,
no extra drain. Denominator is successful submissions; numerator is first unique destination
inbox delivery with `hops <= 5`. ACK/broadcast traffic is excluded. Retries and DTN count;
source retries reset the successful copy's hop counter, not lifetime transmission work.
The new runner asserts unique delivery IDs and the sent counter. Seven-day DTN expiration
cannot be inferred from a 225-second window; undelivered messages and queued copies are
reported separately. No gate, existing golden, default configuration, or threshold was changed.

Starting HEAD was **c74b164**, clean and identical to origin; no reset, force-push or main change.
Local Node is v22.22.3, Python uses only its standard library, and local Dart is unavailable.
Existing reports/libraries/gates in both languages were inspected before experiments.

The new [predeclared protocol](../reports/routing/2026-10-28-selector/PROTOCOL.md) and
[durable work log](../reports/routing/2026-10-28-selector/WORKLOG.md) record budget, splits and
interrupt-resume state. Training seeds **101/202/303**, diagnostic tuning **404**, validation
**505**, exposed exploratory audit **606**, final untouched seed **909**. The original 606
holdout's crowd totals were accidentally exposed by a progress-log tail before fitting;
this is recorded, not hidden. Seed909 was reserved before fitting; the model was serialized
and hashed before its runs started. There is **no further replacement or retuning**.
Only one final seed means no credible seed-level significance claim, regardless of result.

Each new candidate run includes the full config, config hash, source HEAD, synthetic traffic
and per-source pre-traffic local features/outcomes. `sourceSha` is the checkout HEAD at run
start, **not a clean-tree claim**: the harness/controller were under development. The baseline
measurement began at c74b164 with the new uncommitted harness; harness implementation is
retained at 762e048/adac00d. Experimental controller options were absent in these data worlds.
The [provenance manifest](../reports/routing/2026-10-28-selector/provenance.json) records optional motion instrumentation separately from SimConfig hashes. The raw data hash, training-code hash, training revision and immutable model hash are retained.

## 3. Targeted ACK-6000 diagnosis

ACK-6000 changes **text ACK timeout from the scenario's 4,000 ms to 6,000 ms**, not forwarding
TTL, hop limit, retry count, or MPR. A delayed retry can avoid amplification but also defers
recovery and when the source exhausts retries and enters DTN custody. Media's own timer is
not this action.

Exact historical reproduction succeeded, including relay/retry counters:

| Case | Baseline ≤5 | ACK-6000 ≤5 | Baseline/ACK relays | Baseline/ACK retries |
|---|---:|---:|---:|---:|
| Campus42 always | 148/150 | 149/150 | 3652 / 3327 | 31 / 37 |
| Crowd31415 duty | 104/150 | 91/150 | 34483 / 31000 | 158 / 167 |

The 13-message (**8.67-point**) duty regression is reproducible. Its mobile baseline has
mean-largest-component share 0.6385 versus 0.6126 in the ACK arm; both are globally connected
only 11.11% of connectivity samples. End queues grow from 115 to 140 copies; all-delivery p95
rises from 47.75 to 50.46 seconds. This is a delivery/resource trade-off, not denominator drift.
Longer timeout does not necessarily mean fewer retries under a changed event trajectory.

The simulator shares its default RNG among motion, loss and jitter, so policies can alter
movement by consuming the stream differently. Two targeted controls investigated that confound:

| Seed31415 control | Power | Baseline ≤5 | ACK-6000 ≤5 |
|---|---|---:|---:|
| Mobility disabled | Always | 69 | 70 |
| Mobility disabled | Duty | 69 | 69 |
| Independent common motion RNG | Always | 107 | 104 |
| Independent common motion RNG | Duty | 103 | 94 |

The explicit third simulator constructor argument seeds only motion. It is opt-in and
implemented in both engines; default golden behavior is untouched. In each controlled-motion
pair, final node positions match exactly and connectivity statistics match (mean-largest
component 0.72185; connected share 0.31111). Thus mobility-stream coupling is **not the whole
explanation**: a nine-message duty regression remains under identical movement. Static-world
results alone would have misleadingly dismissed the issue. Packet loss/jitter streams remain
policy dependent; this is not a proof of one specific packet-level causal mechanism. Longer
recovery interacting with intermittency is supported as a hypothesis, not an invented trace.
Next diagnosis should replay per-link outcomes/contact traces and trace retry-to-DTN transitions.

New independent seed blocks, final crowd outcomes, per-scenario latency, three/five-hop ratios,
relay/node transmission counts, queues, exhausted retries, role changes and both battery rates
are retained in [per-seed.csv](../reports/routing/2026-10-28-selector/per-seed.csv) and
[summary.json](../reports/routing/2026-10-28-selector/summary.json). All four existing scenarios
and both power modes are present. Historical adverse CSMA/capture and static-density results
remain in the earlier 360-run archive; this iteration adds paired mobility interventions, not
an undocumented full radio/density sweep. New heterogeneous radio/density final holdouts and
larger seed counts remain necessary before promotion.

### New crowd five-hop measurements (actual homogeneous worlds)

| Split | Power | Seeds | Baseline % | ACK-6000 % | Δ pp [descriptive 95% seed t interval] |
|---|---|---|---:|---:|---|
| train | always | 101,202,303 | 88.00 | 86.44 | -1.56 [-12.20, +9.09] |
| train | duty | 101,202,303 | 88.89 | 87.56 | -1.33 [-18.14, +15.47] |
| tune | always | 404 | 84.67 | 78.67 | -6.00 not estimable (one seed) |
| tune | duty | 404 | 83.33 | 71.33 | -12.00 not estimable (one seed) |
| validation | always | 505 | 74.67 | 88.67 | +14.00 not estimable (one seed) |
| validation | duty | 505 | 75.33 | 90.00 | +14.67 not estimable (one seed) |
| exposed-audit | always | 606 | 91.33 | 89.33 | -2.00 not estimable (one seed) |
| exposed-audit | duty | 606 | 87.33 | 85.33 | -2.00 not estimable (one seed) |
| holdout | always | 909 | 77.33 | 83.33 | +6.00 not estimable (one seed) |
| holdout | duty | 909 | 81.33 | 78.67 | -2.67 not estimable (one seed) |

The train intervals are descriptive, not held-out confirmation. **ACK-6000 is rejected for activation:** independent training means are negative, seed505 alone gives a large positive signal, but final909 still loses 2.67 points under duty cycling. This is seed/context variability, not a resolved generalized improvement. [Pareto fronts](../reports/routing/2026-10-28-selector/pareto.json) preserve resource trade-offs per paired context; neither a mean nor a frontier point constitutes approval.

### Offline label replay comparison — NOT live mixed-policy performance

| Split | Baseline % | Always ACK-6000 % | Rules % | Trained stump % |
|---|---:|---:|---:|---:|
| train | 65.31 | 64.83 | 65.11 | 65.31 |
| tune | 63.58 | 61.17 | 62.83 | 63.58 |
| validation | 60.58 | 64.33 | 62.25 | 60.58 |
| final909 | 61.00 | 61.42 | 61.75 | 61.00 |

Rules look better on some held-out label replays, but these source-level counterfactual combinations are not validated network outcomes. The trained stump equals baseline; it supplies **no measured learned-routing benefit**. No bandit/deep model or fabricated neural comparison is substituted.

## 4. Reproducible training and the learned artifact

The finite supervised search fits a one-split tree with thresholds **4/8/12/16/24 neighbors**.
Each leaf chooses baseline or ACK-6000 by summed five-hop-success advantage on training sources.
No weighted opaque reward hides relay, energy or latency costs: those are independent promotion
constraints, not silently monetized. Duty-cycle sources are always baseline. Ties choose baseline,
then the smallest threshold. The model sees no scenario name, seed, destination knowledge,
message content, topology oracle, or future delivery statistic at inference.

Labels compare each origin's outcomes in homogeneous baseline/ACK worlds. Other nodes' policies
and mobility may differ, so combining those labels is **offline label replay**, not a causal
estimate of a mixed-policy network. Training and evaluation reports explicitly say so. Rule-based
comparison uses neighbor count >=12 with the same power override; it is also label replay.

**Actual fitting chose baseline in both leaves, confidence 0.** No candidate partition earned
positive training gain. That degenerate result is honestly retained instead of forcing a useful-
looking model. Confidence is training-seed sign agreement, not a calibrated probability.
The 115-byte JSON artifact is explicitly `experimental: true`, never production-approved.
SHA-256: `ef63fbf524cb9ad056a0bd91fb1360330ad87c2518b64af74a748b47b4319c95`.

Feature schema/API version 1:

| Input | Unit/order | Collection and guard |
|---|---|---|
| neighbors | count /128, first | existing locally computed peer list; range 0..128, integer |
| duty | boolean 0/1, second | user configuration; forces baseline when enabled |
| queue | queued copies /500, third | existing OppQueue length; integer range 0..500; guard only |
| battery / saver | fraction / boolean | existing node state; saver or battery <0.25 overrides candidate |
| observedAt | simulator monotonic ms | actual last peer-list refresh, not fabricated current time; age <=10 s |

The tree compares normalized neighbors with threshold/128. Training inputs are warmup snapshots;
live inputs refresh during traffic. Staleness, future timestamps, clock reversal, missing and
nonfinite values, incompatible schema/action and hard-domain drift fail closed. In-domain
statistical or unseen link-quality shifts cannot be detected reliably by these few features;
this limitation alone argues against production inference.

Deployment artifacts: [model and metadata](../reports/routing/2026-10-28-selector/model/),
[training](../tool/routing/train_selector.py), [frozen final evaluation](../reports/routing/2026-10-28-selector/model/final-evaluation.json).
No dependency, cloud, private data collection or online learning was added. Python stdlib and
bounded JSON avoid a heavyweight interpreter, ONNX/TFLite integration, license or lockfile cost.
A contextual bandit lacks validated local delayed-reward credit/independent interactions here;
no bandit or deep-RL model was trained or benchmarked. Prior cited research is in report13;
none of those publications proves this selector would improve Duman delivery.

## 5. Safety controller and simulator integration

* Baseline mode is independent of model load/health. The default simulator constructor has no
  controller options and consumes the exact original random stream.
* Only baseline-v1 and experimental ack-6000-v1 can be *proposed*. Only baseline can be *applied*.
  Unsupported actions, APIs, nonfinite outputs and malformed/load-failed models cannot take over.
* Three **fresh** observations are required before a predicted switch; repeated timer queries
  on one peer snapshot are not three votes. Minimum dwell is 30 s, maximum four predicted
  switches per session. These are shadow safety parameters, not new release gates.
* User saver/low battery/duty mode overrides immediately. Model confidence below0.6 keeps the
  baseline. Model/context/clock/inference faults latch baseline until a new controller/session.
* `rollbackRoutingSelector()` latches every local source back to baseline. A host may call this
  on resource overrun, monitored regression or manual rollback. No untested automatic delivery
  monitor pretends to distinguish remote non-delivery from lost ACKs.
* Model scalar fields are copied/immutable. No in-run model update mechanism exists. A model
  exception cannot stop delivery. The desktop loader checks a trusted expected SHA256, API,
  action bounds and a 4096-byte file limit before use. A sidecar hash is integrity, **not an
  authenticated remote update**; host trust distribution still matters.
* Diagnostics store only proposed/applied ID, reason, switch count (256-entry tail) plus whole-
  session reason counters. No message body, destination, source identifier or payload is logged
  by this interface. Counters are not delivery estimates or proof of counterfactual success.

Shadow validation on seed505 ran 150 messages in every scenario and power mode. Every paired
baseline/shadow delivery record and full stat object matched exactly. The fitted artifact
predictably reports low confidence (baseline); synthetic shared fixtures exercise nontrivial
switching, oscillation limits, invalid actions and canary denial independently of that trivial
fitted policy. See [shadow.json](../reports/routing/2026-10-28-selector/shadow.json).
Model load and p50/p95 decision timings are measured there on this Node sandbox, **not phones**;
the benchmark includes the fitted low-confidence path, not a claimed worst-case deep inference.
Artifact bytes are measured; isolated heap, controller-bank peak memory and phone energy are not.

## 6. Build, reproduce, stage and roll back

```sh
npm ci --no-audit --no-fund
npx tsc -p tool/tsconfig.golden.json
# CommonJS marker (same as the repository's existing probe scripts):
node -e "require('fs').writeFileSync('tool/.build/package.json','{\"type\":\"commonjs\"}')"
# Use a NEW directory for an independent reproduction, never overwrite frozen evidence:
node tool/.build/tool/routing-targeted.js artifacts/selector/reproduce
node tool/.build/tool/routing-targeted.js artifacts/selector/reproduce --exogenous
python3 tool/routing/train_selector.py artifacts/selector/reproduce/targeted.json artifacts/selector/reproduce/model
# Freeze and review model SHA BEFORE final holdout:
node tool/.build/tool/routing-targeted.js artifacts/selector/reproduce --holdout
python3 tool/routing/evaluate_selector.py artifacts/selector/reproduce
python3 -m unittest discover -s tool/routing -p 'test_*.py'
npx vitest run src/__tests__/routing-selector.test.ts
# Current retained artifact shadow validation:
node tool/.build/tool/routing-shadow.js reports/routing/2026-10-28-selector artifacts/selector/shadow.json
npm test
(cd sim/mesh_sim && dart pub get --enforce-lockfile && dart test)
```

Stage A: offline data/fit/evaluation complete within the declared finite budget; **promotion
failed**. No seed-by-seed significance fishing or repeated final holdout was performed.

Stage B: shadow integration and matched-world checks implemented in both simulators. Instantiate
`new MeshSimulation(config, {mode: "shadow", model: verifiedModel})` in TypeScript, or
`MeshSimulation(config, RoutingSelectorOptions('shadow', verifiedModelMap))` in Dart. Desktop
SHA loader is `tool/routing/load-selector.ts`; pure Dart accepts a preverified map. A mobile host
must provide vetted SHA256 verification/trusted artifact distribution, storage, lifecycle and
privacy UI; no unsupported cryptographic implementation is fabricated inside the Dart core.

Stage C: canary gate is implemented and tested as **denial**. There are no approved phone devices,
app or cohort. Candidate actuation is not enabled even with `mode:'canary'`. Real-device canary
validation is blocked. Completing it requires an app/platform adapter, owner-approved budgets
and non-inferiority criteria, verified model loading on device, and a controlled cohort.

Stage D: no promotion. Keep constructor options absent or use baseline-only.json. Roll back an
existing shadow session via `rollbackRoutingSelector()`; unload model and create a baseline-only
session for next run. Fault latches cannot be reset by another prediction or a model update.

## 7. Verification scope

Local full regression at adac00d: **20 files / 504 tests passed**, exit0, 361.08 seconds.
Final focused selector tests at19024ab: **20 passed**. Python analysis/training tests: **7 passed**.
Web production build, tool compilation, doc drift, cross-language config/constants, Dart
site checks and delimiter checks passed. Local Dart is **not-run**, SDK unavailable.
Authoritative Dart CI at adac00d: **344 passed / 0 failed / 0 skipped**, including shared
switch/fallback vectors, shadow/canary identity and independent-motion tests. The first
implementation CI failed on Dart library/import directive ordering; it was fixed, not waived.
Final code CI [40642776402](https://github.com/eTarikhi/DumanMessenger/actions/runs/40642776402) at **19024ab passed 9/9 jobs**, including full TypeScript504 and Dart344. Runtime/tool sources are unchanged in the final evidence commit. Final-tree CI/evidence is recorded in [verification.json](../reports/routing/2026-10-28-selector/verification.json).

The 124 new homogeneous candidate runs are TypeScript measurements, not a claim that all
were repeated in Dart. Real-device canary, phone memory/battery, host crypto loading and
production activation are blocked/not-run, not passes. A model that fits baseline is not an
optimization success; actual shadow equivalence is not counterfactual delivery superiority.

## 8. Owner decisions and exact remaining work

No question is needed to finish independent work. Before any future activation the owner must
approve: protected-scenario non-inferiority margins, acceptable relay/p95/energy increases,
confidence/sample-size protocol and final holdout budget, canary devices/cohort, host integrity
and release approval. **No repository regression tolerance was found.** Recommend testing a
zero-degradation safety screen first; measured multi-point seed variability means a clinically
meaningful tolerance and powered multi-seed protocol must be agreed, not silently set to make
ACK-6000 pass. Proposed conservative research screens are a **0-point protected
five-hop margin** and **no relay/p95/energy increase relative to paired baseline** until the
owner explicitly approves trade-offs; these are recommendations, not newly approved release
thresholds. Pilot paired crowd standard deviations are 4.29 points always-on and 6.77 points
duty (only three seeds): even estimating a mean within +/-1 point at normal-approximation
95% precision would require roughly 71/176 seeds respectively, before multiplicity and power
adjustments. That precision target is not permission for a 1-point regression, and the tiny
pilot cannot support a definitive sample-size calculation. No default change, online learning or real-user telemetry is authorized.

Unfinished: larger independent seeds and adverse density/link/intermittency families; per-link
exogenous replay; mixed-policy counterfactual evaluation; full candidate matrix in authoritative
Dart; phone heap/latency/battery measurements; app feature UI/storage/crypto loader; physical
canary and promotion. The implemented interface is useful and reversible despite these gaps.
This mission does not produce a generalized delivery win or a production-approved learned model.
