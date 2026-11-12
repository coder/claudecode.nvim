#!/usr/bin/env bash
# shellcheck disable=SC2329,SC2034,SC2154 # helpers run through as_bool; covered_block sets blocks by name; the lib reads what this file sets
# Model-check the openDiff answer lifecycle against facts read from the code.
# Usage: check.sh [--mutants] [--keep] [--record] | check.sh --hash-only
#   exit 0 pass, 1 rule broken, 2 tool or script error, 3 stale (the covered code
#   changed since the model was last confirmed against it: unverified)
#   --hash-only compares covered.lock with the code and runs no TLC: exit 0 fresh, 2 error, 3 stale.
#   --record and --hash-only run no TLC, so they do not download it.
# The TLC pin, the option parsing, the TLC runs and the mutant loop live in scripts/tla/check-lib.sh.

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../../scripts/tla/check-lib.sh
source "$here/../../../scripts/tla/check-lib.sh"

SKILL=verify-diff-lifecycle
MODEL=DiffLifecycle
tla_init "$@"

DIFF=lua/claudecode/diff.lua
SERVER=lua/claudecode/server/init.lua
MAIN=lua/claudecode/init.lua
INLINE=lua/claudecode/diff_inline.lua
TOOLS=lua/claudecode/tools/init.lua
OPEN_DIFF_TOOL=lua/claudecode/tools/open_diff.lua
CLOSE_TAB_TOOL=lua/claudecode/tools/close_tab.lua
CLOSE_ALL_TOOL=lua/claudecode/tools/close_all_diff_tabs.lua
CLIENT=lua/claudecode/server/client.lua

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
covered_block reject_pending "$DIFF" '^function M\._reject_pending_diffs\('
covered_block exit_cleanup "$DIFF" '^local function cleanup_at_exit\('
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
covered_block write_proposal "$DIFF" '^function M\._write_proposal\('
covered_block reject_when_hidden "$DIFF" '^function M\._register_reject_when_hidden\('
covered_block deny_current "$DIFF" '^function M\.deny_current_diff\('

FACTS=(GuardSaved GuardRejected SenderCleared ReplaceRejects CloseTabRejectsPending CloseEachByName StopRejectsPending
  StopPendingOnly DisconnectRejects DisconnectPendingOnly UserCloseAllPendingOnly ClientTagged SetupAnswerReturned
  OpenedEventInSetup)

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
# At exit, a diff that no BufUnload rejected still gets its answer: the VimLeavePre autocmd rejects every pending diff
# before _cleanup_all_active_diffs removes any entry.
FACTS+=(ExitRejectsPending)
exit_rejects_pending() {
  in_order '^function M\._reject_pending_diffs\(\)$' 'diff_data\.status == "pending"' \
    'pcall\(M\._resolve_diff_as_rejected, entry\.tab_name\)' <<<"$reject_pending" &&
    in_order '^local function cleanup_at_exit\(\)$' '^  M\._reject_pending_diffs\(\)$' \
      '^  M\._cleanup_all_active_diffs\("shutdown"\)$' <<<"$exit_cleanup" &&
    in_order '^vim\.api\.nvim_create_autocmd\("VimLeavePre", \{$' '^  callback = cleanup_at_exit,$' <"$DIFF"
}
fact[ExitRejectsPending]=$(as_bool exit_rejects_pending)
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

# The coverage record: one group per Lua and Vimscript file under lua/ and plugin/, so any change to the plugin's
# Lua makes the run STALE until someone confirms the model still fits. A group holds the file's hash, the hashes of
# the covered blocks in it, and its call sites, which point the reader at what changed. Each group starts with a
# header line that only adding or removing the file changes. Git conflicts only on changes to the same or adjacent
# lines, so two branches that edit different files and re-record merge covered.lock without a conflict. Editing the
# same file, or adding or removing files whose groups sit next to each other, still conflicts.
mapfile -t COVERED < <(find lua plugin \( -name '*.lua' -o -name '*.vim' \) | sort)
SITE_RE='(_resolve_diff_as_|resolve_inline_as_|_cleanup_diff_state|_cleanup_all_active_diffs|close_[a-z_]*diffs|close_diff_by_tab_name|resolution_callback|claude_deferred_responses|_register_diff_state|active_diffs|_get_active_diffs|\.status *= *[^=])'

RULES=(AtMostOneAnswer AnswerMatchesDiff NoStrandedCall SavedDiffKept NoRejectedLeftover)
LIVE=(DisconnectedCallsAnswered)
CONSTRAINT=AnswerBound

# Expected first-broken rule for each fact when only that guard is removed. A+B removes both guards at once.
# "-" marks a fact that is not a guard: OpenedEventInSetup=FALSE only removes the handler step, and nothing catches
# it. SetupAnswerReturned=FALSE is caught only through that step, so its row also shows that the step is reachable.
EXPECT=(
  [GuardSaved]=AnswerMatchesDiff [GuardRejected]=AnswerMatchesDiff
  [ReplaceRejects]=NoStrandedCall [CloseTabRejectsPending]=NoStrandedCall [CloseEachByName]=NoStrandedCall [StopRejectsPending]=NoStrandedCall [ExitRejectsPending]=NoStrandedCall
  [SetupAnswerReturned]=NoStrandedCall
  [StopPendingOnly]=SavedDiffKept [DisconnectPendingOnly]=SavedDiffKept [UserCloseAllPendingOnly]=SavedDiffKept
  [UserCloseKeepsAcceptedText]=SavedDiffKept
  [CloseTakesRejected]=NoRejectedLeftover [UserCloseTakesRejected]=NoRejectedLeftover
  [CloseRechecksFilter]=SavedDiffKept [ReplaceKeepsOthersSaved]=SavedDiffKept [CloseKeepsOthersSaved]=SavedDiffKept
  [ClientIdsUnique]=SavedDiffKept
  [DisconnectRejects]=DisconnectedCallsAnswered [ClientTagged]=DisconnectedCallsAnswered
  ["SenderCleared+GuardRejected"]=AtMostOneAnswer
  [OpenedEventInSetup]=-
)
MUTANT_NOTES=("  SenderCleared=FALSE alone is caught by nothing: the pending guards also stop a second answer.")

# Invariants run with three openDiff calls. The liveness property runs with two: its tableau
# makes three calls cost minutes.
tla_constants() {
  local kind=$2
  if [[ $kind == live ]]; then echo "  Reqs = {r1, r2}"; else echo "  Reqs = {r1, r2, r3}"; fi
  echo "  Tabs = {t1, t2}"
  echo "  Clients = {c1, c2}"
  echo "  ClosedHandlerResolvesOther = TRUE"
}

tla_main "$@"
