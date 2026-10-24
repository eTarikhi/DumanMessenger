# 12. CLI cheat sheet

Every command this repository uses, by task. Each entry gives the `make` target (or PowerShell
front end), what it actually runs, and when you would reach for it.

Conventions:
- `make X` on Linux/macOS/WSL/Git Bash · `.\make.ps1 X` on Windows PowerShell — same target, and
  the same *verdict*, but not always the same exit code: `make` reports `2` for any failure because
  that is GNU make's own code, while `make.ps1` runs the underlying script directly and so passes
  `1` through. See the note in `docs/10` §5 and `docs/11-windows-11-workflow.md`.
- The **runs** column is the real command. `make` targets are thin front ends onto `tool/ci/`, which
  copies its commands from `.github/workflows/ci.yml`. Nothing here is a paraphrase.
- Exit codes across the pipeline: `0` verified · `1` failed or could not run · `2` partial · `64` bad
  usage. Those are the *scripts'* codes; through `make`, `1` and `2` both arrive as `2`.

---

## 1. Development & Setup

Environment initialization, dependency management, and starting local servers.

### First contact with the repository

| Command | Runs | Use it when |
| --- | --- | --- |
| `make doctor` | `tool/ci/doctor.sh` | **Before anything else.** Compares your toolchain against the versions CI pins, probes `registry.npmjs.org` / `pub.dev` / `api.github.com`, and checks the pre-push hook is active. |
| `make install` | `npm ci --no-audit --no-fund` then `cd sim/mesh_sim && dart pub get` | After cloning, and whenever a lockfile changes. |
| `make install-hooks` | `git config core.hooksPath .githooks` | Once per clone. Puts the pre-push gate under version control instead of in `.git/hooks`. |
| `make help` | prints every target | You forgot a target name. |

### Dependencies

| Command | Runs | Notes |
| --- | --- | --- |
| `npm ci --no-audit --no-fund` | installs from `package-lock.json` | Reproducible; this is what CI runs. Deletes `node_modules` first. |
| `npm install` | resolves and **rewrites** the lockfile | Only when adding a dependency. Commit the lockfile — CI uses `npm ci` and will fail without it. |
| `cd sim/mesh_sim && dart pub get` | resolves Dart deps | The only dependency is `package:test`. Needs `pub.dev` reachable. |
| `npm ls --depth=0` | top-level tree | Checking what is actually installed. |
| `dart pub deps --style=compact` | Dart dependency tree | From `sim/mesh_sim`. |

> **Never trust a bare `npx tsc` with no `node_modules`.** `npx` silently downloads a package named
> `tsc` (version 2.0.4, unrelated to TypeScript) and you get nonsense errors. Run `npm ci` first.

### Local servers

| Command | Runs | Notes |
| --- | --- | --- |
| `make dev` | `ALLOW_ANY_DEV_HOST=1 npm run dev -- --port 5173` | The React mesh visualiser. `ALLOW_ANY_DEV_HOST` lets a proxied or non-localhost Host header through. |
| `npm run dev -- --host 0.0.0.0` | vite on all interfaces | To open it from a phone on the same Wi‑Fi. Also needs a firewall rule — `docs/11` §6. |
| `npm run preview` | `vite preview` | Serves the **built** output, not the dev server. Use it to check what you actually shipped. |

### Git and branch setup

| Command | Notes |
| --- | --- |
| `git config core.hooksPath .githooks` | What `make install-hooks` does. |
| `git config --system core.longpaths true` | **Windows only.** `node_modules` exceeds 260 chars; without this `npm ci` fails with `ENOENT`. |
| `git add --renormalize .` | Re-apply `.gitattributes` line endings to an existing clone. |
| `git switch -c fix/your-change` | New branch before starting work. |

---

## 2. Build Processes

Compiling, asset building, and the specialized scripts that generate this repository's evidence.

### TypeScript / React

| Command | Runs | Notes |
| --- | --- | --- |
| `make typecheck` | `npx tsc --noEmit -p tsconfig.json` | Type-check without emitting. Fast; run it constantly. |
| `make build` | `npm run build` → `tsc -b && vite build` | Production bundle into `dist/`. |
| `make golden` | `npm run golden` | Regenerates `test-fixtures/golden-vectors.json`, the cross-language contract. **Commit the result** when either engine's RNG, spawn order or scheduling changes. |
| `git diff --quiet -- test-fixtures/golden-vectors.json` | no output = unchanged | The check CI applies after regenerating. Nonzero exit means the vectors moved. |

