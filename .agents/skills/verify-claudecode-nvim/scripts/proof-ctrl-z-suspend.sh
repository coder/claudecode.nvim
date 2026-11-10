#!/usr/bin/env bash
# Proves that Ctrl-Z in the Claude terminal suspends Neovim and never reaches the Claude job (#194).
# Usage: proof-ctrl-z-suspend.sh native|snacks
#   snacks needs SNACKS_DIR=<a snacks.nvim checkout>. VERIFY_OUT=<new dir> picks the evidence dir.
# It launches its own run with terminal_cmd set to scripts/ctrl-z-probe-job.mjs, a raw-mode stand-in for the
# Claude CLI that logs every byte it reads and stops itself on 0x1a. It opens the terminal with :ClaudeCode,
# presses Ctrl-Z, then types one more key.
# vcn.sh runs nvim as the leader of its own session, so its process group is orphaned and the kernel drops the
# SIGTSTP that `:suspend` sends. Neovim therefore never stops here. The proof counts VimSuspend events instead, and
# compares the terminal's Ctrl-Z with the one in a normal window.
# Prints `ok <check>` or `FAIL <check>` per check and ends with `CHECKS <n> FAILED <k>`. Exits 1 when any check
# fails. On a main without the fix, the job reads 0x1a and stops, and Neovim never runs :suspend.
# Evidence lands in the run's $OUT as ctrl-z-<provider>-*.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V="$here/vcn.sh"
provider=${1-}
[[ $provider == native || $provider == snacks ]] || {
  echo "usage: proof-ctrl-z-suspend.sh native|snacks" >&2
  exit 2
}
launch_args=(hello.txt)
if [[ $provider == snacks ]]; then
  [[ -f ${SNACKS_DIR-}/lua/snacks/init.lua ]] || {
    echo "proof-ctrl-z-suspend: SNACKS_DIR must be a snacks.nvim checkout" >&2
    exit 2
  }
  launch_args=(--cmd "set rtp+=$SNACKS_DIR" hello.txt)
fi
node_exe=$(mise which node 2>/dev/null || command -v node)
out=${VERIFY_OUT:-${XUM_SCRATCH_DIR:-/tmp}/verify-claudecode-nvim/ctrl-z-$provider-$(date -u +%Y%m%dT%H%M%SZ)}
log="$out/ctrl-z-$provider-job.log"
export VERIFY_OUT=$out
VCN_SETUP=$(jq -nc --arg p "$provider" --arg cmd "$node_exe $here/ctrl-z-probe-job.mjs $log" \
  '{terminal: {provider: $p}, terminal_cmd: $cmd}')
export VCN_SETUP

started=$("$V" launch "${launch_args[@]}")
VCN_STATE=$(sed -n 's/^VCN_STATE=//p' <<<"$started")
export VCN_STATE
trap '"$V" cleanup >/dev/null' EXIT
# shellcheck source=/dev/null
source "$VCN_STATE/run.env"

total=0
failed=0
check() {
  local label=$1
  shift
  total=$((total + 1))
  if "$@"; then
    echo "ok   $label"
  else
    failed=$((failed + 1))
    echo "FAIL $label"
  fi
}
# state <pid>: the first letter of ps' process state, "-" when the process is gone.
state() { ps -o stat= -p "$1" 2>/dev/null | cut -c1 | grep . || echo -; }
# The job logs `bytes <hex> ...` per read. job_log_lacks <hex>: it never read that byte. job_log_gets <hex>: it
# reads that byte within 5 s.
job_log_lacks() { ! grep -qE "^bytes( [0-9a-f]{2})* $1( |$)" "$log"; }
job_log_gets() {
  local i
  for ((i = 0; i < 50; i++)); do
    job_log_lacks "$1" || return 0
    sleep 0.1
  done
  return 1
}
# lua <code>: evaluate Lua over RPC. The code must use no single quote.
lua() { "$V" expr "luaeval('$1')"; }
# map_in <buffer name>: the terminal-mode <C-z> mapping, as seen from that buffer, or nothing.
map_in() {
  lua "vim.api.nvim_buf_call(vim.fn.bufnr(\"$1\"), function() return vim.fn.maparg(\"<C-z>\", \"t\") end)"
}

# :suspend fires VimSuspend, so the count shows whether Ctrl-Z reached Neovim's own suspend. Control: Ctrl-Z in a
# normal window of hello.txt is the first suspend.
"$V" keys ':let g:suspends = 0 | autocmd VimSuspend * let g:suspends += 1' Enter
"$V" keys Ctrl+Z
"$V" until 'g:suspends' 1 5
"$V" until 'mode()' n 5
"$V" keys ':ClaudeCode' Enter
"$V" until 'mode()' t
"$V" until "&filetype" claudecode
for _ in $(seq 100); do
  if grep -q '^ready ' "$log" 2>/dev/null; then break; fi
  sleep 0.1
done
job_pid=$(sed -n 's/^ready pid=//p' "$log" | tail -n 1)
terminal_buf=$(lua 'vim.api.nvim_get_current_buf()')
"$V" capture "ctrl-z-$provider-1-open" >/dev/null
"$V" screenshot "ctrl-z-$provider-1-open" >/dev/null

check "the Claude terminal buffer has a terminal-mode <C-z> mapping" \
  test -n "$(lua "vim.fn.maparg(\"<C-z>\", \"t\")")"
check "the other buffer (hello.txt) has none" test -z "$(map_in hello.txt)"
check "the Claude terminal buffer's mapping is buffer-local" \
  test "$(lua "vim.fn.maparg(\"<C-z>\", \"t\", false, true).buffer")" = 1

"$V" keys Ctrl+Z
"$V" until 'g:suspends' 2 5 || true
sleep 1
{
  echo "after Ctrl-Z in the terminal: VimSuspend fired $("$V" expr 'g:suspends') time(s) in all, job pid $job_pid state $(state "$job_pid")"
  ps -o pid,pgid,stat,args -p "$job_pid" | cut -c1-120
} >"$out/ctrl-z-$provider-states.txt"
"$V" capture "ctrl-z-$provider-2-after-ctrl-z" >/dev/null

check "Ctrl-Z in the Claude terminal ran :suspend, as it did in the normal window (VimSuspend 1 -> 2)" \
  test "$("$V" expr 'g:suspends')" = 2
check "the job never read the Ctrl-Z byte (0x1a)" job_log_lacks '1a'
check "the job is not stopped" test "$(state "$job_pid")" != T

"$V" until 'mode()' t 5 || true
"$V" keys x
check "after Ctrl-Z, a typed key (0x78) still reaches the job" job_log_gets '78'
"$V" capture "ctrl-z-$provider-3-after-typing" >/dev/null
"$V" screenshot "ctrl-z-$provider-3-after-typing" >/dev/null

echo "terminal buffer: $terminal_buf; job log: $log"
echo "CHECKS $total FAILED $failed"
((failed == 0))
