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
- `require("claudecode")`: loaded once with `pcall` at the end of the file.
  The file does not call `setup` at this point.
  `[plugin/claudecode.lua:pcall(require, "claudecode")]`
- No Lua module table, functions, or user commands are exported from this
  directory. Commands come from `M._create_commands()`, which `M.setup` calls.
  `[lua/claudecode/init.lua:M._create_commands]`

## Invariants

- Neovim 0.8.0 or newer is required. On older versions the file writes an
  error and returns before it sets `vim.g.loaded_claudecode`.
  `[plugin/claudecode.lua:vim.fn.has]`
- After the first successful load, sourcing the file again does nothing,
  because `vim.g.loaded_claudecode` is already set.
  `[plugin/claudecode.lua:vim.g.loaded_claudecode]`
- Auto-setup is scheduled only when `vim.g.claudecode_auto_setup` is truthy.
  Without it, the user must call `require("claudecode").setup()` to get
  commands and the server. `[plugin/claudecode.lua:vim.g.claudecode_auto_setup]`
- Order of execution: the version check, the load guard, the `vim.defer_fn`
  scheduling, and the `pcall(require, "claudecode")` run synchronously while
  the file is sourced. The deferred `setup` call runs later, after the current
  script finishes. `[plugin/claudecode.lua:vim.defer_fn]`
- The deferred `setup` call is not wrapped in `pcall`. An error raised inside
  `M.setup` surfaces from the deferred callback.
  `[plugin/claudecode.lua:vim.defer_fn]`

## Side Effects

- Sets the global `vim.g.loaded_claudecode = 1`.
  `[plugin/claudecode.lua:vim.g.loaded_claudecode]`
- On Neovim older than 0.8.0, writes
  `Claude Code requires Neovim >= 0.8.0` with `vim.api.nvim_err_writeln`.
  `[plugin/claudecode.lua:vim.api.nvim_err_writeln]`
- Loads the `claudecode` Lua module into `package.loaded` at startup. If the
  load fails, shows an `ERROR` notification with `vim.notify`.
  `[plugin/claudecode.lua:vim.notify]`
- When `vim.g.claudecode_auto_setup` is set, schedules
  `require("claudecode").setup(vim.g.claudecode_auto_setup)` with
  `vim.defer_fn(..., 0)`. `[plugin/claudecode.lua:vim.defer_fn]`
- The deferred `setup` call triggers the effects of `M.setup`: it applies the
  configuration, sets up the logger, terminal, and diff modules, calls
  `M.start(false)` when `auto_start` is true, registers user commands, and
  creates the `ClaudeCodeShutdown` augroup with a `VimLeavePre` autocmd.
  `[lua/claudecode/init.lua:M.setup]`

## Verification

- Run: `mise run test`
- No spec under `tests/` exercises `plugin/claudecode.lua` directly. The test
  bootstrap `tests/minimal_init.lua` reads `vim.g.loaded_claudecode` but calls
  `require("claudecode").setup({ auto_start = false, log_level = "trace" })`
  itself.
- Manual check: `fixtures/repro/init.lua` puts this repository on the
  `runtimepath` so that `plugin/claudecode.lua` loads.
