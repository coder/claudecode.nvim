# claudecode.terminal providers

## Overview

This directory holds the terminal providers that host the Claude Code CLI inside or outside Neovim. The dispatcher module `claudecode.terminal` ([`../terminal.lua`](../terminal.lua)) selects one provider, then forwards calls to it with a prepared command string, an env table, and an effective config. This directory also holds `paste_fix.lua`, a shim for a Neovim streamed-paste bug.

| Provider       | How Claude runs                                                |
| -------------- | -------------------------------------------------------------- |
| `native.lua`   | `vim.fn.termopen` in a split that the plugin manages           |
| `snacks.lua`   | `Snacks.terminal.open` from snacks.nvim                        |
| `external.lua` | `vim.fn.jobstart` with `detach = true`, running a user command |
| `none.lua`     | No-op. The user runs Claude Code themselves                    |

## Interface

### Provider contract

The dispatcher requires these 7 callable fields on a custom table provider [terminal.lua:validate_and_enhance_provider]:

- `setup(config)` [terminal/native.lua:M.setup]. `snacks.setup()` ignores its argument [terminal/snacks.lua:M.setup]. `none.setup` is a no-op [terminal/none.lua:M.setup]
- `open(cmd_string, env_table, effective_config, focus)` [terminal/native.lua:M.open]. `external.open(cmd_string, env_table)` ignores config and focus [terminal/external.lua:M.open]
- `close()` [terminal/native.lua:M.close]
- `simple_toggle(cmd_string, env_table, effective_config)` [terminal/native.lua:M.simple_toggle]
- `focus_toggle(cmd_string, env_table, effective_config)` [terminal/native.lua:M.focus_toggle]
- `get_active_bufnr() -> bufnr|nil`. `external` and `none` always return `nil` [terminal/external.lua:M.get_active_bufnr]
- `is_available() -> boolean`. `native`, `external`, and `none` always return `true` [terminal/snacks.lua:M.is_available]

Optional fields (the dispatcher does not require them):

- `toggle(...)`: a legacy alias of `simple_toggle`. All four providers define it. The dispatcher adds a default when it is missing [terminal/native.lua:M.toggle]
- `ensure_visible()`: defined as a no-op only in `external` and `none`. The dispatcher calls it only when present [terminal/external.lua:M.ensure_visible]
- `_get_terminal_for_test()`: defined in `snacks`, `external`, and `none`. `native` does not define it. `validate_and_enhance_provider` adds a default that returns `nil`, but only for a custom table provider. For a built-in provider, `M._get_managed_terminal_for_test` checks that the field exists and returns `nil` when it is missing [terminal/snacks.lua:M._get_terminal_for_test] [terminal.lua:M._get_managed_terminal_for_test]
- The provider type is declared as `ClaudeCodeTerminalProvider`. It declares `toggle` and `_get_terminal_for_test` as required (no `?`), so the type and the dispatcher disagree [types.lua:ClaudeCodeTerminalProvider]

### `paste_fix.lua`

- `is_affected_version() -> boolean`: true for Neovim before 0.12.2, including a 0.12.2 prerelease [terminal/paste_fix.lua:M.is_affected_version]
- `should_enable(opt) -> boolean`: maps `true`, `false`, or `"auto"`/`nil` [terminal/paste_fix.lua:M.should_enable]
- `install()`: installs the `vim.paste` wrapper once (idempotent) [terminal/paste_fix.lua:M.install]
- `apply(opt)`: sets the enabled flag and installs when enabled [terminal/paste_fix.lua:M.apply]
- Test helpers: `_accumulate(acc, lines)`, `_is_installed()`, and `_is_enabled()` [terminal/paste_fix.lua:M._accumulate]

## Invariants

