# claudecode

## Overview

`claudecode` is the core package of claudecode.nvim. It makes Neovim an IDE peer for the Claude Code CLI. It does six jobs:

1. It starts a localhost MCP WebSocket server ([`./server/README.md`](./server/README.md)).
2. It writes a discovery lock file that holds an auth token.
3. It launches the CLI in a terminal provider ([`./terminal/README.md`](./terminal/README.md)) with env vars that point the CLI at the server.
4. It serves MCP tool calls ([`./tools/README.md`](./tools/README.md)).
5. It streams selection and @-mention notifications to the CLI.
6. It shows blocking accept/reject diffs for the edits that Claude proposes.

Module map (direct files):

| File                  | Role                                                                                         |
| --------------------- | -------------------------------------------------------------------------------------------- |
| `init.lua`            | Entry point: `setup`, `start`/`stop`, user commands, @-mention queue                         |
| `config.lua`          | Defaults, legacy-option mapping, and assert-based validation                                 |
| `lockfile.lua`        | `<port>.lock` discovery file and auth token                                                  |
| `terminal.lua`        | Provider dispatcher: command, env, cwd, `send_to_terminal`                                   |
| `diff.lua`            | Native side-by-side blocking diff and the diff lifecycle                                     |
| `diff_inline.lua`     | Unified (`layout = "unified"`) inline diff renderer                                          |
| `selection.lua`       | Visual and cursor selection tracking and the `selection_changed` broadcast                   |
| `integrations.lua`    | File-explorer selection readers (nvim-tree, neo-tree, oil, mini.files, netrw, snacks picker) |
| `visual_commands.lua` | Visual-mode command wrapper and tree-explorer line-to-path mapping                           |
| `cwd.lua`             | Terminal working-directory resolution and git root lookup                                    |
| `utils.lua`           | Shell-free argv parsing, tilde expansion, the selection type of a mode, and UTF-8 repair     |
| `logger.lua`          | Level-filtered logging to `vim.notify` and `nvim_echo`                                       |
| `health.lua`          | `:checkhealth claudecode`                                                                    |
| `types.lua`           | LuaLS `@class` and `@alias` declarations. Its only runtime code is `return {}`               |

## Interface

### Subdirectories

- [`./server/README.md`](./server/README.md): WebSocket (RFC 6455) and JSON-RPC 2.0 MCP server. API: `start(config, auth_token)`, `stop()`, `send`, `send_response`, `broadcast`, and `get_status()`.
- [`./terminal/README.md`](./terminal/README.md): the `native`, `snacks`, `external`, and `none` providers, plus `paste_fix` for streamed pastes.
- [`./tools/README.md`](./tools/README.md): the MCP tool registry. It exposes 10 tools and the hidden `close_tab`.

### Entry point (`init.lua`)

- `M.setup(opts) -> M`: applies config, sets up the logger, terminal, and diff modules, and creates commands and the shutdown autocmd. It starts the server when `auto_start` is set [init.lua:M.setup]
- `M.start(show_startup_notification?) -> ok, port|err` and `M.stop() -> ok, err?` [init.lua:M.start]
- `M.state`: `config`, `server`, `port`, `auth_token`, `initialized`, `mention_queue`, `mention_timer`, and `connection_timer` [init.lua:M.state]
- `M.is_claude_connected()`: false when the server is not running. When `get_status().clients` is non-empty, true only when a client has `handshake_complete`. When it is empty, true when `client_count > 0`, with no handshake check [init.lua:M.is_claude_connected]
- `M.send_at_mention(file_path, start_line?, end_line?, context?) -> ok, err?`: line numbers are 0-indexed [init.lua:M.send_at_mention]
- `M.process_mention_queue(from_new_connection?)`: the server's `on_connect` callback calls it [init.lua:M.process_mention_queue]
- `M.open_with_model(args)`, `M.get_version()`, and `M.version` (`0.2.0`) [init.lua:M.version]
- Internal API: `M._create_commands`, `M._broadcast_at_mention`, `M._add_paths_to_claude` (default `max_files` 100, `batch_size` 10), `M._format_path_for_at_mention`, `M._ensure_terminal_visible_if_connected`, and `M._maybe_warn_unfocusable_provider` [init.lua:M._add_paths_to_claude]

### User commands [init.lua:M._create_commands]

