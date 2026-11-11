# plugin

## Overview

`plugin/` holds the Neovim runtime loader for claudecode.nvim. Neovim sources
`plugin/claudecode.lua` automatically at startup when the repository is on the
`runtimepath`. The file does not define commands or start the server itself.
It checks the Neovim version, sets a load guard, schedules an optional
auto-setup, and pre-loads the main module. User commands are registered only
when `require("claudecode").setup()` runs. The main module lives in
`lua/claudecode/` (see [`lua/claudecode/init.lua`](../lua/claudecode/init.lua)).

## Interface

- `vim.g.loaded_claudecode`: load guard. The file reads it and returns early if
  it is set. Otherwise it sets it to `1`.
  `[plugin/claudecode.lua:vim.g.loaded_claudecode]`
- `vim.g.claudecode_auto_setup`: optional user global. When it is truthy, its
  value is passed unchanged as the `opts` argument to
  `require("claudecode").setup(...)`. The file does not validate the type of
  the value. Example from the source comment:
  `vim.g.claudecode_auto_setup = { auto_start = true }`.
  `[plugin/claudecode.lua:vim.g.claudecode_auto_setup]`
- `require("claudecode")`: called in two places. At the end of the file it
  runs once with `pcall`, and the file does not call `setup` at this point.
  Inside the deferred auto-setup callback it runs without `pcall`.
  `[plugin/claudecode.lua:pcall(require, "claudecode")]`
  `[plugin/claudecode.lua:vim.defer_fn]`
- No Lua module table, functions, or user commands are exported from this
  directory. Commands come from `M._create_commands()`, which `M.setup` calls.
  `[lua/claudecode/init.lua:M._create_commands]`

## Invariants

- Neovim 0.8.0 or newer is required. On older versions the file writes an
  error and returns before it sets `vim.g.loaded_claudecode`.
  `[plugin/claudecode.lua:vim.fn.has]`
- After the first successful load, sourcing the file again does nothing,
  because `vim.g.loaded_claudecode` is already set. No auto-setup is scheduled
  and no `require` runs on the second source.
  `[plugin/claudecode.lua:vim.g.loaded_claudecode]`
- The file sets `vim.g.loaded_claudecode` before it schedules auto-setup and
  before it loads the main module. If the module fails to load, the guard stays
  set, so sourcing the file again does not retry the load.
  `[plugin/claudecode.lua:vim.g.loaded_claudecode]`
- Auto-setup is scheduled only when `vim.g.claudecode_auto_setup` is truthy.
  Without it, the user must call `require("claudecode").setup()` to get
  commands and the server. `[plugin/claudecode.lua:vim.g.claudecode_auto_setup]`
- The file reads `vim.g.claudecode_auto_setup` twice. The truthiness check runs
  while the file is sourced. The callback reads the global again when it runs,
  so `setup` gets the value the global holds at that moment.
  `[plugin/claudecode.lua:vim.defer_fn]`
- Order of execution: the version check, the load guard, the `vim.defer_fn`
  scheduling, and the `pcall(require, "claudecode")` run synchronously while
  the file is sourced. The deferred `setup` call runs later, after the current
  script finishes. `[plugin/claudecode.lua:vim.defer_fn]`
- Commands from auto-setup do not exist while startup scripts run, unless a
  script waits for events, for example with `:sleep` or `vim.wait()`. In a
  headless check on Neovim 0.12.3, `:ClaudeCode` was missing when the `-c`
  startup commands and `VimEnter` ran, and present after the deferred callback
  ran.
  `[plugin/claudecode.lua:vim.defer_fn]`
- The deferred `require("claudecode").setup(...)` call is not wrapped in
  `pcall`. An error from loading the module or from `M.setup` surfaces from the
  deferred callback. `[plugin/claudecode.lua:vim.defer_fn]`
- This file does not check whether `setup` already ran. If the user's config also
  calls `require("claudecode").setup()`, `setup` runs twice. `M.setup` does
  not check `M.state.initialized` before it applies the configuration.
  `[plugin/claudecode.lua:vim.defer_fn]` `[lua/claudecode/init.lua:M.setup]`

## Side Effects

- Sets the global `vim.g.loaded_claudecode = 1`.
  `[plugin/claudecode.lua:vim.g.loaded_claudecode]`
- On Neovim older than 0.8.0, writes
  `Claude Code requires Neovim >= 0.8.0` with `vim.api.nvim_err_writeln`.
  This path does not use `vim.notify` and has no log level. Because the version
  check runs before the load guard, every source on an old Neovim writes the
  message again. `[plugin/claudecode.lua:vim.api.nvim_err_writeln]`
- Loads the `claudecode` Lua module into `package.loaded` at startup. If the
  load fails, shows
  `ClaudeCode: Failed to load main module. Plugin may not function correctly.`
  with `vim.notify` at `vim.log.levels.ERROR`. A successful load shows no
  message. `[plugin/claudecode.lua:vim.notify]`
- When `vim.g.claudecode_auto_setup` is truthy, schedules
  `require("claudecode").setup(vim.g.claudecode_auto_setup)` with
  `vim.defer_fn(..., 0)`. `[plugin/claudecode.lua:vim.defer_fn]`
- The deferred `setup` call triggers the effects of `M.setup`: it applies the
  configuration, sets up the logger, terminal, and diff modules, warns when
  `focus_after_send` cannot work with the configured terminal provider, calls
  `M.start(false)` when `auto_start` is true, registers user commands, creates
  the `ClaudeCodeShutdown` augroup with a `VimLeavePre` autocmd, and sets
  `M.state.initialized = true`. `[lua/claudecode/init.lua:M.setup]`
  `[lua/claudecode/init.lua:M._maybe_warn_unfocusable_provider]`

## Verification

- Run: `mise run test` (or `mise run all` for format, lint, and test).
- No spec under `tests/` exercises `plugin/claudecode.lua` directly.
  `mise run test` runs Busted on `*_spec.lua` and `*_test.lua` files under
  LuaJIT, not inside Neovim.
- `mise run check` runs the syntax check on `lua/` and `luacheck` on `lua/` and
  `tests/`. Neither covers `plugin/claudecode.lua`. `mise run format` formats
  it with StyLua.
- `tests/minimal_init.lua` is the `-u` init file for headless Neovim test runs
  (`scripts/run_integration_tests_individually.sh`), not for `mise run test`.
  It calls
  `require("claudecode").setup({ auto_start = false, log_level = "trace" })`
  itself, and only when `vim.g.loaded_claudecode` is unset and `should_load` is
  true (the command line names `command_args_spec` or `mcp_tools_spec`, or
  `CLAUDECODE_INTEGRATION_TEST=true`).
- Manual check: `fixtures/repro/init.lua` puts this repository on the
  `runtimepath` so that `plugin/claudecode.lua` loads. It also calls `setup`
  itself, so it does not exercise auto-setup.
- Headless auto-setup check, run from the repository root. It prints `2` when
  the deferred `setup` has registered `:ClaudeCode`, and `0` without the
  `--cmd 'let g:claudecode_auto_setup ...'` line:

  ```sh
  nvim --headless -u NORC -i NONE --cmd "set rtp^=$PWD" \
    --cmd 'let g:claudecode_auto_setup = {"auto_start": v:false}' \
    -c 'lua vim.defer_fn(function() io.stdout:write(vim.fn.exists(":ClaudeCode") .. "\n") vim.cmd("qa!") end, 100)'
  ```
