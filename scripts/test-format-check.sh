#!/usr/bin/env bash
# Checks that `mise run format-check` writes nothing, and that `mise run format` still writes. It adds untracked probe
# files to the working tree (unformatted Markdown, Lua and shell, and a Markdown file whose name starts with a dash) and
# removes them on exit. The check must fail, name each probe, and change nothing in the working tree: the test compares
# git's status (with untracked files and the ignored entries) and the hash of every changed or untracked file before and
# after the check. It sees a new ignored file or folder, and it does not see a change inside an ignored folder that
# exists already. (The old task, `treefmt --ci` with the write flags, rewrote the probes.) `mise run format` on the
# probes must write the formatted text. The check must pass on the formatted probes, and it must fail on a shell probe
# that shfmt keeps and shellcheck rejects. In a vendored copy of the repo (a folder with no .git inside another git
# repository, made in a temporary folder) the check must pass on a formatted probe and fail on an unformatted one, so
# treefmt must take the vendored folder as its tree root. After a version bump of a formatter, treefmt must format a
# file again: the test swaps in a second "version" of stylua (the real one with another quote style) and runs treefmt
# with a private cache folder.
# A second run of the test in the same checkout stops with exit 2 at once, because the probes exist. The check runs on
# the whole tree, so the test needs a formatted tree: its third run expects exit 0.
# Usage: scripts/test-format-check.sh
# Exit 0: the checks hold. Exit 1: one failed. Exit 2: a probe file is there already.
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

md=format-check-probe.md
lua=format-check-probe.lua
sh=format-check-probe.sh
dash=-format-check-probe.md
bump=format-check-bump-probe.lua

scratch=$(mktemp -d)
made=()
cleanup() {
  rm -rf "$scratch"
  for file in "${made[@]:-}"; do
    if [ -n "$file" ]; then
      rm -f -- "$file"
    fi
  done
}
trap cleanup EXIT

# `noclobber` makes the redirection fail when the file exists, so only one run of the test can own a probe, even when
# two runs start together.
for file in "$md" "$lua" "$sh" "$dash" "$bump"; do
  if ! (
    set -o noclobber
    : >"$file"
  ) 2>/dev/null; then
    echo "test-format-check: $file exists already (another run of this test, or a run that was killed), so the test" \
      "cannot use it" >&2
    exit 2
  fi
  made+=("$file")
done

fail() {
  echo "test-format-check: $1" >&2
  exit 1
}

# What each probe holds before the formatters run, and after. Prettier rewrites the bullet, stylua adds spaces, and
# shfmt -i 2 turns the indent of four spaces into two.
unformatted_md='# Probe\n\n\n*   unformatted\n'
formatted_md='# Probe\n\n- unformatted\n'
unformatted_lua='local   probe  =  {1,2}\n'
formatted_lua='local probe = { 1, 2 }\n'
unformatted_sh='#!/bin/sh\nprobe_fn() {\n    echo probe\n}\nprobe_fn\n'
formatted_sh='#!/bin/sh\nprobe_fn() {\n  echo probe\n}\nprobe_fn\n'

# Writes the probes with the text $1 (md and dash), $2 (lua) and $3 (sh).
write_probes() {
  printf '%b' "$1" >"$md"
  printf '%b' "$1" >"$dash"
  printf '%b' "$2" >"$lua"
  printf '%b' "$3" >"$sh"
}

# Prints the state of the working tree: git's status, with untracked files and ignored entries (an ignored folder is one
# entry), and the hash of each file that status lists as changed or untracked.
tree_state() {
  git status --porcelain -uall --ignored=matching
  git ls-files -z --modified --others --exclude-standard |
    xargs -0 -r sh -c 'for file; do if [ -f "$file" ]; then git hash-object -- "$file"; fi; done' sh
}

# Runs the check. Sets `status`, and leaves the output in "$scratch/output". It fails when the check changed the tree.
run_check() {
  tree_state >"$scratch/state-before"
  status=0
  mise run format-check >"$scratch/output" 2>&1 || status=$?
  tree_state >"$scratch/state-after"
  if ! cmp -s "$scratch/state-before" "$scratch/state-after"; then
    fail "format-check changed the working tree: $(diff "$scratch/state-before" "$scratch/state-after" | head -n 6)"
  fi
}

# Fails unless "$1" holds the text that printf makes from "$2".
expect_text() {
  printf '%b' "$2" >"$scratch/expected"
  cmp -s -- "$1" "$scratch/expected" || fail "$1 does not hold the text that $3"
}

