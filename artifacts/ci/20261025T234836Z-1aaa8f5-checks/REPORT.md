# Verification report

| | |
| --- | --- |
| Commit | `1aaa8f5` |
| Branch | `arena/ff85cb12-dumanmessenger` |
| Groups | `docs ts dart cli probes` |
| Date | 2026-10-25T23:55:09Z |
| Host | `Linux 6.18.54.1-microsoft-standard-WSL2 x86_64` |
| node | /mnt/c/Users/Administrator/Desktop/Git-Clones/DumanMessenger/tool/ci/lib.sh: line 58: /home/administrator/bin/node: Permission denied |
| npm | 11.19.0 |
| dart | 3.13.7 |
| python3 | 3.14.9 |
| Elapsed | 392s |

## Summary

**12 passed · 12 failed · 0 could not run.**

| group | check | result | verified before? | detail |
| --- | --- | --- | --- | --- |
| docs | `drift` | success | yes | — |
| docs | `dart-balance` | success | yes | — |
| docs | `parity` | success | yes | — |
| docs | `dart-sites` | success | yes | — |
| docs | `checker-self-test` | success | yes | — |
| ts | `npm-ci` | success | yes | — |
| ts | `typecheck` | success | yes | — |
| ts | `test` | success | yes | — |
| ts | `golden-regen` | success | yes | — |
| ts | `golden-diff` | success | yes | — |
| ts | `build` | success | yes | — |
| dart | `pub-get` | success | no | — |
| dart | `analyze` | failure | no | — |
| dart | `test` | failure | no | +0 -10: Some tests failed |
| dart | `cli` | failure | no | — |
| cli | `campus_quad-always-on` | failure | no | — |
| cli | `campus_quad-duty-cycle` | failure | no | — |
| cli | `sparse_village` | failure | no | — |
| cli | `festival_crowd` | failure | no | — |
| cli | `partitioned_pair` | failure | no | — |
| probes | `sos` | failure | no | — |
| probes | `group` | failure | no | — |
| probes | `history` | failure | no | — |
| probes | `media` | failure | no | — |

## Failures, and checks that could not run

### dart / analyze

```
Analyzing mesh_sim...

  error - lib/src/routing.dart:170:5 - A value of type 'num' can't be returned from the function 'ogmWireBytes' because it has a return type of 'int'. - return_of_invalid_type
  error - test/engine_test.dart:2715:20 - The function 'run' isn't defined. Try importing the library that defines 'run', correcting the name to the name of an existing function, or defining a function named 'run'. - undefined_function
  error - test/engine_test.dart:2717:21 - The function 'run' isn't defined. Try importing the library that defines 'run', correcting the name to the name of an existing function, or defining a function named 'run'. - undefined_function

3 issues found.

```

### dart / test

