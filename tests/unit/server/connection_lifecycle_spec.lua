--- A client that the plugin is done with must leave the server promptly, be reported once and have its socket closed,
--- and a Claude that answers pings must never be dropped. These tests run the real tcp.lua and client.lua against a
--- socket that works like libuv's: a write callback runs only when the test calls `done` (a Claude that does not read
--- never completes a write), and a second close of a handle is an error. The loop time is cached at the start of a pass
--- of the main loop, and a check handle runs after the pass has read the sockets, as in libuv.
require("tests.busted_setup")

describe("The lifecycle of a WebSocket connection", function()
  local tcp, frame, server, callbacks, scheduled
  local clock, cached, checks, saved
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
    scheduled, clock, checks = nil, 1000000, {}
    cached = clock
    saved = {
      schedule = vim.schedule,
      now = vim.loop.now,
      new_timer = vim.loop.new_timer,
      new_check = vim.loop.new_check,
      update_time = vim.loop.update_time,
    }
    -- While `scheduled` is a list, scheduled callbacks wait in it, as they wait for the main loop in Neovim.
    vim.schedule = function(fn)
      if scheduled then
        table.insert(scheduled, fn)
      else
        fn()
      end
    end
    -- `clock` is the time of the world. `cached` is the loop time: libuv sets it from `clock` when a pass of the main loop
    -- starts, and after the poll that reads the sockets. A callback that blocks does not move it.
    vim.loop.now = function()
      return cached
    end
    vim.loop.update_time = function()
      cached = clock
    end
    vim.loop.new_check = function()
      local handle = {}
      function handle:start(callback)
        self.callback = callback
        table.insert(checks, self)
      end
      function handle:stop()
        self.callback, self.stopped = nil, true
      end
      function handle:close()
        self.closed = true
      end
      return handle
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
    vim.loop.new_check, vim.loop.update_time = saved.new_check, saved.update_time
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

  ---Start the ping timer on the server, and return the function that runs on each tick. A tick runs at the start of a
  ---pass of the main loop, or at its end (libuv 1.44 runs the timers again after the check handles): the loop time is
  ---the time of the world, unless `after_block` of the pass is set.
  ---@return function tick Runs the timer callback. `tick(block)`: a callback that ran before it in its pass blocked for
  ---`block` ms, so the loop time is that old
  local function start_ping_timer()
    local callback
    vim.loop.new_timer = function()
      return {
        start = function(_, _, _, timer_callback)
          callback = timer_callback
        end,
        stop = function() end,
        close = function() end,
      }
    end
    tcp.start_ping_timer(server, interval)
    vim.loop.new_timer = saved.new_timer
    return function(block)
      cached = clock
      clock = clock + (block or 0)
      callback()
    end
  end

  ---The poll of a pass of the main loop, with the read of Claude's socket that the test makes, then the check handles
  ---that the ticks since the last poll started.
  ---@param handle table|nil The socket of the client that Claude wrote to
  ---@param data string|nil What Claude wrote
  local function poll(handle, data)
    cached = clock
    if handle then
      handle._read_cb(nil, data)
    end
    local pending = checks
    checks = {}
    for _, check in ipairs(pending) do
      check.callback()
      assert.is_true(check.stopped and check.closed, "a check handle stayed running or open after it ran")
    end
  end

  local function pong()
    return frame.create_frame(frame.OPCODE.PONG, "ping", true, true)
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
  end)

  describe("when a Claude never answers a ping", function()
    it("drops it at the first read of its socket after the fourth tick, and not at the tick", function()
      local tick = start_ping_timer()
      local client, writes, handle = connect_and_upgrade()

      clock = clock + interval
      tick() -- the first ping
      poll()
      for _ = 1, 2 do
        clock = clock + interval
        tick() -- the first ping is 1, then 2 intervals old
        poll()
      end
      assert.is_not_nil(server.clients[client.id], "the client was dropped before its ping was 2.5 intervals old")
      clock = clock + interval
      tick() -- the first ping is 3 intervals old, and Neovim did not read the socket since this tick
      assert.is_not_nil(server.clients[client.id], "a tick dropped the client before the socket was read")
      assert.spy(callbacks.on_disconnect).was_not_called()
      poll()

      assert.is_nil(server.clients[client.id])
      assert.spy(callbacks.on_disconnect).was_called_with(client, 1006, "Connection timeout")
      assert.equals(1011, close_status(writes[#writes]))
      assert.is_true(handle:is_closing())
    end)

    it("drops it at the first read after a late tick that finds its ping 2.5 intervals old", function()
      local tick = start_ping_timer()
      local client = connect_and_upgrade()

      clock = clock + interval
      tick()
      poll()
      clock = clock + 1.3 * interval
      tick()
      poll() -- the first ping is 1.3 intervals old
      assert.is_not_nil(server.clients[client.id])
      clock = clock + 1.3 * interval
      tick()
      poll() -- the first ping is 2.6 intervals old: the third tick is not needed

      assert.is_nil(server.clients[client.id])
    end)

    it("counts the time from the first ping that went unanswered, after Claude answered before", function()
      local tick = start_ping_timer()
      local client, _, handle = connect_and_upgrade()

      clock = clock + interval
      tick()
      poll(handle, pong()) -- Claude answers the first ping
      for _ = 1, 4 do
        clock = clock + interval
        tick()
        assert.is_not_nil(server.clients[client.id])
        poll()
      end

      assert.is_nil(server.clients[client.id], "the ping of the second tick was unanswered for 3 intervals")
    end)

    it("does not drop a Claude whose pong waits in the socket when its ping is 3 intervals old", function()
      local tick = start_ping_timer()
      local client, _, handle = connect_and_upgrade()

      clock = clock + interval
      tick()
      poll() -- Claude answers after this poll
      for _ = 1, 2 do
        clock = clock + interval
        tick()
        poll()
      end
      clock = clock + interval
      tick() -- the ping of the first tick is 3 intervals old, and its pong was not read yet
      poll(handle, pong())

      assert.is_not_nil(server.clients[client.id], "the check ran before the pong was read")
      assert.spy(callbacks.on_disconnect).was_not_called()
    end)
  end)

  describe("when the main loop blocks before the pongs of a Claude that answers every ping are read", function()
    -- libuv runs timers before it reads sockets, and Neovim 0.8 (libuv 1.44) runs the timers a second time at the end
    -- of a pass, after the check handles. A tick that Neovim runs late after a block finds the pongs of the last pings
    -- unread, and two late ticks can run with no read between them.
    it("does not drop it when two late ticks run with no read between them", function()
      local tick = start_ping_timer()
      local client, _, handle = connect_and_upgrade()

      clock = clock + interval
      tick()
      poll() -- Claude answers after this poll
      clock = clock + interval
      tick()
      poll(handle, pong())
      clock = clock + interval
      tick() -- ping 3
      poll()
      -- A check callback blocks for 1.3 intervals right after the ping. The timers run again at the end of the pass, and
      -- a vim.schedule callback blocks for 1.3 intervals before the next pass reads the socket.
      clock = clock + 1.3 * interval
      tick()
      clock = clock + 1.3 * interval
      tick()
      assert.is_not_nil(server.clients[client.id], "a late tick dropped the client")

      poll(handle, pong() .. pong() .. pong())

      assert.is_not_nil(server.clients[client.id], "the check of a late tick dropped the client")
      assert.spy(callbacks.on_disconnect).was_not_called()
    end)

    it("does not drop it however many late ticks run with no read between them", function()
      local tick = start_ping_timer()
      local client, _, handle = connect_and_upgrade()

      for _ = 1, 20 do
        clock = clock + 1.3 * interval
        tick()
      end
      assert.is_not_nil(server.clients[client.id], "a late tick dropped the client")
      poll(handle, pong() .. pong() .. pong())

      assert.is_not_nil(server.clients[client.id], "the check of a late tick dropped the client")
      assert.spy(callbacks.on_disconnect).was_not_called()
    end)

    it(
      "stamps a ping with the time of the world, not the loop time cached before an earlier callback blocked",
      function()
        local tick = start_ping_timer()
        local client = connect_and_upgrade()

        clock = clock + interval
        tick(100000) -- a timer that ran before the ping timer in this pass blocked for 100 s
        poll() -- Claude had no time to answer yet

        assert.is_not_nil(server.clients[client.id], "the ping was dropped for the age of the loop time")
      end
    )

    it("forgets the pings that went unanswered when Neovim wakes from sleep", function()
      local tick = start_ping_timer()
      local client, _, handle = connect_and_upgrade()

      clock = clock + interval
      tick()
      poll()
      clock = clock + interval
      tick()
      poll()
      clock = clock + 10 * interval -- the machine slept: Claude slept too, and answers once it is awake
      tick()
      poll()
      assert.is_not_nil(server.clients[client.id], "the wake was not forgiven")
      poll(handle, pong())

      assert.is_not_nil(server.clients[client.id])
    end)
  end)

  describe("when a client leaves between a tick and the check that follows it", function()
    local one_line

    before_each(function()
      one_line = spy.on(require("claudecode.logger"), "one_line")
    end)

    after_each(function()
      one_line:revert()
    end)

    ---Four ticks, with a poll after each but the last. Claude never answered: at the fourth tick its oldest ping is 3
    ---intervals old, and the check of that tick is the next to run.
    local function tick_four_times(tick)
      for round = 1, 4 do
        clock = clock + interval
        tick()
        if round < 4 then
          poll()
        end
      end
    end

    it("does not report a client that hung up, and logs nothing about it", function()
      local tick = start_ping_timer()
      local client, _, handle = connect_and_upgrade()
      tick_four_times(tick)

      handle._read_cb(nil, nil) -- Claude hangs up before the pass reads anything else
      assert.spy(callbacks.on_disconnect).was_called(1)
      assert.spy(callbacks.on_disconnect).was_called_with(client, 1006, "EOF")
      poll()

      assert.spy(callbacks.on_disconnect).was_called(1)
      assert.spy(one_line).was_not_called()
    end)

    it("does not drop a client that is closing", function()
      local tick = start_ping_timer()
      local client, writes, handle = connect_and_upgrade()
      tick_four_times(tick)
      scheduled = {} -- on_close waits for the loop
      handle._read_cb(nil, frame.create_frame(frame.OPCODE.CLOSE, "\3\232", true, true))
      assert.equals("closing", client.state)
      local written = #writes
      poll()

      assert.equals(written, #writes, "a Close frame followed the reply to Claude's Close frame")
      assert.spy(callbacks.on_disconnect).was_not_called()
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

        -- Claude reads again: libuv writes the queue, then the socket closes, and Claude's hang-up reports nothing more.
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

      for _ = 1, 4 do
        clock = clock + interval
        tick()
        poll()
      end

      assert.is_nil(server.clients[client.id])
      assert.spy(callbacks.on_disconnect).was_called(1)
      assert.equals(1011, close_status(writes[#writes]))
      assert.is_true(handle:is_closing(), "the socket waits for a Claude that does not read")
    end)
  end)
end)
