# Changelog

## [Unreleased]

## [0.4.0] - 2026-06-25

### Added

- `:checkhealth claudecode` health check that verifies your Neovim version, `setup()`, the Claude CLI, terminal provider, WebSocket server, lock file, and live connection state, with actionable advice on each failure ([#275](https://github.com/coder/claudecode.nvim/pull/275)).
- `:ClaudeCodeSendText {text}` command (and `require("claudecode.terminal").send_to_terminal(text, opts)`) to send arbitrary text to the open Claude terminal as if typed at the prompt; `:ClaudeCodeSendText!` inserts without submitting. Multi-line text is sent via bracketed paste. Works with the in-editor `native`/`snacks` providers only ([#272](https://github.com/coder/claudecode.nvim/pull/272)).
- `User ClaudeCodeSendComplete` autocmd, fired once per file when a send is accepted while Claude is connected, with `data = { file_path, start_line, end_line, context }` (lines 0-indexed). Lets you run post-send logic such as focusing a Claude session running outside Neovim (`provider = "none"`/`"external"`), e.g. via `tmux select-pane` ([#265](https://github.com/coder/claudecode.nvim/pull/265)).
- `User ClaudeCodeDiffOpened` / `ClaudeCodeDiffClosed` autocmds carrying a data payload (tab/window/file info), so configs can react to diffs opening and closing — resize, relayout, statusline, etc. ([#270](https://github.com/coder/claudecode.nvim/pull/270), [#297](https://github.com/coder/claudecode.nvim/pull/297)).
- `:ClaudeCodeCloseAllDiffs` command to close pending Claude diffs at once; accepted-but-unwritten diffs are left intact so saved edits are never discarded ([#261](https://github.com/coder/claudecode.nvim/pull/261)).
- `diff_opts.layout = "unified"`: a unified diff rendered in a single buffer with deleted (red/strikethrough) and added (green) lines interleaved, a compact alternative to the two-pane `"vertical"`/`"horizontal"` layouts. Requires Neovim >= 0.9.0; the `ClaudeCodeInlineDiffAdd`/`Delete`/`AddSign`/`DeleteSign` highlight groups are customizable ([#195](https://github.com/coder/claudecode.nvim/pull/195), [#295](https://github.com/coder/claudecode.nvim/pull/295)).
- `terminal.auto_insert` option (default `true`) controlling whether the Claude terminal auto-enters insert/terminal mode on focus; set `auto_insert = false` to stay in Normal mode and preserve your scroll position ([#233](https://github.com/coder/claudecode.nvim/pull/233)).
- `terminal.diff_split_width_percentage` (optional terminal width while a diff is open, falling back to `split_width_percentage`) and `diff_opts.auto_resize_terminal` (default `true`; set `false` to own the layout yourself) ([#270](https://github.com/coder/claudecode.nvim/pull/270)).
- `:ClaudeCodeTreeAdd` and `:ClaudeCodeSend` now support snacks.nvim pickers (`snacks_picker_list`), adding the selected/highlighted file(s) to Claude's context ([#269](https://github.com/coder/claudecode.nvim/pull/269)).
- netrw file selection: `<leader>as` in netrw buffers adds marked files or the file under cursor to Claude's context ([#62](https://github.com/coder/claudecode.nvim/pull/62)).
- Selection updates are now also sent on `BufEnter`, so switching buffers without moving the cursor still updates Claude's selection context ([#159](https://github.com/coder/claudecode.nvim/pull/159)).
- Model picker refreshed: evergreen, version-free labels (`Claude Opus (Latest)`, `Claude Sonnet (Latest)`, `Claude Haiku (Latest)`), the 1M-context `opus[1m]`/`sonnet[1m]` variants, and `Default (account recommended)` ([#256](https://github.com/coder/claudecode.nvim/pull/256)).

### Fixed

- The WebSocket auth token is now generated from a cryptographically secure RNG, and the lock file is written atomically with `0600` permissions in a `0700` directory (previously world-readable `0644`). Handshake auth comparison is constant-time ([#259](https://github.com/coder/claudecode.nvim/pull/259)).
- Malformed WebSocket frames now close the connection with the correct RFC 6455 status code instead of leaving the connection wedged with un-drainable bytes ([#258](https://github.com/coder/claudecode.nvim/pull/258)).
- A second Neovim instance no longer fails to start its server with `EADDRINUSE`; port binding retries across candidate ports and the per-process PRNG seed is restored ([#284](https://github.com/coder/claudecode.nvim/pull/284)).
- Disconnect callbacks now fire on every teardown path (EOF, read/protocol errors, CLOSE frames, keepalive timeouts), preventing phantom clients from accumulating ([#176](https://github.com/coder/claudecode.nvim/pull/176)).
- System sleep is detected (>1.5x ping interval elapsed) and client pong timestamps are reset on wake, preventing false keepalive disconnections after a laptop resumes ([#141](https://github.com/coder/claudecode.nvim/pull/141)).
- `closeAllDiffTabs` is now scoped to claudecode's own tracked diffs and no longer wipes out an open diffview.nvim, fugitive, or native `:diffsplit`; `openFile`/`openDiff` no longer reuse a window in diff mode ([#290](https://github.com/coder/claudecode.nvim/pull/290)).
- Rejecting a Claude diff with `:q` (or `:close` / `<C-w>c` / closing the tab) now resolves it as rejected via a new `WinClosed` autocmd ([#266](https://github.com/coder/claudecode.nvim/pull/266)).
- Diffs opened via `openDiff` are now auto-closed when the client that opened them disconnects or the integration stops, instead of lingering forever when resolved outside this Neovim ([#261](https://github.com/coder/claudecode.nvim/pull/261)).
- Diffs now open when the Claude terminal is the only window — a split is created to host the diff instead of failing with "No suitable editor window found" ([#260](https://github.com/coder/claudecode.nvim/pull/260)).
- A leftover diff split is no longer left behind after accepting a diff; plugin-created windows are tracked and cleaned up deterministically ([#175](https://github.com/coder/claudecode.nvim/pull/175)).
- `open_in_new_tab` diff setup errors no longer strand an empty tab; focus returns to the original tab ([#264](https://github.com/coder/claudecode.nvim/pull/264)).
- `keep_terminal_focus` now works for floating Snacks terminals instead of stealing focus to the hidden diff split ([#178](https://github.com/coder/claudecode.nvim/pull/178)).
- Fixed the Snacks "climbing cursor" on hide/show toggle: the panel is now parked rather than destroyed, preserving the cursor anchor Claude re-renders against (splits on all versions; floats require Neovim >= 0.10) ([#271](https://github.com/coder/claudecode.nvim/pull/271)).
- The Claude terminal now adds loopback hosts (`localhost`, `127.0.0.1`, `::1`) to `no_proxy`/`NO_PROXY`, so a configured proxy no longer tunnels Claude's `ws://127.0.0.1` IDE connection and times out queued @ mentions ([#268](https://github.com/coder/claudecode.nvim/pull/268)).
- Worked around a Neovim core bug (< 0.12.2) that fragmented large bracketed pastes into the terminal, making Cmd+V appear to truncate content; controlled via `terminal.fix_streamed_paste` (`"auto"` default, no-op on >= 0.12.2) ([#252](https://github.com/coder/claudecode.nvim/pull/252)).
- Quickly-made visual selections are now pushed to Claude reliably; selections are flushed synchronously on visual-mode exit and persist until the cursor moves ([#267](https://github.com/coder/claudecode.nvim/pull/267)).
- IDE tool responses are now handled correctly: diagnostics return grouped URI-based payloads with editor-native ranges and severity names, an unsupported resources capability is no longer advertised, and background file opens preserve focus ([#274](https://github.com/coder/claudecode.nvim/pull/274)).
- `getDiagnostics` now accepts a bare file path (not just a `file://` URI), since Claude often sends the path without a scheme ([#163](https://github.com/coder/claudecode.nvim/pull/163)).
- `ClaudeCodeSend` no longer misroutes ordinary files into tree-extraction when their path merely contains `neo-tree`/`NvimTree`; buffers are now classified by filetype only ([#292](https://github.com/coder/claudecode.nvim/pull/292)).
- File paths containing `$` are now handled correctly in `ClaudeCodeAdd` and `openFile` ([#286](https://github.com/coder/claudecode.nvim/pull/286)).
- The legacy diff options `vertical_split` and `open_in_current_tab` are applied correctly again (they were silently ignored after a merge-order change) ([#142](https://github.com/coder/claudecode.nvim/pull/142)).
- Fixed a segfault when accepting a new-file diff with `render-markdown.nvim` installed, by turning off diff mode before the post-write redraw ([#224](https://github.com/coder/claudecode.nvim/pull/224)).
- The empty scratch buffer is now wiped when the terminal provider is `none` ([#223](https://github.com/coder/claudecode.nvim/pull/223)).
- `snacks_picker_list` buffers are excluded from main-editor-window detection, so diffs no longer target the picker ([#165](https://github.com/coder/claudecode.nvim/pull/165)).
- Selection-context fallback now matches the `[Claude Code]` terminal name via substring, so external (`provider = "none"`) terminals correctly skip sending selection context ([#160](https://github.com/coder/claudecode.nvim/pull/160)).
- Selection debounce timers are now stopped and closed safely, fixing a libuv handle leak and stale callbacks firing after being superseded ([#245](https://github.com/coder/claudecode.nvim/pull/245)).
- A one-time warning is now emitted when `focus_after_send = true` with `provider = "none"`/`"external"`, pointing at the new `ClaudeCodeSendComplete` event ([#265](https://github.com/coder/claudecode.nvim/pull/265)).
- Bumped the Haiku picker label to 4.5 ([#146](https://github.com/coder/claudecode.nvim/pull/146)).

### Changed

- Floating diff terminals are no longer resized when restoring terminal widths ([#178](https://github.com/coder/claudecode.nvim/pull/178)).

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
