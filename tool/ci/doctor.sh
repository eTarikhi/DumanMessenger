#!/usr/bin/env bash
# Check this machine against what the repository and its CI actually require.
#
# Not a generic "do you have node" check: the versions are compared against the pins in
# .github/workflows/ci.yml and sim/mesh_sim/pubspec.yaml, because the failure mode worth
# catching is a toolchain that is present and *different* — a build that passes on Node 20
# and fails on the Node 22 CI uses tells you nothing useful about either.
#
# Exits 0 when everything required is present, 1 when something required is missing.
# Optional tools (Docker, act, gh) are reported but never fail the check.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

ROOT="$(repo_root)"
DART_DIR="$ROOT/sim/mesh_sim"

PASS=0; WARN=0; FAIL=0

ok()   { printf '  %s %-34s %s\n' "${C_GREEN}✔${C_RESET}" "$1" "${C_DIM}$2${C_RESET}"; PASS=$((PASS+1)); }
bad()  { printf '  %s %-34s %s\n' "${C_RED}✘${C_RESET}" "$1" "$2"; FAIL=$((FAIL+1)); }
meh()  { printf '  %s %-34s %s\n' "${C_YELLOW}!${C_RESET}" "$1" "$2"; WARN=$((WARN+1)); }
opt()  { printf '  %s %-34s %s\n' "${C_DIM}○${C_RESET}" "$1" "${C_DIM}$2${C_RESET}"; }
head_(){ echo; printf '%s\n' "${C_BOLD}$1${C_RESET}"; }

OS="$(uname -s)"
case "$OS" in
  Darwin)  PKG="brew install <pkg>" ;;
  Linux)   if grep -qi microsoft /proc/version 2>/dev/null; then PKG="sudo apt-get install <pkg>  (WSL)"
           else PKG="sudo apt-get install <pkg>"; fi ;;
  *)       PKG="install <pkg> with your package manager" ;;
esac

echo
log "doctor · $ROOT"
log_dim "host $OS $(uname -m) · branch $(git_branch) @ $(git_sha)"

# --- required: the tools the pipeline runs ------------------------------------

head_ "required toolchain"

if have node; then
  NODE_V="$(node --version | sed 's/^v//')"
  NODE_MAJOR="${NODE_V%%.*}"
  if [ "$NODE_MAJOR" = "$REQUIRED_NODE_MAJOR" ]; then
    ok "node $NODE_V" "matches CI (actions/setup-node: $REQUIRED_NODE_MAJOR)"
  else
    meh "node $NODE_V" "CI pins major $REQUIRED_NODE_MAJOR — results may differ"
  fi
else
  bad "node" "MISSING. CI pins $REQUIRED_NODE_MAJOR. $PKG → nodejs, or use nvm/fnm."
fi

have npm && ok "npm $(npm --version)" "npm ci needs package-lock.json (present)" \
         || bad "npm" "MISSING — ships with node."

have git && ok "git $(git --version | awk '{print $3}')" "" \
         || bad "git" "MISSING."

have python3 && ok "python3 $(python3 --version | awk '{print $2}')" "the five checkers in tool/ci/ and diagnostics.py" \
             || bad "python3" "MISSING — the whole checks job needs it: five static checkers and diagnostics.py."

if have dart; then
  DART_V="$(dart --version 2>&1 | awk '{print $NF}')"
  # pubspec pins ^3.4.0; compare major.minor numerically rather than lexically, so 3.10 does
  # not read as older than 3.4.
  DART_MAJ="${DART_V%%.*}"; DART_REST="${DART_V#*.}"; DART_MIN="${DART_REST%%.*}"
  MIN_MAJ="${MIN_DART_SDK%%.*}"; MIN_REST="${MIN_DART_SDK#*.}"; MIN_MIN="${MIN_REST%%.*}"
  if [ "${DART_MAJ:-0}" -gt "$MIN_MAJ" ] || { [ "${DART_MAJ:-0}" -eq "$MIN_MAJ" ] && [ "${DART_MIN:-0}" -ge "$MIN_MIN" ]; }; then
    ok "dart $DART_V" "satisfies pubspec ^$MIN_DART_SDK"
  else
    bad "dart $DART_V" "pubspec requires ^$MIN_DART_SDK"
  fi
