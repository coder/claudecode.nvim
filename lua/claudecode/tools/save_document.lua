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
          }),
        },
      },
    }
  end

  -- The inner pcall keeps the error a plain message: an error that escapes the
  -- nvim_buf_call callback comes back with a Lua stack trace and local paths.
  local success, err
  local call_ok, call_err = pcall(vim.api.nvim_buf_call, bufnr, function()
    success, err = pcall(vim.cmd, "write")
  end)
  if not call_ok then
    success, err = false, call_err
  end

  if not success then
    local message = tostring(err)
    -- Keep the Vim error ("E45: ...") when there is one, else the first line.
    message = message:match("E%d+:[^\n]*") or message:match("^[^\n]*")
    return {
      content = {
        {
          type = "text",
          text = vim.json.encode({
            success = false,
            message = "Failed to save file: " .. message,
            filePath = params.filePath,
          }),
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
        }),
      },
    },
  }
end

return {
  name = "saveDocument",
  schema = schema,
  handler = handler,
}
