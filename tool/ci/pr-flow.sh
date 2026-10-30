#!/usr/bin/env bash
# Open a pull request from validated work, and merge it when the evidence says it is safe.
#
# The sequence this automates:
#
#   1. validate locally with the same pipeline CI runs   (tool/ci/run-pipeline.sh)
#   2. push the branch
#   3. open a PR, or find the one that already exists
#   4. decide whether to merge, and merge
#
# Step 4 is where the judgement lives, and it is deliberately not "local validation passed,
# so merge". Local validation is the gate for *opening* the PR: it is fast, it is on your
# machine, and it stops you publishing something broken. It is not sufficient for *merging*,
# because a local run is only as broad as the toolchain installed locally — a machine with no
# Dart SDK verifies two jobs out of five and cannot tell you the authoritative engine builds.
#
# So --merge-on chooses the evidence the merge is allowed to rest on:
#
#   checks  (default)  wait for remote CI and merge only if every check passes. Correct for
#                      a healthy repository. When CI cannot run at all — this repository has
#                      been refused for billing — the script says so and refuses, rather than
#                      treating "no checks reported" as "checks passed".
#   local              merge on the strength of the local run alone. This is the informed
#                      override for a repository whose CI is down, and it is recorded as such
#                      in the PR body and in artifacts/ci/verification-log.jsonl.
#   never              open the PR and stop. The default for anyone who wants to review first.
#
# Usage:
#   tool/ci/pr-flow.sh                              # validate, push, open PR, wait for CI
#   tool/ci/pr-flow.sh --dry-run                    # every decision, no side effects
#   tool/ci/pr-flow.sh --merge-on local --yes       # CI is down; merge on the local run
#   tool/ci/pr-flow.sh --merge-on never             # just open the PR
#   tool/ci/pr-flow.sh --new-branch fix/retry-timer # branch, then the whole flow
#   tool/ci/pr-flow.sh --squash --delete-branch
#
# Exit codes: 0 done · 1 validation or merge refused · 2 partial and not forced ·
#             3 push failed · 4 PR step failed · 64 bad usage

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

ROOT="$(repo_root)"
LOG_FILE="$ROOT/artifacts/ci/verification-log.jsonl"

BASE=""
TITLE=""
BODY=""
DRAFT=0
MERGE_ON="checks"
MERGE_METHOD="merge"
SKIP_VALIDATE=0
FORCE_PARTIAL=0
NO_PUSH=0
DRY_RUN=0
ASSUME_YES=0
DELETE_BRANCH=0
NEW_BRANCH=""
CHECK_TIMEOUT=1800
CHECK_INTERVAL=30
FAST_FLAG=""
JOBS=""

usage() {
  # Walk the leading `#` block instead of a hard-coded line range. Four of these scripts had
  # drifted past their own range and were printing their source code as help text — measured, not
  # suspected: `run-pipeline.sh --help` emitted eleven lines of `set -uo pipefail`, `HERE=…`,
  # `. "$HERE/lib.sh"`. Re-tuning six magic numbers would leave the same trap for the next edit;
  # this is the pattern `daily.sh` already uses.
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --base)            BASE="$2"; shift 2 ;;
    --base=*)          BASE="${1#*=}"; shift ;;
    --title)           TITLE="$2"; shift 2 ;;
    --title=*)         TITLE="${1#*=}"; shift ;;
    --body)            BODY="$2"; shift 2 ;;
    --body=*)          BODY="${1#*=}"; shift ;;
    --draft)           DRAFT=1; shift ;;
    --merge-on)        MERGE_ON="$2"; shift 2 ;;
    --merge-on=*)      MERGE_ON="${1#*=}"; shift ;;
    --squash)          MERGE_METHOD="squash"; shift ;;
    --merge)           MERGE_METHOD="merge"; shift ;;
    --rebase)          MERGE_METHOD="rebase"; shift ;;
    --skip-validate)   SKIP_VALIDATE=1; shift ;;
    --force-partial)   FORCE_PARTIAL=1; shift ;;
    --no-push)         NO_PUSH=1; shift ;;
    --dry-run|-n)      DRY_RUN=1; shift ;;
    --yes|-y)          ASSUME_YES=1; shift ;;
    --delete-branch)   DELETE_BRANCH=1; shift ;;
    --new-branch)      NEW_BRANCH="$2"; shift 2 ;;
    --new-branch=*)    NEW_BRANCH="${1#*=}"; shift ;;
    --fast)            FAST_FLAG="--fast"; shift ;;
    --job)             JOBS="$2"; shift 2 ;;
    --timeout)         CHECK_TIMEOUT="$2"; shift 2 ;;
    --interval)        CHECK_INTERVAL="$2"; shift 2 ;;
    -h|--help)         usage; exit 0 ;;
    *)                 err "unknown option: $1"; usage >&2; exit 64 ;;
  esac
