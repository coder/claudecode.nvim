--- HTTP client for OpenCode API integration
--- Sends file references via OpenCode's HTTP API instead of terminal injection
--- @module 'opencode.http_client'

local M = {}

local logger = require("opencode.logger")

---Sends a file reference to OpenCode via HTTP API
---@param port number The OpenCode HTTP server port
---@param text string The text to append to the prompt (e.g., "@file.lua#12-34")
---@param callback? fun(success: boolean, error?: string) Optional callback for async handling
---@return boolean success
---@return string|nil error
function M.append_prompt(port, text, callback)
  if type(port) ~= "number" or port <= 0 then
    local err = "Invalid port: " .. tostring(port)
    logger.error("http_client", err)
    if callback then
      callback(false, err)
    end
    return false, err
  end

  if type(text) ~= "string" or text == "" then
    local err = "Empty text provided"
    logger.error("http_client", err)
    if callback then
      callback(false, err)
    end
    return false, err
  end

  local url = string.format("http://localhost:%d/tui/publish", port)
  local payload = {
    type = "tui.prompt.append",
    properties = {
      text = text,
    },
  }

  -- Build curl command
  local cmd = {
    "curl",
    "-s", -- silent
    "-X", "POST",
    "-H", "Content-Type: application/json",
    "-H", "Accept: application/json",
    "-d", vim.fn.json_encode(payload),
    url,
  }

  logger.debug("http_client", "Sending to OpenCode API:", vim.inspect(payload))
  logger.debug("http_client", "curl command:", table.concat(cmd, " "))

  local job_id = vim.fn.jobstart(cmd, {
    on_exit = function(_, exit_code)
      local success = exit_code == 0
      if not success then
        local err = string.format("HTTP request failed with exit code: %d", exit_code)
        logger.error("http_client", err)
        if callback then
          callback(false, err)
        end
      else
        logger.debug("http_client", "Successfully sent file reference via HTTP API")
        if callback then
          callback(true, nil)
        end
      end
    end,
    on_stderr = function(_, data)
      if data and #data > 0 then
        for _, line in ipairs(data) do
          if line and line ~= "" then
            logger.error("http_client", "curl stderr:", line)
          end
        end
      end
    end,
  })

  if job_id <= 0 then
    local err = "Failed to start curl job"
    logger.error("http_client", err)
    if callback then
      callback(false, err)
    end
    return false, err
  end

  -- For synchronous behavior (no callback), we return immediately
  -- The job runs async in background
  if not callback then
    return true, nil
  end

  return true, nil
end

---Validates that OpenCode HTTP server is accessible
---@param port number The port to check
---@param callback fun(success: boolean, error?: string)
function M.validate_server(port, callback)
  if type(port) ~= "number" or port <= 0 then
    callback(false, "Invalid port")
    return
  end

  local url = string.format("http://localhost:%d/path", port)
  local cmd = {
    "curl",
    "-s",
    "-o", "/dev/null", -- discard output
    "-w", "%{http_code}", -- get HTTP status code
    "--max-time", "2", -- 2 second timeout
    url,
  }

  local stdout_lines = {}
  local job_id = vim.fn.jobstart(cmd, {
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line and line ~= "" then
            table.insert(stdout_lines, line)
          end
        end
      end
    end,
    on_exit = function(_, exit_code)
      local stdout = table.concat(stdout_lines, "")
      local http_code = tonumber(stdout) or 0

      if exit_code == 0 and http_code == 200 then
        logger.debug("http_client", "OpenCode server validated on port", port)
        callback(true, nil)
      else
        local err = string.format("Server not accessible (exit: %d, http: %d)", exit_code, http_code)
        logger.error("http_client", err)
        callback(false, err)
      end
    end,
  })

  if job_id <= 0 then
    callback(false, "Failed to start validation job")
  end
end

return M