- `external` tracks one job. It counts as running only when `jobid > 0`. `open` does nothing while a job is running [terminal/external.lua:is_valid]
- `external.open` refuses (ERROR notify) when `provider_opts.external_terminal_cmd` is unset. A string command must not be empty and must contain 1 or 2 `%s` placeholders. A function command must return a string or a table [terminal/external.lua:M.open]
- `external.open` runs the job in `vim.fn.getcwd()`. It calls `jobstart` through `pcall`. When `jobstart` raises (for example `E475` for a command that is not executable) or returns `0` or `-1`, it sends one ERROR notification, which includes the error text when `jobstart` raised, and clears `jobid` [terminal/external.lua:M.open]
- `native` clears `bufnr`, `winid`, and `jobid` when its buffer is invalid. It recovers `winid` by scanning windows that show the buffer [terminal/native.lua:is_valid]
- `native` sets `bufhidden=hide`, so the Claude job survives when its window closes [terminal/native.lua:open_terminal]. Hide closes the window without force, and the buffer stays alive [terminal/native.lua:hide_terminal]
- `native` calls `termopen` through `pcall`. Neovim raises `E475` for a command that is not executable, and returns `0` or `-1` instead when errors are silenced. When an autocmd deletes the new buffer before `termopen` runs, `native` skips `termopen` and treats it as a failure. When a `TermOpen` autocmd wipes the buffer after `termopen` started the job, the wipe also stops the job, and `native` treats it as a failure. On any of these failures `native` sends one ERROR notification, which includes the error text when `termopen` raised. Its callers (`M.open`, `M.simple_toggle`, and `M.focus_toggle`) send none. `native` also closes the new window, restores the original window, deletes the buffer it created, and clears its state. A buffer that an autocmd swapped into the split stays [terminal/native.lua:open_terminal]
- `native` shows the exit tip once per session when `show_native_term_exit_tip` is set [terminal/native.lua:open_terminal]
- `native` marks each terminal buffer it starts with `b:claudecode_native_terminal` [terminal/native.lua:open_terminal]. While it tracks no terminal, `open`, `simple_toggle`, and `focus_toggle` adopt a marked buffer that a window displays, and take its job id from `b:terminal_job_id`. They never adopt an unmarked terminal, even when its name contains `claude` [terminal/native.lua:adopt_existing_terminal]
- `snacks.is_available` requires snacks.nvim to load and `Snacks.terminal` to exist [terminal/snacks.lua:M.is_available]
- `snacks` reuses the tracked instance while `terminal:buf_valid()` is true. It passes an argv list from `utils.parse_command`, so no shell expands bracketed model aliases [terminal/snacks.lua:M.open]
- `snacks` calls `Snacks.terminal.open` through `pcall`. Snacks shows its window before it calls `termopen`, so `snacks` wraps `on_buf` to capture the instance and then calls any `on_buf` from `snacks_win_opts`. A start fails when `termopen` raises (for example `E475` for a command that is not executable) or when the buffer is not a terminal afterwards (`termopen` returns `-1` when errors are silenced). On a failed start `snacks` closes the Snacks window, deletes its scratch buffer, clears its state, and sends one ERROR notification with the first line of the error. The notification shows the command but not the env table [terminal/snacks.lua:M.open]
- `snacks` forces `auto_close = false` on the Snacks instance. It sets `start_insert` and `auto_insert` only when focusing and `auto_insert ~= false` [terminal/snacks.lua:build_opts]
- `snacks` overrides the instance's `hide`, `show`, and `toggle` methods and keeps the originals in `term._cc` [terminal/snacks.lua:patch_instance]
- `snacks` hides floats with `nvim_win_set_config({hide=true})` only on Neovim 0.10 and later. It closes split windows and re-creates them on show [terminal/snacks.lua:cc_hide]
- `paste_fix` decides at phase 1 whether a streamed paste targets the managed terminal. It replays the whole paste once as phase -1, inside the captured window if focus moved [terminal/paste_fix.lua:M.install]
- `paste_fix` passes other pastes, and all pastes while disabled, to the original `vim.paste` unchanged. `is_managed_terminal` reads `vim.bo[bufnr].buftype` outside `pcall`, so it throws for an invalid `bufnr`. Its only caller passes the current buffer [terminal/paste_fix.lua:is_managed_terminal]

## Side Effects

- `native` runs `vsplit`, shows a new listed buffer from `nvim_create_buf` in the split, then runs `vim.fn.termopen` in that buffer with the command, env, and cwd. This spawns the Claude process. When an autocmd swapped another buffer into the split, `native` shows its terminal buffer there after the start. It runs `startinsert` when focused and `auto_insert` is not `false` [terminal/native.lua:open_terminal]
- `native` on exit clears its state. With `auto_close` it closes the tracked window only if the window still shows the terminal buffer. When the buffer is invalid, it closes the tracked window without that check. It never closes the last window (the only non-floating window of the only tab page), which keeps showing the exited terminal [terminal/native.lua:open_terminal]
- `native.close` clears its state and the buffer's mark, so an `open` that runs during the wait starts a new terminal. It calls `jobstop`, and when `jobstop` reports a running job, it waits up to 1 s for the job to exit. A close from a `TermClose` autocmd does not wait, because the job already exited. It then force-deletes the terminal buffer. Neovim closes the other windows that show it, and the editor's last window stays and shows another buffer. This works for a visible, hidden, or adopted terminal [terminal/native.lua:close_terminal]
- `snacks` calls `Snacks.terminal.open`, which spawns the Claude process [terminal/snacks.lua:M.open]
- `snacks` always registers a buffer-local `BufWipeout` handler. It registers a buffer-local `TermClose` handler only when `auto_close` is true. `TermClose` runs `checktime` and logs an ERROR on a nonzero exit [terminal/snacks.lua:setup_terminal_events]
- `snacks` maps terminal-mode `<S-CR>` to send a backslash and then a carriage return after 10 ms [terminal/snacks.lua:build_opts]
- `snacks` sets window options and `vim.w[win].snacks_win` on re-created splits [terminal/snacks.lua:reapply_snacks_window_state]
- `external` spawns a detached process with `vim.fn.jobstart`. `close` calls `vim.fn.jobstop` [terminal/external.lua:M.close]
- `none` has no side effects [terminal/none.lua:M.open]
- `paste_fix.install` replaces the global `vim.paste` once. The dispatcher calls `paste_fix.apply(defaults.fix_streamed_paste)` during setup, and the default is `"auto"` [terminal.lua:M.setup]

## Verification

- Run: `mise run test`
- Targeted: `busted -v tests/unit/terminal/external_spec.lua`, `busted -v tests/unit/terminal/none_provider_spec.lua`, `busted -v tests/unit/terminal/paste_fix_spec.lua`, `busted -v tests/unit/terminal/snacks_spec.lua`, `busted -v tests/unit/terminal/snacks_toggle_spec.lua`, `busted -v tests/unit/terminal/snacks_failed_start_spec.lua`, `busted -v tests/unit/terminal/send_text_spec.lua`, `busted -v tests/unit/native_terminal_toggle_spec.lua`
