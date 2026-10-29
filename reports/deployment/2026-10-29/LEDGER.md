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
| A: receive authentication state, wipe, key cache, header validation | VERIFIED | 93 Node crypto tests; strengthened wipe +6 regressions |
| A: authoritative Dart core and protocol goldens | VERIFIED | Unchanged source, static parity + TS goldens; push CI40870982058 Dart +6 CLI jobs pass. Final-source CI linked in PR handoff |
| A: TS full suite (new patched runner) | BLOCKED | First run510pass/11timeout failures; single-worker diagnostic still2timeouts; default5000ms retained; no assertions/gates relaxed. Remote push CI40870982058 confirms510pass/11timeouts; final-source run linked in PR handoff |
| A: production web build + private staging package | VERIFIED | Build pass, manifest verifier and5 Node HTTP/package checks pass |
| A: browser interactive workflow / physical device operation | BLOCKED | SSR/HTTP not a browser or radio. Manual browser/device validation required |
| A: durable encrypted persistence, radio adapters, native app/crypto | BLOCKED | Sources/integrations absent; SDK installation alone insufficient |
| B: frozen baseline/models/seeds/source integrity | VERIFIED |8 Python evidence tests;3301 paired baseline full stats identical; historical research unchanged |
| B: >90% five-hop reliable delivery / resource budgets | DEFERRED | Not achieved, not simulator release gate; no baseline/default promotion |
| B: diagnostic ML/action benefit/Dart experimental profile | DEFERRED | Risk prediction only; no causal optimizer, TS-only profile gap explicit |
| C: packages, configuration, deployment/security/rollback docs | COMPLETE | docs/18, .env.example, package tests, read-only CI artifact preparation |
| C: compiled Linux-x64 authoritative CLI package | VERIFIED | CI compiled/help/checksum/upload succeed on Dart3.13.7/Linux-x64; artifact download locally blocked by Azure host egress |
| C: private staging HTTP and rollback smoke | VERIFIED | Clean ce9faa1 package all assets200/hash-equal, missing404; corrupted candidate exits1 before bind; restored known-good HTTP200;5 package/HTTP/rollback tests |
| C: public hosting/store/release rollout | BLOCKED | Explicit owner authorization, TLS/access policy/signing/hardware decisions required |

## Priority deployment checklist

1. Restore the red TS timing gate (confirmed locally AND in CI); investigate remaining timing failures without weakening
assertions/timeouts or reverting to vulnerable dependencies. No green claim until actual.
2. Build immutable clean-SHA simulator package, smoke HTTP/security/corruption/rollback;
verify sourceSHA/archive checksum, preserve known-good copy, confirm no secrets.
3. Browser manually exercise warning, scenario/seed, step/pause/reset, synthetic send,
groups/media controls and no unexpected network/permissions. Use synthetic data only.
4. Owner chooses private staging access/proxy/TLS; public deployment requires approval.
5. For handset product, provide actual Flutter/native app target, secure storage/identity/
crypto design and BLE/Wi-Fi adapters; implement, test permissions/background lifecycle,
rollback-safe ratchets and device/network/security matrix before readiness re-evaluation.

**Overall: NOT READY — BLOCKED.** Runnable simulator private preview is diagnostic staging
only, not a waiver of the red TS gate. No public deployment/release/merge performed.

## Separate research checklist (does not hold simulator baseline hostage)

Preserve immutable82-world archive/models/checksums. Keep MPR baseline/fallback and
experimental opt-ins unchanged. Do not reuse exposed740x/7501 as unseen holdout. Agree
noninferiority/overhead/energy gates, obtain Dart/device parity and measured phone budgets,
then form a bounded new hypothesis/independent evaluation. No unlimited search or
causal/real-radio claims from frozen failure-risk model.
