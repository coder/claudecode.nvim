#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154,SC2329 # check-lib.sh reads these; helpers run through as_bool
# Model-check the Claude terminal lifecycle (native and snacks providers, provider choice) against facts read
# from the code.
# Usage: check.sh [--mutants] [--keep] [--record] | check.sh --hash-only
#   exit 0 pass, 1 rule broken, 2 tool or script error, 3 stale (the covered code changed since the model was last
#   confirmed against it: unverified)
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SKILL=verify-terminal-lifecycle MODEL=TerminalLifecycle
source "$here/../../../scripts/tla/check-lib.sh"
tla_init "$@"

# followed_by FIRST SECOND: a line that matches FIRST is directly followed by a line that matches SECOND. in_order
# lets lines come between, so a guard whose `return` was deleted can still match a later `return`.
followed_by() {
  A=$1 B=$2 awk 'prev && $0 ~ ENVIRON["B"] { ok = 1 } { prev = ($0 ~ ENVIRON["A"]) } END { exit !ok }'
}

TERM_LUA=lua/claudecode/terminal.lua
NATIVE=lua/claudecode/terminal/native.lua
SNACKS=lua/claudecode/terminal/snacks.lua
OWNED=lua/claudecode/terminal/owned.lua
MAIN=lua/claudecode/init.lua
COVERED=("$TERM_LUA" "$NATIVE" "$SNACKS" "$OWNED" "$MAIN")
SITE_RE='(OWNED_MARK|cleanup_state\(|forget_exited_job|forget_ended_terminal|adopt_existing_terminal|wrap_terminal|upgrade_wrapper|remember_backdrop|register_window_events|adopted_config|focus_adopted|stop_snacks_terminal|stop_native_terminal|stop_other|stop_buffer|open_terminal\(|close_terminal\(|hide_terminal\(|show_hidden_terminal\(|cc_hide\(|cc_show\(|^ *terminal = |termopen|jobstop|vim\.wait\(|nvim_win_close|get_provider\(\)|load_provider\(|terminal\.(open|close|simple_toggle|focus_toggle|ensure_visible)\()'

covered_block load_provider "$TERM_LUA" '^local function load_provider\('
covered_block get_provider "$TERM_LUA" '^local function get_provider\(\)'
covered_block ensure_visible "$TERM_LUA" '^local function ensure_terminal_visible_no_focus\('
covered_block term_open "$TERM_LUA" '^function M\.open\('
covered_block term_close "$TERM_LUA" '^function M\.close\(\)'
covered_block term_simple_toggle "$TERM_LUA" '^function M\.simple_toggle\('
covered_block term_focus_toggle "$TERM_LUA" '^function M\.focus_toggle\('
covered_block term_hide_float "$TERM_LUA" '^function M\.hide_float\('
covered_block is_last_window "$NATIVE" '^local function is_last_window\('
covered_block is_valid "$NATIVE" '^local function is_valid\(\)'
covered_block forget_exited "$NATIVE" '^local function forget_exited_job\('
covered_block forget_ended "$NATIVE" '^local function forget_ended_terminal\('
covered_block adopt "$NATIVE" '^local function adopt_existing_terminal\(\)'
covered_block stop_snacks "$NATIVE" '^local function stop_snacks_terminal\('
covered_block start_terminal "$NATIVE" '^local function start_terminal\('
covered_block open_terminal "$NATIVE" '^local function open_terminal\('
covered_block close_terminal "$NATIVE" '^function close_terminal\(\)'
covered_block native_visible "$NATIVE" '^local function is_terminal_visible\(\)'
covered_block hide_terminal "$NATIVE" '^local function hide_terminal\(\)'
covered_block show_hidden "$NATIVE" '^function show_hidden_terminal\('
covered_block focus_adopted "$NATIVE" '^local function focus_adopted\('
covered_block native_open "$NATIVE" '^function M\.open\('
covered_block native_simple_toggle "$NATIVE" '^function M\.simple_toggle\('
covered_block native_focus_toggle "$NATIVE" '^function M\.focus_toggle\('
covered_block native_active "$NATIVE" '^function M\.get_active_bufnr\('
covered_block owned_job_ended "$OWNED" '^function M\.job_ended\('
covered_block owned_is_live "$OWNED" '^function M\.is_live\('
covered_block owned_find "$OWNED" '^function M\.find\('
covered_block owned_stop_buffer "$OWNED" '^local function stop_buffer\('
covered_block owned_stop_other "$OWNED" '^function M\.stop_other\('
covered_block snacks_available "$SNACKS" '^local function is_available\(\)'
covered_block snacks_events "$SNACKS" '^local function setup_terminal_events\('
covered_block cc_is_visible "$SNACKS" '^local function cc_is_visible\('
covered_block cc_hide "$SNACKS" '^local function cc_hide\('
covered_block cc_show "$SNACKS" '^local function cc_show\('
covered_block snacks_forget_ended "$SNACKS" '^local function forget_ended_terminal\('
covered_block snacks_remember_backdrop "$SNACKS" '^local function remember_backdrop\('
covered_block snacks_register_events "$SNACKS" '^local function register_window_events\('
covered_block snacks_find_backdrop "$SNACKS" '^local function find_backdrop\('
covered_block snacks_find_window "$SNACKS" '^local function find_window\('
covered_block snacks_wrapper_options "$SNACKS" '^local function wrapper_options\('
covered_block snacks_wrap "$SNACKS" '^local function wrap_terminal\('
covered_block snacks_upgrade_wrapper "$SNACKS" '^local function upgrade_wrapper\('
covered_block snacks_adopted_config "$SNACKS" '^local function adopted_config\('
covered_block snacks_adopt "$SNACKS" '^local function adopt_existing_terminal\('
covered_block snacks_stop_native "$SNACKS" '^local function stop_native_terminal\('
covered_block snacks_open "$SNACKS" '^function M\.open\('
covered_block snacks_close "$SNACKS" '^function M\.close\(\)'
covered_block snacks_simple_toggle "$SNACKS" '^function M\.simple_toggle\('
covered_block snacks_focus_toggle "$SNACKS" '^function M\.focus_toggle\('
covered_block snacks_active "$SNACKS" '^function M\.get_active_bufnr\('
covered_block snacks_hide_float "$SNACKS" '^function M\.hide_float\('
covered_block user_commands "$MAIN" '^  if terminal_ok then$'
covered_block send_at_mention "$MAIN" '^function M\.send_at_mention\('

