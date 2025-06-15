---
-- Visual command handling module for ClaudeCode.nvim
-- Implements neo-tree-style visual mode exit and command processing
-- @module claudecode.visual_commands
local M = {}

--- Get current vim mode with fallback for test environments
--- @param full_mode boolean|nil Whether to get full mode info (passed to vim.fn.mode)
--- @return string current_mode The current vim mode
local function get_current_mode(full_mode)
  local current_mode = "n" -- Default fallback

  pcall(function()
    if vim.api and vim.api.nvim_get_mode then
      current_mode = vim.api.nvim_get_mode().mode
    else
      current_mode = vim.fn.mode(full_mode)
    end
  end)

  return current_mode
end

-- ESC key constant matching neo-tree's implementation
local ESC_KEY
local success = pcall(function()
  ESC_KEY = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
end)
if not success then
  ESC_KEY = "\27"
end

--- Exit visual mode properly and schedule command execution
--- @param callback function The function to call after exiting visual mode
--- @param ... any Arguments to pass to the callback
function M.exit_visual_and_schedule(callback, ...)
  local args = { ... }

  -- Capture visual selection data BEFORE exiting visual mode
  local visual_data = M.capture_visual_selection_data()

  pcall(function()
    vim.api.nvim_feedkeys(ESC_KEY, "i", true)
  end)

  -- Schedule execution until after mode change (neo-tree pattern)
  local schedule_fn = vim.schedule or function(fn)
    fn()
  end -- Fallback for test environments
  schedule_fn(function()
    -- Pass the captured visual data as the first argument
    callback(visual_data, unpack(args))
  end)
end

--- Validate that we're currently in a visual mode
--- @return boolean true if in visual mode, false otherwise
--- @return string|nil error message if not in visual mode
function M.validate_visual_mode()
  local current_mode = get_current_mode(true)

  local is_visual = current_mode == "v" or current_mode == "V" or current_mode == "\022"

  -- Additional debugging: check visual marks and cursor position
  if is_visual then
    pcall(function()
      vim.api.nvim_win_get_cursor(0)
      vim.fn.getpos("'<")
      vim.fn.getpos("'>")
      vim.fn.getpos("v")
    end)
  end

  if not is_visual then
    return false, "Not in visual mode (current mode: " .. current_mode .. ")"
  end

  return true, nil
end

--- Get visual selection range using vim marks or current cursor position
--- @return number, number start_line, end_line (1-indexed)
function M.get_visual_range()
  local start_pos, end_pos = 1, 1 -- Default fallback

  -- Use pcall to handle test environments
  local range_success = pcall(function()
    -- Check if we're currently in visual mode
    local current_mode = get_current_mode(true)
    local is_visual = current_mode == "v" or current_mode == "V" or current_mode == "\022"

    if is_visual then
      -- In visual mode, ALWAYS use cursor + anchor (marks are stale until exit)
      local cursor_pos = vim.api.nvim_win_get_cursor(0)[1]
      local anchor_pos = vim.fn.getpos("v")[2]

      if anchor_pos > 0 then
        start_pos = math.min(cursor_pos, anchor_pos)
        end_pos = math.max(cursor_pos, anchor_pos)
      else
        -- Fallback: just use current cursor position
        start_pos = cursor_pos
        end_pos = cursor_pos
      end
    else
      -- Not in visual mode, try to use the marks (they should be valid now)
      local mark_start = vim.fn.getpos("'<")[2]
      local mark_end = vim.fn.getpos("'>")[2]

      if mark_start > 0 and mark_end > 0 then
        start_pos = mark_start
        end_pos = mark_end
      else
        -- No valid marks, use cursor position
        local cursor_pos = vim.api.nvim_win_get_cursor(0)[1]
        start_pos = cursor_pos
        end_pos = cursor_pos
      end
    end
  end)

  if not range_success then
    return 1, 1
  end

  if end_pos < start_pos then
    start_pos, end_pos = end_pos, start_pos
  end

  -- Ensure we have valid line numbers (at least 1)
  start_pos = math.max(1, start_pos)
  end_pos = math.max(1, end_pos)

  return start_pos, end_pos
