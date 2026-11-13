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
command -v "$nvim" >/dev/null || {
  echo "ERROR: no Neovim at $nvim (set NVIM=<path to nvim>)" >&2
  exit 2
}
# The runner changes into a work directory, so a relative path of the caller must be absolute first.
[[ $nvim == */* ]] && nvim=$(cd "$(dirname "$nvim")" && pwd)/$(basename "$nvim")
snacks_rtp=
# snacks-*.lua start with snacks.nvim on the runtimepath; auto-*.lua add it themselves, later.
if [[ $replay == snacks-* || $replay == auto-* ]]; then
  [[ -n ${SNACKS_NVIM:-} && -f $SNACKS_NVIM/lua/snacks/init.lua && -f $SNACKS_NVIM/lua/snacks/terminal.lua ]] || {
    echo "ERROR: $replay needs SNACKS_NVIM=<snacks.nvim checkout with Snacks.terminal>" >&2
    exit 2
  }
  SNACKS_NVIM=$(cd "$SNACKS_NVIM" && pwd)
  export SNACKS_NVIM
  [[ $replay == auto-* ]] || snacks_rtp=$SNACKS_NVIM
fi
home=$(mktemp -d "${TMPDIR:-/tmp}/verify-terminal-lifecycle-replay.XXXXXX")
trap 'rm -rf "$home"' EXIT
mkdir -p "$home"/{config,data,state,cache,claude,work}
cd "$home/work"
# The paths go to Neovim through the environment and a Lua call, not through `set rtp^=` and `luafile`: a path with a space,
# a comma, a backslash or a | would be split or cut by those Ex commands. 'runtimepath' needs a comma and a backslash escaped.
# lib.finish quits with 0 or 1. A replay that raises, or that returns without calling lib.after_startup (which sets
# vim.g.replay_after_startup and runs its body later, from the main loop), gets `cquit 2`, a setup error. One that hangs is
# stopped by timeout (124), which is a setup error too.
code=0
XDG_CONFIG_HOME=$home/config XDG_DATA_HOME=$home/data XDG_STATE_HOME=$home/state XDG_CACHE_HOME=$home/cache \
  CLAUDE_CONFIG_DIR=$home/claude REPLAY_LIB=$here/lib.lua REPLAY_REPO=$repo REPLAY_SNACKS=$snacks_rtp \
  REPLAY_FILE=$here/$replay timeout 60 "$nvim" --headless -u NONE -i NONE \
  --cmd 'lua for _, dir in ipairs({ os.getenv("REPLAY_SNACKS"), os.getenv("REPLAY_REPO") }) do if dir ~= "" then vim.o.runtimepath = (dir:gsub("[\\,]", "\\%0")) .. "," .. vim.o.runtimepath end end' \
  -c 'lua local ok, err = pcall(dofile, os.getenv("REPLAY_FILE")); if not ok then io.stderr:write(tostring(err) .. "\n") end; if not ok or not vim.g.replay_after_startup then vim.cmd("cquit 2") end' 2>&1 || code=$?
if [[ $code -eq 124 ]]; then
  echo "ERROR: $replay did not finish within 60 s" >&2
  exit 2
fi
exit "$code"
