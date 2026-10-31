# claudecode.tools

## Overview

`claudecode.tools` is the MCP tool registry and the set of tools that Claude Code can call in Neovim. The server ([`../server/README.md`](../server/README.md)) sends each `tools/list` request to `get_tool_list` and each `tools/call` request to `handle_invoke`. Each tool file returns a table `{ name, schema, handler, requires_coroutine? }`. `init.lua` registers these tables.

## Interface

### Registry (`init.lua`)

- `M.ERROR_CODES`: `PARSE_ERROR -32700`, `INVALID_REQUEST -32600`, `METHOD_NOT_FOUND -32601`, `INVALID_PARAMS -32602`, and `INTERNAL_ERROR -32000` [tools/init.lua:M.ERROR_CODES]
- `M.tools`: a map from tool name to `{ handler, schema, requires_coroutine }` [tools/init.lua:M.tools]
- `M.setup(server)`: stores the server and calls `register_all` [tools/init.lua:M.setup]
- `M.register(tool_module)`: requires `name` and `handler`. Otherwise it calls `vim.notify` at ERROR level and returns. It sends no MCP notification [tools/init.lua:M.register]
- `M.register_all()`: registers 10 exposed tools and the internal `close_tab` [tools/init.lua:M.register_all]
- `M.get_tool_list()`: returns `{ name, description, inputSchema }` only for tools that have a `schema` [tools/init.lua:M.get_tool_list]
- `M.handle_invoke(client, params)`: looks up `params.name` and runs the tool with `params.arguments` [tools/init.lua:M.handle_invoke]
- `M.build_response(ok, value, err)`: maps a handler outcome, as `pcall` or `coroutine.resume` returns it, to `{ result }` or `{ error }`. `handle_invoke` uses it, and so does `diff.open_diff_blocking` when it resumes a deferred tool [tools/init.lua:M.build_response]

### Registered tools

| MCP name              | File                        | Required params                                                   | Exposed             |
| --------------------- | --------------------------- | ----------------------------------------------------------------- | ------------------- |
| `openFile`            | `open_file.lua`             | `filePath`                                                        | yes                 |
| `getCurrentSelection` | `get_current_selection.lua` | none                                                              | yes                 |
| `getOpenEditors`      | `get_open_editors.lua`      | none                                                              | yes                 |
| `openDiff`            | `open_diff.lua`             | `old_file_path`, `new_file_path`, `new_file_contents`, `tab_name` | yes                 |
| `getLatestSelection`  | `get_latest_selection.lua`  | none                                                              | yes                 |
| `closeAllDiffTabs`    | `close_all_diff_tabs.lua`   | none                                                              | yes                 |
| `getDiagnostics`      | `get_diagnostics.lua`       | none (optional `uri`)                                             | yes                 |
| `getWorkspaceFolders` | `get_workspace_folders.lua` | none                                                              | yes                 |
| `checkDocumentDirty`  | `check_document_dirty.lua`  | `filePath`                                                        | yes                 |
| `saveDocument`        | `save_document.lua`         | `filePath`                                                        | yes                 |
| `close_tab`           | `close_tab.lua`             | `tab_name`                                                        | no (`schema = nil`) |

Sources: [tools/init.lua:M.register_all], [tools/close_tab.lua:schema], [tools/open_diff.lua:requires_coroutine].

## Invariants

