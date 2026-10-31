#!/usr/bin/env bash
# shellcheck disable=SC2329,SC2034 # helpers run through as_bool; coverage() reads blocks by name
# Model-check the openDiff answer lifecycle against facts read from the code.
# Usage: check.sh [--mutants] [--keep] [--record]
#   exit 0 pass, 1 rule broken, 2 tool or script error, 3 stale (the covered code
#   changed since the model was last confirmed against it: unverified)
set -euo pipefail
export LC_ALL=C

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(git -C "$here" rev-parse --show-toplevel)
cd "$repo"

LOCK="$here/covered.lock"
TLC_VERSION=1.7.4
TLC_SHA256=936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88
TLC_JAR="${TLC_JAR:-${XDG_CACHE_HOME:-$HOME/.cache}/claudecode-nvim-tla/tla2tools-$TLC_VERSION.jar}"
JAVA="${JAVA:-java}"

mutants=0
keep=0
record=0
for arg in "$@"; do
  case "$arg" in
  --mutants) mutants=1 ;;
  --keep) keep=1 ;;
  --record) record=1 ;;
  *)
    echo "usage: $0 [--mutants] [--keep] [--record]" >&2
    exit 2
    ;;
  esac
done

work=$(mktemp -d "${TMPDIR:-/tmp}/verify-diff-lifecycle.XXXXXX")
if [[ $keep == 1 ]]; then
  echo "work dir: $work"
else
  trap 'rm -rf "$work"' EXIT
fi

if [[ ! -f $TLC_JAR ]]; then
  mkdir -p "$(dirname "$TLC_JAR")"
  curl -fsSL -o "$TLC_JAR.tmp" "https://github.com/tlaplus/tlaplus/releases/download/v$TLC_VERSION/tla2tools.jar"
  mv "$TLC_JAR.tmp" "$TLC_JAR"
fi
sha256() {
  if command -v sha256sum >/dev/null; then sha256sum; else shasum -a 256; fi
}
if [[ $(sha256 <"$TLC_JAR" | cut -d' ' -f1) != "$TLC_SHA256" ]]; then
  echo "ERROR: $TLC_JAR does not match sha256 $TLC_SHA256" >&2
  exit 2
fi

# Print the block that starts at the first line matching $2 in file $1, up to the
# `end` at the same indentation.
block() {
  awk -v re="$2" '
    !found && $0 ~ re { found = 1; match($0, /^ */); indent = RLENGTH; print; next }
    found { print; if ($0 ~ "^" sprintf("%" indent "s", "") "end([ ,)]|$)") exit }
  ' "$1"
}

# True when the regexes match lines of stdin in this order.
in_order() {
  awk -v pats="$(printf '%s\n' "$@")" '
    BEGIN { n = split(pats, p, "\n"); i = 1 }
    i <= n && $0 ~ p[i] { i++ }
    END { exit !(i > n) }
  '
}

DIFF=lua/claudecode/diff.lua
SERVER=lua/claudecode/server/init.lua
MAIN=lua/claudecode/init.lua
INLINE=lua/claudecode/diff_inline.lua
TOOLS=lua/claudecode/tools/init.lua
OPEN_DIFF_TOOL=lua/claudecode/tools/open_diff.lua

