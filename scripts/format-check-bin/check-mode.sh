#!/usr/bin/env bash
# Check mode of the three formatters that write files: prettier, stylua and shfmt.
# `treefmt --ci` has no dry run: it runs each formatter with its write flags and then fails because a file changed, so a
# failed check rewrites the tree. `mise run format-check` puts this folder first on PATH. treefmt then finds `prettier`,
# `stylua` and `shfmt` here (they are symlinks to this script), and runs them with the options of treefmt.toml, a `--`,
# and the file names. This script drops those options (everything up to the first `--`), takes its own folder off
# PATH, and runs the real tool in check mode: the tool fails on a file that it would change, prints that file, and
# writes nothing. `mise run format` and a plain `treefmt` run the real tools, so treefmt's cache keys on them, as it did
# before this folder existed.
# Usage: the name it is called by (prettier, stylua or shfmt), then treefmt's options, `--` and the file names.
# Exit status: the tool's own, 2 for an unknown name, for no `--`, and for a second run of this script.
set -euo pipefail

tool=$(basename -- "$0")
if [ -n "${FORMAT_CHECK_STAND_IN:-}" ]; then
  echo "format-check: $tool found this stand-in again, so no real $tool is on PATH, or FORMAT_CHECK_STAND_IN is set" \
    "in the environment (unset it)" >&2
  exit 2
fi
export FORMAT_CHECK_STAND_IN=1
while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
  shift
done
if [ "$#" -eq 0 ]; then
  echo "format-check: $tool got no -- before the file names" >&2
  exit 2
fi
shift

self=$(cd -- "$(dirname -- "$0")" && pwd)
path=
IFS=: read -r -a parts <<<"$PATH"
for part in "${parts[@]}"; do
  if [ ! "$part" -ef "$self" ]; then
    path=${path:+$path:}$part
  fi
done
export PATH=$path

case "$tool" in
prettier) exec prettier --check -- "$@" ;;
stylua) exec stylua --check -- "$@" ;;
shfmt) exec shfmt -i 2 -d -- "$@" ;;
esac
echo "format-check: unknown tool $tool" >&2
exit 2
