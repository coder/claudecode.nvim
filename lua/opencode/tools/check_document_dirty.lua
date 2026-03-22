---Tool implementation for checking if a document is dirty.

local schema = {
  description = "Check if a document has unsaved changes (is dirty)",
  inputSchema = {
    type = "object",
    properties = {
      filePath = {
        type = "string",
        description = "Path to the file to check",
      },
    },
    required = { "filePath" },
    additionalProperties = false,
    ["$schema"] = "http://json-schema.org/draft-07/schema#",
  },
}

---Handles the checkDocumentDirty tool invocation.
---Checks if the specified file (buffer) has unsaved changes.
---@param params table The input parameters for the tool
---@return table MCP-compliant response with dirty status
local function handler(params)
  if not params.filePath then
    error({ code = -32602, message = "Invalid params", data = "Missing filePath parameter" })
  end

  local bufnr = vim.fn.bufnr(params.filePath)

  if bufnr == -1 then
    -- Return success: false when document not open, matching VS Code behavior
    return {
      content = {
        {
          type = "text",
          text = vim.json.encode({
            success = false,
            message = "Document not open: " .. params.filePath,
          }, { indent = 2 }),
        },
      },
    }
  end

  local is_dirty = vim.api.nvim_buf_get_option(bufnr, "modified")
  local is_untitled = vim.api.nvim_buf_get_name(bufnr) == ""

  -- Return MCP-compliant format with JSON-stringified result
  return {
    content = {
      {
        type = "text",
        text = vim.json.encode({
          success = true,
          filePath = params.filePath,
          isDirty = is_dirty,
          isUntitled = is_untitled,
        }, { indent = 2 }),
      },
    },
  }
end

return {
  name = "checkDocumentDirty",
  schema = schema,
  handler = handler,
}
