#!/usr/bin/env bash
# One command for the daily run: the CI mirror and the full check collection, in one dated
# artifact directory, with one summary and one exit code.
#
# This exists because the two halves were separately runnable and separately interpretable,
# and "run everything I would have CI run" should not mean remembering which script covers
# which half or what each exit code meant:
#
#   tool/ci/run-pipeline.sh   mirrors .github/workflows/ci.yml step for step, so a green run
#                             here is evidence about the remote one. Exit 0 green, 1 failed,
#                             2 partial — it never reports 0 for a run that could not execute
#                             everything.
#   tool/ci/collect-checks.sh collects every check in the repository, including the toolchain-
#                             free ones and the evidence probes that reproduce published
#                             numbers. Exit 0 all passed, 1 failed *or* could not run — the two
#                             are deliberately not distinguished, because neither is a pass.
#
# This script runs both, keeps their artifacts side by side under one dated directory, writes
# DAILY.md across the top, and resolves the ambiguity the collector leaves: it reads the
# collector's JSON to tell "something failed" from "nothing failed but the Dart SDK is
# missing", which are opposite situations needing opposite responses.
#
# Exit codes — the same discipline as run-pipeline.sh, and the reason this is worth having:
#   0   everything that could run, ran and passed, and nothing was skipped
#   1   something failed. Fix it before pushing.
#   2   nothing failed, but part of the run could not execute. On a machine without the Dart
#       SDK this is the expected result and it is *not* a pass: sim/mesh_sim is the
#       authoritative engine and no check here can compile it. Install the SDK per
#       docs/11 §2 and re-run; the report says which checks were skipped and why.
#  64   usage error
#
# Duration, measured on a machine without the Dart SDK: `--fast` is **11.5 min** (687 s), which
# is longer than it looks because the two halves each do their own typecheck and test run — this
# script composes two complete tools rather than merging their work, and the duplication is the
# price of not having to know which script covers what. Adding the evidence probes adds about
# **15 min**, measured separately as the difference between `collect-checks.sh` with and without
# `--with-evidence` (1192 s against 304 s), of which `npm run media` alone is ~14 min across its
# 18 sections. The full CI mirror additionally runs the production build, the CLI acceptance
# matrix and the Dart probes, which is the largest part on a machine that *has* the SDK and is
# therefore not measured here. `--no-evidence` is the useful middle: every check, none of the
# re-measuring.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

ROOT="$(repo_root)"

usage() {
  sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  cat <<USAGE

Options:
  --fast          the quick subset of the CI mirror (typecheck, unit tests, analyze, dart
                  test) and no evidence probes. Measured at 11.5 min without the Dart SDK.
                  Good daily; not good before a push.
  --no-evidence   the full CI mirror and every check, but skip the evidence probes that
                  re-measure the numbers published in docs/06-docs/09. Roughly --fast plus
                  the production build and the CLI matrix.
  --dir DIR       artifact directory (default artifacts/ci/daily/<UTC stamp>-<sha>)
  --json PATH     also write the combined summary as JSON
  --prune N       after a successful write, delete all but the N most recent daily
                  directories. Nothing is ever deleted without this flag: a daily run
                  accumulates artifacts and silently reclaiming them is how somebody loses
                  the run they wanted to compare against
  --quiet         only the final summary and the exit code
  --help          this text

Runs:
  ./tool/ci/daily.sh                  everything — the CI mirror and every published number
  ./tool/ci/daily.sh --no-evidence    every check, no re-measuring
  ./tool/ci/daily.sh --fast           the daily quick run, measured at 11.5 min

Windows:  .\\make.ps1 daily [--no-evidence]     (same three modes)
USAGE
}

FAST=0
EVIDENCE=1
QUIET=0
DIR=""
JSON_OUT=""
PRUNE=0

require_value() { [ -n "${2-}" ] || { err "option $1 needs a value"; exit 64; }; }

while [ $# -gt 0 ]; do
  case "$1" in
    --fast)         FAST=1; EVIDENCE=0; shift ;;
    --no-evidence)  EVIDENCE=0; shift ;;
    --dir)          require_value "$1" "${2-}"; DIR="$2"; shift 2 ;;
    --dir=*)        DIR="${1#*=}"; shift ;;
    --json)         require_value "$1" "${2-}"; JSON_OUT="$2"; shift 2 ;;
    --json=*)       JSON_OUT="${1#*=}"; shift ;;
    --prune)        require_value "$1" "${2-}"; PRUNE="$2"; shift 2 ;;
    --prune=*)      PRUNE="${1#*=}"; shift ;;
    --quiet)        QUIET=1; shift ;;
    --help|-h)      usage; exit 0 ;;
    *)              err "unknown option: $1"; usage; exit 64 ;;
  esac
