#!/usr/bin/env bash
# Proves that the plugin checks every `tools/call` once at the entry (#500): a malformed call gets -32602 that names the
# wrong parameter, a valid call gets its normal answer, and no answer leaks a path. It starts the plugin server of one
# tree in a headless nvim and sends the cases over a real WebSocket (see proof-tools-call-wire.mjs).
# Usage: proof-tools-call-wire.sh [tree]     tree: a plugin tree with lua/claudecode (default: this checkout)
# Prints one `ok:` or `FAIL:` line per case and ends with `COUNT tools-call-wire cases=<n> failed=<n> leaks=<n>`.
# Exit: 0 every case passed, 1 a case failed or an answer leaked, 2 the probe could not run.
# VCN_NVIM=<path> runs that Neovim (0.8 or newer), as in vcn.sh. nvim gets an empty environment apart from
# PATH=/usr/bin:/bin, a scratch HOME and scratch XDG dirs, and runs with terminal.provider = "none": no `claude` starts.
set -euo pipefail
umask 077

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$SKILL_DIR/../../.." && pwd)"

die() {
  echo "proof-tools-call-wire: $*" >&2
  exit 2
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

RUN="$(mktemp -d /tmp/wire-probe.XXXXXX)"
RUN="$(cd "$RUN" && pwd -P)"
mkdir "$RUN/work"
# nvim quits by itself after 3 minutes, in case this script dies before its cleanup.
env -i PATH=/usr/bin:/bin HOME="$RUN/home" XDG_CONFIG_HOME="$RUN/config" XDG_DATA_HOME="$RUN/data" \
  XDG_STATE_HOME="$RUN/state" XDG_CACHE_HOME="$RUN/cache" CLAUDE_CONFIG_DIR="$RUN/claude" \
  WIRE_TREE="$TREE" WIRE_CWD="$RUN/work" "$NVIM" --headless -u NONE -i NONE \
  --cmd 'lua vim.opt.rtp:prepend(vim.env.WIRE_TREE); vim.api.nvim_set_current_dir(vim.env.WIRE_CWD)' \
  -c "lua require('claudecode').setup({ terminal = { provider = 'none' }, track_selection = false })" \
  -c "lua vim.defer_fn(function() vim.cmd('qa!') end, 180000)" >"$RUN/nvim.out" 2>&1 &
NVIM_PID=$!

shopt -s nullglob
for _ in {1..100}; do
  locks=("$RUN"/claude/ide/*.lock)
  [[ ${#locks[@]} -eq 0 ]] || break
  kill -0 "$NVIM_PID" 2>/dev/null || die "nvim exited before it wrote a lock file"
  sleep 0.1
done
[[ ${#locks[@]} -gt 0 ]] || die "nvim wrote no lock file in 10 s"
"$NODE" "$SKILL_DIR/scripts/proof-tools-call-wire.mjs" "${locks[0]}" "$TREE" "$RUN/work" &
NODE_PID=$!
rc=0
wait "$NODE_PID" || rc=$?
exit "$rc"
