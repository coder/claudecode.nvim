#!/usr/bin/env bash
# Checks that `mise run format-check` writes nothing, and that `mise run format` still writes. It adds untracked probe
# files to the working tree (unformatted Markdown, Lua and shell, and one more of each kind whose name starts with a
# dash) and removes them on exit. The check must fail, name each probe, and change nothing in the working tree: the test
# compares git's status (with untracked files and the ignored entries) and the hash of every changed or untracked file
# before and after the check. It sees a new ignored file or folder, and it does not see a change to an ignored file or
# folder that exists already. (The old task, `treefmt --ci` with the write flags, rewrote the probes.) `mise run format`
# on the probes must write the formatted text. The check must pass on the formatted probes, and it must fail on a shell
# probe that shfmt keeps and shellcheck rejects, also when its name starts with a dash. The dash names are there
# because a tool reads such a name as an option when no `--` comes before the file names: prettier skips the file,
# stylua reads `-V...` as `--version` and skips every file of its batch, shfmt stops with an error when the name is the
# first of its file list (it takes a dash name that comes after a plain name as a file), and shellcheck reads `-P...` as
# a source path and lints nothing of that name. In a vendored copy of the repo (a folder with no .git inside
# another git repository, made in a temporary folder) the check must pass on a formatted probe and fail on an
# unformatted one, so treefmt must take the vendored folder as its tree root. After a version bump of a formatter,
# treefmt must format a file again, with its cache on, under mise's environment and outside it, and a second run with
# the same version must find the file in the cache (it formats 0 files): the test swaps in a second "version" of stylua
# (the real one with another quote style) and runs treefmt with a private cache folder. In a checkout whose path holds
# a `"`, a `$HOME` or a backtick, the check must still write nothing and fail on an unformatted file. In a checkout
# whose path holds a colon, which splits the PATH entry of the stand-ins, the check must stop with exit 2 and write
# nothing, and so it must in a checkout that lacks the stand-in of one tool.
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
dashlua=-Vformat-check-probe.lua
dashsh=-format-check-probe.sh
dashlint=-Pformat-check-probe.sh
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
for file in "$md" "$lua" "$sh" "$dash" "$dashlua" "$dashsh" "$dashlint" "$bump"; do
  if ! (
    set -o noclobber
    : >"$file"
  ) 2>/dev/null; then
    echo "test-format-check: $file exists already (another run of this test, or a run that was killed), so the test" \
      "cannot use it. Remove the probes of a killed run with: rm -- <name>" >&2
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
clean_sh='#!/bin/sh\necho "$1"\n'
lint_sh='#!/bin/sh\necho $1\n'

