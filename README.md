# Duman Messenger — Serverless Offline Messenger
### Bluetooth + Wi-Fi Direct / Wi-Fi Aware Mesh | No Internet, No Cellular Required

> **Vision:** A pager & walkie-talkie for the disconnected world. People within short distance can message and call directly via Bluetooth/WiFi, and the network self-organizes to extend range through smart router nodes.

**Package contents:**
- `docs/01-feasibility-analysis.md` — Possibilities & problems (deep research)
- `docs/02-technical-architecture.md` — Evaluated stacks & selected approach
- `docs/03-smart-router-algorithm.md` — Coverage-based super-node election (Duman Adaptive Routing)
- `docs/04-security-privacy.md` — Threat model & E2EE without servers
- `docs/05-comprehensive-feasibility-study.md` — Full feasibility study: constraint analysis, protocol/framework comparison, architecture, phased roadmap & talent matrix
- `roadmap/roadmap.md` — Phase-by-phase delivery plan (12 months, MVP → Scale)
- `roadmap/index.html` — Interactive visual roadmap (open in browser)
- `skills/` — 8 development skill definitions for the build team
- `docs/06-simulator-findings.md` — Simulator calibration evidence, protocol corrections & the one documented limitation
- `docs/07-e2ee-noise-xx.md` — Noise_XX as a *mesh* protocol: measured handshake cost, when to negotiate, packet/padding sizes
- `docs/08-media-transport-ptt.md` — What a byte costs on this mesh: chunked files, streamed push-to-talk, the retry timer, skills/05's acceptance boxes, and what one real radio changes
- `docs/09-field-test-plan.md` — The one criterion that needs a building: capture schema, analyzer, protocol, and what the simulator predicts
- `docs/10-local-development-and-ci.md` — The local CI mirror, every check in one report, the daily run, and §11: what a given machine cannot do
- `docs/11-windows-11-workflow.md` — The same workflow on Windows 11: WSL2, Git Bash, `make.ps1`
- `docs/12-cli-cheat-sheet.md` — Every command, by task
- `PRIVACY.md` — Privacy policy draft: what leaves the device, who can see it on air, and what cannot be undone. No controller and no counsel review yet, and it says so
- `sim/mesh_sim/` — **Dart mesh simulator** (authoritative headless engine + CLI)
- `tool/` — the evidence probes behind every published number, the field-report analyzer, and `tool/ci/` (the local pipeline, the check collection, the daily run)
- `src/` — **TypeScript mesh simulator** (reference engine + React visualiser)
- `test-fixtures/golden-vectors.json` — cross-language determinism contract asserted by both engines

**Status:** Research Complete | Stack Selected | Simulator Implemented (Dart + TS) | Ready for Development
**Date:** Oct 2026 | **Location:** Bucharest, RO
**Target platforms:** Android 8+ • iOS 13+ (with graceful degradation)

---

## Quick start (Windows 11 x64)

What a clean Windows 11 machine needs to develop, build and verify this repository, in the order it
needs it. `docs/11-windows-11-workflow.md` is the long form — WSL2 versus Git Bash, `make.ps1`,
line endings, long paths, Task Scheduler; `docs/10-local-development-and-ci.md` is the same
pipeline on Linux and macOS; `docs/12-cli-cheat-sheet.md` is every command by task.

### 1. Required

