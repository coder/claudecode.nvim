#!/usr/bin/env bash
# Drive claudecode.nvim in a real Neovim (agent-tty) while scripts/ws-client.mjs plays the Claude CLI.
# Usage: vcn.sh <command> [args]. Every command except launch needs VCN_STATE (printed by launch).
#   launch [file...]            start nvim + client; prints VCN_STATE=... and OUT=...
#   doctor                      read-only health check, exit 1 on any FAIL
#   keys [-l] <key|text>...     press each agent-tty key name (Enter, Escape, Ctrl+W), type any other arg;
#                               after -l every arg is typed
#   expr <vimscript-expr>       evaluate an expression over nvim RPC and print it
#   until <expr> <want> [secs]  poll expr until it prints want (default 10 s)
#   rpc <id> <method> [params]  send a JSON-RPC request as the Claude client
#   tool <id> <name> [args]     shorthand for rpc <id> tools/call {name, arguments}
#   await <id> [secs]           print the response with that id, exit 1 on timeout (default 10 s)
#   capture <name>              save the screen text to $OUT/<name>.screen.txt and print it
#   screenshot <name>           save a PNG of the screen to $OUT/<name>.png and print its path
#   record <name>               save a WebM of the session so far to $OUT/<name>.webm and print its path
#   connect                     start one more client, named by VCN_CLIENT, and finish its handshake
#   disconnect                  kill the client VCN_CLIENT names (unset: the launch client)
#   cleanup                     stop everything this run started, delete VCN_STATE, keep $OUT
# VCN_CLIENT=<name> makes rpc, tool, await, connect and disconnect act as that client.
# VCN_AGENT_TTY=<path> makes launch run that agent-tty (default: the first agent-tty on PATH, then mise's, that
#                      passes `agent-tty doctor`).
# VCN_NVIM=<path> makes launch run that nvim (default: the repo's mise nvim, then nvim on PATH).
# VCN_RTP=<dir>[:<dir>...] adds plugin dirs to nvim's runtimepath, for example a snacks.nvim clone.
# TMPDIR=<dir> makes launch put its state dir (vcn.XXXXXX) in <dir> instead of /tmp. <dir> must be an absolute path to an
#              existing directory with no . or .. part, and neither it nor a dir above it may be writable by others without
#              the sticky bit. Launch resolves <dir> once, so VCN_STATE has no symlink in it.
#              agent-tty never reads it: every agent-tty call runs with TMPDIR=$VCN_STATE/tmp.
set -euo pipefail
# Evidence holds buffer text and accepted diffs: keep every file this run writes private.
umask 077
# load records that the check of $VCN_STATE passed. A caller's environment must not be able to preset that.
unset state_checked

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$SKILL_DIR/../../.." && pwd)"
# The key names agent-tty send-keys accepts, in the case its docs use. Lowercase words are typed.
KEY_RE='^((Ctrl|Alt|Shift)\+)*(Enter|Tab|Escape|Backspace|Space|Up|Down|Left|Right|Home|End|Insert|Delete|PageUp|PageDown|F[1-9]|F1[0-2])$'
MOD_CHAR_RE='^((Ctrl|Alt|Shift)\+)+[!-~]$'

die() {
  echo "vcn: $*" >&2
  exit 1
}

bin() {
  mise which "$1" 2>/dev/null || command -v "$1" || die "$1 not found on PATH"
}

env_line() { printf '%s=%q\n' "$1" "$2"; }