The `golden`, `media`, `history` and `field:*` npm scripts all compile `tool/*.ts` through
`tool/tsconfig.golden.json` into `tool/.build/` first, then run the emitted JS. `tool/.build/` is
git-ignored.

### Dart

| Command | Runs | Notes |
| --- | --- | --- |
| `make dart-analyze` | `cd sim/mesh_sim && dart analyze` | **Errors and warnings fail; infos do not.** A `dead_code` warning will therefore break CI. |
| `dart format .` | reformats | Not a CI gate — formatting is left to contributors. |
| `dart compile exe bin/mesh_sim.dart` | native binary | Produces a standalone executable; useful for field testing without a SDK on the device. |
| `dart compile js` / `dart pub global activate` | other targets | Not used by this repository's CI. |

### Specialized evidence scripts

These generate the numbers in `docs/06`–`docs/09`. Each takes a section name so re-measuring one
lever does not mean re-measuring eleven others.

| Command | Runs | Produces |
| --- | --- | --- |
| `make media` | `npm run media` | All of `docs/08` §7–§12: file transfer, PTT, the retry timer, contention, backpressure, shedding, the capture effect. |
| `make media SECT=captureEffect` | `npm run media captureEffect` | One section only. An unknown name exits `2` and lists the valid ones. |
| the thirteen sections | | `serialization`, `file`, `voice`, `retry`, `acceptance`, `contention`, `channel`, `priority`, `capture`, `backoff`, `shedding`, `captureEffect`, `captureMargin` |
| `make e2ee` | `npm run e2ee` | `docs/07` §2–§4 and §7 — what a Noise_XX handshake costs on this mesh: per-leg establishment latency, the leg lost at four hops in a crowd, how often a device meets a new peer, the padded packet sizing, and (since `src/crypto/` landed) the crypto itself. The first three sections implement **no cryptography**: they are crypto-shaped messages through the real engine, which is the part a protocol simulator can honestly answer. The fourth runs the reference protocol layer over OpenSSL. |
| `make e2ee SECT=churn` | `npm run e2ee churn` | One section: `latency` (§2.1, §2.2), `churn` (§3), `packet` (§4), `crypto` (§2.1 note 3, §4, §6, §7.2). An unknown name exits `2` and lists them. |
| `make e2ee SECT=crypto` | `npm run e2ee crypto` | Runs `src/crypto/` and reports measured numbers: handshake legs **32 / 96 / 64 B** against a 247 B GATT MTU (§7.2); a sealed packet at seven body sizes measured against the engine's own size model, including one whose code-unit count and byte count disagree (§4); **1 062 µs** of CPU for a whole handshake against §2.1's **675 ms** of radio, so 0.157 % (§2.1 note 3); and the capture test — a relay holding a legitimate message key from its own session with the sender reads the header and nothing else (§6). Fails if a sealed packet disagrees with the engine's model, if a leg exceeds the MTU, or if the CPU share passes 5 %. |
| `make history` | `npm run history` | `docs/06` §17 — group-history anti-entropy against the same world with it off. |
| `npm run field:capture -- campus_quad 42 /tmp/cap.jsonl` | capture run | The field-test capture schema. Add `flood-all` as a 4th argument for the naive baseline. |
| `npm run field:report -- /tmp/cap.jsonl /tmp/base.jsonl` | compare two captures | Delivery, overhead and latency against the baseline. |

### The Dart CLI itself

