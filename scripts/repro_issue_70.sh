#!/usr/bin/env bash
#
# Reproduce issue #70: "[BUG] Sending files, current buffer, or lines to claude
# doesn't work." -> [ClaudeCode] [queue] [ERROR] Connection timeout - clearing N
# queued @ mentions.
#
# https://github.com/coder/claudecode.nvim/issues/70
#
# The symptom is always the same single fact: the Claude CLI never opens a
# WebSocket connection back to the plugin's server, so queued @ mentions expire.
# This harness isolates ONE currently-live, plugin-relevant root cause -- an
# HTTP(S)/ALL proxy in the environment that has no localhost exclusion, which
# Claude honors for its `ws://127.0.0.1:<port>` IDE connection (matching the
# `no_proxy=localhost,127.0.0.1,::1` workaround reported on the issue).
#
# It starts the REAL plugin server (scripts/repro_issue_70_probe.lua), launches
# the REAL Claude CLI against it under three environments via agent-tty, and
# asserts whether Claude actually connected:
#
#   A  baseline (no proxy)                         -> EXPECT connect
#   B  proxy set, no localhost exclusion           -> EXPECT no-connect  (the bug)
#   C  proxy set + no_proxy=localhost,127.0.0.1,::1 -> EXPECT connect    (the fix)
#
# Requirements: nvim, the `claude` CLI (logged in), `agent-tty`, and `jq`.
# This harness only ever sets env vars + points CLAUDE_CODE_SSE_PORT at its own
# throwaway server; it never touches other ~/.claude/ide lock files.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE_LUA="$REPO_ROOT/scripts/repro_issue_70_probe.lua"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/issue70.XXXXXX")"
AGENT_HOME="$WORK/att-home"
DEAD_PROXY="http://127.0.0.1:1" # closed port -> any proxied connection fails fast
WAIT_CONNECT_S=14

mkdir -p "$AGENT_HOME"

for bin in nvim claude agent-tty jq; do
  command -v "$bin" >/dev/null 2>&1 || {
    echo "MISSING dependency: $bin" >&2
    exit 3
  }
done

PROBE_PIDS=()
# shellcheck disable=SC2329  # invoked indirectly via `trap cleanup EXIT`
cleanup() {
  for s in $(agent-tty --home "$AGENT_HOME" list --json 2>/dev/null | jq -r '.result.sessions[]?.sessionId // empty' 2>/dev/null); do
    agent-tty --home "$AGENT_HOME" destroy "$s" --json >/dev/null 2>&1
  done
  for p in "${PROBE_PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
  pkill -f "repro_issue_70_probe.lua $REPO_ROOT" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

# start_probe <status_file> <stop_file> -> echoes the port
start_probe() {
  local status="$1" stop="$2"
  rm -f "$status" "$stop"
  nvim --headless -u NONE -l "$PROBE_LUA" "$REPO_ROOT" "$status" "$stop" 120000 >/dev/null 2>&1 &
  PROBE_PIDS+=("$!")
  local port=""
  for _ in $(seq 1 50); do
    [ -f "$status" ] && port="$(jq -r '.port // empty' "$status" 2>/dev/null)" && [ -n "$port" ] && break
    sleep 0.2
  done
  echo "$port"
}

# run_scenario <name> <expect:connect|noconnect> <env-setup-shell>
run_scenario() {
  local name="$1" expect="$2" envsetup="$3"
  local status="$WORK/$name.json" stop="$WORK/$name.stop"
  local port
  port="$(start_probe "$status" "$stop")"
  if [ -z "$port" ]; then
    echo "  [$name] FAIL: probe did not start"
    touch "$stop"
    return 1
  fi

  local sid
  sid="$(agent-tty --home "$AGENT_HOME" create --json --cols 200 --rows 50 -- /bin/bash | jq -r '.result.sessionId')"
  agent-tty --home "$AGENT_HOME" run "$sid" "cd '$REPO_ROOT'; unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY no_proxy NO_PROXY; export ENABLE_IDE_INTEGRATION=true CLAUDE_CODE_SSE_PORT=$port; $envsetup; echo SCN_READY" --json >/dev/null 2>&1
  agent-tty --home "$AGENT_HOME" wait "$sid" --text 'SCN_READY' --timeout-ms 5000 --json >/dev/null 2>&1
  agent-tty --home "$AGENT_HOME" run "$sid" 'claude' --no-wait --json >/dev/null 2>&1
  # best-effort: dismiss a first-run trust prompt if one appears
  sleep 1
  agent-tty --home "$AGENT_HOME" send-keys "$sid" Enter --json >/dev/null 2>&1

  local connected="false"
  for _ in $(seq 1 "$WAIT_CONNECT_S"); do
    connected="$(jq -r '.connected // false' "$status" 2>/dev/null)"
    [ "$connected" = "true" ] && break
    sleep 1
  done

  # tear down this scenario's claude + server before reporting
  agent-tty --home "$AGENT_HOME" type "$sid" '/quit' --json >/dev/null 2>&1
  agent-tty --home "$AGENT_HOME" send-keys "$sid" Enter --json >/dev/null 2>&1
  touch "$stop"
  agent-tty --home "$AGENT_HOME" destroy "$sid" --json >/dev/null 2>&1

  local got="noconnect"
  [ "$connected" = "true" ] && got="connect"
  if [ "$got" = "$expect" ]; then
    echo "  [$name] PASS  (port $port: expected=$expect, got=$got)"
    return 0
  else
    echo "  [$name] FAIL  (port $port: expected=$expect, got=$got)"
    return 1
  fi
}

echo "issue #70 connection repro  (claude: $(claude --version 2>/dev/null | head -1))"
echo "repo: $REPO_ROOT"
echo

fails=0
run_scenario "A_baseline" "connect" ":" || fails=$((fails + 1))
run_scenario "B_proxy" "noconnect" "export http_proxy=$DEAD_PROXY https_proxy=$DEAD_PROXY all_proxy=$DEAD_PROXY" || fails=$((fails + 1))
run_scenario "C_no_proxy" "connect" "export http_proxy=$DEAD_PROXY https_proxy=$DEAD_PROXY all_proxy=$DEAD_PROXY no_proxy=localhost,127.0.0.1,::1 NO_PROXY=localhost,127.0.0.1,::1" || fails=$((fails + 1))

echo
if [ "$fails" -eq 0 ]; then
  echo "PASS issue #70 reproduced: a proxy with no localhost exclusion blocks Claude's"
  echo "     IDE WebSocket (B), while baseline (A) and the no_proxy fix (C) connect."
  exit 0
else
  echo "INCONCLUSIVE: $fails scenario(s) did not match expectation (see above)."
  echo "  Most often this means the local 'claude' is not logged in / cannot reach"
  echo "  the IDE socket for an unrelated reason. Re-run after 'claude' works manually."
  exit 1
fi
