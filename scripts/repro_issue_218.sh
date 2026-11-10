#!/usr/bin/env bash
#
# Check for issue #218:
#   "[BUG] Neovim crashes when accepting new file diff with render-markdown.nvim
#    installed"
#   https://github.com/coder/claudecode.nvim/issues/218
#
# Root cause found for the report: accepting (:w) a NEW-file *markdown* diff that claudecode
# opened in a NEW TAB (diff_opts.open_in_new_tab = true) tears the diff down via
# diff.close_diff_by_tab_name -> _cleanup_diff_state, which runs `:tabclose` on
# the tab whose windows are STILL in diff mode. When render-markdown.nvim is
# attached to that markdown buffer AND the Claude terminal is open in the other
# tab, that `:tabclose` abnormally terminates Neovim. Removing render-markdown,
# or turning diff mode off before the teardown (the reporter's `diffoff`
# workaround), avoids it.
#
# On the builds that crashed, the symptom was build-dependent (same memory-unsafety bug):
#   * a Neovim 0.12.3 build     -> SIGSEGV, raw exit 139  (matches the reporter)
#   * some 0.11.0 release builds -> abnormal exit 0, no VimLeave, dies mid-tabclose
# Either way Neovim disappeared the instant the diff was accepted. Whether a given
# build, set of plugin commits and claudecode.nvim checkout still crashes is what
# this script finds out. It does not assume it.
#
# This driver needs a REAL terminal UI (the crash is in the redraw/teardown path,
# which does not run under --headless), so it uses the `agent-tty` CLI. No real
# Claude/API is required: the fixture's :Repro218 opens a harmless Claude terminal
# (a sleeping process) and drives the openDiff coroutine flow directly.
#
# Usage:
#   scripts/repro_issue_218.sh                 # default run: render-markdown installed
#   NVIM_BIN=/path/to/nvim scripts/repro_issue_218.sh
#   scripts/repro_issue_218.sh --no-render-markdown   # control run: render-markdown removed
#
# What it checks: is Neovim still running after the new-file markdown diff is accepted?
#
# The run works on a COPY of fixtures/issue-218 in a temp directory (the copy keeps
# the committed lazy-lock.json), so it never modifies a tracked file. The temp
# directory is removed on exit. So are the agent-tty session, its entry in agent-tty's
# per-user home registry, and its empty socket directory under /tmp/agent-tty (the
# session's home is a fresh temp directory, so none of them belongs to another run).
# Plugins are installed into stdpath("data") of the
# fixture's NVIM_APPNAME (${XDG_DATA_HOME:-$HOME/.local/share}/issue-218 or
# issue-218norm), outside the temp directory, and `Lazy! restore` pins them to the
# commits in that lock file. The exception is lazy.nvim itself on the first run (empty
# data dir): at startup it rewrites its own lock entry to the `stable` commit that the
# bootstrap in fixtures/issue-218/lua/config/lazy.lua clones, so the pin does not apply
# to it. Later runs restore it to the pinned commit.
#
# Exit code:
#   0  default run: Neovim terminated after the accept (the crash was observed).
#      control run: Neovim kept running (control OK).
#   1  default run: Neovim kept running (the crash was NOT observed on this build and
#      checkout, which is the expected result once the crash is fixed).
#      control run: Neovim terminated (unexpected).
#      Either run: agent-tty, nvim or jq is missing, or no agent-tty session could be created.
#   2  Either run: Neovim did not show "Repro218 ready" within 10 s after :Repro218, so the
#      run never reached the ready state and checked nothing.
#   3  Either run: after `Lazy! restore` a fixture plugin is not at its commit in
#      lazy-lock.json (the restore failed), so the run would test other revisions.

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
command -v jq >/dev/null 2>&1 || {
  echo "ERROR: jq not found on PATH (required to read the agent-tty JSON output)." >&2
  exit 1
}

