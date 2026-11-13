#!/usr/bin/env bash
# Run one replay in a headless Neovim with this checkout first on 'runtimepath' and every XDG dir and
# CLAUDE_CONFIG_DIR in a fresh temp dir, so the run never touches your config or ~/.claude.
# The replay runs from -c, not -l, so that Neovim 0.8 runs it too. Paths pass through the environment, so a path with a
# space or a quote needs no escaping.
# Usage: run.sh <replay>.lua   (NVIM=/path/to/nvim overrides the Neovim binary)
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(git -C "$here" rev-parse --show-toplevel)
script=${1:?usage: run.sh <replay>.lua}
[[ -f $here/$script ]] || {
  echo "no replay $here/$script" >&2
  exit 2
}
nvim=${NVIM:-nvim}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/verify-ws-connection-replay.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp"/{config,data,state,cache,claude}
# A replay ends the run with qa! or cq! (harness.lua finish). An error in one ends it with cq!, as -l did.
XDG_CONFIG_HOME=$tmp/config XDG_DATA_HOME=$tmp/data XDG_STATE_HOME=$tmp/state XDG_CACHE_HOME=$tmp/cache \
  CLAUDE_CONFIG_DIR=$tmp/claude VWC_REPO=$repo VWC_REPLAY=$here/$script "$nvim" --headless -u NONE -i NONE \
  --cmd "lua vim.opt.rtp:prepend(os.getenv('VWC_REPO'))" \
  -c "lua local ok, err = pcall(dofile, os.getenv('VWC_REPLAY')); if not ok then io.stderr:write(tostring(err), '\\n'); vim.cmd('cq!') end; vim.cmd('qa!')"