done

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
SHA="$(git_sha)"
BRANCH="$(git_branch)"
[ -n "$DIR" ] || DIR="$ROOT/artifacts/ci/daily/${STAMP}-${SHA}"
mkdir -p "$DIR" || { err "cannot create $DIR"; exit 64; }
ensure_parent() {
  local target="$1" d
  [ -n "$target" ] || return 0
  d="$(dirname "$target")"
  [ -d "$d" ] || mkdir -p "$d" || { err "cannot create $d for $target"; exit 64; }
}
ensure_parent "$JSON_OUT"

HAVE_DART=1; have dart || HAVE_DART=0
HAVE_NODE=1; have node || HAVE_NODE=0

[ "$QUIET" = 1 ] || log "daily run · $BRANCH @ $SHA · $STAMP"
[ "$QUIET" = 1 ] || log_dim "artifacts: ${DIR#$ROOT/}"
if [ "$HAVE_DART" = 0 ]; then
  warn "the Dart SDK is not installed, so sim/mesh_sim cannot be compiled or tested."
  log_dim "This run will exit 2, not 0: nothing failing is not the same as everything passing."
  log_dim "Install it per docs/11 §2 and re-run; the report lists what was skipped."
fi

START_ALL=$SECONDS

# --- 1. the CI mirror -----------------------------------------------------------

PIPE_ARGS=(--keep-going --allow-missing-dart
           --artifacts "$DIR/pipeline" --json "$DIR/pipeline.json" --label daily)
[ "$FAST" = 1 ] && PIPE_ARGS+=(--fast)

echo
[ "$QUIET" = 1 ] || log "1/2 · the CI mirror (.github/workflows/ci.yml, step for step)"
"$HERE/run-pipeline.sh" "${PIPE_ARGS[@]}" >"$DIR/pipeline.txt" 2>&1
PIPE=$?
[ "$QUIET" = 1 ] || tail -25 "$DIR/pipeline.txt"

# --- 2. every check in the repository -------------------------------------------

CHECK_ARGS=(--report "$DIR/REPORT.md" --json "$DIR/checks.json")
[ "$EVIDENCE" = 1 ] && CHECK_ARGS+=(--with-evidence)

echo
[ "$QUIET" = 1 ] || log "2/2 · every check$([ "$EVIDENCE" = 1 ] && echo ", including the evidence probes")"
"$HERE/collect-checks.sh" "${CHECK_ARGS[@]}" >"$DIR/checks.txt" 2>&1
CHECKS=$?
[ "$QUIET" = 1 ] || tail -20 "$DIR/checks.txt"

# --- 3. resolve what the collector's exit code cannot ----------------------------
#
# The collector exits 1 for "a check failed" and for "nothing failed but 13 could not run",
# and those need opposite responses: one is a defect, the other is a missing toolchain. Its
# JSON separates them, so read that rather than guessing from the code.
CHECK_FAILED=0
CHECK_NOTRUN=0
CHECK_PASSED=0
if [ -f "$DIR/checks.json" ] && have python3; then
  read -r CHECK_FAILED CHECK_NOTRUN CHECK_PASSED <<EOF
$(python3 - "$DIR/checks.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
    print(d.get("failed", 0), d.get("notRun", 0), d.get("passed", 0))
except Exception:
    print(-1, -1, -1)
PY
)
EOF
fi
if [ "$CHECK_FAILED" = -1 ]; then
  # No usable JSON: fall back to the exit code and say that the split is unknown, rather than
  # reporting a number this script did not actually read.
  CHECK_FAILED=$CHECKS
  CHECK_NOTRUN=0
fi

# run-pipeline: 0 green, 1 failed, 2 partial.
PIPE_FAILED=0; PIPE_PARTIAL=0
case "$PIPE" in
  0) ;;
  2) PIPE_PARTIAL=1 ;;
  *) PIPE_FAILED=1 ;;
esac

ELAPSED=$((SECONDS - START_ALL))
if [ "$PIPE_FAILED" = 1 ] || [ "$CHECK_FAILED" -gt 0 ]; then
  VERDICT="FAILED"
  EXIT=1
