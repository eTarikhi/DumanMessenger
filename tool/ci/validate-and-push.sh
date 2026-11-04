#!/usr/bin/env bash
# Validate with the local pipeline, then push — and only then.
#
# The order is the point. `git push` after a green build is a convenience; `git push`
# *conditional* on a green build is a gate, and the difference only shows up on the day
# something is red. This script will not push on a failed run, and it will not push on a
# run that could not finish either — a machine without the Dart SDK cannot verify the
# authoritative engine, and "the TypeScript passed" is not the same claim.
#
# Because that situation is real rather than hypothetical (CI on this repository has been
# unavailable for billing reasons, and the Dart engine has no compiler in some workspaces),
# there is one deliberate escape hatch: --force-partial. It pushes anyway, and it says so
# out loud, in the artifact record and in the append-only verification log, so a commit
# that was never fully verified is discoverable later instead of looking like one that was.
#
# Usage:
#   tool/ci/validate-and-push.sh                          # full pipeline, then push
#   tool/ci/validate-and-push.sh --message "fix: ..."     # commit the tree first
#   tool/ci/validate-and-push.sh --fast                   # quick subset, then push
#   tool/ci/validate-and-push.sh --dry-run                # everything except the push
#   tool/ci/validate-and-push.sh --force-partial          # push despite a partial run
#
# Exit codes: 0 pushed (or dry-run clean) · 1 pipeline failed · 2 partial and not forced ·
#             3 push failed · 64 bad usage

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

ROOT="$(repo_root)"
LOG_FILE="$ROOT/artifacts/ci/verification-log.jsonl"

MESSAGE=""
DRY_RUN=0
FORCE_PARTIAL=0
NO_COMMIT=0
JOBS=""
FAST_FLAG=""
REMOTE="origin"
ASSUME_YES=0

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
    --message|-m)     MESSAGE="$2"; shift 2 ;;
    --message=*)      MESSAGE="${1#*=}"; shift ;;
    --job)            JOBS="$2"; shift 2 ;;
    --fast)           FAST_FLAG="--fast"; shift ;;
    --dry-run)        DRY_RUN=1; shift ;;
    --force-partial)  FORCE_PARTIAL=1; shift ;;
    --no-commit)      NO_COMMIT=1; shift ;;
    --remote)         REMOTE="$2"; shift 2 ;;
    --yes|-y)         ASSUME_YES=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    *)                err "unknown option: $1"; usage >&2; exit 64 ;;
  esac
done

BRANCH="$(git_branch)"
if [ "$BRANCH" = HEAD ] || [ -z "$BRANCH" ]; then
  err "detached HEAD — check out a branch first."
  exit 64
fi

# --- 1. what is about to be verified ------------------------------------------

echo
log "validate-and-push · ${BRANCH} @ $(git_sha)"

if [ -n "$MESSAGE" ] && [ "$NO_COMMIT" = 0 ]; then
  if [ -z "$(git -C "$ROOT" status --porcelain)" ]; then
    log_dim "nothing to commit; the message will not be used"
  else
    git -C "$ROOT" add -A
    git -C "$ROOT" commit -q -m "$MESSAGE"
    log "committed: $(git -C "$ROOT" log --oneline -1)"
  fi
fi

# Artifacts are a local record, not a deliverable: keep them out of the commit that is
# about to be verified, or every push would carry the previous push's logs.
if git -C "$ROOT" status --porcelain -- artifacts/ | grep -q .; then
  warn "artifacts/ is not ignored — add it to .gitignore so run logs are not committed"
fi

DIRTY="$(git -C "$ROOT" status --porcelain | grep -v '^?? artifacts/' || true)"
if [ -n "$DIRTY" ]; then
  warn "the working tree has uncommitted changes. They will be verified but not pushed:"
  printf '%s\n' "$DIRTY" | head -10 | sed 's/^/    /'
  [ "$ASSUME_YES" = 0 ] && [ "$DRY_RUN" = 0 ] && {
    printf '  verify anyway? [y/N] '; read -r reply
    case "$reply" in y|Y|yes) ;; *) err "aborted"; exit 64 ;; esac
  }
