#!/usr/bin/env bash
# Proves how `vcn.sh launch` picks agent-tty and loads VCN_RTP, with stand-ins for a broken agent-tty and for mise:
#   skip-broken       an agent-tty on PATH that fails `agent-tty doctor` comes first: launch runs the next one that passes
#   mise-broken       mise's agent-tty is the broken one: launch runs the PATH one that passes
#   mise-only         the only good agent-tty is the one `mise which` names: launch runs it
#   path-over-mise    a different good agent-tty on PATH and in mise: the PATH one wins
#   explicit          VCN_AGENT_TTY wins over a broken agent-tty on PATH and a broken one in mise
#   explicit-broken   VCN_AGENT_TTY fails doctor: launch exits 1 naming it, and does not fall back to PATH
#   explicit-missing  VCN_AGENT_TTY is not an executable file: launch exits 1 naming it
#   none-passes       every candidate fails doctor: launch exits 1 with one message that lists each failure (the
#                     `Error:` line of a Node stack trace, and a `mise ERROR` line) and the fix, and claims no saved
#                     screen
#   rtp               VCN_RTP=<dir>:<dir> puts both dirs on nvim's runtimepath, so require() finds a module in each
#   rtp-relative      relative VCN_RTP entries resolve against the directory launch runs in (a shallow temp dir, so
#                     `..` parts cannot clamp at / and hide a missing resolution)
#   rtp-symlink       a VCN_RTP entry with `..` after a symlink means the parent of the link's target
#   rtp-missing       a VCN_RTP entry that is not a directory: launch exits 1 naming it
#   rtp-control       without VCN_RTP the same require() fails
#   sigterm           SIGTERM to the process group of a launch with a live session: it exits 143, leaves no state dir
#                     or process, and saves no evidence (final screen, PNG, WebM), which takes long on a loaded host
#   signal-early      SIGTERM, SIGINT and SIGHUP before the run exists (launch held in `mkdir`): exit 143, no state dir
#   signal-doctor     the same three signals while `agent-tty doctor` runs: exit 143, no state dir, the full cleanup
#                     ran (it calls `agent-tty home forget`), launch printed `vcn: launch failed` to its caller, and the
#                     socket directory that agent-tty made under the run's home is gone
#   signal-mktemp     the same three signals while mktemp is making the state dir: exit 143, no state dir left
#   signal-twice      a second SIGTERM, SIGINT or SIGHUP while the teardown is held in `agent-tty home forget` (or, for
#                     the early teardown, in the `rm` of the state dir): the teardown still finishes (exit 143, no state
#                     dir), and the held `home forget`, a Node process like the real one, is not killed by it
#   signal-storm      ten rounds of SIGTERM, SIGINT and SIGHUP every 0.2 ms while launch is held in `agent-tty doctor`:
#                     the signals that land while the first one's trap hands over to launch_failed do not stop the
#                     teardown
#   signal-outside    a child of launch that someone else kills with SIGTERM makes launch exit 143, but launch got no
#                     signal: it runs the full cleanup, which saves the evidence
#   signal-printed    SIGTERM while launch is blocked printing VCN_STATE (stdout is a full pipe): exit 143, no state dir
#   signal-failed     a launch that fails by itself (initialize answers an error), then SIGTERM to its process group
#                     while the real `agent-tty snapshot` of the failure screen runs: launch exits 1, screen has text
#   decoy-state       a symlink /tmp/vcn.* to a directory of this user, whose run.env would touch a marker, sorts after
#                     the real state dirs: find_state does not pick it and stop_run does not run it
#   cleanup-no-agent-tty  `vcn.sh cleanup` of a run that stopped before an agent-tty passed doctor, so run.env has no
#                     ATT_BIN: it still removes the state dir
# A good agent-tty is $VCN_AGENT_TTY when set, else the first agent-tty on PATH or in mise. The cases that start a run
# need everything under Needs in SKILL.md, and the signal cases need perl.
# Prints one `ok <case>` per case, or `FAIL <case>: <reason>` and exits 1, and ends with `CASES <n>`.
set -euo pipefail
V="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vcn.sh"
root=$PWD
TMP=$(mktemp -d)
live_state="" live_path="" st="" decoy=""
# own_dir <dir>: true for a real directory that this user owns. `vcn.sh cleanup` sources the run.env of a state dir, so the
# proof never acts on one that another user made.
own_dir() { [[ -d $1 && ! -L $1 && -O $1 ]]; }
# stop_run <state dir>: stops a run that a case left behind, so no process of it outlives the proof.
stop_run() {
  [[ $1 == /tmp/vcn.* ]] && own_dir "$1" || return 0
  env PATH="$base" VCN_STATE="$1" "$V" cleanup >/dev/null 2>&1 || true
  rm -rf -- "$1"
}
cleanup_all() {
  if [[ -n $live_state ]]; then
    env PATH="$live_path" VCN_STATE="$live_state" "$V" cleanup >/dev/null 2>&1 || true
  fi
  stop_run "$st"
  [[ -z $decoy || ! -L $decoy ]] || rm -f -- "$decoy"
  rm -rf "$TMP"
}
trap cleanup_all EXIT
cases=0

