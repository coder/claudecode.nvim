--- A client that the plugin is done with must leave the server promptly, be reported once and have its socket closed,
--- and a Claude that answers pings must never be dropped. These tests run the real tcp.lua and client.lua against a
--- socket that works like libuv's: a write callback runs only when the test calls `done` (a Claude that does not read
--- never completes a write), and a second close of a handle is an error.
require("tests.busted_setup")

describe("The lifecycle of a WebSocket connection", function()
  local tcp, frame, utils, server, callbacks, scheduled
  local clock, saved, timers, prepares, checks
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
    scheduled, clock, timers, prepares, checks = nil, 1000000, {}, {}, {}
    utils = require("claudecode.utils")
    saved = {
      schedule = vim.schedule,
      now = vim.loop.now,
      new_timer = vim.loop.new_timer,
      new_prepare = vim.loop.new_prepare,
      new_check = vim.loop.new_check,
      valid_utf8 = utils.valid_utf8,
    }
    -- `send_message` scans each outbound text with `utils.valid_utf8`, byte by byte in Lua. Under luacov every byte costs
    -- a line hook, so the multi-MiB messages of these tests took minutes in CI. They check how a message is queued and
    -- when its client is dropped, not its encoding: `send_utf8_spec.lua` tests that.
    utils.valid_utf8 = function(text)
      return text
    end
    -- Each timer waits for the test to run it, and records how it ended. The ping timer is one of them.
    vim.loop.new_timer = function()
      local timer = { stopped = false, closed = false }
      function timer:start(delay, repeat_ms, callback)
        self.delay, self.repeat_ms, self.callback = delay, repeat_ms, callback
      end
      function timer:stop()
        self.stopped = true
      end
      function timer:close()
        self.closed = true
      end
      table.insert(timers, timer)
      return timer
    end
    -- libuv runs a prepare callback at the start of the poll phase of a loop iteration and a check callback after it. These
    -- handles run when the test calls `poll()`, and record how they ended.
    local function fake_handle(list)
      return function()
        local handle = { active = false, closed = false }
        function handle:start(callback)
          self.active, self.callback = true, callback
          return true
        end
        function handle:stop()
          self.active = false
          return true
        end
        function handle:close()
          assert(not self.closed, "handle is already closing")
          self.closed, self.active = true, false
        end
        function handle:is_closing()
          return self.closed
        end
        table.insert(list, handle)
        return handle
      end
    end
    vim.loop.new_prepare = fake_handle(prepares)
    vim.loop.new_check = fake_handle(checks)
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
    vim.loop.new_prepare, vim.loop.new_check = saved.new_prepare, saved.new_check
    utils.valid_utf8 = saved.valid_utf8
  end)

  ---Accept a connection whose socket works like libuv's. `handle:get_write_queue_size()` counts the bytes of the writes
  ---that wait, and `handle.drain(n)` lets the kernel accept `n` bytes of them, the oldest write first.
  ---@return table client
  ---@return table writes Each write: { data = string, left = integer, done = function(err) }
  ---@return table handle
  local function connect()
    tcp._handle_new_connection(server)
    local client = assert(server.clients["client_" .. _G.claudecode_clients_created])
    local handle, writes = client.tcp_handle, {}
    local closed = false
    function handle:write(data, callback)
      assert(not closed, "write after close")
      local write = { data = data, left = #data }
      function write.done(err)
        write.left = 0
        if callback then
          callback(err)
        end
      end
      table.insert(writes, write)
    end
    function handle:get_write_queue_size()
      local size = 0
      for _, write in ipairs(writes) do
        size = size + write.left
      end
      return size
    end
    function handle.drain(bytes)
      for _, write in ipairs(writes) do
        local taken = math.min(write.left, bytes)
        write.left, bytes = write.left - taken, bytes - taken
        if taken > 0 and write.left == 0 then
          write.done()
        end
      end
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
  ---One poll phase of the loop: the armed prepare callbacks run, then libuv polls its sockets (`during` runs, and
  ---reports what Claude read), then the armed check callbacks run.
  ---@param during function|nil What libuv reports while it polls
  local function poll(during)
    for _, handle in ipairs(prepares) do
      if handle.active then
        handle.callback()
      end
    end
    if during then
      during()
    end
    for _, handle in ipairs(checks) do
      if handle.active then
        handle.callback()
      end
    end
  end

  ---Start the ping timer. The first result runs one loop iteration: the timer callback, then a poll phase. The second
  ---result runs the timer callback alone, as a tick that libuv runs before it polls.
  local function start_ping_timer()
    local before = #timers
    tcp.start_ping_timer(server, interval)
    assert.equals(before + 1, #timers)
    local ping_timer = timers[#timers]
    return function()
      ping_timer.callback()
      poll()
    end, ping_timer.callback
  end

  ---The timer that waits for the Close frame of a client. It repeats every keepalive window, two ping intervals, and
  ---the ping timer every interval.
  local function close_deadline()
    local deadlines = {}
    for _, timer in ipairs(timers) do
      if timer.repeat_ms == 2 * interval then
        table.insert(deadlines, timer)
      end
    end
    assert.equals(1, #deadlines, "no deadline waits for the Close frame")
    return deadlines[1]
  end

  ---One keepalive window passes and the timer runs.
  local function run_after_window(timer)
    clock = clock + timer.repeat_ms
    timer.callback()
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
    -- libuv runs timers before it reads sockets. A tick that Neovim runs late after a block finds the pong of the last ping
    -- still in the socket, so its last_pong is a whole interval older than the tick before it. A block of up to 1.5
    -- intervals is not a wake, so last_pong is not reset.
    it("does not drop a Claude that answers every ping, and forgets the late tick once Claude answers", function()
      local tick = start_ping_timer()
      local client, writes, handle = connect_and_upgrade()
      local pong = frame.create_frame(frame.OPCODE.PONG, "ping", true, true)
      -- A Claude answers a ping after it read it, so libuv has written the pings queued for it by then.
      local function claude_pongs()
        handle.drain(math.huge)
        handle._read_cb(nil, pong)
      end

      clock = clock + interval
      tick()
      claude_pongs()
      clock = clock + interval
      tick() -- Neovim blocks right after this ping, before it reads the pong, for 1.3 intervals
      clock = clock + 1.3 * interval
      tick()

      assert.is_not_nil(server.clients[client.id], "the client was dropped by a late tick")
      assert.spy(callbacks.on_disconnect).was_not_called()
      claude_pongs() -- the loop reads the pong after the late tick
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

  -- A PONG keeps the keepalive window open, so only the write queue can show that Claude stopped reading. The queue
  -- counts as stalled when two observations in a row, one per ping tick, found that libuv wrote no byte of it.
  describe("when Claude answers each ping but stops reading", function()
    local reply = string.rep("x", 262144)

    ---Claude's PONG reaches the server, then one interval passes and the ping timer runs.
    local function pong_and_tick(tick, handle)
      handle._read_cb(nil, frame.create_frame(frame.OPCODE.PONG, "", true, true))
      clock = clock + interval
      tick()
    end

    it("closes the client once the write queue stalls for two intervals, and frees the queue", function()
      local tick = start_ping_timer()
      local client, writes, handle = connect_and_upgrade()

      -- Every interval Neovim queues another reply, and Claude reads none of them.
      for _ = 1, 2 do
        tcp.send_to_client(server, client.id, reply)
        pong_and_tick(tick, handle)
      end
      assert.is_not_nil(server.clients[client.id], "the client was dropped before the window ended")
      assert.is_true(handle:get_write_queue_size() > 2 * #reply)

      tcp.send_to_client(server, client.id, reply)
      pong_and_tick(tick, handle)

      assert.is_nil(server.clients[client.id])
      assert.spy(callbacks.on_disconnect).was_called(1)
      assert.spy(callbacks.on_disconnect).was_called_with(client, 1006, "Write queue stalled")
      assert.equals(1011, close_status(writes[#writes]))
      assert.is_true(handle:is_closing(), "the socket still holds the queue")
    end)

    it("reports the stall as one info line", function()
      local logger = require("claudecode.logger")
      local lines = {}
      local saved_one_line = logger.one_line
      logger.one_line = function(level, component, text)
        table.insert(lines, { level = level, component = component, text = text })
      end
      local tick = start_ping_timer()
      local client, _, handle = connect_and_upgrade()
      tcp.send_to_client(server, client.id, reply)

      for _ = 1, 3 do
        pong_and_tick(tick, handle)
      end
      logger.one_line = saved_one_line

      assert.same({
        {
          level = "info",
          component = "server",
          text = "Closed " .. client.id .. ": not reading for 60s, 256 KB queued",
        },
      }, lines)
    end)

    it("keeps a client that reads slowly, although its queue keeps growing", function()
      local tick = start_ping_timer()
      local client, _, handle = connect_and_upgrade()

      -- Neovim queues a reply every interval and the kernel takes 1 KB of the queue: Claude reads, but slowly.
      for _ = 1, 20 do
        tcp.send_to_client(server, client.id, reply)
        handle.drain(1024)
        pong_and_tick(tick, handle)
      end

      assert.is_not_nil(server.clients[client.id], "a Claude that reads was dropped")
      assert.spy(callbacks.on_disconnect).was_not_called()
      assert.is_true(handle:get_write_queue_size() > 19 * #reply)
    end)

    it("keeps a client that is sent one large message, however long it takes to read", function()
      local tick = start_ping_timer()
      local client, _, handle = connect_and_upgrade()
      local large = string.rep("x", 16 * 1024 * 1024)
      tcp.send_to_client(server, client.id, large)

      -- Claude reads 1 MB per interval, so the message needs 16 intervals, many times the window.
      for _ = 1, 20 do
        handle.drain(1024 * 1024)
        pong_and_tick(tick, handle)
      end

      assert.is_not_nil(server.clients[client.id], "a Claude that reads one large message was dropped")
      assert.spy(callbacks.on_disconnect).was_not_called()
      assert.is_true(handle:get_write_queue_size() < 1024, "only the pings of the last intervals are left")
    end)

    it("counts the window from the last byte Claude read, not from the connection", function()
      local tick = start_ping_timer()
      local client, _, handle = connect_and_upgrade()
      tcp.send_to_client(server, client.id, reply)

      -- Claude reads for five intervals. Then it stops.
      for _ = 1, 5 do
        handle.drain(1024)
        pong_and_tick(tick, handle)
      end
      assert.is_not_nil(server.clients[client.id])
      pong_and_tick(tick, handle) -- no progress for one interval
      assert.is_not_nil(server.clients[client.id], "the window ended after one interval")
      pong_and_tick(tick, handle) -- no progress for two

      assert.is_nil(server.clients[client.id])
    end)

    it("keeps a client that reads every ping, so that its queue is empty at each tick", function()
      local tick = start_ping_timer()
      local client, _, handle = connect_and_upgrade()

      for _ = 1, 10 do
        handle.drain(math.huge)
        pong_and_tick(tick, handle)
      end

      assert.is_not_nil(server.clients[client.id])
      assert.spy(callbacks.on_disconnect).was_not_called()
    end)

    it("gives the client a fresh window after Neovim slept, as it does for the keepalive", function()
      local tick = start_ping_timer()
      local client, _, handle = connect_and_upgrade()
      tcp.send_to_client(server, client.id, reply)
      pong_and_tick(tick, handle)

      -- The machine sleeps for ten minutes. The timer runs first when it wakes, before Claude could read.
      clock = clock + 600000
      tick()
      assert.is_not_nil(server.clients[client.id], "the sleep counted against the client")

      pong_and_tick(tick, handle)
      assert.is_not_nil(server.clients[client.id], "the window did not restart at the wake")
      pong_and_tick(tick, handle)

      assert.is_nil(server.clients[client.id])
    end)
  end)

  -- Two rules judge a connected client on each ping tick. The pong rule gives a client without a pong one more tick
  -- (`pong_overdue`) and then drops it. The stall rule drops a client that answers, whose write queue made no progress at
  -- two observations in a row. The pong rule runs first, so only a client that answers is judged for a stall.
  describe("when a client misses a pong and its write queue stalls", function()
    local reply = string.rep("x", 262144)

    local function pong(handle)
      handle._read_cb(nil, frame.create_frame(frame.OPCODE.PONG, "", true, true))
    end

    ---Start a client whose queue never drains, which answers the first tick and the third, and not the second.
    local function stalled_client_that_misses_a_pong()
      local tick = start_ping_timer()
      local client, writes, handle = connect_and_upgrade()
      tcp.send_to_client(server, client.id, reply)
      pong(handle)
      clock = clock + interval
      tick() -- the 101 reply was written: that is progress, and the last one
      clock = clock + interval
      tick() -- no pong for two intervals: the second chance
      return tick, client, writes, handle
    end

    it("gives a silent client its second chance although its queue stalled too, then drops it for the pong", function()
      local client_manager = require("claudecode.server.client")
      local tick = start_ping_timer()
      local client, writes, handle = connect_and_upgrade()
      tcp.send_to_client(server, client.id, reply)
      -- No pong for two intervals and no byte written for two ticks: both rules find this client dead at the first tick.
      client.last_pong = clock - 2 * interval
      client.last_drain = clock - 3 * interval
      client.drained_bytes = client.queued_bytes - handle:get_write_queue_size()
      client.write_stalled = true -- the tick before found no progress either
      assert.is_false(client_manager.is_client_alive(client, 2 * interval))
      assert.is_false(client_manager.is_client_reading(client))

      tick()

      assert.is_not_nil(server.clients[client.id], "the stall skipped the second chance of the pong rule")
      assert.is_true(client.pong_overdue)
      assert.equals(frame.OPCODE.PING, parse(writes[#writes]).opcode)

      clock = clock + interval
      tick()

      assert.is_nil(server.clients[client.id])
      assert.spy(callbacks.on_disconnect).was_called(1)
      assert.spy(callbacks.on_disconnect).was_called_with(client, 1006, "Connection timeout")
      assert.equals(1011, close_status(writes[#writes]))
      assert.equals("Keepalive timeout", parse(writes[#writes]).payload:sub(3))
      assert.is_true(handle:is_closing())
    end)

    it("drops a client for the stall when its pong arrives, because the pong does not save a stalled queue", function()
      local tick, client, writes, handle = stalled_client_that_misses_a_pong()
      assert.is_true(client.pong_overdue)

      pong(handle) -- the late pong is read, but nothing of the queue is written
      clock = clock + interval
      tick()

      assert.is_nil(client.pong_overdue, "the tick that found the pong kept the flag")
      assert.is_nil(server.clients[client.id])
      assert.spy(callbacks.on_disconnect).was_called(1)
      assert.spy(callbacks.on_disconnect).was_called_with(client, 1006, "Write queue stalled")
      assert.equals("Not reading", parse(writes[#writes]).payload:sub(3))
    end)

    it("keeps a client whose pong arrives while its queue drains, and clears the flag", function()
      local tick = start_ping_timer()
      local client, _, handle = connect_and_upgrade()
      tcp.send_to_client(server, client.id, reply)
      pong(handle)
      clock = clock + interval
      tick()
      clock = clock + interval
      tick() -- no pong: the second chance
      assert.is_true(client.pong_overdue)

      handle.drain(1024) -- Claude reads a little, and answers
      pong(handle)
      clock = clock + interval
      tick()

      assert.is_nil(client.pong_overdue)
      assert.is_not_nil(server.clients[client.id])
      assert.spy(callbacks.on_disconnect).was_not_called()
    end)

    it("clears both flags and restarts the stall window when the machine wakes from sleep", function()
      local tick, client, _, handle = stalled_client_that_misses_a_pong()
      assert.is_true(client.pong_overdue)
      assert.is_true(client.write_stalled)

      clock = clock + 600000 -- the machine slept for ten minutes, and the timer runs first when it wakes
      tick()
      assert.is_nil(client.pong_overdue, "the wake kept the flag")
      assert.is_nil(client.write_stalled, "the wake kept the stall count")
      assert.is_not_nil(server.clients[client.id], "the sleep counted against the client")

      pong(handle)
      clock = clock + interval
      tick()
      assert.is_not_nil(server.clients[client.id], "the stall window did not restart at the wake")
      pong(handle)
      clock = clock + interval
      tick()

      assert.is_nil(server.clients[client.id])
      assert.spy(callbacks.on_disconnect).was_called_with(client, 1006, "Write queue stalled")
    end)
  end)

  -- libuv reports that a socket is writable again only in a poll phase. A main-loop block inside an I/O callback can
  -- make a ping tick run before that poll, so the tick finds no write progress although Claude read during the block.
  -- A tick therefore only asks for an observation, which is taken in the check callback after a poll phase that began
  -- after the tick. The stall count (`write_stalled`) changes only there, and the second observation in a row without
  -- progress drops the client, however late the ticks come.
  describe("when the write queue is observed after a fresh poll phase", function()
    local pong

    before_each(function()
      pong = frame.create_frame(frame.OPCODE.PONG, "", true, true)
    end)

    ---A client with a queued reply that Claude does not read, and one tick that saw the 101 reply as progress.
    local function stalled_client()
      local tick, raw_tick = start_ping_timer()
      local client, _, handle = connect_and_upgrade()
      tcp.send_to_client(server, client.id, string.rep("x", 262144))
      handle._read_cb(nil, pong)
      clock = clock + interval
      tick()
      return tick, raw_tick, client, handle
    end

    local function answer_and(run, gap)
      return function(handle)
        handle._read_cb(nil, pong)
        clock = clock + gap * interval
        run()
      end
    end

    it("keeps a reading client until libuv can report the bytes it read during the block", function()
      local tick, raw_tick, client, handle = stalled_client()
      answer_and(tick, 1)(handle) -- no write progress for one interval: the first observation that counts
      assert.is_true(client.write_stalled)

      -- A libuv I/O callback blocks for 1.3 intervals. Claude reads during the block. The late tick runs before the next
      -- poll phase can account for the newly writable socket, while the last pong is still within its window.
      answer_and(raw_tick, 1.3)(handle)
      assert.is_not_nil(server.clients[client.id], "the late tick dropped a reader before libuv reported its progress")
      poll(function()
        handle.drain(1024) -- the poll phase reports the bytes that Claude read
      end)

      assert.is_not_nil(server.clients[client.id], "the observation after the poll dropped a reader that made progress")
      assert.is_nil(client.write_stalled)
      assert.spy(callbacks.on_disconnect).was_not_called()
    end)

    it("does not drop a client at a tick without a poll phase after it, however stalled the queue is", function()
      local tick, raw_tick, client, handle = stalled_client()
      answer_and(tick, 1)(handle)
      assert.is_true(client.write_stalled)

      answer_and(raw_tick, 1)(handle) -- the second tick without progress, and no poll phase yet
      assert.is_not_nil(server.clients[client.id], "the tick dropped the client before a fresh poll")
      assert.spy(callbacks.on_disconnect).was_not_called()

      poll() -- the poll phase reports nothing: the second observation without progress
      assert.is_nil(server.clients[client.id])
      assert.spy(callbacks.on_disconnect).was_called_with(client, 1006, "Write queue stalled")
    end)

    it("drops a client at the second observation in a row without progress, not at the first", function()
      local tick, _, client, handle = stalled_client()
      assert.is_nil(client.write_stalled)

      answer_and(tick, 1)(handle)
      assert.is_not_nil(server.clients[client.id], "the first observation without progress dropped the client")
      assert.is_true(client.write_stalled)

      answer_and(tick, 1)(handle)
      assert.is_nil(server.clients[client.id])
      assert.spy(callbacks.on_disconnect).was_called_with(client, 1006, "Write queue stalled")
    end)

    it("clears the count when an observation finds progress", function()
      local tick, _, client, handle = stalled_client()
      answer_and(tick, 1)(handle)
      assert.is_true(client.write_stalled)

      handle.drain(1024)
      answer_and(tick, 1)(handle)
      assert.is_nil(client.write_stalled)

      answer_and(tick, 1)(handle) -- the first observation without progress again
      assert.is_not_nil(server.clients[client.id])
      assert.is_true(client.write_stalled)
    end)

    it("still drops a stalled client within two ticks when every tick comes late", function()
      local tick, _, client, handle = stalled_client()

      answer_and(tick, 1.06)(handle) -- 6% late, as under a loop that is always a little busy
      assert.is_true(client.write_stalled)
      answer_and(tick, 1.4)(handle) -- below the wake threshold of 1.5 intervals

      assert.is_nil(server.clients[client.id], "late ticks kept a stalled client")
      assert.spy(callbacks.on_disconnect).was_called_with(client, 1006, "Write queue stalled")
    end)

    it("serves two ticks that came before one poll phase with one observation", function()
      local tick, raw_tick, client, handle = stalled_client()

      answer_and(raw_tick, 1)(handle)
      answer_and(raw_tick, 1)(handle)
      poll() -- one observation for both ticks: the first without progress
      assert.is_not_nil(server.clients[client.id])
      assert.is_true(client.write_stalled)

      answer_and(tick, 1)(handle)
      assert.is_nil(server.clients[client.id])
    end)

    it("makes no observation at the tick that finds the machine woken from sleep, and clears the count", function()
      local tick, _, client, handle = stalled_client()
      answer_and(tick, 1)(handle)
      assert.is_true(client.write_stalled)

      clock = clock + 600000 -- the machine slept for ten minutes
      tick()

      assert.is_nil(client.write_stalled, "the wake kept the count")
      assert.is_not_nil(server.clients[client.id], "the sleep counted against the client")
    end)

    it("judges only the clients that answered at the tick", function()
      local tick, _, client, handle = stalled_client()
      answer_and(tick, 1)(handle)
      assert.is_true(client.write_stalled)

      -- No pong for two intervals: the pong rule gives its second chance, and the stall rule leaves the client alone.
      client.last_pong = clock - 2 * interval
      clock = clock + interval
      tick()

      assert.is_not_nil(server.clients[client.id])
      assert.is_true(client.pong_overdue)
      assert.is_true(client.write_stalled)
    end)

    describe("with the prepare and check handles of the server", function()
      it("creates them with the ping timer, and arms them only between a tick and its observation", function()
        local _, raw_tick = start_ping_timer()
        assert.equals(1, #prepares)
        assert.equals(1, #checks)
        assert.is_false(prepares[1].active or checks[1].active)

        connect_and_upgrade()
        raw_tick()
        assert.is_true(prepares[1].active)
        assert.is_false(checks[1].active)

        poll()
        assert.is_false(prepares[1].active or checks[1].active, "a handle keeps running after its observation")
        assert.is_false(prepares[1].closed or checks[1].closed)
      end)

      it("does not arm them for a server without a connected client", function()
        local _, raw_tick = start_ping_timer()
        raw_tick()
        assert.is_false(prepares[1].active)
      end)

      it("reuses them when the ping timer starts again", function()
        start_ping_timer()
        start_ping_timer()
        assert.equals(1, #prepares)
        assert.equals(1, #checks)
      end)

      it("closes them in stop_server, and a pending observation never runs", function()
        local _, raw_tick = start_ping_timer()
        local client, _, handle = connect_and_upgrade()
        tcp.send_to_client(server, client.id, string.rep("x", 262144))
        raw_tick()
        assert.is_true(prepares[1].active)

        tcp.stop_server(server)

        assert.is_true(prepares[1].closed and checks[1].closed, "stop_server left a handle open")
        assert.is_nil(server.stall_check)
        poll() -- nothing runs, and nothing fails
        assert.is_true(handle:is_closing() or client.state ~= "connected")
        tcp.stop_server(server) -- a second stop leaves nothing to close
      end)

      it("closes the timer and every handle, and reports an error, when libuv cannot create a handle", function()
        local on_error = spy.new(function() end)
        server.on_error = on_error
        vim.loop.new_check = function()
          return nil
        end

        local result = tcp.start_ping_timer(server, interval)

        assert.is_nil(result)
        assert.spy(on_error).was_called(1)
        assert.is_true(timers[#timers].closed, "the ping timer was left open")
        assert.is_true(prepares[1].closed, "the prepare handle was left open")
        assert.is_nil(server.stall_check)
      end)
    end)

    describe("is_client_reading", function()
      local client_manager

      before_each(function()
        client_manager = require("claudecode.server.client")
      end)

      local function silent_client()
        local client, _, handle = connect_and_upgrade()
        tcp.send_to_client(server, client.id, string.rep("x", 262144))
        client_manager.is_client_reading(client) -- sees the 101 reply
        return client, handle
      end

      it("says false only at the second observation in a row that found no progress", function()
        local client = silent_client()
        assert.is_true(client_manager.is_client_reading(client))
        assert.is_false(client_manager.is_client_reading(client))
      end)

      it("clears the count when an observation finds progress", function()
        local client, handle = silent_client()
        assert.is_true(client_manager.is_client_reading(client))
        assert.is_true(client.write_stalled)
        handle.drain(1)
        assert.is_true(client_manager.is_client_reading(client))
        assert.is_nil(client.write_stalled)
      end)

      it("counts an empty queue as progress", function()
        local client, handle = silent_client()
        assert.is_true(client_manager.is_client_reading(client))
        handle.drain(math.huge)
        assert.is_true(client_manager.is_client_reading(client))
        assert.is_nil(client.write_stalled)
      end)
    end)
  end)

  -- `queued_bytes` must count every frame that the server writes, or a reader that makes progress looks stalled. A
  -- reader that drains less than the frames queued behind its reads loses its progress in the count.
  describe("when the server counts the frames it writes", function()
    local reply = string.rep("x", 262144)

    it("counts the pings it sends, while a reader drains one byte per tick", function()
      local tick = start_ping_timer()
      local client, _, handle = connect_and_upgrade()
      tcp.send_to_client(server, client.id, reply)
      for _ = 1, 8 do
        handle.drain(1)
        handle._read_cb(nil, frame.create_frame(frame.OPCODE.PONG, "", true, true))
        clock = clock + interval
        tick()
        assert.is_not_nil(server.clients[client.id], "a reader was dropped despite one byte of progress")
      end
    end)

    it("counts the pongs it sends, while a reader drains less than the payload of a pong", function()
      local tick = start_ping_timer()
      local client, _, handle = connect_and_upgrade()
      tcp.send_to_client(server, client.id, reply)
      for _ = 1, 8 do
        handle._read_cb(nil, frame.create_frame(frame.OPCODE.PING, string.rep("p", 125), true, true))
        handle.drain(64)
        handle._read_cb(nil, frame.create_frame(frame.OPCODE.PONG, "", true, true))
        clock = clock + interval
        tick()
        assert.is_not_nil(server.clients[client.id], "a reader was dropped despite 64 bytes of progress")
      end
    end)

    it("reports the write error once, to the callback, when the last piece of a frame fails", function()
      local client, writes = connect_and_upgrade()
      local callback = spy.new(function() end)
      tcp.send_to_client(server, client.id, string.rep("x", 2 * 1024 * 1024), callback)
      for index = 2, #writes - 1 do
        writes[index].done()
      end
      assert.spy(callback).was_not_called()

      writes[#writes].done("EPIPE")

      assert.spy(callback).was_called(1)
      assert.spy(callback).was_called_with("EPIPE")
    end)

    it("counts a broadcast to a client as failed when the last piece of its frame fails", function()
      local _, writes = connect_and_upgrade()
      local on_written = spy.new(function() end)
      tcp.broadcast(server, string.rep("x", 2 * 1024 * 1024), on_written)
      for index = 2, #writes - 1 do
        writes[index].done()
      end
      assert.spy(on_written).was_not_called()

      writes[#writes].done("EPIPE")

      assert.spy(on_written).was_called(1)
      assert.spy(on_written).was_called_with(0)
    end)
  end)

  -- libuv lowers the queue size of a socket by the bytes it wrote on Linux and macOS, but only by a whole write request
  -- when that request is done on Windows. A large frame is queued in pieces, so progress shows after each piece.
  describe("when a message is larger than one piece of a write", function()
    local piece = 1024 * 1024

    it("queues it in pieces that make up the frame, and calls back once, after the last piece", function()
      local client, writes = connect_and_upgrade()
      local message = string.rep("abcdefgh", 3 * piece / 8 + 5) -- three pieces and a short rest
      local expected = frame.create_text_frame(message)
      local callback = spy.new(function() end)

      tcp.send_to_client(server, client.id, message, callback)

      local pieces = {}
      for index = 2, #writes do -- writes[1] is the 101 reply
        table.insert(pieces, writes[index].data)
        assert.is_true(#writes[index].data <= piece)
      end
      assert.equals(4, #pieces)
      assert.is_true(expected == table.concat(pieces), "the pieces are not the frame")
      for index = 2, #writes - 1 do
        writes[index].done()
      end
      assert.spy(callback).was_not_called()
      writes[#writes].done()
      assert.spy(callback).was_called(1)
    end)

    -- A server frame with a payload of 64 KiB or more has a 10-byte header, so a payload of `size - 10` bytes makes a
    -- frame of exactly `size` bytes. A frame of a whole number of pieces plus one byte ends in a piece of one byte, and
    -- only that piece may call back.
    for _, case in ipairs({
      { size = piece, pieces = 1 },
      { size = piece + 1, pieces = 2 },
      { size = 2 * piece + 1, pieces = 3 },
    }) do
      it("calls back once for a frame of " .. case.size .. " bytes", function()
        local client, writes = connect_and_upgrade()
        local callback = spy.new(function() end)

        tcp.send_to_client(server, client.id, string.rep("x", case.size - 10), callback)

        assert.equals(1 + case.pieces, #writes, "the 101 reply and the pieces")
        local total = 0
        for index = 2, #writes do
          total = total + #writes[index].data
        end
        assert.equals(case.size, total)
        for index = 2, #writes - 1 do
          writes[index].done()
        end
        assert.spy(callback).was_not_called()
        writes[#writes].done()
        assert.spy(callback).was_called(1)
      end)
    end

    it("queues a message of one piece or less as one write", function()
      local client, writes = connect_and_upgrade()

      tcp.send_to_client(server, client.id, string.rep("x", piece - 16))

      assert.equals(2, #writes)
    end)

    it("keeps a client whose reader takes several intervals for a message, as libuv counts it on Windows", function()
      local tick = start_ping_timer()
      local client, writes, handle = connect_and_upgrade()
      tcp.send_to_client(server, client.id, string.rep("x", 8 * piece))

      -- Claude reads 2 MB per interval. A write counts as done once Claude read all of it.
      local credit = 0
      for _ = 1, 6 do
        credit = credit + 2 * piece
        for _, write in ipairs(writes) do
          if write.left > 0 then
            if #write.data > credit then
              break
            end
            credit = credit - #write.data
            write.done()
          end
        end
        handle._read_cb(nil, frame.create_frame(frame.OPCODE.PONG, "", true, true))
        clock = clock + interval
        tick()
      end

      assert.is_not_nil(server.clients[client.id], "a Claude that reads the message was dropped")
      assert.spy(callbacks.on_disconnect).was_not_called()
    end)
  end)

  -- The ping timer sees only the clients in `server.clients`. A client that left it with its Close frame still queued
  -- is covered by the deadline of that frame: the same window, and the same rule, no write progress for two intervals.
  describe("when a Close frame waits in the queue of a Claude that does not read", function()
    local reply = string.rep("x", 262144)
    local function binary()
      return frame.create_frame(frame.OPCODE.BINARY, "x", true, true)
    end

    it(
      "closes the socket of a client that broke the protocol once the queue made no progress for the window",
      function()
        start_ping_timer()
        local client, _, handle = connect_and_upgrade()
        tcp.send_to_client(server, client.id, reply)

        handle._read_cb(nil, binary())
        assert.is_nil(server.clients[client.id], "the ping timer would still see the client")
        assert.is_false(handle:is_closing(), "the socket was closed before the Close frame was written")
        local deadline = close_deadline()

        run_after_window(deadline)

        assert.is_true(handle:is_closing(), "the socket still holds the queue")
        assert.equals("closed", client.state)
        assert.is_true(deadline.stopped and deadline.closed, "the deadline keeps running")
        assert.spy(callbacks.on_disconnect).was_called(1)
      end
    )

    it(
      "closes the socket of a client that the server stopped, once the queue made no progress for the window",
      function()
        start_ping_timer()
        local client, _, handle = connect_and_upgrade()
        tcp.send_to_client(server, client.id, reply)

        tcp.stop_server(server)
        assert.is_false(handle:is_closing(), "the socket was closed before the Close frame was written")
        local deadline = close_deadline()

        run_after_window(deadline)

        assert.is_true(handle:is_closing(), "the socket still holds the queue")
        assert.equals("closed", client.state)
        assert.is_true(deadline.stopped and deadline.closed, "the deadline keeps running")
      end
    )

    it("waits while Claude reads, and the write callback then closes the socket and ends the deadline", function()
      start_ping_timer()
      local client, writes, handle = connect_and_upgrade()
      tcp.send_to_client(server, client.id, reply)
      handle._read_cb(nil, binary())
      local deadline = close_deadline()

      handle.drain(1024) -- Claude reads a little: that is progress
      run_after_window(deadline)
      assert.is_false(handle:is_closing(), "a Claude that reads was cut off")
      assert.is_false(deadline.stopped)

      handle.drain(math.huge) -- Claude reads the rest, so the Close frame is written
      assert.is_true(handle:is_closing())
      assert.is_true(deadline.stopped and deadline.closed, "the deadline outlives the write")
      assert.equals(1003, close_status(writes[#writes]))

      -- A deadline that runs after the socket closed does nothing: closing a handle twice is an error in libuv.
      deadline.callback()
      assert.equals("closed", client.state)
    end)

    it("closes the socket once when libuv cancels the Close frame's write after the deadline closed it", function()
      start_ping_timer()
      local client, writes, handle = connect_and_upgrade()
      tcp.send_to_client(server, client.id, reply)
      handle._read_cb(nil, binary())
      local deadline = close_deadline()

      run_after_window(deadline)
      assert.is_true(handle:is_closing())

      -- libuv runs the callback of each write still queued, with ECANCELED, once the handle closes.
      writes[#writes].done("ECANCELED")
      assert.equals("closed", client.state)
    end)

    it("does not wait for a client that the ping timer dropped, whose socket closes at once", function()
      local tick = start_ping_timer()
      local client, _, handle = connect_and_upgrade()
      tcp.send_to_client(server, client.id, reply)

      for _ = 1, 3 do
        handle._read_cb(nil, frame.create_frame(frame.OPCODE.PONG, "", true, true))
        clock = clock + interval
        tick()
      end

      assert.is_nil(server.clients[client.id])
      assert.is_true(handle:is_closing())
      local deadline = close_deadline()
      assert.is_true(deadline.stopped and deadline.closed, "the deadline outlives the drop")
      deadline.callback()
    end)

    it("arms nothing when the Close frame was written at once", function()
      local handle = { closed = false }
      function handle:write(_, callback)
        if callback then
          callback()
        end
      end
      function handle:get_write_queue_size()
        return 0
      end
      function handle:close()
        assert(not self.closed, "handle is already closing")
        self.closed = true
      end
      function handle:is_closing()
        return self.closed
      end
      local client = require("claudecode.server.client").create_client(handle, 2 * interval)
      client.state, client.handshake_complete = "connected", true

      require("claudecode.server.client").close_client(client, 1000, "")

      assert.equals(0, #timers)
      assert.is_true(handle.closed)
    end)

    it("arms nothing for a client that has no keepalive window", function()
      local client, _, handle = connect_and_upgrade() -- no ping timer was started, so the server has no window
      tcp.send_to_client(server, client.id, reply)

      tcp.stop_server(server)

      assert.equals(0, #timers)
      assert.is_false(handle:is_closing())
    end)
  end)
end)
