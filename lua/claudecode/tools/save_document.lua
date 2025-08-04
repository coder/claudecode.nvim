--- Tool implementation for saving a document.

local schema = {
  description = "Save a document with unsaved changes",
  inputSchema = {
    type = "object",
    properties = {
      filePath = {
        type = "string",
        description = "Path to the file to save",
      },
    },
    required = { "filePath" },
    additionalProperties = false,
    ["$schema"] = "http://json-schema.org/draft-07/schema#",
  },
}

---Handles the saveDocument tool invocation.
---Saves the specified file (buffer).
---@param params table The input parameters for the tool
---@return table MCP-compliant response with save status
local function handler(params)
  if not params.filePath then
    error({
      code = -32602,
      message = "Invalid params",
      data = "Missing filePath parameter",
    })
  end

  local bufnr = vim.fn.bufnr(params.filePath)

  if bufnr == -1 then
    -- Return failure when document not open, matching VS Code behavior
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

  local success, err = pcall(vim.api.nvim_buf_call, bufnr, function()
    vim.cmd("write")
  end)

  if not success then
    return {
      content = {
        {
          type = "text",
          text = vim.json.encode({
            success = false,
            message = "Failed to save file: " .. tostring(err),
            filePath = params.filePath,
          }, { indent = 2 }),
        },
      },
    }
  end

  -- Return MCP-compliant format with JSON-stringified success result
  return {
    content = {
      {
        type = "text",
        text = vim.json.encode({
          success = true,
          filePath = params.filePath,
          saved = true,
          message = "Document saved successfully",
        }, { indent = 2 }),
      },
    },
  }
end

return {
  name = "saveDocument",
  schema = schema,
  handler = handler,
}
