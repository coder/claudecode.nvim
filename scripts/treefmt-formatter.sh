#!/usr/bin/env bash
# The command of the three formatters in treefmt.toml that write files: prettier, stylua and shfmt.
# `treefmt --ci` has no dry run: it runs each formatter in write mode and then fails because a file changed, so a failed
# check rewrites the tree. This wrapper picks the flags of one tool from one place. With FORMAT_CHECK=1 (set by
# `mise run format-check`) the tool only checks, and it fails on a file that it would change, and prints that file. In
# every other run (`mise run format`) it writes. The includes and excludes of each formatter stay in treefmt.toml, so
# both modes format the same files.
# Usage: scripts/treefmt-formatter.sh <prettier|stylua|shfmt> <file>...
# Exit status: the tool's own.
set -euo pipefail

tool=${1:?"usage: treefmt-formatter.sh <prettier|stylua|shfmt> <file>..."}
shift

if [ "${FORMAT_CHECK:-}" = 1 ]; then
  case "$tool" in
  prettier) exec prettier --check "$@" ;;
  stylua) exec stylua --check "$@" ;;
  shfmt) exec shfmt -i 2 -d "$@" ;;
  esac
else
  case "$tool" in
  prettier) exec prettier --write "$@" ;;
  stylua) exec stylua "$@" ;;
  shfmt) exec shfmt -i 2 -w "$@" ;;
  esac
fi
echo "treefmt-formatter: unknown tool $tool" >&2
exit 2
