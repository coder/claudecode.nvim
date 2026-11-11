---@brief WebSocket client connection management
local frame = require("claudecode.server.frame")
local handshake = require("claudecode.server.handshake")
local logger = require("claudecode.logger")
local server_utils = require("claudecode.server.utils")
local utils = require("claudecode.utils")

local M = {}

-- The reason text of each RFC 6455 status the server closes with (section 7.4.1).
local CLOSE_REASONS = {
  [1002] = "Protocol error",
  [1003] = "Unsupported data",
  [1007] = "Invalid frame payload data",
  [1009] = "Message too big",
}

-- Diffs remember the id of the client that opened them after it disconnects, so an id must never
-- come back. A handle's address can: libuv reuses the memory of a collected handle. The count lives
-- in _G because reloading this module would reset a local while the diff module keeps the old ids.

---@class WebSocketClient
---@field id string Unique client identifier
---@field tcp_handle table The vim.loop TCP handle
---@field state string Connection state: "connecting", "upgrading" (its 101 reply is being written), "connected", "closing", "closed"
---@field buffer string Incoming data buffer
---@field pending table|nil The reads of an incomplete frame, with their total length in `size` and the frame's in `needed`
---@field fragments table|nil Joined pieces of the text message whose last fragment has not arrived, and their total `size`
---@field handshake_complete boolean Whether WebSocket handshake is complete
---@field close_pending boolean|nil True while a Close frame waits to be written: its write callback closes the socket, or its deadline does
---@field close_timer table|nil The deadline of the Close frame: a repeating timer that runs while `close_pending` is set
---@field keepalive_timeout number|nil The window in milliseconds for a pong and for write progress, from the server's ping interval
---@field connected_at number|nil When the WebSocket handshake completed (vim.loop.now())
---@field last_ping number Timestamp of last ping sent
---@field last_pong number Timestamp of last pong received
---@field queued_bytes integer The bytes passed to the socket's write queue since the connection began
---@field drained_bytes integer The bytes libuv had written to the socket when `sample_write_progress` last saw progress
---@field last_drain number Timestamp of the last `sample_write_progress` check that found the write queue empty or smaller
---@field write_stalled boolean|nil True after a ping tick found no write progress. The next such tick asks for a look after the next poll, and only that look drops the client
---@field pong_overdue boolean|nil True after a ping timer tick found no pong for two intervals. The next such tick drops the client

---Create a new WebSocket client
---@param tcp_handle table The vim.loop TCP handle
---@param keepalive_timeout number|nil The window in milliseconds that the server's ping timer allows for a pong and for write progress. Without it the client has no deadline for its Close frame
---@return WebSocketClient client The client object
function M.create_client(tcp_handle, keepalive_timeout)
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
    queued_bytes = 0,
    drained_bytes = 0,
    last_drain = vim.loop.now(),
    keepalive_timeout = keepalive_timeout,
  }

  return client
end

-- The size of one write request for a large frame. libuv lowers the size of a socket's write queue by the bytes it wrote
-- on Linux and macOS, but on Windows only by a whole request when it is done. Queued in pieces, a large frame shows its
-- progress there too, and `is_client_reading` does not take a Claude that reads it for a stalled one.
local WRITE_PIECE_BYTES = 1024 * 1024

---Write to the socket of a client. Every write goes through here, so `queued_bytes` counts them all: the bytes still in
---libuv's write queue are `queued_bytes - drained_bytes`, and `is_client_reading` tells a stalled queue from a slow one.
---A frame of more than `WRITE_PIECE_BYTES` is queued in pieces. libuv finishes the requests of a socket in order, so the
---callback of the last piece says that the whole frame is written, or that a piece failed. A piece that libuv refuses at
---once ends the frame there.
---@param client WebSocketClient
---@param data string
---@param callback function? Optional callback: function(err)
---@return any queued, string|nil err What `tcp_handle:write` returned for the request that carries the callback
local function write(client, data, callback)
  client.queued_bytes = client.queued_bytes + #data
  if #data <= WRITE_PIECE_BYTES then
    return client.tcp_handle:write(data, callback)
  end
  local queued, err
  for first = 1, #data, WRITE_PIECE_BYTES do
    local last_piece = first + WRITE_PIECE_BYTES > #data
    queued, err =
      client.tcp_handle:write(data:sub(first, first + WRITE_PIECE_BYTES - 1), last_piece and callback or nil)
    if not queued and err then
      -- The frame is cut short, and the callback rides on the last piece: no later piece may follow, and the caller
      -- hears the error here.
      return nil, err
    end
  end
  return queued, err