FACTS=(NativeMarkBeforeTermopen OwnedUnstartedIsNotEnded OwnedLiveNeedsMark OwnedLiveSkipsEndedJob
  NativeAdoptsHiddenTerminal NativeShowsAdoptedHidden NativeExitClearsMark NativeAdoptedExitHandled
  NativeExitForgetsOwnJobOnly NativeExitKeepsLastWindow NativeExitChecksWindowBuffer NativeEntriesForgetEndedJob
  NativeRescansSwappedWindow NativeCloseAdopts NativeCloseForgetsFirst NativeCloseClearsMark NativeKeepsHiddenJob
  NativeHideKeepsLastWindow NativeFailCleansUp NativeStartSurvivesClosedSplit NativeOpenSkipsDuringStart NativeRunsDeferredClose NativeStopsSnacksClaude
  SnacksOpenSkipsDuringStart
  SnacksMarksStartedTerminal SnacksEntriesAdopt SnacksEntriesForgetEndedJob SnacksCloseAdopts SnacksExitForgets
  SnacksForgetChecksInstance
  SnacksCloseForgetsFirst SnacksCloseClearsMark SnacksHideKeepsLastWindow SnacksFailCleansUp SnacksStopsNativeClaude
  SnacksAvailabilityCached OwnedStopOtherStops)

# native.lua: the mark goes on the new buffer before the window shows it (the swap in utils.win_set_buf_in_split fires BufEnter) and before
# termopen (TermOpen), so an open() from either autocmd adopts the terminal being started.
fact[NativeMarkBeforeTermopen]=$(as_bool in_order '^  local new_bufnr = vim\.api\.nvim_create_buf\(' \
  '^  vim\.b\[new_bufnr\]\[OWNED_MARK\] = true$' '^  utils\.win_set_buf_in_split\(new_winid, new_bufnr\)$' \
  'pcall\(vim\.fn\.termopen, term_cmd_arg, termopen_opts\)' <<<"$start_terminal")
# owned.lua: a buffer whose job has not started (channel 0) has not ended, so the autocmd's open() can adopt it.
fact[OwnedUnstartedIsNotEnded]=$(as_bool grep -qE \
  '^  return channel ~= 0 and not pcall\(vim\.fn\.jobpid, channel\)$' <<<"$owned_job_ended")
