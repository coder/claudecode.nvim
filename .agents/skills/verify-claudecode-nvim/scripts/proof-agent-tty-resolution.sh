#!/usr/bin/env bash
# Proves how `vcn.sh launch` picks agent-tty and loads VCN_RTP, with stand-ins for a broken agent-tty and for mise:
#   skip-broken       an agent-tty on PATH that fails `agent-tty doctor` comes first: launch runs the next one that passes
#   mise-broken       mise's agent-tty is the broken one: launch runs the PATH one that passes
#   explicit          VCN_AGENT_TTY wins over a broken agent-tty on PATH
#   explicit-broken   VCN_AGENT_TTY fails doctor: launch exits 1 naming it, and does not fall back to PATH
#   explicit-missing  VCN_AGENT_TTY is not an executable file: launch exits 1 naming it
#   none-passes       every candidate fails doctor: launch exits 1 with one message that lists each failure and the fix
#   rtp               VCN_RTP=<dir>:<dir> puts both dirs on nvim's runtimepath, so require() finds a module in each
#   rtp-control       without VCN_RTP the same require() fails
# A good agent-tty is $VCN_AGENT_TTY when set, else the first agent-tty on PATH or in mise. The cases that start a run
# need everything under Needs in SKILL.md.
# Prints one `ok <case>` per case, or `FAIL <case>: <reason>` and exits 1, and ends with `CASES <n>`.
set -euo pipefail
V="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vcn.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cases=0

fail() {
  echo "FAIL $1: $2" >&2
  exit 1
}

good=${VCN_AGENT_TTY:-$(command -v agent-tty || mise which agent-tty)} || fail setup "no agent-tty to use as the good one"
real_mise=$(command -v mise)
base=$(dirname "$(command -v jq)"):$(dirname "$(command -v setsid)"):/usr/bin:/bin
for dir in ${base//:/ }; do
  [[ ! -e $dir/agent-tty ]] || fail setup "$dir holds an agent-tty, so no case can leave PATH without a good one"
done

# The stand-in dies the way a mise-installed agent-tty without node-pty's native build does.
mkdir "$TMP/broken" "$TMP/mise"
printf '%s\n' '#!/bin/sh' "echo 'Error: Failed to load native module: pty.node, checked: build/Release' >&2" 'exit 1' >"$TMP/broken/agent-tty"
# The stand-in answers `mise which agent-tty` with $FAKE_MISE_ATT, and nothing else differently.
cat >"$TMP/mise/mise" <<MISE
#!/bin/sh
if [ "\$1" = which ] && [ "\$2" = agent-tty ]; then
  [ -n "\${FAKE_MISE_ATT-}" ] && echo "\$FAKE_MISE_ATT" && exit 0
  exit 1
fi
exec "$real_mise" "\$@"
MISE
chmod +x "$TMP/broken/agent-tty" "$TMP/mise/mise"
mkdir "$TMP/good"
ln -s "$good" "$TMP/good/agent-tty"

# launch <case> <PATH> [VAR=value...]: sets rc, out and state.
launch() {
  local name=$1 path=$2
  shift 2
  rc=0
  out=$(env -u VERIFY_OUT -u XUM_SCRATCH_DIR -u VCN_AGENT_TTY PATH="$path" VERIFY_OUT="$TMP/out-$name" "$@" "$V" launch 2>&1) || rc=$?
  state=$(grep -o 'VCN_STATE=/tmp/vcn\.[A-Za-z0-9]*' <<<"$out" | head -n 1 | cut -d= -f2 || true)
}

stop() { [[ -z $state ]] || env PATH="$1" VCN_STATE="$state" "$V" cleanup >/dev/null; }

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
  [[ -z $state || ! -e $state ]] || fail "$name" "state dir $state is still there"
  echo "ok $name: exit 1, output has '$want'"
  cases=$((cases + 1))
}

launched_with skip-broken "$TMP/mise:$TMP/broken:$TMP/good:$base" "$TMP/good/agent-tty"
launched_with mise-broken "$TMP/mise:$TMP/good:$base" "$TMP/good/agent-tty" FAKE_MISE_ATT="$TMP/broken/agent-tty"
launched_with explicit "$TMP/mise:$TMP/broken:$base" "$good" VCN_AGENT_TTY="$good"
refused explicit-broken "$TMP/mise:$TMP/good:$base" "$TMP/broken/agent-tty: Error: Failed to load native module: pty.node" \
  VCN_AGENT_TTY="$TMP/broken/agent-tty"
refused explicit-missing "$TMP/mise:$TMP/good:$base" "VCN_AGENT_TTY=$TMP/nope is not an executable file" VCN_AGENT_TTY="$TMP/nope"
refused none-passes "$TMP/mise:$TMP/broken:$base" "npm install --prefix <dir> agent-tty@0.5.0" FAKE_MISE_ATT="$TMP/broken/agent-tty"
[[ $out == *"MISE_DISABLE_TOOLS=npm:agent-tty VCN_AGENT_TTY=<dir>/node_modules/.bin/agent-tty"* ]] || fail none-passes "output lacks the fix command: $out"
[[ $out == *"$TMP/broken/agent-tty: Error: Failed to load native module: pty.node"* ]] || fail none-passes "output lacks the candidate's failure: $out"

for d in one two; do
  mkdir -p "$TMP/rtp-$d/lua"
  echo "return { dir = '$d' }" >"$TMP/rtp-$d/lua/vcn_rtp_$d.lua"
done
probe="luaeval('(pcall(require, \"vcn_rtp_one\") and \"one\" or \"-\") .. (pcall(require, \"vcn_rtp_two\") and \"two\" or \"-\")')"
launch rtp "$TMP/mise:$TMP/good:$base" VCN_RTP="$TMP/rtp-one:$TMP/rtp-two"
((rc == 0)) || fail rtp "launch exited $rc: $out"
got=$(env PATH="$TMP/mise:$TMP/good:$base" VCN_STATE="$state" "$V" expr "$probe" 2>&1) || true
stop "$TMP/mise:$TMP/good:$base"
[[ $got == onetwo ]] || fail rtp "require found '$got', wanted onetwo"
echo "ok rtp: require() found a module in each VCN_RTP dir"
cases=$((cases + 1))
launch rtp-control "$TMP/mise:$TMP/good:$base"
((rc == 0)) || fail rtp-control "launch exited $rc: $out"
got=$(env PATH="$TMP/mise:$TMP/good:$base" VCN_STATE="$state" "$V" expr "$probe" 2>&1) || true
stop "$TMP/mise:$TMP/good:$base"
[[ $got == -- ]] || fail rtp-control "require found '$got' without VCN_RTP"
echo "ok rtp-control: require() fails without VCN_RTP"
cases=$((cases + 1))
echo "CASES $cases"
