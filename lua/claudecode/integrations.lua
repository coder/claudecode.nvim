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
  
  -- Check for multi-selection first
  if state.tree and state.tree.get_selection then
    local selection = state.tree:get_selection()
    if selection and #selection > 0 then
      logger.debug("integrations", "Found " .. #selection .. " selected items in neo-tree")
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