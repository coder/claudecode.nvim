#!/usr/bin/env bash
# Proves how `vcn.sh launch` picks agent-tty and loads VCN_RTP, with stand-ins for a broken agent-tty and for mise:
#   skip-broken       an agent-tty on PATH that fails `agent-tty doctor` comes first: launch runs the next one that passes
#   mise-broken       mise's agent-tty is the broken one: launch runs the PATH one that passes
#   mise-only         the only good agent-tty is the one `mise which` names: launch runs it
#   path-over-mise    a different good agent-tty on PATH and in mise: the PATH one wins
#   jq-resolved       a failing jq on PATH and a working one that only `mise which jq` names: launch and its cleanup
#                     run the jq that mise names
#   setsid-resolved   a failing setsid on PATH and a working one that only `mise which setsid` names: a launch that
#                     fails by itself still saves its failure screen and the final evidence, and runs `agent-tty home
#                     forget`, all through the setsid that mise names
#   jq-old-run        a run.env without JQ_BIN, as an older vcn.sh wrote it: a command resolves jq again
#   node-dir          a run.env whose NODE_DIR is empty, relative or has a colon is refused, by cleanup too, which names the
#                     rm -rf for the state dir (att() would put the current dir, or a second dir, on PATH), and one whose NODE_DIR
#                     is an absolute dir without a node is not
#   state-resolved    a VCN_STATE with a . or .. part, a symlink in its path, or a symlink as its last part is refused, not
#                     sourced
#   state-slash       a VCN_STATE with a trailing /, /. or //, or a .. after a symlink, is refused, not sourced
#   state-mode        a VCN_STATE that is group-writable is refused, not sourced
#   state-parent      a VCN_STATE under a dir that others can write without the sticky bit is refused, not sourced
#   state-names       the same, when the name of that dir ends in a space, a tab or a newline, and a symlink with the
#                     shorter name sits next to it
#   state-env         a state_checked in the caller's environment does not skip the check
#   state-mode-partial  a state dir that only others can write (702), or only the group (720), is refused, not sourced
#   state-parent-partial  the same for a dir above the state dir
#   tmp-multihop      TMPDIR is this user's symlink to a second symlink in a dir that others can write, to a dir only this user
#                     can write: launch accepts it, and after another user repoints the second symlink, `record` still
#                     writes no byte of theirs into the evidence dir, because no agent-tty call of vcn.sh reads the caller's TMPDIR
#   tmp-later-tmpdir  a command run with a TMPDIR that does not exist works: agent-tty makes its staging dirs in the state dir
#   get-values        `vcn.sh get` answers the values of a hand-made run.env exactly (a path with a space, an equals sign, quotes
#                     and a newline, also at its end with -z), and answers no name that run.env does not hold
#   get-state         `get` and each of the five journeys refuse a state dir that others can write, before they source its run.env
#   journey-out       journey-opendiff-accept.sh writes all its evidence into the OUT of its run, whatever VERIFY_OUT looks like
#                     (` OUT=` in the name, a newline in it or at its end) and whatever OUT the caller exported
#   dashboard         `vcn.sh dashboard` shows the running session in a terminal (script(1) stands in for one)
#   tmp-removed       a run without $VCN_STATE/tmp, as an older vcn.sh left it, works: `record` makes the dir (0700) and writes a WebM
#   state-count       a stat that answers for one dir fewer than the walk asked for (a shim drops the record of the loose
#                     dir above the state dir) makes the walk refuse, not pass
#   state-newline     a state dir whose name ends in a newline is accepted: the check reads its resolved path whole
#   state-owner       a VCN_STATE that another user owns, with a run.env in it, is refused, not sourced (a bwrap user
#                     namespace with a read-only overlay stands in for the other user; SKIP where bwrap cannot make it)
#   state-ancestor    the same when only a dir above the state dir is another user's, and the state dir is this user's
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
#   signal-symlink    the same, with a TMPDIR that is a symlink: agent-tty names the socket directory after the real path
#                     of the home, and the cleanup removes that one
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
#   decoy-state       a /tmp/vcn.* dir (made with mktemp) whose run.env would touch a marker: every launch of this proof
#                     runs with a private TMPDIR, so find_state does not pick the decoy and stop_run does not run it
#   signal-gap        a launch that fails by itself, with SIGTERM, SIGINT and SIGHUP sent while launch_failed is held
#                     before its first command: launch tears the run down (exit 143, its failure line, no state dir)
#   cleanup-no-agent-tty  `vcn.sh cleanup` of a run that stopped before an agent-tty passed doctor, so run.env has no
#                     ATT_BIN: it still removes the state dir
# A good agent-tty is $VCN_AGENT_TTY when set, else the first agent-tty on PATH or in mise. The cases that start a run
# need everything under Needs in SKILL.md, and the signal cases need perl.
# Prints one `ok <case>` per case, or `FAIL <case>: <reason>` and exits 1, and ends with `CASES <n>`.
set -euo pipefail
V="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vcn.sh"
root=$PWD
# Resolved, because launch prints the state dir under the resolved path of TMPDIR.
TMP=$(realpath -- "$(mktemp -d)")
# Every launch of this proof makes its state dir in priv, which only this user can enter. `vcn.sh cleanup` sources
# the run.env of a state dir, so find_state and stop_run never look at /tmp/vcn.*, where another user can make or
# swap dirs.
priv=$TMP/vcn-state
mkdir -m 700 "$priv"
live_state="" live_path="" st="" decoy=""
# stop_run <state dir>: stops a run that a case left behind, so no process of it outlives the proof.
stop_run() {
  [[ $1 == "$priv"/vcn.* && -e $1 ]] || return 0
  env PATH="$base" VCN_STATE="$1" "$V" cleanup >/dev/null 2>&1 || true
  rm -rf -- "$1"
}
cleanup_all() {
  if [[ -n $live_state ]]; then
    env PATH="$live_path" VCN_STATE="$live_state" "$V" cleanup >/dev/null 2>&1 || true
  fi
  stop_run "$st"
  if [[ $decoy == /tmp/vcn.?????? ]]; then rm -rf -- "$decoy"; fi
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
# The stand-in answers `mise which agent-tty` with $FAKE_MISE_ATT, `mise which setsid` with $FAKE_MISE_SETSID and `mise
# which jq` with $FAKE_MISE_JQ when those are set, and runs every other command from the directory the proof started in,
# so a case can launch from another directory and still resolve nvim and node.
cat >"$TMP/mise/mise" <<MISE
#!/bin/sh
if [ "\$1" = which ] && [ "\$2" = agent-tty ]; then
  [ -n "\${FAKE_MISE_ATT-}" ] && echo "\$FAKE_MISE_ATT" && exit 0
  exit 1
fi
if [ "\$1" = which ] && [ "\$2" = setsid ] && [ -n "\${FAKE_MISE_SETSID-}" ]; then
  echo "\$FAKE_MISE_SETSID" && exit 0
fi
if [ "\$1" = which ] && [ "\$2" = jq ] && [ -n "\${FAKE_MISE_JQ-}" ]; then
  echo "\$FAKE_MISE_JQ" && exit 0
fi
cd "$root" && exec "$real_mise" "\$@"
MISE
# A setsid and a jq that fail, to put first on PATH where only mise names a working one. logged/agent-tty records each
# call's subcommand in $GATE/calls and runs the good agent-tty.
mkdir "$TMP/bad-setsid" "$TMP/bad-jq" "$TMP/logged"
for tool in setsid jq; do
  printf '#!/bin/sh\necho "this %s must not run" >&2\nexit 1\n' "$tool" >"$TMP/bad-$tool/$tool"
  chmod +x "$TMP/bad-$tool/$tool"
done
cat >"$TMP/logged/agent-tty" <<LOGGED
#!/bin/sh
printf '%s %s\\n' "\$3" "\$4" >>"\$GATE/calls"
exec "$TMP/good/agent-tty" "\$@"
LOGGED
chmod +x "$TMP/logged/agent-tty"
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
"-p $priv/vcn."*"/home $priv/vcn."*"/claude $priv/vcn."*"/work $priv/vcn."*"/tmp")
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
"-rf -- $priv/vcn."*)
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
"-d $priv/vcn.XXXXXX")
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
$priv/vcn.*/run.env\ */run.env) kill -TERM \$\$ ;;
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
# A hook that BASH_ENV makes vcn.sh source. It holds launch_failed before its first command while $GATE/hold-gap
# exists. That gap is a few microseconds wide: a signal reaches launch before launch_failed ignores signals, and no
# stand-in can hold a command there.
cat >"$TMP/hold-gap.bash" <<'HOLDGAP'
set -T
trap '
  if [[ ${FUNCNAME[0]-} == launch_failed && -f ${GATE-}/hold-gap ]]; then
    : >"$GATE/gap-reached"
    while [[ -f $GATE/hold-gap ]]; do sleep 0.05; done
  fi
