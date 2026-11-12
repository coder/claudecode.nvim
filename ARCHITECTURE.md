# Architecture

This document provides technical details about the claudecode.nvim implementation for developers and contributors.

## Overview

The plugin implements a WebSocket server in pure Lua that speaks the same protocol as Anthropic's official IDE extensions. It's built entirely with Neovim built-ins (`vim.loop`, `vim.json`) with zero external dependencies.

## Core Components

### 1. WebSocket Server (`server/`)

A complete RFC 6455 WebSocket implementation in pure Lua:

```lua
-- server/tcp.lua - TCP server using vim.loop
local tcp = vim.loop.new_tcp()
tcp:bind("127.0.0.1", port)  -- Always localhost!
tcp:listen(128, on_connection)

-- server/handshake.lua - HTTP upgrade handling
-- Validates Sec-WebSocket-Key, generates Accept header
local accept_key = base64(sha1(key .. WEBSOCKET_GUID))

-- server/frame.lua - WebSocket frame parser
-- Handles fragmentation, masking, control frames
local opcode = bit.band(byte1, 0x0F)
local masked = bit.band(byte2, 0x80) ~= 0
local payload_len = bit.band(byte2, 0x7F)

-- server/client.lua - Connection management
-- Tracks state, handles ping/pong, manages cleanup
```

Key implementation details:

- Uses `vim.schedule()` for thread-safe Neovim API calls
- Implements SHA-1 in pure Lua for WebSocket handshake
- Handles all WebSocket opcodes (text, binary, close, ping, pong)
- Automatic ping/pong keepalive every 30 seconds

### 2. Lock File System (`lockfile.lua`)

Writes the discovery file that Claude CLI reads to find the server, and removes it again:

- The file is `<port>.lock` in `$CLAUDE_CONFIG_DIR/ide`, or in `~/.claude/ide` when that variable is unset or empty [lua/claudecode/lockfile.lua:get_lock_dir].
- It holds JSON with `pid`, `workspaceFolders` (the working directory, then the workspace folders of each LSP client), `ideName` (`"Neovim"`), `transport` (`"ws"`) and `authToken` [lua/claudecode/lockfile.lua:M.create] [lua/claudecode/lockfile.lua:M.get_workspace_folders].
- A new lock directory gets mode `0700`, and `create` tries to tighten an existing one to `0700` [lua/claudecode/lockfile.lua:M.create].
- `create` writes the file atomically: it writes a temp file in the same directory, then renames it onto the lock path. The temp file has mode `0600` and is opened with `wx`, so an existing file or symlink at its path makes the open fail. A failed write or rename makes `create` try to remove the temp file:

```lua
-- lockfile.lua, M.create (shortened)
local tmp_path = lock_path .. ".tmp." .. vim.fn.getpid() .. "." .. string.format("%d", vim.loop.hrtime())
local fd = vim.loop.fs_open(tmp_path, "wx", tonumber("600", 8))
-- ... write every byte, close fd ...
os.rename(tmp_path, lock_path)
```

- `remove` deletes the file with `vim.loop.fs_unlink`, which refuses a folder. It returns an error when `vim.loop.fs_lstat` finds nothing or a folder at the lock path, and when `fs_unlink` fails. A lock file that exists but cannot be read (mode 000) is still deleted, and a link at the lock path is removed as a link, never its target [lua/claudecode/lockfile.lua:M.remove].
- `init.lua` owns the lifecycle. `start` calls `create` once the server has bound its port [lua/claudecode/init.lua:M.start]. `stop` calls `remove` and only logs a warning when the removal fails, so a lock file that the removal failed to delete stays [lua/claudecode/init.lua:M.stop]. The `VimLeavePre` autocmd that `setup` creates calls `stop` when the server runs [lua/claudecode/init.lua:M.setup] (see Resource Cleanup).

### 3. MCP Tool System (`tools/`)

Dynamic tool registration with JSON schema validation:

```lua
-- Tool registration
M.register("openFile", {
  type = "object",
  properties = {
    filePath = { type = "string", description = "Path to open" }
  },
  required = { "filePath" }
}, function(params)
  -- Implementation
  vim.cmd("edit " .. params.filePath)
  return { content = {{ type = "text", text = "Opened" }} }
end)

-- Automatic MCP tool list generation
function M.get_tool_list()
  local tools = {}
  for name, tool in pairs(registry) do
    if tool.schema then  -- Only expose tools with schemas
      table.insert(tools, {
        name = name,
        description = tool.schema.description,
        inputSchema = tool.schema
      })
    end
  end
  return tools
end
```

### 4. Diff System (`diff.lua`, `diff_inline.lua`)

