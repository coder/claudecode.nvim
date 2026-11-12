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
- Avoid one-letter names; prefer explicit, testable functions.
- `openFile` write protection: rely only on buffer state that Neovim exposes, and on `new_file_buffers` (`lua/claudecode/tools/open_file.lua`), the one Lua record that stands in for an internal flag (BF_NEW). Do not add Lua-side tracking for another internal buffer flag Neovim has no API for, such as BF_NOTEDITED or BF_READERR. State that gap in `lua/claudecode/tools/README.md` instead.
- Claude terminal float and diffs: the plugin does not store who hid the float, and it does not show the float again after a diff (a diff in its own tab still calls `ensure_visible` in its original tab when it closes, as before). A diff hides the float only after a live check that a window of the terminal is a float in the diff's own tab (`hide_terminal_float_for_diff` in `lua/claudecode/diff.lua`). The user reopens it with `:ClaudeCode` or `:ClaudeCodeFocus`. Do not add a record of which diff hid the float or a step that restores it: such a record went stale when the user moved or closed the float.

## Code Shape

- Interfaces: put a function on a module table `M` only when another module, the documented Lua API or Neovim calls it. Everything else is `local`. Tests drive behavior through that interface. Do not add `M._name` hooks for tests.
- Modules: prefer few modules that each hide a lot. Merge a helper module into its only consumer. Do not add a module for one caller.
- Validation: check data once, where it comes in: `setup(opts)` in `config.lua`, user command arguments, MCP messages at the socket and at the tool handler, files, user callbacks, other plugins, and Neovim state at the start of an async callback. Below that point, use the data without re-checking it.
- One-off logic: write logic that has one call site where it is used. Keep a single-use function only when it is recursive, when it is a named algorithm (SHA-1, base64), or when inlining it turns early returns into flags or adds two levels of nesting.
- `pcall`: use it only where the callee can fail while the plugin's own code and state are correct: optional plugins, user callbacks, data from the socket or a file, file and process IO, and Neovim calls that can throw on valid input, above all in cleanup paths.
- Fail-closed checks on the auth token path stay, even where today's code cannot reach them.
- The Busted suite runs on a mock `vim`, which does not throw where Neovim does. Before you remove a `pcall` or a guard around a Neovim call, probe the call in real Neovim.
- Window cleanup: a cleanup closes, changes or deletes only a window, buffer or tab that the plugin can show it made. `:split`, `:vsplit` and `:tabnew` return no id and run the user's autocmds. So the current window after such a command is no proof of ownership, and neither is "the one new window". Deleting a buffer can close each window that shows it, so the same rule holds for those windows. Close without `force` a window that the plugin made: Neovim then refuses when the close would lose a modified buffer. Neovim does not refuse for a `buftype=nofile` buffer, so a close without `force` is still not safe for a window that the plugin cannot show it made. Today's `diff.lua` does not follow this rule yet, and a behavior-preserving refactor leaves that code as it is. Issue #528 has the cases.

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
