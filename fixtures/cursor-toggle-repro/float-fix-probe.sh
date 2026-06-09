#!/usr/bin/env bash
#
# Candidate-fix validation for issue #183. Identical harness to float-repro.sh,
# except the hide/show toggle goes through <leader>ah -> :ReproConfigHideToggle,
# which hides the Snacks FLOAT via nvim_win_set_config{hide=true/false} instead
# of letting Snacks close+recreate the window. The triage predicts this keeps the
# window object (libvterm grid + cursor anchor) alive, so Claude's focus-in
# repaint stays aligned and delta stays 0 across toggles.
#
# Compare directly against float-repro.sh:
#   float-repro.sh   (Snacks close+recreate):  delta 0 -> 1 (BUG)
#   float-fix-probe.sh (config-hide):          expect delta 0 -> 0 (FIXED)
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

command -v agent-tty >/dev/null || {
  echo "ERROR: agent-tty not found"
  exit 1
}

WORK="${CLAUDE_JOB_DIR:-/tmp}/tmp/float-fix.$$"
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

measure() {
  "${a[@]}" snapshot "$1" --json 2>/dev/null | python3 -c '
import json,sys
r=json.load(sys.stdin)["result"]
rows=[l["row"] for l in r["visibleLines"] if "❯" in l["text"]]
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

# Toggle via the config-hide path (<leader>ah).
toggle_cycle() {
  local sid="$1"
  "${a[@]}" send-keys "$sid" 'C-Backslash' 'C-n' --json >/dev/null 2>&1
  "${a[@]}" send-keys "$sid" 'C-w' 'h' --json >/dev/null 2>&1
  "${a[@]}" wait "$sid" --screen-stable-ms 400 --timeout-ms 8000 --json >/dev/null 2>&1
  "${a[@]}" type "$sid" ' ah' --json >/dev/null 2>&1 # hide (config)
  "${a[@]}" wait "$sid" --screen-stable-ms 500 --timeout-ms 8000 --json >/dev/null 2>&1
  "${a[@]}" type "$sid" ' ah' --json >/dev/null 2>&1 # show (config)
  "${a[@]}" wait "$sid" --screen-stable-ms 900 --timeout-ms 8000 --json >/dev/null 2>&1
}

sid="$("${a[@]}" create --json --cols 120 --rows 40 -- \
  bash -lc "cd '$FIX_DIR' && CURSOR_REPRO_PROVIDER=snacks CURSOR_REPRO_POSITION=float NVIM_APPNAME=cursor-toggle-repro XDG_CONFIG_HOME='$FIX_DIR' $NVIM '$WORK/sample.txt'" |
  python3 -c "import json,sys;print(json.load(sys.stdin)['result']['sessionId'])")"

# shellcheck disable=SC2086
echo "Neovim: $($NVIM --version | head -1)"
echo "Claude: $(claude --version 2>/dev/null | head -1 || echo '??')"
echo "== provider=snacks (float) + CONFIG-HIDE toggle (candidate fix), cycles=$CYCLES =="
"${a[@]}" wait "$sid" --screen-stable-ms 1800 --timeout-ms 20000 --json >/dev/null 2>&1
"${a[@]}" type "$sid" ' ah' --json >/dev/null 2>&1 # first <leader>ah -> Snacks creates+shows float
if ! "${a[@]}" wait "$sid" --text 'auto mode' --timeout-ms 40000 --json >/dev/null 2>&1; then
  echo "   SKIP: Claude did not reach its prompt (not logged in?)."
  "${a[@]}" destroy "$sid" --json >/dev/null 2>&1
  exit 0
fi
"${a[@]}" wait "$sid" --screen-stable-ms 1500 --timeout-ms 20000 --json >/dev/null 2>&1
echo "   baseline:        $(measure "$sid")"
for i in $(seq 1 "$CYCLES"); do
  toggle_cycle "$sid"
  echo "   after toggle $i:  $(measure "$sid")"
done
"${a[@]}" type "$sid" 'ZZZQ' --json >/dev/null 2>&1
"${a[@]}" wait "$sid" --screen-stable-ms 800 --timeout-ms 8000 --json >/dev/null 2>&1
echo "   --- final screen (typed marker 'ZZZQ') ---"
dump "$sid" | sed 's/^/     /'
"${a[@]}" send-keys "$sid" 'C-Backslash' 'C-n' --json >/dev/null 2>&1
"${a[@]}" type "$sid" ':qa!' --json >/dev/null 2>&1
"${a[@]}" send-keys "$sid" Enter --json >/dev/null 2>&1
sleep 0.3
"${a[@]}" destroy "$sid" --json >/dev/null 2>&1
echo
echo "PASS if delta stays 0 across toggles and 'ZZZQ' lands after ❯ (not on the box border)."
