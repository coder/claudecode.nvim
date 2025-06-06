---
-- Tree integration module for ClaudeCode.nvim
-- Handles detection and selection of files from nvim-tree and neo-tree
-- @module claudecode.integrations
local M = {}

local logger = require("claudecode.logger")

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
    logger.warn("integrations", "nvim-tree API not available")
    return {}, "nvim-tree not available"
  end

  local files = {}

  -- Check for multi-selection first (marked files)
  local marks = nvim_tree_api.marks.list()
  if marks and #marks > 0 then
    logger.debug("integrations", "Found " .. #marks .. " marked files in nvim-tree")
    for _, mark in ipairs(marks) do
      if mark.type == "file" and mark.absolute_path then
        table.insert(files, mark.absolute_path)
        logger.debug("integrations", "Added marked file: " .. mark.absolute_path)
      end
    end
    if #files > 0 then
      return files, nil
    end
  end

  -- Fall back to node under cursor
  local node = nvim_tree_api.tree.get_node_under_cursor()
  if node then
    if node.type == "file" and node.absolute_path then
      logger.debug("integrations", "Found file under cursor: " .. node.absolute_path)
      return { node.absolute_path }, nil
    elseif node.type == "directory" then
      return {}, "Cannot add directory to Claude context. Please select a file."
    end
  end

  return {}, "No file found under cursor"
end

--- Get selected files from neo-tree
--- Supports both multi-selection and single file under cursor
--- @return table files List of file paths
--- @return string|nil error Error message if operation failed
function M._get_neotree_selection()
  local success, manager = pcall(require, "neo-tree.sources.manager")
  if not success then
    logger.warn("integrations", "neo-tree manager not available")
    return {}, "neo-tree not available"
  end

  local state = manager.get_state("filesystem")
  if not state then
    logger.warn("integrations", "neo-tree filesystem state not available")
    return {}, "neo-tree filesystem state not available"
  end

  local files = {}
  local selection = nil

  -- Debug: Log available state structure
  logger.debug("integrations", "neo-tree state available, checking for selection")

  -- Method 1: Check for visual selection in neo-tree (when using V to select multiple lines)
  -- This is likely what happens when you select multiple files with visual mode

  -- Get visual selection range if in visual mode
  local mode = vim.fn.mode()
  if mode == "V" or mode == "v" or mode == "\22" then -- Visual modes
    logger.debug("integrations", "Visual mode detected: " .. mode)

    -- Get the visual selection range
    local start_line = vim.fn.line("v")
    local end_line = vim.fn.line(".")
    if start_line > end_line then
      start_line, end_line = end_line, start_line
    end

    logger.debug("integrations", "Visual selection from line " .. start_line .. " to " .. end_line)

    -- Get the rendered tree to map line numbers to file paths
    if state.tree and state.tree.get_nodes then
      local nodes = state.tree:get_nodes()
      if nodes then
        local line_to_node = {}

        -- Build a mapping of line numbers to nodes
        local function map_nodes(node_list, depth)
          depth = depth or 0
          for _, node in ipairs(node_list) do
            if node.position and node.position.row then
              line_to_node[node.position.row] = node
            end
            if node.children then
              map_nodes(node.children, depth + 1)
            end
          end
        end

        map_nodes(nodes)

        -- Get files from selected lines
        for line = start_line, end_line do
          local node = line_to_node[line]
          if node and node.type == "file" and node.path then
            table.insert(files, node.path)
            logger.debug("integrations", "Added file from line " .. line .. ": " .. node.path)
          end
        end

        if #files > 0 then
          return files, nil
        end
      end
    end
  end

  -- Method 2: Try neo-tree's built-in selection methods
  if state.tree then
    if state.tree.get_selection then
      selection = state.tree:get_selection()
      if selection and #selection > 0 then
        logger.debug("integrations", "Found selection via get_selection: " .. #selection)
      end
    end

    -- Method 3: Check state-level selection
    if (not selection or #selection == 0) and state.selected_nodes then
      selection = state.selected_nodes
      logger.debug("integrations", "Found selection via state.selected_nodes: " .. #selection)
    end

    -- Process selection if found
    if selection and #selection > 0 then
      for _, node in ipairs(selection) do
        if node.type == "file" and node.path then
          table.insert(files, node.path)
          logger.debug("integrations", "Added selected file: " .. node.path)
        end
      end
      if #files > 0 then
        return files, nil
      end
    end
  end

  -- Fall back to current node under cursor
  if state.tree then
    local node = state.tree:get_node()
    if node then
      if node.type == "file" and node.path then
        logger.debug("integrations", "Found file under cursor: " .. node.path)
        return { node.path }, nil
      elseif node.type == "directory" then
        return {}, "Cannot add directory to Claude context. Please select a file."
      end
    end
  end

  return {}, "No file found under cursor"
end

return M