| Command | Notes |
| --- | --- |
| `dart run bin/mesh_sim.dart --scenario campus_quad --seed 42` | **The gated acceptance run.** Asserts the criteria and exits nonzero if they fail. Scenarios: `campus_quad`, `sparse_village`, `festival_crowd`, `partitioned_pair`. |
| `... --policy mpr` | Routing policy: `mpr` (default), `route-flood` or `flood-all`. **`flood-all` is the naive baseline the overhead ratio is measured against.** |
| `... --nodes 20` | Override the scenario's node count. The acceptance criteria are specified at 20. |
| `... --messages 150` | How many messages to send. |
| `... --gap 250` | Simulated milliseconds between messages. |
| `... --help` | The CLI's own usage text, with the current defaults interpolated. |
| `... --no-check` | Report the numbers without asserting the gate. Every probe uses this. |
| `... --duty-cycle` | The `skills/07` power arm: NORMAL scans 3 s / sleeps 7 s, SUPER continuous. |
| `... --channel-access csma` | The medium when two radios talk at once: `free` (default), `half-duplex`, `csma` — carrier sense (`docs/08` §12.9–§12.10). |
| `... --channel-capture strongest` | A busy **receiver**: `none` (default, takes everything), `first` (pessimistic bound), `strongest` (the capture effect, `docs/08` §12.15). |
| `... --capture-ratio 12` | dB a newcomer must clear to take the receiver over. Default `6`. Read only under `strongest`. |
| `... --channel-queue 4` | Transmit queue depth, default `8`, so a busy radio buffers instead of dropping (`docs/08` §12.7). |
| `... --channel-priority ack-first` | Which queued packet a busy radio takes next: `fifo` (default), `ack-first`, `by-class` (`docs/08` §12.8). |
| `... --backoff binary` | Wait a random number of slots before taking a medium that just freed up: `none` (default), `binary` (`docs/08` §12.13). |
| `... --media-backpressure` | Off by default. Stop a transfer pumping chunks into a radio that is already full (`docs/08` §12.12). |
| `... --json` | Machine-readable output. Names the arm it ran under a `radio` key. |
| `... --sos` | SOS flood reach (roadmap Phase 3). |
| `... --group 5` | Group delivery modes (`docs/06` §14). |
| `... --history` | Group-history anti-entropy (`docs/06` §17). |
| `... --media` | Media transport and push-to-talk (`docs/08`). |
| `... --trace` / `--capture` / `--capture-ogm` | Hop routes, pcap-like log, OGM capture. |

> **Reproducing the contention arms.** `docs/08` §12.9's six-arm table is `--channel-access` ×
> `--channel-capture` over `free`/`half-duplex`/`csma` and `none`/`first`; §12.15 adds `strongest`
> and sweeps `--capture-ratio` over 0/3/6/12/20 dB. Compare `deliveryRatio` and `overheadRatio`
> between runs — `--json` carries the `radio` block saying which arm produced them, so six runs
> cannot be mixed up after the fact. An unknown name is a usage error printing the valid set and
> exiting `64`, never a silent fall back to the default, and a flag you do not pass changes
> nothing: the shipped combination is inert by construction (§12.7), which is what keeps the
> golden vectors where they are.

---

## 3. Testing & Debugging

Unit testing, linting, debugging tools, and error logging.

### Running tests

| Command | Runs | Notes |
| --- | --- | --- |
| `make test` | `npm test` → `vitest run` | The TypeScript suite: engine, components, acceptance. |
| `npm run test:watch` | `vitest` | Watch mode. **Use `timeout 120 npx vitest run …` in a script** — an unbounded watcher will hang an automated run. |
| `make dart-test` | `dart test --reporter expanded` | The authoritative engine. |
| `npx vitest run src/__tests__/channel.test.ts` | one file | Narrowing down. |
| `npx vitest run -t "capture effect"` | by test name | Narrowing further. |
| `dart test test/transport_test.dart` | one Dart file | From `sim/mesh_sim`. |
| `dart test --name "refuses"` | by name | |

> **vitest ignores type errors.** A suite can be green while the code does not compile. Always run
> `make typecheck` alongside `make test`.

### Linting and static analysis

