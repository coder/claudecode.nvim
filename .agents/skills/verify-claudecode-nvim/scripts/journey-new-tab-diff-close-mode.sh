#!/usr/bin/env bash
# Claude closes a diff that opened in a new tab while the user has left that tab's Claude terminal in terminal-normal
# mode, and again after the user went back to the first tab. The cursor ends in the user's file in Normal mode, and
# the next key moves the cursor instead of typing into the file. Needs VCN_STATE from a launch with a real Claude
# terminal and diff_opts.open_in_new_tab, for example:
#   VCN_SETUP='{"terminal_cmd":"sleep 300","terminal":{"provider":"native"},"diff_opts":{"open_in_new_tab":true}}' vcn.sh launch
# Add "layout":"unified" to diff_opts for the unified layout. For the snacks provider, set terminal.provider to
# "snacks" and launch with `--cmd "set rtp^=<snacks.nvim dir>"`. Evidence lands in $OUT as new-tab-diff-close-*.
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
  "$V" tool "$1" openDiff "$(jq -nc --arg p "$WORK/hello.txt" --arg t "$(tab_name "$1")" --arg c $'alpha\nBETA\ngamma\n' \
    '{old_file_path:$p,new_file_path:$p,new_file_contents:$c,tab_name:$t}')"
  "$V" until "bufname() =~# '($1)' && tabpagenr() == 2" 1 10
  "$V" until 'mode(1)' n
}

close_and_check() {
  local id=$1 label=$2 mode text
  "$V" tool "c-$id" close_tab "$(jq -nc --arg t "$(tab_name "$id")" '{tab_name:$t}')"
  [[ $("$V" await "c-$id" 10 | jq -r '.result.content[0].text') == TAB_CLOSED ]] || fail "close_tab c-$id did not answer TAB_CLOSED"
  "$V" until "tabpagenr('\$') . bufname()" 1hello.txt
  # Nothing signals that an insert did not start, so wait for a pending one before reading the mode.
  sleep 0.5
  mode=$("$V" expr 'mode(1)')
  "$V" capture "new-tab-diff-close-$label" >/dev/null
  [[ $mode == n ]] || fail "after close_tab the file is in mode '$mode', not 'n' (see $OUT/new-tab-diff-close-$label.screen.txt)"
  "$V" keys l
  sleep 0.3
  text=$("$V" expr "join(getbufline(bufnr('hello.txt'), 1, '\$'), '|') . '|' . &modified")
  [[ $text == 'alpha|beta|gamma|0' ]] || fail "the key typed after close_tab changed the file: '$text'"
  echo "ok: $label: mode $mode, the file is unchanged"
}

"$V" doctor >"$OUT/new-tab-diff-close-doctor.txt" || fail "doctor failed: $(cat "$OUT/new-tab-diff-close-doctor.txt")"

step "The user opens the Claude terminal, then goes back to the editor in Normal mode"
"$V" keys ':ClaudeCode' Enter
"$V" until '&buftype' terminal
"$V" keys "Ctrl+\\" 'Ctrl+N'
"$V" keys ':wincmd p' Enter
"$V" until 'mode(1) . bufname()' 'nhello.txt'

step "Claude proposes d1; the user focuses the terminal in that tab and leaves terminal mode"
open_diff d1
"$V" keys Ctrl+W l
"$V" until '&buftype . mode(1)' terminalt
"$V" keys "Ctrl+\\" 'Ctrl+N'
"$V" until '&buftype . mode(1)' terminalnt
"$V" capture new-tab-diff-close-1-terminal-normal >/dev/null

step "Claude closes d1 while the cursor is in that terminal"
close_and_check d1 2-terminal-normal

step "Claude proposes d2; the user focuses the terminal, leaves terminal mode, and goes back to the first tab"
open_diff d2
"$V" keys Ctrl+W l
"$V" until '&buftype . mode(1)' terminalt
"$V" keys "Ctrl+\\" 'Ctrl+N'
"$V" until '&buftype . mode(1)' terminalnt
"$V" keys ':tabfirst' Enter
"$V" until "tabpagenr() . bufname() . mode(1)" 1hello.txtn
"$V" capture new-tab-diff-close-3-other-tab >/dev/null

step "Claude closes d2 while the cursor is in the first tab"
close_and_check d2 4-first-tab
echo "PASS new-tab-diff-close-mode; evidence in $OUT"
