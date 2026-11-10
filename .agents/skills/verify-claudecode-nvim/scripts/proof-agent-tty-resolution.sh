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
#   rtp-relative      relative VCN_RTP entries resolve against the directory launch runs in
#   rtp-symlink       a VCN_RTP entry with `..` after a symlink means the parent of the link's target
#   rtp-missing       a VCN_RTP entry that is not a directory: launch exits 1 naming it
#   rtp-control       without VCN_RTP the same require() fails
#   sigterm           SIGTERM to the process group of a running launch: it exits 143 and leaves no state dir or process
# A good agent-tty is $VCN_AGENT_TTY when set, else the first agent-tty on PATH or in mise. The cases that start a run
# need everything under Needs in SKILL.md.
# Prints one `ok <case>` per case, or `FAIL <case>: <reason>` and exits 1, and ends with `CASES <n>`.
set -euo pipefail
V="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vcn.sh"
TMP=$(mktemp -d)
live_state="" live_path=""
cleanup_all() {
  if [[ -n $live_state ]]; then
    env PATH="$live_path" VCN_STATE="$live_state" "$V" cleanup >/dev/null 2>&1 || true
  fi
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
# The stand-in answers `mise which agent-tty` with $FAKE_MISE_ATT, and nothing else differently.
cat >"$TMP/mise/mise" <<MISE
#!/bin/sh
if [ "\$1" = which ] && [ "\$2" = agent-tty ]; then
  [ -n "\${FAKE_MISE_ATT-}" ] && echo "\$FAKE_MISE_ATT" && exit 0
  exit 1
fi
exec "$real_mise" "\$@"
MISE
chmod +x "$TMP/broken/agent-tty" "$TMP/shim/agent-tty" "$TMP/mise/mise"
ln -s "$good" "$TMP/good/agent-tty"
ln -s "$good" "$TMP/good2/agent-tty"
good_path=$TMP/mise:$TMP/good:$base

# launch <case> <PATH> [VAR=value...]: runs launch and sets rc, out and state.
launch() {
  local name=$1 path=$2
  shift 2
  rc=0
  out=$(env -u VERIFY_OUT -u XUM_SCRATCH_DIR -u VCN_AGENT_TTY PATH="$path" VERIFY_OUT="$TMP/out-$name" "$@" "$V" launch 2>&1) || rc=$?
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
rtp_case rtp-relative onetwo VCN_RTP="$(realpath -s --relative-to=. "$TMP/rtp-one"):$(realpath -s --relative-to=. "$TMP/rtp-two")"
rtp_case rtp-symlink onetwo VCN_RTP="$TMP/rtp-one:$TMP/lnk/../rtp-linked"
refused rtp-missing "$good_path" "VCN_RTP entry $TMP/nope is not a directory" VCN_RTP="$TMP/rtp-one:$TMP/nope"
rtp_case rtp-control --

# A signal ends bash with $? still 0 in an EXIT trap, so launch must turn it into an exit to clean up its run. The
# signal lands after launch made the agent-tty session, so the cleanup must destroy a live session: its host process
# and its nvim both carry the run's tag.
sigterm_case() {
  local name=sigterm pid f st="" rc=0 pids=()
  env -u VERIFY_OUT -u XUM_SCRATCH_DIR -u VCN_AGENT_TTY PATH="$good_path" VERIFY_OUT="$TMP/out-$name" \
    "$TMP/tools/setsid" "$V" launch >"$TMP/$name.txt" 2>&1 </dev/null &
  pid=$!
  for _ in $(seq 300); do
    for f in /tmp/vcn.*/run.env; do
      if [[ -f $f ]] && grep -qxF "OUT=$TMP/out-$name" "$f" 2>/dev/null; then st=$(dirname "$f"); fi
    done
    [[ -z $st ]] || break
    sleep 0.1
  done
  [[ -n $st ]] || fail "$name" "launch wrote no run.env within 30 s: $(cat "$TMP/$name.txt")"
  live_state=$st live_path=$good_path
  for _ in $(seq 600); do
    grep -q '^TUI_PID=' "$st/run.env" 2>/dev/null && break
    sleep 0.1
  done
  grep -q '^TUI_PID=' "$st/run.env" || fail "$name" "launch made no session within 60 s: $(cat "$TMP/$name.txt")"
  [[ ! -e $TMP/out-$name/run.env ]] || fail "$name" "launch finished before the signal"
  kill -TERM -- "-$pid" || fail "$name" "no process group $pid to signal"
  wait "$pid" || rc=$?
  [[ $rc == 143 ]] || fail "$name" "launch exited $rc after SIGTERM, wanted 143: $(cat "$TMP/$name.txt")"
  [[ ! -e $st ]] || fail "$name" "state dir $st is still there after SIGTERM"
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

sigterm_case
echo "CASES $cases"