# Writes the probes with the text $1 (md and dash), $2 (lua and dashlua) and $3 (sh and dashsh). The probe that the
# linter must reject, dashlint, holds a clean script until a step changes it. (A file that is still empty fails the
# linter, because it has no shebang, so each shell probe gets its text here before any check runs.)
write_probes() {
  printf '%b' "$1" >"$md"
  printf '%b' "$1" >"$dash"
  printf '%b' "$2" >"$lua"
  printf '%b' "$2" >"$dashlua"
  printf '%b' "$3" >"$sh"
  printf '%b' "$3" >"$dashsh"
  printf '%b' "$clean_sh" >"$dashlint"
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

# Fails unless the output of the check names the file "$1": a line must hold the name, and not only a longer name that
# ends with it (the name of the dash probe ends with the name of the plain probe).
expect_named() {
  escaped=$(printf '%s' "$1" | sed 's/[.[\*^$]/\\&/g')
  grep -qE -- "(^|[^-A-Za-z0-9_.])$escaped" "$scratch/output" || fail "format-check does not name $1"
}

# Fails unless "$1" holds the text that printf makes from "$2".
expect_text() {
  printf '%b' "$2" >"$scratch/expected"
  cmp -s -- "$1" "$scratch/expected" || fail "$1 does not hold the text that $3"
}

# 1. Six unformatted probes: the check fails, names each probe, and changes nothing.
write_probes "$unformatted_md" "$unformatted_lua" "$unformatted_sh"
run_check
[ "$status" -ne 0 ] || fail "format-check passed with unformatted probes"
for file in "$md" "$dash" "$lua" "$dashlua" "$sh" "$dashsh"; do
  expect_named "$file"
done

# 2. `mise run format` formats the probes (and only them). The dash names come first: shfmt stops reading options at the
# first name that is no option, so a dash name behind a plain name would not show a missing `--`.
if ! mise run format -- "./$dashsh" "./$dashlua" "./$dash" "$md" "$lua" "$sh" >"$scratch/output" 2>&1; then
  fail "mise run format failed: $(tail -n 5 "$scratch/output")"
fi
expect_text "$md" "$formatted_md" "prettier writes"
expect_text "$dash" "$formatted_md" "prettier writes in a file whose name starts with a dash"
expect_text "$lua" "$formatted_lua" "stylua writes"
expect_text "$dashlua" "$formatted_lua" "stylua writes in a file whose name starts with a dash"
expect_text "$sh" "$formatted_sh" "shfmt -i 2 writes"
expect_text "$dashsh" "$formatted_sh" "shfmt -i 2 writes in a file whose name starts with a dash"

# 3. The formatted probes pass the check, and the check changes nothing.
run_check
[ "$status" -eq 0 ] || fail "format-check failed the formatted probes: $(tail -n 5 "$scratch/output")"

# 4. shfmt keeps this file, and shellcheck fails on it (SC2086): the check fails, and the tree stays. Then the same for
# a file whose name starts with -P, which shellcheck reads as a source path when no `--` comes before the file names.
# That second part cannot show a missing `--` for shellcheck by itself: with `-format-check-probe.sh` in the tree, a
# run without `--` fails every time ("Unknown format ormat-check-probe.sh"), so the test fails earlier, at step 2.
write_probes "$formatted_md" "$formatted_lua" "$lint_sh"
run_check
[ "$status" -ne 0 ] || fail "format-check passed a file that shellcheck fails"
expect_named "$sh"
write_probes "$formatted_md" "$formatted_lua" "$formatted_sh"
printf '%b' "$lint_sh" >"$dashlint"
run_check
[ "$status" -ne 0 ] || fail "format-check passed a file whose name starts with a dash and that shellcheck fails"
expect_named "$dashlint"

# 5. A vendored copy: the folder has no .git, and a git repository holds it. treefmt.toml's tree-root-file makes the
# folder the tree root, so the excludes apply (the lock file below is unformatted on purpose, and an exclude of
# treefmt.toml skips it). The folder is in a temporary folder, with the stand-ins first on PATH and mise's tools after.
tool_path=$(mise exec -- printenv PATH 2>/dev/null | tail -n 1)
vendor=$scratch/outer/vendor/copy
mkdir -p "$vendor/scripts" "$vendor/fixtures/probe"
cp treefmt.toml "$vendor/treefmt.toml"
cp -R scripts/format-check-bin "$vendor/scripts/format-check-bin"
printf '{"a":1,   "b":2}\n' >"$vendor/fixtures/probe/lazy-lock.json"
git init -q "$scratch/outer"

# Runs the check in the vendored copy. Sets `status`, and leaves the output in "$scratch/output".
run_vendored() {
  status=0
  (cd "$vendor" && PATH="$vendor/scripts/format-check-bin:$tool_path" treefmt --ci) >"$scratch/output" 2>&1 || status=$?
}

printf '%b' "$formatted_md" >"$vendor/probe.md"
run_vendored
[ "$status" -eq 0 ] || fail "format-check failed in a vendored copy: $(tail -n 5 "$scratch/output")"
printf '%b' "$unformatted_md" >"$vendor/probe.md"
run_vendored
[ "$status" -ne 0 ] || fail "format-check passed an unformatted probe in a vendored copy"
grep -qF -- "probe.md" "$scratch/output" || fail "format-check does not name probe.md in a vendored copy"

# 6. A version bump of a formatter. treefmt keys its cache on the command of each formatter, so a bump of stylua must
# make treefmt format a file again, and an unchanged stylua must find the file in the cache. The two "versions" are the
# real stylua, and the real stylua with another quote style. treefmt runs in two ways, each with its own private cache
# folder: under mise's environment (`mise exec`), and outside it (a bare environment with the tools on PATH). In each
# way the test runs version 1 (it formats the probe, which stays as it is), version 1 again (the cache has the probe:
# treefmt formats 0 files), and version 2 (it rewrites the probe).
real_stylua=$(mise which stylua)
mkdir -p "$scratch/stylua-1" "$scratch/stylua-2"
printf '#!/bin/sh\nexec "%s" "$@"\n' "$real_stylua" >"$scratch/stylua-1/stylua"
printf '#!/bin/sh\nexec "%s" --quote-style ForceSingle "$@"\n' "$real_stylua" >"$scratch/stylua-2/stylua"
chmod +x "$scratch/stylua-1/stylua" "$scratch/stylua-2/stylua"

# Runs treefmt on the bump probe, in the way $1 (inside or outside), with the stylua in the folder $2 first on PATH.
run_stylua_version() {
  status=0
  if [ "$1" = inside ]; then
    XDG_CACHE_HOME="$scratch/cache-$1" mise exec -- sh -c 'PATH=$1:$PATH exec treefmt "$2"' sh "$2" "$bump" \
      >"$scratch/output" 2>&1 || status=$?
  else
    env -i HOME="${HOME:-/}" PATH="$2:$tool_path" XDG_CACHE_HOME="$scratch/cache-$1" treefmt "$bump" \
      >"$scratch/output" 2>&1 || status=$?
  fi
  [ "$status" -eq 0 ] || fail "treefmt failed ($1 mise, $2): $(tail -n 5 "$scratch/output")"
}

for way in inside outside; do
  printf 'local s = "x"\n' >"$bump"
  run_stylua_version "$way" "$scratch/stylua-1"
  expect_text "$bump" 'local s = "x"\n' "the first stylua version leaves ($way mise)"
  run_stylua_version "$way" "$scratch/stylua-1"
  grep -q "formatted 0 files" "$scratch/output" ||
    fail "treefmt did not find the probe in its cache on a second run ($way mise): $(tail -n 2 "$scratch/output")"
  run_stylua_version "$way" "$scratch/stylua-2"
  expect_text "$bump" "local s = 'x'\\n" \
    "the second stylua version writes ($way mise: treefmt used its cache after a version bump)"
done

# 7. Checkouts with an odd path. The task reads the path of the checkout from $MISE_CONFIG_ROOT. A template
# (`{{config_root}}`) pastes the path into the shell text instead: a quote then makes a syntax error, and `$HOME` or a
# backtick changes the folder name, so treefmt finds no stand-in and runs the real tools, which write. A colon splits
# the PATH entry in the same way, so the task must stop with exit 2 before treefmt runs. Each checkout is a small copy
# (the task, the tool settings and the stand-ins) with one Markdown probe. mise trusts it through a private state
# folder, because MISE_TRUSTED_CONFIG_PATHS cannot hold a colon. Then a copy without the stand-in of one tool: the task
# must stop with exit 2 and name that tool, so a missing symlink cannot let the real tool write.

# Makes the folder $1: a small copy of the checkout that mise trusts.
make_copy() {
  mkdir -p "$1/scripts"
  cp mise.toml mise.lock treefmt.toml .stylua.toml "$1/"
  cp -R scripts/format-check-bin "$1/scripts/format-check-bin"
  (cd "$1" && MISE_STATE_DIR="$scratch/mise-state" mise trust "$1/mise.toml") >"$scratch/output" 2>&1 ||
    fail "mise did not trust the copy in $1: $(tail -n 3 "$scratch/output")"
}

copy_hashes() {
  (cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r file; do
    printf '%s ' "$file"
    cksum <"$file"
  done)
}

# Runs the check in the folder $1. Sets `status`, and leaves the output in "$scratch/output".
run_in_copy() {
  status=0
  (cd "$1" && MISE_STATE_DIR="$scratch/mise-state" mise run format-check) >"$scratch/output" 2>&1 || status=$?
}

for name in 'q"uote' 'd$HOME' 'b`true`b' 'c:olon'; do
  copy=$scratch/paths/$name
  make_copy "$copy"

  printf '%b' "$formatted_md" >"$copy/probe.md"
  run_in_copy "$copy"
  if [ "$name" = 'c:olon' ]; then
    [ "$status" -eq 2 ] || fail "format-check exited $status on a formatted probe in $copy (expected 2)"
  else
    [ "$status" -eq 0 ] ||
      fail "format-check exited $status on a formatted probe in $copy: $(tail -n 3 "$scratch/output")"
  fi

  printf '%b' "$unformatted_md" >"$copy/probe.md"
  copy_hashes "$copy" >"$scratch/copy-before"
  run_in_copy "$copy"
  copy_hashes "$copy" >"$scratch/copy-after"
  cmp -s "$scratch/copy-before" "$scratch/copy-after" ||
    fail "format-check changed the files in $copy: $(diff "$scratch/copy-before" "$scratch/copy-after" | head -n 4)"
  if [ "$name" = 'c:olon' ]; then
    [ "$status" -eq 2 ] || fail "format-check exited $status on an unformatted probe in $copy (expected 2)"
    grep -qF "does not resolve to the stand-in" "$scratch/output" ||
      fail "format-check does not say that the stand-ins are missing in $copy: $(tail -n 3 "$scratch/output")"
  else
    [ "$status" -eq 1 ] ||
      fail "format-check exited $status on an unformatted probe in $copy (expected 1): $(tail -n 3 "$scratch/output")"
    expect_named probe.md
  fi
done

for tool in prettier stylua shfmt; do
  copy=$scratch/paths/no-$tool
  make_copy "$copy"
  rm -- "$copy/scripts/format-check-bin/$tool"
  printf '%b' "$formatted_md" >"$copy/probe.md"
  run_in_copy "$copy"
  [ "$status" -eq 2 ] || fail "format-check exited $status in a copy without the stand-in of $tool (expected 2)"
  grep -qF "$tool does not resolve to the stand-in" "$scratch/output" ||
    fail "format-check does not name $tool in a copy without its stand-in: $(tail -n 3 "$scratch/output")"
done

echo "test-format-check: ok"
