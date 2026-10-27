# 10. Local development, CI and monitoring

How to build, test, verify and publish this repository from your own machine — and why the
local pipeline is a copy of the remote one rather than a separate idea about what "passes"
means.

Two things make this document necessary rather than a README paragraph.

The first is that this repository has **two engines that must agree**: a TypeScript reference
implementation under `src/` and an authoritative Dart engine under `sim/mesh_sim/`. They share
golden vectors in `test-fixtures/golden-vectors.json`, so a change to one that is not mirrored
in the other is a build failure and not a style difference. Verifying half the repository is
worse than verifying none of it, because it produces a green light that means something
narrower than it appears to.

The second is that **CI on this repository has been unavailable**. GitHub Actions refuses to
start jobs here with *"The job was not started because recent account payments have failed or
your spending limit needs to be increased."* That is an account problem, not a code problem, and
it is not fixable from a branch. Until it is resolved under **Settings → Billing & plans**, the
local pipeline in `tool/ci/` is the only way to verify a change — which is exactly the situation
this document and those scripts were written for.

---

## 1. What you need

| Requirement | Version | Why this one | Optional? |
| --- | --- | --- | --- |
| **Node.js** | **22.x** | `actions/setup-node` pins `node-version: 22` in `ci.yml` | no |
| **npm** | 10.x (ships with Node 22) | CI runs `npm ci`, which needs `package-lock.json` | no |
| **Dart SDK** | **stable, ≥ 3.4.0** | `dart-lang/setup-dart` pins `stable`; `sim/mesh_sim/pubspec.yaml` pins `sdk: ^3.4.0` | no — see §2 |
| **Git** | 2.30+ | the push gate inspects ancestry before pushing | no |
| **Python 3** | 3.9+ | `tool/ci/diagnostics.py`, shared with the workflow | no |
| **`gh`** (GitHub CLI) | 2.x, authenticated | `make watch` / `make diagnose` read remote runs | yes |
| **Docker + `act`** | any recent | runs the real workflow YAML in a container (§7) | yes |
| **GNU Make** | 4.x | the `make` front ends | yes, but recommended |

Check all of it at once:

```bash
make doctor
```

`doctor` does not just ask whether the tools exist — it compares what you have against what CI
pins, because the failure worth catching is a toolchain that is present and *different*. It also
probes `registry.npmjs.org`, `pub.dev` and `api.github.com`, since a restricted network makes
`npm ci` and `dart pub get` fail in ways that look like code errors.

It exits nonzero when something required is missing, and prints the install command for your
platform when it is.

**On Windows 11**, read `docs/11-windows-11-workflow.md` first: the runtime choice (WSL2 vs Git
Bash), the two configuration steps that are easy to miss (`core.longpaths`, and the line endings
`.gitattributes` now pins), and how to run the commands natively when there is no bash at all.

---

## 2. Installing the Dart SDK

This is the step that gets missed, because the TypeScript half of the repository works perfectly
well without it and CI is normally what catches the gap. With CI unavailable, nothing catches it.

**macOS**

```bash
brew tap dart-lang/dart
brew install dart
dart --version
```

**Linux (Debian/Ubuntu, including WSL)**

```bash
sudo apt-get update
sudo apt-get install -y wget gnupg apt-transport-https

wget -qO- https://dl-ssl.google.com/linux/linux_signing_key.pub \
  | sudo gpg --dearmor -o /usr/share/keyrings/dart.gpg

echo 'deb [signed-by=/usr/share/keyrings/dart.gpg arch=amd64] https://storage.googleapis.com/download.dartlang.org/linux/debian stable main' \
  | sudo tee /etc/apt/sources.list.d/dart_stable.list

sudo apt-get update && sudo apt-get install -y dart
echo 'export PATH="$PATH:/usr/lib/dart/bin"' >> ~/.bashrc && source ~/.bashrc
```

**Any platform, no package manager**

Download `dartsdk-<os>-<arch>-release.zip` from
`https://storage.googleapis.com/dart-archive/channels/stable/release/latest/sdk/`, unzip it
anywhere, and put its `bin/` directory on `PATH`.

Then fetch the package's dependencies once:

```bash
cd sim/mesh_sim && dart pub get
```

The only dependency is `package:test`. If `pub.dev` is unreachable from your network, this step
will fail and the Dart jobs cannot run — `make doctor` tells you before you find out the slow way.

---

## 3. First-time setup

```bash
git clone https://github.com/eTarikhi/DumanMessenger.git && cd DumanMessenger
make doctor          # confirm the toolchain before anything else
make install         # npm ci + dart pub get
make install-hooks   # pre-push gate; skips a push that would fail CI
make ci              # the whole pipeline, locally
```

