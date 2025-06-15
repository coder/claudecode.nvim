--- Tool implementation for opening a file.

local schema = {
  description = "Opens a file in the editor with optional selection by line numbers or text patterns",
  inputSchema = {
    type = "object",
    properties = {
      filePath = {
        type = "string",
        description = "Path to the file to open",
      },
      startLine = {
        type = "integer",
        description = "Optional: Line number to start selection",
      },
      endLine = {
        type = "integer",
        description = "Optional: Line number to end selection",
      },
      startText = {
        type = "string",
        description = "Optional: Text pattern to start selection",
      },
      endText = {
        type = "string",
        description = "Optional: Text pattern to end selection",
      },
    },
    required = { "filePath" },
    additionalProperties = false,
    ["$schema"] = "http://json-schema.org/draft-07/schema#",
  },
}

--- Handles the openFile tool invocation.
-- Opens a file in the editor with optional selection.
-- @param params table The input parameters for the tool.
-- @field params.filePath string Path to the file to open.
-- @field params.startLine integer (Optional) Line number to start selection.
-- @field params.endLine integer (Optional) Line number to end selection.
-- @field params.startText string (Optional) Text pattern to start selection.
-- @field params.endText string (Optional) Text pattern to end selection.
-- @return table A table with a message indicating success.
-- @error table A table with code, message, and data for JSON-RPC error if failed.
--- Finds a suitable main editor window to open files in.
-- Excludes terminals, sidebars, and floating windows.
-- @return number|nil Window ID of the main editor window, or nil if not found
local function find_main_editor_window()
  local windows = vim.api.nvim_list_wins()

  for _, win in ipairs(windows) do
    local buf = vim.api.nvim_win_get_buf(win)
    local buftype = vim.api.nvim_buf_get_option(buf, "buftype")
    local filetype = vim.api.nvim_buf_get_option(buf, "filetype")
    local win_config = vim.api.nvim_win_get_config(win)

    -- Check if this is a suitable window
    local is_suitable = true

    -- Skip floating windows
    if win_config.relative and win_config.relative ~= "" then
      is_suitable = false
    end

    -- Skip special buffer types
    if is_suitable and (buftype == "terminal" or buftype == "nofile" or buftype == "prompt") then
      is_suitable = false
    end

    -- Skip known sidebar filetypes
    if
      is_suitable
      and (
        filetype == "neo-tree"
        or filetype == "neo-tree-popup"
        or filetype == "ClaudeCode"
        or filetype == "NvimTree"
        or filetype == "oil"
        or filetype == "aerial"
        or filetype == "tagbar"
      )
    then
      is_suitable = false
    end

    -- This looks like a main editor window
    if is_suitable then
      return win
    end
  end

  return nil
end

local function handler(params)
  if not params.filePath then
    error({ code = -32602, message = "Invalid params", data = "Missing filePath parameter" })
  end

  local file_path = vim.fn.expand(params.filePath)

  if vim.fn.filereadable(file_path) == 0 then
    -- Using a generic error code for tool-specific operational errors
    error({ code = -32000, message = "File operation error", data = "File not found: " .. file_path })
  end

  -- Find the main editor window
  local target_win = find_main_editor_window()

  if target_win then
    -- Open file in the target window
    vim.api.nvim_win_call(target_win, function()
      vim.cmd("edit " .. vim.fn.fnameescape(file_path))
    end)
    -- Focus the window after opening
    vim.api.nvim_set_current_win(target_win)
  else
    -- Fallback: Create a new window if no suitable window found
    -- Try to move to a better position
    vim.cmd("wincmd t") -- Go to top-left
    vim.cmd("wincmd l") -- Move right (to middle if layout is left|middle|right)

    -- If we're still in a special window, create a new split
    local buf = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
    local buftype = vim.api.nvim_buf_get_option(buf, "buftype")

    if buftype == "terminal" or buftype == "nofile" then
      vim.cmd("vsplit")
    end

    vim.cmd("edit " .. vim.fn.fnameescape(file_path))
  end

  -- TODO: Implement selection by line numbers (params.startLine, params.endLine)
  -- TODO: Implement selection by text patterns if params.startText and params.endText are provided.

  return { message = "File opened: " .. file_path }
end

return {
  name = "openFile",
  schema = schema,
  handler = handler,
}
