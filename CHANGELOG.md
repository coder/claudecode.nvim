# Changelog

## [Unreleased]

## [0.5.0] - 2026-11-14

### Added

- Set the `claudecode` filetype on the Claude terminal buffer (native and snacks), so autocmds can target it ([#202](https://github.com/coder/claudecode.nvim/pull/202), @ehaynes99)
- `<C-z>` in the Claude terminal now suspends Neovim instead of suspending Claude Code, matching Ctrl-Z in any other window ([#448](https://github.com/coder/claudecode.nvim/pull/448))

### Changed

- The `unified` diff layout now officially runs on Neovim 0.8.0 (it only needs `vim.diff`); the "requires Neovim >= 0.9.0" note has been dropped ([#564](https://github.com/coder/claudecode.nvim/pull/564))
- `@mentions` are now sent as absolute paths, matching the official VS Code extension and resolving correctly when Claude's working directory differs from Neovim's ([#460](https://github.com/coder/claudecode.nvim/pull/460))
- An invalid `terminal.provider` value now keeps the previously configured provider and the warning names it accurately (`Keeping 'auto'.`) instead of falsely claiming it defaulted to `native` ([#530](https://github.com/coder/claudecode.nvim/pull/530))

### Fixed

- `:ClaudeCodeAdd %` now works for buffers whose path contains spaces ([#304](https://github.com/coder/claudecode.nvim/pull/304), @joshmedeski)
- Queued `@mentions` are now delivered once, in order, or report an error; a mention queued while Claude is launching is delivered once Claude connects even if startup is slow ([#454](https://github.com/coder/claudecode.nvim/pull/454))
- A send with `disable_broadcast_debouncing = true` now waits for the connection readiness window instead of reaching Claude mid-startup ([#541](https://github.com/coder/claudecode.nvim/pull/541))
- Terminal lifecycle hardening: keep a single live Claude, never run a second one, never close the wrong window, and no longer error with `E444` when Claude's window is the only one ([#451](https://github.com/coder/claudecode.nvim/pull/451))
- Reuse the `:tabnew` window for the unified new-tab diff, removing the stray empty pane and fixing new-tab cleanup ([#303](https://github.com/coder/claudecode.nvim/pull/303), @zakissimo)
- Diff accept now returns the exact proposed bytes: keep trailing blank lines in a unified diff ([#535](https://github.com/coder/claudecode.nvim/pull/535)), accept proposals without a final line break in the split layouts ([#542](https://github.com/coder/claudecode.nvim/pull/542)), save an emptied buffer as an empty string ([#551](https://github.com/coder/claudecode.nvim/pull/551)), and save CRLF proposals with CRLF line endings ([#577](https://github.com/coder/claudecode.nvim/pull/577))
- `getCurrentSelection` answers from the live editor when no selection is tracked, and from the previous window when the Claude terminal is current ([#457](https://github.com/coder/claudecode.nvim/pull/457), [#463](https://github.com/coder/claudecode.nvim/pull/463))
- Held selections end correctly when their text or cursor changes, and are no longer leaked across file changes or the Claude terminal ([#452](https://github.com/coder/claudecode.nvim/pull/452), [#471](https://github.com/coder/claudecode.nvim/pull/471), [#481](https://github.com/coder/claudecode.nvim/pull/481), [#493](https://github.com/coder/claudecode.nvim/pull/493), [#524](https://github.com/coder/claudecode.nvim/pull/524), [#540](https://github.com/coder/claudecode.nvim/pull/540), [#562](https://github.com/coder/claudecode.nvim/pull/562))
- Malformed `tools/call` and `close_tab` requests now get proper JSON-RPC `-32602` "Invalid params" errors instead of internal error text or leaked file paths ([#497](https://github.com/coder/claudecode.nvim/pull/497), [#500](https://github.com/coder/claudecode.nvim/pull/500))
- `saveDocument` reports only the Vim error (e.g. `E45: 'readonly' option is set`) instead of a full Lua stack trace with install paths ([#453](https://github.com/coder/claudecode.nvim/pull/453))
- `openFile` finishes reloading a file even when a user's `BufReadPre`/`FileChangedShell` autocmd errors, so the buffer holds the new content and a later `:w` doesn't silently overwrite Claude's file ([#461](https://github.com/coder/claudecode.nvim/pull/461), [#468](https://github.com/coder/claudecode.nvim/pull/468))
- WebSocket server reliability: never time out a live Claude, drop dead or silent clients promptly, and hold disconnect cleanup until window changes are allowed ([#455](https://github.com/coder/claudecode.nvim/pull/455), [#467](https://github.com/coder/claudecode.nvim/pull/467), [#479](https://github.com/coder/claudecode.nvim/pull/479), [#488](https://github.com/coder/claudecode.nvim/pull/488), [#499](https://github.com/coder/claudecode.nvim/pull/499))
- The Claude terminal working directory is found and used correctly for folders whose names contain spaces, commas, `$`, `\`, brackets, or other path characters ([#561](https://github.com/coder/claudecode.nvim/pull/561), [#569](https://github.com/coder/claudecode.nvim/pull/569))
- Lock file handling reports failed removals and cleans up on token mismatch, so a stale auth token is never silently left on disk ([#459](https://github.com/coder/claudecode.nvim/pull/459), [#557](https://github.com/coder/claudecode.nvim/pull/557))
- Extensive diff lifecycle hardening: clean teardown after `:wq`, `:q`, `:qa`, `:edit`, and a second `:w`; preserve the sign column and diff mode in windows a closed diff leaves; hide a floating Claude terminal only while a diff is open in its tab; answer every open diff when Neovim exits; and keep Neovim alive when a user handler raises during diff setup ([#469](https://github.com/coder/claudecode.nvim/pull/469), [#473](https://github.com/coder/claudecode.nvim/pull/473), [#478](https://github.com/coder/claudecode.nvim/pull/478), [#483](https://github.com/coder/claudecode.nvim/pull/483), [#491](https://github.com/coder/claudecode.nvim/pull/491), [#494](https://github.com/coder/claudecode.nvim/pull/494), [#504](https://github.com/coder/claudecode.nvim/pull/504), [#511](https://github.com/coder/claudecode.nvim/pull/511), [#516](https://github.com/coder/claudecode.nvim/pull/516), [#538](https://github.com/coder/claudecode.nvim/pull/538), [#558](https://github.com/coder/claudecode.nvim/pull/558), [#574](https://github.com/coder/claudecode.nvim/pull/574))

## [0.4.0] - 2026-11-09

### Added

- `:ClaudeCodeSendText {text}` command and `require("claudecode.terminal").send_to_terminal(text, opts)` to send arbitrary text to the open Claude terminal as if typed at the prompt (submitting by default; `:ClaudeCodeSendText!` inserts without submitting). Multi-line text is sent via bracketed paste. Works with the in-editor `native`/`snacks` providers only. ([#197](https://github.com/coder/claudecode.nvim/issues/197), [#272](https://github.com/coder/claudecode.nvim/pull/272))
- `:checkhealth claudecode` health check that verifies Neovim version, `setup()`, the Claude CLI, terminal provider, WebSocket server, lock file, and live connection state. ([#275](https://github.com/coder/claudecode.nvim/pull/275))
- `:ClaudeCodeCloseAllDiffs` command to close pending Claude diffs at once. A diff accepted with `:w` closes once the file holds the accepted text; otherwise the accepted text is put into the buffer as unsaved changes for `:w`/`:e!` so edits are never discarded. ([#248](https://github.com/coder/claudecode.nvim/issues/248), [#261](https://github.com/coder/claudecode.nvim/pull/261))
- `diff_opts.layout = "unified"`: a VS Code-style unified diff rendered in a single buffer with interleaved deleted/added lines, as a compact alternative to `"vertical"`/`"horizontal"`. Documented to require Neovim >= 0.9.0. Customizable via the `ClaudeCodeInlineDiffAdd`/`Delete`/`AddSign`/`DeleteSign` highlight groups. ([#195](https://github.com/coder/claudecode.nvim/pull/195), [#295](https://github.com/coder/claudecode.nvim/pull/295), [#297](https://github.com/coder/claudecode.nvim/pull/297))
- `User ClaudeCodeSendComplete` autocmd, fired once per file when a send is accepted while Claude is connected, with `data = { file_path, start_line, end_line, context }` (lines 0-indexed). Enables post-send logic such as focusing a Claude session running outside Neovim. ([#228](https://github.com/coder/claudecode.nvim/issues/228), [#265](https://github.com/coder/claudecode.nvim/pull/265))
- `User ClaudeCodeDiffOpened` / `ClaudeCodeDiffClosed` autocmds carrying diff metadata, plus `diff_opts.auto_resize_terminal` (default `true`) to opt out of plugin-managed terminal width during diffs and `terminal.diff_split_width_percentage` to set a distinct terminal width while a diff is open. ([#270](https://github.com/coder/claudecode.nvim/pull/270))
- `terminal.auto_insert` option (default `true`): set to `false` to stay in Normal mode when refocusing the Claude terminal and preserve your scroll position instead of jumping to the prompt. ([#233](https://github.com/coder/claudecode.nvim/pull/233))
- `ClaudeCodeTreeAdd` / `<leader>as` support in snacks.nvim pickers (`snacks_picker_list`), covering `Snacks.explorer()` and modal `Snacks.picker.files()`/`grep()`. ([#192](https://github.com/coder/claudecode.nvim/issues/192), [#269](https://github.com/coder/claudecode.nvim/pull/269))
- netrw file selection for `<leader>as` / `:ClaudeCodeTreeAdd`, supporting marked files and the file under the cursor. ([#62](https://github.com/coder/claudecode.nvim/pull/62))

### Changed

- Model picker labels are now version-free evergreen aliases (`Claude Opus (Latest)`, `Claude Sonnet (Latest)`, `Claude Haiku (Latest)`), with new 1M-context variants (`opus[1m]`, `sonnet[1m]`) and a `Default (account recommended)` entry. ([#146](https://github.com/coder/claudecode.nvim/pull/146), [#256](https://github.com/coder/claudecode.nvim/pull/256))
- `:checkhealth claudecode` and the MCP `serverInfo.version` now report the real plugin version from the `VERSION` file instead of a hard-coded value. ([#437](https://github.com/coder/claudecode.nvim/pull/437))

### Fixed

- The Snacks provider no longer fails to launch Claude when a model alias contains shell-glob characters (e.g. `opus[1m]`); the command is now passed as an argv list with no shell interpretation. ([#256](https://github.com/coder/claudecode.nvim/pull/256))
- The native terminal now adopts only terminal buffers it started (marked with `b:claudecode_native_terminal`), instead of any visible terminal whose name contains `claude`. Upgrade note: a terminal that an older plugin version started (for example after `:Lazy reload` following an upgrade), or that a session file restored, carries no mark and is no longer adopted. The next open starts a second Claude session, and the old terminal keeps running until you close its buffer or quit Claude in it. ([#349](https://github.com/coder/claudecode.nvim/pull/349), [#352](https://github.com/coder/claudecode.nvim/pull/352), [#364](https://github.com/coder/claudecode.nvim/pull/364))
- `closeAllDiffTabs` is now scoped to claudecode's own tracked diffs and no longer wipes out an open diffview.nvim, fugitive, or native `:diffsplit` review; `openFile`/`openDiff` also never reuse a window that is in diff mode. ([#277](https://github.com/coder/claudecode.nvim/issues/277), [#290](https://github.com/coder/claudecode.nvim/pull/290))
- `close_tab` now closes only the diff with that tab name and never deletes a user buffer. ([#373](https://github.com/coder/claudecode.nvim/pull/373))
- Closing the native terminal, for example with `:ClaudeCodeClose`, now stops the Claude job instead of leaving it running. ([#336](https://github.com/coder/claudecode.nvim/pull/336))
- The Claude terminal now adds loopback hosts to `no_proxy`/`NO_PROXY` so a configured proxy no longer tunnels Claude's `ws://127.0.0.1` IDE connection and times out queued @ mentions. ([#70](https://github.com/coder/claudecode.nvim/issues/70), [#268](https://github.com/coder/claudecode.nvim/pull/268))
- `focus_after_send = true` with `provider = "none"`/`"external"` now emits a one-time warning pointing to the `User ClaudeCodeSendComplete` autocmd instead of failing silently. ([#228](https://github.com/coder/claudecode.nvim/issues/228), [#265](https://github.com/coder/claudecode.nvim/pull/265))
- Rejecting a Claude diff with `:q` / `:close` / `<C-w>c` (or closing the tab) now resolves it as rejected via a `WinClosed` autocmd. ([#266](https://github.com/coder/claudecode.nvim/pull/266))
- Quickly-made and single-line visual selections are now pushed to Claude reliably; selections are flushed synchronously on visual-mode exit and persist until the cursor moves, including in the external `/ide` flow and Select mode. ([#246](https://github.com/coder/claudecode.nvim/issues/246), [#267](https://github.com/coder/claudecode.nvim/pull/267), [#367](https://github.com/coder/claudecode.nvim/pull/367), [#381](https://github.com/coder/claudecode.nvim/pull/381), [#388](https://github.com/coder/claudecode.nvim/pull/388))
- Pending diffs are now automatically closed when the client that opened them disconnects or the integration stops, so orphaned proposals no longer linger. ([#248](https://github.com/coder/claudecode.nvim/issues/248), [#261](https://github.com/coder/claudecode.nvim/pull/261))
- `openDiff` now works when the Claude terminal is the only window, creating a split to host the diff instead of failing with "No suitable editor window found". ([#260](https://github.com/coder/claudecode.nvim/pull/260))
- Fixed the "climbing cursor" in the Snacks terminal, where the cursor sat one row above Claude's prompt after hide and show. On Neovim >= 0.10 a floating terminal is now hidden instead of closed. A split is still closed on hide and created again on show, which keeps the cursor in place. Floating terminals on Neovim < 0.10 keep the old behavior. ([#240](https://github.com/coder/claudecode.nvim/issues/240), [#183](https://github.com/coder/claudecode.nvim/issues/183), [#271](https://github.com/coder/claudecode.nvim/pull/271))
- Worked around a Neovim core bug (< 0.12.2) that fragmented large bracketed pastes into the terminal; controlled by `terminal.fix_streamed_paste` (`"auto"` by default). ([#252](https://github.com/coder/claudecode.nvim/pull/252))
- `openFile` now selects exactly the requested line range or matched text, keeps the user's Visual mode, unsaved changes, focus and preview window intact, never prompts W11/W12, and never picks the preview window as the main editor window. ([#353](https://github.com/coder/claudecode.nvim/pull/353), [#365](https://github.com/coder/claudecode.nvim/pull/365), [#370](https://github.com/coder/claudecode.nvim/pull/370), [#375](https://github.com/coder/claudecode.nvim/pull/375), [#382](https://github.com/coder/claudecode.nvim/pull/382), [#384](https://github.com/coder/claudecode.nvim/pull/384), [#387](https://github.com/coder/claudecode.nvim/pull/387), [#396](https://github.com/coder/claudecode.nvim/pull/396), [#408](https://github.com/coder/claudecode.nvim/pull/408))
- `getDiagnostics` now handles plain file paths without a `file://` URI scheme, and IDE diagnostics return grouped URI-based payloads with editor-native ranges and severity names. ([#163](https://github.com/coder/claudecode.nvim/pull/163), [#274](https://github.com/coder/claudecode.nvim/pull/274))
- `:ClaudeCodeAdd` and `openFile` now handle `$` in file paths. ([#286](https://github.com/coder/claudecode.nvim/pull/286))
- Prevented a segfault when accepting a new-file diff with `render-markdown.nvim` installed, by turning off diff mode before the post-write redraw. ([#224](https://github.com/coder/claudecode.nvim/pull/224))
- The auth token is now generated from a CSPRNG and the lock file is written atomically with mode `0600` in a `0700` directory. ([#259](https://github.com/coder/claudecode.nvim/pull/259))
- Detect system sleep/wake and reset client keepalive timestamps to prevent false disconnections. ([#141](https://github.com/coder/claudecode.nvim/pull/141))
- The WebSocket server now retries port binding on `EADDRINUSE` (parallel instances), closes connections on malformed/oversized or binary frames with the correct status, joins fragmented messages, validates UTF-8 per message, and never repeats a client id within a process. ([#258](https://github.com/coder/claudecode.nvim/pull/258), [#283](https://github.com/coder/claudecode.nvim/issues/283), [#378](https://github.com/coder/claudecode.nvim/pull/378), [#383](https://github.com/coder/claudecode.nvim/pull/383), [#390](https://github.com/coder/claudecode.nvim/pull/390), [#395](https://github.com/coder/claudecode.nvim/pull/395), [#405](https://github.com/coder/claudecode.nvim/pull/405), [#422](https://github.com/coder/claudecode.nvim/pull/422), [#431](https://github.com/coder/claudecode.nvim/pull/431))
- Legacy `diff_opts` (e.g. `vertical_split`, `open_in_current_tab`) now take effect again after the config merge-order regression. ([#142](https://github.com/coder/claudecode.nvim/pull/142))
- `:q` on a diff window no longer hangs; floating diff terminals keep focus; empty buffers are wiped when the terminal provider is `none`; and accepted diffs are handed over in the buffer's own line-ending format. ([#178](https://github.com/coder/claudecode.nvim/pull/178), [#223](https://github.com/coder/claudecode.nvim/pull/223), [#266](https://github.com/coder/claudecode.nvim/pull/266), [#392](https://github.com/coder/claudecode.nvim/pull/392))

### Compatibility

- Integration tests now run on Neovim v0.8.0, and a new-tab diff no longer fails there because Neovim 0.8 has no `statuscolumn`. The unified layout is documented to require Neovim >= 0.9.0, and the v0.8.0 integration tests skip it. ([#369](https://github.com/coder/claudecode.nvim/pull/369), [#394](https://github.com/coder/claudecode.nvim/pull/394))

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