end

--- Check if we're in a tree buffer and get the tree state
--- @return table|nil, string|nil tree_state, tree_type ("neo-tree" or "nvim-tree")
function M.get_tree_state()
  local current_ft = "" -- Default fallback
  local current_win = 0 -- Default fallback

  -- Use pcall to handle test environments
  local state_success = pcall(function()
    current_ft = vim.bo.filetype or ""
    current_win = vim.api.nvim_get_current_win()
  end)

  if not state_success then
    return nil, nil
  end

  if current_ft == "neo-tree" then
    local manager_success, manager = pcall(require, "neo-tree.sources.manager")
    if not manager_success then
      return nil, nil
    end

    local state = manager.get_state("filesystem")
    if not state then
      return nil, nil
    end

    -- Validate we're in the correct neo-tree window
    if state.winid and state.winid == current_win then
      return state, "neo-tree"
    else
      return nil, nil
    end
  elseif current_ft == "NvimTree" then
    local api_success, nvim_tree_api = pcall(require, "nvim-tree.api")
    if not api_success then
      return nil, nil
    end

    return nvim_tree_api, "nvim-tree"
  elseif current_ft == "oil" then
    local oil_success, oil = pcall(require, "oil")
    if not oil_success then
      return nil, nil
    end

    return oil, "oil"
  else
    return nil, nil
  end
end

--- Create a visual command wrapper that follows neo-tree patterns
--- @param normal_handler function The normal command handler
--- @param visual_handler function The visual command handler
--- @return function The wrapped command function
function M.create_visual_command_wrapper(normal_handler, visual_handler)
  return function(...)
    local current_mode = get_current_mode(true)

    if current_mode == "v" or current_mode == "V" or current_mode == "\022" then
      -- Use the neo-tree pattern: exit visual mode, then schedule execution
      M.exit_visual_and_schedule(visual_handler, ...)
    else
      normal_handler(...)
    end
  end
end

--- Capture visual selection data while still in visual mode
--- @return table|nil visual_data Captured data or nil if not in visual mode
function M.capture_visual_selection_data()
  local valid = M.validate_visual_mode()
  if not valid then
    return nil
  end

  local tree_state, tree_type = M.get_tree_state()
  if not tree_state then
    return nil
  end

  local start_pos, end_pos = M.get_visual_range()

  -- Validate that we have a meaningful range
  if start_pos == 0 or end_pos == 0 then
    return nil
  end

  return {
    tree_state = tree_state,
    tree_type = tree_type,
    start_pos = start_pos,
    end_pos = end_pos,
  }
end

