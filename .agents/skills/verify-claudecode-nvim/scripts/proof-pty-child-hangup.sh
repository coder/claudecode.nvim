#!/usr/bin/env bash
# Proves the hangup race of Neovim's pty jobs that the termopen wrapper in tests/minimal_init.lua guards against. Neovim
# forks a pty job's child with its own signal handlers and resets them a few system calls later. A hangup in that gap
# runs libuv's handler in the child, which writes into the signal pipe that it shares with Neovim, so Neovim reads a
# SIGHUP of its own and exits. A shim loaded with LD_PRELOAD holds the child in that gap, so the case is not a matter of luck.
# Usage: proof-pty-child-hangup.sh [tree]     tree: a checkout with tests/minimal_init.lua (default: this checkout)
# VCN_NVIM=<path> runs that Neovim (0.8 or newer). It must be the Neovim binary itself, not a shim of a version manager.
# Cases, each one headless Neovim that starts `sleep` in a terminal job and stops it 50 ms later:
#   control   no shim: Neovim survives
#   window    the child waits 400 ms in the gap: Neovim exits with "Caught deadly signal 'SIGHUP'"
#   wrapper   the same wait, with tests/minimal_init.lua of the tree: termopen returns after the child ran exec, Neovim survives
# Prints one `ok:` or `FAIL:` line per case and ends with `COUNT pty-child-hangup cases=<n> failed=<n>`.
# Exit: 0 every case passed, 1 a case failed, 2 the probe could not run (not Linux, no C compiler, no Neovim).
set -u

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
tree=$(cd "${1:-$here/../../../..}" && pwd -P) || exit 2
nvim=${VCN_NVIM:-nvim}

[[ $(uname -s) == Linux ]] || {
  echo "SKIP: the shim needs glibc on Linux"
  exit 2
}
cc=$(command -v cc || command -v gcc) || {
  echo "SKIP: no C compiler"
  exit 2
}
command -v "$nvim" >/dev/null || {
  echo "SKIP: no Neovim ($nvim)"
  exit 2
}
[[ -f $tree/tests/minimal_init.lua ]] || {
  echo "SKIP: $tree has no tests/minimal_init.lua"
  exit 2
}

work=$(mktemp -d) || exit 2
[[ -n $work && -d $work ]] || exit 2
trap 'rm -rf -- "$work"' EXIT

cat >"$work/shim.c" <<'C'
#define _GNU_SOURCE
#include <dlfcn.h>
#include <signal.h>
#include <stdlib.h>
#include <unistd.h>

static pid_t main_pid;
__attribute__((constructor)) static void remember_main(void) { main_pid = getpid(); }

/* init_child() calls signal(SIGCHLD, SIG_DFL) first, after login_tty() made the child the session leader. */
sighandler_t signal(int sig, sighandler_t handler) {
  static sighandler_t (*real)(int, sighandler_t);
  if (!real) real = (sighandler_t (*)(int, sighandler_t))dlsym(RTLD_NEXT, "signal");
  if (getpid() != main_pid && sig == SIGCHLD && handler == SIG_DFL) usleep(400000);
  return real(sig, handler);
}
C
"$cc" -shared -fPIC -o "$work/shim.so" "$work/shim.c" -ldl || {
  echo "SKIP: the shim did not compile"
  exit 2
}

cat >"$work/probe.lua" <<'LUA'
local job = vim.fn.termopen({ "sleep", "60" })
vim.wait(50)
vim.fn.jobstop(job)
vim.wait(300)
io.stdout:write("SURVIVED\n")
io.stdout:flush()
vim.cmd("qa!")
LUA

mkdir -p "$work/home/.local/share/nvim/site/pack/vendor/start/plenary.nvim" "$work/tmp"

# run_case <init: none|minimal> <shim: yes|no>: prints the Neovim output.
run_case() {
  local shim=() init_arg=NONE
  [[ $1 == minimal ]] && init_arg=$tree/tests/minimal_init.lua
  [[ $2 == yes ]] && shim=(LD_PRELOAD="$work/shim.so")
  (cd "$tree" && env -i PATH="$PATH" HOME="$work/home" TMPDIR="$work/tmp" XDG_DATA_HOME="$work/home/.local/share" \
    XDG_STATE_HOME="$work/home/state" XDG_CONFIG_HOME="$work/home/config" XDG_CACHE_HOME="$work/home/cache" TERM=dumb \
    timeout -k 3 30 env "${shim[@]}" "$nvim" --headless -u "$init_arg" -i NONE -n -c "luafile $work/probe.lua" 2>&1 </dev/null)
}

cases=0 failed=0
verdict() { # <name> <ok|bad> <detail>
  cases=$((cases + 1))
  if [[ $2 == ok ]]; then echo "ok: $1: $3"; else
    failed=$((failed + 1))
    echo "FAIL: $1: $3"
  fi
}

out=$(run_case none no)
if [[ $out == *SURVIVED* ]]; then
  verdict control ok "Neovim survived a job that was stopped after 50 ms"
else
  verdict control bad "Neovim did not survive: ${out:0:80}"
fi

out=$(run_case none yes)
if [[ $out == *"Caught deadly signal 'SIGHUP'"* && $out != *SURVIVED* ]]; then
  verdict window ok "Neovim exited on a SIGHUP of the stopped job's child"
else
  verdict window bad "no SIGHUP exit: ${out:0:80}"
fi

out=$(run_case minimal yes)
if [[ $out == *SURVIVED* ]]; then
  verdict wrapper ok "Neovim survived: termopen returned after the child ran exec"
else
  verdict wrapper bad "Neovim did not survive: ${out:0:80}"
fi

echo "COUNT pty-child-hangup cases=$cases failed=$failed"
((failed == 0))
