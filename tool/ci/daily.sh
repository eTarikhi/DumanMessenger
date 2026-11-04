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
# Before either half this runs tool/ci/blockers.sh, a pre-flight that measures what the
# machine cannot do — no Dart SDK and no pub.dev, CI refused for billing, no radio, no handset,
# no crowd — and prices each of those in roadmap items. It never affects the verdict, because
# it always exits 0: a missing toolchain is a fact about the machine, not a defect in the
# repository. It runs *first* for one reason — if HEAD has been rolled back to the branch
# point, which this sandbox does between turns, the twenty minutes that follow would measure a
# checkout that is not the pushed one, and the report should say so before spending them.
#
# This script runs both halves, keeps their artifacts side by side under one dated directory,
# writes DAILY.md across the top, and resolves the ambiguity the collector leaves: it reads the
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
  # The header is printed by walking it, not by a line range. It was `sed -n '2,40p'` until
  # the header grew by eight lines and the option list silently lost its last paragraph —
  # a stale range in a --help is invisible until somebody reads the tail, and nobody does.
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
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

# --- 0. what this machine cannot do ---------------------------------------------
#
# Written to the artifact directory in full rather than summarised, because the value of the
# probe is its evidence column: "curl exit 35, HTTP 000, 0 bytes" is what makes "the Dart SDK
# is not installable here" a measurement instead of an excuse.
echo
[ "$QUIET" = 1 ] || log "0/2 · what this machine cannot do (tool/ci/blockers.sh)"
"$HERE/blockers.sh" --json "$DIR/blockers.json" >"$DIR/blockers.txt" 2>&1
BLOCKERS=$?
if [ "$QUIET" != 1 ]; then
  grep -E '^(summary|roadmap:)' "$DIR/blockers.txt" | head -2
  [ "$BLOCKERS" = 0 ] || warn "blockers.sh exited $BLOCKERS — read ${DIR#$ROOT/}/blockers.txt"
fi

B_BLOCKED=0; B_DRIFT=0; B_OPEN=0; B_REACH=0; B_DRIFT_ROWS=""; B_CHECKOUT=0
if [ -f "$DIR/blockers.json" ] && have python3; then
  read -r B_BLOCKED B_DRIFT B_OPEN B_REACH B_CHECKOUT B_DRIFT_ROWS <<EOF
$(python3 - "$DIR/blockers.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
    r = d.get("roadmap", {})
    rows = d.get("driftRows", [])
    # Only these two mean the run is measuring something other than the pushed checkout;
    # a missing node_modules is repairable but does not invalidate what follows.
    checkout = 1 if any(n in ("git-head", "git-worktree") for n in rows) else 0
    print(d.get("blocked", 0), d.get("drift", 0), r.get("open", 0),
          r.get("reachableFromHere", 0), checkout, ",".join(rows) or "-")
except Exception:
    print(0, 0, 0, 0, 0, "-")
PY
)
EOF
fi
# Drift is the one finding here that changes what the rest of the run means, so it is the one
# that gets a warning on stderr rather than a line in a file nobody opens until something fails.
if [ "$B_DRIFT" -gt 0 ]; then
  warn "$B_DRIFT blocker row(s) repairable from this machine: ${B_DRIFT_ROWS//,/ } (see ${DIR#$ROOT/}/blockers.txt)."
  if [ "$B_CHECKOUT" = 1 ]; then
    warn "One of them is the checkout itself, so this run may be measuring something other than"
    warn "the pushed work. Repair it (git fetch origin && git reset --mixed origin/$BRANCH) and re-run."
  fi
fi

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
      printf 'check in this repository can compile it. Three static checkers stand in for part of\n'
      printf 'that — delimiter balance, cross-language constant and config/stats parity, and\n'
      printf 'declaration-site consistency — and none of them is a compiler. The other two scripts in\n'
      printf 'the docs group check documentation drift and PowerShell syntax, which a Dart compiler\n'
      printf 'would not have caught either. Install the SDK per\n'
      printf '`docs/11` §2 and re-run; until then treat every Dart result here as unknown rather\n'
      printf 'than green.\n\n' ;;
  esac

  printf '## What this machine cannot do\n\n'
  printf '%s blocker(s) probed before the run, %s of them repairable from here.\n\n' "$B_BLOCKED" "$B_DRIFT"
  if [ "$B_OPEN" -gt 0 ]; then
    printf 'Of the %s open roadmap items, %s can be closed on this machine. The other %s need\n' \
      "$B_OPEN" "$B_REACH" "$((B_OPEN - B_REACH))"
    printf 'a handset, a store account and signing key, a Dart/Flutter toolchain that is not\n'
    printf 'installable from here, or a crowd of people carrying phones — `blockers.txt` lists\n'
    printf 'every item with the rule that classified it and the probe behind each row.\n\n'
  else
    printf 'The roadmap could not be read, so no item was classified; `blockers.txt` says why.\n\n'
  fi
  if [ "$B_CHECKOUT" = 1 ]; then
    printf '> **The checkout itself is one of the %s repairable rows** (`%s`), so everything below\n' \
      "$B_DRIFT" "${B_DRIFT_ROWS//,/ }"
    printf '> was measured against something other than the pushed work — most likely a local\n'
    printf '> .git rolled back to the branch point, which this sandbox does between turns. Repair it\n'
    printf '> (`git fetch origin && git reset --mixed origin/%s`) and re-run before believing a number\n' "$BRANCH"
    printf '> in this file.\n\n'
  elif [ "$B_DRIFT" -gt 0 ]; then
    printf '> %s row(s) are repairable here (`%s`); none of them is the checkout, so the results\n' \
      "$B_DRIFT" "${B_DRIFT_ROWS//,/ }"
    printf '> below describe the pushed work.\n\n'
  fi

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
  printf '* `blockers.txt`, `blockers.json` — what this machine cannot do, probed before the run\n'
  if [ -d "$DIR/evidence" ] || [ "$EVIDENCE" = 1 ]; then
    printf '* `evidence-*.txt` — the probes that reproduce the numbers published in docs/06-docs/09\n'
  fi
} > "$DIR/DAILY.md"

