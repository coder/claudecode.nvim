#!/usr/bin/env bash
# shellcheck disable=SC2329,SC2034,SC2154 # helpers run through as_bool; covered_block sets, and coverage() reads, blocks by name
# Model-check the openDiff answer lifecycle against facts read from the code.
# Usage: check.sh [--mutants] [--keep] [--record] | check.sh --hash-only
#   exit 0 pass, 1 rule broken, 2 tool or script error, 3 stale (the covered code
#   changed since the model was last confirmed against it: unverified)
#   --hash-only compares covered.lock with the code and runs no TLC: exit 0 fresh, 2 error, 3 stale.
#   --record and --hash-only run no TLC, so they do not download it.
set -euo pipefail
export LC_ALL=C
if ((BASH_VERSINFO[0] < 4)); then
  echo "ERROR: check.sh needs bash 4 or newer, not $BASH_VERSION (on macOS: brew install bash)" >&2
  exit 2
fi

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
hash_only=0
for arg in "$@"; do
  case "$arg" in
  --mutants) mutants=1 ;;
  --keep) keep=1 ;;
  --record) record=1 ;;
  --hash-only) hash_only=1 ;;
  *)
    echo "usage: $0 [--mutants] [--keep] [--record] | $0 --hash-only" >&2
    exit 2
    ;;
  esac
done

if [[ $record == 1 && $mutants == 1 ]]; then
  echo "usage: --record cannot be combined with --mutants; run --mutants first, then --record" >&2
  exit 2
fi
if [[ $hash_only == 1 && $mutants$keep$record != 000 ]]; then
  echo "usage: --hash-only takes no other option" >&2
  exit 2
fi

tlc=1
[[ $hash_only == 0 && $record == 0 ]] || tlc=0

work=$(mktemp -d "${TMPDIR:-/tmp}/verify-diff-lifecycle.XXXXXX")
if [[ $keep == 1 ]]; then
  echo "work dir: $work"
else
  trap 'rm -rf "$work"' EXIT
fi

if [[ $tlc == 1 && ! -f $TLC_JAR ]]; then
  mkdir -p "$(dirname "$TLC_JAR")" || exit 2
  curl -fsSL -o "$TLC_JAR.tmp" "https://github.com/tlaplus/tlaplus/releases/download/v$TLC_VERSION/tla2tools.jar" || {
    echo "ERROR: could not download TLC $TLC_VERSION to $TLC_JAR" >&2
    exit 2
  }
  mv "$TLC_JAR.tmp" "$TLC_JAR"
fi
sha256() {
  if command -v sha256sum >/dev/null; then sha256sum; else shasum -a 256; fi
}
if [[ $tlc == 1 && $(sha256 <"$TLC_JAR" | cut -d' ' -f1) != "$TLC_SHA256" ]]; then
  echo "ERROR: $TLC_JAR does not match sha256 $TLC_SHA256" >&2
  exit 2
fi

# Print the block that starts at the first line matching $2 in file $1, up to the
# `end` at the same indentation.
block() {
  # Patterns go through ENVIRON: gawk processes backslash escapes in -v values, which breaks \(.
  RE=$2 awk '
    BEGIN { re = ENVIRON["RE"] }
    !found && $0 ~ re { found = 1; match($0, /^ */); indent = RLENGTH; print; next }
    found { print; if ($0 ~ "^" sprintf("%" indent "s", "") "end([ ,)]|$)") exit }
  ' "$1"
}

