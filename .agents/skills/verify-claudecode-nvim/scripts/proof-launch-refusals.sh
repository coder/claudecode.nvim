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
#   out-uncreatable  mkdir cannot create VERIFY_OUT
#   out-file       VERIFY_OUT is a file
#   parent-uncreatable  mkdir cannot create the default parent dir
#   out-acl-unremovable  VERIFY_OUT has a default ACL that launch cannot remove (setfacl fails)
#   race           another launch makes the missing dir above VERIFY_OUT first, group-writable: launch uses it,
#                  refuses it in the check after mkdir, and leaves it in place
# and that it accepts:
#   out-dash       a relative VERIFY_OUT that starts with "-", run from another directory
#   out-acl        a 0500 VERIFY_OUT with a default ACL: launch makes it 0700 without the ACL, so every evidence file is 0600
#   out-made       a new VERIFY_OUT two levels below a dir with a default ACL: launch creates both dirs 0700 and
#                  without an ACL, so every evidence file is 0600
# A refused launch must also leave the files under the proof's temp dir as it found them.
# Prints PASS <case> per case, or FAIL: <reason> and exits 1. The init case's evidence dir is
# deleted when every case passes, and kept with its path printed when one fails.
set -euo pipefail
V="$(dirname "${BASH_SOURCE[0]}")/vcn.sh"
TMP=$(mktemp -d)
init_out=""
finish() {
  local rc=$?
  rm -rf "$TMP"
  [[ -n $init_out ]] || return 0
  if ((rc == 0)); then
    rm -rf "$init_out"
  else
    echo "init evidence kept in $init_out" >&2
  fi
}
trap finish EXIT

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
  local name=$1 want=$2 before after
  shift 2
  before=$(find "$TMP" | sort)
  launch "$name" "$@"
  [[ $err == *"$want"* ]] || fail "$name: stderr lacks '$want': $err"
  [[ $err != *VCN_STATE=* ]] || fail "$name: launch started a run before it refused: $err"
  after=$(find "$TMP" | sort)
  [[ $after == "$before" ]] ||
    fail "$name: launch changed $TMP (< removed, > added): $(diff <(echo "$before") <(echo "$after") | grep '^[<>]' | tr '\n' ' ')"
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
refused out-uncreatable "cannot create /proc/vcn-proof" VERIFY_OUT=/proc/vcn-proof
: >"$TMP/out-file"
refused out-file "$TMP/out-file is not a directory" VERIFY_OUT="$TMP/out-file"
refused parent-uncreatable "cannot create /proc/verify-claudecode-nvim/" XUM_SCRATCH_DIR=/proc
# Two first launches can both find the default parent dir missing. The mkdir shim plays the launch that makes
# $TMP/race/mid first, and makes it unsafe, so only the check after mkdir can refuse it.
mkdir "$TMP/race" "$TMP/race-bin"
printf '#!/bin/sh\n[ "$4" = "%s" ] && "%s" -m 770 -- "$4" && echo "mkdir: File exists" >&2 && exit 1\nexec "%s" "$@"\n' \
  "$TMP/race/mid" "$(command -v mkdir)" "$(command -v mkdir)" >"$TMP/race-bin/mkdir"
chmod +x "$TMP/race-bin/mkdir"
launch race PATH="$TMP/race-bin:$PATH" VERIFY_OUT="$TMP/race/mid/out"
[[ $err == *"$TMP/race/mid, above the evidence dir, is writable by others and not sticky"* ]] ||
  fail "race: launch did not take the dir the other launch made: $err"
[[ -d $TMP/race/mid && ! -e $TMP/race/mid/out ]] ||
  fail "race: launch removed the dir the other launch made, or kept the one it made"
