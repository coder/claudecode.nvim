# scripts

## Overview

`scripts/` holds developer and release tooling for claudecode.nvim. Nothing here is loaded by the plugin at runtime. The directory has five groups:

1. Shell libraries that find the plugin's WebSocket server through its lock file and speak JSON-RPC to it (`lib_claude.sh`, `lib_ws_persistent.sh`, `claude_shell_helpers.sh`).
2. Interactive and probe clients built on those libraries (`claude_interactive.sh`, `mcp_test.sh`, `research_messages.sh`, `websocat.sh`, `test_neovim_websocket.sh`).
3. Test harnesses (`run_integration_tests_individually.sh`, `test_opendiff.lua`, `test_opendiff_simple.sh`, `manual_test_helper.lua`).
4. Standalone reproductions of GitHub issues (`repro_issue_*.lua`, `repro_issue_*.sh`).
5. Release tooling: a release-please wrapper that writes changelog entries with Communique (`release-please-runner.js`, `run-release-please.sh`, `package.json`). `test-release-please-runner.js` holds the tests for `release-please-runner.js`.

CI runs four of these files: `.github/workflows/release-please.yaml` runs `./scripts/run-release-please.sh`, and `.github/workflows/test.yml` runs `./scripts/run_integration_tests_individually.sh`, `nvim --headless -u NONE -l scripts/repro_issue_238.lua`, and `npm --prefix scripts run test:release-please-runner` (which runs `test-release-please-runner.js`).

`mise.toml` provisions `websocat` and `jq` for the WebSocket scripts.

## Interface

### Shell libraries (source them)

- `lib_claude.sh` sets `CLAUDE_LOCKFILE_DIR` to `$CLAUDE_CONFIG_DIR/ide`, or to `$HOME/.claude/ide` when `CLAUDE_CONFIG_DIR` is unset. It also exports `CLAUDE_LOG_DIR=mcp_test_logs` and `CLAUDE_WS_TIMEOUT=10` [lib_claude.sh:CLAUDE_LOCKFILE_DIR].
- `find_claude_lockfile` prints the port of the newest `*.lock` file by mtime and returns 1 when none exists. It reads the mtime with GNU `stat -c "%Y"`. BSD `stat` on macOS rejects that option, so there the function finds no lock file [lib_claude.sh:find_claude_lockfile].
- `get_claude_ws_url` prints `ws://localhost:PORT` [lib_claude.sh:get_claude_ws_url].
- `get_claude_auth_token PORT` reads `authToken` from `PORT.lock`, with `jq` or a `grep`/`sed` fallback [lib_claude.sh:get_claude_auth_token].
- `create_message`, `create_notification`, and `create_init_message` print JSON-RPC requests, notifications, and an `initialize` request (protocolVersion `2025-03-26`) [lib_claude.sh:create_message, create_notification, create_init_message].
- `send_claude_message MSG [WS_URL] [AUTH_TOKEN]` sends one message through `timeout` + `websocat` [lib_claude.sh:send_claude_message].
- `list_claude_tools`, `get_current_selection`, `open_file PATH`, and `initialize_claude_session` wrap `tools/list`, `tools/call getCurrentSelection`, `tools/call openFile`, and the initialize handshake [lib_claude.sh:list_claude_tools, get_current_selection, open_file, initialize_claude_session].
- `init_log_dir`, `log_message_and_response`, `claude_is_running`, `command_exists`, and `check_required_tools` are helpers for logging, liveness, and tool checks [lib_claude.sh:init_log_dir, log_message_and_response, claude_is_running, command_exists, check_required_tools].
- `lib_ws_persistent.sh` keeps a WebSocket open across calls. Functions: `ws_connect URL [CONN_ID] [AUTH_TOKEN]`, `ws_is_connected`, `ws_disconnect`, `ws_request JSON [CONN_ID] [TIMEOUT]`, `ws_notify`, `ws_rpc_request`, `ws_create_message`, `ws_format_json`, `ws_cleanup_all`, `ws_setup_trap`, `ws_start_listener CONN_ID CALLBACK [METHOD]`, and `ws_stop_listener` [lib_ws_persistent.sh:ws_connect, ws_request, ws_start_listener].
- `ws_rpc_request` special-cases `mcp.connect`: it sends a notification and returns a fake success [lib_ws_persistent.sh:ws_rpc_request].
- `claude_shell_helpers.sh` defines interactive shell commands: `claude_port`, `claude_ws_url`, `claude_running`, `claude_get_selection [-v]`, `claude_open_file`, `claude_list_tools [-v]`, `claude_send METHOD PARAMS [ID]`, `claude_interactive`, and `claude_help` [claude_shell_helpers.sh:claude_get_selection, claude_send, claude_help].

