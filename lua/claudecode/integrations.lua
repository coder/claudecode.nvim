local M = {}

function M.get_path_from_tree()
  if vim.bo.filetype == "NvimTree" then
    local success, nvim_tree_api = pcall(require, "nvim-tree.api")
    if success and nvim_tree_api then
      local node = nvim_tree_api.tree.get_node_under_cursor()
      if node and node.absolute_path then
        return node.absolute_path
      end
    end
  elseif vim.bo.filetype == "neo-tree" then
    local success, manager = pcall(require, "neo-tree.sources.manager")
    if success and manager then
      local state = manager.get_state("filesystem")
      if state and state.tree then
        local node = state.tree:get_node()
        if node and node.path then
          return node.path
        end
      end
    end
  end

  vim.notify("Could not get file path from tree.", vim.log.levels.WARN, { title = "ClaudeCode" })
  return nil
end

return M
