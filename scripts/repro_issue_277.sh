#!/usr/bin/env bash
#
# Reproduce issue #277: "[BUG] closeAllDiffTabs closes all diff-mode windows,
# destroying unrelated diffs (diffview.nvim)"
# https://github.com/coder/claudecode.nvim/issues/277
#
# Drives a real Neovim TUI (fixtures/issue-277, diffview.nvim + dev claudecode)
# inside agent-tty, then acts as the Claude CLI by sending MCP `tools/call`
# requests straight to the plugin's WebSocket server (the real CLI fires
# closeAllDiffTabs at the start of a user turn whenever an IDE is connected).
#
# Phases (each asserts the BUG reproduces, i.e. PASS == bug present):
#   1  :DiffviewOpen, then closeAllDiffTabs        -> both side-by-side diff
#      windows are closed, only the Diffview file panel survives ("blank review")
#   2  native `:vertical diffsplit`, then openFile -> the file is :edit-ed INTO a
#      diff-mode window (find_main_editor_window does not exclude &diff windows)
#      and joins the user's diff
#   3  native diff, then closeAllDiffTabs          -> user's vimdiff windows are
#      closed (no plugins involved at all)
#
# Requirements: nvim, agent-tty, websocat, jq, git, perl. No `claude` login is
# needed; the script speaks the MCP protocol itself.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/issue277.XXXXXX")"
AGENT_HOME="$WORK/att-home"
NVIM_SOCK="$WORK/nvim.sock"
DEMO_REPO="$WORK/demo-repo"
ARTIFACTS="${ISSUE277_ARTIFACTS:-$WORK/artifacts}"
DIFFVIEW_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/issue-277/diffview.nvim"

mkdir -p "$AGENT_HOME" "$ARTIFACTS"

for bin in nvim agent-tty jq git perl; do
  command -v "$bin" >/dev/null 2>&1 || {
    echo "MISSING dependency: $bin" >&2
    exit 3
  }
done

# A `websocat` mise shim can exist but have no active version, so probe that the
# resolved command actually runs before trusting it.
WEBSOCAT=websocat
"$WEBSOCAT" --version >/dev/null 2>&1 ||
  WEBSOCAT="$(find "${MISE_DATA_DIR:-$HOME/.local/share/mise}/installs/websocat" -maxdepth 2 -name websocat -type f 2>/dev/null | head -1)"
if [ -z "$WEBSOCAT" ] || ! "$WEBSOCAT" --version >/dev/null 2>&1; then
  echo "MISSING dependency: websocat (no working binary found)" >&2
  exit 3
fi

