---
-- Tree integration module for ClaudeCode.nvim
-- Handles detection and selection of files from nvim-tree and neo-tree
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
      -- No valid visual marks found

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
          -- Message nodes not included in selection
        end
        -- No node found at this line
      end

      -- Extract file paths from selected nodes with enhanced validation

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
      -- No files found in visual selection
    end
    -- Not in correct neo-tree window
  end
  -- Not in visual mode

  -- Method 2: Try neo-tree's built-in selection methods

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
      -- No files found in selection
    end
    -- No selection available
  end
  -- No tree available

  -- Fall back to current node under cursor

  if state.tree then
    local node = state.tree:get_node()

    if node then
      if node.type == "file" and node.path then
        return { node.path }, nil
      elseif node.type == "directory" and node.path then
        return { node.path }, nil
      end
      -- Invalid node type or path
    end
    -- No cursor node found
  end
  -- No tree state available

  return {}, "No file found under cursor"
end

return M
