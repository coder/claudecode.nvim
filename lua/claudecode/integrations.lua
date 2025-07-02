---
-- Tree integration module for ClaudeCode.nvim
-- Handles detection and selection of files from nvim-tree, neo-tree, oil.nvim and snacks.explorer
-- @module claudecode.integrations
local M = {}

--- Get selected files from the current tree explorer
--- @return table|nil files List of file paths, or nil if error
--- @return string|nil error Error message if operation failed
function M.get_selected_files_from_tree()
  local current_ft = vim.bo.filetype

  if current_ft == "NvimTree" then
    return M._get_nvim_tree_selection()
  elseif current_ft == "neo-tree" then
    return M._get_neotree_selection()
  elseif current_ft == "oil" then
    return M._get_oil_selection()
  elseif current_ft == "snacks_picker_list" then
    return M._get_snacks_explorer_selection()
  else
    return nil, "Not in a supported tree buffer (current filetype: " .. current_ft .. ")"
  end
end

--- Get selected files from nvim-tree
--- Supports both multi-selection (marks) and single file under cursor
--- @return table files List of file paths
--- @return string|nil error Error message if operation failed
function M._get_nvim_tree_selection()
  local success, nvim_tree_api = pcall(require, "nvim-tree.api")
  if not success then
    return {}, "nvim-tree not available"
  end

  local files = {}

  local marks = nvim_tree_api.marks.list()

  if marks and #marks > 0 then
    for i, mark in ipairs(marks) do
      if mark.type == "file" and mark.absolute_path and mark.absolute_path ~= "" then
        -- Check if it's not a root-level file (basic protection)
        if not string.match(mark.absolute_path, "^/[^/]*$") then
          table.insert(files, mark.absolute_path)
        end
      end
    end

    if #files > 0 then
      return files, nil
    end
  end

  local node = nvim_tree_api.tree.get_node_under_cursor()
  if node then
    if node.type == "file" and node.absolute_path and node.absolute_path ~= "" then
      -- Check if it's not a root-level file (basic protection)
      if not string.match(node.absolute_path, "^/[^/]*$") then
        return { node.absolute_path }, nil
      else
        return {}, "Cannot add root-level file. Please select a file in a subdirectory."
      end
    elseif node.type == "directory" and node.absolute_path and node.absolute_path ~= "" then
      return { node.absolute_path }, nil
    end
  end

  return {}, "No file found under cursor"
end

