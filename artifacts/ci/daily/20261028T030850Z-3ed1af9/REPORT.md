# Verification report

| | |
| --- | --- |
| Commit | `3ed1af9` |
| Branch | `arena/ff85cb12-dumanmessenger` |
| Groups | `docs ts dart cli probes evidence` |
| Date | 2026-10-28T04:11:26Z |
| Host | `Linux 6.18.54.1-microsoft-standard-WSL2 x86_64` |
| node | /mnt/c/Users/Administrator/Desktop/Git-Clones/DumanMessenger/tool/ci/lib.sh: line 58: /home/administrator/bin/node: Permission denied |
| npm | 11.19.0 |
| dart | 3.13.7 |
| python3 | 3.12.3 |
| Elapsed | 2984s |

## Summary

**30 passed · 0 failed · 0 could not run.**

| group | check | result | verified before? | detail |
| --- | --- | --- | --- | --- |
| docs | `drift` | success | yes | — |
| docs | `dart-balance` | success | yes | — |
| docs | `parity` | success | yes | — |
| docs | `dart-sites` | success | yes | — |
| docs | `ps1` | success | yes | — |
| docs | `checker-self-test` | success | yes | — |
| ts | `npm-ci` | success | yes | — |
| ts | `typecheck` | success | yes | — |
| ts | `test` | success | yes | — |
| ts | `golden-regen` | success | yes | — |
| ts | `golden-diff` | success | yes | — |
| ts | `build` | success | yes | — |
| dart | `pub-get` | success | no | — |
| dart | `analyze` | success | no | — |
| dart | `test` | success | yes | +279: All tests passed |
| dart | `cli` | success | no | — |
| cli | `campus_quad-always-on` | success | no | — |
| cli | `campus_quad-duty-cycle` | success | no | — |
| cli | `sparse_village` | success | no | — |
| cli | `festival_crowd` | success | no | — |
| cli | `partitioned_pair` | success | no | — |
| probes | `sos` | success | no | — |
| probes | `group` | success | no | — |
| probes | `history` | success | no | — |
| probes | `media` | success | no | — |
| evidence | `media-probe` | success | yes | — |
| evidence | `history-probe` | success | yes | — |
| evidence | `e2ee-probe` | success | yes | — |
| evidence | `rate-probe` | success | yes | — |
| evidence | `cover-probe` | success | yes | — |

## Dart diagnostics, parsed

The same parser CI publishes as annotations, so locations are `file:line:col`.

```
dart analyze — 0 error(s), 0 warning(s), 0 info(s)
  (no analyzer issues with a location; raw output below if non-empty)

dart test — 279 passed, 0 failed, 0 skipped
  (no failing tests parsed)

CLI acceptance (campus_quad, seed 42) — last 15 lines
  |   batteryPct8hSuper        55.65
  |   scansPerSec              33.2
  |   relaysPerSec             16.2311
  |   awakeRatio               1.0
  |   scansSkippedAsleep       0
  |   electionEvents           6
  |   latencyByHop             hops      n     avg     p95
  |                               1     62   247 ms   314 ms
  |                               2     38   646 ms   829 ms
  |                               3     27   902 ms  1127 ms
  |                               4     12  1066 ms  1550 ms
  |                               5      1  1257 ms  1257 ms
  |                               6      2  1746 ms  2026 ms
  | 
  | PASS — acceptance criteria met.

```

## Artifacts

`artifacts/ci/20261028T032142Z-3ed1af9-checks`

Every check that ran has a `.txt` capture there, plus a `.exit` file with its status.
A group that could not run has a `.missing` file recording why.
