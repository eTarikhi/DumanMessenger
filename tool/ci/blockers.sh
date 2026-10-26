#!/usr/bin/env bash
# What stops this project from being finished *here* — probed, not asserted.
#
# `doctor.sh` answers "is this machine able to verify this repository?". This answers a
# different question that doctor cannot: "what is the reason the work stops before the
# roadmap is done?". The two overlap on the Dart SDK and nowhere else, because most of what
# stops this project is not a missing tool — it is a network egress rule, a refused CI
# account, a radio that does not exist in a container, and a crowd of fifteen people.
#
# Every row is measured at run time and the measurement is printed next to the verdict, so a
# reader can disagree with the conclusion by looking at the evidence rather than by trusting
# the prose. Nothing here is a claim about what a *properly provisioned* machine can do, and
# no row is a guess: the one thing that cannot be probed (the crowd) says so in its evidence.
#
# Sections:
#   A toolchain      what cannot be compiled or built on this machine
#   B egress         which hosts the roadmap needs that this machine cannot reach
#   C remote CI      whether GitHub Actions can execute a job at all, and since when it could
#   D hardware       radios, phones, and the people holding them
#   E repository     the rollback signature: HEAD, working tree, dependencies, artifacts
#   F roadmap        each open item classified by what it would take to close it
#
# Exit codes — deliberately not a gate:
#   0   the report was produced. Blockers are the *expected* finding; a non-zero exit here
#       would train whoever runs the daily job to ignore it.
#   1   the report could not be produced (no python3 for the JSON, unreadable repository)
#   3   with --strict only: a row this machine *can* fix is wrong — a rolled-back HEAD, a
#       working tree holding base-commit content, or no node_modules. Those three are the
#       signature of a sandbox rollback and they cost a repair before any work can start.
#  64   usage error
#
# Cost: ~20 s, nearly all of it the eight egress probes and the two `gh` calls. Blocked TLS
# fails fast here (curl exit 35 in well under a second), so the timeouts are a ceiling rather
# than an expectation.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

ROOT="$(repo_root)"
ROADMAP="$ROOT/roadmap/roadmap.md"
DART_DIR="$ROOT/sim/mesh_sim"

usage() {
  sed -n '2,36p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  cat <<USAGE

Options:
  --json PATH     also write every row as JSON (needs python3)
  --quiet         only the summary line and the exit code
  --strict        exit 3 if a row this machine can fix is wrong (see exit codes above)
  --help          this text

Runs:
  ./tool/ci/blockers.sh                 the whole report
  ./tool/ci/blockers.sh --quiet         one line: how many blockers, of which repairable
  ./tool/ci/blockers.sh --json artifacts/blockers.json

Windows:  .\\make.ps1 blockers
Reads:    docs/10-local-development-and-ci.md §11 (what each row means, and what it costs)
USAGE
}

QUIET=0
STRICT=0
JSON_OUT=""

require_value() { [ -n "${2-}" ] || { err "option $1 needs a value"; exit 64; }; }

while [ $# -gt 0 ]; do
  case "$1" in
    --json)     require_value "$1" "${2-}"; JSON_OUT="$2"; shift 2 ;;
    --json=*)   JSON_OUT="${1#*=}"; shift ;;
    --quiet)    QUIET=1; shift ;;
    --strict)   STRICT=1; shift ;;
    --help|-h)  usage; exit 0 ;;
    *)          err "unknown option: $1"; usage; exit 64 ;;
  esac
done

# --- row plumbing --------------------------------------------------------------
#
# One array per column rather than an array of delimited strings, because bash has no structs
# and splitting on a delimiter is how a report ends up mis-aligned the first time an evidence
# value contains it — and the evidence values here are URLs, curl exit codes and file lists,
# i.e. exactly the characters one would otherwise pick as a delimiter.
#
# Rows print as they are recorded, so the report reads in section order; the arrays exist for
# the JSON output and the counts, not to buffer the display.
ROW_NAME=(); ROW_STATUS=(); ROW_EVIDENCE=(); ROW_COST=()
N_BLOCKED=0; N_DRIFT=0; N_OK=0; N_UNKNOWN=0

say() { [ "$QUIET" = 1 ] || printf '%s\n' "$@"; }
head_() { say ""; say "${C_BOLD}$1${C_RESET}"; }
stamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# row <name> <status> <evidence> <what it costs>
# status is one of: ok | blocked | drift | unknown | n/a
row() {
  local mark colour
  case "$2" in
    ok)      mark="ok     "; colour="$C_GREEN";  N_OK=$((N_OK + 1)) ;;
    blocked) mark="BLOCKED"; colour="$C_RED";    N_BLOCKED=$((N_BLOCKED + 1)) ;;
    drift)   mark="DRIFT  "; colour="$C_YELLOW"; N_DRIFT=$((N_DRIFT + 1)) ;;
    *)       mark="unknown"; colour="$C_DIM";    N_UNKNOWN=$((N_UNKNOWN + 1)) ;;
  esac
  ROW_NAME+=("$1"); ROW_STATUS+=("$2"); ROW_EVIDENCE+=("$3"); ROW_COST+=("$4")
  if [ "$QUIET" != 1 ]; then
    printf '  %s%s%s %-24s %s\n' "$colour" "$mark" "$C_RESET" "$1" "$3"
    printf '  %-32s%s↳ %s%s\n' "" "$C_DIM" "$4" "$C_RESET"
  fi
}

