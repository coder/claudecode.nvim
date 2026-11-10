#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154 # the sourcing check.sh sets and reads these variables
# Shared harness for the TLA+ check scripts under .agents/skills/verify-*/check.sh.
# A check.sh sources this file, sets the variables below, declares its facts, then calls tla_main "$@".
#
#   SKILL        skill folder name, e.g. verify-mention-queue
#   MODEL        TLA+ module name; the spec lives at $here/model/$MODEL.tla
#   COVERED      array of repo-relative files that the model describes (the coverage record hashes each)
#   SITE_RE      ERE; each non-comment line of a COVERED file that matches it is listed in the record
#   FACTS        array of fact names, each a BOOLEAN constant of the model; fact[NAME] holds TRUE or FALSE
#   RULES        array of invariant names (TypeOK is always checked first and is not a rule)
#   LIVE         array of temporal property names (may be empty)
#   EXPECT       assoc array: fact name (or A+B for a combination) -> the rule that must break when it is FALSE,
#                or "-" for a fact that is not a guard
#   tla_constants NAME KIND
#                function printing the CONSTANTS lines (indented, without the facts) for run NAME,
#                KIND is "inv" or "live"
#   CONSTRAINT   optional state constraint name
#   MUTANT_NOTES optional array of lines that --mutants prints after its last row, before its closing line
#
# Exit codes: 0 pass, 1 rule broken, 2 tool or script error (or TypeOK broken), 3 stale.
set -euo pipefail
export LC_ALL=C
if ((BASH_VERSINFO[0] < 4)); then
  echo "ERROR: check.sh needs bash 4 or newer, not $BASH_VERSION (on macOS: brew install bash)" >&2
  exit 2
fi

# CI reads these two pin lines to key its jar cache and passes that jar as TLC_JAR. A check.sh must not set its own pin.
TLC_VERSION=1.7.4
TLC_SHA256=936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88
TLC_JAR="${TLC_JAR:-${XDG_CACHE_HOME:-$HOME/.cache}/claudecode-nvim-tla/tla2tools-$TLC_VERSION.jar}"
JAVA="${JAVA:-java}"

blocks=()
declare -A block_file
declare -A fact
FACTS=()
LIVE=()
CONSTRAINT=""
MUTANT_NOTES=()
declare -A EXPECT

sha256() {
  if command -v sha256sum >/dev/null; then sha256sum; else shasum -a 256; fi
}

# Print the block that starts at the first line matching $2 in file $1, up to the `end` at the same indentation.
block() {
  # Patterns go through ENVIRON: gawk processes backslash escapes in -v values, which breaks \(.
  RE=$2 awk '
    BEGIN { re = ENVIRON["RE"] }
    !found && $0 ~ re { found = 1; match($0, /^ */); indent = RLENGTH; print; next }
    found { print; if ($0 ~ "^" sprintf("%" indent "s", "") "end([ ,)]|$)") exit }
  ' "$1"
}

# True when the regexes match lines of stdin in this order.
in_order() {
  PATS=$(printf '%s\n' "$@") awk '
    BEGIN { n = split(ENVIRON["PATS"], p, "\n"); i = 1 }
    i <= n && $0 ~ p[i] { i++ }
    END { exit !(i > n) }
  '
}

as_bool() { if "$@"; then echo TRUE; else echo FALSE; fi; }

# covered_block NAME FILE REGEX: set $NAME to the block of FILE that starts at REGEX, and note it for the record.
covered_block() {
  blocks+=("$1")
  block_file[$1]=$2
  printf -v "$1" '%s' "$(block "$2" "$3")"
}

tla_parse_args() {
  mutants=0 keep=0 record=0 hash_only=0
  local arg
  for arg in "$@"; do
    case "$arg" in
    --mutants) mutants=1 ;;
    --keep) keep=1 ;;
    --record) record=1 ;;
    --hash-only) hash_only=1 ;;
    *)
      echo "usage: $0 [--mutants] [--keep] [--record] | $0 --hash-only" >&2
      exit 2
      ;;
    esac
  done
  if [[ $record == 1 && $mutants == 1 ]]; then
    echo "usage: --record cannot be combined with --mutants; run --mutants first, then --record" >&2
    exit 2
  fi
  if [[ $hash_only == 1 && $mutants$keep$record != 000 ]]; then
    echo "usage: --hash-only takes no other option" >&2
    exit 2
  fi
}

