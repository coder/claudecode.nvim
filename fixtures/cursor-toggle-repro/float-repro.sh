#!/usr/bin/env bash
#
# Reproduction of claudecode.nvim issue #183 — "Input cursor in floating mode
# moves upwards every time I toggle" — driven through a real Neovim TUI inside an
# isolated agent-tty session.
#
# This is the FLOAT-specific sibling of agent-repro.sh (which targets the #240
# vertical-split case). It launches the Snacks terminal provider with
# `position = "float"` (the exact layout from the bug report), opens the real
# Claude CLI, then hides + re-shows the float CYCLES times. After each cycle it
# prints the delta between Claude's "❯" prompt row and the terminal cursor row:
#
#     delta = promptRow - cursorRow
#       0  -> aligned (cursor sits on the ❯ line, correct)
#      >0  -> BUG: cursor is delta rows ABOVE the prompt (the "climbing cursor")
#
# #183 reports the drift ACCUMULATES per toggle, so under snacks/float we expect
# delta to grow 0 -> 1 -> 2 -> ...  The native provider is run as a control and
# should stay at delta 0.
#
# Finally it focuses the float and types a visible marker ("ZZZQ") so the snapshot
# shows where typed text actually lands relative to the prompt box.
#
# Requirements: agent-tty, python3, nvim (mise), snacks.nvim, a logged-in `claude`.
#
# Usage:
#   ./float-repro.sh                 # 5 hide/show cycles, providers: snacks native
#   CYCLES=8 ./float-repro.sh
#   PROVIDERS="snacks" ./float-repro.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" # .../fixtures/cursor-toggle-repro
FIX_DIR="$(dirname "$HERE")"                         # .../fixtures
CYCLES="${CYCLES:-5}"
PROVIDERS="${PROVIDERS:-snacks native}"
export _ZO_DOCTOR=0

if [ -n "${NVIM_BIN:-}" ]; then
  NVIM="$NVIM_BIN"
elif command -v mise >/dev/null 2>&1; then
  NVIM="mise exec -- nvim"
else
  NVIM="nvim"
fi

command -v agent-tty >/dev/null || {
  echo "ERROR: agent-tty not found"
  exit 1
}
command -v python3 >/dev/null || {
  echo "ERROR: python3 not found"
  exit 1
}

WORK="${CLAUDE_JOB_DIR:-/tmp}/tmp/float-repro.$$"
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

# measure <sid> -> "cursorRow=.. promptRow=.. delta=.."
measure() {
  local sid="$1"
  "${a[@]}" snapshot "$sid" --json 2>/dev/null | python3 -c '
import json,sys
r=json.load(sys.stdin)["result"]
rows=[l["row"] for l in r["visibleLines"] if "❯" in l["text"]]
prow=rows[-1] if rows else None
cur=r["cursorRow"]
delta=(prow-cur) if prow is not None else None
print(f"cursorRow={cur} promptRow={prow} delta={delta}")
'
}

# dump full visible screen for the final visual proof
dump() {
  local sid="$1"
  "${a[@]}" snapshot "$sid" --json 2>/dev/null | python3 -c '
import json,sys
r=json.load(sys.stdin)["result"]
print("cursorRow=%s cursorCol=%s"%(r.get("cursorRow"),r.get("cursorCol")))
for l in r["visibleLines"]:
    t=l["text"].rstrip()
    if t: print("%3d| %s"%(l["row"], t))
'
}

# escape terminal-insert -> normal, move to editor window, hide float, show float.
toggle_cycle() {
  local sid="$1"
  "${a[@]}" send-keys "$sid" 'C-Backslash' 'C-n' --json >/dev/null 2>&1
  "${a[@]}" send-keys "$sid" 'C-w' 'h' --json >/dev/null 2>&1
  "${a[@]}" wait "$sid" --screen-stable-ms 400 --timeout-ms 8000 --json >/dev/null 2>&1
  "${a[@]}" type "$sid" ' ac' --json >/dev/null 2>&1 # <leader>ac -> hide
  "${a[@]}" wait "$sid" --screen-stable-ms 500 --timeout-ms 8000 --json >/dev/null 2>&1
  "${a[@]}" type "$sid" ' ac' --json >/dev/null 2>&1 # <leader>ac -> show
  "${a[@]}" wait "$sid" --screen-stable-ms 900 --timeout-ms 8000 --json >/dev/null 2>&1
}

launch() { # launch <provider> -> echoes sid
  local prov="$1"
  local env="CURSOR_REPRO_PROVIDER=$prov CURSOR_REPRO_POSITION=float"
  env="$env NVIM_APPNAME=cursor-toggle-repro XDG_CONFIG_HOME='$FIX_DIR'"
  "${a[@]}" create --json --cols 120 --rows 40 -- \
    bash -lc "cd '$FIX_DIR' && $env $NVIM '$WORK/sample.txt'" |
    python3 -c "import json,sys;print(json.load(sys.stdin)['result']['sessionId'])"
}

# shellcheck disable=SC2086
echo "Neovim: $($NVIM --version | head -1)"
echo "Claude: $(claude --version 2>/dev/null | head -1 || echo '??')"
echo "position=float  width=0.9 height=0.9  cycles=$CYCLES"
echo

for prov in $PROVIDERS; do
  echo "== provider=$prov (float) =="
  sid="$(launch "$prov")"
  "${a[@]}" wait "$sid" --screen-stable-ms 1800 --timeout-ms 20000 --json >/dev/null 2>&1
  "${a[@]}" type "$sid" ' ac' --json >/dev/null 2>&1
  if ! "${a[@]}" wait "$sid" --text 'auto mode' --timeout-ms 40000 --json >/dev/null 2>&1; then
    echo "   SKIP: Claude did not reach its prompt (not logged in?)."
    "${a[@]}" destroy "$sid" --json >/dev/null 2>&1
    continue
  fi
  "${a[@]}" wait "$sid" --screen-stable-ms 1500 --timeout-ms 20000 --json >/dev/null 2>&1
  echo "   baseline:        $(measure "$sid")"
  for i in $(seq 1 "$CYCLES"); do
    toggle_cycle "$sid"
    echo "   after toggle $i:  $(measure "$sid")"
  done
  # Type a visible marker to show where input actually lands (focus is in the float now).
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
done

echo "Interpretation: snacks/float -> delta climbs (cursor above ❯ = #183 bug);"
echo "native/float -> delta stays 0 (aligned). Same Claude binary, different provider."
