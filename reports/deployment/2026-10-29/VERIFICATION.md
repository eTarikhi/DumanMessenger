# Execution evidence and honest readiness decision

Date2026-10-29. Starting83629459a9b1b9bae372223e562083e373061de1 preserved. Implementation
checkpoint **ce9faa1eddace2856aed22421d01b9b21ac613c8**; the commit containing this report adds
send-key exception cleanup (+1crypto regression) and repeated-package/rollback test; pins the observed Dart3.13.7 compiler and moves independent
package/audit checks ahead of the long TS suite without relaxing its failure gate.
Exact final commit/run/tree are recorded in the final PR3 handoff and agent response;
no report can contain its own Git hash. Do not confuse historical836 green CI with this
candidate. All commands below run in repository root unless stated otherwise.

## Local environment and commands

Node22.22.3, npm10.9.8, Python3.11.2; Vite6.4.5, React plugin4.7.0, Vitest4.1.12, TS5.9.3.
Dart/Flutter/Docker absent; no browser automation/native hardware/signing/backend configured.
Tool outputs in ignored tool/.build/deployment-* (not durable artifacts); bounded durable
CI failure annotation snapshot is CI-ce9faa1.json. No copied credentials/private logs.

| Exact command | Exit / result | Scope and limitation |
|---|---|---|
| `npm ci --no-audit --no-fund` |0,100packages | npm10 reproducibility from new lock; npm11 used ONLY to resolve upgrade |
| `npm ls --all` |0 | No invalid peers/dependency-tree errors |
| `npm audit --json` / `npm audit --audit-level=low` |0,0vulnerabilities | Before6dev advisories; after0 full-tree, point-in-time feed |
| `npm run typecheck` |0 | Includes updated crypto/tests/UI; not Dart compilation |
| `npx vitest run src/crypto/__tests__` |0,93tests/5files | Real Node/OpenSSL; six new recovery/validation/cleanup regressions; not mobile integration |
| `npm run test:deployment` |0,5tests | Real Node sockets: methods, MIME, headers, traversal, integrity, symlinks, corruption, immutable serving, repeatable manifest/rollback |
| `npm test` (initial dirty checkpoint) |1,510pass/11timeouts; extra Node-runner discovery suite error |337.56s; all521TS tests retained; Node tests renamed .checks.mjs and independently gated |
| `npx vitest run src/__tests__/scan-interval.test.ts --maxWorkers=1` |1,4pass/2timeouts |19.47s; dense comparisons8.59/8.48s. Reducing concurrency does NOT solve. No timeout/assertion changes retained |
| `npm run golden` |0 | Builds shared tools and regenerates protocol/golden vectors |
| `git diff --exit-code -- test-fixtures/golden-vectors.json` |0 | Golden bytes unchanged |
| `python3 tool/ci/check-docs.py` |0,12checks | Commands/citations/CI mirror documentation consistent |
| `python3 tool/ci/check-parity.py` |0 | Static parity, not Dart execution |
| `python3 tool/ci/check-dart-balance.py` |0 | Static syntax guard only |
| `python3 tool/ci/check-dart-sites.py` |0 |88config fields,83stats fields,14event kinds; not SDK verification |
| `python3 -m unittest discover -s tool/routing -p test_diagnosis.py -v` |0,4tests | Historical source/data/pair integrity |
| `python3 -m unittest discover -s tool/routing -p test_reliability.py -v` |0,4tests | Frozen model/features/grouped splits, known metrics, checksums |
| `node tool/deploy/routing-smoke.mjs` |0 | festival_crowd3301:122/150always,118/150duty; COMPLETE historical stats exactly equal; no new generalized90% claim |
| `npm run build` |0 |46modules; JS302091B,CSS750B,index1025B; browser bundle contains simulation, not Node crypto |
| `npm run package:simulator -- artifacts/staging-ce9faa1` |0 | Clean source ce9faa1,dirty=false;7allowlisted files,316230B combined; excludes manifest itself |
| `git diff --check` |0 | No whitespace errors |
| `git diff 8362945 -- reports/routing docs/17-routing-reliability-study.md test-fixtures/golden-vectors.json` |0bytes | Historical research/models/goldens not rewritten |

Secret-pattern scan (`git grep -Il -E` for AWS access IDs, PEM private-key delimiters,
GitHub-token patterns) found no candidates in tracked source excluding package-lock;
not a comprehensive secret detector. No secret/database/server config introduced.

## CI checkpoint: fresh authoritative results, NOT all green