# owned.lua is_live reads the mark and the job on one line. Each fact must also hold alone, so a reworded line that
# drops one condition flips only that fact. Both providers find their Claude through is_live.
owned_uses_is_live() {
  grep -qE '^    if M\.is_live\(buf, mark\) then$' <<<"$owned_find" &&
    grep -qE 'owned\.find\(OWNED_MARK\)' <<<"$adopt" &&
    grep -qE 'owned\.find\(OWNED_MARK\)' <<<"$snacks_adopt"
}
fact[OwnedLiveNeedsMark]=$(as_bool owned_uses_is_live)
fact[OwnedLiveSkipsEndedJob]=$(as_bool owned_uses_is_live)
grep -qE 'and vim\.b\[buf\]\[mark\]( and| or|$)' <<<"$owned_is_live" || fact[OwnedLiveNeedsMark]=FALSE
grep -qE 'and not M\.job_ended\(buf\)( and| or|$)' <<<"$owned_is_live" || fact[OwnedLiveSkipsEndedJob]=FALSE
# native.lua adopt_existing_terminal takes the terminal whether or not a window shows it, and the entries show a hidden
# one (focus_adopted).
native_adopts_hidden() {
  in_order '^  local buf = owned\.find\(OWNED_MARK\)$' '^  bufnr, winid, jobid = buf, win, vim\.bo\[buf\]\.channel$' \
    <<<"$adopt" &&
    # The only return before the adoption is the one for a missing buffer. A return for a missing window would stop it.
    [[ $(awk '/^  local buf = owned\.find\(OWNED_MARK\)$/ { on = 1 } /^  bufnr, winid, jobid = buf/ { on = 0 } on && /return/' <<<"$adopt" | wc -l) -eq 1 ]]
}
fact[NativeAdoptsHiddenTerminal]=$(as_bool native_adopts_hidden)
native_shows_adopted_hidden() {
  in_order '^  if winid then$' '^    if focus then$' '^      focus_terminal\(\)$' '^  else$' \
    '^    show_hidden_terminal\(effective_config, focus\)$' <<<"$focus_adopted" &&
    grep -qE '^      focus_adopted\(effective_config, focus\)$' <<<"$native_open" &&
    grep -qE '^        focus_adopted\(effective_config, true\)$' <<<"$native_simple_toggle" &&
    in_order '^      if not winid then$' '^        show_hidden_terminal\(effective_config, true\)$' <<<"$native_focus_toggle"
}
fact[NativeShowsAdoptedHidden]=$(as_bool native_shows_adopted_hidden)
# on_exit schedules the mark clear and forget_exited_job.
fact[NativeExitClearsMark]=$(as_bool in_order '^    on_exit = function\(job_id, _, _\)$' '^      vim\.schedule\(function\(\)$' \
  '^        if vim\.api\.nvim_buf_is_valid\(new_bufnr\) then$' '^          vim\.b\[new_bufnr\]\[OWNED_MARK\] = nil$' \
  '^        forget_exited_job\(job_id, effective_config\.auto_close\)$' <<<"$start_terminal")
fact[NativeAdoptedExitHandled]=$(as_bool in_order '^  bufnr, winid, jobid = buf, win, vim\.bo\[buf\]\.channel$' \
  'vim\.api\.nvim_create_autocmd\("TermClose", \{' '^    buffer = buf,$' '^      vim\.schedule\(function\(\)$' \
  '^        forget_exited_job\(adopted_jobid, config\.auto_close\)$' <<<"$adopt")
fact[NativeExitForgetsOwnJobOnly]=$(as_bool in_order '^  if job_id ~= jobid then$' '^    return$' \
  '^  cleanup_state\(\)' <<<"$forget_exited")
# forget_exited_job closes the tracked window only when it is not the last window, and (for a valid buffer) only
# when it still shows the terminal buffer.
native_exit_keeps_last_window() {
  in_order '^    and not is_last_window\(current_winid_for_job\)$' '^  then$' \
    'vim\.api\.nvim_win_close\(current_winid_for_job, true\)' <<<"$forget_exited" &&
    in_order '^  if #vim\.api\.nvim_list_tabpages\(\) > 1 then$' '^    return false$' \
      'vim\.api\.nvim_win_get_config\(other\)\.relative == ""' '^      return false$' '^  return true$' <<<"$is_last_window"
}
fact[NativeExitKeepsLastWindow]=$(as_bool native_exit_keeps_last_window)
fact[NativeExitChecksWindowBuffer]=$(as_bool in_order \
  '^    if current_bufnr_for_job and vim\.api\.nvim_buf_is_valid\(current_bufnr_for_job\) then$' \
  '^      if vim\.api\.nvim_win_get_buf\(current_winid_for_job\) == current_bufnr_for_job then$' \
  '^        vim\.api\.nvim_win_close\(current_winid_for_job, true\)$' <<<"$forget_exited")
