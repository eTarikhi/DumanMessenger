# TypeScript timeout root-cause investigation

**Investigation date:** 2026-11-05
**Source:** `a1f1916981c2244a2f8664573b66afbd5a2659b4` (empty checkpoint over `bdf719cf88205f944187cb79b8288264a56c13bd`)
**Disposition:** All ten tests reproducibly exceed the unchanged 5,000 ms wall-time budget. Their test bodies are synchronous simulation work; Vitest reports timeout after the callback returns over budget. Representative source-equivalent profiles show dense simulation work, TQ/OGM processing, RF geometry, and GC. **No safe equivalent optimization was established; code, tests, routing defaults, timeout, and vectors are unchanged.**

## 1. Commands and evidence

### Existing full-suite baseline

`npm test -- --reporter=verbose` completed with **517/527 passing, ten `Test timed out in 5000ms` failures**, duration 315.66 seconds. It ran with the repository's default Vitest worker configuration. The timeout remains `testTimeout: 5000` in `vitest.config.ts:7`.

### Focused comparison runs

To record per-test timings, the same ten names were selected from the same four files with the default 5,000 ms setting. These are diagnostic selections only; neither invocation changes a test or replaces the complete suite result.

- **Default-worker diagnostic:** `vitest run <four files> --reporter=json --outputFile=/tmp/duman-m3-ten-default.json -t '<ten-name pattern>'`. No explicit `--maxWorkers` was set. Tool wall time: **208.341 s**. JSON: 210 discovered, 10 failed, 200 not selected. All ten exact failures were timeouts.
- **Single-worker diagnostic:** same files and name pattern with `--maxWorkers=1`, JSON output `/tmp/duman-m3-ten-results.json`. Tool wall time: **213.388 s**. JSON: 210 discovered, 10 failed, 200 not selected. All ten exact failures were timeouts.
- A preceding single-worker filtered run also failed all ten (217.23 s overall; 202.96 s reported test time). Thus each target timed out in the complete default run, a focused default run, and two focused single-worker runs. The failures are reproducible across these runs; exact elapsed time varies.

The filtered JSON `assertionResults.duration` values are the measured synchronous test-body durations, not a changed timeout. The package implementation at `node_modules/@vitest/runner/dist/chunk-artifact.js` wraps the callback in `withTimeout` and checks elapsed time again when a synchronous callback returns; the test is rejected if elapsed time is at least 5,000 ms. `MeshSimulation.runFor` and these test bodies execute synchronously, so the runner cannot preempt the CPU loop at exactly 5 seconds. This explains why the reported test-body duration can be much greater than 5,000 ms while the failure still says `Test timed out in 5000ms`.

## 2. Per-test diagnostics

Times below are milliseconds from Vitest's JSON reporter: **default pool / `--maxWorkers=1`**. Each invocation used the unmodified 5,000 ms timeout. “Direct profile” refers to a separate temporary esbuild/Node harness that replicated the named test workload; it is not a Vitest worker profile and included no new repository source.