' DEBUG
HOLDGAP
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
  out=$(cd "${launch_cwd:-.}" && env -u VERIFY_OUT -u XUM_SCRATCH_DIR -u VCN_AGENT_TTY PATH="$path" VERIFY_OUT="$TMP/out-$name" TMPDIR="$priv" "$@" "$V" launch 2>&1) || rc=$?
  state=$(grep -o 'VCN_STATE=/[^[:space:])]*' <<<"$out" | head -n 1 | cut -d= -f2 || true)
  if ((rc == 0)); then
    live_state=$state live_path=$path
  fi
  [[ -z $state || $state == "$priv"/vcn.* ]] || fail "$name" "launch made its state dir $state outside its TMPDIR $priv"
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
launched_with jq-resolved "$TMP/mise:$TMP/bad-jq:$TMP/good:$base" "$TMP/good/agent-tty" FAKE_MISE_JQ="$TMP/tools/jq"
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
  env -u VERIFY_OUT -u XUM_SCRATCH_DIR -u VCN_AGENT_TTY PATH="$path" VERIFY_OUT="$TMP/out-$name" TMPDIR="$priv" "$@" \
    "$perl" -e '$SIG{INT} = $SIG{HUP} = "DEFAULT"; exec @ARGV' "$TMP/tools/setsid" "$V" launch >"${launch_out:-$TMP/$name.txt}" 2>&1 </dev/null &
  pid=$!
}