- Server: `:ClaudeCodeStart`, `:ClaudeCodeStop`, and `:ClaudeCodeStatus`.
- Context: `:ClaudeCodeSend` (range, tree-aware), `:ClaudeCodeTreeAdd`, and `:ClaudeCodeAdd <path> [start] [end]`.
- Terminal: `:ClaudeCode [args]`, `:ClaudeCodeFocus [args]`, `:ClaudeCodeOpen [args]`, `:ClaudeCodeClose`, and `:ClaudeCodeSendText[!] <text>`. These commands exist only when `claudecode.terminal` loads.
- Diff: `:ClaudeCodeDiffAccept`, `:ClaudeCodeDiffDeny`, and `:ClaudeCodeCloseAllDiffs`.
- Model: `:ClaudeCodeSelectModel [args]`.

### User autocmd events

- `User ClaudeCodeSendComplete` with `data = { file_path, start_line, end_line, context }` [init.lua:fire_send_complete]
- `User ClaudeCodeDiffOpened` and `User ClaudeCodeDiffClosed` [diff.lua:fire_diff_event]

### Configuration (`config.lua`)

- `M.defaults`, `M.apply(user_config) -> config`, and `M.validate(config) -> true` [config.lua:M.apply]
- Defaults: `port_range = { min = 10000, max = 65535 }`, `auto_start = true`, `log_level = "info"`, `track_selection = true`, `focus_after_send = false`, `visual_demotion_delay_ms = 50`, `connection_wait_delay = 600`, `connection_timeout = 10000`, `queue_timeout = 5000`, `terminal.provider = "auto"`, and six `models` entries [config.lua:M.defaults]
- `diff_opts` defaults: `layout = "vertical"`, `open_in_new_tab = false`, `keep_terminal_focus = false`, `hide_terminal_in_new_tab = false`, `on_new_file_reject = "keep_empty"`, and `auto_resize_terminal = true` [config.lua:M.defaults]

### Other modules

- `terminal.lua`: `setup`, `open`, `close`, `simple_toggle`, `focus_toggle`, `toggle`, `toggle_open_no_focus`, `ensure_visible`, `get_active_terminal_bufnr`, and `send_to_terminal(text, { submit = true, focus = false })` [terminal.lua:M.send_to_terminal]
- `terminal.lua` test hook: `_get_managed_terminal_for_test()` returns the provider's `_get_terminal_for_test()` result, or nil [terminal.lua:M._get_managed_terminal_for_test]
- `terminal.lua` defaults: `split_side = "right"`, `split_width_percentage = 0.30`, `provider = "auto"`, `auto_close = true`, `auto_insert = true`, `fix_streamed_paste = "auto"`, and `git_repo_cwd = false` [terminal.lua:M.defaults]
- `diff.lua`: `setup`, `open_diff(old_file_path, new_file_path, new_file_contents, tab_name)` (wraps `_open_native_diff`), `open_diff_blocking(old_file_path, new_file_path, new_file_contents, tab_name, client_id)`, `close_diff_by_tab_name`, `close_all_diffs`, `close_pending_diffs`, `close_saved_diffs`, `close_diffs_for_client`, `accept_current_diff`, `deny_current_diff`, and `reload_file_buffers_manual` [diff.lua:M.open_diff_blocking]
- `diff_inline.lua`: `setup_inline_diff`, `compute_inline_diff`, `extract_new_content`, `render_diff_buffer`, `resolve_inline_as_saved`, `resolve_inline_as_rejected`, and `cleanup_inline_diff` [diff_inline.lua:M.setup_inline_diff]
- `selection.lua`: `enable(server, visual_demotion_delay_ms)`, `disable`, `get_latest_selection`, `send_current_selection`, `get_range_selection`, `send_at_mention_for_visual_selection`, and the autocmd handlers `on_cursor_moved`, `on_mode_changed`, and `on_text_changed` [selection.lua:M.enable]
- `selection.lua` internals: `state`, `debounce_update`, `update_selection`, `handle_selection_demotion`, `get_visual_selection`, `get_visual_selection_from_marks`, `flush_visual_selection`, `get_cursor_position`, `has_selection_changed`, and `send_selection_update` [selection.lua:M.update_selection]
- `lockfile.lua`: `lock_dir`, `generate_auth_token`, `create(port, auth_token?) -> ok, path, token`, `remove`, `update`, `get_auth_token`, and `get_workspace_folders` [lockfile.lua:M.create]
- `integrations.lua`: `get_selected_files_from_tree()` dispatches on filetype to `_get_nvim_tree_selection`, `_get_neotree_selection`, `_get_oil_selection`, `_get_mini_files_selection`, `_get_mini_files_selection_with_range(start_line, end_line)`, `_get_netrw_selection`, and `_get_snacks_picker_selection` [integrations.lua:M.get_selected_files_from_tree]
- `visual_commands.lua`: `create_visual_command_wrapper`, `exit_visual_and_schedule`, `validate_visual_mode`, `get_visual_range`, `get_tree_state`, `capture_visual_selection_data`, and `get_files_from_visual_selection` [visual_commands.lua:M.create_visual_command_wrapper]
- `cwd.lua`: `resolve(term_cfg, ctx)` and `git_root(start_dir)` [cwd.lua:M.resolve]
- `utils.lua`: `shell_split`, `parse_command`, `expand_tilde`, `normalize_focus`, `selection_type`, `utf8_sequence_length`, and `valid_utf8` [utils.lua:M.parse_command] [utils.lua:M.valid_utf8]
- `logger.lua`: `levels`, `setup`, `error`, `warn`, `info`, `debug`, `trace`, and `is_level_enabled` [logger.lua:M.setup]
- `health.lua`: `check()` [health.lua:M.check]