`npm ci` now does this for you: `package.json`'s `prepare` script runs `git config
core.hooksPath .githooks`, which is the first command every setup path in this document and in
`docs/11` §1 already tells a new machine to run. Before that the gate was opt-in and a fresh clone
had none, because git will not install a hook by itself. `make install-hooks` sets the same
`core.hooksPath` to `.githooks`, which keeps the hook in version
control where it can be reviewed and updated, instead of in `.git/hooks` where it is invisible
and per-clone. Bypass a single push with `git push --no-verify`.

---

## 4. The development loop

```bash
make dev             # the React visualiser (ALLOW_ANY_DEV_HOST=1 for proxied previews)
make test            # vitest run — the TypeScript suite
make typecheck       # tsc --noEmit -p tsconfig.json
make dart-test       # dart test --reporter expanded
make dart-analyze    # errors and warnings fail; infos do not
make golden          # regenerate the cross-language vectors and show the diff
```

Two habits this repository rewards:

**Run `make golden` and commit the result whenever you touch either engine's RNG, spawn order or
scheduling.** The golden vectors are the contract between the two implementations. CI fails if
`npm run golden` changes the committed file, so finding that out locally costs seconds and
finding it out remotely costs a push and a red build.

**Use the probes to measure a mechanism rather than reasoning about it.** Almost every conclusion
in `docs/06`, `docs/08` and `docs/09` is a number from one of these:

```bash
make media                       # every section of docs/08's radio work
make media SECT=captureEffect    # one section — the whole probe is minutes of simulation
make history                     # docs/06 §17, group-history anti-entropy
```

`npm run media` accepts a section name because re-measuring one lever should not mean
re-measuring eleven others to get at it.

---

## 5. Running the CI pipeline locally

```bash
make ci          # all five jobs
make ci-fast     # typecheck, unit tests, dart analyze, dart test
make web         # one job
make dart
make cli-matrix
make probes
./tool/ci/run-pipeline.sh --list          # exactly what each job runs
./tool/ci/run-pipeline.sh --job dart,probes --keep-going
```

### It is a runner, not a reimplementation

Every command in `tool/ci/run-pipeline.sh` is the command `.github/workflows/ci.yml` runs, in the
order it runs it — including three behaviours that are easy to drop and expensive to lose:

1. **The `dart` job runs all three of its checks unconditionally and gates afterwards**, so a
   single red build reports the analyzer output, the test failures *and* the CLI metrics together
   instead of stopping at the first. `set -e` is deliberately not used.
2. **`cli-matrix` and `probes` have `needs: dart`**, so they never quietly run anyway on a
   tree that is already known to be broken. Which verdict they get depends on *why* Dart did
   not run, and that difference is the point:

   | `dart` was | downstream | meaning | `--allow-missing-dart` |
   | --- | --- | --- | --- |
   | `MISSING` (no SDK) | `MISSING` | a toolchain gap on this machine | excuses it → exit `2` |
   | `FAILURE` (ran, red) | `BLOCKED` | a real broken build | **does not** → exit `1` |

   Conflating the two would either make a Dart-less machine unable to push at all, or let a
   genuinely red engine through because someone had set a flag intended for a missing SDK.
   The flag excuses an absent toolchain; it never excuses a failing one.
3. **The golden-vector step fails when regenerating changes the committed file.** That check is
   the cross-language contract, and it is the one most often forgotten locally because it needs
   two commands rather than one.

### Exit codes, and the one that matters most

| Code | Meaning |
| --- | --- |
| `0` | every selected job ran and passed. Verified. |
| `1` | something failed, **or something could not run** |
| `2` | partial — only with `--allow-missing-dart` |
| `64` | bad usage |

> **Through `make`, codes `1` and `2` are both reported as `2`.** GNU make exits `2` for any recipe
> failure and has no way to hand a recipe's own status back, so the `1`-versus-`2` distinction —
> failed versus partial, which is the whole point of having two codes — does not survive the `make`
> front door. Measured rather than inferred: `./tool/ci/run-pipeline.sh --job dart` exits `1`,
> `make dart` exits `2`, and `run-pipeline.sh --job dart --allow-missing-dart` exits `2`, so on a
> machine with no Dart SDK the two verdicts are indistinguishable through `make` alone. It survives
> when you call the script directly, and on Windows through `.\make.ps1`, which runs the script
> rather than `make` for every target in its script table. If you are scripting against a verdict,
> call the script; if you are reading a report, the verdict is printed in it either way.

**A job that could not run is a failure, never a silent skip.** On a machine without the Dart
SDK, `make ci` fails and marks three of five jobs `MISSING` — the pipeline exits `1` and make
reports `2`, for the reason above. That is the single most
important design decision in `tool/ci/`: a green local run that quietly omitted the authoritative
engine would be worse than no local run at all, because it is the kind of thing you stop checking.

`--allow-missing-dart` exists for working anyway, and it returns `2` — never `0`. Exit code `0` is
reserved for a run that verified everything it claimed to.

### Artifacts

Every step's output is captured, mirroring the workflow's `/tmp/dart-*.txt`:

```
artifacts/ci/20261023T193803Z-ab7e7ff-push/
  web-npm-ci.txt       dart-pub-get.txt      dart-diagnostics.json
  web-typecheck.txt    dart-analyze.txt      dart-diagnostics.txt
  web-test.txt         dart-test.txt         cli-campus_quad-always-on.txt
  web-golden.txt       dart-cli.txt          cli-festival_crowd-always-on.txt
  web-build.txt                              probe-sos.txt   probe-history.txt
  <name>.exit — every step also records its numeric exit status
                                             probe-group.txt probe-media.txt
```

`artifacts/` is git-ignored: these are a local record, not a deliverable, and committing them
would mean every push carried the previous push's logs.

### Every check at once: `make checks`

`run-pipeline.sh` is a mirror of the workflow, and the mirror is the point: §10 maps each of its
steps onto the workflow step it copies, so a green local run is evidence about the remote one.
Adding checks to it would break that claim. So the superset lives in its own script.

```bash
make checks            # every check, one pass, one report
make checks-list       # what it would run — runs nothing
make checks-evidence   # also reproduce the numbers published in docs/06–docs/09 (slow)

# Or both halves at once, which is what a daily run should use:
make daily             # the CI mirror + every check + the evidence probes, one DAILY.md (~27 min)
make daily-fast        # the same, minus the evidence probes (measured 11.5 min without Dart)
make daily-checks      # the full CI mirror + every check, no re-measuring
```

Every run also appends **one line to `reports/verification-log.jsonl`**, which is tracked — the
only verification record in this repository that survives a wiped sandbox. Everything else it
produces lands under `artifacts/`, which `.gitignore` excludes, so the evidence about a given sha
was destroyed by exactly the event it exists to explain. The line is a digest and not a log:
verdict, exit codes, per-check counts, tool versions, elapsed seconds and the artifact directory
name, about 300 bytes, no captured output. It is uncommitted when written, because the sha it
describes is already committed, and the script prints `git add reports/verification-log.jsonl`
rather than committing on your behalf.

Three differences from `make ci` matter:

**1. It records which checks have never been run.** Every check has a registry row —
`name | label | verified-before? | what it catches` — and `make checks-list` prints it:

```
── dart — Dart authoritative engine — NEVER COMPILED on the current tree
  pub-get                  NEVER RUN      dart pub get
                           catches: the package resolving at all — this has never been run on this tree
  analyze                  NEVER RUN      dart analyze (errors and warnings fail)
                           catches: whether the radio-model and byte-counting mirrors COMPILE at all