elif [ "$PIPE_PARTIAL" = 1 ] || [ "$CHECK_NOTRUN" -gt 0 ]; then
  VERDICT="INCOMPLETE"
  EXIT=2
else
  VERDICT="GREEN"
  EXIT=0
fi

# --- 4. how this run differs from the previous one -------------------------------
#
# A daily run that cannot be compared with yesterday's is a daily run whose output has to be
# read from scratch every morning. The comparison is deliberately narrow — counts, verdict and
# elapsed time, not per-check diffs — because the useful signal at this cadence is "something
# appeared or disappeared", not "this number moved by 0.4".
PREV_DIR=""
PREV_LINE="(no previous daily run to compare against)"
if have python3; then
  PREV_DIR="$(find "$ROOT/artifacts/ci/daily" -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
    | grep -v -F "$DIR" | sort | tail -1)"
  if [ -n "$PREV_DIR" ] && [ -f "$PREV_DIR/daily.json" ] && [ -f "$DIR/checks.json" ]; then
    PREV_LINE="$(python3 - "$PREV_DIR/daily.json" "$DIR/checks.json" "$VERDICT" "$ELAPSED" <<'PY'
import json, sys
try:
    prev = json.load(open(sys.argv[1], encoding="utf-8"))
    cur = json.load(open(sys.argv[2], encoding="utf-8"))
except Exception as exc:
    print(f"(the previous run's record could not be read: {exc})")
    sys.exit(0)
verdict, elapsed = sys.argv[3], int(sys.argv[4])
def delta(a, b):
    d = b - a
    return f"{b} ({'+' if d > 0 else ''}{d})" if d else f"{b} (unchanged)"
parts = [
    f"verdict {prev.get('verdict', '?')} → {verdict}",
    f"passed {delta(prev.get('passed', 0), cur.get('passed', 0))}",
    f"failed {delta(prev.get('failed', 0), cur.get('failed', 0))}",
    f"could-not-run {delta(prev.get('notRun', 0), cur.get('notRun', 0))}",
    f"elapsed {prev.get('seconds', '?')}s → {elapsed}s",
    f"sha {prev.get('sha', '?')} → {cur.get('sha', '?')}",
]
print("; ".join(parts))
PY
)"
  elif [ -n "$PREV_DIR" ]; then
    PREV_LINE="(the previous run at ${PREV_DIR##*/} has no daily.json — it predates this comparison)"
  fi
fi

# --- 5. the one-page summary -----------------------------------------------------

DART_LINE="MISSING — install per docs/11 §2"
if [ "$HAVE_DART" = 1 ]; then DART_LINE="$(dart_sdk_version 2>/dev/null || echo present)"; fi

{
  printf '# Daily run — %s\n\n' "$STAMP"
  printf '| | |\n| --- | --- |\n'
  printf '| Commit | `%s` |\n' "$SHA"
  printf '| Branch | `%s` |\n' "$BRANCH"
  printf '| Mode | %s |\n' "$([ "$FAST" = 1 ] && echo "fast" || { [ "$EVIDENCE" = 1 ] && echo "full, with evidence probes" || echo "full, without evidence probes"; })"
  printf '| Elapsed | %ss |\n' "$ELAPSED"
  printf '| dart | %s |\n' "$DART_LINE"
  printf '| node | %s |\n' "$(tool_version node 2>/dev/null || echo MISSING)"
  printf '| Verdict | **%s** (exit %s) |\n\n' "$VERDICT" "$EXIT"

  printf '## Compared with the previous run\n\n%s\n\n' "$PREV_LINE"

  printf '## What that verdict means\n\n'
  case "$VERDICT" in
    GREEN)
      printf 'Everything that could run, ran and passed, and nothing was skipped.\n\n' ;;
    FAILED)
      printf 'Something failed. Read the two logs below before pushing anything:\n\n'
      printf '* `pipeline.txt` — the CI mirror, step for step against `.github/workflows/ci.yml`\n'
      printf '* `checks.txt` — every check, with `REPORT.md` as the table\n\n' ;;
    INCOMPLETE)
      printf 'Nothing failed, but part of the run could not execute — which is **not a pass**.\n\n'
      printf 'Almost certainly the Dart SDK: `sim/mesh_sim` is the authoritative engine and no\n'
      printf 'check in this repository can compile it. The four static checkers stand in for part\n'
      printf 'of that (delimiter balance, cross-language constant and config/stats parity,\n'
      printf 'declaration-site consistency) and they are not a compiler. Install the SDK per\n'
      printf '`docs/11` §2 and re-run; until then treat every Dart result here as unknown rather\n'
      printf 'than green.\n\n' ;;
  esac

  printf '## The two halves\n\n'
  printf '| half | exit | reading |\n| --- | ---: | --- |\n'
  printf '| CI mirror (`run-pipeline.sh`) | %s | %s |\n' "$PIPE" \
    "$(case "$PIPE" in 0) echo "green";; 2) echo "partial — a job could not run";; *) echo "FAILED";; esac)"
  printf '| checks (`collect-checks.sh`) | %s | %s passed, %s failed, %s could not run |\n\n' \
    "$CHECKS" "$CHECK_PASSED" "$CHECK_FAILED" "$CHECK_NOTRUN"

  printf '## Files in this directory\n\n'
  printf '* `DAILY.md` — this page\n'
  printf '* `REPORT.md` — the check table, one row per check, with what each was verified against\n'
  printf '* `pipeline.txt`, `checks.txt` — full output of each half\n'
  printf '* `pipeline/`, `checks.json`, `pipeline.json` — per-step artifacts and machine-readable results\n'
  if [ -d "$DIR/evidence" ] || [ "$EVIDENCE" = 1 ]; then
    printf '* `evidence-*.txt` — the probes that reproduce the numbers published in docs/06-docs/09\n'
  fi
} > "$DIR/DAILY.md"