else
  bad "dart" "MISSING — the authoritative engine cannot be built or tested."
  cat <<DART

      The Dart SDK is the one dependency that is easy to miss, because the TypeScript
      half of this repository works without it and CI is what usually catches the gap.
      Install it from dart.dev/tools/sdk, or:

        macOS    brew tap dart-lang/dart && brew install dart
        Linux    sudo apt-get update && sudo apt-get install -y wget gnupg apt-transport-https
                 wget -qO- https://dl-ssl.google.com/linux/linux_signing_key.pub \\
                   | sudo gpg --dearmor -o /usr/share/keyrings/dart.gpg
                 echo 'deb [signed-by=/usr/share/keyrings/dart.gpg arch=amd64] \\
                   https://storage.googleapis.com/download.dartlang.org/linux/debian stable main' \\
                   | sudo tee /etc/apt/sources.list.d/dart_stable.list
                 sudo apt-get update && sudo apt-get install -y dart
                 export PATH="\$PATH:/usr/lib/dart/bin"     # put this in your shell rc
        direct   https://storage.googleapis.com/dart-archive/channels/stable/release/latest/sdk/
                 (dartsdk-<os>-<arch>-release.zip; unzip anywhere and put bin/ on PATH)

      Then:  cd sim/mesh_sim && dart pub get
DART
fi

# --- required: project state --------------------------------------------------

head_ "project state"

if [ -f "$ROOT/package-lock.json" ]; then
  ok "package-lock.json" "npm ci can install reproducibly"
else
  bad "package-lock.json" "MISSING — npm ci will fail; CI uses npm ci, not npm install"
fi

if [ -d "$ROOT/node_modules" ]; then
  ok "node_modules/" "installed"
else
  meh "node_modules/" "not installed — run: make install"
fi

if [ -f "$DART_DIR/pubspec.lock" ]; then
  # The lock is a committed artifact (991d11c), so report what it pins rather than only that it
  # exists: the package count and the SDK range it was resolved under are the two facts that decide
  # whether `dart pub get --enforce-lockfile` will work on this machine. Both are read out of the
  # file, never hard-coded — a re-resolved lock changes them and this line should follow.
  lock_pkgs=$(grep -cE '^  [A-Za-z0-9_]+:$' "$DART_DIR/pubspec.lock" 2>/dev/null) || lock_pkgs='?'
  lock_sdk=$(awk '/^sdks:/{f=1;next} f&&/^[[:space:]]+dart:/{sub(/^[[:space:]]*dart:[[:space:]]*/,"");gsub(/"/,"");print;exit}' \
             "$DART_DIR/pubspec.lock" 2>/dev/null) || lock_sdk=''
  ok "sim/mesh_sim/pubspec.lock" \
     "committed: ${lock_pkgs} packages, resolved for Dart ${lock_sdk:-an unrecorded SDK range}"
else
  meh "sim/mesh_sim/pubspec.lock" "absent — run: cd sim/mesh_sim && dart pub get, then commit it (docs/11 §2)"
fi

if [ -f "$ROOT/test-fixtures/golden-vectors.json" ]; then
  if git -C "$ROOT" diff --quiet -- test-fixtures/golden-vectors.json 2>/dev/null; then
    ok "test-fixtures/golden-vectors.json" "committed and unmodified"
  else
    bad "test-fixtures/golden-vectors.json" "MODIFIED — the cross-language contract has drifted"
    echo "        run 'npm run golden', inspect the diff, and commit it if intended."
  fi
else
  bad "test-fixtures/golden-vectors.json" "MISSING — both engines assert against it"