fail() {
  echo "FAIL $1: $2" >&2
  exit 1
}

good=${VCN_AGENT_TTY:-$(command -v agent-tty || mise which agent-tty)} || fail setup "no agent-tty to use as the good one"
real_mise=$(command -v mise)
real_mkdir=$(command -v mkdir)
real_mktemp=$(command -v mktemp)
real_rm=$(command -v rm)
real_cp=$(command -v cp)
perl=$(command -v perl) || fail setup "perl not found"
# The tools vcn.sh needs, each linked by name, so PATH holds no agent-tty. A mise shim dir would hold one.
mkdir "$TMP/tools"
for tool in jq setsid; do
  exe=$(mise which "$tool" 2>/dev/null || command -v "$tool") || fail setup "$tool not found"
  ln -s "$exe" "$TMP/tools/$tool"
done
base=$TMP/tools:/usr/bin:/bin
for dir in /usr/bin /bin; do
  [[ ! -e $dir/agent-tty ]] || fail setup "$dir holds an agent-tty, so no case can leave PATH without a good one"
done

# The stand-ins die the way a mise-installed agent-tty without node-pty's native build does (Node prints the source
# line with `new Error(` before the `Error:` line) and the way a mise shim does when its tool is disabled.
mkdir "$TMP/broken" "$TMP/shim" "$TMP/mise" "$TMP/good" "$TMP/good2"
cat >"$TMP/broken/agent-tty" <<'BROKEN'
#!/bin/sh
cat >&2 <<'TRACE'
/node_modules/node-pty/lib/utils.js:36
    throw new Error("Failed to load native module: " + name + ".node, checked: " + dirs.join(', ') + ": " + lastError);
          ^

Error: Failed to load native module: pty.node, checked: build/Release, build/Debug, prebuilds/linux-x64: Error: Cannot find module './prebuilds/linux-x64//pty.node'
Require stack:
- /node_modules/node-pty/lib/utils.js
    at Object.loadNativeModule (/node_modules/node-pty/lib/utils.js:36:11)

Node.js v26.12.1
TRACE
exit 1
BROKEN
cat >"$TMP/shim/agent-tty" <<'SHIM'
#!/bin/sh
cat >&2 <<'ERRORS'
mise ERROR agent-tty is not a valid shim. This likely means you uninstalled a tool and the shim does not point to anything.
mise ERROR Version: 2026.10.25 linux-x64 (2026-10-31)
ERRORS
exit 1
SHIM
# The stand-in answers `mise which agent-tty` with $FAKE_MISE_ATT, and runs every other command from the directory the
# proof started in, so a case can launch from another directory and still resolve nvim and node.
cat >"$TMP/mise/mise" <<MISE
#!/bin/sh
if [ "\$1" = which ] && [ "\$2" = agent-tty ]; then
  [ -n "\${FAKE_MISE_ATT-}" ] && echo "\$FAKE_MISE_ATT" && exit 0
  exit 1
fi
cd "$root" && exec "$real_mise" "\$@"
MISE
# The signal cases hold launch at a known point: in the `mktemp` that makes the state dir, in the `mkdir` that makes
# the run's dirs, which runs before run.env exists, in the `rm` of the early teardown (while $GATE/hold-rm exists), or
# in `agent-tty doctor` (the stand-in logs every call to $GATE/calls and answers all but doctor at once, and holds
# `home forget` while $GATE/hold-forget exists). Each stand-in tells the proof it was reached through $GATE/reached.
# The agent-tty stand-in is a Node script, because Node resets the signals that its parent ignored, as it does for the
# real agent-tty: a shell script would keep the ignore and could not show a signal killing `home forget`.
mkdir "$TMP/gate-bin" "$TMP/gate-mktemp" "$TMP/gate-cp" "$TMP/slow"
cat >"$TMP/gate-bin/mkdir" <<MKDIR
#!/bin/sh
case "\$*" in
"-p /tmp/vcn."*"/home /tmp/vcn."*"/claude /tmp/vcn."*"/work")
  if [ ! -f "\$GATE/reached" ]; then
    printf '%s\n' "\$2" | sed 's#/home\$##' >"\$GATE/state"
    : >"\$GATE/reached"
    while [ -f "\$GATE/hold" ]; do sleep 0.05; done
  fi
  ;;