tla_fetch_jar() {
  if [[ ! -f $TLC_JAR ]]; then
    mkdir -p "$(dirname "$TLC_JAR")" || exit 2
    curl -fsSL -o "$TLC_JAR.tmp" "https://github.com/tlaplus/tlaplus/releases/download/v$TLC_VERSION/tla2tools.jar" || {
      echo "ERROR: could not download TLC $TLC_VERSION to $TLC_JAR" >&2
      exit 2
    }
    mv "$TLC_JAR.tmp" "$TLC_JAR"
  fi
  if [[ $(sha256 <"$TLC_JAR" | cut -d' ' -f1) != "$TLC_SHA256" ]]; then
    echo "ERROR: $TLC_JAR does not match sha256 $TLC_SHA256" >&2
    exit 2
  fi
}

# The coverage record: one group per covered file. A group holds a header that only adding or removing the file
# changes, the file's hash, the hashes of the covered blocks in it, and its call sites with their enclosing
# top-level statement, which point the reader at what changed.
tla_coverage() {
  local name file
  for name in "${blocks[@]}"; do
    [[ -n ${!name} ]] || {
      echo "ERROR: covered block $name not found; update its start regex in check.sh" >&2
      exit 2
    }
  done
  for file in "${COVERED[@]}"; do
    [[ -f $file ]] || {
      echo "ERROR: covered file $file does not exist; update COVERED in check.sh" >&2
      exit 2
    }
  done
  while IFS= read -r file; do
    printf '== %s\n' "$file"
    printf 'file %s %s\n' "$file" "$(sha256 <"$file" | cut -c1-16)"
    for name in "${blocks[@]}"; do
      [[ ${block_file[$name]} == "$file" ]] || continue
      printf 'block %-22s %s\n' "$name" "$(printf '%s\n' "${!name}" | sha256 | cut -c1-16)"
    done
    RE=$SITE_RE awk '
      BEGIN { re = ENVIRON["RE"] }
      /^[^[:space:]-]/ && !/^(end|else|elseif|return|[})])/ { top = $0 }
      $0 ~ re && $0 !~ /^[[:space:]]*--/ { line = $0; sub(/^[[:space:]]+/, "", line); print "site " FILENAME ": " line " @ " top }
    ' "$file" | sort
  done < <(printf '%s\n' "${COVERED[@]}" | sort -u)
}

# Compare (or with --record, write) covered.lock. Sets stale=0|1. Exits for --record and --hash-only.
tla_lock() {
  local lock="$here/covered.lock" current
  current=$(tla_coverage)
  if [[ $record == 1 ]]; then
    if [[ -L $lock || (-e $lock && ! -f $lock) ]]; then
      echo "ERROR: $lock is a symlink or not a regular file; refusing to write it" >&2
      exit 2
    fi
    local tmp
    tmp=$(mktemp "$here/.covered.lock.XXXXXX")
    printf '%s\n' "$current" >"$tmp"
    mv -f "$tmp" "$lock"
    echo "recorded $lock"
    exit 0
  fi
  stale=0
  if [[ -L $lock ]]; then
    echo "ERROR: $lock is a symlink; the coverage record must be a regular file" >&2
    exit 2
  fi
  if [[ ! -f $lock ]] || ! diff -q "$lock" <(printf '%s\n' "$current") >/dev/null; then
    stale=1
    echo "== STALE: the covered code changed since covered.lock was recorded (git log -- covered.lock shows when)."
    echo "   UNVERIFIED: no result below covers these changes until you read them and update the model."
    { diff <(cat -- "$lock" 2>/dev/null) <(printf '%s\n' "$current") || true; } | grep -E '^[<>]' |
      sed -e 's/^</   was:/' -e 's/^>/   now:/' -e 's/[^[:print:]]/?/g'
  fi
  if [[ $hash_only == 1 ]]; then
    if [[ $stale == 1 ]]; then
      echo "== RESULT: STALE. Follow \"Update after an intended change\" in .agents/skills/$SKILL/SKILL.md"
      exit 3
    fi
    echo "== RESULT: covered.lock matches the code"
    exit 0
  fi
}

