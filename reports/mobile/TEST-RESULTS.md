# Local baseline test results

**Run date:** 2026-11-05
**Source snapshot:** `a1f1916981c2244a2f8664573b66afbd5a2659b4`, parent `bdf719cf88205f944187cb79b8288264a56c13bd`
**Host:** Linux `6.1.158+`, `x86_64`; Node `v22.22.3`; npm `10.9.8`
**Run type:** local checkout only. No GitHub Actions or remote CI.

## Commands run

| Command | Result | Observed detail |
|---|---|---|
| `npm ci --ignore-scripts --no-audit --no-fund` | **PASS** | Installed 100 packages from the committed npm lockfile in about 2.6 seconds. `--ignore-scripts` deliberately avoided the package `prepare` hook, which changes this clone's local Git hook configuration. No package manifest/lockfile change was made. |
| `npm run typecheck` | **PASS** | `tsc --noEmit -p tsconfig.json`; process duration about 9.4 seconds. |
| `npm run build` | **PASS** | `tsc -b && vite build`; process duration about 11.0 seconds. Builds the existing browser simulator only; it is not a Flutter/Android/iOS build. |
| `npm run test:deployment` | **PASS** | 5 tests passed, 0 failed; local Node deployment/package and HTTP-smoke checks; process duration about 0.56 seconds. |
| `npm test -- --reporter=verbose` | **FAIL — strict timeouts** | 28 test files: 24 passed, 4 failed; 527 total tests: 517 passed and 10 failed. All ten reported failures were `Test timed out in 5000ms`. Vitest summary duration: 315.66 seconds. The existing 5,000 ms timeout was not changed. |
| `python3 tool/ci/check-docs.py` | **PASS** | 12 documentation drift checks passed after the report files were created. |
| `python3 tool/ci/check-parity.py` | **PASS — static only** | 88 `SimConfig` knobs, 83 stats fields, 59 shared constants, and the shared coverage weights agree across the TypeScript and Dart source inventories. This does not compile Dart or run its tests. |
| `python3 tool/ci/check-dart-balance.py` | **PASS — static only** | 27/27 Dart files balanced; not a Dart analysis or execution result. |
| `python3 tool/ci/check-dart-sites.py` | **PASS — static only** | Dart declaration/use-site consistency checks passed; not a Dart analysis or execution result. |
| One-off Python check of the six new Markdown files | **PASS** | Relative local links resolve; no trailing whitespace or conflict markers. The check was not added as a repository script. |

The TypeScript test run did not skip, disable, delete, or weaken tests. No simulator, protocol, routing default, threshold, behavior, or golden fixture was edited. Build output and `node_modules` are generated/ignored local artifacts.

## Ten current Vitest timeout failures

These are failures, not passes or waived checks:

1. `src/__tests__/acceptance.test.ts` — `dense crowd` / `stays stable and cheap at 60 nodes`.
2. `src/__tests__/acceptance.test.ts` — `dense crowd` / `holds its delivery bar on seeds the gate above does not use`.
3. `src/__tests__/acceptance.test.ts` — `dense crowd` / `costs MPR nothing against the same engine without suppression`.
4. `src/__tests__/radio-occupancy.test.ts` — `costs a dense crowd fewer deferrals and buys it delivery, once contention is modelled`.
5. `src/__tests__/scan-interval.test.ts` — `scans more in a dense world, which is what the row says and what it costs`.
6. `src/__tests__/scan-interval.test.ts` — `clamps, so one peer does not stop a node scanning and a crowd does not pin it awake`.
7. `src/__tests__/simulation.test.ts` — `scale: the documented 10-200 node range` / `runs at the top of the range, and the fallback does not go quadratic`.
8. `src/__tests__/simulation.test.ts` — `community relays` / `elects the plugged tablets and moves relay work off other people's batteries`.
9. `src/__tests__/simulation.test.ts` — `cap-aware community-relay promotion` / `exempting tablets from the cap elects all six and pushes the ratio to the top of the band`.
10. `src/__tests__/simulation.test.ts` — `preferring a community relay` / `and that is where the benefit stops: the bundle waits on a node that never moves`.

The current run establishes only that these tests exceeded the configured per-test limit in this run. It does not establish the cause, a code regression, or any current routing/performance result. Reproduce and profile on a supported host before proposing a behavior-preserving optimization. Do **not** increase the timeout to turn this baseline green.

## Checks not run and why

| Check | Status / reason |
|---|---|
| `dart analyze`, `dart test` (13 Dart test files) | **Not run:** `dart` is not installed. No SDK download or remote CI was attempted. |
| `flutter test`, Android Gradle build/install/launch, Android emulator/physical-device tests | **Not run:** Flutter, Java, Gradle, `adb`, and `sdkmanager` are unavailable; no mobile project or device is present. |
| iOS build/launch, iOS Simulator, physical iPhone tests | **Not run:** this host is Linux and `xcodebuild`, `xcrun`, and `pod` are unavailable. |
| Manual interactive browser test | **Not run:** build and component test results are not manual browser interaction evidence. |
| Dependency/security audit, SBOM/license review | **Not run:** these are supply-chain/release tasks and are not represented by the build/test results. |
| `npm run golden` / fixture regeneration | **Not run:** this would regenerate a protected shared fixture; no baseline change or golden rewrite was authorized. |
| Historical routing diagnostics / remote CI | **Not run:** the current request prohibits remote CI; historical values are not current evidence. |

## Evidence separation and provenance warning

The TypeScript tests exercise the simulator/reference code. The deployment tests exercise the browser simulator's local package/server. Neither is an emulator or physical-device test, and neither proves secure real-device messaging. The existing Dart simulator suite is also unverified in this environment.

This run reports **527 tests total, 517 passing, and 10 timed out** at source checkpoint `a1f1916981c2244a2f8664573b66afbd5a2659b4`. Do not conflate that with historical `527/532` or historical five-second-timeout evidence. Do not report the five-hop `>90%` goal as achieved from this run or from old evidence.
