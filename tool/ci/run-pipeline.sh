#!/usr/bin/env bash
# Run the repository's CI pipeline on this machine.
#
# This is a *runner*, not a reimplementation: every command below is the command
# `.github/workflows/ci.yml` runs, in the order it runs it, including the parts that are
# easy to drop and matter most —
#
#   * the `dart` job runs analyze, test and the CLI check unconditionally and gates on all
#     three afterwards, so one red build reports everything instead of stopping at the
#     first failure;
#   * `cli-matrix` and `probes` have `needs: dart`, so they are *blocked* when dart fails
#     rather than quietly running anyway;
#   * the golden-vector step fails when `npm run golden` changes the committed file, which
#     is how a cross-language drift between the two engines gets caught.
#
# The rule that makes a local run trustworthy: a job that could not run is recorded as
# MISSING and fails the pipeline. Pass --allow-missing-dart to accept a partial run, and
# the exit code becomes 2 (partial) rather than 0 — never 0. `validate-and-push.sh` only
# pushes on 0, so an unverified Dart engine cannot ride along on a green TypeScript run.
#
# Usage:
#   tool/ci/run-pipeline.sh                       # every job
#   tool/ci/run-pipeline.sh --job web             # one job
#   tool/ci/run-pipeline.sh --job dart,probes     # several
#   tool/ci/run-pipeline.sh --fast                # typecheck + tests + analyze only
#   tool/ci/run-pipeline.sh --list                # what would run
#
# Exit codes: 0 all selected jobs ran and passed · 1 something failed or could not run ·
#             2 partial (--allow-missing-dart) · 64 bad usage

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

ROOT="$(repo_root)"
DART_DIR="$ROOT/sim/mesh_sim"

JOBS_ALL="checks web dart cli-matrix probes"
JOBS_FAST_WEB="typecheck test golden"
JOBS_FAST_DART="analyze test"

SELECTED="$JOBS_ALL"
FAST=0
KEEP_GOING=0
ALLOW_MISSING_DART=0
QUIET=0
JSON_OUT=""
LIST_ONLY=0
LABEL="run"

usage() {
  # Walk the leading `#` block instead of a hard-coded line range. Four of these scripts had
  # drifted past their own range and were printing their source code as help text — measured, not
  # suspected: `run-pipeline.sh --help` emitted eleven lines of `set -uo pipefail`, `HERE=…`,
  # `. "$HERE/lib.sh"`. Re-tuning six magic numbers would leave the same trap for the next edit;
  # this is the pattern `daily.sh` already uses.
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
  cat <<USAGE

Options:
  --job LIST             comma-separated: checks, web, dart, cli-matrix, probes (default: all)
  --fast                 the quick subset: typecheck, unit tests, analyze, dart test.
                         Skips the production build, the CLI acceptance matrix and the
                         probes. Good before a commit; not good before a push.
  --keep-going           run every selected job even after one fails (default: stop at the
                         first failing job, except inside the dart job which always
                         reports all three of its checks)
  --allow-missing-dart   accept a run that could not execute the Dart jobs. Exit code 2
                         instead of 1. Never exit 0: a partial run is not a green run.
  --artifacts DIR        where to capture step output (default artifacts/ci/<ts>-<sha>)
  --json PATH            write a machine-readable result record
  --label NAME           tag the artifact directory (default: run)
  --quiet                only the result table
  --list                 print what would run and exit
  -h, --help

USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --job)                SELECTED="${2//,/ }"; shift 2 ;;
    --job=*)              SELECTED="${1#*=}"; SELECTED="${SELECTED//,/ }"; shift ;;
    --fast)               FAST=1; shift ;;
    --keep-going)         KEEP_GOING=1; shift ;;
    --allow-missing-dart) ALLOW_MISSING_DART=1; shift ;;
    --artifacts)          ARTIFACT_OVERRIDE="$2"; shift 2 ;;
    --json)               JSON_OUT="$2"; shift 2 ;;
    --label)              LABEL="$2"; shift 2 ;;
    --quiet)              QUIET=1; shift ;;
    --list)               LIST_ONLY=1; shift ;;
    -h|--help)            usage; exit 0 ;;
    *)                    err "unknown option: $1"; usage >&2; exit 64 ;;
  esac