```
00:00 +0: loading test/acceptance_test.dart
00:00 +0 -1: loading test/acceptance_test.dart [E]
  Failed to load "test/acceptance_test.dart":
  lib/src/routing.dart:171:58: Error: A value of type 'num' can't be returned from a function with return type 'int'.
      math.max(0, neighborCount) * math.max(0, aliasBytes) +
                                                           ^
00:00 +0 -2: loading test/atrium_test.dart [E]
  Failed to load "test/atrium_test.dart":
  lib/src/routing.dart:171:58: Error: A value of type 'num' can't be returned from a function with return type 'int'.
      math.max(0, neighborCount) * math.max(0, aliasBytes) +
                                                           ^
00:00 +0 -3: loading test/channel_test.dart [E]
  Failed to load "test/channel_test.dart":
  lib/src/routing.dart:171:58: Error: A value of type 'num' can't be returned from a function with return type 'int'.
      math.max(0, neighborCount) * math.max(0, aliasBytes) +
                                                           ^
00:00 +0 -4: loading test/community_relay_test.dart [E]
  Failed to load "test/community_relay_test.dart":
  lib/src/routing.dart:171:58: Error: A value of type 'num' can't be returned from a function with return type 'int'.
      math.max(0, neighborCount) * math.max(0, aliasBytes) +
                                                           ^
00:00 +0 -5: loading test/dtn_test.dart [E]
  Failed to load "test/dtn_test.dart":
  lib/src/routing.dart:171:58: Error: A value of type 'num' can't be returned from a function with return type 'int'.
      math.max(0, neighborCount) * math.max(0, aliasBytes) +
                                                           ^
00:00 +0 -6: loading test/engine_test.dart [E]
  Failed to load "test/engine_test.dart":
  test/engine_test.dart:2715:20: Error: Method not found: 'run'.
        final flat = run(festivalCrowd(42),
                     ^^^
  test/engine_test.dart:2717:21: Error: Method not found: 'run'.
        final sized = run(festivalCrowd(42),
                      ^^^
  lib/src/routing.dart:171:58: Error: A value of type 'num' can't be returned from a function with return type 'int'.
      math.max(0, neighborCount) * math.max(0, aliasBytes) +
                                                           ^
00:00 +0 -7: loading test/golden_test.dart [E]
  Failed to load "test/golden_test.dart":
  lib/src/routing.dart:171:58: Error: A value of type 'num' can't be returned from a function with return type 'int'.
      math.max(0, neighborCount) * math.max(0, aliasBytes) +
                                                           ^
00:00 +0 -8: loading test/history_test.dart [E]
  Failed to load "test/history_test.dart":
  lib/src/routing.dart:171:58: Error: A value of type 'num' can't be returned from a function with return type 'int'.
      math.max(0, neighborCount) * math.max(0, aliasBytes) +
                                                           ^
00:00 +0 -9: loading test/media_test.dart [E]
  Failed to load "test/media_test.dart":
  lib/src/routing.dart:171:58: Error: A value of type 'num' can't be returned from a function with return type 'int'.
      math.max(0, neighborCount) * math.max(0, aliasBytes) +
                                                           ^
00:00 +0 -10: loading test/transport_test.dart [E]
  Failed to load "test/transport_test.dart":
  lib/src/routing.dart:171:58: Error: A value of type 'num' can't be returned from a function with return type 'int'.
      math.max(0, neighborCount) * math.max(0, aliasBytes) +
                                                           ^
00:00 +0 -10: Some tests failed.

Failing tests:
  test/acceptance_test.dart: loading test/acceptance_test.dart
  test/atrium_test.dart: loading test/atrium_test.dart
  test/channel_test.dart: loading test/channel_test.dart
  test/community_relay_test.dart: loading test/community_relay_test.dart
  ... and 6 more

```

### dart / cli

```
lib/src/routing.dart:171:58: Error: A value of type 'num' can't be returned from a function with return type 'int'.
    math.max(0, neighborCount) * math.max(0, aliasBytes) +
                                                         ^

```

### cli / campus_quad-always-on

```
lib/src/routing.dart:171:58: Error: A value of type 'num' can't be returned from a function with return type 'int'.
    math.max(0, neighborCount) * math.max(0, aliasBytes) +
                                                         ^

```

### cli / campus_quad-duty-cycle

```
lib/src/routing.dart:171:58: Error: A value of type 'num' can't be returned from a function with return type 'int'.
    math.max(0, neighborCount) * math.max(0, aliasBytes) +
                                                         ^

```

### cli / sparse_village

```
lib/src/routing.dart:171:58: Error: A value of type 'num' can't be returned from a function with return type 'int'.
    math.max(0, neighborCount) * math.max(0, aliasBytes) +
                                                         ^

```

### cli / festival_crowd

```
lib/src/routing.dart:171:58: Error: A value of type 'num' can't be returned from a function with return type 'int'.
    math.max(0, neighborCount) * math.max(0, aliasBytes) +
                                                         ^

```

### cli / partitioned_pair

```
lib/src/routing.dart:171:58: Error: A value of type 'num' can't be returned from a function with return type 'int'.
    math.max(0, neighborCount) * math.max(0, aliasBytes) +
                                                         ^

```

### probes / sos

```
lib/src/routing.dart:171:58: Error: A value of type 'num' can't be returned from a function with return type 'int'.
    math.max(0, neighborCount) * math.max(0, aliasBytes) +
                                                         ^

```

### probes / group

```
lib/src/routing.dart:171:58: Error: A value of type 'num' can't be returned from a function with return type 'int'.
    math.max(0, neighborCount) * math.max(0, aliasBytes) +
                                                         ^

```

### probes / history

```
lib/src/routing.dart:171:58: Error: A value of type 'num' can't be returned from a function with return type 'int'.
    math.max(0, neighborCount) * math.max(0, aliasBytes) +
                                                         ^

```

### probes / media

```
lib/src/routing.dart:171:58: Error: A value of type 'num' can't be returned from a function with return type 'int'.
    math.max(0, neighborCount) * math.max(0, aliasBytes) +
                                                         ^

```

## Dart diagnostics, parsed

The same parser CI publishes as annotations, so locations are `file:line:col`.

