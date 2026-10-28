# 15 — Evolutionary learning toward more than 90% five-hop delivery

Date: 2026-10-28. **Outcome: target NOT achieved on unseen crowd seeds. Default unchanged.**

## What was actually tested

Continued from709a2ec, not from historical0082fd5. The sandbox had restored session files but
rolled local Git metadata back to82d967a. Fetched origin, compared the engine, and repaired
index/branch-ref metadata without resetting the worktree or discarding files. The tree then
matched709a2ec exactly. All work remains on arena/ff85cb12-dumanmessenger; no main merge.

[Predeclared protocol](../reports/routing/2026-10-28-evolution/PROTOCOL.md) fixed an **80-world**
budget, training/validation/final seed splits and target before final evaluation. The primary
stretch target is **strictly >90% on every final crowd seed and both power contexts**, not one
favorable run or a pooled average. Existing campus acceptance remains unchanged; it already
exceeded90%. Sparse/partitioned traffic is never removed from the sent denominator.

The learning method is **bounded evolutionary parameter optimization**, not a neural network:

1. Evaluate baseline and beacon intervals1000/3000/5000ms with baseline ACK4000ms.
2. Select the strongest parent per user power context using worst training-seed five-hop
   ratio, then mean, then lower relay count.
3. Mutate each parent with ACK3000/6000ms. Evaluate all unique children on both train seeds
   and both power contexts. Eight profiles total were evaluated.
4. Freeze a two-context policy and SHA256 before any validation/final selection. Only feature:
   configured user power mode. No seed/scenario oracle or future delivery enters selection.
5. Evaluate frozen profiles versus regenerated baseline on validation and final seeds, plus
   protected campus/sparse/partitioned scenarios. No refit, threshold change or repeat-until-
   significant final evaluation.

Training1101/1102; validation2201/2202/2203; final3301/3302/3303. Protected scenarios use2201/2202.
Common independent motion seed is `seed XOR 0x1347`; loss/jitter event streams still depend on
policy. These regenerated paired worlds must not be pooled with the old default-RNG trajectories.
The source/hash/config and motion seed are retained per experiment, with resumable checkpoints.
The capture used runner revision84f26b1; a later provenance-only fix preserves initial source
HEAD during future same-code resumes. Old captures refuse changed-code resumes by design.

All profiles keep MPR, packet TTL, max retries, RF range, duty-cycle window and traffic intact.
Metric semantics are unchanged:150 planned text unicasts, successful sends as denominator,
unique destination deliveries with successful-copy hops<=5 as numerator, ACK/broadcast excluded,
retries and DTN included,1500ms gaps, no extra drain. Source retries reset the copy's hop counter
as before; lifetime radio work is accounted separately. No late/carry delivery is relabelled a
five-hop success. Queued/undelivered copies are not falsely called expired seven-day bundles.

## Learned configuration and held-out outcome

The frozen policy selected:

| User power context | Beacon interval | Text ACK timeout |
|---|---:|---:|
| Always-on | 3000ms | 6000ms |
| Duty-cycle | 1000ms | 3000ms |

This is an **offline experimental artifact**, not an approved live-selector model. It cannot
be loaded as a production-approved API1 decision stump; a regression test explicitly verifies
rejection. No runtime registry/default or model activation gate was changed.

| Set | Power | Baseline five-hop % | Learned five-hop % | Worst learned seed % | Paired difference, 95% seed t interval (points) |
|---|---|---:|---:|---:|---|
| Validation | Always | 69.33 | 71.11 | 60.67 | +1.78 [-4.04,+7.59] |
| Validation | Duty | 69.11 | 70.89 | 57.33 | +1.78 [-8.74,+12.30] |
| Final holdout | Always | 79.78 | 79.78 | 78.00 | 0.00 [-8.28,+8.28] |
| Final holdout | Duty | 79.11 | 80.44 | 78.67 | +1.33 [-4.64,+7.30] |

Intervals are exploratory, unadjusted paired intervals over three **seeds**, not independent
packets. They do not establish an improvement. The policy was not modified using these results.
The final >90% target therefore **failed**, despite small mean improvements in some contexts.

