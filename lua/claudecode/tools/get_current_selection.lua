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
  local ok, encoded = pcall(vim.json.encode, data)
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
    -- Find the editor window. The Claude terminal is not an editor (tracked mode skips it
    -- too), and Claude usually asks while the user types there, so use the window the
    -- user came from instead.
    local editor_buf = vim.api.nvim_get_current_buf()
    local editor_win = nil -- nil: the current window
    if selection_module.is_claude_terminal_buffer(editor_buf) then
      local previous = vim.fn.winnr("#")
      local previous_win = previous > 0 and vim.fn.win_getid(previous) or 0
      editor_buf = nil
      if previous_win ~= 0 then
        local previous_buf = vim.api.nvim_win_get_buf(previous_win)
        if not selection_module.is_claude_terminal_buffer(previous_buf) then
          editor_win, editor_buf = previous_win, previous_buf
        end
      end
    end
    local buf_name = editor_buf and vim.api.nvim_buf_get_name(editor_buf)

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

    -- No tracked selection: `track_selection` is off, or nothing was tracked yet.
    -- Read the editor now, so the answer is the user's real selection or cursor.
    if editor_win then
      -- Visual mode belongs to the current window, so the other window has only a cursor.
      selection = selection_module.get_cursor_position(editor_win)
    else
      selection = selection_module.get_visual_selection() or selection_module.get_cursor_position()
    end
    assert(type(selection) == "table" and selection.selection, "expected a selection table from claudecode.selection")
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
