# ACK-6000 and learned selector evidence — 2026-10-28

Main report and deployment/rollback guide: [docs/14-learned-routing-selector.md](../../../docs/14-learned-routing-selector.md).

* `PROTOCOL.md`: predeclared search, budget, primary comparison, missing owner tolerances,
  and disclosed 606 holdout exposure / replacement reserved before fitting.
* `WORKLOG.md`: durable execution ledger, including the failed first Dart CI run.
* `targeted.json`: 104 actual homogeneous routing runs; full effective configs and hashes,
  source HEAD, per-source warmup features, paired outcomes and simulator stats.
* `exogenous.json`: four controlled-motion runs; positions prove movement matches by policy.
* `final-holdout.json`: 16 seed909 runs after model freeze, not used for training or tuning.
* `per-seed.csv`: 124 flat routing result rows with primary and secondary metrics.
* `summary.json`: independent crowd seed comparisons; no one-seed confidence intervals.
* `pareto.json`: nondominated baseline/ACK pairs over five-hop delivery, relays, p95 and NORMAL energy.
* `model/`: experimental fitted policy, metadata/hashes, baseline-only config and frozen evaluation.
* `shadow.json`: eight pairs of actual baseline/shadow worlds (16 additional runs), exact
  delivery/stat equality, whole-session diagnostic counters and Node load/decision timings.
* `verification.json`: actual verification and exact unrun/blocked scope.
* `SHA256SUMS`: integrity checks for retained evidence and model artifacts.

No private data, message contents, unrestricted model code, paid training dependency or
online learning is involved. The synthetic source-index features are local observations;
paired source labels are not causal guarantees for a mixed-policy network. The trained
model chooses baseline in both leaves. No candidate is approved or active.

Raw first-capture `sourceSha` is the starting checkout HEAD, not a claim of a clean tree:
experiments used the new harness while implementation was pending. Main benchmark baseline
started at c74b164; relevant implementation is retained in 762e048/adac00d. The first shadow
capture records model hash and version, not a clean source snapshot; integration equivalence
is separately tested by the exact shared-fixture and baseline/shadow regression tests.
Training metadata includes the exact code hash (matches adac00d's trainer), dataset hash and
checkout HEAD when fitting, which can precede the commit containing pending changes. Future
runner captures record engine/runner hashes and support atomic checkpoints with --resume;
old captures lacking those fields deliberately cannot be silently resumed under new code.

Reproduction commands are in the report. Use a new artifacts/ directory, never overwrite
this dated evidence. The runner refuses to overwrite an existing checkpoint without --resume;
resume rejects changed code/toolchain hashes. A trainer refuses to overwrite a different
frozen model. Evaluation never refits the model. No final holdout retesting to find significance.
