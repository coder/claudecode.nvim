# Changelog

## [Unreleased]

## [0.4.0] - 2026-11-01

### Added

- `:ClaudeCodeSendText {text}` command and `require("claudecode.terminal").send_to_terminal(text, opts)` to type text into the open Claude pane and submit it (`:ClaudeCodeSendText!` inserts without submitting). In-editor providers (`native`/`snacks`) only. ([#272](https://github.com/coder/claudecode.nvim/pull/272))
- `:ClaudeCodeCloseAllDiffs` command to close all pending Claude diffs at once; accepted edits are preserved as unsaved buffer changes if not yet written. ([#261](https://github.com/coder/claudecode.nvim/pull/261))
- `:checkhealth claudecode` health check for diagnosing Neovim version, `setup()`, Claude CLI, terminal provider, WebSocket server, lock file, and connection state. ([#275](https://github.com/coder/claudecode.nvim/pull/275))
- `User ClaudeCodeSendComplete` autocmd fired once per file on accepted send (`data = { file_path, start_line, end_line, context }`, 0-indexed), enabling post-send automation such as focusing an external Claude session. ([#265](https://github.com/coder/claudecode.nvim/pull/265))
- `User ClaudeCodeDiffOpened` / `ClaudeCodeDiffClosed` autocmds carrying window/file payloads for reacting to diff lifecycle. ([#270](https://github.com/coder/claudecode.nvim/pull/270))
- `diff_opts.layout = "unified"`: a single-buffer unified diff with interleaved removed/added lines (requires Neovim >= 0.9). ([#195](https://github.com/coder/claudecode.nvim/pull/195), [#295](https://github.com/coder/claudecode.nvim/pull/295))
- `diff_opts.diff_split_width_percentage` to set a separate Claude terminal width while a diff is open, and `diff_opts.auto_resize_terminal` to opt out of plugin-managed resizing. ([#270](https://github.com/coder/claudecode.nvim/pull/270))
- `terminal.auto_insert` (default `true`): set to `false` to stay in Normal mode and preserve scroll position when refocusing the Claude terminal. ([#233](https://github.com/coder/claudecode.nvim/pull/233))
- `terminal.fix_streamed_paste` (`"auto"` default): work around a Neovim core bug (< 0.12.2) that fragmented large bracketed pastes into the terminal. ([#252](https://github.com/coder/claudecode.nvim/pull/252))
- netrw file selection support for `<leader>as` / `:ClaudeCodeTreeAdd`. ([#62](https://github.com/coder/claudecode.nvim/pull/62))
- `:ClaudeCodeTreeAdd` support in snacks.nvim pickers and `Snacks.explorer()`. ([#269](https://github.com/coder/claudecode.nvim/pull/269))
- Evergreen model picker with version-free labels, 1M-context variants (`opus[1m]`/`sonnet[1m]`), and a `Default (account recommended)` entry. ([#256](https://github.com/coder/claudecode.nvim/pull/256))

### Fixed

- Security: WebSocket auth token now generated from a CSPRNG and the IDE lock file written with `0600` permissions in a `0700` directory (was world-readable). ([#259](https://github.com/coder/claudecode.nvim/pull/259))
- `closeAllDiffTabs` no longer closes diffs it doesn't own — open diffview.nvim, fugitive, or `:diffsplit` reviews are no longer wiped on every Claude turn; `openFile`/`openDiff` also stop reusing diff/preview windows. ([#290](https://github.com/coder/claudecode.nvim/pull/290), [#277](https://github.com/coder/claudecode.nvim/pull/277), [#384](https://github.com/coder/claudecode.nvim/pull/384), [#391](https://github.com/coder/claudecode.nvim/pull/391))
- Loopback hosts (`localhost`, `127.0.0.1`, `::1`) are added to `no_proxy`/`NO_PROXY` so a configured HTTP proxy no longer tunnels Claude's `ws://127.0.0.1` IDE connection and times out queued @ mentions. ([#268](https://github.com/coder/claudecode.nvim/pull/268))
- Detect system sleep/wake and reset keepalive timers to prevent false client disconnections after a laptop resumes. ([#141](https://github.com/coder/claudecode.nvim/pull/141))
- Prevent a segfault (exit 139) when accepting a new-file diff with `render-markdown.nvim` installed. ([#224](https://github.com/coder/claudecode.nvim/pull/224))
- Legacy `diff_opts.vertical_split` / `open_in_current_tab` now apply correctly. ([#142](https://github.com/coder/claudecode.nvim/pull/142))
- `getDiagnostics` works when Claude passes a bare file path instead of a `file://` URI. ([#163](https://github.com/coder/claudecode.nvim/pull/163))
- `openDiff` works when the Claude terminal is the only window; it now creates a split to host the diff. ([#260](https://github.com/coder/claudecode.nvim/pull/260))
- Rejecting a diff with `:q` / `:close` / closing the tab now resolves it as rejected. ([#266](https://github.com/coder/claudecode.nvim/pull/266))
- Orphaned diffs are auto-closed when the client that opened them disconnects or the integration stops. ([#261](https://github.com/coder/claudecode.nvim/pull/261))
- `keep_terminal_focus` now works with floating Claude terminals (e.g. Snacks `position="float"`). ([#178](https://github.com/coder/claudecode.nvim/pull/178))
- Snacks terminal no longer leaves a "climbing cursor" above the prompt after hide/show; float fix requires Neovim >= 0.10. ([#271](https://github.com/coder/claudecode.nvim/pull/271))
- Quickly-made and single-line visual selections now reliably reach Claude, including via the external `/ide` flow. ([#267](https://github.com/coder/claudecode.nvim/pull/267))
- Selection updates now also fire on `BufEnter`. ([#159](https://github.com/coder/claudecode.nvim/pull/159))
- `ClaudeCodeAdd` and `openFile` handle `$` and other special characters in file paths. ([#286](https://github.com/coder/claudecode.nvim/pull/286))
- Native terminal provider now adopts only terminal buffers it started (marked with `b:claudecode_native_terminal`). ([#349](https://github.com/coder/claudecode.nvim/pull/349))
- `openFile` selects exactly the requested line/text range, leaves the user's window/mode/unsaved changes alone, and avoids W11/W12 prompts; the preview window is never treated as the main editor window. ([#353](https://github.com/coder/claudecode.nvim/pull/353), [#370](https://github.com/coder/claudecode.nvim/pull/370), [#375](https://github.com/coder/claudecode.nvim/pull/375), [#382](https://github.com/coder/claudecode.nvim/pull/382), [#387](https://github.com/coder/claudecode.nvim/pull/387), [#396](https://github.com/coder/claudecode.nvim/pull/396), [#408](https://github.com/coder/claudecode.nvim/pull/408))
- `diff_opts.open_in_new_tab = true` works on Neovim 0.8 (which lacks `'statuscolumn'`); new-tab/unified diffs are sized and cleaned up correctly, and user window sizes are restored on close. ([#394](https://github.com/coder/claudecode.nvim/pull/394), [#399](https://github.com/coder/claudecode.nvim/pull/399), [#403](https://github.com/coder/claudecode.nvim/pull/403), [#410](https://github.com/coder/claudecode.nvim/pull/410), [#421](https://github.com/coder/claudecode.nvim/pull/421), [#429](https://github.com/coder/claudecode.nvim/pull/429))
- Accepted diffs hand text over in the buffer's own format (including CRLF), and `:ClaudeCodeCloseAllDiffs` finishes rather than discarding accepted diffs. ([#392](https://github.com/coder/claudecode.nvim/pull/392), [#376](https://github.com/coder/claudecode.nvim/pull/376), [#361](https://github.com/coder/claudecode.nvim/pull/361))
- `close_tab` closes only the named diff, never a user buffer. ([#373](https://github.com/coder/claudecode.nvim/pull/373))
- Numerous WebSocket server hardening fixes: close on malformed/ill-formed frames with the correct status code instead of stalling, reassemble fragmented messages, reject binary frames, send only valid UTF-8, retry port binding on `EADDRINUSE` for parallel instances, and never repeat a client id within a process. ([#258](https://github.com/coder/claudecode.nvim/pull/258), [#390](https://github.com/coder/claudecode.nvim/pull/390), [#395](https://github.com/coder/claudecode.nvim/pull/395), [#378](https://github.com/coder/claudecode.nvim/pull/378), [#284](https://github.com/coder/claudecode.nvim/pull/284), [#383](https://github.com/coder/claudecode.nvim/pull/383))
- Native terminal lifecycle hardening: stop the Claude job when closing the terminal, clean up when `termopen`/`jobstart` rejects or a `TermOpen` autocmd wipes the buffer, and only adopt terminals whose job is still running. ([#336](https://github.com/coder/claudecode.nvim/pull/336), [#330](https://github.com/coder/claudecode.nvim/pull/330), [#345](https://github.com/coder/claudecode.nvim/pull/345), [#339](https://github.com/coder/claudecode.nvim/pull/339), [#364](https://github.com/coder/claudecode.nvim/pull/364))
- IDE tool responses now return grouped URI-based diagnostics with editor-native ranges, stop advertising an unsupported resources capability, and preserve structured error codes from coroutine tools. ([#274](https://github.com/coder/claudecode.nvim/pull/274), [#338](https://github.com/coder/claudecode.nvim/pull/338))
- Haiku model label updated to the latest release. ([#146](https://github.com/coder/claudecode.nvim/pull/146))

### Changed

- Integration tests now also run on Neovim 0.8.0 to keep the minimum supported version working. ([#369](https://github.com/coder/claudecode.nvim/pull/369))

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
