#!/usr/bin/env bash
# Claude exits while the user is in the command-line window (`q:`) with two openDiff calls waiting: both calls are
# answered at once, and both diffs close once the user leaves that window. Needs VCN_STATE from a fresh `vcn.sh launch`
# (hello.txt open). Evidence lands in $OUT as diff-disconnect-cmdwin-*.
set -euo pipefail
V="$(dirname "${BASH_SOURCE[0]}")/vcn.sh"
# shellcheck source=/dev/null
source "$VCN_STATE/run.env"

fail() {
  echo "FAIL: $*" >&2
  "$V" capture diff-disconnect-cmdwin-failure >/dev/null || true
  exit 1
}
step() { echo "== $*"; }
tab_name() { printf '✻ [Claude Code] %s (%s) ⧉' "$1" "$2"; }

# The diffs as "<pending>/<rejected>/<saved>" counts, the proposal buffers that exist, and the senders that still wait.
statuses() {
  "$V" expr "luaeval('(function() local n = {pending = 0, rejected = 0, saved = 0}; for _, d in pairs(require(\"claudecode.diff\")._get_active_diffs()) do n[d.status] = n[d.status] + 1 end; return n.pending .. \"/\" .. n.rejected .. \"/\" .. n.saved end)()')"
}
proposals() {
  "$V" expr "luaeval('#vim.tbl_filter(function(b) return vim.api.nvim_buf_get_name(b):find(\"(proposed)\", 1, true) ~= nil end, vim.api.nvim_list_bufs())')"
}
senders() { "$V" expr "luaeval('vim.tbl_count(_G.claude_deferred_responses or {})')"; }
snapshot() { echo "statuses=$(statuses) proposals=$(proposals) senders=$(senders) cmdwin='$("$V" expr 'getcmdwintype()')'"; }

"$V" doctor >"$OUT/diff-disconnect-cmdwin-doctor.txt" || fail "doctor failed: $(cat "$OUT/diff-disconnect-cmdwin-doctor.txt")"

step "Claude proposes d1 for hello.txt in the first tab"
"$V" tool d1 openDiff "$(jq -nc --arg p "$WORK/hello.txt" --arg t "$(tab_name hello.txt d1)" \
  '{old_file_path:$p,new_file_path:$p,new_file_contents:"alpha\nBETA\ngamma\n",tab_name:$t}')"
"$V" until "bufname() =~# '(d1) ⧉ (proposed)$'" 1

step "The user opens an empty tab, so Claude's d2 for other.txt opens in the current tab"
"$V" keys ':tabnew' Enter
"$V" until 'tabpagenr()' 2
"$V" tool d2 openDiff "$(jq -nc --arg p "$WORK/other.txt" --arg t "$(tab_name other.txt d2)" \
  '{old_file_path:$p,new_file_path:$p,new_file_contents:"one\nTWO\nthree\nfour\n",tab_name:$t}')"
"$V" until "bufname() =~# '(d2) ⧉ (proposed)$'" 1
[[ $(statuses) == 2/0/0 && $(proposals) == 2 && $(senders) == 2 ]] || fail "setup: $(snapshot)"

step "The user opens the command-line window"
"$V" keys 'q:'
"$V" until 'getcmdwintype()' ':'
"$V" capture diff-disconnect-cmdwin-1-in-window >/dev/null
"$V" screenshot diff-disconnect-cmdwin-1-in-window >/dev/null

step "Claude exits: its socket closes while the window is open"
"$V" disconnect
"$V" until "luaeval('(function() local n = 0; for _, d in pairs(require(\"claudecode.diff\")._get_active_diffs()) do if d.status == \"pending\" then n = n + 1 end end; return n end)()')" 0 5 ||
  fail "a call is still waiting for its answer after Claude exited: $(snapshot)"
[[ $(senders) == 0 ]] || fail "a response sender is still registered: $(snapshot)"
[[ $(statuses) == 0/2/0 ]] || fail "both diffs should be rejected: $(snapshot)"
messages=$("$V" expr 'execute("messages")')
[[ $messages != *E11* && $messages != *E565* ]] || fail "the cleanup raised in the command-line window: $messages"
[[ $(proposals) == 2 ]] || fail "the proposals closed while windows could not change: $(snapshot)"
"$V" capture diff-disconnect-cmdwin-2-after-exit >/dev/null
echo "ok: both calls answered, diffs held while the window is open: $(snapshot)"

step "The user leaves the command-line window; both diffs close"
"$V" keys ':quit' Enter
"$V" until 'getcmdwintype()' ''
"$V" until "luaeval('vim.tbl_count(require(\"claudecode.diff\")._get_active_diffs())')" 0 5 ||
  fail "a rejected diff kept its registry entry after the window closed: $(snapshot)"
[[ $(proposals) == 0 ]] || fail "a proposal buffer is left after its diff closed: $(snapshot)"
"$V" capture diff-disconnect-cmdwin-3-closed >/dev/null
"$V" screenshot diff-disconnect-cmdwin-3-closed >/dev/null
"$V" record diff-disconnect-cmdwin >/dev/null
echo "PASS diff-disconnect-cmdwin; evidence in $OUT"