```
dart analyze — 0 error(s), 0 warning(s), 0 info(s)
  (no analyzer issues with a location; raw output below if non-empty)
  | Analyzing mesh_sim...
  | 
  |   error - lib/src/routing.dart:170:5 - A value of type 'num' can't be returned from the function 'ogmWireBytes' because it has a return type of 'int'. - return_of_invalid_type
  |   error - test/engine_test.dart:2715:20 - The function 'run' isn't defined. Try importing the library that defines 'run', correcting the name to the name of an existing function, or defining a function named 'run'. - undefined_function
  |   error - test/engine_test.dart:2717:21 - The function 'run' isn't defined. Try importing the library that defines 'run', correcting the name to the name of an existing function, or defining a function named 'run'. - undefined_function
  | 
  | 3 issues found.

dart test — 0 passed, 10 failed, 0 skipped
  FAIL loading test/acceptance_test.dart
       at location unknown
       Failed to load "test/acceptance_test.dart":
         lib/src/routing.dart:171:58: Error: A value of type 'num' can't be returned from a function with return type 'int'.
             math.max(0, neighborCount) * math.max(0, aliasBytes) +
                                                                  ^
  FAIL loading test/atrium_test.dart
       at location unknown
       Failed to load "test/atrium_test.dart":
         lib/src/routing.dart:171:58: Error: A value of type 'num' can't be returned from a function with return type 'int'.
             math.max(0, neighborCount) * math.max(0, aliasBytes) +
                                                                  ^
  FAIL loading test/channel_test.dart
       at location unknown
       Failed to load "test/channel_test.dart":
         lib/src/routing.dart:171:58: Error: A value of type 'num' can't be returned from a function with return type 'int'.
             math.max(0, neighborCount) * math.max(0, aliasBytes) +
                                                                  ^
  FAIL loading test/community_relay_test.dart
       at location unknown
       Failed to load "test/community_relay_test.dart":
         lib/src/routing.dart:171:58: Error: A value of type 'num' can't be returned from a function with return type 'int'.
             math.max(0, neighborCount) * math.max(0, aliasBytes) +
                                                                  ^
  FAIL loading test/dtn_test.dart
       at location unknown
       Failed to load "test/dtn_test.dart":
         lib/src/routing.dart:171:58: Error: A value of type 'num' can't be returned from a function with return type 'int'.
             math.max(0, neighborCount) * math.max(0, aliasBytes) +
                                                                  ^
  FAIL loading test/engine_test.dart
       at location unknown
       Failed to load "test/engine_test.dart":
         test/engine_test.dart:2715:20: Error: Method not found: 'run'.
               final flat = run(festivalCrowd(42),
                            ^^^
         test/engine_test.dart:2717:21: Error: Method not found: 'run'.
               final sized = run(festivalCrowd(42),
                             ^^^
         lib/src/routing.dart:171:58: Error: A value of type 'num' can't be returned from a function with return type 'int'.
             math.max(0, neighborCount) * math.max(0, aliasBytes) +
                                                                  ^
  FAIL loading test/golden_test.dart
       at location unknown
       Failed to load "test/golden_test.dart":
         lib/src/routing.dart:171:58: Error: A value of type 'num' can't be returned from a function with return type 'int'.
             math.max(0, neighborCount) * math.max(0, aliasBytes) +
                                                                  ^
  FAIL loading test/history_test.dart
       at location unknown
       Failed to load "test/history_test.dart":
         lib/src/routing.dart:171:58: Error: A value of type 'num' can't be returned from a function with return type 'int'.
             math.max(0, neighborCount) * math.max(0, aliasBytes) +
                                                                  ^
  FAIL loading test/media_test.dart
       at location unknown
       Failed to load "test/media_test.dart":
         lib/src/routing.dart:171:58: Error: A value of type 'num' can't be returned from a function with return type 'int'.
             math.max(0, neighborCount) * math.max(0, aliasBytes) +
                                                                  ^
  FAIL loading test/transport_test.dart
       at location unknown
       Failed to load "test/transport_test.dart":
         lib/src/routing.dart:171:58: Error: A value of type 'num' can't be returned from a function with return type 'int'.
             math.max(0, neighborCount) * math.max(0, aliasBytes) +
                                                                  ^

CLI acceptance (campus_quad, seed 42) — last 15 lines
  | lib/src/routing.dart:171:58: Error: A value of type 'num' can't be returned from a function with return type 'int'.
  |     math.max(0, neighborCount) * math.max(0, aliasBytes) +
  |                                                          ^

```

## Artifacts

`artifacts/ci/20261025T234836Z-1aaa8f5-checks`

Every check that ran has a `.txt` capture there, plus a `.exit` file with its status.
A group that could not run has a `.missing` file recording why.