done

case "$MERGE_ON" in checks|local|never) ;; *) err "--merge-on must be checks, local or never"; exit 64 ;; esac

say()  { [ "$DRY_RUN" = 1 ] && log_dim "[dry-run] $*" || log "$*"; }
would() {
  # In a dry run, print the command instead of running it. Everything with a side effect
  # goes through here, so --dry-run really has no side effects.
  if [ "$DRY_RUN" = 1 ]; then
    printf '%s\n' "${C_DIM}    would run: $*${C_RESET}"
    return 0
  fi
  "$@"
}

# --- 0. preflight --------------------------------------------------------------

have gh || { err "the GitHub CLI (gh) is required. Install it, then: gh auth login"
             err "Never paste a token into this repository."; exit 64; }

if ! gh auth status >/dev/null 2>&1; then
  err "gh is installed but not authenticated. Run: gh auth login"
  exit 64
fi

REPO="$(git -C "$ROOT" remote get-url origin 2>/dev/null | sed -E 's#.*github.com[:/]##; s#\.git$##')"
[ -n "$REPO" ] || { err "cannot determine the repository from the origin remote"; exit 64; }

BRANCH="$(git_branch)"
if [ -n "$NEW_BRANCH" ]; then
  say "creating branch $NEW_BRANCH from $BRANCH"
  would git -C "$ROOT" checkout -b "$NEW_BRANCH" || exit 1
  BRANCH="$NEW_BRANCH"
fi

if [ -z "$BASE" ]; then
  BASE="$(gh repo view "$REPO" --json defaultBranchRef -q '.defaultBranchRef.name' 2>/dev/null || true)"
  [ -n "$BASE" ] || BASE="main"
  log_dim "base branch: $BASE (the repository default)"
fi

if [ "$BRANCH" = "$BASE" ]; then
  err "you are on '$BASE', which is also the PR base. A pull request needs two branches."
  err "Create one first:  tool/ci/pr-flow.sh --new-branch fix/your-change"
  exit 64
fi

log "pr-flow · $REPO · $BRANCH → $BASE · merge-on=$MERGE_ON · method=$MERGE_METHOD"
[ "$DRY_RUN" = 1 ] && warn "dry run: nothing will be pushed, opened or merged"

# --- 1. validate locally -------------------------------------------------------
#
# This is the gate for opening a PR at all. A red local run stops here, before anything is
# published, which is the whole point of validating first.

VERIFICATION="skipped"
JOBS_VERIFIED="-"
RUN_ID="none"
PIPE_RC=0

if [ "$SKIP_VALIDATE" = 1 ]; then
  warn "skipping local validation at your request; the PR body will say so"
  VERIFICATION="skipped"
else
  echo
  log "step 1 — validate locally"
  PIPE_ARGS=(--keep-going --label pr-flow)
  [ -n "$FAST_FLAG" ] && PIPE_ARGS+=(--fast)
  [ -n "$JOBS" ] && PIPE_ARGS+=(--job "$JOBS")
  # A partial run is allowed to continue only when asked for; otherwise the runner itself
  # refuses, and so does this script.
  [ "$FORCE_PARTIAL" = 1 ] && PIPE_ARGS+=(--allow-missing-dart)

  JSON_RECORD="$(mktemp -t pr-flow-record.XXXXXX.json)"
  PIPE_ARGS+=(--json "$JSON_RECORD")

  "$HERE/run-pipeline.sh" "${PIPE_ARGS[@]}"
  PIPE_RC=$?

  if have python3 && [ -s "$JSON_RECORD" ]; then
    VERIFICATION="$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("verification") or "unknown")
