#!/usr/bin/env bash
# Collect every check this repository has, run them all in one pass, and produce one report.
#
# Why this is a separate script from run-pipeline.sh
# --------------------------------------------------
# run-pipeline.sh mirrors .github/workflows/ci.yml command for command, and that 1:1 mapping is
# its whole value — adding checks to it would break the claim that a green local run predicts a
# green remote one. This script is deliberately a *superset*: everything CI runs, plus the checks
# that only make sense locally (regenerating the golden vectors and diffing them, the evidence
# probes that produce the numbers in docs/06-09), plus one thing CI cannot tell you — which of
# these checks have never actually been run against the current tree.
#
# That last part is the reason this exists. Remote CI on this repository has been refused for
# billing since 8406717, and the workspace that produced the Dart capture-effect mirror had no
# Dart SDK at all. So an entire half of the repository reached main without ever being compiled.
# A check that has never run is not the same thing as a check that passed, and this script labels
# the difference on every line instead of leaving it to memory.
#
# It never stops early. The point is to run everything once and see the whole picture, so a
# failure in check 3 does not hide check 4. Failures are collected and reported together.
#
# Usage:
#   tool/ci/collect-checks.sh                  # ts + dart + cli + probes
#   tool/ci/collect-checks.sh --list           # what it would run, and what is already verified
#   tool/ci/collect-checks.sh --with-evidence  # also reproduce the docs' probe numbers (slow)
#   tool/ci/collect-checks.sh --only dart      # one group: docs | ts | dart | cli | probes | evidence
#   tool/ci/collect-checks.sh --report out.md  # where to write the Markdown report
#
# Exit codes: 0 everything passed · 1 something failed or could not run · 64 bad usage.
# There is deliberately no "partial" exit here: a check that could not run is a check that did
# not pass, and this script's job is to say so rather than to grade the machine.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

ROOT="$(repo_root)"
DART_DIR="$ROOT/sim/mesh_sim"

GROUPS_ALL="docs ts dart cli probes evidence"
SELECTED="docs ts dart cli probes"
SCOPED=0
WITH_EVIDENCE=0
LIST_ONLY=0
REPORT=""
JSON_OUT=""

require_value() { [ -n "${2-}" ] || { err "option $1 needs a value"; exit 64; }; }

usage() { sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --list|-l)      LIST_ONLY=1; shift ;;
    --with-evidence) WITH_EVIDENCE=1; SELECTED="$SELECTED evidence"; shift ;;
    --only)         require_value "$1" "${2-}"; SELECTED="${2//,/ }"; SCOPED=1; shift 2 ;;
    --only=*)       SELECTED="${1#*=}"; SELECTED="${SELECTED//,/ }"; SCOPED=1; shift ;;
    --report)       require_value "$1" "${2-}"; REPORT="$2"; shift 2 ;;
    --report=*)     REPORT="${1#*=}"; shift ;;
    --json)         require_value "$1" "${2-}"; JSON_OUT="$2"; shift 2 ;;
    --json=*)       JSON_OUT="${1#*=}"; shift ;;
    -h|--help)      usage; exit 0 ;;
    *)              err "unknown option: $1"; usage >&2; exit 64 ;;
  esac
done

for g in $SELECTED; do
  case " $GROUPS_ALL " in *" $g "*) ;; *) err "unknown group: $g (one of: $GROUPS_ALL)"; exit 64 ;; esac
done

