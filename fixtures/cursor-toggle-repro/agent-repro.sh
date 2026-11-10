#!/usr/bin/env bash
#
# Reproduction of claudecode.nvim issue #240 / #183 — the "climbing cursor" bug,
# driven through a real Neovim TUI inside an isolated agent-tty session.
#
# Symptom: with the Snacks terminal provider (LazyVim's default), hiding and then
# re-showing the Claude side panel leaves the terminal cursor ONE ROW ABOVE
# Claude's "❯" input prompt, so typed text lands on the wrong line (#240). On a
# floating window the same drift accumulates per toggle (#183).
#
# This script runs two independent checks:
#
#   PART A — instrument (NO auth needed): runs box.py (a synthetic TUI that enables
#   focus reporting and logs every byte + SIGWINCH it receives) as the terminal
#   command, toggles the window, and shows that Neovim sends focus-out/in
#   (ESC[O / ESC[I) on hide/show but NO SIGWINCH (pty size constant). This is the
#   real trigger — not the "SIGWINCH" the community fixes assumed.
#
#   PART B — drift repro (needs a working `claude`): runs the REAL Claude CLI under
#   the snacks provider (drifts) and the native provider (does not) and prints the
#   cursor-vs-prompt delta after each toggle. delta 0 = aligned, delta 1 = bug.
#
# Requirements: agent-tty, python3, nvim, snacks.nvim installed somewhere the
# fixture can find it (see init.lua). For PART B also a logged-in `claude`.
#
# Usage:
#   ./agent-repro.sh                       # uses `nvim` on PATH (or mise)
#   NVIM_BIN=/path/to/nvim ./agent-repro.sh
#   CYCLES=6 ./agent-repro.sh              # more hide/show cycles
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" # .../fixtures/cursor-toggle-repro
FIX_DIR="$(dirname "$HERE")"                         # .../fixtures
CYCLES="${CYCLES:-4}"
export _ZO_DOCTOR=0

if [ -n "${NVIM_BIN:-}" ]; then
  NVIM="$NVIM_BIN"
elif command -v mise >/dev/null 2>&1; then
  NVIM="mise exec -- nvim"
else
  NVIM="nvim"
fi

command -v agent-tty >/dev/null || {
  echo "ERROR: agent-tty not found on PATH"
  exit 1
}
command -v python3 >/dev/null || {
  echo "ERROR: python3 not found on PATH"
  exit 1
}
# shellcheck disable=SC2086
$NVIM --version >/dev/null 2>&1 || {
  echo "ERROR: could not run Neovim ('$NVIM'); set NVIM_BIN"
  exit 1
}

WORK="$(mktemp -d)"
AGENT_HOME="$WORK/atty-home"
mkdir -p "$AGENT_HOME"
trap 'agent-tty --home "$AGENT_HOME" gc --json >/dev/null 2>&1; rm -rf "$WORK"' EXIT

# A small numbered file so the "main editor" window has visible content.
python3 - "$WORK/sample.txt" <<'PY'
import sys
open(sys.argv[1], "w").write("\n".join("line %02d" % i for i in range(1, 61)) + "\n")
PY

a=(agent-tty --home "$AGENT_HOME")

# Parse a snapshot into "cursorRow promptRow delta". promptRow = last visible row
# whose text contains the marker ($1, default ❯).
measure() { # measure <sid> [marker]
  local sid="$1" marker="${2:-❯}"
  "${a[@]}" snapshot "$sid" --json 2>/dev/null | MARK="$marker" python3 -c '
import json,os,sys
mark=os.environ["MARK"]
r=json.load(sys.stdin)["result"]
rows=[l["row"] for l in r["visibleLines"] if mark in l["text"]]
prow=rows[-1] if rows else None
cur=r["cursorRow"]
delta=(prow-cur) if prow is not None else None
print(f"cursorRow={cur} promptRow={prow} delta={delta}")
'
}