WORK="$(mktemp -d)"
AGENT_HOME="$WORK/atty"
ATTY=(agent-tty --home "$AGENT_HOME")
SID=""
SOCK_DIR=""
# shellcheck disable=SC2329  # invoked indirectly via the EXIT trap below
cleanup() {
  if [[ -n "$SID" ]]; then
    "${ATTY[@]}" destroy "$SID" --json >/dev/null 2>&1 || true
  fi
  # `destroy` leaves this run's home in agent-tty's per-user registry and its empty socket
  # directory in /tmp/agent-tty. The home is a fresh temp dir, so both belong to this run.
  "${ATTY[@]}" home forget "$AGENT_HOME" --json >/dev/null 2>&1 || true
  if [[ -n "$SOCK_DIR" ]]; then rmdir "$SOCK_DIR" 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT
mkdir -p "$AGENT_HOME" # agent-tty requires its --home dir to exist before `create`
EXITF="$WORK/nvim_exit.txt"
: >"$EXITF"

# Run a COPY of the fixture, committed lazy-lock.json included: `Lazy!` writes that
# lock file, and it must not write the tracked one in the checkout.
if [[ "$WANT_RM" -eq 1 ]]; then
  APPNAME="issue-218"
else
  APPNAME="issue-218norm" # the control: the same fixture without render-markdown.lua
fi
CONFHOME="$WORK/config"
mkdir -p "$CONFHOME"
cp -R "$REPO_ROOT/fixtures/issue-218" "$CONFHOME/$APPNAME"
if [[ "$WANT_RM" -eq 0 ]]; then
  rm "$CONFHOME/$APPNAME/lua/plugins/render-markdown.lua"
fi
# lazy.nvim runs `:source` on the plugin files of the checkout, and `:source` expands `$VAR`
# and backticks in a path. Neovim gets this plain symlink instead of the checkout path, so a
# checkout under any directory name loads.
CHECKOUT_LINK="$WORK/checkout"
ln -s "$REPO_ROOT" "$CHECKOUT_LINK"

echo "Repo:        $REPO_ROOT"
echo "Neovim:      $("$NVIM_BIN" --version | head -1)  ($NVIM_BIN)"
echo "render-md:   $([[ $WANT_RM -eq 1 ]] && echo INSTALLED || echo REMOVED)"
echo "Workdir:     $WORK"
echo

echo "==> Installing fixture plugins at the commits in lazy-lock.json (lazy restore)…"
# Neovim exits 0 even when `Lazy! restore` fails (for example when a pinned commit cannot be
# fetched), so the check below compares every plugin the config uses with the committed
# lock file. lazy.nvim itself is skipped (see the header). Paths reach Neovim through
# environment variables, never through its command line, so a path cannot be parsed as Ex
# syntax. The copy is outside the checkout, so CLAUDECODE_DEV_DIR tells the fixture which
# checkout to load.
RESTORE_CHECK="$WORK/restore_check.lua"
cat >"$RESTORE_CHECK" <<'EOF'
local lock = vim.json.decode(table.concat(vim.fn.readfile(vim.env.REPRO218_LOCKFILE), "\n"))
local Git = require("lazy.manage.git")
local stale = {}
for _, plugin in ipairs(require("lazy").plugins()) do
  if plugin.name ~= "lazy.nvim" and not plugin._.is_local then
    local want = lock[plugin.name] and lock[plugin.name].commit
    local info = plugin._.installed and Git.info(plugin.dir) or nil
    if not (want and info and info.commit == want) then
      table.insert(stale, plugin.name)
    end
  end
end
if #stale > 0 then
  io.stderr:write("not at the commit in lazy-lock.json: " .. table.concat(stale, ", ") .. "\n")
  vim.cmd("cquit 3")
end
EOF
RESTORE_LOG="$WORK/restore.log"
NVIM_APPNAME="$APPNAME" XDG_CONFIG_HOME="$CONFHOME" CLAUDECODE_DEV_DIR="$CHECKOUT_LINK" \
  REPRO218_LOCKFILE="$REPO_ROOT/fixtures/issue-218/lazy-lock.json" REPRO218_RESTORE_CHECK="$RESTORE_CHECK" \
  "$NVIM_BIN" --headless "+Lazy! restore" "+lua dofile(vim.env.REPRO218_RESTORE_CHECK)" "+qa" >"$RESTORE_LOG" 2>&1
RESTORE_RC=$?
if [[ "$RESTORE_RC" -ne 0 ]]; then
  STALE="$(sed -n 's/^.*not at the commit in lazy-lock.json: //p' "$RESTORE_LOG")"
  echo "ERROR: Lazy! restore did not leave the fixture plugins at the commits in lazy-lock.json (nvim exit $RESTORE_RC)." >&2
  if [[ -n "$STALE" ]]; then
    echo "       Not at their locked commit: $STALE" >&2
  else
    echo "       Last lines from Neovim:" >&2
    tail -n 5 "$RESTORE_LOG" | sed 's/^/         /' >&2
  fi
  echo "       The run would test other plugin revisions, so it reached no verdict." >&2
  exit 3
fi

# Wrapper launcher that captures Neovim's RAW exit status (139 = SIGSEGV). It is a fixed
# script: the work dir, the nvim binary and the status file arrive as arguments and the
# Neovim environment arrives through `env` below, so no path is ever interpolated into shell
# code.
LAUNCH="$WORK/launch.sh"
cat >"$LAUNCH" <<'EOF'
#!/bin/bash
cd "$1" || exit 1
"$2"
echo "RAW=$?" > "$3"
exit $?
EOF
chmod +x "$LAUNCH"

echo "==> Launching Neovim under agent-tty…"
SID="$("${ATTY[@]}" create --json --cols 150 --rows 44 -- \
  env NVIM_APPNAME="$APPNAME" XDG_CONFIG_HOME="$CONFHOME" CLAUDECODE_DEV_DIR="$CHECKOUT_LINK" \
  "$LAUNCH" "$WORK" "$NVIM_BIN" "$EXITF" | jq -r '.result.sessionId')"
if [[ -z "$SID" || "$SID" == "null" ]]; then
  echo "ERROR: failed to create agent-tty session." >&2
  exit 1
fi
# The socket directory is empty after `destroy`; cleanup removes it. rmdir never removes a
# directory that still holds a socket.
SOCK="$("${ATTY[@]}" inspect "$SID" --json 2>/dev/null | jq -r '.result.host.rpcSocketPath // empty')"
if [[ "$SOCK" == /* ]]; then SOCK_DIR="$(dirname "$SOCK")"; fi

"${ATTY[@]}" wait "$SID" --screen-stable-ms 1800 --json >/dev/null 2>&1 || true

echo "==> :Repro218 (open new-file markdown diff in a new tab)…"
"${ATTY[@]}" type "$SID" ":Repro218" --json >/dev/null 2>&1
"${ATTY[@]}" send-keys "$SID" "Enter" --json >/dev/null 2>&1
"${ATTY[@]}" wait "$SID" --text "Repro218 ready" --timeout 10000 --json >/dev/null 2>&1
READY_RC=$?
if [[ "$READY_RC" -ne 0 ]]; then
  # Without the ready state the :w below checks nothing, so any verdict would be meaningless.
  echo "ERROR: Neovim did not show 'Repro218 ready' within 10 s (agent-tty wait exit $READY_RC)." >&2
  echo "       The run never reached the ready state, so it reached no verdict." >&2
  exit 2
fi
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
