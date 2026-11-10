#!/usr/bin/env bash
# Tests for scripts/tla/check-lib.sh. It builds a toy skill on the lib in a scratch git repo (the path has a space)
# and runs real TLC on a one-variable model. Each case prints one line, and the last line is a COUNT line.
# Exit 0 when every case passes, 1 when one fails. Needs java; the lib fetches the TLC jar when it is missing.
# Usage: test-check-lib.sh [path to check-lib.sh]
set -uo pipefail
export LC_ALL=C

lib=${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-lib.sh}
lib=$(cd "$(dirname "$lib")" && pwd)/$(basename "$lib")
[[ -f $lib ]] || {
  echo "ERROR: no lib at $lib" >&2
  exit 2
}

root=$(mktemp -d) || exit 2
trap 'rm -rf "$root"' EXIT
repo="$root/toy repo"
skill="$repo/.agents/skills/verify-toy"
check="$skill/check.sh"
export TMPDIR="$root/tmp dir"
mkdir -p "$TMPDIR" "$repo/scripts/tla" "$skill/model" "$repo/lua" "$root/fakebin"
cp "$lib" "$repo/scripts/tla/check-lib.sh"
printf 'local M = {}\nfunction M.step(x)\n  if x < 3 then\n    return x + 1\n  end\n  return x\nend\nreturn M\n' >"$repo/lua/toy.lua"
printf 'return 1\n' >"$repo/lua/other.lua"

cat >"$skill/model/Toy.tla" <<'TLA'
---- MODULE Toy ----
EXTENDS Naturals
CONSTANTS Guard, Other, InitBad, TypeBadInit
VARIABLE x
Init == x = IF TypeBadInit THEN 25 ELSE (IF InitBad THEN 9 ELSE 0)
Next == \/ /\ (Guard => x < 3) /\ x' = x + 1
        \/ /\ Other /\ x = 3 /\ x' = 0
Spec == Init /\ [][Next]_x /\ WF_x(Next)
TypeOK == x \in 0..20
Bound == x <= 5
Small == x <= 8
Cap == x <= 10
Reach == <>(x = 3)
====
TLA

# The toy check.sh: each TOY_* variable switches one thing, so a case changes one input of the lib.
cat >"$check" <<'SH'
#!/usr/bin/env bash
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$here/../../../scripts/tla/check-lib.sh"
[[ -n ${TOY_NO_SKILL-} ]] || SKILL=verify-toy
MODEL=${TOY_MODEL-Toy}
tla_init "$@"
covered_block step lua/toy.lua '^function M\.step\('
eval "COVERED=(${TOY_COVERED-lua/toy.lua lua/other.lua})"
[[ -n ${TOY_NO_SITE_RE-} ]] || SITE_RE=return
fact[Guard]=$(as_bool grep -q 'if x < 3 then' <<<"$step")
fact[Other]=TRUE
fact[InitBad]=${TOY_INITBAD-FALSE}
fact[TypeBadInit]=${TOY_TYPEBAD-FALSE}
[[ -n ${TOY_NO_RULES-} ]] || eval "RULES=(${TOY_RULES-Bound})"
eval "FACTS=(${TOY_FACTS-Guard Other InitBad TypeBadInit})"
eval "LIVE=(${TOY_LIVE-})"
eval "EXPECT=(${TOY_EXPECT-[Guard]=Bound [Other]=- [InitBad]=- [TypeBadInit]=-})"
MUTANT_NOTES=("  toy note")
CONSTRAINT=Cap
tla_constants() {
  [[ -z ${TOY_MKDIR-} ]] || mkdir -p "$work/$TOY_MKDIR"
  return "${TOY_CALLBACK_RC-0}"
}
tla_main "$@"
SH
chmod +x "$check"
git -C "$repo" init -q