# find_state <case>: sets st to the state dir whose run.env names the case's evidence dir, within 30 s.
find_state() {
  local f
  st=""
  for _ in $(seq 300); do
    for f in "$priv"/vcn.*/run.env; do
      if [[ -f $f ]] && grep -qxF "OUT=$TMP/out-$1" "$f" 2>/dev/null; then st=${f%/*}; fi
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
    [[ $where == early || $(grep -c '^vcn: launch failed' "$TMP/$run.txt") == 1 ]] || fail "$run" "launch did not print its failure line once: $(cat "$TMP/$run.txt")"
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

# A launch that fails by itself (its only agent-tty is broken) gets a signal while launch_failed is held before its
# first command. The signal trap runs the teardown itself, once: launch exits 143, prints its failure line, leaves no
# state dir.
signal_gap_case() {
  local name=signal-gap sig gate run
  for sig in TERM INT HUP; do
    run=$name-$sig gate=$TMP/gate-$name-$sig
    mkdir "$gate"
    : >"$gate/hold-gap"
    start_launch "$run" "$good_path" GATE="$gate" BASH_ENV="$TMP/hold-gap.bash" VCN_AGENT_TTY="$TMP/broken/agent-tty"
    wait_for "$run" "$gate/gap-reached"
    find_state "$run"
    release "$gate/hold-gap"
    signal_group "$run" "$sig" "$st"
    wait "$rel"
    [[ $(grep -c '^vcn: launch failed' "$TMP/$run.txt") == 1 ]] || fail "$run" "launch did not print its failure line once: $(cat "$TMP/$run.txt")"
  done
  echo "ok $name: SIGTERM, SIGINT and SIGHUP before launch_failed ignored them made launch tear the run down once"
  cases=$((cases + 1))
}

# A /tmp/vcn.* dir that this proof did not start, with a run.env that names this case's evidence dir and would touch a
# marker. find_state looks only in priv and stop_run refuses a dir outside it, so the decoy is never read or sourced.
decoy_case() {
  local name=decoy-state gate=$TMP/gate-decoy marker=$TMP/decoy-marker why=""
  mkdir "$gate"
  decoy=$(mktemp -d /tmp/vcn.XXXXXX)
  printf 'OUT=%s\ntouch %s\n' "$TMP/out-$name" "$marker" >"$decoy/run.env"
  start_launch "$name" "$TMP/mise:$TMP/slow:$base" GATE="$gate"
  wait_for "$name" "$gate/reached"
  find_state "$name"
  [[ $st == "$priv"/vcn.* ]] || why="find_state picked $st, outside the private dir"
  stop_run "$decoy"
  [[ ! -e $marker ]] || why="${why:+$why, }stop_run sourced the run.env of the decoy"
  [[ -f $decoy/run.env ]] || why="${why:+$why, }stop_run removed the decoy"
  kill -TERM -- "-$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  if [[ $decoy == /tmp/vcn.?????? ]]; then rm -rf -- "$decoy"; fi
  decoy=""
  [[ -z $why ]] || fail "$name" "$why"
  echo "ok $name: a /tmp/vcn.* decoy was neither picked by find_state nor run by stop_run"
  cases=$((cases + 1))
}

# The failing setsid comes first on PATH and only mise names a working one. A launch that fails by itself (initialize
# answers an error) saves its failure screen, the final evidence and runs `home forget` through agent-tty in a session of
# its own, which needs the setsid that launch resolved: the bare name would run the failing one.
setsid_resolved_case() {
  local name=setsid-resolved gate=$TMP/gate-setsid-resolved why=""
  mkdir "$gate"
  launch "$name" "$TMP/mise:$TMP/bad-setsid:$TMP/logged:$base" GATE="$gate" FAKE_MISE_SETSID="$TMP/tools/setsid" VCN_INIT_JSONRPC=1.0
  ((rc == 1)) || why="launch exited $rc, wanted 1"
  [[ $out == *"vcn: initialize failed: "* ]] || why="${why:+$why, }launch failed at another step: the client did not start through that setsid"
  [[ -s $TMP/out-$name/launch-failure.screen.txt ]] || why="${why:+$why, }the failure screen was not saved"
  [[ -s $TMP/out-$name/final.screen.txt ]] || why="${why:+$why, }the cleanup saved no final screen"
  grep -qx 'home forget' "$gate/calls" 2>/dev/null || why="${why:+$why, }launch did not run agent-tty home forget"
  [[ -z $state || ! -e $state ]] || why="${why:+$why, }state dir $state is still there"
  stop_run "$state"
  [[ -z $why ]] || fail "$name" "$why: $out"
  echo "ok $name: a launch that failed by itself saved its screens and forgot its home through the setsid that mise names"
  cases=$((cases + 1))
}

# The run.env of a run that an older vcn.sh started has no JQ_BIN. A command that needs jq must resolve it again.
jq_old_run_case() {
  local name=jq-old-run dir out rc=0
  dir=$(mktemp -d "$priv/vcn.XXXXXX")
  mkdir "$TMP/out-$name"
  printf '%s=%s\n' VCN_STATE "$dir" OUT "$TMP/out-$name" >"$dir/run.env"
  out=$(env PATH="$base" VCN_STATE="$dir" "$V" rpc old1 ping 2>&1) || rc=$?
  [[ $dir == "$priv"/vcn.?????? ]] && rm -rf -- "$dir"
  ((rc == 0)) || fail "$name" "rpc on a run.env without JQ_BIN exited $rc: $out"
  grep -q '"id":"old1"' "$TMP/out-$name/ws-out.jsonl" || fail "$name" "rpc wrote no request: $out"
  echo "ok $name: a run.env without JQ_BIN still runs jq"
  cases=$((cases + 1))
}

# att() puts NODE_DIR in front of PATH. A command must refuse a run.env whose NODE_DIR would put the current dir (empty, relative)
# or a second dir (a colon) on PATH, and must not refuse an absolute dir that has lost its node, because cleanup has to run.
node_dir_case() {
  local name=node-dir dir out rc val want
  for val in "|it is not an absolute path" "bin|it is not an absolute path" "/usr/bin:/tmp|it has a colon, which PATH would split"; do
    want=${val#*|}
    val=${val%%|*}
    dir=$(mktemp -d "$priv/vcn.XXXXXX")
    printf 'VCN_STATE=%q\nOUT=%q\nNODE_DIR=%q\n' "$dir" "$TMP/out-$name" "$val" >"$dir/run.env"
    rc=0
    out=$(env PATH="$base" VCN_STATE="$dir" "$V" doctor 2>&1) || rc=$?
    ((rc == 1)) && [[ $out == *"NODE_DIR=$val in $dir/run.env is not usable: $want"* ]] ||
      fail "$name" "doctor with NODE_DIR='$val' exited $rc, wanted 1 with '$want': $out"
    # cleanup refuses too, because it would run agent-tty with that PATH. It must say how to stop the run by hand, and it must
    # leave the state dir for that.
    rc=0
    out=$(env PATH="$base" VCN_STATE="$dir" "$V" cleanup 2>&1) || rc=$?
    ((rc == 1)) && [[ $out == *"To stop this run by hand, stop its nvim and agent-tty processes, then remove its state dir: rm -rf $(printf %q "$dir")"* && -d $dir ]] ||
      fail "$name" "cleanup with NODE_DIR='$val' exited $rc without the hand-cleanup hint for $dir, or removed it: $out"
    rm -rf -- "$dir"
  done
  mkdir "$TMP/no-node"
  dir=$(mktemp -d "$priv/vcn.XXXXXX")
  printf 'VCN_STATE=%q\nOUT=%q\nNODE_DIR=%q\n' "$dir" "$TMP/out-$name" "$TMP/no-node" >"$dir/run.env"
  rc=0
  out=$(env PATH="$base" VCN_STATE="$dir" "$V" doctor 2>&1) || rc=$?
  [[ $out != *"NODE_DIR="* ]] || fail "$name" "doctor refused an absolute NODE_DIR that holds no node: $out"
  rm -rf -- "$dir" "$TMP/no-node"
  echo "ok $name: an empty, relative or colon NODE_DIR was refused, and an absolute dir without a node was not"
  cases=$((cases + 1))
}

# `vcn.sh get` reads a value of run.env after the check that every command makes, and the journeys use it in place of a source.
# The run.env of get_run_dir is hand-made, and its OUT holds a space, an equals sign, a tab, quotes and a newline (also at its end).
get_run_dir() { # <name> <dir>: makes a state dir under $priv that holds NODE_DIR, WORK and the weird OUT
  mkdir -p "$TMP/no-node"
  printf 'VCN_STATE=%q\nOUT=%q\nWORK=%q\nNODE_DIR=%q\n' "$2" "$weird_out" "$2/work" "$TMP/no-node" >"$2/run.env"
}
get_values_case() {
  local name=get-values dir got out rc
  weird_out=$'/tmp/a b OUT=/x\t\'q"\nline2\n'
  dir=$(mktemp -d "$priv/vcn.XXXXXX")
  get_run_dir "$name" "$dir"
  got=$(env PATH="$good_path" VCN_STATE="$dir" "$V" get WORK) || fail "$name" "get WORK failed"
  [[ $got == "$dir/work" ]] || fail "$name" "get WORK printed '$got', not $dir/work"
  got=""
  IFS= read -r -d "" got < <(env PATH="$good_path" VCN_STATE="$dir" "$V" get -z OUT) || fail "$name" "get -z OUT printed no NUL end"
  [[ $got == "$weird_out" ]] || fail "$name" "get -z OUT printed '$got', not the whole OUT"
  got=$(env PATH="$good_path" VCN_STATE="$dir" "$V" get OUT)
  [[ $got == "${weird_out%$'\n'}" ]] || fail "$name" "get OUT in a command substitution printed '$got'"
  for got in PATH SID "a b" "" "O.T" "OUT; touch $TMP/marker-$name"; do
    rc=0
    out=$(env PATH="$good_path" VCN_STATE="$dir" "$V" get "$got" 2>&1) || rc=$?
    ((rc == 1)) && [[ $out == "vcn: get: "* ]] || fail "$name" "get '$got' exited $rc with '$out', wanted 1 and a get: refusal"
  done
  [[ ! -e $TMP/marker-$name ]] || fail "$name" "get ran a name that it was given"
  rc=0
  out=$(env PATH="$good_path" VCN_STATE="$dir" "$V" get 2>&1) || rc=$?
  ((rc == 1)) || fail "$name" "get without a name exited $rc: $out"
  rm -rf -- "$dir" "$TMP/no-node"
  echo "ok $name: get printed WORK, OUT with -z whole, and refused PATH, a name that run.env lacks, a bad name and no name"
  cases=$((cases + 1))
}

# A stale or foreign VCN_STATE is the input that the check exists for. A journey that sourced run.env ran it unchecked. get
# and every journey must stop at the check: the marker that the run.env touches stays away.
get_state_case() {
  local name=get-state dir out rc journey cmd
  weird_out=/tmp/x
  dir=$(mktemp -d "$priv/vcn.XXXXXX")
  get_run_dir "$name" "$dir"
  printf 'touch %s\n' "$TMP/marker-$name" >>"$dir/run.env"
  chmod 770 "$dir"
  for journey in get "$(dirname "$V")"/journey-*.sh; do
    if [[ $journey == get ]]; then cmd=("$V" get OUT); else cmd=("$journey"); fi
    rc=0
    out=$(env PATH="$good_path" VCN_STATE="$dir" "${cmd[@]}" 2>&1) || rc=$?
    [[ ! -e $TMP/marker-$name ]] || fail "$name" "${journey##*/} sourced the run.env of $dir"
    ((rc == 1)) && [[ $out == *"refusing state dir $dir: it is group- or world-writable"* ]] ||
      fail "$name" "${journey##*/} exited $rc, wanted 1 with the refusal of $dir: $out"
  done
  rm -rf -- "$dir" "$TMP/no-node"
  echo "ok $name: get and the five journeys refused a state dir that others can write, and its run.env was not sourced"
  cases=$((cases + 1))
}

