--- Tool implementation for getting the latest text selection.

local schema = {
  description = "Get the most recent text selection (even if not in the active editor)",
  inputSchema = {
    type = "object",
    additionalProperties = false,
    ["$schema"] = "http://json-schema.org/draft-07/schema#",
  },
}

---Handles the getLatestSelection tool invocation.
---Gets the most recent text selection, even if not in the current active editor.
---This is different from getCurrentSelection which only gets selection from active editor.
---@return table content MCP-compliant response with content array
local function handler(params)
  local selection_module_ok, selection_module = pcall(require, "claudecode.selection")
  if not selection_module_ok then
    error({ code = -32000, message = "Internal server error", data = "Failed to load selection module" })
  end

  local selection = selection_module.get_latest_selection()

  if not selection then
    -- Return MCP-compliant format with JSON-stringified result
    return {
      content = {
        {
          type = "text",
          text = vim.json.encode({
            success = false,
            message = "No selection available",
          }, { indent = 2 }),
        },
      },
    }
  end

  -- Return MCP-compliant format with JSON-stringified selection data
  return {
    content = {
      {
        type = "text",
        text = vim.json.encode(selection, { indent = 2 }),
      },
    },
  }
end

return {
  name = "getLatestSelection",
  schema = schema,
  handler = handler,
}
