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
#   cleanup                     stop everything this run started, delete VCN_STATE, keep $OUT
set -euo pipefail
# Evidence holds buffer text and accepted diffs: keep every file this run writes private.
umask 077

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

load() {
  [[ -n ${VCN_STATE-} ]] || die "VCN_STATE is not set (launch prints it)"
  [[ -f $VCN_STATE/run.env ]] || die "no run at $VCN_STATE (already cleaned up?)"
  # shellcheck source=/dev/null
  source "$VCN_STATE/run.env"
}

# agent-tty needs Node 24+, so it runs on the repo's mise node.
att() { PATH="$NODE_DIR:$PATH" "$ATT_BIN" --home "$ATT_HOME" "$@"; }

# Callers pass --json. A failed command answers ok:false.
attj() {
  local out
  out=$(att "$@") || true
  jq -e '.ok == true' <<<"$out" >/dev/null 2>&1 || die "agent-tty $1 failed: ${out:-no output}"
  printf '%s\n' "$out"
}

# A wait that times out still answers ok:true, so read timedOut. On an exited session it answers at once.
settle() {
  local out
  out=$(att wait "$SID" --screen-stable-ms 300 --timeout 5000 --json 2>/dev/null) || true
  jq -e '.ok == true and .result.timedOut == false' <<<"$out" >/dev/null 2>&1 ||
    echo "vcn: screen did not settle within 5s; capturing it anyway" >&2
}

nv() {
  local rc=0
  timeout -s KILL 5 "$NVIM_BIN" --server "$NVIM_SOCK" --remote-expr "$1" || rc=$?
  # GNU timeout exits 137 after -s KILL, uutils exits 124.
  ((rc != 124 && rc != 137)) || echo "vcn: nvim RPC gave no answer in 5s; nvim may be blocked in a prompt" >&2
  return "$rc"
}

send() { jq -nc "$@" >>"$OUT/ws-out.jsonl"; }

# await matches responses by id, so a reused id would return the earlier answer.
cmd_rpc() {
  jq -e --arg id "$1" 'select(.id == $id)' "$OUT/ws-out.jsonl" >/dev/null 2>&1 &&
    die "id $1 was already used in this run; pick a new id"
  send --arg id "$1" --arg m "$2" --argjson p "${3-"{}"}" '{jsonrpc:"2.0",id:$id,method:$m,params:$p}'
}

cmd_await() {
  local id=$1 secs=${2-10} line
  local deadline=$((SECONDS + secs))
  while :; do
    # fromjson? skips a line the client is still writing.
    line=$(jq -cR --arg id "$id" 'fromjson? | select(.id == $id)' "$OUT/ws-in.jsonl" | head -n 1)
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
      steps=$(jq -c --arg k "$arg" '. + [{sendKeys: [$k]}]' <<<"$steps")
    else
      steps=$(jq -c --arg t "$arg" '. + [{type: $t}]' <<<"$steps")
    fi
  done
  attj batch "$SID" "$steps" --json >/dev/null
}

cmd_capture() {
  settle
  attj snapshot "$SID" --format text --json | jq -r .result.text >"$OUT/$1.screen.txt"
  cat "$OUT/$1.screen.txt"
}