The `openDiff` tool calls `open_diff_blocking`. It runs in the tool's coroutine, sets up the diff, and yields until the diff is resolved. The reply to Claude goes out then. When the setup fails (for example, because the file has unsaved changes), it raises an error and does not yield. A `ClaudeCodeDiffOpened` handler can resolve the diff while it is set up. `open_diff_blocking` then returns that result at once and does not yield [lua/claudecode/tools/open_diff.lua:handler] [lua/claudecode/diff.lua:M.open_diff_blocking].

- `diff_opts.layout` picks the layout. `"vertical"` (the default) and `"horizontal"` use Neovim's diff mode: the old file in one window (an empty buffer for a new file), and the proposal in a split to its right or below it. `"unified"` is drawn inline by `diff_inline.lua` and is not a Neovim diff [lua/claudecode/diff.lua:create_split] [lua/claudecode/diff.lua:M._setup_blocking_diff]:

```lua
-- diff.lua, setup_new_buffer (shortened)
vim.api.nvim_set_current_win(original_win)
vim.cmd("diffthis")

create_split()
local new_win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(new_win, new_buf)
...
vim.cmd("diffthis")
```

- The proposal is an unlisted `acwrite` scratch buffer, so `:w` runs the plugin's write handler. It is not a temp file. Its name is `<tab_name> (proposed)` for a native diff of an existing file, `<tab_name> (NEW FILE - proposed)` for a native diff of a new file, and `<tab_name> (unified diff)` for the unified layout [lua/claudecode/diff.lua:M._setup_blocking_diff] [lua/claudecode/diff_inline.lua:M.setup_inline_diff].
- A native diff prefers the current tab (`diff_opts.open_in_new_tab = false`), and goes to an editor window in another tab only when the current tab has none. It opens in a new tab when that option is set, or when the tab that it picks, or the current tab, already has a diff window [lua/claudecode/diff.lua:windows_current_tab_first] [lua/claudecode/diff.lua:find_main_editor_window] [lua/claudecode/diff.lua:M._setup_blocking_diff].
- The plugin sets no keymap for the diff. In the proposal buffer, `:w` accepts it (so do `:wq`, `:x` and `ZZ`), and so does `:ClaudeCodeDiffAccept`. `:ClaudeCodeDiffDeny` rejects it, and so does closing the last window that shows the proposal, deleting its buffer, or switching that window to another buffer (`:edit`, `:enew`). The switch rejects through `BufHidden`, on the next loop turn, and only if the diff is still the same one and the proposal is still hidden. The two commands read the diff from the current buffer, so run them in the proposal buffer: in any other buffer they only warn that no diff is active. The README's example config maps `<leader>aa` and `<leader>ad` to the two commands [lua/claudecode/diff.lua:M._write_proposal] [lua/claudecode/diff.lua:M.accept_current_diff] [lua/claudecode/diff.lua:M.deny_current_diff] [lua/claudecode/diff.lua:M._register_reject_when_hidden].
- A diff resolves once. Accept replies `FILE_SAVED` with the content, and reject replies `DIFF_REJECTED` [lua/claudecode/diff.lua:M._resolve_diff_as_saved] [lua/claudecode/diff.lua:M._resolve_diff_as_rejected]. The plugin does not write the target file. Normally Claude writes it after `FILE_SAVED`. When that Claude session ends or drops the answer before it writes, `:ClaudeCodeCloseAllDiffs` puts the accepted text into the file's buffer as unsaved changes. A diff whose buffer cannot take the text (for example, because it has unsaved changes) stays open [lua/claudecode/diff.lua:M.close_saved_diffs].
- Only `open_diff` writes a temp file. It is the non-blocking entry point, and the plugin does not call it. The file goes under `stdpath("cache")/claudecode_diffs/<session folder>`, or under `claudecode_diffs_fallback` when the first folder cannot be made. `vim.fn.tempname()` supplies only a part of the session folder name, with the time and the PID [lua/claudecode/diff.lua:create_temp_file] [lua/claudecode/diff.lua:M._open_native_diff].

### 5. Selection Tracking (`selection.lua`)

Pushes a `selection_changed` notification when the selection Claude should see differs from the last one sent. Most updates are debounced, and three events are not:

