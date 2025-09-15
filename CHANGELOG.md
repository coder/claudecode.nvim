# Changelog

## [0.3.0] - 2025-09-15

### Features

- External terminal provider to run Claude in a separate terminal ([#102](https://github.com/coder/claudecode.nvim/pull/102))
- Terminal provider APIs: implement `ensure_visible` for reliability ([#103](https://github.com/coder/claudecode.nvim/pull/103))
- Working directory control for Claude terminal ([#117](https://github.com/coder/claudecode.nvim/pull/117))
- Support function values for `external_terminal_cmd` for dynamic commands ([#119](https://github.com/coder/claudecode.nvim/pull/119))
- Add `"none"` terminal provider option for external CLI management ([#130](https://github.com/coder/claudecode.nvim/pull/130))
- Shift+Enter keybinding for newline in terminal input ([#116](https://github.com/coder/claudecode.nvim/pull/116))
- `focus_after_send` option to control focus after sending to Claude ([#118](https://github.com/coder/claudecode.nvim/pull/118))
- Snacks: `snacks_win_opts` to override `Snacks.terminal.open()` options ([#65](https://github.com/coder/claudecode.nvim/pull/65))
- Terminal/external quality: CWD support, stricter placeholder parsing, and `jobstart` CWD (commit e21a837)

- Diff UX redesign with horizontal layout and new tab options ([#111](https://github.com/coder/claudecode.nvim/pull/111))
- Prevent diff on dirty buffers ([#104](https://github.com/coder/claudecode.nvim/pull/104))
- `keep_terminal_focus` option for diff views ([#95](https://github.com/coder/claudecode.nvim/pull/95))
- Control behavior when rejecting “new file” diffs ([#114](https://github.com/coder/claudecode.nvim/pull/114))

- Add Claude Haiku model + updated type annotations ([#110](https://github.com/coder/claudecode.nvim/pull/110))
- `CLAUDE_CONFIG_DIR` environment variable support ([#58](https://github.com/coder/claudecode.nvim/pull/58))
- `PartialClaudeCodeConfig` type for safer partial configs ([#115](https://github.com/coder/claudecode.nvim/pull/115))
- Generalize format hook; add floating window docs (commit 7e894e9)
- Add env configuration option; fix `vim.notify` scheduling ([#21](https://github.com/coder/claudecode.nvim/pull/21))

- WebSocket authentication (UUID tokens) for the server ([#56](https://github.com/coder/claudecode.nvim/pull/56))
- MCP tools compliance aligned with VS Code specs ([#57](https://github.com/coder/claudecode.nvim/pull/57))

- Mini.files integration and follow-up touch-ups ([#89](https://github.com/coder/claudecode.nvim/pull/89), [#98](https://github.com/coder/claudecode.nvim/pull/98))

### Bug Fixes

- Wrap ERROR/WARN logging in `vim.schedule` to avoid fast-event context errors ([#54](https://github.com/coder/claudecode.nvim/pull/54))
- Native terminal: do not wipe Claude buffer on window close ([#60](https://github.com/coder/claudecode.nvim/pull/60))
- Native terminal: respect `auto_close` behavior ([#63](https://github.com/coder/claudecode.nvim/pull/63))
- Snacks integration: fix invalid window with `:ClaudeCodeFocus` ([#64](https://github.com/coder/claudecode.nvim/pull/64))
- Debounce update on selection for stability ([#92](https://github.com/coder/claudecode.nvim/pull/92))

### Documentation

- Update PROTOCOL.md with complete VS Code tool specs; streamline README ([#55](https://github.com/coder/claudecode.nvim/pull/55))
- Convert configuration examples to collapsible sections; add community extensions ([#93](https://github.com/coder/claudecode.nvim/pull/93))
- Local and native binary installation guide ([#94](https://github.com/coder/claudecode.nvim/pull/94))
- Auto-save plugin note and fix ([#106](https://github.com/coder/claudecode.nvim/pull/106))
- Add AGENTS.md and improve config validation notes (commit 3e2601f)

### Refactors & Development

- Centralize type definitions in dedicated `types.lua` module ([#108](https://github.com/coder/claudecode.nvim/pull/108))
- Devcontainer with Nix support; follow-up simplification ([#112](https://github.com/coder/claudecode.nvim/pull/112), [#113](https://github.com/coder/claudecode.nvim/pull/113))
- Add Neovim test fixture configs and helper scripts (commit 35bb60f)
- Update Nix dependencies and documentation formatting (commit a01b9dc)
- Debounce/Claude hooks refactor (commit e08921f)

### New Contributors

- @alvarosevilla95 — first contribution in [#60](https://github.com/coder/claudecode.nvim/pull/60)
- @qw457812 — first contribution in [#64](https://github.com/coder/claudecode.nvim/pull/64)
- @jdurand — first contribution in [#89](https://github.com/coder/claudecode.nvim/pull/89)
- @marcinjahn — first contribution in [#102](https://github.com/coder/claudecode.nvim/pull/102)
- @proofer — first contribution in [#98](https://github.com/coder/claudecode.nvim/pull/98)
- @ehaynes99 — first contribution in [#106](https://github.com/coder/claudecode.nvim/pull/106)
- @rpbaptist — first contribution in [#92](https://github.com/coder/claudecode.nvim/pull/92)
- @nerdo — first contribution in [#78](https://github.com/coder/claudecode.nvim/pull/78)
- @totalolage — first contribution in [#21](https://github.com/coder/claudecode.nvim/pull/21)
- @TheLazyLemur — first contribution in [#18](https://github.com/coder/claudecode.nvim/pull/18)
- @nabekou29 — first contribution in [#58](https://github.com/coder/claudecode.nvim/pull/58)

### Full Changelog

- <https://github.com/coder/claudecode.nvim/compare/v0.2.0...v0.3.0>

## [0.2.0] - 2025-06-18

### Features

- **Diagnostics Integration**: Added comprehensive diagnostics tool that provides Claude with access to LSP diagnostics information ([#34](https://github.com/coder/claudecode.nvim/pull/34))
- **File Explorer Integration**: Added support for oil.nvim, nvim-tree, and neotree with @-mention file selection capabilities ([#27](https://github.com/coder/claudecode.nvim/pull/27), [#22](https://github.com/coder/claudecode.nvim/pull/22))
- **Enhanced Terminal Management**:
  - Added `ClaudeCodeFocus` command for smart toggle behavior ([#40](https://github.com/coder/claudecode.nvim/pull/40))
  - Implemented auto terminal provider detection ([#36](https://github.com/coder/claudecode.nvim/pull/36))
  - Added configurable auto-close and enhanced terminal architecture ([#31](https://github.com/coder/claudecode.nvim/pull/31))
- **Customizable Diff Keymaps**: Made diff keymaps adjustable via LazyVim spec ([#47](https://github.com/coder/claudecode.nvim/pull/47))

### Bug Fixes

- **Terminal Focus**: Fixed terminal focus error when buffer is hidden ([#43](https://github.com/coder/claudecode.nvim/pull/43))
- **Diff Acceptance**: Improved unified diff acceptance behavior using signal-based approach instead of direct file writes ([#41](https://github.com/coder/claudecode.nvim/pull/41))
- **Syntax Highlighting**: Fixed missing syntax highlighting in proposed diff view ([#32](https://github.com/coder/claudecode.nvim/pull/32))
- **Visual Selection**: Fixed visual selection range handling for `:'\<,'\>ClaudeCodeSend` ([#26](https://github.com/coder/claudecode.nvim/pull/26))
- **Native Terminal**: Implemented `bufhidden=hide` for native terminal toggle ([#39](https://github.com/coder/claudecode.nvim/pull/39))

### Development Improvements

- **Testing Infrastructure**: Moved test runner from shell script to Makefile for better development experience ([#37](https://github.com/coder/claudecode.nvim/pull/37))
- **CI/CD**: Added Claude Code GitHub Workflow ([#2](https://github.com/coder/claudecode.nvim/pull/2))

## [0.1.0] - 2025-06-02

### Initial Release

First public release of claudecode.nvim - the first Neovim IDE integration for
Claude Code.

#### Features

- Pure Lua WebSocket server (RFC 6455 compliant) with zero dependencies
- Full MCP (Model Context Protocol) implementation compatible with official extensions
- Interactive terminal integration for Claude Code CLI
- Real-time selection tracking and context sharing
- Native Neovim diff support for code changes
- Visual selection sending with `:ClaudeCodeSend` command
- Automatic server lifecycle management

#### Commands

- `:ClaudeCode` - Toggle Claude terminal
- `:ClaudeCodeSend` - Send visual selection to Claude
- `:ClaudeCodeOpen` - Open/focus Claude terminal
- `:ClaudeCodeClose` - Close Claude terminal

#### Requirements

- Neovim >= 0.8.0
- Claude Code CLI
