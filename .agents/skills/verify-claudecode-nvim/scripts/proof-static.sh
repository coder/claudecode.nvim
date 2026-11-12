#!/usr/bin/env bash
# Static proofs of the verify-claudecode-nvim skill. They read the skill's own files and start no run, no agent-tty and no nvim,
# so `mise run check` runs them in CI:
#   no-bare-tools  vcn.sh has no jq or setsid command except through $JQ_BIN and $SETSID_BIN, not even as the default of a
#                  parameter expansion (reads the source, so it reaches every call site, which a run of launch does not)
#   doc-vars       a code block, or the inline code of a doc, that expands PORT, SID, NVIM_PID or NODE_DIR sets it with `VAR=$(` in
#                  the same block (or the same doc, for inline code), because a fresh shell has none of them. Prose that names
#                  an assignment sets nothing, and neither does a comment
#   no-source-run-env  no script of the skill, and no recipe in its docs, sources a run.env, except `load` in vcn.sh, which checks the
#                  state dir first (the callers read a value through `vcn.sh get`)
#   doc-get-exact  no recipe reads a path of the run (OUT, WORK, ...) through `$(... get NAME)`, which cuts a newline at the end
#   doc-recipe     the recipe that features/README.md and SKILL.md give for reading OUT and WORK returns both whole, for a
#                  VERIFY_OUT that ends in a newline (the case runs the documented line on a hand-made run.env)
# What the checks do not see: an indented code block (four spaces) and <pre>, a command that a variable or an eval of a built
# string holds, a source in a file that is not a shell script (.lua, .py, .mjs), and a fence in a quote or a list that markdown
# would not open. A source after `builtin`, `command` or `eval`, in backticks or quotes, and an inline span that a line break
# splits are seen. The docs must exist: a missing SKILL.md or features/*.md fails every case that reads them.
# Prints one `ok <case>` per case, or `FAIL <case>: <reason>` and exits 1, and ends with `CASES <n>`.
set -euo pipefail
V="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vcn.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cases=0
skill=$(dirname "$V")/..

fail() {
  echo "FAIL $1: $2" >&2
  exit 1
}

# need_docs <case>: the docs that the cases read must exist, or a rename leaves them nothing to check and every one passes.
need_docs() {
  [[ -f $skill/SKILL.md ]] || fail "$1" "$skill/SKILL.md is missing"
  compgen -G "$skill/features/*.md" >/dev/null || fail "$1" "$skill/features has no .md file"
}

# jq-resolved and setsid-resolved reach only the calls that a launch makes. This case reads the source: any word jq or setsid
# in a code line, except the two resolutions (`=$(bin jq)`, `=$(bin setsid)`), is a bare call and fails it. A default in a
# parameter expansion (`${JQ_BIN:-jq}`) names the tool as bare as a call does, and the word pattern skips it on purpose, because
# a name with a hyphen before it (`mise-jq`) is not a call.
word_re='(^|[^[:alnum:]_$-])(jq|setsid)($|[^[:alnum:]_-])'
default_re='\$\{[A-Za-z_][A-Za-z0-9_]*:?[-=+?](jq|setsid)\}'
strip_re='(JQ_BIN|SETSID_BIN)=\$\(bin (jq|setsid)\)'

# bare_hits <file>: the numbered code lines of the file that name jq or setsid as a bare call or as a default, except the two
# resolutions.
bare_hits() {
  grep -n '' "$1" | grep -vE '^[0-9]+:[[:space:]]*#' | sed -E "s/$strip_re//" | grep -E "$word_re|$default_re" || true
}

