#!/usr/bin/env bash
# Static proofs of the verify-claudecode-nvim skill. They read the skill's own files and start no run, no agent-tty and no nvim,
# so `mise run check` runs them in CI. Each `ok` line says only what the scanner sees:
#   no-bare-tools  no code line of vcn.sh names jq or setsid as a bare call, except the two resolutions, and none as the default of
#                  a parameter expansion (reads the source, so it reaches every call site, which a run of launch does not)
#   doc-vars       a code block, or the inline code of a doc taken together, that expands PORT, SID, NVIM_PID or NODE_DIR with a $
#                  (also in a $(( )) that holds no parenthesis before it) sets it with `VAR=$(` in the same block (or the same doc,
#                  for inline code), because a fresh shell has none of them. Prose that names an assignment sets nothing, and neither
#                  does a comment
#   no-source-run-env  no script of the skill, and no recipe in its docs, has a source of a run.env that the scanner sees, except
#                  `load` in vcn.sh, which checks the state dir first (the callers read a value through `vcn.sh get`)
#   doc-get-exact  no recipe has a `get [-z] <path name>` (OUT, WORK, ...) in a `$(...)` that is still open there (inner ones too),
#                  because a substitution cuts a newline at the end of the value, and a `<(...)` with such a get is only
#                  `IFS= read -r -d '' NAME < <(COMMAND get -z <path name>)`: one simple command before `get`, nothing after the
#                  name, and the `read` right before the `<(`
#   doc-recipe     the recipe that features/README.md and SKILL.md give for reading OUT and WORK returns both whole, for a
#                  VERIFY_OUT that ends in a newline and holds a backslash, and stops the call with status 1 and a message when `get`
#                  refuses (the case runs the documented line on a hand-made run.env, with no V of its own)
# What the checks do not see: an indented code block (four spaces) and <pre>, a command that a variable or an eval of a built
# string holds, a source in a file that is not a shell script (.lua, .py, .mjs), a fence in a quote or a list that markdown would
# not open, a `get` of a path that is in no `$(...)` and no `<(...)` (a pipe or a file that feeds `read`), a `get` whose name is a
# variable (`get -z "$1"`, as the helper of the docs has), and six shapes that no code block and no code line of a script has: in
# a code block, a command substitution or a `<(...)` whose `get` is on the next line, a backtick substitution of `get`, a source
# or `.` whose run.env is on the next line after a backslash (in a code block or a script), a quoted command word (`"source"
# run.env`), a run.env named through BASH_ENV, and a use of PORT, SID, NVIM_PID or NODE_DIR without a $ (`let`, `(( ))`,
# `${#PORT}`). A source after `builtin`, `command` or `eval`, in backticks, or in a quoted string that starts with it, and an
# inline span that a line break splits are seen. The docs must exist: a missing SKILL.md or features/*.md fails every case that
# reads them.
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
  echo "ok $name: no code line of vcn.sh names jq or setsid as a bare call or a default, except the two resolutions"
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
  echo "ok $name: every code block, and the inline code of each doc taken together, that expands PORT, SID, NVIM_PID or NODE_DIR with a \$ sets it"
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
  echo "ok $name: no source of a run.env that the scanner sees, except load in vcn.sh"
  cases=$((cases + 1))
}

