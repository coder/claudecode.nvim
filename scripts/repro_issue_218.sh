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
# SIGTERM, SIGINT and SIGHUP run the same cleanup, and the cleanup ignores further signals,
# so every step in it has a deadline. It stops the Neovim that is restoring plugins and
# that Neovim's child processes (SIGTERM, then SIGKILL after about 5 s: Neovim ignores
# SIGTERM while a vim.fn.system() child runs, as in lazy.nvim's bootstrap clone, and then
# does not exit), and removes the plugin directories that the interrupted restore added, so
# that no half-installed plugin stays for the next run. It lets an `agent-tty create` that
# is already running finish (about 5 s), and destroys every session in the run's own
# agent-tty home. Each agent-tty call in the cleanup runs in its own session and has a
# deadline, because Node resets a signal that the cleanup ignores, and a second signal to
# the process group would kill the call.
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
# 143, 130, 129
#      Either run: the script received SIGTERM, SIGINT or SIGHUP, ran its cleanup and
#      reached no verdict.

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

# The warnings of the cleanup go to the stderr that the script started with, kept on fd 8. The
# cleanup can run inside a call whose stderr is redirected, such as `run_killable ... >/dev/null
# 2>&1`, and a warning would vanish there. Children that outlive a call get `8>&-`.
exec 8>&2 || exec 8>/dev/null
# State that the cleanup reads. A signal before the first assignment finds it empty.
WORK=""
AGENT_HOME=""
ATTY=(agent-tty)
SID=""
CREATE_PID=""  # `agent-tty create`: the cleanup lets it finish, then destroys its session
RESTORING=0    # 1 while the restore Neovim runs
LAZY_DIR=""    # stdpath("data")/lazy of the fixture's NVIM_APPNAME
LAZY_BEFORE="" # the entries of LAZY_DIR before the restore
# bash runs a trap only after a foreground command ends, but `wait` returns at once. So the
# long commands run in the background and the script waits for them. A signal then runs the
# cleanup at once, and the cleanup stops every job that is still running.
run_killable() {
  "$@" 8>&- &
  wait $!
}
# The live processes among the PIDs in $2... and all the current descendants of PID $1, one `ps`
# call. A zombie does not count. `ps -A -o pid= -o ppid= -o stat=` works on Linux and macOS.
# shellcheck disable=SC2329  # only the cleanup (an EXIT trap) calls it
tree_alive() {
  local root=$1
  shift
  ps -A -o pid= -o ppid= -o stat= 2>/dev/null | awk -v root="$root" -v list=" $* " '
    { pid[NR] = $1; st[NR] = $3; kids[$2] = kids[$2] " " $1 }
    END {
      seen[root] = 1; queue[1] = root; n = 1
      for (h = 1; h <= n; h++) {
        m = split(kids[queue[h]], k, " ")
        for (i = 1; i <= m; i++) if (!(k[i] in seen)) { seen[k[i]] = 1; queue[++n] = k[i] }
      }
      for (i = 1; i <= NR; i++)
        if (st[i] !~ /^Z/ && ((pid[i] in seen) || index(list, " " pid[i] " "))) printf "%s ", pid[i]
    }'
}
# Stop the process $1 and its descendants. SIGTERM first: git removes a partial clone on SIGTERM.
# Neovim ignores a deadly signal while a vim.fn.system() child runs, so SIGKILL whatever is alive
# after about 5 s. Descendants that appear while it waits get the SIGTERM too. The deadline is in
# seconds, not in loop counts, because one `ps` call can take 0.3 s on a loaded host.
# shellcheck disable=SC2329  # only the cleanup (an EXIT trap) calls it
stop_tree() {
  local known=" " live new p end=$((SECONDS + 6))
  while :; do
    # shellcheck disable=SC2086  # the list of PIDs is split on purpose
    live="$(tree_alive "$1" $known)"
    [[ -n "$live" ]] || return 0
    new=""
    for p in $live; do
      [[ "$known" == *" $p "* ]] || new+=" $p"
    done
    known+="$new "
    # shellcheck disable=SC2086
    [[ -z "$new" ]] || kill $new 2>/dev/null || true
    ((SECONDS < end)) || break
    sleep 0.1
  done
  # shellcheck disable=SC2086
  kill -KILL $live 2>/dev/null || true
}
# Run a command in its own session, so that a signal to this script's process group cannot
# reach it. setsid(1) is not on macOS, but /usr/bin/perl is. Without either, run it as it is.
# shellcheck disable=SC2329  # only the cleanup (an EXIT trap) calls it
in_new_session() {
  if command -v setsid >/dev/null 2>&1; then
    setsid -w "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or die "exec $ARGV[0]: $!\n"' -- "$@"
  else
    "$@"
  fi
}
# The socket directory of agent-tty home $1: /tmp/agent-tty/ and the first 8 hex digits of the
# sha256 of the home path (agent-tty's sessionPaths.js). Prints nothing without a sha256 tool.
# shellcheck disable=SC2329  # only the cleanup (an EXIT trap) calls it
socket_dir() {
  local sum=""
  if command -v sha256sum >/dev/null 2>&1; then
    sum="$(printf '%s' "$1" | sha256sum)"
  elif command -v shasum >/dev/null 2>&1; then
    sum="$(printf '%s' "$1" | shasum -a 256)"
  elif command -v openssl >/dev/null 2>&1; then
    sum="$(printf '%s' "$1" | openssl dgst -sha256 | sed 's/^.* //')"
  fi
  sum="${sum:0:8}"
  [[ "$sum" =~ ^[0-9a-f]{8}$ ]] && printf '/tmp/agent-tty/%s' "$sum"
  return 0
}
# shellcheck disable=SC2329  # only the cleanup (an EXIT trap) calls it
warn() {
  printf '%s\n' "$*" >&8
}
# An agent-tty call from the cleanup: its own session, and SIGKILL after about $1 seconds. Node
# resets a signal that `trap ''` ignores, so without the session a second signal to the process
# group kills `list`, `inspect` or `destroy`, and the session survives. Output goes to the caller,
# and the error output is dropped. A call that takes 3 s on a quiet host can take 10 s on a busy
# one, so the deadlines are long. A call that the deadline stops prints a warning and returns 124.
# shellcheck disable=SC2329  # only the cleanup (an EXIT trap) calls it
atty_cleanup() {
  local secs=$1 end=$((SECONDS + $1)) pid live what
  shift
  what=$1
  [[ "$1" != home ]] || what="$1 $2"
  in_new_session "${ATTY[@]}" "$@" 2>/dev/null 8>&- &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && ((SECONDS < end)); do sleep 0.1; done
  if kill -0 "$pid" 2>/dev/null; then
    live="$(tree_alive "$pid" "$pid")"
    # shellcheck disable=SC2086
    kill -KILL $live 2>/dev/null || true
    wait "$pid" 2>/dev/null
    warn "WARNING: the cleanup stopped 'agent-tty $what' after $secs s."
    return 124
  fi
  wait "$pid" 2>/dev/null
  return 0
}
# shellcheck disable=SC2329  # invoked indirectly via the EXIT trap below
cleanup() {
  trap '' INT TERM HUP # a second signal must not cut the cleanup short
  local pid sid sock socks dir end entry stopped='' forget_stopped='' q_home q_work
  # A create that is still running makes a session whose ID this script has not read yet.
  # Give it about 5 s to finish, then stop it.
  if [[ -n "$CREATE_PID" ]]; then
    end=$((SECONDS + 6))
    while kill -0 "$CREATE_PID" 2>/dev/null && ((SECONDS < end)); do sleep 0.1; done
    ! kill -0 "$CREATE_PID" 2>/dev/null || stop_tree "$CREATE_PID"
    wait "$CREATE_PID" 2>/dev/null || true
  fi
  # Every other job: the restore Neovim, or an agent-tty wait. `jobs -p` also finds a job that
  # a signal caught between `&` and the line that saves its PID.
  for pid in $(jobs -p); do
    stop_tree "$pid"
    wait "$pid" 2>/dev/null || true
  done
  # The fixture's bootstrap skips the clone when lazy.nvim's directory exists, and Lazy! restore
  # trusts a plugin directory. An interrupted restore can leave a half-installed one, so remove
  # the entries that this run added.
  if [[ "$RESTORING" -eq 1 && -n "$LAZY_DIR" && -d "$LAZY_DIR" ]]; then
    for entry in "$LAZY_DIR"/* "$LAZY_DIR"/.[!.]*; do
      [[ -e "$entry" || -L "$entry" ]] || continue
      [[ $'\n'"$LAZY_BEFORE"$'\n' == *$'\n'"${entry##*/}"$'\n'* ]] || rm -rf "$entry"
    done
  fi
  # Only once ATTY carries --home: before that, `agent-tty list` would read the user's own home.
  if [[ "${ATTY[1]:-}" == "--home" ]]; then
    # The home is a fresh temp dir, so every session in it belongs to this run, and `--all`
    # includes a session whose Neovim has exited. `destroy` leaves the session's empty socket
    # directory in /tmp/agent-tty, and rmdir never removes a directory that still holds a
    # socket. It also leaves this run's home in agent-tty's per-user registry.
    socks="$(socket_dir "$AGENT_HOME")"
    atty_cleanup 30 list --all --json >"$WORK/cleanup-list.json" || stopped=1
    for sid in $(jq -r '.result.sessions[]?.sessionId // empty' "$WORK/cleanup-list.json" 2>/dev/null); do
      atty_cleanup 30 inspect "$sid" --json >"$WORK/cleanup-inspect.json" || stopped=1
      sock="$(jq -r '.result.host.rpcSocketPath // empty' "$WORK/cleanup-inspect.json" 2>/dev/null)"
      atty_cleanup 60 destroy "$sid" --json >/dev/null || stopped=1
      if [[ "$sock" == /* ]]; then socks+=" $(dirname "$sock")"; fi
    done
    # The directory of a session whose Neovim has exited has no path in `inspect`, so the home
    # gives it. The host can delete its socket file a moment after `destroy` returns, so retry.
    if [[ -z "$stopped" ]]; then
      end=$((SECONDS + 5))
      for dir in $socks; do
        while [[ -d "$dir" ]] && ! rmdir "$dir" 2>/dev/null && ((SECONDS < end)); do sleep 0.1; done
        [[ ! -d "$dir" ]] || warn "WARNING: the socket directory $dir still holds a socket. A session host of this run can still be running."
      done
    fi
    [[ -n "$stopped" ]] || atty_cleanup 30 home forget "$AGENT_HOME" --json >/dev/null || forget_stopped=1
  fi
  if [[ -n "$stopped" ]]; then
    # A session of this run can still be running, and only the run's own home lists it. So the
    # home and its registry entry stay, and the warning says how to find the session and how to
    # remove everything.
    q_home="$(printf '%q' "$AGENT_HOME")"
    q_work="$(printf '%q' "$WORK")"
    warn "         A session of this run can still be running. Its agent-tty home stays: $q_home"
    warn "         List its sessions:  agent-tty --home $q_home list --all"
    warn "         Remove a session:   agent-tty --home $q_home destroy <session-id>"
    warn "         When no session is left: agent-tty home forget $q_home; rm -rf $q_work"
  elif [[ -n "$WORK" ]]; then
    rm -rf "$WORK"
  fi
  if [[ -n "$forget_stopped" ]]; then
    warn "         agent-tty's registry still lists the home $(printf '%q' "$AGENT_HOME"). Remove the entry with: agent-tty home forget $(printf '%q' "$AGENT_HOME")"
  fi
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP
WORK="$(mktemp -d)"
AGENT_HOME="$WORK/atty"
mkdir -p "$AGENT_HOME" # agent-tty requires its --home dir to exist before `create`
ATTY=(agent-tty --home "$AGENT_HOME")
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
LAZY_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/$APPNAME/lazy"
LAZY_BEFORE="$(ls -A "$LAZY_DIR" 2>/dev/null)"
RESTORING=1
# Neovim reads nothing here. Without </dev/null a failed bootstrap clone waits for a key.
run_killable env NVIM_APPNAME="$APPNAME" XDG_CONFIG_HOME="$CONFHOME" CLAUDECODE_DEV_DIR="$CHECKOUT_LINK" \
  REPRO218_LOCKFILE="$REPO_ROOT/fixtures/issue-218/lazy-lock.json" REPRO218_RESTORE_CHECK="$RESTORE_CHECK" \
  "$NVIM_BIN" --headless "+Lazy! restore" "+lua dofile(vim.env.REPRO218_RESTORE_CHECK)" "+qa" >"$RESTORE_LOG" 2>&1 </dev/null
RESTORE_RC=$?
RESTORING=0
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
CREATE_OUT="$WORK/create.json"
"${ATTY[@]}" create --json --cols 150 --rows 44 -- \
  env NVIM_APPNAME="$APPNAME" XDG_CONFIG_HOME="$CONFHOME" CLAUDECODE_DEV_DIR="$CHECKOUT_LINK" \
  "$LAUNCH" "$WORK" "$NVIM_BIN" "$EXITF" >"$CREATE_OUT" &
CREATE_PID=$!
wait "$CREATE_PID"
CREATE_PID=""
SID="$(jq -r '.result.sessionId' "$CREATE_OUT")"
if [[ -z "$SID" || "$SID" == "null" ]]; then
  echo "ERROR: failed to create agent-tty session." >&2
  exit 1
fi

run_killable "${ATTY[@]}" wait "$SID" --screen-stable-ms 1800 --json >/dev/null 2>&1 || true

echo "==> :Repro218 (open new-file markdown diff in a new tab)…"
"${ATTY[@]}" type "$SID" ":Repro218" --json >/dev/null 2>&1
"${ATTY[@]}" send-keys "$SID" "Enter" --json >/dev/null 2>&1
run_killable "${ATTY[@]}" wait "$SID" --text "Repro218 ready" --timeout 10000 --json >/dev/null 2>&1
READY_RC=$?
if [[ "$READY_RC" -ne 0 ]]; then
  # Without the ready state the :w below checks nothing, so any verdict would be meaningless.
  echo "ERROR: Neovim did not show 'Repro218 ready' within 10 s (agent-tty wait exit $READY_RC)." >&2
  echo "       The run never reached the ready state, so it reached no verdict." >&2
  exit 2
fi
run_killable "${ATTY[@]}" wait "$SID" --screen-stable-ms 1200 --json >/dev/null 2>&1 || true

echo "==> :w (accept the diff)…"
"${ATTY[@]}" send-keys "$SID" "Escape" --json >/dev/null 2>&1
"${ATTY[@]}" type "$SID" ":w" --json >/dev/null 2>&1
"${ATTY[@]}" send-keys "$SID" "Enter" --json >/dev/null 2>&1

# Give Neovim a moment to crash (or not).
run_killable "${ATTY[@]}" wait "$SID" --exit --timeout 8000 --json >/dev/null 2>&1 || true

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
