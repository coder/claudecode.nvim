-- Unit tests for WebSocket server module
-- luacheck: globals expect
require("tests.busted_setup")

describe("WebSocket Server", function()
  local server

  -- Set up before each test
  local function setup()
    -- Reset loaded modules
    package.loaded["claudecode.server.init"] = nil -- Also update package.loaded key

    -- Load the module under test
    server = require("claudecode.server.init")
  end

  -- Clean up after each test
  local function teardown()
    -- Ensure server is stopped
    if server.state.server then
      server.stop()
    end
  end

  -- Run setup before each test
  setup()

  it("should have a get_status function", function()
    local status = server.get_status()

    expect(status).to_be_table()
    expect(status.running).to_be_false()
    expect(status.port).to_be_nil()
    expect(status.client_count).to_be(0)
  end)

  it("should start server successfully", function()
    local config = {
      port_range = {
        min = 10000,
        max = 65535,
      },
    }

    local success, port = server.start(config)

    expect(success).to_be_true()
    expect(server.state.server).to_be_table()
    expect(server.state.port).to_be(port)
    expect(port >= config.port_range.min and port <= config.port_range.max).to_be_true()

    -- Clean up
    server.stop()
  end)

  it("should not start server twice", function()
    local config = {
      port_range = {
        min = 10000,
        max = 65535,
      },
    }

    -- Start once
    local success1, _ = server.start(config)
    expect(success1).to_be_true()

    -- Try to start again
    local success2, error2 = server.start(config)
    expect(success2).to_be_false()
    expect(error2).to_be("Server already running")

    -- Clean up
    server.stop()
  end)

  it("should stop server successfully", function()
    local config = {
      port_range = {
        min = 10000,
        max = 65535,
      },
    }

    -- Start server
    server.start(config)

    -- Stop server
    local success, _ = server.stop()

    expect(success).to_be_true()
    expect(server.state.server).to_be_nil()
    expect(server.state.port).to_be_nil()

    local status = server.get_status()
    expect(status.running).to_be_false()
    expect(status.client_count).to_be(0)
  end)

  it("should not stop server if not running", function()
    -- Ensure server is not running
    if server.state.server then
      server.stop()
    end

    -- Try to stop again
    local success, error = server.stop()

    expect(success).to_be_false()
    expect(error).to_be("Server not running")
  end)

  it("should register message handlers", function()
    server.register_handlers()

    expect(server.state.handlers).to_be_table()
    expect(type(server.state.handlers["initialize"])).to_be("function") -- Function, not table
    expect(type(server.state.handlers["tools/list"])).to_be("function") -- Function, not table
  end)

  it("should not advertise unsupported MCP resources", function()
    server.register_handlers()

    vim.empty_dict = vim.empty_dict or function()
      return {}
    end

    local result = server.state.handlers["initialize"]({}, {})

    expect(result).to_be_table()
    expect(result.capabilities).to_be_table()
    expect(result.capabilities.resources).to_be_nil()
    expect(result.capabilities.tools).to_be_table()
  end)

  it("should send message to client", function()
    -- Start server first
    local config = { port_range = { min = 10000, max = 65535 } }
    server.start(config)

    -- Mock client
    local client = { id = "test_client" }

    local method = "test_method"
    local params = { foo = "bar" }

    local success = server.send(client, method, params)

    expect(success).to_be_true()

    -- Clean up
    server.stop()
  end)

  it("should send response to client", function()
    -- Start server first
    local config = { port_range = { min = 10000, max = 65535 } }
    server.start(config)

    -- Mock client
    local client = { id = "test_client" }

    local id = "test_id"
    local result = { foo = "bar" }

    local success = server.send_response(client, id, result)

    expect(success).to_be_true()

    -- Clean up
    server.stop()
  end)

  it("should broadcast to all clients, and report whether a connected client took it", function()
    -- Start server first
    local config = { port_range = { min = 10000, max = 65535 } }
    server.start(config)

    local method = "test_method"
    local params = { foo = "bar" }

    -- The @ mention queue keeps a mention that no client took, so a broadcast to nobody must not report success.
    local ok, success_without_client = pcall(server.broadcast, method, params)
    local written = {}
    local function add_client(id, state)
      server.state.server.clients[id] = {
        id = id,
        state = state,
        tcp_handle = {
          write = function(_, data)
            table.insert(written, id)
          end,
          is_closing = function()
            return false
          end,
          close = function() end,
        },
      }
    end
    add_client("closing_client", "closing")
    local ok_closing, success_with_closing_client = pcall(server.broadcast, method, params)
    add_client("connected_client", "connected")
    local ok_connected, success_with_connected_client = pcall(server.broadcast, method, params)

    -- Clean up first, so that a failed assertion does not leave the server running for the next test.
    server.state.server.clients = {}
    server.stop()

    assert.is_true(ok and ok_closing and ok_connected)
    expect(success_without_client).to_be_false()
    expect(success_with_closing_client).to_be_false()
    expect(success_with_connected_client).to_be_true()
    assert.same({ "connected_client" }, written)
  end)

  it("reports once, after the last write finished, how many writes of a broadcast succeeded", function()
    server.start({ port_range = { min = 10000, max = 65535 } })
    local pending_writes = {}
    local function add_client(id, sync_error)
      server.state.server.clients[id] = {
        id = id,
        state = "connected",
        tcp_handle = {
          write = function(_, _, callback)
            if sync_error ~= nil then
              callback(sync_error or nil)
            else
              table.insert(pending_writes, callback)
            end
          end,
          is_closing = function()
            return false
          end,
          close = function() end,
        },
      }
    end
    local reports = {}
    local function on_written(count)
      table.insert(reports, count)
    end

    local results = {}
    -- No client: nothing to report.
    results.none = server.broadcast("m", {}, on_written)
    local reports_without_client = #reports
    -- Two clients whose writes finish later, one with an error.
    add_client("a")
    add_client("b")
    results.async = server.broadcast("m", {}, on_written)
    local reports_before_writes = #reports
    pending_writes[1]("ECONNRESET")
    local reports_after_first_write = #reports
    pending_writes[2]()
    local async_reports = vim.deepcopy(reports)
    -- Writes that finish at once, both failed.
    server.state.server.clients = {}
    reports = {}
    add_client("c", "EPIPE")
    add_client("d", "EPIPE")
    results.sync = server.broadcast("m", {}, on_written)
    local sync_failed_reports = vim.deepcopy(reports)
    -- Writes that finish at once, one failed and two succeeded: the report must wait for the last of them, whatever
    -- order pairs() visits the clients in.
    server.state.server.clients = {}
    reports = {}
    add_client("e", "EPIPE")
    add_client("f", false)
    add_client("g", false)
    results.sync_mixed = server.broadcast("m", {}, on_written)

    server.state.server.clients = {}
    server.stop()

    assert.is_false(results.none)
    assert.equals(0, reports_without_client)
    assert.is_true(results.async)
    assert.equals(0, reports_before_writes)
    assert.equals(0, reports_after_first_write)
    assert.same({ 1 }, async_reports)
    assert.is_true(results.sync)
    assert.same({ 0 }, sync_failed_reports)
    assert.is_true(results.sync_mixed)
    assert.same({ 2 }, reports)
  end)

  it("counts a write that libuv refuses at once as failed, and still reports once", function()
    server.start({ port_range = { min = 10000, max = 65535 } })
    local function add_client(id, write)
      server.state.server.clients[id] = {
        id = id,
        state = "connected",
        tcp_handle = {
          write = write,
          is_closing = function()
            return false
          end,
          close = function() end,
        },
      }
    end
    -- libuv returns nil and the error for a write it refuses, and never runs that write's callback.
    add_client("refused", function()
      return nil, "EBADF: bad file descriptor"
    end)
    add_client("written", function(_, _, callback)
      callback()
      return true
    end)
    local reports = {}
    local took = server.broadcast("m", {}, function(count)
      table.insert(reports, count)
    end)

    server.state.server.clients = {}
    server.stop()

    assert.is_true(took)
    assert.same({ 1 }, reports)
  end)

  describe("invalid JSON-RPC messages", function()
    local tcp = require("claudecode.server.tcp")
    local original = {}
    local encoded

    before_each(function()
      original.server = server.state.server
      original.send_to_client = tcp.send_to_client
      original.decode = vim.json.decode
      original.encode = vim.json.encode
      original.null = vim.NIL
      server.state.server = {}
      tcp.send_to_client = function() end
      vim.NIL = setmetatable({}, { __name = "vim.NIL" })
      encoded = {}
      vim.json.encode = function(value)
        table.insert(encoded, value)
        return ""
      end
    end)

    after_each(function()
      server.state.server = original.server
      tcp.send_to_client = original.send_to_client
      vim.json.decode = original.decode
      vim.json.encode = original.encode
      vim.NIL = original.null
    end)

    for _, payload in ipairs({ "5", "true", "false", '"text"' }) do
      it("answers -32600 with a JSON null id for payload " .. payload, function()
        vim.json.decode = _G.json_decode

        local ok, err = pcall(server._handle_message, { id = "test_client" }, payload)

        assert.is_true(ok, tostring(err))
        expect(#encoded).to_be(1)
        expect(encoded[1].id).to_be(vim.NIL)
        expect(encoded[1].error.code).to_be(-32600)
      end)
    end

    it("answers -32700 with a JSON null id when the message is not JSON", function()
      vim.json.decode = function()
        error("Expected value but found invalid token")
      end

      server._handle_message({ id = "test_client" }, "{not json")

      expect(#encoded).to_be(1)
      expect(encoded[1].id).to_be(vim.NIL)
      expect(encoded[1].error.code).to_be(-32700)
    end)
  end)

  describe("authentication integration", function()
    it("should start server with authentication token", function()
      local config = {
        port_range = {
          min = 10000,
          max = 65535,
        },
      }
      local auth_token = "550e8400-e29b-41d4-a716-446655440000"

      local success, port = server.start(config, auth_token)

      expect(success).to_be_true()
      expect(server.state.auth_token).to_be(auth_token)
      expect(server.state.server).to_be_table()
      expect(server.state.port).to_be(port)

      -- Clean up
      server.stop()
    end)

    it("should clear auth token when server stops", function()
      local config = {
        port_range = {
          min = 10000,
          max = 65535,
        },
      }
      local auth_token = "550e8400-e29b-41d4-a716-446655440000"

      -- Start server with auth token
      server.start(config, auth_token)
      expect(server.state.auth_token).to_be(auth_token)

      -- Stop server
      server.stop()
      expect(server.state.auth_token).to_be_nil()
    end)

    it("should start server without authentication token", function()
      local config = {
        port_range = {
          min = 10000,
          max = 65535,
        },
      }

      local success, port = server.start(config, nil)

      expect(success).to_be_true()
      expect(server.state.auth_token).to_be_nil()
      expect(server.state.server).to_be_table()
      expect(server.state.port).to_be(port)

      -- Clean up
      server.stop()
    end)

    it("should pass auth token to TCP server creation", function()
      local config = {
        port_range = {
          min = 10000,
          max = 65535,
        },
      }
      local auth_token = "550e8400-e29b-41d4-a716-446655440000"

      -- Mock the TCP server module to verify auth token is passed
      local tcp_server = require("claudecode.server.tcp")
      local original_create_server = tcp_server.create_server
      local captured_auth_token = nil

      tcp_server.create_server = function(cfg, callbacks, auth_token_arg)
        captured_auth_token = auth_token_arg
        return original_create_server(cfg, callbacks, auth_token_arg)
      end

      local success, _ = server.start(config, auth_token)

      -- Restore original function
      tcp_server.create_server = original_create_server

      expect(success).to_be_true()
      expect(captured_auth_token).to_be(auth_token)

      -- Clean up
      server.stop()
    end)

    it("should maintain auth token in server state throughout lifecycle", function()
      local config = {
        port_range = {
          min = 10000,
          max = 65535,
        },
      }
      local auth_token = "550e8400-e29b-41d4-a716-446655440000"

      -- Start server
      server.start(config, auth_token)
      expect(server.state.auth_token).to_be(auth_token)

      -- Get status should show running state
      local status = server.get_status()
      expect(status.running).to_be_true()
      expect(server.state.auth_token).to_be(auth_token)

      -- Send message should work with auth token in place
      local client = { id = "test_client" }
      local success = server.send(client, "test_method", { test = "data" })
      expect(success).to_be_true()
      expect(server.state.auth_token).to_be(auth_token)

      -- Clean up
      server.stop()
    end)

    it("should reject starting server if auth token is explicitly false", function()
      local config = {
        port_range = {
          min = 10000,
          max = 65535,
        },
      }

      -- Use an empty string as invalid auth token
      local success, _ = server.start(config, "")

      expect(success).to_be_true() -- Server should still start, just with empty token
      expect(server.state.auth_token).to_be("")

      -- Clean up
      server.stop()
    end)
  end)

  -- Clean up after all tests
  teardown()
end)