esac
exec "$real_mkdir" "\$@"
MKDIR
cat >"$TMP/gate-bin/rm" <<RM
#!/bin/sh
case "\$*" in
"-rf -- /tmp/vcn."*)
  if [ -f "\$GATE/hold-rm" ]; then
    : >"\$GATE/rm-reached"
    while [ -f "\$GATE/hold-rm" ]; do sleep 0.05; done
  fi
  ;;
esac
exec "$real_rm" "\$@"
RM
cat >"$TMP/gate-mktemp/mktemp" <<MKTEMP
#!/bin/sh
case "\$*" in
"-d /tmp/vcn.XXXXXX")
  name=\$("$real_mktemp" "\$@") || exit 1
  printf '%s\\n' "\$name" >"\$GATE/state"
  : >"\$GATE/reached"
  while [ -f "\$GATE/hold" ]; do sleep 0.05; done
  printf '%s\\n' "\$name"
  exit 0
  ;;
esac
exec "$real_mktemp" "\$@"
MKTEMP
# The `cp` that copies run.env at the end of launch kills itself with SIGTERM, as a child that someone else kills does.
cat >"$TMP/gate-cp/cp" <<CP
#!/bin/sh
case "\$*" in
/tmp/vcn.*/run.env\ */run.env) kill -TERM \$\$ ;;
esac
exec "$real_cp" "\$@"
CP
cat >"$TMP/slow/agent-tty" <<'SLOW'
#!/usr/bin/env node
const fs = require("fs");
const { execFileSync } = require("child_process");
const gate = process.env.GATE;
const [sub, sub2] = process.argv.slice(4);
const wait = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
fs.appendFileSync(`${gate}/calls`, `${process.argv.slice(4, 6).join(" ")}\n`);
if (sub === "home" && sub2 === "forget") {
  if (fs.existsSync(`${gate}/hold-forget`)) {
    fs.writeFileSync(`${gate}/forget-reached`, "");
    while (fs.existsSync(`${gate}/hold-forget`)) wait(50);
  }
  fs.writeFileSync(`${gate}/forget-done`, "");
}
if (sub === "doctor") {
  // The real agent-tty makes the socket directory under this home at its first call.
  // signal-doctor checks that launch removes it.
  if (process.env.REAL_ATT) {
    try {
      execFileSync(process.env.REAL_ATT, process.argv.slice(2), { stdio: "ignore" });
    } catch {}
  }
  fs.writeFileSync(`${gate}/reached`, "");
  wait(300000);
}
SLOW
# A preload (NODE_OPTIONS=--require) that holds the first `agent-tty snapshot` while $GATE/hold-snapshot exists. It runs
# in the Node process of the real agent-tty, after Node has reset the signals that launch's shell ignores.
cat >"$TMP/hold-snapshot.js" <<'HOLD'
const fs = require("fs");
const gate = process.env.GATE;
const args = process.argv.slice(2);
const held = gate && args[0] === "--home" && args[2] === "snapshot" && fs.existsSync(`${gate}/hold-snapshot`);
if (held && !fs.existsSync(`${gate}/snapshot-reached`)) {
  fs.writeFileSync(`${gate}/snapshot-reached`, "");
  const cell = new Int32Array(new SharedArrayBuffer(4));
  while (fs.existsSync(`${gate}/hold-snapshot`)) Atomics.wait(cell, 0, 0, 50);
}
HOLD
chmod +x "$TMP/broken/agent-tty" "$TMP/shim/agent-tty" "$TMP/mise/mise" "$TMP/gate-bin/mkdir" "$TMP/gate-bin/rm" \
  "$TMP/gate-mktemp/mktemp" "$TMP/gate-cp/cp" "$TMP/slow/agent-tty"
ln -s "$good" "$TMP/good/agent-tty"
ln -s "$good" "$TMP/good2/agent-tty"
good_path=$TMP/mise:$TMP/good:$base