## Invariants

### Lifecycle and auth

- `setup` runs `config.apply` before logger, terminal, and diff setup. The auto-start runs only after `diff.setup` [init.lua:M.setup]
- `start` refuses with "Already running". The auth token must be a string of length 10 or more. If `server.start` fails, `start` returns the error at once. If the lock file fails, `start` stops the server and clears its state [init.lua:M.start]
- `start` requires the token returned by `lockfile.create` to equal the generated token. Otherwise it stops the server [init.lua:M.start]
- `stop` returns "Not running" without a server. When `lockfile.remove` returns an error, `stop` only logs a warning. `lockfile.remove` returns `true` even when `os.remove` fails without raising (for example in a read-only directory), so that failure is silent and the lock file stays [init.lua:M.stop] [lockfile.lua:M.remove]
- The auth token is 32 lowercase hex characters from `vim.loop.random` or `/dev/urandom`. It never comes from `math.random` [lockfile.lua:get_random_bytes]
- The lock directory is `$CLAUDE_CONFIG_DIR/ide` when that variable is set, else `~/.claude/ide`. It is resolved once when the module loads [lockfile.lua:M.lock_dir]
- `lockfile.create` requires a port in 1..65535 and a caller token of 10..500 characters. It writes JSON `{ pid, workspaceFolders, ideName = "Neovim", transport = "ws", authToken }` [lockfile.lua:M.create]

### Configuration and terminal

- `config.validate` asserts most top-level fields. It does not assert `disable_broadcast_debouncing` or `enable_broadcast_debouncing_in_tests`. Examples: `0 < port_range.min <= max <= 65535`, `log_level` in `trace|debug|info|warn|error`, `env` values are strings, `models` is a non-empty list of `{ name, value }`, and `diff_opts.layout` is `vertical|horizontal|unified`. For `terminal` it asserts only that it is a table and checks `provider_opts`. It does not assert `terminal.provider` or other `terminal.*` keys [config.lua:M.validate]
- `config.apply` deep-copies the defaults. It maps the legacy `vertical_split` option to `layout`, and legacy `open_in_current_tab` to `open_in_new_tab` [config.lua:M.apply]
- Provider selection: `auto` uses snacks if available, else native. `external` requires `external_terminal_cmd` as a function or as a string containing `%s`. Every other failure falls back to `native` [terminal.lua:get_provider]
- The Claude command is `terminal_cmd`, or `claude` when it is unset. `no_proxy` and `NO_PROXY` always include `localhost`, `127.0.0.1`, and `::1` [terminal.lua:get_claude_command_and_env]
- Terminal cwd precedence: `cwd_provider`, then static `cwd`, then the git root when `git_repo_cwd` is set [terminal.lua:build_config]
- `send_to_terminal` never opens a terminal. It refuses the `none` and `external` providers. It wraps multi-line text in bracketed-paste markers [terminal.lua:M.send_to_terminal]
- `utils.parse_command` does no globbing or variable expansion, so model aliases such as `opus[1m]` stay intact [utils.lua:M.parse_command]

### @-mentions and selection