Protected campus measurements reached **100%** in both power modes (baseline99.33% always,
99.67% duty). This is real, but claiming it solved the crowd target would be misleading.
Sparse/partitioned ratios remained unchanged (means26.67%/45.00%); their lower scores remain
visible, not hidden inside a dense-network average.

## Resource costs and safety

A higher score is not free. On final seeds the learned policy increased total node transmissions
by up to **5.39% always / 5.67% duty** and relay transmissions by up to **2114 / 2318** per window.
The worst paired p95 latency increase was **8.33s / 42.60s** respectively. Even a tiny five-hop
mean gain would not justify silent approval of those costs. [Per-seed CSV](../reports/routing/2026-10-28-evolution/per-seed.csv)
and [summary](../reports/routing/2026-10-28-evolution/summary.json) retain overall/three-hop delivery,
hop mean/p95, relay/control/total transmission counts, retries/exhaustion, queue/undelivered,
role changes, radio demand and both battery estimates. No owner resource budget was increased.

Both learned choices fail a robust promotion decision. Existing release criteria, owner-approved
non-inferiority tolerances, protocol timing review, authoritative Dart evaluation of these new
profiles and real-device validation remain outstanding. The existing shadow controller still
applies baseline only; online learning remains disabled.

## Contact-bound diagnostic: not another delivery score

A separate optimistic temporal-contact calculation observed every250ms physics graph on the
same independent movement, retained carriers across partitions, and allowed unlimited copies,
unlimited hops, zero loss and zero latency. On seeds1102 and2203 it found all150 pairs
optimistically reachable. **That100% is NOT a measured five-hop delivery ratio.** It is only
an upper bound. It neither proves the90% five-hop target achievable nor proves it impossible.
It prevents wrongly claiming this bounded negative search established physical infeasibility.
The contact-closure helper has tests for carry through splits and unreachable components.

The next justified research direction is bounded route/path-cost or relay-choice learning with
local information and replayed exogenous contacts/loss, rather than repeatedly testing timer
settings on final seeds until one happens to pass. Changing range, hops, traffic or denominator
would not solve this task honestly. Arbitrary deep-model complexity is not evidence of a gain.

## Reproduction, verification, and evidence

```sh
npm ci --no-audit --no-fund
npx tsc -p tool/tsconfig.golden.json
node -e "require('fs').writeFileSync('tool/.build/package.json','{\"type\":\"commonjs\"}')"
node tool/.build/tool/routing-evolve.js artifacts/evolution-new
python3 tool/routing/analyze_evolution.py artifacts/evolution-new
# Same compiled-source/toolchain checkpoint: resume the same command after interruption.
node tool/.build/tool/routing-contact-bound.js 1102 festival_crowd artifacts/contact-bound.json
npx vitest run src/__tests__/routing-contact-bound.test.ts src/__tests__/routing-learning-artifact.test.ts
python3 -m unittest discover -s tool/routing -p 'test_*.py'
```

Use a new output directory; do not overwrite frozen dated evidence. Nodev22.22.3; dependencies
installed with npm ci. No new package, paid training service, private traffic or model dependency.
The search and two contact bounds ran successfully; all80 rows passed sent/duplicate assertions.
Tool compilation/typecheck and five new targeted regression tests passed; seven Python tests
passed. CI40676513246 at84f26b1 passed9/9 jobs (TypeScript506 tests; existing Dart suite remains
separate from new-profile measurements). The final artifact-consistency tests add three tests;
their final-tree CI status is recorded in the verification file rather than assumed from that run.

Local Dart is unavailable. New profile outcomes have **not** been run in authoritative Dart.
No deployment or positive generalized learned-routing result is claimed. Full inputs, raw results,
frozen policy/hash and verification are in [the dated evidence folder](../reports/routing/2026-10-28-evolution/).
The target remains open; finite learning experiments cannot honestly guarantee90% for every
network condition. No model is promoted merely to satisfy a requested stopping score.