selected() { case " $SELECTED " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# --- the check registry --------------------------------------------------------
#
# One row per check: name | human label | verified-before? | what it would catch.
# "verified-before" is the honest answer as of the tree this script was written against, and it
# is the column that makes the report worth reading: a wall of green means very little if some
# of those checks have never been executed anywhere.
REGISTRY_DOCS=(
  "drift|does every documented command actually exist?|yes|a doc naming a flag, target or probe section that is not there"
)

REGISTRY_TS=(
  "npm-ci|npm ci (reproducible install)|yes|lockfile drift, a missing or corrupt dependency"
  "typecheck|tsc --noEmit on the app config|yes|any type error in src/ or tool/"
  "test|vitest run — the TypeScript suite|yes|engine, component and acceptance regressions"
  "golden-regen|regenerate the cross-language golden vectors|yes|the generator itself failing"
  "golden-diff|the regenerated vectors match the committed file|yes|the two engines drifting apart"
  "build|production build (tsc -b && vite build)|yes|anything that breaks the shipped bundle"
)
REGISTRY_DART=(
  "pub-get|dart pub get|no|the package resolving at all — this has never been run on this tree"
  "analyze|dart analyze (errors and warnings fail)|no|whether the capture-effect mirror COMPILES"
  "test|dart test --reporter expanded|no|the 197 Dart cases, including 3 that have never run"
  "cli|CLI acceptance: campus_quad, seed 42, gated|no|the skills/02 and skills/08 criteria"
)
REGISTRY_CLI=(
  "campus_quad-always-on|campus_quad, always-on radios, gated|no|delivery/overhead/SUPER ratio"
  "campus_quad-duty-cycle|campus_quad with --duty-cycle, gated|no|the skills/07 battery arm"
  "sparse_village|sparse_village, reported not gated|no|a disconnected world still runs"
  "festival_crowd|festival_crowd, reported not gated|no|dense-mobile behaviour"
  "partitioned_pair|partitioned_pair, reported not gated|no|the DTN carry path"
)
REGISTRY_PROBES=(
  "sos|SOS flood reach (roadmap Phase 3)|no|SOS reaching the sender's component"
  "group|group delivery modes (docs/06 §14)|no|unicast vs broadcast group cost"
  "history|group history anti-entropy (docs/06 §17)|no|digest repair after a member goes dark"
  "media|media transport and PTT (docs/08)|no|10 MB at 1/2/3 hops, PTT play delay"
)
REGISTRY_EVIDENCE=(
  "media-probe|npm run media — all thirteen sections|partial|the docs/08 numbers, reproduced"
  "history-probe|npm run history|partial|the docs/06 §17 numbers, reproduced"
  "e2ee-probe|npm run e2ee — handshake latency, session churn, packet sizing|yes|the docs/07 §2-§4 numbers, reproduced"
)

describe_group() {
  case "$1" in
    docs)     printf 'Documentation drift — needs no toolchain, so it always runs' ;;
    ts)       printf 'TypeScript engine + React visualiser — verified locally many times' ;;
    dart)     printf 'Dart authoritative engine — NEVER COMPILED on the current tree' ;;
    cli)      printf 'CLI acceptance across scenarios — never run on the current tree' ;;
    probes)   printf 'CLI probes behind docs/06 and docs/08 — never run on the current tree' ;;
    evidence) printf 'Evidence probes that produce the published numbers (slow)' ;;
  esac
}

if [ "$LIST_ONLY" = 1 ]; then
  log "checks this script can run"
  for g in $GROUPS_ALL; do
    selected "$g" || { printf '\n%s\n' "${C_DIM}── $g (not selected) ──${C_RESET}"; continue; }
    printf '\n%s\n' "── $g — $(describe_group "$g")"
    var="REGISTRY_${g^^}[@]"
    for row in "${!var}"; do
      IFS='|' read -r name label before catches <<< "$row"
      case "$before" in
        yes)     tag="${C_GREEN}verified before${C_RESET}" ;;
        no)      tag="${C_RED}NEVER RUN${C_RESET}" ;;
        *)       tag="${C_YELLOW}$before${C_RESET}" ;;
      esac
      printf '  %-24s %-14s %s\n' "$name" "$tag" "${C_DIM}$label${C_RESET}"
      printf '  %-24s %s\n' "" "${C_DIM}catches: $catches${C_RESET}"
    done
  done
  printf '\n'
  log_dim "run without --list to execute them. Nothing stops at the first failure."
  exit 0
fi

# --- results -------------------------------------------------------------------