- An unknown tool returns `{ error = { code = -32601, message = "Tool not found: <name>" } }` [tools/init.lua:M.handle_invoke]
- An error that is a `{ code, message }` table keeps its code, whether the handler raises it or returns `false, err`. This holds for tools with `requires_coroutine` too, also when the reply is sent after a deferred resume. Any other error maps to `-32000` [tools/init.lua:M.build_response] [diff.lua:M.open_diff_blocking]
- A successful handler returns `{ result = <value> }` [tools/init.lua:M.handle_invoke]. Each tool handler builds the MCP shape `{ content = { { type = "text", text = ... } } }` itself [tools/open_file.lua:handler]
- Tools with `requires_coroutine` run in `coroutine.create`. If the coroutine yields, `handle_invoke` returns `{ _deferred = true, coroutine, client, params }` and sends no response yet. Only `openDiff` sets `requires_coroutine = true` [tools/init.lua:M.handle_invoke]
- `openDiff` raises `-32602` when a required parameter is missing. Outside a non-main coroutine it raises `-32000` with `message = "Internal server error"` and `data = "openDiff must run in coroutine context"` [tools/open_diff.lua:handler]
- `openDiff` calls `diff.open_diff_blocking(old, new, contents, tab_name, client.id)`. Structured errors pass through. Other errors become `-32000` "Error opening blocking diff" [tools/open_diff.lua:handler]
- `openFile`, `checkDocumentDirty`, and `saveDocument` raise `-32602` when `filePath` is missing [tools/open_file.lua:handler]
- `openFile` raises `-32602` before it opens the file when `startLine` or `endLine` is not an integer, `startLine` is below 1 or past the last line of the file, or `endLine` is below `startLine`. An `endLine` past the last line selects through the last line, and the answer names the lines it selected [tools/open_file.lua:handler]
- `openFile` raises `-32000` with `message = "File operation error"` and `data = "File not found: <path>"` when the file is not readable. Its defaults are `preview=false`, `makeFrontmost=true`, and `selectToEndOfLine=false` [tools/open_file.lua:handler]
- `checkDocumentDirty` and `saveDocument` return a `success=false` JSON result (not an error) when the file has no open buffer [tools/save_document.lua:handler]
- `getDiagnostics` raises `-32000` when `vim.lsp`, `vim.diagnostic`, or `vim.diagnostic.get` is missing. It raises `-32001` "File not open" when no buffer exists for `uri` (`vim.fn.bufnr(path) == -1`). An unloaded buffer does not raise [tools/get_diagnostics.lua:handler]
- `getLatestSelection` returns a `success=false` JSON result when no selection exists [tools/get_latest_selection.lua:handler]
- With no selection, `getCurrentSelection` returns `success=false` only when the active buffer has no name. When a named buffer is active, it returns `success=true` with an empty selection [tools/get_current_selection.lua:handler]
- `close_tab` returns its error tables as values, not raised errors. `handle_invoke` therefore wraps them in `result`. A missing buffer counts as success [tools/close_tab.lua:handler]

## Side Effects

- `openFile` runs `edit` (or `pedit` for preview) in the main editor window. It can split or move windows when no suitable window exists, and it sets visual marks and the cursor for line or text ranges [tools/open_file.lua:handler]
- `openDiff` opens a blocking diff through `claudecode.diff`. The response stays deferred until the user accepts or rejects the diff [tools/open_diff.lua:handler]. A diff that resolves before `openDiff` yields, for example from a `ClaudeCodeDiffOpened` handler, is answered at once [diff.lua:M.open_diff_blocking]
- `saveDocument` runs `write` in the matching buffer with `nvim_buf_call` [tools/save_document.lua:handler]
- `closeAllDiffTabs` calls `diff.close_all_diffs` and returns `CLOSED_<n>_DIFF_TABS` [tools/close_all_diff_tabs.lua:handler]
- `close_tab` calls `diff.close_diff_by_tab_name` for diff tabs. Otherwise it calls `nvim_buf_delete` with `force=false` [tools/close_tab.lua:handler]
- `getCurrentSelection`, `getLatestSelection`, `getOpenEditors`, `getDiagnostics`, `getWorkspaceFolders`, and `checkDocumentDirty` only read editor state [tools/get_open_editors.lua:handler]
- `handle_invoke` writes debug log entries through `claudecode.logger` [tools/init.lua:M.handle_invoke]

## Verification

- Run: `mise run test`
- Targeted: `busted -v tests/unit/tools_spec.lua`, `busted -v tests/unit/tools/open_file_spec.lua`, `busted -v tests/unit/tools/open_diff_mcp_spec.lua`, `busted -v tests/unit/tools/get_diagnostics_spec.lua`, `busted -v tests/unit/tools/save_document_spec.lua`, `busted -v tests/integration/mcp_tools_spec.lua`
