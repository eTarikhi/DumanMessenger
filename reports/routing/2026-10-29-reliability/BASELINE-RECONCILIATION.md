# Historical baseline reconciliation and currentHEAD reproduction

Verified actual startingHEAD **dbd6e83b963b364b9e6de7d42a20a0d8038d7cfa** on target branch,
clean tree, expected origin, fetched without changing branch/worktree. Contrary to the
older final report's uncertainty, GitHub CI **40848112462** and **40848103808** both ran
on that exact HEAD and completed success. The older810cab6 result is not substituted
for this finalHEAD verification. New source/test commit is recorded in new raw rows.

The apparently different baselines are mathematically reconciled, not averaged together:

| Study | Crowd seeds | Always numerator/denominator | Duty numerator/denominator |
|---|---|---:|---:|
| Evolution source709a2ec |3301,3302,3303|359/450=79.7778%|356/450=79.1111%|
| Diagnosis source810cab6 |5301…5306|746/900=82.8889%|745/900=82.7778%|

Exact per-seed values/sourceSHAs retained in reconciliation.json, recomputed directly from
immutable raw evolution runs and gzip diagnosis rows, baseline-only. Both use150 successful
synthetic text sends/world,1500ms spacing,225000ms measured traffic after8000ms warmup,
independent motionseed XOR0x1347, trafficseed XOR0x5bf03635, baseline beacon2000/ACK4000,
canonical unique FIRST destination receipt<=5 hops. No denominator change or pooling.

The evolution report's79.78/80.44 experimental values used mode-dependent **timing**
profiles on330x; the later83.11/83.67 experimental values used **epoch route selection**
on530x. Neither difference is causal progress across reports: both policies and seeds
changed. Candidate comparisons must use their own paired baselines. SourceSHA provenance
also differs; baseline core behavior was unchanged and is tested through exact replay.

CurrentHEAD replay was executed BEFORE engine edits in this mission:12 worlds, crowd330x
both modes and protected2201 each other scenario/mode; every old stats field/five count
matches (baseline.json, sourceSha dbd6e83, captured per-file hashes, exit0). Thus current
baseline is reproducibly79.78/79.11 on330x. This does not mean all new seeds average that.
A separate audit explicitly replays all12 baseline530x worlds with fullstats equality
checks, to verify the82.89/82.78 population too, rather than merely citing old percentages.
The completed audit result is recorded in RESULTS.md; it is not an untouched holdout.

Historical SHA manifests include *historical source file* hashes. New engine research
changes legitimately make `sha256sum` against the newer working tree fail for those source
entries; that is not corrupted raw evidence. Historical analyzer/contract checks now
verify source via `git show <recordedSourceSha>:<path>` instead of assuming old source
must equal current source forever. Old report data/manifests remain untouched. New report
manifest separately checks present source and new evidence. Historical docs' reproduction
commands should be run from their recorded source revision for bit-identical verification.