| Tool | Version this repository pins | What it is needed for | Install |
| --- | --- | --- | --- |
| **Git for Windows** | 2.30+ | everything — and it supplies Git Bash, one of the two runtimes `make.ps1` forwards to | `winget install --id Git.Git -e` |
| **Node.js** | **22.x** — `package.json` declares `engines: { "node": ">=22" }` and CI pins `node-version: 22` | the TypeScript reference engine, the React visualiser, `npm test`, the cross-language golden vectors, the production build | `winget install --id OpenJS.NodeJS.LTS -e` |
| **npm** | 10.x, ships with Node | `npm ci` against the committed `package-lock.json` — the reproducible install both CI and the local pipeline use | *(with Node)* |
| **Dart SDK** | **stable ≥ 3.4.0** — `sim/mesh_sim/pubspec.yaml` declares `sdk: ^3.4.0` | the **authoritative** engine: `dart analyze`, `dart test`, and the CLI acceptance runs behind `skills/02`, `skills/07` and `skills/08` | `choco install dart-sdk -y`, or the zip route in `docs/11` §2 |
| **Python 3** | 3.9+ | the five static checkers in `tool/ci/` (`check-docs`, `check-parity`, `check-dart-balance`, `check-dart-sites`, `check-ps1`) and `tool/ci/diagnostics.py`. **Standard library only — no pip packages, no virtualenv** | `winget install --id Python.Python.3.12 -e` |
| **A bash runtime** | WSL2 + Ubuntu (recommended) or Git Bash | `tool/ci/*.sh`, the `Makefile` and the pre-push hook are bash. `make.ps1` is a *dispatcher*: it finds one of these, translates the path and forwards your arguments | `wsl --install -d Ubuntu` |
| **GNU Make** | 4.x | every `make …` target. Git Bash does **not** ship it, which is the usual reason `make` "does not work" on Windows | inside WSL: `sudo apt install make` |
| **curl** | any | `make doctor` and `make blockers` probe egress, CI and the toolchain with it | present in WSL; natively `winget install --id curl.curl -e` |
| **jq** | 1.6+ | `tool/ci/blockers.sh --json` and the daily run's previous-run comparison | inside WSL: `sudo apt install jq` |

Runtime dependencies install themselves from the committed lockfiles: `npm ci` pulls
`react` + `react-dom` and the dev set (`typescript`, `vite`, `vitest`, `@vitejs/plugin-react`,
`@types/*`) from `package-lock.json`; `dart pub get` pulls the single dev dependency
`package:test` from `sim/mesh_sim/pubspec.yaml`. There is nothing to install by hand and no
dependency this repository vendors.

### 2. Optional, and what each one unlocks