# probe <url> [extra curl flags] -> sets PROBE_CODE, PROBE_EXIT, PROBE_BYTES. An unreachable
# host is a finding, not an error, so this never fails the script.
#
# Redirects are followed on purpose. The signature of this sandbox's egress rule is not a
# refused connection to github.com — github.com answers — it is a 302 to a host that is not
# allowlisted, after which the download yields nothing. A probe that stopped at the first
# response would report that as reachable, and would be wrong about the only case that matters
# here: whether the bytes can actually be fetched.
PROBE_CODE=""; PROBE_EXIT=0; PROBE_BYTES=0
probe() {
  if ! have curl; then PROBE_CODE="no-curl"; PROBE_EXIT=127; PROBE_BYTES=0; return 0; fi
  local url="$1" out; shift
  out="$(curl -sL -o /dev/null --max-time 8 "$@" -w '%{http_code}:%{size_download}' "$url" 2>/dev/null)"
  PROBE_EXIT=$?
  PROBE_CODE="${out%%:*}"; PROBE_BYTES="${out##*:}"
  [ -n "$PROBE_CODE" ] || PROBE_CODE="000"
  [ -n "$PROBE_BYTES" ] || PROBE_BYTES=0
  PROBE_BYTES="${PROBE_BYTES%.*}"
}

# Two different questions, because a redirect to a blocked host answers the first and fails
# the second:
#   answered — the TCP+TLS path works and something came back (a 404 is an answer)
#   fetched  — and bytes were actually delivered, which is what a download needs
answered() { probe "$@"; [ "$PROBE_EXIT" = 0 ] && [ "$PROBE_CODE" != "000" ]; }
fetched()  { probe "$@"; [ "$PROBE_EXIT" = 0 ] && [ "$PROBE_CODE" != "000" ] \
             && [ "$PROBE_BYTES" != "0" ]; }

# --- A. toolchain ---------------------------------------------------------------

head_ "A · toolchain — what cannot be compiled or built on this machine"

DART_FILES=0; DART_LINES=0
if [ -d "$DART_DIR" ]; then
  DART_FILES=$(find "$DART_DIR" -name '*.dart' -not -path '*/.dart_tool/*' | wc -l | tr -d ' ')
  DART_LINES=$(find "$DART_DIR" -name '*.dart' -not -path '*/.dart_tool/*' -print0 \
    | xargs -0 cat 2>/dev/null | wc -l | tr -d ' ')
fi

if have dart; then
  row "dart-sdk" ok "$(dart_sdk_version || echo present)" \
      "the authoritative engine can be compiled and tested here"
else
  probe "https://storage.googleapis.com/dart-archive/channels/stable/release/latest/VERSION"
  row "dart-sdk" blocked \
      "dart absent; SDK host storage.googleapis.com → curl exit $PROBE_EXIT, HTTP $PROBE_CODE, $PROBE_BYTES bytes" \
      "$DART_FILES Dart files / $DART_LINES lines — the authoritative engine — have never been compiled on this machine, and no check here can compile them"
fi

if have flutter; then
  row "flutter-sdk" ok "$(tool_version flutter | head -1)" "the app/ tree could be built here"
else
  row "flutter-sdk" blocked "flutter absent" \
      "the roadmap's app/ (Flutter UI, permissions flows, onboarding) cannot be built, run or screenshot here"
fi

if answered "https://pub.dev/api/packages/test"; then
  row "pub-dev" ok "HTTP $PROBE_CODE, $PROBE_BYTES bytes" "new Dart packages can be added"
else
  row "pub-dev" blocked "curl exit $PROBE_EXIT, HTTP $PROBE_CODE, $PROBE_BYTES bytes" \
      "no new Dart dependencies at all: no Opus codec, no SQLite plugin, no BLE plugin — pubspec.yaml is frozen at what it already lists"
fi

if have pwsh; then
  row "powershell" ok "$(tool_version pwsh | head -1)" "make.ps1 can be executed, not only read"
