#!/usr/bin/env bash
# Monitor this repository's CI on GitHub, and say why a run failed.
#
# Watching CI here is not just `gh run list`. Two things make it worth a script:
#
#   * A red Dart build publishes its diagnostics as *annotations* on the check run, because
#     the runner's generic problem matcher loses file paths and `$GITHUB_STEP_SUMMARY` is not
#     readable through the API at all. Fetching those takes three API calls with a job id
#     found by name, which is fiddly enough that it does not get done.
#   * A job can fail without ever running. This repository has had exactly that: every job
#     reporting "The job was not started because recent account payments have failed". That
#     is not a build failure and no amount of code change will fix it, so the script names it
#     separately instead of letting it look like a red test.
#
# Usage:
#   tool/ci/watch.sh                     # recent runs on this branch
#   tool/ci/watch.sh --follow            # poll until the newest run finishes
#   tool/ci/watch.sh --all               # recent runs on every branch
#   tool/ci/watch.sh --diagnose [RUN]    # jobs + annotations for a run (default: newest)
#   tool/ci/watch.sh --run RUN --follow
#   tool/ci/watch.sh --classify-run [RUN]  # print billing|runner|none and exit (for scripts)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

ROOT="$(repo_root)"
BRANCH="$(git_branch)"
LIMIT=8
FOLLOW=0
SCOPE_BRANCH=1
DIAGNOSE=0
CLASSIFY_RUN=""
RUN_ID=""
INTERVAL=30

usage() { sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --follow|-f)   FOLLOW=1; shift ;;
    --all|-a)      SCOPE_BRANCH=0; shift ;;
    --branch|-b)   BRANCH="$2"; shift 2 ;;
    --diagnose|-d) DIAGNOSE=1; [ "${2:-}" != "" ] && case "$2" in -*) ;; *) RUN_ID="$2"; shift ;; esac; shift ;;
    --run|-r)      RUN_ID="$2"; shift 2 ;;
    --classify-run) CLASSIFY_RUN=1
                    [ "${2:-}" != "" ] && case "$2" in -*) ;; *) CLASSIFY_RUN="$2"; shift ;; esac
                    shift ;;
    --limit|-n)    LIMIT="$2"; shift 2 ;;
    --interval)    INTERVAL="$2"; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *)             err "unknown option: $1"; usage >&2; exit 64 ;;
  esac
done

if ! have gh; then
  err "the GitHub CLI (gh) is not installed. See docs/10-local-development-and-ci.md §4."
  exit 64
fi
if ! gh auth status >/dev/null 2>&1; then
  err "gh is not authenticated. Run 'gh auth login'."
  err "Do not paste a token into this repository or into chat; authenticate the CLI directly."
  exit 64
fi

REPO="$(git -C "$ROOT" remote get-url origin 2>/dev/null | sed -E 's#.*github.com[:/]##; s#\.git$##')"

# `gh run list --branch` only when scoped to one; an empty expansion would pass an empty
# argument, which gh rejects rather than ignores.
GH_SCOPE=()
[ "$SCOPE_BRANCH" = 1 ] && GH_SCOPE=(--branch "$BRANCH")
[ -n "$REPO" ] || { err "cannot determine the repository from the origin remote"; exit 64; }

# --- helpers ------------------------------------------------------------------

# billing_block <runId> — does this run's failure look like an infrastructure refusal
# rather than a build failure? Printed as the reason if so.
billing_block() {
  local run="$1" text
  text="$(gh api "repos/$REPO/actions/runs/$run/jobs" --paginate \
            -q '.jobs[].steps[]?.name' 2>/dev/null || true)"
  # The message lands in the job's annotation stream, not in its steps.
  local ann
  for jobid in $(gh run view "$run" --json jobs -q '.jobs[].databaseId' 2>/dev/null); do
    ann="$(gh api "repos/$REPO/check-runs/$jobid/annotations" --paginate -q '.[].message' 2>/dev/null || true)"
    case "$ann" in
      *"payments have failed"*|*"spending limit"*) printf 'billing'; return 0 ;;
      *"runner image"*|*"no hosted runners"*|*"queued"*) printf 'runner'; return 0 ;;
    esac
  done
  return 1
}

