#!/usr/bin/env bash
#
# #183 instrument refresh: run box.py (synthetic TUI that enables focus reporting
# DECSET ?1004 and logs every input byte + SIGWINCH) as the terminal command under
# the Snacks FLOAT, toggle it CYCLES times via the normal Snacks close+recreate
# path (<leader>ac), and report SIGWINCH vs FOCUS event counts. Confirms (freshly,
# on the current snacks/nvim) that the toggle sends focus-out/in but NO SIGWINCH,
# i.e. the "pty resize / SIGWINCH" the community fixes blame does not occur.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIX_DIR="$(dirname "$HERE")"
CYCLES="${CYCLES:-4}"
export _ZO_DOCTOR=0
if [ -n "${NVIM_BIN:-}" ]; then
  NVIM="$NVIM_BIN"
elif command -v mise >/dev/null 2>&1; then
  NVIM="mise exec -- nvim"
else NVIM="nvim"; fi

WORK="${CLAUDE_JOB_DIR:-/tmp}/tmp/box-float.$$"
rm -rf "$WORK"
mkdir -p "$WORK"
AGENT_HOME="$WORK/atty-home"
mkdir -p "$AGENT_HOME"
BOXLOG="$WORK/box.log"
trap 'agent-tty --home "$AGENT_HOME" gc --json >/dev/null 2>&1; rm -rf "$WORK"' EXIT
python3 - "$WORK/sample.txt" <<'PY'
import sys
open(sys.argv[1], "w").write("\n".join("line %02d" % i for i in range(1, 61)) + "\n")
PY
a=(agent-tty --home "$AGENT_HOME")
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
  bash -lc "cd '$FIX_DIR' && CURSOR_REPRO_PROVIDER=snacks CURSOR_REPRO_POSITION=float CURSOR_REPRO_CMD='python3 $HERE/box.py' CURSOR_REPRO_BOX_LOG='$BOXLOG' NVIM_APPNAME=cursor-toggle-repro XDG_CONFIG_HOME='$FIX_DIR' $NVIM '$WORK/sample.txt'" |
  python3 -c "import json,sys;print(json.load(sys.stdin)['result']['sessionId'])")"
"${a[@]}" wait "$sid" --screen-stable-ms 1500 --timeout-ms 15000 --json >/dev/null 2>&1
"${a[@]}" type "$sid" ' ac' --json >/dev/null 2>&1
"${a[@]}" wait "$sid" --text 'synthetic claude' --timeout-ms 15000 --json >/dev/null 2>&1
"${a[@]}" wait "$sid" --screen-stable-ms 700 --timeout-ms 8000 --json >/dev/null 2>&1
for _ in $(seq 1 "$CYCLES"); do toggle_cycle "$sid"; done
"${a[@]}" send-keys "$sid" 'C-Backslash' 'C-n' --json >/dev/null 2>&1
"${a[@]}" type "$sid" ':qa!' --json >/dev/null 2>&1
"${a[@]}" send-keys "$sid" Enter --json >/dev/null 2>&1
sleep 0.3
"${a[@]}" destroy "$sid" --json >/dev/null 2>&1
winch="$(grep -c SIGWINCH "$BOXLOG" 2>/dev/null || true)"
winch="${winch:-0}"
fin="$(grep -c 'FOCUS_IN' "$BOXLOG" 2>/dev/null || true)"
fin="${fin:-0}"
fout="$(grep -c 'FOCUS_OUT' "$BOXLOG" 2>/dev/null || true)"
fout="${fout:-0}"
echo "Neovim: $($NVIM --version | head -1)   cycles=$CYCLES (snacks float, close+recreate toggle)"
echo "  SIGWINCH events on toggle: $winch   (expect 0 -> NOT a pty resize)"
echo "  FOCUS_IN  (ESC[I) events:  $fin"
echo "  FOCUS_OUT (ESC[O) events:  $fout   (focus churn present on every hide/show)"
