#!/usr/bin/env bash
# Proves that the plugin checks every `tools/call` once at the entry (#500): a malformed call gets -32602 that names the
# wrong parameter, a valid call gets its normal answer, and no answer leaks a path. It starts the plugin server of one
# tree in a headless nvim and sends the cases over a real WebSocket (see proof-tools-call-wire.mjs).
# Usage: proof-tools-call-wire.sh [tree]     tree: a plugin tree with lua/claudecode (default: this checkout)
# Prints one `ok:` or `FAIL:` line per case and ends with `COUNT tools-call-wire cases=<n> failed=<n> leaks=<n>`.
# Exit: 0 every case passed, 1 a case failed or a frame leaked, 2 the probe could not run, or judged fewer cases than
# its table holds, or the tree, the work folder or the home folder path holds a double quote, a backslash or a control
# character (the checker refuses it: the leak rule could not find such a path in a frame).
# VCN_NVIM=<path> runs that Neovim (0.8 or newer), as in vcn.sh. It must be the Neovim binary itself or a wrapper that
# runs it with exec, because nvim must be a direct child of this script, and not a version-manager shim, which does not
# start with an empty environment. nvim and the checker start with an empty environment. When nvim and node are the
# binaries themselves, nvim gets only PATH=/usr/bin:/bin, WIRE_PARENT, WIRE_TREE, WIRE_CWD, and HOME, TMPDIR,
# XDG_CONFIG_HOME, XDG_DATA_HOME, XDG_STATE_HOME, XDG_CACHE_HOME and CLAUDE_CONFIG_DIR in the run dir, and the checker
# gets no variable. nvim runs with terminal.provider = "none", so no `claude` starts.
set -euo pipefail
umask 077

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$SKILL_DIR/../../.." && pwd)"

die() {
  echo "proof-tools-call-wire: $*" >&2
  exit 2
}

# The last lines of nvim's output say why the server did not come up. This runs only while no lock file exists, and the
# plugin logs only the length of its token, never the token.
why() {
  { tail -n 5 "$RUN/nvim.out" 2>/dev/null || true; } >&2
  echo >&2
  die "$1"
}

bin() {
  mise which "$1" 2>/dev/null || command -v "$1" || die "$1 not found on PATH"
}

TREE="$(cd "${1:-$REPO}" 2>/dev/null && pwd -P)" || die "no such tree: ${1-}"
[[ -f $TREE/lua/claudecode/init.lua ]] || die "$TREE has no lua/claudecode/init.lua"
NVIM="${VCN_NVIM:-$(bin nvim)}"
NODE="$(bin node)"
if PATH=/usr/bin:/bin command -v claude >/dev/null; then
  die "a claude program is on PATH=/usr/bin:/bin: refusing to start nvim"
fi

# Both processes are children of this script. The cleanup stops them by PID and removes the temp dir.
RUN=""
NVIM_PID=""
NODE_PID=""
# shellcheck disable=SC2329
cleanup() {
  local pid
  trap '' TERM INT HUP # a second signal must not end the cleanup
  for pid in $NODE_PID $NVIM_PID; do
    kill "$pid" 2>/dev/null || true
    for _ in {1..30}; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  [[ -z $RUN ]] || rm -rf -- "$RUN"
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP

RUN="$(mktemp -d /tmp/wire-probe.XXXXXX)" || die "cannot make a temp dir under /tmp"
REAL="$(cd "$RUN" && pwd -P)" || die "cannot enter the temp dir $RUN"
RUN="$REAL"
mkdir "$RUN/work" "$RUN/tmp" || die "cannot make the dirs in $RUN"
# What nvim gets, and nothing else. The checker gets nothing.
NVIM_ENV=(env -i PATH=/usr/bin:/bin WIRE_PARENT="$$" WIRE_TREE="$TREE" WIRE_CWD="$RUN/work" HOME="$RUN/home"
  TMPDIR="$RUN/tmp" XDG_CONFIG_HOME="$RUN/config" XDG_DATA_HOME="$RUN/data" XDG_STATE_HOME="$RUN/state"
  XDG_CACHE_HOME="$RUN/cache" CLAUDE_CONFIG_DIR="$RUN/claude")
"${NVIM_ENV[@]}" "$NVIM" --version >/dev/null 2>&1 ||
  die "$NVIM does not start with an empty environment (a version-manager shim?): set VCN_NVIM to a real Neovim binary"
env -i "$NODE" --version >/dev/null 2>&1 ||
  die "$NODE does not start with an empty environment (a version-manager shim?): put a real node first on PATH"
# nvim must be a direct child of this script: it checks its parent before the plugin starts, and quits with an error
# when the parent is not this script (a wrapper without exec). It then quits by itself when this script is gone, SIGKILL
# included: it checks its parent every half second. Its server stop closes the socket, which ends the checker, and
# removes the lock file.
"${NVIM_ENV[@]}" "$NVIM" --headless -u NONE -i NONE \
  --cmd 'lua function wire_gone() return (vim.uv or vim.loop).os_getppid() ~= tonumber(vim.env.WIRE_PARENT) end; if wire_gone() then io.stderr:write("wire-probe: this nvim is not a direct child of the launcher\n"); vim.cmd("cquit 3") end; vim.opt.rtp:prepend(vim.env.WIRE_TREE); vim.api.nvim_set_current_dir(vim.env.WIRE_CWD)' \
  -c "lua require('claudecode').setup({ terminal = { provider = 'none' }, track_selection = false })" \
  -c "lua vim.fn.timer_start(500, function() if wire_gone() then vim.cmd('qa!') end end, { ['repeat'] = -1 })" >"$RUN/nvim.out" 2>&1 &
NVIM_PID=$!

shopt -s nullglob
for _ in {1..100}; do
  locks=("$RUN"/claude/ide/*.lock)
  [[ ${#locks[@]} -eq 0 ]] || break
  if ! kill -0 "$NVIM_PID" 2>/dev/null; then
    ! grep -q "not a direct child" "$RUN/nvim.out" ||
      die "$NVIM runs Neovim as a child (a wrapper without exec?): set VCN_NVIM to the Neovim binary itself"
    why "nvim exited before it wrote a lock file"
  fi
  sleep 0.1
done
[[ ${#locks[@]} -gt 0 ]] || why "nvim wrote no lock file in 10 s"
env -i "$NODE" "$SKILL_DIR/scripts/proof-tools-call-wire.mjs" "${locks[0]}" "$TREE" "$RUN/work" &
NODE_PID=$!
rc=0
wait "$NODE_PID" || rc=$?
exit "$rc"