# open, simple_toggle and focus_toggle run the exit cleanup of a terminal whose job ended, before they look at it.
native_entries_forget_ended() {
  grep -qxE 'local job_ended = owned\.job_ended' "$NATIVE" &&
    in_order '^  if bufnr and vim\.api\.nvim_buf_is_valid\(bufnr\) and job_ended\(bufnr\) then$' \
      '^    forget_exited_job\(jobid, job_auto_close\)$' <<<"$forget_ended" &&
    in_order '^  forget_ended_terminal\(\)$' '^  if is_valid\(\) then$' <<<"$native_open" &&
    in_order '^  forget_ended_terminal\(\)$' '^  local has_buffer = ' <<<"$native_simple_toggle" &&
    in_order '^  forget_ended_terminal\(\)$' '^  local has_buffer = ' <<<"$native_focus_toggle"
}
fact[NativeEntriesForgetEndedJob]=$(as_bool native_entries_forget_ended)
# is_valid scans the windows again when the tracked window shows another buffer, and clears it when none shows Claude.
fact[NativeRescansSwappedWindow]=$(as_bool in_order \
  '^  if not winid or not vim\.api\.nvim_win_is_valid\(winid\) or vim\.api\.nvim_win_get_buf\(winid\) ~= bufnr then$' \
  '^    winid = nil$' <<<"$is_valid")
fact[NativeCloseAdopts]=$(as_bool grep -qE '^  if not is_valid\(\) and not adopt_existing_terminal\(\) then$' <<<"$close_terminal")
fact[NativeCloseForgetsFirst]=$(as_bool in_order '^  local closing_bufnr, closing_jobid = bufnr, jobid$' \
  '^  cleanup_state\(\)$' 'vim\.wait\(' <<<"$close_terminal")
fact[NativeCloseClearsMark]=$(as_bool in_order '^  local closing_bufnr, closing_jobid = bufnr, jobid$' \
  '^  vim\.b\[closing_bufnr\]\[OWNED_MARK\] = nil$' 'vim\.wait\(' <<<"$close_terminal")
# The buffer is bufhidden=hide before it has a window, so a window that closes (a hide, or an autocmd of the start that
# closes the split) never unloads it: with 'nohidden' that would end the job, or start a second terminal on 0.8. The start
# sets it again after termopen, because an autocmd of the start can have changed it (to wipe, for example).
fact[NativeKeepsHiddenJob]=$(as_bool in_order '^  vim\.b\[new_bufnr\]\[OWNED_MARK\] = true$' \
  '^  vim\.bo\[new_bufnr\]\.bufhidden = "hide"$' '^  utils\.win_set_buf_in_split\(new_winid, new_bufnr\)$' \
  '^  jobid = termopen_result$' '^  vim\.bo\[bufnr\]\.bufhidden = "hide"$' <<<"$start_terminal")