| Tool | Unlocks | Install |
| --- | --- | --- |
| **GitHub CLI** (`gh`) 2.x, authenticated | `make watch`, `make diagnose`, `make pr` — reading CI runs, their annotations, and opening a pull request | `winget install --id GitHub.cli -e`, then `gh auth login` |
| **Docker Desktop** + **act** | `make act` — running `.github/workflows/ci.yml` itself in a container instead of the local mirror of it | `winget install --id Docker.DockerDesktop -e`; act from [nektos/act releases](https://github.com/nektos/act/releases) |
| **PowerShell 5.1** | already ships with Windows 11. `make.ps1` targets it, and `tool/ci/check-ps1.py` fails the build on PowerShell-7-only syntax (`??`, `?.`, the ternary, `&&`/`||` as pipeline chain operators) so that it keeps running on 5.1 — and on a pass-through parameter PowerShell will not bind positionally, which is what broke `.\make.ps1 doctor` the first time anybody ran it | *(installed)* |
| **VS Code + the WSL extension** | editing inside the distro, which is where the pipeline actually runs | [code.visualstudio.com](https://code.visualstudio.com/) |
| **Flutter SDK** | **not needed today.** The roadmap's `app/` directory does not exist yet; Flutter becomes a requirement when roadmap item 13 (the mono-repo `app/` + `transport/android` + `transport/ios`) starts, and it needs `pub.dev` reachable | [docs.flutter.dev](https://docs.flutter.dev/) |

### 3. Two Windows settings that are not optional

```powershell
git config --system core.longpaths true    # elevated shell: node_modules exceeds the 260-character
                                           # limit, and npm ci fails partway with ENOENT without it
git config core.autocrlf false             # .gitattributes already pins eol=lf on *.sh, Makefile,
                                           # .githooks/* and *.py; this stops a CRLF checkout from
                                           # breaking bash and from making an unchanged golden
                                           # vector look modified
```

Cloned before `.gitattributes` existed? Renormalise once: `git add --renormalize .` and check that
`git status` lists only files whose endings actually changed.

### 4. First run

```powershell
git clone https://github.com/eTarikhi/DumanMessenger.git
cd DumanMessenger
.\make.ps1 doctor      # this machine against what CI pins — read this first, it names every gap
.\make.ps1 install     # npm ci + dart pub get (skips Dart with a warning if the SDK is absent)
.\make.ps1 checks      # every check in one report; the five static ones need no Node and no Dart
.\make.ps1 ci          # the whole workflow, job for job, mirroring ci.yml
```

The same four from inside WSL or Git Bash, where `make` exists: `make doctor && make install &&
make checks && make ci`. `npm ci` also activates the pre-push gate — `package.json`'s `prepare`
script runs `git config core.hooksPath .githooks`, so the fast pipeline runs before every push
without a separate `make install-hooks`. Bypass one push with `git push --no-verify`.

Budget roughly 12 minutes for `make daily-fast` and about 27 for `make daily` on a machine without
the Dart SDK; both are longer with it, because the Dart jobs then actually run.

### 5. What "deploy" means for this repository today

| Artefact | Command | Output |
| --- | --- | --- |
| The simulator web app | `npm run build` (`tsc -b && vite build`) | `dist/` — static files, host anywhere. `npm run preview` serves it locally |
| The authoritative engine, headless | `cd sim/mesh_sim && dart run bin/mesh_sim.dart --scenario campus_quad --seed 42` | metrics on stdout; **exits non-zero if the acceptance criteria fail**, which is what CI gates on |
| A Windows executable of that CLI | `dart compile exe sim/mesh_sim/bin/mesh_sim.dart -o mesh_sim.exe` | plausible — `lib/` imports only `dart:async`, `dart:convert`, `dart:math` and `dart:typed_data`, and only `bin/` imports `dart:io` — but **not exercised by CI or by any test here**, so try it before relying on it |
| The messenger app itself | — | **does not exist yet.** There is no `app/` directory: store distribution (Play, F-Droid, TestFlight) is roadmap items 94 and 479, gated on signing keys and store accounts, not on anything installable |

### 6. What is verified about these instructions

Recorded rather than implied, because this repository's own rule is that partial verification is
stated (`docs/10` §6, `docs/11` §9):

* **Verified by execution in CI** — every `dart` and `npm` command above. The branch head is green on
  all nine jobs: `dart analyze` clean, the gated `campus_quad` acceptance run passing, all five CLI
  matrix arms and all four probes. Both suites' tallies are published as notice annotations
  (`dart test`, `npm test`) so the counts never have to be remembered — at the time of writing,
  [run 40617596690](https://github.com/eTarikhi/DumanMessenger/actions/runs/40617596690) reported
  **279 Dart cases** and **480 TypeScript cases in 18 files**, 0 failed.
* **Verified locally on Linux** — `npm ci`, `npm test` (18 files), `npm run build`,
  the five static checkers and their self-tests, `make doctor`, `make blockers`, `make daily-fast`.
* **Executed on real Windows 11 — twice, and it failed twice.** On 2026-10-27 `make.ps1` was run for the
  first time anywhere, on Windows 11 with PowerShell 5.1, and its own documented invocation was
  rejected before the dispatcher did any work: `.\make.ps1 doctor` &rarr; *Cannot validate argument
  on parameter 'Runtime'. The argument "doctor" does not belong to the set "auto,wsl,bash"*. The
  cause: a `ValueFromRemainingArguments` parameter with no `Position`, which PowerShell excludes
  from positional binding, so the target bound to `-Runtime` and hit its `ValidateSet`. Fixed, and
  `check-ps1.py` gained a third failure class for it — run against the pre-fix file it names the
  defect, against the fixed file it is clean.
* **What the second execution then verified** — WSL2 detection with a real distro, `wslpath -u`
  translation, the `/mnt/c` performance warning, single-quote-only quoting surviving the PowerShell
  &rarr; `wsl.exe` &rarr; `bash -lc` layers, exit-code propagation, and the branch that refuses to
  report 127 as a pipeline verdict. That run failed too, on arithmetic rather than plumbing: the
  script took the *parent* of its own directory as the repository root, so every forwarded command ran
  one level too high — `bash: /mnt/c/Users/…/Git-Clones/tool/ci/doctor.sh: No such file or
  directory`. Fixed to `$PSScriptRoot`, guarded at startup so it fails in PowerShell with a reason
  instead of in bash with a path, and now a fourth `check-ps1.py` class.
* **Still not observed** — a target completing. No doctor output, no `make` target and no script
  target has ever run through this dispatcher to a verdict of 0, 1 or 2. No PowerShell exists in the
  environment these instructions were written in and its release asset host is unreachable from it, so
  the remainder is checked statically by `tool/ci/check-ps1.py` (delimiter balance, no
  PowerShell-7-only syntax, no unbindable pass-through parameter, no repo root computed from a false
  assumption about where the script lives) in CI's `checks` job and in `make checks`. The `winget` and
  `choco` install commands are the ones `docs/11` §1–§2 documents; they have not been run here
  either.

---

## Mesh simulator

Two engines, one set of golden vectors. Both are deterministic discrete-event
simulations on a virtual clock: same seed ⇒ same run, byte for byte.

**Dart (authoritative, headless — this is what the roadmap builds on):**

```bash
cd sim/mesh_sim
dart pub get
dart test                                                    # incl. golden parity with the TS engine
dart run bin/mesh_sim.dart --scenario campus_quad --seed 42  # exits non-zero if acceptance fails
dart run bin/mesh_sim.dart --scenario festival_crowd --nodes 80 --json
dart run bin/mesh_sim.dart --duty-cycle   # NORMAL scans 3 s / sleeps 7 s (skills/07)
dart run bin/mesh_sim.dart --sos          # SOS reach probe: component-relative and raw
dart run bin/mesh_sim.dart --media        # 10 MB image at 1/2/3 hops, BLE-only ladder, PTT budgets
dart run bin/mesh_sim.dart --history      # group history repair: members spread wide, and the five
                                          # nearest, each against the same world with repair off
dart run bin/mesh_sim.dart --trace        # per-delivery route: dBm, action and reason per hop
dart run bin/mesh_sim.dart --capture      # pcap-like mesh log tail (--capture-ogm adds beacons)
```

**TypeScript (reference engine + browser visualiser):**

```bash
npm ci
npm test          # the whole suite: RF, election, routing, DTN, power, SOS, hop traces, abuse limits,
                  # blocks, wake-locks, radio occupancy, connectivity, acceptance, UI renders
npm run dev       # canvas: watch SUPERs get elected, MPR suppress floods, bundles wait for a
                  # contact, and a split network draw a ring per component. Click a node to
                  # decline its router role, turn on battery saver, or block a peer locally
npm run golden    # regenerate test-fixtures/golden-vectors.json after an engine change
npm run media     # 18 sections, ~14 min: docs/08's media and radio work plus docs/06 §24's
                  # occupancy, beacon interval, reach and interval-mode measurements
npm run history   # group-history anti-entropy, with and without repair (docs/06 §17)
npm run e2ee      # what E2EE costs on this mesh: handshake legs, session churn, packet sizing,
                  # real crypto throughput (docs/07 §2-§4, §7)
npm run rate      # docs/04 §6's abuse limits: honest traffic, a 12x flooder, a local block
npm run cover     # docs/04 §5's dummy beacons — measured, and rejected (docs/06 §23)
npm run field:capture -- campus_quad 42 /tmp/cap.jsonl [flood-all]   # a field-test capture, from a run
npm run field:report  -- /tmp/cap.jsonl /tmp/base.jsonl              # the roadmap's field numbers (docs/09)
```

Scenarios: `campus_quad` (20 nodes — the `skills/02` + `skills/08` acceptance
case), `sparse_village` and `partitioned_pair` (store-carry-forward DTN),
`festival_crowd` (60 nodes, the `docs/02` §6 density target).

Measured on `campus_quad` across six seeds (re-measured 2026-10-28; the two engines agree to the
unit): **SUPER ratio 20-25%, delivery 99.3-100%, 98.7-100% of messages within 5 hops and 89.3-96.0%
within 3, 8-10% of the naive flood-all relay budget, ≤0.14 role changes per node per minute.** The
three-hop figure is published beside the five-hop one because `skills/02` words its criterion "at 3
hops" while both suites enforce five — an owner decision, recorded as finding F2, not a test. In the 60-node crowd the
engine delivers **85.3-98.7% over nine seeds** at 10.6-12.8% of naive flood's relays — naive
flooding does reach 100% there, for 7.8-9.5× the relays (`docs/06` §6, §16). The nine-seed delivery
readings reproduce seed for seed against the current engine; the two overhead figures were re-measured 2026-10-28 at `757c134`,
because they had drifted with it.

That crowd range is wide because the crowd is **bimodal**, and quoting it without saying so
would be the mistake this repository spent a week unwinding: 60 mobile nodes spawned in clusters
split and re-join inside a measurement window, so broadcast reach lands near 98% in a window that
stays connected and 50-79% in one that does not. Which mode a seed takes is not stable across
arms, so a three-seed mean can be ordered almost arbitrarily — one did, and §24.8 retracted it.
Read any crowd number beside its in-window connectivity (`connectedSampleShare`) and its seed
count; `docs/06` §24.8-§24.13 is the whole story, and §24.14 collects what follows from it.

Criteria, calibration evidence and the protocol bugs found while measuring are in
[`docs/06-simulator-findings.md`](docs/06-simulator-findings.md). E2EE is specified, costed **and
implemented** — handshake latency per leg, when to negotiate at all, and the packet/padding size
model both engines use — in [`docs/07-e2ee-noise-xx.md`](docs/07-e2ee-noise-xx.md). `src/crypto/`
carries Noise_XX, the symmetric ratchet, SAS comparison, identity/QR and packet sealing across
eight modules and 87 tests, built on `node:crypto`'s vetted primitives rather than anything
hand-rolled, which is what `skills/03`'s *"never custom crypto"* actually asks for. It is
deliberately outside the browser bundle — nothing in `App.tsx`'s import graph may reach it, and a
test fails if that changes — and there is no Dart mirror, because the Dart SDK has no X25519 or
ChaCha20 and no package source was reachable to add one.

**SOS mode** (`docs/05` §3.2-3.3, roadmap Phase 3): the originator floods, then re-floods three
times at 5 s intervals, each flood a *fresh message id* (the seen-cache would swallow a repeat that
reused one) carrying a fresh GPS fix, with receivers collapsing on `sosId` so four floods raise one
alert. SOS bypasses MPR at every hop — suppression exists to delete duplicate copies, and an emergency
broadcast is made of them. Measured: reach over the sender's radio-connected component is **100% in
all four worlds**; in the 60-node crowd four floods take raw reach from 89.4% to 100%, and with
link-layer retries disabled repeats take a degraded world from 40.8% to 64.5% — while six floods buy
nothing over four when the gap is *radius* rather than loss. TTL is the radius knob and stays at the
documented 5, except in `festival_crowd`, which is 6+ hops across from an edge sender
(`docs/06-simulator-findings.md` §11).

**Scale** (`skills/08`: nodeCount 10-200): measured end to end, and the top of the
range had a cliff — at 200 nodes in a 100×100 m area every node hears ~179 of the
other 199, so a beacon that advertises at most 30 neighbours cannot answer the MPR
coverage question, and every relay fell back to flooding all of its peers (one 3-hop
delivery: 7,038 transmissions). Bounding that fallback to six **direction-spread**
peers cuts the worst case 76% and 100 nodes by 86%, costs one message in 60 at 200
nodes, and is inert below 30 peers — so the 20- and 60-node evidence, and the golden
vectors, are unchanged (`docs/06-simulator-findings.md` §15).

**Group channels** (`docs/04` §4, roadmap Phase 1): 3-10 members, an admin, and a key epoch that
rotates on every membership change — so a node that leaves keeps relaying group traffic but can no
longer read it, and a node that joins cannot read the history it missed. Delivery ships in two
measured modes: a **scoped flood** the whole network relays and only members accept (the default, and
the only mode that does not reveal the membership to every node on the path), or **one routed unicast
per member**, which is up to 130× cheaper when every member is a direct peer and up to 5.8× dearer
when they are spread across the world. `dart run bin/mesh_sim.dart --group 10` reports both on any
world and says which is cheaper and why; the visualiser manages membership from the node inspector and
flips the mode live from the chat header (`docs/06-simulator-findings.md` §14).

**Media transport** (`skills/05`, `docs/05` §3.2-3.3, roadmap Phase 3): a payload now costs what it
occupies the radio with — `max(0, bytes − 1024) × 8 / kbps` per hop, at 80 kbit/s on BLE against
20 Mbit/s on Wi-Fi Direct, the 250× ratio `docs/05` claims — and it is inert below one packet, which is
why every earlier measurement and both golden fixtures are unchanged. Files go out as 64 KB slices
behind a 4-deep sliding window, each slice an ordinary unicast so it inherits ACKs, retries, the
OppQueue and the hop trace: a 10 MB image crosses 1/2/3 hops in **7.6 s / 16.9 s / 33.0 s**, and when
its receiver disappears for 20 s mid-transfer a stall watchdog re-sends what is missing and it finishes
in 45.0 s (skills/05's "resume" acceptance box). Push-to-talk streams 500 ms Opus frames at 12 kbps —
750 B, exactly one padded BLE packet — leaving at the end of each capture window, and plays **407 ms**
after release at one hop and **1.10 s** at three against the roadmap's <3 s / <8 s; media retries on a
600 ms timer because the text plane's 4 s is eight voice frames and one lost frame left an 8.5 s hole in
the audio. Chunks are counted apart from 1:1 traffic so one file cannot flatter `deliveryRatio`, the
chat panel renders a transfer as one progress row instead of 160 empty bubbles, and
`dart run bin/mesh_sim.dart --media` / `npm run media` print every table in
[`docs/08-media-transport-ptt.md`](docs/08-media-transport-ptt.md).

**Field-test instrumentation** (roadmap Phase 2, `docs/09`): the one acceptance item that needs a
building is prepared for instead of guessed at. A JSONL capture schema, an analyzer that turns a capture
into delivery-vs-flood-all, the SUPER ratio and battery %/h, and an RF calibration fit that decides
whether the simulator's radio model is *this* building's model — all validated against a synthetic
capture whose ground truth is known, where the fit recovers −55.0 dBm / 20.0 dB per decade / 31.6 m to
three significant figures.

**Group history repair** (roadmap Phase 1's "CRDT for group/broadcast history (hash beacon
anti-entropy)"): every member holds its group's messages as a grow-only set keyed by message id, so
merging two members is a union and a beacon may be lost, duplicated or reordered without the protocol
caring. Each offers every co-member it can *hear* a digest — 16 XOR-folded bucket hashes, **156
characters whether the group has said nothing or 400 messages**, one 256 B BLE packet — and a peer whose
buckets differ asks for those buckets *and lists the ids it already holds*, which is what lets a reply be
capped at 32 entries and still converge (without the list, every round re-offers the same head and repair
stalls). Nothing is acknowledged; the next beacon is the retry. Measured on a five-member group with one
member out of range for a whole 20-message conversation: **20/20 recovered, converged in 8.8 s**, against
**0/20** with beacons off, for 31 beacons/min and 81 B/s when idle. The boundary is measured too — beacons
are peer-to-peer, so what converges is the membership's *peer graph*: a spread membership recovers the
returning member and still never converges, because reach is the scoped flood's job, not repair's
(`docs/06-simulator-findings.md` §17).

**Hop transparency** (roadmap Phase 4): every delivery carries a per-hop trace — arrival time, link
budget in dBm, who handed it over, the action and the router's own reason — and `deliveredChain()`
recovers the route from what turns out to be a fan-out *tree* (a 4-hop delivery lists 15 nodes), which
is what makes the roadmap's "via 2 nodes • SUPER Amir" computable instead of decorative. A bounded
pcap-like capture log sits behind `--capture` and is provably inert: with it on, every counter and
node position is identical and the golden vectors are byte-for-byte unchanged (§13).

**Power policy** (`skills/02`, `skills/07`): SUPER opt-out and battery saver are
respected immediately — no two-cycle hysteresis, because a user toggle is not
score noise — and the declination is advertised in the OGM so neighbours stop
counting it as a top-20% candidate. The duty cycle (`scan 3s/sleep 7s`, SUPER
continuous) throttles scanning only, and it is what brings NORMAL inside
`skills/07`'s battery budget: measured **19-25% per 8 h always-on** versus
**8.7-12.4% duty-cycled**, delivery-neutral on the seed mean. The visualiser's
metrics dashboard and `--json` report battery %/h per role, scans/s, relays/s and
latency by hop (`docs/06-simulator-findings.md` §10).

---
**Quick verdict:** Buildable — but NOT as a single “Bluetooth-call-everywhere” app. Feasible as a **hybrid mesh**: `BLE (discovery + text) + Wi-Fi Direct/Aware (media + voice) + store-and-forward + opportunistic routing`. Voice = push-to-talk walkie-talkie, not cellular-grade full duplex. See analysis inside.