# `$(...)` cuts the newlines at the end of its output, and VERIFY_OUT can end in one. A recipe that has a `get` of a path of the run
# in a `$(...)` writes its next file to the twin of the evidence dir, which is a different path in the same checked parent. A `read`
# without `IFS=` trims a newline at the end of the value, and one without `-d ''` stops at the first newline, and a path can hold
# one. The docs read a path with `IFS= read -r -d ''` on `get -z`. A value that is no path (PORT, SID) can use a substitution.
# path_reads follows quotes and parentheses on one line at a time. It flags a `get [-z] <path name>` (the name can be in quotes) in a
# `$(...)` that is still open there, also after an inner `$(...)` or a quoted `)`. A `get` in a `<(...)` passes only as
# `IFS= read -r -d '' NAME < <(COMMAND get -z <path name>)`: one simple command (none of ; & | ( ) < >) before `get`, nothing after the
# name, and the `read` right before the `<(`. Every other `<(...)` with such a get is flagged: another command or a group in it, a
# `{ ...; }` or a `while` loop that it feeds, no `-z`, no `IFS=`, no `-r`, no `-d ''`. A get in no `$(...)` and no `<(...)` is not
# checked (a pipe or a file that feeds `read`).
path_names='OUT|WORK|VCN_STATE|ATT_HOME|NVIM_SOCK|NVIM_BIN|NODE_DIR|ATT_BIN|ATT_SOCK|JQ_BIN'
path_reads_awk=$(
  cat <<'AWK'
function bad(s,   n, i, c, two, sp, dq, j, rest, len) {
  n = length(s); sp = 0; dq = 0
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (c == "\\") { i++; continue }
    if (dq == 0 && c == sq) {
      j = index(substr(s, i + 1), sq)
      if (j == 0) return 0
      i += j; continue
    }
    if (c == dqc) { dq = 1 - dq; continue }
    two = substr(s, i, 2)
    if (two == "$(") { sp++; T[sp] = "$("; D[sp] = dq; dq = 0; i++; continue }
    if (dq == 0 && two == "<(") { sp++; T[sp] = "<("; D[sp] = dq; O[sp] = i; i++; continue }
    if (dq == 0 && c == "(") { sp++; T[sp] = "("; D[sp] = dq; continue }
    if (dq == 0 && c == ")") { if (sp > 0) { dq = D[sp]; sp-- } continue }
    if (c == "g" && (i == 1 || substr(s, i - 1, 1) !~ /[A-Za-z0-9_.\/-]/)) {
      rest = substr(s, i)
      if (match(rest, getre) && substr(rest, RLENGTH + 1, 1) !~ /[A-Za-z0-9_]/) {
        len = RLENGTH
        if (flagged(s, i, len, rest, sp)) return 1
        i += len - 1
      }
    }
  }
  return 0
}
function flagged(s, i, len, rest, sp,   k, pre, before) {
  for (k = 1; k <= sp; k++) if (T[k] == "$(") return 1
  for (k = sp; k >= 1; k--) if (T[k] == "<(") break
  if (k == 0) return 0
  pre = substr(s, O[k] + 2, i - O[k] - 2)
  if (pre !~ /^[ \t]*[^;&|()<>]*[ \t]$/) return 1
  if (rest !~ /^get[ \t]+-z[ \t]/) return 1
  if (substr(s, i + len) !~ /^[ \t]*\)/) return 1
  before = substr(s, 1, O[k] - 1)
  if (before !~ readre) return 1
  return 0
}
BEGIN {
  sq = "\047"; dqc = "\042"
  getre = "^get[ \t]+(-z[ \t]+)?[" dqc sq "]?(" names ")[" dqc sq "]?"
  readre = "(^|[ \t;&|{(])IFS=[ \t]+read[ \t]+-r[ \t]+-d[ \t]*(" sq sq "|" dqc dqc ")[ \t]+[^ \t;&|<>(){}]+[ \t]*<[ \t]*$"
}
{ if (bad($0)) print NR ":" $0 }
AWK
)

# path_reads: the numbered lines on stdin that read a path of the run so that the end of it is lost.
path_reads() { awk -v names="$path_names" "$path_reads_awk"; }

