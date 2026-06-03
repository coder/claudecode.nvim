---@brief [[
--- Lock file management for Claude Code Neovim integration.
--- This module handles creation, removal and updating of lock files
--- which allow Claude Code CLI to discover the Neovim integration.
---@brief ]]
---@module 'claudecode.lockfile'
local M = {}

---Path to the lock file directory
---@return string lock_dir The path to the lock file directory
local function get_lock_dir()
  local claude_config_dir = os.getenv("CLAUDE_CONFIG_DIR")
  if claude_config_dir and claude_config_dir ~= "" then
    return vim.fn.expand(claude_config_dir .. "/ide")
  else
    return vim.fn.expand("~/.claude/ide")
  end
end

M.lock_dir = get_lock_dir()

---Read n random bytes from a cryptographically secure source.
---Tries libuv's OS CSPRNG first, then falls back to /dev/urandom.
---Never falls back to math.random: a weak token is worse than a startup error.
---@param n number The number of random bytes to read
---@return string bytes A string of exactly n random bytes
local function get_random_bytes(n)
  -- Prefer libuv's uv_random (OS CSPRNG). Use vim.loop.random (available on
  -- Neovim 0.8+) rather than vim.uv.random (only aliased on 0.10+).
  if vim.loop and vim.loop.random then
    local ok, bytes = pcall(vim.loop.random, n)
    if ok and type(bytes) == "string" and #bytes == n then
      return bytes
    end
  end

  -- Fallback: read directly from the kernel CSPRNG.
  local file = io.open("/dev/urandom", "rb")
  if file then
    local bytes = file:read(n)
    file:close()
    if type(bytes) == "string" and #bytes == n then
      return bytes
    end
  end

  error("Failed to obtain " .. n .. " bytes of secure random data (no vim.loop.random or readable /dev/urandom)")
end

---Generate a cryptographically secure authentication token.
---@return string token A 32-character lowercase hex string (128 bits of entropy)
local function generate_auth_token()
  local bytes = get_random_bytes(16)

  -- Hex-encode the random bytes into a 32-character lowercase string.
  local token = bytes:gsub(".", function(c)
    return string.format("%02x", string.byte(c))
  end)

  -- Sanity-check the generated token shape.
  if not token:match("^[0-9a-f]+$") then
    error("Generated invalid auth token format")
  end

  if #token < 16 then
    error("Generated auth token too short: " .. #token .. " (expected at least 16)")
  end

  return token
end

---Generate a new authentication token
---@return string auth_token A newly generated authentication token
function M.generate_auth_token()
  return generate_auth_token()
end

---Create the lock file for a specified WebSocket port
---@param port number The port number for the WebSocket server
---@param auth_token? string Optional pre-generated auth token (generates new one if not provided)
---@return boolean success Whether the operation was successful
---@return string result_or_error The lock file path if successful, or error message if failed
---@return string? auth_token The authentication token if successful
function M.create(port, auth_token)
  if not port or type(port) ~= "number" then
    return false, "Invalid port number"
  end

  if port < 1 or port > 65535 then
    return false, "Port number out of valid range (1-65535): " .. tostring(port)
  end

  local ok, err = pcall(function()
    return vim.fn.mkdir(M.lock_dir, "p", "0700")
  end)

  if not ok then
    return false, "Failed to create lock directory: " .. (err or "unknown error")
  end

  local lock_path = M.lock_dir .. "/" .. port .. ".lock"

  local workspace_folders = M.get_workspace_folders()
  if not auth_token then
    local auth_success, auth_result = pcall(generate_auth_token)
    if not auth_success then
      return false, "Failed to generate authentication token: " .. (auth_result or "unknown error")
    end
    auth_token = auth_result
  else
    -- Validate provided auth_token
    if type(auth_token) ~= "string" then
      return false, "Authentication token must be a string, got " .. type(auth_token)
    end
    if #auth_token < 10 then
      return false, "Authentication token too short (minimum 10 characters)"
    end
    if #auth_token > 500 then
      return false, "Authentication token too long (maximum 500 characters)"
    end
  end

  -- Prepare lock file content
  local lock_content = {
    pid = vim.fn.getpid(),
    workspaceFolders = workspace_folders,
    ideName = "Neovim",
    transport = "ws",
    authToken = auth_token,
  }

  local json
  local ok_json, json_err = pcall(function()
    json = vim.json.encode(lock_content)
    return json
  end)

  if not ok_json or not json then
    return false, "Failed to encode lock file content: " .. (json_err or "unknown error")
  end

  -- Write atomically with restrictive (0600) permissions: write to a temp file
  -- in the same directory, then rename into place. Using "wx" (O_CREAT|O_EXCL)
  -- refuses to follow an existing file or symlink at the temp path.
  local tmp_path = lock_path .. ".tmp." .. vim.fn.getpid()

  local write_ok, write_err = pcall(function()
    local fd = vim.loop.fs_open(tmp_path, "wx", tonumber("600", 8))
    if not fd then
      error("could not open temp file: " .. tmp_path)
    end

    local close_and_raise = function(message)
      pcall(vim.loop.fs_close, fd)
      error(message)
    end

    local ok_write, write_result = pcall(vim.loop.fs_write, fd, json)
    if not ok_write or not write_result then
      close_and_raise("could not write temp file: " .. tostring(write_result))
    end

    local ok_close = pcall(vim.loop.fs_close, fd)
    if not ok_close then
      error("could not close temp file: " .. tmp_path)
    end
  end)

  if not write_ok then
    pcall(vim.loop.fs_unlink, tmp_path)
    return false, "Failed to write lock file: " .. (write_err or "unknown error")
  end

  local rename_ok, rename_err = os.rename(tmp_path, lock_path)
  if not rename_ok then
    pcall(vim.loop.fs_unlink, tmp_path)
    return false, "Failed to write lock file: " .. (rename_err or "rename failed")
  end

  return true, lock_path, auth_token
end

---Remove the lock file for the given port
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

---Update the lock file for the given port
---@param port number The port number of the WebSocket server
---@return boolean success Whether the operation was successful
---@return string result_or_error The lock file path if successful, or error message if failed
---@return string? auth_token The authentication token if successful
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

---Read the authentication token from a lock file
---@param port number The port number of the WebSocket server
---@return boolean success Whether the operation was successful
---@return string? auth_token The authentication token if successful, or nil if failed
---@return string? error Error message if operation failed
function M.get_auth_token(port)
  if not port or type(port) ~= "number" then
    return false, nil, "Invalid port number"
  end

  local lock_path = M.lock_dir .. "/" .. port .. ".lock"

  if vim.fn.filereadable(lock_path) == 0 then
    return false, nil, "Lock file does not exist: " .. lock_path
  end

  local file = io.open(lock_path, "r")
  if not file then
    return false, nil, "Failed to open lock file: " .. lock_path
  end

  local content = file:read("*all")
  file:close()

  if not content or content == "" then
    return false, nil, "Lock file is empty: " .. lock_path
  end

  local ok, lock_data = pcall(vim.json.decode, content)
  if not ok or type(lock_data) ~= "table" then
    return false, nil, "Failed to parse lock file JSON: " .. lock_path
  end

  local auth_token = lock_data.authToken
  if not auth_token or type(auth_token) ~= "string" then
    return false, nil, "No valid auth token found in lock file"
  end

  return true, auth_token, nil
end

---Get active LSP clients using available API
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

---Get workspace folders for the lock file
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