done

for job in $SELECTED; do
  case " $JOBS_ALL " in *" $job "*) ;; *) err "unknown job: $job (one of: $JOBS_ALL)"; exit 64 ;; esac
done

# --- what would run -----------------------------------------------------------

describe_jobs() {
  cat <<'PLAN'
checks     Toolchain-free static checks              [no Node, no Dart — python3 only]
             python3 tool/ci/check-docs.py
             python3 tool/ci/check-dart-balance.py
             python3 tool/ci/check-parity.py
             python3 tool/ci/check-dart-sites.py
             python3 tool/ci/check-ps1.py make.ps1
             the four checkers' --self-test modes
web        TypeScript engine + React simulator
             npm ci
             npx tsc --noEmit -p tsconfig.json
             npm test
             npm run golden && git diff --quiet -- test-fixtures/golden-vectors.json
             npm run build
dart       Dart mesh_sim (authoritative engine)      [runs all three, then gates]
             dart pub get (--enforce-lockfile; pubspec.lock is committed, so that is the branch taken)
             dart analyze
             dart test --reporter expanded
             dart run bin/mesh_sim.dart --scenario campus_quad --seed 42
             diagnostics, then gate on analyze+test+cli
cli-matrix CLI acceptance across scenarios           [needs: dart]
             campus_quad      --seed 42
             campus_quad      --seed 42 --duty-cycle
             sparse_village   --seed 42 --no-check
             festival_crowd   --seed 42 --no-check
             partitioned_pair --seed 42 --no-check
probes     CLI probes (SOS, groups, media)           [needs: dart]
             --sos --no-check · --group 5 --no-check
             --history --no-check · --media --no-check
PLAN
}

if [ "$LIST_ONLY" = 1 ]; then
  describe_jobs
  exit 0
fi

if [ "$FAST" = 1 ]; then
  log_dim "fast mode: skipping the production build, the CLI acceptance matrix and the probes"
fi

init_artifacts "$LABEL"
[ -n "${ARTIFACT_OVERRIDE:-}" ] && { artifact_dir="$ARTIFACT_OVERRIDE"; mkdir -p "$artifact_dir"; }

RUN_ID="$(basename "$artifact_dir")"
[ "$QUIET" = 1 ] || log "local CI run ${C_DIM}${RUN_ID} on $(git_branch) @ $(git_sha)${C_RESET}"
[ "$QUIET" = 1 ] || log_dim "artifacts: ${artifact_dir#$ROOT/}"

# --- preflight ----------------------------------------------------------------

MISSING_TOOLS=""
have node || MISSING_TOOLS="$MISSING_TOOLS node"
have npm  || MISSING_TOOLS="$MISSING_TOOLS npm"
have git  || MISSING_TOOLS="$MISSING_TOOLS git"
HAVE_DART=1; have dart || { HAVE_DART=0; MISSING_TOOLS="$MISSING_TOOLS dart"; }
HAVE_PYTHON=1; have python3 || { HAVE_PYTHON=0; MISSING_TOOLS="$MISSING_TOOLS python3"; }

if [ "$QUIET" = 0 ]; then
  echo
  log_dim "toolchain   node $(tool_version node | sed 's/^v//')   npm $(tool_version npm)   python3 $(tool_version python3 | awk '{print $2}')"
  if [ "$HAVE_DART" = 1 ]; then
    log_dim "            dart $(dart_sdk_version)"
  else
    log_dim "            dart ${C_YELLOW}MISSING${C_RESET} — see docs/10-local-development-and-ci.md §2"
  fi
  log_dim "            CI pins node ${REQUIRED_NODE_MAJOR} (actions/setup-node) and dart ${REQUIRED_DART_SDK} ≥ ${MIN_DART_SDK} (pubspec)"
fi

