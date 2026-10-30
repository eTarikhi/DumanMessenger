# CI stabilization / simulator performance evidence

## Executive decision: NOT READY — BLOCKED

Discovery is explicitly separated and a measured, state-equivalent optimization is
implemented. The five-second gate is UNCHANGED. It is **not solved**: the paired local
suite improves512pass/10timeouts from510pass/12timeouts, but cannot satisfy staging
acceptance. Exact final push-CI/result/SHA are recorded in the PR3 handoff after execution;
never infer a green run from these independent successes. Native integrations are a
separate roadmap, not a prerequisite invented to hold simulator staging hostage.

## Initial inspection and preservation

Actual PR tip **544f17bb16ed3d440df9b34ef56572e1a3a08e81**, not reported9f5235d. New owner
commits515a743/544f17b add historical captures/change artifact ignore handling, not engine
or test changes. Initial push CI40982630009:8/9jobs pass; web511pass/11timeout failures.
Checks API supplied failure annotations; full-log download hosts remain outside egress.
Read dated29 handoff/security/ledger and exact package/Vite/node:test sources before edits.

Sandbox Git metadata was82d967a while all existing source bytes matched544f17b. Verified
all remote blobs; preserved the sole differing existing file **.gitignore** (owner's local
artifacts-ignore edit). Restored1056 absent remote tracked capture files without replacing
any existing file; repaired only index/ref metadata to actual branch tip. No reset, branch
switch, history rewrite, owner-change discard or historical research rewrite.

## Runner boundaries and unchanged gates

`vitest.config.ts`: only `src/**/__tests__/**/*.test.{ts,tsx}`, explicit5000ms timeout.
`npm run test:deployment`: only `node --test tool/deploy/deployment.checks.mjs` (five tests).
The previous rename had already prevented duplicate discovery; that work was not repeated.
Explicit include prevents future accidental tool/HTTP discovery. Two new tests check the
configuration and independent node:test command. `vitest list --filesOnly`:28source files,
zero tool/HTTP/MJS files. Original26files/522tests retained; five new cases yield527total.
No original tests edited, removed, split, quarantined, moved into fixtures or weakened.
Patched dependencies/lockfile unchanged; no vulnerable downgrade or timeout increase.

## Measurements / diagnosis

Node22.22.3/npm10.9.8/Vitest4.1.12/Linux; V8 CPU sampling enabled identically in both full
runs. Commands:

```
node node_modules/vitest/vitest.mjs run --execArgv=--cpu-prof \
  --execArgv=--cpu-prof-dir=tool/.build/profiles-before \
  --reporter=json --outputFile=tool/.build/before.json
# Same command with profiles-after / after.json after optimization.
```

Python resource.getrusage measured children; `/usr/bin/time` absent. Reusable harness:
`python3 tool/perf/measure-tests.py --label NEW --profile` (refuses overwrite, exits with
actual test status, hashes relevant source and records versions). Raw profiles/logs stay
ignored in tool/.build. Bounded durable evidence: measurements.json, TIMINGS.md,
differential.jsonl. File-scoped CPU samples identify call paths; they are NOT independent
per-test CPU/memory counters. Individual test elapsed times come from Vitest JSON.

| Full original522-test run | Before | After |
|---|---:|---:|
| Wall seconds |375.872|314.626|
| Child user CPU seconds |414.794|355.019|
| Child system CPU seconds |23.495|18.918|
| Maximum child RSS KiB (not sum/concurrent RSS) |444168|497808|
| Pass / fail |510 /12|512 /10|
| Prune self CPU seconds (sampled) |73.68|14.57|

Single paired observation: **16.3% lower wall time**, **80.2% lower pruning self CPU**,
**12.1% higher maximum child RSS**. This memory tradeoff is disclosed, NOT an approved
phone/resource budget or generalized benchmark claim. Sampling/scheduling/GC add noise.
One of the original11 cases (static connectivity) and an additional local normalisation
case clear5000ms; remaining10 exceed it. See TIMINGS.md for ALL original11 individual
names/timings, plus the extra locally reproduced marginal case. JSON timeout stacks use
STACK_TRACE_ERROR; initial CI and focused normal-reporter runs confirm timeout diagnosis.

Call paths for every row (shared paths are intentionally stated, not claimed separate
CPU profiles):
- Three dense acceptance cases: measure → replay → runFor → handleEvent → onOgm/beacon →
acceptOgm → receiveOGM → recordTqSample/tqWindowFor; onScan → pruneStaleEntries/MPR.
The nine-seed case executes9worlds; seed/policy case executes3×3worlds, not runner startup.
- Connectivity/radio comparisons: measured → runFor → onScan/pruning, RF obstacle tests
and airtime/channel events; static versus moving graph changes work, not assertions.
- Two adaptive-scan cases: measured twice (fixed/density) → repeated scans → history
pruning/MPR and OGM reception. Density mode legitimately schedules more scans.
- Dense200node case: scaleRun → runFor → large receipt histories and OGM fan-out, then
routing traffic. Sparse fallback cap/200node/delivery assertions untouched.
- Community-relay case: runArm five times (same seed, different tablet/policy settings)
→ full event engines; cap-aware case: crowdArm four times → warmup/scans/elections.
- Observed-normalisation extra case: six seeded worlds with observedPeerMax RF scans.
- Carrier-preference case: run(false)/run(true), full traffic and DTN queue simulation.