else
  probe "https://github.com/PowerShell/PowerShell/releases/latest"
  TAG_CODE="$PROBE_CODE"
  # A 500-byte range request: enough to prove whether the asset host delivers anything,
  # without pulling a 70 MB tarball through a probe that is going to fail anyway.
  probe "https://github.com/PowerShell/PowerShell/releases/download/v7.6.8/powershell-7.6.8-linux-x64.tar.gz" -r 0-500
  if [ "$PROBE_BYTES" = 0 ]; then
    row "powershell" blocked \
        "pwsh absent; release page HTTP $TAG_CODE, but the asset yields $PROBE_BYTES bytes (curl exit $PROBE_EXIT, HTTP $PROBE_CODE) — github.com answers and redirects to objects.githubusercontent.com, which is outside the allowlist" \
        "make.ps1 and docs/11's whole Windows path are checked statically by tool/ci/check-ps1.py and have never been executed anywhere"
  else
    row "powershell" blocked "pwsh absent, though the release asset is downloadable ($PROBE_BYTES bytes of the range arrived)" \
        "installable on this machine — the only blocker in section A that provisioning could remove"
  fi
fi

if have node; then
  NODE_V="$(node --version | sed 's/^v//')"
  if [ "${NODE_V%%.*}" = "$REQUIRED_NODE_MAJOR" ]; then
    row "node" ok "v$NODE_V (CI pins $REQUIRED_NODE_MAJOR)" "the TS reference engine and its test suite run here"
  else
    row "node" drift "v$NODE_V, CI pins major $REQUIRED_NODE_MAJOR" \
        "results may differ from CI's; npm ci warns EBADENGINE but still installs unless engine-strict is set"
  fi
else
  row "node" blocked "node absent" "nothing in src/ can be typechecked, tested or built"
fi

if have python3; then
  row "python3" ok "$(python3 --version 2>&1)" \
      "the five static checkers run (they are stdlib-only on purpose, for exactly this machine)"
else
  row "python3" blocked "python3 absent" \
      "check-docs/parity/dart-balance/dart-sites/ps1 cannot run — and they are the stand-ins for the missing Dart compiler"
fi

if have gh; then
  row "gh" ok "$(tool_version gh | head -1 | awk '{print $3}')" \
      "remote CI state can be read (whether it can *run* is section C)"
else
  row "gh" unknown "gh absent" "remote CI state cannot be read from here"
fi

# --- B. egress -------------------------------------------------------------------

head_ "B · egress — hosts the roadmap needs that this machine cannot reach"

# The allowlist is a fact about this sandbox, not about the repository, so it is probed
# rather than quoted: on a machine with no allowlist every row below simply comes back ok.
# Field 4 is the question being asked — `answer` (does the path work at all) or `fetch` (do
# bytes arrive). SDK archives and release assets are `fetch`, because for those a 302 that
# ends with nothing is a failure, and calling it reachable is exactly the mistake that would
# make this report claim the Dart SDK is installable when it is not.
for pair in \
  "github.com|https://github.com|source, issues, releases|answer" \
  "api.github.com|https://api.github.com|check-run annotations, the only machine-readable CI channel|answer" \
  "registry.npmjs.org|https://registry.npmjs.org/vitest|npm ci|answer" \
  "pypi.org|https://pypi.org/simple/|pip install pyyaml for the workflow parser|answer" \
  "pub.dev|https://pub.dev/api/packages/test|every Dart dependency|fetch" \
  "storage.googleapis.com|https://storage.googleapis.com/dart-archive/channels/stable/release/latest/VERSION|the Dart SDK itself|fetch" \
  "objects.githubusercontent.com|https://github.com/PowerShell/PowerShell/releases/download/v7.6.8/powershell-7.6.8-linux-x64.tar.gz|release assets, incl. PowerShell|fetch" \
  "results-receiver.actions.githubusercontent.com|https://results-receiver.actions.githubusercontent.com/|CI log download|answer"
do
  host="${pair%%|*}"; rest="${pair#*|}"; url="${rest%%|*}"; rest="${rest#*|}"
  need="${rest%%|*}"; mode="${rest##*|}"
  GOOD=0
  if [ "$mode" = fetch ]; then
    fetched "$url" -r 0-500 && GOOD=1
  else
    answered "$url" && GOOD=1
  fi
  if [ "$GOOD" = 1 ]; then
    row "egress:$host" ok "HTTP $PROBE_CODE, $PROBE_BYTES bytes" "$need"
  else
    row "egress:$host" blocked \
        "curl exit $PROBE_EXIT, HTTP $PROBE_CODE, $PROBE_BYTES bytes (asked: does it $mode?)" \
        "$need — unreachable"
  fi
done

# --- C. remote CI ----------------------------------------------------------------

head_ "C · remote CI — can GitHub Actions execute a job at all?"

