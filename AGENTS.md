# Repository Guidelines

## Project Structure & Module Organization

- `lua/claudecode/`: Core plugin modules (`init.lua`, `config.lua`, `diff.lua`, `terminal/`, `server/`, `tools/`, `logger.lua`, etc.).
- `plugin/`: Lightweight loader that guards startup and optional auto-setup.
- `tests/`: Busted test suite (`unit/`, `integration/`, `helpers/`, `mocks/`, and `bin/` with a stub `claude` that is first on `PATH` in every test).
- `fixtures/`: Minimal Neovim configs for manual and integration testing.
- `scripts/`: Development and release helpers.
- `dev-config.lua` (repo root): lazy.nvim spec for local development.

## Build, Test, and Development Commands

- Setup (one time): install [mise](https://mise.jdx.dev), then `mise install && mise run setup` to provision the toolchain and build the Lua test rocks. Activate mise in your shell (`eval "$(mise activate bash)"` in your rc) so bare tools like `busted`/`nvim` are on PATH; otherwise prefix with `mise exec --`. Run `mise tasks` to list all tasks.
- `mise run check`: Syntax checks + `luacheck` on `lua/` and `tests/`.
- `mise run format`: Format the tree with treefmt (replaces the former `nix fmt`).
- `mise run test`: Run Busted tests with coverage (outputs `luacov.stats.out`; `.luacov` limits it to `lua/claudecode/` and `plugin/`) in a random order. It prints the seed, and `BUSTED_SEED=<seed> mise run test` repeats that order. A test registered inside a `pairs()` loop fails the run (`tests/helpers/test_order.lua`, loaded by `.busted` through `tests/helpers/busted_helper.lua`).
- `mise run clean`: Remove coverage artifacts.
  Examples:
- Run all tests: `mise run test`
- Run one file: `busted -v tests/unit/terminal_spec.lua`

## Coding Style & Naming Conventions

- Lua: 2‑space indent, 120‑column width, double quotes preferred.
- Formatting: StyLua configured in `.stylua.toml` (require-sort enabled).
- Linting: `luacheck` with settings in `.luacheckrc` (uses `luajit+busted` std).
- Modules/files: lower_snake_case; return a module table `M` with documented functions (EmmyLua annotations encouraged).
- Avoid one-letter names.
- `openFile` write protection: rely only on buffer state that Neovim exposes, and on `new_file_buffers` (`lua/claudecode/tools/open_file.lua`), the one Lua record that stands in for an internal flag (BF_NEW). Do not add Lua-side tracking for another internal buffer flag Neovim has no API for, such as BF_NOTEDITED or BF_READERR. State that gap in `lua/claudecode/tools/README.md` instead.
- Claude terminal float and diffs: the plugin does not store who hid the float, and it does not show the float again after a diff (a diff in its own tab still calls `ensure_visible` in its original tab when it closes, as before). A diff hides the float only after a live check that a window of the terminal is a float in the diff's own tab (`hide_terminal_float_for_diff` in `lua/claudecode/diff.lua`). The user reopens it with `:ClaudeCode` or `:ClaudeCodeFocus`. Do not add a record of which diff hid the float or a step that restores it: such a record went stale when the user moved or closed the float.

## Code Shape

- Interfaces: put a function on a module table `M` only when another module, the documented Lua API or Neovim calls it. Everything else is `local`. Tests drive behavior through that interface. Do not add `M._name` hooks for tests.
- Modules: prefer few modules that each hide a lot. Merge a helper module into its only consumer. Do not add a module for one caller. A module that the README tells users to `require` (`claudecode.cwd`) is documented Lua API, not a helper: keep it.
- Validation: check data once, where it comes in: the options of `setup(opts)` in `config.apply` (`config.lua`), user command arguments, MCP messages at the socket and at the tool handler, files, user callbacks, other plugins, and Neovim state at the start of an async callback and after a call that runs the user's autocmds. Below that point, use the data without re-checking it. Of the `terminal.*` options, `config.apply` checks only `provider_opts`. `terminal.setup` checks the other keys, and `diff.lua` checks the split widths where it reads them from the raw options. So `config.apply` is no reason to remove a check of a `terminal.*` value.
- One-off logic: write logic that has one call site where it is used. Keep a single-use function only when it is recursive, when it is a named algorithm (SHA-1, base64), or when inlining it turns early returns into flags or adds two levels of nesting.
- `pcall`: use it only where the callee can fail while the plugin's own code and state are correct: optional plugins, user callbacks, data from the socket or a file, file and process IO, and Neovim calls that can throw on valid input, above all in cleanup paths.
- Fail-closed checks on the auth token path stay, even where today's code cannot reach them.
- The Busted suite runs on a mock `vim`, which does not throw where Neovim does. Before you remove a `pcall` or a guard around a Neovim call, probe the call in real Neovim. Probe it with a user autocmd that raises, too: a clean Neovim does not show that `nvim_win_close` throws when a `WinClosed` or `WinLeave` handler raises. Probe it under textlock and in the command-line window as well, on both Neovim versions that CI runs. With no handler at all, `nvim_win_close` and `nvim_buf_delete` throw under textlock. In the command-line window, the result depends on the call, on the Neovim version and on which window the call closes, so probe the exact call there. Probe it with 'verbose' above 0 as well (`:verbose`, `nvim -V1`): `vim.fn.expand("<abuf>")` outside an autocmd gives "" with 'verbose' at 0, and raises E496 with it above 0 (under `:silent!` it gives "" and sets v:errmsg instead), so the test for "inside an autocmd" (`inside_autocmd` in `lua/claudecode/utils.lua`) wraps it in `pcall` and gives v:errmsg back as it was.
- Window cleanup: a cleanup closes, changes or deletes only a window, buffer or tab that the plugin can show it made. `:split`, `:vsplit` and `:tabnew` return no id and run the user's autocmds. So the current window after such a command is no proof of ownership, and neither is "the one new window". Deleting a buffer can close each window that shows it, so the same rule holds for those windows. Close without `force` a window that the plugin made: Neovim then refuses when the close would lose a modified buffer. Neovim does not refuse for a `buftype=nofile` buffer, so a close without `force` is still not safe for a window that the plugin cannot show it made. Today's `diff.lua` does not follow this rule yet, and a behavior-preserving refactor leaves that code as it is. Issue #528 has the cases.
- Terminal placement: show a Claude terminal in the split that the plugin just made with `utils.win_set_buf_in_split`, not with `nvim_win_set_buf`. A `BufLeave` autocmd of the user's that enters another window inside `nvim_win_set_buf` makes Neovim load the buffer into that window. The helper fires `BufLeave` of the old buffer by hand, with `:doautocmd <nomodeline> BufLeave`, in the split, while the buffer still shows there, and only outside an autocmd. Neovim holds no buffer locked while it fires its own `BufLeave`, and `:doautocmd` passes on the error of a handler as a swap does. The helper puts the cursor back in the split when an autocmd moved it, then swaps with `BufLeave` and `OptionSet` in 'eventignore' (`:noautocmd` sets the user's value again, with no `OptionSet`), so Neovim fires every other event itself, after the `BufLeave` autocmds are done. Do not fire `BufWinLeave`, `BufHidden` or `BufUnload` by hand, and do not use `nvim_exec_autocmds` for any of them. Neovim holds the buffer locked while it fires them, so a hand-fired one lets a user's handler wipe a buffer that Neovim refuses to wipe (E937), and it decides the window count once, before a user's `BufLeave` autocmd can close or show a window. Do not enter another window to let Neovim fire the leave events: `BufLeave` then runs in the window of the user's file, where a non-nested autocmd that closes the window makes Neovim fire no `BufWinLeave` or `BufHidden`, and the extra `WinEnter` runs the user's `startinsert` autocmds with the terminal in the split. Do not add a step after a plain swap that puts the terminal back either: a repair of a window that Neovim's own window count no longer matches raised E37, unloaded the user's file, hung or crashed Neovim, depending on 'hidden' and 'bufhidden'. When a `BufLeave` autocmd closes the split, the helper shows nothing and returns false, and the provider leaves the terminal hidden and logs nothing (a show without focus puts the cursor back in the window it started in, when that window still exists). A provider reads its record of the terminal's buffer (`bufnr` in `native.lua`, `term.buf` in `snacks.lua`) into a local before the split and the swap, because a user autocmd of either can close Claude, which clears the record. A buffer in the split that a plain swap leaves loaded and hidden (any buffer that an autocmd of `BufLeave` showed there, a terminal, a scratch buffer, a changed or an unchanged file, or the old buffer when an autocmd closed its other window and it is changed) would be unloaded or wiped by `buffer!` when 'hidden' is off or its 'bufhidden' is `unload`, `delete` or `wipe`, with its text or its job. The helper sets that buffer's 'bufhidden' to `hide` for the swap, with `:noautocmd` (a plain assignment runs the user's `OptionSet` autocmds), and gives the old value back after the swap, also when the swap raises. Do not return false for such a buffer, and do not use `:buffer` without `!` (E37 or the 'confirm' dialog). A diff in a new tab enters the new tab again when the helper returns false, because an autocmd of `BufLeave` can have entered a window in another tab. Do not add a log line, or a check of the split or the buffer after the swap, for a close that a user autocmd made.

## Testing Guidelines

- Frameworks: Busted + Luassert; Plenary used where Neovim APIs are needed.
- File naming: `*_spec.lua` or `*_test.lua` under `tests/unit` or `tests/integration`.
- Mocks/helpers: place in `tests/mocks` and `tests/helpers`; prefer pure‑Lua mocks.
- Coverage: keep high signal; exercise server, tools, diff, and terminal paths.
- Quick tip: prefer `mise run test` (it sets `LUA_PATH` and coverage flags).

## Commit & Pull Request Guidelines

- Commits: Use Conventional Commits (e.g., `feat:`, `fix:`, `docs:`, `test:`, `chore:`). Keep messages imperative and scoped.
- PRs: include a clear description, linked issues, repro steps, and tests. Update docs (`README.md`, `ARCHITECTURE.md`, or `DEVELOPMENT.md`) when behavior changes.
- Pre-flight: run `mise run all` (format, lint, test). Attach screenshots or terminal recordings for UX-visible changes (diff flows, terminal behavior).

## Security & Configuration Tips

- Do not commit secrets or local paths; prefer environment variables. The plugin honors `CLAUDE_CONFIG_DIR` for lock files.
- Local CLI paths (e.g., `opts.terminal_cmd`) should be configured in user config, not hardcoded in repo files.
- Wire probe cleanup: `.agents/skills/verify-claudecode-nvim/scripts/proof-tools-call-wire.sh` starts a test server that writes its auth token to a lock file. Keep its one cleanup rule: nvim is a direct child of the script, checks its parent every half second and stops its server when the parent is gone. So the lock file is gone within 5 seconds after the script ends, as long as nvim is still alive and its main loop runs. The script's own cleanup is only the faster path. Do not add a second cleanup mechanism. `features/tools-call-wire.md` in that skill states the limits.