except Exception: print("unknown")' "$JSON_RECORD" 2>/dev/null)"
    JOBS_VERIFIED="$(python3 -c 'import json,sys
try: print(",".join(json.load(open(sys.argv[1])).get("jobs") or {}) or "-")
except Exception: print("-")' "$JSON_RECORD" 2>/dev/null)"
    RUN_ID="$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("runId") or "unknown")
except Exception: print("unknown")' "$JSON_RECORD" 2>/dev/null)"
  fi
  rm -f "$JSON_RECORD"

  if [ "$PIPE_RC" -eq 1 ]; then
    echo
    err "local validation FAILED — not opening a pull request."
    err "Fix the failures above. A PR is a request for other people's attention, and"
    err "spending it on a build you know is red is the expensive way to find out."
    exit 1
  fi
  if [ "$PIPE_RC" -eq 2 ] && [ "$FORCE_PARTIAL" = 0 ]; then
    echo
    err "local validation was PARTIAL — some jobs could not run for want of a toolchain."
    err "Re-run with --force-partial to open the PR anyway; it will be labelled partial."
    exit 2
  fi
fi

# --- 2. push -------------------------------------------------------------------

echo
log "step 2 — push $BRANCH"

if [ "$NO_PUSH" = 1 ]; then
  log_dim "  skipped (--no-push)"
else
  # A pre-push hook may gate this. That is wanted: it is the same fast subset, and if it
  # blocks, the push should block.
  if would git -C "$ROOT" push -u origin "$BRANCH"; then
    log_dim "  pushed"
  else
    err "push failed. If the message above came from the pre-push gate, the build is red;"
    err "if it came from the remote, check authentication with: gh auth status"
    exit 3
  fi
fi

# --- 3. the pull request -------------------------------------------------------

echo
log "step 3 — pull request"

EXISTING="$(gh pr view "$BRANCH" --repo "$REPO" --json number,url -q '.number' 2>/dev/null || true)"

if [ -n "$EXISTING" ]; then
  PR_URL="$(gh pr view "$BRANCH" --repo "$REPO" --json url -q '.url' 2>/dev/null || echo "")"
  say "a PR already exists for this branch: #$EXISTING $PR_URL"
  PR_NUMBER="$EXISTING"
else
  [ -n "$TITLE" ] || TITLE="$(git -C "$ROOT" log -1 --pretty=%s)"

  # The body states what was actually verified, including what was not. A PR description
  # that says "tested" when three jobs out of five could not run is how unreviewed risk gets
  # merged, so the local verdict goes in the body rather than staying in a local artifact.
  COMMITS="$(git -C "$ROOT" log --no-merges --pretty='- `%h` %s' "origin/$BASE..HEAD" 2>/dev/null \
             || git -C "$ROOT" log --no-merges -n 20 --pretty='- `%h` %s')"

  if [ -z "$BODY" ]; then
    BODY="$(cat <<EOF
## Commits

$COMMITS

## Local verification

