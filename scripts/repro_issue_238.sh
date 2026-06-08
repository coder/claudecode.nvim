#!/usr/bin/env bash
#
# repro_issue_238.sh — Reproduce GitHub issue #238
# "[BUG] Rejecting with `:q` does not work"
#
# Symptom: with terminal.provider = "none" and diff_opts.open_in_new_tab = true,
# rejecting a Claude diff with `:q` closes the proposed window but does NOT
# reject the change — Claude is never told DIFF_REJECTED and the tab lingers.
#
# This script acts as the MCP client (i.e. it plays the role of Claude). It:
#   1. discovers the running claudecode.nvim server from its lock file,
#   2. sends the MCP initialize handshake,
#   3. opens ONE diff via `openDiff` (blocks server-side — deferred response),
#   4. KEEPS THE SOCKET OPEN for --hold seconds, logging every server->client
#      frame to --out, so you can `:q` in Neovim and observe whether a
#      DIFF_REJECTED response ever comes back.
#
# Unlike repro_issue_248.sh (which disconnects to test on_disconnect cleanup),
# this script stays connected so the rejection signal — if any — is captured.
#
# Usage:
#   scripts/repro_issue_238.sh --file /abs/path/to/target.txt \
#       --lock-dir "$CLAUDE_CONFIG_DIR/ide" --out /tmp/frames.jsonl --hold 30
#
# Env:
#   CLAUDE_CONFIG_DIR   if set, lock files are read from "$CLAUDE_CONFIG_DIR/ide"
#                       (matches lua/claudecode/lockfile.lua get_lock_dir()).
#
# Requirements: websocat, jq.

set -euo pipefail

FILE=""
LOCK_DIR="${CLAUDE_LOCKFILE_DIR:-${CLAUDE_CONFIG_DIR:+$CLAUDE_CONFIG_DIR/ide}}"
LOCK_DIR="${LOCK_DIR:-$HOME/.claude/ide}"
OUT=""
HOLD=30
TAB="✻ [Claude Code] target.txt (issue238) ⧉"

while [[ $# -gt 0 ]]; do
  case "$1" in
  --file)
    FILE="$2"
    shift 2
    ;;
  --lock-dir)
    LOCK_DIR="$2"
    shift 2
    ;;
  --out)
    OUT="$2"
    shift 2
    ;;
  --hold)
    HOLD="$2"
    shift 2
    ;;
  --tab)
    TAB="$2"
    shift 2
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

# Allow overriding the websocat binary (e.g. to bypass a mise shim that refuses
# to run in an untrusted directory): WEBSOCAT=/abs/path/to/websocat scripts/...
WEBSOCAT="${WEBSOCAT:-websocat}"
command -v "$WEBSOCAT" >/dev/null || {
  echo "ERROR: websocat not found (looked for: $WEBSOCAT)" >&2
  exit 1
}
command -v jq >/dev/null || {
  echo "ERROR: jq not found" >&2
  exit 1
}
[[ -n "$FILE" ]] || {
  echo "ERROR: --file is required" >&2
  exit 2
}
[[ -f "$FILE" ]] || {
  echo "ERROR: file not found: $FILE" >&2
  exit 2
}
OUT="${OUT:-$(mktemp -t repro238.frames.XXXXXX)}"

# --- discover the running server -------------------------------------------
LOCK_FILE=$(find "$LOCK_DIR" -maxdepth 1 -name '*.lock' -type f 2>/dev/null | head -1 || true)
if [[ -z "$LOCK_FILE" ]]; then
  echo "ERROR: no lock file in $LOCK_DIR — is the fixture's server running?" >&2
  exit 1
fi
PORT=$(basename "$LOCK_FILE" .lock)
TOKEN=$(jq -r '.authToken // empty' "$LOCK_FILE")
[[ -n "$TOKEN" ]] || {
  echo "ERROR: lock file missing authToken: $LOCK_FILE" >&2
  exit 1
}

echo "server     : ws://127.0.0.1:$PORT"
echo "lock file  : $LOCK_FILE"
echo "file       : $FILE"
echo "frames out : $OUT"
echo "hold       : ${HOLD}s"
echo

# --- build the MCP message stream ------------------------------------------
REQ=$(mktemp -t repro238.req.XXXXXX)
trap 'rm -f "$REQ"' EXIT
emit() { printf '%s\n' "$1" >>"$REQ"; }

emit '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{"roots":{"listChanged":true}},"clientInfo":{"name":"repro-issue-238","version":"1.0.0"}}}'
emit '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}'

# Proposed contents: original file with one line changed, so the diff is real.
contents="$(sed 's/line three/line three (EDITED BY CLAUDE)/' "$FILE")"
msg=$(jq -nc \
  --arg old "$FILE" --arg new "$FILE" --arg contents "$contents" --arg tab "$TAB" \
  '{jsonrpc:"2.0",id:101,method:"tools/call",params:{name:"openDiff",arguments:{old_file_path:$old,new_file_path:$new,new_file_contents:$contents,tab_name:$tab}}}')
emit "$msg"
echo "  -> openDiff: $TAB"

# --- run the connection, holding it open while we capture server frames -----
# URL must come BEFORE --header (websocat --header is variadic).
: >"$OUT"
(
  tail -n +1 -f "$REQ" &
  TAIL_PID=$!
  sleep "$HOLD"
  kill "$TAIL_PID" 2>/dev/null || true
) | "$WEBSOCAT" -t "ws://127.0.0.1:$PORT" --header "x-claude-code-ide-authorization: $TOKEN" 2>/dev/null |
  tee "$OUT" || true

echo
echo "=== server -> client frames captured in $OUT ==="
if grep -q DIFF_REJECTED "$OUT" 2>/dev/null; then
  echo "RESULT: DIFF_REJECTED was received — rejection WORKED."
elif grep -q FILE_SAVED "$OUT" 2>/dev/null; then
  echo "RESULT: FILE_SAVED was received — diff was accepted."
else
  echo "RESULT: no DIFF_REJECTED / FILE_SAVED in window — diff was NOT resolved (the #238 bug)."
fi
