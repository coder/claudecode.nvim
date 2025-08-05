--- Tool implementation for getting workspace folders.

local schema = {
  description = "Get all workspace folders currently open in the IDE",
  inputSchema = {
    type = "object",
    additionalProperties = false,
    ["$schema"] = "http://json-schema.org/draft-07/schema#",
  },
}

---Handles the getWorkspaceFolders tool invocation.
---Retrieves workspace folders, currently defaulting to CWD and attempting LSP integration.
---@return table MCP-compliant response with workspace folders data
local function handler(params)
  local cwd = vim.fn.getcwd()

  -- TODO: Enhance integration with LSP workspace folders if available,
  -- similar to how it's done in claudecode.lockfile.get_workspace_folders.
  -- For now, this is a simplified version as per the original tool's direct implementation.

  local folders = {
    {
      name = vim.fn.fnamemodify(cwd, ":t"),
      uri = "file://" .. cwd,
      path = cwd,
    },
  }

  -- A more complete version would replicate the logic from claudecode.lockfile:
  -- local lsp_folders = get_lsp_workspace_folders_logic_here()
  -- for _, folder_path in ipairs(lsp_folders) do
  --   local already_exists = false
  --   for _, existing_folder in ipairs(folders) do
  --     if existing_folder.path == folder_path then
  --       already_exists = true
  --       break
  --     end
  --   end
  --   if not already_exists then
  --     table.insert(folders, {
  --       name = vim.fn.fnamemodify(folder_path, ":t"),
  --       uri = "file://" .. folder_path,
  --       path = folder_path,
  --     })
  --   end
  -- end

  -- Return MCP-compliant format with JSON-stringified workspace data
  return {
    content = {
      {
        type = "text",
        text = vim.json.encode({
          success = true,
          folders = folders,
          rootPath = cwd,
        }, { indent = 2 }),
      },
    },
  }
end

return {
  name = "getWorkspaceFolders",
  schema = schema,
  handler = handler,
}