- **Debounced, 100 ms.** `CursorMoved`, `CursorMovedI`, `BufEnter`, `ModeChanged`, `TextChanged`, `TextChangedI` and `TextChangedP` each restart a one-shot timer. When it fires, `update_selection` reads the mode and sends the selection, or the cursor in normal mode.
- **At once.** Leaving visual mode sends the selection from the `'<` and `'>` marks (the flush). Editing the held text, or consuming it with an operator, sends the cursor. Moving the cursor away from a held selection sends the cursor. When the held text changes while you are in the Claude terminal (Neovim reloads the file, or a plugin edits it), the cursor of its file goes out too: `TextChanged` fires only for the current buffer, so a listener from `nvim_buf_attach` on the file's buffer sees the change.
- **Entering another file** waits for the debounce.
- **Claude terminal buffers** are skipped.

A selection released with Esc stays with Claude (issue #246) until the cursor moves away, you start another selection, an operator consumes it, its text changes, or you go to another file. Going to the Claude terminal keeps it, and so does coming back to the file with the cursor where you released the selection. When a released selection has been left but the plugin has not replaced it yet, a demotion timer of `visual_demotion_delay_ms` (default 50 ms) replaces it with the cursor. The timer does nothing in the Claude terminal, in visual mode, or while the cursor is still where you released the selection.

### 6. Terminal Integration (`terminal.lua`)

Flexible terminal management with provider pattern:

```lua
-- Snacks.nvim provider (preferred)
if has_snacks then
  Snacks.terminal.open(cmd, {
    win = { position = "right", width = 0.3 }
  })
else
  -- Native fallback
  vim.cmd("vsplit | terminal " .. cmd)
end
```

## Key Implementation Patterns

### Thread Safety

All Neovim API calls from async contexts use `vim.schedule()`:

```lua
client:on("message", function(data)
  vim.schedule(function()
    -- Safe to use vim.* APIs here
  end)
end)
```

### Error Handling

Consistent error propagation pattern:

```lua
local ok, result = pcall(risky_operation)
if not ok then
  logger.error("server", "Operation failed: " .. tostring(result))
  return false, result
end
return true, result
```

### Resource Cleanup

At exit, Neovim fires `BufUnload` for each loaded buffer, and then runs the `VimLeavePre` autocmds. The plugin registers two of them, and they run in this order. Neovim runs the autocmds of one event in the order that they were registered. `diff.lua` registers its autocmd when it first loads, and `M.setup` loads `diff.lua` before it registers its own [lua/claudecode/init.lua:M.setup].

First, the autocmd of `diff.lua`, in the `ClaudeCodeMCPDiff` group, rejects each diff whose status is `pending`, oldest first, while the server still runs. Then it closes every diff and clears its state. It runs whether or not the server runs [lua/claudecode/diff.lua:cleanup_at_exit] [lua/claudecode/diff.lua:M._cleanup_all_active_diffs]:

```lua
-- diff.lua, module level (shortened)
local function cleanup_at_exit()
  -- reject each diff that is pending, oldest first, each under pcall
  M._cleanup_all_active_diffs("shutdown") -- close each diff and clear its state
end

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = get_autocmd_group(), -- "ClaudeCodeMCPDiff"
  callback = cleanup_at_exit,
})
```

The `BufUnload` loop that runs before both autocmds already rejects most diffs, because the `BufUnload` autocmd of a proposal buffer rejects its diff [lua/claudecode/diff.lua:register_diff_autocmds]. That loop stops when an autocmd deletes the buffer that it fired for, and SIGTERM and SIGHUP run `VimLeavePre` without the loop. The reject pass of `cleanup_at_exit` rejects the diffs that the loop did not reach, and it skips a diff whose status is not `pending`. A reject can remove its own diff (a new-file diff with `on_new_file_reject = "keep_empty"`), so a diff can be gone before the next one is rejected.

Second, the autocmd of `init.lua`, in the `ClaudeCodeShutdown` group, runs `stop` only when the server runs. Without a server, it only clears the @-mention queue [lua/claudecode/init.lua:M.setup] [lua/claudecode/init.lua:clear_mention_queue]. `stop` removes the lock file, stops the server, and clears the queue [lua/claudecode/init.lua:M.stop]. The server's own `stop` sends a response for each request whose handler is still running, and the TCP server then closes each client with the close code 1001 [lua/claudecode/server/init.lua:M.stop] [lua/claudecode/server/tcp.lua:M.stop_server]:

```lua
-- init.lua, M.setup (shortened)
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("ClaudeCodeShutdown", { clear = true }),
  callback = function()
    if M.state.server then
      M.stop()  -- Stop server, try to remove lock file (only logs a warning when it cannot)
    else
      -- Clear queue even if server isn't running
      clear_mention_queue()
    end
  end,
})
```

SIGKILL, a crash, and a quit from inside an autocmd that is not `nested` run neither autocmd. What Claude receives for each kind of call, in each kind of exit, is in the root [README.md](./README.md), under Global Invariants.

## Module Structure

```
lua/claudecode/
├── init.lua              # Plugin entry point
├── config.lua            # Configuration management
├── server/               # WebSocket implementation
│   ├── tcp.lua           # TCP server (vim.loop)
│   ├── handshake.lua     # HTTP upgrade handling
│   ├── frame.lua         # RFC 6455 frame parser
│   ├── client.lua        # Connection management
│   └── utils.lua         # Pure Lua SHA-1, base64
├── tools/init.lua        # MCP tool registry
├── diff.lua              # Native diff support
├── selection.lua         # Selection tracking
├── terminal.lua          # Terminal management
└── lockfile.lua          # Discovery files
```

## Testing

### Automated Testing

Three-layer testing strategy using busted:

```lua
-- Unit tests: isolated function testing
describe("frame parser", function()
  it("handles masked frames", function()
    local frame = parse_frame(masked_data)
    assert.equals("hello", frame.payload)
  end)
end)

-- Component tests: subsystem testing
describe("websocket server", function()
  it("accepts connections", function()
    local server = Server:new()
    server:start(12345)
    -- Test connection logic
  end)
end)

-- Integration tests: end-to-end with mock Claude
describe("full flow", function()
  it("handles tool calls", function()
    local mock_claude = create_mock_client()
    -- Test complete message flow
  end)
end)
```

### Integration Testing with Fixtures

Manual testing with real Neovim configurations in the `fixtures/` directory:

```bash
# Test with different file explorers
source fixtures/nvim-aliases.sh
vv nvim-tree  # Test with nvim-tree integration
vv oil        # Test with oil.nvim integration
vv mini-files # Test with mini.files integration
vv netrw      # Test with built-in netrw

# Each fixture provides:
# - Complete Neovim configuration
# - Plugin dependencies
# - Development keybindings
# - Integration-specific testing scenarios
```

**Fixture Architecture**:

- `fixtures/bin/` - Helper scripts (`vv`, `vve`, `list-configs`)
- `fixtures/[integration]/` - Complete Neovim configs for testing
- `fixtures/nvim-aliases.sh` - Shell aliases for easy testing

## Performance & Security

- **Debounced Updates**: 100 ms debounce on selection changes, except leaving visual mode, editing or consuming the held text, and moving the cursor away from a held selection, which report at once
- **Localhost Only**: Server binds to 127.0.0.1
- **Resource Cleanup**: At exit, two `VimLeavePre` autocmds run. The one in `diff.lua` runs first and rejects each pending diff. The one in `init.lua` runs `stop` when the server runs, and `stop` stops the server and tries to remove the lock file [lua/claudecode/diff.lua:cleanup_at_exit] [lua/claudecode/init.lua:M.setup] [lua/claudecode/init.lua:M.stop]. A SIGKILL, a crash, or a quit from inside an autocmd that is not `nested` skips both and leaves the lock file
- **In-memory State**: The plugin keeps, among other things, the latest selection [lua/claudecode/selection.lua:M.state], the proposed text of each open diff [lua/claudecode/diff.lua:M._register_diff_state], an input buffer for each connected client [lua/claudecode/server/client.lua:M.create_client], and the @-mentions that wait to go out [lua/claudecode/init.lua:mention_queue]. `lockfile.lua` reads `CLAUDE_CONFIG_DIR` once, when it loads [lua/claudecode/lockfile.lua:get_lock_dir]
- **Async and Blocking I/O**: Sockets and timers use libuv callbacks. The TCP server accepts connections and reads through callbacks, writes with libuv's asynchronous `write`, and runs its ping timer from a libuv timer [lua/claudecode/server/tcp.lua:M._bind_and_listen] [lua/claudecode/server/tcp.lua:M._handle_new_connection] [lua/claudecode/server/client.lua:write] [lua/claudecode/server/tcp.lua:M.start_ping_timer]. The selection debounce and the @-mention queue use timers [lua/claudecode/selection.lua:M.debounce_update] [lua/claudecode/init.lua:start_timer]. File I/O is synchronous and blocks Neovim until it returns: `lockfile.lua` calls `fs_open`, `fs_write`, `fs_close`, `fs_stat`, `fs_lstat` and `fs_unlink` without callbacks, reads the lock file with `io.open`, and uses `os.rename` [lua/claudecode/lockfile.lua:M.create] [lua/claudecode/lockfile.lua:M.remove] [lua/claudecode/lockfile.lua:M.get_auth_token], and `diff.lua` reads and writes files with `io.open` [lua/claudecode/diff.lua:read_file] [lua/claudecode/diff.lua:create_temp_file]