ROWS=()          # group|name|outcome|seconds|detail
FAILURES=()      # group|name|artifact
add_row() { ROWS+=("$1|$2|$3|$4|$5"); }
add_fail() { FAILURES+=("$1|$2|$3"); }
# lib.sh's skip_step writes "${artifact_dir}/${label// /-}.missing". Mirror that exactly.
missing_file() { printf '%s' "$artifact_dir/${1// /-}.missing"; }

HAVE_DART=1; have dart || HAVE_DART=0
HAVE_NODE=1; have node || HAVE_NODE=0
HAVE_NPM=1;  have npm  || HAVE_NPM=0

init_artifacts checks
RUN_ID="$(basename "$artifact_dir")"
[ -n "$REPORT" ] || REPORT="$artifact_dir/REPORT.md"

START_ALL=$(date +%s)

log "collecting checks · $(git_branch) @ $(git_sha)"
log_dim "artifacts: ${artifact_dir#$ROOT/}"
log_dim "report:    ${REPORT#$ROOT/}"
echo
# One line, because shell continuation would concatenate the indents into visible gaps.
NODE_VER="$([ "$HAVE_NODE" = 1 ] && tool_version node | sed 's/^v//' || echo MISSING)"
NPM_VER="$([ "$HAVE_NPM" = 1 ] && tool_version npm || echo MISSING)"
PY_VER="$(have python3 && tool_version python3 | awk '{print $2}' || echo MISSING)"
log_dim "toolchain   node $NODE_VER · npm $NPM_VER · python3 $PY_VER"
if [ "$HAVE_DART" = 1 ]; then
  DART_VER="$(dart_sdk_version)"
  log_dim "            dart ${DART_VER:-unknown}"
  # The pubspec's floor, checked before anything runs: an older SDK makes `pub get` fail with a
  # message about the package rather than about the toolchain, which sends you looking in the
  # wrong place.
  if [ -n "$DART_VER" ] && ! version_ge "$DART_VER" "$MIN_DART_SDK"; then
    warn "Dart SDK $DART_VER is older than the $MIN_DART_SDK that sim/mesh_sim/pubspec.yaml"
    warn "requires. pub get will fail on the SDK constraint, not on anything in the code."
  fi
else
  log_dim "            dart ${C_YELLOW}MISSING${C_RESET} — the Dart group will be reported as NOT RUN, not as passed."
  log_dim "            Install it per docs/11-windows-11-workflow.md §2 (or docs/10 §2 on Linux/macOS)"
  log_dim "            and re-run. Until then this report cannot answer the one open question."
fi
echo

# --- group: docs ---------------------------------------------------------------
#
# First because it is the only group that needs no toolchain at all: pure Python over files that
# are already here. It runs in well under a second, so it gives an answer even on a machine where
# nothing else can, and it catches the failure mode this repository keeps hitting — a command
# written into the docs from memory that the program does not have.

if selected docs; then
  log "docs — $(describe_group docs)"
  if have python3; then
    run_step o "documentation drift (check-docs.py)" "docs-drift.txt" "$ROOT" \
             python3 "$HERE/check-docs.py"
    add_row docs drift "$o" "$SECONDS" ""
    [ "$o" = success ] || add_fail docs drift docs-drift.txt
  else
    skip_step o "docs (whole group)" "python3 is not installed"
    add_row docs drift not-run 0 "no python3"
    add_fail docs "(whole group)" "-"
  fi
  echo
fi

# --- group: ts -----------------------------------------------------------------

