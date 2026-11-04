# Evolutionary learning continuation — evidence index

[Report and measured decision](../../../docs/15-evolutionary-five-hop-search.md).

* PROTOCOL.md — fixed budget, splits, safety and target specified before final comparison.
* runs.json — all80 actual worlds, per-seed full configurations/hashes, stats and metric counts.
* policy.json / policy.sha256 — frozen learned configurations, objective, population and provenance.
* per-seed.csv — flat delivery/hop/relay/latency/retry/energy/stability comparison.
* summary.json — held-out seed intervals, worst cases and explicit rejection reasons.
* contact-bound-*.json — two optimistic temporal reachability diagnostics, NOT five-hop scores.
* verification.json — checks, CI revisions and unverified scope. SHA256SUMS — retained integrity hashes.

Raw first execution used the new runner while the clean baseline starting HEAD was709a2ec;
runner source is retained at84f26b1. No runtime source changed. The later source-HEAD retention
fix changes checkpoint code hashes, so reproduce old evidence with its recorded version or
use a fresh output directory. Do not silently mix new code into an old checkpoint.

Policy selection used only1101/1102. The holdout3301/3302/3303 was not used for tuning. No
release default was changed. Exceeding90% on protected campus is not evidence that the
crowd stretch target passed: the latter failed and the summary deliberately records false.
The optimistic100% contact bounds likewise are never substituted for actual five-hop ratios.
