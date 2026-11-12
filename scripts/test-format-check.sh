#!/usr/bin/env bash
# Checks that `mise run format-check` writes nothing. On a tree with an unformatted file it must fail, name the file,
# and leave the file as it was. On a formatted file it must pass and leave the file as it was. A linter failure
# (shellcheck on a shell file that shfmt leaves as it is) must fail it too. A tracked file that is deleted from the
# working tree must not fail it. A symlink that does not resolve, and a nested git repository, must not fail it
# either, because treefmt's git walker skips both. A Prettier configuration in a folder above the checkout must apply,
# as it does for `treefmt --ci` in the tree.
# The test adds one or two untracked files to the working tree and removes them on exit. It also moves the tracked file
# LICENSE out of the tree for one check and moves it back on exit. The last checks run a copy of format-check.sh in a
# throwaway git repository in a temporary folder, with mise's treefmt and Prettier on PATH.
# Usage: scripts/test-format-check.sh
# Exit 0: the checks hold. Exit 1: one failed. Exit 2: a probe file is there already, or LICENSE is not in the tree.
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

probe=format-check-probe.md
lint_probe=format-check-probe.sh
# A tracked file that no formatter touches.
tracked_probe=LICENSE
for file in "$probe" "$lint_probe"; do
  if [ -e "$file" ]; then
    echo "test-format-check: $file exists already, so the test cannot use it" >&2
    exit 2
  fi
done
if [ ! -f "$tracked_probe" ] || ! git ls-files --error-unmatch -- "$tracked_probe" >/dev/null 2>&1; then
  echo "test-format-check: $tracked_probe is not a tracked file in the tree, so the test cannot move it" >&2
  exit 2
fi

scratch=$(mktemp -d)
# Moves the tracked file back first. If that fails, the file stays in $scratch and the test keeps the folder.
cleanup() {
  if [ -e "$scratch/$tracked_probe" ]; then
    mv -- "$scratch/$tracked_probe" "$tracked_probe" || {
      echo "test-format-check: could not move $tracked_probe back, it is in $scratch" >&2
      exit 1
    }
  fi
  rm -rf "$scratch" "$probe" "$lint_probe"
}
trap cleanup EXIT

fail() {
  echo "test-format-check: $1" >&2
  exit 1
}

# Runs the check with the probe file $1 in the tree. Sets `status`, and leaves the output in "$scratch/output".
run_check() {
  cp "$1" "$scratch/before"
  status=0
  mise run format-check >"$scratch/output" 2>&1 || status=$?
  cmp -s "$1" "$scratch/before" || fail "format-check wrote to $1"
}

# Prettier rewrites this one: it wants one blank line and a dash.
printf '# Probe\n\n\n*   unformatted\n' >"$probe"
run_check "$probe"
[ "$status" -ne 0 ] || fail "format-check passed an unformatted file"
grep -q "$probe" "$scratch/output" || fail "format-check does not name $probe"

# The same file, formatted: the check passes.
printf '# Probe\n\n- unformatted\n' >"$probe"
run_check "$probe"
[ "$status" -eq 0 ] || fail "format-check failed a formatted file: $(tail -n 5 "$scratch/output")"

# shfmt keeps this file, and shellcheck fails on it (SC2086): the check fails, and the file stays.
rm "$probe"
printf '#!/bin/sh\necho $1\n' >"$lint_probe"
run_check "$lint_probe"
[ "$status" -ne 0 ] || fail "format-check passed a file that shellcheck fails"
rm "$lint_probe"

# git still lists a tracked file that is deleted from the working tree, and tar cannot read it: the check skips it.
mv -- "$tracked_probe" "$scratch/$tracked_probe"
status=0
mise run format-check >"$scratch/output" 2>&1 || status=$?
[ ! -e "$tracked_probe" ] || fail "format-check wrote $tracked_probe"
[ "$status" -eq 0 ] || fail "format-check failed with $tracked_probe deleted: $(tail -n 5 "$scratch/output")"

# The last three checks use a throwaway repository, so they add nothing to the working tree. Its treefmt.toml formats
# Markdown with Prettier, and probe.md is formatted by Prettier's defaults. It is not committed: git lists it as an
# untracked file that is not ignored, as it lists the probe files above.
tool_path=$(mise exec -- printenv PATH 2>/dev/null | tail -n 1)
repo=$scratch/parent/repo
mkdir -p "$repo/scripts"
cp scripts/format-check.sh "$repo/scripts/format-check.sh"
printf '[formatter.prettier]\ncommand = "prettier"\noptions = ["--write"]\nincludes = ["*.md"]\n' >"$repo/treefmt.toml"
printf '# Probe\n\nThis paragraph is longer than thirty characters.\n' >"$repo/probe.md"
git init -q "$repo"

# Runs the copy of format-check.sh in the throwaway repository. Sets `status`, and leaves the output in "$scratch/output".
run_throwaway() {
  cp "$repo/probe.md" "$scratch/before"
  status=0
  (cd "$repo" && PATH="$tool_path" bash scripts/format-check.sh) >"$scratch/output" 2>&1 || status=$?
  cmp -s "$repo/probe.md" "$scratch/before" || fail "format-check wrote to probe.md in the throwaway repository"
}

run_throwaway
[ "$status" -eq 0 ] || fail "format-check failed the formatted throwaway repository: $(tail -n 5 "$scratch/output")"

# treefmt's git walker skips a symlink. The copy of the files has none, so a link that does not resolve cannot fail diff.
ln -s no-such-file.md "$repo/dangling.md"
run_throwaway
[ "$status" -eq 0 ] || fail "format-check failed with a symlink that does not resolve: $(tail -n 5 "$scratch/output")"
rm "$repo/dangling.md"

# The git walker skips a nested repository (and a submodule) as one folder, so its unformatted file does not count.
git init -q "$repo/nested"
printf '# Nested\n\n\n*   unformatted\n' >"$repo/nested/n.md"
run_throwaway
[ "$status" -eq 0 ] || fail "format-check failed with a nested repository: $(tail -n 5 "$scratch/output")"
rm -rf "$repo/nested"

# The copy lives in the git directory of the repository, so Prettier finds this configuration above it, as it does
# for the repository itself. With it, Prettier wraps the paragraph of probe.md, and the check fails and names the file.
printf '{"proseWrap": "always", "printWidth": 30}\n' >"$scratch/parent/.prettierrc"
run_throwaway
[ "$status" -ne 0 ] || fail "format-check ignored a Prettier configuration above the repository"
grep -q "probe.md" "$scratch/output" || fail "format-check does not name probe.md for a Prettier configuration above the repository"

echo "test-format-check: ok"