### WebSocket clients and probes

- `mcp_test.sh [-p PORT] [-l DIR] [-t SEC] [-c] [-h] [tests]` runs the MCP tests `connect`, `toolslist`, `toolinvoke`, `methods`, and `selection`. The default is `all`, and a comma-separated list is accepted. The port defaults to `find_claude_lockfile` [mcp_test.sh:should_run_test, WEBSOCKET_PORT].
- `claude_interactive.sh` (no arguments) is a menu REPL: get selection, list tools, open file, custom JSON-RPC message, initialize, connection info, listen, reconnect, and exit [claude_interactive.sh:show_menu, handle_custom_message, handle_listen].
- `research_messages.sh [-p PORT] [-t SEC] [-l LOGFILE]` listens for TIMEOUT seconds (default 30), probes several method names, and prints counts of methods, ids, and `selection_changed` notifications [research_messages.sh:send_test_message, TIMEOUT].
- `websocat.sh` opens an interactive `websocat` session to `get_claude_ws_url` [websocat.sh:get_claude_ws_url].
- `test_neovim_websocket.sh [-t SEC] [-l SEC] [-d DIR] [-h] [all|connect|toolslist|selection]` starts Neovim with the plugin, waits for a new lock file, and runs connection, `tools/list`, and selection-listen tests [test_neovim_websocket.sh:usage, run_tests, find_newest_lockfile].

### Test harnesses

- `run_integration_tests_individually.sh` (no arguments) runs each `tests/integration/*_spec.lua` in its own headless Neovim under `timeout 30s`, skips `command_args_spec.lua`, and prints totals [run_integration_tests_individually.sh:run_test_file].
- `test_opendiff.lua` is a raw-socket Lua client that sends `tools/call openDiff` with an edited `README.md` [test_opendiff.lua:test_opendiff].
- `test_opendiff_simple.sh` sends the same `openDiff` call through `websocat` or `wscat` and reports exit 124 as "blocked" [test_opendiff_simple.sh:JSON_MESSAGE].
- `manual_test_helper.lua` is run with `:luafile`. It calls the `claudecode.tools.open_diff` handler in a coroutine and reports whether it yields [manual_test_helper.lua:test_opendiff_directly].

### Issue reproductions

The Lua repros run from the repository root with `nvim --headless -u NONE -l scripts/<file>`. They prepend the repo root to `runtimepath` [repro_issue_208.lua:rtp:prepend]. `repro_issue_70_probe.lua` is the exception: it prepends `<repo_root>/lua` to `package.path` instead [repro_issue_70_probe.lua:package.path].

