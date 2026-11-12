#!/usr/bin/env bash
# Verifies the formatting of the working tree and writes nothing to it (`mise run format-check`).
# `treefmt --ci` has no dry run: it formats the files in place and then fails because it changed them, so a failed
# check leaves the tree rewritten. This script copies the files that treefmt's git walker formats twice, runs treefmt
# on one copy, and compares the two copies. That walker formats the regular files that git lists (tracked, and
# untracked but not ignored). It skips a symlink, a folder (a nested repository or a submodule) and a tracked file that
# was deleted, so the copy leaves those out. The copy is one tar pipe, not one cp for each file, because a process
# start is slow on a loaded host.
# The copies live in the git directory, so that a formatter looks for its configuration in the same parent folders as
# it does for the tree itself. For a linked worktree the git directory is the one inside the main checkout, so the
# parent folders are those of the main checkout.
# Usage: scripts/format-check.sh
# Exit 0: no file would change and no formatter failed. Exit 1: a file would change, a formatter failed, or the files
# could not be copied or compared.
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

if ! git_dir=$(git rev-parse --absolute-git-dir 2>/dev/null); then
  echo "format-check: $root is no git checkout, so there is no list of files to check. Run it in a clone." >&2
  exit 1
fi
scratch=$(mktemp -d "$git_dir/format-check.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/before" "$scratch/after"

files=()
while IFS= read -r -d '' file; do
  if [ -f "$file" ] && [ ! -L "$file" ]; then
    files+=("$file")
  fi
done < <(git ls-files -z --cached --others --exclude-standard --deduplicate)
if ! printf '%s\0' "${files[@]}" | tar --null -T - -cf - | tar -xf - -C "$scratch/before"; then
  echo "format-check: cannot copy the files of the tree (see the tar error above)" >&2
  exit 1
fi
cp -R "$scratch/before/." "$scratch/after/"

# The copy has no .git, so treefmt walks the files. Its config file is one of the copied files. A linter (shellcheck,
# for example) can make treefmt fail without changing a file, and that failure fails this check too.
formatter_status=0
(cd "$scratch/after" && treefmt --no-cache --walk filesystem --tree-root .) || formatter_status=$?

diff_status=0
(cd "$scratch" && diff -ru before after >&2) || diff_status=$?
if [ "$diff_status" -eq 1 ]; then
  echo "format-check: the diff above is what treefmt would change (before is the tree, after is formatted). Run mise run format to write it." >&2
  exit 1
elif [ "$diff_status" -ne 0 ]; then
  echo "format-check: diff failed with status $diff_status" >&2
  exit 1
fi
exit "$formatter_status"