if [ -n "$MISSING_TOOLS" ]; then
  warn "missing toolchain:$MISSING_TOOLS"

  # Only complain when the selection actually needs what is missing. `--job web` never
  # touches Dart, and telling someone that run is a partial failure would train them to
  # ignore the message on the runs where it genuinely matters.
  NEEDS_DART=0 NEEDS_NODE=0
  for job in $SELECTED; do
    case "$job" in
      dart|cli-matrix|probes) NEEDS_DART=1 ;;
      web)                    NEEDS_NODE=1 ;;
    esac
  done

  MISSING_REQUIRED=""
  for m in $MISSING_TOOLS; do
    case "$m" in
      dart|python3) [ "$NEEDS_DART" = 1 ] && MISSING_REQUIRED="$MISSING_REQUIRED $m" ;;
      node|npm)     [ "$NEEDS_NODE" = 1 ] && MISSING_REQUIRED="$MISSING_REQUIRED $m" ;;
      *)            MISSING_REQUIRED="$MISSING_REQUIRED $m" ;;
    esac
  done

  if [ -z "$MISSING_REQUIRED" ]; then
    log_dim "       not needed by the selected jobs:$SELECTED"
  elif [ "$ALLOW_MISSING_DART" = 0 ]; then
    err "refusing to report a partial run as success. Install what is missing, or pass"
    err "  --allow-missing-dart   to accept exit code 2 (partial) instead of 0 (verified)."
    # Still fall through and run what can run, so the output is useful; the exit code
    # at the end is what carries the verdict.
  fi
fi

# --- result bookkeeping -------------------------------------------------------

declare -A JOB_RESULT
RESULTS_ORDER=()

record_job() { # <job> <result> <detail>
  JOB_RESULT["$1"]="$2"
  JOB_DETAIL["$1"]="${3:-}"
  RESULTS_ORDER+=("$1")
}
declare -A JOB_DETAIL

job_header() {
  [ "$QUIET" = 1 ] && return 0
  echo
  log "$1"
}

# should_run <job> — honour --job selection and `needs:` edges.
needs_dart() {
  case "$1" in cli-matrix|probes) return 0 ;; *) return 1 ;; esac
}

selected() { case " $SELECTED " in *" $1 "*) return 0 ;; *) return 1 ;; esac }

# --- job: web -----------------------------------------------------------------

job_checks() {
  job_header "checks — toolchain-free static checks (docs, parity, Dart sites)"
  local out
  if ! have python3; then
    skip_step out "static checks (whole job)" "python3 is not installed"
    record_job checks missing "python3 absent"
    return
  fi
  # Mirrors the workflow's `checks` job step for step. No Node and no Dart, which is the point:
  # this job answers even when the toolchain jobs cannot, and it is the only one that catches a
  # protocol constant changed in one engine and not the other, a config knob or statistics field
  # present in one engine only, or a document naming a command that does not exist.
  local failed=""
  run_step out "Documentation drift (check-docs.py)" "checks-drift.txt" \
           "$ROOT" python3 tool/ci/check-docs.py
  [ "$out" = success ] || failed="$failed drift"

  run_step out "Dart delimiter balance (check-dart-balance.py)" "checks-dart-balance.txt" \
           "$ROOT" python3 tool/ci/check-dart-balance.py
  [ "$out" = success ] || failed="$failed dart-balance"

  run_step out "Cross-language parity (check-parity.py)" "checks-parity.txt" \
           "$ROOT" python3 tool/ci/check-parity.py
  [ "$out" = success ] || failed="$failed parity"

  run_step out "Dart declaration sites (check-dart-sites.py)" "checks-dart-sites.txt" \
           "$ROOT" python3 tool/ci/check-dart-sites.py
  [ "$out" = success ] || failed="$failed dart-sites"

  # make.ps1 cannot be executed here and could not be executed on the runner either, so both
  # sides check it statically and both say so. The workflow gained the same step; before that
  # the checker existed and no pipeline called it.
  run_step out "PowerShell static check (check-ps1.py)" "checks-ps1.txt" \
           "$ROOT" python3 tool/ci/check-ps1.py make.ps1
  [ "$out" = success ] || failed="$failed ps1"

  # A check that always passes is indistinguishable from a broken one, and all four have found
  # bugs in themselves, so the self-tests are a CI step rather than an optional extra.
  run_step out "Checker self-tests" "checks-self-test.txt" "$ROOT" bash -c \
    'python3 tool/ci/check-docs.py --self-test &&
     python3 tool/ci/check-dart-balance.py --self-test &&
     python3 tool/ci/check-parity.py --self-test &&
     python3 tool/ci/check-dart-sites.py --self-test'
  [ "$out" = success ] || failed="$failed self-test"

  if [ -n "$failed" ]; then record_job checks failure "$failed"; else record_job checks success ""; fi
}