# doc_get_exact_case: the first list holds a line for each shape that the scanner must flag, the second the lines that it must pass
# (the last of them are real forms of this skill's own scripts). A line that starts with ## names a shape and is skipped.
doc_get_exact_case() {
  local name=doc-get-exact file hits line
  need_docs "$name"
  while IFS= read -r line; do
    [[ -z $line || $line == '##'* ]] && continue
    [[ -n $(path_reads <<<"$line") ]] || fail "$name" "the scanner misses: $line"
  done <<'SAMPLES'
## a get of a path in a command substitution, with or without -z, with the name in quotes
OUT=$($V get OUT)
x="$(vcn.sh get WORK)"
echo "$($V get VCN_STATE)"
WORK=$($V get WORK)
x=$($V get -z OUT)
OUT=$($V get -z "OUT")
x=$("$V" get 'WORK')
## the substitution is still open at the get: an inner substitution or group, a quoted or escaped ) or ', a double-quoted substitution, a read in it
OUT=$(cd "$(dirname "$V")"; "$V" get -z OUT)
x=$(f $(g) | "$V" get -z OUT)
OUT=$(echo ")"; "$V" get -z OUT)
OUT=$(echo ')'; "$V" get -z OUT)
OUT=$(echo \); "$V" get -z OUT)
OUT=$( (echo a); "$V" get -z OUT)
echo "$(date) b)"; IFS= read -r OUT < <("$V" get -z OUT)
echo "x $("$V" get -z OUT)"
x=$(IFS= read -r -d '' OUT < <("$V" get -z OUT))
## a <( with more than one command, or with something after the get
IFS= read -r OUT < <(cd "$d" && "$V" get -z OUT)
IFS= read -r -d '' OUT < <(true; "$V" get -z OUT)
IFS= read -r -d '' OUT < <(cd "$d"; "$V" get -z OUT)
IFS= read -r -d '' OUT < <("$V" get -z OUT | tr -d x)
IFS= read -r -d '' OUT < <( ("$V" get -z OUT) )
IFS= read -r -d '' OUT < <(x=$(date) "$V" get -z OUT)
IFS= read -r -d '' OUT < <(env A=b "$V" get -z OUT 2>/dev/null)
## a <( that does not feed IFS= read -r -d '' NAME directly: a group, a while loop, two reads, no IFS=, no -r, no -d '', another -d
{ IFS= read -r OUT; } < <("$V" get -z OUT)
{ IFS= read -r -d '' OUT; } < <("$V" get -z OUT)
while IFS= read -r OUT; do :; done < <("$V" get -z OUT)
read -r -d "" scratch <<< x; IFS= read -r OUT < <($V get -z OUT)
read -r -d '' OUT < <($V get -z OUT)
read -d '' OUT < <($V get -z OUT)
IFS= read -d '' OUT < <($V get -z OUT)
IFS= read -r OUT < <($V get -z OUT)
IFS= read -r OUT < <($V get -z "OUT")
IFS= read -r -d x OUT < <($V get -z OUT)
IFS= read -rd '' OUT < <($V get -z OUT)
## a <( without -z (get ends the value with a newline)
IFS= read -r -d '' X < <($V get OUT)
SAMPLES
  while IFS= read -r line; do
    [[ -z $line || $line == '##'* ]] && continue
    [[ -z $(path_reads <<<"$line") ]] || fail "$name" "the scanner flags a line that loses no newline: $line"
  done <<'SAMPLES'
