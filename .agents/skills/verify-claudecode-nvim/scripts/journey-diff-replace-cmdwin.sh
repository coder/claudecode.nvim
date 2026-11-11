#!/usr/bin/env bash
# A second Claude client sends openDiff with the tab name of an open diff while the user is in the command-line window
# (`q:`): the first call is answered, the new call gets an error answer (Neovim refuses the new windows), nothing raises
# in the cleanup, and the old diff closes once the user leaves that window. Needs VCN_STATE from a fresh `vcn.sh launch`
# (hello.txt open). Evidence lands in $OUT as diff-replace-cmdwin-*.
set -euo pipefail
V="$(dirname "${BASH_SOURCE[0]}")/vcn.sh"
# shellcheck source=/dev/null
source "$VCN_STATE/run.env"

fail() {
  echo "FAIL: $*" >&2
  "$V" capture diff-replace-cmdwin-failure >/dev/null || true
  exit 1
}
step() { echo "== $*"; }
TAB=$(printf '✻ [Claude Code] hello.txt (%s) ⧉' shared)

statuses() {
  "$V" expr "luaeval('(function() local n = {pending = 0, rejected = 0, saved = 0}; for _, d in pairs(require(\"claudecode.diff\")._get_active_diffs()) do n[d.status] = n[d.status] + 1 end; return n.pending .. \"/\" .. n.rejected .. \"/\" .. n.saved end)()')"
}
proposals() {
  "$V" expr "luaeval('#vim.tbl_filter(function(b) return vim.api.nvim_buf_get_name(b):find(\"(proposed)\", 1, true) ~= nil end, vim.api.nvim_list_bufs())')"
}
snapshot() { echo "statuses=$(statuses) proposals=$(proposals) cmdwin='$("$V" expr 'getcmdwintype()')'"; }

"$V" doctor >"$OUT/diff-replace-cmdwin-doctor.txt" || fail "doctor failed: $(cat "$OUT/diff-replace-cmdwin-doctor.txt")"

step "Claude proposes d1 under one tab name; a second Claude client b connects"
"$V" tool d1 openDiff "$(jq -nc --arg p "$WORK/hello.txt" --arg t "$TAB" \
  '{old_file_path:$p,new_file_path:$p,new_file_contents:"alpha\nBETA\ngamma\n",tab_name:$t}')"
"$V" until "bufname() =~# '(shared) ⧉ (proposed)$'" 1
VCN_CLIENT=b "$V" connect
[[ $(statuses) == 1/0/0 && $(proposals) == 1 ]] || fail "setup: $(snapshot)"

step "The user opens the command-line window"
"$V" keys 'q:'
"$V" until 'getcmdwintype()' ':'
"$V" capture diff-replace-cmdwin-1-in-window >/dev/null
"$V" screenshot diff-replace-cmdwin-1-in-window >/dev/null

step "Client b sends openDiff with the same tab name"
VCN_CLIENT=b "$V" tool r1 openDiff "$(jq -nc --arg p "$WORK/other.txt" --arg t "$TAB" \
  '{old_file_path:$p,new_file_path:$p,new_file_contents:"one\nTWO\nthree\nfour\n",tab_name:$t}')"
VCN_CLIENT=b "$V" await r1 10 >"$OUT/diff-replace-cmdwin-b-answer.json" || fail "b's call got no answer"
jq -e '.error.code == -32000' "$OUT/diff-replace-cmdwin-b-answer.json" >/dev/null ||
  fail "b's call should get error -32000 while windows cannot change: $(cat "$OUT/diff-replace-cmdwin-b-answer.json")"
jq -e '(.error.data // "") | contains("diffoff") | not' "$OUT/diff-replace-cmdwin-b-answer.json" >/dev/null ||
  fail "the cleanup of the old diff raised in the command-line window: $(cat "$OUT/diff-replace-cmdwin-b-answer.json")"
"$V" await d1 10 >"$OUT/diff-replace-cmdwin-a-answer.json" || fail "the first call got no answer"
jq -e '.result.content[0].text == "DIFF_REJECTED"' "$OUT/diff-replace-cmdwin-a-answer.json" >/dev/null ||
  fail "the first call should be answered DIFF_REJECTED: $(cat "$OUT/diff-replace-cmdwin-a-answer.json")"
# The refused setup logs an ERROR line wider than the screen, so Neovim waits at Press ENTER and RPC stops answering.
"$V" capture diff-replace-cmdwin-2-error-prompt >/dev/null
"$V" keys Enter
"$V" until 'getcmdwintype()' ':'
[[ $(statuses) == 0/1/0 && $(proposals) == 1 ]] || fail "the old diff should wait, rejected, while the window is open: $(snapshot)"
"$V" capture diff-replace-cmdwin-3-after-replace >/dev/null
echo "ok: first call answered, b got an error, the old diff waits: $(snapshot)"

step "The user leaves the command-line window; the old diff closes"
"$V" keys ':quit' Enter
"$V" until 'getcmdwintype()' ''
"$V" until "luaeval('vim.tbl_count(require(\"claudecode.diff\")._get_active_diffs())')" 0 5 ||
  fail "the rejected diff kept its registry entry after the window closed: $(snapshot)"
[[ $(proposals) == 0 ]] || fail "a proposal buffer is left after its diff closed: $(snapshot)"
"$V" capture diff-replace-cmdwin-4-closed >/dev/null
"$V" screenshot diff-replace-cmdwin-4-closed >/dev/null
"$V" record diff-replace-cmdwin >/dev/null
echo "PASS diff-replace-cmdwin; evidence in $OUT"