end

---Stop the deadline of the Close frame. Safe to call when none runs.
---@param client WebSocketClient
local function stop_close_timer(client)
  local timer = client.close_timer
  if timer then
    client.close_timer = nil
    timer:stop()
    timer:close()
  end
end

---Start the deadline of a Close frame that was just queued. The ping timer sees only the clients in the server's list,
---and a client that broke the protocol, or that the server stopped, has left it with its frame still queued. A socket
---that wrote no byte for a keepalive window is closed, and the queue with it, as for the ping timer. The window starts
---with the frame, and a Claude that reads keeps the socket open. One window without progress is enough here: the client
---is leaving already, so a close that comes too early after a blocked loop costs only its Close frame.
---@param client WebSocketClient
local function start_close_timer(client)
  local timeout = client.keepalive_timeout
  -- Not when the write callback already ran: the frame is written and the socket is closed.
  if not timeout or not client.close_pending then
    return
  end
  local timer = vim.loop.new_timer()
  if not timer then
    return
  end
  stop_close_timer(client)
  client.close_timer = timer
  client.drained_bytes = client.queued_bytes - client.tcp_handle:get_write_queue_size()
  client.last_drain = vim.loop.now()
  timer:start(timeout, timeout, function()
    -- The write callback, a drop by the ping timer, or a close of the handle ended the wait: stop, and touch nothing.
    -- Whichever of this callback and the write callback runs first closes the socket, and the other finds it closed.
    if client.close_timer ~= timer then
      return
    end
    local handle = client.tcp_handle
    if not client.close_pending or handle:is_closing() then
      stop_close_timer(client)
    elseif not M.sample_write_progress(client) then
      stop_close_timer(client)
      client.close_pending = nil
      client.state = "closed"
      handle:close()
    end
  end)
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
  if data_frame.opcode ~= frame.OPCODE.CONTINUATION and fragments then
    return nil, 1002, "Data frame inside another message"
  elseif data_frame.opcode == frame.OPCODE.BINARY then
    return nil, 1003, "Binary messages not supported"
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

---Close a connection after a protocol error, and report its client at once. The Close frame is written before the
---socket closes: its write callback closes the socket, and nothing else may close it before (see `close_pending`).
---The client must not wait for that write: a Claude that does not read would keep it in `server.clients` until it does.
---@param client WebSocketClient
---@param status integer The RFC 6455 status to close with
---@param problem string What broke the protocol, short enough for one line of :messages
---@param on_error function Callback for errors: function(client, error_msg)
local function fail_connection(client, status, problem, on_error)
  client.buffer = ""
  M.close_client(client, status, CLOSE_REASONS[status])
  on_error(client, problem)
end

