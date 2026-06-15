#!/usr/bin/env bash
set -euo pipefail

release_please_bin="$(command -v release-please)"
release_please_node_modules="$(dirname "$(dirname "$release_please_bin")")"
NODE_PATH="$release_please_node_modules" node scripts/release-please-runner.js "$@"