# A fix that skips the last window or pcalls the close flips this fact.
native_hide_keeps_last_window() {
  { in_order '^    if is_last_window\(winid\) then$' '^      return$' '^    vim\.api\.nvim_win_close\(winid, false\)$' <<<"$hide_terminal" &&
    followed_by 'Terminal window is the last window, not hiding it' '^      return$' <<<"$hide_terminal"; } ||
    grep -qE 'pcall\(vim\.api\.nvim_win_close, winid, false\)' <<<"$hide_terminal"
}
fact[NativeHideKeepsLastWindow]=$(as_bool native_hide_keeps_last_window)
# open_terminal reads its split again after termopen. An autocmd of the start (a BufEnter or TermOpen autocmd that calls
# focus_toggle, which adopts the half-started terminal and hides its window) can have closed it. The code then looks at
# the split only while it exists, tracks the window that shows Claude now (none when it is hidden), and focuses only
# when there is one.
native_start_survives_closed_split() {
  in_order '^  jobid = termopen_result$' \
    '^  if vim\.api\.nvim_win_is_valid\(new_winid\) and vim\.api\.nvim_win_get_buf\(new_winid\) ~= new_bufnr then$' \
    '^  winid = new_winid$' '^  bufnr = new_bufnr$' '^  is_valid\(\)$' '^  if focus and winid then$' <<<"$start_terminal"
}
fact[NativeStartSurvivesClosedSplit]=$(as_bool native_start_survives_closed_split)
# A start runs from `starting = true` to `starting = false`, and open_terminal returns first when it finds the flag set. An
# entry that an autocmd of the start calls (WinLeave, WinNew, WinEnter of the vsplit, BufNew, BufAdd of the new buffer) finds no
# buffer with a mark yet and reaches open_terminal, so without the guard it starts a second Claude. The pcall keeps an error
# of the start from leaving the flag set.
native_open_skips_during_start() {
  followed_by '^  if starting then$' '^    return$' <<<"$open_terminal" &&
    in_order '^  if starting then$' '^  starting = true$' 'pcall\(start_terminal, ' '^  starting = false$' <<<"$open_terminal"
}
fact[NativeOpenSkipsDuringStart]=$(as_bool native_open_skips_during_start)
# A close that an autocmd of the start asked for sets close_after_start (M.close, not read here: without it the close would wait
# inside termopen, and the model has no nested wait). open_terminal reads the request after the start returns, clears it, and
# runs close_terminal, also when the start raised.
native_runs_deferred_close() {
  in_order '^  starting = false$' '^  local close_requested = close_after_start$' '^  close_after_start = false$' \
    '^  if close_requested then$' 'pcall\(close_terminal\)' <<<"$open_terminal"
}
fact[NativeRunsDeferredClose]=$(as_bool native_runs_deferred_close)
fact[NativeFailCleansUp]=$(as_bool in_order '^  if failure then$' '^      vim\.api\.nvim_win_close\(new_winid, true\)$' \
  '^      vim\.api\.nvim_buf_delete\(new_bufnr, \{ force = true \}\)$' '^    cleanup_state\(\)$' '^    return$' \
  '^  jobid = termopen_result$' <<<"$start_terminal")
# Before it starts Claude, and in close when it finds none to adopt, the native provider stops the snacks Claude.
native_stops_snacks() {
  in_order '^  stop_snacks_terminal\(\)$' '^  if is_valid\(\) then' <<<"$open_terminal" &&
    in_order '^    stop_snacks_terminal\(\)$' '^    return$' <<<"$close_terminal" &&
    grep -qE 'owned\.stop_other\(owned\.SNACKS_MARK, "snacks"\)' <<<"$stop_snacks"
}
fact[NativeStopsSnacksClaude]=$(as_bool native_stops_snacks)

# owned.lua: stop_other stops every marked live buffer of the other provider, one by one until none is left, and stop_buffer
# clears the mark, stops the job, waits for its exit and deletes the buffer. The providers call it before a start and in
# close (NativeStopsSnacksClaude, SnacksStopsNativeClaude), and the model's StopAll step relies on it.
owned_stop_other_stops() {
  in_order '^  if not M\.find\(mark\) then$' '^    return false$' '^  local buf = M\.find\(mark\)$' '^  while buf do$' \
    '^    if not stop_buffer\(buf, mark\) then$' '^      return false$' '^    buf = M\.find\(mark\)$' '^  return true$' \
    <<<"$owned_stop_other" &&
    in_order '^  vim\.b\[buf\]\[mark\] = nil$' '^  M\.wait_for_exec\(channel\)$' '^  if vim\.api\.nvim_buf_is_valid\(buf\) and vim\.fn\.jobstop\(channel\) == 1 then$' \
      '^    vim\.wait\(1000, function\(\)$' '^    vim\.api\.nvim_buf_delete\(buf, \{ force = true \}\)$' \
      '^  return not vim\.api\.nvim_buf_is_valid\(buf\)$' <<<"$owned_stop_buffer"
}
fact[OwnedStopOtherStops]=$(as_bool owned_stop_other_stops)