if have gh; then
  NEWEST="$(gh run list --limit 1 --json conclusion,createdAt,headSha \
    --jq '.[0] | "\(.conclusion)|\(.createdAt)|\(.headSha[0:7])"' 2>/dev/null || true)"
  if [ -n "$NEWEST" ]; then
    N_CONC="${NEWEST%%|*}"; rest="${NEWEST#*|}"; N_DATE="${rest%%|*}"; N_SHA="${rest##*|}"
    if [ "$N_CONC" = "success" ]; then
      row "actions:newest-run" ok "success at $N_DATE ($N_SHA)" "CI is executing jobs"
    else
      CLASS="unknown"
      [ -x "$HERE/watch.sh" ] && CLASS="$("$HERE/watch.sh" --classify-run 2>/dev/null | tail -1 || echo unknown)"
      case "$CLASS" in
        billing) COST="jobs are refused before they start: 'recent account payments have failed or your spending limit needs to be increased'. Not fixable from a branch — it needs the account's billing settings, and \`gh run rerun\` is refused too" ;;
        runner)  COST="no runner available; a re-run may fix it" ;;
        no-run)  COST="no run to classify" ;;
        *)       COST="the run failed for a reason this probe could not classify; read the annotations with make diagnose" ;;
      esac
      row "actions:newest-run" blocked "$N_CONC at $N_DATE ($N_SHA), classified '$CLASS'" "$COST"
    fi
  else
    row "actions:newest-run" unknown "gh run list returned nothing" "cannot tell whether CI ran"
  fi

  LAST_GREEN="$(gh run list --limit 200 --json conclusion,createdAt,headSha \
    --jq '[.[] | select(.conclusion=="success")][0] | "\(.createdAt)|\(.headSha[0:7])"' 2>/dev/null || true)"
  if [ -n "$LAST_GREEN" ] && [ "$LAST_GREEN" != "null|null" ]; then
    SINCE="${LAST_GREEN%%|*}"
    # gh's --jq takes a filter string and has no --arg, so the timestamp read one call
    # earlier is interpolated. It came from gh, not from a human, so it carries no quoting
    # risk of the kind that would make interpolating user input acceptable.
    SINCE_FAILS="$(gh run list --limit 200 --json conclusion,createdAt \
      --jq "[.[] | select(.createdAt > \"$SINCE\") | select(.conclusion != \"success\")] | length" 2>/dev/null || echo '?')"
    row "actions:last-green" blocked \
        "${SINCE} (${LAST_GREEN##*|}); $SINCE_FAILS non-success runs since" \
        "every verification claim after that timestamp is local-only: run-pipeline.sh mirrors the workflow step for step, but nothing has executed it"
  else
    row "actions:last-green" unknown "no successful run in the last 200" "CI has never been seen green from here"
  fi
else
  row "actions:newest-run" unknown "gh absent" "cannot read remote CI state"
fi

# --- D. hardware -----------------------------------------------------------------

head_ "D · hardware — radios, phones, and the people holding them"

BLE_HCI="$(find /sys/class/bluetooth -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')"
if [ "$BLE_HCI" -gt 0 ]; then
  row "ble-adapter" ok "$BLE_HCI adapter(s) under /sys/class/bluetooth" \
      "the BLE GATT hello could be exercised against a real radio"
else
  row "ble-adapter" blocked "no /sys/class/bluetooth entries$(have bluetoothctl && echo '; bluetoothctl present but no adapter')" \
      "roadmap line 41 (Android GATT server + scanner + 12-byte beacon) and line 42 (CoreBluetooth) cannot be tested; the beacon's wire format exists only as sim/mesh_sim's AdvertPayload.beacon"
fi

WIFI_PHY="$(find /sys/class/net -maxdepth 2 -name phy80211 2>/dev/null | wc -l | tr -d ' ')"
if [ "$WIFI_PHY" -gt 0 ] && have iw; then
  row "wifi-direct" ok "$WIFI_PHY wireless phy, iw present" "Wi-Fi Direct could be probed"
else
  row "wifi-direct" blocked "$WIFI_PHY wireless phy under /sys/class/net; iw $(have iw && echo present || echo absent)" \
      "roadmap line 253 (WifiP2pManager group + socket relay) and line 352 (Wi-Fi Aware) cannot be exercised; the 1 KB transport switch is simulated only"
fi

if have adb; then
  ADB_N="$(adb devices 2>/dev/null | tail -n +2 | grep -c 'device$' || true)"
  if [ "${ADB_N:-0}" -gt 0 ]; then
    row "android-device" ok "$ADB_N device(s) attached" "foreground service, permissions and battery logging could be measured"
  else
    row "android-device" blocked "adb present, 0 devices attached" \
        "roadmap lines 44/139/149 (permissions, foreground service, battery logging) need a handset"
  fi
else
  row "android-device" blocked "adb absent" \
      "roadmap lines 44/139/149 (permissions, foreground service, battery logging) need a handset"
fi

case "$(uname -s)" in
  Darwin) row "ios-device" unknown "macOS host; xcrun $(have xcrun && echo present || echo absent)" \
                "CoreBluetooth and MultipeerConnectivity still need a paired iPhone and a signing identity" ;;
  *)      row "ios-device" blocked "host is $(uname -s), not macOS; no xcrun" \
                "every iOS roadmap item (42, 258, 351, and the v0.9 launch) is out of reach from this machine whatever else is installed — Apple's toolchain does not run on Linux" ;;
