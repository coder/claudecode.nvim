---@brief WebSocket reconnection manager with exponential backoff
local logger = require("claudecode.logger")
local safe_tcp = require("claudecode.server.safe_tcp")

local M = {}

---@enum ConnectionState
M.ConnectionState = {
  DISCONNECTED = "disconnected",
  CONNECTING = "connecting",
  CONNECTED = "connected",
  RECONNECTING = "reconnecting",
  FAILED = "failed",
}

---@class ReconnectConfig
---@field enabled boolean Enable auto-reconnection
---@field max_attempts number Maximum reconnection attempts
---@field initial_delay number Initial delay in milliseconds
---@field max_delay number Maximum delay in milliseconds
---@field backoff_factor number Exponential backoff factor
---@field show_notifications boolean Show user notifications

---@class ReconnectState
---@field status string Current connection status
---@field attempt number Current reconnection attempt
---@field next_delay number Next reconnection delay
---@field reconnect_timer table|nil Active reconnection timer
---@field last_disconnect_time number|nil Last disconnection timestamp
---@field last_disconnect_reason string|nil Last disconnection reason
---@field last_error string|nil Last error message
---@field total_reconnects number Total successful reconnections

---Default reconnection configuration
M.default_config = {
  enabled = true,
  max_attempts = 10,
  initial_delay = 1000,
  max_delay = 30000,
  backoff_factor = 2,
  show_notifications = true,
}

---Current reconnection state
M.state = {
  status = M.ConnectionState.DISCONNECTED,
  attempt = 0,
  next_delay = 0,
  reconnect_timer = nil,
  last_disconnect_time = nil,
  last_disconnect_reason = nil,
  last_error = nil,
  total_reconnects = 0,
}

---Active configuration
M.config = vim.tbl_deep_extend("force", {}, M.default_config)

---Connection callback
M.connect_callback = nil

---Initialize the reconnection manager
---@param config ReconnectConfig|nil Configuration options
---@param connect_fn function Callback to establish connection
function M.setup(config, connect_fn)
  if config then
    M.config = vim.tbl_deep_extend("force", M.default_config, config)
  end
  
  M.connect_callback = connect_fn
  logger.debug("reconnect", "Reconnection manager initialized with config:", vim.inspect(M.config))
end