echo "PASS race: $err"
# A default ACL gives a new dir or file group access whatever the harness's umask 077.
mkdir "$TMP/acl"
if command -v setfacl >/dev/null && setfacl -d -m u::rwx,g::rwx,o::--- "$TMP/acl" 2>/dev/null; then
  # chmod does not touch a default ACL, so this dir passes both checks, and its files would get group access.
  mkdir -m 700 "$TMP/acl-out" "$TMP/no-setfacl"
  setfacl -d -m u::rwx,g::rwx,o::--- "$TMP/acl-out"
  printf '#!/bin/sh\nexit 1\n' >"$TMP/no-setfacl/setfacl"
  chmod +x "$TMP/no-setfacl/setfacl"
  refused out-acl-unremovable "a new file in $TMP/acl-out gets mode 660, not 600" \
    PATH="$TMP/no-setfacl:$PATH" VERIFY_OUT="$TMP/acl-out"
else
  echo "SKIP out-acl-unremovable, out-acl, out-made: setfacl cannot set a default ACL on $TMP/acl"
fi
[[ -z $(ls -A "$TMP/out") ]] || fail "a refused launch wrote into $TMP/out"

vcn=$(cd "$(dirname "$V")" && pwd)/vcn.sh
mkdir "$TMP/cwd"
err=$(cd "$TMP/cwd" && env -u XUM_SCRATCH_DIR VERIFY_OUT=-dash "$vcn" launch 2>&1) || fail "out-dash: launch failed: $err"
VCN_STATE=$(sed -n 's/^VCN_STATE=//p' <<<"$err") "$vcn" cleanup >/dev/null
[[ $(stat -c %a -- "$TMP/cwd/-dash") == 700 ]] || fail "out-dash: $TMP/cwd/-dash is not a 0700 dir"
[[ -e $TMP/cwd/-dash/session.webm ]] || fail "out-dash: cleanup from another directory did not save session.webm there"
echo "PASS out-dash: launched with VERIFY_OUT=-dash from $TMP/cwd; cleanup from $PWD saved its evidence there"

# private <case> <dir>: a run with VERIFY_OUT=dir works, and after cleanup dir is 0700 and holds only 0600 files.
private() {
  local name=$1 dir=$2 shared
  err=$(env -u XUM_SCRATCH_DIR VERIFY_OUT="$dir" "$vcn" launch 2>&1) || fail "$name: launch failed: $err"
  VCN_STATE=$(sed -n 's/^VCN_STATE=//p' <<<"$err") "$vcn" cleanup >/dev/null
  shared=$(find "$dir" -type f ! -perm 600 -printf '%m %P, ')
  [[ -z $shared ]] || fail "$name: evidence files that are not 0600: $shared"
  [[ -e $dir/session.webm ]] || fail "$name: cleanup did not save session.webm"
  [[ $(stat -c %a -- "$dir") == 700 ]] || fail "$name: $dir is not a 0700 dir"
}

if [[ -d $TMP/acl-out ]]; then
  # 0500 is safe too, but the owner cannot create files there until launch makes it 0700.
  chmod 500 "$TMP/acl-out"
  private out-acl "$TMP/acl-out"
  echo "PASS out-acl: launch made the 0500 $TMP/acl-out a 0700 dir without its default ACL, and all $(find "$TMP/acl-out" -type f | wc -l) evidence files are 0600"
  # A new default parent dir (XUM_SCRATCH_DIR=$TMP/acl) is made by the same code as $TMP/acl/mid.
  private out-made "$TMP/acl/mid/out"
  [[ $(stat -c %a -- "$TMP/acl/mid") == 700 ]] || fail "out-made: $TMP/acl/mid is not a 0700 dir"
  acl=$(getfacl --skip-base -- "$TMP/acl/mid" 2>/dev/null | grep -v '^#' || true)
  [[ -z $acl ]] || fail "out-made: $TMP/acl/mid keeps the ACL it inherited: $(tr '\n' ' ' <<<"$acl")"
  echo "PASS out-made: launch created $TMP/acl/mid and $TMP/acl/mid/out as 0700 without an ACL in a dir with a default ACL, and all $(find "$TMP/acl/mid/out" -type f | wc -l) evidence files are 0600"
fi

init_out=$(mktemp -d)
launch init VCN_INIT_JSONRPC=1.0 VERIFY_OUT="$init_out"
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
echo "PASS init: launch exited 1 on the plugin's -32600 answer; $state is gone, no tagged process"
