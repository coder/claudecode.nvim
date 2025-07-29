---@brief WebSocket handshake handling (RFC 6455)
local utils = require("claudecode.server.utils")

local M = {}

---@brief Check if an HTTP request is a valid WebSocket upgrade request
---@param request string The HTTP request string
---@param expected_auth_token string|nil Expected authentication token for validation
---@return boolean valid True if it's a valid WebSocket upgrade request
---@return table|string headers_or_error Headers table if valid, error message if not
function M.validate_upgrade_request(request, expected_auth_token)
  local headers = utils.parse_http_headers(request)

  -- Check for required headers
  if not headers["upgrade"] or headers["upgrade"]:lower() ~= "websocket" then
    return false, "Missing or invalid Upgrade header"
  end

  if not headers["connection"] or not headers["connection"]:lower():find("upgrade") then
    return false, "Missing or invalid Connection header"
  end

  if not headers["sec-websocket-key"] then
    return false, "Missing Sec-WebSocket-Key header"
  end

  if not headers["sec-websocket-version"] or headers["sec-websocket-version"] ~= "13" then
    return false, "Missing or unsupported Sec-WebSocket-Version header"
  end

  -- Validate WebSocket key format (should be base64 encoded 16 bytes)
  local key = headers["sec-websocket-key"]
  if #key ~= 24 then -- Base64 encoded 16 bytes = 24 characters
    return false, "Invalid Sec-WebSocket-Key format"
  end

  -- Validate authentication token if required
  if expected_auth_token then
    -- Check if expected_auth_token is valid
    if type(expected_auth_token) ~= "string" or expected_auth_token == "" then
      return false, "Server configuration error: invalid expected authentication token"
    end

    local auth_header = headers["x-claude-code-ide-authorization"]
    if not auth_header then
      return false, "Missing authentication header: x-claude-code-ide-authorization"
    end

    -- Check for empty auth header
    if auth_header == "" then
      return false, "Authentication token too short (min 10 characters)"
    end

    -- Check for suspicious auth header lengths
    if #auth_header > 500 then
      return false, "Authentication token too long (max 500 characters)"
    end

    if #auth_header < 10 then
      return false, "Authentication token too short (min 10 characters)"
    end

    if auth_header ~= expected_auth_token then
      return false, "Invalid authentication token"
    end
  end

  return true, headers
end

---@brief Generate a WebSocket handshake response
---@param client_key string The client's Sec-WebSocket-Key header value
---@param protocol string|nil Optional subprotocol to accept
---@return string|nil response The HTTP response string, or nil on error
function M.create_handshake_response(client_key, protocol)
  local accept_key = utils.generate_accept_key(client_key)
  if not accept_key then
    return nil
  end

  local response_lines = {
    "HTTP/1.1 101 Switching Protocols",
    "Upgrade: websocket",
    "Connection: Upgrade",
    "Sec-WebSocket-Accept: " .. accept_key,
  }

  if protocol then
    table.insert(response_lines, "Sec-WebSocket-Protocol: " .. protocol)
  end

  -- Add empty line to end headers
  table.insert(response_lines, "")
  table.insert(response_lines, "")

  return table.concat(response_lines, "\r\n")
end

---@brief Parse the HTTP request line
---@param request string The HTTP request string
---@return string|nil method The HTTP method (GET, POST, etc.)
---@return string|nil path The request path
---@return string|nil version The HTTP version
function M.parse_request_line(request)
  local first_line = request:match("^([^\r\n]+)")
  if not first_line then
    return nil, nil, nil
  end

  local method, path, version = first_line:match("^(%S+)%s+(%S+)%s+(%S+)$")
  return method, path, version
end

---@brief Check if the request is for the WebSocket endpoint
---@param request string The HTTP request string
---@return boolean valid True if the request is for a valid WebSocket endpoint
function M.is_websocket_endpoint(request)
  local method, path, version = M.parse_request_line(request)

  -- Must be GET request
  if method ~= "GET" then
    return false
  end

  -- Must be HTTP/1.1 or later
  if not version or not version:match("^HTTP/1%.1") then
    return false
  end

  -- Accept any path for now (could be made configurable)
  if not path then
    return false
  end

  return true
end

---@brief Create a WebSocket handshake error response
---@param code number HTTP status code
---@param message string Error message
---@return string response The HTTP error response
function M.create_error_response(code, message)
  local status_text = {
    [400] = "Bad Request",
    [404] = "Not Found",
    [426] = "Upgrade Required",
    [500] = "Internal Server Error",
  }

  local status = status_text[code] or "Error"

  local response_lines = {
    "HTTP/1.1 " .. code .. " " .. status,
    "Content-Type: text/plain",
    "Content-Length: " .. #message,
    "Connection: close",
    "",
    message,
  }

  return table.concat(response_lines, "\r\n")
end

---@brief Process a complete WebSocket handshake
---@param request string The HTTP request string
---@param expected_auth_token string|nil Expected authentication token for validation
---@return boolean success True if handshake was successful
---@return string response The HTTP response to send
---@return table|nil headers The parsed headers if successful
function M.process_handshake(request, expected_auth_token)
  -- Check if it's a valid WebSocket endpoint request
  if not M.is_websocket_endpoint(request) then
    local response = M.create_error_response(404, "WebSocket endpoint not found")
    return false, response, nil
  end

  -- Validate the upgrade request
  local is_valid_upgrade, validation_payload = M.validate_upgrade_request(request, expected_auth_token) ---@type boolean, table|string
  if not is_valid_upgrade then
    assert(type(validation_payload) == "string", "validation_payload should be a string on error")
    local error_message = validation_payload
    local response = M.create_error_response(400, "Bad WebSocket upgrade request: " .. error_message)
    return false, response, nil
  end

  -- If is_valid_upgrade is true, validation_payload must be the headers table
  assert(type(validation_payload) == "table", "validation_payload should be a table on success")
  local headers_table = validation_payload

  -- Generate handshake response
  local client_key = headers_table["sec-websocket-key"]
  local protocol = headers_table["sec-websocket-protocol"] -- Optional

  local response = M.create_handshake_response(client_key, protocol)
  if not response then
    local error_response = M.create_error_response(500, "Failed to generate WebSocket handshake response")
    return false, error_response, nil -- error_response is string, nil is for headers
  end

  return true, response, headers_table -- headers_table is 'table', compatible with 'table|nil'
end

---@brief Check if a request buffer contains a complete HTTP request
---@param buffer string The request buffer
---@return boolean complete True if the request is complete
---@return string|nil request The complete request if found
---@return string remaining Any remaining data after the request
function M.extract_http_request(buffer)
  -- Look for the end of HTTP headers (double CRLF)
  local header_end = buffer:find("\r\n\r\n")
  if not header_end then
    return false, nil, buffer
  end

  -- For WebSocket upgrade, there should be no body
  local request = buffer:sub(1, header_end + 3) -- Include the final CRLF
  local remaining = buffer:sub(header_end + 4)

  return true, request, remaining
end

return M
