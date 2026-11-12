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
SITE_RE='(latest_selection|last_active_visual_selection|cursor_at_flush|visual_entry|debounce_timer|demotion_timer|send_selection_update|flush_visual_selection|update_selection|handle_selection_demotion|selection_tick|watched_buffers|watch_selection_buffer|record_selection_read|reconcile_held_selection|clear_held_state|selection_changed|selection\.(enable|disable))'

covered_block unmoved "$SEL" '^local function cursor_unmoved_since_flush\('
covered_block clear_held "$SEL" '^local function clear_held_state\('
covered_block text_there "$SEL" '^local function selection_text_is_there\('
covered_block cursor_other "$SEL" '^local function cursor_in_other_buffer\('
covered_block demote_text "$SEL" '^local function demote_if_selection_text_changed\('
covered_block holds_selection "$SEL" '^local function holds_selection_of\('
covered_block entry_of "$SEL" '^local function visual_entry_of\('
covered_block note_edit "$SEL" '^local function note_visual_edit\('
covered_block check_edits "$SEL" '^local function check_visual_edits\('
covered_block watch_buffer "$SEL" '^local function watch_selection_buffer\('
covered_block record_read "$SEL" '^local function record_selection_read\('
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
  ReconcileOnTextChanged TextChangeReports MoveReports LeaveNoted ReadRecordsTick ListensToSelectionBuffer
  TerminalReportsHeldBuffer UpdateChecksHeldText ListenerNotesVisualEdit VisualCheckSparesPluginEdit FlushIgnoresTick)