# launch <case> <PATH> [VAR=value...]: runs launch, in $launch_cwd when it is set, and sets rc, out and state.
launch() {
  local name=$1 path=$2
  shift 2
  rc=0
  out=$(cd "${launch_cwd:-.}" && env -u VERIFY_OUT -u XUM_SCRATCH_DIR -u VCN_AGENT_TTY PATH="$path" VERIFY_OUT="$TMP/out-$name" "$@" "$V" launch 2>&1) || rc=$?
  state=$(grep -o 'VCN_STATE=/tmp/vcn\.[A-Za-z0-9]*' <<<"$out" | head -n 1 | cut -d= -f2 || true)
  if ((rc == 0)); then
    live_state=$state live_path=$path
  fi
}

stop() {
  [[ -z $state ]] || env PATH="$1" VCN_STATE="$state" "$V" cleanup >/dev/null
  live_state=""
}

launched_with() { # <case> <PATH> <want ATT_BIN> [VAR=value...]
  local name=$1 path=$2 want=$3 got
  shift 3
  launch "$name" "$path" "$@"
  ((rc == 0)) || fail "$name" "launch exited $rc: $out"
  got=$(sed -n 's/^ATT_BIN=//p' "$TMP/out-$name/run.env" | head -n 1)
  stop "$path"
  [[ -f $TMP/out-$name/final.screen.txt ]] || fail "$name" "cleanup saved no final screen"
  [[ $got == "$want" ]] || fail "$name" "run.env has ATT_BIN=$got, wanted $want"
  echo "ok $name: ATT_BIN=$got"
  cases=$((cases + 1))
}

refused() { # <case> <PATH> <text launch prints> [VAR=value...]
  local name=$1 path=$2 want=$3
  shift 3
  launch "$name" "$path" "$@"
  ((rc == 1)) || {
    stop "$path"
    fail "$name" "launch exited $rc, wanted 1: $out"
  }
  [[ $out == *"$want"* ]] || fail "$name" "output lacks '$want': $out"
  [[ $out != *"screen saved"* ]] || fail "$name" "output claims a saved screen, but no session started: $out"
  [[ -z $state || ! -e $state ]] || fail "$name" "state dir $state is still there"
  echo "ok $name: exit 1, output has '$want'"
  cases=$((cases + 1))
}

launched_with skip-broken "$TMP/mise:$TMP/broken:$TMP/good:$base" "$TMP/good/agent-tty"
launched_with mise-broken "$TMP/mise:$TMP/good:$base" "$TMP/good/agent-tty" FAKE_MISE_ATT="$TMP/broken/agent-tty"
launched_with mise-only "$TMP/mise:$base" "$TMP/good/agent-tty" FAKE_MISE_ATT="$TMP/good/agent-tty"
launched_with path-over-mise "$good_path" "$TMP/good/agent-tty" FAKE_MISE_ATT="$TMP/good2/agent-tty"
launched_with explicit "$TMP/mise:$TMP/broken:$base" "$good" VCN_AGENT_TTY="$good" FAKE_MISE_ATT="$TMP/broken/agent-tty"
refused explicit-broken "$TMP/mise:$TMP/good:$base" "$TMP/broken/agent-tty: Error: Failed to load native module: pty.node" \
  VCN_AGENT_TTY="$TMP/broken/agent-tty"
refused explicit-missing "$TMP/mise:$TMP/good:$base" "VCN_AGENT_TTY=$TMP/nope is not an executable file" VCN_AGENT_TTY="$TMP/nope"
refused none-passes "$TMP/mise:$TMP/shim:$TMP/broken:$base" "VCN_AGENT_TTY=<dir>/node_modules/.bin/agent-tty" \
  FAKE_MISE_ATT="$TMP/broken/agent-tty"
for want in "npm install --prefix <dir> agent-tty@0.5.0" \
  "$TMP/shim/agent-tty: mise ERROR agent-tty is not a valid shim." \
  "$TMP/broken/agent-tty: Error: Failed to load native module: pty.node"; do
  [[ $out == *"$want"* ]] || fail none-passes "output lacks '$want': $out"
done

for d in one two; do
  mkdir -p "$TMP/rtp-$d/lua"
  echo "return { dir = '$d' }" >"$TMP/rtp-$d/lua/vcn_rtp_$d.lua"
done
mkdir -p "$TMP/target/inner" "$TMP/target/rtp-linked/lua"
echo "return { dir = 'linked' }" >"$TMP/target/rtp-linked/lua/vcn_rtp_two.lua"
ln -s "$TMP/target/inner" "$TMP/lnk"
probe="luaeval('(pcall(require, \"vcn_rtp_one\") and \"one\" or \"-\") .. (pcall(require, \"vcn_rtp_two\") and \"two\" or \"-\")')"

