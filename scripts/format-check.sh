#!/usr/bin/env bash
# Verifies the formatting of the working tree and writes nothing to it (`mise run format-check`).
# `treefmt --ci` has no dry run: it formats the files in place and then fails because it changed them, so a failed
# check leaves the tree rewritten. This script copies the files that git knows (tracked, and untracked but not ignored)
# twice, runs treefmt on one copy, and compares the two copies. The copy is one tar pipe, not one cp for each file,
# because a process start is slow on a loaded host.
# Usage: scripts/format-check.sh
# Exit 0: no file would change and no formatter failed. Exit 1: a file would change, or a formatter failed.
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/before" "$scratch/after"

files=()
while IFS= read -r -d '' file; do
  # `git ls-files` also lists a tracked file that was deleted from the working tree.
  if [ -e "$file" ] || [ -L "$file" ]; then
    files+=("$file")
  fi
done < <(git ls-files -z --cached --others --exclude-standard --deduplicate)
printf '%s\0' "${files[@]}" | tar --null -T - -cf - | tar -xf - -C "$scratch/before"
cp -R "$scratch/before/." "$scratch/after/"

# The copy is no git repository, so treefmt walks the files. Its config file is one of the copied files. A linter (such
# as shellcheck) can make treefmt fail without changing a file, and that failure fails this check too.
formatter_status=0
(cd "$scratch/after" && treefmt --no-cache --walk filesystem --tree-root .) || formatter_status=$?

diff_status=0
(cd "$scratch" && diff -ru before after >&2) || diff_status=$?
if [ "$diff_status" -ne 0 ]; then
  echo "format-check: the diff above is what treefmt would change (before is the tree, after is formatted). Run mise run format to write it." >&2
  exit 1
fi
exit "$formatter_status"
