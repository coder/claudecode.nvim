---@brief TCP server implementation using vim.loop
local client_manager = require("claudecode.server.client")

local M = {}

---@class TCPServer
---@field server table The vim.loop TCP server handle
---@field port number The port the server is listening on
---@field auth_token string|nil The authentication token for validating connections
---@field clients table<string, WebSocketClient> Table of connected clients
---@field on_message function Callback for WebSocket messages
---@field on_connect function Callback for new connections
---@field on_disconnect function Callback for client disconnections
---@field on_error fun(err_msg: string) Callback for errors

-- Seed Lua's PRNG exactly once per process. #282 removed the implicit seeding
-- that used to happen via utils.shuffle_array (math.randomseed(os.time())), which
-- left LuaJIT's fixed default seed in place -- so every fresh Neovim picked the
-- *same* starting port and parallel instances always collided (#283). Mixing in a
-- sub-second source avoids two instances launched in the same second seeding
-- identically. hrtime is guarded because some test stubs omit it.
local rng_seeded = false
local function ensure_rng_seeded()
  if rng_seeded then
    return
  end
  local jitter
  local ok, hr = pcall(function()
    return vim.loop and vim.loop.hrtime and vim.loop.hrtime()
  end)
  if ok and type(hr) == "number" then
    jitter = hr % 1000000
  else
    jitter = math.floor((os.clock() % 1) * 1000000)
  end
  math.randomseed((os.time() * 1000000) + jitter)
  rng_seeded = true
end

-- Iterate the port range exactly once, starting from a random offset and wrapping
-- around. Returns a closure rather than materializing the range: the default
-- 10000-65535 range is ~55k entries, and building/shuffling it on every startup
-- was the cost #282 set out to remove.
local function port_iterator(min_port, max_port)
  local port_count = max_port - min_port + 1
  if port_count <= 0 then
    return function()
      return nil
    end
  end
  ensure_rng_seeded()
  local start_offset = math.random(port_count) - 1
  local checked = -1
  return function()
    checked = checked + 1
    if checked >= port_count then
      return nil
    end
    return min_port + ((start_offset + checked) % port_count)
  end
end

---Find an available port using a best-effort bind probe.
---NOTE: this is only a pre-filter. A successful throwaway bind does NOT guarantee
---the port is free: libuv's bind() defers EADDRINUSE to listen()/connect(), so a
---port another process is actively listening on still passes this probe. The
---authoritative check is create_server's bind+listen with retry.
---@param min_port number Minimum port to try
---@param max_port number Maximum port to try
---@return number|nil port Available port number, or nil if none found
function M.find_available_port(min_port, max_port)
  assert(type(min_port) == "number", "min_port must be a number")
  assert(type(max_port) == "number", "max_port must be a number")

  if min_port > max_port then
    return nil
  end

  for port in port_iterator(min_port, max_port) do
    local test_server = vim.loop.new_tcp()
    if test_server then
      local success = test_server:bind("127.0.0.1", port)
      test_server:close()

      if success then
        return port
      end
    end
  end

  return nil
end

---Bind AND listen on a single fresh TCP handle, returning that same handle.
---Binding then listening on one socket (instead of probing a throwaway socket and
---re-binding) is what makes a busy port detectable: libuv's bind() defers
---EADDRINUSE to listen(), so the listen() call is the real test, and keeping the
---handle we listened on removes the probe/rebind TOCTOU window.
---@param server TCPServer The server object whose connection handler to wire up
---@param port number Port to bind and listen on
---@return table|nil handle The bound+listening TCP handle, or nil on failure
---@return string|nil error Error message if failed
function M._bind_and_listen(server, port)
  local handle = vim.loop.new_tcp()
  if not handle then
    return nil, "Failed to create TCP server"
  end

  local bind_success, bind_err = handle:bind("127.0.0.1", port)
  if not bind_success then
    handle:close()
    return nil, "Failed to bind to port " .. port .. ": " .. (bind_err or "unknown error")
  end

  local listen_success, listen_err = handle:listen(128, function(err)
    if err then
      server.on_error("Listen error: " .. err)
      return
    end

    M._handle_new_connection(server)
  end)

  if not listen_success then
    handle:close()
    return nil, "Failed to listen on port " .. port .. ": " .. (listen_err or "unknown error")
  end

  return handle, nil
end

---Create and start a TCP server
---@param config ClaudeCodeConfig Server configuration
---@param callbacks table Callback functions
---@param auth_token string|nil Authentication token for validating connections
---@return TCPServer|nil server The server object, or nil on error
---@return string|nil error Error message if failed
function M.create_server(config, callbacks, auth_token)
  local min_port = config.port_range.min
  local max_port = config.port_range.max

  -- Build the server object up front so the listen callback can close over it.
  local server = {
    server = nil,
    port = nil,
    auth_token = auth_token,
    clients = {},
    on_message = callbacks.on_message or function() end,
    on_connect = callbacks.on_connect or function() end,
    on_disconnect = callbacks.on_disconnect or function() end,
    on_error = callbacks.on_error or function() end,
  }

  -- Walk candidate ports and bind+listen on each until one succeeds. Retrying
  -- here (rather than committing to a single pre-probed port) is what fixes #283:
  -- when several Neovim instances race for the same port, the losers just advance
  -- to the next candidate instead of giving up with EADDRINUSE.
  local last_err
  local tried_any = false
  for port in port_iterator(min_port, max_port) do
    tried_any = true
    local handle, err = M._bind_and_listen(server, port)
    if handle then
      server.server = handle
      server.port = port
      return server, nil
    end
    last_err = err
  end

  if not tried_any then
    return nil, "No available ports in range " .. min_port .. "-" .. max_port
  end
  return nil,
    "Failed to bind to any port in range " .. min_port .. "-" .. max_port .. ": " .. (last_err or "unknown error")
end

---Handle a new client connection
---@param server TCPServer The server object
function M._handle_new_connection(server)
  local client_tcp = vim.loop.new_tcp()
  if not client_tcp then
    server.on_error("Failed to create client TCP handle")
    return
  end

  local accept_success, accept_err = server.server:accept(client_tcp)
  if not accept_success then
    server.on_error("Failed to accept connection: " .. (accept_err or "unknown error"))
    client_tcp:close()
    return
  end

  -- Create WebSocket client wrapper
  local client = client_manager.create_client(client_tcp)
  server.clients[client.id] = client

  -- Set up data handler
  client_tcp:read_start(function(err, data)
    if err then
      local error_msg = "Client read error: " .. err
      server.on_error(error_msg)
      M._disconnect_client(server, client, 1006, error_msg)
      return
    end

    if not data then
      -- EOF - client disconnected
      M._disconnect_client(server, client, 1006, "EOF")
      return
    end

    -- Process incoming data
    client_manager.process_data(client, data, function(cl, message)
      server.on_message(cl, message)
    end, function(cl, code, reason)
      M._disconnect_client(server, cl, code, reason)
    end, function(cl, error_msg)
      server.on_error("Client " .. cl.id .. " error: " .. error_msg)
      M._disconnect_client(server, cl, 1006, "Client error: " .. error_msg)
    end, server.auth_token)
  end)

  -- Notify about new connection
  server.on_connect(client)
end

---Disconnect a client and remove it from the server.
---This ensures `server.on_disconnect` is invoked for every disconnect path
---(EOF, read errors, protocol errors, timeouts), and only once per client.
---@param server TCPServer The server object
---@param client WebSocketClient The client to disconnect
---@param code number|nil WebSocket close code
---@param reason string|nil WebSocket close reason
function M._disconnect_client(server, client, code, reason)
  assert(type(server) == "table", "Expected server to be a table")
  local on_disconnect_type = type(server.on_disconnect)
  local on_disconnect_mt = on_disconnect_type == "table" and getmetatable(server.on_disconnect) or nil
  assert(
    on_disconnect_type == "function" or (on_disconnect_mt ~= nil and type(on_disconnect_mt.__call) == "function"),
    "Expected server.on_disconnect to be callable"
  )
  assert(type(server.clients) == "table", "Expected server.clients to be a table")
  assert(type(client) == "table", "Expected client to be a table")
  assert(type(client.id) == "string", "Expected client.id to be a string")
  if code ~= nil then
    assert(type(code) == "number", "Expected code to be a number")
  end
  if reason ~= nil then
    assert(type(reason) == "string", "Expected reason to be a string")
  end

  -- Idempotency: a client can hit multiple disconnect paths (e.g. CLOSE frame
  -- followed by a TCP EOF). Only notify/remove once.
  if not server.clients[client.id] then
    return
  end

  server.on_disconnect(client, code, reason)
  M._remove_client(server, client)
end

---Remove a client from the server
---@param server TCPServer The server object
---@param client WebSocketClient The client to remove
function M._remove_client(server, client)
  if server.clients[client.id] then
    server.clients[client.id] = nil

    if not client.tcp_handle:is_closing() then
      client.tcp_handle:close()
    end
  end
end

---Send a message to a specific client
---@param server TCPServer The server object
---@param client_id string The client ID
---@param message string The message to send
---@param callback function|nil Optional callback
function M.send_to_client(server, client_id, message, callback)
  local client = server.clients[client_id]
  if not client then
    if callback then
      callback("Client not found: " .. client_id)
    end
    return
  end

  client_manager.send_message(client, message, callback)
end

---Broadcast a message to all connected clients
---@param server TCPServer The server object
---@param message string The message to broadcast
function M.broadcast(server, message)
  for _, client in pairs(server.clients) do
    client_manager.send_message(client, message)
  end
end

---Get the number of connected clients
---@param server TCPServer The server object
---@return number count Number of connected clients
function M.get_client_count(server)
  local count = 0
  for _ in pairs(server.clients) do
    count = count + 1
  end
  return count
end

---Get information about all clients
---@param server TCPServer The server object
---@return table clients Array of client information
function M.get_clients_info(server)
  local clients = {}
  for _, client in pairs(server.clients) do
    table.insert(clients, client_manager.get_client_info(client))
  end
  return clients
end

---Close a specific client connection
---@param server TCPServer The server object
---@param client_id string The client ID
---@param code number|nil Close code
---@param reason string|nil Close reason
function M.close_client(server, client_id, code, reason)
  local client = server.clients[client_id]
  if client then
    client_manager.close_client(client, code, reason)
  end
end

---Stop the TCP server
---@param server TCPServer The server object
function M.stop_server(server)
  -- Close all clients
  for _, client in pairs(server.clients) do
    client_manager.close_client(client, 1001, "Server shutting down")
  end

  -- Clear clients
  server.clients = {}

  -- Close server
  if server.server and not server.server:is_closing() then
    server.server:close()
  end
end

---Start a periodic ping task to keep connections alive
---@param server TCPServer The server object
---@param interval number Ping interval in milliseconds (default: 30000)
---@return table? timer The timer handle, or nil if creation failed
function M.start_ping_timer(server, interval)
  interval = interval or 30000 -- 30 seconds
  local last_run = vim.loop.now()

  local timer = vim.loop.new_timer()
  if not timer then
    server.on_error("Failed to create ping timer")
    return nil
  end

  timer:start(interval, interval, function()
    local now = vim.loop.now()
    local elapsed = now - last_run

    -- Detect potential system sleep: timer interval was significantly exceeded
    -- Allow 50% grace period (e.g., 45s instead of 30s) to account for system load
    local is_wake_from_sleep = elapsed > (interval * 1.5)

    if is_wake_from_sleep then
      -- After system sleep/wake, reset all client pong timestamps to prevent false timeouts
      -- This gives clients a fresh keepalive window since the time jump isn't their fault
      require("claudecode.logger").debug(
        "server",
        string.format(
          "Detected potential wake from sleep (%.1fs elapsed), resetting client keepalive timers",
          elapsed / 1000
        )
      )
      for _, client in pairs(server.clients) do
        if client.state == "connected" then
          client.last_pong = now
        end
      end
    end

    for _, client in pairs(server.clients) do
      if client.state == "connected" then
        -- Check if client is alive (local connections, so use standard timeout)
        if client_manager.is_client_alive(client, interval * 2) then
          client_manager.send_ping(client, "ping")
        else
          -- Client connection timed out - log at INFO level (this is expected behavior)
          local time_since_pong = math.floor((now - client.last_pong) / 1000)
          require("claudecode.logger").info(
            "server",
            string.format("Client %s keepalive timeout (%ds idle), closing connection", client.id, time_since_pong)
          )
          client_manager.close_client(client, 1006, "Connection timeout")
          M._disconnect_client(server, client, 1006, "Connection timeout")
        end
      end
    end

    last_run = now
  end)

  return timer
end

return M