| # | Test and source location | Workload/configuration | Default / single duration | Determinism and exact failure | Profile / likely dominant work |
|---:|---|---|---:|---|---|
| 1 | `acceptance.test.ts:257` — `stays stable and cheap at 60 nodes` | `festivalCrowd(42)`, 60 nodes; one 150-message run with 1,500 ms gaps plus `flood-all` and `route-flood` comparison arms: three dense runs total. | **18,141 / 19,901** | Fixed seed; timeout in full and every focused run. Exact failure: `Test timed out in 5000ms.` | Same `measure`/three-arm workload profiled in the 3-seed MPR harness. OGM/TQ-history, GC, RF geometry, peer/MPR selection. This exact one-seed case was not separately profiled. |
| 2 | `acceptance.test.ts:266` — `holds its delivery bar on seeds the gate above does not use` | Nine 60-node `festivalCrowd` seeds; one `measure(..., false)` run per seed, 150 messages with 1,500 ms gaps: 1,350 planned sends across nine runs. | **51,668 / 55,568** | Fixed seed list; timeout in full and every focused run. Exact failure as above. | Direct 9-seed workload profile: GC, `receiveOGM`, `countWallCrossings`/`rssiModel`/`segmentsIntersect`, `recordTqSample`, `tqWindowFor`, MPR selection, pruning. |
| 3 | `acceptance.test.ts:300` — `costs MPR nothing against the same engine without suppression` | Three 60-node seeds; each `measure` runs primary, `flood-all`, and `route-flood` arms, 150-message plan per arm: nine simulation runs. | **57,409 / 59,647** | Fixed seeds and identical traffic plans; timeout in full and every focused run. Exact failure as above. | Direct 3-seed/3-arm workload profile: GC (~10.2 s sampled), `receiveOGM`, `segmentsIntersect`, TQ history, `rssiModel`, `selectMprSet`, `peersInRange`, OGM acceptance/pruning. |
| 4 | `radio-occupancy.test.ts:195` — `costs a dense crowd fewer deferrals and buys it delivery, once contention is modelled` | Two 60-node `festivalCrowd(42)` simulations; each has 90 s simulated warmup, 30 injected messages over 40 s, then 60 s simulated run; CSMA with hop-latency versus airtime occupancy. | **7,392 / 7,367** | Fixed seed/configs; timeout in full and all focused runs. Exact failure as above. | Direct two-arm profile (~6.66 s): GC, OGM/TQ history, `rssiModel`, `segmentsIntersect`, MPR and stale-entry pruning. No evidence the contention queue alone is dominant. |
| 5 | `scan-interval.test.ts:50` — `scans more in a dense world, which is what the row says and what it costs` | Two 60-node `festivalCrowd(42)` runs, fixed versus density scan interval; each warms 90 s, injects 30 messages over 40 s, then runs 60 s. | **8,745 / 7,129** | Fixed seed; timeout in full and all focused runs. Exact failure as above. | Direct two-mode profile (~8.55 s): GC, `countWallCrossings`/`orient`, OGM/TQ-history, MPR and stale-entry work; scan scheduling also appears. |
| 6 | `scan-interval.test.ts:71` — `clamps, so one peer does not stop a node scanning and a crowd does not pin it awake` | Same fixed/adaptive dense-crowd helper and two 60-node simulations as test 5; checks scan-rate bounds. | **8,308 / 6,801** | Fixed seed; timeout in full and all focused runs. Exact failure as above. | Same direct scan-helper profile as test 5. The individual assertion body was not separately profiled; it uses the same helper/workload. |
| 7 | `simulation.test.ts:771` — `runs at the top of the range, and the fallback does not go quadratic` | One 200-node `campusQuad(42)` in 100×100 m; warmup, six sends with 1,500 ms windows, refresh and peer/delivery/transmission assertions. | **14,039 / 13,895** | Fixed seed; timeout in full and all focused runs. Exact failure as above. | Direct scale profile (14.84 s) and profile: `receiveOGM`, `tqWindowFor`, `recordTqSample`, GC, `acceptOgm`, `segmentsIntersect`, `rssiModel`, `selectMprSet`, pruning and `peersInRange`. Not a Vitest-worker profile. |
| 8 | `simulation.test.ts:2104` — `elects the plugged tablets and moves relay work off other people's batteries` | Five 60-node seed-42 crowd arms (MPR/flood, zero/three/six relays); each warms 20 s, then plans 100 messages at 1 s gaps. | **14,664 / 14,429** | Fixed seed/plan; timeout in full and all focused runs. Exact failure as above. | Direct five-arm profile (~14.81 s): GC, OGM, TQ history, RF geometry, MPR selection, route pruning and message receive. |
| 9 | `simulation.test.ts:2771` — `exempting tablets from the cap elects all six and pushes the ratio to the top of the band` | Four 60-node seed-42 `crowdArm` evaluations (six tablets with/without quota, three with/without quota); each runs 20 s warmup plus 60 s election/simulation; no application traffic. | **6,368 / 5,787** | Fixed seed/config; timeout in full and all focused runs. Exact failure as above. | Direct four-arm profile (~6.31 s): GC, `receiveOGM`, `selectMprSet`, RF geometry, TQ windows/samples, stale-route pruning. The direct harness omits some post-run result formatting; it profiles the dominant simulation loop. |
| 10 | `simulation.test.ts:2995` — `and that is where the benefit stops: the bundle waits on a node that never moves` | Two 60-node seed-42 festival-crowd runs (preference off/on); 20 s warmup, choose six high-peer positions, 40 messages at 1 s gaps, then 120 s simulated store/carry wait. | **7,402 / 7,108** | Fixed seed and message plan; timeout in full and all focused runs. Exact failure as above. | Direct two-arm profile (~9.16 s with profiler): GC, `countWallCrossings`, `receiveOGM`, MPR, TQ-history, `rssiModel`/geometry and pruning. The profiled harness copied the workload and is not a Vitest worker. |