list_runs() {
  local filter=()
  [ "$SCOPE_BRANCH" = 1 ] && filter=(--branch "$BRANCH")
  gh run list "${filter[@]}" --limit "$LIMIT" \
    --json databaseId,headSha,status,conclusion,createdAt,displayTitle \
    -q '.[] | [.databaseId, .headSha[0:7], .status, (.conclusion // "-"), .createdAt, .displayTitle] | @tsv' \
    | while IFS=$'\t' read -r id sha status concl created title; do
        local marker
        case "$concl" in
          success)          marker="${C_GREEN}✔ pass${C_RESET}" ;;
          failure)          marker="${C_RED}✘ fail${C_RESET}" ;;
          cancelled)        marker="${C_YELLOW}⊘ cancelled${C_RESET}" ;;
          skipped)          marker="${C_DIM}○ skipped${C_RESET}" ;;
          "")               case "$status" in
                              in_progress) marker="${C_BLUE}● running${C_RESET}" ;;
                              queued)      marker="${C_DIM}◌ queued${C_RESET}" ;;
                              *)           marker="$status" ;;
                            esac ;;
          *)                marker="$concl" ;;
        esac
        printf '  %b  %s  %s  %s%s\n' "$marker" "$sha" "$id" "${created/T/ }" "  ${title:0:52}"
      done
}

diagnose_run() {
  local run="$1"
  echo
  log "run $run"
  gh run view "$run" --json status,conclusion,headSha,headBranch,url,event \
     -q '"  \(.headBranch) @ \(.headSha[0:7])  \(.status)/\(.conclusion // "-")  \(.event)\n  \(.url)"' 2>/dev/null

  echo
  log_dim "jobs"
  gh run view "$run" --json jobs -q '.jobs[] | "  \(.conclusion // .status) \(.name)"' 2>/dev/null |
    while read -r concl name; do
      case "$concl" in
        success) printf '  %s %s\n' "${C_GREEN}✔${C_RESET}" "$name" ;;
        failure) printf '  %s %s\n' "${C_RED}✘${C_RESET}" "$name" ;;
        skipped) printf '  %s %s\n' "${C_DIM}○${C_RESET}" "$name" ;;
        *)       printf '  %s %s\n' "${C_BLUE}●${C_RESET}" "$name ($concl)" ;;
      esac
    done

  # An infrastructure refusal explains everything below it, so check for it first and stop
  # rather than reporting four jobs that never started as four failures.
  local kind
  if kind="$(billing_block "$run")"; then
    echo
    case "$kind" in
      billing)
        err "these jobs never started: GitHub Actions is refused for billing reasons."
        echo "      The annotation reads: \"The job was not started because recent account"
        echo "      payments have failed or your spending limit needs to be increased.\""
        echo
        echo "      This is not a build failure and no code change will fix it. Someone with"
        echo "      access to the account has to resolve it under Settings → Billing & plans,"
        echo "      or raise the Actions spending limit. Until then:"
        echo
        echo "        make ci          # run the same pipeline locally"
        echo "        make push        # validate locally, then push"
        echo
        echo "      The Dart engine cannot be verified locally without a Dart SDK, so while"
        echo "      Actions is down, Dart changes are unverified. Say so where it matters."
        ;;
      runner)
        err "these jobs could not get a runner. Retry later, or check the runner configuration."
        ;;
    esac
    return 0
  fi

  echo
  log_dim "annotations (the diagnostics the Dart job publishes)"
  local found=0 jobid
  for jobid in $(gh run view "$run" --json jobs -q '.jobs[].databaseId' 2>/dev/null); do
    local name
    name="$(gh run view "$run" --json jobs -q ".jobs[] | select(.databaseId == $jobid) | .name" 2>/dev/null)"
    local out
    out="$(gh api "repos/$REPO/check-runs/$jobid/annotations" --paginate \
            -q '.[] | "  [\(.annotation_level)] \(.title)\n      \(.message | gsub("\n"; "\n      "))"' 2>/dev/null)"
    # A generic "Process completed with exit code N" says nothing; the annotations that carry
    # a title are the ones the Dart diagnostics step published.
    if [ -n "$out" ]; then
      printf '%s\n' "$out" | grep -q '\] .*.' && {
        found=1
        printf '  %s\n' "${C_DIM}— ${name}${C_RESET}"
        printf '%s\n' "$out" | grep -v 'Process completed with exit code' | grep -v '^  \[notice\]'
      }
    fi
  done
  [ "$found" = 0 ] && log_dim "  (none — the failure is in the job log; try: gh run view $run --log-failed)"

  echo
  log_dim "reproduce locally"
  echo "      make ci                    # every job the workflow runs"
  echo "      ./tool/ci/run-pipeline.sh --job dart --keep-going"
  echo
  log_dim "job logs cannot be downloaded from every network; if --log-failed is empty, the"
  log_dim "annotations above are the only machine-readable channel, which is why the Dart job"
  log_dim "publishes them."
}

