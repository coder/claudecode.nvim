#!/usr/bin/env bash
# Run one replay probe on headless Neovim with this checkout first on 'runtimepath'.
# Usage: .agents/skills/verify-selection-tracking/replays/run.sh <probe>.lua   (NVIM=/path/to/nvim to pick a binary)
# Each run gets a fresh XDG and CLAUDE_CONFIG_DIR under $XUM_SCRATCH_DIR (or /tmp), removed afterwards.
# Exit 0 when the probe prints OK, 1 when it prints BUG.
set -euo pipefail
[[ $# -eq 1 ]] || {
  echo "usage: run.sh <probe>.lua   (NVIM=/path/to/nvim picks the binary, DELAY_MS=<ms> sets the demotion delay of the two long-delay probes)" >&2
  exit 2
}
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
# The paths go through the environment and are escaped by Neovim's own Lua API (a comma in 'runtimepath' is not enough
# for require, so the lua directory is on package.path too), so a checkout path with a space, a comma or a quote works. The watchdog is plain bash: macOS has no GNU timeout.
export REPLAY_REPO=$repo REPLAY_HERE=$here REPLAY_PROBE=$probe
XDG_CONFIG_HOME=$tmp/config XDG_DATA_HOME=$tmp/data XDG_STATE_HOME=$tmp/state XDG_CACHE_HOME=$tmp/cache \
  CLAUDE_CONFIG_DIR=$tmp/claude TMPDIR=$tmp/tmp "${NVIM:-nvim}" --headless -u NONE -i NONE \
  --cmd "lua local repo = os.getenv('REPLAY_REPO'); vim.opt.rtp:prepend(repo); package.path = os.getenv('REPLAY_HERE') .. '/?.lua;' .. repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path" \
  -c "lua dofile(os.getenv('REPLAY_PROBE'))" &
nvim_pid=$!
(
  sleep 30
  kill -KILL "$nvim_pid" 2>/dev/null
) >/dev/null 2>&1 &
watchdog_pid=$!
status=0
wait "$nvim_pid" || status=$?
kill "$watchdog_pid" 2>/dev/null || true
wait "$watchdog_pid" 2>/dev/null || true
exit "$status"
