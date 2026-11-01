--- A client can hang up right after it sends a request: with its upgrade request, before the 101 reply is written, or
--- while the request waits for the main loop. Its request must not run then. The client holds the auth token, and a
--- request such as openFile changes the editor for a client that is gone.
require("tests.busted_setup")

describe("A request from a client that has gone", function()
  local server, tcp, frame, handled, scheduled
  local saved = {}
  local token = "test-token-0123456789"
  local request = '{"jsonrpc":"2.0","id":7,"method":"tools/list"}'

  before_each(function()
    for _, name in ipairs({
      "claudecode.server.handshake",
      "claudecode.server.client",
      "claudecode.server.tcp",
      "claudecode.server.init",
    }) do
      package.loaded[name] = nil
    end
    tcp = require("claudecode.server.tcp")
    server = require("claudecode.server.init")
    frame = require("claudecode.server.frame")
    handled, scheduled = {}, nil
    saved.schedule = vim.schedule
    -- While `scheduled` is a list, scheduled callbacks wait in it, as they wait for the main loop in Neovim.
    vim.schedule = function(fn)
      if scheduled then
        table.insert(scheduled, fn)
      else
        fn()
      end
    end
    assert(server.start({ port_range = { min = 10000, max = 65535 } }, token))
    server._handle_message = function(_, message)
      table.insert(handled, message)
    end
  end)

  after_each(function()
    vim.schedule = saved.schedule
    if server.state.server then
      server.stop()
    end
  end)

  local upgrade = "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
    .. "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n"
    .. "x-claude-code-ide-authorization: "
    .. token
    .. "\r\n\r\n"

  ---A connection whose socket works like libuv's: a write callback runs only when the test calls `done`, and a write
  ---after close is an error.
  ---@return table client
  ---@return table writes Each write: { data = string, done = function(err) }
  local function connect()
    tcp._handle_new_connection(server.state.server)
    local client = assert(server.state.server.clients["client_" .. _G.claudecode_clients_created])
    local handle, writes = client.tcp_handle, {}
    local closed = false
    function handle:write(data, callback)
      assert(not closed, "write after close")
      table.insert(writes, { data = data, done = callback or function() end })
    end
    function handle:close()
      assert(not closed, "handle is already closing")
      closed = true
    end
    function handle:is_closing()
      return closed
    end
    return client, writes
  end

  local function run_scheduled()
    local queue = scheduled
    scheduled = nil
    for _, fn in ipairs(queue) do
      fn()
    end
  end

  it("does not run a request sent with the upgrade request when the client hangs up before the 101 reply", function()
    local client, writes = connect()

    client.tcp_handle._read_cb(nil, upgrade .. frame.create_frame(frame.OPCODE.TEXT, request, true, true))
    client.tcp_handle._read_cb(nil, nil) -- EOF in the same loop turn, before the 101 write callback
    writes[1].done()

    assert.same({}, handled)
    assert.equals(1, #writes)
    assert.are_not.equal("connected", client.state)
  end)

  it("does not run a request whose client hangs up before the main loop runs it", function()
    local client, writes = connect()
    client.tcp_handle._read_cb(nil, upgrade)
    writes[1].done()
    assert.equals("connected", client.state)
    scheduled = {}

    client.tcp_handle._read_cb(nil, frame.create_frame(frame.OPCODE.TEXT, request, true, true))
    client.tcp_handle._read_cb(nil, nil)
    run_scheduled()

    assert.same({}, handled)
  end)

  it("does not run a request that came in the same read as the client's Close frame", function()
    local client, writes = connect()
    client.tcp_handle._read_cb(nil, upgrade)
    writes[1].done()
    scheduled = {}

    client.tcp_handle._read_cb(
      nil,
      frame.create_frame(frame.OPCODE.TEXT, request, true, true)
        .. frame.create_frame(frame.OPCODE.CLOSE, "\3\232", true, true)
    )
    run_scheduled()

    assert.same({}, handled)
    local close = assert(frame.parse_frame(writes[2].data))
    assert.equals(frame.OPCODE.CLOSE, close.opcode)
  end)

  it("runs a request from a client that is still connected when the main loop runs it", function()
    local client, writes = connect()
    client.tcp_handle._read_cb(nil, upgrade)
    writes[1].done()
    scheduled = {}

    client.tcp_handle._read_cb(nil, frame.create_frame(frame.OPCODE.TEXT, request, true, true))
    run_scheduled()

    assert.same({ request }, handled)
  end)

  it("closes with 1001 and runs no request when the server stops before the 101 reply is written", function()
    local client, writes = connect()
    client.tcp_handle._read_cb(nil, upgrade .. frame.create_frame(frame.OPCODE.TEXT, request, true, true))

    server.stop()
    for _, write in ipairs(writes) do
      write.done()
    end

    assert.equals(2, #writes, "the 101 reply and a Close frame")
    local close = assert(frame.parse_frame(writes[2].data))
    assert.equals(frame.OPCODE.CLOSE, close.opcode)
    assert.equals(1001, close.payload:byte(1) * 256 + close.payload:byte(2))
    assert.is_true(client.tcp_handle:is_closing())
    assert.same({}, handled)
  end)
end)
