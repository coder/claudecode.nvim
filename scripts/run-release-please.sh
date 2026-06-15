#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
cd "$repo_root"

if [ -d "$script_dir/node_modules/release-please" ]; then
  node "$script_dir/release-please-runner.js" "$@"
  exit 0
fi

release_please_bin="$(command -v release-please)"
release_please_node_modules="$(dirname "$(dirname "$release_please_bin")")"
NODE_PATH="$release_please_node_modules" node "$script_dir/release-please-runner.js" "$@"
