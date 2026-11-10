#!/usr/bin/env bash
#
# Reproduction / verification for issue #218:
#   "[BUG] Neovim crashes when accepting new file diff with render-markdown.nvim
#    installed"
#   https://github.com/coder/claudecode.nvim/issues/218
#
# Root cause (verified): accepting (:w) a NEW-file *markdown* diff that claudecode
# opened in a NEW TAB (diff_opts.open_in_new_tab = true) tears the diff down via
# diff.close_diff_by_tab_name -> _cleanup_diff_state, which runs `:tabclose` on
# the tab whose windows are STILL in diff mode. When render-markdown.nvim is
# attached to that markdown buffer AND the Claude terminal is open in the other
# tab, that `:tabclose` abnormally terminates Neovim. Removing render-markdown,
# or turning diff mode off before the teardown (the reporter's `diffoff`
# workaround), avoids it.
#
# The exact symptom is build-dependent (same memory-unsafety bug):
#   * Neovim 0.12.3            -> SIGSEGV, raw exit 139  (matches the reporter)
#   * some 0.11.0 release builds -> abnormal exit 0, no VimLeave, dies mid-tabclose
# Either way Neovim disappears the instant the diff is accepted.
#
# This driver needs a REAL terminal UI (the crash is in the redraw/teardown path,
# which does not run under --headless), so it uses the `agent-tty` CLI. No real
# Claude/API is required: the fixture's :Repro218 opens a harmless Claude terminal
# (a sleeping process) and drives the openDiff coroutine flow directly.
#
# Usage:
#   scripts/repro_issue_218.sh                 # repro (expects crash)
#   NVIM_BIN=/path/to/nvim scripts/repro_issue_218.sh
#   scripts/repro_issue_218.sh --no-render-markdown   # control (expects survival)
#
# Exit code: 0 if the expected outcome was observed, 1 otherwise.

# Note: no `set -e` — agent-tty subcommands can return non-zero on benign
# conditions (e.g. a `wait` that times out), and we handle outcomes explicitly.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$(dirname "$(realpath "$0")")")" && pwd)"
NVIM_BIN="${NVIM_BIN:-nvim}"
WANT_RM=1
[[ "${1:-}" == "--no-render-markdown" ]] && WANT_RM=0

command -v agent-tty >/dev/null 2>&1 || {
  echo "ERROR: agent-tty not found on PATH (required: the crash needs a real TTY/UI)." >&2
  exit 1
}
command -v "$NVIM_BIN" >/dev/null 2>&1 || {
  echo "ERROR: nvim binary '$NVIM_BIN' not found (set NVIM_BIN)." >&2
  exit 1
}

WORK="$(mktemp -d)"
AGENT_HOME="$WORK/atty"
mkdir -p "$AGENT_HOME" # agent-tty requires its --home dir to exist before `create`
EXITF="$WORK/nvim_exit.txt"
: >"$EXITF"

if [[ "$WANT_RM" -eq 1 ]]; then
  APPNAME="issue-218"
  CONFHOME="$REPO_ROOT/fixtures"
else
  # Build a sibling fixture without render-markdown.lua (the control).
  APPNAME="issue-218norm"
  CONFHOME="$WORK/fixtures-norm"
  mkdir -p "$CONFHOME/$APPNAME/lua/plugins"
  cp -R "$REPO_ROOT/fixtures/issue-218/lua/config" "$CONFHOME/$APPNAME/lua/config"
  cp "$REPO_ROOT/fixtures/issue-218/lua/plugins/dev-claudecode.lua" "$CONFHOME/$APPNAME/lua/plugins/"
  cp "$REPO_ROOT/fixtures/issue-218/lua/plugins/snacks.lua" "$CONFHOME/$APPNAME/lua/plugins/"
  printf 'require("config.lazy")\n' >"$CONFHOME/$APPNAME/init.lua"
fi

echo "Repo:        $REPO_ROOT"
echo "Neovim:      $($NVIM_BIN --version | head -1)  ($NVIM_BIN)"
echo "render-md:   $([[ $WANT_RM -eq 1 ]] && echo INSTALLED || echo REMOVED)"
echo "Workdir:     $WORK"
echo

