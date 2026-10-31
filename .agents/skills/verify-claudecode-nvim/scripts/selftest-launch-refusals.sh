#!/usr/bin/env bash
# Proves what vcn.sh launch refuses and accepts, with real launches. Refused: an initialize call that answers
# an error, and a VERIFY_OUT that is a symlink (also with a trailing slash), not a directory, not owned by you,
# or not empty. Accepted: a missing VERIFY_OUT (also a relative one that starts with "-") and an empty
# directory you own, all left at mode 0700. Prints PASS, FAIL, or SKIP per case and exits 1 on any FAIL.
# Takes about a minute. Run it from the repo root.
set -euo pipefail
umask 077

V="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vcn.sh"
base=$(mktemp -d "${XUM_SCRATCH_DIR:-/tmp}/vcn-selftest.XXXXXX")
fails=0
log=""

result() {
  echo "$1 $2: $3"
  [[ $1 != FAIL ]] || fails=$((fails + 1))
}

# A refused launch exits 1 with the message. A launch that was not refused is cleaned up.
refused() {
  local name=$1 want=$2 rc=0 state
  shift 2
  log=$(env "$@" "$V" launch 2>&1) || rc=$?
  state=$(sed -n 's/^VCN_STATE=//p' <<<"$log")
  if [[ -n $state ]]; then VCN_STATE=$state "$V" cleanup >/dev/null 2>&1 || true; fi
  if ((rc != 1)); then
    result FAIL "$name" "exit $rc, wanted 1: $(tr '\n' ' ' <<<"$log")"
  elif ! grep -qE "$want" <<<"$log"; then
    result FAIL "$name" "message does not match /$want/: $(tr '\n' ' ' <<<"$log")"
  else
    result PASS "$name" "exit 1: $(grep -m1 -E "$want" <<<"$log")"
  fi
}

# An accepted launch prints OUT, the dir is ours at 0700, and cleanup succeeds. A relative VERIFY_OUT is
# resolved from the directory in $3.
accepted() {
  local name=$1 out=$2 cwd=${3-.} log state rc=0
  log=$(cd "$cwd" && VERIFY_OUT=$out "$V" launch 2>&1) || rc=$?
  state=$(sed -n 's/^VCN_STATE=//p' <<<"$log")
  if [[ -n $state ]]; then VCN_STATE=$state "$V" cleanup >/dev/null 2>&1 || rc=$?; fi
  [[ $out == /* ]] || out=$cwd/$out
  if ((rc != 0)) || [[ -z $state ]]; then
    result FAIL "$name" "exit $rc: $(tr '\n' ' ' <<<"$log")"
  elif [[ $(stat -c '%a %u' "$out") != "700 $(id -u)" ]]; then
    result FAIL "$name" "$out is $(stat -c '%a %U' "$out"), wanted 700 $(id -un)"
  else
    result PASS "$name" "launched and cleaned up, $out is 700 $(id -un)"
  fi
}

refused init-error 'vcn: initialize failed: .*"code":-32601' VCN_BREAK_INIT=1 VERIFY_OUT="$base/init"
if grep -q 'vcn: cleanup ok, no processes left' <<<"$log" && [[ -f $base/init/launch-failure.screen.txt ]]; then
  result PASS init-teardown "cleanup ok, no processes left, launch-failure.screen.txt saved"
else
  result FAIL init-teardown "no clean teardown: $(tr '\n' ' ' <<<"$log")"
fi

mkdir "$base/target"
ln -s target "$base/link"
refused out-symlink 'is a symlink' VERIFY_OUT="$base/link"
refused out-symlink-slash 'is a symlink' VERIFY_OUT="$base/link/"
[[ -z $(ls -A "$base/target") ]] || result FAIL out-symlink "the launch wrote into the symlink target"

: >"$base/file"
refused out-not-dir 'is not a directory' VERIFY_OUT="$base/file"

foreign=""
for d in /srv /mnt /media /var/local /var/opt /var/empty; do
  if [[ -d $d && ! -O $d && -z $(ls -A "$d" 2>/dev/null) ]]; then
    foreign=$d
    break
  fi
done
if [[ -n $foreign ]]; then
  refused out-foreign 'is not owned by' VERIFY_OUT="$foreign"
else
  result SKIP out-foreign "no empty directory owned by another user found"
fi

mkdir "$base/full"
: >"$base/full/keep"
refused out-not-empty 'is not empty' VERIFY_OUT="$base/full"

accepted out-missing "$base/new/out"
accepted out-dash-relative -dash "$base"
mkdir "$base/empty"
chmod 755 "$base/empty"
accepted out-empty-own "$base/empty"

echo "evidence: $base"
((fails == 0))