# run_tlc NAME "INVARIANTS" "PROPERTIES" [FACT=VALUE ...]
# Leaves TLC output in $work/NAME.out and returns TLC's exit code.
run_tlc() {
  local name=$1 invariants=$2 properties=$3
  shift 3
  local -A vals
  local f kv kind=inv
  [[ -z $properties ]] || kind=live
  for f in "${FACTS[@]}"; do vals[$f]=${fact[$f]}; done
  for kv in "$@"; do vals[${kv%%=*}]=${kv#*=}; done
  {
    echo "SPECIFICATION Spec"
    echo "CONSTANTS"
    tla_constants "$name" "$kind"
    for f in "${FACTS[@]}"; do echo "  $f = ${vals[$f]}"; done
    [[ -z $invariants ]] || echo "INVARIANT $invariants"
    [[ -z $properties ]] || echo "PROPERTY $properties"
    [[ -z $CONSTRAINT ]] || echo "CONSTRAINT $CONSTRAINT"
    echo "CHECK_DEADLOCK FALSE"
  } >"$work/$name.cfg"
  local rc=0
  (cd "$work" && "$JAVA" -Xmx4g -XX:+UseParallelGC -Djava.io.tmpdir="$work" -cp "$TLC_JAR" tlc2.TLC \
    -workers 1 -lncheck final -cleanup -metadir "$work/meta-$name" -config "$name.cfg" "$MODEL.tla") \
    >"$work/$name.out" 2>&1 || rc=$?
  return "$rc"
}

broken_rule() {
  grep -oE 'Invariant [A-Za-z0-9_]+ is violated' "$1" | head -1 | awk '{print $2}' || true
}

show_trace() {
  echo "  -- trace (actions in order; read it with /statechart for plain words):"
  grep -E '^State [0-9]+: |^[0-9]+: <|Back to state' "$work/$1.out" | sed 's/^/     /'
}

# One run per liveness property: TLC stops at the first broken property, so a joint run hides the others.
tla_check() {
  local result=0 run rc
  echo "== model: code as written"
  local runs=(main)
  for run in "${LIVE[@]}"; do runs+=("live-$run"); done
  for run in "${runs[@]}"; do
    rc=0
    if [[ $run == main ]]; then
      run_tlc main "TypeOK ${RULES[*]}" "" || rc=$?
    else
      run_tlc "$run" "TypeOK" "${run#live-}" || rc=$?
    fi
    case "$rc" in
    0) echo "  $run: pass ($(grep -oE '[0-9,]+ distinct states found' "$work/$run.out" | tail -1))" ;;
    12)
      if [[ $(broken_rule "$work/$run.out") == TypeOK ]]; then
        echo "  $run: TypeOK broke: the model itself is wrong, not the code"
        show_trace "$run"
        exit 2
      fi
      echo "  $run: BROKEN: $(broken_rule "$work/$run.out")"
      show_trace "$run"
      result=1
      ;;
    13)
      echo "  $run: BROKEN: ${run#live-} (liveness)"
      show_trace "$run"
      result=1
      ;;
    *)
      echo "  $run: TLC ERROR (exit $rc)"
      tail -20 "$work/$run.out" | sed 's/^/  /'
      exit 2
      ;;
    esac
  done
  if [[ $result == 0 && $stale == 1 ]]; then
    echo "== RESULT: STALE, UNVERIFIED (the model passes, but nobody has checked it against the changed code)"
    exit 3
  fi
  [[ $result == 0 ]] && echo "== RESULT: PASS" || echo "== RESULT: FAIL"
  exit "$result"
}

