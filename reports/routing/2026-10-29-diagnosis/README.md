# Diagnosis-first routing evidence —2026-10-29

Read PROTOCOL.md → FAILURE-ANALYSIS.md → EXPERIMENT-AND-PROMOTION.md.
Decision: **negative, disabled TS-only research candidate, no default change/promotion**.

## Reproduce

Repository root, Node22.22.3/npm10.9.8/TypeScript5.9.3/Python3.11.2:

```sh
npm ci --no-audit --no-fund
./node_modules/.bin/tsc -p tool/tsconfig.golden.json
printf '{"type":"commonjs"}\n' > tool/.build/package.json
# Use NEW output locations, do not overwrite frozen report evidence:
node tool/.build/tool/routing-diagnose.js artifacts/diagnosis-replay
node tool/.build/tool/routing-epoch-experiment.js artifacts/epoch-replay
# Analyze the retained evidence without fitting/running new simulations:
python3 tool/routing/analyze_diagnosis.py reports/routing/2026-10-29-diagnosis
python3 -m unittest discover -s tool/routing -p test_diagnosis.py -v
sha256sum -c reports/routing/2026-10-29-diagnosis/SHA256SUMS
```

Analyzer accepts experiments.json or deterministic gzip archive, verifies per-file source
hashes, pair completeness, diagnostic overflow and replay equality. Its replay input dir
must contain both baseline.json and experiments.json; frozen evidence stores compressed
experiments only. Raw JSON was gzip-compressed with mtime0 after successful completion,
without filtering records. Command exits are retained in verification.json. No resume
logic: use fresh output paths. sourceSha is starting executable commit810cab6; hashes
identify exact implementation including runner and diagnostics. git commit is not a claim
that newer evidence/docs existed at that source SHA. Motion is independent (`seed XOR
0x1347`), trafficPlan uses existing XOR0x5bf03635; RF/jitter draw pairing is imperfect.

## Inventory

- baseline.json:12 exact replay configs, full stats and every missed message's bounded
observations; ideal temporal reachability per miss and aggregate. Its graph closure
samples every physics250ms graph through the final boundary; instantaneous unlimited
copy/hop/lossless carry reachability, explicitly NOT a five-hop score.
- experiments.json.gz:64 worlds, complete configs/stats and150 synthetic per-message
outcomes/observations per world; all32 seed pairs including negative results.
- failure-evidence.json:578 baseline misses (per context/mode, not a pooled performance
population), mutually exclusive strongest-evidence labels plus overlapping tags and
first timestamps. Labels explicitly leave global causality unresolved where needed.
- paired-per-seed.csv:every paired metric, no seed removal.
- summary.json:per-context/mode/split aggregates, seed distributions, t intervals and
screen gates. `unbounded` denotes a zero-baseline positive ratio, not JSON infinity.
- verification.json, SHA256SUMS:commands/exits/toolchains, CI references and file integrity.

The protocol was committed99cabbe before new-seed experiments started; fixture coordinate
correction810cab6 changed only a test. Experiments and final replay both started from810cab6.
Historical65fdd27/80-world evidence is untouched; no benchmark populations were pooled.
