#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154,SC2329 # check-lib.sh reads these; covered_block sets the block variables
# Model-check what Claude sees as the current selection (lua/claudecode/selection.lua) against facts read
# from the code.
# Usage: check.sh [--mutants] [--keep] [--record] | check.sh --hash-only
#   exit 0 pass, 1 rule broken, 2 tool or script error (or TypeOK broken), 3 stale
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SKILL=verify-selection-tracking MODEL=SelectionTracking
source "$here/../../../scripts/tla/check-lib.sh"
tla_init "$@"

SEL=lua/claudecode/selection.lua
MAIN=lua/claudecode/init.lua
SERVER=lua/claudecode/server/init.lua
CURRENT_TOOL=lua/claudecode/tools/get_current_selection.lua
LATEST_TOOL=lua/claudecode/tools/get_latest_selection.lua
COVERED=("$SEL" "$MAIN" "$SERVER" "$CURRENT_TOOL" "$LATEST_TOOL")
SITE_RE='(latest_selection|last_active_visual_selection|cursor_at_flush|visual_entry|debounce_timer|demotion_timer|send_selection_update|flush_visual_selection|update_selection|handle_selection_demotion|selection_tick|reconcile_held_selection|clear_held_state|selection_changed|selection\.(enable|disable))'

covered_block unmoved "$SEL" '^local function cursor_unmoved_since_flush\('
covered_block clear_held "$SEL" '^local function clear_held_state\('
covered_block text_there "$SEL" '^local function selection_text_is_there\('
covered_block demote_text "$SEL" '^local function demote_if_selection_text_changed\('
covered_block reconcile "$SEL" '^local function reconcile_held_selection\('
covered_block enable "$SEL" '^function M\.enable\('
covered_block disable "$SEL" '^function M\.disable\('
covered_block cancel_debounce "$SEL" '^function M\._cancel_debounce_timer\('
covered_block cancel_demotion "$SEL" '^function M\._cancel_demotion_timer\('
covered_block autocmds "$SEL" '^function M\._create_autocommands\('
covered_block on_cursor_moved "$SEL" '^function M\.on_cursor_moved\('
covered_block on_mode_changed "$SEL" '^function M\.on_mode_changed\('
covered_block on_text_changed "$SEL" '^function M\.on_text_changed\('
covered_block debounce_update "$SEL" '^function M\.debounce_update\('
covered_block update_selection "$SEL" '^function M\.update_selection\('
covered_block demotion "$SEL" '^function M\.handle_selection_demotion\('
covered_block from_marks "$SEL" '^function M\.get_visual_selection_from_marks\('
covered_block flush "$SEL" '^function M\.flush_visual_selection\('
covered_block changed "$SEL" '^function M\.has_selection_changed\('
covered_block send_update "$SEL" '^function M\.send_selection_update\('
covered_block get_latest "$SEL" '^function M\.get_latest_selection\('
covered_block is_terminal "$SEL" '^function M\.is_claude_terminal_buffer\('
covered_block start "$MAIN" '^function M\.start\('
covered_block stop "$MAIN" '^function M\.stop\('
covered_block broadcast "$SERVER" '^function M\.broadcast\('
covered_block on_connect "$SERVER" '^ *on_connect = function\(client\)'
covered_block current_tool "$CURRENT_TOOL" '^local function handler\('
covered_block latest_tool "$LATEST_TOOL" '^local function handler\('

FACTS=(FlushOnVisualExit FlushSkipsOperator FlushSkipsTerminal FlushRecordsCursor UpdateSkipsTerminal
  PendingKeepsHeld ElseClearsHeldState DemotionWaitsForMove DemotionClearsHeldState DebounceIgnoresStale
  DemotionIgnoresStale ClearsBeforeClose EntryClearsHeld FlushSkipReports PendingClearsHeld ReconcileOnCursorMoved
  ReconcileOnTextChanged TextChangeReports MoveReports LeaveNoted ReadRecordsTick)

