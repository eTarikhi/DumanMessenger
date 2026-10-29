#!/usr/bin/env bash
# Shared plumbing for the local CI runner.
#
# The design rule for everything in tool/ci/ is that a local run has to mean the
# same thing as a remote one. So the commands here are copied from
# .github/workflows/ci.yml rather than paraphrased, the diagnostics parser is the
# same file both sides call, and — the part that is easiest to get wrong — a job
# that could not run is a *failure*, never a silent skip. A green local run that
# quietly omitted the authoritative engine would be worse than no local run at
# all, because it is the kind of thing you stop checking.

# Deliberately not `set -e`: the whole point of the `dart` job is that its three
# checks run unconditionally so one red build reports the analyzer, the test
# failures *and* the CLI metrics instead of stopping at the first. `set -e`
# would reintroduce exactly the behaviour the workflow was written to avoid.
set -uo pipefail

# --- output -------------------------------------------------------------------

if [ -t 1 ] && [ "${CI_COLOR:-auto}" != "never" ]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[36m'
else
  C_RESET=''; C_DIM=''; C_BOLD=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''
fi

log()      { printf '%s\n' "${C_BLUE}==>${C_RESET}${C_BOLD} $*${C_RESET}"; }
log_dim()  { printf '%s\n' "${C_DIM}$*${C_RESET}"; }
warn()     { printf '%s\n' "${C_YELLOW}warning:${C_RESET} $*" >&2; }
err()      { printf '%s\n' "${C_RED}error:${C_RESET} $*" >&2; }

# A step result line. Kept in one place so the local table and the JSON record
# cannot drift apart in what they consider a pass.
step_line() { # <marker> <name> <seconds>
  printf '  %s %-52s %s%ss%s\n' "$1" "$2" "${C_DIM}" "$3" "${C_RESET}"
}

# --- repository layout --------------------------------------------------------

# repo_root: the checkout, found from this file's own location so the scripts work
# from any cwd and from a git worktree.
repo_root() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  (cd "$here/../.." && pwd)
}

git_sha()   { git -C "$(repo_root)" rev-parse --short HEAD 2>/dev/null || echo "unknown"; }
git_branch(){ git -C "$(repo_root)" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown"; }

# --- toolchain preflight ------------------------------------------------------

have() { command -v "$1" >/dev/null 2>&1; }

# tool_version <cmd> [args...] — first line of --version, or empty.
tool_version() {
  local cmd="$1"; shift
  have "$cmd" && { "$cmd" "${@:---version}" 2>&1 | head -1; } || true
}

# The versions the workflow pins. Stated here so `make doctor` can compare what a
# machine has against what CI actually uses, instead of letting a contributor
# discover the difference as a build that passes locally and fails remotely.
REQUIRED_NODE_MAJOR=22      # actions/setup-node with node-version: 22
REQUIRED_DART_SDK=3.13.7    # exact CI compiler, matching committed lock
MIN_DART_SDK=3.4.0          # sim/mesh_sim/pubspec.yaml environment.sdk: ^3.4.0

# --- artifacts ----------------------------------------------------------------

# Every step's output is captured, mirroring the workflow's /tmp/dart-*.txt, so a
# failure can be re-read after the fact and so diagnostics.py has the same inputs
# locally that it has in CI.
artifact_dir=""

init_artifacts() { # [label]
  local label="${1:-run}"
  artifact_dir="$(repo_root)/artifacts/ci/$(date -u +%Y%m%dT%H%M%SZ)-$(git_sha)-${label}"
  mkdir -p "$artifact_dir"
}

# run_step <outcome-var> <label> <artifact-name> <cwd> <command...>
#
# Runs a command, tees it to an artifact, times it, and stores "success" or
# "failure" in the named variable. `set -o pipefail` matters here for the same
# reason it matters in the workflow: without it `cmd | tee file` reports tee's
# exit status and a failing build looks green.
run_step() {
  local __outvar="$1"; local label="$2"; local artifact="$3"; local cwd="$4"; shift 4
  local start end elapsed rc=0
  start=$(date +%s)
  printf '%s\n' "${C_DIM}\$ (cd ${cwd#$(repo_root)/}) $*${C_RESET}"
  # `2>&1 | tee` with pipefail, exactly as the workflow does it.
  ( cd "$cwd" && "$@" ) 2>&1 | tee "${artifact_dir}/${artifact}"
  rc=${PIPESTATUS[0]}
  end=$(date +%s); elapsed=$((end - start))
  if [ "$rc" -eq 0 ]; then
    eval "$__outvar=success"
    step_line "${C_GREEN}PASS${C_RESET}" "$label" "$elapsed"
  else
    eval "$__outvar=failure"
    step_line "${C_RED}FAIL${C_RESET} ($rc)" "$label" "$elapsed"
  fi
  printf '%s\n' "$rc" > "${artifact_dir}/${artifact%.txt}.exit"
  return 0
}

# skip_step <outcome-var> <label> <reason>
#
# Records a job that could not run. The outcome string is deliberately neither
# "success" nor "skipped" — it is "missing", which the gate treats as a failure.
skip_step() {
  local __outvar="$1"; local label="$2"; local reason="$3"
  eval "$__outvar=missing"
  step_line "${C_YELLOW}MISS${C_RESET}" "$label" "0"
  warn "$label could not run: $reason"
  printf '%s\n' "missing: $reason" > "${artifact_dir}/${label// /-}.missing"
}

# dart_sdk_version
#
# `dart --version` prints:
#   Dart SDK version: 3.5.4 (stable) (Thu Oct 17 16:22:05 2024 +0200) on "linux_x64"
# Taking the last field — which both pipeline scripts used to do — yields the platform, not the
# version, so every report and JSON record claimed the SDK was called "linux_x64". Pull the
# semver out by shape instead; the build date contains no X.Y.Z so it cannot be mistaken for it.
dart_sdk_version() {
  tool_version dart | grep -oE '[0-9]+\.[0-9]+\.[0-9]+[0-9A-Za-z+.-]*' | head -1
}

# version_ge <have> <want>
#
# Dotted-numeric comparison. No `sort -V` (GNU-only, absent on BSD/macOS) and no subprocesses.
# A pre-release suffix is truncated at its first non-digit, which is all the SDK floor needs.
version_ge() {
  local IFS=. i x y
  local -a a b
  read -ra a <<< "$1"
  read -ra b <<< "$2"
  for ((i = 0; i < ${#b[@]}; i++)); do
    x="${a[i]:-0}"; y="${b[i]:-0}"
    x="${x%%[!0-9]*}"; y="${y%%[!0-9]*}"
    [ "${x:-0}" -gt "${y:-0}" ] && return 0
    [ "${x:-0}" -lt "${y:-0}" ] && return 1
  done
  return 0
}
