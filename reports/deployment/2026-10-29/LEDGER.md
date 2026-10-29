# Independent milestones — completion ledger

This ledger separates supported simulator staging from the unimplemented handset product.
Status vocabulary: COMPLETE (implemented/documented), VERIFIED (executed evidence),
IN PROGRESS (pending check), BLOCKED (requires missing integration/environment/authority),
DEFERRED (intentionally outside current baseline). Final execution evidence is in
VERIFICATION.md; do not treat initial baseline CI as verification of changed source.

| Milestone / criterion | Status | Evidence / remaining action |
|---|---|---|
| A: repository inventory, preserved local/history/research | VERIFIED | BASELINE.md; immutable historical paths unchanged |
| A: dependency remediation, repeatable lock install | VERIFIED | npm10 ci, npm ls, full audit0; exact patched tools locked |
| A: receive authentication state, wipe, key cache, header validation | VERIFIED | 92 Node crypto tests; strengthened wipe +5 regressions |
| A: authoritative Dart core and protocol goldens | IN PROGRESS | Unchanged source, static parity + TS goldens pass; fresh exact-SHA CI pending |
| A: TS full suite (new patched runner) | BLOCKED | First run510pass/11timeout failures; single-worker diagnostic still2timeouts; default5000ms retained; no assertions/gates relaxed. Remote exact-SHA CI pending |
| A: production web build + private staging package | VERIFIED | Build pass, manifest verifier and4 Node HTTP/package checks pass |
| A: browser interactive workflow / physical device operation | BLOCKED | SSR/HTTP not a browser or radio. Manual browser/device validation required |
| A: durable encrypted persistence, radio adapters, native app/crypto | BLOCKED | Sources/integrations absent; SDK installation alone insufficient |
| B: frozen baseline/models/seeds/source integrity | VERIFIED |8 Python evidence tests;3301 paired baseline full stats identical; historical research unchanged |
| B: >90% five-hop reliable delivery / resource budgets | DEFERRED | Not achieved, not simulator release gate; no baseline/default promotion |
| B: diagnostic ML/action benefit/Dart experimental profile | DEFERRED | Risk prediction only; no causal optimizer, TS-only profile gap explicit |
| C: packages, configuration, deployment/security/rollback docs | COMPLETE | docs/18, .env.example, package tests, read-only CI artifact preparation |
| C: compiled Linux-x64 authoritative CLI package | IN PROGRESS | Added CI compile/help/checksum/artifact; local Dart missing |
| C: private staging HTTP and rollback smoke | IN PROGRESS | Unit HTTP verified; clean-SHA standalone package and rollback still pending |
| C: public hosting/store/release rollout | BLOCKED | Explicit owner authorization, TLS/access policy/signing/hardware decisions required |

## Priority deployment checklist

1. Obtain fresh exact-SHA CI; investigate any remaining timing failures without weakening
assertions/timeouts or reverting to vulnerable dependencies. No green claim until actual.
2. Build immutable clean-SHA simulator package, smoke HTTP/security/corruption/rollback;
verify sourceSHA/archive checksum, preserve known-good copy, confirm no secrets.
3. Browser manually exercise warning, scenario/seed, step/pause/reset, synthetic send,
groups/media controls and no unexpected network/permissions. Use synthetic data only.
4. Owner chooses private staging access/proxy/TLS; public deployment requires approval.
5. For handset product, provide actual Flutter/native app target, secure storage/identity/
crypto design and BLE/Wi-Fi adapters; implement, test permissions/background lifecycle,
rollback-safe ratchets and device/network/security matrix before readiness re-evaluation.

## Separate research checklist (does not hold simulator baseline hostage)

Preserve immutable82-world archive/models/checksums. Keep MPR baseline/fallback and
experimental opt-ins unchanged. Do not reuse exposed740x/7501 as unseen holdout. Agree
noninferiority/overhead/energy gates, obtain Dart/device parity and measured phone budgets,
then form a bounded new hypothesis/independent evaluation. No unlimited search or
causal/real-radio claims from frozen failure-risk model.