# snacks.lua
snacks_open_skips_during_start() {
  grep -qxE 'local starting = false' "$SNACKS" &&
    followed_by '^  if starting then$' '^    return$' <<<"$snacks_open" &&
    in_order '^  if starting then$' '^  starting = true$' \
      '^  local opened, open_result = pcall\(Snacks\.terminal\.open, cmd, opts\)$' '^  starting = false$' <<<"$snacks_open"
}
fact[SnacksOpenSkipsDuringStart]=$(as_bool snacks_open_skips_during_start)
fact[SnacksMarksStartedTerminal]=$(as_bool in_order '^  if started then$' \
  '^    vim\.b\[term_instance\.buf\]\[OWNED_MARK\] = true$' '^    terminal = term_instance$' <<<"$snacks_open")
# adopt_existing_terminal takes a marked buffer with a live job when none is tracked, and wraps it in a Snacks window.
# Open and both toggles call it first, with their config.
snacks_entries_adopt() {
  in_order '^  if terminal and terminal:buf_valid\(\) then$' '^    return$' '^  local buf = owned\.find\(OWNED_MARK\)$' \
    '^    terminal = wrap_terminal\(buf, config\)$' <<<"$snacks_adopt" &&
    in_order '^  adopt_existing_terminal\(config\)$' '^  if terminal and terminal:buf_valid\(\) then$' <<<"$snacks_open" &&
    in_order '^  adopt_existing_terminal\(config\)$' '^  if terminal and terminal:buf_valid\(\) then$' <<<"$snacks_simple_toggle" &&
    in_order '^  adopt_existing_terminal\(config\)$' '^  if terminal and terminal:buf_valid\(\) then$' <<<"$snacks_focus_toggle"
}
fact[SnacksEntriesAdopt]=$(as_bool snacks_entries_adopt)
# adopt_existing_terminal, the first call in open, both toggles, close and get_active_bufnr, runs forget_ended_terminal.
# It forgets a tracked terminal whose job ended, when the terminal started with auto_close. A TermClose autocmd that runs
# before the provider's handler, or an adopted instance whose handler belongs to an earlier module copy, would leave it
# tracked until the scheduled close wipes it.
snacks_entries_forget_ended() {
  in_order '^  if not \(terminal and terminal:buf_valid\(\)\) then$' '^    return$' \
    '^  local started_with = terminal\._cc and terminal\._cc\.config$' \
    '^  if started_with and started_with\.auto_close and owned\.job_ended\(terminal\.buf\) then$' '^    terminal = nil$' \
    <<<"$snacks_forget_ended" &&
    in_order '^  forget_ended_terminal\(\)$' '^  if terminal and terminal:buf_valid\(\) then$' <<<"$snacks_adopt"
}
fact[SnacksEntriesForgetEndedJob]=$(as_bool snacks_entries_forget_ended)
fact[SnacksCloseAdopts]=$(as_bool in_order '^  adopt_existing_terminal\(\)$' \
  '^  if not \(terminal and terminal:buf_valid\(\)\) then$' <<<"$snacks_close")
fact[SnacksExitForgets]=$(as_bool in_order '^  if config\.auto_close then$' '^    term_instance:on\("TermClose", function\(\)$' \
  '^      forget\(\)$' '^      vim\.schedule\(function\(\)$' '^        term_instance:close\(\{ buf = true \}\)$' \
  <<<"$snacks_events")
fact[SnacksForgetChecksInstance]=$(as_bool in_order '^  local function forget\(\)$' '^    if terminal == term_instance then$' \
  '^      terminal = nil$' <<<"$snacks_events")
fact[SnacksCloseForgetsFirst]=$(as_bool in_order '^  local closing = terminal$' '^  terminal = nil$' 'vim\.wait\(' \
  '^    closing:close\(\)$' <<<"$snacks_close")
# snacks.lua: the mark of the terminal that closes goes before the wait for the exec, which runs scheduled callbacks while
# the job still runs, so an open() among them cannot adopt it by its mark. The model has no such wait: it counts a closing
# terminal as ended (`JobEnded`), so this fact breaks a rule only together with OwnedLiveSkipsEndedJob, as in native.
fact[SnacksCloseClearsMark]=$(as_bool in_order '^  local closing = terminal$' '^  terminal = nil$' \
  '^    vim\.b\[closing_bufnr\]\[OWNED_MARK\] = nil$' '^      owned\.wait_for_exec\(jobid\)$' \
  '^    vim\.fn\.jobstop\(jobid\)$' <<<"$snacks_close")
fact[SnacksHideKeepsLastWindow]=$(as_bool grep -qE '^    if pcall\(vim\.api\.nvim_win_close, win, false\) then$' \
  <<<"$cc_hide")