if selected ts; then
  log "ts — $(describe_group ts)"
  if [ "$HAVE_NPM" = 0 ]; then
    skip_step o "ts (whole group)" "npm is not installed"
    for row in "${REGISTRY_TS[@]}"; do
      IFS='|' read -r name _ _ _ <<< "$row"; add_row ts "$name" not-run 0 "npm missing"
    done
    add_fail ts "(whole group)" "-"
  else
    run_step o "npm ci" "ts-npm-ci.txt" "$ROOT" npm ci --no-audit --no-fund
    add_row ts npm-ci "$o" "$SECONDS" ""; [ "$o" = success ] || add_fail ts npm-ci ts-npm-ci.txt

    run_step o "Typecheck (tsc --noEmit)" "ts-typecheck.txt" "$ROOT" npx tsc --noEmit -p tsconfig.json
    add_row ts typecheck "$o" "$SECONDS" ""; [ "$o" = success ] || add_fail ts typecheck ts-typecheck.txt

    run_step o "Unit + acceptance tests (vitest)" "ts-test.txt" "$ROOT" npm test
    counts="$(grep -oE 'Tests +[0-9]+ (passed|failed)' "$artifact_dir/ts-test.txt" 2>/dev/null | tail -1)"
    add_row ts test "$o" "$SECONDS" "$counts"; [ "$o" = success ] || add_fail ts test ts-test.txt

    run_step o "Golden vectors regenerate" "ts-golden-regen.txt" "$ROOT" npm run golden
    add_row ts golden-regen "$o" "$SECONDS" ""; [ "$o" = success ] || add_fail ts golden-regen ts-golden-regen.txt

    # The check CI actually applies: regenerating must not change the committed file. Run as its
    # own step so the report can distinguish "the generator broke" from "the vectors drifted".
    run_step o "Golden vectors are up to date" "ts-golden-diff.txt" "$ROOT" \
             git diff --quiet -- test-fixtures/golden-vectors.json
    add_row ts golden-diff "$o" "$SECONDS" ""
    if [ "$o" != success ]; then
      add_fail ts golden-diff ts-golden-diff.txt
      warn "golden vectors changed. Either mirror the change into the other engine, or revert it."
    fi

    run_step o "Production build (tsc -b && vite build)" "ts-build.txt" "$ROOT" npm run build
    add_row ts build "$o" "$SECONDS" ""; [ "$o" = success ] || add_fail ts build ts-build.txt
  fi
  echo
fi

# --- group: dart ---------------------------------------------------------------

if selected dart; then
  log "dart — $(describe_group dart)"
  if [ "$HAVE_DART" = 0 ]; then
    skip_step o "dart (whole group)" "the Dart SDK is not installed"
    for row in "${REGISTRY_DART[@]}"; do
      IFS='|' read -r name _ _ _ <<< "$row"; add_row dart "$name" not-run 0 "no Dart SDK"
    done
    add_fail dart "(whole group)" "-"
  else
    run_step o "dart pub get" "dart-pub-get.txt" "$DART_DIR" dart pub get
    add_row dart pub-get "$o" "$SECONDS" ""; [ "$o" = success ] || add_fail dart pub-get dart-pub-get.txt

    # All three run unconditionally, exactly as the workflow's dart job does, so one red build
    # reports the analyzer, the test failures AND the CLI metrics instead of stopping at the first.
    run_step o "Analyze (dart analyze)" "dart-analyze.txt" "$DART_DIR" dart analyze
    add_row dart analyze "$o" "$SECONDS" ""
    [ "$o" = success ] || add_fail dart analyze dart-analyze.txt

    run_step o "Tests (dart test --reporter expanded)" "dart-test.txt" "$DART_DIR" \
             dart test --reporter expanded
    dcounts="$(grep -oE '\+[0-9]+( -[0-9]+)?: (All tests passed|Some tests failed)' "$artifact_dir/dart-test.txt" 2>/dev/null | tail -1)"
    add_row dart test "$o" "$SECONDS" "$dcounts"
    [ "$o" = success ] || add_fail dart test dart-test.txt

    run_step o "CLI acceptance (campus_quad, seed 42)" "dart-cli.txt" "$DART_DIR" \
             dart run bin/mesh_sim.dart --scenario campus_quad --seed 42
    add_row dart cli "$o" "$SECONDS" ""
    [ "$o" = success ] || add_fail dart cli dart-cli.txt

    # Reuse the parser CI uses, so the report carries real file:line:col locations rather than a
    # wall of raw output. This is the part that makes a remote failure fixable from the report.
    if have python3; then
      python3 "$HERE/diagnostics.py" \
        --analyze "$artifact_dir/dart-analyze.txt" \
        --test    "$artifact_dir/dart-test.txt" \
        --cli     "$artifact_dir/dart-cli.txt" \
        --format text --out "$artifact_dir/dart-diagnostics.json" \
        > "$artifact_dir/dart-diagnostics.txt" 2>&1 || true
      echo
      log_dim "dart diagnostics (the same parser CI publishes as annotations):"
      sed 's/^/    /' "$artifact_dir/dart-diagnostics.txt" | head -60
    fi
  fi
  echo
