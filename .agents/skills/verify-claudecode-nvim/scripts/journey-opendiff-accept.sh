#!/usr/bin/env bash
# openDiff accept via :w, from a fresh `vcn.sh launch` (hello.txt open). Needs VCN_STATE.
# Evidence lands in $OUT as opendiff-accept-*.
set -euo pipefail
V="$(dirname "${BASH_SOURCE[0]}")/vcn.sh"
# shellcheck source=/dev/null
source "$VCN_STATE/run.env"
FILE="$WORK/hello.txt"
TAB="✻ [Claude Code] hello.txt (vcn) ⧉"
PROPOSED=$'alpha\nBETA\ngamma\n'
ACCEPTED=$'alpha\nBETA\nGAMMA user edit\n'

fail() {
  echo "FAIL: $*" >&2
  exit 1
}
step() { echo "== $*"; }
sha() { sha256sum "$FILE" | cut -d' ' -f1; }
disk() { echo "$1 $(sha)" >>"$OUT/opendiff-accept-disk.txt"; }

"$V" doctor >"$OUT/opendiff-accept-doctor.txt" || fail "doctor failed: $(cat "$OUT/opendiff-accept-doctor.txt")"
before=$(sha)
disk before-openDiff

step "Claude calls openDiff; the call blocks"
"$V" tool diff1 openDiff "$(jq -nc --arg p "$FILE" --arg c "$PROPOSED" --arg t "$TAB" \
  '{old_file_path:$p,new_file_path:$p,new_file_contents:$c,tab_name:$t}')"
"$V" until "bufname() ==# '$TAB (proposed)' && &diff" 1
if "$V" await diff1 2 >/dev/null 2>&1; then fail "openDiff answered before the user acted"; fi
"$V" capture opendiff-accept-1-open >/dev/null
"$V" screenshot opendiff-accept-1-open >/dev/null

step "User edits line 3 of the proposal and saves with :w"
"$V" keys ':3' Enter cc
"$V" keys -l 'GAMMA user edit'
"$V" keys Escape
"$V" until 'mode() . getline(3)' 'nGAMMA user edit'
"$V" capture opendiff-accept-2-edited >/dev/null
"$V" screenshot opendiff-accept-2-edited >/dev/null
[[ $(sha) == "$before" ]] || fail "file changed before :w"
"$V" keys ':w' Enter
"$V" await diff1 10 >"$OUT/opendiff-accept-response.json"
jq -e --arg want "$ACCEPTED" '.result.content | .[0].text == "FILE_SAVED" and .[1].text == $want' \
  "$OUT/opendiff-accept-response.json" >/dev/null ||
  fail "response is not FILE_SAVED with the user-edited text: $(cat "$OUT/opendiff-accept-response.json")"
disk after-:w
[[ $(sha) == "$before" ]] || fail "plugin wrote the file; Claude must write it"
"$V" capture opendiff-accept-3-saved >/dev/null
"$V" screenshot opendiff-accept-3-saved >/dev/null

step "Claude writes the accepted text and closes the diff tab"
jq -j '.result.content[1].text' "$OUT/opendiff-accept-response.json" >"$FILE"
disk after-client-write
"$V" tool close1 close_tab "$(jq -nc --arg t "$TAB" '{tab_name:$t}')"
[[ $("$V" await close1 10 | jq -r '.result.content[0].text') == TAB_CLOSED ]] || fail "close_tab did not answer TAB_CLOSED"
"$V" until "winnr('\$') . &diff . bufname()" '10hello.txt'
"$V" until "join(getline(1, '\$'), '|')" 'alpha|BETA|GAMMA user edit'
"$V" capture opendiff-accept-4-closed >/dev/null
"$V" record opendiff-accept >/dev/null
echo "PASS opendiff-accept; evidence in $OUT"