esac

# This row cannot be probed, and saying so is the point: it is the one blocker that no amount
# of provisioning inside a container removes, and skills/08 forbids claiming results without it.
row "crowd" blocked "no probe exists — this is a fact about the world, not about this machine" \
    "roadmap line 197 (field test 1: campus quad) and line 373 (15 real phones crowded) need people carrying phones; skills/08 forbids claiming large-scale results without that crowd test"

# --- E. repository state ----------------------------------------------------------

head_ "E · repository — the rollback signature"

BRANCH="$(git_branch)"
LOCAL_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
git rev-parse --verify -q "origin/$BRANCH" >/dev/null 2>&1 || git fetch -q origin "$BRANCH" 2>/dev/null || true
REMOTE_SHA="$(git rev-parse --short "origin/$BRANCH" 2>/dev/null || echo none)"
MAIN_SHA="$(git rev-parse --short origin/main 2>/dev/null || echo none)"
BASE_REF="origin/main"

# HEAD_DRIFT tells the working-tree row below how to read its own counts: 55 modified paths
# mean "work in progress" when HEAD is where the push left it, and "the pushed work is sitting
# here uncommitted" when HEAD has been reset to the branch point. Same numbers, opposite
# readings, and reporting the first when the second is true is how a rollback gets committed
# over the top of itself.
HEAD_DRIFT=0
if [ "$REMOTE_SHA" = "none" ]; then
  row "git-head" unknown "no origin/$BRANCH to compare against (offline?)" \
      "cannot tell whether the local checkout still holds the pushed work"
elif [ "$LOCAL_SHA" = "$REMOTE_SHA" ]; then
  row "git-head" ok "HEAD $LOCAL_SHA == origin/$BRANCH" "the checkout is where the push left it"
elif [ "$LOCAL_SHA" = "$MAIN_SHA" ]; then
  HEAD_DRIFT=1
  BEHIND="$(git rev-list --count "HEAD..origin/$BRANCH" 2>/dev/null || echo '?')"
  row "git-head" drift "HEAD $LOCAL_SHA == origin/main, $BEHIND commit(s) behind origin/$BRANCH" \
      "the local .git was reset to the branch point and the pushed work survives only as uncommitted files; repair with git fetch origin && git reset --mixed origin/$BRANCH — never --hard, which deletes it"
else
  # Ahead and behind are different situations and only one of them is drift. Local commits
  # that have not been pushed yet are the normal state of a working turn, and calling that
  # DRIFT would make --strict fail every run between a commit and its push — a row that cries
  # wolf gets ignored, and then the case that matters (pushed work missing from the checkout)
  # scrolls past unread. So: behind > 0 is drift, ahead-only is not.
  COUNTS="$(git rev-list --left-right --count "HEAD...origin/$BRANCH" 2>/dev/null || echo "")"
  AHEAD="${COUNTS%%[[:space:]]*}"; BEHIND="${COUNTS##*[[:space:]]}"
  case "$AHEAD"  in ''|*[!0-9]*) AHEAD=0 ;;  esac
  case "$BEHIND" in ''|*[!0-9]*) BEHIND=0 ;; esac
  if [ "$BEHIND" -gt 0 ]; then
    HEAD_DRIFT=1
    row "git-head" drift \
        "HEAD $LOCAL_SHA is $BEHIND pushed commit(s) behind origin/$BRANCH ($REMOTE_SHA) and $AHEAD ahead" \
        "this checkout does not contain work that is already public; git fetch origin && git reset --mixed origin/$BRANCH before committing, or the next push reverts it"
  else
    row "git-head" ok "$AHEAD local commit(s) ahead of origin/$BRANCH, none missing" \
        "ordinary unpushed work — push it when the checks pass, because a rollback keeps only what origin has"
  fi
fi

# A dirty working tree is the normal state mid-turn, so dirt alone is not drift — that would
# make --strict fail every push and the row would get ignored. The signature worth catching is
# narrower and decidable: a tracked file whose content is *byte-identical to the base commit*,
# i.e. the file was rolled back rather than edited. Anything else is reported as counts, with
# the ambiguity stated instead of resolved by guesswork.
MOD=0; UNT=0; STALE=0; STALE_NAMES=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  st="${line:0:2}"; path="${line:3}"
  case "$st" in
    '??') UNT=$((UNT + 1)) ;;
    *)
      MOD=$((MOD + 1))
      if git cat-file -e "$BASE_REF:$path" 2>/dev/null \
         && [ "$(git hash-object "$path" 2>/dev/null)" = "$(git rev-parse "$BASE_REF:$path" 2>/dev/null)" ]; then
        STALE=$((STALE + 1)); STALE_NAMES="$STALE_NAMES $path"
      fi
      ;;
  esac