job_web() {
  job_header "web — TypeScript engine + React simulator"
  local out
  if ! have npm; then skip_step out "npm ci" "npm is not installed"; record_job web missing "npm absent"; return; fi

  if [ "$FAST" = 0 ]; then
    run_step out "npm ci" "web-npm-ci.txt" "$ROOT" npm ci --no-audit --no-fund
    # A failed install is not recoverable: every later step would fail the same way and
    # say less about the cause.
    if [ "$out" != success ]; then record_job web failure "npm ci"; return; fi
  else
    [ -d "$ROOT/node_modules" ] || { run_step out "npm ci" "web-npm-ci.txt" "$ROOT" npm ci --no-audit --no-fund
                                     [ "$out" != success ] && { record_job web failure "npm ci"; return; }; }
    log_dim "  (fast: reusing existing node_modules)"
  fi

  local failed=""
  run_step out "Typecheck (tsc --noEmit)" "web-typecheck.txt" "$ROOT" npx tsc --noEmit -p tsconfig.json
  [ "$out" = success ] || failed="$failed typecheck"

  run_step out "Unit + acceptance tests (vitest)" "web-test.txt" "$ROOT" npm test
  [ "$out" = success ] || failed="$failed test"

  # The workflow regenerates the vectors and fails if the committed file moved. That is the
  # cross-language contract: if either engine's RNG stream, spawn order or scheduling
  # order drifts, the vectors change and this step says so.
  run_step out "Golden vectors regenerate" "web-golden.txt" "$ROOT" npm run golden
  if [ "$out" != success ]; then
    failed="$failed golden"
  elif ! git -C "$ROOT" diff --quiet -- test-fixtures/golden-vectors.json; then
    err "test-fixtures/golden-vectors.json is stale. Run 'npm run golden' and commit the result."
    git -C "$ROOT" diff --stat -- test-fixtures/golden-vectors.json | tee "$artifact_dir/web-golden-stale.txt"
    warn "the regenerated file is left in your working tree. Commit it if the change is intended,"
    warn "or restore it with: git checkout -- test-fixtures/golden-vectors.json"
    failed="$failed golden-stale"
  else
    step_line "${C_GREEN}PASS${C_RESET}" "Golden vectors are up to date" "0"
  fi

  if [ "$FAST" = 0 ]; then
    run_step out "Production build (tsc -b && vite build)" "web-build.txt" "$ROOT" npm run build
    [ "$out" = success ] || failed="$failed build"
    run_step out "Deployment regressions" "web-deployment.txt" "$ROOT" npm run test:deployment
    [ "$out" = success ] || failed="$failed deployment"
    run_step out "Dependency audit" "web-audit.txt" "$ROOT" npm audit --audit-level=low
    [ "$out" = success ] || failed="$failed audit"
    run_step out "Simulator staging package" "web-package.txt" "$ROOT" npm run package:simulator -- "$artifact_dir/package"
    [ "$out" = success ] || failed="$failed package"
  fi

  if [ -n "$failed" ]; then record_job web failure "$failed"; else record_job web success; fi
}

# --- job: dart ----------------------------------------------------------------

