---@brief [[
--- Mock WebSocket server implementation for testing.
--- This module provides a minimal implementation of the WebSocket server
--- functionality, suitable for testing or when real WebSocket connections
--- are not available or needed.
---@brief ]]

local M = {}
local tools = require("claudecode.tools.init")

--- Mock server state
M.state = {
  server = nil,
  port = nil,
  clients = {},
  handlers = {},
  messages = {}, -- Store messages for testing
}

---Find an available port in the given range
---@param min number The minimum port number
---@param max number The maximum port number
---@return number port The selected port
function M.find_available_port(min, max)
  -- For mock implementation, just return the minimum port
  -- In a real implementation, this would scan for available ports in the range
  return min
end

---Start the WebSocket server
---@param config table Configuration options
---@return boolean success Whether the server started successfully
---@return number|string port_or_error The port number or error message
function M.start(config)
  if M.state.server then
    -- Already running
    return false, "Server already running"
  end

  -- Find an available port
  local port = M.find_available_port(config.port_range.min, config.port_range.max)

  if not port then
    return false, "No available ports found"
  end

  -- Store the port in state
  M.state.port = port

  -- Create mock server object
  M.state.server = {
    port = port,
    clients = {},
    on_message = function() end,
    on_connect = function() end,
    on_disconnect = function() end,
  }

  -- Register message handlers
  M.register_handlers()

  return true, port
end

---Stop the WebSocket server
---@return boolean success Whether the server stopped successfully
---@return string|nil error Error message if failed
function M.stop()
  if not M.state.server then
    -- Not running
    return false, "Server not running"
  end

  -- Reset state
  M.state.server = nil
  M.state.port = nil
  M.state.clients = {}
  M.state.messages = {}

  return true
end

--- Register message handlers
function M.register_handlers()
  -- Default handlers
  M.state.handlers = {
    ["mcp.connect"] = function(client, params)
      -- Handle connection handshake
      -- Parameters not used in this mock implementation
      return { result = { message = "Connection established" } }
    end,

    ["mcp.tool.invoke"] = function(client, params)
      -- Handle tool invocation by dispatching to tools implementation
      return tools.handle_invoke(client, params)
    end,
  }
end

---Add a client to the server
---@param client_id string A unique client identifier
---@return table client The client object
function M.add_client(client_id)
  if not M.state.server then
    error("Server not running")
  end

  local client = {
    id = client_id,
    connected = true,
    messages = {},
  }

  M.state.clients[client_id] = client
  return client
end

---Remove a client from the server
---@param client_id string The client identifier
---@return boolean success Whether removal was successful
function M.remove_client(client_id)
  if not M.state.server or not M.state.clients[client_id] then
    return false
  end

  M.state.clients[client_id] = nil
  return true
end

---Send a message to a client
---@param client table|string The client object or ID
---@param method string The method name
---@param params table The parameters to send
---@return boolean success Whether sending was successful
function M.send(client, method, params)
  local client_obj

  if type(client) == "string" then
    client_obj = M.state.clients[client]
  else
    client_obj = client
  end

  if not client_obj then
    return false
  end

  local message = {
    jsonrpc = "2.0",
    method = method,
    params = params,
  }

  -- Store for testing
  table.insert(client_obj.messages, message)
  table.insert(M.state.messages, {
    client = client_obj.id,
    direction = "outbound",
    message = message,
  })

  return true
end

---Send a response to a client
---@param client table|string The client object or ID
---@param id string The message ID
---@param result table|nil The result data
---@param error table|nil The error data
---@return boolean success Whether sending was successful
function M.send_response(client, id, result, error)
  local client_obj

  if type(client) == "string" then
    client_obj = M.state.clients[client]
  else
    client_obj = client
  end

  if not client_obj then
    return false
  end

  local response = {
    jsonrpc = "2.0",
    id = id,
  }

  if error then
    response.error = error
  else
    response.result = result
  end

  -- Store for testing
  table.insert(client_obj.messages, response)
  table.insert(M.state.messages, {
    client = client_obj.id,
    direction = "outbound",
    message = response,
  })

  return true
end

---Broadcast a message to all connected clients
---@param method string The method name
---@param params table The parameters to send
---@return boolean success Whether broadcasting was successful
function M.broadcast(method, params)
  local success = true

  for client_id, _ in pairs(M.state.clients) do
    local send_success = M.send(client_id, method, params)
    success = success and send_success
  end

  return success
end

---Simulate receiving a message from a client
---@param client_id string The client ID
---@param message table The message to process
---@return table|nil response The response if any
function M.simulate_message(client_id, message)
  local client = M.state.clients[client_id]

  if not client then
    return nil
  end

  -- Store the message
  table.insert(M.state.messages, {
    client = client_id,
    direction = "inbound",
    message = message,
  })

  -- Process the message
  if message.method and M.state.handlers[message.method] then
    local handler = M.state.handlers[message.method]
    local response = handler(client, message.params)

    if message.id and response then
      -- If the message had an ID, this is a request and needs a response
      M.send_response(client, message.id, response.result, response.error)
      return response
    end
  end

  return nil
end

---Clear test messages
function M.clear_messages()
  M.state.messages = {}

  for _, client in pairs(M.state.clients) do
    client.messages = {}
  end
end

return M