rtp_case() { # <case> <want require() result> [VAR=value...]
  local name=$1 want=$2 got
  shift 2
  launch "$name" "$good_path" "$@"
  ((rc == 0)) || fail "$name" "launch exited $rc: $out"
  got=$(env PATH="$good_path" VCN_STATE="$state" "$V" expr "$probe" 2>&1) || true
  stop "$good_path"
  [[ $got == "$want" ]] || fail "$name" "require found '$got', wanted '$want'"
  echo "ok $name: require() found '$got'"
  cases=$((cases + 1))
}

rtp_case rtp onetwo VCN_RTP="$TMP/rtp-one:$TMP/rtp-two"
launch_cwd=$TMP rtp_case rtp-relative onetwo VCN_RTP="rtp-one:rtp-two"
rtp_case rtp-symlink onetwo VCN_RTP="$TMP/rtp-one:$TMP/lnk/../rtp-linked"
refused rtp-missing "$good_path" "VCN_RTP entry $TMP/nope is not a directory" VCN_RTP="$TMP/rtp-one:$TMP/nope"
rtp_case rtp-control --

# A signal ends bash with $? still 0 in an EXIT trap, so launch must turn it into an exit to clean up its run.
# A background job starts with SIGINT ignored, and a harness can start it with SIGHUP ignored, and bash cannot trap a
# signal that was ignored at entry: perl resets both before launch starts.
# start_launch <case> <PATH> [VAR=value...]: runs launch in the background in its own process group and sets pid. Its
# output goes to $launch_out when that is set.
start_launch() {
  local name=$1 path=$2
  shift 2
  # shellcheck disable=SC2016
  env -u VERIFY_OUT -u XUM_SCRATCH_DIR -u VCN_AGENT_TTY PATH="$path" VERIFY_OUT="$TMP/out-$name" "$@" \
    "$perl" -e '$SIG{INT} = $SIG{HUP} = "DEFAULT"; exec @ARGV' "$TMP/tools/setsid" "$V" launch >"${launch_out:-$TMP/$name.txt}" 2>&1 </dev/null &
  pid=$!
}

