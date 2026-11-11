#!/usr/bin/env bash
# Checks that `:wq`, `:x` and `ZZ` close the proposal window, a second `:w` neither fails nor answers again, no buffer
# stays modified after an answer (so `:qa` can quit), and `:b hello.txt` or `:e other.txt` in the proposal window keeps
# that window after `close_tab`, out of diff mode and with its own sign column, and a sign column that the user sets
# after the `:e` stays. Needs VCN_STATE and OUT, the two values a fresh launch prints:
#   vcn.sh launch                                       # the split layout
#   VCN_SETUP='{"diff_opts":{"layout":"unified"}}' vcn.sh launch
# Pass `new` to propose the new file new.txt instead of hello.txt. Prints one `ok:` or `FAIL:` line per check and
# `PASS` or `FAIL: <count> of <total> checks failed` last. Evidence lands in $OUT as diff-close-save-*.
set -euo pipefail
V="$(dirname "${BASH_SOURCE[0]}")/vcn.sh"
: "${VCN_STATE:?export VCN_STATE and OUT, the two values launch printed}" "${OUT:?export VCN_STATE and OUT, the two values launch printed}"
WORK=$VCN_STATE/work
target=${1:-existing}
[[ $target == existing || $target == new ]] || {
  echo "usage: journey-diff-close-save.sh [existing|new]" >&2
  exit 2
}
file=hello.txt
[[ $target == new ]] && file=new.txt

checks=0
failures=0
check() {
  local what=$1
  shift
  checks=$((checks + 1))
  if "$@"; then
    echo "ok: $what"
  else
    failures=$((failures + 1))
    echo "FAIL: $what"
  fi
}
step() { echo "== $*"; }
tab_name() { printf '✻ [Claude Code] %s (%s) ⧉' "$file" "$1"; }

open_diff() {
  "$V" tool "$1" openDiff "$(jq -nc --arg p "$WORK/$file" --arg t "$(tab_name "$1")" \
    '{old_file_path:$p,new_file_path:$p,new_file_contents:"alpha\nBETA\ngamma\n",tab_name:$t}')"
  "$V" until "bufname() =~# '($1)'" 1 10 >/dev/null
}

answer() { "$V" await "$1" 10 | jq -r '.result.content[0].text'; }
answered() { [[ $(answer "$1") == "$2" ]]; }
answers_sent() { jq -c --arg id "$1" 'select(.id == $id)' "$OUT/ws-in.jsonl" | wc -l; }
sent_once() { [[ $(answers_sent "$1") == 1 ]]; }

proposal_windows_expr() {
  printf "luaeval('vim.tbl_count(vim.tbl_filter(function(w) return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)):find(\"(%s)\", 1, true) ~= nil end, vim.api.nvim_list_wins()))')" "$1"
}
window_closed() { "$V" until "$(proposal_windows_expr "$1")" 0 3 >/dev/null; }

# `:qa` stops with E37 or E162 on a modified buffer, except nofile and nowrite buffers, such as the new-file
# placeholder.
no_modified_buffer() {
  [[ $("$V" expr "len(filter(getbufinfo({'bufmodified': 1}), 'index([\"nofile\", \"nowrite\"], getbufvar(v:val.bufnr, \"&buftype\")) < 0'))") == 0 ]]
}
no_error() { [[ -z $("$V" expr 'v:errmsg') ]]; }