```

This is the reason the script exists. Remote CI has been refused for billing since `8406717`, and
the workspace that produced the Dart capture-effect mirror had no Dart SDK. An entire half of the
repository reached `main` without ever being compiled. A wall of green means very little when some
of the checks behind it have never executed anywhere, so the report separates
`success` / `failure` / `not-run` in the console table, in a `verified before?` column, and in the
JSON — and `(first ever run)` is printed next to a check that passes for the first time.

**2. It never stops early.** A failure in check 3 does not hide check 4; everything is collected
and reported together, which is what you want when a run costs minutes and you cannot watch it.

**3. It writes something you can send back.** After the console table it prints a paste-back block:

```
DUMAN-CHECKS 82d967a 2026-10-24T02:29:05Z node=22.22.3 dart=MISSING
ts.npm-ci=success
ts.test=success(Tests  276 passed)
dart.analyze=not-run(no Dart SDK)
--- why nothing could run ---
no check failed; 4 could not run for want of a toolchain:
missing: the Dart SDK is not installed
```

When something *did* fail, that trailer becomes `--- first failure detail ---` with the tail of the
capture, and `--- dart diagnostics ---` with `file:line:col` locations from `diagnostics.py` — the
same parser CI publishes as annotations. The block prefers a real failure over a whole-group skip,
so a missing toolchain earlier in the list cannot bury the output that explains the break.

The Markdown report goes to `artifacts/ci/<run>/REPORT.md` (`--report` to choose), the JSON to
`--json`. Groups are `docs`, `ts`, `dart`, `cli`, `probes`, `evidence`; the first five run by default and
`evidence` is opt-in because it re-runs every published measurement, minutes each.

`docs` runs first and needs no toolchain at all, which is why it carries five checks rather than
one — on a machine where nothing else can run, this group still gives an answer. A sixth row runs
their self-tests, which is not a sixth check so much as evidence the other five are not broken.

1. **`drift`** — `tool/ci/check-docs.py`, asking whether every command these documents tell you to
   run actually exists, reading the answer out of the programs rather than out of the prose. It is
   here because this repository keeps making that mistake: two probe section names were once
   documented that `tool/media-probe.ts` does not have, and four real Dart CLI flags were missing
   from the cheat sheet. `make check-docs` runs it alone. Every check has a fault injected into a
   copy of the tree by `--self-test`, which prints its own case count, and two of them were added
   the same day as the thing they guard. **`ci-jobs`** asks whether `.github/workflows/ci.yml` and
   `run-pipeline.sh`'s `JOBS_ALL` still name the same jobs. They are maintained in two places by hand, and the local
   pipeline's whole claim to be evidence about the remote one rests on them agreeing — a job in the
   workflow the pipeline does not run means a green local run says nothing about it, and a job the
   pipeline runs that the workflow does not means CI is laxer than the local gate.
   **`section-counts`** asks whether a documented *number* of probe sections equals the number the
   probe has, and it was written for a defect found by accident: the README said `npm run media`
   had 17 sections for as long as the probe had eighteen, and every check passed, because a count
   is not a name and `media-sections` only reads names.
   **`ci-checkers`** asks a question one level down from `ci-jobs`: the workflow's `checks` job,
   `run-pipeline.sh`'s `job_checks` and `collect-checks.sh`'s `docs` group are three hand-kept lists
   of the same scripts, and comparing only job *names* cannot see a step missing inside one of them.
   That is how `check-ps1.py` came to be run by nothing automated at all — it had a `make` target and
   three lists that did not mention it. The check compares the three sets, and also asks whether any
   `tool/ci/check-*.py` on disk is run by none of them, because a checker with a target and no
   automation is indistinguishable from no checker. Two subtleties its self-test forced out: a step
   *label* naming a script is not an invocation (every entry point labels its step that way, and
   counting mentions let a deleted invocation pass), and a `--self-test` run is not running the check.
   **`ci-jobs`** also requires every job in `JOBS_ALL` to be described by `run-pipeline.sh --list`
   and named by its `--job` help line, because §10 tells a reader `--list` prints the mapping "from
   the script itself" — and the `checks` job, the one whose purpose is catching drift, was in
   neither.
2. **`dart-balance`** — `tool/ci/check-dart-balance.py`, delimiter balance across all 22 Dart
   sources in `sim/mesh_sim`, needing no Dart SDK. `make dart-balance` runs it alone. It is not
   `dart analyze` and does not claim to be; it exists for exactly the situation this repository is
   in, where the authoritative engine is written in a language no machine in the pipeline can
   compile.
3. **`parity`** — `tool/ci/check-parity.py`, asking whether the two engines still agree.
   `make parity` runs it alone. This is the check the current pipeline most
   needs and least expects: `make golden` catches a changed constant on the TypeScript side
   and `dart test` on the Dart side, and **neither can run where there is no Dart SDK**, which is
   everywhere in this pipeline right now. It asks three questions, and the third is stricter than
   the first two on purpose.

   It pairs **every constant it can match by name** across `src/*.ts` and `sim/mesh_sim/lib/src/*.dart`
   (`make parity` prints the count, split into the ones compared numerically and the ones compared by
   expression, which is why no number is written here — three in this section had gone stale while
   every check still passed) —
   including module-private ones, since Dart's `_pdrWindow` and TypeScript's `PDR_WINDOW` are the
   same contract. It does **not** require the two constant inventories to match, because they are
   not supposed to: `broadcastAddress`, `defaultConfig` and `ln10` have no TypeScript counterpart
   by design (`make parity` lists the one-sided names on both sides, and reading that list is how
   `mask` was found missing from this sentence), and a check demanding symmetry would need an
   exception list long enough to hide what it was for. One-sided names are listed rather than failed, which is how the checker found
   `MPR_WAIT_MS` / `mprWaitDefaultMs` — a synonym pair it had been silently skipping.

   It reads `docs/03` §3's coverage-score weight vector out of both engines, requiring the five
   weights to match each other and sum to 1 — if they do not, the 0.60 promote and 0.50 demote
   thresholds mean something other than what §3 says.

   And it requires two *type* inventories to be **identical**: `SimConfig` and `SimulationStats`,
   field for field, with none one-sided — both counts printed by `make parity` and by
   `make dart-sites`, and both larger than the numbers this paragraph used to carry, which is what
   happens to a count in prose when a feature adds knobs. Both were verified to match exactly
   before the rule was written, which is what makes it safe for the rule to fail rather than
   report. The mistake it exists for is the easiest to make in a two-engine repository and the
   hardest to see without a compiler: a knob added to one engine and not the other, so an
   experiment that set it silently configured half the contract; or a statistic only one engine
   reports, so `--json` and the React dashboard are not the same contract on both sides and a
   consumer reads `undefined` from one of them. Nothing else in the pipeline would notice either.

   The rule does **not** extend to the shared enums, and the reason is not that they cannot be
   parsed. They can: mask comments and strings on both sides, walk to the *matching* brace rather
   than the first one at column zero, and every one of the thirteen enums named on both sides
   agrees on its member count today — `ChannelAccess` 3, `ChannelBackoff` 2, `ChannelCapture` 3,
   `ChannelPriority` 3, `EventKind` 14, `ForwardMode` 6, `HopAction` 7, `MeshLogKind` 13,
   `MsgType` 8, `PeerNorm` 2, `RelayPolicy` 3, `Role` 2, `TransportType` 3. (Two earlier attempts
   at that parse disagreed with this list because they read prose out of doc comments and stopped
   at the wrong brace, which is why the numbers were measured before being written down.)

   The obstacle is that the two languages are *supposed* to spell the members differently, in
   three ways at once: Dart cannot use `super` or `class` as identifiers, so `Role.superNode` is
   TypeScript's `"SUPER"` and `ChannelPriority.byClass` is its `"class"`; Dart writes lowerCamel
   where TypeScript writes kebab-case (`halfDuplex` / `"half-duplex"`, `waitMpr` / `"wait-mpr"`,
   `floodAll` / `"flood-all"`); and Dart's `EventKind.ackTimeout` is TypeScript's `"acktimeout"`.
   Eight of the enums also exist in TypeScript only as unnamed unions inline in `SimConfig`, so
   they cannot be paired by name at all. Comparing them would need an alias table covering all
   three conventions — precisely the exception list long enough to hide what the check was for,
   which is why the constant inventories are reported rather than required to match. Measuring the
   counts by hand once, and writing the result here, costs less and lies less.
4. **`dart-sites`** — `tool/ci/check-dart-sites.py`, asking whether the Dart engine's *repeated*
   declarations are all present. `make dart-sites` runs it alone. The Dart engine repeats every
   `SimConfig` field at up to five places (declaration, constructor parameter, `copyWith`
   parameter, `copyWith` body) and every `SimulationStats` field at four (declaration,
   `required this.` parameter, `toJson()` entry, and the construction site in `_computeStats`),
   plus one `case` per `EventKind` value. The sites are hundreds of lines apart, `sim/mesh_sim`
   cannot be compiled here, and the failure modes are not all loud: a stats field missing from
   `toJson()` compiles and runs and simply never appears in `--json` output — which is what
   commit `f18c5c6` found 32 of — and a `copyWith` parameter with no body assignment compiles and
   *silently keeps the old value*, so an experiment that thinks it set a knob did not. It walks a
   comment-and-string-masked copy of the file at identical offsets, because doc comments inside a
   parameter list contain unbalanced parentheses, and it understands all three member shapes Dart
   uses here: block bodies, bodyless `const` constructors, and expression bodies
   (`copyWith({...}) => SimConfig(...)`). It also resolves **every qualified reference in the
   package** — 748 of them against 84 declared types — so a receiver that is not a declared type
   and an enum member that does not exist are both caught. Those are the two mistakes a compiler
   catches instantly and nothing else here could see, and both were typed into `sim/mesh_sim` for
   real during the week the check was written: `OgmiIntervalMode` for `OgmIntervalMode`, and a stub
   function referencing a `_Never` type that did not exist. Each was found by hand and fixed before
   commit, which is luck rather than a process. The scan runs on masked text, so a `Role.normal` in
   a doc comment is not a reference — a fact the self-test depends on, since one of its faults had
   to be re-aimed at a use in code after its first occurrence turned out to be inside a comment.
   `values` and `index` are allowed on every enum because Dart provides them, and five SDK types
   with static members are allowlisted by name; the failure message tells a maintainer to add a
   sixth deliberately rather than loosen the rule, because a permissive version of this check
   cannot see the typo it exists for.

   Two things it does **not** check, both measured before being declined. It does not verify that a
   called *function* exists: 321 distinct call sites against a regex-collected declaration set
   leaves 13 names unresolved, of which six are `package:test` matchers, one is the `catch`
   keyword, and six are local helpers declared inside test bodies in forms the declaration regex
   cannot see. That is what separates it from the type and import checks, whose undeclared surfaces
   measured five and zero — Dart's function *declaration* syntax (nested, closures bound to
   variables, `async`, getters, extensions) is varied enough that a regex declaration set is
   incomplete, and an incomplete declaration set produces false positives rather than misses.
   Nor does it check argument counts or types, for the same reason plus Dart's optional,
   positional-optional and named parameters. Six names to allowlist and six declaration forms to
   support is a parser, and a check that needs one should not pretend otherwise.

   The same reasoning was applied to a fifth question before it was added: is every type a file
   names reachable from that file's *own* imports? Dart resolves names through `import` and
   `export` and nothing else, so using a type from `types.dart` inside `simulation.dart` without
   importing it is a compile error, and it is the error a cross-file feature introduces silently —
   which is what every feature added this month was, putting a new enum in one file and using it
   from another. Measured first, and the measurement was wrong the first time: parsing import
   specifiers from the masked copy finds none at all, because a specifier *is* a string literal
   and masking strings is what lets the reference check ignore prose. That reported 193 problems
   on a clean tree and looked like a check worth abandoning; parsed from the raw text with the
   barrel's exports followed one hop, it reports zero and is worth having. Both numbers are
   recorded here because the difference between them is the whole judgement, and a reader who
   only saw the second would not know the first was a bug in the measurement rather than in the
   engine.
5. **`ps1`** — `tool/ci/check-ps1.py make.ps1`. The Windows entry point has 21 targets (`check-docs.py`
   prints the count, so a stale number here is detectable; a line count is not) that no Linux runner can execute and no PowerShell-less sandbox can even parse, so this is a
   *static* check in four classes: delimiter balance; PowerShell-7-only syntax (`??`, `?.`, the
   ternary, `&&`/`||` as pipeline chain operators, `$PSStyle`) that fails on the Windows PowerShell
   5.1 that Windows 11 actually ships, with a message that does not say "your PowerShell is too old";
   a pass-through parameter PowerShell cannot bind positionally — a `ValueFromRemainingArguments`
   parameter with no `Position`, or one whose siblings stay positionally bindable; and a repository
   root computed by climbing above the directory that holds the script. Neither of the last two is
   theoretical. On 2026-10-27 the first real Windows 11 execution of `.\make.ps1 doctor` failed with
   *Cannot validate argument on parameter 'Runtime'*, and the second — after that was fixed, on the
   same machine, minutes later — failed with `bash: /mnt/c/Users/…/Git-Clones/tool/ci/doctor.sh: No
   such file or directory`, because the script took the parent of its own directory as the repository
   root. A pass is still never evidence the script ran, and both times it ran the reason it failed was
   something this check did not yet cover; each failure became a class. See `docs/11` §3 and §9. Until it was wired into this group it had a `make` target and no automation:
   the workflow, the CI mirror and the collector all skipped it, so the front door was checked only
   when a human typed `make check-ps1`.
6. **`checker-self-test`** — the `--self-test` modes of the four checkers that have one
   (`check-ps1.py` does not). `check-docs.py` injects a fault per defect class into a copy of the
   tree and requires each to be caught *and named* — 14 cases today, three of them added the same day
   as the drift they guard; `check-dart-balance.py` runs 19 snippets, 12 of which are clean and must
   not alarm; `check-parity.py` breaks a synthetic two-engine fixture in 12 ways;
   `check-dart-sites.py` breaks the real engine in memory in 12 ways and requires each to be named.
   Every one of those four numbers is printed by the tool that owns it, and all four were read off that output rather than
   carried over from an earlier revision of this paragraph — which is how two of them came to be
   wrong by one while every check still passed. This row exists because all
   four checkers have found bugs in themselves: `check-docs.py` caught its own
   `.sh`-stem regex and `make help`'s digit-blind grep, `check-dart-balance.py` caught itself
   holding a string delimiter beside the stack instead of in the frame, which made it report
   `mesh_sim.dart`'s usage text as an unterminated string, and `check-dart-sites.py` caught itself
   brace-walking into a parameter list so it never saw a body, missing expression-bodied members
   altogether, then reporting four correctly formatted `copyWith` assignments as broken because
   `dart format` had wrapped them across two lines, and — on the day the reference check was added
   — reporting **265 false positives** because its enum parser matched to the first `}` at column
   zero, which over-runs a one-line enum like `enum ChannelAccess { free, halfDuplex, csma }` and
   swallows the declarations after it. That parser had been harmless while its only consumer was
   `EventKind`, which is multi-line, and became wrong the moment a second check depended on it. A
   check that reports 265 problems on a clean tree gets ignored, and then it is worse than no
   check at all. A check that always passes is
   indistinguishable from a broken one, and nothing else in the pipeline would notice.

Exit codes: `0` everything passed · `1` something failed **or could not run** · `64` bad usage.
There is no `2` here. `run-pipeline.sh` grades the machine as well as the code, which is why it has
a `partial` verdict and `--allow-missing-dart`; this script grades the code only, and a check it
could not run is a check that did not pass.

---

## 6. Validating and pushing

```bash
make push                                    # full pipeline, then push — refuses on red
make push-dry                                # everything except the push
make commit-push MSG="fix: the retry timer"   # commit the tree, validate, push
make push-force                              # push after a PARTIAL run, recorded as partial
```

`tool/ci/validate-and-push.sh` runs the pipeline first and pushes only on success. The order is
the point: `git push` after a green build is a convenience, `git push` *conditional* on a green
build is a gate, and the difference only shows up on the day something is red.

It also checks whether the push will fast-forward **before** running the pipeline, so a rejected
push does not cost you four minutes of simulation first, and it refuses to `--force`.

### Two gates, and how they avoid running the suite twice

There are two independent gates: this script, and the `pre-push` hook from §3, which fires on any
`git push`. Left to themselves they run the same test suite twice per push — roughly seven minutes
for no additional information, which is enough to make people reach for `--no-verify` and lose both.

So the script skips the hook **only when its own run already covered every job**, and says so
(both gates append to the same verification log, so skipping one does not lose the record):

```
==> pushing to origin/arena/5ce83e54-dumanmessenger
    skipping the pre-push hook: this run already covered every job it would have
```

A scoped run is narrower than the hook, so there the hook keeps its say:

```bash
./tool/ci/validate-and-push.sh --job web --no-commit   # script verifies web; hook runs the fast subset
git push                                               # hook is the only gate
```

The hook blocks on a **failed** run and warns on a **partial** one. That asymmetry is deliberate: a
missing optional toolchain is not a broken build, and treating it as one would make the repository
unusable rather than safe. What it must never do is stay quiet — so a partial push says out loud
that remote CI is the authority on the jobs this machine could not run, and that if CI is
unavailable the gap should be stated wherever the commits are described.

### Partial verification is recorded, not hidden

Because a machine without a Dart SDK is a real situation and not a hypothetical one, there is
exactly one escape hatch: `--force-partial` (or `make push-force`). It pushes, and it says so out
loud — in the run record and in an append-only log:

```bash
$ tail -1 artifacts/ci/verification-log.jsonl
{"timestamp":"<UTC>","branch":"<branch>","sha":"<short-sha>","verification":"<see below>",
 "jobs":"<the jobs that actually ran>","pipelineExit":<0|1|2>,"runId":"<artifact-dir>",
 "gate":"<pre-push|absent>","pushed":<true|false|null>}
```

Both gates write here, so the trail covers a bare `git push` and not only `make push`. `gate`
says which one. Records from the hook carry `pushed: null` **by design**: the hook runs *before*
the push, so it cannot know whether the push succeeds, and asserting success there would be the
same overclaim the log exists to prevent. Records from `validate-and-push.sh` start as `null` and
are rewritten to `true` once the push is known.

So a commit that was never fully verified stays discoverable later instead of looking like one
that was. If you use it, say so wherever the work is described — a report that claims a build
passed when a third of it could not run is worse than one that names the gap.

### What `verification` may say

The word "full" is easy to over-claim, so it is narrow by construction: it means *every job in
the workflow*, not every job you asked for.

| value | means |
| --- | --- |
| `full` | every job in the workflow ran and passed |
| `scoped:web` | everything **selected** ran and passed — and only `web` was selected |
| `partial` | a job could not run for want of a toolchain (needs `--allow-missing-dart`) |
| `…(fast)` | the fast subset; the production build, CLI matrix and probes were skipped |

A scoped run that is entirely green still says nothing about the jobs it left out, which is why
`--job web` records `scoped:web` and not `full`. Pushing that way is legitimate — the Dart engine
may be untouched by the change — but the record must not imply a Dart job ran when none did.
`jobs` names what actually ran, so the two fields cannot be read apart from each other.

### Opening a pull request, and deciding whether to merge it

```bash
make pr                                    # validate, push, open the PR, merge only if CI passes
make pr-dry                                # every decision printed, no side effects
make pr-open                               # open the PR and stop — leave merging to a human
make pr-local                              # merge on the local run alone; recorded as such
make pr-branch BRANCH=fix/your-change      # create the branch, then the whole flow
```

`tool/ci/pr-flow.sh` uses the same validation as `make push`, then adds the PR and the merge.
The judgement is in the merge step, and it is deliberately **not** "local validation passed, so
merge". Local validation gates *opening* the PR: it is fast and it stops you publishing something
broken. It is not sufficient for *merging*, because a local run is only as broad as the toolchain
installed locally — a machine with no Dart SDK verifies two jobs out of five (`checks` and `web`)
and cannot tell you the authoritative engine builds.

So `--merge-on` chooses what evidence a merge may rest on:

| | merges when | use it when |
| --- | --- | --- |
| `checks` *(default)* | every remote CI check passes | CI is healthy. The right default. |
| `local` | the local run passed | CI cannot run at all, and you are choosing to accept local evidence. Recorded in the PR body and the verification log. |
| `never` | it does not | you want a human to review first |

With `--merge-on checks`, a failed check is **classified before it is acted on**, using the same
`billing_block()` `make diagnose` uses. "The build is red" and "CI could not run" look identical in
a PR's check summary and need opposite responses: one means go and fix something, the other means do
not merge and say why. Reading "no checks reported" as "checks passed" is how unverified code gets
merged, so the script refuses and lists the options in order of how much truth they preserve.

`--json` writes the same verdict per run, with the toolchain versions it was produced with:

```json
{ "runId": "<artifact-dir>", "sha": "<short-sha>", "verification": "full",
  "toolchain": {"node": "22.22.3", "npm": "10.9.8", "dart": "3.5.4", "python3": "3.11.2"},
  "jobs": {"web": {"result": "success", "detail": ""},
           "dart": {"result": "failure", "detail": "test=failure"}} }
```

---

## 7. Monitoring remote CI

```bash
make watch                 # recent runs on this branch
make watch-all             # every branch      (./tool/ci/watch.sh --all)
make follow                # wait for the newest run, then explain it
make diagnose              # jobs + annotations for the newest failed run
make diagnose RUN=39934242890
```

`watch.sh` does two things `gh run list` does not.

**It reads the annotations.** A red Dart build publishes its diagnostics as annotations on the
check run, because the runner's generic problem matcher loses file paths and `$GITHUB_STEP_SUMMARY`
is not readable through the API at all. Fetching them takes three calls with a job id found by
name, which is fiddly enough that it does not get done by hand. `make diagnose` does it and prints
the analyzer errors and failing tests with real `file:line:col` locations.

**Superseded runs are cancelled.** `ci.yml` has a `concurrency` group per ref with
`cancel-in-progress` true for every ref but `main`, because successive pushes used to start one
pipeline each and six runs piled up in the 45 minutes while one feature landed — each already
superseded by the next before it had finished, which on a repository paying per minute is waste and
on a repository whose Actions is refused is six identical refusals in `make watch` instead of one.
A cancelled run is reported by `gh` as `cancelled`, not `failure`, and means nothing about the code;
the run for a merged commit on `main` is the record of what landed and is never cancelled.

**It distinguishes a build failure from an infrastructure refusal.** A job can fail without ever
running, and this repository has had exactly that. `watch.sh` checks for the billing message
before reporting anything else, because five jobs that never started are not five failures:

```
error: these jobs never started: GitHub Actions is refused for billing reasons.
       The annotation reads: "The job was not started because recent account
       payments have failed or your spending limit needs to be increased."

       This is not a build failure and no code change will fix it. Someone with
       access to the account has to resolve it under Settings → Billing & plans...
```

Note that **job logs cannot be downloaded from every network** — `results-receiver.actions.githubusercontent.com`
is frequently unreachable. When `gh run view --log-failed` comes back empty, the annotations are
the only machine-readable channel, which is precisely why the Dart job publishes them.

### The higher-fidelity path: `act`

`tool/ci/` runs the workflow's *commands* natively. If you want to run the workflow *file* —
container images, `needs:` edges, `continue-on-error`, the diagnostics step, the gate — install
[`act`](https://github.com/nektos/act):

```bash
brew install act        # or: go install github.com/nektos/act@latest
make act                # every job
make act JOB=dart       # one job
```

Two caveats. `act` needs Docker, and `dart-lang/setup-dart@v1` and `actions/setup-node@v5` need
network access from inside the container. On a restricted network, native `make ci` is the path
that works; `act` is the path that is most faithful. Use `act` before a release, `make ci`
while iterating.

---

## 8. Keeping the local and remote pipelines from drifting

A local runner is only worth having if a green local run predicts a green remote one. Two
mechanisms keep that true, and both are deliberate.

**The commands are copied, not paraphrased.** `run-pipeline.sh` names each step after the
workflow step it mirrors and runs the same command with the same flags in the same working
directory. When you change `ci.yml`, change `run-pipeline.sh` in the same commit — `make doctor`
prints the job count from the workflow so a new job is at least visible.

**One pipeline, two front doors.** `make.ps1` gives Windows 11 the same targets, and it is a
*dispatcher*: it finds WSL2 or Git Bash, translates the path, forwards your arguments unchanged and
returns the pipeline's exit code. It deliberately contains no pipeline logic. A second
implementation of the same policy — in PowerShell, or anywhere else — is a second thing that can
drift from the workflow while still looking green, which is the failure this section exists to
prevent. `tool/ci/check-ps1.py` statically checks it (delimiter balance, PowerShell-7-only syntax
that fails on the Windows PowerShell 5.1 Windows 11 ships, parameter binding that would make the
documented invocation fail, and a repo root computed from a false assumption about where the script
lives — the last two each found by a real Windows execution) because it cannot be executed on a Linux
runner. That check runs in the workflow's `checks` job, in `run-pipeline.sh --job checks` and
in `make checks`; it used to run in none of them, which is the drift `ci-checkers` in §5 now exists
to catch. See `docs/11-windows-11-workflow.md`.

**The diagnostics parser is one file both sides call.** `tool/ci/diagnostics.py` used to be an
inline heredoc inside `ci.yml`. That meant the local runner either duplicated it — and then the
two could drift, so a local run would report something different from the remote one — or went
without it. The workflow now calls the same file:

```yaml
- name: Publish diagnostics
  if: always()
  continue-on-error: true
  run: >-
    python3 ../../tool/ci/diagnostics.py --format github
```

It is worth being precise about what this parser does, because it is the reason a red Dart build
here is diagnosable at all. It reads the captured `dart analyze` output, whose field order differs
between SDK versions — so it locates the field ending in `:line:col` rather than assuming a
position — and the `dart test --reporter expanded` output, grouping each `<mm:ss> +n -m: name [E]`
block with the first `test/…dart line:col` frame inside it. It then emits
`::error file=…,line=…,col=…::` workflow commands plus a `$GITHUB_STEP_SUMMARY` section.

Locally it prints the same findings as readable text (`--format text`) or JSON (`--format json`),
so the parsing is exercised on every local run and cannot rot between CI runs.

The step is `continue-on-error: true`: deciding whether the build passed is the Gate step's job,
and a bug in a *reporter* should not fail an otherwise green build.

---

## 9. Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `make ci` exits 1 with jobs marked `MISSING` | a required tool is absent | `make doctor`, then install what it names |
| `make ci` exits 2 | you passed `--allow-missing-dart` | install Dart, or accept that this is a partial run |
| `cli-matrix` and `probes` say `BLOCKED` | `needs: dart`, and `dart` **failed** | fix the `dart` job; they will run once it passes |
| `cli-matrix` and `probes` say `MISSING` | `needs: dart`, and Dart is **absent** | install Dart (§2); this is partial, not broken |
| Golden vectors are stale | either engine's RNG, spawn or scheduling order moved | `make golden`, inspect, commit — or revert if unintended |
| `dart pub get` hangs or fails | `pub.dev` unreachable | `make doctor` probes it; you need network access to pub.dev |
| `npm ci` fails but `npm install` works | `package-lock.json` out of sync | regenerate and commit the lockfile; CI uses `npm ci` |
| `make watch` errors on auth | `gh` not logged in | `gh auth login` — never paste a token into the repo |
| `gh run view --log-failed` is empty | log host unreachable | `make diagnose`; annotations are the other channel |
| Every remote job fails instantly | **Actions billing** | Settings → Billing & plans. No code change helps. |
| `act` fails on `setup-dart` | no network inside the container | use native `make ci` instead |
| `npx tsc` installs a bogus `tsc@2.0.4` | `node_modules/` missing | `npm ci` first — never trust a bare `npx tsc` |
| A push is rejected after a green pipeline | remote moved ahead | the gate now detects this *before* running; pull or rebase |

---

## 10. Reference: workflow step → local command

| `ci.yml` job | step | local equivalent |
| --- | --- | --- |
| `checks` | Documentation drift | `python3 tool/ci/check-docs.py` |
| | Dart delimiter balance | `python3 tool/ci/check-dart-balance.py` |
| | Cross-language parity | `python3 tool/ci/check-parity.py` |
| | Dart declaration sites | `python3 tool/ci/check-dart-sites.py` |
| | PowerShell static check | `python3 tool/ci/check-ps1.py make.ps1` |
| | Checker self-tests | the same four scripts with `--self-test` |
| `web` | `npm ci` | `npm ci --no-audit --no-fund` |
| | Typecheck | `npx tsc --noEmit -p tsconfig.json` |
| | Unit + acceptance tests | `npm test` |
| | Golden vectors are up to date | `npm run golden` + `git diff --quiet -- test-fixtures/golden-vectors.json` |
| | Production build | `npm run build` |
| `dart` | Resolve Dart dependencies | `cd sim/mesh_sim && dart pub get --enforce-lockfile` once `pubspec.lock` is committed; plain `dart pub get` with a warning until then |
| | Analyze *(continue-on-error)* | `dart analyze` → `artifacts/…/dart-analyze.txt` |
| | Tests *(continue-on-error)* | `dart test --reporter expanded` → `dart-test.txt` |
| | CLI acceptance *(continue-on-error)* | `dart run bin/mesh_sim.dart --scenario campus_quad --seed 42` → `dart-cli.txt` |
| | Publish diagnostics | `python3 tool/ci/diagnostics.py --format text` |
| | Gate | all three outcomes must be `success` |
| `cli-matrix` | 4 scenarios × power model | 5 combos; only `campus_quad` is gated, so only it has a duty-cycle arm |
| `probes` | SOS, group, history, media | the same four commands with `--no-check` |

`./tool/ci/run-pipeline.sh --list` prints this mapping from the script itself, so the table above
and the runner cannot disagree for long.

---

## 11. What this machine cannot do

`make doctor` asks whether a machine can verify this repository. `make blockers`
(`tool/ci/blockers.sh`) asks the other question — the one that decides when work on this project
stops: **why is it not finished?** The two overlap on the Dart SDK and nowhere else, because most
of what stops this project is not a missing tool. It is an egress rule, a refused CI account, a
radio that does not exist in a container, and fifteen people standing in a quad.

```bash
make blockers                              # 27 rows, about 20 s
./tool/ci/blockers.sh --strict             # exit 3 if a row this machine *can* fix is wrong
./tool/ci/blockers.sh --json artifacts/blockers.json
.\make.ps1 blockers                        # Windows
```

Every row is measured when the script runs, and the measurement is printed next to the verdict,
so a conclusion can be disputed by reading its evidence instead of trusting the prose. The one
row that cannot be probed says so in the evidence column rather than inventing a number.

### The six sections, and what they found on 2026-10-26

**A · toolchain.** `dart` absent, and its SDK host unreachable — `storage.googleapis.com` →
`curl exit 35, HTTP 000, 0 bytes`. That is the load-bearing one: `sim/mesh_sim` is the
authoritative engine, **22 Dart files / 15 200 lines**, and not one of them has ever been
compiled on the machine that wrote them. `flutter` absent, so the roadmap's `app/` cannot be
built, run or screenshotted. `pub.dev` unreachable, so `pubspec.yaml` is frozen at what it
already lists — no Opus codec, no SQLite plugin, no BLE plugin — and `pubspec.lock` cannot be
generated here either, so Dart dependency resolution is not reproducible from this machine: CI
resolves `test: ^1.25.0` afresh and publishes a warning annotation saying so until somebody commits
a lock (§2, `docs/11` §2). `pwsh` absent *and not
installable*: the release page answers (`HTTP 200`) and the asset redirects to
`objects.githubusercontent.com`, which is outside the egress allowlist, yielding `0 bytes` — so
`make.ps1` and the whole of `docs/11` are checked statically by `check-ps1.py`; the two executions
anywhere — both on Windows 11, 2026-10-27 — failed, first at parameter binding and then on a repo
root computed one directory too high, which are the defects `check-ps1.py`'s third and fourth classes
now catch. That static check is now part of all three entry points rather than
something a person had to remember to run. `node v22.22.3` and `python3 3.11.2` are present, which is why the TS
reference engine and the five stdlib-only checkers do run here.

**B · egress.** Eight hosts probed, four blocked: `pub.dev`, `storage.googleapis.com`,
`objects.githubusercontent.com`, `results-receiver.actions.githubusercontent.com`. Redirects are
followed and the delivered byte count is read, because a 302 with nothing behind it is the exact
shape of the failure here — a probe that stopped at the first response would report the Dart SDK
as installable. The last of the four is why CI log download fails: `gh run view --log-failed`
returns empty, and the only machine-readable channel left is check-run annotations
(`make diagnose`).

**C · remote CI.** The newest run is `failure … classified 'billing'` — jobs are refused before
they start, with *"recent account payments have failed or your spending limit needs to be
increased"*, and `gh run rerun` is refused too. The last green run was **2026-10-23T08:46:52Z**
(`8406717`), with **82 non-success runs since**. So every verification claim after that timestamp
is local-only: `run-pipeline.sh` mirrors the workflow step for step, but nothing has executed it.
This is not fixable from a branch; it needs the account's billing settings.

**D · hardware.** No `/sys/class/bluetooth` entries, no wireless phy under `/sys/class/net`, no
`iw`, no `adb`, and a Linux host with no `xcrun`. That closes the BLE GATT hello, the iOS beacon,
Wi-Fi Direct, Wi-Fi Aware, the permissions and foreground-service work, and every iOS item —
including the v0.9 launch, because Apple's toolchain does not run on Linux at all. One row is not
a probe and is labelled that way: a crowd of fifteen people carrying phones. `skills/08` already
forbids claiming large-scale results without it.

**E · repository.** The rollback signature, and the only section whose rows this machine can fix.
`git-head` compares HEAD with `origin/<branch>` and separates *ahead* from *behind*, because only
behind is drift: unpushed local commits are the normal state of a working turn, and flagging them
would make `--strict` fail between every commit and its push. `git-worktree` is deliberately
narrower than "is the tree dirty" — dirt is ordinary work in progress, whereas a tracked file
whose content is **byte-identical to the base commit** is a snapshot restored from before the work
landed, and committing it pushes a revert. Both signatures were tested by fabricating them:
reverting `README.md` to its base content, and resetting HEAD to `origin/main`.

**F · roadmap.** All 28 open items read out of `roadmap/roadmap.md` and classified by what closing
them would take, each printed with the rule that matched it so the classification can be argued
with row by row: **5 need people** (field test, crowd, external audit, launch, community relay),
**2 a store account and signing key**, **10 a handset or an OS API**, **10 the Dart/Flutter
toolchain**, and **1 can be written from here** — line 383, the privacy policy, whose crypto-export
half is already in `docs/04` §7. The list is regenerated on every run and deliberately never
transcribed into a document: a table copied by hand is stale the day a roadmap line moves, and this
one reads the file.

That one item was then written, the same day the classifier named it: `PRIVACY.md`, at the root
where a store listing expects it. The box stays open, and the reason is in the roadmap note — a
privacy policy needs a data controller and this repository has no legal entity behind it, so
Article 13's identity-and-contact requirement is unmet, and it needs counsel, which is not
engineering work. The classifier's answer was therefore right and incomplete in the useful way: it
found the only open item whose *documents* could be produced here, and producing them exposed the
two things that cannot be. `make blockers` still reports 28 open items; it does not know, and
should not guess, that one of them is now waiting on a lawyer rather than on a compiler.

### Why it is not a row in `make checks`

It always exits 0. "This machine has no Dart SDK" is a fact about the machine rather than a defect
in the repository, and a row that can only pass would sit in a pass/fail table as a permanent pass
— the opposite of what it is for. `--strict` is the exception: exit 3 on the three rows this
machine can actually fix (a rolled-back HEAD, a stale working tree, no `node_modules`), which is a
pre-push question and not a daily one.

`daily.sh` runs it as **step 0**, before both halves, and it does not affect the verdict. It runs
first for one reason: if HEAD has been rolled back to the branch point, the twenty minutes that
follow would measure a checkout that is not the pushed one, and the report should say so before
spending them. When that is the situation, `DAILY.md` opens its blocker section with a callout
naming the rows, and `daily.json` records them under `blockers.driftRows` with
`blockers.checkoutSuspect: true`.

### The three reasons the work stops, in the order they cost time

1. **The verification pass competes with the work for the same hours.** `npx vitest run` is 461
   tests and took **383 s** on this machine on 2026-10-26; the collector with evidence probes is
   about twenty minutes; the daily run about twelve without them. Re-proving what was already
   proved is not free, so the checks are collected into one dated artifact
   (`tool/ci/daily.sh`, `--prune N`, previous-run deltas) instead of being paid inline every round.
2. **The sandbox is rolled back between turns, and the rollback leaves no trace in the
   repository.** `node_modules` and `artifacts/` are wiped, and the local `.git` is reset to the
   branch point, so pushed work is present only as uncommitted files that look exactly like new
   work. It happened fifteen times on this branch by 2026-10-27 — twice while this section was being
   written, once while a Windows transcript was being answered — and
   each time it costs a `git fetch`, a `git reset --mixed origin/<branch>`, an `npm ci` and a
   re-run of the suite before anything new can be written. Section E exists to detect it in about
   two seconds instead of at the end of a twenty-minute run. What a rollback cannot erase is
   `reports/verification-log.jsonl` (§5): counts and verdicts rather than captures, so "which shas
   were verified, and what was missing when they were" still has an answer afterwards.
3. **What is left is not code that can be written here.** Sections A–D are the reason, and section
   F prices it: of 28 open roadmap items, **none** is closable from this machine and all 28 need
   hardware, a store account, a toolchain that is not installable, a legal entity, or a crowd.
   Section F said 1 until 2026-10-27, when the row it counted — line 488, the legal documents —
   was reclassified from `sandbox` to `people`: `PRIVACY.md` had been written after the rule, and
   its own note keeps the box open for a data controller and counsel review, which is not writing.
   A classifier that contradicts the note it classifies is worse than none, so the count is 0. The remainder is not deferred
   work — it is the part of this project that was never going to happen inside a container. What
   *can* be produced here is the specification, the two engines, the checks and the measurements,
   for whoever has the phones.

### What the report deliberately does not claim

It does not say the project cannot be finished; it says which parts cannot be finished *here*, and
what each of those parts would need. On a machine with the Dart SDK, a handset and a CI account
that pays, section A shrinks to one row, section C goes green, and section F still lists the crowd
— because that row has no probe and never will.