---Classify disconnection reason
---@param code number|nil WebSocket close code
---@param reason string|nil Close reason
---@return string error_type Type of error
---@return boolean should_reconnect Whether to attempt reconnection
local function classify_disconnect(code, reason)
  -- Normal closure codes (don't reconnect)
  if code == 1000 or code == 1001 then
    return "normal", false
  end
  
  -- Authentication errors (don't reconnect)
  if reason and (reason:match("auth") or reason:match("unauthorized")) then
    return "auth", false
  end
  
  -- Server errors (reconnect)
  if code and code >= 1011 and code <= 1015 then
    return "server", true
  end
  
  -- Network errors or abnormal closure (reconnect)
  if code == 1006 or not code then
    return "network", true
  end
  
  -- Default: attempt reconnection for unknown errors
  return "unknown", true
end

---Calculate next reconnection delay with exponential backoff
---@return number delay Delay in milliseconds
local function calculate_next_delay()
  if M.state.attempt == 0 then
    return M.config.initial_delay
  end
  
  local delay = M.state.next_delay * M.config.backoff_factor
  return math.min(delay, M.config.max_delay)
end

---Show user notification about connection status
---@param message string The message to show
---@param level number|nil Notification level (vim.log.levels.*)
local function notify_user(message, level)
  if not M.config.show_notifications then
    return
  end
  
  level = level or vim.log.levels.INFO
  vim.notify("ClaudeCode: " .. message, level)
end

---Update connection status
---@param new_status string New connection status
local function update_status(new_status)
  local old_status = M.state.status
  M.state.status = new_status
  
  logger.debug("reconnect", "Status changed from", old_status, "to", new_status)
  
  -- Notify about status changes
  if new_status == M.ConnectionState.CONNECTED then
    if old_status == M.ConnectionState.RECONNECTING then
      M.state.total_reconnects = M.state.total_reconnects + 1
      notify_user(string.format("Reconnected successfully (attempt %d)", M.state.attempt))
    else
      notify_user("Connected to Claude Code")
    end
  elseif new_status == M.ConnectionState.RECONNECTING then
    if M.state.attempt == 1 then
      notify_user("Connection lost. Attempting to reconnect...", vim.log.levels.WARN)
    end
  elseif new_status == M.ConnectionState.FAILED then
    notify_user(
      string.format("Failed to reconnect after %d attempts. Use :ClaudeCodeReconnect to try again.", 
        M.config.max_attempts),
      vim.log.levels.ERROR
    )
  end
end

---Attempt to reconnect
local function attempt_reconnect()
  if M.state.status == M.ConnectionState.CONNECTED then
    logger.debug("reconnect", "Already connected, skipping reconnection")
    return
  end
  
  if M.state.attempt >= M.config.max_attempts then
    logger.warn("reconnect", "Maximum reconnection attempts reached")
    update_status(M.ConnectionState.FAILED)
    return
  end
  
  M.state.attempt = M.state.attempt + 1
  M.state.next_delay = calculate_next_delay()
  
  logger.info("reconnect", string.format(
    "Reconnection attempt %d/%d (next delay: %dms)",
    M.state.attempt,
    M.config.max_attempts,
    M.state.next_delay
  ))
  
  update_status(M.ConnectionState.RECONNECTING)
  
  -- Show progress for later attempts
  if M.state.attempt > 1 and M.state.attempt % 3 == 0 then
    notify_user(string.format(
      "Reconnecting... (attempt %d/%d)",
      M.state.attempt,
      M.config.max_attempts
    ), vim.log.levels.WARN)
  end
  
  -- Attempt connection
  if M.connect_callback then
    local success, err = pcall(M.connect_callback)
    if not success then
      logger.error("reconnect", "Connection callback failed:", tostring(err))
      M.state.last_error = tostring(err)
      
      -- Schedule next attempt
      if M.state.attempt < M.config.max_attempts then
        schedule_reconnect()
      else
        update_status(M.ConnectionState.FAILED)
      end
    end
    -- Note: The connection callback should call on_connected() when successful
  else
    logger.error("reconnect", "No connection callback configured")
    update_status(M.ConnectionState.FAILED)
  end
end

---Schedule a reconnection attempt
function schedule_reconnect()
  -- Cancel any existing timer
  if M.state.reconnect_timer then
    safe_tcp.safe_timer_stop(M.state.reconnect_timer)
    M.state.reconnect_timer = nil
  end
  
  if not M.config.enabled then
    logger.debug("reconnect", "Reconnection disabled, not scheduling")
    return
  end
  
  if M.state.status == M.ConnectionState.CONNECTED then
    logger.debug("reconnect", "Already connected, not scheduling reconnection")
    return
  end
  
  local delay = M.state.next_delay
  logger.debug("reconnect", "Scheduling reconnection in", delay, "ms")
  
  M.state.reconnect_timer = safe_tcp.safe_timer(function()
    M.state.reconnect_timer = nil
    attempt_reconnect()
  end, delay, 0)
end

---Handle successful connection
function M.on_connected()
  logger.info("reconnect", "Connection established successfully")
  
  -- Cancel any pending reconnection
  if M.state.reconnect_timer then
    safe_tcp.safe_timer_stop(M.state.reconnect_timer)
    M.state.reconnect_timer = nil
  end
  
  -- Reset reconnection state
  M.state.attempt = 0
  M.state.next_delay = M.config.initial_delay
  M.state.last_error = nil
  
  update_status(M.ConnectionState.CONNECTED)
end

---Handle disconnection
---@param code number|nil WebSocket close code
---@param reason string|nil Disconnection reason
function M.on_disconnected(code, reason)
  logger.info("reconnect", "Disconnected with code:", code, "reason:", reason or "unknown")
  
  M.state.last_disconnect_time = vim.loop.now()
  M.state.last_disconnect_reason = reason
  
  local error_type, should_reconnect = classify_disconnect(code, reason)
  logger.debug("reconnect", "Disconnection classified as:", error_type, "should_reconnect:", should_reconnect)
  
  update_status(M.ConnectionState.DISCONNECTED)
  
  if should_reconnect and M.config.enabled then
    -- Reset attempt counter for new disconnection
    if M.state.status ~= M.ConnectionState.RECONNECTING then
      M.state.attempt = 0
      M.state.next_delay = M.config.initial_delay
    end
    
    schedule_reconnect()
  else
    if error_type == "normal" then
      notify_user("Disconnected from Claude Code")
    elseif error_type == "auth" then
      notify_user("Authentication failed. Please check your configuration.", vim.log.levels.ERROR)
    else
      notify_user("Disconnected. Auto-reconnection disabled.", vim.log.levels.WARN)
    end
  end
end

---Manually trigger reconnection
function M.reconnect()
  logger.info("reconnect", "Manual reconnection requested")
  
  if M.state.status == M.ConnectionState.CONNECTED then
    notify_user("Already connected to Claude Code")
    return
  end
  
  -- Reset state for manual reconnection
  M.state.attempt = 0
  M.state.next_delay = M.config.initial_delay
  update_status(M.ConnectionState.RECONNECTING)
  
  attempt_reconnect()
end

---Stop all reconnection attempts
function M.stop()
  logger.info("reconnect", "Stopping reconnection manager")
  
  if M.state.reconnect_timer then
    safe_tcp.safe_timer_stop(M.state.reconnect_timer)
    M.state.reconnect_timer = nil
  end
  
  M.state.status = M.ConnectionState.DISCONNECTED
  M.state.attempt = 0
end

---Get current reconnection status
---@return table status Current status information
function M.get_status()
  return {
    status = M.state.status,
    attempt = M.state.attempt,
    max_attempts = M.config.max_attempts,
    next_delay = M.state.next_delay,
    last_disconnect_time = M.state.last_disconnect_time,
    last_disconnect_reason = M.state.last_disconnect_reason,
    last_error = M.state.last_error,
    total_reconnects = M.state.total_reconnects,
    enabled = M.config.enabled,
  }
end

---Enable or disable auto-reconnection
---@param enabled boolean Whether to enable reconnection
function M.set_enabled(enabled)
  M.config.enabled = enabled
  logger.info("reconnect", "Auto-reconnection", enabled and "enabled" or "disabled")
  
  if enabled and M.state.status == M.ConnectionState.DISCONNECTED then
    -- Start reconnection if currently disconnected
    schedule_reconnect()
  elseif not enabled and M.state.reconnect_timer then
    -- Stop any pending reconnection
    safe_tcp.safe_timer_stop(M.state.reconnect_timer)
    M.state.reconnect_timer = nil
  end
end

---Reset all statistics
function M.reset_stats()
  M.state.total_reconnects = 0
  M.state.last_disconnect_time = nil
  M.state.last_disconnect_reason = nil
  M.state.last_error = nil
  logger.debug("reconnect", "Statistics reset")
end

return M