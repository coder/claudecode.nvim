# How Claude Code IDE Extensions Actually Work

This document explains the protocol and architecture behind Claude Code's IDE integrations, based on reverse-engineering the VS Code extension. Use this guide to build your own integrations or understand how the official ones work.

## TL;DR

Claude Code extensions create WebSocket servers in your IDE that Claude connects to. They use a WebSocket variant of MCP (Model Context Protocol) that only Claude supports. The IDE writes a lock file with connection info, sets some environment variables, and Claude automatically connects when launched.

## How Discovery Works

When you launch Claude Code from your IDE, here's what happens:

### 1. IDE Creates a WebSocket Server

The extension starts a WebSocket server on a random port (10000-65535) that listens for connections from Claude.

### 2. Lock File Creation

The IDE writes a discovery file to `~/.claude/ide/[port].lock`:

```json
{
  "pid": 12345, // IDE process ID
  "workspaceFolders": ["/path/to/project"], // Open folders
  "ideName": "VS Code", // or "Neovim", "IntelliJ", etc.
  "transport": "ws", // WebSocket transport
  "authToken": "550e8400-e29b-41d4-a716-446655440000" // Random UUID for authentication
}
```

### 3. Environment Variables

When launching Claude, the IDE sets:

- `CLAUDE_CODE_SSE_PORT`: The WebSocket server port
- `ENABLE_IDE_INTEGRATION`: Set to "true"

### 4. Claude Connects

Claude reads the lock files, finds the matching port from the environment, and connects to the WebSocket server.

## Authentication

When Claude connects to the IDE's WebSocket server, it must authenticate using the token from the lock file. The authentication happens via a custom WebSocket header:

```
x-claude-code-ide-authorization: 550e8400-e29b-41d4-a716-446655440000
```

The IDE validates this header against the `authToken` value from the lock file. If the token doesn't match, the connection is rejected.

## The Protocol

Communication uses WebSocket with JSON-RPC 2.0 messages:

```json
{
  "jsonrpc": "2.0",
  "method": "method_name",
  "params": {
    /* parameters */
  },
  "id": "unique-id" // for requests that expect responses
}
```

The protocol is based on MCP (Model Context Protocol) specification 2025-03-26, but uses WebSocket transport instead of stdio/HTTP.

## Key Message Types

### From IDE to Claude

These are notifications the IDE sends to keep Claude informed:

#### 1. Selection Updates

Sent whenever the user's selection changes:

```json
{
  "jsonrpc": "2.0",
  "method": "selection_changed",
  "params": {
    "text": "selected text content",
    "filePath": "/absolute/path/to/file.js",
    "fileUrl": "file:///absolute/path/to/file.js",
    "selection": {
      "start": { "line": 10, "character": 5 },
      "end": { "line": 15, "character": 20 },
      "isEmpty": false
    }
  }
}
```

#### 2. At-Mentions

When the user explicitly sends a selection as context:

```json
{
  "jsonrpc": "2.0",
  "method": "at_mentioned",
  "params": {
    "filePath": "/path/to/file",
    "lineStart": 10,
    "lineEnd": 20
  }
}
```

### From Claude to IDE

According to the MCP spec, Claude should be able to call tools, but **current implementations are mostly one-way** (IDE → Claude).

#### Tool Calls (Future)

```json
{
  "jsonrpc": "2.0",
  "id": "request-123",
  "method": "tools/call",
  "params": {
    "name": "openFile",
    "arguments": {
      "filePath": "/path/to/file.js"
    }
  }
}
```

#### Tool Responses

```json
{
  "jsonrpc": "2.0",
  "id": "request-123",
  "result": {
    "content": [{ "type": "text", "text": "File opened successfully" }]
  }
}
```

## Available MCP Tools

The VS Code extension registers 12 tools that Claude can call. Here's the complete specification:

### 1. openFile

**Description**: Open a file in the editor and optionally select a range of text

**Input**:

```json
{
  "filePath": "/path/to/file.js",
  "preview": false,
  "startText": "function hello",
  "endText": "}",
  "selectToEndOfLine": false,
  "makeFrontmost": true
}
```

- `filePath` (string, required): Path to the file to open
- `preview` (boolean, default: false): Whether to open in preview mode
- `startText` (string, optional): Text pattern to find selection start
- `endText` (string, optional): Text pattern to find selection end
- `selectToEndOfLine` (boolean, default: false): Extend selection to end of line
- `makeFrontmost` (boolean, default: true): Make the file the active editor tab