# journey-opendiff-accept.sh writes opendiff-accept-* files into OUT. A caller can export a stale OUT, and VERIFY_OUT can be a path
# that a parse of printed text gets wrong: ` OUT=` inside the name, a newline in it, or a newline at its end (a command
# substitution cuts that one). Each shape must end with every file in the OUT of its run and none in the other dirs.
journey_out_case() {
  local name=journey-out shape want real jout n m stale=$TMP/stale-out else=$TMP/jo-else r
  mkdir "$stale" "$else"
  for shape in a1 newline nlend; do
    case $shape in
    a1) want="$TMP/jo-a1/run OUT=$else" ;;
    newline) want="$TMP/jo-nl/first"$'\n'"second" ;;
    nlend) want="$TMP/jo-nlend/dir"$'\n' ;;
    esac
    rc=0
    out=$(env -u XUM_SCRATCH_DIR -u VCN_AGENT_TTY PATH="$good_path" VERIFY_OUT="$want" TMPDIR="$priv" "$V" launch 2>&1) || rc=$?
    state=$(sed -n 's/^VCN_STATE=//p' <<<"$out" | head -n 1)
    ((rc == 0)) && [[ $state == "$priv"/vcn.?????? ]] || fail "$name" "launch with the $shape VERIFY_OUT exited $rc: $out"
    live_state=$state live_path=$good_path
    real=""
    IFS= read -r -d "" real < <(env VCN_STATE="$state" "$V" get -z OUT) || true
    [[ $real == "$want" ]] || fail "$name" "get OUT is not the VERIFY_OUT of the $shape launch"
    r=0
    jout=$(env PATH="$good_path" VCN_STATE="$state" OUT="$stale" "$(dirname "$V")/journey-opendiff-accept.sh" 2>&1) || r=$?
    n=$(find "$real" -maxdepth 1 -name 'opendiff-accept-*' -print0 | tr -cd '\0' | wc -c)
    m=$(find "$else" "$stale" -type f -print0 | tr -cd '\0' | wc -c)
    stop "$good_path"
    ((r == 0 && n > 0 && m == 0)) ||
      fail "$name" "$shape: the journey exited $r with $n files in its OUT and $m in the other dirs: $(tail -n 3 <<<"$jout")"
    find "$else" "$stale" -mindepth 1 -delete
  done
  echo "ok $name: the journey wrote its files into the OUT of the run for a VERIFY_OUT with OUT= in it, with a newline in it and at its end, and an exported stale OUT"
  cases=$((cases + 1))
}