fact[SnacksFailCleansUp]=$(as_bool in_order '^  opts\.win\.on_buf = function\(instance\)$' '^    shown_instance = instance$' \
  '^  local opened, open_result = pcall\(Snacks\.terminal\.open, cmd, opts\)$' '^    terminal = nil$' \
  '^    local leftover = term_instance or shown_instance$' '^      leftover:close\(\{ buf = true \}\)$' <<<"$snacks_open")
# Before it starts Claude, and in close when it finds none to adopt, the snacks provider stops the native Claude.
snacks_stops_native() {
  grep -qE '^  if stop_native_terminal\(\) and terminal and terminal:buf_valid\(\) then$' <<<"$snacks_open" &&
    in_order '^    stop_native_terminal\(\)$' '^    return$' <<<"$snacks_close" &&
    grep -qE 'owned\.stop_other\(owned\.NATIVE_MARK, "native"\)' <<<"$snacks_stop_native"
}
fact[SnacksStopsNativeClaude]=$(as_bool snacks_stops_native)
# snacks.lua reads require("snacks") once, when the module loads, and load_provider gets that module through require,
# which keeps it. So the provider that "auto" or "snacks" resolves to does not change until a reload. (load_provider
# also keeps the module in its own table. That is a second cache, and the fact does not need it.)
snacks_availability_cached() {
  grep -qxE 'local snacks_available, Snacks = pcall\(require, "snacks"\)' "$SNACKS" &&
    grep -qE '^  return snacks_available and Snacks and Snacks\.terminal ~= nil$' <<<"$snacks_available" &&
    grep -qE 'pcall\(require, "claudecode\.terminal\." \.\. provider_name\)' <<<"$load_provider" &&
    in_order '^  elseif defaults\.provider == "auto" then$' '^    local snacks_provider = load_provider\("snacks"\)$' \
      '^    if snacks_provider and snacks_provider\.is_available\(\) then$' <<<"$get_provider"
}
fact[SnacksAvailabilityCached]=$(as_bool snacks_availability_cached)

RULES=(AtMostOneClaude CloseStopsClaude CloseNeverReuses OpenShowsLiveClaude HideKeepsClaude HideNoError
  FailedStartLeavesNoWindow ExitClosesOnlyOwnWindow)
LIVE=()
EXPECT=(
  ["NativeMarkBeforeTermopen+NativeOpenSkipsDuringStart"]=AtMostOneClaude
  ["OwnedUnstartedIsNotEnded+NativeOpenSkipsDuringStart"]=AtMostOneClaude
  [OwnedLiveSkipsEndedJob]=OpenShowsLiveClaude
  ["OwnedLiveNeedsMark+OwnedLiveSkipsEndedJob"]=CloseNeverReuses
  [NativeAdoptsHiddenTerminal]=AtMostOneClaude
  [NativeShowsAdoptedHidden]=OpenShowsLiveClaude
  ["NativeExitClearsMark+OwnedLiveSkipsEndedJob"]=OpenShowsLiveClaude
  ["NativeAdoptedExitHandled+NativeEntriesForgetEndedJob"]=OpenShowsLiveClaude
  ["NativeExitForgetsOwnJobOnly+NativeCloseAdopts"]=CloseStopsClaude
  [NativeExitKeepsLastWindow]=ExitClosesOnlyOwnWindow
  [NativeExitChecksWindowBuffer]=ExitClosesOnlyOwnWindow
  [NativeEntriesForgetEndedJob]=OpenShowsLiveClaude
  [NativeRescansSwappedWindow]=OpenShowsLiveClaude
  [NativeCloseAdopts]=CloseStopsClaude
  [NativeCloseForgetsFirst]=CloseNeverReuses
  ["NativeCloseClearsMark+OwnedLiveSkipsEndedJob"]=CloseNeverReuses
  [NativeKeepsHiddenJob]=HideKeepsClaude
  [NativeHideKeepsLastWindow]=HideNoError
  [NativeFailCleansUp]=FailedStartLeavesNoWindow
  [NativeStartSurvivesClosedSplit]=HideNoError
  [NativeOpenSkipsDuringStart]=AtMostOneClaude
  [NativeRunsDeferredClose]=CloseStopsClaude
  [NativeStopsSnacksClaude]=AtMostOneClaude
  [SnacksOpenSkipsDuringStart]=AtMostOneClaude
  [SnacksMarksStartedTerminal]=AtMostOneClaude
  [SnacksEntriesAdopt]=AtMostOneClaude
  [SnacksEntriesForgetEndedJob]=OpenShowsLiveClaude
  [SnacksCloseAdopts]=CloseStopsClaude
  ["SnacksExitForgets+SnacksEntriesForgetEndedJob"]=OpenShowsLiveClaude
  ["SnacksForgetChecksInstance+SnacksCloseAdopts"]=CloseStopsClaude
  [SnacksCloseForgetsFirst]=CloseNeverReuses
  ["SnacksCloseClearsMark+OwnedLiveSkipsEndedJob"]=CloseNeverReuses
  [SnacksHideKeepsLastWindow]=HideNoError
  [SnacksFailCleansUp]=FailedStartLeavesNoWindow
  [SnacksStopsNativeClaude]=AtMostOneClaude
  [OwnedStopOtherStops]=AtMostOneClaude
  ["SnacksAvailabilityCached+SnacksStopsNativeClaude"]=AtMostOneClaude
)

