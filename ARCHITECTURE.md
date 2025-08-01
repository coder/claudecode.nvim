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

Manages discovery files for Claude CLI:

```lua
-- Atomic file writing to prevent partial reads
local temp_path = lock_path .. ".tmp"
write_file(temp_path, json_data)
vim.loop.fs_rename(temp_path, lock_path)

-- Cleanup on exit
vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    vim.loop.fs_unlink(lock_path)
  end
})
```

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

### 4. Diff System (`diff.lua`)

Native Neovim diff implementation:

```lua
-- Create temp file with proposed changes
local temp_file = vim.fn.tempname()
write_file(temp_file, new_content)

-- Open diff in current tab to reduce clutter
vim.cmd("edit " .. original_file)
vim.cmd("diffthis")
vim.cmd("vsplit " .. temp_file)
vim.cmd("diffthis")

-- Custom keymaps for diff mode
vim.keymap.set("n", "<leader>da", accept_all_changes)
vim.keymap.set("n", "<leader>dq", exit_diff_mode)
```

### 5. Selection Tracking (`selection.lua`)

Debounced selection monitoring:

```lua
-- Track selection changes with debouncing
local timer = nil
vim.api.nvim_create_autocmd("CursorMoved", {
  callback = function()
    if timer then timer:stop() end
    timer = vim.defer_fn(send_selection_update, 50)
  end
})

-- Visual mode demotion delay
-- Preserves selection context when switching to terminal
```

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
  logger.error("Operation failed: " .. tostring(result))
  return false, result
end
return true, result
```

### Resource Cleanup

Automatic cleanup on shutdown:

```lua
vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    M.stop()  -- Stop server, remove lock file
  end
})
```

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

- **Debounced Updates**: 50ms delay on selection changes
- **Localhost Only**: Server binds to 127.0.0.1
- **Resource Cleanup**: Automatic on vim exit
- **Memory Efficient**: Minimal footprint, no caching
- **Async I/O**: Non-blocking vim.loop operations
