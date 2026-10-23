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

`make install-hooks` sets `core.hooksPath` to `.githooks`, which keeps the hook in version
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
make ci          # all four jobs
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

**A job that could not run is a failure, never a silent skip.** On a machine without the Dart
SDK, `make ci` exits `1` and marks three of four jobs `MISSING`. That is the single most
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
installed locally — a machine with no Dart SDK verifies one job out of four and cannot tell you the
authoritative engine builds.

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

**It distinguishes a build failure from an infrastructure refusal.** A job can fail without ever
running, and this repository has had exactly that. `watch.sh` checks for the billing message
before reporting anything else, because four jobs that never started are not four failures:

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
prevent. `tool/ci/check-ps1.py` statically checks it (delimiter balance, and PowerShell-7-only
syntax that fails on the Windows PowerShell 5.1 Windows 11 ships) because it cannot be executed on a
Linux runner. See `docs/11-windows-11-workflow.md`.

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
| `web` | `npm ci` | `npm ci --no-audit --no-fund` |
| | Typecheck | `npx tsc --noEmit -p tsconfig.json` |
| | Unit + acceptance tests | `npm test` |
| | Golden vectors are up to date | `npm run golden` + `git diff --quiet -- test-fixtures/golden-vectors.json` |
| | Production build | `npm run build` |
| `dart` | `dart pub get` | `cd sim/mesh_sim && dart pub get` |
| | Analyze *(continue-on-error)* | `dart analyze` → `artifacts/…/dart-analyze.txt` |
| | Tests *(continue-on-error)* | `dart test --reporter expanded` → `dart-test.txt` |
| | CLI acceptance *(continue-on-error)* | `dart run bin/mesh_sim.dart --scenario campus_quad --seed 42` → `dart-cli.txt` |
| | Publish diagnostics | `python3 tool/ci/diagnostics.py --format text` |
| | Gate | all three outcomes must be `success` |
| `cli-matrix` | 4 scenarios × power model | 5 combos; only `campus_quad` is gated, so only it has a duty-cycle arm |
| `probes` | SOS, group, history, media | the same four commands with `--no-check` |

`./tool/ci/run-pipeline.sh --list` prints this mapping from the script itself, so the table above
and the runner cannot disagree for long.