resolve_saved=$(block "$DIFF" '^function M\._resolve_diff_as_saved\(')
resolve_rejected=$(block "$DIFF" '^function M\._resolve_diff_as_rejected\(')
open_blocking=$(block "$DIFF" '^function M\.open_diff_blocking\(')
setup_blocking=$(block "$DIFF" '^function M\._setup_blocking_diff\(')
close_by_name=$(block "$DIFF" '^function M\.close_diff_by_tab_name\(')
close_pending=$(block "$DIFF" '^function M\.close_pending_diffs\(')
close_for_client=$(block "$DIFF" '^function M\.close_diffs_for_client\(')
server_stop=$(block "$SERVER" '^function M\.stop\(\)')
on_disconnect=$(block "$SERVER" '^ *on_disconnect = function\(')
handle_request=$(block "$SERVER" '^function M\._handle_request\(')
user_close_all=$(block "$MAIN" 'nvim_create_user_command\("ClaudeCodeCloseAllDiffs"')
close_active=$(block "$DIFF" '^local function close_active_diffs\(')
cleanup_all=$(block "$DIFF" '^function M\._cleanup_all_active_diffs\(')
inline_saved=$(block "$INLINE" '^function M\.resolve_inline_as_saved\(')
inline_rejected=$(block "$INLINE" '^function M\.resolve_inline_as_rejected\(')
handle_invoke=$(block "$TOOLS" '^function M\.handle_invoke\(')
open_diff_tool=$(block "$OPEN_DIFF_TOOL" '^local function handler\(params, client\)')
setup_inline=$(block "$INLINE" '^function M\.setup_inline_diff\(')
accept_current=$(block "$DIFF" '^function M\.accept_current_diff\(')
deny_current=$(block "$DIFF" '^function M\.deny_current_diff\(')

FACTS=(GuardSaved GuardRejected SenderCleared ReplaceRejects CloseTabRejectsPending CloseEachByName StopRejectsPending
  StopPendingOnly DisconnectRejects DisconnectPendingOnly UserCloseAllPendingOnly ClientTagged OpenedEventInSetup)
declare -A fact

as_bool() { if "$@"; then echo TRUE; else echo FALSE; fi; }

fact[GuardSaved]=$(as_bool in_order 'if not diff_data or diff_data\.status ~= "pending" then' '^ *return$' \
  'diff_data\.status = "saved"' <<<"$resolve_saved")
fact[GuardRejected]=$(as_bool in_order 'if not diff_data or diff_data\.status ~= "pending" then' '^ *return$' \
  'diff_data\.status = "rejected"' <<<"$resolve_rejected")
fact[SenderCleared]=$(as_bool test "$(grep -c '_G\.claude_deferred_responses\[co_key\] = nil' <<<"$open_blocking" || true)" -eq 2)
fact[ReplaceRejects]=$(as_bool in_order 'if active_diffs\[tab_name\] then' 'existing_diff\.status == "pending"' \
  'M\._resolve_diff_as_rejected\(tab_name\)' 'M\._cleanup_diff_state\(tab_name, "replaced by new diff"\)' \
  'coroutine\.running\(\)' <<<"$open_blocking")
fact[CloseTabRejectsPending]=$(as_bool in_order 'if diff_data\.status == "pending" then' \
  'M\._resolve_diff_as_rejected\(tab_name\)' 'M\._cleanup_diff_state\(tab_name' <<<"$close_by_name")
fact[CloseEachByName]=$(as_bool in_order 'for _, tab_name in ipairs\(tab_names\) do' \
  'if M\.close_diff_by_tab_name\(tab_name\) then' <<<"$close_active")
fact[StopRejectsPending]=$(as_bool in_order 'diff\.close_pending_diffs\(' 'tcp_server\.stop_server\(' \
  '_G\.claude_deferred_responses = \{\}' <<<"$server_stop")
fact[StopPendingOnly]=$(as_bool grep -qE '^ *return diff_data\.status == "pending"$' <<<"$close_pending")
fact[DisconnectRejects]=$(as_bool in_order 'vim\.schedule\(function\(\)' 'diff\.close_diffs_for_client\(client_id' \
  <<<"$on_disconnect")
fact[DisconnectPendingOnly]=$(as_bool grep -qE \
  '^ *return diff_data\.client_id == client_id and diff_data\.status == "pending"$' <<<"$close_for_client")