# True when the regexes match lines of stdin in this order.
in_order() {
  PATS=$(printf '%s\n' "$@") awk '
    BEGIN { n = split(ENVIRON["PATS"], p, "\n"); i = 1 }
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
CLOSE_TAB_TOOL=lua/claudecode/tools/close_tab.lua
CLOSE_ALL_TOOL=lua/claudecode/tools/close_all_diff_tabs.lua
CLIENT=lua/claudecode/server/client.lua

blocks=()
declare -A block_file
# covered_block NAME FILE REGEX: set $NAME to the block of FILE that starts at REGEX, and note it for the record.
covered_block() {
  blocks+=("$1")
  block_file[$1]=$2
  printf -v "$1" '%s' "$(block "$2" "$3")"
}
covered_block resolve_saved "$DIFF" '^function M\._resolve_diff_as_saved\('
covered_block resolve_rejected "$DIFF" '^function M\._resolve_diff_as_rejected\('
covered_block open_blocking "$DIFF" '^function M\.open_diff_blocking\('
covered_block setup_blocking "$DIFF" '^function M\._setup_blocking_diff\('
covered_block close_by_name "$DIFF" '^function M\.close_diff_by_tab_name\('
covered_block close_pending "$DIFF" '^function M\.close_pending_diffs\('
covered_block close_for_client "$DIFF" '^function M\.close_diffs_for_client\('
covered_block close_all "$DIFF" '^function M\.close_all_diffs\('
covered_block close_saved "$DIFF" '^function M\.close_saved_diffs\('
covered_block close_rejected "$DIFF" '^function M\.close_rejected_diffs\('
covered_block file_holds "$DIFF" '^local function file_holds_accepted_text\('
covered_block buffer_holds "$DIFF" '^local function buffer_holds_accepted_text\('
covered_block put_in_buffer "$DIFF" '^local function put_accepted_text_in_buffer\('
covered_block held_for_other "$DIFF" '^local function holds_edits_for_other_client\('
covered_block close_tab_tool "$CLOSE_TAB_TOOL" '^local function handler\(params, client\)'
covered_block close_all_tool "$CLOSE_ALL_TOOL" '^local function handler\(params, client\)'
covered_block create_client "$CLIENT" '^function M\.create_client\('
covered_block server_stop "$SERVER" '^function M\.stop\(\)'
covered_block on_disconnect "$SERVER" '^ *on_disconnect = function\('
covered_block handle_request "$SERVER" '^function M\._handle_request\('
covered_block setup_deferred "$SERVER" '^function M\._setup_deferred_response\('
covered_block user_close_all "$MAIN" 'nvim_create_user_command\("ClaudeCodeCloseAllDiffs"'
covered_block close_active "$DIFF" '^local function close_active_diffs\('
covered_block cleanup_all "$DIFF" '^function M\._cleanup_all_active_diffs\('
covered_block inline_saved "$INLINE" '^function M\.resolve_inline_as_saved\('
covered_block inline_rejected "$INLINE" '^function M\.resolve_inline_as_rejected\('
covered_block handle_invoke "$TOOLS" '^function M\.handle_invoke\('
covered_block open_diff_tool "$OPEN_DIFF_TOOL" '^local function handler\(params, client\)'
covered_block setup_inline "$INLINE" '^function M\.setup_inline_diff\('
covered_block accept_current "$DIFF" '^function M\.accept_current_diff\('
covered_block fire_event "$DIFF" '^local function fire_diff_event\('
covered_block register_state "$DIFF" '^function M\._register_diff_state\('
covered_block cleanup_state "$DIFF" '^function M\._cleanup_diff_state\('
covered_block diff_autocmds "$DIFF" '^local function register_diff_autocmds\('
covered_block deny_current "$DIFF" '^function M\.deny_current_diff\('

FACTS=(GuardSaved GuardRejected SenderCleared ReplaceRejects CloseTabRejectsPending CloseEachByName StopRejectsPending
  StopPendingOnly DisconnectRejects DisconnectPendingOnly UserCloseAllPendingOnly ClientTagged SetupAnswerReturned
  OpenedEventInSetup)
declare -A fact

as_bool() { if "$@"; then echo TRUE; else echo FALSE; fi; }

fact[GuardSaved]=$(as_bool in_order 'if not diff_data or diff_data\.status ~= "pending" then' '^ *return$' \
  'diff_data\.status = "saved"' <<<"$resolve_saved")
fact[GuardRejected]=$(as_bool in_order 'if not diff_data or diff_data\.status ~= "pending" then' '^ *return$' \
  'diff_data\.status = "rejected"' <<<"$resolve_rejected")
fact[SenderCleared]=$(as_bool in_order '_G\.claude_deferred_responses\[co_key\]\(' \
  '_G\.claude_deferred_responses\[co_key\] = nil' <<<"$open_blocking")
fact[ReplaceRejects]=$(as_bool in_order 'if active_diffs\[tab_name\] then' 'existing_diff\.status == "pending"' \
  'M\._resolve_diff_as_rejected\(tab_name\)' 'M\._cleanup_diff_state\(tab_name, "replaced by new diff"\)' \
  'coroutine\.running\(\)' <<<"$open_blocking")
fact[CloseTabRejectsPending]=$(as_bool in_order 'if diff_data\.status == "pending" then' \
  'M\._resolve_diff_as_rejected\(tab_name\)' 'M\._cleanup_diff_state\(tab_name' <<<"$close_by_name")
# A saved diff stays with the client it was accepted for: a replacing openDiff from another
# client errors, and close_tab and closeAllDiffTabs hand their caller to close_diff_by_tab_name.
FACTS+=(ReplaceKeepsOthersSaved CloseKeepsOthersSaved)
held_for_other_reads_owner() {
  grep -qE '^  return diff_data\.status == "saved" and diff_data\.client_id ~= nil and diff_data\.client_id ~= client_id$' \
    <<<"$held_for_other"
}
replace_keeps_others_saved() {
  held_for_other_reads_owner &&
    in_order 'if active_diffs\[tab_name\] then' 'if holds_edits_for_other_client\(existing_diff, client_id\) then' \
      '^ *error\(\{$' 'M\._cleanup_diff_state\(tab_name, "replaced by new diff"\)' <<<"$open_blocking"
}
fact[ReplaceKeepsOthersSaved]=$(as_bool replace_keeps_others_saved)
close_keeps_others_saved() {
  held_for_other_reads_owner &&
    in_order '^function M\.close_diff_by_tab_name\(tab_name, client_id\)$' \
      'if client_id and holds_edits_for_other_client\(diff_data, client_id\) then' '^ *return false$' \
      'M\._cleanup_diff_state\(tab_name' <<<"$close_by_name" &&
    grep -q 'M\.close_diff_by_tab_name(tab_name, client_id)' <<<"$close_active" &&
    grep -q 'return M\.build_response(pcall(tool_data\.handler, input, client))' <<<"$handle_invoke" &&
    grep -qE '^  return close_active_diffs\(nil, .*, client_id\)$' <<<"$close_all" &&
    grep -q 'diff\.close_all_diffs(".*", client and client\.id or nil)' <<<"$close_all_tool" &&
    grep -q 'diff\.close_diff_by_tab_name(tab_name, client and client\.id or nil)' <<<"$close_tab_tool"
}
fact[CloseKeepsOthersSaved]=$(as_bool close_keeps_others_saved)
fact[CloseEachByName]=$(as_bool in_order 'for _, tab_name in ipairs\(tab_names\) do' \
  'if (.* and )?M\.close_diff_by_tab_name\(tab_name(, client_id)?\) then' <<<"$close_active")
# A ClaudeCodeDiffClosed handler runs inside each close, so the loop must re-read the entry
# and rerun the snapshot's filter on it.
FACTS+=(CloseRechecksFilter)
close_rechecks_filter() {
  local snapshot=('local function matches\(diff_data\)'
    'return diff_data ~= nil and \(not filter_fn or filter_fn\(diff_data\)\)' 'if matches\(diff_data\) then'
    'for _, tab_name in ipairs\(tab_names\) do')
  in_order "${snapshot[@]}" 'if matches\(active_diffs\[tab_name\]\) and M\.close_diff_by_tab_name\(tab_name[,)]' \
    <<<"$close_active" ||
    in_order "${snapshot[@]}" '^    local diff_data = active_diffs\[tab_name\]$' \
      'if \(?matches\(diff_data\)( or rejected\))? and M\.close_diff_by_tab_name\(tab_name[,)]' <<<"$close_active"
}
fact[CloseRechecksFilter]=$(as_bool close_rechecks_filter)
# An entry that a handler rejected since the snapshot holds no edits and has its answer, so the loop closes it too.
FACTS+=(CloseTakesRejected)
fact[CloseTakesRejected]=$(as_bool in_order '^      listed\[tab_name\] = diff_data$' \
  'for _, tab_name in ipairs\(tab_names\) do' '^    local diff_data = active_diffs\[tab_name\]$' \
  '^    local rejected = diff_data == listed\[tab_name\] and diff_data\.status == "rejected"$' \
  'if \(matches\(diff_data\) or rejected\) and M\.close_diff_by_tab_name\(tab_name[,)]' <<<"$close_active")
# A saved diff outlives its client's connection, so a later connection must never get that client's id.
# The counter is a global so a reload of server/client.lua keeps it, and only create_client may set it.
FACTS+=(ClientIdsUnique)
client_ids_unique() {
  [[ $(grep -rEo '_G(\.claudecode_clients_created|\["claudecode_clients_created"\]) *=([^=]|$)|rawset\(_G, *"claudecode_clients_created"' lua plugin | wc -l) == 1 ]] &&
    in_order '^  _G\.claudecode_clients_created = \(_G\.claudecode_clients_created or 0\) \+ 1$' \
      '^  local client_id = "client_" \.\. _G\.claudecode_clients_created$' '^    id = client_id,$' <<<"$create_client"
}
fact[ClientIdsUnique]=$(as_bool client_ids_unique)
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
# The user's command closes a saved diff only through close_saved_diffs, whose filter reads the accepted text back
# from the file or from the file's buffer.
FACTS+=(UserCloseKeepsAcceptedText)
user_close_keeps_accepted_text() {
  grep -q 'diff\.close_saved_diffs(' <<<"$user_close_all" &&
    in_order 'close_active_diffs\(function\(diff_data\)$' '^    return diff_data\.status == "saved"$' \
      '^      and \(file_holds_accepted_text\(diff_data\) or buffer_holds_accepted_text\(diff_data\)\)$' \
      '^  end, reason or "close saved diffs"\)$' <<<"$close_saved" &&
    grep -qE '^  return read_file\(diff_data\.old_file_path\) == diff_data\.result_content\.content\[2\]\.text$' <<<"$file_holds" &&
    grep -q 'vim\.api\.nvim_buf_get_lines(buf, 0, -1, false)' <<<"$buffer_holds"
}
fact[UserCloseKeepsAcceptedText]=$(as_bool user_close_keeps_accepted_text)
# The user's command also closes rejected diffs: they hold no edits and Claude has their answer, and a client that
# exited never sends the close_tab that would close them.
FACTS+=(UserCloseTakesRejected)
user_close_takes_rejected() {
  grep -q 'diff\.close_rejected_diffs(' <<<"$user_close_all" &&
    grep -qE '^ *return diff_data\.status == "rejected"$' <<<"$close_rejected"
}
fact[UserCloseTakesRejected]=$(as_bool user_close_takes_rejected)
client_tagged() {
  grep -q 'return tool_data\.handler(input, client)' <<<"$handle_invoke" &&
    grep -q 'client and client\.id or nil' <<<"$open_diff_tool" &&
    grep -qE '^ *client_id = params\.client_id,$' <<<"$setup_blocking" &&
    grep -qE '^ *client_id = params\.client_id,$' <<<"$setup_inline"
}
fact[ClientTagged]=$(as_bool client_tagged)
# Before the yield, the resolution callback keeps its result instead of resuming
# the running coroutine, and open_diff_blocking returns that result.
setup_answer_returned() {
  in_order '^ *local waiting = false$' 'pcall\(M\._setup_blocking_diff' '^ *if not waiting then$' \
    '^ *setup_result = result$' '^ *return$' 'coroutine\.resume\(co, result\)' '^ *if setup_result then$' \
    '^ *return setup_result$' '^ *waiting = true$' 'coroutine\.yield\(\)' <<<"$open_blocking"
}
fact[SetupAnswerReturned]=$(as_bool setup_answer_returned)
# The ClaudeCodeDiffOpened event runs user handlers synchronously inside setup,
# before open_diff_blocking yields.
opened_event_in_setup() {
  grep -qE '^ *pcall\(vim\.api\.nvim_exec_autocmds, "User"' <<<"$fire_event" &&
    ! grep -q 'vim\.schedule\|defer_fn' <<<"$fire_event" &&
    grep -qE '^    fire_diff_event\("ClaudeCodeDiffOpened"' <<<"$setup_blocking" &&
    in_order 'pcall\(M\._setup_blocking_diff' 'coroutine\.yield\(\)' <<<"$open_blocking"
}
fact[OpenedEventInSetup]=$(as_bool opened_event_in_setup)

if [[ $hash_only == 0 ]]; then
  echo "== code facts (TRUE = guard present)"
  for f in "${FACTS[@]}"; do printf '  %-26s %s\n' "$f" "${fact[$f]}"; done
fi

# The coverage record: one group per Lua and Vimscript file under lua/ and plugin/, so any change to the plugin's
# Lua makes the run STALE until someone confirms the model still fits. A group holds the file's hash, the hashes of
# the covered blocks in it, and its call sites, which point the reader at what changed. Each group starts with a
# header line that only adding or removing the file changes. Git conflicts only on changes to the same or adjacent
# lines, so two branches that edit different files and re-record merge covered.lock without a conflict. Editing the
# same file, or adding or removing files whose groups sit next to each other, still conflicts.
SITE_RE='(_resolve_diff_as_|resolve_inline_as_|_cleanup_diff_state|_cleanup_all_active_diffs|close_[a-z_]*diffs|close_diff_by_tab_name|resolution_callback|claude_deferred_responses|_register_diff_state|active_diffs|_get_active_diffs|\.status *= *[^=])'
coverage() {
  local name file
  for name in "${blocks[@]}"; do
    [[ -n ${!name} ]] || {
      echo "ERROR: covered block $name not found; update its start regex in check.sh" >&2
      exit 2
    }
  done
  while IFS= read -r file; do
    printf '== %s\n' "$file"
    printf 'file %s %s\n' "$file" "$(sha256 <"$file" | cut -c1-16)"
    for name in "${blocks[@]}"; do
      [[ ${block_file[$name]} == "$file" ]] || continue
      printf 'block %-18s %s\n' "$name" "$(printf '%s\n' "${!name}" | sha256 | cut -c1-16)"
    done
    # Each site also names its enclosing top-level statement, so moving a call into another
    # function or autocmd changes the record.
    RE=$SITE_RE awk '
      BEGIN { re = ENVIRON["RE"] }
      /^[^[:space:]-]/ && !/^(end|else|elseif|return|[})])/ { top = $0 }
      $0 ~ re && $0 !~ /^[[:space:]]*--/ { line = $0; sub(/^[[:space:]]+/, "", line); print "site " FILENAME ": " line " @ " top }
    ' "$file" | sort
  done < <(find lua plugin \( -name '*.lua' -o -name '*.vim' \) | sort)
}
current=$(coverage)
if [[ $record == 1 ]]; then
  # A contributor checkout can make covered.lock a symlink to a script: never write through one.
  if [[ -L $LOCK || (-e $LOCK && ! -f $LOCK) ]]; then
    echo "ERROR: $LOCK is a symlink or not a regular file; refusing to write it" >&2
    exit 2
  fi
  tmp=$(mktemp "$here/.covered.lock.XXXXXX")
  printf '%s\n' "$current" >"$tmp"
  mv -f "$tmp" "$LOCK"
  echo "recorded $LOCK"
  exit 0
