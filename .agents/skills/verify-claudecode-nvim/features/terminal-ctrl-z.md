# Suspend Neovim with Ctrl-Z in the Claude terminal

Ctrl-Z in the Claude terminal suspends Neovim, as it does in any other window, and never reaches the Claude job. A terminal passes Ctrl-Z to its job, and Claude Code then suspends itself with nothing in a Neovim terminal to resume it (#194). The `native` and `snacks` providers map `<C-z>` in terminal mode, on the Claude terminal buffer only, to `:suspend`. A `FileType claudecode` autocmd can replace the mapping.

## Sub-features

- `ctrl-z-mapping` maps `<C-z>` in terminal mode on the Claude terminal buffer, once, and on no other buffer.
- `ctrl-z-suspends-neovim` runs `:suspend` on Ctrl-Z in the Claude terminal, as Ctrl-Z in a normal window does. In a shell, Neovim stops and `fg` resumes it in terminal mode.
- `ctrl-z-skips-job` keeps the Ctrl-Z byte (0x1a) from the Claude job, so the job is never stopped.
- `ctrl-z-user-override` keeps a buffer-local `<C-z>` mapping that a `FileType claudecode` handler sets.

## How to get to it (user POV)

- The user opens the Claude terminal with `:ClaudeCode` and presses Ctrl-Z in terminal mode.

## Driving it with vcn.sh

Preconditions:

- `provider = "native"` or `provider = "snacks"`. The snacks provider needs a snacks.nvim checkout (`SNACKS_DIR`). Clone it into scratch and record its commit.
- A stand-in job for the Claude CLI: `scripts/ctrl-z-probe-job.mjs <log>`. It puts its terminal in raw mode, logs each byte it reads, and stops itself on 0x1a, the way Claude Code does. Never start the real `claude` CLI.
- `python3` for the real-stop phase.

Steps:

- **Whole proof.** Run `SNACKS_DIR=<snacks.nvim checkout> .agents/skills/verify-claudecode-nvim/scripts/proof-ctrl-z-suspend.sh native` and the same with `snacks`. The script launches its own run, so it needs no `$V launch` first. It prints one `ok` or `FAIL` line per check, ends with `CHECKS <n> FAILED <k>`, and exits 1 on a failure. Phase 1 runs in vcn.sh and checks the mapping, the `VimSuspend` count, and the job's byte log. Phase 2 is `scripts/proof-ctrl-z-stop.py`, which runs nvim as a foreground job of `bash -i` in a pty. Ctrl-Z must stop nvim (state `T`) while the job stays in state `S` and never reads 0x1a. `fg` must resume nvim in terminal mode, and a typed key must reach the job. The control, Ctrl-Z in a normal window, must stop nvim the same way. Evidence lands in `$VERIFY_OUT` (default `$XUM_SCRATCH_DIR/verify-claudecode-nvim/ctrl-z-<provider>-<time>`) as `ctrl-z-<provider>-*`. Phase 1 writes the job log, the process states, one screen text and one PNG of the open terminal, and `pty/` holds the phase 2 job log, process states, the shell transcript (it shows the `Stopped` line) and the raw pty output.
- **Phase 2 alone.** Run `python3 .agents/skills/verify-claudecode-nvim/scripts/proof-ctrl-z-stop.py --provider native --repo "$PWD" --nvim "$(mise which nvim)" --node "$(mise which node)" --out <new dir>`. For `snacks`, add `--snacks <snacks.nvim checkout>`.
- **By hand.** Launch with `VERIFY_OUT=<new dir> VCN_SETUP="$(jq -nc --arg cmd "$(mise which node) $PWD/.agents/skills/verify-claudecode-nvim/scripts/ctrl-z-probe-job.mjs <new dir>/job.log" '{terminal:{provider:"native"},terminal_cmd:$cmd}')" $V launch`. Run `$V keys ':ClaudeCode' Enter` and `$V until 'mode()' t`. `$V expr 'maparg("<C-z>", "t")'` prints `<Cmd>suspend<CR>`. Run `$V keys Ctrl+Z`. The job log has no `bytes 1a` line, and `$V expr 'mode()'` still prints `t`.
- **Control.** Register `:autocmd VimSuspend * let g:suspends += 1` after `:let g:suspends = 0`. Ctrl-Z in the Claude terminal and Ctrl-Z in a normal window each add one to `g:suspends`.

## Gotchas

- Neovim 0.12 answers `:suspend` by sending itself SIGSTOP, but only after the terminal replies to the Primary Device Attributes query (`ESC [ c`). agent-tty sends no reply, so nvim in a vcn.sh run never stops, not even for Ctrl-Z in a normal window. The nvim screen also stops updating after the first `:suspend`, so capture the terminal before the first Ctrl-Z. Count `VimSuspend` events there, and use `proof-ctrl-z-stop.py` to see the stop. A process group that is orphaned does not explain it, because the kernel cannot drop SIGSTOP.
- The pty in `proof-ctrl-z-stop.py` replies `ESC [ ? 62 ; c` to that query. Without the reply, nvim waits at `:suspend` and never stops. The script signals only the shell, nvim, the nvim server and the job it started, and it kills them at the end.
- The probe job must stop itself with SIGSTOP. The Claude job leads its own session, so its process group is orphaned, and the kernel drops a default-action SIGTSTP for it. `ctrl-z-probe-job.mjs` sends SIGSTOP, and the job's process state shows `T` after a Ctrl-Z that reached it.
- The `terminal_cmd` must use absolute paths. nvim runs with `PATH=/usr/bin:/bin`, so a bare `node` is not found.
- `VCN_SETUP` and `VERIFY_OUT` must name the same evidence dir, because the job log path is part of `terminal_cmd`. `VERIFY_OUT` must be missing or empty.
- The `snacks` run needs snacks.nvim on the runtimepath. Pass it as launch arguments: `$V launch --cmd 'set rtp+=<dir>' hello.txt`.
