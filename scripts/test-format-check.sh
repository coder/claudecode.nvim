#!/usr/bin/env bash
# Checks that `mise run format-check` writes nothing. On a tree with an unformatted file it must fail, name the file,
# and leave the file as it was. On a formatted file it must pass and leave the file as it was. A linter failure
# (shellcheck on a shell file that shfmt leaves as it is) must fail it too.
# The test adds one or two untracked files to the working tree and removes them on exit.
# Usage: scripts/test-format-check.sh
# Exit 0: the checks hold. Exit 1: one failed. Exit 2: a probe file is there already.
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

probe=format-check-probe.md
lint_probe=format-check-probe.sh
for file in "$probe" "$lint_probe"; do
  if [ -e "$file" ]; then
    echo "test-format-check: $file exists already, so the test cannot use it" >&2
    exit 2
  fi
done

scratch=$(mktemp -d)
trap 'rm -rf "$scratch" "$probe" "$lint_probe"' EXIT

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

echo "test-format-check: ok"