# --- machine-readable classification ------------------------------------------
#
# For scripts that need the verdict without parsing prose. tool/ci/pr-flow.sh uses this to
# tell "CI is unavailable" from "the build is red", because the correct responses are
# opposites: one means do not merge and say why, the other means go and fix something.
# Printing a single word keeps that contract from drifting with the human-facing text.
if [ -n "$CLASSIFY_RUN" ]; then
  if [ "$CLASSIFY_RUN" = 1 ]; then
    CLASSIFY_RUN="$(gh run list "${GH_SCOPE[@]}" --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null)"
  fi
  if [ -z "$CLASSIFY_RUN" ]; then
    printf 'no-run\n'
    exit 0
  fi
  reason="$(billing_block "$CLASSIFY_RUN" 2>/dev/null || true)"
  case "$reason" in
    billing) printf 'billing\n' ;;
    runner)  printf 'runner\n' ;;
    *)       printf 'none\n' ;;
  esac
  exit 0
fi

# --- drive --------------------------------------------------------------------

if [ "$DIAGNOSE" = 1 ] || [ -n "$RUN_ID" ]; then
  if [ -z "$RUN_ID" ]; then
    RUN_ID="$(gh run list "${GH_SCOPE[@]}" --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null)"
  fi
  [ -n "$RUN_ID" ] || { err "no run to diagnose"; exit 1; }
  diagnose_run "$RUN_ID"
  exit 0
fi

echo
if [ "$SCOPE_BRANCH" = 1 ]; then
  log "CI · $REPO · branch $BRANCH"
else
  log "CI · $REPO · all branches"
fi
list_runs

NEWEST="$(gh run list "${GH_SCOPE[@]}" --limit 1 \
  --json databaseId,status,conclusion -q '.[0] | "\(.databaseId) \(.status) \(.conclusion // "")"' 2>/dev/null)"
NEWEST_ID="${NEWEST%% *}"

if [ "$FOLLOW" = 1 ] && [ -n "$NEWEST_ID" ]; then
  echo
  log "following run $NEWEST_ID (every ${INTERVAL}s, Ctrl-C to stop)"
  while :; do
    state="$(gh run view "$NEWEST_ID" --json status,conclusion -q '"\(.status) \(.conclusion // "")"' 2>/dev/null)"
    case "$state" in
      completed*) printf '\n'; break ;;
      *)          printf '.'; sleep "$INTERVAL" ;;
    esac
  done
  diagnose_run "$NEWEST_ID"
  case "$state" in
    "completed success") exit 0 ;;
    *)                   exit 1 ;;
  esac
fi

echo
log_dim "newest run: $NEWEST_ID · diagnose it with: make diagnose   (or --follow to wait)"
exit 0
