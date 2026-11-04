# Failure taxonomy, field availability and diagnostic ML

## Auditable labels, not causal inventions

Preserved prior `failure-evidence.json` and reproduced baseline records. The canonical
binary supervised target is **no unique first destination delivery within five hops by
the fixed horizon**. It includes over-five first deliveries and undelivered messages;
these are distinct descriptive subcategories. Duplicate and later shorter copies do
not change the canonical first-delivery label. No RF-root-cause label is invented.

The prior taxonomy's strongest-evidence priority remains: ideal temporal contact absent;
first receipt over five; observed reverse-route branch; TTL-exhausted branch; MPR geometric
coverage gap; exhausted retries; link loss; otherwise unknown. Only the first is a
physical-horizon upper-bound exclusion and the second a measured metric outcome. Remaining
labels explicitly say causality unresolved. Every failed record retains first timestamps,
counts and bounded examples; tags overlap. No output is called a mutually exclusive
physical-cause classifier. All12 replay worlds have zero diagnostic overflow.

Crowd330x:185 misses total across the separately reported91/94 misses per mode;65 over-five,
120 undelivered;22 absent ideal contact. Overlapping observations:129 over-budget route,
53 reverse route,32 MPR geometric gaps,168 copy link losses,156 retry exhaustion. Confidence
is high that these events occurred; low that any one event explains the global outcome.
Suggested interventions are bounded first-hop diversity and future age-aware coverage
proof, not removing MPR. Sparse/partitioned temporal reachability limits are distinct
from a route-policy defect. No7-day bundle expiry occurs in225 seconds; route expiry
counters do not mean message expiry. Channel free/none has RF loss but no simulated MAC
collision. Sleeping affects discovery/scanning, not universal data reception.

## Old-record schema and missingness

| Field | Availability/units | Permitted use |
|---|---|---|
| scenario/power,seed,source/dest IDs | retained | context, grouping; IDs/seed excluded predictors |
| send timestamp | synthetic ms after warmup | elapsed traffic time normalized225000, available at send; benchmark-specific |
| first receipt/hops/latency | future outcome | LABEL/evaluation only, never predictor |
| retries/loss/coverage/duplicates/queues | post-send diagnostic counts; first ms; bounded examples | overlapping descriptive strata only |
| ideal temporal contact | optimistic future oracle, some baseline records only | impossible-pair analysis, never predictor |
| source neighbor count/link/TQ/route age/queue at send | NOT retained in old records | marked missing, no reconstruction/future proxy |
| exact directional ETX, neighbor-list age, full backup paths/cut vertices | not retained/represented | no invented metrics or disjointness claim |

## Models actually trained before new final seeds

Dependency-free `reliability_ml.py` compares constant prevalence, a depth-one regression
stump (bounded thresholds) and L2 logistic regression. Inputs ONLY duty, elapsed send
time, context indicators. Fixed preprocessing,600 gradient iterations/L2.002; train4301,
4302 and protected6301; validation4303/4304; exposed retrospective audit5301…5306 and
protected6302. No row from the same seed crosses splits, including modes/arms. Only
baseline rows are fitted; no paired treatment rows leak into model evaluation. SHA256
of raw data in diagnostic-model.json; per-world error/calibration in ml-per-world.json.

Validation chose logistic by Brier score, not accuracy. It has **0 failure recall at0.5**,
AUC0.509, Brier0.1266 and ECE0.1448 on crowd validation: essentially no useful ordering
and substantial overprediction. Exposed multi-context audit AUC0.780, precision0.697,
recall0.575, Brier0.1490, ECE0.0823 mainly benefits from easy scenario differences; this
must NOT be advertised as a crowd routing predictor. Accuracy88% at validation is mostly
majority successes. No SHAP for a weak model, no mixed-effects asymptotic claims from
one protected train/test seed, no survival independence assumption under repeated/censored
attempts. Seed-wise metrics are retained rather than IID packet confidence intervals.

## New minimally invasive source snapshots

Runner reads existing source state **before** send: observed peer count/128, source DTN
queue/500, battery, SUPER flag, route presence/hops/6,TQ,age clipped at30000ms, duty and
elapsed time/225000. Missing route: hasRoute0, other route features0. All fields finite;
reject missing/extra feature keys. Features represent the source's possibly stale beliefs,
not geometry, another node's live queue or future contact. Reading them calls no RNG and
schedules no events. Routing diagnostics ON/OFF invariance is tested for baseline AND
new backup arm. No new core diagnostic mutation is required for snapshots.

`reliability_local_ml.py freeze` trains on4301 baseline only, selects logistic vs constant
using4302 Brier, locks artifact BEFORE740x runs. Two worlds per split is only exploratory.
Same threshold0.5, fixed L2.01/600 iterations; no final-dependent refit. Artifact includes
feature order, preprocessing, data hash, weights, timing and unsupported-runtime status.
`evaluate` reports precision/recall/AUC/Brier/ECE and calibration by context/mode on untouched
final baseline rows; the selected model NEVER selects forwarding actions. New rich-feature
results are in RESULTS.md. Prediction ≠ treatment benefit ≠ causality. No learned routing
model or online learning is deployed.