# Each fact set FALSE alone (or a listed A+B combination), each rule checked alone. The mutant must break the
# rule EXPECT names, and every rule must break at least once, or the rule is vacuous.
tla_mutants() {
  local status=0 f p rule name rc want
  local -A rule_hit
  local hits assigns parts note
  echo "== mutants: each guard removed alone, each rule checked alone"
  for f in "${FACTS[@]}"; do
    [[ -n ${EXPECT[$f]:-} || " ${!EXPECT[*]} " == *"+$f "* || " ${!EXPECT[*]} " == *" $f+"* ]] || {
      echo "  $f has no EXPECT entry: every fact must be caught by a rule, alone or in a listed combination"
      status=2
    }
  done
  for f in "${!EXPECT[@]}"; do
    # "-" marks a fact that is not a guard (it switches an environment step on or off): nothing must catch it.
    [[ ${EXPECT[$f]} != - ]] || continue
    hits=()
    assigns=()
    IFS=+ read -ra parts <<<"$f"
    for p in "${parts[@]}"; do assigns+=("$p=FALSE"); done
    for rule in "${RULES[@]}" "${LIVE[@]}"; do
      name="mut-${f//+/-}-$rule"
      rc=0
      if [[ " ${LIVE[*]} " == *" $rule "* ]]; then
        run_tlc "$name" "TypeOK" "$rule" "${assigns[@]}" || rc=$?
      else
        run_tlc "$name" "TypeOK $rule" "" "${assigns[@]}" || rc=$?
      fi
      case "$rc" in
      0) ;;
      12 | 13)
        # Exit 12 counts only when TLC names this rule: a TypeOK break means the model is wrong.
        if [[ $rc == 13 || $(broken_rule "$work/$name.out") == "$rule" ]]; then
          hits+=("$rule")
          rule_hit[$rule]=1
        else
          echo "  $f / $rule: TLC broke $(broken_rule "$work/$name.out") instead"
          status=2
        fi
        ;;
      *)
        echo "  $f / $rule: TLC ERROR (exit $rc)"
        tail -5 "$work/$name.out" | sed 's/^/    /'
        status=2
        ;;
      esac
    done
    want=${EXPECT[$f]}
    if [[ " ${hits[*]} " == *" $want "* ]]; then
      printf '  %-34s caught by: %s\n' "$f=FALSE" "${hits[*]}"
    else
      printf '  %-34s NOT CAUGHT as expected (%s); broke: %s\n' "$f=FALSE" "$want" "${hits[*]:-nothing}"
      [[ $status == 2 ]] || status=1
    fi
  done
  for rule in "${RULES[@]}" "${LIVE[@]}"; do
    if [[ -z ${rule_hit[$rule]:-} ]]; then
      echo "  rule $rule never broke: it is vacuous"
      [[ $status == 2 ]] || status=1
    fi
  done
  for note in "${MUTANT_NOTES[@]+"${MUTANT_NOTES[@]}"}"; do echo "$note"; done
  [[ $status == 0 ]] && echo "== mutants: every guard is caught" || echo "== mutants: FAILED"
  if [[ $status == 0 && $stale == 1 ]]; then
    echo "== RESULT: STALE, UNVERIFIED (the mutants pass, but nobody has checked the model against the changed code)"
    exit 3
  fi
  exit "$status"
}

# Call after the facts are set. Runs the lock comparison, then the model or the mutants.
tla_main() {
  local f
  for f in "${FACTS[@]}"; do
    [[ ${fact[$f]:-} == TRUE || ${fact[$f]:-} == FALSE ]] || {
      echo "ERROR: fact $f is not set to TRUE or FALSE" >&2
      exit 2
    }
  done
  if [[ $hash_only == 0 ]]; then
    echo "== code facts (TRUE = guard present)"
    for f in "${FACTS[@]}"; do printf '  %-30s %s\n' "$f" "${fact[$f]}"; done
  fi
  tla_lock
  tla_fetch_jar
  cp "$here/model/$MODEL.tla" "$work/"
  if [[ $mutants == 1 ]]; then tla_mutants; else tla_check; fi
}

# Call first, before covered_block: parses the options, moves to the repo root, makes the work dir.
tla_init() {
  tla_parse_args "$@"
  repo=$(git -C "$here" rev-parse --show-toplevel)
  cd "$repo"
  work=$(mktemp -d "${TMPDIR:-/tmp}/$SKILL.XXXXXX")
  if [[ $keep == 1 ]]; then
    echo "work dir: $work"
  else
    trap 'rm -rf "$work"' EXIT
  fi
}