job_dart() {
  job_header "dart — Dart mesh_sim (authoritative engine)"
  if [ "$HAVE_DART" = 0 ]; then
    skip_step _o "dart (whole job)" "the Dart SDK is not installed"
    record_job dart missing "no Dart SDK"
    return
  fi

  # Mirrors the workflow: enforce the lockfile when one is committed, and say so plainly when
  # there is none, because `test: ^1.25.0` resolved afresh is not a reproducible build.
  local pubout
  run_step pubout "dart pub get" "dart-pub-get.txt" "$DART_DIR" bash -c \
    'if [ -f pubspec.lock ]; then dart pub get --enforce-lockfile; else
       echo "note: pubspec.lock is not committed, so this resolves dependencies fresh" >&2
       dart pub get; fi'
  if [ "$pubout" != success ]; then record_job dart failure "pub get"; return; fi

  # These three run unconditionally and are gated afterwards, exactly as the workflow does
  # it, so a single red build reports the analyzer, the test failures and the CLI metrics
  # together instead of stopping at the first.
  local analyze=success test=success cli=success package=success smoke=success
  run_step analyze "Analyze (dart analyze)" "dart-analyze.txt" "$DART_DIR" dart analyze
  run_step test    "Tests (dart test --reporter expanded)" "dart-test.txt" "$DART_DIR" \
                   dart test --reporter expanded

  if [ "$FAST" = 1 ]; then
    log_dim "  (fast: skipping the CLI acceptance run)"
    cli=success
  else
    run_step cli "CLI acceptance (campus_quad, seed 42)" "dart-cli.txt" "$DART_DIR" \
                 dart run bin/mesh_sim.dart --scenario campus_quad --seed 42
    mkdir -p "$DART_DIR/build"
    run_step package "Compile authoritative CLI" "dart-compile.txt" "$DART_DIR" \
                 dart compile exe bin/mesh_sim.dart -o build/duman-mesh-sim
    if [ "$package" = success ]; then
      run_step smoke "Compiled CLI help smoke" "dart-compiled-smoke.txt" "$DART_DIR" build/duman-mesh-sim --help
    else smoke=failure; fi
  fi

  # Diagnostics: the same parser the workflow calls, on the same captured files.
  if [ "$HAVE_PYTHON" = 1 ]; then
    echo
    log_dim "diagnostics"
    python3 "$HERE/diagnostics.py" \
      --analyze "$artifact_dir/dart-analyze.txt" \
      --test    "$artifact_dir/dart-test.txt" \
      --cli     "$artifact_dir/dart-cli.txt" \
      --format text --out "$artifact_dir/dart-diagnostics.json" \
      2>&1 | tee "$artifact_dir/dart-diagnostics.txt"
  else
    warn "python3 is not installed; skipping diagnostics (the raw captures are in the artifact dir)"
  fi

  # Gate — the workflow's own condition, on the same three outcomes.
  if [ "$analyze" != success ] || [ "$test" != success ] || [ "$cli" != success ] || [ "$package" != success ] || [ "$smoke" != success ]; then
    err "Dart engine failed (analyze: $analyze, test: $test, CLI: $cli). Captured output is in ${artifact_dir#$ROOT/}"
    record_job dart failure "analyze=$analyze test=$test cli=$cli compile=$package smoke=$smoke"
  else
    record_job dart success
  fi
}

# --- job: cli-matrix ----------------------------------------------------------

job_cli_matrix() {
  job_header "cli-matrix — CLI acceptance across scenarios"
  if [ "${JOB_RESULT[dart]:-}" != success ]; then
    local dep="${JOB_RESULT[dart]:-not run}"
    local why="needs: dart ($dep)"
    skip_step _o "cli-matrix (whole job)" "$why"
    # A dependency that is *missing* is a toolchain gap, so this job could not run either
    # and --allow-missing-dart may accept it as partial. A dependency that *failed* is a
    # red build, and nothing downstream of it can be trusted — that stays a hard failure.
    # Conflating the two made a Dart-less machine unpushable even with the flag set.
    if [ "$dep" = missing ]; then
      record_job cli-matrix missing "$why"
    else
      record_job cli-matrix blocked "$why"
    fi
    return
  fi
  if [ "$FAST" = 1 ]; then
    log_dim "  (fast: skipped)"
    record_job cli-matrix success "fast-skipped"
    return
  fi

  # The matrix, with the workflow's exclusion: only campus_quad is gated, so only it earns
  # a second power arm. The other three run --no-check because the DTN scenarios are
  # deliberately partitioned and would report the same numbers twice without asserting
  # anything new.
  local -a combos=(
    "campus_quad|always-on|"
    "campus_quad|duty-cycle|--duty-cycle"
    "sparse_village|always-on|--no-check"
    "festival_crowd|always-on|--no-check"
    "partitioned_pair|always-on|--no-check"
  )
  local failed="" combo scenario power extra out
  for combo in "${combos[@]}"; do
    IFS='|' read -r scenario power extra <<< "$combo"
    # shellcheck disable=SC2086
    run_step out "$scenario ($power)" "cli-$scenario-$power.txt" "$DART_DIR" \
             dart run bin/mesh_sim.dart --scenario "$scenario" --seed 42 $extra
    [ "$out" = success ] || failed="$failed $scenario/$power"
  done
  if [ -n "$failed" ]; then record_job cli-matrix failure "$failed"; else record_job cli-matrix success; fi
}

