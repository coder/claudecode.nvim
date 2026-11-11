#!/usr/bin/env bash
# Replay one finding of verify-terminal-lifecycle against the real plugin in a headless Neovim.
# Usage: replays/run.sh <replay>.lua
#   NVIM=<path>          Neovim to run (default: nvim on PATH)
#   SNACKS_NVIM=<dir>    a snacks.nvim checkout, needed by the snacks-*.lua replays
# Claude is played by `sh -c 'sleep ...'`; the real claude CLI never runs. Neovim gets throwaway XDG dirs and
# CLAUDE_CONFIG_DIR, so the replay touches no user config. Exit 0 when no check shows its finding, 1 when one does, 2 on a
# setup error.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(git -C "$here" rev-parse --show-toplevel)
replay=${1:?usage: replays/run.sh <replay>.lua}
[[ -f $here/$replay ]] || {
  echo "ERROR: no replay $here/$replay" >&2
  exit 2
}
nvim=${NVIM:-nvim}
rtp=$repo
# snacks-*.lua start with snacks.nvim on the runtimepath; auto-*.lua add it themselves, later.
if [[ $replay == snacks-* || $replay == auto-* ]]; then
  [[ -n ${SNACKS_NVIM:-} && -f $SNACKS_NVIM/lua/snacks/init.lua ]] || {
    echo "ERROR: $replay needs SNACKS_NVIM=<snacks.nvim checkout>" >&2
    exit 2
  }
  [[ $replay == auto-* ]] || rtp=$rtp,$SNACKS_NVIM
fi
home=$(mktemp -d "${TMPDIR:-/tmp}/verify-terminal-lifecycle-replay.XXXXXX")
trap 'rm -rf "$home"' EXIT
mkdir -p "$home"/{config,data,state,cache,claude,work}
cd "$home/work"
XDG_CONFIG_HOME=$home/config XDG_DATA_HOME=$home/data XDG_STATE_HOME=$home/state XDG_CACHE_HOME=$home/cache \
  CLAUDE_CONFIG_DIR=$home/claude REPLAY_LIB=$here/lib.lua timeout 60 "$nvim" --headless -u NONE -i NONE \
  --cmd "set rtp^=$rtp" -c "luafile $here/$replay" 2>&1
