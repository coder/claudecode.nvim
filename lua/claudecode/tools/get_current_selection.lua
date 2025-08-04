--- Tool implementation for getting the current selection.

local schema = {
  description = "Get the current text selection in the editor",
  inputSchema = {
    type = "object",
    additionalProperties = false,
    ["$schema"] = "http://json-schema.org/draft-07/schema#",
  },
}

---Helper function to safely encode data as JSON with error handling.
---@param data table The data to encode as JSON
---@param error_context string A description of what failed for error messages
---@return string The JSON-encoded string
local function safe_json_encode(data, error_context)
  local ok, encoded = pcall(vim.json.encode, data, { indent = 2 })
  if not ok then
    error({
      code = -32000,
      message = "Internal server error",
      data = "Failed to encode " .. error_context .. ": " .. tostring(encoded),
    })
  end
  return encoded
end

---Handles the getCurrentSelection tool invocation.
---Gets the current text selection in the editor.
---@return table response MCP-compliant response with selection data.
local function handler(params)
  local selection_module_ok, selection_module = pcall(require, "claudecode.selection")
  if not selection_module_ok then
    error({ code = -32000, message = "Internal server error", data = "Failed to load selection module" })
  end

  local selection = selection_module.get_latest_selection()

  if not selection then
    -- Check if there's an active editor/buffer
    local current_buf = vim.api.nvim_get_current_buf()
    local buf_name = vim.api.nvim_buf_get_name(current_buf)

    if not buf_name or buf_name == "" then
      -- No active editor case - match VS Code format
      local no_editor_response = {
        success = false,
        message = "No active editor found",
      }

      return {
        content = {
          {
            type = "text",
            text = safe_json_encode(no_editor_response, "no editor response"),
          },
        },
      }
    end

    -- Valid buffer but no selection - return cursor position with success field
    local empty_selection = {
      success = true,
      text = "",
      filePath = buf_name,
      fileUrl = "file://" .. buf_name,
      selection = {
        start = { line = 0, character = 0 },
        ["end"] = { line = 0, character = 0 },
        isEmpty = true,
      },
    }

    -- Return MCP-compliant format with JSON-stringified empty selection
    return {
      content = {
        {
          type = "text",
          text = safe_json_encode(empty_selection, "empty selection"),
        },
      },
    }
  end

  -- Add success field to existing selection data
  local selection_with_success = vim.tbl_extend("force", selection, { success = true })

  -- Return MCP-compliant format with JSON-stringified selection data
  return {
    content = {
      {
        type = "text",
        text = safe_json_encode(selection_with_success, "selection"),
      },
    },
  }
end

return {
  name = "getCurrentSelection",
  schema = schema,
  handler = handler,
}