Push run **40870982058**, source ce9faa1, [run](https://github.com/eTarikhi/DumanMessenger/actions/runs/40870982058).
**8/9jobs success; web failure**. Static checks pass; authoritative Dart analyze/tests/CLI
and compiled executable help/checksum/upload all pass; all six downstream CLI acceptance/
probe jobs pass. SDK annotation: **Dart3.13.7 stable, linux_x64 (2026-10-22)**. Dart test step succeeded;344 is the existing historical suite inventory, not a fresh raw
log tally (download blocked). This suite remains authoritative for EXISTING simulator only, not Node crypto,
new experimental TS profile or any handset app. Final-source exact run follows in PR handoff.

Web checkpoint: npm ci/typecheck pass;521tests,510pass/11fail, **all failures default5000ms
timeouts**, confirmed via Checks API annotations. Test tally published; subsequent goldens,
build, audit, deployment checks and web artifact upload **skipped** due existing failure.
Those independent checks were executed locally, never represented as CI successes.
PR-event run40870990817 tests a GitHub synthetic merge ref, not a literal checkout of
branch tip; push run is exact-source authority. Artifact SHA names reflect checkout ref.

`gh run view --log-failed` and `gh run download ... -n dart-cli-linux-x64-ce9faa1...` failed
once: redirects to results-receiver.actions.githubusercontent.com / Azure Blob are outside
sandbox egress allowlist. API job statuses/steps/check annotations ARE accessible and used;
do not invent full-log inspection or local execution of downloaded binary. Recover by
viewing/downloading Actions artifacts on authorized normal host or permitting those hosts.
No tokens/signed download URLs retained. CI artifact expiry14days, not a published release.

## Root cause and bounded investigation of red timing gate

Vitest4 enforces elapsed time for synchronous tests; old runner's successful synchronous
simulations did not establish that each workload completed inside5000ms. CPU-heavy dense/
multi-world workloads exceed that bound both locally and on fresh CI. Tests and simulation
inputs/assertions left intact; raising/turning off timeout, vulnerable downgrade, skipping
cases and masking failed CI were NOT used. Single-worker experiment fails identically.
No evidence of changed routing outcomes (goldens/paired baseline replay unchanged).

`node --cpu-prof --cpu-prof-dir=tool/.build tool/deploy/routing-smoke.mjs` profiling found
self-time approximately2.37s stale-table pruning,1.95s GC,1.18s RSSI,1.05s OGM receive
in two worlds. This identifies a next performance investigation, not a safe fix already
proven. A broad router rewrite/cache/memory change would risk parity/historical behavior;
no speculative experimental policy/default tuning introduced merely to turn CI green.
Next action: reproduce specific failing tests, profile exact heavy workloads, implement
bounded semantics-preserving optimization with Dart/golden/research parity, keep5000ms
and all assertions, then rerun full exact-SHA checks. If wall-clock budget is a product
change, owner approval is necessary; it has NOT been implicitly granted here.

## Private intended-target smoke and rollback

Built clean ce9faa1 package; server CLI `HOST=0.0.0.0 PORT=4173 ALLOW_PREVIEW_EMBED=1 node
artifacts/staging-ce9faa1/serve.mjs artifacts/staging-ce9faa1` bound successfully with no
preview warnings. Actual HTTP fetched all three web files:200,correct MIME, byte hashes
match manifest; /missing.js404. No localhost API/backend calls exist. Preview is synthetic
static UI, not public deployment/authenticated messaging.

Stopped preview, built separate candidate, appended synthetic corruption to index.html;
`node artifacts/corrupt-candidate-ce9faa1/serve.mjs artifacts/corrupt-candidate-ce9faa1`
exited1 (integrity mismatch) BEFORE binding. Restarted original verified package; GET /200.
Automated rollback/manifest determinism regression also passes. Browser interaction/TLS/
proxy authentication/devices were NOT verified by this HTTP test and remain explicit gates.

## Verdict / milestones / user intervention

**NOT READY — BLOCKED** overall: strict TS timing gate is red. A private diagnostic
simulator preview works; that is NOT a release waiver. Phone messenger additionally lacks
app/native radios/production crypto/secure persistence/background permission lifecycle.
Research>90% is independently DEFERRED, not why simulator gate is red.

No main/other-branch changes, merges, force push, release publication, public hosting,
cloud/provider creation, signing or irreversible rollout performed. Focused commits on
intended branch only. Owner intervention: approve real app/platform/security/storage
choices, provide devices/signing/operator TLS/access policy and authorize external rollout
ONLY after core gates pass; no credentials requested in chat. Timing optimization can
continue autonomously within unchanged parity/security/acceptance constraints.