user_close_all_pending_only() {
  grep -q 'diff\.close_pending_diffs(' <<<"$user_close_all" && ! grep -q 'close_all_diffs' <<<"$user_close_all"
}
fact[UserCloseAllPendingOnly]=$(as_bool user_close_all_pending_only)
client_tagged() {
  grep -q 'return tool_data\.handler(input, client)' <<<"$handle_invoke" &&
    grep -q 'client and client\.id or nil' <<<"$open_diff_tool" &&
    grep -qE '^ *client_id = params\.client_id,$' <<<"$setup_blocking" &&
    grep -qE '^ *client_id = params\.client_id,$' <<<"$setup_inline"
}
fact[ClientTagged]=$(as_bool client_tagged)
# The ClaudeCodeDiffOpened event runs user handlers synchronously inside setup,
# the resolution callback resumes the coroutine without checking that it is
# suspended, and the server stores the response sender only after the yield.
opened_event_in_setup() {
  grep -qE '^    fire_diff_event\("ClaudeCodeDiffOpened"' <<<"$setup_blocking" &&
    in_order 'pcall\(M\._setup_blocking_diff' 'coroutine\.resume\(co, result\)' 'coroutine\.yield\(\)' \
      <<<"$open_blocking" &&
    ! grep -q 'coroutine\.status(co)' <<<"$open_blocking" &&
    in_order 'pcall\(handler, client, params\)' 'M\._setup_deferred_response\(deferred_info\)' <<<"$handle_request"
}
fact[OpenedEventInSetup]=$(as_bool opened_event_in_setup)

echo "== code facts (TRUE = guard present)"
for f in "${FACTS[@]}"; do printf '  %-24s %s\n' "$f" "${fact[$f]}"; done

# The coverage record: a hash of every block the model describes, plus every line
# under lua/ that resolves, closes, registers, or answers a diff, or writes a status. A changed block or
# a new caller makes the run STALE until someone confirms the model still fits.
SITE_RE='(_resolve_diff_as_|resolve_inline_as_|_cleanup_diff_state|_cleanup_all_active_diffs|close_[a-z_]*diffs|close_diff_by_tab_name|resolution_callback|claude_deferred_responses|_register_diff_state|active_diffs\[[^]]*\] *=[^=]|\.status *= *[^=])'
coverage() {
  local name
  for name in resolve_saved resolve_rejected open_blocking setup_blocking close_by_name close_pending \
    close_for_client close_active cleanup_all inline_saved inline_rejected server_stop on_disconnect \
    handle_request handle_invoke open_diff_tool setup_inline accept_current deny_current user_close_all; do
    [[ -n ${!name} ]] || {
      echo "ERROR: covered block $name not found; update its start regex in check.sh" >&2
      exit 2
    }
    printf 'block %-18s %s\n' "$name" "$(printf '%s\n' "${!name}" | sha256 | cut -c1-16)"
  done
  # Each site also names its enclosing top-level statement, so moving a call into another
  # function or autocmd changes the record.
  find lua -name '*.lua' -print0 | sort -z | xargs -0 awk -v re="$SITE_RE" '
    FNR == 1 { top = "" }
    /^[^[:space:]-]/ && !/^(end|else|elseif|return|[})])/ { top = $0 }
    $0 ~ re && $0 !~ /^[[:space:]]*--/ { line = $0; sub(/^[[:space:]]+/, "", line); print "site " FILENAME ": " line " @ " top }
  ' | sort
}
current=$(coverage)
if [[ $record == 1 ]]; then
  sync=$(git rev-parse HEAD)
  if base=$(git merge-base HEAD origin/main 2>/dev/null) && git diff --quiet "$base" HEAD -- lua/; then sync=$base; fi
  printf 'sync %s\n%s\n' "$sync" "$current" >"$LOCK"
  echo "recorded $LOCK at sync commit $sync"
  exit 0
fi
stale=0
if [[ ! -f $LOCK ]] || ! diff -q <(sed 1d "$LOCK") <(printf '%s\n' "$current") >/dev/null; then
  stale=1
  echo "== STALE: the covered code changed since commit $(head -1 "$LOCK" 2>/dev/null | cut -c6-17)."
  echo "   UNVERIFIED: no result below covers these changes until you read them and update the model."
  { diff <(sed 1d "$LOCK" 2>/dev/null) <(printf '%s\n' "$current") || true; } | grep -E '^[<>]' |
    sed -e 's/^</   was:/' -e 's/^>/   now:/'