# java that succeeds without checking anything: a harness that skips TLC reads as PASS.
printf '#!/bin/sh\nexit 0\n' >"$root/fakebin/java"
# curl that "downloads" a file that is not the TLC jar.
cat >"$root/fakebin/curl" <<'SH'
#!/bin/sh
while [ $# -gt 0 ]; do
  if [ "$1" = -o ]; then
    shift
    echo 'not a jar' >"$1"
    exit 0
  fi
  shift
done
exit 1
SH
chmod +x "$root/fakebin/java" "$root/fakebin/curl"

n=0 failed=0 skipped=0 out="" rc=0
count_files() { find "$1" -mindepth 1 | wc -l; }
# run COMMAND...: every case starts from the fresh lock, so a case that writes one cannot make the next one stale.
run() {
  [[ ! -f $skill/covered.lock.fresh ]] || cp "$skill/covered.lock.fresh" "$skill/covered.lock"
  out=$("$@" 2>&1)
  rc=$?
}
# expect NAME WANT_RC [PATTERN]: check $rc and $out from the last run.
expect() {
  local name=$1 want=$2 pattern=${3-}
  n=$((n + 1))
  if [[ $rc != "$want" ]]; then
    failed=$((failed + 1))
    echo "FAIL  $name: rc=$rc, want $want; last line: $(tail -n 1 <<<"$out")"
  elif [[ -n $pattern ]] && ! grep -qE -- "$pattern" <<<"$out"; then
    failed=$((failed + 1))
    echo "FAIL  $name: rc=$rc, but the output lacks /$pattern/; last line: $(tail -n 1 <<<"$out")"
  else
    echo "ok    $name"
  fi
}

run "$check" --record
expect "record a fresh lock" 0 "recorded"
cp "$skill/covered.lock" "$skill/covered.lock.fresh"
run "$check"
expect "baseline passes" 0 "RESULT: PASS"
run env TOY_TYPEBAD=TRUE "$check"
expect "TypeOK broken in the initial state exits 2" 2 "TypeOK broke"
run env TOY_INITBAD=TRUE TOY_RULES=Small "$check"
expect "a rule broken in the initial state ends with RESULT: FAIL" 1 "RESULT: FAIL"
run env TOY_RULES= "$check"
expect "empty RULES exits 2" 2 "RULES is empty"
run env TOY_NO_RULES=1 "$check"
expect "unset RULES exits 2" 2 "RULES is empty"
run env TOY_NO_SKILL=1 "$check"
expect "unset SKILL exits 2" 2 "must set SKILL"
run env TOY_NO_SITE_RE=1 "$check"
expect "unset SITE_RE exits 2" 2 "must set SITE_RE"
run env TOY_COVERED= "$check" --record
expect "empty COVERED exits 2" 2 "COVERED is empty"
run env TOY_COVERED=lua/other.lua "$check" --record
expect "a covered block in a file missing from COVERED exits 2" 2 "does not list"
run env TOY_MODEL=NoSuchModel "$check"
expect "a missing model file exits 2" 2 "no model at"
run env TOY_FACTS= "$check"
expect "empty FACTS exits 2" 2 "FACTS is empty"
run env TOY_CALLBACK_RC=1 "$check"
expect "a failing tla_constants exits 2" 2 "tla_constants failed"
run env TOY_LIVE=Reach TOY_MKDIR=live-Reach.cfg JAVA="$root/fakebin/java" "$check"
expect "a failed cfg write exits 2" 2 "could not write"
run env TOY_EXPECT='[Guard+Othr]=Bound [Other]=- [InitBad]=- [TypeBadInit]=-' "$check" --mutants
expect "an EXPECT key that names a non-fact exits 2" 2 "not in FACTS"
run env TOY_EXPECT='[Guard + Other]=Bound [InitBad]=- [TypeBadInit]=-' "$check" --mutants
expect "an EXPECT key with a space exits 2" 2 "has a space"
run env TOY_EXPECT='[Guard]=Bound [Other+InitBad+TypeBadInit]=-' "$check" --mutants
expect "the middle fact of an A+B+C EXPECT key has an entry" 0 "every guard is caught"
run "$check" --mutants
expect "--mutants passes and catches the guard" 0 "Guard=FALSE +caught by: Bound"
if [[ $(grep -n 'toy note' <<<"$out" | cut -d: -f1) -lt $(grep -n 'every guard is caught' <<<"$out" | cut -d: -f1) ]]; then
  n=$((n + 1))
  echo "ok    MUTANT_NOTES print before the closing line"
else
  n=$((n + 1))
  failed=$((failed + 1))
  echo "FAIL  MUTANT_NOTES print before the closing line"
fi

quoted="$root/tmp q'dir"
mkdir -p "$quoted"
run env TMPDIR="$quoted" "$check" --hash-only
expect "a TMPDIR with a single quote exits 0" 0 "covered.lock matches"
if [[ $(count_files "$quoted") == 0 ]]; then
  n=$((n + 1))
  echo "ok    a TMPDIR with a single quote leaves no work dir"
else
  n=$((n + 1))
  failed=$((failed + 1))
  echo "FAIL  a TMPDIR with a single quote leaves $(count_files "$quoted") work dir(s)"
fi

jar="$root/jar dir/tla2tools.jar"
run env PATH="$root/fakebin:$PATH" TLC_JAR="$jar" "$check" --mutants
expect "a download that fails the sha256 exits 2" 2 "does not match sha256"
if [[ ! -e $jar && ! -e $jar.tmp ]]; then
  n=$((n + 1))
  echo "ok    a download that fails the sha256 is not cached"
else
  n=$((n + 1))
  failed=$((failed + 1))
  echo "FAIL  a download that fails the sha256 stays at $jar"
fi

chmod 000 "$repo/lua/other.lua"
if [[ -r $repo/lua/other.lua ]]; then
  skipped=$((skipped + 1))
  echo "skip  an unreadable covered file exits 2 (this user can read any file)"
else
  run "$check" --hash-only
  expect "an unreadable covered file exits 2" 2 "not readable"
fi
chmod 644 "$repo/lua/other.lua"

echo "COUNT cases=$n failed=$failed skipped=$skipped"
[[ $failed == 0 ]]
