# Repository Guidelines

## Project Structure & Module Organization

- `lua/claudecode/`: Core plugin modules (`init.lua`, `config.lua`, `diff.lua`, `terminal/`, `server/`, `tools/`, `logger.lua`, etc.).
- `plugin/`: Lightweight loader that guards startup and optional auto-setup.
- `tests/`: Busted test suite (`unit/`, `integration/`, `helpers/`, `mocks/`).
- `fixtures/`: Minimal Neovim configs for manual and integration testing.
- `scripts/`: Development helpers; `dev-config.lua` aids local testing.

## Build, Test, and Development Commands

- Setup (one time): install [mise](https://mise.jdx.dev), then `mise install && mise run setup` to provision the toolchain and build the Lua test rocks. Activate mise in your shell (`eval "$(mise activate bash)"` in your rc) so bare tools like `busted`/`nvim` are on PATH; otherwise prefix with `mise exec --`. Run `mise tasks` to list all tasks.
- `mise run check`: Syntax checks + `luacheck` on `lua/` and `tests/`.
- `mise run format`: Format the tree with treefmt (replaces the former `nix fmt`).
- `mise run test`: Run Busted tests with coverage (outputs `luacov.stats.out`).
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
