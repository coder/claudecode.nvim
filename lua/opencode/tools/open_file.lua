--- Tool implementation for opening a file.

local schema = {
  description = "Open a file in the editor and optionally select a range of text",
  inputSchema = {
    type = "object",
    properties = {
      filePath = {
        type = "string",
        description = "Path to the file to open",
      },
      preview = {
        type = "boolean",
        description = "Whether to open the file in preview mode",
        default = false,
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
        description = "Text pattern to find the start of the selection range. Selects from the beginning of this match.",
      },
      endText = {
        type = "string",
        description = "Text pattern to find the end of the selection range. Selects up to the end of this match. If not provided, only the startText match will be selected.",
      },
      selectToEndOfLine = {
        type = "boolean",
        description = "If true, selection will extend to the end of the line containing the endText match.",
        default = false,
      },
      makeFrontmost = {
        type = "boolean",
        description = "Whether to make the file the active editor tab. If false, the file will be opened in the background without changing focus.",
        default = true,
      },
    },
    required = { "filePath" },
    additionalProperties = false,
    ["$schema"] = "http://json-schema.org/draft-07/schema#",
  },
}

---Finds a suitable main editor window to open files in.
---Excludes terminals, sidebars, and floating windows.
---@return integer? win_id Window ID of the main editor window, or nil if not found
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
        or filetype == "NvimTree"
        or filetype == "oil"
        or filetype == "minifiles"
        or filetype == "netrw"
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

--- Handles the openFile tool invocation.
--- Opens a file in the editor with optional selection.
---@param params table The input parameters for the tool
---@return table MCP-compliant response with content array
local function handler(params)
  if not params.filePath then
    error({ code = -32602, message = "Invalid params", data = "Missing filePath parameter" })
  end

  local file_path = vim.fn.expand(params.filePath)

  if vim.fn.filereadable(file_path) == 0 then
    -- Using a generic error code for tool-specific operational errors
    error({ code = -32000, message = "File operation error", data = "File not found: " .. file_path })
  end

  -- Set default values for optional parameters
  local preview = params.preview or false
  local make_frontmost = params.makeFrontmost ~= false -- default true
  local select_to_end_of_line = params.selectToEndOfLine or false

  local message = "Opened file: " .. file_path

  -- Find the main editor window
  local target_win = find_main_editor_window()

  if target_win then
    -- Open file in the target window
    vim.api.nvim_win_call(target_win, function()
      if preview then
        vim.cmd("pedit " .. vim.fn.fnameescape(file_path))
      else
        vim.cmd("edit " .. vim.fn.fnameescape(file_path))
      end
    end)
    -- Focus the window after opening if makeFrontmost is true
    if make_frontmost then
      vim.api.nvim_set_current_win(target_win)
    end
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

    if preview then
      vim.cmd("pedit " .. vim.fn.fnameescape(file_path))
    else
      vim.cmd("edit " .. vim.fn.fnameescape(file_path))
    end
  end

  -- Handle text selection by line numbers
  if params.startLine or params.endLine then
    local start_line = params.startLine or 1
    local end_line = params.endLine or start_line

    -- Convert to 0-based indexing for vim API
    local start_pos = { start_line - 1, 0 }
    local end_pos = { end_line - 1, -1 } -- -1 means end of line

    vim.api.nvim_buf_set_mark(0, "<", start_pos[1], start_pos[2], {})
    vim.api.nvim_buf_set_mark(0, ">", end_pos[1], end_pos[2], {})
    vim.cmd("normal! gv")

    message = "Opened file and selected lines " .. start_line .. " to " .. end_line
  end

  -- Handle text pattern selection
  if params.startText then
    local buf = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local start_line_idx, start_col_idx
    local end_line_idx, end_col_idx

    -- Find start text
    for line_idx, line in ipairs(lines) do
      local col_idx = string.find(line, params.startText, 1, true) -- plain text search
      if col_idx then
        start_line_idx = line_idx - 1 -- Convert to 0-based
        start_col_idx = col_idx - 1 -- Convert to 0-based
        break
      end
    end

    if start_line_idx then
      -- Find end text if provided
      if params.endText then
        for line_idx = start_line_idx + 1, #lines do
          local line = lines[line_idx] -- Access current line directly
          if line then
            local col_idx = string.find(line, params.endText, 1, true)
            if col_idx then
              end_line_idx = line_idx
              end_col_idx = col_idx + string.len(params.endText) - 1
              if select_to_end_of_line then
                end_col_idx = string.len(line)
              end
              break
            end
          end
        end

        if end_line_idx then
          message = 'Opened file and selected text from "' .. params.startText .. '" to "' .. params.endText .. '"'
        else
          -- End text not found, select only start text
          end_line_idx = start_line_idx
          end_col_idx = start_col_idx + string.len(params.startText) - 1
          message = 'Opened file and positioned at "'
            .. params.startText
            .. '" (end text "'
            .. params.endText
            .. '" not found)'
        end
      else
        -- Only start text provided
        end_line_idx = start_line_idx
        end_col_idx = start_col_idx + string.len(params.startText) - 1
        message = 'Opened file and selected text "' .. params.startText .. '"'
      end

      -- Apply the selection
      vim.api.nvim_win_set_cursor(0, { start_line_idx + 1, start_col_idx })
      vim.api.nvim_buf_set_mark(0, "<", start_line_idx, start_col_idx, {})
      vim.api.nvim_buf_set_mark(0, ">", end_line_idx, end_col_idx, {})
      vim.cmd("normal! gv")
      vim.cmd("normal! zz") -- Center the selection in the window
    else
      message = 'Opened file, but text "' .. params.startText .. '" not found'
    end
  end

  -- Return format based on makeFrontmost parameter
  if make_frontmost then
    -- Simple message format when makeFrontmost=true
    return {
      content = {
        {
          type = "text",
          text = message,
        },
      },
    }
  else
    -- Detailed JSON format when makeFrontmost=false
    local buf = vim.api.nvim_get_current_buf()
    local detailed_info = {
      success = true,
      filePath = file_path,
      languageId = vim.api.nvim_buf_get_option(buf, "filetype"),
      lineCount = vim.api.nvim_buf_line_count(buf),
    }

    return {
      content = {
        {
          type = "text",
          text = vim.json.encode(detailed_info, { indent = 2 }),
        },
      },
    }
  end
end

return {
  name = "openFile",
  schema = schema,
  handler = handler,
}