# load sources run.env, so $VCN_STATE must be a dir that only this user can write, in a place where no other user can swap
# it. After that one check nothing in it can change under another user's hand. A stale VCN_STATE can name a dir or
# symlink that another user made at a freed name.
unsafe_state() {
  local uid mode real
  # A path with a symlink or a . or .. part could be pointed elsewhere by another user after the check, and source and rm -rf
  # would follow it. realpath -z ends the path with a NUL, so read keeps a newline at its end, which a substitution would cut.
  real=""
  IFS= read -r -d "" real < <(realpath -ez -- "$1" 2>/dev/null) || true
  if [[ $real != "$1" ]]; then
    echo "it is not its own resolved path (${real:-it does not exist})"
    return
  fi
  read -r uid mode < <(stat -c '%u %a' -- "$1" 2>/dev/null) || {
    echo "it does not exist"
    return
  }
  if ((uid != EUID)); then
    echo "it is owned by another user"
  elif (((8#$mode & 8#022) != 0)); then
    echo "it is group- or world-writable"
  else
    unsafe_above "$1" "the state dir"
  fi
}

load() {
  local why
  [[ -n ${VCN_STATE-} ]] || die "VCN_STATE is not set (launch prints it)"
  [[ -f $VCN_STATE/run.env ]] || die "no run at $VCN_STATE (already cleaned up?)"
  # launch calls load many times, and a passed check stays true, so it runs once per VCN_STATE.
  if [[ ${state_checked-} != "$VCN_STATE" ]]; then
    why=$(unsafe_state "$VCN_STATE")
    [[ -z $why ]] || die "refusing state dir $VCN_STATE: $why"
    state_checked=$VCN_STATE
  fi
  [[ -z ${VCN_CLIENT-} || $VCN_CLIENT =~ ^[a-z0-9]+$ ]] || die "VCN_CLIENT must match [a-z0-9]+"
  # shellcheck source=/dev/null
  source "$VCN_STATE/run.env"
  # A run that an older vcn.sh started has no JQ_BIN.
  [[ -n ${JQ_BIN-} ]] || JQ_BIN=$(bin jq)
}

# agent-tty needs Node 24+, so it runs on the repo's mise node. During a teardown (own_session set) it gets a session of
# its own: Node resets the signals that its parent ignores, so `trap ''` does not reach it, and a signal sent to launch's
# process group would end the call. A process in another session never gets that signal. It runs the setsid that launch
# resolved (SETSID_BIN): a bare setsid could be another one on PATH, or none.
#
# agent-tty makes its staging dirs (a WebM export, a screenshot, the browser profile) under TMPDIR and follows every symlink in
# it each time. A caller's TMPDIR can hold a symlink that another user repoints after launch, and a command can run with
# any TMPDIR, so agent-tty gets one of its own: $VCN_STATE/tmp, in the dir that load has checked.
att() {
  local own=()
  [[ -z ${own_session-} ]] || own=("$SETSID_BIN" -w)
  [[ -d $VCN_STATE/tmp ]] || mkdir -m 700 -- "$VCN_STATE/tmp"
  PATH="$NODE_DIR:$PATH" TMPDIR="$VCN_STATE/tmp" ${own[@]+"${own[@]}"} "$ATT_BIN" --home "$ATT_HOME" "$@"
}

# Callers pass --json. A failed command answers ok:false.
attj() {
  local out
  out=$(att "$@") || true
  "$JQ_BIN" -e '.ok == true' <<<"$out" >/dev/null 2>&1 || die "agent-tty $1 failed: ${out:-no output}"
  printf '%s\n' "$out"
}

agent_tty_candidates() {
  if [[ -n ${VCN_AGENT_TTY-} ]]; then
    # Absolute, without resolving symlinks: an agent-tty shim only works under its own name.
    [[ -f $VCN_AGENT_TTY && -x $VCN_AGENT_TTY ]] || die "VCN_AGENT_TTY=$VCN_AGENT_TTY is not an executable file"
    realpath -s -- "$VCN_AGENT_TTY"
    return
  fi
  {
    type -ap agent-tty || true
    mise which agent-tty 2>/dev/null || true
  } | awk '!seen[$0]++'
}

no_agent_tty() {
  die "$1
If a failure names pty.node, that agent-tty lacks node-pty's native build, as a mise-installed npm-agent-tty can. Install one outside mise and name it:
  npm install --prefix <dir> agent-tty@0.5.0
  VCN_AGENT_TTY=<dir>/node_modules/.bin/agent-tty $0 launch"
}

pick_agent_tty() {
  local cand why doctor tried=""
  for cand in "$@"; do
    ATT_BIN=$cand
    # A substitution, so a signal's trap runs with launch's own stderr and not with doctor's redirections.
    doctor=$(att doctor --json 2>"$VCN_STATE/doctor.err") || true
    printf '%s\n' "$doctor" >"$OUT/agent-tty-doctor.json"
    if "$JQ_BIN" -e '.result.ok == true' "$OUT/agent-tty-doctor.json" >/dev/null 2>&1; then
      env_line ATT_BIN "$cand" >>"$VCN_STATE/run.env"
      return 0
    fi
    why=$("$JQ_BIN" -r '[.result.checks[]?[]? | select(.status != "pass") | "\(.name): \(.message)"] | join("; ")' \
      "$OUT/agent-tty-doctor.json" 2>/dev/null || true)
    # A candidate that dies before doctor prints anything leaves only stderr. Take the `Error:` line of a Node stack
    # trace (a source line with `new Error(` comes first) or a mise shim's `mise ERROR` line.
    [[ -n $why ]] || why=$(grep -m1 -E '^([A-Za-z]*Error:|mise ERROR)' "$VCN_STATE/doctor.err" || sed -n '/./{p;q;}' "$VCN_STATE/doctor.err")
    [[ -n $why ]] || why="no usable output"
    tried+=$'\n'"  $cand: $why"
  done
  no_agent_tty "no agent-tty passes \`agent-tty doctor\`:$tried"
}

# nvim runs in $WORK, so a relative VCN_RTP entry would point nowhere and plugin code would silently not load.
# Symlinks resolve too: `link/..` means the parent of link's target, which realpath -s would collapse to link's parent.
rtp_dirs() {
  local dir out="" dirs=() IFS=:
  read -ra dirs <<<"${VCN_RTP-}"
  for dir in ${dirs[@]+"${dirs[@]}"}; do
    [[ -z $dir ]] && continue
    [[ -d $dir ]] || die "VCN_RTP entry $dir is not a directory"
    out+=${out:+:}$(realpath -- "$dir")
  done
  printf '%s' "$out"
}

# A wait that times out still answers ok:true, so read timedOut. On an exited session it answers at once.
settle() {
  local out
  out=$(att wait "$SID" --screen-stable-ms 300 --timeout 5000 --json 2>/dev/null) || true
  "$JQ_BIN" -e '.ok == true and .result.timedOut == false' <<<"$out" >/dev/null 2>&1 ||
    echo "vcn: screen did not settle within 5s; capturing it anyway" >&2
}

nv() {
  local rc=0
  if [[ ${NVIM_08-0} == 1 ]]; then
    # Neovim 0.8 prints the --remote-expr result on stderr, together with any error.
    timeout -s KILL 5 "$NVIM_BIN" --server "$NVIM_SOCK" --remote-expr "$1" 2>&1 || rc=$?
  else
    timeout -s KILL 5 "$NVIM_BIN" --server "$NVIM_SOCK" --remote-expr "$1" || rc=$?
  fi
  # GNU timeout exits 137 after -s KILL, uutils exits 124.
  ((rc != 124 && rc != 137)) || echo "vcn: nvim RPC gave no answer in 5s; nvim may be blocked in a prompt" >&2
  return "$rc"
}

# Each client has its own message files: ws-out.jsonl for the launch client, ws-out-<name>.jsonl for another.
chan() { printf '%s' "${VCN_CLIENT:+-$VCN_CLIENT}"; }

client_pid_var() { printf 'CLIENT_PID%s' "${VCN_CLIENT:+_$VCN_CLIENT}"; }

send() { "$JQ_BIN" -nc "$@" >>"$OUT/ws-out$(chan).jsonl"; }

# await matches responses by id, so a reused id would return the earlier answer.
cmd_rpc() {
  "$JQ_BIN" -e --arg id "$1" 'select(.id == $id)' "$OUT/ws-out$(chan).jsonl" >/dev/null 2>&1 &&
    die "id $1 was already used by this client; pick a new id"
  send --arg id "$1" --arg m "$2" --argjson p "${3-"{}"}" '{jsonrpc:"2.0",id:$id,method:$m,params:$p}'
}

cmd_await() {
  local id=$1 secs=${2-10} line
  local deadline=$((SECONDS + secs))
  while :; do
    # fromjson? skips a line the client is still writing.
    line=$("$JQ_BIN" -cR --arg id "$id" 'fromjson? | select(.id == $id)' "$OUT/ws-in$(chan).jsonl" | head -n 1)
    if [[ -n $line ]]; then
      echo "$line"
      return 0
    fi
    ((SECONDS < deadline)) || die "no response for id $id within ${secs}s"
    sleep 0.1
  done
}

cmd_until() {
  local expr=$1 want=$2 secs=${3-10} got=""
  local deadline=$((SECONDS + secs))
  while :; do
    got=$(nv "$expr" 2>/dev/null || true)
    [[ $got == "$want" ]] && return 0
    ((SECONDS < deadline)) || die "'$expr' is '$got', wanted '$want' after ${secs}s"
    sleep 0.1
  done
}

# One batch keeps the steps in order and costs one agent-tty call.
cmd_keys() {
  local literal=0 steps='[]' arg
  (($# > 0)) || die "keys needs at least one key or text"
  for arg in "$@"; do
    if ((!literal)) && [[ $arg == -l ]]; then
      literal=1
      continue
    fi
    [[ -n $arg ]] || die "keys got an empty argument"
    if ((!literal)) && [[ $arg =~ $KEY_RE || $arg =~ $MOD_CHAR_RE ]]; then
      steps=$("$JQ_BIN" -c --arg k "$arg" '. + [{sendKeys: [$k]}]' <<<"$steps")
    else
      steps=$("$JQ_BIN" -c --arg t "$arg" '. + [{type: $t}]' <<<"$steps")
    fi
  done
  attj batch "$SID" "$steps" --json >/dev/null
}

cmd_capture() {
  settle
  attj snapshot "$SID" --format text --json | "$JQ_BIN" -r .result.text >"$OUT/$1.screen.txt"
  cat "$OUT/$1.screen.txt"
}

# screenshot has no output flag: it writes under ATT_HOME, which cleanup deletes, so copy it out.
cmd_screenshot() {
  local src
  settle
  src=$(attj screenshot "$SID" --json | "$JQ_BIN" -r .result.artifactPath)
  cp "$src" "$OUT/$1.png"
  echo "$OUT/$1.png"
}

cmd_record() {
  settle
  attj record export "$SID" --format webm --timing accelerated --out "$OUT/$1.webm" --json >/dev/null
  echo "$OUT/$1.webm"
}

ours() { [[ -n $1 ]] && grep -qzxF "VCN_RUN_TAG=$VCN_STATE" "/proc/$1/environ" 2>/dev/null; }

tagged() { grep -lzxF "VCN_RUN_TAG=$VCN_STATE" /proc/[0-9]*/environ 2>/dev/null | cut -d/ -f3 || true; }

ppid() { ps -o ppid= -p "$1" 2>/dev/null | tr -d ' '; }

is_exe() { [[ -n $1 && $(readlink "/proc/$1/exe" 2>/dev/null) == "$(readlink -f "$2")" ]]; }

# Neovim 0.9+ runs the server that answers RPC as a child of the TUI process. On 0.8 one process is both.
server_under_tui() {
  if [[ ${NVIM_08-0} == 1 ]]; then [[ $NVIM_PID == "$TUI_PID" ]]; else [[ $(ppid "$NVIM_PID") == "$TUI_PID" ]]; fi
}

# cleanup fast: for a signal, whose sender wants launch gone. It skips the evidence (a screenshot and a video), which
# takes many seconds on a loaded host.
cmd_cleanup() {
  local fast=${1-}
  if [[ -z ${VCN_STATE-} || ! -f $VCN_STATE/run.env ]]; then
    echo "vcn: nothing to clean at ${VCN_STATE-<unset>}"
    return 0
  fi
  load
  [[ $VCN_STATE =~ ^/(.*/)?vcn\.[A-Za-z0-9]{6}$ ]] || die "refusing to delete unexpected state dir $VCN_STATE"
  local i var pids=()
  # agent-tty still renders a session whose nvim exited, so the evidence step runs for any session.
  if [[ -n ${SID-} ]]; then
    if [[ $fast != fast ]]; then
      (cmd_capture final) >/dev/null || echo "vcn: could not save final.screen.txt" >&2
      (cmd_screenshot final) >/dev/null || echo "vcn: could not save final.png" >&2
      nv 'execute("messages")' >"$OUT/messages.txt" 2>/dev/null || true
      (cmd_record session) >/dev/null || echo "vcn: could not save session.webm" >&2
    fi
    att destroy "$SID" --json >/dev/null 2>&1 || att destroy "$SID" --force --json >/dev/null 2>&1 || true
  fi
  for var in $(compgen -v CLIENT_PID); do
    if ours "${!var}"; then kill "${!var}" 2>/dev/null || true; fi
  done
  for i in $(seq 50); do
    mapfile -t pids < <(tagged)
    ((${#pids[@]} == 0)) && break
    # Every PID here carries this run's tag, so it is ours.
    if ((i == 30)); then kill "${pids[@]}" 2>/dev/null || true; fi
    sleep 0.1
  done
  ((${#pids[@]} == 0)) || die "processes from this run still alive: ${pids[*]}"
  # destroy leaves this home in the per-user registry and its empty socket directory in /tmp/agent-tty.
  [[ -z ${ATT_BIN-} ]] || att home forget "$ATT_HOME" --json >/dev/null 2>&1 || true
  # agent-tty makes the socket directory (the first 8 hex digits of the sha256 of the real path of the home) at its first
  # call, but ATT_SOCK names it only after `inspect`: a run stopped earlier has no ATT_SOCK. ATT_HOME is $VCN_STATE/att,
  # and load refuses a VCN_STATE that is not its own real path, so the path needs no resolving here.
  rmdir "/tmp/agent-tty/$(printf %s "$VCN_STATE/att" | sha256sum | cut -c1-8)" 2>/dev/null || true
  if [[ -n ${ATT_SOCK-} ]]; then rmdir "$(dirname "$ATT_SOCK")" 2>/dev/null || true; fi
  rm -rf "$VCN_STATE"
  echo "vcn: cleanup ok, no processes left; evidence kept in $OUT"
}

cmd_doctor() {
  local fails=0 lock="$VCN_STATE/claude/ide/$PORT.lock" session st mode tok_nvim tok_lock
  check() {
    local label=$1
    shift
    if "$@" >/dev/null 2>&1; then echo "ok    $label"; else
      echo "FAIL  $label"
      fails=$((fails + 1))
    fi
  }
  not_prompt() { [[ -n $1 && $1 != r* ]]; }
  session=$(att inspect "$SID" --json 2>/dev/null | "$JQ_BIN" -c .result.session 2>/dev/null || echo '{}')
  st=$(nv 'luaeval("vim.json.encode(require(\"claudecode.server.init\").get_status())")' 2>/dev/null || echo '{}')
  mode=$(nv 'mode(1)' 2>/dev/null || true)
  tok_nvim=$(nv "luaeval(\"vim.fn.sha256(require('claudecode').state.auth_token)\")" 2>/dev/null || true)
  tok_lock=$("$JQ_BIN" -j .authToken "$lock" 2>/dev/null | sha256sum | cut -d' ' -f1) || true
  check "agent-tty session $SID is running" test "$("$JQ_BIN" -r .status <<<"$session")" = running
  tui_ok() { [[ $("$JQ_BIN" -r .childPid <<<"$session") == "$TUI_PID" ]] && server_under_tui; }
  check "nvim server (pid $NVIM_PID) runs under the session's TUI (pid $TUI_PID)" tui_ok
  check "client ws-client.mjs (pid $CLIENT_PID) is alive" is_exe "$CLIENT_PID" "$NODE_DIR/node"
  check "nvim RPC answers as pid $NVIM_PID" test "$(nv 'getpid()' 2>/dev/null)" = "$NVIM_PID"
  check "nvim is not blocked in a prompt (mode '$mode')" not_prompt "$mode"
  check "lock file $lock names nvim pid $NVIM_PID" test "$("$JQ_BIN" -r .pid "$lock" 2>/dev/null)" = "$NVIM_PID"
  check "plugin server is running on lock port $PORT" test "$("$JQ_BIN" -r '"\(.running) \(.port)"' <<<"$st")" = "true $PORT"
  check "lock authToken matches the server token" test -n "$tok_nvim" -a "$tok_nvim" = "$tok_lock"
  check "a client finished the WebSocket handshake" test "$("$JQ_BIN" '[.clients[]? | select(.handshake_complete)] | length' <<<"$st")" -ge 1
  echo "paths: VCN_STATE=$VCN_STATE OUT=$OUT WORK=$WORK"
  ((fails == 0))
}

# On a shared host another user can read or swap evidence in a dir they own or can write.
# Prints why <dir> is unsafe, or nothing.
unsafe_dir() {
  # A . or .. after a symlink would hide that symlink from unsafe_above.
  if [[ /$1/ == */./* || /$1/ == */../* ]]; then
    echo "$1 has a . or .. part"
  elif [[ -L $1 ]]; then
    echo "$1 is a symlink"
  elif [[ -e $1 && ! -O $1 ]]; then
    echo "$1 is owned by another user"
  elif [[ -e $1 ]] && (((8#$(stat -c %a "$1") & 8#022) != 0)); then
    echo "$1 is group- or world-writable"
  else
    unsafe_above "$1"
  fi
}

# Another user who can write a dir above <dir> can rename <dir> away after the checks.
unsafe_above() {
  local logical="" resolved="" why
  IFS= read -r -d "" logical < <(realpath -smz -- "$1/..") || true
  IFS= read -r -d "" resolved < <(realpath -mz -- "$1/..") || true
  why=$(unsafe_walk "$logical" "${2-the evidence dir}")
  if [[ -z $why && $resolved != "$logical" ]]; then
    why=$(unsafe_walk "$resolved" "${2-the evidence dir}")
  fi
  [[ -z $why ]] || echo "$why"
}

# stat prints one record per dir, mode, owner and type and no name, so no path is ever read back from a line of text:
# a name with a trailing space, a tab or a newline would be cut, and a twin symlink with the shorter name tested in its
# place. The type is the raw mode in hex (%f): GNU stat translates the label that %F prints.
unsafe_walk() {
  local dir=$1 what=$2 mode uid raw rec i=0 dirs=() existing=()
  while :; do
    dirs+=("$dir")
    [[ $dir != / ]] || break
    dir=${dir%/*}
    dir=${dir:-/}
  done
  for dir in "${dirs[@]}"; do
    if [[ -e $dir || -L $dir ]]; then existing+=("$dir"); fi
  done
  while IFS= read -r rec; do
    read -r mode uid raw <<<"$rec"
    dir=${existing[i]-}
    i=$((i + 1))
    if ((uid != 0 && uid != EUID)); then
      echo "$dir, above $what, is owned by another user"
      return
    fi
    if (((16#$raw & 16#f000) != 16#a000)) && (((8#$mode & 8#022) != 0 && (8#$mode & 8#1000) == 0)); then
      echo "$dir, above $what, is writable by others and not sticky"
      return
    fi
  done < <(stat -c '%a %u %f' -- "${existing[@]}" 2>/dev/null)
  if ((i != ${#existing[@]})); then
    echo "$1, above $what, could not be read in full"
  fi
}

# The fast cleanup runs for $signaled, not for status 143: a child that someone else killed with SIGTERM also gives 143.
# A second signal must not stop the teardown halfway.
launch_failed() {
  local rc=$?
  ((rc == 0)) && return 0
  trap '' TERM INT HUP
  own_session=1
  if [[ -n $signaled ]]; then
    echo "vcn: launch failed (VCN_STATE=$VCN_STATE); tearing the run down" >&2
    cmd_cleanup fast >&2 || true
  else
    echo "vcn: launch failed (VCN_STATE=$VCN_STATE)${SID:+; screen saved to $OUT/launch-failure.screen.txt}; tearing the run down" >&2
    (cmd_capture launch-failure) >/dev/null 2>&1 || true
    cmd_cleanup >&2 || true
  fi
  exit "$rc"
}

# Start ws-client.mjs as the client VCN_CLIENT names, record its PID, and finish the MCP handshake.
start_client() {
  local ch init
  ch=$(chan)
  : >>"$OUT/ws-out$ch.jsonl"
  : >>"$OUT/ws-in$ch.jsonl"
  # setsid: an agent's bash tool kills the background jobs of a call when the call ends, and the
  # client must outlive it. The client reads the token from the lock file, so it is not in argv.
  VCN_RUN_TAG=$VCN_STATE "$SETSID_BIN" "$NODE_DIR/node" "$SKILL_DIR/scripts/ws-client.mjs" \
    "$VCN_STATE/claude/ide/$PORT.lock" "$OUT/ws-out$ch.jsonl" "$OUT/ws-in$ch.jsonl" \
    </dev/null >/dev/null 2>>"$OUT/ws-client$ch.log" &
  env_line "$(client_pid_var)" "$!" >>"$VCN_STATE/run.env"
  load
  # VCN_INIT_JSONRPC lets scripts/proof-launch-refusals.sh get a real error answer from the plugin.
  send --arg v "${VCN_INIT_JSONRPC:-2.0}" \
    '{jsonrpc:$v,id:"init",method:"initialize",params:{protocolVersion:"2025-06-18",capabilities:{},clientInfo:{name:"vcn",version:"0"}}}'
  init=$(cmd_await init 10)
  "$JQ_BIN" -e '.result.protocolVersion | type == "string"' <<<"$init" >/dev/null || die "initialize failed: $init"
  send '{jsonrpc:"2.0",method:"notifications/initialized"}'
}

cmd_connect() {
  local var
  [[ -n ${VCN_CLIENT-} ]] || die "connect needs VCN_CLIENT=<name> for the new client"
  var=$(client_pid_var)
  [[ -z ${!var-} ]] || die "client $VCN_CLIENT was already started in this run"
  SETSID_BIN=$(bin setsid)
  start_client
  echo "client $VCN_CLIENT connected; its messages are in $OUT/ws-out$(chan).jsonl and $OUT/ws-in$(chan).jsonl"
}

# Kill a client by its recorded PID, the way a Claude CLI that exits drops its socket.
cmd_disconnect() {
  local var
  var=$(client_pid_var)
  ours "${!var-}" || die "client ${VCN_CLIENT:-<launch>} is not running in this run"
  kill "${!var}"
}

cmd_launch() {
  # The launch client is the unnamed one, whatever VCN_CLIENT the caller set.
  local VCN_CLIENT=""
  local nvim_exe att_cands node_exe tmpdir given state out="" guard why sid tui sock lock="" f i dir missing made mode nvim_08=0
  if [[ -n ${VCN_NVIM-} ]]; then
    # Absolute, without resolving symlinks: a mise shim only works under its own name.
    nvim_exe=$(realpath -s -- "$VCN_NVIM")
    [[ -f $nvim_exe && -x $nvim_exe ]] || die "VCN_NVIM=$VCN_NVIM is not an executable file"
  else
    nvim_exe=$(bin nvim)
  fi
  [[ $("$nvim_exe" --version | head -n 1) != "NVIM v0.8."* ]] || nvim_08=1
  att_cands=$(agent_tty_candidates)
  [[ -n $att_cands ]] || no_agent_tty "agent-tty not found on PATH or through mise"
  mapfile -t att_cands <<<"$att_cands"
  VCN_RTP=$(rtp_dirs)
  node_exe=$(bin node)
  # Every call runs these paths, not the bare names: another setsid or jq earlier on PATH could differ or fail.
  SETSID_BIN=$(bin setsid)
  JQ_BIN=$(bin jq)
  [[ -f $REPO/lua/claudecode/init.lua ]] || die "$REPO is not a claudecode.nvim checkout"
  if [[ -n ${VERIFY_OUT-} ]]; then
    # A trailing slash would make -L test the symlink's target.
    guard=$VERIFY_OUT
    while [[ $guard == ?*/ ]]; do guard=${guard%/}; done
    # Absolute, so a leading "-" is not read as an option and later commands can run from any directory.
    [[ $guard == /* ]] || guard=$PWD/$guard
    out=$guard
  else
    guard=${XUM_SCRATCH_DIR:-/tmp}/verify-claudecode-nvim
  fi
  why=$(unsafe_dir "$guard")
  [[ -z $why ]] || die "refusing evidence dir: $why; set VERIFY_OUT to a fresh dir you own"
  if [[ -n $out && -e $out && ! -d $out ]]; then
    die "$out is not a directory; pick a fresh VERIFY_OUT"
  fi
  tmpdir=${TMPDIR:-/tmp}
  [[ $tmpdir == /* ]] || die "TMPDIR=${TMPDIR-} is not an absolute path"
  # As for VERIFY_OUT, a path that has a . or .. part is refused, not resolved: TMPDIR must already be the dir it names.
  [[ /$tmpdir/ != */./* && /$tmpdir/ != */../* ]] || die "TMPDIR=$tmpdir has a . or .. part"
  # mktemp gets the resolved path, so the check below and mktemp see the same path. A dir that is missing now could be made by
  # another user after the check and before mktemp.
  given=""
  IFS= read -r -d "" given < <(realpath -smz -- "$tmpdir" 2>/dev/null) || given=""
  IFS= read -r -d "" tmpdir < <(realpath -ez -- "$tmpdir" 2>/dev/null) || tmpdir=""
  [[ -d $tmpdir ]] || die "TMPDIR=${TMPDIR:-/tmp} is not an existing directory"
  # Another user who can write TMPDIR or a dir above it could swap the state dir for one with a run.env of their own, which
  # cleanup and every other command source.
  why=$(unsafe_walk "$tmpdir" "the state dir")
  [[ -z $why ]] || die "refusing TMPDIR: $why; set TMPDIR to a dir only you can write"
  # agent-tty reads TMPDIR as it was given and makes its staging dirs there, so another user who can repoint a symlink in the
  # path as given (who owns it, or can write the dir that holds it) could redirect them. The walk covers that path as well.
  why=$(unsafe_walk "$given" "the state dir")
  [[ -z $why ]] || die "refusing TMPDIR: $why; set TMPDIR to a dir only you can write"
  # Short /tmp path: the nvim RPC socket path must stay under 108 bytes.
  # A signal while mktemp runs is recorded and acted on once the state dir exists. mktemp ignores signals, so it cannot
  # die between making the dir and printing its name.
  signaled=""
  trap 'signaled=1' TERM INT HUP
  state=$(
    trap '' TERM INT HUP
    exec mktemp -d "${tmpdir%/}/vcn.XXXXXX"
  )
  trap 'trap "" TERM INT HUP; rm -rf -- "$state"; exit 143' TERM INT HUP
  [[ -z $signaled ]] || {
    rm -rf -- "$state"
    exit 143
  }
  out=${out:-$guard/$(date -u +%Y%m%dT%H%M%SZ)-${state##*.}}
  if [[ -e $out ]] && [[ -n $(ls -A "$out") ]]; then
    rmdir "$state"
    die "$out is not empty; pick a fresh VERIFY_OUT"
  fi
  missing=()
  dir=$out
  while [[ ! -e $dir && ! -L $dir ]]; do
    missing+=("$dir")
    dir=$(dirname -- "$dir")
  done
  # Make each missing dir 0700 as mkdir creates it, shallowest first, so a default ACL on a parent never gives the
  # group access to it. With mkdir -p, the dirs above the evidence dir would get the ACL's mode, and the check below
  # would refuse them. made lists the dirs this launch made, deepest first, so a refusal can remove them again.
  made=()
  for ((i = ${#missing[@]} - 1; i >= 0; i--)); do
    if why=$(mkdir -m 700 -- "${missing[i]}" 2>&1); then
      made=("${missing[i]}" ${made[@]+"${made[@]}"})
    elif ((i > 0)) && [[ -d ${missing[i]} && ! -L ${missing[i]} ]]; then
      : # Another launch made this parent dir first. Use it: the check below decides whether it is safe.
    else
      echo "$why" >&2
      rmdir "$state"
      ((${#made[@]} == 0)) || rmdir -- "${made[@]}" || true
      die "cannot create $out; set VERIFY_OUT to a fresh dir you own"
    fi
  done
  # Check again: another user could have made the dir between the first check and mkdir, and a
  # default ACL can make a new dir group-writable whatever the umask.
  why=$(unsafe_dir "$guard")
  if [[ -n $why ]]; then
    rmdir "$state"
    # rmdir removes only empty dirs, and made holds only dirs this launch made, so this never deletes a file, a
    # non-empty dir, or a dir that another process made.
    ((${#made[@]} == 0)) || rmdir -- "${made[@]}" || true
    die "refusing evidence dir: $why; set VERIFY_OUT to a fresh dir you own"
  fi
  # A default ACL on the evidence dir, which mkdir copies from its parent and chmod leaves alone, gives every
  # file made in it group access whatever the umask. Remove all ACLs from it and from the dirs this launch made
  # above it, make it 0700 (a 0500 VERIFY_OUT is safe but not writable), then check that a new file is private.
  if command -v setfacl >/dev/null; then
    setfacl -b -k -- "$out" ${made[@]+"${made[@]}"} 2>/dev/null || true
  fi
  chmod 700 "$out"
  : >"$out/ws-in.jsonl"
  mode=$(stat -c %a -- "$out/ws-in.jsonl")
  if [[ $mode != 600 ]]; then
    rm -f -- "$out/ws-in.jsonl"
    rmdir "$state"
    ((${#made[@]} == 0)) || rmdir -- "${made[@]}" || true
    die "a new file in $out gets mode $mode, not 600; remove its default ACL (setfacl -k) or set VERIFY_OUT to another dir"
  fi
  mkdir -p "$state"/{home,claude,work,tmp}
  printf 'alpha\nbeta\ngamma\n' >"$state/work/hello.txt"
  printf 'one\ntwo\nthree\nfour\n' >"$state/work/other.txt"
  : >"$out/ws-out.jsonl"
  {
    env_line VCN_STATE "$state"
    env_line OUT "$out"
    env_line WORK "$state/work"
    env_line ATT_HOME "$state/att"
    env_line NVIM_SOCK "$state/nvim.sock"
    env_line NVIM_BIN "$nvim_exe"
    env_line NVIM_08 "$nvim_08"
    env_line NODE_DIR "$(dirname "$node_exe")"
    env_line JQ_BIN "$JQ_BIN"
  } >"$state/run.env"
  export VCN_STATE=$state
  # load refuses a state dir that is not its own resolved path or that others can reach, before launch has a teardown to run,
  # and launch_failed would only call load again. A refusal here removes what this launch made.
  why=$(unsafe_state "$state")
  if [[ -n $why ]]; then
    rm -f -- "$out/ws-in.jsonl" "$out/ws-out.jsonl"
    rm -rf -- "$state"
    ((${#made[@]} == 0)) || rmdir -- "${made[@]}" || true
    die "refusing state dir $state: $why"
  fi
  load
  trap launch_failed EXIT
  # A signal ends bash with $? still 0 in the EXIT trap, so this trap acts on it: it ignores the signals, drops the
  # EXIT trap, and runs launch_failed itself with status 143. An exit here would end the shell before the teardown
  # when the trap runs inside the EXIT trap of a launch that failed by itself, before launch_failed ignores signals.
  trap 'trap "" TERM INT HUP; signaled=1; trap - EXIT; (exit 143) || launch_failed' TERM INT HUP
  pick_agent_tty "${att_cands[@]}"
  load
  [[ $# -gt 0 ]] || set -- hello.txt
  # COLORTERM: agent-tty answers no truecolor query, so without it nvim keeps 'notermguicolors'. The default
  # colorscheme then gives DiffChange no color, and a changed line shows only its changed characters.
  sid=$(VCN_RUN_TAG=$state attj create --json --cols 160 --rows 40 --cwd "$WORK" --name vcn -- \
    env -i VCN_RUN_TAG="$state" TERM=xterm-256color COLORTERM=truecolor LANG=C.UTF-8 PATH=/usr/bin:/bin HOME="$state/home" \
    XDG_CONFIG_HOME="$state/home/.config" XDG_DATA_HOME="$state/home/.local/share" \
    XDG_STATE_HOME="$state/home/.local/state" XDG_CACHE_HOME="$state/home/.cache" \
    CLAUDE_CONFIG_DIR="$state/claude" VCN_REPO="$REPO" VCN_SETUP="${VCN_SETUP-}" VCN_RTP="${VCN_RTP-}" \
    "$nvim_exe" --listen "$NVIM_SOCK" -u "$SKILL_DIR/scripts/init.lua" "$@" | "$JQ_BIN" -r .result.sessionId)
  env_line SID "$sid" >>"$state/run.env"
  load
  # The session's process is the nvim TUI. It runs the nvim server, which answers RPC, as its child.
  { read -r tui && read -r sock; } < <(attj inspect "$SID" --json | "$JQ_BIN" -r '.result.session.childPid, .result.host.rpcSocketPath')
  {
    env_line TUI_PID "$tui"
    env_line ATT_SOCK "$sock"
  } >>"$state/run.env"
  load
  cmd_until 'getpid() > 0' 1 10
  env_line NVIM_PID "$(nv 'getpid()')" >>"$state/run.env"
  load
  server_under_tui || die "nvim server $NVIM_PID does not run under the session's TUI process $TUI_PID"
  for i in $(seq 100); do
    for f in "$state"/claude/ide/*.lock; do
      [[ -f $f ]] && "$JQ_BIN" -e --argjson p "$NVIM_PID" '.pid == $p' "$f" >/dev/null 2>&1 && lock=$f
    done
    [[ -n $lock ]] && break
    sleep 0.1
  done
  [[ -n $lock ]] || die "no lock file for pid $NVIM_PID in $state/claude/ide"
  env_line PORT "$(basename "$lock" .lock)" >>"$state/run.env"
  load
  start_client
  cp "$state/run.env" "$OUT/run.env"
  {
    "$nvim_exe" --version | head -n 1
    echo "agent-tty $(att version --json | "$JQ_BIN" -r .result.cliVersion)"
  } >>"$OUT/run.env"
  echo "VCN_STATE=$state"
  echo "OUT=$OUT"
  trap - EXIT TERM INT HUP
}

case ${1-} in
launch)
  shift
  cmd_launch "$@"
  ;;
cleanup) cmd_cleanup ;;
doctor | keys | expr | until | rpc | tool | await | capture | screenshot | record | connect | disconnect)
  load
  c=$1
  shift
  case $c in
  doctor) cmd_doctor ;;
  keys) cmd_keys "$@" ;;
  expr)
    nv "$1"
    echo
    ;;
  until) cmd_until "$@" ;;
  rpc) cmd_rpc "$@" ;;
  tool) cmd_rpc "$1" tools/call "$("$JQ_BIN" -nc --arg n "$2" --argjson a "${3-"{}"}" '{name:$n,arguments:$a}')" ;;
  await) cmd_await "$@" ;;
  capture) cmd_capture "$1" ;;
  screenshot) cmd_screenshot "$1" ;;
  record) cmd_record "$1" ;;
  connect) cmd_connect ;;
  disconnect) cmd_disconnect ;;
  esac
  ;;
help | -h | --help)
  sed -n '2,/^set /{/^#/s/^# \{0,1\}//p;}' "${BASH_SOURCE[0]}"
  ;;
*)
  sed -n '2,/^set /{/^#/s/^# \{0,1\}//p;}' "${BASH_SOURCE[0]}" >&2
  exit 2
  ;;
esac