- Line numbers sent to Claude are 0-indexed. `:ClaudeCodeAdd` converts the 1-indexed input [init.lua:M._create_commands]
- A mention sent while disconnected goes to the queue, and the terminal opens. The queue drops mentions older than `queue_timeout` and is cleared after `connection_timeout` [init.lua:M.process_mention_queue]
- Selection tracking is a no-op unless it is enabled. Updates are debounced by 100 ms. Claude terminal buffers are skipped [selection.lua:M.update_selection]
- The automatic paths send `selection_changed` only when the selection differs from the last one sent [selection.lua:M.update_selection] [selection.lua:M.flush_visual_selection]. `send_current_selection` sends with no change check [selection.lua:M.send_current_selection]
- Select mode (`gh`, or `v`, `V` and CTRL-V when `'selectmode'` contains `cmd`) is tracked like Visual mode [selection.lua:is_visual_mode], and a command such as a `<cmd>ClaudeCodeSend<CR>` mapping takes the visual path there [visual_commands.lua:M.create_visual_command_wrapper]
- A visual selection is flushed on visual exit. The flush is skipped if the buffer changed during visual mode [selection.lua:M.flush_visual_selection]
- `selection_changed` positions are 0-based lines and 0-based UTF-8 byte offsets into the buffer line, not VS Code's UTF-16 code units. `end` is exclusive. A position inside a multibyte code point, such as a stale mark after an edit and `gv`, moves back to the code point's first byte [selection.lua:code_point_start]. A charwise or blockwise selection ends after the character that starts at its end position, the way Neovim selects it. That character is what the cursor and `y` treat as one (`vim.fn.byteidx`): it includes its composing characters, and on Neovim 0.11+ the rest of its grapheme cluster. On Neovim 0.11+ a control, such as a TAB, U+0085 or U+200B, is a character of its own, without the composing characters after it. With `'selection'` set to `exclusive`, a selection of more than one position ends after the character before that position instead [selection.lua:selection_end_byte]
- A charwise selection that includes a line break (`v$`) ends at the start of the next line, and its text ends with that line break, as Neovim yanks it. On the buffer's last line, for a blockwise selection, and with `'virtualedit'` containing `all` (where the end is a virtual space), the end stays at the end of the line. On an empty line, and for a block whose last row is empty, that end is `character` 1, because Claude Code counts an end at `character` 0 as the line before. With `all`, the text has none of the virtual spaces that Neovim's `y` adds. A blockwise selection sends the contiguous span between its first and last positions, not the rectangle [selection.lua:end_past_line]
- A linewise selection ends on its last line at that line's byte length. When that line is empty and another line follows, it ends at the start of the next line, and its text ends with the empty line's line break, because Claude Code counts an end at `character` 0 as the line before. An empty last line of the buffer ends at `character` 1 [selection.lua:extract_linewise_text]
- A mention sent without a range from a tracked selection that ends at `character` 0 of a line ends on the line before [selection.lua:M.send_at_mention_for_visual_selection]
- Selection text sent to Claude is always valid UTF-8. Each invalid byte sequence in the buffer becomes U+FFFD, so the text can be longer than the byte range of its positions [utils.lua:M.valid_utf8]

### Diffs

- `open_diff_blocking` must run inside a non-main coroutine. Otherwise it raises `-32000` [diff.lua:M.open_diff_blocking]
- `open_diff_blocking` makes `old_file_path` absolute against the cwd at the call, so a later `:cd` does not change the file a diff points at [diff.lua:M.open_diff_blocking]
- A diff starts from a window that shows the old file, or from the main editor window. Neither is a diff window or the preview window [diff.lua:M._setup_blocking_diff] [diff.lua:find_main_editor_window]
- A new diff with an existing tab name first rejects the old diff (if pending), then cleans it up [diff.lua:M.open_diff_blocking]
- A diff that resolves before `open_diff_blocking` yields, for example from a `ClaudeCodeDiffOpened` handler that runs `:ClaudeCodeDiffDeny`, is returned at once as the openDiff reply instead of a deferred one [diff.lua:M.open_diff_blocking]
- When the target buffer is dirty, diff setup raises `-32000` with message "Diff setup failed". Its `data` holds the inner error, which contains "Cannot create diff: file has unsaved changes" [diff.lua:M._setup_blocking_diff]
- A diff resolves only from status `pending`. Save returns `FILE_SAVED` and the content. Reject returns `DIFF_REJECTED` and the tab name [diff.lua:M._resolve_diff_as_saved]
- Saving the proposed buffer (`BufWriteCmd`) never writes the file. It only resolves the diff. Windows stay open until `close_tab` [diff.lua:register_diff_autocmds]
- `close_pending_diffs` and `close_diffs_for_client` close only `pending` diffs. `close_all_diffs` closes every diff [diff.lua:M.close_pending_diffs]
- `close_saved_diffs`, which `:ClaudeCodeCloseAllDiffs` runs after `close_pending_diffs`, closes a `saved` diff only once its file or the file's buffer holds the accepted text. When the file does not hold it, and the file's buffer has no unsaved changes and an empty `'buftype'`, it first loads the file into its buffer and sets the accepted lines there, unsaved. It never writes the file. It also makes the buffer durable: a `'bufhidden'` of `wipe`, `delete`, or `unload` becomes `hide`. It returns the count, the paths whose buffer got the text, and the paths of the saved diffs it kept [diff.lua:M.close_saved_diffs]