# ModeChanged runs on_mode_changed, which flushes when visual mode ends.
flush_on_visual_exit() {
  in_order 'nvim_create_autocmd\("ModeChanged", \{' 'M\.on_mode_changed\(\)' <<<"$autocmds" &&
    in_order 'local leaving_visual = is_visual_mode\(event\.old_mode\) and not is_visual_mode\(event\.new_mode\)$' \
      '^    elseif leaving_visual then$' '^      M\.flush_visual_selection\(\)$' <<<"$on_mode_changed"
}
fact[FlushOnVisualExit]=$(as_bool flush_on_visual_exit)
# Entering visual mode records the changedtick; the flush returns when it moved (an operator consumed the selection).
flush_skips_operator() {
  in_order '^    if entering_visual then$' \
    '^      M\.state\.visual_entry = \{ bufnr = buf, tick = vim\.api\.nvim_buf_get_changedtick\(buf\) \}$' \
    <<<"$on_mode_changed" &&
    in_order '^  local entry = M\.state\.visual_entry$' \
      '^  if entry and entry\.bufnr == current_buf and vim\.api\.nvim_buf_get_changedtick\(current_buf\) ~= entry\.tick then$' \
      '^    return$' 'M\.get_visual_selection_from_marks\(\)' <<<"$flush"
}
fact[FlushSkipsOperator]=$(as_bool flush_skips_operator)
# Each terminal guard compares the current buffer with the active Claude terminal buffer and returns. The flush's next
# statement after its guard is `local entry`: a later `return` (the operator skip) must not stand in for the guard's.
fact[FlushSkipsTerminal]=$(as_bool in_order 'if M\.is_claude_terminal_buffer\(current_buf\) then' '^ *return$' \
  '^  local entry = M\.state\.visual_entry$' <<<"$flush")
fact[UpdateSkipsTerminal]=$(as_bool in_order 'if M\.is_claude_terminal_buffer\(current_buf\) then' 'M\._cancel_demotion_timer\(\)' '^ *return$' \
  '^  local current_mode_info = vim\.api\.nvim_get_mode\(\)$' <<<"$update_selection")
fact[FlushRecordsCursor]=$(as_bool in_order 'M\.get_visual_selection_from_marks\(\)' \
  '^  M\.state\.cursor_at_flush = \{ bufnr = current_buf, pos = vim\.api\.nvim_win_get_cursor\(0\) \}$' \
  'M\.send_selection_update\(selection\)' <<<"$flush")
# cursor_unmoved_since_flush compares the window cursor with cursor_at_flush in the same buffer.
unmoved_reads_flush() {
  in_order '^  local caf = M\.state\.cursor_at_flush$' '^  if not caf or caf\.bufnr ~= bufnr or caf\.left then$' \
    '^    return false$' '^  local pos = vim\.api\.nvim_win_get_cursor\(0\)$' \
    '^  return pos\[1\] == caf\.pos\[1\] and pos\[2\] == caf\.pos\[2\]$' <<<"$unmoved"
}
pending_keeps_held() {
  unmoved_reads_flush &&
    in_order '^    if M\.state\.demotion_timer then$' '^      if cursor_unmoved_since_flush\(current_buf\) then$' \
      '^        current_selection = M\.state\.latest_selection$' '^      else$' \
      '^        current_selection = M\.get_cursor_position\(\)$' <<<"$update_selection"
}
fact[PendingKeepsHeld]=$(as_bool pending_keeps_held)
fact[ElseClearsHeldState]=$(as_bool in_order 'M\.handle_selection_demotion\(current_buf\)' '^    else$' \
  '^      current_selection = M\.get_cursor_position\(\)$' '^      M\.state\.last_active_visual_selection = nil$' \
  '^      M\.state\.cursor_at_flush = nil$' '^  end$' <<<"$update_selection")
demotion_waits_for_move() {
  unmoved_reads_flush &&
    in_order '^  if current_buf == original_bufnr_when_scheduled then$' \
      '^    if cursor_unmoved_since_flush\(current_buf\) then$' '^      return$' \
      '^    local new_sel_for_demotion = M\.get_cursor_position\(\)$' <<<"$demotion"
}
fact[DemotionWaitsForMove]=$(as_bool demotion_waits_for_move)
fact[DemotionClearsHeldState]=$(as_bool in_order 'M\.send_selection_update\(M\.state\.latest_selection\)' \
  'M\.state\.last_active_visual_selection\.bufnr == original_bufnr_when_scheduled' \
  '^    M\.state\.last_active_visual_selection = nil$' \
  '^  if M\.state\.cursor_at_flush and M\.state\.cursor_at_flush\.bufnr == original_bufnr_when_scheduled then$' \
  '^    M\.state\.cursor_at_flush = nil$' <<<"$demotion")
# Each timer callback returns unless its timer is still the one in M.state.
fact[DebounceIgnoresStale]=$(as_bool in_order 'vim\.schedule_wrap\(function\(\)' \
  '^      if M\.state\.debounce_timer ~= timer then$' '^        return$' 'timer:close\(\)' \
  'M\.update_selection\(\)' <<<"$debounce_update")
