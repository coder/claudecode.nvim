# Changelog

## [Unreleased]

## [0.4.0] - 2026-10-24

### Added

- `:ClaudeCodeSendText {text}` command and `require("claudecode.terminal").send_to_terminal(text, opts)` to send arbitrary text to the open Claude pane as if typed at the prompt; `:ClaudeCodeSendText!` inserts without submitting. In-editor providers (`native`/`snacks`) only. ([#272](https://github.com/coder/claudecode.nvim/pull/272))
- `User ClaudeCodeSendComplete` autocmd fired once per file when a send is accepted while Claude is connected, with `data = { file_path, start_line, end_line, context }` (lines 0-indexed) — lets external-terminal users focus their own session (e.g. via `tmux select-pane`). ([#265](https://github.com/coder/claudecode.nvim/pull/265))
- `:ClaudeCodeCloseAllDiffs` command to close pending Claude diffs at once; already-accepted-but-unwritten diffs are left intact. ([#261](https://github.com/coder/claudecode.nvim/pull/261))
- `:checkhealth claudecode` health check covering Neovim version, `setup()`, Claude CLI resolution, terminal provider, WebSocket server, lock file, and client connection. ([#275](https://github.com/coder/claudecode.nvim/pull/275))
- `diff_opts.layout = "unified"`: a VS Code-style unified diff rendered in a single buffer with deleted and added lines interleaved; customizable `ClaudeCodeInlineDiff*` highlight groups. Requires Neovim >= 0.9.0. ([#195](https://github.com/coder/claudecode.nvim/pull/195), [#295](https://github.com/coder/claudecode.nvim/pull/295), [#297](https://github.com/coder/claudecode.nvim/pull/297))
- `terminal.auto_insert` option (default `true`): set to `false` to stay in Normal mode when refocusing the Claude terminal, preserving scroll position. ([#233](https://github.com/coder/claudecode.nvim/pull/233))
- `terminal.diff_split_width_percentage` and `diff_opts.auto_resize_terminal`, plus `User ClaudeCodeDiffOpened` / `ClaudeCodeDiffClosed` autocmds for reacting to diff lifecycle. ([#270](https://github.com/coder/claudecode.nvim/pull/270))
- Netrw file selection for @-mentions via `<leader>as` (marked files or file under cursor). ([#62](https://github.com/coder/claudecode.nvim/pull/62))
- `:ClaudeCodeTreeAdd` support in snacks.nvim pickers (`snacks_picker_list`), including `Snacks.explorer()` and modal pickers. ([#269](https://github.com/coder/claudecode.nvim/pull/269))
- `terminal.fix_streamed_paste` option (`"auto"` by default) working around a Neovim < 0.12.2 bracketed-paste fragmentation bug. ([#252](https://github.com/coder/claudecode.nvim/pull/252))

### Fixed

- `closeAllDiffTabs` is now scoped to claudecode's own tracked diffs and no longer destroys open diffview.nvim, fugitive, or native `:diffsplit` reviews; `openFile`/`openDiff` also no longer reuse windows in diff mode. ([#290](https://github.com/coder/claudecode.nvim/pull/290))
- The Claude terminal now adds loopback hosts to `no_proxy`/`NO_PROXY`, so a configured `http_proxy`/`all_proxy` no longer tunnels Claude's `ws://127.0.0.1` IDE connection and times out queued @ mentions. ([#268](https://github.com/coder/claudecode.nvim/pull/268))
- Fixed the "climbing cursor" in the Snacks terminal on hide/show toggle, so typed text no longer lands on the wrong line. Splits fixed on all versions; float fix requires Neovim >= 0.10. ([#271](https://github.com/coder/claudecode.nvim/pull/271))
- Rejecting a Claude diff with `:q` / `:close` / `<C-w>c` now resolves it as rejected via a `WinClosed` autocmd. ([#266](https://github.com/coder/claudecode.nvim/pull/266))
- Quickly-made visual selections (single-line `viw`/`v$`/`V`, mouse) are now pushed to Claude reliably, flushed synchronously on visual-mode exit and persisting until the cursor moves. ([#267](https://github.com/coder/claudecode.nvim/pull/267))
- Diffs opened via `openDiff` are now auto-closed when the client that opened them disconnects or the integration stops, instead of lingering forever. ([#261](https://github.com/coder/claudecode.nvim/pull/261))
- Diffs now open when the Claude terminal is the only window, creating a split instead of failing with "No suitable editor window found". ([#260](https://github.com/coder/claudecode.nvim/pull/260))
- Fixed a segfault (exit 139) when accepting a new-file diff with `render-markdown.nvim` installed. ([#224](https://github.com/coder/claudecode.nvim/pull/224))
- `ClaudeCodeSend` now classifies tree buffers by filetype only, so an ordinary file whose path contains `neo-tree`/`NvimTree` is no longer misrouted. ([#292](https://github.com/coder/claudecode.nvim/pull/292))
- Snacks Explorer and picker windows are excluded from main-editor-window detection, so diffs no longer open on top of the explorer. ([#255](https://github.com/coder/claudecode.nvim/pull/255), [#165](https://github.com/coder/claudecode.nvim/pull/165))
- Legacy `vertical_split` / `open_in_current_tab` diff options now apply correctly again (merge-order bug). ([#142](https://github.com/coder/claudecode.nvim/pull/142))
- Handle `$` in file paths for `ClaudeCodeAdd` and `openFile`. ([#286](https://github.com/coder/claudecode.nvim/pull/286))
- `getDiagnostics` now accepts a bare file path (no `file://` schema), which Claude frequently sends. ([#163](https://github.com/coder/claudecode.nvim/pull/163))
- IDE diagnostics now return grouped, URI-based payloads with editor-native ranges and severity names; the unsupported resources capability is no longer advertised, and background file opens preserve focus. ([#274](https://github.com/coder/claudecode.nvim/pull/274))
- `keep_terminal_focus` now works for floating Claude terminals. ([#178](https://github.com/coder/claudecode.nvim/pull/178))
- Plugin-created diff splits are now closed deterministically on cleanup, preventing leftover windows. ([#175](https://github.com/coder/claudecode.nvim/pull/175))
- A stranded empty tab is now closed when `open_in_new_tab` diff setup errors before the diff registers. ([#264](https://github.com/coder/claudecode.nvim/pull/264))
- Empty scratch buffer is wiped when the terminal provider is `none`. ([#223](https://github.com/coder/claudecode.nvim/pull/223))
- `focus_after_send = true` now emits a one-time warning with `provider = "none"`/`"external"` (where it cannot focus), pointing at the new `ClaudeCodeSendComplete` event. ([#265](https://github.com/coder/claudecode.nvim/pull/265))
- The WebSocket server now closes connections on malformed frames instead of stalling, and fires `on_disconnect` on all teardown paths to prevent phantom clients. ([#258](https://github.com/coder/claudecode.nvim/pull/258), [#176](https://github.com/coder/claudecode.nvim/pull/176))
- Port binding now retries on `EADDRINUSE`, so parallel Neovim instances start on different ports instead of colliding. ([#284](https://github.com/coder/claudecode.nvim/pull/284))
- System sleep is detected to prevent false keepalive timeouts and disconnections on wake. ([#141](https://github.com/coder/claudecode.nvim/pull/141))
- Selection updates are now also sent on `BufEnter`, and external-terminal (`provider = "none"`) buffers are correctly skipped via substring matching. ([#159](https://github.com/coder/claudecode.nvim/pull/159), [#160](https://github.com/coder/claudecode.nvim/pull/160))

### Changed

- Modernized the `:ClaudeCodeSelectModel` picker with version-free labels (`Claude Opus (Latest)`, etc.), 1M-context variants, and a `Default (account recommended)` entry. ([#256](https://github.com/coder/claudecode.nvim/pull/256))
- The Snacks provider now launches Claude via an argv list instead of a shell string, fixing a zsh glob bug that broke 1M-context model aliases. ([#256](https://github.com/coder/claudecode.nvim/pull/256))

### Security

- The WebSocket auth token is now generated from a CSPRNG and the lock file is written atomically with `0600` permissions in a `0700` directory. ([#259](https://github.com/coder/claudecode.nvim/pull/259))

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