fi
stale=0
if [[ -L $LOCK ]]; then
  echo "ERROR: $LOCK is a symlink; the coverage record must be a regular file" >&2
  exit 2
fi
if [[ ! -f $LOCK ]] || ! diff -q "$LOCK" <(printf '%s\n' "$current") >/dev/null; then
  stale=1
  echo "== STALE: the covered code changed since covered.lock was recorded (git log -- covered.lock shows when)."
  echo "   UNVERIFIED: no result below covers these changes until you read them and update the model."
  { diff <(cat -- "$LOCK" 2>/dev/null) <(printf '%s\n' "$current") || true; } | grep -E '^[<>]' |
    sed -e 's/^</   was:/' -e 's/^>/   now:/' -e 's/[^[:print:]]/?/g'
fi
if [[ $hash_only == 1 ]]; then
  if [[ $stale == 1 ]]; then
    echo "== RESULT: STALE. Run .agents/skills/verify-diff-lifecycle/check.sh --record and commit covered.lock, or ask a maintainer to"
    exit 3
  fi
  echo "== RESULT: covered.lock matches the code"
  exit 0
fi

cp "$here/model/DiffLifecycle.tla" "$work/"

# run_tlc NAME "INVARIANTS" "PROPERTIES" [FACT=VALUE ...]
# Leaves TLC output in $work/NAME.out and returns TLC's exit code. Invariants run
# with three openDiff calls. The liveness property runs with two: its tableau
# makes three calls cost minutes.
run_tlc() {
  local name=$1 invariants=$2 properties=$3
  shift 3
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
    echo "  ClosedHandlerResolvesOther = TRUE"
    for f in "${FACTS[@]}"; do echo "  $f = ${vals[$f]}"; done
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

RULES_INV=(AtMostOneAnswer AnswerMatchesDiff NoStrandedCall SavedDiffKept NoRejectedLeftover)
ALL_INV="TypeOK ${RULES_INV[*]}"

if [[ $mutants == 1 ]]; then
  # Expected first-broken rule for each fact when only that guard is removed.
  declare -A expect=(
    [GuardSaved]=AnswerMatchesDiff [GuardRejected]=AnswerMatchesDiff
    [ReplaceRejects]=NoStrandedCall [CloseTabRejectsPending]=NoStrandedCall [CloseEachByName]=NoStrandedCall [StopRejectsPending]=NoStrandedCall
    [SetupAnswerReturned]=NoStrandedCall
    [StopPendingOnly]=SavedDiffKept [DisconnectPendingOnly]=SavedDiffKept [UserCloseAllPendingOnly]=SavedDiffKept
    [UserCloseKeepsAcceptedText]=SavedDiffKept
    [CloseTakesRejected]=NoRejectedLeftover [UserCloseTakesRejected]=NoRejectedLeftover
    [CloseRechecksFilter]=SavedDiffKept [ReplaceKeepsOthersSaved]=SavedDiffKept [CloseKeepsOthersSaved]=SavedDiffKept
    [ClientIdsUnique]=SavedDiffKept
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
        run_tlc "$name" "TypeOK" "$rule" "${assigns[@]}" || rc=$?
      else
        run_tlc "$name" "TypeOK $rule" "" "${assigns[@]}" || rc=$?
      fi
      case "$rc" in
      0) ;;
      12 | 13)
        # Exit 12 counts only when TLC names this rule: a TypeOK break means the model is wrong.
        if [[ $rc == 13 || $(broken_rule "$work/$name.out") == "$rule" ]]; then
          hits+=("$rule")
          rule_hit[$rule]=1
        else
          echo "  $f / $rule: TLC broke $(broken_rule "$work/$name.out") instead"
          status=2
        fi
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
  # OpenedEventInSetup is not a guard: FALSE only removes the handler step. SetupAnswerReturned=FALSE
  # is caught only through that step, so its row also shows that the step is reachable.
  [[ $status == 0 ]] && echo "== mutants: every guard is caught" || echo "== mutants: FAILED"
  if [[ $status == 0 && $stale == 1 ]]; then
    echo "== RESULT: STALE, UNVERIFIED (the mutants pass, but nobody has checked the model against the changed code)"
    exit 3
  fi
  exit "$status"
fi

result=0
echo "== model: code as written"
for run in main live; do
  rc=0
  if [[ $run == main ]]; then
    run_tlc main "$ALL_INV" "" || rc=$?
  else
    run_tlc live "TypeOK" "DisconnectedCallsAnswered" || rc=$?
  fi
  echo "  $run: $(describe "$run" "$rc")"
  if [[ $rc == 12 && $(broken_rule "$work/$run.out") == TypeOK ]]; then
    echo "  TypeOK broke: the model itself is wrong, not the code"
    show_trace "$run"
    exit 2
  elif [[ $rc == 12 || $rc == 13 ]]; then
    show_trace "$run"
    result=1
  elif [[ $rc != 0 ]]; then
    tail -20 "$work/$run.out" | sed 's/^/  /'
    exit 2
  fi
done

if [[ $result == 0 && $stale == 1 ]]; then
  echo "== RESULT: STALE, UNVERIFIED (the model passes, but nobody has checked it against the changed code)"
  exit 3
fi
[[ $result == 0 ]] && echo "== RESULT: PASS" || echo "== RESULT: FAIL"
exit "$result"
