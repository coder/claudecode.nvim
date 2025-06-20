---@brief WebSocket server for Claude Code Neovim integration
local claudecode_main = require("claudecode") -- Added for version access
local logger = require("claudecode.logger")
local tcp_server = require("claudecode.server.tcp")
local tools = require("claudecode.tools.init") -- Added: Require the tools module

local MCP_PROTOCOL_VERSION = "2024-11-05"

local M = {}

---@class ServerState
---@field server table|nil The TCP server instance
---@field port number|nil The port server is running on
---@field auth_token string|nil The authentication token for validating connections
---@field clients table A list of connected clients
---@field handlers table Message handlers by method name
---@field ping_timer table|nil Timer for sending pings
M.state = {
  server = nil,
  port = nil,
  auth_token = nil,
  clients = {},
  handlers = {},
  ping_timer = nil,
}

---@brief Initialize the WebSocket server
---@param config table Configuration options
---@param auth_token string|nil The authentication token for validating connections
---@return boolean success Whether server started successfully
---@return number|string port_or_error Port number or error message
function M.start(config, auth_token)
  if M.state.server then
    return false, "Server already running"
  end

  M.state.auth_token = auth_token

  -- Log authentication state
  if auth_token then
    logger.debug("server", "Starting WebSocket server with authentication enabled")
    logger.debug("server", "Auth token length:", #auth_token)
  else
    logger.debug("server", "Starting WebSocket server WITHOUT authentication (insecure)")
  end

  M.register_handlers()

  tools.setup(M)

  local callbacks = {
    on_message = function(client, message)
      M._handle_message(client, message)
    end,
    on_connect = function(client)
      M.state.clients[client.id] = client

      -- Log connection with auth status
      if M.state.auth_token then
        logger.debug("server", "Authenticated WebSocket client connected:", client.id)
      else
        logger.debug("server", "WebSocket client connected (no auth):", client.id)
      end

      -- Notify main module about new connection for queue processing
      local main_module = require("claudecode")
      if main_module._process_queued_mentions then
        vim.schedule(function()
          main_module._process_queued_mentions()
        end)
      end
    end,
    on_disconnect = function(client, code, reason)
      M.state.clients[client.id] = nil
      logger.debug(
        "server",
        "WebSocket client disconnected:",
        client.id,
        "(code:",
        code,
        ", reason:",
        (reason or "N/A") .. ")"
      )
    end,
    on_error = function(error_msg)
      logger.error("server", "WebSocket server error:", error_msg)
    end,
  }

  local server, error_msg = tcp_server.create_server(config, callbacks, M.state.auth_token)
  if not server then
    return false, error_msg or "Unknown server creation error"
  end

  M.state.server = server
  M.state.port = server.port

  M.state.ping_timer = tcp_server.start_ping_timer(server, 30000) -- Start ping timer to keep connections alive

  return true, server.port
end

---@brief Stop the WebSocket server
---@return boolean success Whether server stopped successfully
---@return string|nil error_message Error message if any
function M.stop()
  if not M.state.server then
    return false, "Server not running"
  end

  if M.state.ping_timer then
    M.state.ping_timer:stop()
    M.state.ping_timer:close()
    M.state.ping_timer = nil
  end

  tcp_server.stop_server(M.state.server)

  -- CRITICAL: Clear global deferred responses to prevent memory leaks and hanging
  if _G.claude_deferred_responses then
    _G.claude_deferred_responses = {}
  end

  M.state.server = nil
  M.state.port = nil
  M.state.auth_token = nil
  M.state.clients = {}

  return true
end

---@brief Handle incoming WebSocket message
---@param client table The client that sent the message
---@param message string The JSON-RPC message
function M._handle_message(client, message)
  local success, parsed = pcall(vim.json.decode, message)
  if not success then
    M.send_response(client, nil, nil, {
      code = -32700,
      message = "Parse error",
      data = "Invalid JSON",
    })
    return
  end

  if type(parsed) ~= "table" or parsed.jsonrpc ~= "2.0" then
    M.send_response(client, parsed.id, nil, {
      code = -32600,
      message = "Invalid Request",
      data = "Not a valid JSON-RPC 2.0 request",
    })
    return
  end

  if parsed.id then
    M._handle_request(client, parsed)
  else
    M._handle_notification(client, parsed)
  end
end

---@brief Handle JSON-RPC request (requires response)
---@param client table The client that sent the request
---@param request table The parsed JSON-RPC request
function M._handle_request(client, request)
  local method = request.method
  local params = request.params or {}
  local id = request.id

  local handler = M.state.handlers[method]
  if not handler then
    M.send_response(client, id, nil, {
      code = -32601,
      message = "Method not found",
      data = "Unknown method: " .. tostring(method),
    })
    return
  end

  local success, result, error_data = pcall(handler, client, params)
  if success then
    -- Check if this is a deferred response (blocking tool)
    if result and result._deferred then
      logger.debug("server", "Handler returned deferred response - storing for later")
      -- Store the request info for later response
      local deferred_info = {
        client = result.client,
        id = id,
        coroutine = result.coroutine,
        method = method,
        params = result.params,
      }
      -- Set up the completion callback
      M._setup_deferred_response(deferred_info)
      return -- Don't send response now
    end

    if error_data then
      M.send_response(client, id, nil, error_data)
    else
      M.send_response(client, id, result, nil)
    end
  else
    M.send_response(client, id, nil, {
      code = -32603,
      message = "Internal error",
      data = tostring(result), -- result contains error message when pcall fails
    })
  end
end

---@brief Set up deferred response handling for blocking tools
---@param deferred_info table Information about the deferred request
-- Note: deferred_responses table removed - using global _G.claude_deferred_responses instead

-- Add a unique module ID to detect reloading
local module_instance_id = math.random(10000, 99999)
logger.debug("server", "Server module loaded with instance ID:", module_instance_id)

-- Note: debug_deferred_table function removed as deferred_responses table is no longer used

function M._setup_deferred_response(deferred_info)
  local co = deferred_info.coroutine

  logger.debug("server", "Setting up deferred response for coroutine:", tostring(co))
  logger.debug("server", "Storage happening in module instance:", module_instance_id)

  -- Create a response sender function that captures the current server instance
  local response_sender = function(result)
    logger.debug("server", "Deferred response triggered for coroutine:", tostring(co))

    if result and result.content then
      -- MCP-compliant response
      M.send_response(deferred_info.client, deferred_info.id, result, nil)
    elseif result and result.error then
      -- Error response
      M.send_response(deferred_info.client, deferred_info.id, nil, result.error)
    else
      -- Fallback error
      M.send_response(deferred_info.client, deferred_info.id, nil, {
        code = -32603,
        message = "Internal error",
        data = "Deferred response completed with unexpected format",
      })
    end
  end

  -- Store the response sender in a global location that won't be affected by module reloading
  if not _G.claude_deferred_responses then
    _G.claude_deferred_responses = {}
  end
  _G.claude_deferred_responses[tostring(co)] = response_sender

  logger.debug("server", "Stored response sender in global table for coroutine:", tostring(co))
end

-- Note: _send_deferred_response is no longer needed
-- Responses are now handled via the global _G.claude_deferred_responses table
-- to avoid module reloading issues

---@brief Handle JSON-RPC notification (no response)
---@param client table The client that sent the notification
---@param notification table The parsed JSON-RPC notification
function M._handle_notification(client, notification)
  local method = notification.method
  local params = notification.params or {}

  local handler = M.state.handlers[method]
  if handler then
    pcall(handler, client, params)
  end
end

---@brief Register message handlers for the server
function M.register_handlers()
  M.state.handlers = {
    ["initialize"] = function(client, params) -- Renamed from mcp.connect
      return {
        protocolVersion = MCP_PROTOCOL_VERSION,
        capabilities = {
          logging = vim.empty_dict(), -- Ensure this is an object {} not an array []
          prompts = { listChanged = true },
          resources = { subscribe = true, listChanged = true },
          tools = { listChanged = true },
        },
        serverInfo = {
          name = "claudecode-neovim",
          version = claudecode_main.version:string(),
        },
      }
    end,

    ["notifications/initialized"] = function(client, params) -- Added handler for initialized notification
    end,

    ["prompts/list"] = function(client, params) -- Added handler for prompts/list
      return {
        prompts = {}, -- This will be encoded as an empty JSON array
      }
    end,

    ["tools/list"] = function(_client, _params)
      return {
        tools = tools.get_tool_list(),
      }
    end,

    ["tools/call"] = function(client, params)
      logger.debug(
        "server",
        "Received tools/call. Tool: ",
        params and params.name,
        " Arguments: ",
        vim.inspect(params and params.arguments)
      )
      local result_or_error_table = tools.handle_invoke(client, params)

      -- Check if this is a deferred response (blocking tool)
      if result_or_error_table and result_or_error_table._deferred then
        logger.debug("server", "Tool is blocking - setting up deferred response")
        -- Return the deferred response directly - _handle_request will process it
        return result_or_error_table
      end

      -- Log the response for debugging
      logger.debug("server", "Response - tools/call", params and params.name .. ":", vim.inspect(result_or_error_table))

      if result_or_error_table.error then
        return nil, result_or_error_table.error
      elseif result_or_error_table.result then
        return result_or_error_table.result, nil
      else
        -- Should not happen if tools.handle_invoke behaves correctly
        return nil,
          {
            code = -32603,
            message = "Internal error",
            data = "Tool handler returned unexpected format",
          }
      end
    end,
  }
end

---@brief Send a message to a client
---@param client table The client to send to
---@param method string The method name
---@param params table|nil The parameters to send
---@return boolean success Whether message was sent successfully
function M.send(client, method, params)
  if not M.state.server then
    return false
  end

  local message = {
    jsonrpc = "2.0",
    method = method,
    params = params or vim.empty_dict(),
  }

  local json_message = vim.json.encode(message)
  tcp_server.send_to_client(M.state.server, client.id, json_message)
  return true
end

---@brief Send a response to a client
---@param client table The client to send to
---@param id number|string|nil The request ID to respond to
---@param result any|nil The result data if successful
---@param error_data table|nil The error data if failed
---@return boolean success Whether response was sent successfully
function M.send_response(client, id, result, error_data)
  if not M.state.server then
    return false
  end

  local response = {
    jsonrpc = "2.0",
    id = id,
  }

  if error_data then
    response.error = error_data
  else
    response.result = result
  end

  local json_response = vim.json.encode(response)
  tcp_server.send_to_client(M.state.server, client.id, json_response)
  return true
end

---@brief Broadcast a message to all connected clients
---@param method string The method name
---@param params table|nil The parameters to send
---@return boolean success Whether broadcast was successful
function M.broadcast(method, params)
  if not M.state.server then
    return false
  end

  local message = {
    jsonrpc = "2.0",
    method = method,
    params = params or vim.empty_dict(),
  }

  local json_message = vim.json.encode(message)
  tcp_server.broadcast(M.state.server, json_message)
  return true
end

---@brief Get server status information
---@return table status Server status information
function M.get_status()
  if not M.state.server then
    return {
      running = false,
      port = nil,
      client_count = 0,
    }
  end

  return {
    running = true,
    port = M.state.port,
    client_count = tcp_server.get_client_count(M.state.server),
    clients = tcp_server.get_clients_info(M.state.server),
  }
end

return M