fi

# --- 2. run the pipeline ------------------------------------------------------

JSON_RECORD="$(mktemp -t ci-result.XXXXXX.json)"
trap 'rm -f "$JSON_RECORD" "${PUSH_LOG:-}"' EXIT

PIPELINE_ARGS=(--json "$JSON_RECORD" --label push)
[ -n "$FAST_FLAG" ] && PIPELINE_ARGS+=("$FAST_FLAG")
[ -n "$JOBS" ] && PIPELINE_ARGS+=(--job "$JOBS")
# The runner exits 1 on a missing toolchain; this script needs to distinguish "failed" from
# "could not run", so it asks for the partial code and decides for itself.
PIPELINE_ARGS+=(--allow-missing-dart)

"$HERE/run-pipeline.sh" "${PIPELINE_ARGS[@]}"
PIPE_RC=$?

if [ "$PIPE_RC" -eq 1 ]; then
  echo
  err "pipeline FAILED — not pushing."
  err "fix the failures above; captured output is in the artifact directory."
  exit 1
fi

# Take the verdict from the pipeline's own record rather than re-deriving it here. That
# record is scope-aware, and this log is the artefact someone reads later to decide what
# was ever actually verified — a --job web push that logged "full" would claim the Dart
# engine had been checked when no Dart job ran at all.
VERIFICATION="$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("verification") or "")
except Exception: print("")' "$JSON_RECORD" 2>/dev/null)"
if [ -z "$VERIFICATION" ]; then
  # Fall back to deriving it, if the record could not be read.
  VERIFICATION="full"
  [ "$PIPE_RC" -eq 2 ] && VERIFICATION="partial"
  case "$FAST_FLAG" in --fast) VERIFICATION="$VERIFICATION+fast" ;; esac
fi
JOBS_VERIFIED="$(python3 -c 'import json,sys
try: print(",".join(json.load(open(sys.argv[1])).get("jobs") or {}) or "unknown")
except Exception: print("unknown")' "$JSON_RECORD" 2>/dev/null)"

# --- 3. record what was verified ----------------------------------------------

mkdir -p "$(dirname "$LOG_FILE")"
RECORD_RUN="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["runId"])' "$JSON_RECORD" 2>/dev/null || echo unknown)"
{
  printf '{"timestamp":"%s","branch":"%s","sha":"%s","verification":"%s","jobs":"%s","pipelineExit":%d,"runId":"%s","pushed":' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$BRANCH" "$(git_sha)" "$VERIFICATION" "$JOBS_VERIFIED" "$PIPE_RC" "$RECORD_RUN"
  # Filled in below, once the push outcome is known; a placeholder keeps the line valid JSON
  # even if this script is interrupted between here and there.
  printf 'null}\n'
} >> "$LOG_FILE"

# --- 4. the partial verdict ---------------------------------------------------

if [ "$PIPE_RC" -eq 2 ] && [ "$FORCE_PARTIAL" = 0 ]; then
  echo
  err "the pipeline ran PARTIALLY — jobs could not run for want of a toolchain."
  err "A partial run is not a green build, so this will not push on its own authority."
  echo
  echo "  What is missing is in the table above (marked MISSING or BLOCKED)."
  echo "  Install the toolchain — docs/10-local-development-and-ci.md §2 — and re-run,"
  echo "  or push anyway with:"
  echo
  echo "      $0 --force-partial"
  echo
  echo "  That records the push as partially verified in artifacts/ci/verification-log.jsonl"
  echo "  rather than pretending it was checked."
  exit 2
fi

if [ "$PIPE_RC" -eq 2 ]; then
  warn "pushing after a PARTIAL run because --force-partial was given."
  warn "The record will say verification=partial. Get a real run before trusting this build."
fi

# --- 5. push ------------------------------------------------------------------

