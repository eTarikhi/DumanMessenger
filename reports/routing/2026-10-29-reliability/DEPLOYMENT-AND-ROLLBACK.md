# Supported execution and deployment boundary

**No production promotion is authorized.** Experimental research profiles cannot be
selected by a live RoutingSelector model. Dart remains authoritative and has neither
experimental epoch nor backup profile. There is no actual phone cohort/native adapter
in this mission. Passing existing Dart tests is not new-profile validation.

## Reproduce offline without touching frozen reports

```sh
./node_modules/.bin/tsc -p tool/tsconfig.golden.json
printf '{"type":"commonjs"}\n' > tool/.build/package.json
node tool/.build/tool/routing-reliability.js artifacts/reliability-replay development
python3 tool/routing/reliability_local_ml.py artifacts/reliability-replay freeze
node tool/.build/tool/routing-reliability.js artifacts/reliability-replay final
python3 tool/routing/reliability_local_ml.py artifacts/reliability-replay evaluate
python3 tool/routing/analyze_reliability.py artifacts/reliability-replay
```

One explicit constructor flag selects the offline arm:

```ts
new MeshSimulation(config, undefined, motionSeed, diagnostics, 'source-backup-v1');
// Immediate baseline rollback: construct a new baseline session, not in-flight switching.
new MeshSimulation(config, undefined, motionSeed); // default profile is baseline
```

Profiles are finite registered IDs, fixed per run; unknown IDs throw at construction.
No arbitrary executable/config thresholds from model output; no online learning or cloud
routing dependency. Runtime selector still applies baseline for all recommendations,
including canary mode, pending approval. Existing artifact parser rejects these research
profile/model descriptions (wrong schema/output IDs); their checksums are integrity
records, NOT a loader permission or app deployment package.

## Stage gates and fallback

1. **Offline** only now. Outcome and source/config/data SHA256 in raw archive/manifests.
Diagnostic ML weights/preprocessing/data hash are packaged for Python evaluation only,
marked liveEligible=false. Model selection predicts failure, not action advantage.
2. **Shadow**, future: expose source-local finite/fresh features without user content,
freeze compatible model, record proposals without routing changes, verify full ON/OFF
invariance and drift diagnostics. AUC or shadow decisions alone do not prove delivery.
3. **Opt-in canary**, future BLOCKED: needs winning deterministic policies, authoritative
Dart parity plus shared route/retry/DTN/radio goldens and actual native adapter/cohort.
Existing selector has low-confidence/invalid/stale/OOD/power override,3-vote hysteresis,
30s dwell,4-switch cap, and fault/rollback latch. Those safeguards are not claimed to
actuate or validate the new profile; candidate-specific fallback/cost-budget tests are
required before registration. Invalid profile fails closed to caller error; production
remains independent baseline, not a new fallback-capable deployed engine.
4. **Promotion**, BLOCKED: owner-approved cost/regression tolerances, robust unseen
both-mode target, protected performance, real-device battery/latency, review approval.
No automatic promotion after a positive offline mean or a small Pareto screen.

Keep baseline artifact selectable independently, log no message contents, reject unknown
model/version/policy, require feature freshness/finite values, enforce hard protocol and
power/cap rules outside ML. A real integration must map load/inference/resource errors
to session-latched baseline, with no learned-code execution and no default online update.

## Owner action list

- Agree explicit non-inferiority tolerances and permitted data/control airtime, p95,
queue, fairness, energy/CPU/memory budgets;5%/10% screen is a proposal, not approval.
- Decide if future investment should target directional link telemetry, coverage age,
MAC realism, contact feasibility or adapter/hardware first. Existing temporal oracle
is optimistic unlimited-hop, never the product score.
- Approve source/wire-format/Dart work and devices/cohort for any successful candidate.
- Agree a variance-powered new seed count/protocol after discovery. All330x/430x/530x/
630x/740x/7501 outcomes used here are exposed after this report, not future holdout.
- Online learning, real-user data, new services/dependencies or costs need separate
explicit consent. None were needed or introduced here.