# --- job: probes --------------------------------------------------------------

job_probes() {
  job_header "probes — CLI probes (SOS, groups, media)"
  if [ "${JOB_RESULT[dart]:-}" != success ]; then
    local dep="${JOB_RESULT[dart]:-not run}"
    local why="needs: dart ($dep)"
    skip_step _o "probes (whole job)" "$why"
    # A dependency that is *missing* is a toolchain gap, so this job could not run either
    # and --allow-missing-dart may accept it as partial. A dependency that *failed* is a
    # red build, and nothing downstream of it can be trusted — that stays a hard failure.
    # Conflating the two made a Dart-less machine unpushable even with the flag set.
    if [ "$dep" = missing ]; then
      record_job probes missing "$why"
    else
      record_job probes blocked "$why"
    fi
    return
  fi
  if [ "$FAST" = 1 ]; then
    log_dim "  (fast: skipped)"
    record_job probes success "fast-skipped"
    return
  fi

  # Each probe runs in its own world, so what a mechanism costs is reported without
  # contaminating the acceptance run's overhead ratio. --no-check because a probe's numbers
  # are about the mechanism under test, not about the connected-world delivery gate.
  local failed="" out
  run_step out "SOS flood reach (roadmap Phase 3)" "probe-sos.txt" "$DART_DIR" \
           dart run bin/mesh_sim.dart --scenario campus_quad --seed 42 --sos --no-check
  [ "$out" = success ] || failed="$failed sos"
  run_step out "Group delivery modes (docs/06 §14)" "probe-group.txt" "$DART_DIR" \
           dart run bin/mesh_sim.dart --scenario campus_quad --seed 42 --group 5 --no-check
  [ "$out" = success ] || failed="$failed group"
  run_step out "Group history anti-entropy (docs/06 §17)" "probe-history.txt" "$DART_DIR" \
           dart run bin/mesh_sim.dart --scenario campus_quad --seed 42 --history --no-check
  [ "$out" = success ] || failed="$failed history"
  run_step out "Media transport and push-to-talk (docs/08)" "probe-media.txt" "$DART_DIR" \
           dart run bin/mesh_sim.dart --scenario campus_quad --seed 42 --media --no-check
  [ "$out" = success ] || failed="$failed media"

  if [ -n "$failed" ]; then record_job probes failure "$failed"; else record_job probes success; fi
}

# --- drive --------------------------------------------------------------------

START_ALL=$(date +%s)
for job in $SELECTED; do
  case "$job" in
    checks)     job_checks ;;
    web)        job_web ;;
    dart)       job_dart ;;
    cli-matrix) job_cli_matrix ;;
    probes)     job_probes ;;
  esac
  if [ "${JOB_RESULT[$job]}" = failure ] && [ "$KEEP_GOING" = 0 ]; then
    # `needs:` edges mean the downstream jobs cannot be trusted once dart fails; stopping is
    # the workflow's own behaviour, not a shortcut.
    log_dim "stopping after $job (use --keep-going to run the rest)"
    for rest in $SELECTED; do
      [ -n "${JOB_RESULT[$rest]:-}" ] || { JOB_RESULT["$rest"]="not-run"; JOB_DETAIL["$rest"]=""; RESULTS_ORDER+=("$rest"); }
    done
    break
  fi
done
END_ALL=$(date +%s)