### What the per-test durations show

All ten JSON-reported callback durations exceed 5,000 ms in both configurations. In the focused default run they range from **6.37 s to 57.41 s**; with one worker, **5.79 s to 59.65 s**. Default versus single-worker times are close for the radio and simulation cases and vary in opposite directions for the scan cases and acceptance tests. Removing worker parallelism does not bring any case near 5 seconds. The two-CPU host may affect absolute timings, but worker contention is not a sufficient explanation.

The test inputs use explicit seeds and deterministic traffic generators. Failures repeat across the full suite and focused runs; durations vary with execution conditions. This establishes repeatable over-budget behavior, not bit-for-bit runtime determinism or universal timing on other hosts.

## 3. Representative direct CPU profiles

The following temporary harnesses bundled current repository simulation/scenario functions with workload loops copied from the tests, then used Node V8 `--cpu-prof --cpu-prof-interval=1000`. They were run outside the repository; no source files or test assertions were changed. These profiles characterize the synchronous simulator workloads, not Vitest worker scheduling and not every individual test.

| Workload replica | Wall time under profiler | Leading approximate sampled self-time areas |
|---|---:|---|
| 3-seed acceptance MPR arms | 58.42 s | GC 10.2 s; `receiveOGM` 5.85 s; `segmentsIntersect` 4.57 s; `recordTqSample` 4.14 s; `tqWindowFor` 3.89 s; `rssiModel` 3.74 s; `selectMprSet` 3.68 s; `peersInRange` 3.28 s; OGM acceptance/pruning. |
| 9-seed acceptance delivery arms | 55.75 s | GC 9.06 s; `receiveOGM` 5.66 s; `countWallCrossings` 4.53 s; TQ sample/window 7.74 s combined; MPR selection 3.51 s; `rssiModel` 3.22 s; route pruning/geometry. |
| Radio-occupancy two-arm workload | 6.66 s | GC 1.07 s; `receiveOGM` 0.78 s; `rssiModel` 0.62 s; MPR, TQ, `segmentsIntersect`, `acceptOgm`, route pruning. |
| Scan-interval two-mode workload | 8.55 s | GC 1.22 s; `countWallCrossings` 0.88 s; `receiveOGM` 0.88 s; MPR 0.75 s; TQ samples/windows and RF geometry. |
| 200-node scale replica | 14.84 s | `receiveOGM` 2.08 s; `tqWindowFor` 1.95 s; `recordTqSample` 1.83 s; GC 1.83 s; `acceptOgm` 1.17 s; `segmentsIntersect` 1.09 s; `rssiModel` 0.80 s; MPR/pruning/peer search. |
| Five-arm community-relay workload | 14.81 s | GC 2.16 s; `receiveOGM` 1.51 s; `rssiModel` 1.40 s; MPR 1.07 s; geometry and TQ history. |
| Four-arm cap/election workload | 6.31 s | GC 0.84 s; `receiveOGM` 0.67 s; MPR 0.60 s; geometry and TQ history. |
| Two-arm DTN/community preference workload | 9.16 s | GC 1.47 s; `countWallCrossings` 0.98 s; `receiveOGM` 0.92 s; MPR/TQ/RF geometry and pruning. |

