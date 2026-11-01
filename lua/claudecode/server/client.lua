---@brief WebSocket client connection management
local frame = require("claudecode.server.frame")
local handshake = require("claudecode.server.handshake")
local logger = require("claudecode.logger")
local server_utils = require("claudecode.server.utils")
local utils = require("claudecode.utils")

local M = {}

-- Diffs remember the id of the client that opened them after it disconnects, so an id must never
-- come back. A handle's address can: libuv reuses the memory of a collected handle. The count lives
-- in _G because reloading this module would reset a local while the diff module keeps the old ids.

---@class WebSocketClient
---@field id string Unique client identifier
---@field tcp_handle table The vim.loop TCP handle
---@field state string Connection state: "connecting", "connected", "closing", "closed"
---@field buffer string Incoming data buffer
---@field fragments table|nil Joined pieces of the text message whose last fragment has not arrived, and their total `size`
---@field handshake_complete boolean Whether WebSocket handshake is complete
---@field last_ping number Timestamp of last ping sent
---@field last_pong number Timestamp of last pong received

---Create a new WebSocket client
---@param tcp_handle table The vim.loop TCP handle
---@return WebSocketClient client The client object
function M.create_client(tcp_handle)
  _G.claudecode_clients_created = (_G.claudecode_clients_created or 0) + 1
  local client_id = "client_" .. _G.claudecode_clients_created

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

---Adds a data frame to the message the client is sending. A text message arrives as one TEXT frame with FIN set, or
---as fragments: a TEXT frame with FIN clear, then CONTINUATION frames up to one with FIN set. A fragment may end
---inside a code point, so only the whole text is checked for UTF-8.
---@param client WebSocketClient
---@param data_frame WebSocketFrame A TEXT, BINARY or CONTINUATION frame
---@return string|nil message The whole text message, once its last fragment arrived
---@return integer|nil status The RFC 6455 status to close with when the frame breaks the protocol
---@return string|nil problem What broke it, short enough for one line of :messages
local function add_data_frame(client, data_frame)
  local fragments = client.fragments
  if data_frame.opcode == frame.OPCODE.BINARY then
    return nil, 1003, "Binary messages not supported"
  elseif data_frame.opcode == frame.OPCODE.TEXT and fragments then
    return nil, 1002, "Text frame inside another message"
  elseif data_frame.opcode == frame.OPCODE.CONTINUATION and not fragments then
    return nil, 1002, "Unexpected continuation frame"
  end
  fragments = fragments or { size = 0 }
  fragments.size = fragments.size + #data_frame.payload
  if fragments.size > frame.MAX_PAYLOAD_LENGTH then
    return nil, 1009, "WebSocket message too big"
  end
  -- Join each piece onto the one below it while that one is not longer, as a binary counter carries. Many tiny
  -- or empty fragments then keep O(log n) strings, not one table entry each.
  table.insert(fragments, data_frame.payload)
  for i = #fragments - 1, 1, -1 do
    if #fragments[i] > #fragments[i + 1] then
      break
    end
    fragments[i] = fragments[i] .. table.remove(fragments)
  end
  if not data_frame.fin then
    client.fragments = fragments
    return nil
  end
  client.fragments = nil
  local message = table.concat(fragments)
  if not server_utils.is_valid_utf8(message) then
    return nil, 1007, "Invalid UTF-8 in text message"
  end
  return message
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
    -- Stop if a prior frame (or a TCP error) already initiated teardown. The
    -- handle can still be open (Close-frame write / scheduled on_close/on_error
    -- pending) and read is not stopped, so a later TCP segment could otherwise
    -- re-enter process_data and dispatch frames against a closing/closed client.
    if client.state == "closing" or client.state == "closed" then
      break
    end

    local parsed_frame, bytes_consumed, close_code = frame.parse_frame(client.buffer)

    if not parsed_frame then
      if close_code then
        -- Fatal protocol violation: send the RFC 6455 Close frame, drop the
        -- offending bytes (so they are not re-parsed forever, which previously
        -- wedged the connection), and tear the connection down.
        --
        -- on_error runs the synchronous teardown (tcp.lua _disconnect_client ->
        -- _remove_client -> tcp_handle:close()), which would cancel the pending
        -- Close-frame write if it ran first. Passing it as close_client's on_done
        -- runs it from the write callback, i.e. only after the status code has
        -- been flushed, so the peer actually receives the 1002/1007/1009 close.
        client.buffer = ""
        M.close_client(client, close_code, "Protocol error", function()
          on_error(client, "WebSocket protocol error in frame")
        end)
      end
      break -- No close_code means the frame is incomplete; wait for more bytes.
    end

    client.buffer = client.buffer:sub(bytes_consumed + 1)

    local opcode = parsed_frame.opcode
    if opcode == frame.OPCODE.TEXT or opcode == frame.OPCODE.BINARY or opcode == frame.OPCODE.CONTINUATION then
      local message, status, problem = add_data_frame(client, parsed_frame)
      if message then
        vim.schedule(function()
          on_message(client, message)
        end)
      elseif status then
        -- Same teardown as a fatal frame above: on_error runs only after the Close frame is written.
        client.buffer = ""
        M.close_client(client, status, status == 1003 and "Unsupported data" or "Protocol error", function()
          on_error(client, problem)
        end)
        break
      end
    elseif opcode == frame.OPCODE.CLOSE then
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
      -- A CLOSE is terminal: drop any bytes that followed it (a frame after CLOSE
      -- is a protocol violation) and stop iterating, so we neither echo a PONG
      -- after our own Close nor dispatch on_message after on_close. Matches the
      -- other termination branches.
      client.buffer = ""
      break
    elseif opcode == frame.OPCODE.PING then
      local pong_frame = frame.create_pong_frame(parsed_frame.payload)
      client.tcp_handle:write(pong_frame)
    elseif opcode == frame.OPCODE.PONG then
      client.last_pong = vim.loop.now()
    else
      M.close_client(client, 1002, "Protocol error", function()
        on_error(client, "Unknown WebSocket opcode: " .. opcode)
      end)
      client.buffer = ""
      break
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

  -- Every outbound message passes here. A buffer name or path in it can hold any bytes, and the client drops the
  -- connection on a text frame that is not valid UTF-8.
  local text_frame = frame.create_text_frame(utils.valid_utf8(message))
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
---@param on_done function|nil Optional callback run after the Close frame has been
---  written (or once the connection is already gone). Protocol-violation paths use
---  it to defer error/teardown until the status code has actually been flushed.
function M.close_client(client, code, reason, on_done)
  if client.state == "closed" or client.state == "closing" then
    if on_done then
      vim.schedule(on_done)
    end
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
    if on_done then
      vim.schedule(on_done)
    end
    return
  end

  if client.handshake_complete then
    local close_frame = frame.create_close_frame(code, reason)
    client.tcp_handle:write(close_frame, function()
      client.state = "closed"
      if not client.tcp_handle:is_closing() then
        client.tcp_handle:close()
      end
      -- Run any teardown only after the Close frame has been flushed, so a
      -- caller's synchronous handle close cannot cancel the pending write. libuv
      -- always invokes this callback (on success or error), so on_done is never
      -- dropped.
      if on_done then
        on_done()
      end
    end)
    -- Mark as "closing" while the Close frame write/teardown is in flight. The
    -- write callback transitions to "closed". Do not clobber the "closed" state
    -- set synchronously on the not-handshake-complete branch below.
    client.state = "closing"
  else
    client.state = "closed"
    client.tcp_handle:close()
    if on_done then
      vim.schedule(on_done)
    end
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