done < <(git status --porcelain 2>/dev/null)

if [ "$STALE" -gt 0 ]; then
  row "git-worktree" drift \
      "$STALE tracked file(s) hold their base-commit content:$STALE_NAMES" \
      "the snapshot was restored from before the work landed; commit as-is and the push reverts it. Take the pushed version: git checkout -- <path>"
elif [ "$MOD" = 0 ] && [ "$UNT" = 0 ]; then
  row "git-worktree" ok "clean" "nothing uncommitted to lose at the next rollback"
elif [ "$HEAD_DRIFT" = 1 ]; then
  row "git-worktree" drift "$MOD tracked modification(s), $UNT untracked, none of them base-commit content" \
      "with HEAD off origin/$BRANCH these paths are most likely the pushed work sitting here uncommitted; fix git-head first (reset --mixed), then re-read this row — do not commit over it"
else
  row "git-worktree" ok "$MOD tracked modification(s), $UNT untracked — none of them base-commit content" \
      "ordinary work in progress; neither rollback signature is present"
fi

if [ -d "$ROOT/node_modules" ]; then
  NPKG="$(find "$ROOT/node_modules" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')"
  row "node-deps" ok "node_modules: $NPKG top-level packages" "tests, typecheck and the build can run"
else
  row "node-deps" drift "node_modules absent" \
      "npm ci --no-audit --no-fund is required before any TS check; the sandbox wipes it between turns, so every turn pays it again"
fi

NDAILY=0
[ -d "$ROOT/artifacts/ci/daily" ] && \
  NDAILY="$(find "$ROOT/artifacts/ci/daily" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
if [ -d "$ROOT/artifacts" ]; then
  row "artifacts" ok "artifacts/ present, $NDAILY daily run(s) recorded" \
      "daily.sh can compare this run with the previous one"
else
  row "artifacts" blocked "artifacts/ absent (gitignored, and wiped along with the sandbox)" \
      "no run history survives a turn boundary, so 'compared with the previous run' has nothing to compare and every measured duration has to be re-measured from scratch"
fi

# --- F. roadmap reachability -------------------------------------------------------

head_ "F · roadmap — what each open item would take to close"

# A heuristic, printed as one: every item is listed with the rule that matched it, so a reader
# can dispute a row by reading the row rather than by trusting the total. Rules are ordered
# most-specific first and the first match wins. `people` precedes `device` because a field
# test needs radios *and* a crowd, and the crowd is the part that cannot be provisioned;
# `toolchain` precedes `device` because "Mono-repo: app/ Flutter + transport/android" names a
# phone only as a build target, and what it actually needs is an SDK.
RULE_RE=(
  'Identity:|QR add-contact'
  'Legal:|privacy policy'
  'field test|real phones|crowd|external audit|community relay|public launch'
  'F-Droid|Play |TestFlight|Distribution|CI \+'
  'Flutter|Mono-repo|UI:|SDK|E2EE|panic wipe|Group UX|Onboarding|maps|Plugin API|analytics'
  'BLE|GATT|CoreBluetooth|WiFi Direct|WifiP2p|Multipeer|WiFi Aware|foreground service|Permissions|iOS|Android|Opus|Battery/performance'
)
RULE_CLS=(toolchain sandbox people store toolchain device)
RULE_WHY=(
  'the cryptography is built and tested in the TS reference (src/crypto/identity.ts); what remains is Dart and Flutter, which this machine cannot compile'
  'documents: the crypto-export note is already in docs/04 §7, and a privacy policy can be written and reviewed here'
  'needs people in a physical place (a field test, a crowd, an auditor, a launch)'
  'needs a store account and a signing key (Play, F-Droid, TestFlight) and CI minutes this account is refused'
  'needs the Flutter/Dart toolchain — and pub.dev — to build and test'
  'needs a radio or an OS API that only exists on a handset'
)
FALLTHROUGH_WHY='no rule matched: nothing here needs hardware, an account or a toolchain this machine lacks, so it can be written and verified from here'

CLASS_OF=(); CLASS_LINE=(); CLASS_TEXT=(); CLASS_RULE=()
N_OPEN=0; N_CLOSED=0
N_PEOPLE=0; N_STORE=0; N_DEVICE=0; N_TOOL=0; N_SANDBOX=0