fi

# --- group: cli ----------------------------------------------------------------

if selected cli; then
  log "cli — $(describe_group cli)"
  if [ "$HAVE_DART" = 0 ]; then
    skip_step o "cli-matrix (whole group)" "needs the Dart SDK"
    for row in "${REGISTRY_CLI[@]}"; do
      IFS='|' read -r name _ _ _ <<< "$row"; add_row cli "$name" not-run 0 "no Dart SDK"
    done
    add_fail cli "(whole group)" "-"
  else
    # Only campus_quad is gated in CI; the other three report their numbers without asserting the
    # connected-world criteria, because a sparse or partitioned world cannot meet them by design.
    run_step o "campus_quad (always-on)" "cli-campus_quad-always-on.txt" "$DART_DIR" \
             dart run bin/mesh_sim.dart --scenario campus_quad --seed 42
    add_row cli campus_quad-always-on "$o" "$SECONDS" ""
    [ "$o" = success ] || add_fail cli campus_quad-always-on cli-campus_quad-always-on.txt

    run_step o "campus_quad (--duty-cycle)" "cli-campus_quad-duty-cycle.txt" "$DART_DIR" \
             dart run bin/mesh_sim.dart --scenario campus_quad --seed 42 --duty-cycle
    add_row cli campus_quad-duty-cycle "$o" "$SECONDS" ""
    [ "$o" = success ] || add_fail cli campus_quad-duty-cycle cli-campus_quad-duty-cycle.txt

    for scenario in sparse_village festival_crowd partitioned_pair; do
      run_step o "$scenario (--no-check)" "cli-$scenario.txt" "$DART_DIR" \
               dart run bin/mesh_sim.dart --scenario "$scenario" --seed 42 --no-check
      add_row cli "$scenario" "$o" "$SECONDS" ""
      [ "$o" = success ] || add_fail cli "$scenario" "cli-$scenario.txt"
    done
  fi
  echo
fi

# --- group: probes -------------------------------------------------------------

if selected probes; then
  log "probes — $(describe_group probes)"
  if [ "$HAVE_DART" = 0 ]; then
    skip_step o "probes (whole group)" "needs the Dart SDK"
    for row in "${REGISTRY_PROBES[@]}"; do
      IFS='|' read -r name _ _ _ <<< "$row"; add_row probes "$name" not-run 0 "no Dart SDK"
    done
    add_fail probes "(whole group)" "-"
  else
    run_step o "SOS flood reach" "probe-sos.txt" "$DART_DIR" \
             dart run bin/mesh_sim.dart --scenario campus_quad --seed 42 --sos --no-check
    add_row probes sos "$o" "$SECONDS" ""; [ "$o" = success ] || add_fail probes sos probe-sos.txt

    run_step o "Group delivery modes" "probe-group.txt" "$DART_DIR" \
             dart run bin/mesh_sim.dart --scenario campus_quad --seed 42 --group 5 --no-check
    add_row probes group "$o" "$SECONDS" ""; [ "$o" = success ] || add_fail probes group probe-group.txt

    run_step o "Group history anti-entropy" "probe-history.txt" "$DART_DIR" \
             dart run bin/mesh_sim.dart --scenario campus_quad --seed 42 --history --no-check
    add_row probes history "$o" "$SECONDS" ""; [ "$o" = success ] || add_fail probes history probe-history.txt

    run_step o "Media transport and PTT" "probe-media.txt" "$DART_DIR" \
             dart run bin/mesh_sim.dart --scenario campus_quad --seed 42 --media --no-check
    add_row probes media "$o" "$SECONDS" ""; [ "$o" = success ] || add_fail probes media probe-media.txt
  fi
  echo