---Process incoming data for a client
---@param client WebSocketClient The client object
---@param data string The incoming data
---@param on_message function Callback for complete messages: function(client, message_text)
---@param on_close function Callback for client close: function(client, code, reason)
---@param on_error function Callback for errors: function(client, error_msg)
---@param auth_token string|nil Expected authentication token for validation
---@param on_open function|nil Callback once the WebSocket handshake completed: function(client)
function M.process_data(client, data, on_message, on_close, on_error, auth_token, on_open)
  -- Nothing more is parsed from a client that is closing, so none of its bytes are kept either.
  if client.state == "closing" or client.state == "closed" then
    client.buffer, client.pending = "", nil
    return
  end

  -- A frame longer than one read arrives in many. Joining each read onto the bytes before it copies them all every
  -- time, so the reads of an incomplete frame wait in a list until the whole frame is there.
  local pending = client.pending
  if pending then
    table.insert(pending, data)
    pending.size = pending.size + #data
    if pending.size < pending.needed then
      return
    end
    client.pending = nil
    client.buffer = table.concat(pending)
  else
    client.buffer = client.buffer .. data
  end

  if not client.handshake_complete then
    -- Bytes that arrive while the 101 reply is written are frames. They wait for the write callback.
    if client.state == "upgrading" then
      return
    end
    local complete, request, remaining = handshake.extract_http_request(client.buffer)
    if complete and request then
      client.buffer = remaining
      logger.debug("client", "Processing WebSocket handshake for client:", client.id)

      -- Log if auth token is required
      if auth_token then
        logger.debug("client", "Authentication required for client:", client.id)
      else
        logger.debug("client", "No authentication required for client:", client.id)
      end

      local success, response_from_handshake, _ = handshake.process_handshake(request, auth_token)
      local rejection

      -- Log authentication results
      if success then
        client.state = "upgrading"
        if auth_token then
          logger.debug("client", "Client authenticated successfully:", client.id)
        else
          logger.debug("client", "Client handshake completed (no auth required):", client.id)
        end
      else
        -- The body of the error response says why.
        local body = response_from_handshake:match("\r\n\r\n(.+)$") or "Bad handshake"
        rejection = body:gsub("^Bad WebSocket upgrade request: ", "")
        logger.one_line("warn", "client", "Rejected " .. client.id .. ": " .. rejection)
        client.state = "closing"
      end

      write(client, response_from_handshake, function(err)
        if err or not success then
          -- on_error removes the client from the server and closes its socket. A server that stopped while the reply
          -- was written has already dropped the client, so the socket is closed here too.
          on_error(client, err and "Failed to send handshake response: " .. err or "Rejected: " .. rejection)
          if not client.tcp_handle:is_closing() then
            client.tcp_handle:close()
          end
          return
        end

        -- The client hung up, or the server stopped, while the reply was written. The frames it sent with its request
        -- must not run.
        if client.state ~= "upgrading" or client.tcp_handle:is_closing() then
          client.buffer, client.pending = "", nil
          return
        end
        client.handshake_complete = true
        client.state = "connected"
        -- The keepalive window starts now. The ping timer ignores a client that is not connected, so the main loop can
        -- block between the accept and this point for longer than the timeout, and no ping reached this client yet.
        client.last_pong = vim.loop.now()
        -- init.lua sends queued @ mentions only once some connected client has been connected for
        -- connection_wait_delay ms since this point. The broadcast then also reaches clients that connected later.
        client.connected_at = client.last_pong
        logger.debug("client", "WebSocket connection established for client:", client.id)
        if on_open then
          on_open(client)
        end

        if #client.buffer > 0 then
          M.process_data(client, "", on_message, on_close, on_error, auth_token, on_open)
        end
      end)
    end
    return
  end

  -- Parse from an offset and cut the buffer once at the end: cutting it after each frame copies the rest of the
  -- buffer every time, which costs quadratic time for many small frames in one read.
  local offset = 1
  local frame_length
  while #client.buffer - offset >= 1 do -- Minimum frame size is 2 bytes
    -- Stop if a prior frame (or a TCP error) already initiated teardown. The
    -- handle can still be open (Close-frame write / scheduled on_close/on_error
    -- pending) and read is not stopped, so a later TCP segment could otherwise
    -- re-enter process_data and dispatch frames against a closing/closed client.
    if client.state == "closing" or client.state == "closed" then
      break
    end

    local parsed_frame, bytes_consumed, close_code, detail = frame.parse_frame(client.buffer, offset)

    if not parsed_frame then
      if close_code then
        -- Fatal protocol violation: send the RFC 6455 Close frame, drop the
        -- offending bytes (so they are not re-parsed forever, which previously
        -- wedged the connection), and tear the connection down.
        fail_connection(client, close_code, detail, on_error)
      else
        frame_length = detail -- The frame is incomplete. Its length is known once its header arrived.
      end
      break
    end

    offset = offset + bytes_consumed

    -- parse_frame rejects every opcode but the six handled here with 1002, so no other opcode gets this far.
    local opcode = parsed_frame.opcode
    if opcode == frame.OPCODE.TEXT or opcode == frame.OPCODE.BINARY or opcode == frame.OPCODE.CONTINUATION then
      local message, status, problem = add_data_frame(client, parsed_frame)
      if message then
        vim.schedule(function()
          -- A client that hung up or closed before the main loop got here gets no reply, and its request must not
          -- change the editor either.
          if client.state == "connected" and not client.tcp_handle:is_closing() then
            on_message(client, message)
          end
        end)
      elseif status then
        fail_connection(client, status, problem, on_error)
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
        write(client, close_frame)
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
      write(client, pong_frame)
    elseif opcode == frame.OPCODE.PONG then
      client.last_pong = vim.loop.now()
    end
  end
  client.buffer = client.buffer:sub(offset)
  if frame_length then
    client.pending = { client.buffer, size = #client.buffer, needed = frame_length }
    client.buffer = ""
  end
end

---Send a text message to a client
---@param client WebSocketClient The client object
---@param message string The message to send
---@param callback function? Optional callback: function(err), run once when the write finished or failed
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
  -- libuv runs the callback only for a write it queued. A write it refuses at once returns nil and the error, and
  -- never runs the callback, so the caller hears about that failure here.
  local queued, err = write(client, text_frame, callback)
  if not queued and err and callback then
    callback(err)
  end
end

---Send a ping to a client
---@param client WebSocketClient The client object
---@param data string|nil Optional ping data
function M.send_ping(client, data)
  if client.state ~= "connected" then
    return
  end

  local ping_frame = frame.create_ping_frame(data or "")
  write(client, ping_frame)
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
  -- Nothing more is parsed from a closing client, so its unparsed bytes can go now.
  client.buffer, client.pending = "", nil

  -- Defensive guard for callers that don't gate on client.state: if the
  -- underlying handle is already closing (e.g. a TCP error path closed it),
  -- writing a Close frame would target a dead handle and never reach the peer.
  -- Just mark the client closed in that case. Mirrors the is_closing() check
  -- in tcp.lua's _remove_client.
  if client.tcp_handle:is_closing() then
    client.state = "closed"
    return
  end

  -- An upgrading client gets the Close frame too: libuv writes it after the 101 reply that is still queued.
  if client.handshake_complete or client.state == "upgrading" then
    local close_frame = frame.create_close_frame(code, reason)
    -- The write callback closes the socket, so nothing may close it first: that would cancel the frame. libuv invokes
    -- the callback on success, on error and when the socket closes, so the socket is never left open. A Claude that
    -- does not read can keep the frame in the queue for good: the deadline closes the socket then.
    client.close_pending = true
    write(client, close_frame, function()
      client.close_pending = nil
      stop_close_timer(client)
      client.state = "closed"
      if not client.tcp_handle:is_closing() then
        client.tcp_handle:close()
      end
    end)
    start_close_timer(client)
    -- Mark as "closing" while the Close frame write/teardown is in flight. The
    -- write callback transitions to "closed". Do not clobber the "closed" state
    -- set synchronously on the not-handshake-complete branch below.
    client.state = "closing"
  else
    client.state = "closed"
    client.tcp_handle:close()
  end
end

---Stop waiting for the write of a Close frame, because the caller closes the socket at once.
---@param client WebSocketClient The client object
function M.abandon_close_frame(client)
  client.close_pending = nil
  stop_close_timer(client)
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

---Check whether libuv wrote a byte of the write queue of a client since the last check that saw progress, or the queue
---is empty. A client that reads slowly makes progress, and so does one that is sent a single large message, however big.
---@param client WebSocketClient The client object
---@return boolean progress False when the queue is not empty and nothing of it was written since the last progress
function M.sample_write_progress(client)
  local queue_size = client.tcp_handle:get_write_queue_size()
  local drained = client.queued_bytes - queue_size
  if queue_size == 0 or drained > client.drained_bytes then
    client.drained_bytes, client.last_drain = drained, vim.loop.now()
    return true
  end
  return false
end

---Check that a client still reads what the server writes to it. The keepalive cannot tell: a Claude whose reader is
---stuck can still answer each ping, while replies and pings pile up in libuv's write queue, in Neovim's memory.
---Call it once per ping tick. A tick can run before libuv reported the bytes that Claude read during a main-loop block,
---so a tick never drops a client. A tick that finds progress, or an empty queue, clears the count. The first that finds
---none sets it, and the second returns false. `tcp.lua` then looks once more right after the next poll, and only that
---look drops the client.
---@param client WebSocketClient The client object
---@return boolean reading False when this tick, and the one before it, found no write progress
function M.is_client_reading(client)
  if M.sample_write_progress(client) then
    client.write_stalled = nil
    return true
  end
  if client.write_stalled then
    return false
  end
  client.write_stalled = true
  return true
end

---Get client info for debugging
---@param client WebSocketClient The client object
---@return table info Client information
function M.get_client_info(client)
  return {
    id = client.id,
    state = client.state,
    handshake_complete = client.handshake_complete,
    buffer_size = #client.buffer + (client.pending and client.pending.size or 0),
    last_ping = client.last_ping,
    last_pong = client.last_pong,
    connected_at = client.connected_at,
  }
end

return M
