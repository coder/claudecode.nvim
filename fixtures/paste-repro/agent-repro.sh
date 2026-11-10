#!/usr/bin/env bash
#
# Self-contained, deterministic reproduction of claudecode.nvim issue #161
# ("Cmd+V paste truncates content in the Claude Code terminal") using agent-tty.
#
# It drives a real Neovim TUI inside an agent-tty session, opens the plugin's
# native Claude terminal (which here runs observer.py instead of `claude`), pastes
# a large payload via bracketed paste, and reports how many ESC[200~/ESC[201~
# bracketed-paste SEGMENTS the inner PTY received:
#
#   * > 1 segment  => BUG reproduced  (Claude would render N separate [Pasted text #k]
#                                      placeholders => perceived truncation)
#   *   1 segment  => correct         (one logical paste)
#
# Requirements: agent-tty, python3, and one or more Neovim builds.
# The bug is version-dependent (fixed upstream by neovim/neovim#39152, in 0.12.2):
#   * Neovim 0.11.x / 0.12.0 / 0.12.1  -> reproduces (N segments)
#   * Neovim 0.12.2+                   -> single segment
#
# Usage:
#   ./agent-repro.sh                       # uses `nvim` on PATH
#   NVIM_VERSION=0.11.7 ./agent-repro.sh   # run an old Neovim via mise (recommended)
#   NVIM_BIN=/path/to/nvim ./agent-repro.sh
#   LINES=300 ./agent-repro.sh             # bigger payload
#
# NVIM_VERSION resolves the binary through mise. mise installs versions
# side-by-side under its own cache, so this NEVER changes your active/default
# Neovim (that only changes via `mise use`). To run one off without this script:
#   mise exec neovim@0.11.7 -- nvim ...
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIX_DIR="$(dirname "$HERE")" # .../fixtures
LINES="${LINES:-120}"
export _ZO_DOCTOR=0

# Resolve how to launch Neovim (used both verbatim and embedded in a `bash -lc`):
#   explicit NVIM_BIN > NVIM_VERSION (via `mise exec`, side-by-side/ephemeral) > `nvim` on PATH.
# `mise exec neovim@X -- nvim` resolves the managed tool directly, so it is not affected by other
# nvim managers on PATH and never changes your active Neovim.
if [ -n "${NVIM_BIN:-}" ]; then
  NVIM="$NVIM_BIN"
elif [ -n "${NVIM_VERSION:-}" ]; then
  command -v mise >/dev/null || {
    echo "ERROR: NVIM_VERSION set but mise not found on PATH"
    exit 1
  }
  mise install "neovim@$NVIM_VERSION" >/dev/null 2>&1 || true
  NVIM="mise exec neovim@$NVIM_VERSION -- nvim"
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
# $NVIM may be a path, "nvim", or "mise exec neovim@X -- nvim", so smoke-test it
# (unquoted, to word-split the launcher) rather than checking for an executable file.
# shellcheck disable=SC2086
$NVIM --version >/dev/null 2>&1 || {
  echo "ERROR: could not run Neovim ('$NVIM'); set NVIM_BIN or NVIM_VERSION"
  exit 1
}

WORK="$(mktemp -d)"
AGENT_HOME="$WORK/atty-home"
mkdir -p "$AGENT_HOME"
PAYLOAD="$WORK/payload.txt"
trap 'agent-tty --home "$AGENT_HOME" gc --json >/dev/null 2>&1; rm -rf "$WORK"' EXIT

# A multi-line payload big enough to span several TUI input reads (~1 KB chunks).
python3 - "$PAYLOAD" "$LINES" <<'PY'
import sys
path, n = sys.argv[1], int(sys.argv[2])
open(path, "w").write("\n".join("L%03d: the quick brown fox jumps over the lazy dog" % i for i in range(1, n+1)) + "\n")
PY
echo "Payload: $LINES lines, $(wc -c <"$PAYLOAD") bytes"
# shellcheck disable=SC2086
echo "Neovim:  $($NVIM --version | head -1)"
echo

run() { # run <apply_fix 0|1> <label>
  local fix="$1" label="$2"
  local log="$WORK/observer_$label.log"
  rm -f "$log" "$log.raw"
  local a=(agent-tty --home "$AGENT_HOME")
  local sid
  sid="$("${a[@]}" create --json --cols 110 --rows 32 -- \
    bash -lc "cd '$FIX_DIR' && PASTE_OBSERVER_LOG='$log' APPLY_PASTE_FIX='$fix' PASTE_REPRO_AUTOOPEN=1 NVIM_APPNAME=paste-repro XDG_CONFIG_HOME='$FIX_DIR' $NVIM --clean -u '$FIX_DIR/paste-repro/init.lua'" |
    python3 -c "import json,sys;print(json.load(sys.stdin)['result']['sessionId'])")"
  "${a[@]}" wait "$sid" --text 'OBSERVER READY' --timeout-ms 15000 --json >/dev/null 2>&1
  "${a[@]}" paste "$sid" "$(cat "$PAYLOAD")" --json >/dev/null 2>&1
  "${a[@]}" wait "$sid" --screen-stable-ms 1000 --timeout-ms 8000 --json >/dev/null 2>&1
  "${a[@]}" type "$sid" '<<QUIT>>' --json >/dev/null 2>&1
  "${a[@]}" wait "$sid" --screen-stable-ms 700 --timeout-ms 6000 --json >/dev/null 2>&1
  local total
  total="$(grep -E '^TOTAL' "$log" 2>/dev/null || echo 'NO LOG (terminal did not open)')"
  local segs
  segs="$(sed -n 's/.*start_markers=\([0-9]*\).*/\1/p' <<<"$total")"
  local verdict="?"
  [ "${segs:-0}" = "1" ] && verdict="OK (single paste)"
  [ "${segs:-0}" -gt 1 ] 2>/dev/null && verdict="BUG (fragmented)"
  printf '  %-28s %s  => %s\n' "$label" "$total" "$verdict"
  "${a[@]}" send-keys "$sid" "C-\\" "C-n" --json >/dev/null 2>&1
  "${a[@]}" type "$sid" ':qa!' --json >/dev/null 2>&1
  "${a[@]}" send-keys "$sid" Enter --json >/dev/null 2>&1
  sleep 0.3
  "${a[@]}" destroy "$sid" --json >/dev/null 2>&1
}

echo "Result (bracketed-paste segments seen by the inner PTY):"
run 0 "default"
run 1 "with-workaround"
echo
echo "Interpretation: on an affected Neovim (<= 0.11.x / 0.12.1) 'default' shows >1"
echo "segment (bug); 'with-workaround' shows 1. On Neovim 0.12.2+ both show 1."
