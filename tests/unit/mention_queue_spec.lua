--- The @ mention queue keeps one promise: a mention you send reaches Claude once and in the order you sent it, or
--- you see an error, and after a stop nothing is sent and no Lua error happens. Each test drives the real plugin
--- (init.lua and the real server/init.lua, tcp.lua and client.lua) on a fake clock, and plays Claude through the real
--- TCP and WebSocket code paths. A test is named after the finding of the verify-mention-queue model it covers.
require("tests.busted_setup")

describe("The @ mention queue", function()
  local token = "test-token-0123456789"
  local upgrade = "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
    .. "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n"
    .. "x-claude-code-ide-authorization: "
    .. token
    .. "\r\n\r\n"

  local loaded = {
    "claudecode",
    "claudecode.config",
    "claudecode.logger",
    "claudecode.terminal",
    "claudecode.lockfile",
    "claudecode.diff",
    "claudecode.server.init",
    "claudecode.server.tcp",
    "claudecode.server.client",
    "claudecode.server.handshake",
  }
  local saved = {}
  local loop, errors, error_times, claudecode, frame, terminal_opens

  -- A fake libuv loop. Like libuv, it fires every timer that is due in one phase, in the order they were started,
  -- and then the main loop runs every scheduled callback before time moves on. A callback that raises is recorded,
  -- as Neovim reports it.
  local function new_timer()
    local timer = { active = false, closing = false }
    function timer:start(timeout, repeat_ms, callback)
      assert(type(timeout) == "number" and timeout >= 0, "timer started with a bad timeout")
      self.due, self.repeat_ms, self.callback, self.active = loop.now + timeout, repeat_ms, callback, true
      table.insert(loop.timers, self)
      return 0
    end
    function timer:stop()
      self.active = false
      return 0
    end
    function timer:close()
      assert(not self.closing, "timer closed twice")
      self.active, self.closing = false, true
    end
    function timer:is_active()
      return self.active
    end
    function timer:is_closing()
      return self.closing
    end
    return timer
  end

  local function protect(fn)
    local ok, err = pcall(fn)
    if not ok then
      table.insert(loop.lua_errors, tostring(err))
    end
  end

  ---Let `ms` milliseconds pass.
  local function run(ms)
    local stop_at = loop.now + ms
    local phases_now = 0
    while true do
      while #loop.scheduled > 0 do
        protect(table.remove(loop.scheduled, 1))
      end
      local due
      for _, timer in ipairs(loop.timers) do
        if timer.active and timer.due <= stop_at and (not due or timer.due < due) then
          due = timer.due
        end
      end
      if not due then
        break
      end
      phases_now = due == loop.now and phases_now + 1 or 0
      assert(phases_now < 1000, "the timers keep firing without letting time pass")
      loop.now = due
      local firing = {}
      for _, timer in ipairs(loop.timers) do
        if timer.active and timer.due == due then
          table.insert(firing, timer)
        end
      end
      for _, timer in ipairs(firing) do
        -- A timer that an earlier callback of this phase stopped does not fire.
        if timer.active then
          if timer.repeat_ms and timer.repeat_ms > 0 then
            timer.due = timer.due + timer.repeat_ms
          else
            timer.active = false
          end
          protect(timer.callback)
        end
      end
    end
    loop.now = stop_at
  end

  ---Run fn from a uv timer callback `ms` from now, in the same phase as the plugin's timers that are due then.
  local function at(ms, fn)
    new_timer():start(ms, 0, fn)
  end

  before_each(function()
    loop = { now = 0, timers = {}, scheduled = {}, lua_errors = {} }
    errors = {}
    error_times = {}
    saved = {
      new_timer = vim.loop.new_timer,
      now = vim.loop.now,
      schedule = vim.schedule,
      schedule_wrap = vim.schedule_wrap,
      defer_fn = vim.defer_fn,
      getcwd = vim.fn.getcwd,
      isdirectory = vim.fn.isdirectory,
    }
    vim.loop.new_timer = new_timer
    vim.loop.now = function()
      return loop.now
    end
    vim.schedule = function(fn)
      table.insert(loop.scheduled, fn)
    end
    vim.schedule_wrap = function(fn)
      return function(...)
        local args = { ... }
        vim.schedule(function()
          fn(unpack(args))
        end)
      end
    end
    vim.defer_fn = function(fn, timeout)
      local timer = new_timer()
      timer:start(timeout, 0, function()
        vim.schedule(fn)
      end)
      return timer
    end
    vim.fn.getcwd = function()
      return "/project"
    end
    vim.fn.isdirectory = function()
      return 0
    end

    for _, name in ipairs(loaded) do
      package.loaded[name] = nil
    end
    local function record_error(_, ...)
      local parts = {}
      for i = 1, select("#", ...) do
        parts[i] = tostring(select(i, ...))
      end
      table.insert(errors, table.concat(parts, " "))
      table.insert(error_times, loop.now)
    end
    package.loaded["claudecode.logger"] = {
      setup = function() end,
      error = record_error,
      warn = function() end,
      info = function() end,
      debug = function() end,
      trace = function() end,
      one_line = function(level, component, message)
        if level == "error" then
          record_error(component, message)
        end
      end,
      is_level_enabled = function()
        return false
      end,
    }
    terminal_opens = 0
    package.loaded["claudecode.terminal"] = {
      setup = function() end,
      open = function()
        terminal_opens = terminal_opens + 1
      end,
      ensure_visible = function() end,
    }
    package.loaded["claudecode.lockfile"] = {
      generate_auth_token = function()
        return token
      end,
      create = function(port, auth_token)
        return true, "/lock/" .. port .. ".lock", auth_token
      end,
      remove = function()
        return true
      end,
    }
    package.loaded["claudecode.diff"] = {
      setup = function() end,
      close_pending_diffs = function() end,
      close_diffs_for_client = function() end,
    }
    frame = require("claudecode.server.frame")
    claudecode = require("claudecode")
    claudecode.setup({ auto_start = false, track_selection = false, enable_broadcast_debouncing_in_tests = true })
    assert(claudecode.start(false))
    run(0)
  end)

  after_each(function()
    if claudecode.state.server then
      claudecode.stop()
    end
    vim.loop.new_timer = saved.new_timer
    vim.loop.now = saved.now
    vim.schedule = saved.schedule
    vim.schedule_wrap = saved.schedule_wrap
    vim.defer_fn = saved.defer_fn
    vim.fn.getcwd = saved.getcwd
    vim.fn.isdirectory = saved.isdirectory
    for _, name in ipairs(loaded) do
      package.loaded[name] = nil
    end
  end)

  ---Claude opens a TCP connection. Its socket keeps every frame the plugin writes, and the 101 reply's write
  ---completes only when the test calls `handshake_written`, as a libuv write completes in a later loop turn.
  local function claude_connects()
    local tcp = require("claudecode.server.tcp")
    local server = claudecode.state.server.state.server
    tcp._handle_new_connection(server)
    local client = assert(server.clients["client_" .. _G.claudecode_clients_created])
    local claude = { client = client, written = {}, closed = false }
    local handle = client.tcp_handle
    function handle.write(_, data, callback)
      assert(not claude.closed, "write after close")
      if data:sub(1, 12) == "HTTP/1.1 101" then
        claude.reply_written = callback
      elseif claude.write_refused then
        -- libuv refuses the write at once: it returns nil and the error, and never runs the callback.
        return nil, claude.write_refused
      elseif claude.write_error then
        -- The socket fails during the write: libuv reports it only to the write callback, in a later loop turn.
        if callback then
          at(0, function()
            callback(claude.write_error)
          end)
        end
      else
        table.insert(claude.written, data)
        if callback then
          callback()
        end
      end
    end
    function handle.close()
      claude.closed = true
    end
    function handle.is_closing()
      return claude.closed
    end

    function claude.upgrade()
      handle._read_cb(nil, upgrade)
      assert(claude.reply_written, "the plugin did not answer the upgrade request")
    end
    function claude.handshake_written()
      claude.reply_written()
      assert.equals("connected", client.state)
    end
    function claude.handshake()
      claude.upgrade()
      claude.handshake_written()
    end
    -- Claude's socket ends (EOF): the server forgets the client at once.
    function claude.drop()
      handle._read_cb(nil, nil)
    end
    -- Claude sends a CLOSE frame: the client is "closing" until the scheduled on_close removes it.
    function claude.close()
      handle._read_cb(nil, frame.create_frame(frame.OPCODE.CLOSE, "\3\232", true, true))
      assert.equals("closing", client.state)
    end
    -- Claude answers a ping: the server sets last_pong.
    function claude.pong()
      handle._read_cb(nil, frame.create_frame(frame.OPCODE.PONG, "", true, true))
    end
    ---@return string[] paths The filePath of each at_mentioned notification Claude received, in order.
    function claude.received()
      local paths = {}
      for _, data in ipairs(claude.written) do
        local parsed = frame.parse_frame(data)
        -- vim.json.decode is a stub under busted, and Neovim's encoder escapes "/" as "\/".
        if parsed and parsed.opcode == frame.OPCODE.TEXT and parsed.payload:find('"at_mentioned"', 1, true) then
          local path = assert(parsed.payload:match('"filePath":"(.-)"'), parsed.payload)
          table.insert(paths, (path:gsub("\\/", "/")))
        end
      end
      return paths
    end
    return claude
  end

  local function send(path)
    local ok, err = claudecode.send_at_mention(path, nil, nil, "test")
    assert.is_true(ok, err)
  end

  local function names(paths)
    local out = {}
    for i, path in ipairs(paths) do
      out[i] = path:match("[^/]+$")
    end
    return out
  end

  local function assert_no_lua_error()
    assert.same({}, loop.lua_errors)
  end

  ---From now until `till` ms from now, a client connects every `period` ms and completes its handshake. Each one
  ---leaves (EOF) `life` ms after it connected.
  ---@return table[] clients The clients that connected so far
  local function churn(period, life, till)
    local clients = {}
    for start = 0, till - 1, period do
      at(start, function()
        local claude = claude_connects()
        claude.handshake()
        table.insert(clients, claude)
        at(life, claude.drop)
      end)
    end
    return clients
  end

  local function assert_nothing_received(clients)
    for _, claude in ipairs(clients) do
      assert.same({}, claude.received())
    end
  end

  it("control: mentions queued while Claude starts reach Claude once it connects, in order, each once", function()
    send("/project/a.lua")
    send("/project/b.lua")
    send("/project/c.lua")
    run(1000)
    local claude = claude_connects()
    claude.handshake()
    run(1500)

    assert.same({ "a.lua", "b.lua", "c.lua" }, names(claude.received()))
    assert.same({}, errors)
    assert_no_lua_error()
    assert.same({}, claudecode.state.mention_queue)
    assert.is_nil(claudecode.state.mention_timer)
    assert.is_nil(claudecode.state.connection_timer)
  end)

  it("A: a mention queued while Claude starts slowly is delivered, not expired", function()
    send("/project/a.lua")
    run(4600)
    local claude = claude_connects()
    claude.handshake()
    run(1500)

    assert.same({ "a.lua" }, names(claude.received()))
    assert.same({}, errors)
  end)

  it("A: a Claude whose handshake comes 9.9 s after the send is ready at 10.5 s and gets the mention", function()
    send("/project/a.lua")
    run(9900)
    local claude = claude_connects()
    claude.handshake()
    run(1500)

    assert.same({ "a.lua" }, names(claude.received()))
    assert.same({}, errors)
    assert.same({}, claudecode.state.mention_queue)
    assert.is_nil(claudecode.state.connection_timer)
  end)

  it(
    "A, F4: a Claude whose handshake comes 10.3 s after the send is not ready by the deadline: you see an error",
    function()
      send("/project/a.lua")
      run(10300)
      local claude = claude_connects()
      claude.handshake()
      run(1500)

      assert.same({}, claude.received())
      assert.same({ 10600 }, error_times)
      assert.matches(
        "Send timeout %- clearing 1 queued @ mentions that the connected Claude did not take in time",
        errors[1]
      )
      assert.same({}, claudecode.state.mention_queue)
    end
  )

  it("H: Claude drops during the wait after its handshake: the next Claude gets the mention", function()
    send("/project/a.lua")
    local first = claude_connects()
    first.handshake()
    run(100)
    first.drop()
    run(1000)
    assert.same({}, first.received())
    assert.same({}, errors)

    local second = claude_connects()
    second.handshake()
    run(1500)

    assert.same({ "a.lua" }, names(second.received()))
    assert.same({}, errors)
  end)

  it("H: Claude drops during the wait after its handshake and never returns: you see an error", function()
    send("/project/a.lua")
    local claude = claude_connects()
    claude.handshake()
    run(100)
    claude.drop()
    run(11000)

    assert.same({}, claude.received())
    assert.equals(1, #errors)
    assert.matches("Connection timeout", errors[1])
    assert.same({}, claudecode.state.mention_queue)
  end)

  it("H: a handshake and a drop just before the deadline do not move it", function()
    send("/project/a.lua")
    run(9900)
    local claude = claude_connects()
    claude.handshake()
    run(50)
    claude.drop()
    run(2000)

    assert.same({}, claude.received())
    assert.same({ 10600 }, error_times)
    assert.matches("Connection timeout %- clearing 1 queued @ mentions", errors[1])
    assert.same({}, claudecode.state.mention_queue)
  end)

  it("control: a send in the tick after the handshake waits connection_wait_delay with the queued mentions", function()
    send("/project/first.lua")
    local claude = claude_connects()
    claude.handshake()
    -- The handshake's on_open callback still waits for the main loop: Claude counts as connected already.
    send("/project/second.lua")
    run(500)
    assert.same({}, claude.received(), "nothing goes out before connection_wait_delay ends")
    run(1000)

    assert.same({ "first.lua", "second.lua" }, names(claude.received()))
    assert.same({}, errors)
  end)

  it("H: a connected client takes the mention but its socket fails during the write: you see an error", function()
    local claude = claude_connects()
    claude.handshake()
    run(1000)
    claude.write_error = "ECONNRESET"
    send("/project/a.lua")
    run(1000)

    assert.same({}, claude.received())
    assert.equals(1, #errors)
    assert.matches("connection failed while the @ mention /project/a%.lua was sent", errors[1])
  end)

  it("H: a write that libuv refuses at once shows an error too", function()
    local claude = claude_connects()
    claude.handshake()
    run(1000)
    claude.write_refused = "EBADF: bad file descriptor"
    send("/project/a.lua")
    run(1000)

    assert.same({}, claude.received())
    assert.same({}, claudecode.state.mention_queue)
    assert.equals(1, #errors)
    assert.matches("connection failed while the @ mention /project/a%.lua was sent", errors[1])
  end)

  it("H: with disable_broadcast_debouncing, a send whose write fails shows an error with the absolute path", function()
    claudecode.state.config.disable_broadcast_debouncing = true
    local claude = claude_connects()
    claude.handshake()
    run(1000)
    claude.write_error = "ECONNRESET"
    send("src/a.lua")
    -- The send went out at once: nothing waits in the queue, and no flush is due.
    assert.same({}, claudecode.state.mention_queue)
    assert.is_nil(claudecode.state.mention_timer)
    run(100)

    assert.same({}, claude.received())
    assert.equals(1, #errors)
    assert.matches("connection failed while the @ mention /project/src/a%.lua was sent", errors[1])
  end)

  it("D: with disable_broadcast_debouncing, a send right after the handshake waits for connection_wait_delay", function()
    claudecode.state.config.disable_broadcast_debouncing = true
    local claude = claude_connects()
    claude.handshake()
    run(100)
    send("/project/a.lua")
    -- Claude is not ready yet, so the send waits in the queue, as it does with the debounce on.
    assert.equals(1, #claudecode.state.mention_queue)
    run(490)

    assert.same({}, claude.received())
    run(20)

    assert.same({ "a.lua" }, names(claude.received()))
    assert.same({}, errors)
  end)

  it("D: handshakes of other clients do not postpone a flush that is due for a connected Claude", function()
    local claude = claude_connects()
    claude.handshake()
    run(1000)
    send("/project/a.lua")
    for _ = 1, 10 do
      claude_connects().handshake()
      run(40)
    end

    assert.same({ "a.lua" }, names(claude.received()))
    assert.same({}, errors)
  end)

  it(
    "D: when the Claude a flush was kept for leaves, a newly connected Claude still gets connection_wait_delay",
    function()
      local first = claude_connects()
      first.handshake()
      run(1000)
      send("/project/a.lua")
      run(10)
      local second = claude_connects()
      second.handshake()
      run(10)
      first.drop()
      run(280)
      assert.same({}, second.received(), "nothing goes out before the new Claude's connection_wait_delay ends")

      run(400)
      assert.same({ "a.lua" }, names(second.received()))
      assert.same({}, errors)
    end
  )

  it("D: a Claude whose handshake came 700 ms after its TCP connect still gets connection_wait_delay", function()
    local claude = claude_connects()
    run(700)
    claude.handshake()
    send("/project/a.lua")
    run(300)
    assert.same({}, claude.received(), "the wait starts at the handshake, not at the TCP connect")

    run(400)
    assert.same({ "a.lua" }, names(claude.received()))
  end)

  it("D: a Claude whose CLOSE frame arrives as a flush is due does not count as ready", function()
    local first = claude_connects()
    first.handshake()
    run(1000)
    local second = claude_connects()
    second.handshake()
    send("/project/a.lua")
    -- In the timer phase of the due flush, after it: the ready Claude sends its CLOSE frame and is "closing".
    at(50, first.close)
    run(300)
    assert.same({}, second.received(), "only a connected Claude counts as ready")

    run(400)
    assert.same({ "a.lua" }, names(second.received()))
    assert.same({}, first.received())
  end)

  it("D: when the Claude a flush waits for leaves during the wait, the next Claude gets its own wait", function()
    local first = claude_connects()
    first.handshake()
    send("/project/a.lua")
    run(300)
    first.drop()
    run(200)
    local second = claude_connects()
    second.handshake()
    run(300)
    assert.same({}, second.received(), "the flush checks again after its wait")

    run(400)
    assert.same({ "a.lua" }, names(second.received()))
  end)

  it("D: a Claude that answered a ping just now has still been connected since its handshake", function()
    local claude = claude_connects()
    claude.handshake()
    run(1000)
    claude.pong()
    send("/project/a.lua")
    run(100)

    assert.same({ "a.lua" }, names(claude.received()))
  end)

  it("S: clients that overlap but each leave before they are ready do not hold a mention past its deadline", function()
    -- A client connects every 200 ms and stays 300 ms, for 20 s: one is always connected, and none is connected for
    -- connection_wait_delay (600 ms). The mention is sent while the first client is connected.
    local clients = churn(200, 300, 20000)
    run(1)
    send("/project/a.lua")
    run(20400)

    assert.same({ 10601 }, error_times)
    assert.matches("Send timeout %- clearing 1 queued", errors[1])
    assert.same({}, claudecode.state.mention_queue)
    assert_nothing_received(clients)
    assert_no_lua_error()
  end)

  -- A client connects every `period` ms and stays `life` ms, for 30 s: never two at once, and none for
  -- connection_wait_delay (600 ms). The mention is sent while the first client is connected, after its handshake.
  for _, case in ipairs({ { 1000, 300 }, { 700, 300 }, { 650, 500 }, { 900, 100 } }) do
    local period, life = case[1], case[2]
    it(
      ("S: clients that connect every %d ms and stay %d ms do not hold a mention past its deadline"):format(
        period,
        life
      ),
      function()
        local clients = churn(period, life, 30000)
        run(1)
        send("/project/a.lua")
        run(30000)

        assert.same({ 10601 }, error_times)
        assert.matches("clearing 1 queued", errors[1])
        assert.same({}, claudecode.state.mention_queue)
        assert_nothing_received(clients)
        assert_no_lua_error()
      end
    )
  end

  it("control: a mention sent 12 s after the last one went out gets its own deadline", function()
    local first = claude_connects()
    first.handshake()
    send("/project/a.lua")
    run(12000)
    assert.same({ "a.lua" }, names(first.received()))
    first.drop()
    local second = claude_connects()
    second.handshake()
    send("/project/b.lua")
    run(1000)

    assert.same({ "b.lua" }, names(second.received()))
    assert.same({}, errors)
  end)

  it("C, control: a mention sent 12 s after a stop and a start gets its own deadline", function()
    local first = claude_connects()
    first.handshake()
    send("/project/a.lua")
    run(100)
    claudecode.stop()
    assert(claudecode.start(false))
    run(12000)
    local second = claude_connects()
    second.handshake()
    send("/project/b.lua")
    run(1000)

    assert.same({ "b.lua" }, names(second.received()))
    assert.same({}, errors)
  end)

  it("E: a mention sent during the wait after a connect arrives after the one queued before it", function()
    send("/project/first.lua")
    local claude = claude_connects()
    claude.handshake()
    run(100)
    send("/project/second.lua")
    run(400)
    assert.same({}, claude.received(), "nothing goes out before connection_wait_delay ends")
    run(1100)

    assert.same({ "first.lua", "second.lua" }, names(claude.received()))
    assert.same({}, errors)
  end)

  it("E: with disable_broadcast_debouncing, a connected send does not overtake queued mentions", function()
    claudecode.state.config.disable_broadcast_debouncing = true
    send("/project/first.lua")
    local claude = claude_connects()
    claude.handshake()
    run(100)
    send("/project/second.lua")
    run(1500)

    assert.same({ "first.lua", "second.lua" }, names(claude.received()))
    assert.same({}, errors)
  end)

  it("C: :ClaudeCodeStop during the wait after a connect raises no Lua error and sends nothing", function()
    send("/project/a.lua")
    local claude = claude_connects()
    claude.handshake()
    run(100)
    claudecode.stop()
    assert.is_nil(claudecode.state.mention_timer)
    assert.is_nil(claudecode.state.connection_timer)
    run(11000)

    assert_no_lua_error()
    assert.same({}, claude.received())
    assert.same({}, errors)
  end)

  it("C: a stop and a start during the wait do not send the old mention to the new Claude", function()
    send("/project/a.lua")
    local first = claude_connects()
    first.handshake()
    run(100)
    claudecode.stop()
    assert(claudecode.start(false))
    local second = claude_connects()
    second.handshake()
    run(1500)

    assert_no_lua_error()
    assert.same({}, second.received())
  end)

  it("C: a stop cancels a deadline whose callback already waits for the main loop", function()
    send("/project/old.lua")
    -- In the timer phase in which the deadline passes, before its callback runs: stop, start, and send again.
    at(10600, function()
      claudecode.stop()
      assert(claudecode.start(false))
      send("/project/new.lua")
    end)
    run(10600)
    assert.same({}, errors, "the old deadline must not clear the mention sent after the stop")

    run(10700)
    assert.same({ 21200 }, error_times)
    assert.matches("clearing 1 queued", errors[1])
    assert_no_lua_error()
  end)

  it(
    "B, C: :ClaudeCodeStop drops the deadline of the old mention: a mention sent after a restart gets its own",
    function()
      send("/project/old.lua")
      run(5000)
      claudecode.stop()
      assert(claudecode.start(false))
      send("/project/new.lua")
      run(10599)
      assert.same({}, errors, "the old deadline at 10.6 s must not clear the mention sent after the restart")

      run(1)
      assert.same({ 15600 }, error_times)
      assert.matches("Connection timeout %- clearing 1 queued", errors[1])
      assert_no_lua_error()
    end
  )

  it("B: mentions sent 5 s apart with no Claude each time out at their own deadline", function()
    send("/project/first.lua")
    run(5000)
    send("/project/second.lua")
    run(5000)
    send("/project/third.lua")
    run(599)
    assert.same({}, errors)

    run(1)
    assert.matches("Connection timeout %- clearing 1 queued", errors[1])
    assert.equals(2, #claudecode.state.mention_queue)
    run(10000)

    assert.same({ 10600, 15600, 20600 }, error_times)
    assert.matches("Connection timeout %- clearing 1 queued", errors[2])
    assert.matches("Connection timeout %- clearing 1 queued", errors[3])
    assert.same({}, claudecode.state.mention_queue)
    assert.is_nil(claudecode.state.connection_timer)
  end)

  it("B: of two mentions sent 5 s apart, a Claude ready between their deadlines gets the second", function()
    send("/project/first.lua")
    run(5000)
    send("/project/second.lua")
    run(6000)
    local claude = claude_connects()
    claude.handshake()
    run(10000)

    assert.same({ "second.lua" }, names(claude.received()))
    assert.same({ 10600 }, error_times)
    assert.same({}, claudecode.state.mention_queue)
  end)

  it("B, control: the deadline of a mention that went out clears no later mention", function()
    send("/project/first.lua")
    run(5000)
    send("/project/second.lua")
    run(1000)
    local first = claude_connects()
    first.handshake()
    -- The first mention goes out once Claude is ready, at 6.6 s. Claude leaves before the second one goes out.
    run(610)
    first.drop()
    run(5390)
    local second = claude_connects()
    second.handshake()
    run(1000)

    assert.same({ "first.lua" }, names(first.received()))
    assert.same({ "second.lua" }, names(second.received()))
    assert.same({}, errors)
  end)

  it("B: after a connection timeout, a later mention times out with an error too", function()
    send("/project/first.lua")
    run(10700)
    assert.equals(1, #errors)

    send("/project/second.lua")
    run(10700)

    assert.equals(2, #errors)
    assert.matches("Connection timeout", errors[2])
    assert.same({}, claudecode.state.mention_queue)
  end)

  it("S: Claude drops within the debounce after a connected send: the mention times out with an error", function()
    local claude = claude_connects()
    claude.handshake()
    run(1000)
    send("/project/a.lua")
    run(10)
    claude.drop()
    run(11000)

    assert.same({}, claude.received())
    assert.equals(1, #errors)
    assert.matches("Connection timeout", errors[1])
    assert.same({}, claudecode.state.mention_queue)
  end)

  it("S, control: Claude drops within the debounce after a connected send: the next Claude gets the mention", function()
    local first = claude_connects()
    first.handshake()
    run(1000)
    send("/project/a.lua")
    run(10)
    first.drop()
    run(1000)

    local second = claude_connects()
    second.handshake()
    run(1500)

    assert.same({ "a.lua" }, names(second.received()))
    assert.same({}, errors)
  end)

  it("F: a client that sent its CLOSE frame does not count as connected", function()
    local first = claude_connects()
    first.handshake()
    run(1000)
    first.close()

    assert.is_false(claudecode.is_claude_connected())
    send("/project/a.lua")
    run(1000)

    local second = claude_connects()
    second.handshake()
    run(1500)

    assert.same({}, first.received())
    assert.same({ "a.lua" }, names(second.received()))
    assert.same({}, errors)
  end)

  it("D: a mention sent between Claude's TCP connect and its handshake is sent once the handshake completes", function()
    local claude = claude_connects()
    run(50)
    send("/project/a.lua")
    claude.upgrade()
    run(10)
    claude.handshake_written()
    run(2000)

    assert.same({ "a.lua" }, names(claude.received()))
    run(10000)
    assert.same({}, errors)
  end)

  it("D: a Claude that gets ready just at the deadline gets the mention", function()
    send("/project/a.lua")
    run(9000)
    local claude = claude_connects()
    claude.upgrade()
    -- The handshake completes at 10 s, so Claude is ready at the deadline, 10.6 s, and the flush is due then too.
    at(1000, claude.handshake_written)
    run(2000)

    assert.same({ "a.lua" }, names(claude.received()))
    assert.same({}, errors)
    assert_no_lua_error()
  end)

  ---Send `count` mentions at once, as a tree add of that many files does, and return their names in order.
  local function send_many(count)
    local sent = {}
    for index = 1, count do
      send("/project/f" .. index .. ".lua")
      sent[index] = "f" .. index .. ".lua"
    end
    return sent
  end

  for _, handshake_at in ipairs({ 8000, 9800 }) do
    it(
      ("F1: 100 mentions sent at once all reach a Claude whose handshake comes %d ms later"):format(handshake_at),
      function()
        local sent = send_many(100)
        run(handshake_at)
        local claude = claude_connects()
        claude.handshake()
        -- Claude is ready connection_wait_delay later, and the queue drains to it, 25 ms apart, past the deadline.
        run(5000)

        assert.same(sent, names(claude.received()))
        assert.same({}, errors)
        assert.same({}, claudecode.state.mention_queue)
        assert.is_nil(claudecode.state.mention_timer)
        assert.is_nil(claudecode.state.connection_timer)
        assert_no_lua_error()
      end
    )
  end

  ---The count in the error that cleared the queue.
  local function cleared_count(message)
    return tonumber((assert(message:match("clearing (%d+) queued"), message)))
  end

  it("F1: when a ready Claude leaves in the middle of the queue, the rest leave at their deadline", function()
    send_many(100)
    run(8000)
    local claude = claude_connects()
    claude.handshake()
    run(1000)
    claude.drop()
    local got = #claude.received()
    assert.is_true(got > 0 and got < 100, "Claude got " .. got)
    run(5000)

    assert.same({ 10600 }, error_times)
    assert.matches("Connection timeout", errors[1])
    assert.equals(100 - got, cleared_count(errors[1]))
    assert.same({}, claudecode.state.mention_queue)
    assert.is_nil(claudecode.state.connection_timer)
  end)

  it("F1: when a ready Claude leaves after the deadline, the rest leave at the next flush", function()
    send_many(100)
    run(9800)
    local claude = claude_connects()
    claude.handshake()
    run(1200)
    claude.drop()
    local got = #claude.received()
    assert.is_true(got > 0 and got < 100, "Claude got " .. got)
    run(5000)

    assert.equals(1, #error_times)
    assert.is_true(error_times[1] > 11000 and error_times[1] <= 11025, "the error came at " .. error_times[1])
    assert.matches("Connection timeout", errors[1])
    assert.equals(100 - got, cleared_count(errors[1]))
    assert.same({}, claudecode.state.mention_queue)
    assert.is_nil(claudecode.state.connection_timer)
  end)

  it("F1: when a ready Claude leaves after the deadline while another waits, the rest leave at once", function()
    send_many(100)
    run(9800)
    local first = claude_connects()
    first.handshake()
    run(1100)
    -- A second Claude connects at 10.9 s and is ready only at 11.5 s.
    local second = claude_connects()
    second.handshake()
    run(100)
    first.drop()
    local got = #first.received()
    assert.is_true(got > 0 and got < 100, "the first Claude got " .. got)
    run(5000)

    assert.equals(1, #error_times)
    assert.is_true(error_times[1] > 11000 and error_times[1] <= 11025, "the error came at " .. error_times[1])
    assert.matches("Send timeout", errors[1])
    assert.equals(100 - got, cleared_count(errors[1]))
    assert.same({}, claudecode.state.mention_queue)
    assert_no_lua_error()
  end)

  it("F1: a ready Claude that leaves before its handshake callback ran does not strand the queue", function()
    send("/project/a.lua")
    run(10000)
    -- Neovim runs the scheduled callbacks in order, late when its loop was busy: the handshake's on_open callback runs
    -- only after the deadline, at which Claude is ready, and after Claude left.
    local held = {}
    local schedule = vim.schedule
    vim.schedule = function(fn)
      table.insert(held, fn)
    end
    local claude = claude_connects()
    claude.handshake()
    vim.schedule = schedule
    run(610)
    claude.drop()
    for _, fn in ipairs(held) do
      fn()
    end
    run(1000)

    assert.same({}, claude.received())
    assert.equals(1, #errors)
    assert.matches("Connection timeout %- clearing 1 queued", errors[1])
    assert.same({}, claudecode.state.mention_queue)
    assert.is_nil(claudecode.state.connection_timer)
    assert_no_lua_error()
  end)

  it("E: a send while a flush is due does not postpone that flush", function()
    local claude = claude_connects()
    claude.handshake()
    run(1000)
    send("/project/first.lua")
    run(40)
    send("/project/second.lua")
    run(15)
    assert.same({ "first.lua" }, names(claude.received()), "the flush was due 50 ms after the first send")

    run(100)
    assert.same({ "first.lua", "second.lua" }, names(claude.received()))
    assert.same({}, errors)
  end)

  it("G: a bad path sent while Claude is not connected returns an error and queues nothing", function()
    local ok, err = claudecode.send_at_mention("", nil, nil, "test")

    assert.is_false(ok)
    assert.matches("non%-empty string", err)
    assert.same({}, claudecode.state.mention_queue)
    assert.is_nil(claudecode.state.mention_timer)
    assert.is_nil(claudecode.state.connection_timer)
    assert.equals(0, terminal_opens)
  end)

  it("G: a queued mention reaches Claude with the same absolute path as a connected send", function()
    -- Relative input, as :ClaudeCodeAdd src/queued.lua passes it: both paths must make it absolute at the send.
    send("src/queued.lua")
    local claude = claude_connects()
    claude.handshake()
    run(1500)
    send("src/connected.lua")
    run(1000)

    assert.same({ "/project/src/queued.lua", "/project/src/connected.lua" }, claude.received())
  end)
end)
