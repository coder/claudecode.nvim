require("tests.busted_setup")

describe("WebSocket handshake authentication", function()
  local handshake

  before_each(function()
    handshake = require("claudecode.server.handshake")
  end)

  after_each(function()
    package.loaded["claudecode.server.handshake"] = nil
  end)

  describe("validate_upgrade_request with authentication", function()
    local valid_request_base = table.concat({
      "GET /websocket HTTP/1.1",
      "Host: localhost:8080",
      "Upgrade: websocket",
      "Connection: upgrade",
      "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
      "Sec-WebSocket-Version: 13",
      "",
      "",
    }, "\r\n")

    it("should accept valid request with correct auth token", function()
      local expected_token = "550e8400-e29b-41d4-a716-446655440000"
      local request_with_auth = table.concat({
        "GET /websocket HTTP/1.1",
        "Host: localhost:8080",
        "Upgrade: websocket",
        "Connection: upgrade",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Version: 13",
        "x-claude-code-ide-authorization: " .. expected_token,
        "",
        "",
      }, "\r\n")

      local is_valid, headers = handshake.validate_upgrade_request(request_with_auth, expected_token)

      assert.is_true(is_valid)
      assert.is_table(headers)
      assert.equals(expected_token, headers["x-claude-code-ide-authorization"])
    end)

    it("should reject request with missing auth token when required", function()
      local expected_token = "550e8400-e29b-41d4-a716-446655440000"

      local is_valid, error_msg = handshake.validate_upgrade_request(valid_request_base, expected_token)

      assert.is_false(is_valid)
      assert.equals("Missing authentication header: x-claude-code-ide-authorization", error_msg)
    end)

    it("should reject request with incorrect auth token", function()
      local expected_token = "550e8400-e29b-41d4-a716-446655440000"
      local wrong_token = "123e4567-e89b-12d3-a456-426614174000"

      local request_with_wrong_auth = table.concat({
        "GET /websocket HTTP/1.1",
        "Host: localhost:8080",
        "Upgrade: websocket",
        "Connection: upgrade",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Version: 13",
        "x-claude-code-ide-authorization: " .. wrong_token,
        "",
        "",
      }, "\r\n")

      local is_valid, error_msg = handshake.validate_upgrade_request(request_with_wrong_auth, expected_token)

      assert.is_false(is_valid)
      assert.equals("Invalid authentication token", error_msg)
    end)

    it("should accept request without auth token when none required", function()
      local is_valid, headers = handshake.validate_upgrade_request(valid_request_base, nil)

      assert.is_true(is_valid)
      assert.is_table(headers)
    end)

    it("should reject request with empty auth token when required", function()
      local expected_token = "550e8400-e29b-41d4-a716-446655440000"

      local request_with_empty_auth = table.concat({
        "GET /websocket HTTP/1.1",
        "Host: localhost:8080",
        "Upgrade: websocket",
        "Connection: upgrade",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Version: 13",
        "x-claude-code-ide-authorization: ",
        "",
        "",
      }, "\r\n")

      local is_valid, error_msg = handshake.validate_upgrade_request(request_with_empty_auth, expected_token)

      assert.is_false(is_valid)
      assert.equals("Authentication token too short (min 10 characters)", error_msg)
    end)

    it("should handle case-insensitive auth header name", function()
      local expected_token = "550e8400-e29b-41d4-a716-446655440000"

      local request_with_uppercase_header = table.concat({
        "GET /websocket HTTP/1.1",
        "Host: localhost:8080",
        "Upgrade: websocket",
        "Connection: upgrade",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Version: 13",
        "X-Claude-Code-IDE-Authorization: " .. expected_token,
        "",
        "",
      }, "\r\n")

      local is_valid, headers = handshake.validate_upgrade_request(request_with_uppercase_header, expected_token)

      assert.is_true(is_valid)
      assert.is_table(headers)
    end)
  end)

  describe("process_handshake with authentication", function()
    local valid_request_base = table.concat({
      "GET /websocket HTTP/1.1",
      "Host: localhost:8080",
      "Upgrade: websocket",
      "Connection: upgrade",
      "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
      "Sec-WebSocket-Version: 13",
      "",
      "",
    }, "\r\n")

    it("should complete handshake successfully with valid auth token", function()
      local expected_token = "550e8400-e29b-41d4-a716-446655440000"
      local request_with_auth = table.concat({
        "GET /websocket HTTP/1.1",
        "Host: localhost:8080",
        "Upgrade: websocket",
        "Connection: upgrade",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Version: 13",
        "x-claude-code-ide-authorization: " .. expected_token,
        "",
        "",
      }, "\r\n")

      local success, response, headers = handshake.process_handshake(request_with_auth, expected_token)

      assert.is_true(success)
      assert.is_string(response)
      assert.is_table(headers)
      assert.matches("HTTP/1.1 101 Switching Protocols", response)
      assert.matches("Upgrade: websocket", response)
      assert.matches("Connection: Upgrade", response)
      assert.matches("Sec%-WebSocket%-Accept:", response)
    end)

    it("should fail handshake with missing auth token", function()
      local expected_token = "550e8400-e29b-41d4-a716-446655440000"

      local success, response, headers = handshake.process_handshake(valid_request_base, expected_token)

      assert.is_false(success)
      assert.is_string(response)
      assert.is_nil(headers)
      assert.matches("HTTP/1.1 400 Bad Request", response)
      assert.matches("Missing authentication header", response)
    end)

    it("should fail handshake with invalid auth token", function()
      local expected_token = "550e8400-e29b-41d4-a716-446655440000"
      local wrong_token = "123e4567-e89b-12d3-a456-426614174000"

      local request_with_wrong_auth = table.concat({
        "GET /websocket HTTP/1.1",
        "Host: localhost:8080",
        "Upgrade: websocket",
        "Connection: upgrade",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Version: 13",
        "x-claude-code-ide-authorization: " .. wrong_token,
        "",
        "",
      }, "\r\n")

      local success, response, headers = handshake.process_handshake(request_with_wrong_auth, expected_token)

      assert.is_false(success)
      assert.is_string(response)
      assert.is_nil(headers)
      assert.matches("HTTP/1.1 400 Bad Request", response)
      assert.matches("Invalid authentication token", response)
    end)

    it("should complete handshake without auth when none required", function()
      local success, response, headers = handshake.process_handshake(valid_request_base, nil)

      assert.is_true(success)
      assert.is_string(response)
      assert.is_table(headers)
      assert.matches("HTTP/1.1 101 Switching Protocols", response)
    end)
  end)

  describe("authentication edge cases", function()
    it("should handle malformed auth header format", function()
      local expected_token = "550e8400-e29b-41d4-a716-446655440000"

      local request_with_malformed_auth = table.concat({
        "GET /websocket HTTP/1.1",
        "Host: localhost:8080",
        "Upgrade: websocket",
        "Connection: upgrade",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Version: 13",
        "x-claude-code-ide-authorization:not-a-uuid",
        "",
        "",
      }, "\r\n")

      local is_valid, error_msg = handshake.validate_upgrade_request(request_with_malformed_auth, expected_token)

      assert.is_false(is_valid)
      assert.equals("Invalid authentication token", error_msg)
    end)

    it("should handle multiple auth headers (uses last one)", function()
      local expected_token = "550e8400-e29b-41d4-a716-446655440000"
      local wrong_token = "123e4567-e89b-12d3-a456-426614174000"

      local request_with_multiple_auth = table.concat({
        "GET /websocket HTTP/1.1",
        "Host: localhost:8080",
        "Upgrade: websocket",
        "Connection: upgrade",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Version: 13",
        "x-claude-code-ide-authorization: " .. wrong_token,
        "x-claude-code-ide-authorization: " .. expected_token,
        "",
        "",
      }, "\r\n")

      local is_valid, headers = handshake.validate_upgrade_request(request_with_multiple_auth, expected_token)

      assert.is_true(is_valid)
      assert.is_table(headers)
      assert.equals(expected_token, headers["x-claude-code-ide-authorization"])
    end)

    it("should reject very long auth tokens", function()
      local expected_token = string.rep("a", 1000) -- Very long token

      local request_with_long_auth = table.concat({
        "GET /websocket HTTP/1.1",
        "Host: localhost:8080",
        "Upgrade: websocket",
        "Connection: upgrade",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Version: 13",
        "x-claude-code-ide-authorization: " .. expected_token,
        "",
        "",
      }, "\r\n")

      local is_valid, error_msg = handshake.validate_upgrade_request(request_with_long_auth, expected_token)

      assert.is_false(is_valid)
      assert.equals("Authentication token too long (max 500 characters)", error_msg)
    end)
  end)
end)
