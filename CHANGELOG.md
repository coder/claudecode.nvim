# Changelog

## [Unreleased]

## [0.4.0] - 2026-11-02

### Added

- `:checkhealth claudecode` health check that verifies Neovim version, `setup()`, the Claude CLI, terminal provider, the WebSocket server, the lock file, and live connection state ([#275](https://github.com/coder/claudecode.nvim/pull/275)).
- `:ClaudeCodeSendText {text}` command and `require("claudecode.terminal").send_to_terminal(text, opts)` to type arbitrary text into the open Claude pane (submits by default; `:ClaudeCodeSendText!` inserts without submitting). In-editor `native`/`snacks` providers only ([#272](https://github.com/coder/claudecode.nvim/pull/272), [#197](https://github.com/coder/claudecode.nvim/issues/197)).
- `:ClaudeCodeCloseAllDiffs` command to close all pending Claude diffs at once ([#248](https://github.com/coder/claudecode.nvim/issues/248), [#261](https://github.com/coder/claudecode.nvim/pull/261)).
- `User ClaudeCodeSendComplete` autocmd fired once per accepted send while Claude is connected, with `data = { file_path, start_line, end_line, context }` — enabling post-send logic such as focusing an external Claude session ([#228](https://github.com/coder/claudecode.nvim/issues/228), [#265](https://github.com/coder/claudecode.nvim/pull/265)).
- `diff_opts.layout = "unified"`: a VS Code-style unified diff in a single buffer with interleaved added/deleted lines, as a compact alternative to `"vertical"`/`"horizontal"`. Requires Neovim >= 0.9.0; highlight groups `ClaudeCodeInlineDiffAdd`/`Delete`/`AddSign`/`DeleteSign` are customizable ([#195](https://github.com/coder/claudecode.nvim/pull/195), [#295](https://github.com/coder/claudecode.nvim/pull/295)).
- `diff_opts.auto_resize_terminal` (default `true`) opt-out, `terminal.diff_split_width_percentage` for a separate terminal width while a diff is open, and `User ClaudeCodeDiffOpened`/`ClaudeCodeDiffClosed` lifecycle events ([#270](https://github.com/coder/claudecode.nvim/pull/270)).
- `terminal.auto_insert` option (default `true`): set to `false` to stay in Normal mode when focusing the Claude terminal, preserving scroll position ([#233](https://github.com/coder/claudecode.nvim/pull/233)).
- `terminal.fix_streamed_paste` option (`"auto"` by default) that works around a Neovim core bug (< 0.12.2) fragmenting large bracketed pastes into the terminal ([#252](https://github.com/coder/claudecode.nvim/pull/252)).
- netrw file selection for `<leader>as`, supporting marked files and the file under the cursor ([#62](https://github.com/coder/claudecode.nvim/pull/62)).
- `:ClaudeCodeTreeAdd` support in snacks.nvim pickers and `Snacks.explorer()` ([#269](https://github.com/coder/claudecode.nvim/pull/269), [#192](https://github.com/coder/claudecode.nvim/issues/192)).
- Opusplan model option; evergreen version-free model picker labels plus 1M-context (`opus[1m]`/`sonnet[1m]`) and `default` entries ([ac60fda](https://github.com/coder/claudecode.nvim/commit/ac60fda), [#256](https://github.com/coder/claudecode.nvim/pull/256)).

### Fixed

- Hardened the IDE auth token to use a CSPRNG and wrote the lock file atomically with `0600` permissions in a `0700` directory ([#259](https://github.com/coder/claudecode.nvim/pull/259)).
- WebSocket server robustness: close malformed frames with the correct RFC 6455 status instead of stalling, join fragmented messages and validate UTF-8 per message, reject binary frames, send only valid UTF-8, and never repeat a client id within one process ([#258](https://github.com/coder/claudecode.nvim/pull/258), [#395](https://github.com/coder/claudecode.nvim/pull/395), [#378](https://github.com/coder/claudecode.nvim/pull/378), [#390](https://github.com/coder/claudecode.nvim/pull/390), [#383](https://github.com/coder/claudecode.nvim/pull/383), [#329](https://github.com/coder/claudecode.nvim/pull/329)).
- Retry port binding on `EADDRINUSE` so parallel Neovim instances each start on a free port ([#284](https://github.com/coder/claudecode.nvim/pull/284)).
- Detect system sleep/wake and reset keepalive timers to prevent false client disconnections ([#141](https://github.com/coder/claudecode.nvim/pull/141)).
- `closeAllDiffTabs` is now scoped to claudecode's own diffs and never touches diffview.nvim/fugitive/`:diffsplit` reviews or user buffers ([#277](https://github.com/coder/claudecode.nvim/pull/277), [#290](https://github.com/coder/claudecode.nvim/pull/290), [#373](https://github.com/coder/claudecode.nvim/pull/373)).
- Rejecting a diff with `:q`/`:close`/`<C-w>c` now resolves it as rejected ([#266](https://github.com/coder/claudecode.nvim/pull/266)).
- Auto-close pending diffs when the client that opened them disconnects or the integration stops ([#248](https://github.com/coder/claudecode.nvim/issues/248), [#261](https://github.com/coder/claudecode.nvim/pull/261)).
- Open diffs when the Claude terminal is the only window ([#260](https://github.com/coder/claudecode.nvim/pull/260)), and keep `openDiff`/`openFile` out of diff and preview windows ([#391](https://github.com/coder/claudecode.nvim/pull/391), [#384](https://github.com/coder/claudecode.nvim/pull/384)).
- Legacy `diff_opts.vertical_split`/`open_in_current_tab` options now apply correctly ([#142](https://github.com/coder/claudecode.nvim/pull/142)).
- Numerous diff lifecycle, tab, and terminal-width restoration fixes for unified and new-tab diffs ([#297](https://github.com/coder/claudecode.nvim/pull/297), [#394](https://github.com/coder/claudecode.nvim/pull/394), [#399](https://github.com/coder/claudecode.nvim/pull/399), [#403](https://github.com/coder/claudecode.nvim/pull/403), [#421](https://github.com/coder/claudecode.nvim/pull/421), [#429](https://github.com/coder/claudecode.nvim/pull/429), [#432](https://github.com/coder/claudecode.nvim/pull/432)).
- `openFile` now selects the exact requested line/text range, honors `preview`, keeps your Visual mode, unsaved changes, focus, and window when it arrives mid-command, and validates line ranges ([#353](https://github.com/coder/claudecode.nvim/pull/353), [#375](https://github.com/coder/claudecode.nvim/pull/375), [#382](https://github.com/coder/claudecode.nvim/pull/382), [#387](https://github.com/coder/claudecode.nvim/pull/387), [#370](https://github.com/coder/claudecode.nvim/pull/370)).
- IDE diagnostics accept a bare file path without a `file://` URI, and tool responses return grouped URI-based diagnostics with editor-native ranges and severity names ([#163](https://github.com/coder/claudecode.nvim/pull/163), [#274](https://github.com/coder/claudecode.nvim/pull/274)).
- Selection fixes: send updates on `BufEnter`, push quickly-made visual selections, track Select mode, count characters as Neovim does, and end charwise/blockwise selections on a whole character ([#159](https://github.com/coder/claudecode.nvim/pull/159), [#267](https://github.com/coder/claudecode.nvim/pull/267), [#381](https://github.com/coder/claudecode.nvim/pull/381), [#388](https://github.com/coder/claudecode.nvim/pull/388), [#367](https://github.com/coder/claudecode.nvim/pull/367)).
- Native terminal now owns only the buffer it started, cleans up failed starts, stops the Claude job on close, and emits a single error notice ([#339](https://github.com/coder/claudecode.nvim/pull/339), [#349](https://github.com/coder/claudecode.nvim/pull/349), [#336](https://github.com/coder/claudecode.nvim/pull/336), [#345](https://github.com/coder/claudecode.nvim/pull/345), [#330](https://github.com/coder/claudecode.nvim/pull/330)).
- Exclude loopback hosts from proxying so Claude's `ws://127.0.0.1` IDE connection isn't tunneled ([#268](https://github.com/coder/claudecode.nvim/pull/268), [#70](https://github.com/coder/claudecode.nvim/issues/70)).
- Fix the Snacks "climbing cursor" on hide/show toggle ([#271](https://github.com/coder/claudecode.nvim/pull/271)), fix a Snacks shell-glob launch bug with `[1m]` model aliases ([#256](https://github.com/coder/claudecode.nvim/pull/256)), and handle `$` in file paths for `ClaudeCodeAdd`/`openFile` ([#286](https://github.com/coder/claudecode.nvim/pull/286)).
- Prevent a crash with render-markdown.nvim when accepting a new-file diff ([#224](https://github.com/coder/claudecode.nvim/pull/224)); keep structured error codes from coroutine tools ([#338](https://github.com/coder/claudecode.nvim/pull/338)); bump Haiku to 4.5 ([#146](https://github.com/coder/claudecode.nvim/pull/146)).

### Changed

- `focus_after_send = true` now emits a one-time warning under `terminal.provider = "none"`/`"external"` (which run Claude outside Neovim), pointing to the `User ClaudeCodeSendComplete` autocmd ([#265](https://github.com/coder/claudecode.nvim/pull/265)).
- Integration tests now also run on Neovim 0.8.0 ([#369](https://github.com/coder/claudecode.nvim/pull/369)).

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
