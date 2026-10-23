# 11. Windows 11 x64 — development and CI workflow

How to run this repository's toolchain on Windows 11. Read `docs/10-local-development-and-ci.md`
first for what the pipeline does; this document is about getting it to run on this platform.

## 0. The one thing to understand first

`.github/workflows/ci.yml` runs on **`ubuntu-latest`**. The local pipeline in `tool/ci/` is POSIX
shell, deliberately, so that a green local run means the same thing as a green CI run.

That leaves Windows with a choice, and it is worth being honest about the trade-off rather than
pretending it does not exist:

| Approach | Fidelity to CI | Effort | Notes |
| --- | --- | --- | --- |
| **WSL2 (Ubuntu)** | **highest** | one install | Same kernel family, same package manager, Dart SDK installs the documented way. Recommended. |
| **Git Bash** | high | usually zero | Ships with Git for Windows, so you probably already have it. Missing `make` and `python3`. |
| **Native PowerShell** | partial | zero | `npm`, `dart`, `git` and `gh` are all Windows executables and work directly. There is no PowerShell reimplementation of the pipeline, and §4 explains why that is a feature. |

**This repository does not ship a second pipeline written in PowerShell.** A second implementation
of the same policy is a second thing that can drift from the workflow while still looking green,
which is the exact failure `docs/10` §8 exists to prevent. What it ships instead is `make.ps1` — a
thin dispatcher that finds a bash runtime and forwards your arguments unchanged. One pipeline, two
front doors.

---

## 1. Requirements

| Tool | Version | Windows install | Needed for |
| --- | --- | --- | --- |
| **Git for Windows** | 2.30+ | `winget install --id Git.Git -e` | everything; also supplies Git Bash |
| **Node.js** | **22.x LTS** | `winget install --id OpenJS.NodeJS.LTS -e` | the `web` job |
| **Dart SDK** | **stable ≥ 3.4.0** | `choco install dart-sdk -y`, or the zip in §2 | the `dart`, `cli-matrix` and `probes` jobs |
| **Python 3** | 3.9+ | `winget install --id Python.Python.3.12 -e` | `tool/ci/diagnostics.py` |
| **GitHub CLI** | 2.x | `winget install --id GitHub.cli -e` | `make watch`, `make diagnose`, `make pr` |
| **GNU Make** | 4.x | in WSL: `sudo apt install make`; Git Bash does **not** ship it | the `make` targets |
| **WSL2 + Ubuntu** | current | `wsl --install -d Ubuntu` | the recommended runtime |
| Docker Desktop | any | `winget install --id Docker.DockerDesktop -e` | only for `make act` |

Check what you have from PowerShell:

```powershell
.\make.ps1 doctor        # inside the bash runtime, compares you against what CI pins
```

Or natively, without any bash:

```powershell
git --version; node --version; npm --version; dart --version; python --version; gh --version
```

**Versions are not a style preference here.** CI pins `node-version: 22` via `actions/setup-node`
and `dart-lang/setup-dart` with `stable`, against `sdk: ^3.4.0` in `sim/mesh_sim/pubspec.yaml`. A
different Node major can produce different test results, and then a green local run stops predicting
a green CI run — which is the whole value of having one.

---

## 2. Installing the Dart SDK on Windows

This is the step that gets skipped, because the TypeScript half works perfectly without it and CI
would normally catch the gap. **CI on this repository is currently refused for billing reasons**, so
nothing will catch it. Without Dart, `make ci` exits 1 with three of four jobs `MISSING`.