SESSION_ID=""
# shellcheck disable=SC2329  # invoked via `trap cleanup EXIT`
cleanup() {
  [ -n "$SESSION_ID" ] && agent-tty --home "$AGENT_HOME" destroy "$SESSION_ID" --json >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

att() { agent-tty --home "$AGENT_HOME" "$@"; }
# Bounded --remote-expr: a modal hit-enter prompt in nvim would otherwise block
# the RPC (and this script) forever.
rexpr() { perl -e 'alarm 10; exec @ARGV' nvim --server "$NVIM_SOCK" --remote-expr "$1" 2>/dev/null; }
# Clear a hit-enter prompt ONLY if the RPC is actually blocked. A blind Enter
# would land in diffview's file panel (<CR> = reopen the diff!) and undo the
# very state we are asserting on.
ensure_responsive() {
  [ "$(rexpr '1+1')" = "2" ] && return 0
  att send-keys "$SESSION_ID" Enter --json >/dev/null 2>&1
  perl -e 'select(undef,undef,undef,0.5)'
  [ "$(rexpr '1+1')" = "2" ]
}
fail() {
  echo "SETUP FAILURE: $*" >&2
  exit 2
}

# mcp_call <tool-name> <arguments-json>: one-shot MCP tools/call as the Claude
# client. The server does not gate tools/call on `initialize`, and these tools
# respond immediately, so a short-lived socket is enough. macOS has no
# `timeout`; hold stdin open briefly and bound the whole client with alarm.
mcp_call() {
  local req
  req=$(jq -nc --arg name "$1" --argjson args "$2" \
    '{jsonrpc:"2.0",id:1,method:"tools/call",params:{name:$name,arguments:$args}}')
  {
    printf '%s\n' "$req"
    perl -e 'select(undef,undef,undef,2)'
  } |
    perl -e 'alarm 15; exec @ARGV' "$WEBSOCAT" -t "ws://127.0.0.1:$PORT" \
      --header "x-claude-code-ide-authorization: $TOKEN" 2>/dev/null |
    jq -c 'select(.id == 1)' # drop interleaved broadcasts (selection_changed)
  ensure_responsive
}

# ---------------------------------------------------------------------------
# Setup: demo git repo with uncommitted changes + diffview.nvim clone
# ---------------------------------------------------------------------------
mkdir -p "$DEMO_REPO"
(
  cd "$DEMO_REPO" || exit 1
  git init -q
  git config user.email repro@example.com
  git config user.name repro
  for i in $(seq 1 12); do echo "local line_$i = $i"; done >a.lua
  for i in $(seq 1 12); do echo "local other_$i = $i"; done >b.lua
  echo "# demo repo for issue #277" >README.md
  git add . && git commit -qm initial
  # uncommitted change so :DiffviewOpen has something to show
  printf 'local line_2 = 2000 -- CHANGED\n' >tmp && sed '2d' a.lua >>tmp && mv tmp a.lua
) || fail "could not build demo repo"

if [ ! -d "$DIFFVIEW_DIR" ]; then
  echo "[setup] cloning diffview.nvim -> $DIFFVIEW_DIR"
  git clone -q --depth=1 https://github.com/sindrets/diffview.nvim "$DIFFVIEW_DIR" ||
    fail "could not clone diffview.nvim"
fi

# ---------------------------------------------------------------------------
# Launch Neovim (issue-277 fixture) inside agent-tty
# ---------------------------------------------------------------------------
SESSION_ID=$(att create --json --cols 200 --rows 50 --cwd "$DEMO_REPO" \
  --name issue277 \
  --env NVIM_APPNAME=issue-277 \
  --env XDG_CONFIG_HOME="$REPO_ROOT/fixtures" \
  --env _ZO_DOCTOR=0 \
  -- nvim --listen "$NVIM_SOCK" | jq -r '.result.sessionId')
[ -n "$SESSION_ID" ] && [ "$SESSION_ID" != null ] || fail "agent-tty create failed"

for _ in $(seq 1 60); do
  [ -e "$NVIM_SOCK" ] && [ "$(rexpr '1+1')" = "2" ] && break
  perl -e 'select(undef,undef,undef,0.25)'
done
[ "$(rexpr '1+1')" = "2" ] || fail "nvim RPC socket never came up"

SERVER=""
for _ in $(seq 1 60); do
  SERVER=$(rexpr 'v:lua.Repro277Server()')
  [ -n "$SERVER" ] && break
  perl -e 'select(undef,undef,undef,0.25)'
done
[ -n "$SERVER" ] || fail "claudecode server never started (auto_start)"
PORT=${SERVER%% *}
TOKEN=${SERVER##* }
echo "[setup] nvim up; claudecode ws on port $PORT"

snap() { att snapshot "$SESSION_ID" --format text --json | jq -r '.result.text' >"$ARTIFACTS/$1.txt"; }

PASS=0
FAIL=0
verdict() { # <ok> <label>
  if [ "$1" = 1 ]; then
    PASS=$((PASS + 1))
    echo "REPRODUCED: $2"
  else
    FAIL=$((FAIL + 1))
    echo "NOT REPRODUCED: $2"
  fi
}

wait_diff_wins() { # <count> -> 0 if reached
  for _ in $(seq 1 40); do
    [ "$(rexpr 'v:lua.Repro277DiffWinCount()')" = "$1" ] && return 0
    perl -e 'select(undef,undef,undef,0.25)'
  done
  return 1
}

# ---------------------------------------------------------------------------
# Phase 1: closeAllDiffTabs destroys a diffview.nvim review     (defect 1)
# ---------------------------------------------------------------------------
echo
echo "=== Phase 1: :DiffviewOpen + closeAllDiffTabs ==="
rexpr 'execute("DiffviewOpen")' >/dev/null
wait_diff_wins 2 || fail "DiffviewOpen never produced 2 diff windows"
att wait "$SESSION_ID" --screen-stable-ms 700 --timeout-ms 8000 --json >/dev/null
snap phase1-before
P1_BEFORE=$(rexpr 'v:lua.Repro277DiffWinCount()')
P1_STATE_BEFORE=$(rexpr 'v:lua.Repro277State()')
echo "  before: $P1_BEFORE diff windows; windows: $(echo "$P1_STATE_BEFORE" | jq -c '[.[] | {name, filetype, diff}]')"

P1_RESP=$(mcp_call closeAllDiffTabs '{}')
echo "  closeAllDiffTabs response: $(echo "$P1_RESP" | jq -c '.result.content[0].text' 2>/dev/null || echo "$P1_RESP")"

att wait "$SESSION_ID" --screen-stable-ms 700 --timeout-ms 8000 --json >/dev/null
snap phase1-after
P1_AFTER=$(rexpr 'v:lua.Repro277DiffWinCount()')
P1_STATE_AFTER=$(rexpr 'v:lua.Repro277State()')
P1_PANEL=$(echo "$P1_STATE_AFTER" | jq '[.[] | select(.filetype == "DiffviewFiles")] | length')
echo "  after:  $P1_AFTER diff windows; windows: $(echo "$P1_STATE_AFTER" | jq -c '[.[] | {name, filetype, diff}]')"

P1_OK=0
[ "$P1_BEFORE" = 2 ] && [ "$P1_AFTER" = 0 ] && [ "$P1_PANEL" -ge 1 ] && P1_OK=1
verdict "$P1_OK" "diffview side-by-side windows closed; orphaned file panel left behind"

# ---------------------------------------------------------------------------
# Phase 2: openFile :edit-s into a foreign diff window          (defect 2)
# ---------------------------------------------------------------------------
echo
echo "=== Phase 2: native :vertical diffsplit + openFile ==="
rexpr 'execute("DiffviewClose")' >/dev/null
rexpr 'execute("tabonly | only")' >/dev/null
rexpr 'execute("ReproNativeDiff a.lua b.lua")' >/dev/null
wait_diff_wins 2 || fail "ReproNativeDiff never produced 2 diff windows"
P2_STATE_BEFORE=$(rexpr 'v:lua.Repro277State()')
echo "  before: windows: $(echo "$P2_STATE_BEFORE" | jq -c '[.[] | {name, diff}]')"

P2_RESP=$(mcp_call openFile '{"filePath": "README.md"}')
echo "  openFile response: $(echo "$P2_RESP" | jq -c '.result.content[0].text' 2>/dev/null || echo "$P2_RESP")"

att wait "$SESSION_ID" --screen-stable-ms 700 --timeout-ms 8000 --json >/dev/null
snap phase2-after
P2_STATE_AFTER=$(rexpr 'v:lua.Repro277State()')
# The corrupted outcome: README.md was :edit-ed into one half of the vimdiff
# (b.lua's window is gone; entering a new buffer resets the window-local &diff,
# leaving the other half diffing against nothing).
P2_README_WINS=$(echo "$P2_STATE_AFTER" | jq '[.[] | select(.name | endswith("README.md"))] | length')
P2_BLUA_WINS=$(echo "$P2_STATE_AFTER" | jq '[.[] | select(.name | endswith("b.lua"))] | length')
P2_DIFF_AFTER=$(rexpr 'v:lua.Repro277DiffWinCount()')
echo "  after:  windows: $(echo "$P2_STATE_AFTER" | jq -c '[.[] | {name, diff}]')"

P2_OK=0
[ "$P2_README_WINS" -ge 1 ] && [ "$P2_BLUA_WINS" = 0 ] && [ "$P2_DIFF_AFTER" = 1 ] && P2_OK=1
verdict "$P2_OK" "openFile hijacked one half of the user's vimdiff (b.lua window replaced by README.md, diff pair broken)"

# ---------------------------------------------------------------------------
# Phase 3: closeAllDiffTabs destroys a native vimdiff           (defect 1)
# ---------------------------------------------------------------------------
echo
echo "=== Phase 3: native :vertical diffsplit + closeAllDiffTabs ==="
rexpr 'execute("only")' >/dev/null
rexpr 'execute("ReproNativeDiff a.lua b.lua")' >/dev/null
wait_diff_wins 2 || fail "ReproNativeDiff never produced 2 diff windows"
P3_BEFORE=$(rexpr 'v:lua.Repro277DiffWinCount()')
P3_WINS_BEFORE=$(rexpr 'v:lua.Repro277State()' | jq 'length')

P3_RESP=$(mcp_call closeAllDiffTabs '{}')
echo "  closeAllDiffTabs response: $(echo "$P3_RESP" | jq -c '.result.content[0].text' 2>/dev/null || echo "$P3_RESP")"

att wait "$SESSION_ID" --screen-stable-ms 700 --timeout-ms 8000 --json >/dev/null
snap phase3-after
P3_AFTER=$(rexpr 'v:lua.Repro277DiffWinCount()')
P3_WINS_AFTER=$(rexpr 'v:lua.Repro277State()' | jq 'length')
echo "  diff windows: $P3_BEFORE -> $P3_AFTER; total windows: $P3_WINS_BEFORE -> $P3_WINS_AFTER"

P3_OK=0
[ "$P3_BEFORE" = 2 ] && [ "$P3_AFTER" -lt 2 ] && P3_OK=1
verdict "$P3_OK" "user's native vimdiff window(s) closed (E444 spares only the last window)"

# ---------------------------------------------------------------------------
echo
echo "=== Summary: $PASS/3 defects reproduced (artifacts: $ARTIFACTS) ==="
[ -n "${ISSUE277_ARTIFACTS:-}" ] || cp -R "$ARTIFACTS" "${TMPDIR:-/tmp}/issue277-artifacts-latest" 2>/dev/null
[ "$FAIL" = 0 ] || exit 1
exit 0