fact[DemotionIgnoresStale]=$(as_bool in_order 'vim\.schedule_wrap\(function\(\)' \
  '^          if M\.state\.demotion_timer ~= timer then$' '^            return$' 'timer:close\(\)' \
  'M\.handle_selection_demotion\(current_buf\)' <<<"$update_selection")
# Both cancel functions and both callbacks clear the state field before timer:close().
clears_before_close() {
  in_order '^  M\.state\.debounce_timer = nil$' '^  timer:close\(\)$' <<<"$cancel_debounce" &&
    in_order '^  M\.state\.demotion_timer = nil$' '^  timer:close\(\)$' <<<"$cancel_demotion" &&
    in_order 'if M\.state\.debounce_timer ~= timer then' '^      M\.state\.debounce_timer = nil$' \
      '^      timer:close\(\)$' <<<"$debounce_update" &&
    in_order 'if M\.state\.demotion_timer ~= timer then' '^          M\.state\.demotion_timer = nil$' \
      '^          timer:close\(\)$' <<<"$update_selection"
}
fact[ClearsBeforeClose]=$(as_bool clears_before_close)

# clear_held_state() forgets both records of a held selection.
clear_held_clears_both() {
  in_order '^  M\.state\.last_active_visual_selection = nil$' '^  M\.state\.cursor_at_flush = nil$' <<<"$clear_held"
}
# A new visual selection replaces the held one, except in the Claude terminal.
entry_clears_held() {
  clear_held_clears_both &&
    in_order '^    if entering_visual then$' '^      if not M\.is_claude_terminal_buffer\(buf\) then$' '^        clear_held_state\(\)$' \
      '^    elseif leaving_visual then$' <<<"$on_mode_changed"
}
fact[EntryClearsHeld]=$(as_bool entry_clears_held)
# A flush skipped for an operator forgets the held selection and reports the cursor when Claude holds a selection.
flush_skip_reports() {
  clear_held_clears_both &&
    in_order '^  local entry = M\.state\.visual_entry$' '~= entry\.tick then$' '^    clear_held_state\(\)$' \
      '^    local held = M\.state\.latest_selection$' '^    if held and not held\.selection\.isEmpty then$' '^      M\.update_selection\(\)$' \
      '^    return$' 'M\.get_visual_selection_from_marks\(\)' <<<"$flush"
}
fact[FlushSkipReports]=$(as_bool flush_skip_reports)
# The pending-demotion branch ends the hold when it reports the cursor.
pending_clears_held() {
  clear_held_clears_both &&
    in_order '^    if M\.state\.demotion_timer then$' '^      if cursor_unmoved_since_flush\(current_buf\) then$' '^      else$' \
      '^        current_selection = M\.get_cursor_position\(\)$' '^        clear_held_state\(\)$' <<<"$update_selection"
}
fact[PendingClearsHeld]=$(as_bool pending_clears_held)
# The two autocmd handlers call reconcile_held_selection. The BufEnter autocmd says so, because the window cursor is
# not restored yet then.
reconcile_on_cursor_moved() {
  in_order '^  reconcile_held_selection\(not entered_buffer\)$' '^  M\.debounce_update\(\)$' <<<"$on_cursor_moved" &&
    in_order 'nvim_create_autocmd\(\{ "CursorMoved", "CursorMovedI", "BufEnter" \}' 'M\.on_cursor_moved\(args\.event == "BufEnter"\)' \
      <<<"$autocmds"
}
fact[ReconcileOnCursorMoved]=$(as_bool reconcile_on_cursor_moved)
reconcile_on_text_changed() {
  in_order '^  reconcile_held_selection\(true\)$' '^  M\.debounce_update\(\)$' <<<"$on_text_changed" &&
    in_order 'nvim_create_autocmd\(\{ "TextChanged", ' 'M\.on_text_changed\(\)' <<<"$autocmds"
}
fact[ReconcileOnTextChanged]=$(as_bool reconcile_on_text_changed)
# reconcile_held_selection first reports the cursor when the changedtick moved since the selection was read and its
# text is no longer at its range.
text_change_reports() {
  clear_held_clears_both &&
    in_order '^  if demote_if_selection_text_changed\(\) then$' '^    return$' <<<"$reconcile" &&
    in_order 'read\.bufnr ~= current_buf or vim\.api\.nvim_buf_get_changedtick\(current_buf\) == read\.tick then' \
      '^  if selection_text_is_there\(held, current_buf\) then$' '^    return false$' '^  clear_held_state\(\)$' \
      '^  M\.update_selection\(\)$' '^  return true$' <<<"$demote_text"
}
fact[TextChangeReports]=$(as_bool text_change_reports)
# A cursor that left the flushed position is reported at once.
move_reports() {
  clear_held_clears_both &&
    in_order '^  elseif compare_cursor and not cursor_unmoved_since_flush\(current_buf\) then$' '^    clear_held_state\(\)$' \
      '^    M\.update_selection\(\)$' <<<"$reconcile"
}
fact[MoveReports]=$(as_bool move_reports)
# Another buffer entered is noted in cursor_at_flush.away and decided at the next event: the Claude terminal keeps the
# hold, any other buffer sets cursor_at_flush.left, which cursor_unmoved_since_flush reads.
leave_noted() {
  unmoved_reads_flush &&
    in_order '^  if caf\.away and caf\.away ~= current_buf then$' '^    if not M\.is_claude_terminal_buffer\(caf\.away\) then$' \
      '^      caf\.left = true$' '^  elseif caf\.bufnr ~= current_buf then$' '^    caf\.away = current_buf$' <<<"$reconcile"
}
fact[LeaveNoted]=$(as_bool leave_noted)
# The flush and the in-visual update record the buffer and changedtick of the selection they read.
read_records_tick() {
  in_order '^  M\.state\.cursor_at_flush = \{' \
    '^  M\.state\.selection_tick = \{ bufnr = current_buf, tick = vim\.api\.nvim_buf_get_changedtick\(current_buf\) \}$' \
    'M\.send_selection_update\(selection\)' <<<"$flush" &&
    in_order 'M\.state\.last_active_visual_selection = \{' \
      '^      M\.state\.selection_tick = \{ bufnr = current_buf, tick = vim\.api\.nvim_buf_get_changedtick\(current_buf\) \}$' \
      '^    else$' <<<"$update_selection"
}
fact[ReadRecordsTick]=$(as_bool read_records_tick)

