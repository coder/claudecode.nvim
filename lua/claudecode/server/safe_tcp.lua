---@brief Safe TCP operations wrapper to prevent stack errors
local logger = require("claudecode.logger")

local M = {}

---Safely check if a TCP handle is valid and not closing
---@param tcp_handle table|nil The TCP handle to check
---@return boolean valid True if handle is valid
local function is_handle_valid(tcp_handle)
  if not tcp_handle then
    return false
  end
  
  local success, is_closing = pcall(function()
    return tcp_handle:is_closing()
  end)
  
  if not success then
    return false
  end
  
  return not is_closing
end

---Safely execute a TCP operation with error handling
---@param tcp_handle table|nil The TCP handle
---@param operation_name string Name of the operation for logging
---@param operation_func function The operation to execute
---@param ... any Additional arguments for the operation
---@return boolean success True if operation succeeded
---@return any result Result of the operation or error message
function M.safe_tcp_operation(tcp_handle, operation_name, operation_func, ...)
  if not is_handle_valid(tcp_handle) then
    logger.debug("safe_tcp", "TCP handle invalid for operation:", operation_name)
    return false, "TCP handle is closed or invalid"
  end
  
  local args = {...}
  local success, result = pcall(operation_func, tcp_handle, unpack(args))
  
  if not success then
    logger.debug("safe_tcp", "TCP operation failed:", operation_name, "error:", tostring(result))
    return false, tostring(result)
  end
  
  return true, result
end

---Safely write data to a TCP handle
---@param tcp_handle table|nil The TCP handle
---@param data string The data to write
---@param callback function|nil Optional callback
---@return boolean success True if write was initiated
function M.safe_write(tcp_handle, data, callback)
  return M.safe_tcp_operation(tcp_handle, "write", function(handle)
    handle:write(data, function(err)
      if callback then
        -- Wrap callback in pcall to prevent errors from propagating
        pcall(callback, err)
      end
    end)
    return true
  end)
end

---Safely close a TCP handle
---@param tcp_handle table|nil The TCP handle
---@param callback function|nil Optional callback
---@return boolean success True if close was initiated
function M.safe_close(tcp_handle, callback)
  if not tcp_handle then
    return false
  end
  
  -- Check if already closing
  local is_closing = false
  pcall(function()
    is_closing = tcp_handle:is_closing()
  end)
  
  if is_closing then
    logger.debug("safe_tcp", "TCP handle already closing")
    return false
  end
  
  return M.safe_tcp_operation(tcp_handle, "close", function(handle)
    if callback then
      handle:close(function()
        pcall(callback)
      end)
    else
      handle:close()
    end
    return true
  end)
end

---Safely start reading from a TCP handle
---@param tcp_handle table|nil The TCP handle
---@param read_callback function The callback for incoming data
---@return boolean success True if read was started
function M.safe_read_start(tcp_handle, read_callback)
  return M.safe_tcp_operation(tcp_handle, "read_start", function(handle)
    handle:read_start(function(err, data)
      -- Wrap callback in pcall to prevent errors from propagating
      pcall(read_callback, err, data)
    end)
    return true
  end)
end

---Safely stop reading from a TCP handle
---@param tcp_handle table|nil The TCP handle
---@return boolean success True if read was stopped
function M.safe_read_stop(tcp_handle)
  return M.safe_tcp_operation(tcp_handle, "read_stop", function(handle)
    handle:read_stop()
    return true
  end)
end

---Create a safe vim.schedule wrapper
---@param func function The function to schedule
---@param context string Context for error logging
function M.safe_schedule(func, context)
  vim.schedule(function()
    local success, error_msg = pcall(func)
    if not success then
      logger.error("safe_tcp", "Scheduled function failed in", context, ":", tostring(error_msg))
      -- Error is logged but not propagated to prevent Neovim crashes
    end
  end)
end

---Create a safe timer
---@param callback function The timer callback
---@param delay number Initial delay in milliseconds
---@param repeat_interval number|nil Repeat interval (0 for one-shot)
---@return table|nil timer The timer handle or nil if creation failed
function M.safe_timer(callback, delay, repeat_interval)
  local timer = vim.loop.new_timer()
  if not timer then
    logger.error("safe_tcp", "Failed to create timer")
    return nil
  end
  
  local safe_callback = function()
    local success, err = pcall(callback)
    if not success then
      logger.error("safe_tcp", "Timer callback failed:", tostring(err))
    end
  end
  
  timer:start(delay, repeat_interval or 0, safe_callback)
  return timer