**Output**: When `makeFrontmost=true`, returns simple message:

```json
{
  "content": [
    {
      "type": "text",
      "text": "Opened file: /path/to/file.js"
    }
  ]
}
```

When `makeFrontmost=false`, returns detailed JSON:

```json
{
  "content": [
    {
      "type": "text",
      "text": "{\"success\": true, \"filePath\": \"/absolute/path/to/file.js\", \"languageId\": \"javascript\", \"lineCount\": 42}"
    }
  ]
}
```

### 2. openDiff

**Description**: Open a git diff for the file (blocking operation)

**Input**:

```json
{
  "old_file_path": "/path/to/original.js",
  "new_file_path": "/path/to/modified.js",
  "new_file_contents": "// Modified content...",
  "tab_name": "Proposed changes"
}
```

- `old_file_path` (string): Path to original file
- `new_file_path` (string): Path to new file
- `new_file_contents` (string): Contents of the new file
- `tab_name` (string): Tab name for the diff view

**Output**: Returns MCP-formatted response:

```json
{
  "content": [
    {
      "type": "text",
      "text": "FILE_SAVED"
    }
  ]
}
```

or

```json
{
  "content": [
    {
      "type": "text",
      "text": "DIFF_REJECTED"
    }
  ]
}
```

Based on whether the user saves or rejects the diff.

### 3. getCurrentSelection

**Description**: Get the current text selection in the active editor

**Input**: None

**Output**: Returns JSON-stringified selection data:

```json
{
  "content": [
    {
      "type": "text",
      "text": "{\"success\": true, \"text\": \"selected content\", \"filePath\": \"/path/to/file\", \"selection\": {\"start\": {\"line\": 0, \"character\": 0}, \"end\": {\"line\": 0, \"character\": 10}}}"
    }
  ]
}
```

Or when no active editor:

```json
{
  "content": [
    {
      "type": "text",
      "text": "{\"success\": false, \"message\": \"No active editor found\"}"
    }
  ]
}
```

### 4. getLatestSelection

**Description**: Get the most recent text selection (even if not in active editor)

**Input**: None

**Output**: JSON-stringified selection data or `{success: false, message: "No selection available"}`

### 5. getOpenEditors

**Description**: Get information about currently open editors

**Input**: None

**Output**: Returns JSON-stringified array of open tabs:

```json
{
  "content": [
    {
      "type": "text",
      "text": "{\"tabs\": [{\"uri\": \"file:///path/to/file\", \"isActive\": true, \"label\": \"filename.ext\", \"languageId\": \"javascript\", \"isDirty\": false}]}"
    }
  ]
}
```

### 6. getWorkspaceFolders

**Description**: Get all workspace folders currently open in the IDE

**Input**: None

**Output**: Returns JSON-stringified workspace information:

```json
{
  "content": [
    {
      "type": "text",
      "text": "{\"success\": true, \"folders\": [{\"name\": \"project-name\", \"uri\": \"file:///path/to/workspace\", \"path\": \"/path/to/workspace\"}], \"rootPath\": \"/path/to/workspace\"}"
    }
  ]
}
```

### 7. getDiagnostics

**Description**: Get language diagnostics from VS Code

**Input**:

```json
{
  "uri": "file:///path/to/file.js"
}
```

- `uri` (string, optional): File URI to get diagnostics for. If not provided, gets diagnostics for all files.

**Output**: Returns JSON-stringified array of diagnostics per file:

```json
{
  "content": [
    {
      "type": "text",
      "text": "[{\"uri\": \"file:///path/to/file\", \"diagnostics\": [{\"message\": \"Error message\", \"severity\": \"Error\", \"range\": {\"start\": {\"line\": 0, \"character\": 0}}, \"source\": \"typescript\"}]}]"
    }
  ]
}
```

### 8. checkDocumentDirty

**Description**: Check if a document has unsaved changes (is dirty)

**Input**:

```json
{
  "filePath": "/path/to/file.js"
}
```

- `filePath` (string, required): Path to the file to check

**Output**: Returns document dirty status:

```json
{
  "content": [
    {
      "type": "text",
      "text": "{\"success\": true, \"filePath\": \"/path/to/file.js\", \"isDirty\": true, \"isUntitled\": false}"
    }
  ]
}
```

