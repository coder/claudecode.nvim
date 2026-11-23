# Changelog

## [Unreleased]

## [0.5.0] - 2026-11-23

### Added

- Set the `claudecode` filetype on the native and snacks Claude terminal buffers so autocmds and `buflisted = false` rules can target them. On snacks this replaces the `snacks_terminal` filetype; set `terminal.snacks_win_opts = { bo = { filetype = "snacks_terminal" } }` to keep the old one ([#202](https://github.com/coder/claudecode.nvim/pull/202)).
- Ctrl-Z in the Claude terminal now suspends Neovim instead of being passed to Claude Code, matching every other window. Remap it in a `FileType claudecode` autocmd if you want the old behavior ([#448](https://github.com/coder/claudecode.nvim/pull/448)).

### Fixed

- **Security:** reject file paths containing a line break, carriage return, or NUL in `openFile`/`openDiff`, and open every path as a single literal file, closing a code-execution vector when Claude opened or diffed a maliciously named committed file ([#608](https://github.com/coder/claudecode.nvim/pull/608)).
- **Security:** pass the working directory to `external_terminal_cmd` as one argument so a crafted folder name can no longer inject shell commands (CWE-88); templates that embed the cwd inside a larger argument are now refused with an error ([#607](https://github.com/coder/claudecode.nvim/pull/607)).
- `:ClaudeCodeAdd %` now works when the buffer's path contains spaces, and supports escaped spaces ([#304](https://github.com/coder/claudecode.nvim/pull/304)).
- @mentions are now sent as absolute paths, matching the VS Code extension, so they resolve to the right file when Claude's cwd differs from Neovim's ([#460](https://github.com/coder/claudecode.nvim/pull/460)).
- The @mention queue now delivers each queued mention once, in order, or reports an error; a mention queued while Claude is launching is delivered on connect rather than silently dropped, and `:ClaudeCodeStop` no longer leaks a pending mention to the next Claude or raises a Lua error. `queue_timeout` no longer expires mentions by age (`connection_timeout` bounds the wait) ([#454](https://github.com/coder/claudecode.nvim/pull/454), [#480](https://github.com/coder/claudecode.nvim/pull/480), [#541](https://github.com/coder/claudecode.nvim/pull/541)).
- Malformed `tools/call` requests (missing/wrong-typed `name`, non-object `params` or `arguments`, wrong-typed required parameters) now answer with `-32602` "Invalid params" instead of leaking internal Lua errors and file paths, and `close_tab` errors are returned under `error` rather than `result` ([#497](https://github.com/coder/claudecode.nvim/pull/497), [#500](https://github.com/coder/claudecode.nvim/pull/500)).
- `saveDocument` now reports only the Vim error (e.g. `E45: 'readonly' option is set`) when `:write` fails, instead of a full Lua stack trace with install paths ([#453](https://github.com/coder/claudecode.nvim/pull/453)).
- `getCurrentSelection` answers the real selection or cursor position when `track_selection = false`, instead of a fixed empty selection at line 0 ([#457](https://github.com/coder/claudecode.nvim/pull/457)).
- `openFile` now finishes its reload with the whole new file even when a user's `BufReadPre`/`FileChangedShell` autocmd errors, and keeps Neovim's E13 guard so a `BufWriteCmd` autocmd can no longer overwrite Claude's new file with unsaved buffer text ([#461](https://github.com/coder/claudecode.nvim/pull/461), [#468](https://github.com/coder/claudecode.nvim/pull/468)).
- The unified diff layout now rejects on `:q` (answering `DIFF_REJECTED` immediately instead of timing out) and on switching the proposal window to another buffer, in both split and unified layouts ([#469](https://github.com/coder/claudecode.nvim/pull/469)).
- New-tab diffs now open the proposal in Normal mode, close without entering their tab, reuse the `:tabnew` window instead of leaving an empty pane, and tear down their terminal `BufEnter` handler on close ([#303](https://github.com/coder/claudecode.nvim/pull/303), [#473](https://github.com/coder/claudecode.nvim/pull/473), [#478](https://github.com/coder/claudecode.nvim/pull/478), [#485](https://github.com/coder/claudecode.nvim/pull/485)).
- An accepted unified diff now preserves every trailing blank line, and split/horizontal layouts accept a proposal with no final line break correctly, so Claude receives the exact proposed bytes ([#535](https://github.com/coder/claudecode.nvim/pull/535), [#542](https://github.com/coder/claudecode.nvim/pull/542), [#551](https://github.com/coder/claudecode.nvim/pull/551), [#577](https://github.com/coder/claudecode.nvim/pull/577)).
- Closing a diff no longer overwrites the sign column, diff mode, or other window options the user set in windows the diff leaves behind, and leaves no leftovers after `:wq`, a second `:w`, `:qa`, or `:edit` ([#483](https://github.com/coder/claudecode.nvim/pull/483), [#491](https://github.com/coder/claudecode.nvim/pull/491), [#494](https://github.com/coder/claudecode.nvim/pull/494)).
- A floating (snacks) Claude terminal is now hidden while a diff is open in its tab so the diff is visible and usable ([#447](https://github.com/coder/claudecode.nvim/pull/447), [#504](https://github.com/coder/claudecode.nvim/pull/504)).
- Every pending `openDiff` call is answered when Neovim exits, and a handler error during a failed `openDiff` setup no longer crashes Neovim ([#538](https://github.com/coder/claudecode.nvim/pull/538), [#558](https://github.com/coder/claudecode.nvim/pull/558), [#574](https://github.com/coder/claudecode.nvim/pull/574)).
- The Claude terminal now keeps a single live instance and no longer closes or errors on the wrong window: `:ClaudeCodeOpen` after `:e` in Claude's window works, `:ClaudeCode` no longer raises `E444` when Claude is the only window, and an exited terminal is cleaned up before reopening ([#451](https://github.com/coder/claudecode.nvim/pull/451)).
- The running Claude is now found and reused after a plugin reload (`:Lazy reload`) across the native and snacks providers, so `:ClaudeCodeClose` and `:ClaudeCodeSendText` work and a second Claude is not started ([#464](https://github.com/coder/claudecode.nvim/pull/464)).
- The native terminal start survives an autocmd that closes its split, and stays a single start when an autocmd interrupts it ([#527](https://github.com/coder/claudecode.nvim/pull/527), [#544](https://github.com/coder/claudecode.nvim/pull/544)).
- The WebSocket server now drops dead clients promptly, never times out a Claude that answers pings, no longer drops a live Claude on a late keepalive tick during the handshake, and drops a client that answers pings but never reads ([#455](https://github.com/coder/claudecode.nvim/pull/455), [#467](https://github.com/coder/claudecode.nvim/pull/467), [#479](https://github.com/coder/claudecode.nvim/pull/479), [#488](https://github.com/coder/claudecode.nvim/pull/488)).
- The lock file (which holds the WebSocket auth token) now reports a failed removal and is cleaned up on a token mismatch instead of being left on disk silently ([#459](https://github.com/coder/claudecode.nvim/pull/459), [#557](https://github.com/coder/claudecode.nvim/pull/557)).
- Repository lookup (`git_repo_cwd`) now finds a repo whose folder name contains a space, comma, quote, or other path characters even when git cannot run, and the terminal uses a cwd folder with `$` or `\` in its name as written ([#561](https://github.com/coder/claudecode.nvim/pull/561), [#569](https://github.com/coder/claudecode.nvim/pull/569)).
- Visual-selection tracking is more reliable: a held selection ends when its text, cursor, or file changes, and the Claude terminal becoming current no longer clobbers or mis-reports the selection ([#452](https://github.com/coder/claudecode.nvim/pull/452), [#471](https://github.com/coder/claudecode.nvim/pull/471), [#481](https://github.com/coder/claudecode.nvim/pull/481), [#493](https://github.com/coder/claudecode.nvim/pull/493), [#524](https://github.com/coder/claudecode.nvim/pull/524), [#540](https://github.com/coder/claudecode.nvim/pull/540), [#562](https://github.com/coder/claudecode.nvim/pull/562), [#463](https://github.com/coder/claudecode.nvim/pull/463)).
- When setup rejects an invalid `terminal.provider`, the warning now names the provider that is actually kept instead of claiming "native" ([#530](https://github.com/coder/claudecode.nvim/pull/530)).

### Changed

- The unified diff layout is documented and tested to run on Neovim 0.8.0 (it only needs `vim.diff`); the `Requires Neovim >= 0.9.0` note has been removed ([#564](https://github.com/coder/claudecode.nvim/pull/564), [#572](https://github.com/coder/claudecode.nvim/pull/572)).

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
