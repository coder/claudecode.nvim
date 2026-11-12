#!/usr/bin/env bash
# Static proofs of the verify-claudecode-nvim skill. They read the skill's own files and start no run, no agent-tty and no nvim,
# so `mise run check` runs them in CI:
#   no-bare-tools  vcn.sh has no jq or setsid command except through $JQ_BIN and $SETSID_BIN, not even as the default of a
#                  parameter expansion (reads the source, so it reaches every call site, which a run of launch does not)
#   doc-vars       a code block, or the inline code of a doc, that expands PORT, SID, NVIM_PID or NODE_DIR sets it in the same
#                  block (or the same doc, for inline code), because a fresh shell has none of them. Prose that names an
#                  assignment sets nothing, and neither does a comment
#   no-source-run-env  no script of the skill, and no recipe in its docs, sources a run.env, except `load` in vcn.sh, which checks the
#                  state dir first (the callers read a value through `vcn.sh get`)
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

# jq-resolved and setsid-resolved reach only the calls that a launch makes. This case reads the source: any word jq or setsid
# in a code line, except the two resolutions (`=$(bin jq)`, `=$(bin setsid)`), is a bare call and fails it. A default in a
# parameter expansion (`${JQ_BIN:-jq}`) names the tool as bare as a call does, and the word pattern skips it on purpose, because
# a name with a hyphen before it (`mise-jq`) is not a call.
bare_tools_case() {
  local name=no-bare-tools hits site bare sites=0 word_re='(^|[^[:alnum:]_$-])(jq|setsid)($|[^[:alnum:]_-])' form
  local default_re='\$\{[A-Za-z_][A-Za-z0-9_]*:?[-=+?](jq|setsid)\}'
  local strip_re='(JQ_BIN|SETSID_BIN)=\$\(bin (jq|setsid)\)'
  local jq_ref='"$JQ_BIN"' setsid_ref='"$SETSID_BIN"'
  while IFS= read -r site; do
    for form in "" /usr/bin/ ./; do
      bare=${site//"$jq_ref"/${form}jq}
      bare=${bare//"$setsid_ref"/${form}setsid}
      grep -qE "$word_re" <<<"$bare" || fail "$name" "the pattern misses this call written as a bare or path-qualified call: $bare"
    done
    sites=$((sites + 1))
  done < <(grep -E '"\$(JQ_BIN|SETSID_BIN)"' "$V" | grep -v 'env_line JQ_BIN')
  ((sites > 0)) || fail "$name" "vcn.sh has no call through \$JQ_BIN or \$SETSID_BIN to check the pattern against"
  sed -E "s/$strip_re//" <<<'jq --version; JQ_BIN=$(bin jq)' | grep -qE "$word_re" || fail "$name" "a bare jq on a line that ends with the resolution would pass"
  for bare in '"${JQ_BIN:-jq}" -n 1' 'x=${SETSID_BIN=setsid}' '${JQ_BIN-jq}'; do
    grep -qE "$default_re" <<<"$bare" || fail "$name" "the default pattern misses $bare"
  done
  ! grep -qE "$default_re" <<<'"$JQ_BIN" -n "${JQ_BIN:-x}"' || fail "$name" "the default pattern matches a call through \$JQ_BIN"
  hits=$(grep -n '' "$V" | grep -vE '^[0-9]+:[[:space:]]*#' | sed -E "s/$strip_re//" | grep -E "$word_re|$default_re" || true)
  [[ -z $hits ]] || fail "$name" "vcn.sh runs a bare or path-qualified jq or setsid: $(tr '\n' ' ' <<<"$hits")"
  echo "ok $name: vcn.sh runs jq and setsid only through \$JQ_BIN and \$SETSID_BIN"
  cases=$((cases + 1))
}

# A caller used to get PORT, SID, NVIM_PID and NODE_DIR from `source run.env`. A recipe that expands one of them must set it with
# `VAR=$(`, because a fresh shell has none. A recipe is a fenced code block (checked on its own) or an inline code span (all of
# them in a doc are checked together, because a bullet cites one assignment for the steps below it). Prose outside the backticks
# is not a recipe: it can name an assignment that no recipe runs.
# A fence is three or more backticks or tildes with any indent, closed by a line of the same character, at least as long.
# code_units <file> [1]: prints each fenced block, then the inline code spans outside the blocks, each unit ended by a line that
# holds only %%unit%%. A block or a span that sources a run.env sets every variable of the run by itself, so it is left out: it
# needs no `VAR=$(`, and it gives none to the other recipes. With a 1, it prints only those units that source. A comment that
# names such a source is no source.
code_units() {
  awk -v want="${2:-0}" 'function emit(text) { if ((sources(text) ? 1 : 0) == want) printf "%s", text }
    function run_len(t, ch,   n) { n = 0; while (substr(t, n + 1, 1) == ch) n++; return n }
    function sources(text,   n, i, rows, row) {
      n = split(text, rows, "\n")
      for (i = 1; i <= n; i++) {
        row = rows[i]
        sub(/^[ \t]*#.*/, "", row)
        sub(/[ \t]#.*$/, "", row)
        if (row ~ /(^|[^A-Za-z0-9_.-])(source|\.)[ \t]+[^;#]*run\.env/) return 1
      }
      return 0
    }
    { t = $0; sub(/^[ \t]+/, "", t) }
    fenced {
      n = run_len(t, fch)
      if (n >= flen && substr(t, n + 1) ~ /^[ \t]*$/) {
        emit(block)
        print "%%unit%%"
        block = ""
        fenced = 0
        next
      }
      block = block $0 "\n"
      next
    }
    { c = substr(t, 1, 1) }
    (c == "`" || c == "~") && run_len(t, c) >= 3 { fenced = 1; fch = c; flen = run_len(t, c); next }
    { line = $0
      while (match(line, /`[^`]+`/)) {
        span = substr(line, RSTART + 1, RLENGTH - 2)
        if ((sources(span) ? 1 : 0) == want) spans = spans span "\n"
        line = substr(line, RSTART + RLENGTH)
      } }
    END { if (fenced) { emit(block); print "%%unit%%" } printf "%s%%%%unit%%%%\n", spans }' "$1"
}

# The two patterns that decide whether a unit expands a variable and whether it sets it. units_missing and the self-test below
# both call these, so a change to one is a change to what the self-test checks.
var_uses_re() { printf '%s' '\$\{?'"$1"'([^A-Za-z0-9_]|$)'; }
var_sets_re() { printf '%s' '(^|[^A-Za-z0-9_$])'"$1"'=\$\('; }

# units_missing <file> <var>: succeeds when a unit of the file expands <var> and does not set it.
units_missing() {
  local line unit="" uses_re sets_re
  uses_re=$(var_uses_re "$2")
  sets_re=$(var_sets_re "$2")
  while IFS= read -r line; do
    if [[ $line != "%%unit%%" ]]; then
      unit+=$line$'\n'
      continue
    fi
    if grep -qE "$uses_re" <<<"$unit" && ! grep -qE "$sets_re" <<<"$unit"; then
      return 0
    fi
    unit=""
  done < <(code_units "$1")
  return 1
}

doc_vars_case() {
  local name=doc-vars skill file var uses_re sets_re sample missing="" fence
  skill=$(dirname "$V")/..
  sample=$TMP/doc-vars-sample.md
  for var in PORT SID NVIM_PID NODE_DIR; do
    uses_re=$(var_uses_re "$var")
    sets_re=$(var_sets_re "$var")
    grep -qE "$uses_re" <<<"see \"\$$var.lock\" and \${$var}" || fail "$name" "the use pattern misses \$$var"
    ! grep -qE "$uses_re" <<<"echo $var=\$CLAUDE_CODE_SSE_$var" || fail "$name" "the use pattern matches a longer name"
    grep -qE "$sets_re" <<<"$var=\$(basename \"\$L\"/*.lock .lock)" || fail "$name" "the set pattern misses an assignment of $var"
    grep -qE "$sets_re" <<<"export $var=\$(x)" || fail "$name" "the set pattern misses an exported assignment of $var"
    ! grep -qE "$sets_re" <<<"echo $var=\$CLAUDE_CODE_SSE_$var" || fail "$name" "the set pattern matches text that sets nothing"
    ! grep -qE "$sets_re" <<<"X_$var=\$(x)" || fail "$name" "the set pattern matches an assignment of a longer name"
    ! grep -qE "$sets_re" <<<"$var=literal" || fail "$name" "the set pattern matches an assignment that runs nothing"
    # Prose that names the assignment must not satisfy a block that uses the variable, and a block that sets it must.
    printf 'Set it with %s=$(x) before.\n\n```bash\necho "$%s"\n```\n' "$var" "$var" >"$sample"
    units_missing "$sample" "$var" || fail "$name" "a block that expands $var and sets it only in prose passed"
    printf 'Prose.\n\n```bash\n%s=$(x)\necho "$%s"\n```\n' "$var" "$var" >"$sample"
    ! units_missing "$sample" "$var" || fail "$name" "a block that sets $var before it expands it was flagged"
    printf '```bash\n%s=literal\nX_%s=$(x)\necho "$%s"\n```\n' "$var" "$var" "$var" >"$sample"
    units_missing "$sample" "$var" || fail "$name" "a block that sets $var to a literal, or sets a longer name, passed as a block that sets $var"
    # Every spelling of a fence is a block: indented, tildes, and four backticks around a block that holds three.
    for fence in '```' '   ```bash' '~~~' '  ~~~sh' '````'; do
      printf 'Prose.\n\n%s\necho "$%s"\n%s\n' "$fence" "$var" "${fence//[^\`~]/}" >"$sample"
      units_missing "$sample" "$var" || fail "$name" "a block opened by '$fence' that expands $var and sets nothing passed"
      printf 'Prose.\n\n%s\n%s=$(x)\necho "$%s"\n%s\n' "$fence" "$var" "$var" "${fence//[^\`~]/}" >"$sample"
      ! units_missing "$sample" "$var" || fail "$name" "a block opened by '$fence' that sets $var was flagged"
    done
    printf 'Prose.\n\n````\n```\necho "$%s"\n```\n````\n' "$var" >"$sample"
    units_missing "$sample" "$var" || fail "$name" "three backticks inside a four-backtick block closed it, so the use of $var passed"
    printf 'Set `%s=$(x)` first, then `echo "$%s"`.\n' "$var" "$var" >"$sample"
    ! units_missing "$sample" "$var" || fail "$name" "inline code that sets $var for inline code that expands it was flagged"
    printf 'Run `source "$VCN_STATE/run.env"; echo "$%s"`.\n\n```bash\n. "$VCN_STATE/run.env"\necho "$%s"\n```\n' "$var" "$var" >"$sample"
    ! units_missing "$sample" "$var" || fail "$name" "a recipe that sources a run.env was flagged for $var"
    printf 'Run `echo "$%s"`, as in `grep run.env x`.\n' "$var" >"$sample"
    units_missing "$sample" "$var" || fail "$name" "a recipe that only names a run.env passed for $var"
    printf '```bash\n# source "$VCN_STATE/run.env" first\necho "$%s"\n```\n' "$var" >"$sample"
    units_missing "$sample" "$var" || fail "$name" "a comment that names a source of run.env exempted a block that expands $var"
    printf '```bash\necho "$%s" # source run.env\n```\n' "$var" >"$sample"
    units_missing "$sample" "$var" || fail "$name" "a trailing comment that names a source of run.env exempted a block that expands $var"
    printf 'Run `source "$VCN_STATE/run.env"` first, then `echo "$%s"`.\n' "$var" >"$sample"
    units_missing "$sample" "$var" || fail "$name" "a source in one inline recipe set $var for another recipe"
    for file in "$skill"/SKILL.md "$skill"/features/*.md; do
      ! units_missing "$file" "$var" || missing+=" ${file#"$skill"/}:$var"
    done
  done
  rm -f -- "$sample"
  [[ -z $missing ]] || fail "$name" "a recipe expands a variable that it does not set:$missing"
  echo "ok $name: every recipe that expands PORT, SID, NVIM_PID or NODE_DIR sets it"
  cases=$((cases + 1))
}

# sourcing_units <file>: the units of the file that source a run.env.
sourcing_units() { code_units "$1" 1 | grep -v '^%%unit%%$' || true; }

# The callers of a run moved to `vcn.sh get` and `vcn.sh dashboard`. A source of run.env in the skill's own scripts runs every
# line of the file with no check of the state dir, and one in a doc teaches a caller to do it. Only `load` in vcn.sh sources it.
no_source_case() {
  local name=no-source-run-env skill file hits sample=$TMP/no-source.md src_re='(^|[;&|({])[[:space:]]*(source|\.)[[:space:]]+[^;#`]*run\.env' n
  skill=$(dirname "$V")/..
  printf 'Run:\n\n```bash\nsource "$VCN_STATE/run.env"\n```\n' >"$sample"
  [[ -n $(sourcing_units "$sample") ]] || fail "$name" "a fenced block that sources a run.env was not found"
  printf 'Run:\n\n   ~~~\n. "$OUT/run.env"\n   ~~~\n' >"$sample"
  [[ -n $(sourcing_units "$sample") ]] || fail "$name" "an indented ~~~ block that sources a run.env was not found"
  printf 'Run `source "$VCN_STATE/run.env"; echo`.\n' >"$sample"
  [[ -n $(sourcing_units "$sample") ]] || fail "$name" "an inline span that sources a run.env was not found"
  printf 'Do not `source` `$VCN_STATE/run.env`.\n\n```bash\n# source run.env\necho x\n```\n' >"$sample"
  [[ -z $(sourcing_units "$sample") ]] || fail "$name" "prose or a comment that names a source was taken for one"
  rm -f -- "$sample"
  for file in "$skill"/SKILL.md "$skill"/features/*.md; do
    hits=$(sourcing_units "$file")
    [[ -z $hits ]] || fail "$name" "${file#"$skill"/} has a recipe that sources a run.env: $(tr '\n' ' ' <<<"$hits")"
  done
  for file in "$skill"/scripts/*.sh; do
    [[ ${file##*/} != vcn.sh ]] || continue
    hits=$(grep -nE "$src_re" "$file" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
    [[ -z $hits ]] || fail "$name" "${file#"$skill"/} sources a run.env: $(tr '\n' ' ' <<<"$hits")"
  done
  n=$(grep -E "$src_re" "$V" | grep -cvE '^[[:space:]]*#' || true)
  ((n == 1)) || fail "$name" "vcn.sh sources a run.env in $n places, wanted one (load)"
  echo "ok $name: only load in vcn.sh sources a run.env; no script and no recipe does"
  cases=$((cases + 1))
}

bare_tools_case
doc_vars_case
no_source_case
echo "CASES $cases"