fi

# --- group: evidence -----------------------------------------------------------

if selected evidence; then
  log "evidence — $(describe_group evidence)"
  warn "this group re-runs every published measurement. Expect several minutes."
  if [ "$HAVE_NPM" = 0 ]; then
    skip_step o "evidence (whole group)" "npm is not installed"
    add_row evidence media-probe not-run 0 "npm missing"
    add_row evidence history-probe not-run 0 "npm missing"
    add_row evidence e2ee-probe not-run 0 "npm missing"
    add_fail evidence "(whole group)" "-"
  else
    run_step o "npm run media (thirteen sections)" "evidence-media.txt" "$ROOT" npm run media
    add_row evidence media-probe "$o" "$SECONDS" ""
    [ "$o" = success ] || add_fail evidence media-probe evidence-media.txt

    run_step o "npm run history" "evidence-history.txt" "$ROOT" npm run history
    add_row evidence history-probe "$o" "$SECONDS" ""
    [ "$o" = success ] || add_fail evidence history-probe evidence-history.txt

    # The three sections are one run: latency is the expensive one, churn and packet are seconds.
    run_step o "npm run e2ee (latency, churn, packet)" "evidence-e2ee.txt" "$ROOT" npm run e2ee
    add_row evidence e2ee-probe "$o" "$SECONDS" ""
    [ "$o" = success ] || add_fail evidence e2ee-probe evidence-e2ee.txt
  fi
  echo
fi

END_ALL=$(date +%s)

# --- verdict -------------------------------------------------------------------

N_PASS=0 N_FAIL=0 N_NOTRUN=0
for row in "${ROWS[@]}"; do
  IFS='|' read -r _g _n outcome _s _d <<< "$row"
  case "$outcome" in
    success) N_PASS=$((N_PASS + 1)) ;;
    not-run|missing) N_NOTRUN=$((N_NOTRUN + 1)) ;;
    *) N_FAIL=$((N_FAIL + 1)) ;;
  esac
done

log "result"
printf '  %s passed · %s failed · %s could not run · %ss elapsed\n\n' \
  "${C_GREEN}${N_PASS}${C_RESET}" "${C_RED}${N_FAIL}${C_RESET}" \
  "${C_YELLOW}${N_NOTRUN}${C_RESET}" "$((END_ALL - START_ALL))"

current_group=""
for row in "${ROWS[@]}"; do
  IFS='|' read -r g name outcome secs detail <<< "$row"
  if [ "$g" != "$current_group" ]; then
    printf '%s\n' "  $g"
    current_group="$g"
  fi
  case "$outcome" in
    success)        marker="${C_GREEN}PASS${C_RESET}   " ;;
    not-run|missing) marker="${C_YELLOW}NOT RUN${C_RESET}" ;;
    *)              marker="${C_RED}FAIL${C_RESET}   " ;;
  esac
  # Look up whether this check had ever been verified before this run.
  before="?"
  var="REGISTRY_${g^^}[@]"
  for r in "${!var}"; do
    IFS='|' read -r rn _rb rb _rc <<< "$r"
    [ "$rn" = "$name" ] && before="$rb"
  done
  flag=""
  [ "$before" = no ] && flag=" ${C_DIM}(first ever run)${C_RESET}"
  printf '    %s %-26s %s%s%s\n' "$marker" "$name" "${C_DIM}${detail}${C_RESET}" "$flag" ""
done

# --- the report ----------------------------------------------------------------