# 1. Four unformatted probes: the check fails, names each probe, and changes nothing.
write_probes "$unformatted_md" "$unformatted_lua" "$unformatted_sh"
run_check
[ "$status" -ne 0 ] || fail "format-check passed with unformatted probes"
for file in "$md" "$lua" "$sh" "$dash"; do
  grep -qF -- "$file" "$scratch/output" || fail "format-check does not name $file"
done

# 2. `mise run format` formats the probes (and only them).
if ! mise run format -- "$md" "$lua" "$sh" "./$dash" >"$scratch/output" 2>&1; then
  fail "mise run format failed: $(tail -n 5 "$scratch/output")"
fi
expect_text "$md" "$formatted_md" "prettier writes"
expect_text "$dash" "$formatted_md" "prettier writes in a file whose name starts with a dash"
expect_text "$lua" "$formatted_lua" "stylua writes"
expect_text "$sh" "$formatted_sh" "shfmt -i 2 writes"

# 3. The formatted probes pass the check, and the check changes nothing.
run_check
[ "$status" -eq 0 ] || fail "format-check failed the formatted probes: $(tail -n 5 "$scratch/output")"

# 4. shfmt keeps this file, and shellcheck fails on it (SC2086): the check fails, and the tree stays.
write_probes "$formatted_md" "$formatted_lua" '#!/bin/sh\necho $1\n'
run_check
[ "$status" -ne 0 ] || fail "format-check passed a file that shellcheck fails"
grep -qF -- "$sh" "$scratch/output" || fail "format-check does not name $sh for the shellcheck failure"

# 5. A vendored copy: the folder has no .git, and a git repository holds it. treefmt.toml's tree-root-file makes the
# folder the tree root, so treefmt finds the wrapper, and the excludes apply (the lock file below is unformatted on
# purpose, and an exclude of treefmt.toml skips it). The folder is in a temporary folder, with mise's tools on PATH.
tool_path=$(mise exec -- printenv PATH 2>/dev/null | tail -n 1)
vendor=$scratch/outer/vendor/copy
mkdir -p "$vendor/scripts" "$vendor/fixtures/probe"
cp treefmt.toml "$vendor/treefmt.toml"
cp scripts/treefmt-formatter.sh "$vendor/scripts/treefmt-formatter.sh"
printf '{"a":1,   "b":2}\n' >"$vendor/fixtures/probe/lazy-lock.json"
git init -q "$scratch/outer"

# Runs the check in the vendored copy. Sets `status`, and leaves the output in "$scratch/output".
run_vendored() {
  status=0
  (cd "$vendor" && FORMAT_CHECK=1 PATH="$tool_path" treefmt --ci) >"$scratch/output" 2>&1 || status=$?
}

printf '%b' "$formatted_md" >"$vendor/probe.md"
run_vendored
[ "$status" -eq 0 ] || fail "format-check failed in a vendored copy: $(tail -n 5 "$scratch/output")"
printf '%b' "$unformatted_md" >"$vendor/probe.md"
run_vendored
[ "$status" -ne 0 ] || fail "format-check passed an unformatted probe in a vendored copy"
grep -qF -- "probe.md" "$scratch/output" || fail "format-check does not name probe.md in a vendored copy"

# 6. A version bump of a formatter. treefmt keys its cache on the command of a formatter, and for stylua that command is
# the wrapper, so a bump of stylua would not make treefmt format a file again. The two "versions" are the real stylua,
# and the real stylua with another quote style. The first leaves the probe as it is, and the second rewrites it. The
# runs use plain treefmt under mise's environment, with a private cache folder.
real_stylua=$(mise which stylua)
mkdir -p "$scratch/stylua-1" "$scratch/stylua-2"
printf '#!/bin/sh\nexec "%s" "$@"\n' "$real_stylua" >"$scratch/stylua-1/stylua"
printf '#!/bin/sh\nexec "%s" --quote-style ForceSingle "$@"\n' "$real_stylua" >"$scratch/stylua-2/stylua"
chmod +x "$scratch/stylua-1/stylua" "$scratch/stylua-2/stylua"

# Runs treefmt on the bump probe with the stylua in the folder $1 first on PATH.
run_stylua_version() {
  if ! XDG_CACHE_HOME="$scratch/cache" mise exec -- sh -c 'PATH=$1:$PATH exec treefmt "$2"' sh "$1" "$bump" \
    >"$scratch/output" 2>&1; then
    fail "treefmt failed with $1: $(tail -n 5 "$scratch/output")"
  fi
}

printf 'local s = "x"\n' >"$bump"
run_stylua_version "$scratch/stylua-1"
expect_text "$bump" 'local s = "x"\n' "the first stylua version leaves"
run_stylua_version "$scratch/stylua-2"
expect_text "$bump" "local s = 'x'\\n" "the second stylua version writes (treefmt used its cache after a version bump)"

echo "test-format-check: ok"