Remaining sampled hotspots after indexing: GC44.10s, receiveOGM33.58s, tqWindowFor23.91s,
MPR22.48s, acceptOgm22.00s, recordTqSample20.98s; geometry still substantial. Algorithmic
work dominates import/startup overhead. Earlier single-worker experiment did not solve
it; not repeated unchanged. Deterministic seeds/configs, event order and test isolation
are retained. No cached/shared test results or cross-test mutable fixture reuse added.

## Evidence-based retained changes and rejected experiments

- `src/tq-history.ts`: insertion-ordered Map subclass with reverse origin/via indexes.
Instead of reparsing/scanning every live receipt key on each scan, prune dead peer/origin
groups. Surviving-key order, key/value identities, receipt windows, expiry and oldest-key
cap remain identical. Indexes contain live keys only; delete/clear remove empty groups.
Storage remains O(live history entries), with the measured constant-memory cost above.
Non-enumerable indexes do not appear in simulation snapshots. Ordinary Map fixtures retain
legacy pruning support. Production native/Dart storage is NOT implemented by this class.
- `src/election.ts`: when origin/via keys are identical, reuse the exact sample already
looked up instead of constructing/looking up the same key again. No metric/tie-break change.
- `src/simulation.ts`: instantiate indexed history; no scheduler/RNG/radio change.
- Rejected and removed: RF corner-allocation/bounding-box prototype (no convincing gain),
nested pair-value index (extra lookup/memory), and traversal duplicate memo (no benefit:
each sender already gossips only once). No speculative cache/default policy shipped.

## Regression / equivalence evidence

Three new indexed-history tests: normal Map mutation/order/value identity,2000seeded
set/overwrite/delete/expiry/clear operations against plain Map pruning, exact2048-key
oldest eviction and released indexes. Combined with boundary2 and crypto93:98pass.

Compiled immutable544f17b source separately, compared against current compiled engine:
`node tool/perf/compare-engines.cjs tool/.build/reference-compiled/src/simulation.js`.
All four scenarios, duty off/on, three successive checkpoints each, plus dense200node
world: complete enumerable simulator/queue/node/Map/Set state matches byte-for-byte and
next16RNG outputs match. No formal all-input proof implied. Shared goldens regenerate
unchanged; historical3301 pair complete stats equal; eight Python evidence/model tests
pass. Historical routing/models/seeds/docs and all src/crypto/package/deployment code have
zero diff from initial544f17b. Dependencies audit0; security regressions93pass; actual
Node socket/security/packaging/corruption/rollback tests5pass.

Independent local checks: typecheck, build, discovery, four static checkers, goldens+clean
diff, differential, baseline replay,8evidence tests,98focused regressions and5HTTP checks
exit0. Dart SDK/browser binaries are absent locally; no unchanged blocked download retry.
Final CI will run pinned authoritative Dart3.13.7, executable compile/help plus a NEW
compiled campus acceptance run (default checks, no --no-check), six CLI jobs and all TS
cases. Full suite failure must remain visible; web artifact upload remains gated.

## Reproducible staging and remaining blockers

```
npm ci --no-audit --no-fund
npm run typecheck
npm test                          # currently FAILS; do not ignore for acceptance
npm run test:deployment
npm audit --audit-level=low
npm run golden
git diff --exit-code -- test-fixtures/golden-vectors.json
npm run build
npm run package:simulator -- tool/.build/staging-NEW
node tool/.build/staging-NEW/serve.mjs tool/.build/staging-NEW
```

Default loopback4173 only. Do NOT expose beyond trusted local environment until operator
TLS/access controls are configured and verified. No host/provider chosen, auth added or
public staging enabled here. No installed interactive browser; HTTP/SSR cannot stand in
for browser/device tests. Existing security headers, traversal/allowlist/integrity and
rollback safeguards remain enforced. Owner .gitignore edit is preserved; local live-tree
package must truthfully report dirty=true, not be called a clean release. Final handoff
records source/manifest/archive checksum and actual local smoke status.

Acceptance still fails (2) all required TS cases under5s and (8) exact-tip green CI.
Further performance engineering is required in receive bookkeeping, allocation/GC, RF
and MPR with complete-state/golden/Dart evidence. This is unfinished engineering, not a
missing credential or a claim that installing Dart would fix TS timing. Moving multi-world
work outside test timers, relaxing thresholds or silently repartitioning the failing
workloads was explicitly not used as a workaround. No assertion/security/CI gate disabled.

Scope: simulator/diagnostic staging only. Native app, adapters, production identity/key
management, durable encrypted store and devices are missing; detailed prioritized roadmap
is docs/19-native-integration-roadmap.md. Those gaps and >90% routing research remain
separate from the current simulator timing gate. No public release or PR merge performed.
