#!/usr/bin/env bash
#
# repro_issue_248.sh — Reproduce GitHub issue #248
# "[FEATURE] Close diff handled by remote control"
#
# Symptom: diffs that Claude opens in Neovim via the `openDiff` MCP tool stay
# open forever when they are resolved *somewhere other than this Neovim*
# (e.g. Claude "remote control" on a phone) — because Neovim only ever closes a
# diff when the connected client sends a `close_tab` / `closeAllDiffTabs` call,
# and that signal is never delivered for diffs resolved out-of-band.
#
# This script acts as the MCP client (i.e. it plays the role of Claude). It:
#   1. discovers the running claudecode.nvim server from its lock file,
#   2. performs the MCP `initialize` handshake,
#   3. opens N diffs via `openDiff` (each blocks server-side — deferred),
#   4. disconnects WITHOUT sending `close_tab`.
#
# After it exits, look at Neovim. With the #248 fix, on_disconnect auto-closes the
# orphaned diffs (`:DiffState` -> windows=1, active_diffs=0). Before the fix the
# client going away left the diff windows open forever — that was the bug.
#
# Usage:
#   # Terminal 1 — start the test editor (quiet repro fixture):
#   source fixtures/nvim-aliases.sh
#   vv remote-diff           # or: NVIM_APPNAME=remote-diff XDG_CONFIG_HOME=fixtures nvim a.txt
#
#   # Terminal 2 — drive the MCP side:
#   scripts/repro_issue_248.sh            # open 3 diffs, disconnect -> fix auto-closes them
#   scripts/repro_issue_248.sh --cleanup  # open 3 diffs, then closeAllDiffTabs
#   scripts/repro_issue_248.sh -n 5       # open 5 diffs
#
# In Neovim, run :DiffState (provided by the remote-diff fixture) to print the
# window count and the number of still-"pending" diffs.
#
# Requirements: websocat, jq.

set -euo pipefail

NUM_DIFFS=3
CLEANUP=0
LOCK_DIR="${CLAUDE_LOCKFILE_DIR:-$HOME/.claude/ide}"

while [[ $# -gt 0 ]]; do
  case "$1" in
  -n | --num)
    NUM_DIFFS="$2"
    shift 2
    ;;
  --cleanup)
    CLEANUP=1
    shift
    ;;
  -h | --help)
    sed -n '2,40p' "$0"
    exit 0
    ;;
  *)
    echo "Unknown arg: $1" >&2
    exit 2
    ;;
  esac
done

command -v websocat >/dev/null || {
  echo "ERROR: websocat not found (try: mise install / brew install websocat)" >&2
  exit 1
}
command -v jq >/dev/null || {
  echo "ERROR: jq not found" >&2
  exit 1
}

# --- discover the running server -------------------------------------------
LOCK_FILE=$(find "$LOCK_DIR" -maxdepth 1 -name '*.lock' -type f 2>/dev/null | head -1 || true)
if [[ -z "$LOCK_FILE" ]]; then
  echo "ERROR: no lock file in $LOCK_DIR — is Neovim running with claudecode.nvim started?" >&2
  echo "       (in the remote-diff fixture the server auto-starts; otherwise run :ClaudeCodeStart)" >&2
  exit 1
fi
PORT=$(basename "$LOCK_FILE" .lock)
TOKEN=$(jq -r '.authToken // empty' "$LOCK_FILE")
WORKSPACE=$(jq -r '.workspaceFolders[0] // empty' "$LOCK_FILE")
if [[ -z "$TOKEN" || -z "$WORKSPACE" ]]; then
  echo "ERROR: lock file missing authToken/workspaceFolders: $LOCK_FILE" >&2
  exit 1
fi
echo "server     : ws://127.0.0.1:$PORT"
echo "workspace  : $WORKSPACE"
echo "action     : open $NUM_DIFFS diff(s)$([[ $CLEANUP == 1 ]] && echo ', then closeAllDiffTabs' || echo ', then DISCONNECT (no close_tab)')"
echo

# --- build the MCP message stream ------------------------------------------
# We feed websocat from a temp file via `tail -f` so the connection stays open
# while the (blocking/deferred) openDiff calls are in flight.
REQ=$(mktemp -t repro248.XXXXXX)
trap 'rm -f "$REQ"' EXIT

emit() { printf '%s\n' "$1" >>"$REQ"; }

# 1) initialize handshake
emit '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{"roots":{"listChanged":true}},"clientInfo":{"name":"repro-issue-248","version":"1.0.0"}}}'
emit '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}'

# pick a couple of real files from the workspace so the diff has content
mapfile -t FILES < <(find "$WORKSPACE" -maxdepth 1 -type f \( -name '*.txt' -o -name '*.lua' -o -name '*.md' \) | sort | head -"$NUM_DIFFS")
if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "ERROR: no .txt/.lua/.md files in workspace $WORKSPACE to diff against" >&2
  exit 1
fi

# 2) one openDiff per file (these block server-side — responses are deferred)
i=0
for f in "${FILES[@]}"; do
  i=$((i + 1))
  base=$(basename "$f")
  tab="✻ [Claude Code] $base (repro$i) ⧉"
  contents="$(cat "$f")"$'\n\n-- appended by repro_issue_248.sh (pretend Claude edited this)\n'
  msg=$(jq -nc \
    --arg old "$f" --arg new "$f" --arg contents "$contents" --arg tab "$tab" --argjson id "$((100 + i))" \
    '{jsonrpc:"2.0",id:$id,method:"tools/call",params:{name:"openDiff",arguments:{old_file_path:$old,new_file_path:$new,new_file_contents:$contents,tab_name:$tab}}}')
  emit "$msg"
  echo "  -> openDiff: $tab"
done

if [[ $CLEANUP == 1 ]]; then
  emit '{"jsonrpc":"2.0","id":900,"method":"tools/call","params":{"name":"closeAllDiffTabs","arguments":{}}}'
  echo "  -> closeAllDiffTabs"
fi

# --- run the connection briefly, then disconnect ----------------------------
# URL must come BEFORE --header: websocat's --header is variadic and will
# otherwise swallow the URL ("No URL specified").
(
  tail -n +1 -f "$REQ" &
  TAIL_PID=$!
  # keep the socket open ~4s so diffs render / cleanup runs, then stop feeding
  sleep 4
  kill "$TAIL_PID" 2>/dev/null || true
) | websocat -t "ws://127.0.0.1:$PORT" --header "x-claude-code-ide-authorization: $TOKEN" 2>/dev/null || true

echo
if [[ $CLEANUP == 1 ]]; then
  echo "Sent closeAllDiffTabs."
  echo ">>> Run :DiffState in Neovim — expect windows=1, active_diffs=0. <<<"
  echo "    With the #248 fix, closeAllDiffTabs drains the diff registry (resolving"
  echo "    pending diffs), not just the windows. Pre-fix, active_diffs stayed > 0."
else
  echo "Client has DISCONNECTED without sending close_tab."
  echo ">>> Run :DiffState in Neovim — expect windows=1, active_diffs=0. <<<"
  echo "    With the #248 fix, on_disconnect auto-closes this client's pending diffs."
  echo "    Pre-fix, the $NUM_DIFFS diff window(s) would have stayed open (the bug)."
fi
