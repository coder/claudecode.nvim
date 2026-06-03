---@brief WebSocket client connection management
local frame = require("claudecode.server.frame")
local handshake = require("claudecode.server.handshake")
local logger = require("claudecode.logger")

local M = {}

---@class WebSocketClient
---@field id string Unique client identifier
---@field tcp_handle table The vim.loop TCP handle
---@field state string Connection state: "connecting", "connected", "closing", "closed"
---@field buffer string Incoming data buffer
---@field handshake_complete boolean Whether WebSocket handshake is complete
---@field last_ping number Timestamp of last ping sent
---@field last_pong number Timestamp of last pong received

---Create a new WebSocket client
---@param tcp_handle table The vim.loop TCP handle
---@return WebSocketClient client The client object
function M.create_client(tcp_handle)
  local client_id = tostring(tcp_handle):gsub("userdata: ", "client_")

  local client = {
    id = client_id,
    tcp_handle = tcp_handle,
    state = "connecting",
    buffer = "",
    handshake_complete = false,
    last_ping = 0,
    last_pong = vim.loop.now(),
  }

  return client
end

---Process incoming data for a client
---@param client WebSocketClient The client object
---@param data string The incoming data
---@param on_message function Callback for complete messages: function(client, message_text)
---@param on_close function Callback for client close: function(client, code, reason)
---@param on_error function Callback for errors: function(client, error_msg)
---@param auth_token string|nil Expected authentication token for validation
function M.process_data(client, data, on_message, on_close, on_error, auth_token)
  client.buffer = client.buffer .. data

  if not client.handshake_complete then
    local complete, request, remaining = handshake.extract_http_request(client.buffer)
    if complete and request then
      logger.debug("client", "Processing WebSocket handshake for client:", client.id)

      -- Log if auth token is required
      if auth_token then
        logger.debug("client", "Authentication required for client:", client.id)
      else
        logger.debug("client", "No authentication required for client:", client.id)
      end

      local success, response_from_handshake, _ = handshake.process_handshake(request, auth_token)

      -- Log authentication results
      if success then
        if auth_token then
          logger.debug("client", "Client authenticated successfully:", client.id)
        else
          logger.debug("client", "Client handshake completed (no auth required):", client.id)
        end
      else
        -- Log specific authentication failure details
        if auth_token and response_from_handshake:find("auth") then
          logger.warn(
            "client",
            "Authentication failed for client "
              .. client.id
              .. ": "
              .. (response_from_handshake:match("Bad WebSocket upgrade request: (.+)") or "unknown auth error")
          )
        else
          logger.warn(
            "client",
            "WebSocket handshake failed for client "
              .. client.id
              .. ": "
              .. (response_from_handshake:match("HTTP/1.1 %d+ (.+)") or "unknown handshake error")
          )
        end
      end

      client.tcp_handle:write(response_from_handshake, function(err)
        if err then
          logger.error("client", "Failed to send handshake response to client " .. client.id .. ": " .. err)
          on_error(client, "Failed to send handshake response: " .. err)
          return
        end

        if success then
          client.handshake_complete = true
          client.state = "connected"
          client.buffer = remaining
          logger.debug("client", "WebSocket connection established for client:", client.id)

          if #client.buffer > 0 then
            M.process_data(client, "", on_message, on_close, on_error, auth_token)
          end
        else
          client.state = "closing"
          logger.debug("client", "Closing connection for client due to failed handshake:", client.id)
          vim.schedule(function()
            client.tcp_handle:close()
          end)
        end
      end)
    end
    return
  end

  while #client.buffer >= 2 do -- Minimum frame size
    local parsed_frame, bytes_consumed, close_code = frame.parse_frame(client.buffer)

    if not parsed_frame then
      if close_code then
        -- Fatal protocol violation: close with the RFC 6455 status code and drop
        -- the offending bytes instead of leaving them buffered to be re-parsed
        -- forever (which previously wedged the connection).
        --
        -- close_client MUST run before on_error: on_error tears the connection
        -- down synchronously (tcp.lua: _disconnect_client -> _remove_client ->
        -- tcp_handle:close()) without setting client.state, so if it ran first
        -- the Close frame would be written to an already-closed handle and never
        -- reach the peer. Closing first writes the Close frame while the handle
        -- is open and sets client.state, after which on_error's teardown no-ops.
        client.buffer = ""
        M.close_client(client, close_code, "Protocol error")
        on_error(client, "WebSocket protocol error in frame")
      end
      break -- No close_code means the frame is incomplete; wait for more bytes.
    end

    -- Frame validation is now handled entirely within frame.parse_frame.
    -- If frame.parse_frame returns a frame, it's considered valid.

    client.buffer = client.buffer:sub(bytes_consumed + 1)

    if parsed_frame.opcode == frame.OPCODE.TEXT then
      vim.schedule(function()
        on_message(client, parsed_frame.payload)
      end)
    elseif parsed_frame.opcode == frame.OPCODE.BINARY then
      -- Binary message (treat as text for JSON-RPC)
      vim.schedule(function()
        on_message(client, parsed_frame.payload)
      end)
    elseif parsed_frame.opcode == frame.OPCODE.CLOSE then
      local code = 1000
      local reason = ""

      if #parsed_frame.payload >= 2 then
        local payload = parsed_frame.payload
        code = payload:byte(1) * 256 + payload:byte(2)
        if #payload > 2 then
          reason = payload:sub(3)
        end
      end

      if client.state == "connected" then
        local close_frame = frame.create_close_frame(code, reason)
        client.tcp_handle:write(close_frame)
        client.state = "closing"
      end

      vim.schedule(function()
        on_close(client, code, reason)
      end)
    elseif parsed_frame.opcode == frame.OPCODE.PING then
      local pong_frame = frame.create_pong_frame(parsed_frame.payload)
      client.tcp_handle:write(pong_frame)
    elseif parsed_frame.opcode == frame.OPCODE.PONG then
      client.last_pong = vim.loop.now()
    elseif parsed_frame.opcode == frame.OPCODE.CONTINUATION then
      -- Continuation frame - for simplicity, we don't support fragmentation.
      -- close_client before on_error so the Close frame reaches the peer (see
      -- the fatal-frame branch above for why ordering matters).
      M.close_client(client, 1003, "Unsupported data")
      on_error(client, "Fragmented messages not supported")
    else
      M.close_client(client, 1002, "Protocol error")
      on_error(client, "Unknown WebSocket opcode: " .. parsed_frame.opcode)
    end
  end
