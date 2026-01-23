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