# screenshot has no output flag: it writes under ATT_HOME, which cleanup deletes, so copy it out.
cmd_screenshot() {
  local src
  settle
  src=$(attj screenshot "$SID" --json | jq -r .result.artifactPath)
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

cmd_cleanup() {
  if [[ -z ${VCN_STATE-} || ! -f $VCN_STATE/run.env ]]; then
    echo "vcn: nothing to clean at ${VCN_STATE-<unset>}"
    return 0
  fi
  load
  [[ $VCN_STATE == /tmp/vcn.* ]] || die "refusing to delete unexpected state dir $VCN_STATE"
  # agent-tty still renders a session whose nvim exited, so the evidence step runs for any session.
  if [[ -n ${SID-} ]]; then
    (cmd_capture final) >/dev/null || echo "vcn: could not save final.screen.txt" >&2
    (cmd_screenshot final) >/dev/null || echo "vcn: could not save final.png" >&2
    nv 'execute("messages")' >"$OUT/messages.txt" 2>/dev/null || true
    (cmd_record session) >/dev/null || echo "vcn: could not save session.webm" >&2
    att destroy "$SID" --json >/dev/null 2>&1 || att destroy "$SID" --force --json >/dev/null 2>&1 || true
  fi
  local i pids=()
  if ours "${CLIENT_PID-}"; then kill "$CLIENT_PID" 2>/dev/null || true; fi
  for i in $(seq 50); do
    mapfile -t pids < <(tagged)
    ((${#pids[@]} == 0)) && break
    # Every PID here carries this run's tag, so it is ours.
    if ((i == 30)); then kill "${pids[@]}" 2>/dev/null || true; fi
    sleep 0.1
  done
  ((${#pids[@]} == 0)) || die "processes from this run still alive: ${pids[*]}"
  # destroy leaves this home in the per-user registry and its empty socket directory in /tmp/agent-tty.
  att home forget "$ATT_HOME" --json >/dev/null 2>&1 || true
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
  session=$(att inspect "$SID" --json 2>/dev/null | jq -c .result.session 2>/dev/null || echo '{}')
  st=$(nv 'luaeval("vim.json.encode(require(\"claudecode.server.init\").get_status())")' 2>/dev/null || echo '{}')
  mode=$(nv 'mode(1)' 2>/dev/null || true)
  tok_nvim=$(nv "luaeval(\"vim.fn.sha256(require('claudecode').state.auth_token)\")" 2>/dev/null || true)
  tok_lock=$(jq -j .authToken "$lock" 2>/dev/null | sha256sum | cut -d' ' -f1) || true
  check "agent-tty session $SID is running" test "$(jq -r .status <<<"$session")" = running
  check "nvim server (pid $NVIM_PID) runs under the session's TUI (pid $TUI_PID)" \
    test "$(jq -r .childPid <<<"$session") $(ppid "$NVIM_PID")" = "$TUI_PID $TUI_PID"
  check "client ws-client.mjs (pid $CLIENT_PID) is alive" is_exe "$CLIENT_PID" "$NODE_DIR/node"
  check "nvim RPC answers as pid $NVIM_PID" test "$(nv 'getpid()' 2>/dev/null)" = "$NVIM_PID"
  check "nvim is not blocked in a prompt (mode '$mode')" not_prompt "$mode"
  check "lock file $lock names nvim pid $NVIM_PID" test "$(jq -r .pid "$lock" 2>/dev/null)" = "$NVIM_PID"
  check "plugin server is running on lock port $PORT" test "$(jq -r '"\(.running) \(.port)"' <<<"$st")" = "true $PORT"
  check "lock authToken matches the server token" test -n "$tok_nvim" -a "$tok_nvim" = "$tok_lock"
  check "a client finished the WebSocket handshake" test "$(jq '[.clients[]? | select(.handshake_complete)] | length' <<<"$st")" -ge 1
  echo "paths: VCN_STATE=$VCN_STATE OUT=$OUT WORK=$WORK"
  ((fails == 0))
}

launch_failed() {
  local rc=$?
  ((rc == 0)) && return 0
  echo "vcn: launch failed; screen saved to $OUT/launch-failure.screen.txt; tearing the run down" >&2
  (cmd_capture launch-failure) >/dev/null 2>&1 || true
  cmd_cleanup >&2 || true
  exit "$rc"
}

cmd_launch() {
  local nvim_exe att_exe node_exe setsid_exe state out sid tui sock init lock="" f i why="" init_method=initialize
  nvim_exe=$(bin nvim)
  att_exe=$(bin agent-tty)
  node_exe=$(bin node)
  setsid_exe=$(bin setsid)
  bin jq >/dev/null
  [[ -f $REPO/lua/claudecode/init.lua ]] || die "$REPO is not a claudecode.nvim checkout"
  # Short /tmp path: the nvim RPC socket path must stay under 108 bytes.
  state=$(mktemp -d /tmp/vcn.XXXXXX)
  out=${VERIFY_OUT:-${XUM_SCRATCH_DIR:-/tmp}/verify-claudecode-nvim/$(date -u +%Y%m%dT%H%M%SZ)-${state##*.}}
  # Absolute and lexical, symlinks kept: with a trailing "/" -L would test a link's target, and a leading "-"
  # would read as an option.
  out=$(realpath -ms -- "$out")
  # On a shared host another user can create the evidence dir, or a symlink in its place, before the run.
  if [[ -L $out ]]; then
    why="is a symlink"
  elif [[ -e $out && ! -d $out ]]; then
    why="is not a directory"
  elif [[ -d $out && ! -O $out ]]; then
    why="is not owned by $(id -un)"
  elif [[ -d $out && -n $(ls -A "$out") ]]; then
    why="is not empty"
  fi
  if [[ -n $why ]]; then
    rmdir "$state"
    die "$out $why; pick a fresh VERIFY_OUT"
  fi
  if ! mkdir -p "$out"; then
    rmdir "$state"
    die "cannot create $out; pick a fresh VERIFY_OUT"
  fi
  mkdir -p "$state"/{home,claude,work}
  chmod 700 "$out"
  printf 'alpha\nbeta\ngamma\n' >"$state/work/hello.txt"
  printf 'one\ntwo\nthree\nfour\n' >"$state/work/other.txt"
  : >"$out/ws-out.jsonl"
  : >"$out/ws-in.jsonl"
  {
    env_line VCN_STATE "$state"
    env_line OUT "$out"
    env_line WORK "$state/work"
    env_line ATT_HOME "$state/att"
    env_line NVIM_SOCK "$state/nvim.sock"
    env_line NVIM_BIN "$nvim_exe"
    env_line ATT_BIN "$att_exe"
    env_line NODE_DIR "$(dirname "$node_exe")"
  } >"$state/run.env"
  export VCN_STATE=$state
  load
  trap launch_failed EXIT
  att doctor --json >"$OUT/agent-tty-doctor.json" || true
  jq -e '.result.ok == true' "$OUT/agent-tty-doctor.json" >/dev/null ||
    die "agent-tty doctor failed: $(jq -r '[.result.checks[]?[]? | select(.status != "pass") | "\(.name): \(.message)"] | join("; ")' "$OUT/agent-tty-doctor.json")"
  [[ $# -gt 0 ]] || set -- hello.txt
  # COLORTERM: agent-tty answers no truecolor query, so without it nvim keeps 'notermguicolors'. The default
  # colorscheme then gives DiffChange no color, and a changed line shows only its changed characters.
  sid=$(VCN_RUN_TAG=$state attj create --json --cols 160 --rows 40 --cwd "$WORK" --name vcn -- \
    env -i VCN_RUN_TAG="$state" TERM=xterm-256color COLORTERM=truecolor LANG=C.UTF-8 PATH=/usr/bin:/bin HOME="$state/home" \
    XDG_CONFIG_HOME="$state/home/.config" XDG_DATA_HOME="$state/home/.local/share" \
    XDG_STATE_HOME="$state/home/.local/state" XDG_CACHE_HOME="$state/home/.cache" \
    CLAUDE_CONFIG_DIR="$state/claude" VCN_REPO="$REPO" VCN_SETUP="${VCN_SETUP-}" \
    "$nvim_exe" --listen "$NVIM_SOCK" -u "$SKILL_DIR/scripts/init.lua" "$@" | jq -r .result.sessionId)
  env_line SID "$sid" >>"$state/run.env"
  load
  # The session's process is the nvim TUI. It runs the nvim server, which answers RPC, as its child.
  { read -r tui && read -r sock; } < <(attj inspect "$SID" --json | jq -r '.result.session.childPid, .result.host.rpcSocketPath')
  {
    env_line TUI_PID "$tui"
    env_line ATT_SOCK "$sock"
  } >>"$state/run.env"
  load
  cmd_until 'getpid() > 0' 1 10
  env_line NVIM_PID "$(nv 'getpid()')" >>"$state/run.env"
  load
  [[ $(ppid "$NVIM_PID") == "$TUI_PID" ]] || die "nvim server $NVIM_PID is not a child of the session's process $TUI_PID"
  for i in $(seq 100); do
    for f in "$state"/claude/ide/*.lock; do
      [[ -f $f ]] && jq -e --argjson p "$NVIM_PID" '.pid == $p' "$f" >/dev/null 2>&1 && lock=$f
    done
    [[ -n $lock ]] && break
    sleep 0.1
  done
  [[ -n $lock ]] || die "no lock file for pid $NVIM_PID in $state/claude/ide"
  env_line PORT "$(basename "$lock" .lock)" >>"$state/run.env"
  load
  # setsid: an agent's bash tool kills the background jobs of a call when the call ends, and the
  # client must outlive it. The client reads the token from the lock file, so it is not in argv.
  VCN_RUN_TAG=$state "$setsid_exe" "$node_exe" "$SKILL_DIR/scripts/ws-client.mjs" "$lock" "$OUT/ws-out.jsonl" \
    "$OUT/ws-in.jsonl" </dev/null >/dev/null 2>>"$OUT/ws-client.log" &
  env_line CLIENT_PID "$!" >>"$state/run.env"
  load
  # VCN_BREAK_INIT=1 sends the request under a method the plugin does not know, so it answers an error. It exists
  # to prove the refusal below (selftest-launch-refusals.sh).
  [[ ${VCN_BREAK_INIT-} != 1 ]] || init_method=vcn/no-such-method
  cmd_rpc init "$init_method" '{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"vcn","version":"0"}}'
  init=$(cmd_await init 10)
  jq -e '.result.protocolVersion | type == "string"' <<<"$init" >/dev/null || die "initialize failed: $init"
  send '{jsonrpc:"2.0",method:"notifications/initialized"}'
  cp "$state/run.env" "$OUT/run.env"
  {
    "$nvim_exe" --version | head -n 1
    echo "agent-tty $(att version --json | jq -r .result.cliVersion)"
  } >>"$OUT/run.env"
  trap - EXIT
  echo "VCN_STATE=$state"
  echo "OUT=$OUT"
}

case ${1-} in
launch)
  shift
  cmd_launch "$@"
  ;;
cleanup) cmd_cleanup ;;
doctor | keys | expr | until | rpc | tool | await | capture | screenshot | record)
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
  tool) cmd_rpc "$1" tools/call "$(jq -nc --arg n "$2" --argjson a "${3-"{}"}" '{name:$n,arguments:$a}')" ;;
  await) cmd_await "$@" ;;
  capture) cmd_capture "$1" ;;
  screenshot) cmd_screenshot "$1" ;;
  record) cmd_record "$1" ;;
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