# --- 5b. one committed line, because artifacts/ is not -------------------------
#
# Everything above lands under artifacts/, which .gitignore excludes: the record of what a given
# sha actually verified is destroyed by exactly the event it exists to explain. Fourteen rollbacks
# in one week made that concrete — each one erased every earlier run's captures, and "which
# commits were verified, and how" survived only in a conversation nobody can grep. So each run
# appends one line to a *tracked* file, reports/verification-log.jsonl.
#
# It is a digest and not a log: verdict, exit codes, counts, tool versions, the artifact directory
# name. No captured output, ~300 bytes a run, append-only. The line describing this run is
# uncommitted when it is written, because the sha it describes is already committed — the script
# says so and names the file, rather than committing on your behalf.
DIGEST="$ROOT/reports/verification-log.jsonl"
if have python3; then
  if python3 - "$DIGEST" "$SHA" "$BRANCH" "$STAMP" "$ELAPSED" "$VERDICT" "$EXIT" \
               "$CHECK_PASSED" "$CHECK_FAILED" "$CHECK_NOTRUN" "$PIPE" "$EVIDENCE" "$FAST" \
               "$DART_LINE" "$(tool_version node 2>/dev/null || echo MISSING)" \
               "${DIR#$ROOT/}" <<'PY'
import json, sys
from datetime import datetime, timezone

(out, sha, branch, stamp, elapsed, verdict, exit_code, passed, failed, notrun,
 pipe, evidence, fast, dart, node, artifacts) = sys.argv[1:17]


def num(text):
    return int(text) if text.lstrip("-").isdigit() else None


line = {
    "sha": sha,
    "branch": branch,
    "runStamp": stamp,
    "generatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "mode": "fast" if fast == "1" else ("full+evidence" if evidence == "1" else "full"),
    "verdict": verdict,
    "exit": num(exit_code),
    "elapsedSec": num(elapsed),
    "checks": {"passed": num(passed), "failed": num(failed), "notRun": num(notrun)},
    "pipeline": {"exit": num(pipe),
                 "meaning": {0: "green", 1: "failed", 2: "partial"}.get(num(pipe), "unknown")},
    "tools": {"node": node, "dart": dart},
    "artifacts": artifacts,
    "note": "counts only; the captured output behind this line is in artifacts/, which is git-ignored",
}
with open(out, "a", encoding="utf-8") as fh:
    fh.write(json.dumps(line, ensure_ascii=False) + "\n")
PY
  then
    [ "$QUIET" = 1 ] || log_dim "digest: ${DIGEST#$ROOT/} — tracked, and uncommitted: git add ${DIGEST#$ROOT/}"
  else
    err "could not append the digest line to ${DIGEST#$ROOT/}"
  fi
fi

if [ -n "$JSON_OUT" ] && have python3; then
  if python3 - "$JSON_OUT" "$SHA" "$BRANCH" "$STAMP" "$ELAPSED" "$VERDICT" \
              "$PIPE" "$CHECKS" "$CHECK_PASSED" "$CHECK_FAILED" "$CHECK_NOTRUN" \
              "$HAVE_DART" "$DIR" "$B_BLOCKED" "$B_DRIFT" "$B_OPEN" "$B_REACH" \
              "$B_CHECKOUT" "$B_DRIFT_ROWS" <<'PY'
import json, sys
from datetime import datetime, timezone
(out, sha, branch, stamp, secs, verdict, pipe, checks,
 npass, nfail, nnotrun, have_dart, directory,
 nblocked, ndrift, nopen, nreach, ncheckout, ndriftrows) = sys.argv[1:]
ndriftrows = [r for r in ndriftrows.split(",") if r and r != "-"]
json.dump({
    "runId": f"daily-{stamp}", "sha": sha, "branch": branch, "stamp": stamp,
    "seconds": int(secs), "verdict": verdict,
    "pipelineExit": int(pipe), "checksExit": int(checks),
    "passed": int(npass), "failed": int(nfail), "notRun": int(nnotrun),
    "dartSdk": have_dart == "1", "directory": directory,
    "blockers": {"blocked": int(nblocked), "drift": int(ndrift), "driftRows": ndriftrows,
                 "checkoutSuspect": ncheckout == "1",
                 "roadmapOpen": int(nopen), "reachableFromHere": int(nreach)},
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