Times are approximate V8 sample estimates at a 1 ms interval, not exact mutually exclusive CPU accounting. Final RSS/heap readings from temporary processes are not peak memory; no reliable per-test peak-memory measurement was taken. The profiles repeatedly identify OGM/link-quality history, dense radio geometry, election/pruning, and GC. They do not prove that a particular one of these functions alone causes each timeout.

## 4. Contention, algorithms, memory, and scheduling

- **Compute:** Simulation scenarios advance virtual time by processing many synchronous events. Dense 60-node cases repeatedly calculate radio reach, wall intersections, RSSI, OGM reception/acceptance, TQ history, MPR sets, and pruning. Repeating the same world across seeds/arms multiplies this work. The 200-node case increases pairwise geometry and neighbor/OGM activity.
- **Scheduling:** `runFor` and the test callbacks are synchronous. The installed Vitest timeout wrapper checks callback elapsed time when the synchronous callback returns; it cannot interrupt the CPU loop at the 5-second mark. This explains why reported durations are much longer than the configured budget and still end as timeouts. The routines are not awaiting a stuck external service.
- **Contention:** Host `nproc` is 2; cgroup `cpu.max`/`memory.max` were unavailable. Default and explicit single-worker test-body timings are similar, with no consistent single-worker advantage. There was no time-series host contention trace, so transient CPU contention cannot be excluded, but it is not the primary demonstrated cause.
- **Memory/GC:** Multiple direct profiles spend meaningful sampled time in garbage collection. Dense simulation and repeated temporary state/history allocations are plausible contributors. Only final process snapshots were available; peak heap/RSS by test and allocation-site attribution remain unmeasured.
- **Algorithmic diagnosis:** The exact callback work is known per test. Direct profiles of representative test-equivalent workloads repeatedly highlight shared RF/OGM/TQ/MPR paths. The root contribution is not separately isolated for each assertion or every individual test; the table explicitly identifies which profiles are shared replicas.

## 5. Root-cause conclusions by case

1. **All ten:** confirmed direct trigger is synchronous test-body duration exceeding 5 seconds, not an assertion failure, and not an unresolved asynchronous wait. All ten timed out repeatedly under both default and single-worker execution.
2. **Acceptance (three cases):** repeated 60-node simulation arms and seed count dominate; direct profiles of the 3-seed comparison and 9-seed workload show shared OGM/TQ/RF/MPR and GC cost. The one-seed case is not separately profiled, but runs the same `measure` helper.
3. **Radio and scan (three cases):** repeated 60-node warmup plus traffic windows dominate; their test-equivalent profiles show OGM/TQ/RF/election and GC. The radio contention branch adds event/deferral work but is not the only shared cost.
4. **200-node scale:** the direct replica itself takes 14.84 seconds, independently exceeding the configured budget; the 200-node profile shows OGM/TQ/geometry/GC. Worker contention cannot explain this result alone.
5. **Community-relay and cap/election:** repeated 60-node warmups/elections and relay arms cause the measured over-budget work; direct profiles show the same simulation hotspots. The cap case has no application traffic but still performs repeated dense-world election/simulation.
6. **DTN preference:** two dense 60-node warmup/message/store-carry runs exceed budget; direct profile shows common RF/OGM/TQ/MPR/GC work, not only carrier-queue logic.

No claim is made that every hot function is algorithmically quadratic in every scenario, or that one algorithmic rewrite would be safe.

## 6. Optimization decision and next evidence

No source change was made. Potential changes to TQ storage/keying, RF caching, OGM cadence, MPR fan-out/election, event scheduling, or allocations can change observable simulation outputs, stale-state behavior, ordering, memory use, or TypeScript/Dart parity. No candidate optimization was proven equivalent and regression-tested. Increasing the timeout, altering seeds/message counts/assertions, changing routing defaults, or editing goldens remains disallowed.

A future optimization proposal must identify an exact behavior-preserving transformation, add focused equivalence/regression coverage, preserve all existing seeds/assertions/vectors, and show before/after test-body profiles and full-suite results at the same 5,000 ms limit on an owner-approved host. No remote CI was run or requested. See [PERFORMANCE-INVESTIGATION.md](PERFORMANCE-INVESTIGATION.md) for the earlier baseline/profile context.
