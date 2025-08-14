---@brief TCP server implementation using vim.loop
local client_manager = require("claudecode.server.client")
local utils = require("claudecode.server.utils")
local safe_tcp = require("claudecode.server.safe_tcp")
local logger = require("claudecode.logger")

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

---Find an available port by attempting to bind
---@param min_port number Minimum port to try
---@param max_port number Maximum port to try
---@return number|nil port Available port number, or nil if none found
function M.find_available_port(min_port, max_port)
  if min_port > max_port then
    return nil
  end

  -- On Windows, scanning too many ports is slow
  -- Use a smaller range and random starting point
  local range_size = max_port - min_port + 1
  local max_attempts = math.min(100, range_size) -- Limit attempts to 100
  
  -- Use a random starting point instead of shuffling entire range
  math.randomseed(os.time() + vim.loop.now())
  local start_offset = math.random(0, range_size - 1)
  
  -- Try ports in a circular manner from random start
  for i = 0, max_attempts - 1 do
    local port = min_port + ((start_offset + i) % range_size)
    
    local test_server = vim.loop.new_tcp()
    if test_server then
      -- Use pcall to handle potential errors
      local ok, success = pcall(function()
        return test_server:bind("127.0.0.1", port)
      end)
      
      -- Always close the test server
      pcall(test_server.close, test_server)
      
      if ok and success then
        logger.debug("tcp", "Found available port:", port)
        return port
      end
    end
  end
  
  logger.warn("tcp", "No available port found after", max_attempts, "attempts")
  return nil
end

---Create and start a TCP server
---@param config ClaudeCodeConfig Server configuration
---@param callbacks table Callback functions
---@param auth_token string|nil Authentication token for validating connections
---@return TCPServer|nil server The server object, or nil on error
---@return string|nil error Error message if failed
function M.create_server(config, callbacks, auth_token)
  local port = M.find_available_port(config.port_range.min, config.port_range.max)
  if not port then
    return nil, "No available ports in range " .. config.port_range.min .. "-" .. config.port_range.max
  end

  local tcp_server = vim.loop.new_tcp()
  if not tcp_server then
    return nil, "Failed to create TCP server"
  end
  
  -- Apply Windows optimizations if available
  if config.windows_optimizations and vim.loop.os_uname().sysname:match("Windows") then
    -- Set TCP_NODELAY to disable Nagle's algorithm for lower latency
    if config.windows_optimizations.tcp_nodelay then
      pcall(tcp_server.tcp_nodelay, tcp_server, true)
    end
    -- Note: SO_REUSEADDR is set by default in libuv
  end

  -- Create server object
  local server = {
    server = tcp_server,
    port = port,
    auth_token = auth_token,
    clients = {},
    on_message = callbacks.on_message or function() end,
    on_connect = callbacks.on_connect or function() end,
    on_disconnect = callbacks.on_disconnect or function() end,
    on_error = callbacks.on_error or function() end,
  }

  -- Use 0.0.0.0 on Windows for faster binding, 127.0.0.1 on others
  local bind_addr = "127.0.0.1"
  if vim.loop.os_uname().sysname:match("Windows") then
    -- On Windows, binding to 127.0.0.1 can be slower due to DNS resolution
    -- But for security, we still use 127.0.0.1
    bind_addr = "127.0.0.1"
  end
  
  local bind_success, bind_err = tcp_server:bind(bind_addr, port)
  if not bind_success then
    tcp_server:close()
    return nil, "Failed to bind to port " .. port .. ": " .. (bind_err or "unknown error")
  end

  -- Start listening with smaller backlog on Windows for faster startup
  local backlog = 128
  if vim.loop.os_uname().sysname:match("Windows") then
    backlog = 32  -- Smaller backlog for faster startup on Windows
  end
  
  local listen_success, listen_err = tcp_server:listen(backlog, function(err)
    if err then
      callbacks.on_error("Listen error: " .. err)
      return
    end

    M._handle_new_connection(server)
  end)

  if not listen_success then
    tcp_server:close()
    return nil, "Failed to listen on port " .. port .. ": " .. (listen_err or "unknown error")
  end

  return server, nil
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

  -- Set up data handler with error protection
  safe_tcp.safe_read_start(client_tcp, function(err, data)
    -- Wrap entire handler in pcall to prevent stack errors
    local handler_success, handler_error = pcall(function()
      if err then
        safe_tcp.record_error("tcp_errors", err)
        server.on_error("Client read error: " .. err)
        M._remove_client(server, client)
        return
      end

      if not data then
        -- EOF - client disconnected
        M._remove_client(server, client)
        return
      end

      -- Process incoming data with safe callbacks
      local process_success, process_error = pcall(client_manager.process_data, 
        client, data,
        function(cl, message)
          safe_tcp.safe_schedule(function()
            server.on_message(cl, message)
          end, "tcp_on_message")
        end,
        function(cl, code, reason)
          safe_tcp.safe_schedule(function()
            server.on_disconnect(cl, code, reason)
            M._remove_client(server, cl)
          end, "tcp_on_disconnect")
        end,
        function(cl, error_msg)
          safe_tcp.safe_schedule(function()
            server.on_error("Client " .. cl.id .. " error: " .. error_msg)
            M._remove_client(server, cl)
          end, "tcp_on_error")
        end,
        server.auth_token
      )
      
      if not process_success then
        logger.error("tcp", "Data processing failed for client", client.id, ":", tostring(process_error))
        safe_tcp.record_error("callback_errors", tostring(process_error))
        M._remove_client(server, client)
      end
    end)
    
    if not handler_success then
      logger.error("tcp", "Read handler failed:", tostring(handler_error))
      safe_tcp.record_error("callback_errors", tostring(handler_error))
    end
  end)

  -- Notify about new connection
  server.on_connect(client)