## the allowed form, with the name in quotes or not, and the helper of the docs (its name is "$1")
IFS= read -r -d "" OUT < <($V get -z OUT)
IFS= read -r -d '' OUT < <("$V" get -z OUT)
IFS= read -r -d "" OUT < <($V get -z "OUT")
IFS= read -r -d "" "$1" < <("$V" get -z "$1")
getz() { IFS= read -r -d '' "$1" < <("$V" get -z "$1") || { echo "vcn.sh get $1 failed" >&2; return 1; }; }; getz OUT && getz WORK || exit 1
## an earlier substitution or read that is closed before the get must not hide the allowed form
PORT=$("$V" get PORT); IFS= read -r -d '' OUT < <("$V" get -z OUT)
echo "$(date)"; IFS= read -r -d '' OUT < <("$V" get -z OUT)
x=$(date) y=$(date); IFS= read -r -d '' OUT < <("$V" get -z OUT)
read -r scratch <<< x; IFS= read -r -d "" OUT < <($V get -z OUT)
## a get of a name that is no path, a longer name, a word that ends in get, a quoted )
PORT=$($V get PORT)
SID=$($V get SID)
x=$($V get OUTPUT)
read -r PORT < <($V get PORT)
x=$(echo ")"; "$V" get PORT)
x=$(forget OUT)
## forms of this skill's own scripts: one simple command, such as env with variables, before the get
IFS= read -r -d "" got < <(env PATH="$good_path" VCN_STATE="$dir" "$V" get -z OUT) || fail "$name" "x"
IFS= read -r -d '' OUT < <(env -i "$V" get -z "OUT")
SAMPLES
  for file in "$skill"/SKILL.md "$skill"/features/*.md; do
    hits=$(code_units "$file" | path_reads)
    [[ -z $hits ]] || fail "$name" "${file#"$skill"/} reads a path in a way that loses the end of it: $(tr '\n' ' ' <<<"$hits")"
  done
  echo "ok $name: no recipe has a get of OUT, WORK or another path in a \$(...), and a <(...) with one is only IFS= read -r -d '' NAME < <(COMMAND get -z NAME)"
  cases=$((cases + 1))
}

# The recipe of the docs, run as it is written, from the repo root, with no V in the environment (the line sets its own). VERIFY_OUT
# can end in a newline (and WORK follows it) and can hold a backslash, a command substitution would cut the newline, a `read` without
# -r would eat the backslash, and the next file that a caller writes would go to another path. A `get` that refuses must stop the
# call with a message and the status 1, so that no later command runs: a state dir that load refuses, a run.env without OUT (the second getz must not hide it),
# and one without WORK. The state dirs and the run.env files are hand-made, in a dir with a colon in its name (a path can hold one, and
# a case that packs a dir and a name into one string splits it there), under the resolved path of this proof's temp dir. `get` starts no run.
doc_recipe_case() {
  local name=doc-recipe file recipe dir no_out no_work loose out_want work_want rtmp repo got bad rc i bad_dirs bad_names
  need_docs "$name"
  rtmp=$(realpath -- "$TMP")/a:b
  mkdir -m 700 -- "$rtmp"
  repo=$(realpath -- "$skill/../../..")
  dir=$(mktemp -d "$rtmp/vcn.XXXXXX")
  no_out=$(mktemp -d "$rtmp/vcn.XXXXXX")
  no_work=$(mktemp -d "$rtmp/vcn.XXXXXX")
  loose=$(mktemp -d "$rtmp/vcn.XXXXXX")
  out_want=$'/tmp/a b OUT=/x\t\'q"\nback\\slash \\\\ end\\n\n'
  work_want=$dir/work$'\n'
  for bad in "$dir" "$no_out" "$no_work" "$loose"; do
    printf 'VCN_STATE=%q\nNODE_DIR=/usr/bin\nJQ_BIN=/usr/bin/jq\n' "$bad" >"$bad/run.env"
  done
  bad_dirs=("$loose" "$no_out" "$no_work")
  bad_names=(OUT OUT WORK)
  printf 'OUT=%q\nWORK=%q\n' "$out_want" "$work_want" >>"$dir/run.env"
  printf 'WORK=%q\n' "$work_want" >>"$no_out/run.env"
  printf 'OUT=%q\n' "$out_want" >>"$no_work/run.env"
  printf 'OUT=%q\nWORK=%q\n' "$out_want" "$work_want" >>"$loose/run.env"
  chmod 770 "$loose"
  printf '%s' "$out_want" >"$TMP/out.want"
  printf '%s' "$work_want" >"$TMP/work.want"
  got=$(cd "$repo" && env VCN_STATE="$dir" V="$V" bash -c 'OUT=$($V get OUT); printf %s "$OUT" >"$1"' _ "$TMP/out.got" 2>&1) ||
    fail "$name" "the control, a command substitution, failed: $got"
  ! cmp -s "$TMP/out.got" "$TMP/out.want" || fail "$name" "the control read OUT whole through a command substitution, so the case would not see a cut"
  for file in "$skill"/SKILL.md "$skill"/features/README.md; do
    recipe=$(code_units "$file" | grep -F 'getz()' || true)
    [[ -n $recipe && $(grep -c '' <<<"$recipe") == 1 ]] || fail "$name" "${file#"$skill"/} must hold one inline recipe with getz(), found: ${recipe:-none}"
    rm -f "$TMP/out.got" "$TMP/work.got"
    got=$(cd "$repo" && env -u V VCN_STATE="$dir" bash -c "$recipe"$'\n''printf %s "$OUT" >"$1"; printf %s "$WORK" >"$2"' _ "$TMP/out.got" "$TMP/work.got" 2>&1) ||
      fail "$name" "the recipe of ${file#"$skill"/} failed: $got"
    cmp -s "$TMP/out.got" "$TMP/out.want" || fail "$name" "the recipe of ${file#"$skill"/} read OUT as '$(cat "$TMP/out.got")', not the whole value"
    cmp -s "$TMP/work.got" "$TMP/work.want" || fail "$name" "the recipe of ${file#"$skill"/} read WORK as '$(cat "$TMP/work.got")', not the whole value"
    for i in "${!bad_dirs[@]}"; do
      rc=0
      got=$(cd "$repo" && env -u V VCN_STATE="${bad_dirs[i]}" bash -c "$recipe"$'\n''echo after-recipe' 2>&1) || rc=$?
      ((rc == 1)) || fail "$name" "the recipe of ${file#"$skill"/} exited $rc, wanted 1, after a refused get (${bad_names[i]} of ${bad_dirs[i]}): $got"
      ! grep -qF after-recipe <<<"$got" || fail "$name" "a command after the recipe of ${file#"$skill"/} still ran after a refused get (${bad_names[i]} of ${bad_dirs[i]})"
      grep -qF "vcn.sh get ${bad_names[i]} failed" <<<"$got" || fail "$name" "the recipe of ${file#"$skill"/} did not say 'vcn.sh get ${bad_names[i]} failed' after a refused get: $got"
    done
  done
  echo "ok $name: the recipe of SKILL.md and of features/README.md reads OUT and WORK whole (newline, backslash) and stops the call with status 1 when get refuses"
  cases=$((cases + 1))
}

bare_tools_case
doc_vars_case
no_source_case
doc_get_exact_case
doc_recipe_case
echo "CASES $cases"