# The dashboard is a terminal program. script(1) gives it one, and the case checks that the running session (hello.txt) shows.
dashboard_case() {
  local name=dashboard raw=$TMP/dashboard.raw spid kids k r=0
  command -v script >/dev/null || {
    echo "SKIP $name: script(1) is not installed"
    return 0
  }
  launch "$name" "$good_path"
  ((rc == 0)) || fail "$name" "launch exited $rc: $out"
  env PATH="$good_path" VCN_STATE="$state" script -qfec "stty cols 160 rows 40; $V dashboard" /dev/null >"$raw" 2>&1 </dev/null &
  spid=$!
  sleep 15
  kids=$(ps -o pid= --ppid "$spid" | tr -d ' ' | tr '\n' ' ' || true)
  if [[ -d /proc/$spid ]] && tr '\0' ' ' <"/proc/$spid/cmdline" | grep -q '^script -qfec'; then kill -INT "$spid"; fi
  wait "$spid" 2>/dev/null || true
  sleep 1
  for k in $kids; do
    if [[ -d /proc/$k ]] && tr '\0' ' ' <"/proc/$k/cmdline" | grep -q 'dashboard'; then
      kill "$k"
      r=1
    fi
  done
  stop "$good_path"
  sed 's/\x1b\[[0-9;?]*[A-Za-z]//g; s/\x1b[()][A-Z0-9]//g' "$raw" | tr -d '\r' >"$raw.txt"
  if ! grep -q alpha "$raw.txt" || ! grep -q gamma "$raw.txt"; then
    fail "$name" "the dashboard did not show the text of hello.txt: $(head -c 300 "$raw.txt")"
  fi
  ((r == 0)) || fail "$name" "a dashboard process was still alive after its terminal ended (stopped now)"
  echo "ok $name: vcn.sh dashboard showed the running session in a terminal and left no process"
  cases=$((cases + 1))
}

# refuses_state <case> <state dir> <text> [wrapper...]: `vcn.sh cleanup`, run through the wrapper, must exit 1 with <text>
# and must not source the run.env in <state dir>, which touches $TMP/marker-<case>.
refuses_state() {
  local name=$1 dir=$2 want=$3 marker=$TMP/marker-$1 out rc=0
  shift 3
  out=$("$@" env PATH="$base" VCN_STATE="$dir" "$V" cleanup 2>&1) || rc=$?
  [[ ! -e $marker ]] || fail "$name" "vcn.sh sourced the run.env of $dir"
  ((rc == 1)) && [[ $out == *"$want"* ]] || fail "$name" "cleanup exited $rc, wanted 1 with '$want': $out"
}

# marker_state_dir <parent>: a new 0700 state dir under <parent> whose run.env touches the marker of the caller's $name.
marker_state_dir() {
  local dir
  dir=$(mktemp -d "$1/vcn.XXXXXX")
  printf 'touch %s\n' "$TMP/marker-$name" >"$dir/run.env"
  printf '%s' "$dir"
}

