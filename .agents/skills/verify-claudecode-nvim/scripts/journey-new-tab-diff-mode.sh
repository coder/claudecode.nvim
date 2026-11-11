#!/usr/bin/env bash
# Two openDiff calls that each open in a new tab leave the cursor in the proposal in Normal mode. Needs VCN_STATE from a
# launch with a real Claude terminal and diff_opts.open_in_new_tab, for example:
#   VCN_SETUP='{"terminal_cmd":"sleep 300","terminal":{"provider":"native"},"diff_opts":{"open_in_new_tab":true}}' vcn.sh launch
# Add "layout":"unified" to diff_opts for the unified layout. Evidence lands in $OUT as new-tab-diff-mode-*.
set -euo pipefail
V="$(dirname "${BASH_SOURCE[0]}")/vcn.sh"
# shellcheck source=/dev/null
source "$VCN_STATE/run.env"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}
step() { echo "== $*"; }
tab_name() { printf '✻ [Claude Code] hello.txt (%s) ⧉' "$1"; }

open_diff() {
  "$V" tool "$1" openDiff "$(jq -nc --arg p "$WORK/$2" --arg t "$(tab_name "$1")" --arg c "$3" \
    '{old_file_path:$p,new_file_path:$p,new_file_contents:$c,tab_name:$t}')"
}

expect_proposal_in_normal_mode() {
  "$V" until "bufname() =~# '($1)' && tabpagenr() == $2" 1 10
  # Nothing signals that an insert did not start, so wait for a pending one before reading the mode.
  sleep 0.5
  local mode
  mode=$("$V" expr 'mode(1)')
  "$V" capture "new-tab-diff-mode-$3" >/dev/null
  [[ $mode == n ]] || fail "the proposal of $1 is in mode '$mode', not 'n' (see $OUT/new-tab-diff-mode-$3.screen.txt)"
  echo "ok: $1 in tab page $2, mode $mode"
}

"$V" doctor >"$OUT/new-tab-diff-mode-doctor.txt" || fail "doctor failed: $(cat "$OUT/new-tab-diff-mode-doctor.txt")"

step "The user opens the Claude terminal, then goes back to the editor in Normal mode"
"$V" keys ':ClaudeCode' Enter
"$V" until '&buftype' terminal
"$V" keys "Ctrl+\\" 'Ctrl+N'
"$V" keys ':wincmd p' Enter
"$V" until 'mode(1) . bufname()' 'nhello.txt'
"$V" capture new-tab-diff-mode-1-editor >/dev/null

step "Claude proposes d1; it opens in a new tab"
open_diff d1 hello.txt $'alpha\nBETA\ngamma\n'
expect_proposal_in_normal_mode d1 2 2-first

step "Claude proposes d2 while d1 is open; it opens in a second new tab"
open_diff d2 other.txt $'one\nTWO\nthree\nfour\n'
expect_proposal_in_normal_mode d2 3 3-second

step "Claude closes both tabs, newest first"
"$V" tool c2 close_tab "$(jq -nc --arg t "$(tab_name d2)" '{tab_name:$t}')"
[[ $("$V" await c2 10 | jq -r '.result.content[0].text') == TAB_CLOSED ]] || fail "close_tab c2 did not answer TAB_CLOSED"
"$V" tool c1 close_tab "$(jq -nc --arg t "$(tab_name d1)" '{tab_name:$t}')"
[[ $("$V" await c1 10 | jq -r '.result.content[0].text') == TAB_CLOSED ]] || fail "close_tab c1 did not answer TAB_CLOSED"
"$V" until "tabpagenr('\$') . mode(1) . bufname()" '1nhello.txt'
"$V" capture new-tab-diff-mode-4-closed >/dev/null
echo "PASS new-tab-diff-mode; evidence in $OUT"