# --- verdict ------------------------------------------------------------------

echo
log "result"
ANY_FAILURE=0; ANY_MISSING=0
for job in $JOBS_ALL; do
  [ -n "${JOB_RESULT[$job]:-}" ] || continue
  res="${JOB_RESULT[$job]}"
  case "$res" in
    success)  marker="${C_GREEN}PASS${C_RESET}" ;;
    failure)  marker="${C_RED}FAIL${C_RESET}"; ANY_FAILURE=1 ;;
    blocked)  marker="${C_YELLOW}BLOCKED${C_RESET}"; ANY_FAILURE=1 ;;
    missing)  marker="${C_YELLOW}MISSING${C_RESET}"; ANY_MISSING=1 ;;
    not-run)  marker="${C_DIM}—${C_RESET}" ;;
    *)        marker="$res" ;;
  esac
  printf '  %s %-12s %s\n' "$marker" "$job" "${C_DIM}${JOB_DETAIL[$job]:-}${C_RESET}"
done
printf '\n  total %ss · artifacts %s\n' "$((END_ALL - START_ALL))" "${artifact_dir#$ROOT/}"

# "full" has to mean every job in the workflow ran and passed. A scoped run can be entirely
# green *within its scope* and still say nothing about the jobs it left out, and labelling
# that "full" is exactly how an unverified engine ends up looking verified in a record
# someone reads months later.
SCOPED=0
for job in $JOBS_ALL; do selected "$job" || SCOPED=1; done
if [ "$SCOPED" = 1 ]; then
  VERIFIED="scoped:$(printf '%s' "$SELECTED" | tr ' ' ',')"
else
  VERIFIED="full"
fi
if [ "$ANY_MISSING" = 1 ]; then VERIFIED="partial"; fi
if [ "$FAST" = 1 ]; then VERIFIED="$VERIFIED(fast)"; fi

if [ -n "$JSON_OUT" ]; then
  {
    printf '{\n'
    printf '  "runId": "%s",\n' "$RUN_ID"
    printf '  "branch": "%s",\n' "$(git_branch)"
    printf '  "sha": "%s",\n' "$(git_sha)"
    printf '  "timestamp": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '  "fast": %s,\n' "$([ "$FAST" = 1 ] && echo true || echo false)"
    printf '  "verification": "%s",\n' "$VERIFIED"
    printf '  "toolchain": {"node": "%s", "npm": "%s", "dart": "%s", "python3": "%s"},\n' \
      "$(tool_version node | sed 's/^v//')" "$(tool_version npm)" \
      "$([ "$HAVE_DART" = 1 ] && dart_sdk_version || echo missing)" \
      "$(tool_version python3 | awk '{print $2}')"
    printf '  "jobs": {\n'
    first=1
    for job in $JOBS_ALL; do
      [ -n "${JOB_RESULT[$job]:-}" ] || continue
      [ "$first" = 1 ] || printf ',\n'
      first=0
      printf '    "%s": {"result": "%s", "detail": "%s"}' "$job" "${JOB_RESULT[$job]}" "${JOB_DETAIL[$job]:-}"
    done
    printf '\n  },\n'
    printf '  "seconds": %s,\n' "$((END_ALL - START_ALL))"
    printf '  "artifacts": "%s"\n' "${artifact_dir#$ROOT/}"
    printf '}\n'
  } > "$JSON_OUT"
  log_dim "result record: ${JSON_OUT}"
fi

if [ "$ANY_FAILURE" = 1 ]; then
  err "pipeline FAILED"
  exit 1
fi
if [ "$ANY_MISSING" = 1 ]; then
  if [ "$ALLOW_MISSING_DART" = 1 ]; then
    warn "pipeline PARTIAL — some jobs could not run. This is not a green build."
    exit 2
  fi
  err "pipeline INCOMPLETE — jobs could not run for want of a toolchain."
  err "Install it (docs/10-local-development-and-ci.md §2) or pass --allow-missing-dart"
  err "to accept exit code 2. Exit code 0 is reserved for a run that verified everything."
  exit 1
fi
log "pipeline PASSED — verified: ${VERIFIED}"
exit 0