state_resolved_case() {
  local name=state-resolved rdir=$TMP/res-case real dotted linked final
  mkdir -m 700 "$rdir" "$rdir/y" "$rdir/real"
  ln -s "$rdir/real" "$rdir/L"
  ln -s "$rdir/y" "$rdir/lnk"
  real=$(marker_state_dir "$rdir/y")
  dotted=$rdir/L/../y/${real##*/}
  linked=$rdir/lnk/${real##*/}
  final=$rdir/vcn.Lnk123
  ln -s "$real" "$final"
  refuses_state "$name" "$dotted" "refusing state dir $dotted: it is not its own resolved path ($real)"
  refuses_state "$name" "$linked" "refusing state dir $linked: it is not its own resolved path ($real)"
  refuses_state "$name" "$final" "refusing state dir $final: it is not its own resolved path ($real)"
  rm -rf -- "$rdir"
  echo "ok $name: a state dir named through a . or .. part or a symlink was refused and its run.env not sourced"
  cases=$((cases + 1))
}

# stat without -L follows a symlink when the path ends in a slash, so a VCN_STATE spelled <link>/, <link>/. or <link>// has
# no symlink in the chain that the checks walk. Only the test that the path is its own realpath refuses these.
state_slash_case() {
  local name=state-slash sdir=$TMP/slash-case real final spelled
  mkdir -m 700 "$sdir"
  real=$(marker_state_dir "$sdir")
  final=$sdir/vcn.Lnk123
  ln -s "$real" "$final"
  for spelled in "$final/" "$final/." "$final//" "$final/../${real##*/}" "$real/" "$real/."; do
    refuses_state "$name" "$spelled" "refusing state dir $spelled: it is not its own resolved path ($real)"
  done
  rm -rf -- "$sdir"
  echo "ok $name: a state dir spelled with a trailing /, /. or //, or with .. after a symlink, was refused and its run.env not sourced"
  cases=$((cases + 1))
}

state_mode_case() {
  local name=state-mode dir
  dir=$(marker_state_dir "$priv")
  chmod 770 "$dir"
  refuses_state "$name" "$dir" "refusing state dir $dir: it is group- or world-writable"
  [[ $dir == "$priv"/vcn.?????? ]] && rm -rf -- "$dir"
  echo "ok $name: a group-writable state dir was refused and its run.env not sourced"
  cases=$((cases + 1))
}

state_parent_case() {
  local name=state-parent loose=$TMP/loose dir
  mkdir -m 777 "$loose"
  dir=$(marker_state_dir "$loose")
  refuses_state "$name" "$dir" "refusing state dir $dir: $loose, above the state dir, is writable by others and not sticky"
  rm -rf -- "$loose"
  echo "ok $name: a state dir under a dir that others can write was refused and its run.env not sourced"
  cases=$((cases + 1))
}

# A twin symlink with the shorter name sits next to each dir: a walk that read the name back from a line of stat output
# lost a trailing space or tab, split at a newline, tested the twin and passed it.
state_names_case() {
  local name=state-names ndir=$TMP/names stem suffix loose dir
  mkdir -m 700 "$ndir"
  for stem in a b c; do
    case $stem in
    a) suffix=' ' ;;
    b) suffix=$'\t' ;;
    c) suffix=$'\n' ;;
    esac
    loose=$ndir/$stem$suffix
    mkdir -m 777 "$loose"
    ln -s "$ndir" "$ndir/$stem"
    dir=$(marker_state_dir "$loose")
    refuses_state "$name" "$dir" "refusing state dir $dir: $loose, above the state dir, is writable by others and not sticky"
  done
  rm -rf -- "$ndir"
  echo "ok $name: a dir above the state dir that others can write was refused when its name ends in a space, a tab or a newline"
  cases=$((cases + 1))
}

state_env_case() {
  local name=state-env dir
  dir=$(marker_state_dir "$priv")
  chmod 770 "$dir"
  refuses_state "$name" "$dir" "refusing state dir $dir: it is group- or world-writable" env state_checked="$dir"
  [[ $dir == "$priv"/vcn.?????? ]] && rm -rf -- "$dir"
  echo "ok $name: a state_checked in the environment did not skip the check"
  cases=$((cases + 1))
}

# A test of both write bits catches a mode that only the group, or only others, can write. A test of one bit passes the
# other: 702 is the mode for the group bit, 720 for the others bit.
state_mode_partial_case() {
  local name=state-mode-partial dir mode
  for mode in 702 720; do
    dir=$(marker_state_dir "$priv")
    chmod "$mode" "$dir"
    refuses_state "$name" "$dir" "refusing state dir $dir: it is group- or world-writable"
    [[ $dir == "$priv"/vcn.?????? ]] && rm -rf -- "$dir"
  done
  echo "ok $name: a state dir that only others, or only the group, can write was refused and its run.env not sourced"
  cases=$((cases + 1))
}

state_parent_partial_case() {
  local name=state-parent-partial loose dir mode
  for mode in 702 720; do
    loose=$TMP/loose-$mode
    mkdir -m "$mode" "$loose"
    dir=$(marker_state_dir "$loose")
    refuses_state "$name" "$dir" "refusing state dir $dir: $loose, above the state dir, is writable by others and not sticky"
    rm -rf -- "$loose"
  done
  echo "ok $name: a dir above the state dir that only others, or only the group, can write was refused"
  cases=$((cases + 1))
}

# unsafe_walk reads one stat record per dir that exists, and refuses when it gets fewer: a missing record would shift the
# owner and mode of every dir after it. The stat shim drops the loose dir from its arguments, so the one dir that the walk
# must refuse is the one that gets no record.
state_count_case() {
  local name=state-count loose=$TMP/count-loose dir out rc=0
  mkdir -m 777 "$loose"
  mkdir "$TMP/stat-drop"
  printf '#!/bin/bash\nargs=()\nfor a in "$@"; do [[ $a == "$DROP" ]] || args+=("$a"); done\nexec "%s" "${args[@]}"\n' "$(command -v stat)" >"$TMP/stat-drop/stat"
  chmod +x "$TMP/stat-drop/stat"
  dir=$(marker_state_dir "$loose")
  out=$(env PATH="$TMP/stat-drop:$base" DROP="$loose" VCN_STATE="$dir" "$V" cleanup 2>&1) || rc=$?
  [[ ! -e $TMP/marker-$name ]] || fail "$name" "vcn.sh sourced the run.env of $dir while stat answered for one dir fewer"
  ((rc == 1)) && [[ $out == *"refusing state dir $dir: $loose, above the state dir, could not be read in full"* ]] ||
    fail "$name" "cleanup exited $rc, wanted 1 with 'could not be read in full': $out"
  rm -rf -- "$loose" "$TMP/stat-drop"
  echo "ok $name: a walk that got one stat record too few refused the state dir and did not source its run.env"
  cases=$((cases + 1))
}

# A command substitution cuts the newlines at the end of a name. The check compares VCN_STATE with its resolved path, which
# it reads with a NUL end so that the newline stays: a dir named so is the dir it names, and it is accepted.
state_newline_case() {
  local name=state-newline dir out rc=0
  dir=$priv/vcn.Nl$'\n'
  mkdir -m 700 "$dir"
  printf 'touch %s\n' "$TMP/marker-$name" >"$dir/run.env"
  out=$(env PATH="$base" VCN_STATE="$dir" "$V" cleanup 2>&1) || rc=$?
  [[ -e $TMP/marker-$name ]] || fail "$name" "vcn.sh refused a state dir whose name ends in a newline: $out"
  [[ $out != *"refusing state dir"* ]] || fail "$name" "vcn.sh refused a state dir whose name ends in a newline: $out"
  [[ $dir == "$priv"/vcn.* ]] && rm -rf -- "$dir"
  echo "ok $name: a state dir whose name ends in a newline was accepted and its run.env sourced"
  cases=$((cases + 1))
}