end

---Send a text message to a client
---@param client WebSocketClient The client object
---@param message string The message to send
---@param callback function? Optional callback: function(err)
function M.send_message(client, message, callback)
  if client.state ~= "connected" then
    if callback then
      callback("Client not connected")
    end
    return
  end

  local text_frame = frame.create_text_frame(message)
  client.tcp_handle:write(text_frame, callback)
end

---Send a ping to a client
---@param client WebSocketClient The client object
---@param data string|nil Optional ping data
function M.send_ping(client, data)
  if client.state ~= "connected" then
    return
  end

  local ping_frame = frame.create_ping_frame(data or "")
  client.tcp_handle:write(ping_frame)
  client.last_ping = vim.loop.now()
end

---Close a client connection
---@param client WebSocketClient The client object
---@param code number|nil Close code (default: 1000)
---@param reason string|nil Close reason
function M.close_client(client, code, reason)
  if client.state == "closed" or client.state == "closing" then
    return
  end

  code = code or 1000
  reason = reason or ""

  -- Defensive guard for callers that don't gate on client.state: if the
  -- underlying handle is already closing (e.g. a TCP error path closed it),
  -- writing a Close frame would target a dead handle and never reach the peer.
  -- Just mark the client closed in that case. Mirrors the is_closing() check
  -- in tcp.lua's _remove_client.
  if client.tcp_handle:is_closing() then
    client.state = "closed"
    return
  end

  if client.handshake_complete then
    local close_frame = frame.create_close_frame(code, reason)
    client.tcp_handle:write(close_frame, function()
      client.state = "closed"
      if not client.tcp_handle:is_closing() then
        client.tcp_handle:close()
      end
    end)
    -- Mark as "closing" while the Close frame write/teardown is in flight. The
    -- write callback transitions to "closed". Do not clobber the "closed" state
    -- set synchronously on the not-handshake-complete branch below.
    client.state = "closing"
  else
    client.state = "closed"
    client.tcp_handle:close()
  end
end

---Check if a client connection is alive
---@param client WebSocketClient The client object
---@param timeout number Timeout in milliseconds (default: 30000)
---@return boolean alive True if the client is considered alive
function M.is_client_alive(client, timeout)
  timeout = timeout or 30000 -- 30 seconds default

  if client.state ~= "connected" then
    return false
  end

  local now = vim.loop.now()
  return (now - client.last_pong) < timeout
end

---Get client info for debugging
---@param client WebSocketClient The client object
---@return table info Client information
function M.get_client_info(client)
  return {
    id = client.id,
    state = client.state,
    handshake_complete = client.handshake_complete,
    buffer_size = #client.buffer,
    last_ping = client.last_ping,
    last_pong = client.last_pong,
  }
end

return M