RULES=(ReleaseSent NoPhantomSelection NoTerminalSelection HeldUntilMoved HeldEndsWhenMoved SameFile ClaudeSeesCursor
  NoDeletedText TimerClosedOnce)
LIVE=()
# Four guards break no rule alone, because another guard in the code covers for them. EXPECT lists each with a guard
# that covers for it (a "+" key sets both FALSE) and the rule that breaks when both go.
EXPECT=(
  [FlushOnVisualExit]=ReleaseSent [FlushSkipsOperator]=NoPhantomSelection
  [FlushSkipsTerminal]=NoTerminalSelection [UpdateSkipsTerminal]=NoTerminalSelection
  [FlushRecordsCursor]=HeldUntilMoved [PendingKeepsHeld]=HeldUntilMoved [DemotionWaitsForMove]=HeldUntilMoved
  [DebounceIgnoresStale]=TimerClosedOnce [DemotionIgnoresStale]=TimerClosedOnce [ClearsBeforeClose]=TimerClosedOnce
  [FlushSkipReports]=NoDeletedText [ReadRecordsTick]=NoDeletedText [TextChangeReports]=NoDeletedText
  [ReconcileOnTextChanged]=NoDeletedText [ReconcileOnCursorMoved]=HeldEndsWhenMoved [MoveReports]=HeldEndsWhenMoved
  [LeaveNoted]=HeldEndsWhenMoved
  ["DemotionClearsHeldState+MoveReports"]=ClaudeSeesCursor
  ["PendingClearsHeld+ReconcileOnCursorMoved"]=ClaudeSeesCursor
  ["ElseClearsHeldState+LeaveNoted"]=SameFile
  ["EntryClearsHeld+FlushSkipReports"]=HeldEndsWhenMoved
)

# The main run explores any visual_demotion_delay_ms with two files. Two rules need a second file in their mutant runs:
# SameFile, and HeldEndsWhenMoved (LeaveNoted breaks it only when the user can visit another file).
# DelayBelowDebounce stays FALSE: TRUE would drop every order in which a demotion timer fires after a later debounce.
tla_constants() {
  local rule=${1##*-} files="f1"
  [[ $1 != main && $rule != SameFile && $rule != HeldEndsWhenMoved ]] || files="f1, f2"
  echo "  Files = {$files}"
  echo "  Term = term"
  echo "  Pos = {p1, p2}"
  echo "  Ranges = {r1, r2}"
  echo "  None = none"
  echo "  MaxEdits = 1"
  echo "  DelayBelowDebounce = FALSE"
  echo "  WithTerminal = TRUE"
}
tla_main
