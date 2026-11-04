# Research-led reliability continuation —2026-10-29

Read BASELINE-RECONCILIATION.md, RESEARCH.md, FAILURE-AND-ML.md, PROTOCOL.md,
RESULTS.md and DEPLOYMENT-AND-ROLLBACK.md. Preserve prior studies; do not pool seeds/modes.

- `baseline.json`:12 current-startingHEAD exact replays with bounded per-miss observations,
optimistic temporal closure and full prior statistics equality.
- `reconciliation.json`:raw historical baseline populations and exact arithmetic.
- `research-source.json`:RFC status retrieval and pinned external implementation source.
- `diagnostic-model.json`,`ml-per-world.json`:old-record constant/stump/logistic diagnostic
analysis; exposed audit explicitly not untouched evaluation.
- `local-feature-model.json`:source-snapshot logistic/constant selection locked before
740x; metadata/data SHA, normalization and unsupported live-runtime contract.
- `experiments.json.gz`:70 worlds /10500 synthetic sends, complete per-message outcomes,
pre-send source features, bounded post-send observations, full configs/stats/per-node TX,
source hashes and per-seed seeds/modes. Deterministic gzip mtime0, no filtering.
- `paired-per-seed.csv`,`summary.json`:baseline/epoch/backup, paired CIs and individual
values, resource/regression gates and context-specific descriptive Pareto front.
- `local-ml-evaluation.json`:untouched-at-freeze baseline model evaluation per context/mode.
- `verification.json`,`SHA256SUMS`:exact commits, commands/exits/check scope and integrity.

Use fresh replay directories; commands in deployment guide. Source/checkpoint mismatch
hard-fails, stages freeze the diagnostic model before final outcomes. No human response
or owner approval was assumed. Snapshot reads call no RNG; new-arm diagnostic ON/OFF
invariance has a dedicated regression. RF/jitter still not perfectly packet-paired
between different routing arms; fixed independent motion and traffic streams are paired.

Historical report source manifests refer to their own source revision. Verify old source
using git show at recorded sourceSHA or checkout externally, not by overwriting this
session's branch. New checksums include current source; old report files are unchanged.