| Command | Runs | Notes |
| --- | --- | --- |
| `make typecheck` | `tsc --noEmit` | TypeScript. |
| `make dart-analyze` | `dart analyze` | Governed by `sim/mesh_sim/analysis_options.yaml`: `strict-casts`, `strict-raw-types`, `unused_import: error`, `dead_code: warning`, lint `avoid_print`. |
| `make check-docs` | `python3 tool/ci/check-docs.py` | Asks whether every command in `docs/` exists: CLI flags both directions, probe section names, `make` targets, `make.ps1`'s script table, and the flags passed to `tool/ci/*.sh`. `--self-test` injects one fault per check into a temporary copy and proves each is caught — a drift checker that always passes is indistinguishable from one that is broken. |
| `make dart-balance` | `python3 tool/ci/check-dart-balance.py` | Delimiter balance across all 22 `sim/mesh_sim` Dart sources, **with no Dart SDK present**. Not a substitute for `dart analyze` — it answers one question (does every `(`, `[`, `{` and string opened outside a comment get closed, in order?) so a brace mistake costs one line here instead of a hundred unrelated analyzer errors on the first machine that can build. A state machine, not a parser: it strips comments, tracks '''-quoted blocks, and follows `${…}` interpolations including the strings nested inside them. |
| `python3 tool/ci/check-dart-balance.py --self-test` | same, on 19 built-in snippets | 12 clean snippets that must **not** alarm (a delimiter in a comment, in a string, in a raw string, inside an interpolation) and 7 broken ones that must. The negative cases are the point: this class of checker fails in practice by alarming on `mesh_sim.dart`'s usage text, and a false alarm on a 12 000-line engine is how a check gets deleted. The first version did exactly that — it held the string delimiter beside the stack instead of in the frame, so a `' | '` nested in `${…}` inside a ''' block was read as the end of the block. |
| `python3 tool/ci/check-dart-balance.py <file…>` | same, on named files | Defaults to every `.dart` file in the repository. Exit `0` balanced, `1` not, with `file:line:col` for the innermost unclosed frame. |
| `make check-ps1` | `python3 tool/ci/check-ps1.py make.ps1` | Static check of the PowerShell front end: delimiter balance and PowerShell-7-only syntax, for machines that cannot run `pwsh`. |
| `python3 tool/ci/check-ps1.py --ps7-ok <file>` | same, allowing PS7 syntax | For scripts that are deliberately pwsh-only. |

### The whole pipeline, locally

| Command | Runs | Notes |
| --- | --- | --- |
| `make ci` | `tool/ci/run-pipeline.sh` | All four jobs: `web`, `dart`, `cli-matrix`, `probes`. |
| `make ci-fast` | `… --fast` | Skips the production build, the CLI matrix and the probes. |
| `make web` / `make dart` / `make cli-matrix` / `make probes` | `… --job <name>` | One job. |
| `./tool/ci/run-pipeline.sh --list` | prints the mapping | Every step, and the workflow step it mirrors. |
| `./tool/ci/run-pipeline.sh --job dart,probes --keep-going` | several jobs | `--keep-going` runs everything even after a failure. |
| `./tool/ci/run-pipeline.sh --json out.json` | writes a verdict record | Includes the toolchain versions the verdict was produced with. |
| `./tool/ci/run-pipeline.sh --allow-missing-dart` | accepts exit `2` | For working without a Dart SDK. **Never** turns a missing job into a pass. |

A job that cannot run is a **failure**, not a silent skip: without a Dart SDK, `make ci` exits `1`
with three of four jobs `MISSING`.

### Every check at once

`make ci` mirrors the workflow job for job, and that mapping is its whole value. `make checks` is
a deliberate **superset** of it: everything CI runs, plus the checks that only make sense locally,
plus one thing CI cannot tell you — which checks have never actually been run against this tree.

| Command | Runs | Notes |
| --- | --- | --- |
| `make checks` | `tool/ci/collect-checks.sh` | Every check, one pass, one report. **Never stops at the first failure.** |
| `make checks-list` | `… --list` | What it would run, tagged `verified before` / `NEVER RUN` per check. Runs nothing. |
| `make checks-evidence` | `… --with-evidence` | Also re-runs the probes behind the published numbers in `docs/06`–`docs/09`. Minutes, not seconds. |
| `./tool/ci/collect-checks.sh --only dart` | one group | Groups: `docs`, `ts`, `dart`, `cli`, `probes`, `evidence`. Comma-separated: `--only ts,dart`. |
| `./tool/ci/collect-checks.sh --report out.md --json out.json` | choose the outputs | The default report is `artifacts/ci/<run>/REPORT.md`. |

It produces three things: a console table; a Markdown report carrying the tail of every failing
capture plus parsed Dart diagnostics as `file:line:col`; and a **paste-back block** — the whole
result compacted into a few lines starting `DUMAN-CHECKS <sha> <date> node=… dart=…`, meant to be
copied into a message from a machine nobody else can inspect.

Exit `0` only when every check passed. A check that **could not run** exits `1`, because it did
not pass. There is deliberately no `partial` exit here, which is the real difference from
`run-pipeline.sh`: that script grades the machine as well as the code, this one only grades the
code and says plainly what it could not grade.

### Debugging a failure