--- Get selected files from neo-tree
--- Uses neo-tree's own visual selection method when in visual mode
--- @return table files List of file paths
--- @return string|nil error Error message if operation failed
function M._get_neotree_selection()
  local success, manager = pcall(require, "neo-tree.sources.manager")
  if not success then
    return {}, "neo-tree not available"
  end

  local state = manager.get_state("filesystem")
  if not state then
    return {}, "neo-tree filesystem state not available"
  end

  local files = {}

  -- Use neo-tree's own visual selection method (like their copy/paste feature)
  local mode = vim.fn.mode()

  if mode == "V" or mode == "v" or mode == "\22" then
    local current_win = vim.api.nvim_get_current_win()

    if state.winid and state.winid == current_win then
      -- Use neo-tree's exact method to get visual range (from their get_selected_nodes implementation)
      local start_pos = vim.fn.getpos("'<")[2]
      local end_pos = vim.fn.getpos("'>")[2]

      -- Fallback to current cursor and anchor if marks are not valid
      if start_pos == 0 or end_pos == 0 then
        local cursor_pos = vim.api.nvim_win_get_cursor(0)[1]
        local anchor_pos = vim.fn.getpos("v")[2]
        if anchor_pos > 0 then
          start_pos = math.min(cursor_pos, anchor_pos)
          end_pos = math.max(cursor_pos, anchor_pos)
        else
          start_pos = cursor_pos
          end_pos = cursor_pos
        end
      end

      if end_pos < start_pos then
        start_pos, end_pos = end_pos, start_pos
      end

      local selected_nodes = {}

      for line = start_pos, end_pos do
        local node = state.tree:get_node(line)
        if node then
          -- Add validation for node types before adding to selection
          if node.type and node.type ~= "message" then
            table.insert(selected_nodes, node)
          end
        end
      end

      for i, node in ipairs(selected_nodes) do
        -- Enhanced validation: check for file type and valid path
        if node.type == "file" and node.path and node.path ~= "" then
          -- Additional check: ensure it's not a root node (depth protection)
          local depth = (node.get_depth and node:get_depth()) and node:get_depth() or 0
          if depth > 1 then
            table.insert(files, node.path)
          end
        end
      end

      if #files > 0 then
        return files, nil
      end
    end
  end

  if state.tree then
    local selection = nil

    if state.tree.get_selection then
      selection = state.tree:get_selection()
    end

    if (not selection or #selection == 0) and state.selected_nodes then
      selection = state.selected_nodes
    end

    if selection and #selection > 0 then
      for i, node in ipairs(selection) do
        if node.type == "file" and node.path then
          table.insert(files, node.path)
        end
      end

      if #files > 0 then
        return files, nil
      end
    end
  end

  if state.tree then
    local node = state.tree:get_node()

    if node then
      if node.type == "file" and node.path then
        return { node.path }, nil
      elseif node.type == "directory" and node.path then
        return { node.path }, nil
      end
    end
  end

  return {}, "No file found under cursor"
end

--- Get selected files from oil.nvim
--- Supports both visual selection and single file under cursor
--- @return table files List of file paths
--- @return string|nil error Error message if operation failed
function M._get_oil_selection()
  local success, oil = pcall(require, "oil")
  if not success then
    return {}, "oil.nvim not available"
  end

  local bufnr = vim.api.nvim_get_current_buf() --[[@as number]]
  local files = {}

  -- Check if we're in visual mode
  local mode = vim.fn.mode()
  if mode == "V" or mode == "v" or mode == "\22" then
    -- Visual mode: use the common visual range function
    local visual_commands = require("claudecode.visual_commands")
    local start_line, end_line = visual_commands.get_visual_range()

    -- Get current directory once
    local dir_ok, current_dir = pcall(oil.get_current_dir, bufnr)
    if not dir_ok or not current_dir then
      return {}, "Failed to get current directory"
    end

    -- Process each line in the visual selection
    for line = start_line, end_line do
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

    if #files > 0 then
      return files, nil
    end
  else
    -- Normal mode: get file under cursor with error handling
    local ok, entry = pcall(oil.get_cursor_entry)
    if not ok or not entry then
      return {}, "Failed to get cursor entry"
    end

    local dir_ok, current_dir = pcall(oil.get_current_dir, bufnr)
    if not dir_ok or not current_dir then
      return {}, "Failed to get current directory"
    end

    -- Process the entry
    if entry.name and entry.name ~= ".." and entry.name ~= "." then
      local full_path = current_dir .. entry.name
      -- Handle various entry types
      if entry.type == "file" or entry.type == "link" then
        return { full_path }, nil
      elseif entry.type == "directory" then
        -- Ensure directory paths end with /
        return { full_path:match("/$") and full_path or full_path .. "/" }, nil
      else
        -- For unknown types, return the path anyway
        return { full_path }, nil
      end
    end
  end

  return {}, "No file found under cursor"
end

--- Get selected files from snacks.explorer
--- Uses the picker API to get the current selection
--- @param visual_start number|nil Start line of visual selection (optional)
--- @param visual_end number|nil End line of visual selection (optional)
--- @return table files List of file paths
--- @return string|nil error Error message if operation failed
function M._get_snacks_explorer_selection(visual_start, visual_end)
  local snacks_ok, snacks = pcall(require, "snacks")
  if not snacks_ok or not snacks.picker then
    return {}, "snacks.nvim not available"
  end

  -- Get the current explorer picker
  local explorers = snacks.picker.get({ source = "explorer" })
  if not explorers or #explorers == 0 then
    return {}, "No active snacks.explorer found"
  end

  -- Get the first (and likely only) explorer instance
  local explorer = explorers[1]
  if not explorer then
    return {}, "No active snacks.explorer found"
  end

  local files = {}

  -- Helper function to extract file path from various item structures
  local function extract_file_path(item)
    if not item then
      return nil
    end
    local file_path = item.file or item.path or (item.item and item.item.file) or (item.item and item.item.path)

    -- Add trailing slash for directories
    if file_path and file_path ~= "" and vim.fn.isdirectory(file_path) == 1 then
      if not file_path:match("/$") then
        file_path = file_path .. "/"
      end
    end

    return file_path
  end

  -- Helper function to check if path is safe (not root-level)
  local function is_safe_path(file_path)
    if not file_path or file_path == "" then
      return false
    end
    -- Not root-level file & this prevents selecting files like /etc/passwd, /usr/bin/vim, etc.
    return not string.match(file_path, "^/[^/]*$")
  end

  -- Handle visual mode selection if range is provided
  if visual_start and visual_end and explorer.list then
    -- Process each line in the visual selection
    for row = visual_start, visual_end do
      -- Convert row to picker index
      local idx = explorer.list:row2idx(row)
      if idx then
        -- Get the item at this index
        local item = explorer.list:get(idx)
        if item then
          local file_path = extract_file_path(item)
          if file_path and file_path ~= "" and is_safe_path(file_path) then
            table.insert(files, file_path)
          end
        end
      end
    end
    if #files > 0 then
      return files, nil
    end
  end

  -- Check if there are selected items (using toggle selection)
  local selected = explorer:selected({ fallback = false })
  if selected and #selected > 0 then
    -- Process selected items
    for _, item in ipairs(selected) do
      local file_path = extract_file_path(item)
      if file_path and file_path ~= "" and is_safe_path(file_path) then
        table.insert(files, file_path)
      end
    end
    if #files > 0 then
      return files, nil
    end
  end

  -- Fall back to current item under cursor
  local current = explorer:current({ resolve = true })
  if current then
    local file_path = extract_file_path(current)
    if file_path and file_path ~= "" then
      if is_safe_path(file_path) then
        return { file_path }, nil
      else
        return {}, "Cannot add root-level file. Please select a file in a subdirectory."
      end
    end
  end

  return {}, "No file found under cursor"
end

return M