Or when document not open:

```json
{
  "content": [
    {
      "type": "text",
      "text": "{\"success\": false, \"message\": \"Document not open: /path/to/file.js\"}"
    }
  ]
}
```

### 9. saveDocument

**Description**: Save a document with unsaved changes

**Input**:

```json
{
  "filePath": "/path/to/file.js"
}
```

- `filePath` (string, required): Path to the file to save

**Output**: Returns save operation result:

```json
{
  "content": [
    {
      "type": "text",
      "text": "{\"success\": true, \"filePath\": \"/path/to/file.js\", \"saved\": true, \"message\": \"Document saved successfully\"}"
    }
  ]
}
```

Or when document not open:

```json
{
  "content": [
    {
      "type": "text",
      "text": "{\"success\": false, \"message\": \"Document not open: /path/to/file.js\"}"
    }
  ]
}
```

### 10. close_tab

**Description**: Close a tab by name

**Input**:

```json
{
  "tab_name": "filename.js"
}
```

- `tab_name` (string, required): Name of the tab to close

**Output**: Returns `{content: [{type: "text", text: "TAB_CLOSED"}]}`

### 11. closeAllDiffTabs

**Description**: Close all diff tabs in the editor

**Input**: None

**Output**: Returns `{content: [{type: "text", text: "CLOSED_${count}_DIFF_TABS"}]}`

### 12. executeCode

**Description**: Execute Python code in the Jupyter kernel for the current notebook file

**Input**:

```json
{
  "code": "print('Hello, World!')"
}
```

- `code` (string, required): The code to be executed on the kernel

**Output**: Returns execution results with mixed content types:

```json
{
  "content": [
    {
      "type": "text",
      "text": "Hello, World!"
    },
    {
      "type": "image",
      "data": "base64_encoded_image_data",
      "mimeType": "image/png"
    }
  ]
}
```

**Notes**:

- All code executed will persist across calls unless the kernel is restarted
- Avoid declaring variables or modifying kernel state unless explicitly requested
- Only available when working with Jupyter notebooks
- Can return multiple content types including text output and images

### Implementation Notes

- Most tools follow camelCase naming except `close_tab` (uses snake_case)
- The `openDiff` tool is **blocking** and waits for user interaction
- Tools return MCP-formatted responses with content arrays
- All schemas use Zod validation in the VS Code extension
- Selection-related tools work with the current editor state

## Building Your Own Integration

Here's the minimum viable implementation:

### 1. Create a WebSocket Server

```lua
-- Listen on localhost only (important!)
local server = create_websocket_server("127.0.0.1", random_port)
```

### 2. Write the Lock File

```lua
-- ~/.claude/ide/[port].lock
local auth_token = generate_uuid() -- Generate random UUID
local lock_data = {
  pid = vim.fn.getpid(),
  workspaceFolders = { vim.fn.getcwd() },
  ideName = "YourEditor",
  transport = "ws",
  authToken = auth_token
}
write_json(lock_path, lock_data)
```

### 3. Set Environment Variables

```bash
export CLAUDE_CODE_SSE_PORT=12345
export ENABLE_IDE_INTEGRATION=true
claude  # Claude will now connect!
```

### 4. Handle Messages

```lua
-- Validate authentication on WebSocket handshake
function validate_auth(headers)
  local auth_header = headers["x-claude-code-ide-authorization"]
  return auth_header == auth_token
end

-- Send selection updates
send_message({
  jsonrpc = "2.0",
  method = "selection_changed",
  params = { ... }
})

-- Implement tools (if needed)
register_tool("openFile", function(params)
  -- Open file logic
  return { content = {{ type = "text", text = "Done" }} }
end)
```

## Security Considerations

**Always bind to localhost (`127.0.0.1`) only!** This ensures the WebSocket server is not exposed to the network.

## What's Next?

With this protocol knowledge, you can:

- Build integrations for any editor
- Create agents that connect to existing IDE extensions
- Extend the protocol with custom tools
- Build bridges between different AI assistants and IDEs

The WebSocket MCP variant is currently Claude-specific, but the concepts could be adapted for other AI coding assistants.

## Resources

- [MCP Specification](https://spec.modelcontextprotocol.io)
- [Claude Code Neovim Implementation](https://github.com/coder/claudecode.nvim)
- [Official VS Code Extension](https://github.com/anthropic-labs/vscode-mcp) (minified source)
