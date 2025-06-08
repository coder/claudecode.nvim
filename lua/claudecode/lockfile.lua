---@brief [[
--- Lock file management for Claude Code Neovim integration.
--- This module handles creation, removal and updating of lock files
--- which allow Claude Code CLI to discover the Neovim integration.
---@brief ]]

local M = {}

--- Path to the lock file directory
M.lock_dir = vim.fn.expand("~/.claude/ide")

--- Create the lock file for a specified WebSocket port
---@param port number The port number for the WebSocket server
---@return boolean success Whether the operation was successful
---@return string result_or_error The lock file path if successful, or error message if failed
function M.create(port)
  if not port or type(port) ~= "number" then
    return false, "Invalid port number"
  end

  local ok, err = pcall(function()
    return vim.fn.mkdir(M.lock_dir, "p")
  end)

  if not ok then
    return false, "Failed to create lock directory: " .. (err or "unknown error")
  end

  local lock_path = M.lock_dir .. "/" .. port .. ".lock"

  local workspace_folders = M.get_workspace_folders()

  -- Prepare lock file content
  local lock_content = {
    pid = vim.fn.getpid(),
    workspaceFolders = workspace_folders,
    ideName = "Neovim",
    transport = "ws",
  }

  local json
  local ok_json, json_err = pcall(function()
    json = vim.json.encode(lock_content)
    return json
  end)

  if not ok_json or not json then
    return false, "Failed to encode lock file content: " .. (json_err or "unknown error")
  end

  local file = io.open(lock_path, "w")
  if not file then
    return false, "Failed to create lock file: " .. lock_path
  end

  local write_ok, write_err = pcall(function()
    file:write(json)
    file:close()
  end)

  if not write_ok then
    pcall(function()
      file:close()
    end)
    return false, "Failed to write lock file: " .. (write_err or "unknown error")
  end

  return true, lock_path
end

--- Remove the lock file for the given port
---@param port number The port number of the WebSocket server
---@return boolean success Whether the operation was successful
---@return string? error Error message if operation failed
function M.remove(port)
  if not port or type(port) ~= "number" then
    return false, "Invalid port number"
  end

  local lock_path = M.lock_dir .. "/" .. port .. ".lock"

  if vim.fn.filereadable(lock_path) == 0 then
    return false, "Lock file does not exist: " .. lock_path
  end

  local ok, err = pcall(function()
    return os.remove(lock_path)
  end)

  if not ok then
    return false, "Failed to remove lock file: " .. (err or "unknown error")
  end

  return true
end

--- Update the lock file for the given port
---@param port number The port number of the WebSocket server
---@return boolean success Whether the operation was successful
---@return string result_or_error The lock file path if successful, or error message if failed
function M.update(port)
  if not port or type(port) ~= "number" then
    return false, "Invalid port number"
  end

  local exists = vim.fn.filereadable(M.lock_dir .. "/" .. port .. ".lock") == 1
  if exists then
    local remove_ok, remove_err = M.remove(port)
    if not remove_ok then
      return false, "Failed to update lock file: " .. remove_err
    end
  end

  return M.create(port)
end

--- Get active LSP clients using available API
---@return table Array of LSP clients
local function get_lsp_clients()
  if vim.lsp then
    if vim.lsp.get_clients then
      -- Neovim >= 0.11
      return vim.lsp.get_clients()
    elseif vim.lsp.get_active_clients then
      -- Neovim 0.8-0.10
      return vim.lsp.get_active_clients()
    end
  end
  return {}
end

--- Get workspace folders for the lock file
---@return table Array of workspace folder paths
function M.get_workspace_folders()
  local folders = {}

  -- Add current working directory
  table.insert(folders, vim.fn.getcwd())

  -- Get LSP workspace folders if available
  local clients = get_lsp_clients()
  for _, client in pairs(clients) do
    if client.config and client.config.workspace_folders then
      for _, ws in ipairs(client.config.workspace_folders) do
        -- Convert URI to path
        local path = ws.uri
        if path:sub(1, 7) == "file://" then
          path = path:sub(8)
        end

        -- Check if already in the list
        local exists = false
        for _, folder in ipairs(folders) do
          if folder == path then
            exists = true
            break
          end
        end

        if not exists then
          table.insert(folders, path)
        end
      end
    end
  end

  return folders
end

return M