--- Extract files from visual selection in tree buffers
--- @param visual_data table|nil Pre-captured visual selection data
--- @return table files List of file paths
--- @return string|nil error Error message if failed
function M.get_files_from_visual_selection(visual_data)
  -- If we have pre-captured data, use it; otherwise try to get current data
  local tree_state, tree_type, start_pos, end_pos

  if visual_data then
    tree_state = visual_data.tree_state
    tree_type = visual_data.tree_type
    start_pos = visual_data.start_pos
    end_pos = visual_data.end_pos
  else
    local valid, err = M.validate_visual_mode()
    if not valid then
      return {}, err
    end

    tree_state, tree_type = M.get_tree_state()
    if not tree_state then
      return {}, "Not in a supported tree buffer"
    end

    start_pos, end_pos = M.get_visual_range()
  end

  if not tree_state then
    return {}, "Not in a supported tree buffer"
  end

  local files = {}

  if tree_type == "neo-tree" then
    local selected_nodes = {}
    for line = start_pos, end_pos do
      -- Neo-tree's tree:get_node() uses the line number directly (1-based)
      local node = tree_state.tree:get_node(line)
      if node then
        if node.type and node.type ~= "message" then
          table.insert(selected_nodes, node)
        end
      end
    end

    for _, node in ipairs(selected_nodes) do
      if node.type == "file" and node.path and node.path ~= "" then
        local depth = (node.get_depth and node:get_depth()) or 0
        if depth > 1 then
          table.insert(files, node.path)
        end
      elseif node.type == "directory" and node.path and node.path ~= "" then
        local depth = (node.get_depth and node:get_depth()) or 0
        if depth > 1 then
          table.insert(files, node.path)
        end
      end
    end
  elseif tree_type == "nvim-tree" then
    -- For nvim-tree, we need to manually map visual lines to tree nodes
    -- since nvim-tree doesn't have direct line-to-node mapping like neo-tree
    require("claudecode.logger").debug(
      "visual_commands",
      "Processing nvim-tree visual selection from line",
      start_pos,
      "to",
      end_pos
    )

    local nvim_tree_api = tree_state
    local current_buf = vim.api.nvim_get_current_buf()

    -- Get all lines in the visual selection
    local lines = vim.api.nvim_buf_get_lines(current_buf, start_pos - 1, end_pos, false)

    require("claudecode.logger").debug("visual_commands", "Found", #lines, "lines in visual selection")

    -- For each line in the visual selection, try to get the corresponding node
    for i, line_content in ipairs(lines) do
      local line_num = start_pos + i - 1

      -- Set cursor to this line to get the node
      pcall(vim.api.nvim_win_set_cursor, 0, { line_num, 0 })

      -- Get node under cursor for this line
      local node_success, node = pcall(nvim_tree_api.tree.get_node_under_cursor)
      if node_success and node then
        require("claudecode.logger").debug(
          "visual_commands",
          "Line",
          line_num,
          "node type:",
          node.type,
          "path:",
          node.absolute_path
        )

        if node.type == "file" and node.absolute_path and node.absolute_path ~= "" then
          -- Check if it's not a root-level file (basic protection)
          if not string.match(node.absolute_path, "^/[^/]*$") then
            table.insert(files, node.absolute_path)
          end
        elseif node.type == "directory" and node.absolute_path and node.absolute_path ~= "" then
          table.insert(files, node.absolute_path)
        end
      else
        require("claudecode.logger").debug("visual_commands", "No valid node found for line", line_num)
      end
    end

    require("claudecode.logger").debug("visual_commands", "Extracted", #files, "files from nvim-tree visual selection")

    -- Remove duplicates while preserving order
    local seen = {}
    local unique_files = {}
    for _, file_path in ipairs(files) do
      if not seen[file_path] then
        seen[file_path] = true
        table.insert(unique_files, file_path)
      end
    end
    files = unique_files
  elseif tree_type == "oil" then
    local oil = tree_state
    local bufnr = vim.api.nvim_get_current_buf()

    -- Get current directory once
    local dir_ok, current_dir = pcall(oil.get_current_dir, bufnr)
    if dir_ok and current_dir then
      -- Access the process_oil_entry function through a module method
      for line = start_pos, end_pos do
        local entry_ok, entry = pcall(oil.get_entry_on_line, bufnr, line)
        if entry_ok and entry and entry.name then
          -- Skip parent directory entries
          if entry.name ~= ".." and entry.name ~= "." then
            local full_path = current_dir .. entry.name
            -- Handle various entry types
            if entry.type == "file" or entry.type == "link" then
              table.insert(files, full_path)
            elseif entry.type == "directory" then
              -- Ensure directory paths end with /
              table.insert(files, full_path:match("/$") and full_path or full_path .. "/")
            else
              -- For unknown types, return the path anyway
              table.insert(files, full_path)
            end
          end
        end
      end
    end
  end

  return files, nil
end

return M