| Command | Notes |
| --- | --- |
| `ls artifacts/ci/<run>/` | Every step's captured stdout, plus `<name>.exit` with its status. |
| `python3 tool/ci/diagnostics.py --format text` | The same parser CI uses, as readable text. `--format json` for machines, `--format github` for `::error file=…,line=…,col=…::` annotations. |
| `make diagnose` | Jobs and annotations for the newest failed remote run. |
| `make diagnose RUN=40020709332` | A specific run. |
| `./tool/ci/watch.sh --classify-run [RUN]` | Prints `billing`, `runner` or `none` — machine-readable, for scripts. |
| `gh api repos/<owner>/<repo>/check-runs/<jobId>/annotations --paginate` | The raw annotation channel. `$GITHUB_STEP_SUMMARY` is **not** readable through the API; annotations are the only machine-readable one. |
| `gh run view <run> --json jobs -q '.jobs[].databaseId'` | Find the `<jobId>` for the call above. |
| `gh run view <run> --log-failed` | Step logs — **when the log host is reachable.** If it returns empty, use annotations. |

---

## 4. Deployment & Maintenance

Build automation, containerization, and deployment workflows.

### Validated push

| Command | Runs | Notes |
| --- | --- | --- |
| `make push` | `tool/ci/validate-and-push.sh` | Full pipeline, then push. **Refuses on red and on partial.** |
| `make push-dry` | `… --dry-run` | Everything except the push. |
| `make push-force` | `… --force-partial` | Push after a PARTIAL run, and record that it was partial. The single escape hatch. |
| `make commit-push MSG="fix: …"` | `… --message "…"` | Commit the tree, validate, push. |
| `./tool/ci/validate-and-push.sh --job web` | scoped run | Verifies only `web`; logs `verification: scoped:web` so it cannot later be read as a full run. |
| `git push --no-verify` | bypasses the hook | Once, deliberately. The hook's fast subset is what you are skipping. |

Every push is appended to `artifacts/ci/verification-log.jsonl` (git-ignored) with the verdict, the
jobs that actually ran, which gate wrote it, and whether the push completed.

### Pull request automation

| Command | Runs | Notes |
| --- | --- | --- |
| `make pr` | `tool/ci/pr-flow.sh` | Validate → push → open PR → **merge only if every CI check passes.** |
| `make pr-dry` | `… --dry-run` | Every decision printed; no side effects at all. |
| `make pr-open` | `… --merge-on never` | Open the PR and stop. Leaves the merge to a human. |
| `make pr-local` | `… --merge-on local --yes` | Merge on the local run alone — the informed override for when CI cannot run. Records that CI never confirmed it. |
| `make pr-branch BRANCH=fix/thing` | `… --new-branch fix/thing` | Create the branch, then the whole flow. |
| `make pr-squash` | `… --squash --delete-branch` | Squash-merge and clean up. |
| `./tool/ci/pr-flow.sh --base main --title "…" --draft` | explicit control | Also `--rebase`, `--merge`, `--timeout`, `--interval`, `--force-partial`, `--skip-validate`. |

**Local validation gates *opening* the PR; it does not by itself justify *merging*.** A local run is
only as broad as the toolchain installed locally, so `--merge-on checks` is the default. When CI
cannot run at all — this repository has been refused for billing — the script says so and refuses,
rather than reading "no checks reported" as "checks passed".

### Containerization and running the real workflow

| Command | Runs | Notes |
| --- | --- | --- |
| `make act` | `act` | Runs the actual `ci.yml` in Docker: container images, `needs:` edges, `continue-on-error`, the gate. The most faithful local run. |
| `make act JOB=dart` | `act -j dart` | One job. |
| `act -l` | list the workflow's jobs | Sanity-check what `act` sees. |
| `docker run --rm -v "$PWD":/w -w /w node:22 bash -c "npm ci && npm test"` | the `web` job by hand | When `act` is unavailable but Docker is not. |

`act` needs Docker, and `setup-node`/`setup-dart` need network access from inside the container. On a
restricted network, native `make ci` is the path that works; `act` is the path that is most faithful.

### Monitoring remote CI

