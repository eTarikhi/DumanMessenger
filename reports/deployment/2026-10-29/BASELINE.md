# Verified starting point and completion boundary

Actual initial Git HEAD82d967a was stale sandbox metadata, not new owner edits. Fetched
origin83629459a9b1b9bae372223e562083e373061de1; independently hashed EVERY remote tracked
file against worktree and checked extra untracked paths: zero differences/extras. Repaired
index/reference only with read-tree/update-ref, no worktree reset/deletion. Clean intended
branch arena/ff85cb12-dumanmessenger. StartingHEAD CI40853812160/40853803849 both successful.
Prior516 TS/344 Dart and8 offline tests are historical evidence, not new test results.
Issue list (all states) empty. Architecture, roadmap/skills, crypto/session/packet/ratchet,
transport seam, UI, workflows and routing evidence inspected before implementation.

## Actual architecture and milestones

The shipped code is a React/TypeScript simulator + pure-Dart simulator/CLI, NOT an
installed Android/iOS messenger. No app/, native radio adapters, encrypted message store,
secure keystore or Dart crypto exists. UI is intentionally plaintext simulation with a
tested crypto import boundary. No backend, database server, account service or remote
routing endpoint is required or implemented. Do not invent server/cloud configuration.

- A simulator/CLI baseline: package, harden, verify and prepare private staging now.
- A phone messenger baseline: BLOCKED on missing application/native transport/security/
persistence integration plus Flutter/Dart/mobile build environment and devices. This is
not a routing>90% blocker and cannot honestly be solved by an unbuildable scaffold.
- B research: DEFERRED; frozen results preserved, failure-risk model not optimizer,
experimental policies remain TS-only/offline. No new search needed.
- C production rollout: BLOCKED pending explicit owner authorization/environment; no
public hosting, release publication, store upload or signing executed.

## Dependency-aware implementation checklist

1. [x] Verify metadata, owner work and exact startingHEAD CI; inventory actual targets.
2. [ ] Fix concrete crypto state-consumption/resource-bound defects with regressions.
3. [ ] Remediate dependency advisories with minimum compatible upgrades/lockfile.
4. [ ] Add deterministic simulator-only package, integrity verifier and safe staging server.
5. [ ] Harden/static-test deployment path, traversal/security headers and artifact allowlist.
6. [ ] Update README/environment/architecture/deployment/security/recovery guide and ledger.
7. [ ] Cheap static checks → focused tests → full final suite/goldens/CI; offline research
contracts and documented deterministic baseline smoke, no repeated benchmark campaign.
8. [ ] Production build/package/private staging smoke and rollback; no public rollout.
9. [ ] Commit/push focused changes, verify finalHEAD CI, explicit readiness/blockers/handoff.

Toolchains: Node22.22.3/npm10.9.8/Python3.11.2; dart,flutter,docker absent on PATH.
Shell allowlist excludes pub.dev/storage.googleapis.com, so no unchanged SDK download
attempt. Dart stable is available in CI with committed pubspec.lock. npm ci succeeded;
audit found6 dev-tool advisories (2critical/1high/3moderate),0 prod advisories at inventory.
Actual audit JSON retained in final verification summary; not treated as zero risk merely
because the static bundle excludes those developer servers.
