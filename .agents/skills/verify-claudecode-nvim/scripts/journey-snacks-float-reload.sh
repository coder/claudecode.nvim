#!/usr/bin/env bash
# The float terminal after a plugin reload (:Lazy reload clears every claudecode module and runs setup again).
# Snacks keeps its terminal instance, so the new copy of the snacks provider adopts the instance that the old copy
# started. A float that the user shows through the instance and hides again with Snacks' `q` must stay hidden when
# the diff closes, and the cursor must not go into it.
set -euo pipefail
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V="$SCRIPTS/vcn.sh"
OBSERVE="$SCRIPTS/observe-windows.lua"
# OUT and WORK come from the run itself, so the evidence of a journey cannot land in the dir of another run. doctor
# prints them on its `paths:` line, and a doctor that fails still prints it.
: "${VCN_STATE:?export VCN_STATE, the value launch printed}"
run_paths=$({ "$V" doctor || true; } | sed -n 's/^paths: //p')
OUT=$(sed -n 's/.* OUT=\(.*\) WORK=.*/\1/p' <<<"$run_paths")
[[ -n $OUT ]] || {
  echo "FAIL: $V doctor printed no paths line for VCN_STATE=$VCN_STATE" >&2
  exit 1
}
WORK=$VCN_STATE/work
TAB="✻ [Claude Code] hello.txt (float-reload) ⧉"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}
step() { echo "== $*"; }
observe() { "$V" expr "luaeval('dofile(\"$OBSERVE\")')"; }
wait_observed() {
  local filter=$1 secs=$2
  local deadline=$((SECONDS + secs))
  while :; do
    jq -e "$filter" <<<"$(observe)" >/dev/null 2>&1 && return 0
    ((SECONDS < deadline)) || fail "window state never matched: $filter ($(observe | jq -c '{mode,current_buf,current_is_float,visible_floats,visible_terminal_floats}'))"
    sleep 0.1
  done
}
normal() {
  "$V" keys "Ctrl+\\" Ctrl+N
  "$V" until 'mode()' n 10
}

"$V" doctor >"$OUT/snacks-float-reload-doctor.txt" || fail "doctor failed: $(cat "$OUT/snacks-float-reload-doctor.txt")"
provider=$("$V" expr "luaeval('require(\"claudecode\").state.config.terminal.provider')")
keep=$("$V" expr "luaeval('require(\"claudecode\").state.config.diff_opts.keep_terminal_focus and 1 or 0')")
[[ $provider == snacks ]] || fail "terminal.provider is '$provider'; launch with the config in features/terminal-float-diff.md"
[[ $keep == 0 ]] || fail "keep_terminal_focus must be false: the float stays on screen with it"
P="snacks-float-reload"

step "User opens the Claude terminal with :ClaudeCodeFocus; it is a visible float with focus"
"$V" keys ':ClaudeCodeFocus' Enter
wait_observed '.visible_terminal_floats == 1 and .current_is_float and .mode == "t"' 10
normal

step "User reloads the plugin: every claudecode module is cleared and setup runs again"
"$V" keys ':lua local cfg = require("claudecode").state.config; for k in pairs(package.loaded) do if k:match("^claudecode") then package.loaded[k] = nil end end; require("claudecode").setup(cfg)' Enter
sleep 1.5
wait_observed '.visible_terminal_floats == 1' 10

step "Claude calls openDiff; the reloaded copy hides the float"
"$V" tool reload1 openDiff "$(jq -nc --arg p "$WORK/hello.txt" --arg t "$TAB" \
  '{old_file_path:$p,new_file_path:$p,new_file_contents:"alpha\nBETA\ngamma\n",tab_name:$t}')"
wait_observed '.visible_terminal_floats == 0 and .diff_windows >= 1 and .current_is_float == false' 10
"$V" screenshot "$P-1-open" >/dev/null

step "User shows the float through the Snacks instance, then hides it with Snacks' q"
"$V" keys ':lua for _, t in ipairs(require("snacks").terminal.list()) do t:toggle() end' Enter
wait_observed '.visible_terminal_floats == 1' 10
normal
"$V" keys q
wait_observed '.visible_terminal_floats == 0' 10
"$V" screenshot "$P-2-user-hid" >/dev/null

step "Claude closes the diff tab; the float the user hid stays hidden and takes no cursor"
"$V" tool close1 close_tab "$(jq -nc --arg t "$TAB" '{tab_name:$t}')"
[[ $("$V" await close1 10 | jq -r '.result.content[0].text') == TAB_CLOSED ]] || fail "close_tab did not answer TAB_CLOSED"
wait_observed '.diff_windows == 0' 10
sleep 0.5
"$V" capture "$P-3-closed" >/dev/null
"$V" screenshot "$P-3-closed" >/dev/null
observe >"$OUT/$P-3-closed.json"
jq -e '.visible_terminal_floats == 0 and .visible_floats == 0 and .current_is_float == false and .mode == "n"' \
  "$OUT/$P-3-closed.json" >/dev/null ||
  fail "the float came back or took the cursor: $(jq -c '{mode,current_buf,current_is_float,visible_terminal_floats}' "$OUT/$P-3-closed.json")"
"$V" record "$P" >/dev/null
echo "PASS snacks-float-reload; evidence in $OUT"