# The main run turns every environment switch on. A mutant run keeps only the provider and the switches its
# guard needs, so that the paths of the facts it removes cannot be reached through another switch.
tla_constants() {
  local name=$1 providers='{"native", "auto"}' loadable='{FALSE, TRUE}'
  local reloads=TRUE changes=TRUE reenters=TRUE early=TRUE swaps=TRUE wipes=TRUE
  if [[ $name == mut-* ]]; then
    reloads=FALSE changes=FALSE reenters=FALSE early=FALSE swaps=FALSE wipes=FALSE
    case "$name" in
    mut-NativeMarkBeforeTermopen-* | mut-OwnedUnstartedIsNotEnded-*)
      providers='{"native"}' loadable='{FALSE}' reenters=TRUE
      ;;
    mut-OwnedStopOtherStops-*)
      loadable='{TRUE}' reloads=TRUE changes=TRUE
      ;;
    mut-Owned*)
      loadable='{TRUE}' early=TRUE
      ;;
    mut-NativeAdoptsHiddenTerminal-* | mut-NativeShowsAdoptedHidden-* | mut-NativeCloseAdopts-*)
      providers='{"native"}' loadable='{FALSE}' reloads=TRUE
      ;;
    mut-NativeAdoptedExitHandled-*)
      providers='{"native"}' loadable='{FALSE}' reloads=TRUE early=TRUE
      ;;
    mut-NativeEntriesForgetEndedJob-*)
      providers='{"native"}' loadable='{FALSE}' early=TRUE
      ;;
    mut-NativeRescansSwappedWindow-*)
      providers='{"native"}' loadable='{FALSE}' swaps=TRUE
      ;;
    mut-NativeExitChecksWindowBuffer-*)
      providers='{"native"}' loadable='{FALSE}' swaps=TRUE wipes=TRUE
      ;;
    mut-NativeStopsSnacksClaude-* | mut-SnacksStopsNativeClaude-*)
      loadable='{TRUE}' reloads=TRUE changes=TRUE
      ;;
    mut-Native*)
      providers='{"native"}' loadable='{FALSE}' reenters=TRUE
      ;;
    mut-SnacksAvailabilityCached-*) providers='{"auto"}' loadable='{FALSE}' ;;
    mut-SnacksOpenSkipsDuringStart-*) providers='{"auto"}' loadable='{TRUE}' reenters=TRUE ;;
    mut-SnacksMarksStartedTerminal-* | mut-SnacksEntriesAdopt-* | mut-SnacksCloseAdopts-*)
      providers='{"auto"}' loadable='{TRUE}' reloads=TRUE
      ;;
    mut-SnacksEntriesForgetEndedJob-*) providers='{"auto"}' loadable='{TRUE}' reloads=TRUE early=TRUE ;;
    mut-Snacks*) providers='{"auto"}' loadable='{TRUE}' early=TRUE ;;
    esac
  fi
  echo "  Terms = {t1, t2}"
  echo "  Providers = $providers"
  echo "  LoadableAtStart = $loadable"
  echo "  Reloads = $reloads"
  echo "  ProviderChanges = $changes"
  echo "  AutocmdReenters = $reenters"
  echo "  OpenBeforeCleanup = $early"
  echo "  Swaps = $swaps"
  echo "  Wipes = $wipes"
  echo "  OnlyWindow = TRUE"
}

CONSTRAINT=AllRulesHold
tla_main "$@"