fi

cp "$here/model/DiffLifecycle.tla" "$work/"

# run_tlc NAME HANDLER(TRUE/FALSE) "INVARIANTS" "PROPERTIES" [FACT=VALUE ...]
# Leaves TLC output in $work/NAME.out and returns TLC's exit code. Invariants run
# with three openDiff calls. The liveness property runs with two: its tableau
# makes three calls cost minutes.
run_tlc() {
  local name=$1 handler=$2 invariants=$3 properties=$4
  shift 4
  local -A vals
  local f kv
  for f in "${FACTS[@]}"; do vals[$f]=${fact[$f]}; done
  for kv in "$@"; do vals[${kv%%=*}]=${kv#*=}; done
  {
    echo "SPECIFICATION Spec"
    echo "CONSTANTS"
    if [[ -n $properties ]]; then echo "  Reqs = {r1, r2}"; else echo "  Reqs = {r1, r2, r3}"; fi
    echo "  Tabs = {t1, t2}"
    echo "  Clients = {c1, c2}"
    for f in "${FACTS[@]}"; do echo "  $f = ${vals[$f]}"; done
    echo "  UserHandlerResolvesDiff = $handler"
    [[ -n $invariants ]] && echo "INVARIANT $invariants"
    [[ -n $properties ]] && echo "PROPERTY $properties"
    echo "CONSTRAINT AnswerBound"
    echo "CHECK_DEADLOCK FALSE"
  } >"$work/$name.cfg"
  local rc=0
  (cd "$work" && "$JAVA" -Xmx4g -XX:+UseParallelGC -Djava.io.tmpdir="$work" -cp "$TLC_JAR" tlc2.TLC \
    -workers 1 -lncheck final -cleanup -metadir "$work/meta-$name" -config "$name.cfg" DiffLifecycle.tla) \
    >"$work/$name.out" 2>&1 || rc=$?
  return "$rc"
}

broken_rule() {
  grep -oE 'Invariant [A-Za-z]+ is violated' "$1" | head -1 | awk '{print $2}' ||
    true
}

describe() {
  local name=$1 rc=$2
  case "$rc" in
  0) echo "pass ($(grep -oE '[0-9,]+ distinct states found' "$work/$name.out" | tail -1))" ;;
  12) echo "BROKEN: $(broken_rule "$work/$name.out")" ;;
  13) echo "BROKEN: DisconnectedCallsAnswered (liveness)" ;;
  *) echo "TLC ERROR (exit $rc)" ;;
  esac
}

show_trace() {
  echo "  -- trace (actions in order; read it with /statechart for plain words):"
  grep -E '^State [0-9]+: |^[0-9]+: <|Back to state' "$work/$1.out" | sed 's/^/     /'
}

RULES_INV=(AtMostOneAnswer AnswerMatchesDiff NoStrandedCall SavedDiffKept)
ALL_INV="TypeOK ${RULES_INV[*]}"