# find_state <case>: sets st to the state dir whose run.env names the case's evidence dir, within 30 s.
find_state() {
  local f
  st=""
  for _ in $(seq 300); do
    for f in /tmp/vcn.*/run.env; do
      if own_dir "${f%/*}" && [[ -f $f ]] && grep -qxF "OUT=$TMP/out-$1" "$f" 2>/dev/null; then st=${f%/*}; fi
    done
    [[ -z $st ]] || return 0
    sleep 0.1
  done
  fail "$1" "launch wrote no run.env within 30 s: $(cat "$TMP/$1.txt")"
}

# wait_for <case> <file>: waits up to 30 s for a stand-in to create the file.
wait_for() {
  for _ in $(seq 300); do
    [[ -f $2 ]] && return 0
    sleep 0.1
  done
  fail "$1" "launch did not reach the stand-in within 30 s: $(cat "$TMP/$1.txt")"
}

# await_exit <case> <signal> <state dir> [status]: waits for launch, checks its exit (143 unless given) and the dir.
await_exit() {
  local name=$1 sig=$2 dir=$3 want=${4-143} rc=0 left pstat
  for _ in $(seq 1800); do
    pstat=$(ps -o stat= -p "$pid" 2>/dev/null) || true
    [[ -z $pstat || $pstat == Z* ]] && break
    sleep 0.1
  done
  if [[ -n $pstat && $pstat != Z* ]]; then
    kill -KILL -- "-$pid" 2>/dev/null || true
    fail "$name" "launch was still running 180 s after SIG$sig (stopped now)"
  fi
  wait "$pid" || rc=$?
  if [[ $rc != "$want" || -e $dir ]]; then
    left=$([[ -e $dir ]] && echo yes || echo no)
    stop_run "$dir"
    fail "$name" "SIG$sig made launch exit $rc (wanted $want), state dir left: $left"
  fi
}

# signal_group <case> <signal> <state dir>: signals launch's process group, then runs await_exit.
signal_group() {
  kill -"$2" -- "-$pid" || fail "$1" "no process group $pid to signal"
  await_exit "$1" "$2" "$3"
}

signal_case() { # <case> <early|doctor>
  local name=$1 where=$2 sig gate run sockdir
  for sig in TERM INT HUP; do
    run=$name-$sig gate=$TMP/gate-$name-$sig
    mkdir "$gate"
    if [[ $where == early ]]; then
      : >"$gate/hold"
      start_launch "$run" "$TMP/gate-bin:$good_path" GATE="$gate"
      wait_for "$run" "$gate/reached"
      st=$(<"$gate/state")
    else
      start_launch "$run" "$TMP/mise:$TMP/slow:$base" GATE="$gate" REAL_ATT="$good"
      wait_for "$run" "$gate/reached"
      find_state "$run"
      sockdir=/tmp/agent-tty/$(printf %s "$st/att" | sha256sum | cut -c1-8)
      [[ -d $sockdir ]] || fail "$run" "the real agent-tty made no $sockdir, so the proof cannot show launch removes it"
    fi
    signal_group "$run" "$sig" "$st"
    [[ $where == early || ! -e $sockdir ]] || {
      rmdir "$sockdir"
      fail "$run" "launch left the socket dir $sockdir of its agent-tty home"
    }
    # Only the late trap runs launch_failed, whose cleanup ends with `agent-tty home forget`. The early trap only removes
    # the state dir. The line must reach launch's caller even though the trap runs while `agent-tty doctor` runs.
    [[ $where == early ]] || grep -qx 'home forget' "$gate/calls" || fail "$run" "launch did not run its cleanup, agent-tty calls: $(tr '\n' ',' <"$gate/calls")"
    [[ $where == early ]] || grep -q '^vcn: launch failed' "$TMP/$run.txt" || fail "$run" "launch printed no failure line: $(cat "$TMP/$run.txt")"
  done
  echo "ok $name: SIGTERM, SIGINT and SIGHUP made launch exit 143 and remove its state dir"
  cases=$((cases + 1))
}

# The signal lands after launch made the agent-tty session, so the cleanup must destroy a live session: its host
# process and its nvim both carry the run's tag.
sigterm_case() {
  local name=sigterm pids=()
  start_launch "$name" "$good_path"
  find_state "$name"
  live_state=$st live_path=$good_path
  for _ in $(seq 600); do
    grep -q '^TUI_PID=' "$st/run.env" 2>/dev/null && break
    sleep 0.1
  done
  grep -q '^TUI_PID=' "$st/run.env" || fail "$name" "launch made no session within 60 s: $(cat "$TMP/$name.txt")"
  [[ ! -e $TMP/out-$name/run.env ]] || fail "$name" "launch finished before the signal"
  signal_group "$name" TERM "$st"
  [[ ! -e $TMP/out-$name/final.screen.txt ]] || fail "$name" "launch took the time to save evidence after SIGTERM"
  mapfile -t pids < <(grep -lzxF "VCN_RUN_TAG=$st" /proc/[0-9]*/environ 2>/dev/null | cut -d/ -f3 || true)
  if ((${#pids[@]} > 0)); then
    # Every PID here carries this run's tag, so it is the proof's own.
    kill "${pids[@]}" 2>/dev/null || true
    fail "$name" "${#pids[@]} processes of the run $st are still alive (stopped now): ${pids[*]}"
  fi
  live_state=""
  echo "ok $name: SIGTERM to a running launch exited 143 and left no state dir or process"
  cases=$((cases + 1))
}

# release <file>: removes the file one second later, in a background job whose PID goes to rel, so a signal sent right
# after it lands while the stand-in still holds.
release() {
  (sleep 1 && rm -f "$1") &
  rel=$!
}

# A signal lands while mktemp is held after it made the state dir and before launch learns the dir's name.
signal_mktemp_case() {
  local name=signal-mktemp sig gate run
  for sig in TERM INT HUP; do
    run=$name-$sig gate=$TMP/gate-$name-$sig
    mkdir "$gate"
    : >"$gate/hold"
    start_launch "$run" "$TMP/gate-mktemp:$good_path" GATE="$gate"
    wait_for "$run" "$gate/reached"
    st=$(<"$gate/state")
    release "$gate/hold"
    signal_group "$run" "$sig" "$st"
    wait "$rel"
  done
  echo "ok $name: SIGTERM, SIGINT and SIGHUP while mktemp ran made launch exit 143 and remove its state dir"
  cases=$((cases + 1))
}

# A second signal lands while the teardown that the first one started is held: in `agent-tty home forget` for the full
# teardown, or in the `rm` of the state dir for the early one.
signal_twice_case() {
  local name=signal-twice sig gate run where
  for where in doctor early; do
    for sig in TERM INT HUP; do
      run=$name-$where-$sig gate=$TMP/gate-$name-$where-$sig
      mkdir "$gate"
      if [[ $where == doctor ]]; then
        : >"$gate/hold-forget"
        start_launch "$run" "$TMP/mise:$TMP/slow:$base" GATE="$gate"
        wait_for "$run" "$gate/reached"
        find_state "$run"
        kill -TERM -- "-$pid" || fail "$run" "no process group $pid to signal"
        wait_for "$run" "$gate/forget-reached"
        release "$gate/hold-forget"
      else
        : >"$gate/hold" && : >"$gate/hold-rm"
        start_launch "$run" "$TMP/gate-bin:$good_path" GATE="$gate"
        wait_for "$run" "$gate/reached"
        st=$(<"$gate/state")
        kill -TERM -- "-$pid" || fail "$run" "no process group $pid to signal"
        wait_for "$run" "$gate/rm-reached"
        release "$gate/hold-rm"
      fi
      signal_group "$run" "$sig" "$st"
      wait "$rel"
      [[ $where == early || -f $gate/forget-done ]] || fail "$run" "the second SIG$sig ended 'agent-tty home forget' before it finished"
    done
  done
  echo "ok $name: a second SIGTERM, SIGINT or SIGHUP did not stop the teardown (exit 143, no state dir)"
  cases=$((cases + 1))
}

# A signal lands while launch is blocked printing VCN_STATE: stdout is a full pipe that nobody reads. The run exists and
# is complete, so launch must tear it down, because its caller never learns its name.
signal_printed_case() {
  local name=signal-printed fifo=$TMP/fifo-printed
  mkfifo "$fifo"
  exec 8<>"$fifo"
  dd if=/dev/zero bs=1 count=1000000 of="$fifo" oflag=nonblock status=none 2>/dev/null || true
  launch_out=$fifo start_launch "$name" "$good_path"
  find_state "$name"
  live_state=$st live_path=$good_path
  for _ in $(seq 900); do
    grep -q '^agent-tty ' "$TMP/out-$name/run.env" 2>/dev/null && break
    sleep 0.1
  done
  grep -q '^agent-tty ' "$TMP/out-$name/run.env" || fail "$name" "launch did not finish its run within 90 s"
  sleep 1
  kill -TERM -- "-$pid" || fail "$name" "no process group $pid to signal"
  # The signal fails the blocked write of VCN_STATE at once with EINTR. Bash then writes its `write error` message to
  # stderr, which is the same full pipe, and that write blocks until the pipe is read: read it empty.
  dd if=/dev/fd/8 of=/dev/null bs=65536 count=64 iflag=nonblock status=none 2>/dev/null || true
  await_exit "$name" TERM "$st"
  exec 8>&-
  live_state=""
  echo "ok $name: SIGTERM while launch was blocked printing VCN_STATE made it exit 143 and remove the run"
  cases=$((cases + 1))
}

# Guards the `trap ""` at the start of launch's signal trap. The gap that it closes is a few microseconds wide and holds
# no command that a stand-in could hold, so signal the process group every 0.2 ms from the moment launch is held in
# doctor. The first signal kills the stand-in, which ends the hold.
signal_storm_case() {
  local name=signal-storm gate run storm attempt
  for attempt in $(seq 10); do
    run=$name-$attempt gate=$TMP/gate-$name-$attempt
    mkdir "$gate"
    start_launch "$run" "$TMP/mise:$TMP/slow:$base" GATE="$gate"
    wait_for "$run" "$gate/reached"
    find_state "$run"
    # shellcheck disable=SC2016
    "$perl" -e '$end = time + 10; while (time < $end) { $n = 0; $n += kill("-$_", $ARGV[0]) for qw(TERM INT HUP); last unless $n; select(undef, undef, undef, 0.0002) }' \
      "$pid" &
    storm=$!
    await_exit "$run" TERM "$st"
    kill "$storm" 2>/dev/null || true
    wait "$storm" 2>/dev/null || true
    grep -qx 'home forget' "$gate/calls" || fail "$run" "launch did not run its cleanup, agent-tty calls: $(tr '\n' ',' <"$gate/calls")"
  done
  echo "ok $name: ten rounds of SIGTERM, SIGINT and SIGHUP storms made launch exit 143, run its cleanup and remove its state dir"
  cases=$((cases + 1))
}

signal_outside_case() {
  local name=signal-outside why=""
  launch "$name" "$TMP/gate-cp:$good_path"
  ((rc == 143)) || why="launch exited $rc, wanted 143"
  [[ -f $TMP/out-$name/final.screen.txt ]] || why="${why:+$why, }the cleanup saved no final screen"
  [[ -z $state || ! -e $state ]] || why="${why:+$why, }state dir $state is still there"
  stop_run "$state"
  [[ -z $why ]] || fail "$name" "$why: $out"
  echo "ok $name: a child killed from outside made launch exit 143 and take the full cleanup"
  cases=$((cases + 1))
}

# A launch that fails by itself gets a signal to its process group while its teardown saves the screen of the failure.
# The teardown ignores the signal and runs agent-tty in a session of its own: launch exits 1, and the screen has text.
signal_failed_case() {
  local name=signal-failed gate=$TMP/gate-signal-failed
  mkdir "$gate"
  : >"$gate/hold-snapshot"
  start_launch "$name" "$good_path" GATE="$gate" NODE_OPTIONS="--require $TMP/hold-snapshot.js" VCN_INIT_JSONRPC=1.0
  for _ in $(seq 900); do
    [[ -f $gate/snapshot-reached ]] && break
    sleep 0.1
  done
  [[ -f $gate/snapshot-reached ]] || fail "$name" "launch did not reach the failure snapshot in 90 s: $(cat "$TMP/$name.txt")"
  find_state "$name"
  kill -TERM -- "-$pid" || fail "$name" "no process group $pid to signal"
  release "$gate/hold-snapshot"
  await_exit "$name" TERM "$st" 1
  wait "$rel"
  [[ -s $TMP/out-$name/launch-failure.screen.txt ]] || fail "$name" "the saved failure screen is empty: the signal ended snapshot"
  [[ -f $TMP/out-$name/final.screen.txt ]] || fail "$name" "the cleanup saved no final screen"
  echo "ok $name: a signal while a failed launch saved its screen left exit 1 and a screen with text"
  cases=$((cases + 1))
}

# find_state scans /tmp/vcn.*/run.env, and vcn.sh cleanup sources the run.env of the dir that stop_run gets. A symlink
# to a directory of this user passes the owner test, so own_dir refuses it too. The decoy sorts after every real dir.
decoy_case() {
  local name=decoy-state gate=$TMP/gate-decoy target=$TMP/decoy-target marker=$TMP/decoy-marker why=""
  mkdir "$gate" "$target"
  decoy=/tmp/vcn.zzzzzzzz$RANDOM$RANDOM
  printf 'OUT=%s\ntouch %s\n' "$TMP/out-$name" "$marker" >"$target/run.env"
  ln -s "$target" "$decoy"
  start_launch "$name" "$TMP/mise:$TMP/slow:$base" GATE="$gate"
  wait_for "$name" "$gate/reached"
  find_state "$name"
  [[ $st != "$decoy" ]] || why="find_state picked the decoy"
  stop_run "$decoy"
  [[ ! -e $marker ]] || why="${why:+$why, }stop_run sourced the run.env of the decoy"
  [[ -L $decoy && -f $target/run.env ]] || why="${why:+$why, }stop_run removed the decoy"
  kill -TERM -- "-$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -f -- "$decoy"
  decoy=""
  [[ -z $why ]] || fail "$name" "$why"
  echo "ok $name: a symlink decoy was neither picked by find_state nor run by stop_run"
  cases=$((cases + 1))
}

# vcn.sh cleanup on the run.env of a launch that stopped before an agent-tty passed doctor: it has no ATT_BIN.
cleanup_no_agent_tty_case() {
  local name=cleanup-no-agent-tty dir
  dir=$(mktemp -d /tmp/vcn.XXXXXX)
  printf '%s=%s\n' VCN_STATE "$dir" OUT "$TMP/out-$name" ATT_HOME "$dir/att" >"$dir/run.env"
  env PATH="$base" VCN_STATE="$dir" "$V" cleanup >"$TMP/$name.txt" 2>&1 || true
  [[ ! -e $dir ]] || {
    rm -rf -- "$dir"
    fail "$name" "cleanup left $dir: $(cat "$TMP/$name.txt")"
  }
  echo "ok $name: cleanup of a run without an agent-tty removed its state dir"
  cases=$((cases + 1))
}

signal_case signal-early early
signal_case signal-doctor doctor
signal_mktemp_case
signal_twice_case
decoy_case
signal_storm_case
signal_printed_case
signal_outside_case
signal_failed_case
cleanup_no_agent_tty_case
sigterm_case
echo "CASES $cases"
