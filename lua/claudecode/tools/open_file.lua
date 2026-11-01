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
        minimum = 1,
        description = "Optional: Line number to start selection",
      },
      endLine = {
        type = "integer",
        minimum = 1,
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

    -- Skip windows that are part of a diff (vimdiff, diffview.nvim, fugitive, or
    -- claudecode's own diff): :edit-ing into one clears its window-local 'diff'
    -- and destroys the user's diff layout (issue #277).
    if is_suitable and vim.api.nvim_win_get_option(win, "diff") then
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

---Ends Visual or Select mode, if one is on. Select mode replaces the selected text with typed keys, so this runs
---before openFile sends `:normal!` keys.
local function leave_visual_or_select_mode()
  if vim.api.nvim_get_mode().mode:match("^[vVsS\22\19]") then
    vim.cmd("normal! \27")
  end
end

---Selects from `start_col` on `start_row` through `last_col` on `end_row` in charwise visual mode, both ends included.
---With 'selection' set to "exclusive", gv leaves out the character under `'>`, so `'>` goes one byte past
---`last_col`. The marks use setpos() because nvim_buf_set_mark on Neovim 0.8 also sets the mark's coladd,
---and gv then selects one more character. gv reselects in the buffer's last Visual mode, so a charwise Visual
---pass (v<Esc>) comes first, or a buffer last selected with V or CTRL-V gets a linewise or blockwise selection.
---It runs under :noautocmd, so its own ModeChanged pair does not reach user handlers or the selection tracker.
---gv must be the last key openFile sends: with 'selectmode' set to "cmd" it starts Select mode, where any later
---key would replace the selection.
---@param start_row integer 1-based row of the first character
---@param start_col integer 0-based byte column of the first character
---@param end_row integer 1-based row of the last character
---@param last_col integer 0-based byte column of the last byte to select
local function select_range(start_row, start_col, end_row, last_col)
  local end_col = last_col
  if vim.o.selection == "exclusive" then
    end_col = last_col + 1
  end
  leave_visual_or_select_mode()
  vim.cmd("noautocmd normal! v\27")
  vim.fn.setpos("'<", { 0, start_row, start_col + 1, 0 })
  vim.fn.setpos("'>", { 0, end_row, end_col + 1, 0 })
  vim.cmd("normal! gv")
end

---Returns how many lines `file_path` will show once opened, counting at most `max` lines of the file on disk.
---A loaded buffer for the file can hold unsaved lines, and `:edit` shows that buffer, so its count wins.
---bufexists() and bufadd() find that buffer the way `:edit` does, by name or by the inode Neovim cached for it,
---so a symlink, a symlinked directory, or a hard link finds it. bufexists() comes first because bufadd()
---creates a buffer when none exists.
---@param file_path string Path of the file to open
---@param max integer Lines to read from disk at most
---@return integer count
local function line_count_before_open(file_path, max)
  if vim.fn.bufexists(file_path) == 1 then
    local buf = vim.fn.bufadd(file_path)
    if vim.api.nvim_buf_is_loaded(buf) then
      return vim.api.nvim_buf_line_count(buf)
    end
  end
  -- readfile() returns no lines for an empty file, which opens as one empty line.
  return math.max(#vim.fn.readfile(file_path, "", max), 1)
end

--- Handles the openFile tool invocation.
--- Opens a file in the editor with optional selection.
---@param params table The input parameters for the tool
---@return table MCP-compliant response with content array
local function handler(params)
  if not params.filePath then
    error({ code = -32602, message = "Invalid params", data = "Missing filePath parameter" })
  end

  -- An operator the user typed (d, c, y, ...) still waits for its motion. It would act on any selection made now,
  -- and the next motion would act from where the user typed it, so openFile selects nothing and cancels it.
  local operator_pending = vim.api.nvim_get_mode().mode:sub(1, 2) == "no"
  local nothing_selected = " (a pending operator was cancelled and nothing was selected)"

  local start_line, end_line
  if params.startLine ~= nil or params.endLine ~= nil then
    start_line = params.startLine == nil and 1 or params.startLine
    end_line = params.endLine == nil and start_line or params.endLine
    local valid = type(start_line) == "number"
      and type(end_line) == "number"
      and start_line % 1 == 0
      and end_line % 1 == 0
      and start_line >= 1
      and end_line >= start_line
    if not valid then
      error({
        code = -32602,
        message = "Invalid params",
        data = "startLine and endLine must be integers with 1 <= startLine <= endLine",
      })
    end
  end

  -- Expand a leading `~` only. `vim.fn.expand` would treat `$name` as an
  -- environment variable and strip undefined ones, breaking literal `$` paths
  -- (e.g. TanStack Router `$param` files like `src/routes/$post.tsx`).
  local file_path = require("claudecode.utils").expand_tilde(params.filePath)

  if vim.fn.filereadable(file_path) == 0 then
    -- Using a generic error code for tool-specific operational errors
    error({ code = -32000, message = "File operation error", data = "File not found: " .. file_path })
  end

  if start_line then
    local file_line_count = line_count_before_open(file_path, start_line)
    if start_line > file_line_count then
      error({
        code = -32602,
        message = "Invalid params",
        data = "startLine " .. start_line .. " is past the end of the file (" .. file_line_count .. " lines)",
      })
    end
  end

  -- Set default values for optional parameters
  local preview = params.preview or false
  local make_frontmost = params.makeFrontmost ~= false -- default true
  local select_to_end_of_line = params.selectToEndOfLine or false
  local start_text = type(params.startText) == "string" and params.startText ~= "" and params.startText or nil
  local end_text = type(params.endText) == "string" and params.endText ~= "" and params.endText or nil

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

    -- If we're still in a special window (or a diff window — issue #277), create
    -- a new split so we don't :edit over a terminal, sidebar, or someone's diff.
    local cur_win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_win_get_buf(cur_win)
    local buftype = vim.api.nvim_buf_get_option(buf, "buftype")

    if buftype == "terminal" or buftype == "nofile" or vim.api.nvim_win_get_option(cur_win, "diff") then
      vim.cmd("vsplit")
      -- The new split inherits window-local options (including 'diff') from the
      -- window we split off. Clear diff on it so the file we open never joins the
      -- user's diff set -- e.g. opening a file that is itself one of the diffed
      -- buffers would otherwise leave it diffing as an extra pane (issue #277).
      -- :diffoff acts on the current (new) window only, never :diffoff!.
      vim.cmd("diffoff")
    end

    if preview then
      vim.cmd("pedit " .. vim.fn.fnameescape(file_path))
    else
      vim.cmd("edit " .. vim.fn.fnameescape(file_path))
    end
    target_win = vim.api.nvim_get_current_win()
  end

  local function run_in_target_window(callback)
    if target_win then
      return vim.api.nvim_win_call(target_win, callback)
    end
    return callback()
  end

  -- Handle text selection by line numbers
  if start_line then
    run_in_target_window(function()
      -- endLine can run past the last line. start_line is clamped too, so a buffer that ends up shorter
      -- than the count checked before opening still gets a selection.
      end_line = math.min(end_line, vim.api.nvim_buf_line_count(0))
      start_line = math.min(start_line, end_line)
      -- With 'selection' inclusive, a charwise selection that ends on an empty line also covers that line's
      -- line break: gv selects the character under '>, and on an empty line that is the line break. Ending
      -- on the line above instead would move '> and the selection Claude receives off endLine.
      local end_line_text = vim.api.nvim_buf_get_lines(0, end_line - 1, end_line, false)[1]
      if operator_pending then
        vim.api.nvim_win_set_cursor(0, { start_line, 0 })
        message = "Opened file and positioned at line " .. start_line .. nothing_selected
      else
        select_range(start_line, 0, end_line, math.max(#end_line_text - 1, 0))
        message = "Opened file and selected lines " .. start_line .. " to " .. end_line
      end
    end)
  end

  -- Handle text pattern selection
  if start_text then
    run_in_target_window(function()
      local buf = vim.api.nvim_get_current_buf()
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local start_line_idx, start_col_idx
      local end_line_idx, end_col_idx

      -- Find start text
      for line_idx, line in ipairs(lines) do
        local col_idx = string.find(line, start_text, 1, true) -- plain text search
        if col_idx then
          start_line_idx = line_idx
          start_col_idx = col_idx - 1 -- Convert to 0-based
          break
        end
      end

      if start_line_idx then
        -- Find end text if provided
        if end_text then
          for line_idx = start_line_idx, #lines do
            local line = lines[line_idx] -- Access current line directly
            if line then
              local search_from = line_idx == start_line_idx and start_col_idx + string.len(start_text) + 1 or 1
              local col_idx = string.find(line, end_text, search_from, true)
              if col_idx then
                end_line_idx = line_idx
                end_col_idx = col_idx - 1 + string.len(end_text) - 1
                if select_to_end_of_line then
                  end_col_idx = math.max(string.len(line) - 1, 0)
                end
                break
              end
            end
          end

          if end_line_idx then
            message = 'Opened file and selected text from "' .. start_text .. '" to "' .. end_text .. '"'
          else
            message = 'Opened file and positioned at "' .. start_text .. '" (end text "' .. end_text .. '" not found)'
          end
        else
          -- Only start text provided
          end_line_idx = start_line_idx
          end_col_idx = start_col_idx + string.len(start_text) - 1
          message = 'Opened file and selected text "' .. start_text .. '"'
        end

        -- A line range earlier in this call can leave Visual or Select mode on, and moving the cursor in it
        -- would stretch that selection.
        leave_visual_or_select_mode()
        vim.api.nvim_win_set_cursor(0, { start_line_idx, start_col_idx })
        vim.cmd("normal! zz") -- Center the match before gv, which must be the last key
        -- When endText is not found, only the cursor moves, as in the VS Code extension.
        if end_line_idx and operator_pending then
          message = 'Opened file and positioned at "' .. start_text .. '"' .. nothing_selected
        elseif end_line_idx then
          select_range(start_line_idx, start_col_idx, end_line_idx, end_col_idx)
        end
      else
        message = 'Opened file, but text "' .. start_text .. '" not found'
      end
    end)
  end

  if operator_pending then
    -- "i" puts <Esc> before any key the user types next, and "n" skips the user's mappings.
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "ni", false)
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
    local buf = target_win and vim.api.nvim_win_get_buf(target_win) or vim.api.nvim_get_current_buf()
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
          text = vim.json.encode(detailed_info),
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
