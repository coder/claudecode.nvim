require("tests.busted_setup")

local client_manager = require("claudecode.server.client")

describe("TCP server disconnect handling", function()
  local tcp
  local original_process_data

  before_each(function()
    package.loaded["claudecode.server.tcp"] = nil
    tcp = require("claudecode.server.tcp")
    original_process_data = client_manager.process_data
  end)

  after_each(function()
    client_manager.process_data = original_process_data
  end)

  describe("find_available_port", function()
    local original_new_tcp
    local original_random

    before_each(function()
      original_new_tcp = vim.loop.new_tcp
      original_random = math.random
    end)

    after_each(function()
      vim.loop.new_tcp = original_new_tcp
      rawset(math, "random", original_random)
    end)

    it("should not build the whole default range when the first candidate is available", function()
      local bind_count = 0
      vim.loop.new_tcp = function()
        return {
          bind = function(self, host, port)
            bind_count = bind_count + 1
            return true
          end,
          close = function(self) end,
        }
      end

      local port = tcp.find_available_port(10000, 65535)

      assert.is_true(type(port) == "number")
      assert.is_true(port >= 10000 and port <= 65535)
      assert.are.equal(1, bind_count)
    end)

    it("should wrap and scan each port at most once", function()
      local tried_ports = {}
      rawset(math, "random", function(max)
        assert.are.equal(3, max)
        return 3
      end)
      vim.loop.new_tcp = function()
        return {
          bind = function(self, host, port)
            table.insert(tried_ports, port)
            return port == 10000
          end,
          close = function(self) end,
        }
      end

      local port = tcp.find_available_port(10000, 10002)

      assert.are.equal(10000, port)
      assert.are.same({ 10002, 10000 }, tried_ports)
    end)
  end)

  -- Regression tests for #283: create_server must retry across candidate ports
  -- when a port is taken, because the bind-only probe cannot detect an active
  -- listener (libuv defers EADDRINUSE to listen()).
  describe("create_server port-collision retry (#283)", function()
    local original_new_tcp
    local original_random

    before_each(function()
      original_new_tcp = vim.loop.new_tcp
      original_random = math.random
      -- Deterministic start_offset 0 => candidates scanned in ascending order.
      rawset(math, "random", function()
        return 1
      end)
    end)

    after_each(function()
      vim.loop.new_tcp = original_new_tcp
      rawset(math, "random", original_random)
    end)

    -- bind_result/listen_result: true => succeed (return 0, as luv does);
    -- a string => fail with that message (return nil, msg).
    local function make_handle(records, bind_result, listen_result)
      local handle = { closed = false }
      handle.bind = function(_, _host, port)
        handle.bound_port = port
        if bind_result == true then
          return 0
        end
        return nil, bind_result
      end
      handle.listen = function(_, _backlog, cb)
        handle.listen_cb = cb
        if listen_result == true then
          return 0
        end
        return nil, listen_result
      end
      handle.close = function()
        handle.closed = true
      end
      handle.is_closing = function()
        return handle.closed
      end
      table.insert(records, handle)
      return handle
    end

    local function new_tcp_from_specs(records, specs)
      local i = 0
      return function()
        i = i + 1
        local spec = specs[i] or { bind = true, listen = true }
        return make_handle(records, spec.bind, spec.listen)
      end
    end

    it("advances to the next port when listen() reports EADDRINUSE", function()
      local handles = {}
      vim.loop.new_tcp = new_tcp_from_specs(handles, {
        { bind = true, listen = "EADDRINUSE: address already in use" }, -- 10000 busy
        { bind = true, listen = true }, -- 10001 free
      })

      local server, err = tcp.create_server({ port_range = { min = 10000, max = 10002 } }, {}, nil)

      assert.is_nil(err)
      assert.is_table(server)
      assert.are.equal(10001, server.port)
      assert.is_true(handles[1].closed) -- busy handle discarded
      assert.are.equal(handles[2], server.server) -- the listening handle is kept
      assert.is_false(handles[2].closed)
    end)

    it("returns an error after exhausting the range, closing every handle", function()
      local handles = {}
      vim.loop.new_tcp = function()
        return make_handle(handles, true, "EADDRINUSE: address already in use")
      end

      local server, err = tcp.create_server({ port_range = { min = 10000, max = 10002 } }, {}, nil)

      assert.is_nil(server)
      assert.is_string(err)
      assert.is_truthy(err:find("Failed to bind to any port in range 10000%-10002"))
      assert.are.equal(3, #handles) -- every candidate tried exactly once
      for _, h in ipairs(handles) do
        assert.is_true(h.closed)
      end
    end)

    it("treats bind-success-but-listen-EADDRINUSE as unavailable", function()
      local handles = {}
      vim.loop.new_tcp = function()
        return make_handle(handles, true, "EADDRINUSE: address already in use")
      end

      local server, err = tcp.create_server({ port_range = { min = 10000, max = 10000 } }, {}, nil)

      assert.is_nil(server)
      assert.is_string(err)
      assert.is_truthy(err:find("Failed to listen on port 10000"))
      assert.is_true(handles[1].closed)
    end)

    it("keeps the exact handle whose listen() succeeded", function()
      local handles = {}
      vim.loop.new_tcp = function()
        return make_handle(handles, true, true)
      end

      local server, err = tcp.create_server({ port_range = { min = 10000, max = 10000 } }, {}, nil)

      assert.is_nil(err)
      assert.are.equal(handles[1], server.server)
      assert.are.equal(10000, server.port)
      assert.is_function(handles[1].listen_cb)
    end)
  end)

  it("should call on_disconnect and remove client on EOF", function()
    local callbacks = {
      on_message = spy.new(function() end),
      on_connect = spy.new(function() end),
      on_disconnect = spy.new(function() end),
      on_error = spy.new(function() end),
    }

    local config = { port_range = { min = 10000, max = 10000 } }
    local server, err = tcp.create_server(config, callbacks, nil)
    assert.is_nil(err)
    assert.is_table(server)

    tcp._handle_new_connection(server)

    assert.spy(callbacks.on_connect).was_called(1)
    local client = callbacks.on_connect.calls[1].vals[1]
    assert.is_table(client)
    assert.is_table(client.tcp_handle)
    assert.is_function(client.tcp_handle._read_cb)

    -- Simulate client abruptly disconnecting (e.g. CLI terminated via Ctrl-C)
    client.tcp_handle._read_cb(nil, nil)

    assert.spy(callbacks.on_disconnect).was_called(1)
    assert.spy(callbacks.on_disconnect).was_called_with(client, 1006, "EOF")
    expect(server.clients[client.id]).to_be_nil()
  end)

  it("should call on_disconnect and remove client on TCP read error", function()
    local callbacks = {
      on_message = spy.new(function() end),
      on_connect = spy.new(function() end),
      on_disconnect = spy.new(function() end),
      on_error = spy.new(function() end),
    }

    local config = { port_range = { min = 10000, max = 10000 } }
    local server, err = tcp.create_server(config, callbacks, nil)
    assert.is_nil(err)
    assert.is_table(server)

    tcp._handle_new_connection(server)

    local client = callbacks.on_connect.calls[1].vals[1]
    client.tcp_handle._read_cb("boom", nil)

    assert.spy(callbacks.on_disconnect).was_called(1)
    assert.spy(callbacks.on_disconnect).was_called_with(client, 1006, "Client read error: boom")
    expect(server.clients[client.id]).to_be_nil()

    assert.spy(callbacks.on_error).was_called(1)
    assert.spy(callbacks.on_error).was_called_with("Client read error: boom")
  end)

  it("should call on_disconnect when client manager reports an error", function()
    client_manager.process_data = function(cl, data, on_message, on_close, on_error, auth_token)
      on_error(cl, "Protocol error")
    end

    local callbacks = {
      on_message = spy.new(function() end),
      on_connect = spy.new(function() end),
      on_disconnect = spy.new(function() end),
      on_error = spy.new(function() end),
    }

    local config = { port_range = { min = 10000, max = 10000 } }
    local server, err = tcp.create_server(config, callbacks, nil)
    assert.is_nil(err)
    assert.is_table(server)

    tcp._handle_new_connection(server)

    local client = callbacks.on_connect.calls[1].vals[1]
    client.tcp_handle._read_cb(nil, "some data")

    assert.spy(callbacks.on_disconnect).was_called(1)
    assert.spy(callbacks.on_disconnect).was_called_with(client, 1006, "Client error: Protocol error")
    expect(server.clients[client.id]).to_be_nil()
  end)

  it("should only call on_disconnect once if multiple disconnect paths fire", function()
    client_manager.process_data = function(cl, data, on_message, on_close, on_error, auth_token)
      on_close(cl, 1000, "bye")
    end

    local callbacks = {
      on_message = spy.new(function() end),
      on_connect = spy.new(function() end),
      on_disconnect = spy.new(function() end),
      on_error = spy.new(function() end),
    }

    local config = { port_range = { min = 10000, max = 10000 } }
    local server, err = tcp.create_server(config, callbacks, nil)
    assert.is_nil(err)
    assert.is_table(server)

    tcp._handle_new_connection(server)

    local client = callbacks.on_connect.calls[1].vals[1]
    client.tcp_handle._read_cb(nil, "data")

    assert.spy(callbacks.on_disconnect).was_called(1)
    assert.spy(callbacks.on_disconnect).was_called_with(client, 1000, "bye")
    expect(server.clients[client.id]).to_be_nil()

    -- Simulate a later EOF after the CLOSE path already removed the client.
    client.tcp_handle._read_cb(nil, nil)
    assert.spy(callbacks.on_disconnect).was_called(1)
  end)
end)