close_diff() {
  "$V" tool "c-$1" close_tab "$(jq -nc --arg t "$(tab_name "$1")" '{tab_name:$t}')"
  [[ $(answer "c-$1") == TAB_CLOSED ]]
}
back_to_one_window() { "$V" until "winnr('\$')" 1 10 >/dev/null; }
# The window count, the current buffer, and one window option per window, after close_tab.
kept_windows() {
  "$V" expr "winnr('\$') . '|' . bufname() . '|' . join(map(range(1, winnr('\$')), 'getwinvar(v:val, \"$1\")'), ',')"
}
# `:b hello.txt` puts the proposal window on the file the user has open. For an existing file that buffer is still in
# diff mode in the other window, so 'diff' stays on in the kept window until close_tab ends it.
kept_window_out_of_diff_mode() { [[ $(kept_windows '&diff') == '2|hello.txt|0,0' ]]; }
kept_window_sign_column_back() { [[ $(kept_windows '&signcolumn') == '2|other.txt|auto,auto' ]]; }
kept_window_own_sign_column() { [[ $("$V" expr "bufname() . '|' . &signcolumn") == 'other.txt|yes:2' ]]; }

"$V" doctor >"$OUT/diff-close-save-doctor.txt" || {
  echo "FAIL: doctor failed: $(cat "$OUT/diff-close-save-doctor.txt")" >&2
  exit 1
}

for save in ':wq' ':x' 'ZZ'; do
  id="save-${save//[^a-zA-Z]/}"
  step "The user saves the proposal with $save"
  open_diff "$id"
  "$V" keys "$save"
  [[ $save == ZZ ]] || "$V" keys Enter
  check "$save answers FILE_SAVED" answered "$id" FILE_SAVED
  "$V" capture "diff-close-save-$id" >/dev/null
  check "$save closes the proposal window" window_closed "$id"
  check "$save leaves no modified buffer, so :qa can quit" no_modified_buffer
  close_diff "$id" || true
  back_to_one_window || true
  check "$save sends one answer" sent_once "$id"
done

step "The user writes the proposal twice"
open_diff write-twice
"$V" keys ':w' Enter
check "the first :w answers FILE_SAVED" answered write-twice FILE_SAVED
"$V" keys ':w' Enter
"$V" capture diff-close-save-write-twice >/dev/null
check "the second :w raises no error" no_error
check "the two writes send one answer" sent_once write-twice
close_diff write-twice || true
back_to_one_window || true

step "The user rejects with :q, then wants to quit Neovim before Claude calls close_tab"
open_diff reject-quit
"$V" keys ':q' Enter
check ":q answers DIFF_REJECTED" answered reject-quit DIFF_REJECTED
"$V" capture diff-close-save-reject-quit >/dev/null
check "no buffer is modified after the :q, so :qa can quit" no_modified_buffer
close_diff reject-quit || true
back_to_one_window || true

step "The user switches the proposal window back to hello.txt with :b"
open_diff reject-leave
"$V" keys ':b hello.txt' Enter
check ":b answers DIFF_REJECTED" answered reject-leave DIFF_REJECTED
close_diff reject-leave || true
"$V" capture diff-close-save-reject-leave >/dev/null
check "close_tab keeps the user's window on hello.txt, out of diff mode" kept_window_out_of_diff_mode
"$V" keys ':only' Enter
back_to_one_window || true

step "The user switches the proposal window to other.txt with :e"
open_diff reject-other
"$V" keys ':e other.txt' Enter
check ":e answers DIFF_REJECTED" answered reject-other DIFF_REJECTED
close_diff reject-other || true
"$V" capture diff-close-save-reject-other >/dev/null
check "close_tab keeps the user's window on other.txt, with its own sign column" kept_window_sign_column_back
"$V" keys ':only' Enter
back_to_one_window || true

step "The user sets a sign column of its own in the window that :e switched to other.txt"
open_diff reject-own-sign
"$V" keys ':e other.txt' Enter
check ":e answers DIFF_REJECTED" answered reject-own-sign DIFF_REJECTED
"$V" keys ':setlocal signcolumn=yes:2' Enter
close_diff reject-own-sign || true
"$V" capture diff-close-save-reject-own-sign >/dev/null
check "close_tab leaves the sign column that the user set" kept_window_own_sign_column

if ((failures == 0)); then
  echo "PASS diff-close-save ($target): $checks checks; evidence in $OUT"
else
  echo "FAIL: $failures of $checks checks failed; evidence in $OUT" >&2
  exit 1
fi