# ModeChanged runs on_mode_changed, which flushes when visual mode ends.
flush_on_visual_exit() {
  in_order '^  vim\.api\.nvim_create_autocmd\("ModeChanged", \{$' '^      M\.on_mode_changed\(\)$' <<<"$autocmds" &&
    in_order 'local leaving_visual = is_visual_mode\(event\.old_mode\) and not is_visual_mode\(event\.new_mode\)$' \
      '^    elseif leaving_visual then$' '^      M\.flush_visual_selection\(\)$' <<<"$on_mode_changed"
}
fact[FlushOnVisualExit]=$(as_bool flush_on_visual_exit)
# Entering visual mode makes a visual_entry. The flush returns when the entry is consumed or has an edit that the listener
# counted and no check has cleared yet (an operator such as d: its edit comes before the ModeChanged that flushes).
flush_skips_operator() {
  in_order '^    if entering_visual then$' \
    '^      M\.state\.visual_entry = \{ bufnr = buf, consumed = false, unchecked_edits = 0 \}$' \
    <<<"$on_mode_changed" &&
    in_order '^  local entry = M\.state\.visual_entry$' \
      '^  if entry and entry\.bufnr == current_buf and \(entry\.consumed or entry\.unchecked_edits > 0\) then$' \
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
    in_order 'vim\.schedule_wrap\(function\(\)' '^      M\.state\.debounce_timer = nil$' \
      '^      timer:close\(\)$' <<<"$debounce_update" &&
    in_order 'vim\.schedule_wrap\(function\(\)' '^          M\.state\.demotion_timer = nil$' \
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
    in_order '^  local entry = M\.state\.visual_entry$' '^    clear_held_state\(\)$' \
      '^    local held = M\.state\.latest_selection$' '^    if held and not held\.selection\.isEmpty then$' '^      M\.update_selection\(\)$' \
      '^    return$' 'M\.get_visual_selection_from_marks\(\)' <<<"$flush"
}
fact[FlushSkipReports]=$(as_bool flush_skip_reports)
# The pending-demotion branch ends the hold when it reports the cursor.
pending_clears_held() {
  clear_held_clears_both &&
    in_order '^    if M\.state\.demotion_timer then$' '^      else$' \
      '^        current_selection = M\.get_cursor_position\(\)$' '^        clear_held_state\(\)$' <<<"$update_selection"
}
fact[PendingClearsHeld]=$(as_bool pending_clears_held)
# The two autocmd handlers call reconcile_held_selection. The BufEnter autocmd says so, because the window cursor is
# not restored yet then.
reconcile_on_cursor_moved() {
  in_order '^  reconcile_held_selection\(not entered_buffer\)$' '^  M\.debounce_update\(\)$' <<<"$on_cursor_moved" &&
    in_order '^  vim\.api\.nvim_create_autocmd\(\{ "CursorMoved", "CursorMovedI", "BufEnter" \}, \{$' \
      '^      M\.on_cursor_moved\(args\.event == "BufEnter"\)$' <<<"$autocmds"
}
fact[ReconcileOnCursorMoved]=$(as_bool reconcile_on_cursor_moved)
reconcile_on_text_changed() {
  in_order '^  reconcile_held_selection\(true\)$' '^  M\.debounce_update\(\)$' <<<"$on_text_changed" &&
    in_order '^  vim\.api\.nvim_create_autocmd\(\{ "TextChanged", "TextChangedI", "TextChangedP" \}, \{$' '^      M\.on_text_changed\(\)$' <<<"$autocmds"
}
fact[ReconcileOnTextChanged]=$(as_bool reconcile_on_text_changed)
# reconcile_held_selection first reports the cursor when the changedtick moved since the selection was read and its
# text is no longer at its range.
text_change_reports() {
  clear_held_clears_both &&
    in_order '^  if demote_if_selection_text_changed\(\) then$' '^    return$' <<<"$reconcile" &&
    in_order '^  if vim\.api\.nvim_buf_get_changedtick\(read\.bufnr\) == read\.tick or selection_text_is_there\(held, read\.bufnr\) then$' \
      '^    return false$' '^  clear_held_state\(\)$' '^    M\.update_selection\(\)$' '^  return true$' <<<"$demote_text"
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
# The flush and the in-visual update call record_selection_read, which records the buffer and changedtick of the
# selection they read.
read_records_tick() {
  in_order 'M\.get_visual_selection_from_marks\(\)' '^  record_selection_read\(current_buf\)$' \
    'M\.send_selection_update\(selection\)' <<<"$flush" &&
    in_order 'M\.state\.last_active_visual_selection = \{' '^      record_selection_read\(current_buf\)$' \
      '^    else$' <<<"$update_selection" &&
    in_order '^  M\.state\.selection_tick = \{ bufnr = bufnr, tick = vim\.api\.nvim_buf_get_changedtick\(bufnr\) \}$' <<<"$record_read"
}
fact[ReadRecordsTick]=$(as_bool read_records_tick)
# record_selection_read listens to the buffer it records, and the listener schedules the check when the buffer changes
# (a reload or a plugin's edit: TextChanged fires only for the current buffer).
# on_lines and on_reload call check_soon while the buffer holds the selection. Since #524 on_lines does it in the branch of
# `if holds_selection_of(buf) then` (its `elseif not entry` branch detaches the listener, and a check_soon there would
# check nothing it holds), and before #524 it did it after the `if not holds_selection_of(buf) then ... return true end` that
# detaches.
listens_to_selection_buffer() {
  # Each listener is read inside its own body (up to the next `    end,`), so a check_soon that moved into on_detach does
  # not count for on_reload.
  local on_lines on_reload
  on_lines=$(sed -n '/^    on_lines = function(_, buf)$/,/^    end,$/p' <<<"$watch_buffer")
  on_reload=$(sed -n '/^    on_reload = function(_, buf)$/,/^    end,$/p' <<<"$watch_buffer")
  in_order '^  watch_selection_buffer\(bufnr\)$' <<<"$record_read" &&
    in_order '^  local function check_soon\(\)$' 'vim\.schedule\(function\(\)' '^        demote_if_selection_text_changed\(\)$' \
      '^  vim\.api\.nvim_buf_attach\(bufnr, false, \{$' <<<"$watch_buffer" &&
    {
      in_order '^      if holds_selection_of\(buf\) then$' '^        check_soon\(\)$' '^      elseif not entry then$' <<<"$on_lines" ||
        in_order '^      if not holds_selection_of\(buf\) then$' '^      check_soon\(\)$' <<<"$on_lines"
    } &&
    in_order '^ *check_soon\(\)$' <<<"$on_reload"
}
fact[ListensToSelectionBuffer]=$(as_bool listens_to_selection_buffer)
# The check runs in the Claude terminal for a selection of another buffer that is not a Claude terminal, clears the held
# state and sends the cursor of that buffer: update_selection does nothing in the terminal.
terminal_reports_held_buffer() {
  clear_held_clears_both &&
    in_order '^  local in_terminal = M\.is_claude_terminal_buffer\(current_buf\)$' \
      '^  if read\.bufnr ~= current_buf and not in_terminal then$' '^    return false$' \
      '^  local from_terminal = read\.bufnr ~= current_buf and not M\.is_claude_terminal_buffer\(read\.bufnr\)$' \
      '^  local cursor = from_terminal and cursor_in_other_buffer\(read\.bufnr\)$' '^  clear_held_state\(\)$' '^  if cursor then$' \
      '^      M\.state\.latest_selection = cursor$' '^        M\.send_selection_update\(cursor\)$' <<<"$demote_text"
}
fact[TerminalReportsHeldBuffer]=$(as_bool terminal_reports_held_buffer)
# update_selection in the Claude terminal also runs that check: a new terminal is not registered when BufEnter fires.
update_checks_held_text() {
  in_order '^    M\._cancel_demotion_timer\(\)$' '^    demote_if_selection_text_changed\(\)$' <<<"$update_selection"
}
fact[UpdateChecksHeldText]=$(as_bool update_checks_held_text)
# Entering visual mode in a buffer that is not the Claude terminal listens to it, and the listener's on_lines counts an edit
# on the visual_entry of that buffer: visual_entry_of finds it, note_visual_edit adds one to unchecked_edits.
listener_notes_visual_edit() {
  in_order '^    if entering_visual then$' '^      if not M\.is_claude_terminal_buffer\(buf\) then$' '^        watch_selection_buffer\(buf\)$' \
    '^    elseif leaving_visual then$' <<<"$on_mode_changed" &&
    in_order '^  local entry = M\.state\.visual_entry$' '^  return entry and entry\.bufnr == bufnr and entry or nil$' <<<"$entry_of" &&
    in_order '^    on_lines = function\(_, buf\)$' '^      local entry = visual_entry_of\(buf\)$' '^      if entry then$' \
      '^        note_visual_edit\(entry\)$' '^    on_reload = function\(_, buf\)$' <<<"$watch_buffer" &&
    in_order '^  entry\.unchecked_edits = entry\.unchecked_edits \+ 1$' <<<"$note_edit"
}
fact[ListenerNotesVisualEdit]=$(as_bool listener_notes_visual_edit)
# check_visual_edits takes the counted edits back and marks the entry consumed only when visual mode is over: a plugin's edit
# leaves the selection on the screen and does not consume it. note_visual_edit runs that check from vim.schedule and from a
# vim.on_key listener, whichever comes first, so it runs before the flush of the next Esc also when a mapping, a macro or
# a callback that is already running gets the key in first. Without either trigger an edit that nobody checked reaches the flush.
visual_check_spares_plugin_edit() {
  in_order '^  entry\.unchecked_edits = 0$' '^  if not is_visual_mode\(vim\.api\.nvim_get_mode\(\)\.mode\) then$' \
    '^    entry\.consumed = true$' <<<"$check_edits" &&
    in_order '^  vim\.schedule\(function\(\)$' '^    check_visual_edits\(entry\)$' '^  vim\.on_key\(function\(\)$' \
      '^    check_visual_edits\(entry\)$' <<<"$note_edit"
}
fact[VisualCheckSparesPluginEdit]=$(as_bool visual_check_spares_plugin_edit)
# Neither on_mode_changed nor the flush reads a changedtick (comments apart). The code before #524 compared the changedtick
# with the one it recorded at visual entry, which took a plugin's edit or a :write for an operator.
flush_ignores_tick() {
  ! awk '!/^ *--/ && /changedtick/ { found = 1 } END { exit !found }' <<<"$on_mode_changed"$'\n'"$flush"
}
fact[FlushIgnoresTick]=$(as_bool flush_ignores_tick)

RULES=(ReleaseSent NoPhantomSelection NoTerminalSelection HeldUntilMoved HeldInTerminal HeldEndsWhenMoved SameFile ClaudeSeesCursor
  NoDeletedText TimerClosedOnce)
LIVE=()
# Five guards break no rule alone, because another guard in the code covers for them. EXPECT lists each with a guard
# that covers for it (a "+" key sets both FALSE) and the rule that breaks when both go.
EXPECT=(
  [FlushOnVisualExit]=ReleaseSent [FlushSkipsOperator]=NoPhantomSelection
  [FlushSkipsTerminal]=NoTerminalSelection [UpdateSkipsTerminal]=NoTerminalSelection
  [FlushRecordsCursor]=HeldUntilMoved [PendingKeepsHeld]=HeldUntilMoved [DemotionWaitsForMove]=HeldUntilMoved
  [DebounceIgnoresStale]=TimerClosedOnce [DemotionIgnoresStale]=TimerClosedOnce [ClearsBeforeClose]=TimerClosedOnce
  [ReadRecordsTick]=NoDeletedText [TextChangeReports]=NoDeletedText
  [ListensToSelectionBuffer]=NoDeletedText [TerminalReportsHeldBuffer]=NoDeletedText
  [UpdateChecksHeldText]=NoDeletedText
  [ListenerNotesVisualEdit]=NoPhantomSelection [VisualCheckSparesPluginEdit]=ReleaseSent [FlushIgnoresTick]=ReleaseSent
  [ReconcileOnTextChanged]=NoDeletedText [ReconcileOnCursorMoved]=HeldEndsWhenMoved [MoveReports]=HeldEndsWhenMoved
  [LeaveNoted]=HeldEndsWhenMoved
  ["DemotionClearsHeldState+MoveReports"]=ClaudeSeesCursor
  ["PendingClearsHeld+ReconcileOnCursorMoved"]=ClaudeSeesCursor
  ["ElseClearsHeldState+LeaveNoted"]=SameFile
  ["EntryClearsHeld+FlushSkipReports"]=HeldEndsWhenMoved
)

# The main run explores any visual_demotion_delay_ms with two files. Three rules need a second file in their mutant runs:
# SameFile, HeldEndsWhenMoved (LeaveNoted breaks it only when the user can visit another file), and NoDeletedText
# (UpdateChecksHeldText breaks it only when a file changes while the user is in another file).
# DelayBelowDebounce stays FALSE: TRUE would drop every order in which a demotion timer fires after a later debounce.
tla_constants() {
  local rule=${1##*-} files="f1"
  [[ $1 != main && $rule != SameFile && $rule != HeldEndsWhenMoved && $rule != NoDeletedText ]] || files="f1, f2"
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