| Command | Runs | Notes |
| --- | --- | --- |
| `make watch` | `tool/ci/watch.sh` | Recent runs on this branch. |
| `make watch-all` | `… --all` | Every branch. |
| `make follow` | `… --follow` | Poll until the newest run finishes, then explain it. |
| `make diagnose` | `… --diagnose [RUN]` | Jobs, annotations, and **why** it failed — including distinguishing a billing refusal from a red build. |
| `gh run list --limit 8` | raw | |
| `gh run rerun <run>` | retry | Fails with "cannot be rerun" when the account is billing-blocked. |
| `gh pr checks <n>` | PR check status | |

### Maintenance

| Command | Notes |
| --- | --- |
| `make clean` | Removes `dist/`, `tool/.build/`, `sim/mesh_sim/build/` and the CI artifacts. |
| `make clean-artifacts` | Removes only `artifacts/ci/`. |
| `git status --porcelain` | Must be empty before pushing. |
| `tail -1 artifacts/ci/verification-log.jsonl` | What the last push actually verified. |
| `npm audit --audit-level=high` | Dependency advisories. |
| `dart pub outdated` | From `sim/mesh_sim`. |

---

## 5. Sequences worth memorising

**Starting a change**

```bash
make doctor && make install && make install-hooks
```

**Iterating**

```bash
make typecheck && make test          # fast, run constantly
make dart-analyze && make dart-test  # if you touched sim/mesh_sim
```

**Touched either engine's RNG, spawn order or scheduling**

```bash
make golden && git diff -- test-fixtures/golden-vectors.json
# changed  -> mirror the change in the other engine, or revert
# unchanged -> commit and carry on
```

**Finishing**

```bash
make ci && make push          # or: make pr  to open a pull request instead
make watch                    # then confirm remote CI agrees
```

**Something is red and you do not know why**

```bash
make diagnose                 # remote: jobs, annotations, and billing-vs-build
ls artifacts/ci/<run>/        # local: every step's captured output
python3 tool/ci/diagnostics.py --format text
```

---

## 6. The full sequence: clean tree → new branch → validated push → merged PR

### The one-liner

```bash
make pr-branch BRANCH=fix/retry-timer
```

Creates the branch, validates locally, pushes, opens the PR, and merges it when CI passes. It stops
at the first step that fails rather than carrying a problem forward.

Add `--dry-run` the first time you use it, to see every decision without any of the side effects:

```bash
./tool/ci/pr-flow.sh --new-branch fix/retry-timer --dry-run
```

### The explicit version, worth reading once

```bash
# 1. Start from a clean, current tree.
git switch main && git pull --ff-only
git switch -c fix/retry-timer

# 2. Make the change, then verify it — types first, they are the cheapest signal.
make typecheck && make test
make ci                       # every job; exits 1 if a toolchain is missing

# 3. Commit. Read what you are about to commit before you commit it.
git add -A && git status --short
git commit -m "fix: the retry timer measured silence from the wrong moment"

# 4. Push, gated. Refuses on a red or partial run.
make push
# …or push by hand and let the pre-push hook gate it:
git push -u origin fix/retry-timer

# 5. Open the PR, and merge only when the evidence supports it.
make pr                       # merge when every CI check passes
make pr-open                  # open it and leave the merge to a human
make pr-local                 # CI cannot run: merge on local evidence, recorded as such

# 6. Confirm what the remote thinks.
make watch
make diagnose                 # if it is red — and it says whether that is billing or a real failure
```

### The same sequence on Windows 11

`.\make.ps1` replaces `make`; `git` and `gh` are already native executables.

```powershell
.\make.ps1 doctor
git switch -c fix/retry-timer
.\make.ps1 ci
git add -A; git status --short
git commit -m "fix: the retry timer measured silence from the wrong moment"
.\make.ps1 push
.\make.ps1 pr
.\make.ps1 watch
```

If PowerShell will not run the script, that is the execution policy, not the script:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

### What each gate is for

| Gate | Runs | Refuses when |
| --- | --- | --- |
| `pre-push` hook | the fast subset, on every `git push` | the build is actually red. Warns but allows a *partial* run. |
| `make push` | the full pipeline, before pushing | red, **or** partial without `--force-partial` |
| `make pr` | the full pipeline, then CI's checks | local red, or remote checks failed for a reason that is not an infrastructure refusal |

Three gates is not redundancy. The hook catches the bare `git push` that skipped the script; the
script catches the push that skipped the hook; CI catches what neither machine could verify. Each one
says plainly which of them is speaking, so a refusal tells you where to look.
