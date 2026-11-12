#!/usr/bin/env bash
# Checks that `mise run format-check` writes nothing, and that `mise run format` still writes. It adds three untracked
# probe files to the working tree (Markdown, Lua and shell, each unformatted) and removes them on exit. The check must
# fail, name each probe, and leave each probe as it was (the old task, `treefmt --ci` with the write flags, rewrote
# them). `mise run format` on the probes must write the formatted text. The check must pass on the formatted probes, and
# it must fail on a shell probe that shfmt keeps and shellcheck rejects.
# The check runs on the whole tree, so the test needs a formatted tree: its third run expects exit 0.
# Usage: scripts/test-format-check.sh
# Exit 0: the checks hold. Exit 1: one failed. Exit 2: a probe file is there already.
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

md=format-check-probe.md
lua=format-check-probe.lua
sh=format-check-probe.sh
for file in "$md" "$lua" "$sh"; do
  if [ -e "$file" ]; then
    echo "test-format-check: $file exists already, so the test cannot use it" >&2
    exit 2
  fi
done

scratch=$(mktemp -d)
trap 'rm -rf "$scratch" "$md" "$lua" "$sh"' EXIT

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

# Writes the probes with the text $1 (md), $2 (lua) and $3 (sh), and keeps a copy of each in "$scratch/before".
write_probes() {
  printf '%b' "$1" >"$md"
  printf '%b' "$2" >"$lua"
  printf '%b' "$3" >"$sh"
  mkdir -p "$scratch/before"
  cp "$md" "$lua" "$sh" "$scratch/before/"
}

# Runs the check. Sets `status`, and leaves the output in "$scratch/output". It fails when the check changed a probe.
run_check() {
  status=0
  mise run format-check >"$scratch/output" 2>&1 || status=$?
  for file in "$md" "$lua" "$sh"; do
    cmp -s "$file" "$scratch/before/$file" || fail "format-check wrote to $file"
  done
}

# Fails unless "$1" holds the text that printf makes from "$2".
expect_text() {
  printf '%b' "$2" >"$scratch/expected"
  cmp -s "$1" "$scratch/expected" || fail "$1 does not hold the text that $3"
}

# 1. Three unformatted probes: the check fails, names each probe, and leaves each as it was.
write_probes "$unformatted_md" "$unformatted_lua" "$unformatted_sh"
run_check
[ "$status" -ne 0 ] || fail "format-check passed with three unformatted probes"
for file in "$md" "$lua" "$sh"; do
  grep -q "$file" "$scratch/output" || fail "format-check does not name $file"
done

# 2. `mise run format` formats the probes (and only them).
if ! mise run format -- "$md" "$lua" "$sh" >"$scratch/output" 2>&1; then
  fail "mise run format failed: $(tail -n 5 "$scratch/output")"
fi
expect_text "$md" "$formatted_md" "prettier writes"
expect_text "$lua" "$formatted_lua" "stylua writes"
expect_text "$sh" "$formatted_sh" "shfmt -i 2 writes"

# 3. The formatted probes pass the check, and the check leaves them as they are.
cp "$md" "$lua" "$sh" "$scratch/before/"
run_check
[ "$status" -eq 0 ] || fail "format-check failed the formatted probes: $(tail -n 5 "$scratch/output")"

# 4. shfmt keeps this file, and shellcheck fails on it (SC2086): the check fails, and the file stays.
write_probes "$formatted_md" "$formatted_lua" '#!/bin/sh\necho $1\n'
run_check
[ "$status" -ne 0 ] || fail "format-check passed a file that shellcheck fails"
grep -q "$sh" "$scratch/output" || fail "format-check does not name $sh for the shellcheck failure"

echo "test-format-check: ok"