# escape terminal-insert -> normal, move to the editor window, then toggle hide+show.
toggle_cycle() { # toggle_cycle <sid>
  local sid="$1"
  "${a[@]}" send-keys "$sid" 'C-Backslash' 'C-n' --json >/dev/null 2>&1
  "${a[@]}" send-keys "$sid" 'C-w' 'h' --json >/dev/null 2>&1
  "${a[@]}" wait "$sid" --screen-stable-ms 400 --json >/dev/null 2>&1
  "${a[@]}" type "$sid" ' ac' --json >/dev/null 2>&1 # <leader>ac -> hide
  "${a[@]}" wait "$sid" --screen-stable-ms 500 --json >/dev/null 2>&1
  "${a[@]}" type "$sid" ' ac' --json >/dev/null 2>&1 # <leader>ac -> show
  "${a[@]}" wait "$sid" --screen-stable-ms 800 --json >/dev/null 2>&1
}

launch() { # launch <provider> <terminal_cmd_or_empty> <boxlog_or_empty> <position_or_empty> -> echoes sid
  local prov="$1" cmd="${2:-}" boxlog="${3:-}" position="${4:-}"
  local env="CURSOR_REPRO_PROVIDER=$prov NVIM_APPNAME=cursor-toggle-repro XDG_CONFIG_HOME='$FIX_DIR'"
  [ -n "$cmd" ] && env="$env CURSOR_REPRO_CMD='$cmd'"
  [ -n "$boxlog" ] && env="$env CURSOR_REPRO_BOX_LOG='$boxlog'"
  [ -n "$position" ] && env="$env CURSOR_REPRO_POSITION='$position'"
  "${a[@]}" create --json --cols 120 --rows 40 -- \
    bash -lc "cd '$FIX_DIR' && $env $NVIM '$WORK/sample.txt'" |
    python3 -c "import json,sys;print(json.load(sys.stdin)['result']['sessionId'])"
}

# Count visible lines matching Claude's footer -- 0 means the panel is hidden.
claude_panel_lines() { # claude_panel_lines <sid>
  "${a[@]}" snapshot "$1" --json 2>/dev/null |
    python3 -c 'import json,sys; r=json.load(sys.stdin)["result"]; print(sum(1 for l in r["visibleLines"] if "auto mode" in l["text"]))'
}

# shellcheck disable=SC2086
echo "Neovim: $($NVIM --version | head -1)"
echo

############################################################################
echo "== PART A: what does Neovim send to the terminal on hide/show? (no auth) =="
BOXLOG="$WORK/box.log"
sid="$(launch snacks "python3 $HERE/box.py" "$BOXLOG")"
"${a[@]}" wait "$sid" --screen-stable-ms 1500 --json >/dev/null 2>&1
"${a[@]}" type "$sid" ' ac' --json >/dev/null 2>&1
"${a[@]}" wait "$sid" --text 'synthetic claude' --timeout-ms 15000 --json >/dev/null 2>&1
"${a[@]}" wait "$sid" --screen-stable-ms 700 --json >/dev/null 2>&1
for _ in $(seq 1 "$CYCLES"); do toggle_cycle "$sid"; done
"${a[@]}" send-keys "$sid" 'C-Backslash' 'C-n' --json >/dev/null 2>&1
"${a[@]}" type "$sid" ':qa!' --json >/dev/null 2>&1
"${a[@]}" send-keys "$sid" Enter --json >/dev/null 2>&1
sleep 0.3
"${a[@]}" destroy "$sid" --json >/dev/null 2>&1
# grep -c prints "0" and exits 1 when there are no matches; `|| true` keeps that
# single "0" without appending another, and ${x:-0} covers a missing file.
winch="$(grep -c SIGWINCH "$BOXLOG" 2>/dev/null || true)"
winch="${winch:-0}"
fin="$(grep -c 'FOCUS_IN' "$BOXLOG" 2>/dev/null || true)"
fin="${fin:-0}"
fout="$(grep -c 'FOCUS_OUT' "$BOXLOG" 2>/dev/null || true)"
fout="${fout:-0}"
echo "  SIGWINCH events on toggle: $winch   (expect 0 -> NOT a pty resize)"
echo "  FOCUS_IN (ESC[I) events:   $fin"
echo "  FOCUS_OUT (ESC[O) events:  $fout   (focus churn is the real trigger)"
echo

