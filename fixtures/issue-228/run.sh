#!/usr/bin/env bash
# One-command reproduction for issue #228.
# Runs the headless harness against the plugin in this repo.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"

nvim_bin="${NVIM:-nvim}"

cd "$repo_root"
exec "$nvim_bin" -u NONE -l fixtures/issue-228/repro.lua
