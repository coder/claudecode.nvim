# Suspend Neovim with Ctrl-Z in the Claude terminal

Ctrl-Z in the Claude terminal suspends Neovim, as it does in any other window, and never reaches the Claude job. A terminal passes Ctrl-Z to its job, and Claude Code then suspends itself with nothing in a Neovim terminal to resume it (#194). The `native` and `snacks` providers map `<C-z>` in terminal mode, on the Claude terminal buffer only, to `:suspend`. A `FileType claudecode` autocmd can replace the mapping.

## Sub-features

- `ctrl-z-mapping` maps `<C-z>` in terminal mode on the Claude terminal buffer, once, and on no other buffer.
- `ctrl-z-suspends-neovim` runs `:suspend` on Ctrl-Z in the Claude terminal, as Ctrl-Z in a normal window does.
- `ctrl-z-skips-job` keeps the Ctrl-Z byte (0x1a) from the Claude job, so the job is never stopped.
- `ctrl-z-user-override` keeps a buffer-local `<C-z>` mapping that a `FileType claudecode` handler sets.

## How to get to it (user POV)

- The user opens the Claude terminal with `:ClaudeCode` and presses Ctrl-Z in terminal mode.

## Driving it with vcn.sh

Preconditions:

- `provider = "native"` or `provider = "snacks"`. The snacks provider needs a snacks.nvim checkout (`SNACKS_DIR`). Clone it into scratch and record its commit.
- A stand-in job for the Claude CLI: `scripts/ctrl-z-probe-job.mjs <log>`. It puts its terminal in raw mode, logs each byte it reads, and stops itself on 0x1a, the way Claude Code does. Never start the real `claude` CLI.

Steps:

- **Whole proof.** Run `SNACKS_DIR=<snacks.nvim checkout> .agents/skills/verify-claudecode-nvim/scripts/proof-ctrl-z-suspend.sh native` and the same with `snacks`. The script launches its own run, so it needs no `$V launch` first. It prints one `ok` or `FAIL` line per check, ends with `CHECKS <n> FAILED <k>`, and exits 1 on a failure. Evidence lands in `$VERIFY_OUT` (default `$XUM_SCRATCH_DIR/verify-claudecode-nvim/ctrl-z-<provider>-<time>`) as `ctrl-z-<provider>-*`: the job log, the process states, screen text at each step, and PNGs.
- **By hand.** Launch with `VERIFY_OUT=<new dir> VCN_SETUP="$(jq -nc --arg cmd "$(mise which node) $PWD/.agents/skills/verify-claudecode-nvim/scripts/ctrl-z-probe-job.mjs <new dir>/job.log" '{terminal:{provider:"native"},terminal_cmd:$cmd}')" $V launch`. Run `$V keys ':ClaudeCode' Enter` and `$V until 'mode()' t`. `$V expr 'maparg("<C-z>", "t")'` prints `<Cmd>suspend<CR>`. Run `$V keys Ctrl+Z`. The job log has no `bytes 1a` line, and `$V expr 'mode()'` still prints `t`.
- **Control.** Register `:autocmd VimSuspend * let g:suspends += 1` after `:let g:suspends = 0`. Ctrl-Z in a normal window and Ctrl-Z in the Claude terminal each add one to `g:suspends`.

## Gotchas

- vcn.sh runs nvim as the leader of its own session. Its process group is orphaned, and the kernel drops the SIGTSTP that `:suspend` sends, so nvim never stops in this harness, not even for Ctrl-Z in a normal window. Count `VimSuspend` events instead of watching the nvim process state.
- The job must stop itself with SIGSTOP. The Claude job leads its own session too, so the kernel drops a default-action SIGTSTP for it. `ctrl-z-probe-job.mjs` sends SIGSTOP, and the job's process state shows `T` after a Ctrl-Z that reached it.
- The `terminal_cmd` must use absolute paths. nvim runs with `PATH=/usr/bin:/bin`, so a bare `node` is not found.
- `VCN_SETUP` and `VERIFY_OUT` must name the same evidence dir, because the job log path is part of `terminal_cmd`. `VERIFY_OUT` must be missing or empty.
- The `snacks` run needs snacks.nvim on the runtimepath. Pass it as launch arguments: `$V launch --cmd 'set rtp+=<dir>' hello.txt`.