{
  printf '# Verification report\n\n'
  printf '| | |\n| --- | --- |\n'
  printf '| Commit | `%s` |\n' "$(git_sha)"
  printf '| Branch | `%s` |\n' "$(git_branch)"
  printf '| Groups | `%s` |\n' "$SELECTED"
  printf '| Date | %s |\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '| Host | `%s` |\n' "$(uname -srm 2>/dev/null || echo unknown)"
  printf '| node | %s |\n' "$(tool_version node | sed 's/^v//')"
  printf '| npm | %s |\n' "$([ "$HAVE_NPM" = 1 ] && tool_version npm || echo 'MISSING')"
  printf '| dart | %s |\n' "$([ "$HAVE_DART" = 1 ] && dart_sdk_version || echo 'MISSING')"
  printf '| python3 | %s |\n' "$(tool_version python3 | awk '{print $2}')"
  printf '| Elapsed | %ss |\n\n' "$((END_ALL - START_ALL))"

  printf '## Summary\n\n'
  printf '**%s passed · %s failed · %s could not run.**\n\n' "$N_PASS" "$N_FAIL" "$N_NOTRUN"
  printf '| group | check | result | verified before? | detail |\n| --- | --- | --- | --- | --- |\n'
  for row in "${ROWS[@]}"; do
    IFS='|' read -r g name outcome secs detail <<< "$row"
    before="?"
    var="REGISTRY_${g^^}[@]"
    for r in "${!var}"; do
      IFS='|' read -r rn _rb rb _rc <<< "$r"; [ "$rn" = "$name" ] && before="$rb"
    done
    printf '| %s | `%s` | %s | %s | %s |\n' "$g" "$name" "$outcome" "$before" "${detail:-—}"
  done
  printf '\n'

  if [ "${#FAILURES[@]}" -gt 0 ]; then
    printf '## Failures, and checks that could not run\n\n'
    for f in "${FAILURES[@]}"; do
      IFS='|' read -r g name art <<< "$f"
      printf '### %s / %s\n\n' "$g" "$name"
      if [ "$art" = "-" ] || [ ! -f "$artifact_dir/$art" ]; then
        # skip_step wrote the reason to <label, spaces as dashes>.missing. Show it here: the
        # reader of this file may be nowhere near the machine that produced it.
        printf 'Could not run, so there is no output to show. The reason recorded was:\n\n'
        if [ -f "$(missing_file "$g $name")" ]; then
          printf '    %s\n\n' "$(cat "$(missing_file "$g $name")")"
        else
          printf '    (no reason recorded)\n\n'
        fi
        continue
      fi
      printf '```\n'
      # Tail rather than head: for compilers and test runners the actionable lines are at the
      # end, after the progress output. 120 lines is enough for a real diagnosis and small
      # enough to paste.
      tail -120 "$artifact_dir/$art"
      printf '\n```\n\n'
    done
  fi

  if [ -f "$artifact_dir/dart-diagnostics.txt" ]; then
    printf '## Dart diagnostics, parsed\n\n'
    printf 'The same parser CI publishes as annotations, so locations are `file:line:col`.\n\n'
    printf '```\n'; cat "$artifact_dir/dart-diagnostics.txt"; printf '\n```\n\n'
  fi

  printf '## Artifacts\n\n`%s`\n\n' "${artifact_dir#$ROOT/}"
  printf 'Every check that ran has a `.txt` capture there, plus a `.exit` file with its status.\n'
  printf 'A group that could not run has a `.missing` file recording why.\n'
} > "$REPORT"

log_dim "report written: ${REPORT#$ROOT/}"

# --- the paste-back block ------------------------------------------------------
#
# Compact on purpose. If this report has to travel back to whoever is fixing the failures, a
# 400-line Markdown file is not going to make the trip; one line per check plus the first
# failure's detail will.