end

---Remove a client from the server
---@param server TCPServer The server object
---@param client WebSocketClient The client to remove
function M._remove_client(server, client)
  if not client or not client.id then
    return
  end
  
  if server.clients[client.id] then
    server.clients[client.id] = nil
    
    -- Use safe cleanup to prevent errors
    safe_tcp.graceful_client_cleanup(client, "removed_from_server")
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
  -- Close all clients gracefully
  for _, client in pairs(server.clients) do
    pcall(client_manager.close_client, client, 1001, "Server shutting down")
  end

  -- Clear clients
  server.clients = {}

  -- Close server safely
  if server.server then
    safe_tcp.safe_close(server.server)
  end
end

---Start a periodic ping task to keep connections alive
---@param server TCPServer The server object
---@param interval number Ping interval in milliseconds (default: 30000)
---@return table? timer The timer handle, or nil if creation failed
function M.start_ping_timer(server, interval)
  -- Use shorter ping interval on Windows for faster disconnect detection
  if vim.loop.os_uname().sysname:match("Windows") then
    interval = interval or 20000 -- 20 seconds on Windows
  else
    interval = interval or 30000 -- 30 seconds on other platforms
  end

  local ping_callback = function()
    -- Wrap ping logic in pcall to prevent timer failures
    local success, err = pcall(function()
      for _, client in pairs(server.clients) do
        if client.state == "connected" then
          -- Check if client is alive
          if client_manager.is_client_alive(client, interval * 2) then
            client_manager.send_ping(client, "ping")
          else
            -- Client appears dead, close it
            logger.debug("tcp", "Client", client.id, "appears dead, closing")
            client_manager.close_client(client, 1006, "Connection timeout")
            M._remove_client(server, client)
          end
        end
      end
    end)
    
    if not success then
      logger.error("tcp", "Ping timer callback failed:", tostring(err))
      safe_tcp.record_error("callback_errors", tostring(err))
    end
  end

  return safe_tcp.safe_timer(ping_callback, interval, interval)
end

return M
