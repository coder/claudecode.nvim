#!/usr/bin/env bash
#
# Closes the adversarial gap flagged in the #183 deep-research review: we had
# measured box.py's FOCUS/SIGWINCH events but NOT its visual cursor delta. This
# runs box.py (synthetic TUI using ABSOLUTE positioning, CSI row;col H) under the
# Snacks float and measures cursorRow vs its "> " prompt row across snacks
# close+recreate toggles — the same churn that drifts the real Claude CLI by 1 row.
#
# If box.py stays at delta=0, absolute positioning is immune and the drift is
# Claude's cursor-RELATIVE Ink repaint (chain holds). If box.py ALSO drifts, the
# cause is a Neovim PTY/window coordinate mismatch, not Ink — and the whole
# diagnosis flips.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIX_DIR="$(dirname "$HERE")"
CYCLES="${CYCLES:-5}"
export _ZO_DOCTOR=0
if [ -n "${NVIM_BIN:-}" ]; then
  NVIM="$NVIM_BIN"
elif command -v mise >/dev/null 2>&1; then
  NVIM="mise exec -- nvim"
else NVIM="nvim"; fi

WORK="${CLAUDE_JOB_DIR:-/tmp}/tmp/box-delta.$$"
rm -rf "$WORK"
mkdir -p "$WORK"
AGENT_HOME="$WORK/atty-home"
mkdir -p "$AGENT_HOME"
trap 'agent-tty --home "$AGENT_HOME" gc --json >/dev/null 2>&1; rm -rf "$WORK"' EXIT
python3 - "$WORK/sample.txt" <<'PY'
import sys
open(sys.argv[1], "w").write("\n".join("line %02d" % i for i in range(1, 61)) + "\n")
PY
a=(agent-tty --home "$AGENT_HOME")

# box.py draws "> " (strips to ">") on its prompt row and parks the cursor there.
measure() {
  "${a[@]}" snapshot "$1" --json 2>/dev/null | python3 -c '
import json,sys
r=json.load(sys.stdin)["result"]
rows=[l["row"] for l in r["visibleLines"] if "> " in l["text"]]
prow=rows[-1] if rows else None
cur=r["cursorRow"]
delta=(prow-cur) if prow is not None else None
print(f"cursorRow={cur} promptRow={prow} delta={delta}")
'
}
dump() {
  "${a[@]}" snapshot "$1" --json 2>/dev/null | python3 -c '
import json,sys
r=json.load(sys.stdin)["result"]
print("cursorRow=%s cursorCol=%s"%(r.get("cursorRow"),r.get("cursorCol")))
for l in r["visibleLines"]:
    t=l["text"].rstrip()
    if t: print("%3d| %s"%(l["row"], t))
'
}
toggle_cycle() {
  local sid="$1"
  "${a[@]}" send-keys "$sid" 'C-Backslash' 'C-n' --json >/dev/null 2>&1
  "${a[@]}" send-keys "$sid" 'C-w' 'h' --json >/dev/null 2>&1
  "${a[@]}" wait "$sid" --screen-stable-ms 400 --timeout-ms 8000 --json >/dev/null 2>&1
  "${a[@]}" type "$sid" ' ac' --json >/dev/null 2>&1
  "${a[@]}" wait "$sid" --screen-stable-ms 500 --timeout-ms 8000 --json >/dev/null 2>&1
  "${a[@]}" type "$sid" ' ac' --json >/dev/null 2>&1
  "${a[@]}" wait "$sid" --screen-stable-ms 800 --timeout-ms 8000 --json >/dev/null 2>&1
}
sid="$("${a[@]}" create --json --cols 120 --rows 40 -- \
  bash -lc "cd '$FIX_DIR' && CURSOR_REPRO_PROVIDER=snacks CURSOR_REPRO_POSITION=float CURSOR_REPRO_CMD='python3 $HERE/box.py' NVIM_APPNAME=cursor-toggle-repro XDG_CONFIG_HOME='$FIX_DIR' $NVIM '$WORK/sample.txt'" |
  python3 -c "import json,sys;print(json.load(sys.stdin)['result']['sessionId'])")"
echo "Neovim: $($NVIM --version | head -1)   (box.py = absolute-positioning synthetic TUI, snacks float)"
"${a[@]}" wait "$sid" --screen-stable-ms 1500 --timeout-ms 15000 --json >/dev/null 2>&1
"${a[@]}" type "$sid" ' ac' --json >/dev/null 2>&1
"${a[@]}" wait "$sid" --text 'synthetic claude' --timeout-ms 15000 --json >/dev/null 2>&1
"${a[@]}" wait "$sid" --screen-stable-ms 700 --timeout-ms 8000 --json >/dev/null 2>&1
echo "   baseline:        $(measure "$sid")"
for i in $(seq 1 "$CYCLES"); do
  toggle_cycle "$sid"
  echo "   after toggle $i:  $(measure "$sid")"
done
echo "   --- final screen (box.py absolute prompt) ---"
dump "$sid" | sed 's/^/     /'
"${a[@]}" send-keys "$sid" 'C-Backslash' 'C-n' --json >/dev/null 2>&1
"${a[@]}" type "$sid" ':qa!' --json >/dev/null 2>&1
"${a[@]}" send-keys "$sid" Enter --json >/dev/null 2>&1
sleep 0.3
"${a[@]}" destroy "$sid" --json >/dev/null 2>&1
echo
echo "delta=0 across toggles -> absolute positioning IS immune -> drift is Claude's relative repaint (chain holds)."
echo "delta!=0 -> a Neovim PTY/window coordinate mismatch, NOT Ink -> diagnosis flips."