bare_tools_case() {
  local name=no-bare-tools hits site bare sites=0 form
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
  printf 'f() {\n  # jq here is a comment\n  x=$("${JQ_BIN:-jq}" -n 1)\n}\n' >"$TMP/bare-sample"
  [[ $(bare_hits "$TMP/bare-sample") == "3:"* ]] || fail "$name" "the scan of a file missed a default in a parameter expansion: $(bare_hits "$TMP/bare-sample")"
  printf 'f() {\n  x=$("$JQ_BIN" -n 1)\n  JQ_BIN=$(bin jq)\n}\n' >"$TMP/bare-sample"
  [[ -z $(bare_hits "$TMP/bare-sample") ]] || fail "$name" "the scan of a file took a call through \$JQ_BIN or the resolution for a bare call"
  hits=$(bare_hits "$V")
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
# names such a source is no source, but only a whole-line comment is dropped when the units that source are listed, so that
# `echo "x #1"; source run.env` is found. A span that a line break splits is one span.
code_units() {
  awk -v want="${2:-0}" 'function emit(text) { if ((sources(text) ? 1 : 0) == want) printf "%s", text }
    function run_len(t, ch,   n) { n = 0; while (substr(t, n + 1, 1) == ch) n++; return n }
    function sources(text,   n, i, rows, row) {
      n = split(text, rows, "\n")
      for (i = 1; i <= n; i++) {
        row = rows[i]
        sub(/^[ \t]*#.*/, "", row)
        if (!want) sub(/[ \t]#.*$/, "", row)
        if (row ~ /(^|[^A-Za-z0-9_.-])(source|\.|eval)[ \t]+[^;#]*run\.env/) return 1
      }
      return 0
    }
    function flush(   line, span) {
      line = para
      para = ""
      while (match(line, /`[^`]+`/)) {
        span = substr(line, RSTART + 1, RLENGTH - 2)
        if ((sources(span) ? 1 : 0) == want) spans = spans span "\n"
        line = substr(line, RSTART + RLENGTH)
      }
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
    (c == "`" || c == "~") && run_len(t, c) >= 3 { flush(); fenced = 1; fch = c; flen = run_len(t, c); next }
    t == "" { flush(); next }
    t ~ /^(#|[-*+][ \t]|[0-9]+[.)][ \t])/ { flush() }
    { para = (para == "" ? "" : para " ") $0 }
    END { if (fenced) { emit(block); print "%%unit%%" } flush(); printf "%s%%%%unit%%%%\n", spans }' "$1"
}

# The two patterns that decide whether a unit expands a variable and whether it sets it. units_missing and the self-test below
# both call these, so a change to one is a change to what the self-test checks.
var_uses_re() { printf '%s' '(\$\{?|\$\(\(([^)]*[^A-Za-z0-9_$])?)'"$1"'([^A-Za-z0-9_]|$)'; }
var_sets_re() { printf '%s' '(^|[^A-Za-z0-9_$])'"$1"'=\$\('; }

# strip_comments: drops a whole-line comment and a trailing comment. A comment is not run, so it neither uses nor sets a variable.
strip_comments() { sed -E 's/^[[:space:]]*#.*//; s/[[:space:]]#.*$//'; }

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
    unit=$(strip_comments <<<"$unit")
    if grep -qE "$uses_re" <<<"$unit" && ! grep -qE "$sets_re" <<<"$unit"; then
      return 0
    fi
    unit=""
  done < <(code_units "$1")
  return 1
}

doc_vars_case() {
  local name=doc-vars file var uses_re sets_re sample missing="" fence
  need_docs "$name"
  sample=$TMP/doc-vars-sample.md
  for var in PORT SID NVIM_PID NODE_DIR; do
    uses_re=$(var_uses_re "$var")
    sets_re=$(var_sets_re "$var")
    grep -qE "$uses_re" <<<"see \"\$$var.lock\" and \${$var}" || fail "$name" "the use pattern misses \$$var"
    grep -qE "$uses_re" <<<"n=\$(($var + 1))" || fail "$name" "the use pattern misses $var in an arithmetic expansion"
    grep -qE "$uses_re" <<<"n=\$(( x+$var ))" || fail "$name" "the use pattern misses $var after an operator in an arithmetic expansion"
    ! grep -qE "$uses_re" <<<"n=\$((X_$var + 1))" || fail "$name" "the use pattern matches a longer name in an arithmetic expansion"
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
    # A comment is not run: an assignment in one sets nothing, whole-line or trailing.
    printf '```bash\n# %s=$(x)\necho "$%s"\n```\n' "$var" "$var" >"$sample"
    units_missing "$sample" "$var" || fail "$name" "an assignment of $var in a whole-line comment set it"
    printf '```bash\necho "$%s" # %s=$(x)\n```\n' "$var" "$var" >"$sample"
    units_missing "$sample" "$var" || fail "$name" "an assignment of $var in a trailing comment set it"
    printf '```bash\necho "$%s" # %s is set above\n%s=$(x)\n```\n' "$var" "$var" "$var" >"$sample"
    ! units_missing "$sample" "$var" || fail "$name" "a comment on the line of a use hid a real assignment of $var"
    # An expansion in arithmetic is a use, and a span that a line break splits is one span.
    printf '```bash\necho $((%s + 1))\n```\n' "$var" >"$sample"
    units_missing "$sample" "$var" || fail "$name" "a use of $var in \$(( )) passed without an assignment"
    printf 'Run `echo\n"$%s"` and nothing else.\n' "$var" >"$sample"
    units_missing "$sample" "$var" || fail "$name" "a span split over two lines that expands $var passed"
    printf 'Set `%s=$(basename\n"$L")` first, then `echo "$%s"`.\n' "$var" "$var" >"$sample"
    ! units_missing "$sample" "$var" || fail "$name" "an assignment in a span split over two lines was not seen"
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
  local name=no-source-run-env file hits sample=$TMP/no-source.md n line
  need_docs "$name"
  # A source is a command: at the start of a line, after ; & | ( { ! a quote or a backtick, or after a keyword, `builtin`,
  # `command` or `eval`. The words in an echo are not.
  local src_re='(^|[;&|({!`'"'"'"]|(^|[[:space:]])(if|then|do|else|elif|while|until|builtin|command|eval)[[:space:]])[[:space:]]*(source|\.)[[:space:]]+[^;#`]*run\.env|(^|[;&|({![:space:]])eval[[:space:]]+[^;#]*run\.env'
  for line in 'source "$VCN_STATE/run.env"' '  . "$OUT/run.env"' 'if source "$S/run.env"; then' 'x && source run.env' 'then source "$S/run.env"' \
    '! source "$S/run.env"' 'while . ./run.env; do' 'f() { . "$S/run.env"; }' 'builtin source "$S/run.env"' 'command . "$S/run.env"' \
    "eval 'source \"\$S/run.env\"'" 'x=`source "$S/run.env"`' 'echo "x #1"; source "$S/run.env"' 'eval "$(cat "$S/run.env")"'; do
    grep -qE "$src_re" <<<"$line" || fail "$name" "the script pattern misses: $line"
  done
  for line in 'echo "a state dir was refused and its run.env not sourced"' 'echo "named through a . or .. part, its run.env"' 'echo "did not source its run.env"'; do
    ! grep -qE "$src_re" <<<"$line" || fail "$name" "the script pattern takes words of an echo for a source: $line"
  done
  printf 'Run:\n\n```bash\nsource "$VCN_STATE/run.env"\n```\n' >"$sample"
  [[ -n $(sourcing_units "$sample") ]] || fail "$name" "a fenced block that sources a run.env was not found"
  printf 'Run:\n\n   ~~~\n. "$OUT/run.env"\n   ~~~\n' >"$sample"
  [[ -n $(sourcing_units "$sample") ]] || fail "$name" "an indented ~~~ block that sources a run.env was not found"
  printf 'Run `source "$VCN_STATE/run.env"; echo`.\n' >"$sample"
  [[ -n $(sourcing_units "$sample") ]] || fail "$name" "an inline span that sources a run.env was not found"
  printf 'Run `builtin source\n"$VCN_STATE/run.env"` first.\n' >"$sample"
  [[ -n $(sourcing_units "$sample") ]] || fail "$name" "a span split over two lines that sources a run.env was not found"
  printf '```bash\necho "x #1"; source "$VCN_STATE/run.env"\n```\n' >"$sample"
  [[ -n $(sourcing_units "$sample") ]] || fail "$name" "a source after a # inside a string was not found"
  printf '```bash\neval "$(cat "$VCN_STATE/run.env")"\n```\n' >"$sample"
  [[ -n $(sourcing_units "$sample") ]] || fail "$name" "an eval of run.env was not found"
  printf 'Do not `source` `$VCN_STATE/run.env`.\n\n```bash\n# source run.env\necho x\n```\n' >"$sample"
  [[ -z $(sourcing_units "$sample") ]] || fail "$name" "prose or a comment that names a source was taken for one"
  rm -f -- "$sample"
  for file in "$skill"/SKILL.md "$skill"/features/*.md; do
    hits=$(sourcing_units "$file")
    [[ -z $hits ]] || fail "$name" "${file#"$skill"/} has a recipe that sources a run.env: $(tr '\n' ' ' <<<"$hits")"
  done
  for file in "$skill"/scripts/*.sh; do
    # vcn.sh is the one place that sources it, and this script holds the samples of the patterns.
    [[ ${file##*/} != vcn.sh && ${file##*/} != proof-static.sh ]] || continue
    hits=$(grep -nE "$src_re" "$file" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
    [[ -z $hits ]] || fail "$name" "${file#"$skill"/} sources a run.env: $(tr '\n' ' ' <<<"$hits")"
  done
  n=$(grep -E "$src_re" "$V" | grep -cvE '^[[:space:]]*#' || true)
  ((n == 1)) || fail "$name" "vcn.sh sources a run.env in $n places, wanted one (load)"
  echo "ok $name: only load in vcn.sh sources a run.env; no script and no recipe does"
  cases=$((cases + 1))
}

# `$(...)` cuts the newlines at the end of its output, and VERIFY_OUT can end in one. A recipe that reads a path of the run through
# `$($V get OUT)` writes its next file to the twin of the evidence dir, which is a different path in the same checked parent. The
# docs read a path with `get -z`. A value that is no path (PORT, SID) can use a substitution.
doc_get_exact_case() {
  local name=doc-get-exact file hits line
  local sub_re='\$\([^)]*get[[:space:]]+(OUT|WORK|VCN_STATE|ATT_HOME|NVIM_SOCK|NVIM_BIN|NODE_DIR|ATT_BIN|ATT_SOCK|JQ_BIN)([^A-Za-z0-9_]|$)'
  need_docs "$name"
  for line in 'OUT=$($V get OUT)' 'x="$(vcn.sh get WORK)"' 'echo "$($V get VCN_STATE)"' 'WORK=$($V get WORK)'; do
    grep -qE "$sub_re" <<<"$line" || fail "$name" "the pattern misses: $line"
  done
  for line in 'IFS= read -r -d "" OUT < <($V get -z OUT)' 'PORT=$($V get PORT)' 'SID=$($V get SID)' 'x=$($V get OUTPUT)'; do
    ! grep -qE "$sub_re" <<<"$line" || fail "$name" "the pattern takes this line for a path read through a substitution: $line"
  done
  for file in "$skill"/SKILL.md "$skill"/features/*.md; do
    hits=$(code_units "$file" | grep -nE "$sub_re" || true)
    [[ -z $hits ]] || fail "$name" "${file#"$skill"/} reads a path through \$(... get ...), which cuts a newline at its end: $(tr '\n' ' ' <<<"$hits")"
  done
  echo "ok $name: no recipe reads OUT, WORK or another path of the run through a command substitution"
  cases=$((cases + 1))
}

# The recipe of the docs, run as it is written. VERIFY_OUT can end in a newline (and WORK follows it), a command substitution would
# cut it, and the next file that a caller writes would go to another path. The state dir and the run.env are hand-made, in the
# resolved path of this proof's temp dir. `get` starts no run.
doc_recipe_case() {
  local name=doc-recipe file recipe dir out_want work_want rtmp repo got
  need_docs "$name"
  rtmp=$(realpath -- "$TMP")
  repo=$(realpath -- "$skill/../../..")
  dir=$(mktemp -d "$rtmp/vcn.XXXXXX")
  out_want=$'/tmp/a b OUT=/x\t\'q"\nline2\n'
  work_want=$dir/work$'\n'
  printf 'VCN_STATE=%q\nOUT=%q\nWORK=%q\nNODE_DIR=/usr/bin\nJQ_BIN=/usr/bin/jq\n' "$dir" "$out_want" "$work_want" >"$dir/run.env"
  printf '%s' "$out_want" >"$TMP/out.want"
  printf '%s' "$work_want" >"$TMP/work.want"
  got=$(cd "$repo" && env VCN_STATE="$dir" V="$V" bash -c 'OUT=$($V get OUT); printf %s "$OUT" >"$1"' _ "$TMP/out.got" 2>&1) ||
    fail "$name" "the control, a command substitution, failed: $got"
  ! cmp -s "$TMP/out.got" "$TMP/out.want" || fail "$name" "the control read OUT whole through a command substitution, so the case would not see a cut"
  for file in "$skill"/SKILL.md "$skill"/features/README.md; do
    recipe=$(code_units "$file" | grep -F 'getz()' || true)
    [[ -n $recipe && $(grep -c '' <<<"$recipe") == 1 ]] || fail "$name" "${file#"$skill"/} must hold one inline recipe with getz(), found: ${recipe:-none}"
    rm -f "$TMP/out.got" "$TMP/work.got"
    got=$(cd "$repo" && env VCN_STATE="$dir" V="$V" bash -c "$recipe"$'\n''printf %s "$OUT" >"$1"; printf %s "$WORK" >"$2"' _ "$TMP/out.got" "$TMP/work.got" 2>&1) ||
      fail "$name" "the recipe of ${file#"$skill"/} failed: $got"
    cmp -s "$TMP/out.got" "$TMP/out.want" || fail "$name" "the recipe of ${file#"$skill"/} read OUT as '$(cat "$TMP/out.got")', not the whole value"
    cmp -s "$TMP/work.got" "$TMP/work.want" || fail "$name" "the recipe of ${file#"$skill"/} read WORK as '$(cat "$TMP/work.got")', not the whole value"
  done
  echo "ok $name: the recipe of SKILL.md and of features/README.md read OUT and WORK whole, with a newline at their end"
  cases=$((cases + 1))
}

bare_tools_case
doc_vars_case
no_source_case
doc_get_exact_case
doc_recipe_case
echo "CASES $cases"