############################################################################
echo "== PART B: real Claude — does the cursor climb? (needs logged-in claude) =="
if ! command -v claude >/dev/null 2>&1; then
  echo "  SKIP: 'claude' not on PATH."
else
  for prov in snacks native; do
    echo "  -- provider=$prov --"
    sid="$(launch "$prov" "" "")"
    "${a[@]}" wait "$sid" --screen-stable-ms 1500 --json >/dev/null 2>&1
    "${a[@]}" type "$sid" ' ac' --json >/dev/null 2>&1
    if ! "${a[@]}" wait "$sid" --text 'auto mode' --timeout-ms 25000 --json >/dev/null 2>&1; then
      echo "     SKIP: Claude did not reach its prompt (not logged in?)."
      "${a[@]}" destroy "$sid" --json >/dev/null 2>&1
      continue
    fi
    "${a[@]}" wait "$sid" --screen-stable-ms 1300 --json >/dev/null 2>&1
    echo "     baseline:        $(measure "$sid")"
    for i in $(seq 1 "$CYCLES"); do
      toggle_cycle "$sid"
      echo "     after toggle $i:  $(measure "$sid")"
    done
    "${a[@]}" send-keys "$sid" 'C-Backslash' 'C-n' --json >/dev/null 2>&1
    "${a[@]}" type "$sid" ':qa!' --json >/dev/null 2>&1
    "${a[@]}" send-keys "$sid" Enter --json >/dev/null 2>&1
    sleep 0.3
    "${a[@]}" destroy "$sid" --json >/dev/null 2>&1
  done

  # Float variant (#183): also assert the panel actually hides each cycle.
  echo "  -- provider=snacks position=float (#183) --"
  sid="$(launch snacks "" "" float)"
  "${a[@]}" wait "$sid" --screen-stable-ms 1500 --json >/dev/null 2>&1
  "${a[@]}" type "$sid" ' ac' --json >/dev/null 2>&1
  if "${a[@]}" wait "$sid" --text 'auto mode' --timeout-ms 25000 --json >/dev/null 2>&1; then
    "${a[@]}" wait "$sid" --screen-stable-ms 1300 --json >/dev/null 2>&1
    echo "     baseline:        $(measure "$sid")"
    for i in $(seq 1 "$CYCLES"); do
      "${a[@]}" send-keys "$sid" 'C-Backslash' 'C-n' --json >/dev/null 2>&1
      "${a[@]}" type "$sid" ' ac' --json >/dev/null 2>&1 # hide (float config-hide)
      "${a[@]}" wait "$sid" --screen-stable-ms 600 --json >/dev/null 2>&1
      hidden_lines="$(claude_panel_lines "$sid")"
      "${a[@]}" type "$sid" ' ac' --json >/dev/null 2>&1 # show
      "${a[@]}" wait "$sid" --screen-stable-ms 900 --json >/dev/null 2>&1
      echo "     cycle $i: hidden_footer_lines=$hidden_lines (expect 0) ; shown-> $(measure "$sid")"
    done
  else
    echo "     SKIP: Claude did not reach its prompt (not logged in?)."
  fi
  "${a[@]}" send-keys "$sid" 'C-Backslash' 'C-n' --json >/dev/null 2>&1
  "${a[@]}" type "$sid" ':qa!' --json >/dev/null 2>&1
  "${a[@]}" send-keys "$sid" Enter --json >/dev/null 2>&1
  sleep 0.3
  "${a[@]}" destroy "$sid" --json >/dev/null 2>&1

  echo
  echo "  Interpretation: with the fix, snacks (split & float) holds delta=0 like native,"
  echo "  and the float reports hidden_footer_lines=0 on hide (panel truly hidden)."
fi
