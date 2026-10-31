#!/usr/bin/env bash
# Proves that `vcn.sh launch` exits 1 and leaves nothing running when:
#   init           the plugin answers initialize with an error: launch sends jsonrpc "1.0", the plugin answers -32600
#   out-link       VERIFY_OUT is a symlink
#   out-other      VERIFY_OUT is owned by another user
#   out-group      VERIFY_OUT is group-writable
#   out-dot        VERIFY_OUT has a . part
#   out-dotdot     VERIFY_OUT has a .. part
#   parent-link    the default parent dir is a symlink
#   parent-group   the default parent dir is group-writable
#   parent-world   the default parent dir is world-writable
#   above-world    a dir above the default parent dir is world-writable and not sticky
# Prints PASS <case> per case, or FAIL: <reason> and exits 1.
set -euo pipefail
V="$(dirname "${BASH_SOURCE[0]}")/vcn.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# launch <case> [VAR=value...]: run launch and set err to its output. A launch that succeeds is a
# failed case: clean its run up and stop.
launch() {
  local name=$1 rc=0
  shift
  err=$(env -u VERIFY_OUT -u XUM_SCRATCH_DIR "$@" "$V" launch 2>&1) || rc=$?
  if ((rc == 0)); then
    VCN_STATE=$(sed -n 's/^VCN_STATE=//p' <<<"$err") "$V" cleanup >/dev/null
    fail "$name: launch exited 0, wanted 1: $err"
  fi
  ((rc == 1)) || fail "$name: launch exited $rc, wanted 1: $err"
}

# refused <case> <stderr text> [VAR=value...]: launch exits 1 with that text before it starts a run.
refused() {
  local name=$1 want=$2
  shift 2
  launch "$name" "$@"
  [[ $err == *"$want"* ]] || fail "$name: stderr lacks '$want': $err"
  [[ $err != *VCN_STATE=* ]] || fail "$name: launch started a run before it refused: $err"
  echo "PASS $name: $err"
}

mkdir "$TMP/out" "$TMP/link" "$TMP/group" "$TMP/world"
ln -s "$TMP/out" "$TMP/out-link"
refused out-link "$TMP/out-link is a symlink" VERIFY_OUT="$TMP/out-link/"
# Root owns /, so a root caller gets a dir that nobody (uid 65534) owns.
other=/
if ((EUID == 0)); then
  other=$TMP/other
  mkdir "$other"
  chown 65534 "$other"
fi
refused out-other "$other is owned by another user" VERIFY_OUT="$other"
mkdir -m 770 "$TMP/out-group"
refused out-group "$TMP/out-group is group- or world-writable" VERIFY_OUT="$TMP/out-group"
refused out-dot "$TMP/out-link/. has a . or .. part" VERIFY_OUT="$TMP/out-link/."
refused out-dotdot "$TMP/out-link/../out has a . or .. part" VERIFY_OUT="$TMP/out-link/../out"
ln -s "$TMP/out" "$TMP/link/verify-claudecode-nvim"
refused parent-link "$TMP/link/verify-claudecode-nvim is a symlink" XUM_SCRATCH_DIR="$TMP/link"
mkdir -m 770 "$TMP/group/verify-claudecode-nvim"
refused parent-group "$TMP/group/verify-claudecode-nvim is group- or world-writable" XUM_SCRATCH_DIR="$TMP/group"
mkdir -m 707 "$TMP/world/verify-claudecode-nvim"
refused parent-world "$TMP/world/verify-claudecode-nvim is group- or world-writable" XUM_SCRATCH_DIR="$TMP/world"
mkdir -m 777 "$TMP/above"
refused above-world "$TMP/above, above the evidence dir, is writable by others and not sticky" \
  XUM_SCRATCH_DIR="$TMP/above"
[[ -z $(ls -A "$TMP/out") ]] || fail "a refused launch wrote into $TMP/out"

launch init VCN_INIT_JSONRPC=1.0 VERIFY_OUT="$(mktemp -d)"
state=$(sed -n 's/^vcn: launch failed (VCN_STATE=\([^)]*\)).*/\1/p' <<<"$err")
out=$(sed -n 's/^vcn: cleanup ok, no processes left; evidence kept in //p' <<<"$err")
[[ -n $state && -n $out ]] || fail "init: launch did not start a run and tear it down: $err"
printf '%s\n' "$err" >"$out/init-refusal-launch.txt"
[[ $err == *'vcn: initialize failed: '* ]] || fail "init: launch failed at another step: $err"
jq -e 'select(.id == "init") | .jsonrpc == "1.0"' "$out/ws-out.jsonl" >/dev/null ||
  fail "init: launch did not send jsonrpc 1.0"
jq -e 'select(.id == "init") | .error.code == -32600 and .result == null' "$out/ws-in.jsonl" >/dev/null ||
  fail "init: the plugin did not answer -32600: $(cat "$out/ws-in.jsonl")"
[[ ! -e $state ]] || fail "init: $state still exists"
pids=$(grep -lzxF "VCN_RUN_TAG=$state" /proc/[0-9]*/environ 2>/dev/null | cut -d/ -f3 || true)
[[ -z $pids ]] || fail "init: processes tagged $state still alive: $pids"
echo "PASS init: launch exited 1 on the plugin's -32600 answer; $state is gone, no tagged process; evidence in $out"