if [ -n "$JSON_OUT" ] && have python3; then
  if python3 - "$JSON_OUT" "$SHA" "$BRANCH" "$STAMP" "$ELAPSED" "$VERDICT" \
              "$PIPE" "$CHECKS" "$CHECK_PASSED" "$CHECK_FAILED" "$CHECK_NOTRUN" \
              "$HAVE_DART" "$DIR" <<'PY'
import json, sys
from datetime import datetime, timezone
(out, sha, branch, stamp, secs, verdict, pipe, checks,
 npass, nfail, nnotrun, have_dart, directory) = sys.argv[1:]
json.dump({
    "runId": f"daily-{stamp}", "sha": sha, "branch": branch, "stamp": stamp,
    "seconds": int(secs), "verdict": verdict,
    "pipelineExit": int(pipe), "checksExit": int(checks),
    "passed": int(npass), "failed": int(nfail), "notRun": int(nnotrun),
    "dartSdk": have_dart == "1", "directory": directory,
    "generatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}, open(out, "w", encoding="utf-8"), indent=2)
PY
  then
    [ "$QUIET" = 1 ] || log_dim "json: ${JSON_OUT#$ROOT/}"
  else
    err "could not write the json summary to ${JSON_OUT#$ROOT/}"
  fi
fi

# --- 6. optional reclamation ----------------------------------------------------
#
# Opt-in and counted from the newest, so a failed run is never the one deleted first and the
# run being compared against survives until it is the Nth oldest rather than the second.
if [ "$PRUNE" -gt 0 ] 2>/dev/null; then
  mapfile -t ALL_RUNS < <(find "$ROOT/artifacts/ci/daily" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r)
  if [ "${#ALL_RUNS[@]}" -gt "$PRUNE" ]; then
    REMOVED=0
    for old_dir in "${ALL_RUNS[@]:$PRUNE}"; do
      [ "$old_dir" = "$DIR" ] && continue
      rm -rf "$old_dir" && REMOVED=$((REMOVED + 1))
    done
    [ "$QUIET" = 1 ] || log_dim "pruned $REMOVED older daily run(s), keeping the $PRUNE most recent"
  fi
fi

echo
case "$VERDICT" in
  GREEN)     log "GREEN — everything ran and passed, nothing skipped (${ELAPSED}s)" ;;
  FAILED)    err "FAILED — see ${DIR#$ROOT/}/DAILY.md (${ELAPSED}s)" ;;
  INCOMPLETE)
    err "INCOMPLETE — nothing failed, but $CHECK_NOTRUN check(s) could not run (${ELAPSED}s)."
    err "That is not a pass. If the Dart SDK is the reason, install it per docs/11 §2 and re-run."
    ;;
esac
[ "$QUIET" = 1 ] || log_dim "summary: ${DIR#$ROOT/}/DAILY.md"
exit "$EXIT"
