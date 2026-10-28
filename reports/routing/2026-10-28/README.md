# Retained routing experiment evidence — 2026-10-28

Research report: [`docs/13-routing-optimization.md`](../../../docs/13-routing-optimization.md).

* `benchmark.json`: full effective configurations and per-seed, per-scenario metrics for training and held-out validation.
* `summary.json` / `summary.md`: paired uncertainty, resource screening, nondominated sets and aggregate tables.
* `ood.json`: separate static-crowd and CSMA/capture/backoff model-shift evaluation.
* `ood-summary.json` / `ood-summary.md`: adverse-condition tables; analyzing OOD alone intentionally does not substitute for held-out validation.
* `per-seed.csv`: flat 360-row review table with all principal metrics.
* `verification.json`: executed checks and CI evidence, distinguished from unavailable checks.
* `SHA256SUMS`: hashes of retained result files.

Raw JSON stores one compact row per line for reviewable diffs while retaining every effective configuration and stat. Numeric results have not been rounded in raw evidence. Summaries round presentation only. Wall timings depend on this shared sandbox and concurrent jobs, not phone inference performance.

## Reproduce

From the repository root:

```sh
npm run routing:benchmark -- artifacts/routing/benchmark.json
npm run routing:benchmark -- artifacts/routing/ood.json --ood
python3 tool/routing/analyze.py artifacts/routing/benchmark.json > artifacts/routing/summary.json
python3 tool/routing/render.py artifacts/routing/summary.json > artifacts/routing/summary.md
python3 tool/routing/analyze.py artifacts/routing/ood.json > artifacts/routing/ood-summary.json
python3 tool/routing/fixture.py artifacts/routing/benchmark.json > artifacts/routing/proposed-fixture.json
# Compare proposed-fixture.json with test-fixtures/routing-benchmark.json before changing it.
(cd sim/mesh_sim && dart pub get --enforce-lockfile && dart test test/routing_benchmark_test.dart)
```

**First-capture provenance correction:** the initial harness read `sourceSha` at the *end* of its run. Both retained captures explicitly mark that field's timing; it is not evidence of a clean checkout at start. The baseline TypeScript engine is unchanged from `084e3b5`. The harness and its bounded arms are retained in `6418cd8`/`9b90713` (the latter fixes subsequent runs to capture start HEAD/dirty state). Full configs, traffic protocol, seeds and node version accompany each capture. No claim that the mobile trajectories remain coupled across policies is made; see the research report.

The sample size is exploratory. Nothing in this directory is a model accepted for deployment. No release gates are disabled by the benchmark's reporting-only scenario runs.