## Side Effects

- `:ClaudeCodeCloseAllDiffs` can load an accepted diff's file into a listed buffer and replace its lines with the accepted text, leaving the buffer modified [diff.lua:M.close_saved_diffs]
- `start` binds a `127.0.0.1` TCP port and writes the lock file. It enables selection tracking only when `track_selection` is true. `stop` removes the lock file and stops the server [init.lua:M.start]
- `lockfile.create` creates the lock directory with mode 0700. It then tries to chmod an existing directory to 0700 through `pcall` and ignores the result, so on platforms without `fs_chmod` the old mode stays. It writes a temp file opened `wx` with mode 0600, then renames it to `<port>.lock` [lockfile.lua:M.create]
- The terminal env gets `ENABLE_IDE_INTEGRATION=true`, `FORCE_CODE_TERMINAL=true`, `CLAUDE_CODE_SSE_PORT=<port>` only while the server runs, the user `env` (merged last, so it can override these), and the merged `no_proxy`/`NO_PROXY` [terminal.lua:get_claude_command_and_env]
- `terminal.setup` can replace the global `vim.paste` through `paste_fix.apply` [terminal.lua:M.setup]
- The plugin broadcasts `at_mentioned` (`filePath`, `lineStart`, `lineEnd`) [init.lua:M._broadcast_at_mention] and `selection_changed` [selection.lua:M.send_selection_update] to every connected client
- Augroups: `ClaudeCodeShutdown`, which holds the `VimLeavePre` autocmd that stops on exit [init.lua:M.setup], `ClaudeCodeSelection` [selection.lua:M._create_autocommands], `ClaudeCodeMCPDiff` [diff.lua:get_autocmd_group], `ClaudeCodeDiffCleanup` [diff.lua:M._open_native_diff], and a module-level `VimLeavePre` autocmd in `diff.lua` that calls `M._cleanup_all_active_diffs("shutdown")` [diff.lua:M._cleanup_all_active_diffs]
- Diffs create scratch buffers, splits, and tabs. They resize the terminal window and fire `User` events. Cleanup closes these and reloads unchanged file buffers 100 ms after a save [diff.lua:M.close_diff_by_tab_name]
- The native diff writes each temp file into its own session folder under `stdpath("cache")/claudecode_diffs`, or `claudecode_diffs_fallback` when it cannot create a directory in the first. The folder name includes the Neovim PID, so two running Neovim processes never share one. If both fail, `open_diff` returns `success = false` with an error that names both directories [diff.lua:create_temp_file]. A `BufDelete`/`BufWipeout` autocmd on the proposed buffer cleans up once, even when a wipe fires both events. It deletes the file and then its empty folder with `vim.fn.delete`, and warns once for each delete that fails. When the file delete fails, the folder is not empty, so its delete fails too and both warnings show [diff.lua:cleanup_temp_file]. `_cleanup_diff_state` does not [diff.lua:M._open_native_diff]
- `diff_inline.lua` creates the `claudecode_inline_diff` namespace when the module loads. It defines the four `ClaudeCodeInlineDiff*` highlight groups (with `default = true`) [diff_inline.lua:setup_highlights] and sets extmarks [diff_inline.lua:M.render_diff_buffer]
- The plugin runs `git rev-parse --show-toplevel` for the git root [cwd.lua:M.git_root], and `health.check` runs `<claude> --version` [health.lua:check_cli]
- `logger` defers all output through `vim.schedule`. ERROR and WARN go to `vim.notify`. Other levels go to `nvim_echo` [logger.lua:log]

## Verification

- Run: `mise run test`
- Targeted: `busted -v tests/unit/init_spec.lua`, `busted -v tests/unit/config_spec.lua`, `busted -v tests/unit/diff_spec.lua`, `busted -v tests/unit/diff_inline_spec.lua`, `busted -v tests/unit/terminal_spec.lua`, `busted -v tests/unit/utils_spec.lua`, `busted -v tests/unit/health_spec.lua`, `busted -v tests/unit/logger_spec.lua`, `busted -v tests/integration/basic_spec.lua`