if [ -f "$ROADMAP" ]; then
  N_CLOSED=$(grep -c '^\- \[x\]' "$ROADMAP" || true)
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    N_OPEN=$((N_OPEN + 1))
    ln="${entry%%:*}"; text="${entry#*:}"
    cls="sandbox"; why="$FALLTHROUGH_WHY"
    for r in "${!RULE_RE[@]}"; do
      if printf '%s' "$text" | grep -qiE "${RULE_RE[$r]}"; then
        cls="${RULE_CLS[$r]}"; why="${RULE_WHY[$r]}"; break
      fi
    done
    CLASS_OF+=("$cls"); CLASS_LINE+=("$ln"); CLASS_TEXT+=("$text"); CLASS_RULE+=("$why")
  done < <(grep -n '^\- \[ \]' "$ROADMAP")
else
  row "roadmap" unknown "roadmap/roadmap.md not found" "cannot say what is left"
fi

if [ "$N_OPEN" -gt 0 ]; then
  for c in "${CLASS_OF[@]}"; do
    case "$c" in
      people) N_PEOPLE=$((N_PEOPLE + 1)) ;; store) N_STORE=$((N_STORE + 1)) ;;
      device) N_DEVICE=$((N_DEVICE + 1)) ;; toolchain) N_TOOL=$((N_TOOL + 1)) ;;
      *) N_SANDBOX=$((N_SANDBOX + 1)) ;;
    esac
  done

  # The two tables are the evidence behind the `roadmap:open` row, so --quiet drops them and
  # keeps only the row itself: the summary is meant to be three lines, and 28 items are not.
  if [ "$QUIET" != 1 ]; then
    say ""
    say "  ${C_DIM}line  needs      item${C_RESET}"
    say "  --------------------------------------------------------------"
    for i in "${!CLASS_OF[@]}"; do
      t="${CLASS_TEXT[$i]#- \[ \] }"
      printf '  %-5s %-10s %s\n' "${CLASS_LINE[$i]}" "${CLASS_OF[$i]}" "${t:0:76}"
    done
    say ""
    say "  ${C_DIM}why each line got that class:${C_RESET}"
    for i in "${!CLASS_OF[@]}"; do
      printf '  %s%-5s%s %s\n' "${C_DIM}" "${CLASS_LINE[$i]}" "${C_RESET}" "${CLASS_RULE[$i]}"
    done
    say ""
  fi

  row "roadmap:open" blocked \
      "$N_OPEN open / $N_CLOSED closed — people $N_PEOPLE, store $N_STORE, device $N_DEVICE, toolchain $N_TOOL, reachable-from-here $N_SANDBOX" \
      "only the last class can be closed on this machine; the other $((N_OPEN - N_SANDBOX)) need hardware, a store account, a toolchain that is not installable here, or a crowd"
fi

# --- what the rows add up to ------------------------------------------------------
#
# Printed last, and built from the rows rather than written independently of them, so the
# narrative cannot drift away from the measurements above it. The one number that is read
# rather than measured is the cost of a verification pass, and it is read from the most
# recent daily run this machine has — or, when the sandbox has wiped it, the report says so
# instead of quoting a figure from a document.

LAST_RUN="(no daily run is recorded in artifacts/ — the sandbox wipes it — so the durations published in docs/10 §5 and §11 are the only ones this report can quote)"
if [ "$NDAILY" -gt 0 ] && have python3; then
  NEWEST_DIR="$(find "$ROOT/artifacts/ci/daily" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -1)"
  if [ -n "$NEWEST_DIR" ] && [ -f "$NEWEST_DIR/daily.json" ]; then
    LAST_RUN="$(python3 - "$NEWEST_DIR/daily.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
    print(f"the most recent daily run on this machine took {d.get('seconds', '?')} s: verdict "
          f"{d.get('verdict', '?')}, {d.get('passed', 0)} checks passed, "
          f"{d.get('notRun', 0)} could not run ({d.get('stamp', '?')})")
except Exception as exc:
    print(f"(the most recent daily run's record could not be read: {exc})")
PY
)"
  fi
fi

if [ "$QUIET" = 1 ]; then
  printf '%s\n' "${C_BOLD}summary${C_RESET}  $N_BLOCKED blocked · $N_DRIFT repairable-here · $N_OK ok · $N_UNKNOWN unknown  (${#ROW_NAME[@]} rows, $(stamp))"
  printf '%s\n' "${C_DIM}roadmap: $N_OPEN open, $N_CLOSED closed, $N_SANDBOX closable from here. Drop --quiet for the rows and the reasons.${C_RESET}"
fi