- `repro_issue_70.sh` (#70) checks whether the `claude` CLI connects back to the plugin when an HTTP proxy has no localhost exclusion. It prints `PASS issue #70 reproduced` (exit 0) or `INCONCLUSIVE` (exit 1). It drives `repro_issue_70_probe.lua` [repro_issue_70.sh:run_scenario].
- `repro_issue_70_probe.lua <repo_root> <status_file> <stop_file> <wait_ms>` is a helper, not a standalone repro. It starts the real server with `terminal.provider = "none"` and writes `phase`/`connected` JSON to the status file. Exit 0 means a connection was seen, 2 means none, and 1 means no port [repro_issue_70_probe.lua:write_status].
- `repro_issue_208.lua` (#208) checks for a leftover `[No Name]` tab or buffer after a diff resolves with `open_in_new_tab=true` and `provider=none`. Exit 0 means fixed, 1 means reproduced [repro_issue_208.lua:verdict].
- `repro_issue_218.sh [--no-render-markdown]` (#218) checks for a Neovim crash when a new-file markdown diff is accepted in a new tab with render-markdown.nvim. `NVIM_BIN` selects the binary. Exit 0 means the expected outcome happened [repro_issue_218.sh:WANT_RM, NVIM_BIN].
- `repro_issue_231.lua` (#231) checks that a terminal-only layout does not fail with "No suitable editor window found". Exit 0 means fixed, 1 means reproduced [repro_issue_231.lua:verdict].
- `repro_issue_232.lua` (#232) checks for a `BufEnter` auto-insert autocmd on the terminal buffer. Env: `CLAUDECODE_PROVIDER=snacks|native`, `CLAUDECODE_AUTO_INSERT=true|false`. Exit 1 means reproduced, 0 means not reproduced or skipped, and 2 means a setup error [repro_issue_232.lua:reproduced].
- `repro_issue_238.lua` (#238) checks that `:q` on the proposed window rejects the diff. Exit 0 means fixed, 1 means reproduced. CI runs this file [repro_issue_238.lua:verdict].
- `repro_issue_238.sh --file PATH [--lock-dir DIR] [--out FILE] [--hold SEC] [--tab NAME]` (#238) is an external MCP client. It opens one `openDiff` and holds the socket while you run `:q` in Neovim. It prints a `RESULT:` line, but its exit code does not reflect the result [repro_issue_238.sh:RESULT].
- `repro_issue_246.lua` (#246) checks that single-line and fast visual selections reach Claude. Exit 0 means all checks pass, 1 means a check failed [repro_issue_246.lua:check].
- `repro_issue_248.sh [-n N] [--cleanup]` (#248) opens N diffs and disconnects without `close_tab`. It prints no verdict: run `:DiffState` in Neovim and read the counts [repro_issue_248.sh:NUM_DIFFS, CLEANUP].
- `repro_issue_262.lua` (#262) checks that a setup error after `:tabnew` does not strand a tab. Exit 0 means fixed, 1 means reproduced [repro_issue_262.lua:verdict].
- `repro_issue_277.sh` (#277) runs three phases. Phases 1 and 3 check whether `closeAllDiffTabs` also closes diffview.nvim and user vimdiff windows. Phase 2 checks whether `openFile` runs `:edit` into a foreign diff window. `ISSUE277_ARTIFACTS` sets the artifact directory. The exit code covers all three phases: exit 1 means a phase was not reproduced, 2 means a setup failure, and 3 means a missing tool [repro_issue_277.sh:FAIL, WEBSOCAT].
- `repro_issue_283.lua` (#283) checks the port probe. `REPRO283_MODE` selects `mechanism` (default), `port`, or `serve`. In mechanism mode, exit 1 means reproduced [repro_issue_283.lua:mode].
- `repro_issue_283.sh` (#283) runs `repro_issue_283.lua` in all three modes. `NVIM` overrides the binary. Exit 1 means all three parts reproduced. Exit 0 means "not fully reproduced", not "pass" [repro_issue_283.sh:VERDICT].
- `repro_issue_285.lua` (#285) checks that a path with a `$post` segment is accepted by `:ClaudeCodeAdd` and the `openFile` handler, and that `:ClaudeCodeAdd %` still works. Exit 0 means fixed, 1 means reproduced or a regression [repro_issue_285.lua:verdict].
- `repro_issue_289.lua` (#289) checks that `ClaudeCodeSend` does not treat a Lua buffer as a file-tree buffer because its path contains `neo-tree` or `NvimTree`. Exit 1 means reproduced [repro_issue_289.lua:affected_misrouted].

### Release tooling

- `run-release-please.sh [args]` changes to the repo root and runs `node release-please-runner.js`. It uses `scripts/node_modules/release-please` when present, else the `release-please` on `PATH` through `NODE_PATH` [run-release-please.sh:release_please_bin].
- `node release-please-runner.js [--dry-run]` registers Communique-generated changelog notes and the `simple` release type, then creates releases and release PRs. With `--dry-run` it prints JSON with `releases` and `pullRequests` (including `changelogPreview`) and writes nothing to GitHub [release-please-runner.js:main].
- Environment for `release-please-runner.js`: `GITHUB_TOKEN` and `GITHUB_REPOSITORY` (required), `RELEASE_PLEASE_TARGET_BRANCH`, `GITHUB_OUTPUT`, `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `COMMUNIQUE_MODEL`, and `PRETTIER_BIN` [release-please-runner.js:requireEnv, assertLlmCredentials, resolvePrettierBin].
- `release-please-runner.js` exports `CommuniqueSimpleStrategy`, `UnreleasedAwareChangelog`, `assertLlmCredentials`, `buildCommuniqueArgs`, `createCommuniqueChangelogNotes`, `findLineOutsideFences`, `formatChangelogMarkdown`, `formatChangelogSection`, `formatPullRequestOutputs`, `formatReleaseOutputs`, `normalizeCommuniqueBody`, `resolvePrettierBin`, `releasePleaseNotesAreEmpty`, and `todayIsoDate` [release-please-runner.js:module.exports].
- GitHub Actions outputs: `releases_created`, `release_tags`, `prs_created`, `pr_branches`, and `pr_metadata` [release-please-runner.js:formatReleaseOutputs, formatPullRequestOutputs].
- `package.json` is the private package `claudecode.nvim-release-tools`. It pins `prettier` 3.8.4 and `release-please` 17.9.0 and defines the `test:release-please-runner` script [package.json:scripts].

## Invariants

- Clients find the server port from the lock file name (`PORT.lock`) in `CLAUDE_LOCKFILE_DIR`. `send_claude_message`, the first `ws_connect` in `claude_interactive.sh`, `repro_issue_238.sh`, and `repro_issue_248.sh` send the lock file's `authToken` in the `x-claude-code-ide-authorization` header. `repro_issue_277.sh` sends the same header, but reads the port and the token from the plugin state through nvim RPC [lib_claude.sh:get_claude_auth_token, send_claude_message] [lib_ws_persistent.sh:ws_connect]. `mcp_test.sh`, `test_neovim_websocket.sh`, `research_messages.sh`, `websocat.sh`, `test_opendiff.lua`, and `test_opendiff_simple.sh` send no token. The plugin server rejects their upgrade request when it has an auth token, which `start` always sets [mcp_test.sh:ws_connect] [websocat.sh:websocat].
- `lib_claude.sh` checks only `websocat` and `jq`, and does not exit when they are missing. `send_claude_message` also needs `timeout` [lib_claude.sh:check_required_tools, send_claude_message].
- `send_claude_message` builds a single-quoted `bash -c` string, so a single quote in the message or token breaks the command [lib_claude.sh:send_claude_message].
- `lib_ws_persistent.sh` assumes single-line compact JSON. `ws_request` needs a non-empty `.id`, and `ws_start_listener` matches the exact text `"method":"NAME"` [lib_ws_persistent.sh:ws_request, ws_start_listener].
- `ws_request` reads only response bytes written after the request starts. On timeout it prints the last received line when any bytes arrived, else a JSON-RPC error with code `-32000`. It still returns 0 [lib_ws_persistent.sh:ws_request].
- `ws_connect` disconnects an existing connection with the same `CONN_ID` first, and returns 1 unless the process is alive after 0.5 s [lib_ws_persistent.sh:ws_connect].
- `claude_interactive.sh` exits 1 when `claude_is_running` fails [claude_interactive.sh:claude_is_running]. `claude_running`, `claude_get_selection`, `claude_open_file`, `claude_list_tools`, and `claude_send` return 1 when it fails. `claude_port`, `claude_ws_url`, `claude_interactive`, and `claude_help` do not call it [claude_shell_helpers.sh:claude_send].
- `claude_interactive.sh` `handle_reconnect` calls `ws_connect` without the auth token [claude_interactive.sh:handle_reconnect].
- `run_integration_tests_individually.sh` must run from the repo root. It adds a file to `FAILED_FILES` when it parses failures or errors, or when nvim exits nonzero with a code other than 124 or 143 (timeouts). This includes an nvim crash that prints no `Failed :` line. It exits 1 when `FAILED_FILES` is non-empty or the parsed failure or error totals are non-zero, else 0 [run_integration_tests_individually.sh:FAILED_FILES, TOTAL_FAILED].
- `test_opendiff.lua`, `test_opendiff_simple.sh`, and `repro_issue_238.sh` take the first lock file found, not the newest [test_opendiff.lua:discover_port] [test_opendiff_simple.sh:LOCK_FILE] [repro_issue_238.sh:LOCK_FILE].
- `test_opendiff.lua` and `test_opendiff_simple.sh` hardcode `~/.claude/ide` and ignore `CLAUDE_CONFIG_DIR` [test_opendiff.lua:discover_port] [test_opendiff_simple.sh:LOCK_DIR].
- `manual_test_helper.lua` hardcodes an absolute path to `README.md` in one developer's checkout, and returns early when that file is not readable [manual_test_helper.lua:readme_path].
- `repro_issue_70_probe.lua` resolves the lock directory from `CLAUDE_CONFIG_DIR/ide`, else `$HOME/.claude/ide` [repro_issue_70_probe.lua:config_dir].
- `release-please-runner.js` requires `GITHUB_TOKEN` and `GITHUB_REPOSITORY` in `owner/repo` form [release-please-runner.js:requireEnv, main].
- `assertLlmCredentials` throws when both `ANTHROPIC_API_KEY` and `OPENAI_API_KEY` are empty, or when `ANTHROPIC_API_KEY` is empty and `COMMUNIQUE_MODEL` is unset [release-please-runner.js:assertLlmCredentials].
- When default release-please notes have one line or fewer, the runner returns them without calling Communique [release-please-runner.js:releasePleaseNotesAreEmpty].
- `UnreleasedAwareChangelog` keeps the top `Unreleased` section and inserts new entries below it. Headings inside code fences are ignored [release-please-runner.js:UnreleasedAwareChangelog, findLineOutsideFences].
- `formatChangelogSection` asserts a non-empty version and a `YYYY-MM-DD` date, and writes `## [VERSION] - DATE` without a `v` prefix [release-please-runner.js:formatChangelogSection].
- `resolvePrettierBin` uses `PRETTIER_BIN`, then `scripts/node_modules/.bin/prettier`, then `prettier` on `PATH` [release-please-runner.js:resolvePrettierBin].
- `main` creates releases before release PRs [release-please-runner.js:main].

## Side Effects

- Sourcing `lib_ws_persistent.sh` creates `${TMPDIR:-/tmp}/ws_logs`. `ws_connect` writes `pid`, `log.txt`, `request.json`, and `response.json` under `ws_logs/CONN_ID/` and starts a background `tail -f | websocat | tee` pipeline [lib_ws_persistent.sh:WS_LOG_DIR, ws_connect].
- `ws_disconnect` sends SIGTERM to the saved PID only. It sends SIGKILL only when the SIGTERM send fails, not when the process ignores SIGTERM. `ws_setup_trap` runs `ws_cleanup_all` on EXIT, INT, and TERM, and sourcing the library installs that trap [lib_ws_persistent.sh:ws_disconnect, ws_setup_trap].
- `ws_start_listener` starts a background polling loop (0.5 s) and writes `listener.pid` [lib_ws_persistent.sh:ws_start_listener].
- Log directories are created relative to the current directory: `mcp_test_logs` [mcp_test.sh:LOG_DIR], `mcp_interactive_logs` [claude_interactive.sh:CLAUDE_LOG_DIR], `test_neovim_ws_logs` [test_neovim_websocket.sh:LOG_DIR], and `claude_messages.jsonl` / `claude_messages_pretty.txt` [research_messages.sh:LOG_FILE]. Each run truncates its log files, except `claude_interactive.sh`, which only creates its log directory.
- Sourcing `claude_shell_helpers.sh` sets `CLAUDE_LOG_DIR=$HOME/.claude/logs` and creates that directory [claude_shell_helpers.sh:CLAUDE_LOG_DIR].
- The WebSocket clients connect to the plugin server on `127.0.0.1` or `localhost` at the lock-file port [mcp_test.sh:test_connection] [lib_claude.sh:send_claude_message].
- `open_file` and `claude_open_file` make the connected Neovim open a file [lib_claude.sh:open_file] [claude_shell_helpers.sh:claude_open_file].
- `test_neovim_websocket.sh` writes `/tmp/sample_file.lua` and `/tmp/test_claudecode_init.lua`, starts `nvim` in the background, and on exit kills it and deletes those fixed paths and `/tmp/test_claudecode_buffer.txt` [test_neovim_websocket.sh:SAMPLE_FILE, NVIM_BUFFER_FILE, cleanup].
- `run_integration_tests_individually.sh` creates one `mktemp` file per test and deletes it [run_integration_tests_individually.sh:temp_output].
- `test_opendiff.lua` can loop forever when no response arrives after its 30 s receive timeout [test_opendiff.lua:sock:receive].
- The Lua repros create temp files or directories, stub plugin functions (for example `logger`, `vim.notify`, `diff._create_diff_view_from_window`), and rearrange tabs and windows inside their own headless Neovim [repro_issue_285.lua:logger] [repro_issue_289.lua:vim.notify] [repro_issue_262.lua:_create_diff_view_from_window].
- `repro_issue_231.lua` deletes `<repo_root>/__issue_231_repro__.md` [repro_issue_231.lua:try_open_diff].
- `repro_issue_70.sh` and `repro_issue_277.sh` create `agent-tty` sessions and temp directories, and remove both on exit. They create the temp directory before they install the `EXIT` trap, so an exit 3 for a missing tool leaves that directory behind. `repro_issue_70.sh` launches the real `claude` CLI and sets proxy variables to `http://127.0.0.1:1` in its scenarios [repro_issue_70.sh:run_scenario] [repro_issue_277.sh:cleanup].
- `repro_issue_277.sh` clones diffview.nvim into `${XDG_DATA_HOME:-$HOME/.local/share}/issue-277/diffview.nvim` when it is absent. It copies artifacts to `${TMPDIR:-/tmp}/issue277-artifacts-latest` when `ISSUE277_ARTIFACTS` is unset [repro_issue_277.sh:DIFFVIEW_DIR].
- `repro_issue_218.sh` runs `Lazy! sync`, which downloads fixture plugins. It does not remove its temp directory [repro_issue_218.sh:cleanup].
- Without `--cleanup`, `repro_issue_248.sh` disconnects without `close_tab`. The server then rejects and closes that client's pending diffs, so `:DiffState` shows `active_diffs=0`. With `--cleanup` it calls `closeAllDiffTabs` first [repro_issue_248.sh:CLEANUP].
- `repro_issue_283.lua` binds TCP sockets on `127.0.0.1`. `repro_issue_283.sh` starts a background Neovim and kills it on exit [repro_issue_283.lua:listener:bind] [repro_issue_283.sh:cleanup].
- `release-please-runner.js` without `--dry-run` creates GitHub tags, releases, and pull requests through the GitHub API [release-please-runner.js:main].
- `release-please-runner.js` spawns `communique generate` with the full environment (API keys included) in a temp directory `communique-notes-*` that it removes afterward. It runs `prettier` on each changelog update and appends outputs to `GITHUB_OUTPUT`, or prints them when that variable is unset [release-please-runner.js:createCommuniqueChangelogNotes, formatChangelogMarkdown, writeGithubOutputs].

## Verification

- Run: `npm --prefix scripts run test:release-please-runner` (needs `npm --prefix scripts ci` first).
- Run: `mise run format-check`. treefmt formats and lints `scripts/` with `shfmt` and `shellcheck` (`*.sh`), `stylua` (`*.lua`), and `prettier` (`*.js`, `*.json`, `*.md`).
- `mise run check` runs `luacheck` on `lua/` and `tests/` only, so it does not cover `scripts/`.
