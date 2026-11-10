#!/usr/bin/env bash
# Run one replay probe on headless Neovim with this checkout first on 'runtimepath'.
# Usage: .agents/skills/verify-selection-tracking/replays/run.sh <probe>.lua   (NVIM=/path/to/nvim to pick a binary)
# Each run gets a fresh XDG and CLAUDE_CONFIG_DIR under $XUM_SCRATCH_DIR (or /tmp), removed afterwards.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(git -C "$here" rev-parse --show-toplevel)
probe=$here/$(basename "$1")
[[ -f $probe ]] || {
  echo "no probe $1 in $here" >&2
  exit 2
}
tmp=$(mktemp -d "${XUM_SCRATCH_DIR:-/tmp}/selection-replay.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/config" "$tmp/data" "$tmp/state" "$tmp/cache" "$tmp/claude" "$tmp/tmp"
XDG_CONFIG_HOME=$tmp/config XDG_DATA_HOME=$tmp/data XDG_STATE_HOME=$tmp/state XDG_CACHE_HOME=$tmp/cache \
  CLAUDE_CONFIG_DIR=$tmp/claude TMPDIR=$tmp/tmp timeout 30 "${NVIM:-nvim}" --headless -u NONE -i NONE \
  --cmd "set rtp^=$repo" --cmd "lua package.path = '$here/?.lua;' .. package.path" -c "luafile $probe"