if [[ $mutants == 1 ]]; then
  # Expected first-broken rule for each fact when only that guard is removed.
  declare -A expect=(
    [GuardSaved]=AnswerMatchesDiff [GuardRejected]=AnswerMatchesDiff
    [ReplaceRejects]=NoStrandedCall [CloseTabRejectsPending]=NoStrandedCall [CloseEachByName]=NoStrandedCall [StopRejectsPending]=NoStrandedCall
    [StopPendingOnly]=SavedDiffKept [DisconnectPendingOnly]=SavedDiffKept [UserCloseAllPendingOnly]=SavedDiffKept
    [DisconnectRejects]=DisconnectedCallsAnswered [ClientTagged]=DisconnectedCallsAnswered
  )
  status=0
  declare -A rule_hit
  echo "== mutants: each guard removed alone, each rule checked alone"
  for f in "${!expect[@]}" SenderCleared+GuardRejected; do
    hits=()
    assigns=()
    IFS=+ read -ra parts <<<"$f"
    for p in "${parts[@]}"; do assigns+=("$p=FALSE"); done
    for rule in "${RULES_INV[@]}" DisconnectedCallsAnswered; do
      name="mut-${f//+/-}-$rule"
      rc=0
      if [[ $rule == DisconnectedCallsAnswered ]]; then
        run_tlc "$name" FALSE "TypeOK" "$rule" "${assigns[@]}" || rc=$?
      else
        run_tlc "$name" FALSE "TypeOK $rule" "" "${assigns[@]}" || rc=$?
      fi
      case "$rc" in
      0) ;;
      12 | 13)
        hits+=("$rule")
        rule_hit[$rule]=1
        ;;
      *)
        echo "  $f / $rule: TLC ERROR (exit $rc)"
        tail -5 "$work/$name.out" | sed 's/^/    /'
        status=2
        ;;
      esac
    done
    want=${expect[$f]:-AtMostOneAnswer}
    if [[ " ${hits[*]} " == *" $want "* ]]; then
      printf '  %-30s caught by: %s\n' "$f=FALSE" "${hits[*]}"
    else
      printf '  %-30s NOT CAUGHT as expected (%s); broke: %s\n' "$f=FALSE" "$want" "${hits[*]:-nothing}"
      [[ $status == 2 ]] || status=1
    fi
  done
  for rule in "${RULES_INV[@]}" DisconnectedCallsAnswered; do
    if [[ -z ${rule_hit[$rule]:-} ]]; then
      echo "  rule $rule never broke: it is vacuous"
      [[ $status == 2 ]] || status=1
    fi
  done
  echo "  SenderCleared=FALSE alone is caught by nothing: the pending guards also stop a second answer."
  [[ $status == 0 ]] && echo "== mutants: every guard is caught" || echo "== mutants: FAILED"
  exit "$status"
fi

result=0
echo "== model: code as written, no user handler on ClaudeCodeDiffOpened"
for run in main live; do
  rc=0
  if [[ $run == main ]]; then
    run_tlc main FALSE "$ALL_INV" "" || rc=$?
  else
    run_tlc live FALSE "TypeOK" "DisconnectedCallsAnswered" || rc=$?
  fi
  echo "  $run: $(describe "$run" "$rc")"
  if [[ $rc == 12 || $rc == 13 ]]; then
    show_trace "$run"
    result=1
  elif [[ $rc != 0 ]]; then
    tail -20 "$work/$run.out" | sed 's/^/  /'
    exit 2
  fi
done

echo "== known finding: a ClaudeCodeDiffOpened handler closes or accepts the diff"
rc=0
run_tlc opened-handler TRUE "$ALL_INV" "" || rc=$?
echo "  $(describe opened-handler "$rc")"
case "$rc" in
12)
  if [[ $(broken_rule "$work/opened-handler.out") == NoStrandedCall ]]; then
    echo "  still reproduces (expected): Claude's openDiff call is never answered."
    show_trace opened-handler
  else
    echo "  a different rule broke: investigate"
    show_trace opened-handler
    result=1
  fi
  ;;
0)
  echo "  NO LONGER REPRODUCES: the code changed under OpenedEventInSetup. Model the fix, then retire this config."
  result=1
  ;;
*)
  tail -20 "$work/opened-handler.out" | sed 's/^/  /'
  exit 2
  ;;
esac

if [[ $result == 0 && $stale == 1 ]]; then
  echo "== RESULT: STALE, UNVERIFIED (the model passes, but nobody has checked it against the changed code)"
  exit 3
fi
[[ $result == 0 ]] && echo "== RESULT: PASS" || echo "== RESULT: FAIL"
exit "$result"
