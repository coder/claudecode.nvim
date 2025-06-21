--- Tool implementation for getting the current selection.

local schema = {
  description = "Get the current text selection in the editor",
  inputSchema = {
    type = "object",
    additionalProperties = false,
    ["$schema"] = "http://json-schema.org/draft-07/schema#",
  },
}

--- Handles the getCurrentSelection tool invocation.
-- Gets the current text selection in the editor.
-- @param params table The input parameters for the tool (currently unused).
-- @return table The selection data.
-- @error table A table with code, message, and data for JSON-RPC error if failed.
local function handler(_params) -- Prefix unused params with underscore
  local selection_module_ok, selection_module = pcall(require, "claudecode.selection")
  if not selection_module_ok then
    error({ code = -32000, message = "Internal server error", data = "Failed to load selection module" })
  end

  local selection = selection_module.get_latest_selection()

  if not selection then
    -- Consider if "no selection" is an error or a valid state returning empty/specific data.
    -- For now, returning an empty object or specific structure might be better than an error.
    -- Let's assume it's valid to have no selection and return a structure indicating that.
    local empty_selection = {
      text = "",
      filePath = vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()),
      fileUrl = "file://" .. vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()),
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
          text = vim.json.encode(empty_selection, { indent = 2 }),
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
  name = "getCurrentSelection",
  schema = schema,
  handler = handler,
}