**Option A — Chocolatey**

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
choco install dart-sdk -y
```

**Option B — the zip, no package manager**

```powershell
$url = 'https://storage.googleapis.com/dart-archive/channels/stable/release/latest/sdk/dartsdk-windows-x64-release.zip'
Invoke-WebRequest $url -OutFile "$env:TEMP\dart-sdk.zip"
Expand-Archive "$env:TEMP\dart-sdk.zip" -DestinationPath 'C:\tools' -Force
[Environment]::SetEnvironmentVariable('Path', $env:Path + ';C:\tools\dart-sdk\bin', 'User')
```

Open a **new** terminal afterwards — `Path` changes do not apply to shells that are already open,
which is the single most common reason `dart` appears not to work on Windows.

Then, once:

```powershell
cd sim\mesh_sim
dart pub get
```

The only dependency is `package:test`. If `pub.dev` is unreachable from your network, this fails and
the Dart jobs cannot run; `doctor` probes it and tells you before you find out the slow way.

**Under WSL** the SDK must be installed *inside* the distro, not shared from Windows: a Windows
`dart.exe` invoked from WSL works, but resolves paths differently and confuses `dart pub get`. Use
the Linux instructions in `docs/10` §2.

---

## 3. `make.ps1` — the Windows front door

```powershell
.\make.ps1 help                       # what it found, and every target
.\make.ps1 doctor                     # is this machine able to verify this repository?
.\make.ps1 ci                         # every CI job, locally
.\make.ps1 ci --job web --fast        # one job's quick subset
.\make.ps1 push                       # validate, then push — refuses on red or partial
.\make.ps1 pr-dry                     # the whole PR flow, no side effects
.\make.ps1 install-hooks              # the pre-push gate
.\make.ps1 run-pipeline --list        # call any script in tool/ci/ directly
```

It resolves the runtime in this order and tells you which one it picked:

1. **WSL2** — `wsl.exe` present *and* at least one installed distribution. It checks for a distro,
   because `wsl.exe` exists on Windows 11 even with nothing installed, and every invocation then
   dies with "Windows Subsystem for Linux has no installed distributions."
2. **Git Bash** — derived from wherever `git.exe` actually lives, rather than a guessed install
   path, because winget, scoop, Chocolatey and portable installs all put it in different places.
   Also checks `C:\msys64\usr\bin\bash.exe`.
3. **Nothing** — it prints both install commands and exits `64` rather than failing obscurely later.

Force a specific one with `-Runtime wsl` or `-Runtime bash`. Set `$env:DUMAN_CI_VERBOSE = 1` to see
the exact command it hands to the shell, which is the first thing to look at when a path is wrong.

**Exit codes are the pipeline's, passed through untouched:** `0` verified · `1` failed or could not
run · `2` partial · `64` bad usage. Anything else means the *runtime* failed — a bad path, a missing
distro — and `make.ps1` says so explicitly instead of letting a shell error masquerade as a build
verdict.

### If PowerShell refuses to run it

That is the execution policy, not the script:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

Per-user, does not weaken the machine, and does not need an administrator.

### The `/mnt/c` performance warning

If the repository lives on the Windows drive and you run it through WSL, `make.ps1` warns:

```
warning: the repo is on the Windows drive (/mnt/...), so WSL file I/O is slow.
```

WSL reaches `/mnt/c` through a 9P bridge, and it is several times slower than the distro's own
filesystem. `npm ci` and a full `vitest` run both feel it. Everything still works — this is a
performance note, not an error. For repeated runs:

```bash
# inside WSL
git clone https://github.com/eTarikhi/DumanMessenger.git ~/DumanMessenger
cd ~/DumanMessenger && make install
```

Keep one clone for fast iteration and treat the Windows one as your editor's view, or move entirely
into the distro and use VS Code's WSL remote support.

---

## 4. Two Windows-specific configuration steps

### Line endings — `.gitattributes`

Git for Windows offers *"Checkout Windows-style, commit Unix-style"* during install, which sets
`core.autocrlf=true`. Under that setting every text file is checked out with CRLF, **including the
shell scripts the entire CI toolchain is built from**. bash then fails on the stray carriage return:

```
./tool/ci/run-pipeline.sh: /bin/bash^M: bad interpreter: No such file or directory
$'\r': command not found
Makefile:22: *** missing separator
```

Those read like a broken script and are actually a line-ending problem, which is why they cost
hours. `.gitattributes` pins `eol=lf` on `*.sh`, `Makefile`, `.githooks/*`, `*.py` and the source
formats, so the repository's intent overrides any local `autocrlf` setting.

It also matters for CI, not just comfort: the `web` job runs `npm run golden` and then **fails if
`test-fixtures/golden-vectors.json` differs from the committed file**. Node writes `\n` on every
platform, so pinning LF stops a CRLF checkout from making an unchanged golden vector look modified.

If you cloned before `.gitattributes` existed, renormalise once:

```powershell
git add --renormalize .
git status          # should list only files whose endings actually changed
```

### Long paths

`node_modules` exceeds the 260-character limit that Windows still enforces by default:

```powershell
git config --system core.longpaths true      # needs an elevated shell
```

Without it, `npm ci` fails partway with `ENOENT` on a deeply nested path, which looks like a
corrupt registry mirror and is not.

---

## 5. No bash at all? Run the commands natively

Every target is a thin wrapper over commands that are native Windows executables. If you cannot
install WSL or Git Bash, run these directly from PowerShell — this is what `make.ps1` would have
forwarded, minus the runner's bookkeeping:

```powershell
# the `web` job, step by step
npm ci --no-audit --no-fund
npx tsc --noEmit -p tsconfig.json
npm test
npm run golden
git diff --quiet -- test-fixtures/golden-vectors.json   # must produce no output
npm run build

# the `dart` job
cd sim\mesh_sim
dart pub get
dart analyze
dart test --reporter expanded
dart run bin/mesh_sim.dart --scenario campus_quad --seed 42
cd ..\..

# monitoring
gh run list --branch (git rev-parse --abbrev-ref HEAD) --limit 8
gh run view <run-id> --json jobs

# validate, then push — the gate, done by hand
npm ci; npm test; if ($LASTEXITCODE -eq 0) { git push }
```

**Be honest with yourself about what this proves.** Running the commands by hand verifies the
build; it does not verify that you ran *all* of them, in order, including the golden-vector check
that is easy to forget and the `needs:` edges that make a Dart failure block the downstream jobs.
That bookkeeping is what `tool/ci/run-pipeline.sh` adds, and it is why a machine with no Dart SDK
exits `1` rather than reporting a comfortable pass. The native path is a fallback, not an
equivalent.

`docs/12-cli-cheat-sheet.md` has the full command behind every target.

---

## 6. The dev server, and reaching it from a phone

```powershell
.\make.ps1 dev                       # or: npm run dev
```

Vite binds to `localhost` by default. Two Windows specifics:

- **`ALLOW_ANY_DEV_HOST=1`** is set by `make dev` so a proxied or non-localhost Host header is
  accepted. In PowerShell: `$env:ALLOW_ANY_DEV_HOST = 1; npm run dev`.
- **To reach it from an Android device on the same Wi-Fi** — which this project needs, since the
  roadmap's remaining items are field tests — bind to all interfaces and allow it through the
  firewall:

```powershell
npm run dev -- --host 0.0.0.0 --port 5173
New-NetFirewallRule -DisplayName "Vite dev" -Direction Inbound -LocalPort 5173 -Protocol TCP -Action Allow
ipconfig | Select-String "IPv4"      # the address to open on the phone
```

Then open `http://<that-address>:5173` on the device. Under **WSL2** this does not work directly:
WSL has its own NAT'd network, so `localhost` forwarding reaches Windows but not the LAN. Either
run the dev server from Windows PowerShell, or use WSL2's mirrored networking mode
(`networkingMode=mirrored` in `.wslconfig`, Windows 11 22H2+).

---

## 7. Path translation reference

| Windows | Git Bash / MSYS2 | WSL |
| --- | --- | --- |
| `C:\Users\me\DumanMessenger` | `/c/Users/me/DumanMessenger` | `/mnt/c/Users/me/DumanMessenger` |
| `C:\tools\dart-sdk\bin` | `/c/tools/dart-sdk/bin` | `/mnt/c/tools/dart-sdk/bin` |
| `%TEMP%` | `$TEMP` | `/tmp` (a different filesystem) |

`make.ps1` does this translation for you. Do it by hand only when calling a script directly.

Two traps:

- **Ask WSL, do not assume `/mnt/c`.** The automount point is configurable, which is why
  `make.ps1` calls `wslpath -u` rather than string-replacing the drive letter.
- **`/tmp` is not shared.** Under WSL, `/tmp` is the distro's; under Git Bash, `mktemp` maps to
  `%TEMP%`. The workflow writes `/tmp/dart-*.txt` inside an Ubuntu container, and
  `tool/ci/run-pipeline.sh` writes to `artifacts/ci/<run>/` precisely so that nothing depends on
  where `/tmp` happens to be.

---

## 8. Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `...ps1 cannot be loaded because running scripts is disabled` | execution policy | `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` |
| `make.ps1` exits 64, "no bash runtime found" | neither WSL nor Git Bash | `wsl --install -d Ubuntu`, or `winget install --id Git.Git -e` |
| "WSL has no installed distributions" | `wsl.exe` present, no distro | `wsl --install -d Ubuntu`, reboot if asked |
| `$'\r': command not found` | CRLF in a shell script | §4; `git add --renormalize .` |
| `bad interpreter: /bin/bash^M` | same | same |
| `Makefile:NN: *** missing separator` | CRLF in the Makefile | §4 — Makefiles must be LF |
| `dart` works in one terminal but not another | `Path` changed after the shell opened | open a new terminal |
| `npm ci` fails with `ENOENT` on a deep path | 260-char limit | `git config --system core.longpaths true` |
| `npm ci` is extremely slow | Defender scanning `node_modules` | add a Defender exclusion for the repo folder |
| `python3: command not found` in Git Bash | Git for Windows ships no Python | `winget install Python.Python.3.12`; WSL has it already |
| `make: command not found` in Git Bash | Git for Windows ships no make | use WSL, or call the script directly: `.\make.ps1 ci` |
| Phone cannot reach the dev server under WSL2 | WSL2 NAT | §6 — run it from Windows, or mirrored networking |
| `gh pr create` says "not authenticated" | | `gh auth login` — never paste a token into the repo |
| `make.ps1` returns an exit code that is not 0/1/2/64 | the runtime itself failed | `$env:DUMAN_CI_VERBOSE = 1` and read the command it printed |

---

## 9. What is verified about this document, and what is not

Stated plainly, because a setup guide that overstates its own testing is worse than one that admits
its limits.

**Verified by execution:** everything in `tool/ci/`, the `Makefile` targets, the pre-push hook, the
pipeline exit codes, the PR flow including its refusal to merge when CI is billing-blocked, and
`watch.sh --classify-run`. Those were run against this repository and against stubs that simulate a
failing build and a billing refusal.

**Not verified by execution:** `make.ps1`. The sandbox this was written in has no PowerShell and
cannot install one — the release asset host is not reachable from it. So `make.ps1` was **statically
checked only**, by `tool/ci/check-ps1.py`, which confirms balanced delimiters and the absence of
PowerShell 7-only syntax (`??`, `?.`, the ternary, `&&`/`||` as pipeline chain operators) so that it
runs on the Windows PowerShell 5.1 that Windows 11 actually ships. It is written defensively — every
failure path prints an explicit reason and a fix rather than throwing — but it has not been run.

Run `.\make.ps1 doctor` first. If it misbehaves, `$env:DUMAN_CI_VERBOSE = 1` prints the exact
command it handed to the shell, and `.\make.ps1 -Runtime bash <target>` forces the other runtime.
Both are one line to try, and a report of what happened is genuinely useful: this file is the one
part of the toolchain that could not be tested where it was written.