end

---Safely stop and close a timer
---@param timer table|nil The timer handle
---@return boolean success True if timer was stopped
function M.safe_timer_stop(timer)
  if not timer then
    return false
  end
  
  local success, err = pcall(function()
    if timer:is_active() then
      timer:stop()
    end
    if not timer:is_closing() then
      timer:close()
    end
  end)
  
  if not success then
    logger.debug("safe_tcp", "Failed to stop timer:", tostring(err))
    return false
  end
  
  return true
end

---Validate and return client state
---@param client table|nil The client object
---@param operation string The operation being performed
---@return boolean valid True if client is valid
---@return string|nil error_msg Error message if invalid
function M.validate_client_state(client, operation)
  if not client then
    return false, "Client object is nil"
  end
  
  if not client.tcp_handle then
    return false, "Client TCP handle is nil"
  end
  
  if client.state == "closed" or client.state == "closing" then
    logger.debug("safe_tcp", "Client", client.id, "is", client.state, "for operation:", operation)
    return false, "Client is " .. client.state
  end
  
  if not is_handle_valid(client.tcp_handle) then
    -- Update client state if handle is invalid
    client.state = "closing"
    return false, "TCP handle is closing or invalid"
  end
  
  return true
end

---Gracefully cleanup a client connection
---@param client table|nil The client object
---@param reason string The reason for cleanup
function M.graceful_client_cleanup(client, reason)
  if not client then
    return
  end
  
  logger.debug("safe_tcp", "Starting graceful cleanup for client:", client.id, "reason:", reason)
  
  -- Prevent duplicate cleanup
  if client.state == "closed" then
    logger.debug("safe_tcp", "Client", client.id, "already closed, skipping cleanup")
    return
  end
  
  client.state = "closing"
  
  -- Stop any active timers
  if client.ping_timer then
    M.safe_timer_stop(client.ping_timer)
    client.ping_timer = nil
  end
  
  -- Stop reading if active
  if client.tcp_handle then
    M.safe_read_stop(client.tcp_handle)
  end
  
  -- Close TCP connection
  if client.tcp_handle then
    M.safe_close(client.tcp_handle)
    client.tcp_handle = nil
  end
  
  client.state = "closed"
  logger.debug("safe_tcp", "Client", client.id, "cleaned up successfully")
end

---Record and monitor errors
local error_stats = {
  tcp_errors = 0,
  parse_errors = 0,
  callback_errors = 0,
  last_error_time = 0,
  error_threshold = 10,
  error_window = 60000, -- 1 minute window
}

---Record an error for monitoring
---@param error_type string Type of error
---@param error_msg string Error message
---@return boolean critical True if error rate is critical
function M.record_error(error_type, error_msg)
  local now = vim.loop.now()
  
  -- Reset counters if outside the error window
  if now - error_stats.last_error_time > error_stats.error_window then
    error_stats.tcp_errors = 0
    error_stats.parse_errors = 0
    error_stats.callback_errors = 0
  end
  
  error_stats[error_type] = (error_stats[error_type] or 0) + 1
  error_stats.last_error_time = now
  
  logger.debug("safe_tcp", "Error recorded:", error_type, "count:", error_stats[error_type], "msg:", error_msg)
  
  -- Check if error rate is critical
  if error_stats[error_type] > error_stats.error_threshold then
    logger.warn("safe_tcp", "Critical error rate for", error_type, "- consider stopping operations")
    return true
  end
  
  return false
end

---Get current error statistics
---@return table stats Current error statistics
function M.get_error_stats()
  return {
    tcp_errors = error_stats.tcp_errors,
    parse_errors = error_stats.parse_errors,
    callback_errors = error_stats.callback_errors,
    last_error_time = error_stats.last_error_time,
  }
end

---Reset error statistics
function M.reset_error_stats()
  error_stats.tcp_errors = 0
  error_stats.parse_errors = 0
  error_stats.callback_errors = 0
  error_stats.last_error_time = 0
end

return M