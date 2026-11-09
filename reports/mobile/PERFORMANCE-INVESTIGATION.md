# TypeScript timeout and performance investigation

**Run date:** 2026-11-05
**Source provenance:** `a1f1916981c2244a2f8664573b66afbd5a2659b4`, empty checkpoint over `bdf719cf88205f944187cb79b8288264a56c13bd`
**Disposition:** All ten callbacks reproducibly exceed the unchanged 5,000 ms budget; their synchronous simulation work explains the timeout trigger. Representative source-equivalent profiles identify shared OGM/TQ-history, RF geometry, MPR/pruning, and GC work, but do not prove one function causes every case. See [TIMEOUT-ROOT-CAUSE.md](TIMEOUT-ROOT-CAUSE.md). **No safe semantic-preserving optimization was justified; source, tests, timeout, routing defaults, and semantics remain unchanged.**

## 1. Constraints and baseline

The owner-directed constraints for this investigation were followed:

- Do not change the 5,000 ms test timeout.
- Do not skip, weaken, delete, or remove assertions/tests from the complete suite.
- Do not alter production routing defaults, simulator semantics, thresholds, or golden vectors.
- Only implement a demonstrably equivalent optimization with regression coverage; if not established, leave code unchanged.
- Do not use simulator evidence as Android/iOS, emulator, or physical-device evidence.

The full local Vitest baseline remains **517/527 passing, ten failures, all `Test timed out in 5000ms`**, at the unchanged timeout. Full-suite duration was 315.66 seconds. The ten names and full commands are recorded in [TEST-RESULTS.md](TEST-RESULTS.md). The suite did not skip tests. A separate diagnostic run intentionally selected those ten tests; it is not a replacement for or pass of the full suite.

## 2. Host and contention evidence

- Linux `6.1.158+`, `x86_64`; Node `v22.22.3`; npm `10.9.8`.
- `nproc` reported 2. `/sys/fs/cgroup/cpu.max` and `memory.max` were unavailable, so exact cgroup CPU/memory limits were not established.
- A sampled load-average check after the suite was low (`0.01 0.45 0.42`); it was not a time series during the test run and cannot exclude transient contention.
- A focused rerun selected all ten timed-out cases with `--maxWorkers=1` and the existing default 5,000 ms limit. Result: all ten timed out again; Vitest reported 10 failed and 200 not-selected/skipped in that **diagnostic-only filtered invocation**, 202.96 seconds test time and 217.23 seconds overall. The repository tests/configuration were not modified. This shows that concurrent Vitest workers are not the only plausible contributor; it does not establish that scheduling/contention has no effect.
- No full-run CPU, memory, scheduler, or worker-pool trace was collected. The remaining nine failures have not each received an isolated CPU profile. Their root causes and relative costs are not established.

A focused `--cpu-prof` Vitest attempt profiled a mostly idle V8/Vitest driver rather than the test worker; it was not useful for locating test hotspots. An attempted `/usr/bin/time -v` run did not start because `/usr/bin/time` is absent.

## 3. Focused 200-node scale workload

The scale test in `src/__tests__/simulation.test.ts` exercises the upper end of the 10–200-node range. Source inspection confirms a 200-node run with warmup, six message sends and 1,500 ms simulation windows, refresh, then delivery/transmission/peer assertions.

- Focused Vitest filter for this one test: test body reported 15.40 seconds and timed out at 5,000 ms; filtered run total was 16.25 seconds. The filter selected only this test; other tests were not changed.
- A temporary esbuild bundle replicating the workload (outside the repository; no source file added) completed in **14,843.4 ms**. It reported 200 nodes, six sends/deliveries, 12 transmissions, and maximum 193 peers. The final process snapshot was RSS 387.8 MiB and heap used 171 MiB; this is **not a peak-memory measurement** and not a profile of the Vitest worker.
- A direct Node/V8 CPU profile of that temporary bundle sampled approximately 14.87 seconds at 1 ms intervals. Approximate sampled self-time leaders:

| Sampled function/area | Approx. sampled self time |
|---|---:|
| `receiveOGM` | 2,076 ms |
| `tqWindowFor` | 1,947 ms |
| `recordTqSample` | 1,829 ms |
| garbage collection | 1,827 ms |
| `acceptOgm` | 1,167 ms |
| `segmentsIntersect` | 1,094 ms |
| `TqHistory.add` | 829 ms |
| `rssiModel` | 795 ms |
| `selectMprSet` | 699 ms |
| `pruneStaleEntries` | 480 ms |
| `peersInRange` | 392 ms |

