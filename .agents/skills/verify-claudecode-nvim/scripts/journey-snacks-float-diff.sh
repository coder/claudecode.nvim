#!/usr/bin/env bash
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
TAB="✻ [Claude Code] hello.txt (float) ⧉"

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

"$V" doctor >"$OUT/snacks-float-doctor.txt" || fail "doctor failed: $(cat "$OUT/snacks-float-doctor.txt")"
layout=$("$V" expr "luaeval('require(\"claudecode\").state.config.diff_opts.layout')")
keep=$("$V" expr "luaeval('require(\"claudecode\").state.config.diff_opts.keep_terminal_focus and 1 or 0')")
provider=$("$V" expr "luaeval('require(\"claudecode\").state.config.terminal.provider')")
[[ $provider == snacks ]] || fail "terminal.provider is '$provider'; launch with the config in features/terminal-float-diff.md"
if [[ $layout == unified ]]; then proposal_suffix='(unified diff)'; else proposal_suffix='(proposed)'; fi
if [[ $keep == 1 ]]; then focus=keep; else focus=nokeep; fi
P="snacks-float-$layout-$focus"
echo "layout=$layout keep_terminal_focus=$keep"

step "User opens the Claude terminal with :ClaudeCodeFocus; it is a visible float with focus"
"$V" keys ':ClaudeCodeFocus' Enter
wait_observed '.visible_terminal_floats == 1 and .current_is_float and .mode == "t"' 10
"$V" capture "$P-1-terminal" >/dev/null
"$V" screenshot "$P-1-terminal" >/dev/null
observe >"$OUT/$P-1-terminal.json"

step "Claude calls openDiff"
"$V" tool float1 openDiff "$(jq -nc --arg p "$WORK/hello.txt" --arg t "$TAB" \
  '{old_file_path:$p,new_file_path:$p,new_file_contents:"alpha\nBETA\ngamma\n",tab_name:$t}')"
"$V" until "bufname() =~# '$proposal_suffix\$' || bufname() =~# '^term:'" 1 10
if [[ $keep == 1 ]]; then
  wait_observed '.current_is_float and .current_buftype == "terminal"' 10
else
  wait_observed '.current_is_float == false and (.current_buf | endswith("'"$proposal_suffix"'"))' 10
fi
if "$V" await float1 2 >/dev/null 2>&1; then fail "openDiff answered before the user acted"; fi
"$V" capture "$P-2-open" >/dev/null
"$V" screenshot "$P-2-open" >/dev/null
observe >"$OUT/$P-2-open.json"
if [[ $keep == 1 ]]; then
  jq -e '.visible_terminal_floats == 1 and .current_is_float' "$OUT/$P-2-open.json" >/dev/null ||
    fail "keep_terminal_focus: the float and its focus should stay"
else
  jq -e '.visible_floats == 0 and .visible_terminal_floats == 0 and .current_is_float == false and .mode == "n"' \
    "$OUT/$P-2-open.json" >/dev/null || fail "a float is still visible or has focus: $(jq -c '{mode,current_buf,visible_floats}' "$OUT/$P-2-open.json")"
  jq -e '.diff_windows >= 1 and ([.covered[] | .covered_cells] | add) == 0' "$OUT/$P-2-open.json" >/dev/null ||
    fail "a float covers the diff: $(jq -c .covered "$OUT/$P-2-open.json")"
fi
jq -c '{layout:"'"$layout"'",keep_terminal_focus:'"$keep"',visible_floats,diff_windows,covered}' "$OUT/$P-2-open.json"

step "Claude closes the diff tab; a float that the diff hid stays hidden"
"$V" tool close1 close_tab "$(jq -nc --arg t "$TAB" '{tab_name:$t}')"
[[ $("$V" await close1 10 | jq -r '.result.content[0].text') == TAB_CLOSED ]] || fail "close_tab did not answer TAB_CLOSED"
wait_observed '.diff_windows == 0' 10
"$V" capture "$P-3-closed" >/dev/null
"$V" screenshot "$P-3-closed" >/dev/null
observe >"$OUT/$P-3-closed.json"
if [[ $keep == 1 ]]; then
  jq -e '.current_is_float and .visible_terminal_floats == 1' "$OUT/$P-3-closed.json" >/dev/null ||
    fail "keep_terminal_focus: the float and its focus should stay"
else
  jq -e '.visible_floats == 0 and .current_is_float == false' "$OUT/$P-3-closed.json" >/dev/null ||
    fail "the float came back or took focus: $(jq -c '{mode,current_buf,visible_floats}' "$OUT/$P-3-closed.json")"
fi
"$V" record "$P" >/dev/null
echo "PASS snacks-float-diff $layout $focus; evidence in $OUT"