fi

if [ -f "$ROOT/.github/workflows/ci.yml" ]; then
  # Count the job keys under `jobs:`, not every two-space-indented key — `on: push:` is
  # shaped the same way and is not a job.
  NJOB="$(awk '/^jobs:/{f=1;next} f && /^  [a-z][a-z0-9-]*:$/{n++} END{print n+0}' "$ROOT/.github/workflows/ci.yml")"
  ok ".github/workflows/ci.yml" "$NJOB jobs, mirrored command-for-command by tool/ci/"
else
  bad ".github/workflows/ci.yml" "MISSING"
fi

# --- optional: the higher-fidelity path ---------------------------------------

head_ "optional"

if have docker; then
  ok "docker $(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')" "act can run the real workflow"
  if have act; then
    ok "act $(act --version 2>/dev/null | awk '{print $3}')" "make act — runs .github/workflows/ci.yml in a container"
  else
    opt "act" "not installed — brew install act, or github.com/nektos/act releases"
    echo "        Without it, 'make ci' runs the same commands natively instead of the YAML."
  fi
else
  opt "docker" "not installed — only needed for 'make act' (running the real YAML)"
  opt "act" "needs docker; 'make ci' works without either"
fi

if have gh; then
  ok "gh $(gh --version 2>/dev/null | head -1 | awk '{print $3}')" "make watch / make diagnose"
  if gh auth status >/dev/null 2>&1; then
    ok "gh authenticated" "as $(gh api user -q .login 2>/dev/null || echo '(unknown)')"
  else
    meh "gh not authenticated" "run 'gh auth login' — never paste a token into the repo"
  fi
else
  opt "gh" "not installed — remote CI monitoring (make watch) needs it"
fi

# Ask git where hooks come from rather than assuming .git/hooks. `make install-hooks` sets
# core.hooksPath to .githooks so the hook is versioned, and when that is set git ignores
# .git/hooks entirely — so checking the default location reported an installed hook as
# missing, which is the one answer a doctor must not get wrong.
HOOKS_PATH="$(git -C "$ROOT" config core.hooksPath 2>/dev/null || true)"
[ -n "$HOOKS_PATH" ] || HOOKS_PATH=".git/hooks"
case "$HOOKS_PATH" in /*) ;; *) HOOKS_PATH="$ROOT/$HOOKS_PATH" ;; esac

if [ -x "$HOOKS_PATH/pre-push" ]; then
  ok "pre-push hook" "installed at ${HOOKS_PATH#$ROOT/} — runs the fast subset before every push"
elif [ -x "$ROOT/.githooks/pre-push" ]; then
  opt "pre-push hook" "present in .githooks/ but not active — run: make install-hooks"
else
  opt "pre-push hook" "not installed — run: make install-hooks"
fi

# --- reachability -------------------------------------------------------------

head_ "network reachability (only matters for installs and remote CI)"

probe() { # <label> <host>
  if command -v curl >/dev/null 2>&1; then
    if curl -sS -o /dev/null --max-time 5 -I "https://$2" >/dev/null 2>&1; then
      ok "$2" "reachable"
    else
      meh "$2" "unreachable — installs and $1 will not work from here"
    fi
  else
    opt "$2" "curl not installed; not probed"
  fi
}
probe "npm install" registry.npmjs.org
probe "dart pub get" pub.dev
probe "make watch" api.github.com

# --- verdict ------------------------------------------------------------------

echo
if [ "$FAIL" -gt 0 ]; then
  err "$FAIL required check(s) failed, $WARN warning(s)."
  err "The pipeline will report those jobs MISSING and refuse to call the run green."
  exit 1
fi
if [ "$WARN" -gt 0 ]; then
  warn "$WARN warning(s), nothing missing. 'make ci' should run every job."
  exit 0
fi
log "everything required is present. 'make ci' will verify all five jobs."
exit 0