These are profiler sample estimates for the replicated 200-node workload, not exact wall-time attribution or a measure of all ten tests. The result points to repeated OGM/link-quality history work, garbage collection, and dense radio geometry/MPR work. It corroborates that this workload is compute-heavy. It does **not** prove that CPU contention, worker scheduling, or any single function causes all ten timeouts.

## 4. Workload/code-path review

Source inspection of the affected tests and `src/simulation.ts`, `src/routing.ts`, `src/rf.ts`, `src/election.ts`, and `src/tq-history.ts` found several repeated-simulation shapes:

- Dense acceptance cases use 60-node crowd scenarios, multi-seed runs, 150-message runs, and comparisons among primary/MPR or flood arms.
- Radio occupancy compares dense scenarios under contention and delivery measurements.
- Scan-interval cases perform warmup and message windows across fixed/adaptive configurations.
- Simulation cases include the 200-node upper range and repeated community-relay/cap/promotion variants.
- The direct scale profile points to repeated OGM acceptance, per-link TQ-window/sample maintenance and pruning, and pairwise/dense radio calculations (`rssiModel`, wall-segment intersection, peers-in-range), with allocation/GC overhead. MPR selection and stale-entry pruning are also visible.

This is consistent with repeated dense-network work and possible quadratic pairwise geometry/neighbor processing, but no whole-suite complexity proof or line-by-line per-failure profile was performed. The test named “fallback does not go quadratic” does not by itself establish that the fallback routine is the dominant hotspot; the sampled profile includes several routing and RF paths.

## 5. Optimization assessment

No candidate met the required standard of demonstrated semantic equivalence plus regression coverage within this milestone:

- Replacing/restructuring TQ history storage or its map keying could change ordering, exposed state, checkpoint/golden behavior, allocation, or TypeScript/Dart parity. Existing `TqHistory` tests compare its behavior with a plain `Map`; no behavior-preserving replacement was proved.
- Caching RF/range/wall-crossing results could be stale when positions, obstacles, or simulation time change and could alter routing decisions. No cache key/invalidation proof and cross-language parity test were established.
- Changing OGM cadence, fan-out, MPR selection, message schedule, test workload, TTL, test concurrency, timeout, or routing defaults would change semantics or evidence and is outside the constraints.
- Increasing the timeout, reducing seeds/messages, skipping slow tests, or replacing assertions would mask rather than resolve the baseline issue and was not done.

**Decision: no source or test change.** The current code, test files, Vitest config, 5,000 ms limit, routing defaults, semantics, and goldens are unchanged.

## 6. Evidence needed for a follow-up

On an owner-authorized, supported host, collect per-case worker CPU profiles for each of the ten tests and record Node/Vitest versions, CPU quota, worker count, memory peak, and host load during each run. Use repeatable single-case and full-suite runs at the existing timeout. Before any optimization, identify a transformation that preserves exact simulator outputs and TypeScript/Dart parity, add focused regression/equivalence tests, and compare both wall time and output/golden behavior. A follow-up must not claim all ten are solved based on the 200-node profile alone.

The 517/527 test result remains a failed baseline. No routing/reliability target, five-hop delivery claim, or mobile performance result is established by this investigation.

## Milestone 3 follow-up — per-case timings and representative profiles

A second focused comparison recorded Vitest JSON durations for all ten selected failures, with the same test pattern under the default worker pool and `--maxWorkers=1`. Every case still failed with `Test timed out in 5000ms`; measured callback bodies took 5.79–59.65 s in the single-worker run and 6.37–57.41 s in the default-pool run. Vitest's synchronous callback wrapper checks elapsed time on return, so CPU-heavy `runFor` loops are not preempted at five seconds. The runs show no consistent single-worker advantage.

Temporary source-equivalent CPU-profile harnesses now cover the 9-seed acceptance workload, 3-seed MPR arms, radio occupancy, scan intervals, community relays, cap/election, DTN preference, and the 200-node case. The direct profiles repeatedly show OGM reception/TQ-history maintenance, RF geometry, election/pruning, and GC. They are **not Vitest-worker profiles** and do not isolate every assertion. Per-test command, location, configuration, duration, repeatability, profile coverage, and remaining uncertainty are recorded in [TIMEOUT-ROOT-CAUSE.md](TIMEOUT-ROOT-CAUSE.md).

The complete suite was not rerun as part of this focused comparison; the complete baseline remains the earlier 517/527 run. The focused runs selected ten target tests and reported other tests as not selected; the full suite itself was not weakened or skipped.