# Know whether this will be a fast-forward before attempting it: a rejected push after a
# four-minute pipeline is a worse experience than a rejected push before one.
git -C "$ROOT" fetch -q "$REMOTE" "$BRANCH" 2>/dev/null || true
if git -C "$ROOT" rev-parse -q --verify "$REMOTE/$BRANCH" >/dev/null; then
  if ! git -C "$ROOT" merge-base --is-ancestor "$REMOTE/$BRANCH" HEAD; then
    err "$REMOTE/$BRANCH has commits this branch does not. Pull or rebase before pushing;"
    err "pushing now would be rejected (or would need --force, which this script will not do)."
    exit 3
  fi
  AHEAD=$(git -C "$ROOT" rev-list --count "$REMOTE/$BRANCH..HEAD")
  log_dim "ahead of $REMOTE/$BRANCH by $AHEAD commit(s)"
  if [ "$AHEAD" = 0 ]; then
    log "nothing to push — $REMOTE/$BRANCH is already at $(git_sha)"
    exit 0
  fi
fi

if [ "$DRY_RUN" = 1 ]; then
  echo
  log "dry run: would push $(git_sha) to $REMOTE/$BRANCH (verification: $VERIFICATION)"
  git -C "$ROOT" log --oneline "$REMOTE/$BRANCH..HEAD" 2>/dev/null | sed 's/^/    /' || true
  exit 0
fi

echo
log "pushing to $REMOTE/$BRANCH"
# When this script ran *every* job, its pipeline is strictly broader than the pre-push
# hook's fast subset, so letting the hook run would repeat the same test suite and roughly
# double the wait for no additional information. A scoped run (--job web) is narrower than
# the hook, so there the hook still runs and still gets its say.
PUSH_ARGS=("$REMOTE" "$BRANCH")
if [ -z "$JOBS" ]; then
  log_dim "skipping the pre-push hook: this run already covered every job it would have"
  PUSH_ARGS+=(--no-verify)
fi

PUSH_LOG="$(mktemp)"
if git -C "$ROOT" push "${PUSH_ARGS[@]}" 2>&1 | tee "$PUSH_LOG"; then
  # Rewrite the placeholder line with the real outcome. The log is append-only JSON Lines,
  # so this replaces the last line rather than appending a second record for one push.
  if have python3; then
    python3 - "$LOG_FILE" "$(git_sha)" <<'PY'
import json, sys
path, sha = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as fh:
    lines = fh.read().splitlines()
for i in range(len(lines) - 1, -1, -1):
    try:
        rec = json.loads(lines[i])
    except ValueError:
        continue
    if rec.get("sha") == sha and rec.get("pushed") is None:
        rec["pushed"] = True
        lines[i] = json.dumps(rec)
        break
with open(path, "w", encoding="utf-8") as fh:
    fh.write("\n".join(lines) + "\n")
PY
  fi
  echo
  log "pushed $(git_sha) → $REMOTE/$BRANCH · verification: ${VERIFICATION} (jobs: ${JOBS_VERIFIED})"
  log_dim "record: ${LOG_FILE#$ROOT/}"
  log_dim "remote CI will now run the same pipeline. Watch it with: make watch"
  exit 0
fi

# A pre-push hook that blocks and a remote that rejects both end up here, but they need
# opposite advice: one is this machine's own gate doing exactly its job, the other is a
# network or credential problem. Telling someone to reconnect GitHub when their own hook
# just failed the build sends them debugging the wrong thing for an hour.
if grep -q "pre-push gate FAILED" "$PUSH_LOG"; then
  err "push blocked by the local pre-push hook — not by the remote."
  err "This script verified $VERIFICATION for the jobs it selected, but the hook re-ran"
  err "the fast subset over every job and that run failed. Its output is above."
  err "Fix it, or bypass the hook once with: git push --no-verify"
  exit 3
fi

err "push failed. The build was verified locally ($VERIFICATION); the remote rejected it."
err "If this is an authentication failure, the GitHub connection needs attention —"
err "reconnect GitHub rather than pasting a token into this repository."
exit 3
