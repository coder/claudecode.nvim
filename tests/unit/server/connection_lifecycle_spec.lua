--- A client that the plugin is done with must leave the server promptly, be reported once and have its socket closed,
--- and a Claude that answers pings must never be dropped. These tests run the real tcp.lua and client.lua against a
--- socket that works like libuv's: a write callback runs only when the test calls `done` (a Claude that does not read
--- never completes a write), and a second close of a handle is an error.
require("tests.busted_setup")

describe("The lifecycle of a WebSocket connection", function()
  local tcp, frame, server, callbacks, scheduled
  local clock, saved
  local token = "test-token-0123456789"
  local interval = 30000

  local upgrade = "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
    .. "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n"
    .. "x-claude-code-ide-authorization: "
    .. token
    .. "\r\n\r\n"

  before_each(function()
    for _, name in ipairs({ "claudecode.server.client", "claudecode.server.tcp" }) do
      package.loaded[name] = nil
    end
    tcp = require("claudecode.server.tcp")
    frame = require("claudecode.server.frame")
    scheduled, clock = nil, 1000000
    saved = { schedule = vim.schedule, now = vim.loop.now, new_timer = vim.loop.new_timer }
    -- While `scheduled` is a list, scheduled callbacks wait in it, as they wait for the main loop in Neovim.
    vim.schedule = function(fn)
      if scheduled then
        table.insert(scheduled, fn)
      else
        fn()
      end
    end
    vim.loop.now = function()
      return clock
    end
    callbacks = {
      on_message = spy.new(function() end),
      on_connect = spy.new(function() end),
      on_disconnect = spy.new(function() end),
      on_error = spy.new(function() end),
    }
    local err
    server, err = tcp.create_server({ port_range = { min = 10000, max = 65535 } }, callbacks, token)
    assert(server, err)
  end)

  after_each(function()
    vim.schedule, vim.loop.now, vim.loop.new_timer = saved.schedule, saved.now, saved.new_timer
  end)

  ---Accept a connection whose socket works like libuv's.
  ---@return table client
  ---@return table writes Each write: { data = string, done = function(err) }
  ---@return table handle
  local function connect()
    tcp._handle_new_connection(server)
    local client = assert(server.clients["client_" .. _G.claudecode_clients_created])
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
    return client, writes, handle
  end

  ---Accept a connection and finish its handshake: the upgrade request is read and the 101 reply is written.
  local function connect_and_upgrade()
    local client, writes, handle = connect()
    handle._read_cb(nil, upgrade)
    writes[1].done()
    assert.equals("connected", client.state)
    return client, writes, handle
  end

  local function run_scheduled()
    local queue = scheduled
    scheduled = nil
    for _, fn in ipairs(queue) do
      fn()
    end
  end

  ---Start the ping timer on the server, and return the function that runs on each tick.
  local function start_ping_timer()
    local tick
    vim.loop.new_timer = function()
      return {
        start = function(_, _, _, callback)
          tick = callback
        end,
        stop = function() end,
        close = function() end,
      }
    end
    tcp.start_ping_timer(server, interval)
    vim.loop.new_timer = saved.new_timer
    return tick
  end

  local function parse(write)
    return assert(frame.parse_frame(write.data))
  end

  local function close_status(write)
    local close = parse(write)
    assert.equals(frame.OPCODE.CLOSE, close.opcode)
    return close.payload:byte(1) * 256 + close.payload:byte(2)
  end

  describe("when Neovim's main loop is blocked during a client's handshake", function()
    it("gives the client a fresh keepalive window once it is connected, so it is pinged and not dropped", function()
      local tick = start_ping_timer()
      local client, writes, handle = connect()

      -- Neovim is blocked for 100 s right after the accept. The timer runs first when the loop is free again, and
      -- sees the gap. Claude's upgrade request is read after it.
      clock = clock + 100000
      tick()
      handle._read_cb(nil, upgrade)
      writes[1].done()
      assert.equals("connected", client.state)

      -- One interval later, Claude has been connected for one interval and no ping reached it yet.
      clock = clock + interval
      tick()

      assert.is_not_nil(server.clients[client.id], "the client was dropped")
      assert.spy(callbacks.on_disconnect).was_not_called()
      assert.equals(2, #writes, "the 101 reply and a ping")
      assert.equals(frame.OPCODE.PING, parse(writes[2]).opcode)
    end)

    it("still drops a client that never answers, at the second tick that finds no pong", function()
      local tick = start_ping_timer()
      local client, writes, handle = connect_and_upgrade()

      clock = clock + interval
      tick() -- the client is 1 interval old: a ping
      clock = clock + interval
      tick() -- no pong for 2 intervals: the first such tick pings again and does not drop
      assert.is_not_nil(server.clients[client.id], "the client was dropped at the first tick that found no pong")
      assert.equals(frame.OPCODE.PING, parse(writes[#writes]).opcode)
      clock = clock + interval
      tick() -- still no pong: the second such tick drops the client

      assert.is_nil(server.clients[client.id])
      assert.spy(callbacks.on_disconnect).was_called_with(client, 1006, "Connection timeout")
      assert.equals(1011, close_status(writes[#writes]))
      assert.is_true(handle:is_closing())
    end)
  end)

  describe("when the ping timer runs late, below the wake threshold, with Claude's pong still unread", function()
    -- A tick that Neovim runs late can run before the socket read (on Neovim 0.8 after any block, on newer Neovim
    -- after a block inside a libuv callback that runs after the poll phase, such as a check callback), and then finds
    -- the pong of the last ping still in the socket. Its last_pong is a whole interval older than at the tick before
    -- it. A block of up to 1.5 intervals is not a wake, so last_pong is not reset.
    it("does not drop a Claude that answers every ping, and forgets the late tick once Claude answers", function()
      local tick = start_ping_timer()
      local client, writes, handle = connect_and_upgrade()
      local pong = frame.create_frame(frame.OPCODE.PONG, "ping", true, true)

      clock = clock + interval
      tick()
      handle._read_cb(nil, pong)
      clock = clock + interval
      tick() -- Neovim blocks right after this ping, before it reads the pong, for 1.3 intervals
      clock = clock + 1.3 * interval
      tick()

      assert.is_not_nil(server.clients[client.id], "the client was dropped by a late tick")
      assert.spy(callbacks.on_disconnect).was_not_called()
      handle._read_cb(nil, pong) -- the loop reads the pong after the late tick
      clock = clock + interval
      tick()
      clock = clock + 1.3 * interval -- a second late tick, again with the pong unread
      tick()

      assert.is_not_nil(server.clients[client.id], "the first late tick counted against the second one")
      assert.spy(callbacks.on_disconnect).was_not_called()
      assert.equals(frame.OPCODE.PING, parse(writes[#writes]).opcode)
    end)
  end)

  describe("when Claude stops reading, a large message fills its window and Claude breaks the protocol", function()
    local cases = {
      {
        name = "a binary message",
        status = 1003,
        reason = "Client error: Binary messages not supported",
        bytes = function()
          return frame.create_frame(frame.OPCODE.BINARY, "x", true, true)
        end,
      },
      {
        name = "a reserved opcode",
        status = 1002,
        reason = "Client error: Reserved opcode 0x3", -- frame.parse_frame is the only check of an opcode
        bytes = function()
          return string.char(0x83, 0x00)
        end,
      },
      {
        name = "a text message that is not UTF-8",
        status = 1007,
        reason = "Client error: Invalid UTF-8 in text message",
        bytes = function()
          return string.char(0x81, 0x02, 0xFF, 0xFE)
        end,
      },
    }

    for _, case in ipairs(cases) do
      it("reports " .. case.name .. " at once, and closes the socket only once its Close frame is written", function()
        local client, writes, handle = connect_and_upgrade()
        tcp.send_to_client(server, client.id, string.rep("x", 262144)) -- the write waits: Claude does not read
        assert.equals(2, #writes)

        handle._read_cb(nil, case.bytes())

        -- The client is reported and gone from the server while the Close frame still waits behind the big message.
        assert.spy(callbacks.on_disconnect).was_called(1)
        assert.spy(callbacks.on_disconnect).was_called_with(client, 1006, case.reason)
        assert.is_nil(server.clients[client.id])
        assert.equals(3, #writes, "the 101 reply, the big message and a Close frame")
        assert.equals(case.status, close_status(writes[3]))
        assert.is_false(handle:is_closing(), "the socket was closed before the Close frame was written")

        -- Claude reads again: libuv writes the queue, then the socket closes, and Claude's hang-up reports nothing
        -- more.
        for _, write in ipairs(writes) do
          write.done()
        end
        assert.is_true(handle:is_closing())
        handle._read_cb(nil, nil)
        assert.spy(callbacks.on_disconnect).was_called(1)
      end)
    end
  end)

  describe("when the server stops right after Claude's Close frame was read", function()
    it("closes the socket of the client that left the server before its on_close ran", function()
      local client, writes, handle = connect_and_upgrade()
      scheduled = {}

      handle._read_cb(nil, frame.create_frame(frame.OPCODE.CLOSE, "\3\232", true, true)) -- on_close waits for the loop
      assert.equals("closing", client.state)
      assert.equals(frame.OPCODE.CLOSE, parse(writes[2]).opcode, "the reply to Claude's Close frame")
      tcp.stop_server(server)
      run_scheduled()
      handle._read_cb(nil, nil) -- Claude hangs up

      assert.is_true(handle:is_closing(), "the socket was left open")
      assert.spy(callbacks.on_disconnect).was_not_called()
    end)

    it("still writes the Close frame of a stop before it closes the socket of a Claude that hangs up first", function()
      local client, writes, handle = connect_and_upgrade()

      tcp.stop_server(server)
      handle._read_cb(nil, nil) -- Claude hangs up before the Close frame is written
      assert.is_false(handle:is_closing(), "the socket was closed before the Close frame was written")
      writes[2].done()

      assert.equals(1001, close_status(writes[2]))
      assert.is_true(handle:is_closing())
      assert.is_nil(server.clients[client.id])
    end)
  end)

  describe("when the ping timer drops a client whose window is full", function()
    it("closes the socket at once, without waiting for a Claude that does not read", function()
      local tick = start_ping_timer()
      local client, writes, handle = connect_and_upgrade()
      tcp.send_to_client(server, client.id, string.rep("x", 262144))

      for _ = 1, 3 do
        clock = clock + interval
        tick()
      end

      assert.is_nil(server.clients[client.id])
      assert.spy(callbacks.on_disconnect).was_called(1)
      assert.equals(1011, close_status(writes[#writes]))
      assert.is_true(handle:is_closing(), "the socket waits for a Claude that does not read")
    end)
  end)
end)