| | |
| --- | --- |
| Verdict | \`$VERIFICATION\` |
| Jobs that ran | \`$JOBS_VERIFIED\` |
| Local run | \`$RUN_ID\` |

$(case "$VERIFICATION" in
    full*)    echo "Every CI job ran locally and passed." ;;
    scoped*)  echo "Only the jobs named above ran locally. **The others were not verified by this run.**" ;;
    partial*) echo "**Partial.** Some jobs could not run for want of a toolchain on this machine. Treat the unverified jobs as unverified." ;;
    skipped*) echo "**Local validation was skipped** (\`--skip-validate\`). Nothing here has been checked." ;;
    *)        echo "Verdict could not be determined." ;;
  esac)

## Remote CI

Filled in by the merge decision below.
EOF
)"
  fi

  CREATE_ARGS=(pr create --repo "$REPO" --base "$BASE" --head "$BRANCH"
               --title "$TITLE" --body "$BODY")
  [ "$DRAFT" = 1 ] && CREATE_ARGS+=(--draft)

  say "opening a pull request: $BRANCH → $BASE"
  if [ "$DRY_RUN" = 1 ]; then
    printf '%s\n' "${C_DIM}    would run: gh ${CREATE_ARGS[*]}${C_RESET}"
    PR_NUMBER="<dry-run>"
    PR_URL="<dry-run>"
  else
    PR_URL="$(gh "${CREATE_ARGS[@]}" 2>&1)" || { err "gh pr create failed: $PR_URL"; exit 4; }
    PR_NUMBER="$(gh pr view "$BRANCH" --repo "$REPO" --json number -q '.number' 2>/dev/null || echo "")"
    say "opened #$PR_NUMBER  $PR_URL"
  fi
fi

# --- 4. the merge decision -----------------------------------------------------

echo
log "step 4 — merge decision (merge-on=$MERGE_ON)"

record_verdict() { # <outcome> <note>
  mkdir -p "$(dirname "$LOG_FILE")"
  printf '{"timestamp":"%s","branch":"%s","sha":"%s","verification":"%s","jobs":"%s","pipelineExit":%d,"runId":"%s","gate":"pr-flow","mergeOn":"%s","outcome":"%s","pr":"%s","note":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$BRANCH" "$(git_sha)" "$VERIFICATION" "$JOBS_VERIFIED" \
    "$PIPE_RC" "$RUN_ID" "$MERGE_ON" "$1" "${PR_NUMBER:-none}" "$2" >> "$LOG_FILE"
}

if [ "$MERGE_ON" = never ]; then
  say "leaving #$PR_NUMBER open for review (--merge-on never)"
  [ "$DRY_RUN" = 1 ] || record_verdict "opened" "merge-on=never"
  exit 0
fi

CI_STATE="unknown"
if [ "$MERGE_ON" = checks ]; then
  # Wait for the checks, then classify a failure before acting on it. "Checks failed" and
  # "checks could not run" need opposite responses and look identical in a PR summary.
  if [ "$DRY_RUN" = 1 ]; then
    printf '%s\n' "${C_DIM}    would poll: gh pr checks $PR_NUMBER --repo $REPO${C_RESET}"
    printf '%s\n' "${C_DIM}    would merge only if every check passes${C_RESET}"
    CI_STATE="dry-run"
  else
    log_dim "  waiting up to ${CHECK_TIMEOUT}s for checks on #$PR_NUMBER (every ${CHECK_INTERVAL}s)"
    waited=0
    while :; do
      rollup="$(gh pr view "$PR_NUMBER" --repo "$REPO" --json statusCheckRollup \
                 -q '.statusCheckRollup[] | [(.status // ""), (.conclusion // "")] | @tsv' 2>/dev/null || true)"
      if [ -z "$rollup" ]; then
        # No checks reported yet, or none configured. Distinguish those: a run exists but
        # has not registered checks yet versus a repository with no workflow at all.
        log_dim "  no checks reported yet"
      fi
      pending="$(printf '%s\n' "$rollup" | awk -F'\t' 'NF && $1 != "COMPLETED" && $1 != ""' | grep -c '' || true)"
      if [ "${pending:-0}" -eq 0 ] && [ -n "$rollup" ]; then break; fi
      if [ "$waited" -ge "$CHECK_TIMEOUT" ]; then
        err "timed out after ${CHECK_TIMEOUT}s waiting for checks."
        record_verdict "timeout" "checks did not complete"
        exit 1
      fi
      sleep "$CHECK_INTERVAL"
      waited=$((waited + CHECK_INTERVAL))
    done

    failed="$(printf '%s\n' "$rollup" \
              | awk -F'\t' 'NF && $2 != "SUCCESS" && $2 != "NEUTRAL" && $2 != "SKIPPED" && $2 != ""' \
              | grep -c '' || true)"

    if [ "${failed:-0}" -gt 0 ]; then
      # Classify before reporting. Uses watch.sh so there is one definition of what
      # "billing refusal" means in this repository.
      RUN_FOR_SHA="$(gh run list --repo "$REPO" --branch "$BRANCH" --limit 1 \
                      --json databaseId -q '.[0].databaseId' 2>/dev/null || true)"
      if [ -n "$RUN_FOR_SHA" ]; then
        CI_STATE="$("$HERE/watch.sh" --classify-run "$RUN_FOR_SHA" 2>/dev/null || echo none)"
      else
        CI_STATE="none"
      fi

      if [ "$CI_STATE" = billing ] || [ "$CI_STATE" = runner ]; then
        echo
        err "$CI_STATE refusal: the checks failed because CI could not run, not because the"
        err "build is red. This script will not merge on that, and will not report it as a"
        err "pass either — there is no evidence either way."
        echo
        err "Your options, in order of how much they preserve the truth:"
        err "  1. Fix the account: Settings → Billing & plans, then re-run: make diagnose"
        err "  2. Install the missing toolchain locally so the local run is full, then:"
        err "       tool/ci/pr-flow.sh --merge-on local --yes"
        err "     That merges on local evidence and records that CI never confirmed it."
        err "  3. Leave the PR open: tool/ci/pr-flow.sh --merge-on never"
        "$HERE/watch.sh" --diagnose "$RUN_FOR_SHA" 2>/dev/null || true
        record_verdict "refused" "ci-$CI_STATE"
        exit 1
      fi

      echo
      err "checks FAILED on #$PR_NUMBER — not merging."
      [ -n "$RUN_FOR_SHA" ] && "$HERE/watch.sh" --diagnose "$RUN_FOR_SHA" 2>/dev/null || true
      record_verdict "refused" "checks-failed"
      exit 1
    fi

    CI_STATE="green"
    log_dim "  every check passed"
  fi
fi

if [ "$MERGE_ON" = local ]; then
  # The informed override. Say plainly, in the terminal and in the log, that this merge
  # rests on a local run and not on CI.
  warn "merging on local evidence (--merge-on local). Remote CI did not confirm this."
  if [ "${VERIFICATION#full}" = "$VERIFICATION" ]; then
    # Did not start with "full", so some job in the workflow did not run.
    warn "and the local verdict was '$VERIFICATION', not 'full' — some jobs did not run."
  fi
  CI_STATE="local-only"
fi

# Confirmation: a merge is not idempotent and is awkward to undo. Prompt when a human is
# attached; --yes and --dry-run are the ways to run this unattended.
if [ "$ASSUME_YES" = 0 ] && [ "$DRY_RUN" = 0 ] && [ -t 0 ]; then
  printf '\nMerge #%s into %s with --%s? [y/N] ' "${PR_NUMBER:-?}" "$BASE" "$MERGE_METHOD"
  read -r answer
  case "$answer" in
    y|Y|yes|YES) ;;
    *) warn "not merged."; record_verdict "declined" "user declined at the prompt"; exit 0 ;;
  esac
fi

MERGE_ARGS=(pr merge "${PR_NUMBER:-}" --repo "$REPO" "--$MERGE_METHOD")
[ "$DELETE_BRANCH" = 1 ] && MERGE_ARGS+=(--delete-branch)

say "merging #$PR_NUMBER into $BASE (--$MERGE_METHOD)"
if would gh "${MERGE_ARGS[@]}"; then
  echo
  log "merged #$PR_NUMBER → $BASE · local verification: $VERIFICATION · CI: $CI_STATE"
  [ "$DRY_RUN" = 1 ] || record_verdict "merged" "ci=$CI_STATE"
  exit 0
fi

err "the merge failed. Check whether the branch is out of date or reviews are required:"
err "    gh pr view ${PR_NUMBER:-} --repo $REPO"
record_verdict "merge-failed" "gh pr merge returned nonzero"
exit 4