# bwrap makes a user namespace that this user owns (no sudo, no second account). It maps this user to uid 0 and every
# host-root-owned inode to nobody. Its /tmp is a root-owned sticky tmpfs, like a host /tmp, so every dir in the chain
# above the planted one belongs to root there, and the walk above passes.
# foreign_owner_case <case> <planted dir> <state dir> <text> <what passed>: <planted dir> is a read-only overlay. Its top
# layer is a host-root-owned dir, so its owner shows as nobody, and its lower layer holds <state dir> (the planted dir
# itself, or a dir this user owns inside it) with a run.env that touches a marker.
foreign_owner_case() {
  local name=$1 planted=$2 state=$3 want=$4 passed=$5 top="" cand lower=$TMP/$1-lower rel out skill
  local args=()
  command -v bwrap >/dev/null || {
    echo "SKIP $name: bwrap is not installed"
    return 0
  }
  for cand in /srv /opt /usr /etc; do
    [[ $(stat -c '%u %a' -- "$cand" 2>/dev/null) == "0 755" ]] && {
      top=$cand
      break
    }
  done
  [[ -n $top ]] || {
    echo "SKIP $name: no host-root-owned 0755 dir for the top layer"
    return 0
  }
  skill=$(cd "$(dirname "$V")/.." && pwd)
  rel=${state#"$planted"}
  rel=${rel#/}
  mkdir "$lower"
  [[ -z $rel ]] || mkdir -m 700 "$lower/$rel"
  printf 'touch /tmp/marker-%s\n' "$name" >"$lower/$rel/run.env"
  args=(--unshare-user --uid 0 --gid 0 --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/lib /lib
    --symlink usr/lib64 /lib64 --unshare-pid --dev /dev --proc /proc --perms 01777 --tmpfs /tmp
    --overlay-src "$lower" --overlay-src "$top" --ro-overlay "$planted" --ro-bind "$skill" /v
    --setenv PATH /usr/bin:/bin --setenv VCN_STATE "$state")
  bwrap "${args[@]}" /usr/bin/true 2>/dev/null || {
    echo "SKIP $name: bwrap cannot make a user namespace with an overlay here"
    return 0
  }
  out=$(bwrap "${args[@]}" /usr/bin/bash -c '
    [[ $(stat -c %u "$1") != "$EUID" ]] || echo SETUP-PLANTED-IS-MINE
    [[ $1 == "$2" || $(stat -c %u "$2") == "$EUID" ]] || echo SETUP-STATE-IS-NOT-MINE
    /v/scripts/vcn.sh cleanup 2>&1
    echo "rc=$?"
    [[ ! -e /tmp/marker-$3 ]] || echo MARKER-SOURCED' _ "$planted" "$state" "$name" 2>&1) || true
  [[ $out != *SETUP-PLANTED-IS-MINE* ]] || fail "$name" "$planted shows this user as its owner, so the case proves nothing: $out"
  [[ $out != *SETUP-STATE-IS-NOT-MINE* ]] || fail "$name" "$state is not owned by this user, so only the owner test could refuse it: $out"
  [[ $out != *MARKER-SOURCED* ]] || fail "$name" "vcn.sh sourced the run.env of $state: $out"
  [[ $out == *"refusing state dir $state: $want"* && $out == *"rc=1"* ]] ||
    fail "$name" "cleanup did not refuse the dir with '$want' and exit 1: $out"
  echo "ok $name: $passed was refused and its run.env not sourced"
  cases=$((cases + 1))
}

state_owner_case() {
  foreign_owner_case state-owner /tmp/vcn.Abc123 /tmp/vcn.Abc123 "it is owned by another user" \
    "a state dir that another user owns, with a run.env,"
}

# Only the dir above the state dir is foreign: the state dir is this user's 0700 dir, so the owner test passes it.
state_ancestor_case() {
  foreign_owner_case state-ancestor /tmp/P /tmp/P/vcn.Abc123 "/tmp/P, above the state dir, is owned by another user" \
    "a state dir under a dir that another user owns"
}

# swap_watch <dir> <seconds> plays another user who owns <dir>. When agent-tty's staging dir (agent-tty-webm-*) appears there,
# it moves it aside and puts a dir of its own in its place, and when a .webm file appears in that dir, it moves the file
# aside and writes its own bytes under the same name. It polls every 0.05 s and ends once it has planted a file.
swap_watch() {
  local d=$1 until=$((SECONDS + $2)) s f swapped="" planted=""
  while ((SECONDS < until)); do
    for s in "$d"/agent-tty-webm-*; do
      [[ -d $s && ! -L $s && $s != *.orig && -z $swapped ]] || continue
      mv -- "$s" "$s.orig" && mkdir -m 777 -- "$s" && swapped=$s
    done
    if [[ -n $swapped && -z $planted ]]; then
      for f in "$swapped"/*.webm; do
        [[ -f $f ]] || continue
        mv -- "$f" "$f.orig" && printf 'FORGED-BY-ANOTHER-USER\n' >"$f" && planted=$f
      done
    fi
    [[ -z $planted ]] || return 0
    sleep 0.05
  done
}

# Before att() gave agent-tty a TMPDIR of its own, agent-tty read TMPDIR as given and followed every symlink in it each time it
# made a staging dir. TMPDIR is a symlink of this user's (hop1) to a symlink in a dir that others can write (hop2), to the
# private dir. Both walks of launch pass it: hop1 is this user's, and the resolved dir is private. After launch, hop2 is
# pointed at a dir of another user, whom swap_watch plays while `record` runs. The evidence dir must not get the planted
# bytes.
tmp_multihop_case() {
  local name=tmp-multihop loose=$TMP/mh-loose own=$TMP/mh-own other r=0 wpid wcmd
  other=$loose/other
  mkdir -m 777 "$loose" "$other"
  mkdir -m 700 "$own"
  ln -s "$priv" "$loose/hop2"
  ln -s "$loose/hop2" "$own/hop1"
  launch "$name" "$good_path" TMPDIR="$own/hop1"
  ((rc == 0)) || fail "$name" "launch exited $rc: $out"
  rm -- "$loose/hop2"
  ln -s "$other" "$loose/hop2"
  swap_watch "$other" 120 &
  wpid=$!
  wcmd=$(tr '\0' ' ' <"/proc/$wpid/cmdline")
  env PATH="$good_path" TMPDIR="$own/hop1" VCN_STATE="$state" "$V" record r2 >"$TMP/$name-record.txt" 2>&1 || r=$?
  if [[ -d /proc/$wpid && $(tr '\0' ' ' <"/proc/$wpid/cmdline") == "$wcmd" ]]; then kill "$wpid"; fi
  wait "$wpid" 2>/dev/null || true
  stop "$good_path"
  ((r == 0)) || fail "$name" "record exited $r: $(tail -n 2 "$TMP/$name-record.txt")"
  [[ -s $TMP/out-$name/r2.webm ]] || fail "$name" "record wrote no r2.webm"
  ! grep -q FORGED-BY-ANOTHER-USER "$TMP/out-$name/r2.webm" ||
    fail "$name" "r2.webm holds the bytes that another user planted through the symlinks of TMPDIR"
  echo "ok $name: after the second symlink of TMPDIR was repointed, record wrote none of the other user's bytes"
  cases=$((cases + 1))
}

# A command that runs with another TMPDIR than launch did must not depend on it: this one names a dir that does not exist.
tmp_later_case() {
  local name=tmp-later-tmpdir missing=$TMP/no-such-tmp r=0
  launch "$name" "$good_path"
  ((rc == 0)) || fail "$name" "launch exited $rc: $out"
  [[ $(stat -c %a -- "$state/tmp") == 700 ]] || fail "$name" "launch made $state/tmp with mode $(stat -c %a -- "$state/tmp"), not 700"
  env PATH="$good_path" TMPDIR="$missing" VCN_STATE="$state" "$V" record r2 >"$TMP/$name-record.txt" 2>&1 || r=$?
  stop "$good_path"
  ((r == 0)) || fail "$name" "record with TMPDIR=$missing exited $r: $(tail -n 2 "$TMP/$name-record.txt")"
  [[ -s $TMP/out-$name/r2.webm ]] || fail "$name" "record wrote no r2.webm"
  [[ ! -e $missing ]] || fail "$name" "a command made the dir that the TMPDIR of the caller names"
  echo "ok $name: record ran with a TMPDIR that does not exist, and agent-tty used a dir of the state dir"
  cases=$((cases + 1))
}

# A run that an older vcn.sh started has no $VCN_STATE/tmp. att() must make it, mode 0700, before it gives agent-tty that TMPDIR,
# or the WebM export of record fails. The case removes the dir that launch made to look like such a run.
tmp_removed_case() {
  local name=tmp-removed r=0 mode
  launch "$name" "$good_path"
  ((rc == 0)) || fail "$name" "launch exited $rc: $out"
  [[ $state == "$priv"/vcn.?????? ]] || fail "$name" "launch printed a state dir outside the proof's private dir: $state"
  rm -rf -- "$state/tmp"
  env PATH="$good_path" VCN_STATE="$state" "$V" record r2 >"$TMP/$name-record.txt" 2>&1 || r=$?
  mode=$(stat -c %a -- "$state/tmp" 2>/dev/null || echo missing)
  stop "$good_path"
  ((r == 0)) || fail "$name" "record without $state/tmp exited $r: $(tail -n 2 "$TMP/$name-record.txt")"
  [[ -s $TMP/out-$name/r2.webm ]] || fail "$name" "record wrote no r2.webm"
  [[ $mode == 700 ]] || fail "$name" "record left $state/tmp with mode $mode, not 700"
  echo "ok $name: record made $state/tmp again with mode 0700 and wrote a WebM"
  cases=$((cases + 1))
}

signal_symlink_case() {
  local name=signal-symlink gate=$TMP/gate-signal-symlink sockdir
  ln -s "$priv" "$TMP/priv-link"
  mkdir "$gate"
  start_launch "$name" "$TMP/mise:$TMP/slow:$base" GATE="$gate" REAL_ATT="$good" TMPDIR="$TMP/priv-link"
  wait_for "$name" "$gate/reached"
  find_state "$name"
  sockdir=/tmp/agent-tty/$(printf %s "$st/att" | sha256sum | cut -c1-8)
  [[ -d $sockdir ]] || fail "$name" "the real agent-tty made no $sockdir, so the proof cannot show launch removes it"
  signal_group "$name" TERM "$st"
  [[ ! -e $sockdir ]] || {
    rmdir "$sockdir"
    fail "$name" "launch left the socket dir $sockdir of its agent-tty home"
  }
  echo "ok $name: SIGTERM with a symlink in TMPDIR removed the socket dir that agent-tty named after the real home path"
  cases=$((cases + 1))
}

# vcn.sh cleanup on the run.env of a launch that stopped before an agent-tty passed doctor: it has no ATT_BIN.
cleanup_no_agent_tty_case() {
  local name=cleanup-no-agent-tty dir
  dir=$(mktemp -d "$priv/vcn.XXXXXX")
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
signal_gap_case
cleanup_no_agent_tty_case
setsid_resolved_case
jq_old_run_case
node_dir_case
state_resolved_case
state_slash_case
state_mode_case
state_parent_case
state_names_case
state_env_case
state_mode_partial_case
state_parent_partial_case
state_count_case
state_newline_case
state_owner_case
state_ancestor_case
tmp_multihop_case
tmp_later_case
tmp_removed_case
get_values_case
get_state_case
journey_out_case
dashboard_case
signal_symlink_case
sigterm_case
echo "CASES $cases"