say ""
say "${C_BOLD}Why the work stops, in the order it costs time${C_RESET}"
say ""
say "  1. The verification pass competes with the work for the same hours. $LAST_RUN"
say "     Re-proving what was already proved is not free: a loop that pays it every round"
say "     builds less than a loop that builds and hands the proving to one daily job, which"
say "     is what tool/ci/daily.sh exists for and why the checks are collected into an"
say "     artifact instead of being run inline."
say ""
say "  2. The sandbox is rolled back between turns, and the rollback is not visible in the"
say "     repository. Section E is the signature: node_modules and artifacts/ wiped, and the"
say "     local .git reset to the branch point so the pushed work is present only as"
say "     uncommitted files — which then look like new work and can be committed over the top"
say "     of themselves. It has happened repeatedly on this branch, most recently at the start"
say "     of the turn that produced this report, and the repository cannot show a history of it"
say "     because the rollback removes the evidence too. Each occurrence costs a fetch, a"
say "     mixed reset, an npm ci and a re-run of the suite before anything new is written."
say ""
say "  3. What is left is not code that can be written here. Sections A-D are the reason: no"
say "     Dart or Flutter toolchain and no pub.dev, so the authoritative engine can never be"
say "     compiled on this machine; no radio, no handset, no macOS host; CI refused for"
say "     billing, so nothing is verified remotely either. Section F puts a number on it: of"
say "     the $N_OPEN open roadmap items, $N_SANDBOX can be closed from here, and the other"
say "     $((N_OPEN - N_SANDBOX)) need hardware, a store account, a toolchain, or fifteen people in a quad."
say "     skills/08 already forbids claiming large-scale results without that crowd test, so"
say "     the remainder is not deferred code. It is the part of this project that was never"
say "     going to happen inside a container, and the honest output here is the specification,"
say "     the simulator, the checks and the measurements for whoever has the phones."

[ "$QUIET" != 1 ] && printf '%s\n' "${C_BOLD}summary${C_RESET}  $N_BLOCKED blocked · $N_DRIFT repairable-here · $N_OK ok · $N_UNKNOWN unknown  (${#ROW_NAME[@]} rows, $(stamp))"

# --- JSON -------------------------------------------------------------------------

if [ -n "$JSON_OUT" ]; then
  have python3 || { err "--json needs python3"; exit 1; }
  d="$(dirname "$JSON_OUT")"; [ -d "$d" ] || mkdir -p "$d" || { err "cannot create $d"; exit 1; }
  {
    printf '%s\n' "{"
    printf '  "generatedAt": "%s",\n' "$(stamp)"
    printf '  "sha": "%s",\n' "$LOCAL_SHA"
    printf '  "branch": "%s",\n' "$BRANCH"
    printf '  "blocked": %s, "drift": %s, "ok": %s, "unknown": %s,\n' \
      "$N_BLOCKED" "$N_DRIFT" "$N_OK" "$N_UNKNOWN"
    printf '  "roadmap": {"open": %s, "closed": %s, "people": %s, "store": %s, "device": %s, "toolchain": %s, "reachableFromHere": %s},\n' \
      "$N_OPEN" "$N_CLOSED" "$N_PEOPLE" "$N_STORE" "$N_DEVICE" "$N_TOOL" "$N_SANDBOX"
    printf '  "driftRows": ['
    first=1
    for i in "${!ROW_NAME[@]}"; do
      [ "${ROW_STATUS[$i]}" = drift ] || continue
      [ "$first" = 1 ] && first=0 || printf ', '
      printf '"%s"' "${ROW_NAME[$i]}"
    done
    printf '],\n'
    printf '  "blockedRows": ['
    first=1
    for i in "${!ROW_NAME[@]}"; do
      [ "${ROW_STATUS[$i]}" = blocked ] || continue
      [ "$first" = 1 ] && first=0 || printf ', '
      printf '"%s"' "${ROW_NAME[$i]}"
    done
    printf '],\n'
    printf '  "rows": [\n'
    for i in "${!ROW_NAME[@]}"; do
      python3 -c '
import json, sys
name, status, evidence, cost = sys.argv[1:5]
print("    " + json.dumps({"name": name, "status": status, "evidence": evidence,
                          "cost": cost}, ensure_ascii=False), end="")
' "${ROW_NAME[$i]}" "${ROW_STATUS[$i]}" "${ROW_EVIDENCE[$i]}" "${ROW_COST[$i]}"
      [ "$i" -lt $((${#ROW_NAME[@]} - 1)) ] && printf ',\n' || printf '\n'
    done
    printf '  ]\n}\n'
  } > "$JSON_OUT"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$JSON_OUT" \
    || { err "wrote $JSON_OUT but it is not valid JSON"; exit 1; }
  [ "$QUIET" = 1 ] || log_dim "json: ${JSON_OUT#$ROOT/}"
fi

if [ "$STRICT" = 1 ] && [ "$N_DRIFT" -gt 0 ]; then
  err "$N_DRIFT row(s) this machine can fix are wrong — see section E"
  exit 3
fi
exit 0