PASTE="$(mktemp)"
{
  # `groups=` is in the header on purpose: a paste-back listing one check is otherwise
  # indistinguishable from a full run in which only one check exists.
  printf 'DUMAN-CHECKS %s %s groups=%s node=%s dart=%s\n' \
    "$(git_sha)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${SELECTED// /,}" \
    "$NODE_VER" \
    "$([ "$HAVE_DART" = 1 ] && dart_sdk_version || echo MISSING)"
  for row in "${ROWS[@]}"; do
    IFS='|' read -r g name outcome secs detail <<< "$row"
    printf '%s.%s=%s%s\n' "$g" "$name" "$outcome" "${detail:+($detail)}"
  done
  if [ "${#FAILURES[@]}" -gt 0 ]; then
    # Prefer the first check that actually ran and failed. A whole-group skip carries no output,
    # so leading with one would hide a real failure behind it.
    real=""
    for f in "${FAILURES[@]}"; do
      IFS='|' read -r _g _n a <<< "$f"
      if [ "$a" != "-" ] && [ -f "$artifact_dir/$a" ]; then real="$f"; break; fi
    done
    if [ -n "$real" ]; then
      printf -- '--- first failure detail ---\n'
      IFS='|' read -r fg fname fart <<< "$real"
      printf '%s/%s:\n' "$fg" "$fname"
      tail -40 "$artifact_dir/$fart"
    else
      printf -- '--- why nothing could run ---\n'
      printf 'no check failed; %s could not run for want of a toolchain:\n' "$N_NOTRUN"
      for f in "${FAILURES[@]}"; do
        IFS='|' read -r fg fname _a <<< "$f"
        [ -f "$(missing_file "$fg $fname")" ] && cat "$(missing_file "$fg $fname")"
      done
    fi
    if [ -f "$artifact_dir/dart-diagnostics.txt" ]; then
      printf -- '--- dart diagnostics ---\n'
      head -40 "$artifact_dir/dart-diagnostics.txt"
    fi
  fi
} > "$PASTE"

echo
log "paste-back block"
log_dim "everything above, compact enough to send back in one message:"
echo
cat "$PASTE"
rm -f "$PASTE"

# --- json ----------------------------------------------------------------------

if [ -n "$JSON_OUT" ] && have python3; then
  python3 - "$JSON_OUT" "$(git_sha)" "$(git_branch)" "$N_PASS" "$N_FAIL" "$N_NOTRUN" \
            "$((END_ALL - START_ALL))" "$RUN_ID" "$REPORT" "${SELECTED// /,}" ${ROWS[@]+"${ROWS[@]}"} <<'PY'
import json, sys
from datetime import datetime, timezone

(out, sha, branch, npass, nfail, nnotrun, secs, run_id, report, groups, *rows) = sys.argv[1:]
checks = []
for r in rows:
    parts = r.split("|")
    if len(parts) >= 5:
        checks.append({"group": parts[0], "name": parts[1], "result": parts[2],
                       "detail": parts[4]})
json.dump({
    "runId": run_id, "sha": sha, "branch": branch, "groups": groups.split(","),
    "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "seconds": int(secs), "passed": int(npass), "failed": int(nfail),
    "notRun": int(nnotrun), "report": report, "checks": checks,
}, open(out, "w", encoding="utf-8"), indent=2)
PY
  log_dim "json record: $JSON_OUT"
fi

echo
if [ "$N_FAIL" -gt 0 ] || [ "$N_NOTRUN" -gt 0 ]; then
  if [ "$N_FAIL" -gt 0 ]; then
    err "$N_FAIL check(s) FAILED, and $N_NOTRUN could not run."
  else
    err "nothing failed, but $N_NOTRUN check(s) could not run. That is not a pass."
  fi
  if [ "$N_NOTRUN" -gt 0 ] && [ "$HAVE_DART" = 0 ]; then
    err "The Dart SDK is missing, so this report cannot answer the one open question:"
    err "whether the Dart capture-effect mirror compiles. Install it and re-run."
  fi
  err "Report: ${REPORT#$ROOT/}"
  exit 1
fi

if [ "$SCOPED" = 1 ]; then
  not_selected=""
  for g in $GROUPS_ALL; do selected "$g" || not_selected="$not_selected $g"; done
  log "every selected check passed (groups: $SELECTED)."
  log_dim "not selected:${not_selected} — this was not a full run and says nothing about them."
else
  log "every check passed — including the ones that had never been run before."
fi
exit 0