echo "==> Installing fixture plugins (lazy sync)…"
NVIM_APPNAME="$APPNAME" XDG_CONFIG_HOME="$CONFHOME" "$NVIM_BIN" --headless "+Lazy! sync" "+qa" >/dev/null 2>&1 || true

# Wrapper launcher that captures Neovim's RAW exit status (139 = SIGSEGV).
LAUNCH="$WORK/launch.sh"
cat >"$LAUNCH" <<EOF
#!/bin/bash
export NVIM_APPNAME="$APPNAME"
export XDG_CONFIG_HOME="$CONFHOME"
cd "$WORK"
"$NVIM_BIN"
echo "RAW=\$?" > "$EXITF"
exit \$?
EOF
chmod +x "$LAUNCH"

ATTY=(agent-tty --home "$AGENT_HOME")
echo "==> Launching Neovim under agent-tty…"
SID="$("${ATTY[@]}" create --json --cols 150 --rows 44 -- "$LAUNCH" | jq -r '.result.sessionId')"
if [[ -z "$SID" || "$SID" == "null" ]]; then
  echo "ERROR: failed to create agent-tty session." >&2
  exit 1
fi
# shellcheck disable=SC2329  # invoked indirectly via the EXIT trap below
cleanup() { "${ATTY[@]}" destroy "$SID" --json >/dev/null 2>&1 || true; }
trap cleanup EXIT

"${ATTY[@]}" wait "$SID" --screen-stable-ms 1800 --json >/dev/null 2>&1 || true

echo "==> :Repro218 (open new-file markdown diff in a new tab)…"
"${ATTY[@]}" type "$SID" ":Repro218" --json >/dev/null 2>&1
"${ATTY[@]}" send-keys "$SID" "Enter" --json >/dev/null 2>&1
"${ATTY[@]}" wait "$SID" --text "Repro218 ready" --timeout 10000 --json >/dev/null 2>&1 || true
"${ATTY[@]}" wait "$SID" --screen-stable-ms 1200 --json >/dev/null 2>&1 || true

echo "==> :w (accept the diff)…"
"${ATTY[@]}" send-keys "$SID" "Escape" --json >/dev/null 2>&1
"${ATTY[@]}" type "$SID" ":w" --json >/dev/null 2>&1
"${ATTY[@]}" send-keys "$SID" "Enter" --json >/dev/null 2>&1

# Give Neovim a moment to crash (or not).
"${ATTY[@]}" wait "$SID" --exit --timeout 8000 --json >/dev/null 2>&1 || true

STATUS="$("${ATTY[@]}" inspect "$SID" --json 2>&1 | jq -r '.result.session.status')"
RAW="$(sed -n 's/^RAW=//p' "$EXITF" 2>/dev/null || true)"

echo
echo "------------------------------------------------------------"
echo "agent-tty session status : $STATUS"
echo "raw nvim exit code       : ${RAW:-<still running>}"
echo "------------------------------------------------------------"

if [[ "$WANT_RM" -eq 1 ]]; then
  if [[ "$STATUS" == "exited" ]]; then
    if [[ "$RAW" == "139" ]]; then
      echo "RESULT: #218 REPRODUCED — Neovim SIGSEGV (139) on diff accept."
    else
      echo "RESULT: #218 REPRODUCED — Neovim abnormally terminated (raw=$RAW) on diff accept."
      echo "        (exit 0 with no VimLeave is the same memory bug surfacing differently;"
      echo "         try NVIM_BIN pointing at a 0.12.x build to see the canonical SIGSEGV 139.)"
    fi
    exit 0
  fi
  echo "RESULT: NOT reproduced on this build — Neovim is still running after accept."
  exit 1
else
  if [[ "$STATUS" != "exited" ]]; then
    echo "RESULT: control OK — without render-markdown the diff accepts cleanly (no crash)."
    exit 0
  fi
  echo "RESULT: unexpected — Neovim terminated (raw=$RAW) even without render-markdown."
  exit 1
fi
